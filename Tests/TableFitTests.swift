import XCTest
import Foundation
@testable import Liaison

/// A Markdown table always fits the message; it scrolls only when its columns would be unreadable.
final class TableFitTests: XCTestCase {
    private func col(_ min: CGFloat, _ natural: CGFloat) -> TableFit.Column { TableFit.Column(min: min, natural: natural) }

    func testFittingTableFillsTheWidthInProportion() {
        let r = TableFit.fit([col(40, 100), col(40, 300)], available: 800)
        XCTAssertFalse(r.scrolls)
        XCTAssertEqual(r.widths, [200, 600])
        XCTAssertEqual(r.total, 800)
    }

    /// The reported case: a short name column and a long description: the name keeps its width, the description
    /// takes the rest and wraps.
    func testShortColumnKeepsNaturalLongOneTakesTheRest() {
        let r = TableFit.fit([col(80, 120), col(90, 1400)], available: 500)
        XCTAssertFalse(r.scrolls)
        XCTAssertEqual(r.widths, [120, 380])
        XCTAssertEqual(r.total, 500)
    }

    func testLongColumnsShareEqually() {
        let r = TableFit.fit([col(50, 60), col(60, 900), col(60, 700)], available: 460)
        XCTAssertFalse(r.scrolls)
        XCTAssertEqual(r.widths, [60, 200, 200])
    }

    func testNeverWiderThanTheRoomWhenItFits() {
        let cols = [col(30, 90), col(120, 500), col(40, 260), col(10, 40)]
        for avail in stride(from: TableFit.minimumWidth(cols), through: 1200, by: 7) {
            let r = TableFit.fit(cols, available: avail)
            XCTAssertFalse(r.scrolls)
            XCTAssertTrue(abs(r.total - avail) < 0.01, "total \(r.total) at \(avail)")
            for (i, w) in r.widths.enumerated() {
                XCTAssertTrue(w + 0.01 >= min(cols[i].natural, TableFit.readable), "column \(i) at \(avail): \(w)")
            }
        }
    }

    func testLongWordKeptWholeWhenOthersStayReadable() {
        // A URL column (min 220) next to prose: the URL keeps its width, the prose wraps in the rest.
        let r = TableFit.fit([col(220, 240), col(60, 900)], available: 400)
        XCTAssertEqual(r.widths, [220, 180])
    }

    func testLongWordBreaksRatherThanMakingAnotherColumnUnreadable() {
        let r = TableFit.fit([col(300, 320), col(60, 900)], available: 300)
        XCTAssertFalse(r.scrolls)
        XCTAssertEqual(r.widths, [150, 150])
    }

    func testTooManyColumnsScroll() {
        let cols = Array(repeating: col(60, 400), count: 8)
        XCTAssertEqual(TableFit.minimumWidth(cols), 8 * 70)
        let r = TableFit.fit(cols, available: 400)
        XCTAssertTrue(r.scrolls)
        XCTAssertEqual(r.widths, Array(repeating: TableFit.scrollColumn, count: 8))
        XCTAssertTrue(r.total > 400)
    }

    func testNarrowContentColumnsNeverForceScrolling() {
        // Ten tiny columns ("1", "2" ...) fit in less than ten times `readable`.
        let cols = Array(repeating: col(12, 20), count: 10)
        XCTAssertEqual(TableFit.minimumWidth(cols), 200)
        XCTAssertFalse(TableFit.fit(cols, available: 220).scrolls)
    }

    func testScrollWidthsRespectContent() {
        XCTAssertEqual(TableFit.scrollWidths([col(10, 40), col(30, 900), col(500, 600)]), [40, 200, 360])
    }

    func testIdealWidthWithoutRoom() {
        let r = TableFit.fit([col(10, 40), col(30, 90)], available: .infinity)
        XCTAssertEqual(r.widths, [40, 90])
        XCTAssertFalse(r.scrolls)
        XCTAssertEqual(TableFit.fit([], available: 300), TableFit.Result(widths: [], scrolls: false))
    }

    func testNaturalNeverBelowMin() {
        XCTAssertEqual(col(80, 50).natural, 80)
    }
}
