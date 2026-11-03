import XCTest
import Foundation
@testable import Liaison

/// The browser's answer brings Liaison forward the moment it arrives, only for a round in
/// progress. Pure parts of Shared/Core/MacSignIn.swift; the page's half (Memberstack in live mode, a spinner instead of
/// a second Continue with Google) is the server's tests in the web repo.
final class GoogleSignInLiveKeyTests: XCTestCase {
    private let tok = String(repeating: "a", count: 40) + "B-_"

    func testAnswerToTheWaitingRoundComesForwardOnArrival() {
        let handoff = URL(string: "liaison://auth/handoff?code=\(tok)")!
        let google = URL(string: "liaison://auth/google?code=\(tok)")!
        let apple = URL(string: "liaison://auth/apple?code=\(tok)")!
        XCTAssertTrue(MacSignIn.comesForwardOnArrival(MacSignIn.incoming(handoff), googleWaiting: true, appleWaiting: false),
                      "the page's hand-over (success only) brings the app forward before the collect")
        XCTAssertTrue(MacSignIn.comesForwardOnArrival(MacSignIn.incoming(google), googleWaiting: true, appleWaiting: false))
        XCTAssertTrue(MacSignIn.comesForwardOnArrival(MacSignIn.incoming(apple), googleWaiting: false, appleWaiting: true))
    }

    func testNothingComesForwardWithoutItsRound() {
        let handoff = URL(string: "liaison://auth/handoff?code=\(tok)")!
        let apple = URL(string: "liaison://auth/apple?code=\(tok)")!
        XCTAssertFalse(MacSignIn.comesForwardOnArrival(MacSignIn.incoming(handoff), googleWaiting: false, appleWaiting: true),
                       "Google's answer while only Apple waits: not this round's")
        XCTAssertFalse(MacSignIn.comesForwardOnArrival(MacSignIn.incoming(apple), googleWaiting: true, appleWaiting: false))
        XCTAssertFalse(MacSignIn.comesForwardOnArrival(MacSignIn.incoming(URL(string: "https://example.com/")!), googleWaiting: true, appleWaiting: true),
                       "a web page is never an auth answer")
        XCTAssertFalse(MacSignIn.comesForwardOnArrival(MacSignIn.incoming(URL(string: "liaison://open?x=1")!), googleWaiting: true, appleWaiting: true))
    }

    func testRetriesAreFewAndShort() {
        XCTAssertFalse(MacSignIn.frontRetries.isEmpty)
        XCTAssertTrue(MacSignIn.frontRetries.count <= 3)
        XCTAssertEqual(MacSignIn.frontRetries, MacSignIn.frontRetries.sorted())
        XCTAssertTrue((MacSignIn.frontRetries.last ?? 9) <= 2)
    }
}
