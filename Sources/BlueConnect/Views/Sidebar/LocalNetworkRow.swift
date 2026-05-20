import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct LocalNetworkRow: View {
    let service: LocalService
    @EnvironmentObject private var settings: SettingsStore
    @Environment(TailscaleBrowser.self) private var tailscale
    @Environment(TerminalSessionsManager.self) private var terminals
    @Environment(InstallController.self) private var installer
    @Environment(PackageCatalogStore.self) private var packageCatalog
    @Environment(PackagePickerController.self) private var packagePicker
    @Environment(MunkiRepoStore.self) private var munkiStore
    @EnvironmentObject private var quickActionStore: QuickActionStore
    @Environment(\.openWindow) private var openWindow
    @State private var hovered = false
    @State private var showingPortSheet = false
    @State private var showingScpPicker = false
    @State private var showingRunCommand = false
    @State private var showingLocalFilePicker = false
    @State private var quickActionPending: QuickAction?
    @State private var pendingCommand = ""

    var body: some View {
        // The row is a passive label — only the trailing SSH / VNC icons
        // (or the right-click menu) trigger a connection. This avoids the
        // accidental-SSH-on-row-click problem the user hit.
        HStack(spacing: 6) {
            Image(systemName: "macbook").foregroundStyle(.tint).frame(width: 16)
            VStack(alignment: .leading, spacing: 1) {
                Text(service.name).lineLimit(1)
                Text(service.displayHostname).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 4)
            if service.hasSSH {
                Button("SSH (Remote Shell)", systemImage: "terminal", action: connectSSH)
                    .labelStyle(.iconOnly)
                    .font(.caption2)
                    .foregroundStyle(.green)
                    .buttonStyle(.plain)
                    .help("SSH on port \(String(service.sshPort ?? 22))")
            }
            if service.hasVNC {
                Button("VNC (Screen Share)", systemImage: "display", action: connectVNC)
                    .labelStyle(.iconOnly)
                    .font(.caption2)
                    .foregroundStyle(.blue)
                    .buttonStyle(.plain)
                    .help("VNC on port \(String(service.vncPort ?? 5900))")
            }
        }
        .padding(.horizontal, 8).padding(.vertical, 5)
        .background(RoundedRectangle(cornerRadius: 6)
            .fill(hovered ? Color.accentColor.opacity(0.18) : Color.clear))
        .contentShape(Rectangle())
        .onHover { hovered = $0 }
        .contextMenu {
            // Connections — same SSH/VNC/SCP triad as the main host
            // context menu, just routed through the direct-connection
            // ConnectionService methods (no BSC ProxyCommand).
            if service.hasSSH {
                Button("SSH (Remote Shell)") { connectSSH() }
            }
            if service.hasVNC {
                Button("VNC (Screen Share)") { connectVNC() }
            }
            if service.hasSSH {
                Button("Send File via SCP…") {
                    Task { @MainActor in showingScpPicker = true }
                }
            }

            if service.hasSSH {
                Divider()
                Menu("Open in Terminal") {
                    Button("SSH (Terminal.app)") { openInTerminalSSH() }
                }
                Button("Run Shell Command…") {
                    Task { @MainActor in
                        pendingCommand = ""
                        showingRunCommand = true
                    }
                }
                Divider()
                // Install — mirrors the main host context menu but routes
                // through `installer.prepareDirect(…)` so SSH/scp goes
                // straight over the LAN with no BSC ProxyCommand.
                Menu("Install") {
                    Button("Local .pkg / .dmg…") {
                        Task { @MainActor in showingLocalFilePicker = true }
                    }
                    if let cat = packageCatalog.catalog, !cat.packages.isEmpty {
                        Button("From Repo Picker…") {
                            Task { @MainActor in openRepoPicker() }
                        }
                    } else if settings.isMunkiRepoConfigured {
                        Button("From Munki Repo…") {
                            Task { @MainActor in openRepoPicker() }
                        }
                    }
                }
                // Quick Actions — same enabled set as the BSC host menu;
                // free-form shell commands run via the direct transport.
                if !quickActionStore.allEnabled.grouped.isEmpty {
                    Menu("Quick Actions") {
                        ForEach(Array(quickActionStore.allEnabled.grouped.enumerated()),
                                id: \.offset) { entry in
                            Section(entry.element.0) {
                                ForEach(entry.element.1) { action in
                                    Button(action.label) {
                                        Task { @MainActor in
                                            quickActionPending = action
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
            }

            Divider()
            Button("Copy hostname") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(service.displayHostname, forType: .string)
            }
            if service.hasSSH {
                Button("Copy SSH Command") { copySSHCommand() }
            }

            if service.source == .tailscale {
                Divider()
                Button("Custom Connection…") { showingPortSheet = true }
                Button("Hide from sidebar") { hideFromSidebar() }
            }
        }
        .sheet(isPresented: $showingPortSheet) {
            TailscalePortSheet(peerName: service.name)
                .environmentObject(settings)
                .environment(tailscale)
        }
        .fileImporter(isPresented: $showingScpPicker, allowedContentTypes: [.item]) { result in
            if case .success(let url) = result { sendFileViaSCP(url) }
        }
        .sheet(isPresented: $showingRunCommand) { runCommandSheet }
        // Install Local .pkg / .dmg / .app — directly from the LAN, no BSC.
        .fileImporter(isPresented: $showingLocalFilePicker,
                      allowedContentTypes: [
                        UTType(filenameExtension: "pkg") ?? .data,
                        UTType(filenameExtension: "dmg") ?? .data,
                        .application,
                      ]) { result in
            if case .success(let url) = result { installLocalFile(url) }
        }
        // Quick Action sheet — reuses the existing field-driven sheet
        // (header now targets a generic name, not just BlueSkyHost).
        .sheet(item: $quickActionPending) { action in
            QuickActionSheet(targetName: service.name, action: action) { command in
                runRemoteCommand(command, label: action.tabLabel)
            }
        }
        // Observe pending repo-picker installs that targeted THIS row.
        // The picker only deals in BlueSkyHost-keyed targets via its
        // `.hosts` array; we tag local-network targets via the parallel
        // `.localTarget` field below and react to direct/munki/file
        // events when that field matches us.
        .onChange(of: packagePicker.pendingDirectInstall) { _, pkg in
            guard let pkg, packagePicker.localTarget?.id == service.id,
                  let cmd = packageCatalog.catalog?.remoteCommand(for: pkg) else { return }
            runRemoteCommand(cmd, label: "install: \(pkg.name)")
            packagePicker.pendingDirectInstall = nil
            packagePicker.localTarget = nil
        }
        .onChange(of: packagePicker.pendingFileDrop) { _, url in
            guard let url, packagePicker.localTarget?.id == service.id else { return }
            installLocalFile(url)
            packagePicker.pendingFileDrop = nil
            packagePicker.localTarget = nil
        }
        .onChange(of: packagePicker.pendingMunkiInstall) { _, pkg in
            guard let pkg, packagePicker.localTarget?.id == service.id else { return }
            installMunkiPackage(pkg)
            packagePicker.pendingMunkiInstall = nil
            packagePicker.localTarget = nil
        }
    }

    /// Inline sheet for the Run Shell Command… action. Kept here rather
    /// than its own file because it's a 30-line one-purpose form.
    private var runCommandSheet: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: "terminal").foregroundStyle(.green)
                Text("Run command on \(service.name)").font(.headline)
            }
            Text("Runs via direct SSH to \(service.displayHostname) as \(resolvedRemoteUser).")
                .font(.caption).foregroundStyle(.secondary)
            TextField("", text: $pendingCommand,
                      prompt: Text("e.g. uptime, sw_vers, sudo killall Finder"))
                .textFieldStyle(.roundedBorder)
                .font(.body.monospaced())
            HStack {
                Spacer()
                Button("Cancel") { showingRunCommand = false }
                    .keyboardShortcut(.cancelAction)
                Button("Run") {
                    showingRunCommand = false
                    runRemoteCommand(pendingCommand)
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(pendingCommand.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(16)
        .frame(width: 460)
    }

    private func hideFromSidebar() {
        var current = settings.hiddenTailscalePeers
        current.insert(service.name)
        settings.hiddenTailscalePeers = current
    }

    /// Resolved remote user for this row. Tailscale peers consult the
    /// per-peer override → tailscaleDefaultUser → defaultRemoteUser
    /// chain; everything else uses the global default directly.
    private var resolvedRemoteUser: String {
        service.source == .tailscale
            ? settings.tailscaleUser(for: service.name)
            : settings.defaultRemoteUser
    }

    private func connectSSH() {
        guard let port = service.sshPort else {
            if service.hasVNC { connectVNC() }
            return
        }
        let svc = ConnectionService(
            server: settings.serverFqdn,
            adminKeyPath: settings.expandedKeyPath,
            serverSshPort: settings.sshTunnelPort,
            terminals: terminals
        )
        svc.openDirectSSH(hostname: service.hostname,
                          port: port,
                          remoteUser: resolvedRemoteUser)
    }

    private func connectVNC() {
        guard let port = service.vncPort else { return }
        let svc = ConnectionService(
            server: settings.serverFqdn,
            adminKeyPath: settings.expandedKeyPath,
            serverSshPort: settings.sshTunnelPort,
            terminals: terminals
        )
        svc.openDirectVNC(hostname: service.hostname,
                          port: port,
                          remoteUser: resolvedRemoteUser)
    }

    private func openInTerminalSSH() {
        guard let port = service.sshPort else { return }
        let svc = ConnectionService(
            server: settings.serverFqdn,
            adminKeyPath: settings.expandedKeyPath,
            serverSshPort: settings.sshTunnelPort,
            terminals: terminals
        )
        svc.openDirectSSHInTerminal(hostname: service.hostname,
                                    port: port,
                                    remoteUser: resolvedRemoteUser)
    }

    private func sendFileViaSCP(_ url: URL) {
        guard let port = service.sshPort else { return }
        let svc = ConnectionService(
            server: settings.serverFqdn,
            adminKeyPath: settings.expandedKeyPath,
            serverSshPort: settings.sshTunnelPort,
            terminals: terminals
        )
        svc.openDirectSCP(hostname: service.hostname,
                          port: port,
                          remoteUser: resolvedRemoteUser,
                          sourceURL: url)
    }

    private func runRemoteCommand(_ command: String) {
        // First 24 chars of the command, for the tab title.
        let cmd = command.trimmingCharacters(in: .whitespacesAndNewlines)
        let label = String(cmd.prefix(24)) + (cmd.count > 24 ? "…" : "")
        runRemoteCommand(command, label: label)
    }

    /// Shared underneath both the "Run Shell Command…" and Quick Actions
    /// paths. Quick Actions pass their own `tabLabel`.
    private func runRemoteCommand(_ command: String, label: String) {
        guard let port = service.sshPort else { return }
        let cmd = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cmd.isEmpty else { return }
        let svc = ConnectionService(
            server: settings.serverFqdn,
            adminKeyPath: settings.expandedKeyPath,
            serverSshPort: settings.sshTunnelPort,
            terminals: terminals
        )
        svc.openDirectRemoteCommand(hostname: service.hostname,
                                    port: port,
                                    remoteUser: resolvedRemoteUser,
                                    command: cmd,
                                    label: label)
    }

    private func installLocalFile(_ url: URL) {
        guard let port = service.sshPort else { return }
        let target = InstallController.DirectTarget(
            hostname: service.hostname,
            port: port,
            remoteUser: resolvedRemoteUser,
            displayName: service.name
        )
        let ext = url.pathExtension.lowercased()
        let appMode: InstallController.AppMode = ext == "app" ? .compress : .compress
        installer.prepareDirect(target: target, localFile: url, appMode: appMode)
        openWindow(id: "install-progress")
    }

    private func openRepoPicker() {
        guard service.hasSSH else { return }
        // Empty BSC hosts list + localTarget set tells the picker (and
        // ContentView/LocalNetworkRow's onChange observers) to route the
        // pick through the direct-install path on this row.
        packagePicker.present(hosts: [])
        packagePicker.localTarget = service
        openWindow(id: "package-picker")
    }

    /// Copy a ready-to-paste `ssh user@host -p port` form (uses the
    /// dot-stripped hostname so paste targets stay clean).
    private func copySSHCommand() {
        guard let port = service.sshPort else { return }
        let cmd = "ssh -p \(port) \(resolvedRemoteUser)@\(service.displayHostname)"
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(cmd, forType: .string)
    }

    /// Munki install via the direct (LAN) transport. Mirrors
    /// ContentView.installMunkiPackage but uses `prepareMunkiPendingDirect`
    /// so SSH/scp reaches the host directly with no BSC ProxyCommand.
    private func installMunkiPackage(_ pkg: MunkiPkg) {
        guard let port = service.sshPort else { return }
        guard let loc = pkg.installerItemLocation, !loc.isEmpty else { return }
        let ext = (loc as NSString).pathExtension.isEmpty
            ? "pkg" : (loc as NSString).pathExtension
        let fileName = (loc as NSString).lastPathComponent
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("bcadmin-munki-\(UUID().uuidString).\(ext)")
        let store = munkiStore
        let settingsRef = settings
        let target = InstallController.DirectTarget(
            hostname: service.hostname,
            port: port,
            remoteUser: resolvedRemoteUser,
            displayName: service.name
        )
        installer.prepareMunkiPendingDirect(target: target,
                                            expectedFileName: fileName) {
            try await store.fetch(key: "pkgs/\(loc)", to: tmp, settings: settingsRef)
            return tmp
        }
        openWindow(id: "install-progress")
    }
}
