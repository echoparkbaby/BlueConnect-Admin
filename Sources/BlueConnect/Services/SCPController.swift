import Foundation

/// Bridges ContentView (which knows the host you clicked on / dropped a
/// file onto) and the standalone SCP transfer Window. Holds the live
/// `SCPTransfer` plus the target host. Both the main scene and the SCP
/// Window inject this via `.environment` so state survives across the
/// scene boundary.
@MainActor
@Observable
final class SCPController {
    var transfer = SCPTransfer()
    var host: BlueSkyHost?

    /// Reset the transfer state and prepare for a new run. Cancels any
    /// in-flight scp first — overlapping transfers in v1 aren't supported.
    func begin(with host: BlueSkyHost, source: URL? = nil) {
        transfer.cancel()
        transfer.reset()
        if let source { transfer.setSource(source) }
        self.host = host
    }

    func clear() {
        transfer.cancel()
        transfer.reset()
        host = nil
    }
}
