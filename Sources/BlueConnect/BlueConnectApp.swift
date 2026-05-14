import SwiftUI
import AppKit

@main
struct BlueConnectAdminApp: App {
    // SettingsStore + AuthGate stay as ObservableObject because they use
    // @AppStorage internally — @Observable + @AppStorage is a known trap.
    @StateObject private var settings = SettingsStore()
    @StateObject private var auth = AuthGate()
    // Migrated to @Observable; owned via @State.
    @State private var hosts = BlueSkyHostListStore()
    @State private var categories = CategoryStore()
    @State private var recents = RecentConnectStore()
    @State private var activity = ActivityLog()
    @State private var terminals = TerminalSessionsManager()
    @State private var notifier = HostStateNotifier()
    @State private var idleLock = IdleLockMonitor()
    @State private var rendezvous = LocalRendezvousBrowser()
    @State private var tailscale = TailscaleBrowser()
    @State private var scp = SCPController()
    @State private var packageCatalog = PackageCatalogStore()
    @State private var installer = InstallController()
    @State private var packagePicker = PackagePickerController()
    @State private var mrInventory = MunkiReportInventoryStore()

    var body: some Scene {
        WindowGroup("BlueConnect Admin") {
            RootSceneView()
            .environmentObject(settings)
            .environmentObject(auth)
            .environment(hosts)
            .environment(categories)
            .environment(recents)
            .environment(activity)
            .environment(terminals)
            .environment(notifier)
            .environment(rendezvous)
            .environment(tailscale)
            .environment(scp)
            .environment(packageCatalog)
            .environment(installer)
            .environment(packagePicker)
            .environment(mrInventory)
            .task {
                Log.info("App", "BlueConnect Admin starting")
                auth.bootstrap(settings: settings)
                idleLock.start(auth: auth, settings: settings)
                settings.loadRepoPasswordsFromKeychain()
                settings.loadMunkiSecretFromKeychain()
                settings.loadMunkiReportTokenFromKeychain()
                if settings.localNetworkEnabled { rendezvous.start() }
                tailscale.settings = settings
                if settings.tailscaleEnabled { tailscale.start() }
                MainWindowGuard.shared.install(terminals: terminals)
                if !settings.packageCatalogURL.isEmpty {
                    await packageCatalog.refresh(urlString: settings.packageCatalogURL)
                }
            }
            .onChange(of: settings.localNetworkEnabled) { _, enabled in
                if enabled { rendezvous.start() } else { rendezvous.stop() }
            }
            .onChange(of: settings.tailscaleEnabled) { _, enabled in
                if enabled { tailscale.start() } else { tailscale.stop() }
            }
        }
        .commands {
            CommandGroup(replacing: .newItem) { }
            CommandGroup(replacing: .appInfo) {
                Button("About BlueConnect Admin") {
                    let info = Bundle.main.infoDictionary
                    let appVer = info?["CFBundleShortVersionString"] as? String ?? "0.0.0"
                    let build = info?["CFBundleVersion"] as? String ?? "0"
                    let bsVer = hosts.lastResponse?.blueSkyVersion?.nilIfEmpty() ?? "—"
                    let phpVer = hosts.lastResponse?.phpVersion ?? "—"
                    let credits = NSAttributedString(
                        string: """
                        — Connected server —
                        Host: \(settings.serverFqdn.isEmpty ? "—" : settings.serverFqdn)
                        BlueSky version: \(bsVer)
                        PHP: \(phpVer)

                        Based on BlueSkyConnect by sphen.
                        """,
                        attributes: [.foregroundColor: NSColor.labelColor]
                    )
                    NSApplication.shared.orderFrontStandardAboutPanel(options: [
                        .applicationName: "BlueConnect Admin",
                        .applicationVersion: "App \(appVer)",
                        .version: "Build \(build)",
                        .credits: credits,
                    ])
                }
            }
            CommandMenu("Security") {
                Button("Lock Now") { auth.lock() }
                    .keyboardShortcut("L", modifiers: [.command, .shift])
                    .disabled(!auth.requireTouchID)
            }
            CommandMenu("View") {
                Button("Show Log") { terminals.activeSelection = .log }
                    .keyboardShortcut("\\", modifiers: [.command])
            }
            ConnectCommands()
            CommandMenu("Terminal") {
                Button("Previous Tab") { terminals.selectPrevious() }
                    .keyboardShortcut("[", modifiers: [.command, .shift])
                    .disabled(terminals.sessions.count < 2)
                Button("Next Tab") { terminals.selectNext() }
                    .keyboardShortcut("]", modifiers: [.command, .shift])
                    .disabled(terminals.sessions.count < 2)
                Divider()
                // ⌘W is intercepted globally by `MainWindowGuard` (NSEvent
                // local monitor) — see installation in `.task` below. The
                // monitor swallows ⌘W on the main window unconditionally,
                // closing the active tab if one is open. Auxiliary windows
                // (Settings, Send File) keep their default ⌘W = close.
                // The menu item below is for discoverability only and has
                // no shortcut, since the monitor handles it.
                Button("Close Tab") {
                    if let id = terminals.activeSessionID { terminals.close(id) }
                }
                Button("Close All Tabs") { terminals.closeAll() }
                    .keyboardShortcut("w", modifiers: [.command, .shift])
                    .disabled(terminals.sessions.isEmpty)
            }
        }
        Settings {
            SettingsView()
                .environmentObject(settings)
                .environmentObject(auth)
                .environment(hosts)
                .environment(packageCatalog)
                .environment(packagePicker)
                .environment(mrInventory)
        }

        // Standalone, draggable, non-modal window for SCP file transfers.
        // Opened via @Environment(\.openWindow) when ContentView fires off
        // a new transfer (drop on row, SCP icon click, or ⌘3).
        Window("Send File", id: "scp-transfer") {
            SCPWindowView()
                .environmentObject(settings)
                .environment(scp)
        }
        .windowResizability(.contentSize)
        .defaultPosition(.center)

        // Pop-out terminal windows. Opened via openWindow(id:value:) when
        // the user clicks Detach on a tab; closes when they click Re-attach
        // (or via the red traffic light, which auto-reattaches).
        WindowGroup("Terminal", id: "detached-terminal", for: UUID.self) { $sessionID in
            if let id = sessionID {
                DetachedTerminalView(sessionID: id)
                    .environment(terminals)
            }
        }
        .defaultSize(width: 800, height: 480)

        // Ad-hoc package install window — replaces the previous "spew
        // output into a terminal tab" install flow. Driven by InstallController.
        Window("Install Package", id: "install-progress") {
            InstallProgressWindow()
                .environmentObject(settings)
                .environment(installer)
        }
        .windowResizability(.contentSize)
        .defaultPosition(.center)

        // The package picker — was previously a `.sheet` glued to the
        // main window. Now a standalone resizable + movable window so the
        // user can park it next to the host list while picking installs.
        Window("Install Package…", id: "package-picker") {
            PackagePickerWindow()
                .environmentObject(settings)
                .environment(packageCatalog)
                .environment(packagePicker)
        }
        .windowResizability(.contentSize)
        .defaultPosition(.center)

        MenuBarExtra {
            MenuBarContent()
                .environmentObject(settings)
                .environment(hosts)
                .environment(recents)
                .environment(categories)
                .environment(terminals)
        } label: {
            Image(systemName: hosts.lastError != nil ? "globe.badge.chevron.backward" : "globe")
                .foregroundStyle(hosts.lastError != nil ? Color.red : Color.primary)
        }
        .menuBarExtraStyle(.window)
    }
}

