import Foundation

/// Owns the in-memory copy of the package catalog. Fetches the JSON at
/// `settings.packageCatalogURL` on demand and exposes the parsed
/// `PackageCatalog` to the UI. Refresh is manual (Settings button or
/// app launch); we don't poll.
@MainActor
@Observable
final class PackageCatalogStore {
    private(set) var catalog: PackageCatalog?
    private(set) var lastError: String?
    private(set) var isRefreshing: Bool = false

    var isReady: Bool { catalog != nil && !catalog!.packages.isEmpty }

    /// Upload a local .pkg / .dmg / .app to the user's repo storage,
    /// then refresh the catalog so the new file appears in the picker.
    /// Returns nil on success, or a user-facing error string on failure.
    ///
    /// Protocol comes from `service` (Settings → Package Repo picker):
    ///   - "ssh"        → /usr/bin/scp  (or sftp if URL begins with sftp://) with keyPath
    ///   - "ftp"        → /usr/bin/curl --upload-file (ftp/ftps; creds in URL)
    ///   - "nextcloud"  → /usr/bin/curl PUT to a Nextcloud WebDAV endpoint
    ///                    (auth via username/password in URL: https://user:pw@host/…)
    func upload(localFile: URL,
                scpPath uploadPath: String,
                keyPath: String,
                service: String = "ssh",
                catalogURL: String) async -> String? {
        let path = uploadPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !path.isEmpty else {
            return "No upload URL configured (Settings → Package Repo)."
        }
        let result: (Int32, String, String)  // (exit, stderr, command-summary)

        switch service {
        case "ftp":
            Log.info("Packages", "ftp upload \(localFile.lastPathComponent) → \(redact(path))")
            let cmd = "curl --upload-file \(localFile.lastPathComponent) \(redact(path))"
            let r = await runUpload(executable: "/usr/bin/curl",
                                    arguments: ["--silent", "--show-error", "--fail",
                                                "--upload-file", localFile.path, path])
            result = (r.0, r.1, cmd)

        case "nextcloud":
            Log.info("Packages", "nextcloud (WebDAV) \(localFile.lastPathComponent) → \(redact(path))")
            // Auto-append filename if URL ends with '/'. curl uploads as
            // <url>/<localFilename> when the URL has trailing slash; for
            // explicit URLs we leave it alone.
            let cmd = "curl -T \(localFile.lastPathComponent) \(redact(path))"
            let r = await runUpload(executable: "/usr/bin/curl",
                                    arguments: ["--silent", "--show-error", "--fail",
                                                "--upload-file", localFile.path, path])
            result = (r.0, r.1, cmd)

        case "ssh", "":
            fallthrough
        default:
            if path.hasPrefix("sftp://") {
                Log.info("Packages", "sftp \(localFile.lastPathComponent) → \(path)")
                let cmd = "sftp -i \(keyPath) … (put \(localFile.lastPathComponent))"
                let r = await runSFTPUpload(localFile: localFile, sftpURL: path, keyPath: keyPath)
                result = (r.0, r.1, cmd)
            } else {
                let scpTarget = path.hasPrefix("scp://") ? String(path.dropFirst(6)) : path
                Log.info("Packages", "scp \(localFile.lastPathComponent) → \(scpTarget)")
                let cmd = "scp -i \(keyPath) \(localFile.lastPathComponent) \(scpTarget)"
                let r = await runUpload(executable: "/usr/bin/scp",
                                        arguments: ["-i", keyPath,
                                                    "-o", "StrictHostKeyChecking=no",
                                                    "-o", "WarnWeakCrypto=no",
                                                    localFile.path, scpTarget])
                result = (r.0, r.1, cmd)
            }
        }

        guard result.0 == 0 else {
            let stderr = result.1.trimmingCharacters(in: .whitespacesAndNewlines)
            Log.error("Packages", "upload failed (exit \(result.0)): \(stderr)")
            return """
                Exit code: \(result.0)
                Command: \(result.2)
                Stderr: \(stderr.isEmpty ? "(empty)" : stderr.prefix(500))
                """
        }
        await refresh(urlString: catalogURL)
        return nil
    }

