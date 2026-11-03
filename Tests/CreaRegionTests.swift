import XCTest
import Foundation
@testable import Liaison

/// Edit area (Shared/Core/CreaRegion.swift): the box, the cut, the sizes, the soft edge, the request.
final class CreaRegionTests: XCTestCase {
    private func near(_ a: Double, _ b: Double, _ eps: Double = 1e-9) -> Bool { abs(a - b) < eps }

    func testClickMakesBoxOfShorterSide() {
        let b = CreaRegion.around(x: 500, y: 400, w: 1000, h: 800)
        XCTAssertTrue(near(b.w, 240) && near(b.h, 240))
        XCTAssertTrue(near(b.midX, 500) && near(b.midY, 400))
    }

    func testClickNearEdgeStaysInside() {
        let b = CreaRegion.around(x: 5, y: 795, w: 1000, h: 800)
        XCTAssertTrue(near(b.x, 0))
        XCTAssertTrue(near(b.maxY, 800))
        XCTAssertTrue(near(b.w, 240))
    }

    func testDrawnBoxNormalisedAndCut() {
        guard let b = CreaRegion.drawn(from: (900, 700), to: (1200, 100), w: 1000, h: 800) else { return XCTFail("no box") }
        XCTAssertEqual(b, CreaArea(x: 900, y: 100, w: 100, h: 600))
        XCTAssertNil(CreaRegion.drawn(from: (10, 10), to: (14, 300), w: 1000, h: 800))
    }

    func testResizeKeepsOppositeCorner() {
        let b = CreaArea(x: 100, y: 100, w: 200, h: 200)
        let r = CreaRegion.resized(b, corner: .bottomRight, to: 500, 450, w: 1000, h: 800)
        XCTAssertEqual(r, CreaArea(x: 100, y: 100, w: 400, h: 350))
        // dragged past the opposite corner: the minimum side, the opposite corner fixed
        let s = CreaRegion.resized(b, corner: .topLeft, to: 900, 900, w: 1000, h: 800)
        XCTAssertTrue(near(s.maxX, 300) && near(s.maxY, 300))
        XCTAssertTrue(near(s.w, CreaRegion.minSide(w: 1000, h: 800)))
        // outside the picture: cut to it
        let o = CreaRegion.resized(b, corner: .topLeft, to: -50, -50, w: 1000, h: 800)
        XCTAssertEqual(o, CreaArea(x: 0, y: 0, w: 300, h: 300))
    }

    func testCornerHitAndMove() {
        let b = CreaArea(x: 100, y: 100, w: 200, h: 200)
        XCTAssertEqual(CreaRegion.corner(near: 296, 304, of: b, radius: 10), .bottomRight)
        XCTAssertNil(CreaRegion.corner(near: 200, 200, of: b, radius: 10))
        XCTAssertEqual(CreaRegion.moved(b, dx: 900, dy: -500, w: 1000, h: 800), CreaArea(x: 800, y: 0, w: 200, h: 200))
    }

    func testPixelsRoundOutwards() {
        XCTAssertEqual(CreaRegion.pixels(CreaArea(x: 10.4, y: 20.6, w: 100.2, h: 50.1), w: 1000, h: 800),
                       CreaPixelRect(x: 10, y: 20, w: 101, h: 51))
    }

    func testCropPadsAndClamps() {
        let inner = CreaPixelRect(x: 400, y: 300, w: 200, h: 100)
        XCTAssertEqual(CreaRegion.crop(inner, w: 1000, h: 800), CreaPixelRect(x: 350, y: 275, w: 300, h: 150))
        let edge = CreaPixelRect(x: 0, y: 750, w: 200, h: 50)
        XCTAssertEqual(CreaRegion.crop(edge, w: 1000, h: 800), CreaPixelRect(x: 0, y: 737, w: 250, h: 63))
    }

    func testSendSize() {
        let a = CreaRegion.sendSize(w: 2048, h: 1024)
        XCTAssertEqual(a.w, 1024); XCTAssertEqual(a.h, 512); XCTAssertTrue(near(a.scale, 0.5))
        let b = CreaRegion.sendSize(w: 600, h: 300)
        XCTAssertEqual(b.w, 600); XCTAssertEqual(b.h, 300); XCTAssertTrue(near(b.scale, 1))
    }

