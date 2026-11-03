import XCTest
import Foundation
@testable import Liaison

/// the strip shrinks its tabs instead of scrolling; history rows' second line; the page's tint.
final class TabFitTests: XCTestCase {
    private let l = TabFit.Limits()

    func testFewTabsTakeTheMaxWidth() {
        let items = [TabFit.Item.tab(selected: true), .tab(), .tab()]
        let r = TabFit.fit(items, available: 2000)
        XCTAssertEqual(r.widths, [220, 220, 220])
        XCTAssertTrue(r.hidden.isEmpty)
        XCTAssertEqual(r.used, 220 * 3 + 2 * 2)
    }

    func testIdealWidthIsEveryTabAtMax() {
        let items = [TabFit.Item.tab(), .tab()]
        XCTAssertEqual(TabFit.fit(items, available: .infinity).used, 442)
    }

    func testTabsShareTheRoomEqually() {
        let items = Array(repeating: TabFit.Item.tab(), count: 10)
        let r = TabFit.fit(items, available: 1000)
        XCTAssertTrue(r.hidden.isEmpty)
        XCTAssertTrue(r.used <= 1000)
        XCTAssertTrue(r.used > 990)
        XCTAssertEqual(Set(r.widths).count, 1)
        XCTAssertEqual(r.share, r.widths[0])
    }

    func testSelectedNeverUnderItsMinimumOthersShrinkToFavicon() {
        var items = Array(repeating: TabFit.Item.tab(), count: 12)
        items[5] = .tab(selected: true)
        // 11 x 36 + 56 + 11 x 2 = 474
        let r = TabFit.fit(items, available: 480)
        XCTAssertTrue(r.hidden.isEmpty)
        XCTAssertEqual(r.widths[5], 56)
        XCTAssertTrue(r.widths[0] >= 36)
        XCTAssertTrue(r.used <= 480)
    }

    func testPastTheMinimumsTheLastTabsGoToTheMenuNeverTheSelected() {
        var items = Array(repeating: TabFit.Item.tab(), count: 20)
        items[19] = .tab(selected: true)
        let r = TabFit.fit(items, available: 300)
        XCTAssertFalse(r.hidden.isEmpty)
        XCTAssertFalse(r.hidden.contains(19))
        XCTAssertEqual(r.widths[19], 56)
        XCTAssertTrue(r.used <= 300)
        // The hidden ones are the last loose tabs before the selected one.
        XCTAssertEqual(r.hidden, Array(19 - r.hidden.count..<19))
        for i in r.hidden { XCTAssertEqual(r.widths[i], 0) }
    }

    func testHeadersShrinkWithTheTabsAndKeepTheirGroupWhileATabShows() {
        let items: [TabFit.Item] = [.header(120, group: 0), .tab(group: 0), .tab(group: 0), .tab(selected: true)]
        let wide = TabFit.fit(items, available: 2000)
        XCTAssertEqual(wide.widths[0], 120)
        let narrow = TabFit.fit(items, available: 200)
        XCTAssertTrue(narrow.widths[0] < 120)
        XCTAssertTrue(narrow.widths[0] >= l.minHeader)
        XCTAssertTrue(narrow.used <= 200)
        // So little room that the group's tabs leave: its header leaves after them, never before.
        let tiny = TabFit.fit(items, available: 60)
        XCTAssertEqual(tiny.hidden, [0, 1, 2])
    }

    func testFixedItemsKeepTheirSize() {
        let items: [TabFit.Item] = [.header(80, group: 0, fixed: true), .tab(group: 0, fixed: true, width: 36), .tab(), .tab(selected: true)]
        let r = TabFit.fit(items, available: 250)
        XCTAssertEqual(r.widths[0], 80)
        XCTAssertEqual(r.widths[1], 36)
        XCTAssertFalse(r.hidden.contains(0))
        XCTAssertFalse(r.hidden.contains(1))
        // 80 + 36 + 4 (group) + 3 gaps
        XCTAssertEqual(r.used, 80 + 36 + 4 + 6 + r.widths[2] + r.widths[3])
    }

    func testGroupPaddingCounts() {
        let items: [TabFit.Item] = [.header(50, group: 0), .tab(group: 0)]
        XCTAssertEqual(TabFit.fit(items, available: 2000).used, 50 + 220 + 2 + 4)
    }

    // MARK: history rows

    func testHistoryDetailShowsHostAndPath() {
        XCTAssertEqual(HistoryDetail.line(URL(string: "https://www.acme.app/admin/students/")), "acme.app/admin/students")
        XCTAssertEqual(HistoryDetail.line(URL(string: "https://acme.app/")), "acme.app")
        XCTAssertEqual(HistoryDetail.line(URL(string: "https://acme.app/?page=2")), "acme.app?page=2")
        XCTAssertNil(HistoryDetail.line(nil))
    }

