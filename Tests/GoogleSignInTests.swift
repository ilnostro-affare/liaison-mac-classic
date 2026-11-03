import XCTest
import Foundation
@testable import Liaison

/// Continue with Google with no second confirmation, the app forward only on success, and Add
/// Account in the person's own browser. Pure parts of Shared/Core/MacSignIn.swift; the server's and the page's half is
/// The server's tests in the web repo.
final class GoogleSignInTests: XCTestCase {
    private let tok = String(repeating: "a", count: 40) + "B-_"

    /// The direct round asks link_required to go on in the browser (the page with gf), not back through the app.
    func testStartAsksForThePage() {
        let u = MacSignIn.googleStartURL(base: "https://mcp.liaisone.com", challenge: tok)!
        let q = URLComponents(url: u, resolvingAgainstBaseURL: false)!.queryItems!
        // Next=app replaced next=page (no web page at all); the server keeps next=page for 0.2.11.
        // Next=ms (Memberstack's Google on meta-mcp's own page, no code); next=app stays on the server.
        XCTAssertEqual(q.first { $0.name == "next" }?.value, "ms")
        XCTAssertEqual(q.first { $0.name == "cc" }?.value, tok, "the verifier's challenge, which the page's deposit is bound to")
        XCTAssertNil(q.first { $0.name == "gf" }, "gf is made by the server after Google, never by the app")
    }

    /// The page's answer for a direct round is liaison://auth/handoff, which the Google round owns.
    func testHandoffAnswerBelongsToTheGoogleRound() {
        let h = URL(string: "liaison://auth/handoff?code=" + tok)!
        XCTAssertEqual(MacSignIn.incoming(h), .google)
        XCTAssertEqual(MacSignIn.callback(h), .code(tok))
        XCTAssertEqual(MacSignIn.googleCallback(h), .unrelated, "not the server's own answer: collected at /auth/handoff/collect")
    }

    /// The pending link riding on the hand-over: token-shaped, on a 200 ok only.
    func testHandoffLink() {
        XCTAssertEqual(MacSignIn.handoffLink(status: 200, json: ["ok": true, "state": "signed_in", "link": tok]), tok)
        XCTAssertNil(MacSignIn.handoffLink(status: 200, json: ["ok": true, "state": "signed_in"]), "a plain hand-over has none")
        XCTAssertNil(MacSignIn.handoffLink(status: 200, json: ["ok": true, "link": "short"]))
        XCTAssertNil(MacSignIn.handoffLink(status: 200, json: ["ok": true, "link": 42]))
        XCTAssertNil(MacSignIn.handoffLink(status: 410, json: ["ok": false, "link": tok]))
        XCTAssertNil(MacSignIn.handoffLink(status: 200, json: ["ok": false, "link": tok]))
    }

    /// Only a sign-in or something to read brings the app forward; a round still in the browser does not.
    func testComesForwardOnlyOnSuccessOrAMessage() {
        XCTAssertTrue(MacSignIn.comesForward(.signedIn))
        XCTAssertTrue(MacSignIn.comesForward(.tell))
        XCTAssertFalse(MacSignIn.comesForward(.inBrowser), "an older server's link_required: the page reopens in the browser")
        XCTAssertFalse(MacSignIn.comesForward(.quiet), "cancelled at Google, or a link that is not ours")
    }

    /// Adding an account: the workspace window hands the browser's answer to the open round of that provider only.
    func testWorkspaceDeliversToTheAddingRound() {
        XCTAssertTrue(MacSignIn.workspaceDelivers(.google, google: true, waiting: true, adding: true))
        XCTAssertTrue(MacSignIn.workspaceDelivers(.apple, google: false, waiting: true, adding: true))
        XCTAssertFalse(MacSignIn.workspaceDelivers(.apple, google: true, waiting: true, adding: true), "another provider's answer")
        XCTAssertFalse(MacSignIn.workspaceDelivers(.google, google: false, waiting: true, adding: true))
        XCTAssertFalse(MacSignIn.workspaceDelivers(.google, google: true, waiting: false, adding: true), "no round open")
        XCTAssertFalse(MacSignIn.workspaceDelivers(.google, google: true, waiting: true, adding: false), "the first window's sign-in screen takes its own links")
        XCTAssertFalse(MacSignIn.workspaceDelivers(.web, google: true, waiting: true, adding: true))
        XCTAssertFalse(MacSignIn.workspaceDelivers(.other, google: true, waiting: true, adding: true))
    }
}