    func testFeatherBandAndMask() {
        let inner = CreaPixelRect(x: 400, y: 300, w: 200, h: 100)
        let crop = CreaRegion.crop(inner, w: 1000, h: 800)
        let f = CreaRegion.feather(inner: inner, crop: crop)
        XCTAssertEqual(f, CreaRegion.Feather(w: 300, h: 150, left: 50, top: 25, right: 50, bottom: 25))
        // full inside the box, nearly nothing at the cut's edge, rising across the margin
        XCTAssertTrue(near(CreaRegion.alpha(x: 150, y: 75, f), 1))
        XCTAssertTrue(CreaRegion.alpha(x: 0, y: 75, f) < 0.01)
        XCTAssertTrue(CreaRegion.alpha(x: 150, y: 149, f) < 0.02)
        XCTAssertTrue(CreaRegion.alpha(x: 10, y: 75, f) < CreaRegion.alpha(x: 30, y: 75, f))
        let m = CreaRegion.mask(f)
        XCTAssertEqual(m.count, 300 * 150)
        XCTAssertEqual(m[75 * 300 + 150], 255)
        XCTAssertEqual(m[75 * 300 + 0], 0)
        XCTAssertEqual(m[75 * 300 + 299], 0)
    }

    func testFeatherNoBandAtPictureEdge() {
        let inner = CreaPixelRect(x: 0, y: 0, w: 100, h: 100)
        let crop = CreaRegion.crop(inner, w: 1000, h: 800)
        let f = CreaRegion.feather(inner: inner, crop: crop)
        XCTAssertEqual(f.left, 0); XCTAssertEqual(f.top, 0); XCTAssertEqual(f.right, 25)
        XCTAssertTrue(near(CreaRegion.alpha(x: 0, y: 0, f), 1))
    }

    func testRequestAndReply() {
        let b = CreaRegion.body(profile: "p1", png: Data([1, 2, 3]), instruction: "make him\nsmile")
        XCTAssertEqual(b["profile"] as? String, "p1")
        XCTAssertEqual(b["mode"] as? String, "region")
        XCTAssertEqual(b["image"] as? String, "AQID")
        XCTAssertTrue((b["prompt"] as? String ?? "").contains("Change only this: make him smile."))

        let ok = CreaRegion.Reply.parse(["ok": true, "image_b64": "data:image/png;base64,AQID", "cost": 0.04])
        XCTAssertTrue(ok.ok)
        XCTAssertEqual(ok.imageData, Data([1, 2, 3]))
        XCTAssertEqual(ok.cost, 0.04)
        let url = CreaRegion.Reply.parse(["ok": true, "image_url": "/intelligence/plot?k=x"])
        XCTAssertEqual(url.imageURL, "/intelligence/plot?k=x")
        let bad = CreaRegion.Reply.parse(["ok": false, "error": "Limit reached."], status: 200)
        XCTAssertEqual(bad.error, "Limit reached.")
        XCTAssertFalse(bad.ok)
        let missing = CreaRegion.Reply.parse([:], status: 404)
        XCTAssertEqual(missing.error, "Editing an area is not available on the server yet.")
    }

    func testVersions() {
        var v = CreaVersions(files: ["v10.png", "v2.png", "x.png", "v1.png"])
        XCTAssertEqual(v.names, ["v1.png", "v2.png", "v10.png"])
        XCTAssertEqual(v.nextName, "v11.png")
        XCTAssertEqual(v.undo(), "v10.png")
        XCTAssertEqual(v.current, "v2.png")
        var e = CreaVersions()
        XCTAssertFalse(e.canUndo)
        XCTAssertEqual(e.nextName, "v1.png")
        for i in 1...(CreaVersions.cap + 2) { e.push("v\(i).png") }
        XCTAssertEqual(e.names.count, CreaVersions.cap)
        XCTAssertEqual(e.names.first, "v3.png")
    }

    // MARK: - the cut in the model's shape, the answer fitted back, the box on screen

    func testModelRatioIsTheNearestShape() {
        XCTAssertEqual(CreaRegion.modelRatio(w: 450, h: 330).name, "4:3")
        XCTAssertEqual(CreaRegion.modelRatio(w: 300, h: 300).name, "1:1")
        XCTAssertEqual(CreaRegion.modelRatio(w: 300, h: 725).name, "9:16")
        XCTAssertEqual(CreaRegion.modelRatio(w: 1000, h: 560).name, "16:9")
        XCTAssertEqual(CreaRegion.modelRatio(w: 0, h: 5).name, "1:1")
    }

    func testConformGrowsTheCutToTheShapeAndKeepsTheBox() {
        // a portrait photo 900 x 1200, a box 300 x 220: the padded cut is 450 x 330 (1.36) -> 4:3, 450 x 338
        let inner = CreaPixelRect(x: 250, y: 200, w: 300, h: 220)
        let loose = CreaRegion.crop(inner, w: 900, h: 1200)
        XCTAssertEqual(loose, CreaPixelRect(x: 175, y: 145, w: 450, h: 330))
        let c = CreaRegion.conform(loose, inner: inner, ratio: 4.0 / 3, w: 900, h: 1200)
        XCTAssertEqual(c, CreaPixelRect(x: 175, y: 141, w: 450, h: 338))
        XCTAssertTrue(abs(Double(c.w) / Double(c.h) - 4.0 / 3) / (4.0 / 3) < 0.01)
        XCTAssertTrue(c.x <= inner.x && c.y <= inner.y && c.x + c.w >= inner.x + inner.w && c.y + c.h >= inner.y + inner.h)
    }

