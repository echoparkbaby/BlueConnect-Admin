import Testing
@testable import BlueConnectAdmin

/// Round-trip coverage for the drag-and-drop payload format used by the
/// sidebar (status pills, category chips, host rows). Drag identification
/// is prefix-based: a regression that drops the prefix would silently
/// break every cross-sidebar drop without any user-visible error.
@Suite("DragPayload round-trip")
struct DragPayloadTests {

    @Test func statusEncodesAndParses() {
        let payload = DragPayload.status("online")
        #expect(payload.hasPrefix("bcadmin/status:"))
        #expect(DragPayload.parseStatus(payload) == "online")
    }

    @Test func categoryHandlesSpacesAndPunctuation() {
        let payload = DragPayload.category("Front Desk — iMacs")
        #expect(DragPayload.parseCategory(payload) == "Front Desk — iMacs")
    }

    @Test func hostsEncodesIntListAndParsesBack() {
        let payload = DragPayload.hosts([1, 17, 42])
        #expect(DragPayload.parseHosts(payload) == [1, 17, 42])
    }

    @Test func parsersRejectMismatchedPrefix() {
        let statusBlob = DragPayload.status("online")
        #expect(DragPayload.parseCategory(statusBlob) == nil)
        #expect(DragPayload.parseHosts(statusBlob) == nil)
    }

    @Test func parseHostsRejectsEmptyAndGarbage() {
        #expect(DragPayload.parseHosts("bcadmin/hosts:") == nil)
        #expect(DragPayload.parseHosts("bcadmin/hosts:abc,xyz") == nil)
        // One bad component is dropped, others kept — the .compactMap
        // contract. Tested so a refactor that flips it to all-or-
        // nothing is caught.
        #expect(DragPayload.parseHosts("bcadmin/hosts:5,xx,9") == [5, 9])
    }
}
