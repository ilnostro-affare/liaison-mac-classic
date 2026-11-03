import XCTest
import Foundation
@testable import Liaison

/// The Canvas: an item from Dev's preview block, its state when a page is opened again, and the Code tab's file list.
final class CanvasTests: XCTestCase {
    private func preview(_ url: String, title: String = "Preview") -> ChatBlock {
        ChatBlock(tool: "dev_preview", data: ["kind": "dev_preview", "url": url, "title": title])
    }

    func testItemFromPreviewBlockOnly() {
        let i = CanvasItem(block: preview("https://abc.dev.liaisone.com/", title: "Bakery"), profile: "p1")
        XCTAssertEqual(i?.kind, .devPreview)
        XCTAssertEqual(i?.title, "Bakery")
        XCTAssertEqual(i?.url?.absoluteString, "https://abc.dev.liaisone.com/")
        XCTAssertEqual(i?.profile, "p1")
        XCTAssertEqual(i?.hasCode, true)
        XCTAssertNil(CanvasItem(block: ChatBlock(tool: "plot", data: ["kind": "plot", "url": "https://a.com"]), profile: "p1"))
        XCTAssertEqual(CanvasItem(block: preview("https://a.com"), profile: nil)?.hasCode, false)
    }

    func testOpeningSamePageReloadsAndKeepsTabAndWidth() {
        let a = CanvasItem(block: preview("https://a.dev.liaisone.com/"), profile: "p")!
        let b = CanvasItem(block: preview("https://b.dev.liaisone.com/"), profile: "p")!
        let first = CanvasState.opening(a, over: nil)
        XCTAssertEqual(first.tab, .preview)
        XCTAssertFalse(first.mobile)
        XCTAssertEqual(first.reloads, 0)
        var s = first
        s.tab = .code; s.mobile = true
        let again = CanvasState.opening(a, over: s)
        XCTAssertEqual(again.tab, .code)
        XCTAssertTrue(again.mobile)
        XCTAssertEqual(again.reloads, 1)
        let other = CanvasState.opening(b, over: again)
        XCTAssertEqual(other.item, b)
        XCTAssertEqual(other.tab, .preview)
        XCTAssertTrue(other.mobile)
    }

    func testFileRowsSortIndentAndDirectories() {
        let rows = DevFiles.rows(["index.html", "css/styles.css", "css", "./README.md", "css-old.css", "js/app/main.js", "index.html", "assets/", ""])
        XCTAssertEqual(rows.map(\.path), ["README.md", "assets", "css", "css/styles.css", "css-old.css", "index.html", "js", "js/app", "js/app/main.js"])
        XCTAssertEqual(rows.map(\.depth), [0, 0, 0, 1, 0, 0, 0, 1, 2])
        XCTAssertEqual(rows.filter(\.isDir).map(\.path), ["assets", "css", "js", "js/app"])
        XCTAssertEqual(rows.last?.name, "main.js")
        XCTAssertEqual(DevFiles.firstFile(rows), "index.html")
        XCTAssertEqual(DevFiles.firstFile(DevFiles.rows(["b/x.js", "a.txt"])), "a.txt")
        XCTAssertNil(DevFiles.firstFile(DevFiles.rows(["css/"])))
    }

