import XCTest
import Foundation
@testable import Liaison

/// Several pictures in one message as a fan of cards.
final class PhotoFanTests: XCTestCase {
    func testAnglesPerCount() {
        XCTAssertEqual(PhotoFan.angles(count: 0), [])
        XCTAssertEqual(PhotoFan.angles(count: 1), [0])
        XCTAssertEqual(PhotoFan.angles(count: 2), [-4, 4])
        XCTAssertEqual(PhotoFan.angles(count: 3), [-6, 0, 6])
        XCTAssertEqual(PhotoFan.angles(count: 4), [-8, -3, 3, 8])
        XCTAssertEqual(PhotoFan.angles(count: 9), [-8, -3, 3, 8])
    }

    func testMoreBadge() {
        XCTAssertNil(PhotoFan.more(count: 4))
        XCTAssertNil(PhotoFan.more(count: 2))
        XCTAssertEqual(PhotoFan.more(count: 5), 1)
        XCTAssertEqual(PhotoFan.more(count: 11), 7)
    }

    func testOpenSpreadsWider() {
        let shut = PhotoFan.cards(count: 4, open: false)
        let open = PhotoFan.cards(count: 4, open: true)
        XCTAssertEqual(shut.count, 4)
        for (s, o) in zip(shut, open) {
            XCTAssertTrue(abs(o.angle) >= abs(s.angle))
            XCTAssertTrue(abs(o.x) >= abs(s.x))
        }
        // Symmetric around the common bottom point.
        XCTAssertEqual(shut[0].x, -shut[3].x)
        XCTAssertTrue(shut[0].x < 0)
    }

    func testExtentHoldsTheOpenFan() {
        let one = PhotoFan.extent(count: 1, cardWidth: 98, cardHeight: 73)
        XCTAssertEqual(one.width, 98)
        XCTAssertEqual(one.height, 73)
        XCTAssertEqual(one.lift, 0)
        let four = PhotoFan.extent(count: 4, cardWidth: 98, cardHeight: 73)
        XCTAssertTrue(four.width > 98)
        XCTAssertTrue(four.height > 73)
        XCTAssertTrue(four.lift > 0)
        XCTAssertTrue(four.width < 200)
    }
}
