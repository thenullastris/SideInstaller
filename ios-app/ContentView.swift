import SwiftUI
import UIKit

/// RAW, throwaway test harness — default SwiftUI components only, no styling.
/// Three regions: inputs (top), one button per pipeline stage (middle), and the
/// log console (bottom, the important part). All buttons just call `Engine`.
struct ContentView: View {
    @EnvironmentObject private var engine: Engine
    @State private var twoFactorCode: String = ""

    var body: some View {
        VStack(spacing: 0) {
            inputs
            Divider()
            actions
            Divider()
            console
        }
        .alert("Two-factor code", isPresented: $engine.pendingTwoFactor) {
            TextField("6-digit code", text: $twoFactorCode)
                .keyboardType(.numberPad)
            Button("Submit") { engine.submitTwoFactor(twoFactorCode); twoFactorCode = "" }
            Button("Cancel", role: .cancel) { engine.cancelTwoFactor(); twoFactorCode = "" }
        } message: {
            Text("Enter the code from your trusted device.")
        }
    }

    // MARK: Inputs

    private var inputs: some View {
        VStack(alignment: .leading, spacing: 4) {
            TextField("Apple ID email", text: $engine.appleID)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .keyboardType(.emailAddress)
            SecureField("Apple ID password", text: $engine.applePassword)
            TextField("Anisette server URL", text: $engine.anisetteURL)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            TextField("Device IP (LocalDevVPN target)", text: $engine.deviceIP)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .keyboardType(.numbersAndPunctuation)

            Text("VPN: \(engine.vpnStatus)   Wi-Fi: \(engine.wifiStatus)")
            Text("Pairing: \(engine.pairingStatus)")
            Text("Sign-in: \(engine.signInStatus)")
            Text("IPA: \(shortPath(engine.downloadedIPAPath))   Signed: \(shortPath(engine.signedAppPath))")
        }
        .font(.footnote)
        .padding(8)
    }

    private func shortPath(_ p: String?) -> String {
        guard let p else { return "—" }
        return (p as NSString).lastPathComponent
    }

    // MARK: Actions

    private var actions: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 4) {
                Button("Ping Rust core") { engine.ping() }

                Group {
                    Text("Step 2 — pairing + connection").font(.caption).bold()
                    Button("Check VPN + Wi-Fi") { engine.checkVPNAndWifi() }
                    Button("Generate pairing file (RPPairing)") { engine.generatePairingFile() }
                    Button("Connect + read device info") { engine.connectAndReadDeviceInfo() }
                    Button("List installed apps") { engine.listInstalledApps() }
                }

                Group {
                    Text("Step 3 — Apple ID + signing").font(.caption).bold()
                    Button("Apple ID sign in") { engine.appleSignIn() }
                    Button("Fetch cert + App ID + profile") { engine.fetchCertAndProfile() }
                    Button("Download latest SideStore IPA") { engine.downloadLatestSideStore() }
                    Button("Sign IPA") { engine.signIPA() }
                }

                Group {
                    Text("Step 4 — install + finalize").font(.caption).bold()
                    Button("Install SideStore") { engine.installSideStore() }
                    Button("Write pairing file into SideStore") { engine.writePairingIntoSideStore() }
                }

                Divider()
                Button("Run full pipeline") { engine.runFullPipeline() }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(8)
        }
        .frame(maxHeight: 240)
    }

    // MARK: Log console

    private var console: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Log (\(engine.lines.count))").font(.caption).bold()
                Spacer()
                Button("Copy logs") { UIPasteboard.general.string = engine.logText() }
                Button("Clear") { engine.clearLog() }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 1) {
                        ForEach(engine.lines) { line in
                            Text("\(line.stamp)  \(line.text)")
                                .font(.system(.caption2, design: .monospaced))
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .id(line.id)
                        }
                    }
                    .padding(.horizontal, 6)
                }
                .onChange(of: engine.lines.count) { _, _ in
                    if let last = engine.lines.last { proxy.scrollTo(last.id, anchor: .bottom) }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
