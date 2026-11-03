import XCTest
import Foundation
@testable import Liaison

/// 0.2.11: Select element on Dev's own sites (Shared/Core/DevPicker.swift, server).
final class DevPickerTests: XCTestCase {
    private func u(_ s: String) -> URL { URL(string: s)! }

    func testWhichPagesAreDevs() {
        XCTAssertEqual(DevPickerHost.kind(u("https://yoga-studio-k7q2.liaisone.com/about")), .site("yoga-studio-k7q2"))
        XCTAssertEqual(DevPickerHost.kind(u("https://pv-abcd1234.liaisone.com/")), .preview)
        XCTAssertNil(DevPickerHost.kind(u("https://shop.liaisone.si/")))   // .app was bought, not .si
        for h in ["app", "api", "lia", "mcp", "www", "ai", "map", "updates", "admin", "preview"] {
            XCTAssertNil(DevPickerHost.kind(u("https://\(h).liaisone.com/")), h)
        }
        XCTAssertNil(DevPickerHost.kind(u("https://liaisone.com/")))
        XCTAssertNil(DevPickerHost.kind(u("https://evilliaisone.com/")))
        XCTAssertNil(DevPickerHost.kind(u("https://a.b.liaisone.com/")))
        XCTAssertNil(DevPickerHost.kind(u("http://yoga.liaisone.com/")))
        XCTAssertNil(DevPickerHost.kind(u("https://pv-a.liaisone.com/")))
        XCTAssertNil(DevPickerHost.kind(u("https://-x.liaisone.com/")))
        XCTAssertNil(DevPickerHost.kind(nil))
        XCTAssertTrue(DevPickerHost.isDevSite(u("https://yoga.liaisone.com/")))
    }

    /// Server: sites and previews on liaisone.app; a page still open on liaisone.com is the same site.
    func testSitesDomainAppAndTheOldOne() {
        XCTAssertEqual(DevPickerHost.primary, "liaisone.app")
        XCTAssertEqual(DevPickerHost.kind(u("https://pizza-roma.liaisone.app/menu")), .site("pizza-roma"))
        XCTAssertEqual(DevPickerHost.kind(u("https://pizza-roma.liaisone.com/menu")), .site("pizza-roma"))
        XCTAssertEqual(DevPickerHost.kind(u("https://pv-abcd1234.liaisone.app/")), .preview)
        XCTAssertEqual(DevPickerHost.kind(host: "PV-abcd1234.Liaisone.App"), .preview)
        for h in ["app", "api", "lia", "mcp", "www", "ai", "map", "browser", "admin", "updates"] {
            XCTAssertNil(DevPickerHost.kind(u("https://\(h).liaisone.app/")), h)
            XCTAssertNil(DevPickerHost.kind(host: "\(h).liaisone.com"), h)
        }
        XCTAssertNil(DevPickerHost.kind(u("https://liaisone.app/")))
        XCTAssertNil(DevPickerHost.kind(u("https://evilliaisone.app/")))
        XCTAssertNil(DevPickerHost.kind(u("https://a.b.liaisone.app/")))
        XCTAssertNil(DevPickerHost.kind(u("http://yoga.liaisone.app/")))
        XCTAssertNil(DevPickerHost.kind(host: nil))
        let mine = ["pizza-roma"]
        XCTAssertTrue(DevPickerHost.allowed(u("https://pizza-roma.liaisone.app/"), sites: mine))
        XCTAssertTrue(DevPickerHost.allowed(u("https://pizza-roma.liaisone.com/"), sites: mine))
        XCTAssertTrue(DevPickerHost.allowed(u("https://pv-abcd1234.liaisone.app/"), sites: nil))
        XCTAssertFalse(DevPickerHost.allowed(u("https://someone-else.liaisone.app/"), sites: mine))
    }

    func testStableClasses() {
        XCTAssertTrue(DevPickSelector.stableClass("hero-title"))
        XCTAssertTrue(DevPickSelector.stableClass("btn_primary"))
        XCTAssertFalse(DevPickSelector.stableClass("active"))
        XCTAssertFalse(DevPickSelector.stableClass("is-open"))
        XCTAssertFalse(DevPickSelector.stableClass("css-1x2y3z"))
        XCTAssertFalse(DevPickSelector.stableClass("title-x7k2q9"))
        XCTAssertFalse(DevPickSelector.stableClass("col123"))
        XCTAssertFalse(DevPickSelector.stableClass("md:flex"))
        XCTAssertFalse(DevPickSelector.stableClass("2col"))
        XCTAssertFalse(DevPickSelector.stableClass(String(repeating: "a", count: 41)))
    }

