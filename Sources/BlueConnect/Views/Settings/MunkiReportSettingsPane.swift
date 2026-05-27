import SwiftUI

/// Settings → MunkiReport. Server URL, API token (Keychain-backed),
/// API path, Test Connection button, and the drag-to-reorder list of
/// inventory sections with per-section visibility toggles.
///
/// Extracted from `SettingsView.swift` as part of the v1.4 SwiftUI
/// cleanup — SettingsView was 874 lines; pulling the two biggest
/// panes (this one + MunkiRepoSettingsPane) into separate files
/// drops it under 600 and matches the existing pattern from
/// `QuickActionsSettingsPane` / `UniFiSettingsPane`.
struct MunkiReportSettingsPane: View {
    @EnvironmentObject private var settings: SettingsStore

    @State private var testRunning: Bool = false
    @State private var testResult: TestResult? = nil

    private enum TestResult: Equatable {
        case success
        case failure(String)
    }

    var body: some View {
        Form {
            TextField("MunkiReport server URL",
                      text: $settings.munkiReportURL,
                      prompt: Text(verbatim: "https://munkireport.example.com"))
                .help("Root URL of your MunkiReport server (no trailing slash). Used both for the per-host browser link and as the base for the blueconnect_api.php JSON endpoint.")
            SecureField("API token", text: $settings.munkiReportAPIToken)
                .onChange(of: settings.munkiReportAPIToken) { _, _ in
                    settings.saveMunkiReportTokenToKeychain()
                    testResult = nil
                }
                .help("Bearer token for blueconnect_api.php. Must match the BLUECONNECT_API_TOKEN env var on the MR container.")
            TextField("API path",
                      text: $settings.munkiReportAPIPath,
                      prompt: Text(verbatim: "blueconnect_api.php"))
                .onChange(of: settings.munkiReportAPIPath) { _, _ in testResult = nil }
                .help("Path appended to the server URL to reach the PHP endpoint. Default works when the file is at the MR webroot. Use `custom/blueconnect_api.php` when the file lives under MR's bind-mounted custom/ directory.")

            VStack(alignment: .leading, spacing: 6) {
                Text("How to set up the API")
                    .font(.caption).bold().foregroundStyle(.secondary)
                Text("""
                    1. Copy server/munkireport-module/blueconnect_api.php from this project into the MR container's public/ directory.
                    2. Add BLUECONNECT_API_TOKEN=<random 32+ chars> to the MR container's env file and restart it.
                    3. Paste the same token into the field above. Click Test Connection.
                    """)
                    .font(.caption2).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                Button {
                    Task { await runTest() }
                } label: {
                    if testRunning {
                        ProgressView().controlSize(.small)
                    } else {
                        Label("Test Connection", systemImage: "antenna.radiowaves.left.and.right")
                    }
                }
                .disabled(!settings.isMunkiReportAPIConfigured || testRunning)
                Spacer()
            }

            if let result = testResult {
                switch result {
                case .success:
                    HStack(spacing: 6) {
                        Image(systemName: "checkmark.seal.fill").foregroundStyle(.green)
                        Text("API reachable — token accepted, DB query succeeded.")
                            .font(.caption)
                    }
                case .failure(let msg):
                    HStack(alignment: .top, spacing: 6) {
                        Image(systemName: "xmark.octagon.fill").foregroundStyle(.red)
                        Text(msg).font(.caption.monospaced())
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }

            Text("Without the API token, this section is link-out only: right-click a host → Software Inventory → Open in MunkiReport launches the browser.")
                .font(.caption2).foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)

            Divider()

            sectionOrderEditor
        }
        .formStyle(.grouped)
    }

    /// Drag-to-reorder list of MunkiReport inventory sections plus a
    /// per-section visibility toggle. State lives in `SettingsStore`
    /// (`munkiReportSectionOrder` + `munkiReportHiddenSections`); the
    /// inventory pane iterates this order on every render.
    @ViewBuilder
    private var sectionOrderEditor: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Inventory section order")
                .font(.caption).bold().foregroundStyle(.secondary)
            Text("Drag to reorder. Toggle off any section you don't want shown in the right-pane Inventory tab or the standalone MunkiReport sheet.")
                .font(.caption2).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            // SwiftUI Form's grouped style on macOS doesn't supply an
            // edit button; List + .onMove on a ForEach is enough to
            // get drag handles on each row.
            List {
                ForEach(settings.munkiReportSectionOrder, id: \.self) { s in
                    HStack {
                        Image(systemName: s.systemImage)
                            .foregroundStyle(.tint)
                            .frame(width: 18)
                        Text(s.label)
                        Spacer()
                        Toggle("", isOn: Binding(
                            get: { settings.munkiReportSectionIsVisible(s) },
                            set: { newVal in
                                var hidden = settings.munkiReportHiddenSections
                                if newVal { hidden.remove(s) } else { hidden.insert(s) }
                                settings.munkiReportHiddenSections = hidden
                            }
                        ))
                        .labelsHidden()
                        .controlSize(.small)
                    }
                }
                .onMove { source, destination in
                    var order = settings.munkiReportSectionOrder
                    order.move(fromOffsets: source, toOffset: destination)
                    settings.munkiReportSectionOrder = order
                }
            }
            .frame(minHeight: 280, maxHeight: 360)
            .scrollContentBackground(.hidden)

            Button("Reset to default order") {
                settings.munkiReportSectionOrder = MRSection.defaultOrder
                settings.munkiReportHiddenSections = []
            }
            .controlSize(.small)
        }
    }

    @MainActor
    private func runTest() async {
        testRunning = true
        defer { testRunning = false }
        let client = MunkiReportClient()
        do {
            try await client.ping(settings: settings)
            testResult = .success
        } catch {
            testResult = .failure(error.localizedDescription)
        }
    }
}
