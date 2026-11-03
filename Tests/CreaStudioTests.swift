import XCTest
import Foundation
@testable import Liaison

/// Crea Studio (Shared/Core/CreaStudio.swift): how Crea's blocks become one graph, the names, the layout, the target.
final class CreaStudioTests: XCTestCase {
    private func images(_ json: String) -> CreaImages {
        CreaImages(ChatBlock(tool: "crea_images", data: JSONRead.object(Data(json.utf8))))!
    }

    private let drafts = """
    {"stage":"drafts","brief":"Trial yoga class for Acme in Milan. Parents 30-45","images":[
      {"id":"d1","n":1,"url":"/u1","idea":"A"},{"id":"d2","n":2,"url":"/u2","idea":"B"},
      {"id":"d3","n":3,"url":"/u3"},{"id":"d4","n":4,"url":"/u4"}]}
    """

    private func started() -> (CreaStudioBook, String) {
        var b = CreaStudioBook()
        let r = b.ingest(images(drafts), profile: "p", dlg: "crea", now: 100)!
        return (b, r.studio)
    }

    func testDraftsAreTheRootsWithNoBriefNode() {
        let (b, id) = started()
        XCTAssertEqual(b.studios.count, 1)
        let s = b.studio(id)!
        XCTAssertEqual(s.title, "Trial yoga class for Acme in Milan")
        XCTAssertEqual(s.nodes.count, 4)
        XCTAssertFalse(s.nodes.contains { $0.kind == .brief })
        XCTAssertEqual(s.nodes.map(\.parent), Array(repeating: nil, count: 4))
        XCTAssertEqual(s.thread, "p|crea")
    }

