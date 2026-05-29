import SwiftUI
import AppKit

/// Per-host MunkiReport inventory sheet. Fetches `blueconnect_api.php`
/// for the given serial and renders the sections that came back —
/// missing modules just don't appear. Designed to be opened from the
/// host context menu → Software Inventory → "MunkiReport Stats…".
struct MunkiReportInventoryView: View {
    let host: BlueSkyHost

    @EnvironmentObject private var settings: SettingsStore
    @Environment(\.dismiss) private var dismiss
    @State private var client = MunkiReportClient()
    @State private var inventory: MRHostInventory?
    @State private var errorMessage: String?
    @State private var isLoading: Bool = false
    @State private var showingRunnerSheet: Bool = false

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
            Divider()
            footer
        }
        .frame(width: 620, height: 540)
        .task { await load() }
        .sheet(isPresented: $showingRunnerSheet) {
            MunkiReportRunnerSheet(host: host)
                .environmentObject(settings)
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "chart.bar.doc.horizontal.fill")
                .font(.title3).foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 1) {
                Text("MunkiReport Inventory").font(.headline)
                Text("\(host.displayName) · \(host.serialnum ?? "(no serial)")")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if isLoading { ProgressView().controlSize(.small) }
            if let serial = host.serialnum,
               let url = settings.munkiReportDetailURL(serial: serial) {
                Button {
                    NSWorkspace.shared.open(url)
                } label: {
                    Label("Open in MunkiReport", systemImage: "arrow.up.right.square")
                }
                .help("Open this host's dashboard in MunkiReport (browser)")
            }
            // "Run Runner" — opens MunkiReportRunnerSheet to SSH into
            // the host and invoke munkireport-runner. Disabled when
            // we can't reach the host (no serial == not deployed) or
            // it's currently being SSH'd by another sheet instance.
            Button {
                showingRunnerSheet = true
            } label: {
                Label("Run Runner", systemImage: "play.rectangle")
            }
            .help("SSH to this host and run /usr/local/munkireport/munkireport-runner so a fresh check-in happens now")
            .disabled(host.serialnum?.isEmpty ?? true)
            Button {
                Task { await load() }
            } label: {
                Label("Refresh", systemImage: "arrow.clockwise")
            }
            .disabled(isLoading)
        }
        .padding(.horizontal, 16).padding(.vertical, 12)
    }

    @ViewBuilder
    private var content: some View {
        if let err = errorMessage {
            VStack(spacing: 10) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.largeTitle).foregroundStyle(.orange)
                Text(err)
                    .font(.callout)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 40)
                    .textSelection(.enabled)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let inv = inventory {
            ScrollView {
                MunkiReportInventoryContent(inventory: inv, compact: false)
                    .padding(16)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        } else {
            // First-load placeholder — task hasn't completed yet.
            VStack { Spacer(); Text("Loading…").foregroundStyle(.secondary); Spacer() }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var footer: some View {
        HStack {
            if let inv = inventory, inv.reportdata?.lastCheckInDate == nil {
                Text("Host hasn't reported to MunkiReport yet — most sections will be empty.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Button("Close") { dismiss() }
                .keyboardShortcut(.cancelAction)
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
    }

    // MARK: - Load

    private func load() async {
        guard let serial = host.serialnum, !serial.isEmpty else {
            errorMessage = "This host has no serial number — MunkiReport keys on serial, so there's nothing to query."
            return
        }
        guard settings.isMunkiReportAPIConfigured else {
            errorMessage = "Set Settings → MunkiReport → server URL + API token, then drop server/munkireport-module/blueconnect_api.php into MR's public/ dir and set the matching BLUECONNECT_API_TOKEN env var on the container."
            return
        }
        isLoading = true
        defer { isLoading = false }
        errorMessage = nil
        do {
            inventory = try await client.fetchHost(serial: serial, settings: settings)
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