private struct RootSceneView: View {
    @EnvironmentObject private var auth: AuthGate

    @State private var window: NSWindow?
    // Persist the full frame (origin + size) so the window comes back where
    // the user left it. Old size-only keys (`unlockedWindowWidth/Height`) are
    // ignored now — superseded by `unlockedWindowFrame`.
    @AppStorage("unlockedWindowFrame") private var savedFrameString: String = ""

    private let unlockedMinSize = CGSize(width: 1100, height: 600)
    private let unlockedDefaultSize = CGSize(width: 1400, height: 760)

    private var savedUnlockedFrame: NSRect? {
        guard !savedFrameString.isEmpty else { return nil }
        let r = NSRectFromString(savedFrameString)
        return r.size.width > 0 && r.size.height > 0 ? r : nil
    }

    var body: some View {
        Group {
            switch auth.state {
            case .needsLogin:
                LoginView()
            case .locked:
                LockView()
            case .unlocked:
                ContentView()
                    .frame(
                        minWidth: unlockedMinSize.width,
                        idealWidth: unlockedDefaultSize.width,
                        maxWidth: .infinity,
                        minHeight: unlockedMinSize.height,
                        idealHeight: unlockedDefaultSize.height,
                        maxHeight: .infinity
                    )
            }
        }
        .background(WindowAccessor(window: $window))
        .onChange(of: window) { _, w in
            // Track the main window so MainWindowGuard's ⌘W monitor knows
            // which window to protect from accidental close.
            MainWindowGuard.shared.mainWindow = w
        }
        .onAppear { applyWindowSizing(for: auth.state, previous: nil) }
        .onChange(of: auth.state) { previous, current in
            if previous == .unlocked, let window {
                savedFrameString = NSStringFromRect(window.frame)
            }
            applyWindowSizing(for: current, previous: previous)
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.willCloseNotification)) { _ in
            guard auth.state == .unlocked, let window else { return }
            savedFrameString = NSStringFromRect(window.frame)
        }
    }

    private func applyWindowSizing(for state: AuthGate.State, previous: AuthGate.State?) {
        Task { @MainActor in
            guard let window else { return }
            switch state {
            case .needsLogin, .locked:
                window.contentMinSize = .zero
                window.contentView?.layoutSubtreeIfNeeded()
                let fitted = window.contentView?.fittingSize ?? CGSize(width: 360, height: 320)
                window.contentMinSize = fitted
                window.setContentSize(fitted)

            case .unlocked:
                window.contentMinSize = unlockedMinSize
                if previous == .unlocked {
                    // Already unlocked — just enforce min size, leave the
                    // user's current frame alone.
                    let current = window.contentRect(forFrameRect: window.frame).size
                    let target = CGSize(
                        width: max(current.width, unlockedMinSize.width),
                        height: max(current.height, unlockedMinSize.height)
                    )
                    window.setContentSize(target)
                } else if let saved = savedUnlockedFrame {
                    // Restore the full frame (origin + size) the user left it at.
                    window.setFrame(saved, display: true)
                } else {
                    // First-ever launch — center the default size on screen.
                    window.setContentSize(unlockedDefaultSize)
                    window.center()
                }
            }
        }
    }
}

