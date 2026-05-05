import SwiftUI

struct ConnectPanel: View {
    @EnvironmentObject var settings: SettingsStore
    @Environment(CategoryStore.self) var categories
    @Environment(TerminalSessionsManager.self) var terminals
    let hosts: [BlueSkyHost]
    let onSCPNeedsFile: (BlueSkyHost) -> Void
    let onVNCRequest: (BlueSkyHost, String) -> Void
    let onDeleteRequest: (BlueSkyHost, HostAction) -> Void
    let onBulkRequest: ([BlueSkyHost], HostAction) -> Void
    let onRenameRequest: (BlueSkyHost) -> Void
    let onCategoryRequest: ([BlueSkyHost]) -> Void
    let onConnect: (BlueSkyHost) -> Void
    let onSaveNotes: (BlueSkyHost, String) -> Void
    let onUpdateField: (BlueSkyHost, String, Any) -> Void

    @State private var remoteUser: String = ""
    @State private var notes: String = ""
    @State private var notesDirty: Bool = false
    @State private var notesHostId: Int = -1

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                switch hosts.count {
                case 0:
                    placeholder
                case 1:
                    singleHostBody(host: hosts[0])
                default:
                    bulkBody
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(16)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    // MARK: - Single host

    private func singleHostBody(host: BlueSkyHost) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            hostHeader(host)
            categoryRow(host)
            Divider()
            detailsBlock(host)
            Divider()
            userField(host)
            actionButtons(host)
            if !host.active { inactiveWarning }
            Divider()
            alertsBlock(host)
            Divider()
            notesBlock(host)
            Divider()
            dangerZone(host)
            Spacer(minLength: 0)
        }
    }

    @State private var notifyEmail: String = ""
    @State private var notifyEmailDirty: Bool = false
    @State private var notifyEmailHostId: Int = -1

    private func alertsBlock(_ host: BlueSkyHost) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Alerts").font(.caption).foregroundStyle(.secondary)
            Toggle("Notify on status change", isOn: Binding(
                get: { host.notify ?? false },
                set: { onUpdateField(host, "notify", $0) }
            ))
            .toggleStyle(.checkbox)
            Toggle("Send alert if offline", isOn: Binding(
                get: { host.alert ?? false },
                set: { onUpdateField(host, "alert", $0) }
            ))
            .toggleStyle(.checkbox)
            HStack(spacing: 4) {
                TextField("Email address (alerts go here)", text: $notifyEmail)
                    .textFieldStyle(.roundedBorder)
                    .onAppear { syncEmail(host: host) }
                    .onChange(of: host.id) { _, _ in syncEmail(host: host) }
                    .onChange(of: notifyEmail) { _, newValue in
                        if notifyEmailHostId == host.id {
                            notifyEmailDirty = newValue != (host.email ?? "")
                        }
                    }
                if notifyEmailDirty {
                    Button("Save") {
                        onUpdateField(host, "email", notifyEmail)
                        notifyEmailDirty = false
                    }
                    .buttonStyle(.borderless)
                    .font(.caption)
                }
            }
        }
    }

    private func syncEmail(host: BlueSkyHost) {
        notifyEmail = host.email ?? ""
        notifyEmailDirty = false
        notifyEmailHostId = host.id
    }

    private func notesBlock(_ host: BlueSkyHost) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("Notes").font(.caption).foregroundStyle(.secondary)
                Spacer()
                if notesDirty {
                    Button("Save") { onSaveNotes(host, notes); notesDirty = false }
                        .buttonStyle(.borderless)
                        .font(.caption)
                        .keyboardShortcut("s")
                }
            }
            TextEditor(text: $notes)
                .font(.callout)
                .frame(minHeight: 70, maxHeight: 120)
                .scrollContentBackground(.hidden)
                .padding(6)
                .background(Color(NSColor.textBackgroundColor))
                .clipShape(.rect(cornerRadius: 6))
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(Color(NSColor.separatorColor), lineWidth: 0.5)
                )
                .onAppear { syncNotes(host: host) }
                .onChange(of: host.id) { syncNotes(host: host) }
                .onChange(of: notes) { _, newValue in
                    if notesHostId == host.id {
                        notesDirty = newValue != (host.notes ?? "")
                    }
                }
        }
    }

    private func syncNotes(host: BlueSkyHost) {
        notes = host.notes ?? ""
        notesDirty = false
        notesHostId = host.id
    }

    private func hostHeader(_ host: BlueSkyHost) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Image(systemName: host.active ? "circle.fill" : "circle")
                .foregroundStyle(host.active ? .green : .secondary)
            Text(host.displayName).font(.title3).bold().lineLimit(1)
            Spacer()
            Text("#\(host.blueskyid)").foregroundStyle(.secondary)
        }
    }

    private func categoryRow(_ host: BlueSkyHost) -> some View {
        HStack(spacing: 8) {
            if let cat = categories.category(for: host) {
                Text(cat)
                    .font(.caption)
                    .padding(.horizontal, 8).padding(.vertical, 2)
                    .background(Color.accentColor.opacity(0.18))
                    .foregroundStyle(.tint)
                    .clipShape(Capsule())
            }
            Button {
                onCategoryRequest([host])
            } label: {
                Label(categories.category(for: host) == nil ? "Add category" : "Change", systemImage: "tag")
                    .font(.caption)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.tint)
            Spacer()
            Button {
                onRenameRequest(host)
            } label: {
                Label("Rename", systemImage: "pencil").font(.caption)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.tint)
        }
    }

    private func detailsBlock(_ host: BlueSkyHost) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            kv("SSH Port", "\(host.sshPort)")
            kv("VNC Port", "\(host.vncPort)")
            kv("Serial", host.serialnum?.nilIfEmpty() ?? "—")
            kv("DB User", host.username?.nilIfEmpty() ?? "—")
            kv("Sharing", host.sharingname?.nilIfEmpty() ?? "—")
            kv("Status", host.status?.nilIfEmpty() ?? "—")
            kv("Last Seen", host.lastSeen?.nilIfEmpty() ?? "—")
        }
        .font(.callout)
    }

    private func kv(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label).foregroundStyle(.secondary).frame(width: 80, alignment: .leading)
            Text(value).textSelection(.enabled)
            Spacer()
        }
    }

    private func userField(_ host: BlueSkyHost) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Remote user").font(.caption).foregroundStyle(.secondary)
            TextField("ladmin", text: $remoteUser)
                .textFieldStyle(.roundedBorder)
                .onAppear { syncUser(host: host) }
                .onChange(of: host.id) { syncUser(host: host) }
        }
    }

    private func syncUser(host: BlueSkyHost) {
        remoteUser = host.effectiveUser(default: settings.defaultRemoteUser)
    }

    private func actionButtons(_ host: BlueSkyHost) -> some View {
        var svc = ConnectionService(
            server: settings.serverFqdn,
            adminKeyPath: settings.expandedKeyPath,
            serverSshPort: settings.sshTunnelPort,
            terminals: terminals
        )
        svc.onConnect = onConnect
        let user = remoteUser.isEmpty ? settings.defaultRemoteUser : remoteUser

        return VStack(spacing: 8) {
            Button {
                svc.openSSH(host: host, remoteUser: user)
            } label: {
                Label("Remote Shell (SSH)", systemImage: "terminal").frame(maxWidth: .infinity)
            }
            .controlSize(.large)
            .disabled(!host.active)
            .keyboardShortcut("1")

            Button {
                onVNCRequest(host, user)
            } label: {
                Label("Screen Share (VNC)", systemImage: "display").frame(maxWidth: .infinity)
            }
            .controlSize(.large)
            .disabled(!host.active)
            .keyboardShortcut("2")

            Button {
                onSCPNeedsFile(host)
            } label: {
                Label("File Upload (SCP)", systemImage: "doc.badge.arrow.up").frame(maxWidth: .infinity)
            }
            .controlSize(.large)
            .disabled(!host.active)
            .keyboardShortcut("3")
        }
    }

    private func dangerZone(_ host: BlueSkyHost) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Danger zone").font(.caption).foregroundStyle(.secondary)
            Menu {
                Button("Send Delete Command (selfdestruct)") {
                    onDeleteRequest(host, .selfdestruct)
                }
                Divider()
                Button("Delete from Database…", role: .destructive) {
                    onDeleteRequest(host, .delete)
                }
            } label: {
                Label("Remove…", systemImage: "trash").frame(maxWidth: .infinity)
            }
            .menuStyle(.borderlessButton)
            .controlSize(.regular)
        }
    }

    private var inactiveWarning: some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: "exclamationmark.triangle").foregroundStyle(.orange)
            Text("This client isn't currently tunneled. Connections will fail until it reconnects.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    // MARK: - Bulk

    private var bulkBody: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Image(systemName: "square.stack.3d.up").foregroundStyle(.tint)
                Text("\(hosts.count) hosts selected").font(.title3).bold()
            }
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(hosts) { h in
                        HStack(spacing: 6) {
                            Image(systemName: h.active ? "circle.fill" : "circle")
                                .foregroundStyle(h.active ? .green : .secondary)
                                .font(.caption2)
                            Text("#\(h.blueskyid)").foregroundStyle(.secondary)
                            Text(h.displayName).lineLimit(1)
                            if let cat = categories.category(for: h) {
                                Spacer()
                                Text(cat).font(.caption2)
                                    .padding(.horizontal, 5).padding(.vertical, 1)
                                    .background(Color.accentColor.opacity(0.18))
                                    .foregroundStyle(.tint)
                                    .clipShape(Capsule())
                            }
                        }
                        .font(.callout)
                    }
                }
            }
            .frame(maxHeight: 220)
            Divider()
            Text("Bulk actions").font(.caption).foregroundStyle(.secondary)
            Button {
                onCategoryRequest(hosts)
            } label: {
                Label("Set Category for All", systemImage: "tag").frame(maxWidth: .infinity)
            }
            .controlSize(.large)
            Button {
                onBulkRequest(hosts, .selfdestruct)
            } label: {
                Label("Send Delete Command", systemImage: "paperplane").frame(maxWidth: .infinity)
            }
            .controlSize(.large)
            Button(role: .destructive) {
                onBulkRequest(hosts, .delete)
            } label: {
                Label("Delete All from Database…", systemImage: "trash").frame(maxWidth: .infinity)
            }
            .controlSize(.large)
            Spacer()
        }
    }

    // MARK: - Empty

    private var placeholder: some View {
        VStack(spacing: 10) {
            Image(systemName: "list.bullet.rectangle.portrait")
                .font(.system(size: 40)).foregroundStyle(.secondary)
            Text("Select a host").font(.headline)
            Text("Pick a row on the left to connect, or ⌘-click multiple rows for bulk actions.")
                .font(.caption).multilineTextAlignment(.center).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private extension String {
    func nilIfEmpty() -> String? { isEmpty ? nil : self }
}
