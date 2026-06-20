import Foundation
import SideInstallerFFI

/// The single place all business logic lives. SwiftUI's `ContentView` only
/// reads `@Published` state and calls these methods — zero logic in the view,
/// so the real UI can replace the view later without touching anything here.
///
/// A singleton because the C logging callback (a bare `@convention(c)` function
/// pointer that can't capture context) routes lines to `Engine.shared`.
final class Engine: ObservableObject {

    static let shared = Engine()

    // MARK: Log console

    struct LogEntry: Identifiable {
        let id = UUID()
        let stamp: String
        let text: String
    }

    @Published private(set) var lines: [LogEntry] = []

    // MARK: Inputs (debug only; insecure storage is fine here)

    @Published var appleID: String = ""
    @Published var applePassword: String = ""
    @Published var anisetteURL: String = "https://ani.sidestore.io"
    // LocalDevVPN's default device (target) IP; configurable in its app.
    @Published var deviceIP: String = "10.7.0.1"

    // MARK: Plain-text status readouts

    @Published var vpnStatus: String = "unknown"
    @Published var wifiStatus: String = "unknown"
    @Published var pairingStatus: String = "not paired"
    @Published var signInStatus: String = "signed out"

    // Path to the pairing file produced by RPPairing (STEP 2).
    @Published var pairingFilePath: String?

    // Loopback connection over LocalDevVPN (idevice FFI). Long-lived; reused
    // across device-info / list-apps / install. Serialized on deviceQueue.
    let connection = DeviceConnection()
    private let deviceQueue = DispatchQueue(label: "sideinstaller.device")

    // Apple ID sign-in / signing (isideload via FFI). Serialized on signQueue.
    private let signQueue = DispatchQueue(label: "sideinstaller.sign")
    private var signSession: OpaquePointer?          // SignSession*
    @Published var downloadedIPAPath: String?
    @Published var signedAppPath: String?

    // 2FA bridge: the FFI 2FA callback (on a Rust worker thread) blocks on this
    // semaphore until the UI submits/cancels a code.
    @Published var pendingTwoFactor = false
    private let twoFactorSem = DispatchSemaphore(value: 0)
    private var twoFactorResult: String?

