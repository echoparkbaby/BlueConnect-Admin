import Foundation
import Observation

/// Relay between the floating Install Package window and ContentView's
/// action handlers. SwiftUI Window scenes can't capture closures across
/// the scene boundary, so the window writes "intents" here and
/// ContentView reacts via `.onChange`. Keeping it tiny on purpose — this
/// is glue, not logic.
@MainActor
@Observable
final class PackagePickerController {
    /// Hosts the user right-clicked or selected when opening the picker.
    /// Read by the window view to render the target summary and pass
    /// through to install handlers.
    var hosts: [BlueSkyHost] = []

    /// Bumped whenever the user opens the picker. ContentView doesn't use
    /// this — it just calls `openWindow`. The counter exists so reopening
    /// the same window with new hosts re-triggers `.onChange` watchers
    /// downstream that key off `(hosts, openCounter)`.
    var openCounter: Int = 0

    /// Set by the window when the user picks a Direct-catalog package.
    /// ContentView clears it after dispatching the install.
    var pendingDirectInstall: Package? = nil

    /// Set by the window when the user picks a Munki package (with a
    /// specific version, possibly chosen via the right-click drill-down).
    var pendingMunkiInstall: MunkiPkg? = nil

    /// Set by the window when the user drops or picks a local installer.
    var pendingFileDrop: URL? = nil

    /// True when an intent came from the package picker window and the
    /// consumer should close that window after dispatching the install.
    var dismissPickerAfterPendingIntent: Bool = false

    /// Parallel "target" for the direct-install (local-network) flow.
    /// When `hosts` is empty AND `localTarget` is set, ContentView routes
    /// the pending intent through the direct LAN install path.
    var localTarget: LocalService? = nil

    func present(hosts: [BlueSkyHost]) {
        self.hosts = hosts
        self.localTarget = nil
        self.pendingDirectInstall = nil
        self.pendingMunkiInstall = nil
        self.pendingFileDrop = nil
        self.dismissPickerAfterPendingIntent = false
        self.openCounter &+= 1
    }
}
