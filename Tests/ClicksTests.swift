import XCTest
import Foundation
@testable import Liaison

/// 0.2.11: first-click reliability (Shared/Core/Clicks.swift).
final class ClicksTests: XCTestCase {
    func testSmallMovesStayClicks() {
        XCTAssertFalse(LiaClicks.isDrag(dx: 0, dy: 0))
        XCTAssertFalse(LiaClicks.isDrag(dx: 2, dy: 2))      // 2.8 pt: a hand that shook while clicking
        XCTAssertFalse(LiaClicks.isDrag(dx: 3, dy: 0))
        XCTAssertTrue(LiaClicks.isDrag(dx: 4, dy: 0))
        XCTAssertTrue(LiaClicks.isDrag(dx: -3, dy: -3))     // 4.2 pt
        XCTAssertTrue(LiaClicks.dragStart >= 4)
    }

    func testClickKinds() {
        XCTAssertEqual(LiaClicks.kind(clickCount: 0), .single)
        XCTAssertEqual(LiaClicks.kind(clickCount: 1), .single)
        XCTAssertEqual(LiaClicks.kind(clickCount: 2), .double)
        XCTAssertEqual(LiaClicks.kind(clickCount: 3), .double)
    }

    func testPointerThrottle() {
        XCTAssertFalse(LiaClicks.pointerMoved(from: nil, to: nil))
        XCTAssertTrue(LiaClicks.pointerMoved(from: nil, to: CGPoint(x: 1, y: 1)))
        XCTAssertTrue(LiaClicks.pointerMoved(from: CGPoint(x: 1, y: 1), to: nil))
        XCTAssertFalse(LiaClicks.pointerMoved(from: CGPoint(x: 10, y: 10), to: CGPoint(x: 11, y: 11.5)))
        XCTAssertTrue(LiaClicks.pointerMoved(from: CGPoint(x: 10, y: 10), to: CGPoint(x: 12, y: 10)))
        XCTAssertTrue(LiaClicks.pointerMoved(from: CGPoint(x: 10, y: 10), to: CGPoint(x: 10, y: 7)))
    }

    func testChipPresses() {
        XCTAssertTrue(LiaClicks.chipFires(clickCount: 1, chip: 5, lastFired: nil))
        XCTAssertTrue(LiaClicks.chipFires(clickCount: 1, chip: 5, lastFired: 5))     // a new click on it again
        XCTAssertFalse(LiaClicks.chipFires(clickCount: 2, chip: 5, lastFired: 5))    // the double click's second press
        XCTAssertTrue(LiaClicks.chipFires(clickCount: 2, chip: 5, lastFired: nil))   // first press was on the text
        XCTAssertTrue(LiaClicks.chipFires(clickCount: 2, chip: 5, lastFired: 9))     // or on another chip
    }

    func testPopupAccount() {
        let thread = [(id: "act_111", name: "Acme")]
        let known = [(id: "111", name: "Acme Italia"), (id: "222", name: "Other")]
        // the widget's own account and name
        var r = PopupAccountRule.resolve(given: "act_222", givenName: "Given", thread: thread, known: known)
        XCTAssertEqual(r.id, "222"); XCTAssertEqual(r.name, "Given")
        // the widget's account without a name: the known name
        r = PopupAccountRule.resolve(given: "222", givenName: nil, thread: thread, known: known)
        XCTAssertEqual(r.id, "222"); XCTAssertEqual(r.name, "Other")
        // nothing given: the conversation's own account, named from the known list
        r = PopupAccountRule.resolve(given: nil, givenName: "ignored", thread: thread, known: known)
        XCTAssertEqual(r.id, "act_111"); XCTAssertEqual(r.name, "Acme Italia")
        // nothing at all: the first connected one
        r = PopupAccountRule.resolve(given: "", givenName: nil, thread: [], known: known)
        XCTAssertEqual(r.id, "111"); XCTAssertEqual(r.name, "Acme Italia")
        r = PopupAccountRule.resolve(given: nil, givenName: nil, thread: [], known: [])
        XCTAssertEqual(r.id, ""); XCTAssertEqual(r.name, "")
    }

    /// One ad by id opens only on an account known to hold it (rule 11), never the first connected one.
    func testPopupAccountStrictForOneAd() {
        let known = [(id: "111", name: "Acme Italia"), (id: "222", name: "Other")]
        XCTAssertEqual(PopupAccountRule.strict(given: "act_222", givenName: nil, thread: [], known: known)?.id, "222", "the block's own account")
        XCTAssertEqual(PopupAccountRule.strict(given: nil, givenName: nil, thread: [(id: "act_111", name: "Acme")], known: known)?.id, "act_111",
                       "the conversation's only account")
        XCTAssertNil(PopupAccountRule.strict(given: nil, givenName: nil, thread: [], known: known), "no account said: refuse, not the first connected")
        XCTAssertNil(PopupAccountRule.strict(given: "", givenName: nil, thread: [(id: "1", name: "A"), (id: "2", name: "B")], known: known),
                     "a conversation over two accounts does not say which")
        XCTAssertFalse(PopupAccountRule.unknownAccount.isEmpty)
    }
}