    func testConformAtThePictureEdgeShortensTheLongSideNeverIntoTheBox() {
        // too narrow a picture to widen: the height is cut to the shape instead, around the box
        let inner = CreaPixelRect(x: 0, y: 100, w: 300, h: 500)
        let loose = CreaRegion.crop(inner, w: 300, h: 1000)
        XCTAssertEqual(loose, CreaPixelRect(x: 0, y: 0, w: 300, h: 725))
        let c = CreaRegion.conform(loose, inner: inner, ratio: 9.0 / 16, w: 300, h: 1000)
        XCTAssertEqual(c, CreaPixelRect(x: 0, y: 96, w: 300, h: 533))
        // no shape holds the box: the cut as it was
        let tall = CreaPixelRect(x: 0, y: 0, w: 300, h: 900)
        let all = CreaRegion.crop(tall, w: 300, h: 1000)
        XCTAssertEqual(CreaRegion.conform(all, inner: tall, ratio: 9.0 / 16, w: 300, h: 1000), all)
        // inside the picture at the bottom-right corner
        let corner = CreaPixelRect(x: 900, y: 700, w: 100, h: 100)
        let k = CreaRegion.conform(CreaRegion.crop(corner, w: 1000, h: 800), inner: corner, ratio: 16.0 / 9, w: 1000, h: 800)
        XCTAssertTrue(k.x >= 0 && k.y >= 0 && k.x + k.w <= 1000 && k.y + k.h <= 800)
        XCTAssertTrue(k.x <= 900 && k.y <= 700)
    }

    func testAnAnswerOfAnotherShapeIsCroppedNotStretched() {
        // a square answer for a 4:3 cut: its centred 4:3 band
        XCTAssertEqual(CreaRegion.matchShape(w: 1024, h: 1024, toW: 400, toH: 300), CreaPixelRect(x: 0, y: 128, w: 1024, h: 768))
        XCTAssertEqual(CreaRegion.matchShape(w: 1024, h: 1024, toW: 300, toH: 400), CreaPixelRect(x: 128, y: 0, w: 768, h: 1024))
        // the model's own 1K size for 4:3 (1184 x 864, 2.8% wide) is scaled, not cropped
        XCTAssertNil(CreaRegion.matchShape(w: 1184, h: 864, toW: 450, toH: 338))
        XCTAssertNil(CreaRegion.matchShape(w: 900, h: 676, toW: 450, toH: 338))
    }

    func testViewMapAspectFillAndStretch() {
        // the view has the picture's shape: the old width-only factor (3 pixels a point)
        let same = CreaRegion.ViewMap(view: (300, 400), pixels: (900, 1200), fill: true)
        XCTAssertTrue(near(same.pixel(100, 100).x, 300) && near(same.pixel(100, 100).y, 300))
        // a portrait picture filling a landscape box: scaled by the width, centred, its top and bottom cut
        let m = CreaRegion.ViewMap(view: (390, 313), pixels: (900, 1200), fill: true)
        XCTAssertTrue(near(m.sx, 390.0 / 900) && near(m.sy, m.sx))
        XCTAssertTrue(near(m.oy, (313 - 1200 * 390.0 / 900) / 2) && near(m.ox, 0))
        let p = m.pixel(195, 156.5)
        XCTAssertTrue(near(p.x, 450) && near(p.y, 600))   // the view's centre is the picture's centre
        let v = m.view(CreaArea(x: 450, y: 600, w: 90, h: 120))
        XCTAssertTrue(near(v.x, 195) && near(v.y, 156.5) && near(v.w, 39) && near(v.h, 52))
        let d = m.pixelDelta(39, 0)
        XCTAssertTrue(near(d.x, 90) && near(d.y, 0))
        // stretched (a layered picture): each axis its own factor
        let s = CreaRegion.ViewMap(view: (400, 300), pixels: (800, 900), fill: false)
        XCTAssertTrue(near(s.pixel(400, 300).x, 800) && near(s.pixel(400, 300).y, 900))
        XCTAssertTrue(near(s.pixelsPerPoint, 3))
    }

    func testTheRequestNamesTheCutsShape() {
        XCTAssertEqual(CreaRegion.body(profile: "p", png: Data([1]), instruction: "x", aspect: "4:3")["aspect"] as? String, "4:3")
        XCTAssertNil(CreaRegion.body(profile: "p", png: Data([1]), instruction: "x", aspect: "7:3")["aspect"])
        XCTAssertNil(CreaRegion.body(profile: "p", png: Data([1]), instruction: "x")["aspect"])
    }
}
