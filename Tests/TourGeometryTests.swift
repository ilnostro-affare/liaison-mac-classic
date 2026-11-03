import XCTest
import Foundation
@testable import Liaison

final class TourGeometryTests: XCTestCase {
    let win = CGSize(width: 800, height: 600)

    func testHoleClipsAndPads() {
        let h = TourGeometry.hole(CGRect(x: 100, y: 10, width: 120, height: 30), pad: 8, in: win)
        XCTAssertEqual(h, CGRect(x: 92, y: 2, width: 136, height: 46))
    }

    func testHoleOffscreenOrSliverOrHuge() {
        XCTAssertNil(TourGeometry.hole(CGRect(x: 900, y: 10, width: 100, height: 30), pad: 8, in: win))
        XCTAssertNil(TourGeometry.hole(CGRect(x: 100, y: 10, width: 2, height: 2), pad: 0, in: win))
        // Mostly outside (a tab scrolled away at the strip's end).
        XCTAssertNil(TourGeometry.hole(CGRect(x: 780, y: 10, width: 200, height: 30), pad: 0, in: win))
        // Most of the window.
        XCTAssertNil(TourGeometry.hole(CGRect(x: 0, y: 0, width: 790, height: 500), pad: 0, in: win))
        XCTAssertNil(TourGeometry.hole(.zero, pad: 8, in: .zero))
    }

    func testCardBelowAboveAndInside() {
        let card = CGSize(width: 340, height: 160)
        let top = CGRect(x: 700, y: 10, width: 80, height: 30)
        let c = TourGeometry.cardCenter(card: card, hole: top, in: win, margin: 16, gap: 14)
        XCTAssertEqual(c.y, 40 + 14 + 80)
        XCTAssertEqual(c.x, 800 - 16 - 170)   // clamped inside the right edge
        let bottom = CGRect(x: 300, y: 520, width: 200, height: 60)
        let a = TourGeometry.cardCenter(card: card, hole: bottom, in: win, margin: 16, gap: 14)
        XCTAssertEqual(a.y, 520 - 14 - 80)
    }

    func testCardInATinyWindowStaysInside() {
        let small = CGSize(width: 420, height: 300)
        let card = CGSize(width: 340, height: 180)
        let hole = CGRect(x: 20, y: 90, width: 380, height: 80)
        let c = TourGeometry.cardCenter(card: card, hole: hole, in: small, margin: 16, gap: 14)
        XCTAssertTrue(c.x - 170 >= 16)
        XCTAssertTrue(c.x + 170 <= 420 - 16 + 0.001)
        XCTAssertTrue(c.y - 90 >= 16)
        XCTAssertTrue(c.y + 90 <= 300 - 16 + 0.001)
        // No hole: the middle.
        XCTAssertEqual(TourGeometry.cardCenter(card: card, hole: nil, in: small, margin: 16, gap: 14), CGPoint(x: 210, y: 150))
    }

    func testChromeStore() {
        XCTAssertEqual(ChromeStore.id("https://chromewebstore.google.com/detail/bitwarden/nngceckbapebfimnlniiiahkandclblb?hl=en"),
                       "nngceckbapebfimnlniiiahkandclblb")
        XCTAssertNil(ChromeStore.id("https://example.com/x"))
        let anchor = ChromeStore.anchorDate
        XCTAssertEqual(ChromeStore.chromeMajor(on: anchor), 131)
        // About a year later: 13 releases on, one held back.
        XCTAssertEqual(ChromeStore.chromeMajor(on: anchor.addingTimeInterval(52 * 7 * 86_400)), 143)
        let urls = ChromeStore.downloadURLs("nngceckbapebfimnlniiiahkandclblb", on: anchor.addingTimeInterval(52 * 7 * 86_400))
        XCTAssertEqual(urls.count, 3)
        XCTAssertTrue(urls[0].absoluteString.contains("prodversion=143.0.0.0"))
        XCTAssertTrue(urls[0].absoluteString.contains("x=id%3Dnngceckbapebfimnlniiiahkandclblb%26installsource%3Dondemand%26uc"))
        XCTAssertTrue(ChromeStore.isPackage(Data([0x43, 0x72, 0x32, 0x34, 3, 0, 0, 0])))
        XCTAssertTrue(ChromeStore.isPackage(Data([0x50, 0x4B, 0x03, 0x04])))
        XCTAssertFalse(ChromeStore.isPackage(Data("<html>".utf8)))
    }
}
