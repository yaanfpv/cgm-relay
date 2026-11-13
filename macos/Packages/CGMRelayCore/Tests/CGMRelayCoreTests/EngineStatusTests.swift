import Testing
import Foundation
@testable import CGMRelayCore

@Suite("EngineStatus")
struct EngineStatusTests {
    private func decode(_ json: String) throws -> EngineStatus {
        try JSONDecoder.engineStatusDecoder.decode(EngineStatus.self, from: Data(json.utf8))
    }

    @Test("decodes the clients' fractional and whole-second times")
    func decodesClientTimes() throws {
        let status = try decode("""
        {"running": true, "sign_in_failing": false,
         "clients": {
           "xDrip4iOS/1.0": "2026-06-01T12:00:00.250Z",
           "LoopFollow/2.0": "2026-06-01T12:01:00Z"}}
        """)

        let clients = try #require(status.clients)
        #expect(clients.count == 2)
        #expect(clients["xDrip4iOS/1.0"] == Date(timeIntervalSince1970: 1_780_315_200.25))
        #expect(clients["LoopFollow/2.0"] == Date(timeIntervalSince1970: 1_780_315_260))
    }

    @Test("a status from an older engine that still reports lan_reading_clients decodes, and the field is ignored")
    func ignoresTheRetiredLANField() throws {
        let status = try decode(#"{"running": true, "sign_in_failing": false, "clients": {"a": "2026-06-01T12:00:00Z"}, "lan_reading_clients": {"b": "2026-06-01T12:00:00Z"}}"#)

        #expect(status.running)
        #expect(status.clients?.count == 1)
    }
}