private struct WindowAccessor: NSViewRepresentable {
    @Binding var window: NSWindow?

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        Task { @MainActor in
            window = view.window
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        Task { @MainActor in
            window = nsView.window
        }
    }
}

private extension String {
    func nilIfEmpty() -> String? { isEmpty ? nil : self }
}

/// Custom NSWindow subclass for the main BlueConnect Admin window that
/// refuses menu-driven closes (⌘W from the keyboard, or File > Close
/// from the menu bar). Programmatic closes and the red traffic light
/// still work, so the window can be quit normally — just not via the
/// keyboard shortcut where one stray keystroke would lose the session.
///
/// Why a subclass instead of an event monitor: `NSEvent` local monitors
/// fire AFTER `NSApplication`'s menu-key-equivalent matching for ⌘W on
/// macOS, so by the time the monitor sees the event the close has
/// already been triggered. Overriding `performClose(_:)` is the only
/// reliable interception point.
final class BCMainWindow: NSWindow {
    @objc override func performClose(_ sender: Any?) {
        // sender is an NSMenuItem when triggered by File > Close OR by
        // ⌘W (the system matches the shortcut to the menu item). The red
        // traffic light sends `self` or `nil`. Refuse only the menu path.
        if sender is NSMenuItem {
            if let id = MainWindowGuard.shared.terminals?.activeSessionID {
                MainWindowGuard.shared.terminals?.close(id)
            }
            return
        }
        super.performClose(sender)
    }
}

/// Holds the main-window reference and the terminal sessions manager so
/// `BCMainWindow.performClose` can find the active tab to close. Also
/// swaps the SwiftUI-supplied NSWindow's class to BCMainWindow on first
/// sight, which is how we hook performClose without owning the window.
@MainActor
final class MainWindowGuard {
    static let shared = MainWindowGuard()

    weak var mainWindow: NSWindow? {
        didSet {
            guard let mainWindow, mainWindow !== oldValue else { return }
            // Swap the class to our subclass once. Safe because BCMainWindow
            // adds no stored properties — Objective-C runtime allows this.
            if !(mainWindow is BCMainWindow) {
                object_setClass(mainWindow, BCMainWindow.self)
            }
        }
    }
    fileprivate weak var terminals: TerminalSessionsManager?

    func install(terminals: TerminalSessionsManager) {
        self.terminals = terminals
    }
}
