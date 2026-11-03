import XCTest
import Foundation
@testable import Liaison

/// Dev (behind a server flag): its roster entry, its preview block from the stream and from a stored message, its
/// tools' labels and phrasings.
final class DevAgentTests: XCTestCase {
    func testRosterKeepsDevInServerOrderAndFallbackHasNoDev() {
        let json = ##"{"ok":true,"agents":[{"id":"lia","name":"Lia","role":"Orchestrator","shape":"ring","color":"#1F2430","lead":true},{"id":"dev","name":"Dev","role":"Developer","shape":"code","color":"#0891B2","bio":"Builds your site and shows it to you.","browser":true,"write":false,"lead":false,"on_call":false,"writes_first":false,"soon":false},{"id":"met","name":"Met","role":"Meta Ads","shape":"square","color":"#0866FF","write":true}]}"##
        let r = AgentInfo.parseRoster(Data(json.utf8))
        XCTAssertEqual(r?.map(\.id), ["lia", "dev", "met"])
        let dev = r?[1]
        XCTAssertEqual(dev?.shape, .code)
        XCTAssertEqual(dev?.colorHex, 0x0891B2)
        XCTAssertEqual(dev?.write, false)
        XCTAssertEqual(dev?.soon, false)
        XCTAssertEqual(dev?.bio, "Builds your site and shows it to you.")
        XCTAssertFalse(AgentInfo.fallback.contains { $0.id == "dev" })
    }

    /// Lee is retired and Dev takes its look; the server's roster sends Dev with Lee's colour and
    /// shape and no Lee at all. Nothing named Lee is left in the app's own lists, and Dev never shows as an empty slot.
    func testDevTakesLeesLookAndLeeIsGone() {
        let json = ##"{"ok":true,"agents":[{"id":"lia","name":"Lia","role":"Orchestrator","shape":"ring","color":"#1F2430","lead":true},{"id":"dev","name":"Dev","role":"Developer","shape":"triangle","color":"#F0533E","bio":"Builds your site and shows it to you."},{"id":"met","name":"Met","role":"Meta Ads","shape":"square","color":"#0866FF","write":true},{"id":"rep","name":"Rep","role":"Reports","shape":"hexagon","color":"#7B4DDB"}]}"##
        let r = AgentInfo.parseRoster(Data(json.utf8)) ?? []
        XCTAssertEqual(r.map(\.id), ["lia", "dev", "met", "rep"])
        XCTAssertEqual(r[1].shape, .triangle)
        XCTAssertEqual(r[1].colorHex, 0xF0533E)
        XCTAssertNil(AgentInfo.lookup("lee", in: r))
        XCTAssertFalse(AgentInfo.fallback.contains { $0.id == "lee" })
        // Dev is known even where the roster has not arrived (Settings without a workspace): Lee's colour and shape.
        let dev = AgentInfo.lookup("dev", in: [])
        XCTAssertEqual(dev?.name, "Dev")
        XCTAssertEqual(dev?.colorHex, 0xF0533E)
        XCTAssertEqual(dev?.shape, .triangle)
        XCTAssertEqual(DlgOrigin.displayName("dev"), "Dev")
        XCTAssertEqual(DlgOrigin.displayName("lee"), "Lee")   // an old mark still reads as a name
    }

