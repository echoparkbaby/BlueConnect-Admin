import Foundation
import SwiftUI

/// Server-backed category list. Sourced from /bs_categories.json.php on the
/// BlueSky server. Categories are shared across all operators / Macs running
/// BlueConnect Admin against the same server.
@MainActor
@Observable
final class CategoryStore {
    private(set) var categories: [String] = []
    var lastError: String?

    func updateFromHostsResponse(_ resp: BlueSkyHostsResponse) {
        // /bs_hosts.json.php returns the canonical category list inline.
        if let cats = resp.categories {
            self.categories = cats
        }
    }

    func category(for host: BlueSkyHost) -> String? {
        guard let c = host.category, !c.isEmpty else { return nil }
        return c
    }

    func count(of category: String, in hosts: [BlueSkyHost]) -> Int {
        hosts.reduce(0) { acc, h in acc + ((h.category ?? "") == category ? 1 : 0) }
    }

    func createCategory(_ name: String, settings: SettingsStore) async {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        do {
            _ = try await BlueSkyAPI.shared.createCategory(
                name: trimmed,
                apiURL: settings.apiURL,
                username: settings.apiUsername,
                password: settings.webAdminPass
            )
            // Optimistic add — will be canonicalized on next refresh.
            if !categories.contains(trimmed) {
                categories.append(trimmed)
                categories.sort { $0.lowercased() < $1.lowercased() }
            }
        } catch {
            lastError = (error as? APIError)?.errorDescription ?? error.localizedDescription
        }
    }

    func reorder(_ newOrder: [String], settings: SettingsStore) async {
        // Optimistic local apply.
        categories = newOrder
        do {
            _ = try await BlueSkyAPI.shared.reorderCategories(
                newOrder,
                apiURL: settings.apiURL,
                username: settings.apiUsername,
                password: settings.webAdminPass
            )
        } catch {
            lastError = (error as? APIError)?.errorDescription ?? error.localizedDescription
        }
    }

    func deleteCategory(_ name: String, clearFromHosts: Bool, settings: SettingsStore) async {
        do {
            _ = try await BlueSkyAPI.shared.deleteCategory(
                name: name, clearFromHosts: clearFromHosts,
                apiURL: settings.apiURL,
                username: settings.apiUsername,
                password: settings.webAdminPass
            )
            categories.removeAll { $0 == name }
        } catch {
            lastError = (error as? APIError)?.errorDescription ?? error.localizedDescription
        }
    }

    func assign(_ category: String?, to hosts: [BlueSkyHost], settings: SettingsStore) async -> (ok: Int, failed: [String]) {
        let value = category ?? ""
        var ok = 0
        var failed: [String] = []
        for h in hosts {
            do {
                _ = try await BlueSkyAPI.shared.updateHost(
                    blueskyid: h.blueskyid,
                    fields: ["category": value],
                    apiURL: settings.apiURL,
                    username: settings.apiUsername,
                    password: settings.webAdminPass
                )
                ok += 1
            } catch {
                let m = (error as? APIError)?.errorDescription ?? error.localizedDescription
                failed.append("#\(h.blueskyid): \(m.prefix(80))")
            }
        }
        return (ok, failed)
    }
}