    func testParseListAndFile() {
        if case .success(let f) = DevFiles.parseList(Data(#"{"ok":true,"path":".","files":["index.html","css"]}"#.utf8)) {
            XCTAssertEqual(f, ["index.html", "css"])
        } else { XCTFail("list") }
        if case .failure(let e) = DevFiles.parseList(Data(#"{"ok":false,"error":"box asleep"}"#.utf8)) {
            XCTAssertEqual(e.message, "box asleep")
        } else { XCTFail("list error") }
        if case .success(let t) = DevFiles.parseFile(Data(#"{"ok":true,"path":"index.html","content":"<h1>Hi</h1>\n"}"#.utf8)) {
            XCTAssertEqual(t, "<h1>Hi</h1>\n")
        } else { XCTFail("file") }
        if case .failure(let e) = DevFiles.parseFile(Data("nope".utf8)) {
            XCTAssertEqual(e.message, "Could not read the file.")
        } else { XCTFail("file error") }
    }

    func testLineNumbers() {
        XCTAssertEqual(DevFiles.lineNumbers(""), "1")
        XCTAssertEqual(DevFiles.lineNumbers("a\nb"), "1\n2")
        XCTAssertEqual(DevFiles.lineNumbers("a\nb\n"), "1\n2")
    }

    func testFocusingAProjectFile() {
        // Nothing open: the project itself, on Code, with the file picked.
        let a = CanvasState.focusing("src/app.js", profile: "p1", over: nil)
        XCTAssertEqual(a.tab, .code)
        XCTAssertEqual(a.focusPath, "src/app.js")
        XCTAssertEqual(a.focusSeq, 1)
        XCTAssertTrue(a.tabs.contains(.code))
        XCTAssertNil(a.item.previewURL)
        // A preview of the same project stays; it turns to Code; the same file again bumps the pick.
        let prev = CanvasState(item: CanvasItem(kind: .devPreview, title: "Preview", url: URL(string: "https://p.liaisone.com/"), profile: "p1"))
        var b = CanvasState.focusing("index.html", profile: "p1", over: prev)
        XCTAssertEqual(b.item.id, prev.item.id)
        XCTAssertEqual(b.tab, .code)
        b = CanvasState.focusing("index.html", profile: "p1", over: b)
        XCTAssertEqual(b.focusSeq, 2)
        // Another workspace's canvas is replaced; the width is kept.
        var other = prev
        other.mobile = true
        let c = CanvasState.focusing("a.css", profile: "p2", over: other)
        XCTAssertEqual(c.item.profile, "p2")
        XCTAssertTrue(c.mobile)
        // Opening an artifact again forgets the pick.
        XCTAssertNil(CanvasState.opening(b.item, over: b).focusPath)
    }

    // Crea's pictures on the board.

    private func crea() -> CreaImages {
        CreaImages(ChatBlock(tool: "crea_images", data: JSONRead.object(Data(#"{"stage":"drafts","images":[{"id":"a","n":1,"url":"/intelligence/plot?key=a"},{"id":"b","n":2,"url":"/intelligence/plot?key=b"},{"id":"c","n":3,"url":"/intelligence/plot?key=c"}]}"#.utf8))))!
    }

    func testImagesItemAndTabs() {
        let board = CreaBoard(images: crea(), selected: "b", chatProfile: "p", chatDlg: "crea")
        XCTAssertEqual(board.selected, "b")
        XCTAssertEqual(board.selectedIndex, 1)
        XCTAssertEqual(board.title, "Drafts")
        XCTAssertTrue(board.canUseDraft)
        XCTAssertFalse(CreaBoard(images: crea(), selected: nil).canUseDraft)
        XCTAssertEqual(CreaBoard(images: crea(), selected: "zz").selected, "a")   // unknown: the first
        XCTAssertFalse(board.isLayered)
        XCTAssertEqual(board.shownNumber(board.pictures[2]), 3)
        XCTAssertEqual(board.useDraftText(board.pictures[1]), "Use draft 2")
        let item = CanvasItem.images(board)
        XCTAssertEqual(item.kind, .images)
        XCTAssertEqual(item.id, "images|a,b,c")
        XCTAssertFalse(item.hasCode)
        XCTAssertFalse(item.hasChanges)
        XCTAssertNil(item.previewURL)
        // the dialogue's newest Dev page never turns a board into a preview
        XCTAssertNil(item.withPage(URL(string: "https://pv-x.liaisone.com/")).previewURL)
        let s = CanvasState.opening(item, over: nil)
        XCTAssertEqual(s.tab, .images)
        XCTAssertEqual(s.tabs, [.images])
    }

    // A layered block opens on the board with its words (the same editor, the same layouts).
    func testLayeredBoardKeepsLayersAndShownNumbers() {
        let json = #"{"stage":"drafts","layers":[{"id":"h","kind":"headline","text":"Yoga camp"}],"images":[{"id":"a","n":1,"url":"/a"},{"id":"d","n":4,"url":"/d"}]}"#
        guard let c = CreaImages(ChatBlock(tool: "crea_images", data: JSONRead.object(Data(json.utf8)))) else { return XCTFail("not read") }
        let b = CreaBoard(images: c, selected: "d", chatProfile: "p", chatDlg: "crea")
        XCTAssertTrue(b.isLayered)
        XCTAssertEqual(b.layers, c.layers)
        XCTAssertEqual(b.shownNumber(b.pictures[1]), 2)
        XCTAssertEqual(b.useDraftText(b.pictures[1]), "Use draft 2 (number 4 in the drafts list)")
    }

    func testImagesOverDevPreviewAndAgain() {
        let dev = CanvasState(item: CanvasItem(block: preview("https://a.dev.liaisone.com/"), profile: "p")!)
        let b1 = CanvasItem.images(CreaBoard(images: crea(), selected: "a", chatProfile: "p", chatDlg: "crea"))
        let s1 = CanvasState.opening(b1, over: dev)
        XCTAssertEqual(s1.tab, .images)
        // the same block, another picture clicked: same item, the new selection, a refit (reloads)
        let b2 = CanvasItem.images(CreaBoard(images: crea(), selected: "c", chatProfile: "p", chatDlg: "crea"))
        let s2 = CanvasState.opening(b2, over: s1)
        XCTAssertEqual(s2.item.board?.selected, "c")
        XCTAssertEqual(s2.reloads, s1.reloads + 1)
        XCTAssertEqual(s2.tab, .images)
        // Dev's preview opened again gets its own tabs back
        let back = CanvasState.opening(dev.item, over: s2)
        XCTAssertEqual(back.tab, .preview)
        XCTAssertTrue(back.tabs.contains(.code))
    }

    func testBoardMath() {
        let l = CanvasBoardMath.layout(aspects: [1, 2, 1], selected: 1)
        XCTAssertEqual(l.map(\.w), [1024, 2048, 1024])
        XCTAssertEqual(l[1].x, 0)
        XCTAssertEqual(l[0].x, -(1024 + 64 + 512))
        XCTAssertEqual(l[2].x, 1024 + 64 + 512)
        XCTAssertTrue(CanvasBoardMath.layout(aspects: [], selected: 0).isEmpty)
        XCTAssertTrue(abs(CanvasBoardMath.fit(w: 1024, h: 1024, vw: 576, vh: 576) - 0.5) < 0.0001)
        XCTAssertEqual(CanvasBoardMath.fit(w: 10, h: 10, vw: 1000, vh: 1000), 2)   // small pictures at most 200%
        XCTAssertEqual(CanvasBoardMath.step(1, up: true), 1.25)
        XCTAssertEqual(CanvasBoardMath.step(1, up: false), 0.75)
        XCTAssertEqual(CanvasBoardMath.step(0.8, up: false), 0.75)
        XCTAssertEqual(CanvasBoardMath.step(8, up: true), 8)
        XCTAssertEqual(CanvasBoardMath.clamp(100), 8)
        // the point under the pointer stays: board point 0 at offset 0, pointer at x 100, zoom x2 -> offset -100
        let o = CanvasBoardMath.zoom(offset: (x: 0, y: 0), about: (x: 100, y: 0), from: 1, to: 2)
        XCTAssertEqual(o.x, -100)
        XCTAssertEqual(o.y, 0)
        XCTAssertEqual(CanvasBoardMath.percent(0.333), "33%")
    }
}
