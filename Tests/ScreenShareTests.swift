import XCTest
import Foundation
@testable import Liaison

/// Server: what every agent sees of the person's screen (Shared/Core/ScreenShare.swift) - the compact snapshot,
/// its cleaning and caps, the per-workspace switch, the `screen_look` line and the `[screen_result]` answer.
final class ScreenShareTests: XCTestCase {
    private func tab(_ id: String, active: Bool = false, url: String = "https://example.com/p", text: String = "", sel: String = "") -> ScreenShare.Tab {
        ScreenShare.Tab(id: id, title: "Title " + id, url: url, active: active, text: text, selection: sel)
    }

    func testFrontTabCarriesTextOthersOnlyNames() {
        let p = ScreenShare.payload([tab("a", text: "other page"), tab("b", active: true, text: "Front page text", sel: "picked")], shared: true, canLook: true)
        let tabs = p["tabs"] as? [[String: Any]] ?? []
        XCTAssertEqual(tabs.count, 2)
        // The front tab goes first
        XCTAssertEqual(tabs[0]["text"] as? String, "Front page text")
        XCTAssertEqual(tabs[0]["selection"] as? String, "picked")
        XCTAssertEqual(tabs[1]["text"] as? String, "")
        XCTAssertNil(tabs[1]["selection"])
        XCTAssertEqual(p["look"] as? Bool, true)
        XCTAssertEqual(p["available"] as? Bool, true)
        XCTAssertNil(p["hidden"])
    }

    /// 0.2.11: a tab the person stopped sharing with the conversation goes not even by name; with the front one
    /// gone nothing is in front and no picture can be asked for.
    func testUnsharedTabIsLeftOut() {
        let tabs = ScreenShare.unshared([tab("a"), tab("b", active: true, text: "secret")], hidden: ["b"])
        XCTAssertEqual(tabs.map(\.id), ["a"])
        let p = ScreenShare.payload(tabs, shared: true, canLook: true)
        XCTAssertEqual(p["look"] as? Bool, false)
        XCTAssertNil(ScreenShare.seen(p))
        XCTAssertEqual(ScreenShare.unshared([tab("a")], hidden: []).count, 1)
    }

    func testCaps() {
        let long = String(repeating: "word ", count: 5000)
        let p = ScreenShare.payload([tab("a", active: true, text: long, sel: String(repeating: "s", count: 5000))] + (0..<20).map { tab("t\($0)") },
                                    shared: true, canLook: false)
        let tabs = p["tabs"] as? [[String: Any]] ?? []
        XCTAssertEqual(tabs.count, ScreenShare.maxTabs)
        XCTAssertTrue((tabs[0]["text"] as? String ?? "").count <= ScreenShare.frontText)
        XCTAssertTrue((tabs[0]["text"] as? String ?? "").count > ScreenShare.frontText - 10)
        XCTAssertEqual((tabs[0]["selection"] as? String ?? "").count, ScreenShare.selectionCap)
        XCTAssertEqual(p["look"] as? Bool, false)
    }

    func testSharingOffSendsNothingOfThePage() {
        let p = ScreenShare.payload([tab("a", active: true, text: "bank balance")], shared: false, canLook: true)
        XCTAssertEqual((p["tabs"] as? [Any])?.count, 0)
        XCTAssertEqual(p["hidden"] as? Bool, true)
        XCTAssertEqual(p["look"] as? Bool, false)
        XCTAssertEqual(p["available"] as? Bool, true)
        XCTAssertNil(ScreenShare.seen(p))
    }

    func testNoFrontTabNoPicture() {
        let p = ScreenShare.payload([tab("a"), tab("b", url: "")], shared: true, canLook: true)
        XCTAssertEqual(p["look"] as? Bool, false)
        XCTAssertEqual((p["tabs"] as? [[String: Any]])?.count, 1, "a tab with no address is left out")
    }

    func testCleaning() {
        XCTAssertEqual(ScreenShare.clean("a\u{0007}b\u{200B}c", cap: 100), "abc")
        XCTAssertEqual(ScreenShare.clean("  one   two\t\tthree  ", cap: 100), "one two three")
        XCTAssertEqual(ScreenShare.clean("a\n\n\n\n\nb", cap: 100), "a\n\nb")
        XCTAssertEqual(ScreenShare.clean("line one\nline two", cap: 100, oneLine: true), "line one line two")
        XCTAssertEqual(ScreenShare.clean("abcdef", cap: 3), "abc")
    }

