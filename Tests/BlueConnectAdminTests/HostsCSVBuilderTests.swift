import Testing
@testable import BlueConnectAdmin

/// `HostsCSVBuilder.build` is what File → Export Hosts as CSV runs.
/// Easy thing to silently break in a refactor: forget to quote a field
/// that contains a comma / quote / newline, or shuffle the header
/// columns out of sync with the row order. Both produce an Excel file
/// the user wouldn't notice was wrong until they tried to filter it.
@Suite("HostsCSVBuilder")
struct HostsCSVBuilderTests {

    /// Minimal BlueSkyHost factory — most tests only care about a
    /// handful of fields, so this collapses the noise. Required
    /// fields keep their normal types; everything optional defaults
    /// to nil and can be overridden by named arg.
    private func host(
        blueskyid: Int = 1,
        hostname: String? = "host",
        sharingname: String? = nil,
        username: String? = nil,
        status: String? = nil,
        lastSeen: String? = nil,
        category: String? = nil,
        favorite: Bool? = nil,
        notes: String? = nil,
        active: Bool = true,
        sshPort: Int = 22,
        vncPort: Int = 5900
    ) -> BlueSkyHost {
        BlueSkyHost(
            blueskyid: blueskyid, hostname: hostname, sharingname: sharingname,
            username: username, status: status, lastSeen: lastSeen,
            timestamp: 0, active: active, sshPort: sshPort, vncPort: vncPort,
            category: category, favorite: favorite, notes: notes,
            serialnum: nil, notify: nil, alert: nil, email: nil
        )
    }

    @Test func headerComesFirstAndEndsWithNewline() {
        let csv = HostsCSVBuilder.build([])
        let lines = csv.split(separator: "\n", omittingEmptySubsequences: false)
        #expect(lines.first == "blueskyid,hostname,sharingname,username,category,favorite,active,sshPort,vncPort,status,lastSeen,notes")
        #expect(csv.hasSuffix("\n"))
    }

    @Test func emptyHostsProducesHeaderOnly() {
        let csv = HostsCSVBuilder.build([])
        #expect(csv.split(separator: "\n", omittingEmptySubsequences: true).count == 1)
    }

    @Test func basicRowOrdering() {
        let csv = HostsCSVBuilder.build([
            host(blueskyid: 7, hostname: "pine", category: "Studio",
                 favorite: true, active: true, sshPort: 2222, vncPort: 5901)
        ])
        let row = csv.split(separator: "\n").last!
        #expect(row.hasPrefix("7,pine,,,Studio,1,1,2222,5901,,,"))
    }

    @Test func commaInFieldGetsQuoted() {
        let csv = HostsCSVBuilder.build([
            host(notes: "front desk, lobby")
        ])
        #expect(csv.contains(#""front desk, lobby""#))
    }

    @Test func quoteInFieldGetsDoubledAndWrapped() {
        // CSV escape rule: inside a quoted field, " becomes "".
        let csv = HostsCSVBuilder.build([
            host(hostname: #"susan's "main""#)
        ])
        #expect(csv.contains(#""susan's ""main""""#))
    }

    @Test func newlineInFieldGetsQuoted() {
        let csv = HostsCSVBuilder.build([
            host(notes: "line one\nline two")
        ])
        #expect(csv.contains("\"line one\nline two\""))
    }

    @Test func nilFieldsRenderAsEmpty() {
        // hostname/category/notes nil should produce empty fields,
        // never the literal "nil" string.
        let csv = HostsCSVBuilder.build([host(hostname: nil)])
        #expect(!csv.contains("nil"))
        #expect(!csv.contains("Optional"))
    }
}