    func testSelectorFromChain() {
        let chain = [DevPickNode(tag: "h2", classes: ["title", "active", "big"], nth: 1, of: 1),
                     DevPickNode(tag: "section", classes: ["css-9z8y7x"], nth: 2, of: 4),
                     DevPickNode(tag: "main"),
                     DevPickNode(tag: "body")]
        XCTAssertEqual(DevPickSelector.build(chain), "body > main > section:nth-of-type(2) > h2.title.big")
        XCTAssertEqual(DevPickSelector.build(chain, classes: false), "body > main > section:nth-of-type(2) > h2")
        // a unique id ends the walk; a repeated one does not
        let withId = [DevPickNode(tag: "a", nth: 3, of: 3), DevPickNode(tag: "nav", id: "top", idUnique: true), DevPickNode(tag: "body")]
        XCTAssertEqual(DevPickSelector.build(withId), "#top > a:nth-of-type(3)")
        let dup = [DevPickNode(tag: "p"), DevPickNode(tag: "div", id: "x", idUnique: false), DevPickNode(tag: "body")]
        XCTAssertEqual(DevPickSelector.build(dup), "body > div > p")
        // an id we could not write without escaping is not used
        let odd = [DevPickNode(tag: "p", id: "1st", idUnique: true), DevPickNode(tag: "body")]
        XCTAssertEqual(DevPickSelector.build(odd), "body > p")
        XCTAssertNil(DevPickSelector.build([]))
        XCTAssertNil(DevPickSelector.build([DevPickNode(tag: "html")]))
        // what the server accepts: no quotes, brackets or braces
        let s = DevPickSelector.build(chain)!
        XCTAssertFalse(s.contains("[") || s.contains("\"") || s.contains("{"))
    }

    func testNodeFromScript() {
        let n = DevPickNode(["tag": "SECTION", "id": "about", "idUnique": true, "classes": ["a", "b"], "nth": 2, "of": 3])
        XCTAssertEqual(n?.tag, "section")
        XCTAssertEqual(n?.nth, 2)
        XCTAssertTrue(n?.idUnique ?? false)
        XCTAssertNil(DevPickNode(["tag": "x<y"]))
        XCTAssertEqual(DevPickNode(["tag": "p", "nth": 5, "of": 2])?.of, 5)   // of is never under nth
    }

    func testCaps() {
        let s = String(repeating: "\u{00e9}", count: 1500)   // 3000 bytes
        let c = DevPickCaps.cut(s, bytes: DevPickCaps.html)
        XCTAssertTrue(c.utf8.count <= 2048)
        XCTAssertEqual(c.count, 1024)
        XCTAssertEqual(DevPickCaps.cut("<p>x</p>", bytes: 2048), "<p>x</p>")
        XCTAssertEqual(DevPickCaps.squash("  a \n\n b\t c ", 100), "a b c")
    }

    func testLabels() {
        XCTAssertEqual(DevPickLabel.make(tag: "h2", text: "Our lessons"), "h2 \u{00b7} Our lessons")
        XCTAssertEqual(DevPickLabel.make(tag: "a", id: "book", text: "Book now"), "a#book \u{00b7} Book now")
        XCTAssertEqual(DevPickLabel.make(tag: "div", classes: ["active", "card"]), "div.card")
        XCTAssertEqual(DevPickLabel.make(tag: "img"), "img")
        let long = DevPickLabel.make(tag: "p", text: String(repeating: "word ", count: 30))
        XCTAssertTrue(long.hasSuffix("\u{2026}"))
        XCTAssertTrue(long.count <= DevPickCaps.label)
    }

