import Testing
import Foundation
@testable import BlueConnectAdmin

/// The UniFi controller has shipped three different field-name styles
/// over the years (snake_case legacy, camelCase mid-era, integration-API
/// renames). `UniFiClient.ClientInfo`'s custom `init(from:)` tries each
/// alias per field. These tests pin the alias coverage so a future
/// "modernize the decoder" pass can't silently drop legacy support.
@Suite("UniFiClient.ClientInfo decoder")
struct UniFiClientDecoderTests {

    private func decode(_ json: String) throws -> UniFiClient.ClientInfo {
        let data = Data(json.utf8)
        return try JSONDecoder().decode(UniFiClient.ClientInfo.self, from: data)
    }

    @Test func legacySnakeCaseFields() throws {
        let json = """
        {
            "_id": "client-1",
            "hostname": "front-desk-imac",
            "ip": "10.0.0.55",
            "mac": "aa:bb:cc:dd:ee:ff",
            "type": "WIRED",
            "wired_rate_mbps": 1000,
            "vlan": 1
        }
        """
        let c = try decode(json)
        #expect(c.id == "client-1")
        #expect(c.name == "front-desk-imac")
        #expect(c.ip == "10.0.0.55")
        #expect(c.macAddress == "aa:bb:cc:dd:ee:ff")
        #expect(c.isWired)
        #expect(c.txRateMbps == 1000)
        #expect(c.vlan == 1)
    }

    @Test func camelCaseAliases() throws {
        let json = """
        {
            "id": "client-2",
            "name": "shop-laptop",
            "ipAddress": "10.0.0.99",
            "macAddress": "11:22:33:44:55:66",
            "type": "WIRELESS"
        }
        """
        let c = try decode(json)
        #expect(c.id == "client-2")
        #expect(c.name == "shop-laptop")
        #expect(c.ip == "10.0.0.99")
        #expect(c.macAddress == "11:22:33:44:55:66")
        #expect(!c.isWired)
    }

    @Test func fixedIpFallback() throws {
        // Reserved-IP clients have no `ip` until they're online — but
        // the controller still reports `fixed_ip`. The decoder should
        // surface that for the scan table.
        let json = """
        {
            "_id": "client-3",
            "fixed_ip": "10.0.0.200"
        }
        """
        let c = try decode(json)
        #expect(c.ip == "10.0.0.200")
    }

    @Test func networkLabelOverridesVlanForDisplay() throws {
        let json = """
        {
            "_id": "client-4",
            "network": "IoT",
            "vlan": 30
        }
        """
        let c = try decode(json)
        #expect(c.network == "IoT")
        #expect(c.vlan == 30)
    }

    @Test func displaySpeedFormatsGigabit() throws {
        let json = """
        {"_id": "x", "wired_rate_mbps": 1000}
        """
        let c = try decode(json)
        #expect(c.displaySpeed == "1 Gbps")
    }

    @Test func displaySpeedFormatsMegabit() throws {
        let json = """
        {"_id": "x", "wired_rate_mbps": 100}
        """
        let c = try decode(json)
        #expect(c.displaySpeed == "100 Mbps")
    }

    @Test func displaySpeedIsNilWhenUnknown() throws {
        let json = """
        {"_id": "x"}
        """
        let c = try decode(json)
        #expect(c.displaySpeed == nil)
    }
}
