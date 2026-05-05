import Foundation
import LocalAuthentication
import SwiftUI

@MainActor
final class AuthGate: ObservableObject {
    enum State {
        case needsLogin    // First launch — no saved credentials
        case locked        // Saved + Touch ID required
        case unlocked      // Ready
    }

    @Published var state: State = .needsLogin
    @Published var lastError: String?

    @AppStorage("hasSavedLogin") var hasSavedLogin: Bool = false
    @AppStorage("requireTouchID") var requireTouchID: Bool = false
    @AppStorage("requireTouchIDForDestructive") var requireTouchIDForDestructive: Bool = true

    /// Determines initial state based on saved login + Touch ID preference.
    func bootstrap(settings: SettingsStore) {
        if hasSavedLogin {
            settings.loadPasswordFromKeychain()
            if settings.webAdminPass.isEmpty {
                state = .needsLogin
                hasSavedLogin = false
                return
            }
            state = requireTouchID ? .locked : .unlocked
        } else {
            state = .needsLogin
        }
    }

    var isBiometricsAvailable: Bool {
        let ctx = LAContext()
        var err: NSError?
        return ctx.canEvaluatePolicy(.deviceOwnerAuthentication, error: &err)
    }

    func unlockWithTouchID() async {
        guard state == .locked else { return }
        let ctx = LAContext()
        ctx.localizedFallbackTitle = "Use password…"
        var err: NSError?
        guard ctx.canEvaluatePolicy(.deviceOwnerAuthentication, error: &err) else {
            state = .unlocked
            lastError = err?.localizedDescription
            return
        }
        do {
            let ok = try await ctx.evaluatePolicy(
                .deviceOwnerAuthentication,
                localizedReason: "Unlock BlueConnect Admin"
            )
            if ok { state = .unlocked }
        } catch {
            lastError = error.localizedDescription
        }
    }

    func lock() {
        if hasSavedLogin && requireTouchID { state = .locked }
    }

    func logout(settings: SettingsStore) {
        settings.clearCredentials()
        hasSavedLogin = false
        requireTouchID = false
        state = .needsLogin
    }

    /// Touch ID gate for destructive actions (unchanged).
    func confirmDestructive(reason: String) async -> Bool {
        guard requireTouchIDForDestructive else { return true }
        let ctx = LAContext()
        ctx.localizedFallbackTitle = "Use password…"
        var err: NSError?
        guard ctx.canEvaluatePolicy(.deviceOwnerAuthentication, error: &err) else { return true }
        do {
            return try await ctx.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason)
        } catch { return false }
    }

    /// Mark login successful and persist preferences.
    func onLoginSuccess(enableTouchID: Bool) {
        hasSavedLogin = true
        requireTouchID = enableTouchID
        state = .unlocked
    }
}
