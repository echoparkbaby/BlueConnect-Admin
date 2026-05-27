import SwiftUI

/// Sheet that lists every serial currently in BlueSky.blocked_serials
/// with an Unblock button per row. Reached from the main window's
/// overflow menu → "Blocked Hosts…".
///
/// Unblock posts to bs_host_action.json.php with action=unblock. The
/// host will reappear in the regular host list on its next agent
/// reconnect (typically within a minute or two for an active client).
struct BlockedHostsView: View {
    @EnvironmentObject private var settings: SettingsStore
    @EnvironmentObject private var auth: AuthGate
    @Environment(\.dismiss) private var dismiss

    @State private var items: [BlockedSerial] = []
    @State private var loading: Bool = false
    @State private var errorMessage: String?
    @State private var unblockingSerial: String?

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
            Divider()
            footer
        }
        .frame(width: 560, height: 460)
        .task { await load() }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "hand.raised.fill")
                .font(.title3).foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 1) {
                Text("Blocked Hosts").font(.headline)
                Text("Serials in BlueSky.blocked_serials — DB trigger refuses any registration with these.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if loading { ProgressView().controlSize(.small) }
            Button {
                Task { await load() }
            } label: {
                Label("Refresh", systemImage: "arrow.clockwise")
            }
            .disabled(loading)
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
        } else if items.isEmpty {
            VStack(spacing: 8) {
                Image(systemName: "checkmark.shield")
                    .font(.largeTitle).foregroundStyle(.green)
                Text("No hosts blocked")
                    .font(.headline).foregroundStyle(.secondary)
                Text("Block a host via right-click → Danger Zone → Block Host Permanently.")
                    .font(.caption).foregroundStyle(.tertiary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            List {
                ForEach(items) { row in
                    HStack(alignment: .top, spacing: 10) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(row.serial)
                                .font(.callout.monospaced())
                                .textSelection(.enabled)
                            HStack(spacing: 8) {
                                if let bid = row.blueskyid_at_block {
                                    Text("#\(bid)")
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }
                                if let d = row.addedDate {
                                    Text("blocked \(d.formatted(.relative(presentation: .named)))")
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                } else if let s = row.added_at {
                                    Text(s).font(.caption2).foregroundStyle(.secondary)
                                }
                            }
                            if let n = row.note, !n.isEmpty {
                                Text(n).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        Spacer()
                        if unblockingSerial == row.serial {
                            ProgressView().controlSize(.small)
                        } else {
                            Button("Unblock") { unblock(row) }
                                .buttonStyle(.bordered)
                        }
                    }
                    .padding(.vertical, 4)
                }
            }
            .listStyle(.inset)
        }
    }

    private var footer: some View {
        HStack {
            if !items.isEmpty {
                Text("\(items.count) blocked")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Button("Close") { dismiss() }
                .keyboardShortcut(.cancelAction)
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
    }

    // MARK: - Load + Unblock

    private func load() async {
        loading = true
        defer { loading = false }
        errorMessage = nil
        do {
            items = try await BlueSkyAPI.shared.fetchBlockedSerials(
                apiURL: settings.apiURL,
                username: settings.apiUsername,
                password: settings.webAdminPass
            )
        } catch {
            errorMessage = (error as? APIError)?.errorDescription ?? error.localizedDescription
        }
    }

    private func unblock(_ row: BlockedSerial) {
        Task {
            guard await auth.confirmDestructive(reason: "unblock serial \(row.serial)") else { return }
            unblockingSerial = row.serial
            defer { unblockingSerial = nil }
            do {
                _ = try await BlueSkyAPI.shared.unblockSerial(
                    row.serial,
                    apiURL: settings.apiURL,
                    username: settings.apiUsername,
                    password: settings.webAdminPass
                )
                // Drop from local list immediately so the user sees
                // feedback even if reload races.
                items.removeAll { $0.serial == row.serial }
                await load()
            } catch {
                errorMessage = (error as? APIError)?.errorDescription ?? error.localizedDescription
            }
        }
    }
}