    func testCardNumbersAreMasked() {
        XCTAssertEqual(ScreenShare.maskCards("Card 4242 4242 4242 4242 ok"), "Card [card number hidden] ok")
        XCTAssertEqual(ScreenShare.maskCards("4111-1111-1111-1111"), "[card number hidden]")
        XCTAssertEqual(ScreenShare.maskCards("Order 1234567890123 shipped"), "Order 1234567890123 shipped", "fails Luhn: an order number stays")
        XCTAssertEqual(ScreenShare.maskCards("Phone +39 333 123 4567, spend 1,204"), "Phone +39 333 123 4567, spend 1,204")
        XCTAssertEqual(ScreenShare.maskCards("id4242424242424242"), "id4242424242424242", "glued to a word: an id, not a card")
        XCTAssertTrue(ScreenShare.clean("pay 4242424242424242 now", cap: 100).contains("[card number hidden]"))
        XCTAssertTrue(ScreenShare.luhn([4, 2, 4, 2, 4, 2, 4, 2, 4, 2, 4, 2, 4, 2, 4, 2]))
        XCTAssertFalse(ScreenShare.luhn([1, 2, 3, 4]))
    }

    func testSeen() {
        let p = ScreenShare.payload([tab("a", active: true, url: "https://www.adsmanager.example/x?y=1", text: "t")], shared: true, canLook: true)
        XCTAssertEqual(ScreenShare.seen(p), ScreenShare.Seen(title: "Title a", host: "adsmanager.example", id: "a", url: "https://www.adsmanager.example/x?y=1"))
        XCTAssertNil(ScreenShare.seen(nil))
        XCTAssertNil(ScreenShare.seen(ScreenShare.payload([tab("a")], shared: true, canLook: true)))
    }

    // MARK: the tab in front (incident: no tab marked front, the model took the first listed one)

    private func ids(_ p: [String: Any]) -> [String] { (p["tabs"] as? [[String: Any]] ?? []).map { $0["id"] as? String ?? "" } }
    private func actives(_ p: [String: Any]) -> [String] {
        (p["tabs"] as? [[String: Any]] ?? []).filter { ($0["active"] as? Bool) == true }.map { $0["id"] as? String ?? "" }
    }

    func testFrontTabGoesFirst() {
        let p = ScreenShare.payload([tab("pin"), tab("b"), tab("front", active: true, text: "here")], shared: true, canLook: true)
        XCTAssertEqual(ids(p), ["front", "pin", "b"])
        XCTAssertEqual(actives(p), ["front"])
        XCTAssertEqual(p["look"] as? Bool, true)
        XCTAssertEqual(ScreenShare.seen(p)?.id, "front")
    }

    func testCapNeverDropsTheFrontTab() {
        // The tab in front sits past the 12-tab cut (pinned tabs first): it still goes, first, with its text.
        let tabs = (0..<20).map { tab("t\($0)") } + [tab("front", active: true, url: "https://docs.example.com/d", text: "front text")]
        let p = ScreenShare.payload(tabs, shared: true, canLook: true)
        let list = p["tabs"] as? [[String: Any]] ?? []
        XCTAssertEqual(list.count, ScreenShare.maxTabs, "the cap counts the others: 12 in all")
        XCTAssertEqual(ids(p).first, "front")
        XCTAssertEqual(list.first?["text"] as? String, "front text")
        XCTAssertEqual(Array(ids(p).dropFirst()), (0..<(ScreenShare.maxTabs - 1)).map { "t\($0)" }, "the others keep their order")
        XCTAssertEqual(p["look"] as? Bool, true)
        XCTAssertEqual(ScreenShare.seen(p)?.host, "docs.example.com")
    }

    func testUnloadedFrontIsStillFront() {
        // A new tab page or a tab still restoring: no address and no text, but it is what the person looks at.
        let p = ScreenShare.payload([tab("chatgpt", url: "https://chatgpt.com/"), ScreenShare.Tab(id: "new", title: "New Tab", url: "", active: true)],
                                    shared: true, canLook: false)
        XCTAssertEqual(ids(p), ["new", "chatgpt"])
        XCTAssertEqual(actives(p), ["new"])
        XCTAssertEqual(p["look"] as? Bool, false, "no page, no picture")
        XCTAssertEqual(ScreenShare.seen(p)?.title, "New Tab")
        let asleep = ScreenShare.payload([tab("pin"), ScreenShare.Tab(id: "z", title: "Report", url: "https://r.example/q", active: true)], shared: true, canLook: false)
        XCTAssertEqual(actives(asleep), ["z"], "an unloaded front tab is marked front with its address")
        XCTAssertEqual(ids(asleep).first, "z")
    }

    func testPrivateTabsAreNeverSent() {
        var priv = tab("priv", active: true, url: "https://bank.example/", text: "balance")
        priv.isPrivate = true
        var other = tab("priv2", url: "https://mail.example/")
        other.isPrivate = true
        let p = ScreenShare.payload([tab("a"), priv, other], shared: true, canLook: true)
        XCTAssertEqual(ids(p), ["a"])
        XCTAssertEqual(actives(p), [], "a private tab in front is not sent, and no other tab is made front")
        XCTAssertEqual(p["look"] as? Bool, false)
    }