    /// Run any external command and capture stderr for error reporting.
    private func runUpload(executable: String, arguments: [String]) async -> (Int32, String) {
        await Task.detached(priority: .userInitiated) {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: executable)
            p.arguments = arguments
            let err = Pipe()
            p.standardError = err
            p.standardOutput = Pipe()  // discard stdout
            do {
                try p.run()
                p.waitUntilExit()
                let errData = err.fileHandleForReading.readDataToEndOfFile()
                return (p.terminationStatus, String(data: errData, encoding: .utf8) ?? "")
            } catch {
                return (-1, error.localizedDescription)
            }
        }.value
    }

    /// sftp takes `user@host` + a batch script via stdin. Parse `sftp://`
    /// URL → user, host, optional port, remote directory + push the file.
    private func runSFTPUpload(localFile: URL,
                               sftpURL: String,
                               keyPath: String) async -> (Int32, String) {
        // sftp://[user@]host[:port]/path/
        guard let url = URL(string: sftpURL),
              let host = url.host
        else { return (-1, "Invalid sftp:// URL: \(sftpURL)") }
        let user = url.user ?? NSUserName()
        let port = url.port ?? 22
        let remoteDir = url.path.isEmpty ? "/" : url.path
        let local = localFile.path
        let batchScript = "cd \(remoteDir)\nput \(local)\nquit\n"

        return await Task.detached(priority: .userInitiated) {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/sftp")
            p.arguments = [
                "-i", keyPath,
                "-o", "StrictHostKeyChecking=no",
                "-P", "\(port)",
                "-b", "-",                            // batch mode, stdin
                "\(user)@\(host)",
            ]
            let inPipe = Pipe()
            let errPipe = Pipe()
            p.standardInput = inPipe
            p.standardError = errPipe
            p.standardOutput = Pipe()
            do {
                try p.run()
                if let data = batchScript.data(using: .utf8) {
                    inPipe.fileHandleForWriting.write(data)
                }
                try? inPipe.fileHandleForWriting.close()
                p.waitUntilExit()
                let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
                return (p.terminationStatus, String(data: errData, encoding: .utf8) ?? "")
            } catch {
                return (-1, error.localizedDescription)
            }
        }.value
    }

    /// Hide URL-embedded password from log output (e.g. ftp://user:pw@host
    /// → ftp://user:***@host).
    private func redact(_ url: String) -> String {
        guard let schemeEnd = url.range(of: "://") else { return url }
        let afterScheme = schemeEnd.upperBound
        let rest = url[afterScheme...]
        guard let atIdx = rest.firstIndex(of: "@") else { return url }
        let authority = rest[..<atIdx]
        guard let colonIdx = authority.firstIndex(of: ":") else { return url }
        let userPart = authority[..<colonIdx]
        let after = rest[atIdx...]
        return String(url[..<afterScheme]) + userPart + ":***" + after
    }

    /// Fetch the JSON at `urlString` and replace the in-memory catalog.
    /// No-op when the URL is empty.
    func refresh(urlString: String) async {
        let trimmed = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed), !trimmed.isEmpty else {
            catalog = nil
            lastError = trimmed.isEmpty ? nil : "Bad URL"
            return
        }
        isRefreshing = true
        defer { isRefreshing = false }
        do {
            var req = URLRequest(url: url)
            req.cachePolicy = .reloadIgnoringLocalCacheData
            req.timeoutInterval = 15
            let (data, response) = try await URLSession.shared.data(for: req)
            if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                throw NSError(domain: "PackageCatalog", code: http.statusCode,
                              userInfo: [NSLocalizedDescriptionKey: "HTTP \(http.statusCode)"])
            }
            let parsed = try JSONDecoder().decode(PackageCatalog.self, from: data)
            catalog = parsed
            lastError = nil
            Log.info("Packages", "loaded catalog '\(parsed.name ?? "?")' with \(parsed.packages.count) packages")
        } catch {
            catalog = nil
            lastError = error.localizedDescription
            Log.error("Packages", "fetch failed: \(error.localizedDescription)")
        }
    }
}
