import SwiftUI
import UIKit

/// Settings & diagnostics, presented as a sheet from the toolbar gear. Holds the
/// occasional-use configuration (anisette server, device IP) and the activity
/// log for troubleshooting — kept out of the main flow so it stays uncluttered.
struct SettingsView: View {
    @EnvironmentObject private var engine: Engine
    @Environment(\.dismiss) private var dismiss

    /// Lists / deletes the IPAs the app has cached in Documents. Owned here (rather
    /// than injected) because it's pure, cheap file-system work keyed off
    /// `Engine.shared` — a fresh instance just re-scans the disk when the sheet opens.
    @StateObject private var downloadsManager = DownloadsManager()
    /// The IPA the user swiped to delete, pending confirmation.
    @State private var pendingDelete: DownloadedIPA?

    /// `true` once the user picks "កំណត់ដោយខ្លួនឯង…", revealing the free-form URL field.
    @State private var anisetteIsCustom = false

    var body: some View {
        NavigationStack {
            Form {
                downloadsSection
                anisetteSection
                advancedSection
                logSection
            }
            .navigationTitle("ការកំណត់")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("រួចរាល់") { dismiss() }
                }
            }
        }
        .onAppear {
            anisetteIsCustom = !engine.anisetteServers.contains { $0.address == engine.anisetteURL }
            downloadsManager.refresh()
        }
        .alert("លុបការទាញយកនេះឬ?",
               isPresented: Binding(get: { pendingDelete != nil },
                                    set: { if !$0 { pendingDelete = nil } })) {
            Button("លុប", role: .destructive) {
                if let item = pendingDelete { downloadsManager.delete(item) }
                pendingDelete = nil
            }
            Button("បោះបង់", role: .cancel) { pendingDelete = nil }
        } message: {
            if let item = pendingDelete {
                Text("“\(item.fileName)” (\(item.sizeText)) will be removed. You can download it again any time from the Install tab.")
            }
        }
    }

    // MARK: Downloaded IPAs

    /// A compact download manager pinned to the top of Settings: every release
    /// IPA the install flow has cached, its size and age, and swipe-to-delete to
    /// reclaim space. Deleting is non-destructive — the next install re-fetches.
    private var downloadsSection: some View {
        Section {
            if let error = downloadsManager.lastError {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.red)
            }
            if downloadsManager.hasLoaded && downloadsManager.downloads.isEmpty {
                Text("គ្មានឯកសារ IPA ដែលបានទាញយកទេ។ ឯកសារដែលអ្នកដំឡើងពីផ្ទាំង Install នឹងត្រូវផ្ទុកទុកនៅទីនេះ។")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(downloadsManager.downloads) { item in
                    downloadRow(item)
                }
                .onDelete { offsets in
                    if let idx = offsets.first {
                        pendingDelete = downloadsManager.downloads[idx]
                    }
                }
            }
        } header: {
            HStack {
                Text("ឯកសារ IPA ដែលបានទាញយក")
                Spacer()
                if !downloadsManager.downloads.isEmpty {
                    Text("\(downloadsManager.totalSizeText) used")
                        .foregroundStyle(.secondary)
                }
            }
        } footer: {
            Text("ឯកសារ IPA ត្រូវបានផ្ទុកទុកនៅក្នុង Documents របស់កម្មវិធី ដើម្បីឲ្យការដំឡើងឡើងវិញលឿន។ អូសជួរដេកដើម្បីលុប និងដោះលែងទំហំផ្ទុក។")
        }
    }

    private func downloadRow(_ item: DownloadedIPA) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "shippingbox.fill")
                .font(.title3)
                .foregroundStyle(Theme.brand)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.displayName)
                    .font(.subheadline.weight(.medium))
                if let modified = item.modified {
                    Text("Downloaded \(modified.formatted(date: .abbreviated, time: .shortened))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            Text(item.sizeText)
                .font(.caption2.weight(.bold))
                .foregroundStyle(Theme.accent2)
                .padding(.horizontal, 9)
                .padding(.vertical, 4)
                .background(Capsule().fill(Theme.accent.opacity(0.16)))
        }
    }

    // MARK: Anisette server

    private var anisetteSection: some View {
        Section {
            Picker("ម៉ាស៊ីនមេ", selection: anisetteSelection) {
                ForEach(engine.anisetteServers) { server in
                    Text(server.name).tag(Optional(server.address))
                }
                Divider()
                Text("កំណត់ដោយខ្លួនឯង…").tag(String?.none)
            }
            if anisetteIsCustom {
                TextField("URL ម៉ាស៊ីនមេ", text: $engine.anisetteURL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.URL)
            } else {
                Text(engine.anisetteURL)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        } header: {
            Text("ម៉ាស៊ីនមេ Anisette")
        } footer: {
            Text("ប្រើសម្រាប់ចូល Apple។ កម្មវិធីនឹងសាកល្បងម៉ាស៊ីនផ្សេងទៀតដោយស្វ័យប្រវត្តិ ប្រសិនបើមួយណាមិនដំណើរការ។")
        }
    }

    /// Drives the menu: a server's address when one is selected, `nil` for
    /// "កំណត់ដោយខ្លួនឯង…". Selecting a server also stores its address as the URL we use.
    private var anisetteSelection: Binding<String?> {
        Binding(
            get: { anisetteIsCustom ? nil : engine.anisetteURL },
            set: { newValue in
                if let address = newValue {
                    anisetteIsCustom = false
                    engine.anisetteURL = address
                } else {
                    anisetteIsCustom = true
                }
            }
        )
    }

    // MARK: Advanced

    private var advancedSection: some View {
        Section {
            HStack {
                Text("IP ឧបករណ៍")
                Spacer()
                TextField("10.7.0.1", text: $engine.deviceIP)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.numbersAndPunctuation)
                    .multilineTextAlignment(.trailing)
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text("កម្រិតខ្ពស់")
        } footer: {
            Text("គោលដៅតូណែល LocalDevVPN។ ទុកតម្លៃលំនាំដើម លុះត្រាតែអ្នកបានផ្លាស់ប្តូរវា។")
        }
    }

    // MARK: Activity log

    private var logSection: some View {
        Section {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        ForEach(engine.lines) { line in
                            Text("\(line.stamp)  \(line.text)")
                                .font(.system(.caption2, design: .monospaced))
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .id(line.id)
                        }
                    }
                    .padding(.vertical, 4)
                }
                .frame(height: 240)
                .onChange(of: engine.lines.count) { _, _ in
                    if let last = engine.lines.last { proxy.scrollTo(last.id, anchor: .bottom) }
                }
            }
            HStack {
                Button {
                    UIPasteboard.general.string = engine.logText()
                } label: {
                    Label("ចម្លង", systemImage: "doc.on.doc")
                }
                Spacer()
                Button(role: .destructive) {
                    engine.clearLog()
                } label: {
                    Label("សម្អាត", systemImage: "trash")
                }
            }
            .font(.subheadline)
        } header: {
            Text("Activity Log (\(engine.lines.count))")
        }
    }
}
