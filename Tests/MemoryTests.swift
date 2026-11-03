import XCTest
import Foundation
#if canImport(Liaison)
@testable import Liaison
#endif

// Lia's memory: the chat line built from memory_saved blocks, and the Settings book.
final class MemoryTests: XCTestCase {
    private func block(_ s: String) -> ChatBlock {
        ChatBlock(tool: "save_memory", data: JSONRead.object(Data(s.utf8)))
    }

    func testChatLineFacts() {
        let a = block(#"{"kind":"memory_saved","text":"Leads cost up to EUR 8","scope":"account","section":"goals","account":"123","account_name":"Acme Studio Two"}"#)
        let b = block(#"{"kind":"memory_saved","text":"Runs ads since 2019","scope":"you","section":"experience","replaced":"older"}"#)
        let c = block(#"{"kind":"memory_saved","text":"Sells mats","scope":"account","section":"weird","account":"9"}"#)
        let plot = ChatBlock(tool: "x", kind: "plot", url: "/p", type: nil, filename: nil, bytes: nil)
        let items = MemorySaved.items([plot, a, b, c])
        XCTAssertEqual(items.map(\.text), ["Leads cost up to EUR 8", "Runs ads since 2019", "Sells mats"])
        XCTAssertEqual(items[0].whereLine, "Acme Studio Two · Goals")
        XCTAssertEqual(items[1].whereLine, "You · Experience · updated")
        XCTAssertEqual(items[2].whereLine, "Ad account 9 · Memory")
        XCTAssertTrue(a.id != c.id)   // two facts in one turn are two blocks, not one
        XCTAssertNil(MemorySaved.count(1))
        XCTAssertEqual(MemorySaved.count(3), "3")
        XCTAssertNil(MemorySaved(block(#"{"kind":"memory_saved","text":""}"#)))
    }

    func testStreamKeepsEveryFact() {
        var t = LiveTurn()
        t.apply(.block(block(#"{"kind":"memory_saved","text":"One","scope":"you","section":"experience"}"#)))
        t.apply(.block(block(#"{"kind":"memory_saved","text":"Two","scope":"you","section":"experience"}"#)))
        XCTAssertEqual(MemorySaved.items(t.blocks).count, 2)
    }

    private let book = #"""
    {"ok":true,"available":true,"enabled":false,
     "you":{"updated":1760000000000,"items":[{"id":"m1","section":"experience","text":"Ten years of ads","by":"lia","created":1760000000000,"updated":1760000000000}]},
     "accounts":[
      {"account":"123","account_name":"Acme","updated":1760000000000,"items":[{"id":"m2","section":"goals","text":"CPL under 8","by":"you","created":1,"updated":1760000000000},{"id":"m3","section":"offer","text":"Trial lesson","by":"lia","created":1760000000000}]},
      {"account":"456","account_name":null,"updated":1,"items":[]}
     ]}
    """#

    func testBookParsesAndOrdersRows() {
        let b = MemoryBook.parse(Data(book.utf8))!
        XCTAssertTrue(b.available)
        XCTAssertFalse(b.enabled)
        XCTAssertEqual(b.you.items.map(\.id), ["m1"])
        XCTAssertEqual(b.you.name(), "About you")
        XCTAssertEqual(b.you.summary, "Ten years of ads")
        let rows = b.rows(connected: [("789", "Other"), ("123", "Ignored name")])
        XCTAssertEqual(rows.map(\.id), ["123", "456", "789"])
        XCTAssertEqual(rows[0].name(), "Acme")
        XCTAssertEqual(rows[1].name(), "Ad account 456")
        XCTAssertEqual(rows[1].summary, "Nothing saved yet")
        XCTAssertEqual(rows[2].name(), "Other")
        XCTAssertEqual(rows[0].summary, "CPL under 8 · Trial lesson")
        XCTAssertEqual(rows[0].items(in: "goals").map(\.id), ["m2"])
        XCTAssertEqual(rows[0].usedLine(name: "Acme"), "Read in every chat that works in Acme · account 123")
        XCTAssertEqual(b.you.usedLine(name: "About you"), "Read in every chat, before the ad account")
        XCTAssertEqual(rows[0].items[0].subLine.hasPrefix("Edited by you · "), true)
        XCTAssertEqual(rows[0].items[1].subLine.hasPrefix("Saved by Lia from a chat · "), true)
        XCTAssertEqual(rows[0].sections, ["business", "customers", "offer", "goals", "rules", "history"])
        XCTAssertNil(MemoryBook.parse(Data(#"{"ok":false,"error":"unauthorized"}"#.utf8)))
        let missing = MemoryBook.parse(Data(#"{"ok":true}"#.utf8))!
        XCTAssertTrue(missing.enabled)
    }

    func testUpdateReplacesOrInserts() {
        var b = MemoryBook.parse(Data(book.utf8))!
        var s = b.scope("123")!
        s.items.removeAll()
        b.update(s)
        XCTAssertEqual(b.scope("123")?.items.count, 0)
        b.update(MemoryScope(account: "999", accountName: "New", updated: nil, items: []))
        XCTAssertEqual(b.accounts.first?.id, "999")
        XCTAssertEqual(MemoryBook.short(Double(Date(timeIntervalSince1970: 0).timeIntervalSince1970) * 1000 + 86_400_000 * 40).isEmpty, false)
    }
}

// Attachments without lanes.
final class AttachRouteTests: XCTestCase {
    // Every composer file goes to the server; the lane says how.
    func testComposerLanes() {
        XCTAssertEqual(ComposerLane.of(name: "Screenshot 2026-10-20 at 10.00.00.png", bytes: 500_000), .read)
        XCTAssertEqual(ComposerLane.of(name: "report.PDF", bytes: 10), .read)
        // A readable file over 10 MB is stored as it is (the server reads its text)
        XCTAssertEqual(ComposerLane.of(name: "big.pdf", bytes: 11 * 1024 * 1024), .file)
        XCTAssertEqual(ComposerLane.of(name: "IMG_0001.HEIC", bytes: 3_000_000), .readAsPNG)
        XCTAssertEqual(ComposerLane.of(name: "scan.tiff", bytes: 30_000_000), .readAsPNG)
        XCTAssertEqual(ComposerLane.of(name: "clip.mov", bytes: 50_000_000), .storage)
        XCTAssertEqual(ComposerLane.of(name: "long.mp4", bytes: 201 * 1024 * 1024), .refuse("Over 200 MB"))
        // Any file goes to the server (Storage > Uploads), up to 100 MB
        XCTAssertEqual(ComposerLane.of(name: "site.zip", bytes: 10), .file)
        XCTAssertEqual(ComposerLane.of(name: "Makefile", bytes: 10), .file)
    }

    func testComposerDraftFilesRoundTrip() {
        let thumb = Data([1, 2, 3])
        let a = ChatAttachment(key: "ai/m/att/x__shot.png", kind: "image", name: "shot.png", mime: "image/png", bytes: 1234,
                               url: "/intelligence/plot?key=k", preview: thumb)
        let d = ChatAttachment(key: "ai/m/att/y__brief.pdf", kind: "file", name: "brief.pdf", mime: "application/pdf", bytes: 99)
        let m = MediaItem(id: "u/m/clip.mov", source: .upload, name: "clip.mov", preview: nil, seconds: 12.5)
        let entries: [ComposerDraftFiles.Entry] = [.uploaded(a), .uploaded(d), .library(m)]
        let back = ComposerDraftFiles.decode(ComposerDraftFiles.encode(entries))
        XCTAssertEqual(back, entries)
        XCTAssertEqual(ComposerDraftFiles.decode(nil), [])
        XCTAssertEqual(ComposerDraftFiles.decode(Data("[{\"t\":\"att\"},{\"t\":\"lib\",\"id\":\"1\",\"source\":\"nope\"}]".utf8)), [])
    }

    func testRoutes() {
        XCTAssertEqual(AttachRoute.route(name: "a.jpg", mime: "image/jpeg", bytes: 1000), .creativeImage)
        XCTAssertEqual(AttachRoute.route(name: "a.png", mime: "image/png", bytes: 9 * 1024 * 1024), .read)
        XCTAssertEqual(AttachRoute.route(name: "a.webp", mime: "image/webp", bytes: 10), .read)
        XCTAssertEqual(AttachRoute.route(name: "a.gif", mime: "image/gif", bytes: 10), .read)
        XCTAssertEqual(AttachRoute.route(name: "clip.mov", mime: "video/quicktime", bytes: 5_000_000), .creativeVideo)
        XCTAssertEqual(AttachRoute.route(name: "big.mp4", mime: "video/mp4", bytes: 201 * 1024 * 1024),
                       .refuse("Under 200 MB for video in v1 (Meta itself takes up to 4 GB, we will raise this)"))
        XCTAssertEqual(AttachRoute.route(name: "report.pdf", mime: "application/pdf", bytes: 10), .read)
        XCTAssertEqual(AttachRoute.route(name: "data.xlsx", mime: "application/octet-stream", bytes: 10), .read)
        XCTAssertEqual(AttachRoute.route(name: "notes", mime: "text/plain", bytes: 10), .read)
        XCTAssertEqual(AttachRoute.route(name: "song.mp3", mime: "audio/mpeg", bytes: 10),
                       .refuse("Meta accepts JPG, PNG, MP4, MOV. «song.mp3» is none of these"))
        XCTAssertFalse(AttachRoute.isDocument("pdf"))
        XCTAssertEqual(UserText.creativeKeys("look\n\n[attached_creative r2_key=u/a.jpg]\n[attached_creative image_hash=abc]\n[attached_creative r2_key=u/b.png]"),
                       ["u/a.jpg", "abc", "u/b.png"])
    }
}

// The live line (ai.js stOnEvent).
final class LiveStatusTests: XCTestCase {
    func testDwellRotateAndWriting() {
        var s = LiveStatus()
        s.pick = { $0[0] }
        s.on(.reason("x"), thinkTitle: "Reading the account", now: 1000)
        XCTAssertEqual(s.text, "Reading the account")
        s.on(.actStart(id: "1", tool: "get_campaigns", label: ""), thinkTitle: nil, now: 1500)
        XCTAssertEqual(s.text, "Reading the account")          // the thought stands its 1.2 s
        XCTAssertTrue(s.tick(now: 2300))
        let first = ToolPhrases.all["get_campaigns"]![0]
        XCTAssertEqual(s.text, first)
        XCTAssertFalse(s.tick(now: 3000))
        XCTAssertTrue(s.tick(now: 4400))                        // still running after 2.8 s: the next phrasing
        XCTAssertEqual(s.text, ToolPhrases.all["get_campaigns"]![1])
        s.on(.actDone(id: "1"), thinkTitle: nil, now: 4500)
        XCTAssertFalse(s.tick(now: 9000))                       // done: no more rotation
        s.on(.delta("Hi"), thinkTitle: nil, now: 9100)
        XCTAssertEqual(s.text, "Writing the answer")
        s.on(.done(cites: [], ms: nil), thinkTitle: nil, now: 9200)
        s.on(.reason("y"), thinkTitle: "Later", now: 20000)
        XCTAssertEqual(s.text, "Writing the answer")            // stopped
    }

    func testUnknownToolAndWebAndLiveTurn() {
        var s = LiveStatus()
        s.on(.actStart(id: "9", tool: "no_such_tool", label: ""), thinkTitle: nil, now: 0)
        XCTAssertTrue(ToolPhrases.all["_default"]!.contains(s.text))
        var w = LiveStatus()
        w.on(.webStart(query: "ciao"), thinkTitle: nil, now: 0)
        XCTAssertTrue(ToolPhrases.all["web_search"]!.contains(w.text))
        XCTAssertFalse(w.text.contains("ciao"))
        var t = LiveTurn(startedAt: 0)
        t.apply(.reason("**Checking budgets**\n"), now: 10)
        XCTAssertFalse(t.status.text.isEmpty)
        XCTAssertNotNil(ToolPhrases.all["save_memory"])
    }

    func testNoRepeatWithinTurn() {
        var s = LiveStatus()
        var seen: [String] = []
        s.on(.actStart(id: "1", tool: "code", label: ""), thinkTitle: nil, now: 0)
        seen.append(s.text)
        for i in 1...9 { s.tick(now: Double(i) * 2900); seen.append(s.text) }
        XCTAssertEqual(Set(seen).count, 10)
    }
}

// Quick actions (ai.js SLASH_CMDS / barText).
final class QuickActionTests: XCTestCase {
    func testPaletteAndContext() {
        XCTAssertEqual(SlashCommand.matching("").count, 6)
        XCTAssertEqual(SlashCommand.matching("ad").map(\.cmd), ["/adset", "/ad", "/duplicate"])   // "ad set" in the description counts
        XCTAssertEqual(SlashCommand.matching("budget").map(\.cmd), ["/budget"])
        XCTAssertNotNil(SlashCommand.context("/"))
        XCTAssertEqual(SlashCommand.context("please /ru")?.query, "ru")
        XCTAssertEqual(SlashCommand.context("please /ru")?.before, "please")
        XCTAssertNil(SlashCommand.context("a/b"))
        XCTAssertNil(SlashCommand.context("/adset now"))
        XCTAssertNil(SlashCommand.context("nothing"))
    }

    func testSentence() {
        var b = QuickBar(SlashCommand.all.first { $0.cmd == "/adset" }!)
        XCTAssertFalse(b.complete)
        XCTAssertEqual(b.firstOpen, 1)
        b.pick(SlashEntity(id: "42", name: "Milan broad", kind: "ad set", campaign: "Spring", accountName: "Acme",
                           active: true, campaignCBO: false, campaignDailyBudget: nil, campaignCurrency: nil), at: 1, manyAccounts: false)
        b.chips[3]?.value = "Milan v2"
        XCTAssertTrue(b.complete)
        XCTAssertEqual(b.text, "New ad set from template «Milan broad» (id 42) in campaign «Spring», name it Milan v2, budget 10 €/day")
        b.pick(SlashEntity(id: "43", name: "Rome", kind: "ad set", campaign: "CBO one", accountName: "Acme",
                           active: true, campaignCBO: true, campaignDailyBudget: "50", campaignCurrency: "EUR"), at: 1, manyAccounts: true)
        XCTAssertEqual(b.label(5), "CBO 50 EUR/day")
        XCTAssertEqual(b.text, "New ad set from template «Rome» (id 43) in campaign «CBO one» (account «Acme»), name it Milan v2, budget on the campaign (CBO, 50 EUR/day)")
        b.pick(SlashEntity(id: "44", name: "Turin", kind: "ad set", campaign: nil, accountName: nil,
                           active: false, campaignCBO: false, campaignDailyBudget: nil, campaignCurrency: nil), at: 1, manyAccounts: false)
        XCTAssertEqual(b.chips[5]?.value, "10")   // unlocked back to the default
    }

    func testEntitiesParse() {
        let d = #"{"ok":true,"accounts":[{"id":"1"}],"campaigns":[{"id":"c1","name":"Spring","active":true,"account_name":"A"}],"adsets":[{"id":"s1","name":"Milan","campaign":"Spring","campaign_cbo":true,"campaign_daily_budget":"50","campaign_currency":"EUR"}]}"#
        let r = SlashEntity.parse(Data(d.utf8))!
        XCTAssertEqual(r.entities.map(\.kind), ["campaign", "ad set"])
        XCTAssertEqual(r.accounts, 1)
        XCTAssertTrue(r.entities[1].campaignCBO)
        XCTAssertEqual(ModeReply.quote(for: "[quick_action] Activate «X»")?.question, "Quick action")
    }
}