    func testFinalBranchesFromItsDraftAndEditsFromTheTarget() {
        var (b, id) = started()
        _ = b.ingest(images(#"{"stage":"final","images":[{"id":"f2","url":"/f","from":"d2"}]}"#), profile: "p", dlg: "crea", now: 101)
        var s = b.studio(id)!
        XCTAssertEqual(s.node("f2")?.parent, "d2")
        XCTAssertEqual(s.selected, "f2")
        // four finals at once: four branches
        _ = b.ingest(images(#"{"stage":"final","images":[{"id":"g1","url":"/a","from":"d1"},{"id":"g3","url":"/b","from":"d3"}]}"#),
                     profile: "p", dlg: "crea", now: 102)
        s = b.studio(id)!
        XCTAssertEqual(s.node("g1")?.parent, "d1")
        XCTAssertEqual(s.node("g3")?.parent, "d3")
        // an edit without `from`: the request's target
        _ = b.ingest(images(#"{"stage":"edit","images":[{"id":"e1","url":"/e"}]}"#), profile: "p", dlg: "crea", now: 103, pending: "g1")
        XCTAssertEqual(b.studio(id)?.node("e1")?.parent, "g1")
        // a block-level `from` names the image edited
        _ = b.ingest(images(#"{"stage":"edit","from":"f2","images":[{"id":"e2","url":"/e2"}]}"#), profile: "p", dlg: "crea", now: 104)
        XCTAssertEqual(b.studio(id)?.node("e2")?.parent, "f2")
        // without either: the newest final or edit of the dialogue's studio
        _ = b.ingest(images(#"{"stage":"edit","images":[{"id":"e3","url":"/e3"}]}"#), profile: "p", dlg: "crea", now: 105)
        XCTAssertEqual(b.studio(id)?.node("e3")?.parent, "e2")
    }

    func testIngestIsIdempotentAndRefreshesLinks() {
        var (b, id) = started()
        let again = b.ingest(images(drafts.replacingOccurrences(of: "/u1", with: "/fresh")), profile: "p", dlg: "crea", now: 200)
        XCTAssertEqual(again?.added, [])
        XCTAssertEqual(b.studio(id)?.nodes.count, 4)
        XCTAssertEqual(b.studio(id)?.node("d1")?.pic?.url, "/fresh")
    }

    func testLabels() {
        var (b, id) = started()
        _ = b.ingest(images(#"{"stage":"final","images":[{"id":"f2","url":"/f","from":"d2"}]}"#), profile: "p", dlg: "crea", now: 101)
        _ = b.ingest(images(#"{"stage":"edit","images":[{"id":"e1","url":"/e"}]}"#), profile: "p", dlg: "crea", now: 102, pending: "f2")
        let area = CreaStudioNode(id: "loc-a", kind: .area, parent: "e1", file: "loc-a.png", at: 103)
        XCTAssertNotNil(b.add(area, in: id))
        let text = CreaStudioNode(id: "loc-t", kind: .text, parent: "f2", at: 104)
        XCTAssertNotNil(b.add(text, in: id))
        let l = b.studio(id)!.labels()
        XCTAssertEqual(l["d2"], "Draft 2")
        XCTAssertEqual(l["f2"], "Final 2")
        XCTAssertEqual(l["e1"], "Final 2 \u{00B7} edit 1")
        XCTAssertEqual(l["loc-a"], "Final 2 \u{00B7} edit 2")
        XCTAssertEqual(l["loc-t"], "Final 2 \u{00B7} text 1")
        XCTAssertEqual(b.studio(id)!.path(to: "loc-a"), ["d2", "f2", "e1", "loc-a"])
        // a node under an unknown parent is refused
        XCTAssertNil(b.add(CreaStudioNode(id: "x", kind: .area, parent: "nope", at: 1), in: id))
    }

    func testLayoutColumnsAndPins() {
        var (b, id) = started()
        _ = b.ingest(images(#"{"stage":"final","images":[{"id":"f2","url":"/f","from":"d2"}]}"#), profile: "p", dlg: "crea", now: 101)
        var s = b.studio(id)!
        var f = CreaStudioLayout.frames(s)
        XCTAssertEqual(f.count, 5)
        // drafts are full pictures: the same height as the final
        XCTAssertEqual(f["d1"]!.h, f["f2"]!.h)
        XCTAssertTrue(f["d2"]!.maxX < f["f2"]!.x)
        XCTAssertTrue(f["d1"]!.y < f["d2"]!.y)
        // drafts do not overlap
        XCTAssertTrue(f["d1"]!.maxY <= f["d2"]!.y)
        // a dragged node stays put and its subtree moves with it
        let d2 = f["d2"]!, f2 = f["f2"]!
        b.update(id, "d2") { $0.x = d2.x + 50; $0.y = d2.y - 30 }
        s = b.studio(id)!
        f = CreaStudioLayout.frames(s)
        XCTAssertTrue(abs(f["d2"]!.x - (d2.x + 50)) < 1e-9)
        XCTAssertTrue(abs(f["f2"]!.y - (f2.y - 30)) < 1e-9)
        XCTAssertEqual(CreaStudioBook.decoded(b.encoded()), b)
    }

    func testTargetMessage() {
        let m = CreaStudioTargetText.message("make the headline yellow", label: "Final 2 \u{00B7} edit 3", imageId: "e3", attached: true, team: false)
        XCTAssertTrue(m.hasPrefix("Edit the attached image \u{201C}Final 2 \u{00B7} edit 3\u{201D} (id e3)"))
        XCTAssertTrue(m.hasSuffix("make the headline yellow"))
        XCTAssertTrue(CreaStudioTargetText.message("x", label: "Draft 1", imageId: nil, attached: false, team: true).hasPrefix("@Crea Edit the image"))
        XCTAssertEqual(CreaStudioTargetText.chip("Final 2"), "Editing: Final 2")
    }

    func testParentAliasesInBlocks() {
        let c = images(#"{"stage":"edit","parent":"f9","images":[{"id":"e","url":"/e"},{"id":"k","url":"/k","source":"f1"}]}"#)
        XCTAssertEqual(c.images.first { $0.id == "e" }?.from, "f9")
        XCTAssertEqual(c.images.first { $0.id == "k" }?.from, "f1")
    }

    func testFinalWithoutFromJoinsTheDraftsBoard() {
        var (b, id) = started()
        // no `from`, no target: the dialogue's studio, under the draft of its number
        let r = b.ingest(images(#"{"stage":"final","images":[{"id":"f9","n":3,"url":"/f9"}]}"#), profile: "p", dlg: "crea", now: 101)
        XCTAssertEqual(r?.studio, id)
        XCTAssertEqual(b.studios.count, 1)
        XCTAssertEqual(b.studio(id)?.node("f9")?.parent, "d3")
        // a photo too
        _ = b.ingest(images(#"{"stage":"photo","images":[{"id":"ph","url":"/ph"}]}"#), profile: "p", dlg: "crea", now: 102)
        XCTAssertEqual(b.studios.count, 1)
        // drafts again for the same brief: the same studio; a new brief: a new one
        _ = b.ingest(images(drafts.replacingOccurrences(of: "\"id\":\"d", with: "\"id\":\"r")), profile: "p", dlg: "crea", now: 103)
        XCTAssertEqual(b.studios.count, 1)
        XCTAssertEqual(b.studio(id)?.labels()["r1"], "Draft 5")
        _ = b.ingest(images(#"{"stage":"drafts","brief":"Summer camp","images":[{"id":"z1","url":"/z"}]}"#), profile: "p", dlg: "crea", now: 104)
        XCTAssertEqual(b.studios.count, 2)
    }

    func testOldStudiosMigrate() {
        // a brief root, and a final that opened a studio of its own
        var old = CreaStudio(id: "st-d1", title: "T", brief: "T", profile: "p", dlg: "crea", created: 100, updated: 100)
        old.nodes = [CreaStudioNode(id: "brief:st-d1", kind: .brief, note: "T", at: 100),
                     CreaStudioNode(id: "d1", kind: .draft, parent: "brief:st-d1",
                                    pic: CreaPicRef(CreaImages.Picture(id: "d1", n: 1, url: "/u", key: "", idea: "", w: nil, h: nil)), at: 100)]
        old.selected = "brief:st-d1"
        var apart = CreaStudio(id: "st-f1", title: "", brief: "", profile: "p", dlg: "crea", created: 200, updated: 200)
        apart.nodes = [CreaStudioNode(id: "brief:st-f1", kind: .brief, at: 200),
                       CreaStudioNode(id: "f1", kind: .final, parent: "brief:st-f1",
                                      pic: CreaPicRef(CreaImages.Picture(id: "f1", n: 1, url: "/f", key: "", idea: "", w: nil, h: nil)), at: 200)]
        apart.selected = "f1"
        let book = CreaStudioBook(studios: [old, apart])
        let b = CreaStudioBook.decoded(book.encoded())
        XCTAssertEqual(b.studios.count, 1)
        let s = b.studios[0]
        XCTAssertEqual(s.nodes.map(\.id), ["d1", "f1"])
        XCTAssertNil(s.node("d1")?.parent)
        XCTAssertEqual(s.node("f1")?.parent, "d1")
        XCTAssertEqual(s.selected, "f1")
    }
}
