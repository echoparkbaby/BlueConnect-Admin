import Foundation

actor BlueSkyAPI {
    static let shared = BlueSkyAPI()

    private func sanitizeBase(_ apiURL: String) -> String {
        apiURL
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }

    private func authHeader(username: String, password: String) -> String {
        let user = username.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleaned = password.trimmingCharacters(in: .whitespacesAndNewlines)
        let raw = "\(user):\(cleaned)".data(using: .utf8)?.base64EncodedString() ?? ""
        return "Basic \(raw)"
    }

    func renameHost(
        blueskyid: Int,
        newHostname: String,
        apiURL: String,
        username: String,
        password: String
    ) async throws -> [String: Any] {
        // Update BOTH hostname AND sharingname. BSC keeps them as
        // separate columns and HostnameCell renders the bold top line
        // from `hostname` and a gray subtitle from `sharingname` IF
        // they differ — leaving sharingname stale produces the
        // confusing "acorn / maple" two-line display the user saw.
        try await updateHost(
            blueskyid: blueskyid,
            fields: ["hostname": newHostname, "sharingname": newHostname],
            apiURL: apiURL,
            username: username,
            password: password
        )
    }

    func updateHost(
        blueskyid: Int,
        fields: [String: Any],
        apiURL: String,
        username: String,
        password: String
    ) async throws -> [String: Any] {
        let base = sanitizeBase(apiURL)
        guard let url = URL(string: "\(base)/bs_host_update.json.php") else { throw APIError.badURL }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue(authHeader(username: username, password: password), forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.timeoutInterval = 15
        var body: [String: Any] = ["blueskyid": blueskyid]
        for (k, v) in fields { body[k] = v }
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await URLSession.shared.data(for: req)
        guard let http = response as? HTTPURLResponse else { throw APIError.badResponse(0, "") }
        guard (200..<300).contains(http.statusCode) else {
            throw APIError.badResponse(http.statusCode, String(data: data, encoding: .utf8) ?? "")
        }
        return (try JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
    }

    func createCategory(name: String, apiURL: String, username: String, password: String) async throws -> [String: Any] {
        let base = sanitizeBase(apiURL)
        guard let url = URL(string: "\(base)/bs_categories.json.php") else { throw APIError.badURL }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue(authHeader(username: username, password: password), forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.timeoutInterval = 15
        req.httpBody = try JSONSerialization.data(withJSONObject: ["name": name])
        let (data, response) = try await URLSession.shared.data(for: req)
        guard let http = response as? HTTPURLResponse else { throw APIError.badResponse(0, "") }
        guard (200..<300).contains(http.statusCode) else {
            throw APIError.badResponse(http.statusCode, String(data: data, encoding: .utf8) ?? "")
        }
        return (try JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
    }

    func reorderCategories(_ order: [String], apiURL: String, username: String, password: String) async throws -> [String: Any] {
        let base = sanitizeBase(apiURL)
        guard let url = URL(string: "\(base)/bs_categories.json.php") else { throw APIError.badURL }
        var req = URLRequest(url: url)
        req.httpMethod = "PUT"
        req.setValue(authHeader(username: username, password: password), forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.timeoutInterval = 15
        req.httpBody = try JSONSerialization.data(withJSONObject: ["order": order])
        let (data, response) = try await URLSession.shared.data(for: req)
        guard let http = response as? HTTPURLResponse else { throw APIError.badResponse(0, "") }
        guard (200..<300).contains(http.statusCode) else {
            throw APIError.badResponse(http.statusCode, String(data: data, encoding: .utf8) ?? "")
        }
        return (try JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
    }

    func deleteCategory(name: String, clearFromHosts: Bool, apiURL: String, username: String, password: String) async throws -> [String: Any] {
        let base = sanitizeBase(apiURL)
        guard let url = URL(string: "\(base)/bs_categories.json.php") else { throw APIError.badURL }
        var req = URLRequest(url: url)
        req.httpMethod = "DELETE"
        req.setValue(authHeader(username: username, password: password), forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.timeoutInterval = 15
        req.httpBody = try JSONSerialization.data(withJSONObject: ["name": name, "clearFromHosts": clearFromHosts])
        let (data, response) = try await URLSession.shared.data(for: req)
        guard let http = response as? HTTPURLResponse else { throw APIError.badResponse(0, "") }
        guard (200..<300).contains(http.statusCode) else {
            throw APIError.badResponse(http.statusCode, String(data: data, encoding: .utf8) ?? "")
        }
        return (try JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
    }

    func performAction(
        _ action: HostAction,
        blueskyid: Int,
        apiURL: String,
        username: String,
        password: String
    ) async throws -> [String: Any] {
        let base = sanitizeBase(apiURL)
        guard let url = URL(string: "\(base)/bs_host_action.json.php") else {
            throw APIError.badURL
        }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue(authHeader(username: username, password: password), forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.timeoutInterval = 15
        let body: [String: Any] = ["action": action.rawValue, "blueskyid": blueskyid]
        req.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await URLSession.shared.data(for: req)
        } catch {
            throw APIError.network(error)
        }
        guard let http = response as? HTTPURLResponse else {
            throw APIError.badResponse(0, "")
        }
        guard (200..<300).contains(http.statusCode) else {
            throw APIError.badResponse(http.statusCode, String(data: data, encoding: .utf8) ?? "")
        }
        return (try JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
    }

    /// Unblock a serial — DELETE FROM blocked_serials. Reuses the
    /// bs_host_action endpoint with the new `unblock` action keyed on
    /// serial (no blueskyid because the host row is already gone). The
    /// host will reappear in BlueConnect on its next agent reconnect.
    func unblockSerial(
        _ serial: String,
        apiURL: String,
        username: String,
        password: String
    ) async throws -> [String: Any] {
        let base = sanitizeBase(apiURL)
        guard let url = URL(string: "\(base)/bs_host_action.json.php") else {
            throw APIError.badURL
        }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue(authHeader(username: username, password: password), forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.timeoutInterval = 15
        req.httpBody = try JSONSerialization.data(withJSONObject: ["action": "unblock", "serial": serial])

        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await URLSession.shared.data(for: req)
        } catch { throw APIError.network(error) }
        guard let http = response as? HTTPURLResponse else { throw APIError.badResponse(0, "") }
        guard (200..<300).contains(http.statusCode) else {
            throw APIError.badResponse(http.statusCode, String(data: data, encoding: .utf8) ?? "")
        }
        return (try JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
    }

    /// Pull the current contents of BlueSky.blocked_serials. Empty list
    /// when the table doesn't exist yet (no host has ever been blocked).
    func fetchBlockedSerials(
        apiURL: String,
        username: String,
        password: String
    ) async throws -> [BlockedSerial] {
        let base = sanitizeBase(apiURL)
        guard let url = URL(string: "\(base)/bs_blocklist.json.php") else {
            throw APIError.badURL
        }
        var req = URLRequest(url: url)
        req.setValue(authHeader(username: username, password: password), forHTTPHeaderField: "Authorization")
        req.cachePolicy = .reloadIgnoringLocalCacheData
        req.timeoutInterval = 15

        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await URLSession.shared.data(for: req)
        } catch { throw APIError.network(error) }
        guard let http = response as? HTTPURLResponse else { throw APIError.badResponse(0, "") }
        guard (200..<300).contains(http.statusCode) else {
            throw APIError.badResponse(http.statusCode, String(data: data, encoding: .utf8) ?? "")
        }
        do {
            return try JSONDecoder().decode(BlockedSerialsResponse.self, from: data).items
        } catch {
            throw APIError.decoding(error)
        }
    }

    func fetchBlueSkyHosts(apiURL: String, username: String, password: String) async throws -> BlueSkyHostsResponse {
        let base = sanitizeBase(apiURL)
        guard let url = URL(string: "\(base)/bs_hosts.json.php") else {
            throw APIError.badURL
        }
        var req = URLRequest(url: url)
        req.setValue(authHeader(username: username, password: password), forHTTPHeaderField: "Authorization")
        req.cachePolicy = .reloadIgnoringLocalCacheData
        req.timeoutInterval = 15

        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await URLSession.shared.data(for: req)
        } catch {
            throw APIError.network(error)
        }

        guard let http = response as? HTTPURLResponse else {
            throw APIError.badResponse(0, "")
        }
        guard (200..<300).contains(http.statusCode) else {
            throw APIError.badResponse(http.statusCode, String(data: data, encoding: .utf8) ?? "")
        }

        do {
            return try JSONDecoder().decode(BlueSkyHostsResponse.self, from: data)
        } catch {
            throw APIError.decoding(error)
        }
    }
}
