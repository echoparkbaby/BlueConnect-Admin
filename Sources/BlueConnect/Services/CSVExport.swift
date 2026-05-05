import Foundation
import SwiftUI
import UniformTypeIdentifiers

struct HostsCSVDocument: FileDocument {
    static var readableContentTypes: [UTType] = [.commaSeparatedText]
    let csv: String

    init(csv: String) { self.csv = csv }

    init(configuration: ReadConfiguration) throws {
        let data = configuration.file.regularFileContents ?? Data()
        self.csv = String(data: data, encoding: .utf8) ?? ""
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: csv.data(using: .utf8) ?? Data())
    }
}

enum HostsCSVBuilder {
    static func build(_ hosts: [BlueSkyHost]) -> String {
        var lines: [String] = [
            "blueskyid,hostname,sharingname,username,category,favorite,active,sshPort,vncPort,status,lastSeen,notes"
        ]
        for h in hosts {
            let row: [String] = [
                String(h.blueskyid),
                csvField(h.hostname),
                csvField(h.sharingname),
                csvField(h.username),
                csvField(h.category),
                h.isFavorite ? "1" : "0",
                h.active ? "1" : "0",
                String(h.sshPort),
                String(h.vncPort),
                csvField(h.status),
                csvField(h.lastSeen),
                csvField(h.notes),
            ]
            lines.append(row.joined(separator: ","))
        }
        return lines.joined(separator: "\n") + "\n"
    }

    private static func csvField(_ s: String?) -> String {
        let raw = s ?? ""
        // Quote if contains comma, quote, or newline
        if raw.contains(",") || raw.contains("\"") || raw.contains("\n") {
            return "\"" + raw.replacingOccurrences(of: "\"", with: "\"\"") + "\""
        }
        return raw
    }
}
