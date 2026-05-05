import Foundation
import SwiftUI

@MainActor
@Observable
final class BlueSkyHostListStore {
    var hosts: [BlueSkyHost] = []
    var isLoading = false
    var lastError: String?
    var lastUpdated: Date?
    var activeCount: Int = 0
    var lastResponse: BlueSkyHostsResponse?

    func refresh(settings: SettingsStore) async {
        isLoading = true
        lastError = nil
        defer { isLoading = false }
        do {
            let resp = try await BlueSkyAPI.shared.fetchBlueSkyHosts(
                apiURL: settings.apiURL,
                username: settings.apiUsername,
                password: settings.webAdminPass
            )
            self.hosts = resp.hosts
            self.activeCount = resp.activeCount
            self.lastUpdated = Date()
            self.lastResponse = resp
            RuntimeLog.shared.info("API", "refresh ok: \(resp.hosts.count) hosts, \(resp.activeCount) active")
        } catch {
            let msg = (error as? APIError)?.errorDescription
                ?? error.localizedDescription
            self.lastError = msg
            RuntimeLog.shared.error("API", "refresh failed: \(msg)")
        }
    }
}
