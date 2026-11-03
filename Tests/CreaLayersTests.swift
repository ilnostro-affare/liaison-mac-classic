import XCTest
import Foundation
@testable import Liaison

/// Crea's creatives as movable layers (Shared/Core/CreaLayers.swift, the block's `layers`).
final class CreaLayersTests: XCTestCase {
    private func block(_ json: String) -> ChatBlock {
        ChatBlock(tool: "crea_images", data: JSONRead.object(Data(json.utf8)))
    }

    private func near(_ a: Double, _ b: Double, _ eps: Double = 1e-9) -> Bool { abs(a - b) < eps }

    private let layered = """
    {"stage":"drafts","brief":"Yoga","images":[{"id":"a","n":1,"url":"/intelligence/plot?k=a","key":"ai/m/att/crea/a.png","fit":"4:5"},
     {"id":"b","n":2,"url":"/intelligence/plot?k=b","key":"ai/m/att/crea/b.png"}],
     "layers":[{"id":"headline","kind":"headline","text":"Breathe\\n first.","color":"#fff"},
               {"id":"cta","kind":"cta","text":"Join","bg":"#FFE7DC"},
               {"id":"x","kind":"sticker","text":"no"},
               {"id":"sub","kind":"sub","text":"  "},
               {"id":"headline","kind":"headline","text":"dup"},
               {"kind":"brand","text":"kaya","color":"red"}]}
    """

    func testBlockReadsLayers() {
        guard let c = CreaImages(block(layered)) else { return XCTFail("block not read") }
        XCTAssertTrue(c.isLayered)
        // an unknown kind, empty words and a repeated id are skipped; a missing id is the kind
        XCTAssertEqual(c.layers.map(\.id), ["headline", "cta", "brand"])
        XCTAssertEqual(c.layers[0].text, "Breathe first.")
        XCTAssertEqual(c.layers[0].color, "#FFFFFF")
        // a light button without a words colour gets dark words; a colour that is not hex is white
        XCTAssertEqual(c.layers[1].bg, "#FFE7DC")
        XCTAssertEqual(c.layers[1].color, "#111111")
        XCTAssertEqual(c.layers[2].color, "#FFFFFF")
        XCTAssertNil(c.layers[0].bg)
        XCTAssertEqual(c.images[0].fit, "4:5")
        XCTAssertNil(c.images[1].fit)
    }

