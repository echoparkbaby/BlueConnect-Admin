import AppKit

/// Watches for keyboard/mouse activity in the app and locks the auth gate
/// after `settings.idleLockMinutes` of inactivity. Only active when:
/// - `auth.state == .unlocked`
/// - `auth.requireTouchID == true` (else there's nothing to lock back into)
/// - `settings.idleLockMinutes > 0`
///
/// Has no observable state — views don't render from this; it operates
/// silently by mutating `auth.state` when the threshold trips.
@MainActor
final class IdleLockMonitor {
    private weak var auth: AuthGate?
    private weak var settings: SettingsStore?

    private var localMonitor: Any?
    private var globalMonitor: Any?
    private var timer: Timer?
    private var lastActivity = Date()

    func start(auth: AuthGate, settings: SettingsStore) {
        self.auth = auth
        self.settings = settings
        installMonitors()
        rearmTimer()
    }

    func noteActivity() {
        lastActivity = Date()
    }

    private func installMonitors() {
        guard localMonitor == nil else { return }
        let mask: NSEvent.EventTypeMask = [.keyDown, .leftMouseDown, .rightMouseDown,
                                           .otherMouseDown, .scrollWheel, .mouseMoved]
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: mask) { [weak self] event in
            self?.lastActivity = Date()
            return event
        }
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: mask) { [weak self] _ in
            self?.lastActivity = Date()
        }
    }

    private func rearmTimer() {
        timer?.invalidate()
        let t = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    private func tick() {
        guard let auth, let settings else { return }
        let minutes = settings.idleLockMinutes
        guard minutes > 0,
              auth.state == .unlocked,
              auth.requireTouchID
        else { return }
        let idle = Date().timeIntervalSince(lastActivity)
        if idle >= TimeInterval(minutes) * 60 {
            auth.lock()
            lastActivity = Date()
        }
    }
}
