import Foundation
import XCTest
@testable import Liaison

final class RelayLookTests: XCTestCase {
    private func ev(_ id: String, actor: String = "Alex", actorId: String? = nil, eid: String? = nil, journal: Bool = false,
                    via: String? = nil, from: String? = nil, to: String? = nil) -> RelayEvent {
        var e = RelayEvent(id: id, eid: eid, ts: 1, actor: actor, action: "Paused", entity: "Kids", entityType: "", from: from, to: to,
                           viaLiaison: via == "Liaison", system: false)
        e.actorId = actorId
        e.fromJournal = journal
        e.via = via
        return e
    }

    private let people = AccountPeople.parse(Data(#"{"ok":true,"active":[{"name":"Sam Carter","id":"777","changes":3,"last_at":9,"is_you":true},{"name":"Alex Rossi","id":"555","changes":1,"last_at":5}],"access":[{"name":"Anna"}]}"#.utf8))

    func testMineIsTheActorNotTheSource() {
        XCTAssertEqual(people?.active.first?.actorId, "777")
        XCTAssertTrue(RelayLook.isMine(ev("a", actor: "You", journal: true), people: nil))
        XCTAssertTrue(RelayLook.isMine(ev("b", actor: "Someone renamed", actorId: "777", via: "Ads Manager"), people: people))
        XCTAssertTrue(RelayLook.isMine(ev("c", actor: "Sam Carter"), people: people))
        XCTAssertFalse(RelayLook.isMine(ev("d", actor: "Alex Rossi", actorId: "555"), people: people))
        XCTAssertFalse(RelayLook.isMine(ev("e", actor: "Sam Carter"), people: nil))

        let mine = RelayComment(json: ["cid": "c1", "n": "Sam", "x": "ok", "t": 1, "m": "mem_1"])!
        XCTAssertEqual(mine.memberId, "mem_1")
        XCTAssertTrue(RelayLook.isMine(mine, memberId: "mem_1"))
        XCTAssertFalse(RelayLook.isMine(mine, memberId: "mem_2"))
        XCTAssertFalse(RelayLook.isMine(RelayComment(json: ["cid": "c2", "n": "Sam", "x": "ok"])!, memberId: "mem_1"))
    }

    func testParseCarriesIdentityAndStamp() {
        let feed = RelayFeed.parse(Data(#"{"journal":[{"id":"q1","ts":1,"diff":[{"kind":"paused"}]}],"meta_changes":[{"at":5000000,"actor":"Alex","actor_id":555,"action":"x","eid":"m1","cm":1,"via":"Ads Manager"},{"at":6000000,"actor":"Anna","action":"y","eid":"m2","via":"Zapier","via_real":"Zapier Inc"}]}"#.utf8))
        let byId = Dictionary(uniqueKeysWithValues: feed.map { ($0.eid ?? $0.id, $0) })
        XCTAssertEqual(byId["m1"]?.actorId, "555")
        XCTAssertEqual(byId["m1"].map(RelayLook.stamp), .adsManager)
        XCTAssertEqual(byId["m1"]?.liaisonActor, true)
        XCTAssertEqual(byId["m2"].map(RelayLook.stamp), .other("Zapier Inc"))
        XCTAssertEqual(byId["m2"]?.liaisonActor, false)
        let ours = feed.first { $0.fromJournal }
        XCTAssertEqual(ours.map(RelayLook.stamp), .liaison)
        XCTAssertEqual(RelayLook.stamp(ev("n")), .none)
    }

    func testInitialsColorsAndToneLikeTheSite() {
        XCTAssertEqual(RelayLook.initials("Sam Carter"), "SC")
        XCTAssertEqual(RelayLook.initials("alex"), "AL")
        XCTAssertEqual(RelayLook.initials(""), "?")
        XCTAssertEqual(RelayLook.avatarColor("sam carter", people: people), RelayLook.selfColor)
        XCTAssertEqual(RelayLook.avatarColor("Alex Rossi", people: people), RelayLook.pool[0])
        XCTAssertEqual(RelayLook.avatarColor("Anna", people: people), RelayLook.pool[1])
        // the name hash of ai.js: "a" = 97 -> 97 % 7 = 6
        XCTAssertEqual(RelayLook.avatarColor("A", people: nil), RelayLook.pool[6])
        XCTAssertEqual(RelayLook.tone("INACTIVE"), .off)
        XCTAssertEqual(RelayLook.tone("ACTIVE"), .on)
        XCTAssertEqual(RelayLook.tone("€20.00"), .neutral)
    }

    func testDiffCopyDayAndThreadAnchor() {
        XCTAssertEqual(RelayLook.diff(ev("a", from: "ACTIVE", to: "PAUSED")), RelayLook.Diff(from: "ACTIVE", to: "PAUSED"))
        XCTAssertEqual(RelayLook.diff(ev("a", to: "PAUSED")), RelayLook.Diff(to: "PAUSED"))
        XCTAssertNil(RelayLook.diff(ev("a")))
        let json = "{\"rules\":[" + String(repeating: "{\"a\":1},", count: 30) + "]}"
        XCTAssertEqual(RelayLook.diff(ev("a", from: json, to: json))?.hidesEntity, true)
        XCTAssertEqual(RelayLook.copyText(ev("a", from: "1", to: "2")), "Alex Paused Kids (1 \u{2192} 2)")
        XCTAssertEqual(RelayLook.copyText(ev("a", actor: "")), "You Paused Kids")

        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        let now = Date(timeIntervalSince1970: 1_760_000_000)   // 9 Oct 2025, 08:53 UTC
        let ms = now.timeIntervalSince1970 * 1000
        XCTAssertEqual(RelayLook.dayLabel(ms, now: now, calendar: cal), "TODAY")
        XCTAssertEqual(RelayLook.dayLabel(ms - 86_400_000, now: now, calendar: cal), "YESTERDAY")
        XCTAssertEqual(RelayLook.dayLabel(ms - 5 * 86_400_000, now: now, calendar: cal), "4 OCT")

        let rows = [ev("r1", eid: "j1"), ev("r2", eid: "j1"), ev("r3", eid: "m9"), ev("r4")]
        XCTAssertEqual(RelayLook.threadAnchors(rows), ["r2", "r3", "r4"])
        let cs = ["Sam", "Alex", "Sam", "Anna", "Bo"].enumerated().map { RelayComment(json: ["cid": "c\($0.offset)", "n": $0.element, "x": "x"])! }
        XCTAssertEqual(RelayLook.stackNames(cs), ["Sam", "Alex", "Anna"])
    }
}