    func testLocatorFromPick() {
        let o: JSONObject = ["tag": "H2", "id": "", "classes": ["title", "x y"], "text": "  Our   lessons ", "fullText": "Our lessons",
                             "textOnly": true, "html": "<h2 class=\"title\">Our lessons</h2>",
                             "page": ["x": 120.4, "y": 840.0, "w": 600.0, "h": 48.0], "viewport": ["x": 0, "y": 0, "w": 1280.0, "h": 800.0]]
        let l = DevPickLocator.make(o, selector: "main > h2.title")!
        XCTAssertEqual(l.tag, "h2")
        XCTAssertEqual(l.text, "Our lessons")
        XCTAssertEqual(l.classes, ["title"])
        XCTAssertEqual(l.label, "h2.title \u{00b7} Our lessons")
        XCTAssertTrue(l.textOnly)
        let j = l.json
        XCTAssertEqual((j["box"] as? JSONObject)?["x"] as? Int, 120)
        XCTAssertEqual((j["viewport"] as? JSONObject)?["w"] as? Int, 1280)
        XCTAssertNil(j["id"])
        XCTAssertNil(DevPickLocator.make(o, selector: ""))
        var long = o; long["fullText"] = String(repeating: "x", count: 700)
        XCTAssertFalse(DevPickLocator.make(long, selector: "p")!.textOnly)   // long text: a comment, not inline
        var big = o; big["html"] = String(repeating: "y", count: 9000)
        XCTAssertEqual(DevPickLocator.make(big, selector: "p")!.html.utf8.count, DevPickCaps.html)
    }

    func testMoveWords() {
        XCTAssertEqual(DevPickMove(dx: 24, dy: 10).words, "Move 24 px right, 10 px down")
        XCTAssertEqual(DevPickMove(dx: -5, dy: 0).words, "Move 5 px left")
        XCTAssertTrue(DevPickMove(dx: 0, dy: 0).isEmpty)
        var t = DevPickLocator(selector: "footer", tag: "footer"); t.label = "footer"
        let m = DevPickMove(dx: 0, dy: 80, place: .after, target: t)
        XCTAssertEqual(m.words, "Move after \u{00ab}footer\u{00bb}")
        XCTAssertEqual(m.json["where"] as? String, "after")
        XCTAssertEqual((m.json["target"] as? JSONObject)?["selector"] as? String, "footer")
        XCTAssertNil(DevPickMove(dx: 3, dy: 0).json["where"])
    }

    func testReorder() {
        let col = (0..<4).map { DevPickReorder.Sibling(index: $0, box: DevPickBox(x: 0, y: Double($0) * 100, w: 300, h: 90)) }
        XCTAssertFalse(DevPickReorder.horizontal(col.map(\.box)))
        // dragged #0 onto the lower half of #2: after #2
        let r = DevPickReorder.decide(drop: CGPoint(x: 50, y: 270), own: col[0], siblings: col)
        XCTAssertEqual(r?.index, 2)
        XCTAssertEqual(r?.place, .after)
        // the upper half of #3: before #3
        XCTAssertEqual(DevPickReorder.decide(drop: CGPoint(x: 50, y: 310), own: col[0], siblings: col)?.place, .before)
        // before the next one / after the previous one: no change
        XCTAssertNil(DevPickReorder.decide(drop: CGPoint(x: 50, y: 110), own: col[0], siblings: col))
        XCTAssertNil(DevPickReorder.decide(drop: CGPoint(x: 50, y: 180), own: col[2], siblings: col))
        // on no sibling: a shift, not a reorder
        XCTAssertNil(DevPickReorder.decide(drop: CGPoint(x: 900, y: 900), own: col[0], siblings: col))
        // a row of cards: left/right decides
        let row = (0..<3).map { DevPickReorder.Sibling(index: $0, box: DevPickBox(x: Double($0) * 200, y: 0, w: 180, h: 300)) }
        XCTAssertTrue(DevPickReorder.horizontal(row.map(\.box)))
        let rr = DevPickReorder.decide(drop: CGPoint(x: 420, y: 150), own: row[0], siblings: row)
        XCTAssertEqual(rr?.index, 2)
        XCTAssertEqual(rr?.place, .before)
        XCTAssertNil(DevPickReorder.decide(drop: CGPoint(x: 10, y: 10), own: row[0], siblings: [row[0]]))
    }

    func testDraftBody() {
        var l = DevPickLocator(selector: "h2", tag: "h2"); l.text = "Our lessons"
        var d = DevEditDraft(url: u("https://yoga.liaisone.com/"), locator: l)
        XCTAssertFalse(d.canSend)
        d.textFrom = "Our lessons"; d.textTo = "Our lessons"
        XCTAssertFalse(d.canSend)   // the same text is no edit
        d.textTo = "   "
        XCTAssertFalse(d.canSend)
        d.textTo = "Our courses"
        XCTAssertTrue(d.canSend)
        d.comment = "  bolder  "
        d.move = DevPickMove(dx: 0, dy: 0)
        let b = d.body(profile: "p1")
        XCTAssertEqual(b["profile"] as? String, "p1")
        XCTAssertEqual(b["comment"] as? String, "bolder")
        XCTAssertEqual((b["text"] as? JSONObject)?["to"] as? String, "Our courses")
        XCTAssertNil(b["move"])   // an empty move is not sent
        d.comment = String(repeating: "c", count: 5000)
        XCTAssertEqual((d.body(profile: "p1")["comment"] as? String)?.count, DevPickCaps.comment)
        var m = DevEditDraft(url: u("https://yoga.liaisone.com/"), locator: l)
        m.move = DevPickMove(dx: 12, dy: 0)
        XCTAssertTrue(m.canSend)
    }

