import XCTest
import Foundation
@testable import Liaison

/// (his own photo, placed on the canvas, joined the old drafts as "Final 1"): Crea's action place (stage
/// "place", id "up_...") opens a board of its own in the Studio, kind `.upload`, linked to nothing.
final class CreaPlaceTests: XCTestCase {
    private func images(_ json: String) -> CreaImages {
        CreaImages(ChatBlock(tool: "crea_images", data: JSONRead.object(Data(json.utf8))))!
    }

    private let drafts = """
    {"stage":"drafts","brief":"Yogi sketch","images":[{"id":"d1","n":1,"url":"/u1"},{"id":"d2","n":2,"url":"/u2"},{"id":"d3","n":3,"url":"/u3"}]}
    """
    private let place = #"{"stage":"place","brief":"The person's photo","images":[{"id":"up_abc","n":1,"url":"/p","key":"ai/m/att/crea/up_abc.jpg"}]}"#

    private func withDraftsAndFinal() -> (CreaStudioBook, String) {
        var b = CreaStudioBook()
        let r = b.ingest(images(drafts), profile: "p", dlg: "crea", now: 100)!
        _ = b.ingest(images(#"{"stage":"final","images":[{"id":"f1","url":"/f","from":"d1"}]}"#), profile: "p", dlg: "crea", now: 101)
        return (b, r.studio)
    }

    func testAnUnknownStagePlaceStillReadsAsOneFinalPicture() {
        let c = images(place)
        XCTAssertEqual(c.stage, .final)            // an older Mac and the chat block draw it as before
        XCTAssertTrue(CreaStudioBook.isUpload(c.images[0]))
        XCTAssertFalse(CreaStudioBook.isUpload(images(drafts).images[0]))
    }

    func testPlacedPhotoOpensItsOwnBoardNotAFinalOfTheDrafts() {
        var (b, old) = withDraftsAndFinal()
        let r = b.ingest(images(place), profile: "p", dlg: "crea", now: 200)!
        XCTAssertTrue(r.studio != old)
        XCTAssertEqual(b.studios.count, 2)
        XCTAssertFalse(b.studio(old)!.has("up_abc"))
        let s = b.studio(r.studio)!
        XCTAssertEqual(s.nodes.map(\.id), ["up_abc"])
        XCTAssertEqual(s.node("up_abc")?.kind, .upload)
        XCTAssertNil(s.node("up_abc")?.parent)
        XCTAssertEqual(s.selected, "up_abc")
        XCTAssertEqual(s.labels()["up_abc"], "Upload 1")
        XCTAssertTrue(s.isUpload)
        // the old board kept its own final with its draft
        XCTAssertEqual(b.studio(old)?.node("f1")?.parent, "d1")
        XCTAssertEqual(b.studio(old)?.labels()["f1"], "Final 1")
    }

    func testEditsAndWordsLandOnTheUploadBoard() {
        var (b, _) = withDraftsAndFinal()
        let up = b.ingest(images(place), profile: "p", dlg: "crea", now: 200)!.studio
        // action text on the placed photo: same picture with words -> the node gets them (the layers editor)
        let text = #"{"stage":"place","images":[{"id":"up_abc","n":1,"url":"/p2","key":"ai/m/att/crea/up_abc.jpg"}],"layers":[{"kind":"headline","text":"First lesson free"}]}"#
        let again = b.ingest(images(text), profile: "p", dlg: "crea", now: 201)
        XCTAssertEqual(again?.added, [])
        XCTAssertEqual(b.studio(up)?.node("up_abc")?.layers.map(\.text), ["First lesson free"])
        XCTAssertEqual(b.studio(up)?.node("up_abc")?.pic?.url, "/p2")
        // an edit with no `from`: the newest board of the dialogue (the upload's), off the photo
        _ = b.ingest(images(#"{"stage":"edit","images":[{"id":"e1","url":"/e"}]}"#), profile: "p", dlg: "crea", now: 202)
        XCTAssertEqual(b.studio(up)?.node("e1")?.parent, "up_abc")
        XCTAssertEqual(b.studio(up)?.labels()["e1"], "Upload 1 \u{00B7} edit 1")
    }

    func testNewDraftsDoNotJoinTheUploadBoard() {
        var b = CreaStudioBook()
        let up = b.ingest(images(place), profile: "p", dlg: "crea", now: 100)!.studio
        let d = b.ingest(images(#"{"stage":"drafts","brief":"","images":[{"id":"x1","n":1,"url":"/1"},{"id":"x2","n":2,"url":"/2"}]}"#),
                         profile: "p", dlg: "crea", now: 101)!.studio
        XCTAssertTrue(d != up)
        XCTAssertEqual(b.studio(up)?.nodes.map(\.id), ["up_abc"])
    }

    func testUploadBoardSurvivesSavingAndIsNotMergedIntoOldDrafts() {
        var (b, old) = withDraftsAndFinal()
        let up = b.ingest(images(place), profile: "p", dlg: "crea", now: 200)!.studio
        let back = CreaStudioBook.decoded(b.encoded())
        XCTAssertEqual(back.studios.count, 2)
        XCTAssertEqual(back.studio(up)?.node("up_abc")?.kind, .upload)
        XCTAssertFalse(back.studio(old)!.has("up_abc"))
    }

    func testOlderFinalWithoutPrefixStillJoinsTheDrafts() {
        var (b, old) = withDraftsAndFinal()
        _ = b.ingest(images(#"{"stage":"final","images":[{"id":"f9","n":2,"url":"/f9"}]}"#), profile: "p", dlg: "crea", now: 300)
        XCTAssertEqual(b.studio(old)?.node("f9")?.parent, "d2")
        XCTAssertEqual(b.studios.count, 1)
    }

    // MARK: a photo placed (stage "final", no "up_"), as 0.2.12 found it

    /// An id the server minted at 16:40 UTC (live), and one from the day before.
    private let legacyId = "mvjro8aok3m9qz"
    private let olderId = "mvhxxz40p0q1r2"

    private func pic(_ id: String, n: Int = 1, idea: String = "", from: String? = nil, draft: Bool = false) -> CreaPicRef {
        CreaPicRef(CreaImages.Picture(id: id, n: n, url: "/" + id, key: "ai/m/att/crea/\(id).png", idea: idea, w: 1080, h: 1350,
                                      from: from, isDraft: draft))
    }

    private func node(_ id: String, _ kind: CreaStudioNode.Kind, parent: String? = nil, pic: CreaPicRef? = nil, file: String? = nil,
                      at: Double) -> CreaStudioNode {
        CreaStudioNode(id: id, kind: kind, parent: parent, pic: pic, file: file, region: file == nil ? nil : CreaArea(x: 10, y: 10, w: 50, h: 50),
                       note: file == nil ? nil : "make the shirt red", at: at)
    }

    /// The yoga drafts' board as an older Mac build saved it: the placed photo joined it as the final of Draft 1, and the
    /// two Edit area versions hang off the photo.
    private func yogaBoardWithPlacedPhoto() -> CreaStudioBook {
        var s = CreaStudio(id: "st-d1", title: "Вертикальный статичный рекламный", brief: "Вертикальный статичный рекламный креатив",
                           profile: "p", dlg: "crea", created: 100, updated: 300)
        s.nodes = [
            node("d1", .draft, pic: pic("d1", n: 1, idea: "mats", draft: true), at: 100),
            node("d2", .draft, pic: pic("d2", n: 2, idea: "sticks", draft: true), at: 100.001),
            node("f2", .final, parent: "d2", pic: pic("f2", idea: "sticks", from: "d2"), at: 150),
            node(legacyId, .final, parent: "d1", pic: pic(legacyId), at: 200),
            node("loc-a1", .area, parent: legacyId, file: "loc-a1.png", at: 210),
            node("loc-a2", .area, parent: legacyId, file: "loc-a2.png", at: 220),
            node("loc-a3", .area, parent: "loc-a1", file: "loc-a3.png", at: 230),
        ]
        s.selected = "loc-a2"
        var b = CreaStudioBook()
        b.studios = [s]
        return b
    }

    func testLegacyPlaceRuleNeedsAllItsSigns() {
        XCTAssertTrue(CreaStudioBook.placedBefore(id: legacyId, idea: "", from: nil))
        XCTAssertFalse(CreaStudioBook.placedBefore(id: legacyId, idea: "mats", from: nil))      // a generated final has its draft's idea
        XCTAssertFalse(CreaStudioBook.placedBefore(id: legacyId, idea: "", from: "d1"))          // a final made from a draft
        XCTAssertFalse(CreaStudioBook.placedBefore(id: olderId, idea: "", from: nil))            // minted was live
        XCTAssertFalse(CreaStudioBook.placedBefore(id: "f9", idea: "", from: nil))               // not a server id
        XCTAssertFalse(CreaStudioBook.placedBefore(id: "loc-1234567890", idea: "", from: nil))
    }

    func testOpeningTheBookMovesThePlacedPhotoAndItsEditsToAnUploadBoard() {
        let back = CreaStudioBook.decoded(yogaBoardWithPlacedPhoto().encoded())
        XCTAssertEqual(back.studios.count, 2)
        // nothing dropped: 7 nodes before, 7 after
        XCTAssertEqual(back.studios.map(\.nodes.count).reduce(0, +), 7)
        let mats = back.studio("st-d1")!
        XCTAssertEqual(Set(mats.nodes.map(\.id)), ["d1", "d2", "f2"])
        XCTAssertNil(mats.selected)
        XCTAssertEqual(mats.labels()["f2"], "Final 2")
        let up = back.studios.first { $0.id != "st-d1" }!
        XCTAssertTrue(up.isUpload)
        XCTAssertEqual(up.title, "Upload")
        XCTAssertEqual(up.thread, "p|crea")
        XCTAssertEqual(up.node(legacyId)?.kind, .upload)
        XCTAssertNil(up.node(legacyId)?.parent)
        XCTAssertEqual(up.node(legacyId)?.pic?.upload, true)
        // the edits keep their parents and remember the folder their PNGs are in
        XCTAssertEqual(up.node("loc-a1")?.parent, legacyId)
        XCTAssertEqual(up.node("loc-a2")?.parent, legacyId)
        XCTAssertEqual(up.node("loc-a3")?.parent, "loc-a1")
        XCTAssertEqual(up.nodes.filter { $0.kind == .area }.map(\.dir), ["st-d1", "st-d1", "st-d1"])
        XCTAssertEqual(up.selected, "loc-a2")
        let l = up.labels()
        XCTAssertEqual(l[legacyId], "Upload 1")
        XCTAssertEqual(l["loc-a1"], "Upload 1 \u{00B7} edit 1")
        XCTAssertEqual(l["loc-a2"], "Upload 1 \u{00B7} edit 2")
        XCTAssertEqual(CreaStudioLayout.frames(up).count, 4)
        // and it stays so (a second opening changes nothing)
        XCTAssertEqual(CreaStudioBook.decoded(back.encoded()), back)
    }

    /// The other shape: the photo had a board of its own (no drafts) in the same dialogue. The round-2 merge put it,
    /// edits and all, into the older yoga board as "Final 1" (and the edits' PNGs stayed in the other board's folder).
    func testAPlacedPhotosOwnBoardIsNeverMergedIntoTheDrafts() {
        var b = yogaBoardWithPlacedPhoto()
        b.studios[0].nodes.removeAll { $0.id == legacyId || $0.id.hasPrefix("loc-") }
        var own = CreaStudio(id: "st-photo", title: "The person's photo", brief: "The person's photo", profile: "p", dlg: "crea",
                             created: 200, updated: 230)
        own.nodes = [node(legacyId, .final, pic: pic(legacyId), at: 200),
                     node("loc-a1", .area, parent: legacyId, file: "loc-a1.png", at: 210),
                     node("loc-a2", .area, parent: legacyId, file: "loc-a2.png", at: 220)]
        b.studios.append(own)
        let back = CreaStudioBook.decoded(b.encoded())
        XCTAssertEqual(back.studios.count, 2)
        XCTAssertEqual(Set(back.studio("st-d1")!.nodes.map(\.id)), ["d1", "d2", "f2"])
        let s = back.studio("st-photo")!
        XCTAssertEqual(s.node(legacyId)?.kind, .upload)
        XCTAssertEqual(s.node("loc-a1")?.parent, legacyId)
        XCTAssertEqual(s.node("loc-a2")?.parent, legacyId)
        XCTAssertNil(s.node("loc-a1")?.dir)       // never moved: its PNG is in its own folder
    }

    /// A board merged by an earlier revision (no drafts, no photo of the person's): its versions made on this Mac remember the folder.
    func testAMergedBoardsLocalVersionsRememberTheirFolder() {
        var b = yogaBoardWithPlacedPhoto()
        b.studios[0].nodes.removeAll { $0.id == legacyId || $0.id.hasPrefix("loc-") }
        var split = CreaStudio(id: "st-f9", title: "x", brief: "", profile: "p", dlg: "crea", created: 200, updated: 210)
        split.nodes = [node("f9", .final, pic: pic("f9", n: 1, idea: "mats"), at: 200),
                       node("loc-b1", .area, parent: "f9", file: "loc-b1.png", at: 210)]
        b.studios.append(split)
        let back = CreaStudioBook.decoded(b.encoded())
        XCTAssertEqual(back.studios.count, 1)
        XCTAssertEqual(back.studios[0].node("f9")?.parent, "d1")
        XCTAssertEqual(back.studios[0].node("loc-b1")?.parent, "f9")
        XCTAssertEqual(back.studios[0].node("loc-b1")?.dir, "st-f9")
    }

    func testTheLegacyBlockReadAgainOpensItsOwnBoard() {
        var (b, old) = withDraftsAndFinal()
        let r = b.ingest(images(#"{"stage":"final","brief":"The person's photo","images":[{"id":"\#(legacyId)","n":1,"url":"/p","key":"ai/m/att/crea/\#(legacyId).jpg"}]}"#),
                         profile: "p", dlg: "crea", now: 200)!
        XCTAssertTrue(r.studio != old)
        XCTAssertEqual(b.studio(r.studio)?.node(legacyId)?.kind, .upload)
        XCTAssertFalse(b.studio(old)!.has(legacyId))
    }

    /// The server's mark (lia-agents reads the picture's R2 metadata) moves a photo the rule cannot see.
    func testTheServersUploadMarkMovesAKnownFinal() {
        var (b, old) = withDraftsAndFinal()
        _ = b.ingest(images(#"{"stage":"final","images":[{"id":"f9","n":1,"url":"/f9"}]}"#), profile: "p", dlg: "crea", now: 300)
        XCTAssertEqual(b.studio(old)?.node("f9")?.kind, .final)
        _ = b.add(CreaStudioNode(id: "loc-z", kind: .area, parent: "f9", file: "loc-z.png", at: 301), in: old)
        let marked = images(#"{"stage":"final","images":[{"id":"f9","n":1,"url":"/f9b","upload":true}]}"#)
        XCTAssertTrue(marked.images[0].upload)
        let r = b.ingest(marked, profile: "p", dlg: "crea", now: 400)!
        XCTAssertTrue(r.studio != old)
        let up = b.studio(r.studio)!
        XCTAssertEqual(up.node("f9")?.kind, .upload)
        XCTAssertEqual(up.node("f9")?.pic?.url, "/f9b")
        XCTAssertEqual(up.node("loc-z")?.parent, "f9")
        XCTAssertEqual(up.node("loc-z")?.dir, old)
        XCTAssertEqual(b.studio(old)?.node("f1")?.parent, "d1")
    }

    func testAStagePlaceBlockMarksEveryPicture() {
        XCTAssertTrue(images(place).images[0].upload)
        XCTAssertFalse(images(drafts).images.contains { $0.upload })
    }

    // MARK: saving never loses the book

    func testOneUnreadableNodeDoesNotCostTheBook() {
        let b = yogaBoardWithPlacedPhoto()
        var json = String(data: b.encoded()!, encoding: .utf8)!
        json = json.replacingOccurrences(of: #""kind":"area""#, with: #""kind":"hologram""#)
        let back = CreaStudioBook.read(Data(json.utf8))
        XCTAssertNotNil(back)
        // the three nodes of a kind this build does not know are skipped alone; the rest is all there
        XCTAssertEqual(back?.studios.map(\.nodes.count).reduce(0, +), 4)
        XCTAssertNil(CreaStudioBook.read(Data("not json".utf8)))
    }

    func testANaNPlaceNoLongerMakesTheBookUnsavable() {
        var b = yogaBoardWithPlacedPhoto()
        b.update("st-d1", "d1") { $0.x = .nan; $0.y = 4 }
        b.update("st-d1", "loc-a1") { $0.region = CreaArea(x: .infinity, y: 0, w: 1, h: 1) }
        let d = b.encoded()
        XCTAssertNotNil(d)
        let back = CreaStudioBook.read(d!)!
        let all = back.studios.flatMap(\.nodes)
        XCTAssertNil(all.first { $0.id == "d1" }?.x)
        XCTAssertNil(all.first { $0.id == "loc-a1" }?.region)
        XCTAssertEqual(all.count, 7)
    }

    // MARK: panning

    func testADragPansOnlyFromTheEmptyBoard() {
        let rects = [(x: 100.0, y: 100.0, w: 200.0, h: 300.0), (x: 0.0, y: 0.0, w: 0.0, h: 0.0)]
        XCTAssertFalse(CreaStudioPan.mayPan(from: (x: 150, y: 150), over: rects))
        XCTAssertTrue(CreaStudioPan.mayPan(from: (x: 50, y: 50), over: rects))
        XCTAssertTrue(CreaStudioPan.mayPan(from: (x: 0, y: 0), over: rects))   // an empty rectangle covers nothing
    }
}