    private let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        return f
    }()

    private init() {
        installLogging()
        log("SideInstaller engine ready. Tap “Ping Rust core” to verify the FFI + log spine.")
        // Launch self-test: exercises si_ping (which logs via tracing::info!),
        // proving the full Rust-tracing -> FFI callback -> console path at start.
        ping()
        // Show the loopback/Wi-Fi status on launch so the user knows whether to
        // start LocalDevVPN before the connect/install steps.
        checkVPNAndWifi()
    }

    // MARK: - Logging

    private func installLogging() {
        let rc = si_log_init(siLogCallback, nil)
        if rc == 0 {
            log("si_log_init: OK — idevice tracing is now piped into this console.")
        } else {
            log("si_log_init: already initialised (rc=\(rc)).")
        }
    }

    /// Append a line from Swift. Safe to call from any thread.
    func log(_ message: String) {
        appendLine(message)
    }

    /// Append a line that originated in the Rust core's tracing output.
    func appendRustLine(_ message: String) {
        appendLine("[rust] " + message)
    }

    private func appendLine(_ message: String) {
        let stamp = dateFormatter.string(from: Date())
        let entry = LogEntry(stamp: stamp, text: message)
        if Thread.isMainThread {
            lines.append(entry)
        } else {
            DispatchQueue.main.async { [weak self] in self?.lines.append(entry) }
        }
    }

    func clearLog() {
        lines.removeAll()
    }

    /// One big string for the “Copy logs” button.
    func logText() -> String {
        lines.map { "\($0.stamp)  \($0.text)" }.joined(separator: "\n")
    }

    // MARK: - STEP 1: liveness

    func ping() {
        runInBackground("ping") {
            guard let raw = si_ping() else {
                self.log("si_ping returned null")
                return
            }
            let msg = String(cString: raw)
            si_string_free(raw)
            self.log("si_ping -> \(msg)")
        }
    }

    // MARK: - STEP 2: pairing + connection

    func checkVPNAndWifi() {
        let (vpn, wifi, detail) = NetworkStatus.summarize()
        vpnStatus = vpn ? "tunnel up" : "no tunnel (start LocalDevVPN)"
        wifiStatus = wifi ? "on" : "off"
        log("Network: \(detail)")
        log("VPN(loopback)=\(vpnStatus), Wi-Fi=\(wifiStatus). RSD target \(deviceIP):\(DeviceConnection.rsdPort).")
        if !vpn { log("⚠️ No tunnel interface found — open LocalDevVPN and connect before the connect/install steps.") }
    }

    /// RPPairing host (make-or-break #1). Runs on its own threads inside the
    /// controller; reports back via this engine's log/status.
    func generatePairingFile() {
        Task { @MainActor in PairingController.shared.start() }
    }

    /// Open the loopback tunnel + read device info (make-or-break #2).
    /// Transport is pure TCP/RSD over the LocalDevVPN loopback
    /// (idevice `tunnel_create_rppairing`) — no usbmuxd anywhere.
    func connectAndReadDeviceInfo() {
        let path = pairingFilePath ?? PairingController.pairingFilePath()
        let ip = deviceIP
        deviceQueue.async { [weak self] in
            guard let self else { return }

            // Gate: never attempt a connect with a missing or zero-byte pairing
            // file. A missing file would otherwise surface as a confusing
            // idevice `Socket(ENOENT)` (it maps the file-read error to Socket).
            let size = (try? FileManager.default.attributesOfItem(atPath: path)[.size] as? Int) ?? 0
            guard FileManager.default.fileExists(atPath: path), size > 0 else {
                self.log("Cannot connect: pairing file missing or empty at \(path) (size=\(size)).")
                self.log("Run “Generate pairing file (RPPairing)” and approve the Developer Mode PIN first.")
                self.setMain { self.pairingStatus = "no pairing file — pair first" }
                return
            }

            do {
                self.log("Pairing file OK (\(size) bytes). Connecting over TCP/RSD \(ip):\(DeviceConnection.rsdPort) using \(path) …")
                try self.connection.connect(deviceIP: ip, pairingFilePath: path)
                self.log("Tunnel + RSD handshake established.")
                self.log(try self.connection.rsdSummary())
                let info = try self.connection.deviceInfo()
                if info.isEmpty {
                    self.log("Device info: (lockdownd returned no values)")
                } else {
                    self.log("Device info:")
                    for (k, v) in info { self.log("  \(k) = \(v)") }
                }
                self.setMain { self.pairingStatus = "connected" }
            } catch {
                self.log("Connect FAILED: \(error)")
            }
        }
    }

    func listInstalledApps() {
        deviceQueue.async { [weak self] in
            guard let self else { return }
            guard self.connection.isConnected else {
                self.log("Not connected — run “Connect + read device info” first.")
                return
            }
            do {
                let apps = try self.connection.listApps()
                self.log("installation_proxy reachable — \(apps.count) apps:")
                for a in apps.prefix(200) { self.log("  \(a)") }
            } catch {
                self.log("List apps FAILED: \(error)")
            }
        }
    }

    // MARK: - STEP 3: Apple ID + signing

    private var storageDir: String {
        let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("isideload")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.path
    }

    func appleSignIn() {
        let id = appleID, pw = applePassword, ani = anisetteURL, dir = storageDir
        guard !id.isEmpty, !pw.isEmpty else { log("Enter Apple ID + password first."); return }
        setMain { self.signInStatus = "signing in…" }
        signQueue.async { [weak self] in
            guard let self else { return }
            self.log("Apple ID sign-in for \(id) via anisette \(ani) …")
            var session: OpaquePointer?
            var summary: UnsafeMutablePointer<CChar>?
            var error: UnsafeMutablePointer<CChar>?
            let rc = si_apple_signin(id, pw, ani, "SideInstaller", dir,
                                     twoFactorCallback, nil,
                                     &session, &summary, &error)
            if rc == 0 {
                if let old = self.signSession { si_sign_session_free(old) }
                self.signSession = session
                let s = summary.map { String(cString: $0) } ?? ""
                summary.map { si_string_free($0) }
                self.log("Sign-in OK. \(s)")
                self.setMain { self.signInStatus = "signed in (\(s))" }
            } else {
                let msg = error.map { String(cString: $0) } ?? "rc=\(rc)"
                error.map { si_string_free($0) }
                self.log("Sign-in FAILED: \(msg)")
                self.setMain { self.signInStatus = "sign-in failed" }
            }
        }
    }

    func fetchCertAndProfile() {
        // isideload retrieves/creates the dev certificate and registers the
        // App ID + provisioning profile inside sign_app — there is no separate
        // step in its API. This button documents that.
        log("Cert + App ID + provisioning profile are fetched/registered automatically during “Sign IPA” (isideload's sign_app handles them).")
    }

    func downloadLatestSideStore() {
        log("Fetching latest SideStore release…")
        Task { [weak self] in
            guard let self else { return }
            do {
                let path = try await SideStoreDownloader.downloadLatest { line in self.log(line) }
                self.setMain { self.downloadedIPAPath = path }
                self.log("SideStore IPA ready at \(path)")
            } catch {
                self.log("Download FAILED: \(error)")
            }
        }
    }

    func signIPA() {
        guard let session = signSession else { log("Sign in first."); return }
        guard let ipa = downloadedIPAPath else { log("Download the SideStore IPA first."); return }
        signQueue.async { [weak self] in
            guard let self else { return }
            self.log("Signing \(ipa) …")
            var signed: UnsafeMutablePointer<CChar>?
            var error: UnsafeMutablePointer<CChar>?
            let rc = si_sign_ipa(session, ipa, &signed, &error)
            if rc == 0 {
                let path = signed.map { String(cString: $0) } ?? ""
                signed.map { si_string_free($0) }
                self.setMain { self.signedAppPath = path }
                self.log("Signed bundle at \(path)")
            } else {
                let msg = error.map { String(cString: $0) } ?? "rc=\(rc)"
                error.map { si_string_free($0) }
                self.log("Sign FAILED: \(msg)")
            }
        }
    }

    // MARK: 2FA bridge

    /// Called from a Rust worker thread; blocks until the UI submits/cancels.
    func provideTwoFactorCode(_ outBuf: UnsafeMutablePointer<CChar>, _ len: Int) -> Int32 {
        setMain {
            self.pendingTwoFactor = true
            self.log("2FA required — enter the code from your trusted device.")
        }
        twoFactorSem.wait()
        let code = twoFactorResult
        twoFactorResult = nil
        setMain { self.pendingTwoFactor = false }
        guard let code, !code.isEmpty, len > 1 else { return 0 }
        let bytes = Array(code.utf8.prefix(len - 1))
        outBuf.withMemoryRebound(to: UInt8.self, capacity: len) { dst in
            for (i, b) in bytes.enumerated() { dst[i] = b }
            dst[bytes.count] = 0
        }
        return 1
    }

    func submitTwoFactor(_ code: String) {
        twoFactorResult = code
        twoFactorSem.signal()
    }

    func cancelTwoFactor() {
        twoFactorResult = nil
        twoFactorSem.signal()
    }

    // MARK: - STEP 4: install + finalize

    func installSideStore() {
        guard let bundle = signedAppPath else { log("Sign the IPA first (no signed bundle)."); return }
        deviceQueue.async { [weak self] in
            guard let self else { return }
            guard self.connection.isConnected else { self.log("Not connected — connect first."); return }
            do {
                self.log("Installing signed bundle \(bundle) via AFC + installation_proxy …")
                try self.connection.installSignedApp(bundlePath: bundle)
                self.log("Install request completed.")
            } catch {
                self.log("Install FAILED: \(error)")
            }
        }
    }

    func writePairingIntoSideStore() {
        let path = pairingFilePath ?? PairingController.pairingFilePath()
        // The installed SideStore's bundle id is rewritten by isideload to
        // <original>.<teamID>; read it from the signed bundle's Info.plist, else
        // fall back to the canonical id.
        deviceQueue.async { [weak self] in
            guard let self else { return }
            guard self.connection.isConnected else { self.log("Not connected — connect first."); return }
            let size = (try? FileManager.default.attributesOfItem(atPath: path)[.size] as? Int) ?? 0
            guard FileManager.default.fileExists(atPath: path), size > 0 else {
                self.log("Cannot write pairing: source file missing or empty at \(path) (size=\(size)). Generate the pairing file first.")
                return
            }
            // Resolve the *installed* SideStore bundle id (isideload rewrites it
            // to com.SideStore.SideStore.<teamID>). The installation_proxy is the
            // source of truth; fall back to the signed bundle's id only if the
            // lookup finds nothing.
            let bundleID: String
            do {
                if let found = try self.connection.findInstalledBundleID(base: "com.SideStore.SideStore") {
                    bundleID = found
                } else if let signed = self.signedAppBundleID() {
                    bundleID = signed
                    self.log("SideStore not found via installation_proxy; using signed bundle id \(signed).")
                } else {
                    self.log("Cannot write pairing: no installed app matching com.SideStore.SideStore* — install SideStore first.")
                    return
                }
            } catch {
                self.log("Cannot write pairing: failed to look up installed bundle id: \(error)")
                return
            }
            do {
                self.log("Resolved SideStore bundle id: \(bundleID)")
                self.log("Writing \(path) (\(size)B) into \(bundleID) /Documents/ALTPairingFile.mobiledevicepairing …")
                let written = try self.connection.writePairingFile(intoBundleID: bundleID, pairingFilePath: path)
                self.log("Pairing file written into SideStore and read-back VERIFIED (\(written) bytes on device).")
                self.log("NOTE: bytes are SideInstaller's RPPairing record; confirm SideStore accepts it on your device.")
            } catch {
                self.log("Write pairing FAILED: \(error)")
            }
        }
    }

    /// Read CFBundleIdentifier from the signed .app's Info.plist.
    private func signedAppBundleID() -> String? {
        guard let app = signedAppPath else { return nil }
        let plistPath = (app as NSString).appendingPathComponent("Info.plist")
        guard let data = FileManager.default.contents(atPath: plistPath),
              let plist = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any]
        else { return nil }
        return plist["CFBundleIdentifier"] as? String
    }

    // MARK: - Full pipeline

    func runFullPipeline() {
        log("=== Full pipeline ===")
        log("Recommended manual order (interactive steps need on-device confirmation):")
        log("1) Check VPN + Wi-Fi  2) Generate pairing file (approve PIN)")
        log("3) Connect + read device info  4) Apple ID sign in (enter 2FA)")
        log("5) Download SideStore  6) Sign IPA  7) Install  8) Write pairing file")
        // Run the deterministic tail when prerequisites are already satisfied.
        Task { [weak self] in
            guard let self else { return }
            if self.downloadedIPAPath == nil { self.downloadLatestSideStore() }
            self.log("After download + sign-in, tap Sign IPA → Install → Write pairing, or re-run.")
        }
    }

    // MARK: - Helpers

    private func notImplemented(_ name: String, step: Int) {
        log("‹\(name)› not implemented yet (build-order step \(step)).")
    }

    private func runInBackground(_ label: String, _ work: @escaping () -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            work()
        }
    }

    /// Run a closure on the main queue (for @Published mutations off-thread).
    func setMain(_ work: @escaping () -> Void) {
        if Thread.isMainThread { work() } else { DispatchQueue.main.async(execute: work) }
    }
}

// MARK: - C logging callback

/// Bare C function pointer (no captures) — forwards Rust log lines to the
/// singleton engine on the main queue.
private let siLogCallback: SILogCallback = { _, msg in
    guard let msg = msg else { return }
    let text = String(cString: msg)
    DispatchQueue.main.async {
        Engine.shared.appendRustLine(text)
    }
}

/// Bare C function pointer — bridges isideload's 2FA request to the engine's
/// blocking prompt. Runs on a Rust worker thread.
private let twoFactorCallback: SITwoFactorCb = { _, outBuf, bufLen in
    guard let outBuf = outBuf else { return 0 }
    return Engine.shared.provideTwoFactorCode(outBuf, Int(bufLen))
}