    func testTasksAndStream() {
        let list = """
        {"ok":true,"tasks":[{"id":"abc123","site":"yoga","status":"running","summary":"text · h2","label":"h2","url":"https://yoga.liaisone.com/","at":5},
        {"id":"def456","site":"preview","status":"failed","url":"https://evil.example.com/","at":3},{"site":"x"}]}
        """
        let t = DevEditTask.parseList(Data(list.utf8))!
        XCTAssertEqual(t.count, 2)
        XCTAssertEqual(t[0].status, .running)
        XCTAssertFalse(t[0].canRun)
        XCTAssertTrue(t[1].canRun)
        XCTAssertNil(t[1].url)   // not Dev's site: never kept
        XCTAssertNil(DevEditTask.parseList(Data("{\"ok\":false}".utf8)))

        let q = DevEditReply.parse(Data("{\"ok\":true,\"queued\":true,\"task\":{\"id\":\"abc123\",\"site\":\"yoga\",\"status\":\"queued\"},\"message\":\"Dev is busy\"}".utf8))
        XCTAssertTrue(q.queued)
        XCTAssertEqual(q.task?.status, .queued)
        XCTAssertEqual(DevEditReply.parse(Data("{\"ok\":false,\"error\":\"This is not one of Dev's sites.\"}".utf8)).message, "This is not one of Dev's sites.")

        XCTAssertEqual(DevEditStream.parse("data:{\"type\":\"dev_edit\",\"task\":{\"id\":\"abc123\",\"site\":\"yoga\",\"status\":\"running\"}}"),
                       .task(DevEditTask(["id": "abc123", "site": "yoga", "status": "running"])!))
        XCTAssertEqual(DevEditStream.parse("data:{\"type\":\"dev_status\",\"text\":\"Editing files\"}"), .dev(.status("Editing files")))
        XCTAssertEqual(DevEditStream.parse("data:{\"type\":\"done\"}"), .done)
        XCTAssertEqual(DevEditStream.parse("data:{\"type\":\"error\",\"message\":\"x\"}"), .error("x"))
        XCTAssertEqual(DevEditStream.parse("data:{\"type\":\"msg\",\"message\":{\"id\":\"m1\",\"text\":\"Changed it\"}}"), .message(id: "m1", text: "Changed it"))
        XCTAssertNil(DevEditStream.parse("event: x"))
    }

    func testCardPlacement() {
        let b = CGSize(width: 800, height: 600), card = CGSize(width: 300, height: 200)
        XCTAssertEqual(DevPickGeometry.cardOrigin(element: CGRect(x: 100, y: 100, width: 200, height: 40), card: card, in: b), CGPoint(x: 100, y: 148))
        // no room below: above
        XCTAssertEqual(DevPickGeometry.cardOrigin(element: CGRect(x: 100, y: 500, width: 200, height: 40), card: card, in: b), CGPoint(x: 100, y: 292))
        // at the right edge: kept inside
        XCTAssertEqual(DevPickGeometry.cardOrigin(element: CGRect(x: 700, y: 100, width: 80, height: 40), card: card, in: b).x, 492)
        // a tall element with no room either side: inside the view
        let tall = DevPickGeometry.cardOrigin(element: CGRect(x: 0, y: 50, width: 800, height: 540), card: card, in: b)
        XCTAssertTrue(tall.y >= 8 && tall.y + card.height <= b.height - 8)
        XCTAssertEqual(DevPickGeometry.css(CGPoint(x: 100, y: 50), zoom: 2), CGPoint(x: 50, y: 25))
        XCTAssertEqual(DevPickGeometry.rect(DevPickBox(x: 10, y: 20, w: 30, h: 40), zoom: 1), CGRect(x: 10, y: 20, width: 30, height: 40))
    }

