import XCTest
import Foundation
@testable import Liaison

/// 0.2.10 ("Dev doesn't appear right away"): the last /agents/roster per account, read at launch.
final class RosterCacheTests: XCTestCase {
    func testKeyPerAccount() {
        XCTAssertEqual(RosterCache.key(account: "m1"), "lia_ws_roster_m1")
        XCTAssertTrue(RosterCache.key(account: "m1") != RosterCache.key(account: "m2"))
        XCTAssertEqual(RosterCache.key(account: nil), "lia_ws_roster__")
        XCTAssertEqual(RosterCache.key(account: "  "), "lia_ws_roster__")
        // Start over clears every lia_ws_ key, the roster with them
        XCTAssertTrue(RosterCache.key(account: "x").hasPrefix("lia_ws_"))
    }

    func testRoundTripKeepsDevAndFlags() {
        var dev = AgentInfo(id: "dev", name: "Dev", role: "Developer", shape: .triangle, colorHex: 0xF0533E,
                            onCall: true, writesFirst: true)
        dev.bio = "Builds your site."
        let roster = AgentInfo.fallback + [dev, AgentInfo(id: "giggs", name: "Giggs", role: "Google", shape: .half,
                                                          colorHex: 0x1AA260, soon: true)]
        guard let data = RosterCache.encode(roster), let back = RosterCache.decode(data) else {
            return XCTFail("roster did not round-trip")
        }
        XCTAssertEqual(back, roster)
        XCTAssertEqual(back.map(\.id), ["lia", "met", "crea", "dev", "giggs"])
        XCTAssertTrue(back[0].lead)
        XCTAssertTrue(back[1].write)
        XCTAssertEqual(back[3].bio, "Builds your site.")
        XCTAssertTrue(back[3].onCall && back[3].writesFirst)
        XCTAssertTrue(back[4].soon)
    }

    func testServerShapeAndBadInput() {
        let server = Data(##"{"ok":true,"agents":[{"id":"lia","name":"Lia","lead":true,"color":"#1F2430","shape":"ring"},{"id":"dev","name":"Dev","shape":"triangle","color":"#F0533E"}]}"##.utf8)
        XCTAssertEqual(RosterCache.decode(server)?.map(\.id), ["lia", "dev"])
        XCTAssertNil(RosterCache.decode(nil))
        XCTAssertNil(RosterCache.decode(Data("junk".utf8)))
        XCTAssertNil(RosterCache.decode(Data(#"{"ok":true,"agents":[]}"#.utf8)))
        XCTAssertNil(RosterCache.encode([]))
    }
}
