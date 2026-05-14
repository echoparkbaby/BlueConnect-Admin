import Foundation
import Observation

/// Per-serial cache of MunkiReport inventory pulls. Owned by ContentView,
/// shared with the right-side inspector pane (and the standalone sheet).
/// Selecting the same host twice in a row hits the cache and renders
/// instantly; the user can force a refresh from the pane's button.
///
/// Errors are recorded per-serial so the UI can surface a meaningful
/// "MR fetch failed for this host" without losing other cached entries.
@Observable
@MainActor
final class MunkiReportInventoryStore {
    /// `serial → inventory` cache. Stays in memory for the app session.
    var bySerial: [String: MRHostInventory] = [:]
    /// Which serial we're actively fetching right now (used by the UI to
    /// show a spinner only for the row in flight).
    var loadingSerial: String?
    /// `serial → error` so a per-host failure surfaces in the inspector
    /// without globally blanking everything.
    var errorBySerial: [String: String] = [:]

    /// Kick off a fetch for `serial` if we don't have it cached and aren't
    /// already fetching it. Cheap to call repeatedly — safe to invoke
    /// from `.onChange(of: selectedSerial)`.
    func loadIfNeeded(serial: String, settings: SettingsStore) {
        guard !serial.isEmpty else { return }
        guard bySerial[serial] == nil, loadingSerial != serial else { return }
        guard settings.isMunkiReportAPIConfigured else { return }
        Task { await fetch(serial: serial, settings: settings) }
    }

    /// Force re-fetch — invalidates the cache entry and pulls again.
    /// Triggered by the inspector's refresh button.
    func refresh(serial: String, settings: SettingsStore) {
        guard !serial.isEmpty else { return }
        bySerial.removeValue(forKey: serial)
        errorBySerial.removeValue(forKey: serial)
        Task { await fetch(serial: serial, settings: settings) }
    }

    private func fetch(serial: String, settings: SettingsStore) async {
        loadingSerial = serial
        defer { if loadingSerial == serial { loadingSerial = nil } }
        do {
            let client = MunkiReportClient()
            let inv = try await client.fetchHost(serial: serial, settings: settings)
            bySerial[serial] = inv
            errorBySerial.removeValue(forKey: serial)
        } catch {
            errorBySerial[serial] = error.localizedDescription
        }
    }
}
