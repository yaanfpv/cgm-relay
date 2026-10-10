import Testing
import Foundation
@testable import CGMRelayCore

@Suite("EngineStatus")
struct EngineStatusTests {
    private func decode(_ json: String) throws -> EngineStatus {
        try JSONDecoder.engineStatusDecoder.decode(EngineStatus.self, from: Data(json.utf8))
    }

    @Test("decodes lan_reading_clients with fractional and whole-second times")
    func decodesLANReadingClients() throws {
        let status = try decode("""
        {"running": true, "sign_in_failing": false,
         "lan_reading_clients": {
           "xDrip4iOS/1.0": "2026-06-01T12:00:00.250Z",
           "LoopFollow/2.0": "2026-06-01T12:01:00Z"}}
        """)

        let clients = try #require(status.lanReadingClients)
        #expect(clients.count == 2)
        #expect(clients["xDrip4iOS/1.0"] == Date(timeIntervalSince1970: 1_780_315_200.25))
        #expect(clients["LoopFollow/2.0"] == Date(timeIntervalSince1970: 1_780_315_260))
    }

    @Test("decodes a status without lan_reading_clients as nil")
    func decodesWithoutLANReadingClients() throws {
        let status = try decode(#"{"running": true, "sign_in_failing": false, "clients": {"a": "2026-06-01T12:00:00Z"}}"#)

        #expect(status.lanReadingClients == nil)
        #expect(status.clients?.count == 1)
    }

    @Test("lanReadingFetch returns the newest entry at or after since")
    func lanReadingFetchReturnsNewest() {
        let base = Date(timeIntervalSince1970: 1_780_315_200)
        let status = EngineStatus(running: true, lanReadingClients: [
            "old/1.0": base.addingTimeInterval(-60),
            "mid/1.0": base.addingTimeInterval(10),
            "new/1.0": base.addingTimeInterval(30),
        ])

        let fetch = status.lanReadingFetch(since: base)

        #expect(fetch?.userAgent == "new/1.0")
        #expect(fetch?.at == base.addingTimeInterval(30))
    }

    @Test("lanReadingFetch counts an entry exactly at since")
    func lanReadingFetchIncludesSince() {
        let base = Date(timeIntervalSince1970: 1_780_315_200)
        let status = EngineStatus(running: true, lanReadingClients: ["edge/1.0": base])

        #expect(status.lanReadingFetch(since: base)?.userAgent == "edge/1.0")
    }

    @Test("lanReadingFetch is nil when every entry is older, empty, or absent")
    func lanReadingFetchNilWhenNoneRecent() {
        let base = Date(timeIntervalSince1970: 1_780_315_200)
        let older = EngineStatus(running: true, lanReadingClients: ["old/1.0": base.addingTimeInterval(-1)])

        #expect(older.lanReadingFetch(since: base) == nil)
        #expect(EngineStatus(running: true, lanReadingClients: [:]).lanReadingFetch(since: base) == nil)
        #expect(EngineStatus(running: true).lanReadingFetch(since: base) == nil)
    }
}
