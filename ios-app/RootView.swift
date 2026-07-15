import SwiftUI

/// Top-level tab container hosting the app's three screens — Install, Pairing
/// and Certificates. (Managing downloaded IPAs now lives in the Settings sheet.)
///
/// Each page paints the shared animated `AppBackground` behind its own content.
/// (`TabView` hosts each tab in an opaque container, so a single backdrop *behind*
/// the `TabView` would be hidden — the background has to live inside each page.)
/// Because that gradient is driven off the wall clock rather than an elapsed
/// timer, every page renders the identical frame, so it stays perfectly in sync
/// and reads as one continuous surface even across tab switches.
///
/// The two-factor prompt lives here, not inside a tab: every flow drives the same
/// shared `Engine` 2FA bridge, and an `.alert` attached at the root presents
/// regardless of which tab is active.
struct RootView: View {
    @EnvironmentObject private var engine: Engine
    /// Owned here so they survive tab switches and share the one `Engine`.
    @StateObject private var certManager = CertManager()
    @StateObject private var pairingManager = PairingManager()
    @State private var twoFactorCode = ""

    var body: some View {
        TabView {
            Tab("ដំឡើង", systemImage: "square.and.arrow.down") {
                ContentView()
            }
            Tab("ការភ្ជាប់", systemImage: "lock.iphone") {
                PairingView(manager: pairingManager)
            }
            Tab("វិញ្ញាបនបត្រ", systemImage: "checkmark.seal") {
                CertsView(manager: certManager)
            }
        }
        .tint(Theme.accent)
        .preferredColorScheme(.dark)
        .alert("កូដផ្ទៀងផ្ទាត់ពីរជាន់", isPresented: $engine.pendingTwoFactor) {
            TextField("កូដ ៦ខ្ទង់", text: $twoFactorCode)
                .keyboardType(.numberPad)
            Button("ដាក់ស្នើ") { engine.submitTwoFactor(twoFactorCode); twoFactorCode = "" }
            Button("បោះបង់", role: .cancel) { engine.cancelTwoFactor(); twoFactorCode = "" }
        } message: {
            Text("បញ្ចូលកូដដែល Apple ទើបតែផ្ញើទៅឧបករណ៍ដែលអ្នកទុកចិត្ត។")
        }
    }
}