    /// Select element on the preview and this workspace's sites only, never on another site.
    func testOfferedOnlyOnDevsOwnPages() {
        let mine = ["yoga-studio", "pizza-roma"]
        XCTAssertTrue(DevPickerHost.allowed(u("https://pv-b0123abcd-1a2b-0123456789abcdef01234567.liaisone.com/"), sites: nil))
        XCTAssertTrue(DevPickerHost.allowed(u("https://pizza-roma.liaisone.com/menu"), sites: mine))
        // another site on our domain: not this workspace's
        XCTAssertFalse(DevPickerHost.allowed(u("https://someone-else.liaisone.com/"), sites: mine))
        // the list not read yet: not offered (it is read, then offered)
        XCTAssertFalse(DevPickerHost.allowed(u("https://pizza-roma.liaisone.com/"), sites: nil))
        XCTAssertFalse(DevPickerHost.allowed(u("https://pizza-roma.liaisone.com/"), sites: []))
        // never anything else
        XCTAssertFalse(DevPickerHost.allowed(u("https://www.google.com/"), sites: mine))
        XCTAssertFalse(DevPickerHost.allowed(u("https://app.liaisone.com/"), sites: ["app"]))
        XCTAssertFalse(DevPickerHost.allowed(u("http://pizza-roma.liaisone.com/"), sites: mine))
        XCTAssertFalse(DevPickerHost.allowed(nil, sites: mine))
    }

    func testRightClickMenu() {
        let off = DevPickMenu.items(selecting: false)
        XCTAssertEqual(off, [.intent(.comment), .intent(.text), .intent(.move), .separator, .toggle("Select Element")])
        XCTAssertEqual(DevPickMenu.items(selecting: true).last, .toggle("Stop Selecting"))
        XCTAssertEqual(DevPickMenu.title(.comment), "Comment on This Element\u{2026}")
        XCTAssertEqual(DevPickMenu.title(.text), "Edit This Text\u{2026}")
        XCTAssertEqual(DevPickMenu.title(.move), "Move This Element\u{2026}")
        // the pointer in the web view's own coordinates -> top-left origin, as the picker draws
        XCTAssertEqual(DevPickMenu.topLeft(CGPoint(x: 10, y: 30), height: 400, flipped: true), CGPoint(x: 10, y: 30))
        XCTAssertEqual(DevPickMenu.topLeft(CGPoint(x: 10, y: 30), height: 400, flipped: false), CGPoint(x: 10, y: 370))
    }

    /// Update says it replaces the live site; a new address says the live one stays.
    func testPublishWording() {
        let r = DevPublishAsk.replace(host: "pizza-roma.liaisone.com")
        XCTAssertEqual(r.title, "Replace the live site?")
        XCTAssertTrue(r.text.contains("pizza-roma.liaisone.com"))
        XCTAssertTrue(r.text.contains("replaced"))
        XCTAssertEqual(r.button, "Replace Live Site")
        let f = DevPublishAsk.fresh(next: "pizza-roma-yoga-studio.liaisone.com", keeps: "pizza-roma.liaisone.com")
        XCTAssertEqual(f.title, "Publish to a new address?")
        XCTAssertTrue(f.text.hasPrefix("It goes live at pizza-roma-yoga-studio.liaisone.com"))
        XCTAssertTrue(f.text.contains("pizza-roma.liaisone.com stays exactly as it is"))
        XCTAssertTrue(DevPublishAsk.fresh(next: nil, keeps: "x.liaisone.com").text.hasPrefix("It goes live at a new address"))
    }

    /// After a new-address publish the newest site of the folder is Live; the older one is a sibling.
    func testLiveAfterNewAddress() {
        let json = "{\"ok\":true,\"sites\":[{\"slug\":\"pizza-roma-yoga-studio\",\"url\":\"https://pizza-roma-yoga-studio.liaisone.com/\",\"dir\":\"menu\"},{\"slug\":\"pizza-roma\",\"url\":\"https://pizza-roma.liaisone.com/\",\"dir\":\"menu\"},{\"slug\":\"other\",\"url\":\"https://other.liaisone.com/\",\"dir\":\"\"}],\"next\":{\"slug\":\"pizza-roma-alex\",\"url\":\"https://pizza-roma-alex.liaisone.com/\"},\"preview\":{\"kind\":\"static\",\"dir\":\"menu\"}}"
        guard case .success(let s) = DevSites.parse(Data(json.utf8)) else { return XCTFail("parse") }
        XCTAssertEqual(s.live?.slug, "pizza-roma-yoga-studio")
        XCTAssertEqual(s.siblings.map(\.slug), ["pizza-roma"])
        XCTAssertEqual(s.next?.slug, "pizza-roma-alex")
        XCTAssertTrue(s.canPublish)
    }
}