    func testOnlyOneFrontTab() {
        let p = ScreenShare.payload([tab("a", active: true, text: "A"), tab("b", active: true, text: "B")], shared: true, canLook: true)
        XCTAssertEqual(actives(p), ["a"])
        XCTAssertEqual((p["tabs"] as? [[String: Any]])?.last?["text"] as? String, "")
    }

    func testFrontIDOrder() {
        let all = ["pin", "a", "b", "c"]
        XCTAssertEqual(ScreenShare.frontID(peek: true, focused: "b", panes: ["a", "b"], selected: "a", tabs: all), ScreenShare.peekID, "Peek over the page wins")
        XCTAssertEqual(ScreenShare.frontID(peek: false, focused: "b", panes: ["a", "b"], selected: "a", tabs: all), "b", "the focused pane of a split")
        XCTAssertEqual(ScreenShare.frontID(peek: false, focused: "c", panes: ["a", "b"], selected: "a", tabs: all), "a", "focus outside the panes is ignored")
        XCTAssertEqual(ScreenShare.frontID(peek: false, focused: nil, panes: ["a"], selected: "a", tabs: all), "a")
        XCTAssertEqual(ScreenShare.frontID(peek: false, focused: nil, panes: [], selected: "gone", tabs: all), "pin", "the stage shows the first tab")
        XCTAssertNil(ScreenShare.frontID(peek: false, focused: nil, panes: [], selected: nil, tabs: []))
    }

    func testAlwaysOnNoSetting() {
        // 0.2.11: no switch; an old "off" stored by 0.2.10 does not turn it off.
        let key = "lia_screen_share_p-old-off"
        UserDefaults.standard.set(false, forKey: key)
        defer { UserDefaults.standard.removeObject(forKey: key) }
        XCTAssertTrue(ScreenShare.isOn(profile: "p-old-off"))
        XCTAssertTrue(ScreenShare.isOn(profile: "p2"))
    }

    func testShotSize() {
        XCTAssertTrue(ScreenShare.shotSize(width: 2560, height: 1600) == (1280, 800))
        XCTAssertTrue(ScreenShare.shotSize(width: 900, height: 3000) == (384, 1280))
        XCTAssertTrue(ScreenShare.shotSize(width: 800, height: 600) == (800, 600), "never upscaled")
        XCTAssertTrue(ScreenShare.shotSize(width: 0, height: 600) == (1, 1))
    }

    func testResultMessage() {
        let ok = ScreenShare.result(ok: true, look: "r:1", title: "Sales", url: "https://x.example", why: "ignored")
        XCTAssertTrue(ok.hasPrefix("[screen_result] {"))
        let o = JSONRead.object(Data(ok.dropFirst(ScreenShare.tag.count + 1).utf8))
        XCTAssertNotNil(o)
        XCTAssertEqual(JSONRead.bool(o, "ok"), true)
        XCTAssertEqual(JSONRead.string(o, "title"), "Sales")
        XCTAssertNil(JSONRead.string(o, "why"))
        let no = ScreenShare.result(ok: false, look: "r:1", title: "Bank", url: "https://bank.example", why: "a payment field is on the screen")
        let n = JSONRead.object(Data(no.dropFirst(ScreenShare.tag.count + 1).utf8))
        XCTAssertNotNil(n)
        XCTAssertEqual(JSONRead.bool(n, "ok"), false)
        XCTAssertNil(JSONRead.string(n, "title"), "a refused picture names no page")
        XCTAssertEqual(JSONRead.string(n, "why"), "a payment field is on the screen")
    }

    func testScreenLookLine() {
        let l = ScreenLook.parse(line: #"data:{"type":"screen_look","id":"a3","look":"req:a3","tab":"t1","agent":"crea","dlg":"crea"}"#)
        XCTAssertEqual(l, ScreenLook(id: "a3", look: "req:a3", tab: "t1", agent: "crea"))
        XCTAssertEqual(ScreenLook.parse(line: #"{"type":"screen_look","id":"d4"}"#)?.look, "d4", "Dev's line: the id stands for the look")
        XCTAssertNil(ScreenLook.parse(line: #"data:{"type":"browser_task","id":"a3"}"#))
        XCTAssertNil(ScreenLook.parse(line: #"data:{"type":"screen_look"}"#))
    }

    func testTheAnswerIsAMachineMessage() {
        XCTAssertTrue(AgentOf.isMachine(ChatMessage(role: .user, content: ScreenShare.result(ok: false, look: "x"))))
    }
}