    func testHistoryDetailShortensLongPaths() {
        let u = URL(string: "https://crm.acme.app/admin/school/branches/milano-centro/students/enrolments/2026")
        let s = HistoryDetail.line(u) ?? ""
        XCTAssertTrue(s.count <= HistoryDetail.maxLength)
        XCTAssertTrue(s.hasPrefix("crm.acme.app/"))
        XCTAssertTrue(s.hasSuffix("2026"))
        XCTAssertTrue(s.contains("\u{2026}"))
    }

    // MARK: the page's tint

    func testAverageOfAStrip() {
        // two opaque pixels (red, blue), one transparent
        let px: [UInt8] = [255, 0, 0, 255, 0, 0, 255, 255, 0, 0, 0, 0]
        XCTAssertEqual(PageTint.average(rgba: px, count: 3), 0x7F007F)
        XCTAssertNil(PageTint.average(rgba: [0, 0, 0, 0], count: 1))
        // premultiplied half-alpha white reads as white
        XCTAssertEqual(PageTint.average(rgba: [128, 128, 128, 128], count: 1), 0xFFFFFF)
    }

    func testGlyphsAndNoise() {
        XCTAssertTrue(PageTint.onDark(0x1877F2))
        XCTAssertTrue(PageTint.onDark(0x24292F))
        XCTAssertFalse(PageTint.onDark(0xFFFFFF))
        XCTAssertFalse(PageTint.onDark(0xBFDBFE))
        XCTAssertFalse(PageTint.differs(0x102030, 0x112131))
        XCTAssertTrue(PageTint.differs(0x102030, 0x1A2030))
        XCTAssertTrue(PageTint.differs(nil, 0x102030))
        XCTAssertEqual(PageTint.mix(0x000000, 0xFFFFFF, 0.5), 0x808080)
        XCTAssertEqual(PageTint.fade(0xF1F2F4), 0xF1F2F4)
    }
}

/// the page's top band as a gradient, the tint's timing, where a new tab goes.
final class TintFieldTests: XCTestCase {
    /// `w` x `h` opaque pixels, the colour of each column from `columnColor`.
    private func band(_ w: Int, _ h: Int, _ columnColor: (Int, Int) -> UInt32) -> [UInt8] {
        var px: [UInt8] = []
        for y in 0..<h {
            for x in 0..<w {
                let c = columnColor(x, y)
                px += [UInt8((c >> 16) & 0xFF), UInt8((c >> 8) & 0xFF), UInt8(c & 0xFF), 255]
            }
        }
        return px
    }

    func testGridAveragesEachCell() {
        // left half black, right half white, 14 x 4 pixels into 7 x 2 cells
        let px = band(14, 4) { x, _ in x < 7 ? 0x000000 : 0xFFFFFF }
        let f = PageTint.field(rgba: px, width: 14, height: 4)
        XCTAssertEqual(f?.columns, 7)
        XCTAssertEqual(f?.rows, 2)
        XCTAssertEqual(f?.at(0, 0), 0x000000)
        XCTAssertEqual(f?.at(6, 1), 0xFFFFFF)
        // the middle cell straddles the edge: half and half
        XCTAssertEqual(f?.at(3, 0), 0x7F7F7F)
    }

    func testRowsKeepTheVerticalChange() {
        let px = band(7, 2) { _, y in y == 0 ? 0x2040A0 : 0x4060C0 }
        let f = PageTint.field(rgba: px, width: 7, height: 2)
        XCTAssertEqual(f?.row(0), Array(repeating: 0x2040A0, count: 7))
        XCTAssertEqual(f?.row(1), Array(repeating: 0x4060C0, count: 7))
        // the bar's top continues the change upward (darker still), clamped
        XCTAssertEqual(f?.barTopStops(lift: 0.5).first?.color, 0x103090)
    }

    func testTransparentCellsBorrowANeighbour() {
        var px = band(7, 1) { _, _ in 0x336699 }
        px[3 * 4 + 3] = 0   // cell 3 transparent
        let f = PageTint.field(rgba: px, width: 7, height: 1, columns: 7, rows: 1)
        XCTAssertEqual(f?.at(3, 0), 0x336699)
        XCTAssertNil(PageTint.field(rgba: [UInt8](repeating: 0, count: 7 * 4), width: 7, height: 1))
        XCTAssertNil(PageTint.field(rgba: [], width: 7, height: 1))
    }

    func testTinyImagesNeverCrash() {
        let px = band(1, 1) { _, _ in 0xABCDEF }
        let f = PageTint.field(rgba: px, width: 1, height: 1)
        XCTAssertEqual(f?.columns, 1)
        XCTAssertEqual(f?.average, 0xABCDEF)
    }

