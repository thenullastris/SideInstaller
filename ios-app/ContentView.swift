import SwiftUI
import UIKit

/// Friendly, guided one-click installer. The default flow runs every step in
/// order with a progress bar and contextual instructions; the raw per-stage
/// harness lives in a collapsible “Advanced” section at the bottom.
struct ContentView: View {
    @EnvironmentObject private var engine: Engine
    @Environment(\.openURL) private var openURL
    @State private var twoFactorCode: String = ""
    @State private var showAdvanced = false

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                header
                credentials
                sourcePicker
                actionButton
                if engine.isRunning || engine.overallProgress > 0 || engine.finished {
                    progressSection
                }
                if let pin = engine.pairingPIN {
                    pinCard(pin)
                }
                if let guide = engine.guide {
                    guideCard(guide)
                }
                if let error = engine.lastError, !engine.isRunning {
                    errorCard(error)
                }
                if engine.finished {
                    successCard
                }
                advancedSection
            }
            .padding(16)
        }
        .alert("Two-factor code", isPresented: $engine.pendingTwoFactor) {
            TextField("6-digit code", text: $twoFactorCode)
                .keyboardType(.numberPad)
            Button("Submit") { engine.submitTwoFactor(twoFactorCode); twoFactorCode = "" }
            Button("Cancel", role: .cancel) { engine.cancelTwoFactor(); twoFactorCode = "" }
        } message: {
            Text("Enter the code Apple just sent to your trusted device.")
        }
    }

    // MARK: Header

    private var header: some View {
        VStack(spacing: 6) {
            Image(systemName: "square.and.arrow.down.on.square")
                .font(.system(size: 40))
                .foregroundStyle(.tint)
            Text("SideInstaller")
                .font(.largeTitle.bold())
            if let summary = engine.deviceSummary {
                Label(summary, systemImage: "iphone")
                    .font(.caption.bold())
                    .padding(.top, 2)
                    .foregroundStyle(.green)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 8)
    }

    // MARK: What to install

    private var sourcePicker: some View {
        card {
            VStack(alignment: .leading, spacing: 10) {
                Label("What to install", systemImage: "shippingbox")
                    .font(.headline)
                Picker("Version", selection: $engine.installSource) {
                    ForEach(InstallSource.allCases) { src in
                        Text(src.shortName).tag(src)
                    }
                }
                .pickerStyle(.segmented)
            }
        }
        .disabled(engine.isRunning)
    }

    // MARK: Credentials

    private var credentials: some View {
        card {
            VStack(alignment: .leading, spacing: 10) {
                Label("Apple ID", systemImage: "person.crop.circle")
                    .font(.headline)
                TextField("Apple ID email", text: $engine.appleID)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.emailAddress)
                    .textFieldStyle(.roundedBorder)
                SecureField("Apple ID password", text: $engine.applePassword)
                    .textFieldStyle(.roundedBorder)
            }
        }
        .disabled(engine.isRunning)
    }

    // MARK: Primary action

    private var actionButton: some View {
        Button {
            if engine.isRunning { engine.cancelOneClick() } else { engine.runOneClick() }
        } label: {
            HStack {
                if engine.isRunning {
                    ProgressView().tint(.white)
                    Text("Cancel")
                } else {
                    Image(systemName: engine.finished ? "arrow.clockwise" : "square.and.arrow.down")
                    Text(engine.finished ? "Run again" : "Install \(engine.installSource.shortName)")
                }
            }
            .font(.headline)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 14)
        }
        .buttonStyle(.borderedProminent)
        .tint(engine.isRunning ? .red : .accentColor)
    }

    // MARK: Progress + checklist

    private var progressSection: some View {
        card {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text(engine.finished ? "Complete" : "Progress")
                        .font(.headline)
                    Spacer()
                    Text("\(Int(engine.overallProgress * 100))%")
                        .font(.headline.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                ProgressView(value: engine.overallProgress)
                    .tint(engine.finished ? .green : .accentColor)

                VStack(spacing: 0) {
                    ForEach(Step.allCases) { step in
                        StepRow(step: step,
                                state: engine.stepStates[step] ?? .pending,
                                installProgress: engine.installProgress)
                    }
                }
            }
        }
    }

    // MARK: PIN card

    private func pinCard(_ pin: String) -> some View {
        card(tint: .orange) {
            VStack(spacing: 8) {
                Label("Pairing PIN", systemImage: "lock.iphone")
                    .font(.headline)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Text(pin)
                    .font(.system(size: 44, weight: .bold, design: .rounded))
                    .tracking(8)
                    .frame(maxWidth: .infinity)
                Text("Type this code into the prompt in Settings.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button {
                    UIPasteboard.general.string = pin
                } label: {
                    Label("Copy PIN", systemImage: "doc.on.doc")
                        .font(.subheadline)
                }
                .buttonStyle(.bordered)
            }
        }
    }

    // MARK: Guide card

    private func guideCard(_ guide: Guide) -> some View {
        card(tint: .accentColor) {
            VStack(alignment: .leading, spacing: 10) {
                Label(guide.title, systemImage: guide.systemImage)
                    .font(.headline)
                ForEach(Array(guide.steps.enumerated()), id: \.offset) { idx, step in
                    HStack(alignment: .top, spacing: 8) {
                        Text("\(idx + 1).")
                            .font(.subheadline.bold().monospacedDigit())
                            .foregroundStyle(.tint)
                        Text(step)
                            .font(.subheadline)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                if let label = guide.actionLabel, let url = guide.actionURL {
                    Button {
                        openURL(url)
                    } label: {
                        Label(label, systemImage: "arrow.up.right.square")
                            .font(.subheadline)
                    }
                    .buttonStyle(.bordered)
                    .padding(.top, 2)
                }
            }
        }
    }

    // MARK: Error / success

    private func errorCard(_ message: String) -> some View {
        card(tint: .red) {
            VStack(alignment: .leading, spacing: 8) {
                Label("Stopped", systemImage: "exclamationmark.triangle.fill")
                    .font(.headline)
                Text(message)
                    .font(.subheadline)
                    .fixedSize(horizontal: false, vertical: true)
                Text("Fix the issue above, then tap “Install SideStore” to try again. Copy diagnostics from Advanced if you need help.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var successCard: some View {
        card(tint: .green) {
            HStack(spacing: 10) {
                Image(systemName: "checkmark.seal.fill")
                    .font(.title)
                    .foregroundStyle(.green)
                Text("SideStore is installed. Finish the trust step in the card above, then open SideStore.")
                    .font(.subheadline)
            }
        }
    }

    // MARK: Advanced (the old raw harness)

    private var advancedSection: some View {
        DisclosureGroup(isExpanded: $showAdvanced) {
            VStack(alignment: .leading, spacing: 12) {
                advancedInputs
                advancedActions
                Divider()
                console
            }
            .padding(.top, 8)
        } label: {
            Label("Advanced", systemImage: "wrench.and.screwdriver")
                .font(.subheadline.bold())
        }
        .padding(.top, 4)
    }

    private var advancedInputs: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Settings").font(.caption.bold()).foregroundStyle(.secondary)
            TextField("Anisette server URL", text: $engine.anisetteURL)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .textFieldStyle(.roundedBorder)
            TextField("Device IP (LocalDevVPN target)", text: $engine.deviceIP)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .keyboardType(.numbersAndPunctuation)
                .textFieldStyle(.roundedBorder)
            Group {
                Text("VPN: \(engine.vpnStatus)   Wi-Fi: \(engine.wifiStatus)")
                Text("Pairing: \(engine.pairingStatus)")
                Text("Sign-in: \(engine.signInStatus)")
                Text("IPA: \(shortPath(engine.downloadedIPAPath))   Signed: \(shortPath(engine.signedAppPath))")
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
        }
    }

    private var advancedActions: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Run steps individually").font(.caption.bold()).foregroundStyle(.secondary)
            Button("Ping Rust core") { engine.ping() }
            Group {
                Text("Step 2 — pairing + connection").font(.caption2).bold()
                Button("Check VPN + Wi-Fi") { engine.checkVPNAndWifi() }
                Button("Generate pairing file (RPPairing)") { engine.generatePairingFile() }
                Button("Connect + read device info") { engine.connectAndReadDeviceInfo() }
                Button("List installed apps") { engine.listInstalledApps() }
            }
            Group {
                Text("Step 3 — Apple ID + signing").font(.caption2).bold()
                Button("Apple ID sign in") { engine.appleSignIn() }
                Button("Fetch cert + App ID + profile") { engine.fetchCertAndProfile() }
                Button("Download latest SideStore IPA") { engine.downloadLatestSideStore() }
                Button("Sign IPA") { engine.signIPA() }
            }
            Group {
                Text("Step 4 — install + finalize").font(.caption2).bold()
                Button("Install SideStore") { engine.installSideStore() }
                Button("Write pairing file into SideStore") { engine.writePairingIntoSideStore() }
            }
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
    }

    private var console: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Log (\(engine.lines.count))").font(.caption).bold()
                Spacer()
                Button("Copy") { UIPasteboard.general.string = engine.logText() }
                Button("Clear") { engine.clearLog() }
            }
            .font(.caption)
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
                .frame(height: 220)
                .background(Color(.secondarySystemBackground))
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .onChange(of: engine.lines.count) { _, _ in
                    if let last = engine.lines.last { proxy.scrollTo(last.id, anchor: .bottom) }
                }
            }
        }
    }

    // MARK: Helpers

    private func shortPath(_ p: String?) -> String {
        guard let p else { return "—" }
        return (p as NSString).lastPathComponent
    }

    /// A rounded, subtly-tinted container used for every section.
    private func card<Content: View>(tint: Color = .secondary,
                                      @ViewBuilder _ content: () -> Content) -> some View {
        content()
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(14)
            .background(Color(.secondarySystemBackground))
            .clipShape(RoundedRectangle(cornerRadius: 14))
            .overlay(
                RoundedRectangle(cornerRadius: 14)
                    .strokeBorder(tint.opacity(0.25), lineWidth: 1)
            )
    }
}

/// One row of the step checklist: an icon reflecting state + the step title,
/// with a live percentage while installing.
private struct StepRow: View {
    let step: Step
    let state: StepState
    let installProgress: Double

    var body: some View {
        HStack(spacing: 12) {
            icon
                .frame(width: 22, height: 22)
            Text(step.title)
                .font(.subheadline)
                .foregroundStyle(state == .pending ? .secondary : .primary)
            Spacer()
            if step == .install, state == .active {
                Text("\(Int(installProgress * 100))%")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            } else if state == .waiting {
                Text("needs you")
                    .font(.caption2.bold())
                    .foregroundStyle(.orange)
            }
        }
        .padding(.vertical, 6)
    }

    @ViewBuilder
    private var icon: some View {
        switch state {
        case .pending:
            Image(systemName: "circle")
                .foregroundStyle(.tertiary)
        case .active:
            ProgressView()
        case .waiting:
            Image(systemName: "hand.point.up.left.fill")
                .foregroundStyle(.orange)
        case .done:
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
        case .failed:
            Image(systemName: "xmark.circle.fill")
                .foregroundStyle(.red)
        }
    }
}
