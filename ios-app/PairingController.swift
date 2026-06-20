import Foundation
import SideInstallerFFI

/// Drives the RPPairing host (the make-or-break #1 flow). Requests Local
/// Network, keeps the app alive (silent audio) so the listener survives while
/// the user approves the Developer Mode PIN in Settings, advertises the pairing
/// service over Bonjour (NetService — only Local Network needed, no multicast
/// entitlement), runs `si_pairing_run_host` off the main thread, and reports
/// every step into the shared `Engine`.
///
/// Structure ported from StephenDev0/StikPair's PairingController, simplified
/// to keep-alive only (drops the iOS-26 BGContinuedProcessingTask so the
/// deployment floor stays at 17.4).
@MainActor
final class PairingController {

    static let shared = PairingController()

    private let hostName = "SideInstaller"
    private let hostModel = "Mac17,7"   // device sees a Mac-like pairing host
    private let bindAddress = "0.0.0.0"

    private var netService: NetService?
    private let localNetwork = LocalNetworkAuthorization()
    private let keepAlive = KeepAlive()

    private var running = false

    private var engine: Engine { Engine.shared }

    private init() {}

    /// Pairing file destination (also read back when writing into SideStore).
    nonisolated static func pairingFilePath() -> String {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return docs.appendingPathComponent("rp_pairing_file.plist").path
    }

    func start() {
        guard !running else {
            engine.log("Pairing already running.")
            return
        }
        running = true
        engine.pairingStatus = "requesting Local Network…"
        engine.log("RPPairing: requesting Local Network permission…")

        Task {
            guard await localNetwork.request() else {
                engine.log("RPPairing: Local Network permission DENIED. Enable it in Settings › SideInstaller › Local Network, then retry.")
                engine.pairingStatus = "Local Network denied"
                running = false
                return
            }
            engine.log("RPPairing: Local Network granted. Starting keep-alive (silent audio).")
            keepAlive.startAudio()
            engine.pairingStatus = "waiting for device…"
            runHost()
        }
    }

    private func runHost() {
        let bind = bindAddress
        let name = hostName
        let model = hostModel
        let outPath = Self.pairingFilePath()
        // Retained pointer handed to the C callbacks as ctx; released after run.
        let ctx = UnsafeMutableRawPointer(Unmanaged.passRetained(self).toOpaque())

        engine.log("RPPairing: invoking si_pairing_run_host (out=\(outPath))")

        DispatchQueue.global(qos: .userInitiated).async {
            var result = SIPairResult()
            let rc = bind.withCString { bindC in
                name.withCString { nameC in
                    model.withCString { modelC in
                        outPath.withCString { outC in
                            si_pairing_run_host(
                                bindC, 0, nameC, modelC, outC,
                                pairReadyCallback, pairPinCallback, ctx, &result)
                        }
                    }
                }
            }

            let outcome: PairOutcome
            if rc == 0 {
                outcome = .success(
                    name: cStr(result.device_name),
                    model: cStr(result.device_model),
                    udid: cStr(result.device_udid),
                    path: cStr(result.pairing_file_path))
            } else {
                let msg = cStr(result.error)
                outcome = .failure(msg.isEmpty ? "pairing failed (rc=\(rc))" : msg)
            }
            si_pairing_result_free(&result)
            Unmanaged<PairingController>.fromOpaque(ctx).release()

            DispatchQueue.main.async {
                self.finish(outcome)
            }
        }
    }

    private enum PairOutcome {
        case success(name: String, model: String, udid: String, path: String)
        case failure(String)
    }

    private func finish(_ outcome: PairOutcome) {
        stopAdvertising()
        keepAlive.stopAll()
        running = false

        switch outcome {
        case let .success(name, model, udid, path):
            let size = (try? FileManager.default.attributesOfItem(atPath: path)[.size] as? Int) ?? 0
            engine.log("RPPairing: SUCCESS — \(name) (\(model)) UDID \(udid)")
            engine.log("RPPairing: pairing file written to \(path) (\(size) bytes)")
            if size == 0 { engine.log("⚠️ pairing file is zero bytes — Connect will refuse to use it.") }
            engine.pairingFilePath = path
            engine.pairingStatus = "paired: \(name) (\(size)B)"
        case let .failure(message):
            engine.log("RPPairing: FAILED — \(message)")
            engine.pairingStatus = "failed: \(message)"
        }
    }

    // MARK: Bonjour advertising (called from the ready callback)

    fileprivate func startAdvertising(serviceID: String, port: Int32, txt: [String: Data]) {
        stopAdvertising()
        engine.log("RPPairing: advertising _remotepairing-pairable-host._tcp \(serviceID) on port \(port)")
        let service = NetService(
            domain: "",
            type: "_remotepairing-pairable-host._tcp.",
            name: serviceID,
            port: port)
        service.setTXTRecord(NetService.data(fromTXTRecord: txt))
        service.publish()
        netService = service
        engine.pairingStatus = "advertising — open Settings › Privacy & Security › Developer Mode"
    }

    fileprivate func presentPin(_ pin: String) {
        engine.log("RPPairing: PIN = \(pin) — confirm it on this device (Settings → Developer Mode → Pair with SideInstaller).")
        engine.pairingStatus = "enter PIN \(pin) in Settings"
    }

    private func stopAdvertising() {
        netService?.stop()
        netService = nil
    }
}

// MARK: - C callbacks

private let pairReadyCallback: SIPairReadyCb = { ctx, serviceID, port, keys, vals, count in
    guard let ctx = ctx, let serviceID = serviceID else { return }
    let controller = Unmanaged<PairingController>.fromOpaque(ctx).takeUnretainedValue()
    let id = String(cString: serviceID)

    var txt: [String: Data] = [:]
    if let keys = keys, let vals = vals {
        for i in 0..<Int(count) {
            guard let k = keys[i], let v = vals[i] else { continue }
            txt[String(cString: k)] = Data(String(cString: v).utf8)
        }
    }
    DispatchQueue.main.async {
        controller.startAdvertising(serviceID: id, port: Int32(port), txt: txt)
    }
}

private let pairPinCallback: SIPairPinCb = { pin, ctx in
    guard let ctx = ctx, let pin = pin else { return }
    let controller = Unmanaged<PairingController>.fromOpaque(ctx).takeUnretainedValue()
    let pinString = String(cString: pin)
    DispatchQueue.main.async {
        controller.presentPin(pinString)
    }
}

private func cStr(_ ptr: UnsafeMutablePointer<CChar>?) -> String {
    guard let ptr = ptr else { return "" }
    return String(cString: ptr)
}
