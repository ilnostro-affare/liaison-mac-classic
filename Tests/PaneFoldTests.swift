import XCTest
import Foundation
@testable import Liaison

/// The conversation sheet's right side folds; what unfolds it by itself.
final class PaneFoldTests: XCTestCase {
    func testOnlyFoldedUnfolds() {
        XCTAssertFalse(PaneFold.autoUnfolds(.canvasArrived, folded: false, sinceFold: nil))
        XCTAssertTrue(PaneFold.autoUnfolds(.canvasArrived, folded: true, sinceFold: nil))
        XCTAssertTrue(PaneFold.autoUnfolds(.newTab, folded: true, sinceFold: 10))
        XCTAssertTrue(PaneFold.autoUnfolds(.navigated, folded: true, sinceFold: 2.5))
        XCTAssertTrue(PaneFold.autoUnfolds(.gateOpened, folded: true, sinceFold: 60))
    }

    func testActivityNeverUnfolds() {
        XCTAssertFalse(PaneFold.autoUnfolds(.activity, folded: true, sinceFold: nil))
        XCTAssertFalse(PaneFold.autoUnfolds(.activity, folded: true, sinceFold: 100))
    }

    func testGraceAfterTheFold() {
        XCTAssertFalse(PaneFold.autoUnfolds(.canvasArrived, folded: true, sinceFold: 0))
        XCTAssertFalse(PaneFold.autoUnfolds(.gateOpened, folded: true, sinceFold: 1.9))
        XCTAssertTrue(PaneFold.autoUnfolds(.gateOpened, folded: true, sinceFold: 2))
    }

    func testNewPlace() {
        let u = { (s: String) in URL(string: s) }
        XCTAssertTrue(PaneFold.isNewPlace(from: u("https://a.com/x"), to: u("https://b.com/x")))
        XCTAssertTrue(PaneFold.isNewPlace(from: u("https://a.com/x"), to: u("https://a.com/y")))
        XCTAssertTrue(PaneFold.isNewPlace(from: nil, to: u("https://a.com/")))
        XCTAssertFalse(PaneFold.isNewPlace(from: u("https://a.com/x"), to: u("https://a.com/x")))
        XCTAssertFalse(PaneFold.isNewPlace(from: u("https://a.com/x"), to: u("https://a.com/x/")))
        XCTAssertFalse(PaneFold.isNewPlace(from: u("https://A.com/x?q=1"), to: u("https://a.com/x?q=2#top")))
        XCTAssertFalse(PaneFold.isNewPlace(from: u("https://a.com"), to: u("https://a.com/")))
        XCTAssertFalse(PaneFold.isNewPlace(from: u("https://a.com/x"), to: nil))
        XCTAssertFalse(PaneFold.isNewPlace(from: u("https://a.com/x"), to: u("about:blank")))
    }
}