    func testOldBlocksAreFlat() {
        let old = CreaImages(block(#"{"stage":"final","images":[{"id":"x","url":"/a"}]}"#))
        XCTAssertEqual(old?.isLayered, false)
        XCTAssertEqual(old?.layers.count, 0)
        // a photo edit is never layered
        let photo = CreaImages(block(#"{"stage":"photo","images":[{"id":"x","url":"/a"}],"layers":[{"kind":"headline","text":"Hi"}]}"#))
        XCTAssertEqual(photo?.isLayered, false)
    }

    func testFromNamesTheDraft() {
        let f = CreaImages(block(#"{"stage":"final","images":[{"id":"f1","url":"/a","from":"d2"},{"id":"f2","url":"/b","from":"f2"}]}"#))
        XCTAssertEqual(f?.images[0].from, "d2")
        XCTAssertNil(f?.images[1].from)   // itself is no seed
    }

    func testColours() {
        XCTAssertEqual(CreaColor.hex("#abc"), "#AABBCC")
        XCTAssertEqual(CreaColor.hex("ff8800"), "#FF8800")
        XCTAssertNil(CreaColor.hex("red"))
        XCTAssertNil(CreaColor.hex(""))
        XCTAssertNil(CreaColor.hex("#12345"))
        XCTAssertTrue(CreaColor.luminance("#FFFFFF") > 0.99)
        XCTAssertTrue(CreaColor.luminance("#000000") < 0.01)
        XCTAssertTrue(near(CreaColor.rgb("#FF0000").r, 1) && near(CreaColor.rgb("#FF0000").g, 0))
    }

    func testDefaultsStackTopAndCTAAtTheBottom() {
        let ls = [CreaLayer(id: "cta", kind: .cta, text: "Go", color: "#111111", bg: "#FFFFFF"),
                  CreaLayer(id: "headline", kind: .headline, text: "Breathe first.", color: "#FFFFFF"),
                  CreaLayer(id: "brand", kind: .brand, text: "kaya", color: "#FFFFFF"),
                  CreaLayer(id: "sub", kind: .sub, text: "Ten minutes a day.", color: "#FFFFFF")]
        let size: (CreaLayer) -> (w: Double, h: Double) = { _ in (0.5, 0.1) }
        let d = CreaLayers.defaults(ls, size: size)
        XCTAssertTrue(near(d["brand"]!.y, 0.06))
        XCTAssertTrue(near(d["headline"]!.y, 0.06 + 0.1 + 0.03))
        XCTAssertTrue(near(d["sub"]!.y, 0.19 + 0.1 + 0.025))
        XCTAssertTrue(near(d["cta"]!.y, 1 - 0.07 - 0.1))
        XCTAssertTrue(ls.allSatisfy { near(d[$0.id]!.x, 0.07) })
        // tall words never put the CTA over the sub-text
        let tall = CreaLayers.defaults(ls, size: { _ in (0.5, 0.3) })
        XCTAssertTrue(tall["cta"]!.y >= tall["sub"]!.y + 0.3)
    }

    func testResolvedOwnThenSeedThenDefault() {
        let ls = [CreaLayer(id: "headline", kind: .headline, text: "Hi", color: "#FFFFFF"),
                  CreaLayer(id: "cta", kind: .cta, text: "Go", color: "#111111", bg: "#FFFFFF")]
        var own = CreaLayout(); own["headline"] = CreaLayerFrame(x: 0.3, y: 0.4, scale: 1.5)
        own["gone"] = CreaLayerFrame(x: 0.9, y: 0.9)
        var seed = CreaLayout(); seed["cta"] = CreaLayerFrame(x: 0.5, y: 0.5); seed["headline"] = CreaLayerFrame(x: 0.1, y: 0.1)
        let r = CreaLayers.resolved(ls, own: own, seed: seed, size: { _ in (0.2, 0.1) })
        XCTAssertEqual(r["headline"], CreaLayerFrame(x: 0.3, y: 0.4, scale: 1.5))
        XCTAssertEqual(r["cta"], CreaLayerFrame(x: 0.5, y: 0.5))
        XCTAssertNil(r["gone"])
        let fresh = CreaLayers.resolved(ls, own: nil, seed: nil, size: { _ in (0.2, 0.1) })
        XCTAssertEqual(fresh["headline"], CreaLayerFrame(x: 0.07, y: 0.06))
    }

    func testMoveSnapsToMarginCentreAndOthers() {
        let start = CreaLayerFrame(x: 0.2, y: 0.2)
        // near the left margin
        let m = CreaLayers.moved(start, dx: -0.14, dy: 0, w: 0.3, h: 0.1, others: [])
        XCTAssertTrue(near(m.frame.x, CreaLayers.margin))
        XCTAssertEqual(m.guides, [CreaGuide(axis: .vertical, at: CreaLayers.margin)])
        // the centre: a 0.3 wide box at 0.345 -> its middle at 0.495, snapped to 0.5
        let c = CreaLayers.moved(start, dx: 0.145, dy: 0, w: 0.3, h: 0.1, others: [])
        XCTAssertTrue(near(c.frame.x, 0.35))
        XCTAssertTrue(c.guides.contains(CreaGuide(axis: .vertical, at: 0.5)))
        // another layer's left edge
        let o = CreaLayers.moved(start, dx: 0.21, dy: 0.3, w: 0.2, h: 0.1, others: [CreaBox(x: 0.42, y: 0.8, w: 0.3, h: 0.1)])
        XCTAssertTrue(near(o.frame.x, 0.42))
        // far from everything: no snap, no guide
        let f = CreaLayers.moved(start, dx: 0.05, dy: 0.05, w: 0.2, h: 0.1, others: [])
        XCTAssertTrue(near(f.frame.x, 0.25) && near(f.frame.y, 0.25))
        XCTAssertEqual(f.guides, [])
        // Option held: no snapping
        let n = CreaLayers.moved(start, dx: -0.14, dy: 0, w: 0.3, h: 0.1, others: [], snapping: false)
        XCTAssertTrue(near(n.frame.x, 0.06))
        XCTAssertEqual(n.guides, [])
    }

    func testMoveStaysInside() {
        let r = CreaLayers.moved(CreaLayerFrame(x: 0.5, y: 0.5), dx: 0.9, dy: -0.9, w: 0.3, h: 0.2, others: [])
        XCTAssertTrue(near(r.frame.x, 0.7) && near(r.frame.y, 0))
        // a box wider than the picture sits at its left edge
        let w = CreaLayers.clamp(CreaLayerFrame(x: 0.3, y: 0.1), w: 1.2, h: 0.1)
        XCTAssertTrue(near(w.x, 0))
    }

    func testResizeFollowsTheWidthWithinBounds() {
        let s = CreaLayerFrame(x: 0.1, y: 0.1, scale: 1)
        XCTAssertTrue(near(CreaLayers.resized(s, w0: 0.4, dx: 0.2).scale, 1.5))
        XCTAssertTrue(near(CreaLayers.resized(s, w0: 0.4, dx: -0.39).scale, CreaLayers.minScale))
        XCTAssertTrue(near(CreaLayers.resized(s, w0: 0.1, dx: 0.9).scale, CreaLayers.maxScale))
        XCTAssertEqual(CreaLayers.resized(s, w0: 0.4, dx: 0.2).x, 0.1)
        XCTAssertEqual(CreaLayers.resized(s, w0: 0, dx: 0.2), s)
    }

    func testNudge() {
        let f = CreaLayerFrame(x: 0.1, y: 0.1)
        XCTAssertTrue(near(CreaLayers.nudged(f, dx: 1, dy: 0, big: false, w: 0.2, h: 0.1).x, 0.105))
        XCTAssertTrue(near(CreaLayers.nudged(f, dx: 0, dy: -1, big: true, w: 0.2, h: 0.1).y, 0.075))
        XCTAssertTrue(near(CreaLayers.nudged(CreaLayerFrame(x: 0, y: 0), dx: -1, dy: -1, big: true, w: 0.2, h: 0.1).x, 0))
    }

    func testUndoHistory() {
        var h = CreaLayerHistory()
        var a = CreaLayout(); a["h"] = CreaLayerFrame(x: 0.1, y: 0.1)
        var b = a; b["h"] = CreaLayerFrame(x: 0.2, y: 0.1)
        XCTAssertFalse(h.canUndo)
        h.record(a, after: a)            // nothing changed: not a step
        XCTAssertFalse(h.canUndo)
        h.record(a, after: b)
        XCTAssertTrue(h.canUndo)
        XCTAssertEqual(h.undo(), a)
        XCTAssertNil(h.undo())
        for i in 0..<(CreaLayerHistory.cap + 10) {
            var x = CreaLayout(); x["h"] = CreaLayerFrame(x: Double(i) / 100, y: 0)
            h.record(x, after: b)
        }
        XCTAssertEqual(h.past.count, CreaLayerHistory.cap)
        XCTAssertEqual(h.past.first?["h"]?.x, 0.1)   // the oldest ten went
    }

    func testBookKeepsTheNewestAndRoundTrips() {
        var book = CreaLayoutBook()
        for i in 0..<(CreaLayoutBook.cap + 5) {
            var l = CreaLayout(); l["h"] = CreaLayerFrame(x: 0.1, y: Double(i) / 1000)
            book.put(l, for: "p\(i)")
        }
        XCTAssertEqual(book.order.count, CreaLayoutBook.cap)
        XCTAssertNil(book.layouts["p0"])
        XCTAssertNotNil(book.layouts["p\(CreaLayoutBook.cap + 4)"])
        var again = book.layouts["p10"]!
        again["h"]?.x = 0.5
        book.put(again, for: "p10")
        XCTAssertEqual(book.order.last, "p10")
        let back = CreaLayoutBook.decoded(book.encoded())
        XCTAssertEqual(back, book)
        XCTAssertEqual(CreaLayoutBook.decoded(Data("nope".utf8)), CreaLayoutBook())
        book.remove("p10")
        XCTAssertNil(book.layouts["p10"])
        XCTAssertFalse(book.order.contains("p10"))
    }

    func testCropBoxForFit() {
        // 1024 x 1536 (2:3) -> 4:5 is 1024 x 1280, centred
        let b = CreaLayers.cropBox(w: 1024, h: 1536, ratio: "4:5")
        XCTAssertEqual(b?.w, 1024)
        XCTAssertEqual(b?.h, 1280)
        XCTAssertEqual(b?.y, 128)
        let wide = CreaLayers.cropBox(w: 1536, h: 1024, ratio: "1:1")
        XCTAssertEqual(wide?.x, 256)
        XCTAssertEqual(wide?.w, 1024)
        XCTAssertNil(CreaLayers.cropBox(w: 1024, h: 1024, ratio: "1:1"))
        XCTAssertNil(CreaLayers.cropBox(w: 1024, h: 1024, ratio: nil))
        XCTAssertNil(CreaLayers.cropBox(w: 1024, h: 1024, ratio: "x:y"))
    }

    func testEstimateAndSizes() {
        let h = CreaLayer(id: "headline", kind: .headline, text: String(repeating: "word ", count: 12), color: "#FFFFFF")
        let one = CreaLayers.estimate(h, scale: 1, aspect: 1)
        XCTAssertTrue(one.w <= CreaLayers.wrap(.headline, scale: 1) + 1e-9)
        XCTAssertTrue(one.h > 2 * 0.085)   // wraps to more than two lines
        let big = CreaLayers.estimate(h, scale: 2, aspect: 1)
        XCTAssertTrue(big.h > one.h)
        XCTAssertTrue(near(CreaLayers.wrap(.headline, scale: 2), CreaLayers.maxWrap))
        // the font follows the shorter side: the same size on 9:16 and 16:9 of one short side
        XCTAssertTrue(near(CreaLayers.fontSize(.headline, scale: 1, w: 1080, h: 1920), CreaLayers.fontSize(.headline, scale: 1, w: 1920, h: 1080)))
        let cta = CreaLayers.estimate(CreaLayer(id: "cta", kind: .cta, text: "Go", color: "#111111", bg: "#FFFFFF"), scale: 1, aspect: 1)
        XCTAssertTrue(cta.w > 0 && cta.h > 0.04)
    }

    func testEditedWordsLiveInTheLayout() {
        let l = CreaLayer(id: "h", kind: .headline, text: "Old words", color: "#FFFFFF")
        var lay = CreaLayout()
        lay["h"] = CreaLayerFrame(x: 0.1, y: 0.2, scale: 1.5)
        XCTAssertEqual(CreaLayers.edited(l, in: lay).text, "Old words")
        let f = CreaLayers.withText(lay["h"]!, typed: "  New   words ", original: l.text)
        XCTAssertEqual(f.text, "New words")
        XCTAssertEqual(f.scale, 1.5)
        lay["h"] = f
        XCTAssertEqual(CreaLayers.edited(l, in: lay).text, "New words")
        XCTAssertEqual(CreaLayers.edited(l, in: lay).id, "h")
        // the block's own words, or nothing typed, clear the edit
        XCTAssertNil(CreaLayers.withText(f, typed: "Old words", original: l.text).text)
        XCTAssertNil(CreaLayers.withText(f, typed: "   ", original: l.text).text)
        // a nudge keeps the words
        XCTAssertEqual(CreaLayers.nudged(f, dx: 1, dy: 0, big: false, w: 0.2, h: 0.1).text, "New words")
        // an old saved layout (no text) still decodes
        let old = Data(#"{"layouts":{"p":{"frames":{"h":{"x":0.1,"y":0.2,"scale":1}}}},"order":["p"]}"#.utf8)
        XCTAssertNil(CreaLayoutBook.decoded(old).layouts["p"]?["h"]?.text)
        XCTAssertEqual(CreaLayoutBook.decoded(old).layouts["p"]?["h"]?.x, 0.1)
    }

    // The fields Crea can drive (font, plate, colours, place, size) and the person's style on top.
    func testBlockReadsStyleAndPlacement() {
        let json = """
        {"stage":"final","images":[{"id":"f","n":1,"url":"/intelligence/plot?k=f","key":"ai/m/att/crea/f.png"}],
         "layers":[{"kind":"headline","text":"Hi","color":"#000","font":"New York","align":"centre","plate":{"on":true,"color":"#FFE","opacity":0.6},"x":0.2,"y":"30%","w":0.5,"scale":5},
                   {"kind":"cta","text":"Go","plate":"off"},
                   {"kind":"sub","text":"More","x":50},
                   {"kind":"body","text":"Long words","font":"condensed","plate":false}]}
        """
        guard let c = CreaImages(block(json)) else { return XCTFail("block not read") }
        let h = c.layers[0]
        XCTAssertEqual(h.font, .serif)
        XCTAssertEqual(h.align, .center)
        XCTAssertTrue(h.plate)
        XCTAssertTrue(near(h.plateOpacity, 0.6))
        XCTAssertEqual(h.w, 0.5)
        XCTAssertTrue(h.styledByCrea)
        XCTAssertTrue(near(CreaLayers.wrap(h, scale: 3), 0.5))
        XCTAssertEqual(c.layers[3].kind, .body)
        XCTAssertEqual(c.layers[3].font, .condensed)
        XCTAssertFalse(c.layers[3].plate)
        XCTAssertEqual(h.bg, "#FFFFEE")
        XCTAssertEqual(h.x, 0.2)
        XCTAssertTrue(near(h.y ?? -1, 0.3))
        XCTAssertEqual(h.scale, CreaLayers.maxScale)
        XCTAssertFalse(c.layers[1].plate)
        XCTAssertEqual(c.layers[1].color, "#FFFFFF")
        XCTAssertTrue(near(c.layers[2].x ?? -1, 0.5))
        XCTAssertNil(c.layers[2].y)
        XCTAssertFalse(c.images[0].isDraft)
        XCTAssertEqual(CreaFont.read("sans-serif"), .sans)
        XCTAssertEqual(CreaFont.read("SF Mono"), .mono)
        XCTAssertNil(CreaFont.read(""))
    }

    func testCreaPlacementWinsOverAStaleMove() {
        let size: (CreaLayer) -> (w: Double, h: Double) = { _ in (0.3, 0.1) }
        let placed = CreaLayer(id: "h", kind: .headline, text: "Hi", color: "#FFFFFF", x: 0.4, y: 0.5)
        // nothing of the person's: Crea's place
        XCTAssertEqual(CreaLayers.resolved([placed], own: nil, seed: nil, size: size)["h"], CreaLayerFrame(x: 0.4, y: 0.5))
        // the person moved it against this very layer: theirs
        var own = CreaLayout()
        own["h"] = CreaLayers.stamped(CreaLayerFrame(x: 0.1, y: 0.1), for: placed)
        XCTAssertEqual(CreaLayers.resolved([placed], own: own, seed: nil, size: size)["h"]?.x, 0.1)
        // Crea moved it since: Crea's
        let moved = CreaLayer(id: "h", kind: .headline, text: "Hi", color: "#FFFFFF", x: 0.6, y: 0.2, scale: 1.4)
        XCTAssertEqual(CreaLayers.resolved([moved], own: own, seed: nil, size: size)["h"], CreaLayerFrame(x: 0.6, y: 0.2, scale: 1.4))
        // a layer Crea does not place keeps the person's move whatever else changed
        let free = CreaLayer(id: "h", kind: .headline, text: "Other", color: "#FFFFFF")
        XCTAssertEqual(CreaLayers.resolved([free], own: own, seed: nil, size: size)["h"]?.x, 0.1)
    }

    func testStyleOverridesGiveWayToCrea() {
        let l = CreaLayer(id: "h", kind: .headline, text: "Hi", color: "#FFFFFF")
        var lay = CreaLayout()
        lay["h"] = CreaLayers.styled(CreaLayerFrame(x: 0.1, y: 0.1), for: l, color: "#e63946", plate: true, font: .serif)
        let e = CreaLayers.edited(l, in: lay)
        XCTAssertEqual(e.color, "#E63946")
        XCTAssertTrue(e.plate)
        XCTAssertEqual(e.font, .serif)
        XCTAssertEqual(e.plateColor, "#FFFFFF")   // a light plate under dark words
        // the block's own value clears the override
        let back = CreaLayers.styled(lay["h"]!, for: l, font: .sans)
        XCTAssertNil(back.font)
        // Crea recoloured the layer: the person's style gives way, and a new change starts clean
        let crea = CreaLayer(id: "h", kind: .headline, text: "Hi", color: "#111111")
        XCTAssertEqual(CreaLayers.edited(crea, in: lay), crea)
        let fresh = CreaLayers.stamped(lay["h"]!, for: crea)
        XCTAssertNil(fresh.color)
        XCTAssertNil(fresh.font)
        XCTAssertEqual(fresh.basis, crea.signature)
        // an old unstamped edit gives way once Crea styles the layer itself
        var old = CreaLayout(); old["h"] = CreaLayerFrame(x: 0.1, y: 0.1, text: "Mine")
        XCTAssertEqual(CreaLayers.edited(l, in: old).text, "Mine")
        let styled = CreaLayer(id: "h", kind: .headline, text: "Hi", color: "#FFFFFF", font: .mono, styledByCrea: true)
        XCTAssertEqual(CreaLayers.edited(styled, in: old).text, "Hi")
        // a nudge keeps the style
        XCTAssertEqual(CreaLayers.nudged(lay["h"]!, dx: 1, dy: 0, big: false, w: 0.2, h: 0.1).font, .serif)
    }

    func testTextShownDefaultsAndChoice() {
        let draft = CreaImages.Picture(id: "d", n: 1, url: "u", key: "k", idea: "", w: nil, h: nil, isDraft: true)
        let final = CreaImages.Picture(id: "f", n: 1, url: "u", key: "k", idea: "", w: nil, h: nil)
        let ls = [CreaLayer(id: "h", kind: .headline, text: "Hi", color: "#FFFFFF")]
        var t = CreaTextShown()
        XCTAssertFalse(t.isOn(draft))
        XCTAssertTrue(t.isOn(final))
        XCTAssertTrue(t.layers(ls, for: draft).isEmpty)
        t.set(true, for: draft)
        t.set(false, for: final)
        XCTAssertEqual(t.layers(ls, for: draft).count, 1)
        XCTAssertFalse(t.isOn(final))
        let back = CreaTextShown.decoded(t.encoded())
        XCTAssertEqual(back, t)
        // back to the default: nothing kept
        t.set(false, for: draft)
        XCTAssertNil(t.on["d"])
        // a drafts block marks its pictures
        let d = CreaImages(data: JSONRead.object(Data(layered.utf8)) ?? [:])
        XCTAssertEqual(d?.images.allSatisfy(\.isDraft), true)
    }
}