    /// Settings › Usage: every row the server sends is drawn (Dev counted), in its order; Giggs (soon) is left out,
    /// an unknown id still gets a row, a repeated id one row.
    func testUsageRowsIncludeDevWithoutAHardcodedList() {
        let json = ##"{"ok":true,"session":{"pct":12,"resets":null,"agents":[]},"week":{"pct":30.5,"resets":1760000000000,"agents":[{"id":"lia","pct":10},{"id":"dev","pct":14.5},{"id":"met","pct":6},{"id":"giggs","pct":0},{"id":"newbie","pct":1},{"id":"dev","pct":3}]}}"##
        guard let u = AgentUsage.parse(Data(json.utf8)) else { return XCTFail("no usage") }
        let rows = AgentUsage.rows(u.week, roster: AgentInfo.fallback)
        XCTAssertEqual(rows.map(\.agent.id), ["lia", "dev", "met", "newbie"])
        XCTAssertEqual(rows[1].pct, 14.5)
        XCTAssertEqual(rows[1].agent.colorHex, 0xF0533E)
        XCTAssertEqual(rows[3].agent.name, "Newbie")
        let served = AgentInfo.parseRoster(Data(##"{"ok":true,"agents":[{"id":"dev","name":"Dev","role":"Developer","shape":"triangle","color":"#F0533E"}]}"##.utf8)) ?? []
        XCTAssertEqual(AgentUsage.rows(u.week, roster: served)[1].agent.role, "Developer")
    }

    func testPreviewBlockFromStreamAndStoredMessage() {
        let line = #"data:{"type":"block","id":"b1","tool":"dev_preview","data":{"kind":"dev_preview","url":"https://abc.dev.liaisone.com/contact/","title":"Preview"},"agent":"dev"}"#
        guard case .block(let b)? = ChatEvent.parse(line: line) else { return XCTFail("no block") }
        let p = DevPreview(b)
        XCTAssertEqual(p?.url.absoluteString, "https://abc.dev.liaisone.com/contact/")
        XCTAssertEqual(p?.title, "Preview")
        XCTAssertEqual(p?.shortAddress, "abc.dev.liaisone.com/contact")

        let stored: JSONObject = ["id": "m1", "seq": 3, "role": "assistant", "agent": "dev", "text": "Here it is.",
                                  "blocks": [["tool": "dev_preview", "data": ["kind": "dev_preview", "url": "https://x.example.com", "title": ""]]]]
        let m = DlgMessage(json: stored)
        XCTAssertEqual(m?.blocks.count, 1)
        let q = m.flatMap { DevPreview($0.blocks[0]) }
        XCTAssertEqual(q?.title, "Preview")
        XCTAssertEqual(q?.shortAddress, "x.example.com")
    }

    func testPreviewRefusesOtherKindsAndBadAddresses() {
        XCTAssertNil(DevPreview(ChatBlock(tool: "plot", data: ["kind": "plot", "url": "https://a.com"])))
        XCTAssertNil(DevPreview(ChatBlock(tool: "dev_preview", data: ["kind": "dev_preview", "url": "javascript:alert(1)"])))
        XCTAssertNil(DevPreview(ChatBlock(tool: "dev_preview", data: ["kind": "dev_preview", "url": "/relative/path"])))
        XCTAssertNil(DevPreview(ChatBlock(tool: "dev_preview", data: ["kind": "dev_preview"])))
        XCTAssertEqual(DevPreview(ChatBlock(tool: "dev_preview", data: ["kind": "dev_preview", "url": "http://localhost:5173/"]))?.shortAddress, "localhost:5173")
    }

    func testToolLabelsAndPhrases() {
        guard case let .actStart(_, tool, label, _, _)? = ChatEvent.parse(line: #"data:{"type":"act_start","id":"c1","tool":"write_file"}"#) else {
            return XCTFail("no act_start")
        }
        XCTAssertEqual(tool, "write_file")
        XCTAssertEqual(label, "Edit file")
        guard case let .actStart(_, _, served, _, _)? = ChatEvent.parse(line: #"data:{"type":"act_start","id":"c2","tool":"run","label":"npm install"}"#) else {
            return XCTFail("no act_start")
        }
        XCTAssertEqual(served, "npm install")   // the server's label wins
        for t in ["run", "write_file", "read_file", "list_files", "start_preview", "check_preview"] {
            XCTAssertNotNil(DevToolPhrases.labels[t])
            XCTAssertEqual(ToolPhrases.title(t), DevToolPhrases.all[t]?.first)
        }
        XCTAssertEqual(ToolPhrases.title("web_search"), ToolPhrases.all["web_search"]?.first)
    }

    /// Marketing's own bar beside the whole, and the month.
    func testUsageMarketingAndMonth() {
        let json = #"{"ok":true,"session":{"pct":31.3,"mkt_pct":80,"resets":1792120700786,"agents":[]},"week":{"pct":1.6,"mkt_pct":1.7,"agents":[{"id":"dev","pct":1}]},"month":{"pct":10.8,"mkt_pct":32,"resets":1793491200000}}"#
        guard let u = AgentUsage.parse(Data(json.utf8)) else { return XCTFail("no usage") }
        XCTAssertEqual(u.session.pct, 31.3)
        XCTAssertEqual(u.session.mktPct, 80)
        XCTAssertEqual(u.week.mktPct, 1.7)
        XCTAssertEqual(u.month?.pct, 10.8)
        XCTAssertEqual(u.month?.mktPct, 32)
        let old = AgentUsage.parse(Data(#"{"ok":true,"session":{"pct":5,"agents":[]},"week":{"pct":2,"agents":[]}}"#.utf8))
        XCTAssertNil(old?.session.mktPct)
        XCTAssertNil(old?.month)
    }

    /// Free's session and week have no cap of their own (capped: false): no reset line, "counts toward this
    /// month's limit"; a retired agent with money and the web's Lia are rows, so the rows add up to the bar.
    func testUsageUncappedWindowsAndRowsThatAddUp() {
        let json = ##"{"ok":true,"session":{"pct":84,"resets":1792120700786,"capped":false,"of":"month","agents":[]},"week":{"pct":84,"resets":1792120700786,"capped":false,"of":"month","agents":[{"id":"lia","pct":20},{"id":"met","pct":0},{"id":"crea","pct":40},{"id":"rep","pct":8,"name":"Rep","role":"Reports","retired":true},{"id":"giggs","pct":2,"name":"Giggs","role":"Google Ads","retired":true},{"id":"other","pct":14,"name":"Lia on the web","role":"And spend not tied to an agent","other":true}]}}"##
        guard let u = AgentUsage.parse(Data(json.utf8)) else { return XCTFail("no usage") }
        XCTAssertFalse(u.session.capped)
        XCTAssertEqual(u.session.note(session: true, reset: { _, _ in "Resets in 3 hr 0 min" }), AgentUsage.monthNote)
        XCTAssertEqual(AgentUsage.monthNote, "Counts toward this month\u{2019}s limit")
        XCTAssertTrue(AgentUsage.weekFooter(u.week).contains("this month"))
        let rows = AgentUsage.rows(u.week, roster: AgentInfo.fallback)
        XCTAssertEqual(rows.map(\.agent.id), ["lia", "met", "crea", "rep", "giggs", "other"])
        XCTAssertEqual(rows[3].agent.name, "Rep")
        XCTAssertEqual(rows[5].agent.name, "Lia on the web")
        // Seara's shape, a neutral gray (never her yellow)
        XCTAssertEqual(rows[5].agent.shape, .diamond)
        XCTAssertEqual(rows[5].agent.colorHex, AgentUsage.otherGray)
        XCTAssertTrue(rows[5].agent.colorHex != 0xE8A317)
        XCTAssertTrue(abs(rows.reduce(0) { $0 + $1.pct } - u.week.pct) < 0.2)
        // a server: capped, the reset line as before
        let old = AgentUsage.parse(Data(#"{"ok":true,"session":{"pct":5,"resets":1792120700786,"agents":[]},"week":{"pct":2,"agents":[{"id":"giggs","pct":0}]}}"#.utf8))
        XCTAssertEqual(old?.session.capped, true)
        XCTAssertEqual(old?.session.note(session: true, reset: { _, _ in "Resets in 1 hr 0 min" }), "Resets in 1 hr 0 min")
        XCTAssertTrue(old.map { AgentUsage.rows($0.week, roster: AgentInfo.fallback).isEmpty } ?? false)
    }
}
