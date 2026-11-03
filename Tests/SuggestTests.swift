import XCTest
import Foundation
@testable import Liaison

/// /agents/suggest's client side (Shared/Core/Suggest.swift): what goes out and what is accepted back.
final class SuggestTests: XCTestCase {
    func testRecentIsClamped() {
        var msgs: [(agent: String?, text: String)] = (0..<25).map { (agent: $0 % 2 == 0 ? "met" : nil, text: "m\($0) " + String(repeating: "x", count: 500)) }
        msgs.append((agent: "lia", text: "   "))
        let r = Suggest.recent(msgs)
        XCTAssertEqual(r.count, 20)
        XCTAssertTrue((r.first?["text"] as? String)?.hasPrefix("m5 ") ?? false)
        XCTAssertTrue(r.allSatisfy { ($0["text"] as? String)?.count ?? 999 <= 400 })
        XCTAssertNil(r[0]["agent"])
        XCTAssertEqual(r[1]["agent"] as? String, "met")
    }

    func testTasksParse() {
        let long = String(repeating: "a", count: 80)
        let json = #"{"ok":true,"tasks":[{"text":"Pause Spring ad set","agent":"MET"},{"text":"pause spring ad set","agent":"lee"},{"text":"\#(long)"},{"text":""},{"text":"Draft the weekly report","agent":"rep"},{"text":"Fourth","agent":"lia"}]}"#
        let t = Suggest.parseTasks(Data(json.utf8))
        XCTAssertEqual(t.count, 3)
        XCTAssertEqual(t[0], SuggestedTask(text: "Pause Spring ad set", agent: "met"))
        XCTAssertEqual(t[1].text.count, 60)
        XCTAssertEqual(t[1].agent, "lia")
        XCTAssertEqual(t[2].agent, "rep")
        XCTAssertTrue(Suggest.parseTasks(Data(#"{"ok":false,"tasks":[{"text":"x"}]}"#.utf8)).isEmpty)
        XCTAssertTrue(Suggest.parseTasks(Data("nope".utf8)).isEmpty)
    }

    func testGroupsParseAndApply() {
        let json = #"{"ok":true,"groups":[{"name":"Meta Ads Manager Work","icon":"megaphone","tab_ids":["a","b","b"]},{"name":"Solo","icon":"photo","tab_ids":["c"]},{"name":"Shop","tab_ids":["c","d","a"]},{"name":"","tab_ids":["e","f"]}]}"#
        let g = Suggest.parseGroups(Data(json.utf8))
        XCTAssertEqual(g.count, 2)
        XCTAssertEqual(g[0].name, "Meta Ads Manager W")
        XCTAssertEqual(g[0].tabIds, ["a", "b"])
        XCTAssertEqual(g[1].icon, "folder")
        // "b" was closed meanwhile: the first group falls below two and goes; "a" is free again for the second
        let ok = Suggest.applicable(g, available: ["a", "c", "d"])
        XCTAssertEqual(ok.map(\.name), ["Shop"])
        XCTAssertEqual(ok[0].tabIds, ["c", "d", "a"])
        // a tab joins one group only
        let both = Suggest.applicable(g, available: ["a", "b", "c", "d"])
        XCTAssertEqual(both.map(\.tabIds), [["a", "b"], ["c", "d"]])
    }

    /// An empty answer or a failed call keeps the chips on screen; a non-empty one replaces them.
    func testEmptyAnswerKeepsShownTasks() {
        let shown = [SuggestedTask(text: "Check CPL", agent: "lia"), SuggestedTask(text: "New banners", agent: "crea")]
        XCTAssertEqual(Suggest.kept(shown: shown, answer: []), shown)
        XCTAssertEqual(Suggest.kept(shown: shown, answer: nil), shown)
        let one = [SuggestedTask(text: "Leads today", agent: "met")]
        XCTAssertEqual(Suggest.kept(shown: shown, answer: one), one)
        XCTAssertEqual(Suggest.kept(shown: [], answer: []), [])
    }

    func testKeptRoundTripAndKey() {
        let l = [SuggestedTask(text: "a", agent: "lia"), SuggestedTask(text: "b", agent: "met"),
                 SuggestedTask(text: "c", agent: "lia"), SuggestedTask(text: "d", agent: "lia")]
        let d = try? JSONEncoder().encode(l)
        XCTAssertEqual(Suggest.decodeKept(d)?.map(\.text), ["a", "b", "c"])
        XCTAssertNil(Suggest.decodeKept(try? JSONEncoder().encode([SuggestedTask]())))
        XCTAssertNil(Suggest.decodeKept(Data("x".utf8)))
        XCTAssertNil(Suggest.decodeKept(nil))
        let k = Suggest.keptKey(profile: "p1", member: "m1")
        XCTAssertTrue(k.hasPrefix("lia_ws_"))
        XCTAssertTrue(k.contains("p1|"))
    }
}