    func testStopsSpanTheWindowAndFollowThePage() {
        let colors: [UInt32] = [0x000000, 0x000000, 0x000000, 0x808080, 0xFFFFFF, 0xFFFFFF, 0xFFFFFF]
        let f = TintField(columns: 7, rows: 1, colors: colors, x0: 0.1, x1: 0.9)
        let s = f.barStops
        XCTAssertEqual(s.first?.location, 0)
        XCTAssertEqual(s.last?.location, 1)
        XCTAssertEqual(s.count, 9)
        for k in 1..<s.count { XCTAssertTrue(s[k].location > s[k - 1].location) }
        // diffusion softens the hard step: the middle column is a mix, the edges stay
        XCTAssertEqual(s.first?.color, 0x000000)
        XCTAssertEqual(s.last?.color, 0xFFFFFF)
        XCTAssertTrue(f.color(atX: 0.5) > 0x404040 && f.color(atX: 0.5) < 0xC0C0C0)
        // glyph contrast per region
        XCTAssertTrue(f.onDark(atX: 0.05))
        XCTAssertFalse(f.onDark(atX: 0.95))
    }

    func testSolidAndDiffs() {
        let a = TintField.solid(0x112233)
        XCTAssertEqual(a.barStops.map(\.color), [0x112233, 0x112233])
        XCTAssertEqual(a.average, 0x112233)
        XCTAssertFalse(a.differs(from: TintField.solid(0x122334)))
        XCTAssertTrue(a.differs(from: TintField.solid(0x332211)))
        XCTAssertTrue(a.differs(from: TintField(columns: 2, rows: 1, colors: [0x112233, 0x112233])))
        // a short list is padded, a reversed span is put right
        let b = TintField(columns: 3, rows: 2, colors: [1], x0: 0.8, x1: 0.2)
        XCTAssertEqual(b.colors.count, 6)
        XCTAssertEqual(b.x0, 0.2)
        XCTAssertEqual(b.x1, 0.8)
        XCTAssertEqual(PageTint.extend(0x808080, away: 0xFFFFFF, 1), 0x010101)
        XCTAssertEqual(PageTint.mean([0x000000, 0xFFFFFF]), 0x808080)
    }

    func testTimingStaysInsideTheRule() {
        for t in [TintTiming.early, TintTiming.settle, TintTiming.scrollEnd, TintTiming.keyScrollEnd, TintTiming.transition] {
            XCTAssertTrue(TintTiming.reaction.contains(t), "\(t)")
        }
        XCTAssertTrue(TintTiming.scrollThrottle <= 0.15)
        XCTAssertTrue(TintTiming.early < TintTiming.settle)
        XCTAssertTrue(TintTiming.sampleWhileScrolling(now: 10.2, last: 10))
        XCTAssertFalse(TintTiming.sampleWhileScrolling(now: 10.05, last: 10))
    }

    func testNewTabGoesToTheEnd() {
        typealias S = TabStrip.Slot
        let slots = [S(group: nil, pinned: true), S(group: "g", pinned: false), S(group: "g", pinned: false),
                     S(group: nil, pinned: false), S(group: "h", pinned: false)]
        XCTAssertEqual(TabStrip.newTabIndex(slots), 5)
        XCTAssertEqual(TabStrip.newTabIndex([]), 0)
        // in a group: after its last tab
        XCTAssertEqual(TabStrip.newTabIndex(slots, group: "g"), 3)
        XCTAssertEqual(TabStrip.newTabIndex(slots, group: "none"), 5)
        // appended at the end, the strip's order keeps it there (outside every group)
        var after = slots
        after.append(S(group: nil, pinned: false))
        XCTAssertEqual(TabStrip.order(after, pinnedGroups: ["g"]).last, 5)
        XCTAssertEqual(TabStrip.order(after, pinnedGroups: []).last, 5)
    }

    func testSkyGlowInWindowCoordinates() {
        let look = Sky.look(phase: .day, condition: .clear)
        let card = CGRect(x: 10, y: 50, width: 1000, height: 800)
        guard let g = Sky.glow(look, card: card) else { return XCTFail("a clear day has a glow") }
        XCTAssertTrue(abs(Double(g.center.x) - (10 + look.glowX * 1000)) < 0.001)
        XCTAssertTrue(abs(Double(g.center.y) - (50 + look.glowY * 544)) < 0.001)
        XCTAssertTrue(abs(g.radius - 450) < 0.001)
        XCTAssertEqual(Sky.skyHeight(cardHeight: 100), 460)
        XCTAssertNil(Sky.glow(Sky.look(phase: .day, condition: .storm), card: card))
    }
}
