import XCTest
import Foundation
@testable import Liaison

/// ("we remove the web from public today; the web must have nothing to do with it"): the Mac's
/// account flows with no liaisone.com page. Pure parts of Shared/Core/MacSignIn.swift and AccountActions.swift; the
/// server's half is the server's tests in the web repo.
final class AuthNoWebTests: XCTestCase {
    private let tok = String(repeating: "a", count: 40) + "B-_"

    private func query(_ u: URL?) -> [String: String] {
        var out: [String: String] = [:]
        for i in URLComponents(url: u!, resolvingAgainstBaseURL: false)?.queryItems ?? [] { out[i.name] = i.value ?? "" }
        return out
    }

    /// Continue with Google never opens a liaisone.com page: Google directly, whatever this Mac remembers.:
    /// next=ms (an existing account goes on to meta-mcp's own Memberstack page, not to liaisone.com).
    func testSignInStartsWithNextMs() {
        let q = query(MacSignIn.googleStartURL(base: "https://mcp.liaisone.com", challenge: tok))
        XCTAssertEqual(q["next"], "ms")
        XCTAssertNil(q["intent"], "a sign-in is never a connect round")
        XCTAssertTrue(MacSignIn.flow(pageFirst: true) == .direct)
        XCTAssertFalse(MacSignIn.googleStartURL(base: "https://mcp.liaisone.com", challenge: tok)!.absoluteString.contains("signin/mac"))
    }

    /// Settings' Connect: the same start with intent=link and no next.
    func testConnectStartsWithIntentLink() {
        let u = MacSignIn.googleConnectURL(base: "https://mcp.liaisone.com", challenge: tok)
        XCTAssertEqual(u?.host, "mcp.liaisone.com")
        XCTAssertEqual(u?.path, "/auth/google/start")
        let q = query(u)
        XCTAssertEqual(q["intent"], "link")
        XCTAssertEqual(q["cc"], tok)
        XCTAssertEqual(q["scheme"], "liaison")
        XCTAssertNil(q["next"])
        XCTAssertEqual(query(MacSignIn.googleConnectURL(base: "https://mcp.liaisone.com", challenge: tok, scheme: "liaison-dev"))["scheme"], "liaison-dev")
        XCTAssertNil(MacSignIn.googleConnectURL(base: "https://mcp.liaisone.com", challenge: "short"))
    }

    func testCodeRequiredIsRead() {
        let ok: [String: Any] = ["ok": true, "state": "code_required", "link": tok, "email": "Ann@Gmail.com", "sent": true, "user_message": "Enter it."]
        XCTAssertEqual(MacSignIn.googleCodeRequired(status: 200, json: ok),
                       MacSignIn.CodeRequired(link: tok, email: "ann@gmail.com", sent: true, message: "Enter it."))
        var notSent = ok; notSent["sent"] = false
        XCTAssertEqual(MacSignIn.googleCodeRequired(status: 200, json: notSent)?.sent, false)
        var bad = ok; bad["link"] = "short"
        XCTAssertNil(MacSignIn.googleCodeRequired(status: 200, json: bad), "a link that is not token-shaped is no link")
        var other = ok; other["state"] = "link_required"
        XCTAssertNil(MacSignIn.googleCodeRequired(status: 200, json: other))
        XCTAssertNil(MacSignIn.googleCodeRequired(status: 410, json: ok))
        // Apple's collect reads code_required as nothing it knows: the Google path must look for it first
        XCTAssertEqual(MacSignIn.googleCollect(status: 200, json: ok), .failed("Google sign-in did not finish. Try again."))
    }

    func testFinishOutcomes() {
        let t = "eyA.eyB.sig"
        XCTAssertEqual(MacSignIn.googleFinish(status: 200, json: ["ok": true, "state": "signed_in", "member_token": t, "email": "A@B.com", "linked": true]),
                       .signedIn(memberToken: t, email: "a@b.com", linked: true))
        XCTAssertEqual(MacSignIn.googleFinish(status: 200, json: ["ok": true, "state": "signed_in", "member_token": t, "email": "a@b.com"]),
                       .signedIn(memberToken: t, email: "a@b.com", linked: false))
        XCTAssertEqual(MacSignIn.googleFinish(status: 200, json: ["ok": true, "state": "signed_in", "member_token": "nope"]),
                       .failed("Google sign-in did not finish. Try again."), "a token that is not a JWT never signs in")
        XCTAssertEqual(MacSignIn.googleFinish(status: 400, json: ["ok": false, "error": "bad_code"]), .retry("That code is not right or has expired."))
        XCTAssertEqual(MacSignIn.googleFinish(status: 410, json: ["ok": false, "user_message": "Gone."]), .restart("Gone."))
        XCTAssertEqual(MacSignIn.googleFinish(status: 403, json: [:]), .restart("This sign-in has expired. Choose Continue with Google again."))
    }

    func testConnectReadyAndMessages() {
        XCTAssertEqual(MacSignIn.googleConnectReady(status: 200, json: ["ok": true, "state": "link_ready", "link": tok, "email": "A@x.com"])?.email, "a@x.com")
        XCTAssertNil(MacSignIn.googleConnectReady(status: 200, json: ["ok": true, "state": "signed_in", "link": tok]),
                     "a sign-in answer is never taken for a connect")
        XCTAssertNil(AccountActions.connectMessage(status: 200, json: ["ok": true, "state": "linked"]))
        XCTAssertEqual(AccountActions.connectMessage(status: 403, json: ["ok": false, "error": "email_mismatch", "user_message": "This Google account uses x, not y."]),
                       "This Google account uses x, not y.")
        XCTAssertEqual(AccountActions.connectMessage(status: 0, json: [:]), "Could not reach Liaison. Check your connection.")
        XCTAssertNil(AccountActions.connectError("cancelled"))
        XCTAssertEqual(AccountActions.connectError("email_unverified"), "Google did not confirm that account's email, so it cannot be connected.")
        XCTAssertNotNil(MacSignIn.googleMessage(forError: "google_disconnected"))
    }

    func testGoogleStatusAndUnlink() {
        XCTAssertEqual(AccountActions.googleStatus(status: 200, json: ["ok": true, "connected": true, "google_email": "A@gmail.com"]),
                       AccountActions.GoogleState(connected: true, email: "a@gmail.com"))
        XCTAssertEqual(AccountActions.googleStatus(status: 200, json: ["ok": true, "connected": false, "google_email": "x@y.z"]),
                       AccountActions.GoogleState(connected: false, email: ""))
        XCTAssertNil(AccountActions.googleStatus(status: 401, json: ["ok": false]), "no answer: the row keeps Memberstack's providers")
        XCTAssertNil(AccountActions.googleStatus(status: 200, json: ["ok": true]))
        XCTAssertNil(AccountActions.unlinkMessage(status: 200, json: ["ok": true, "state": "unlinked"]))
        XCTAssertNil(AccountActions.unlinkMessage(status: 200, json: ["ok": true, "state": "not_connected"]))
        XCTAssertEqual(AccountActions.unlinkMessage(status: 502, json: [:]), "Google could not be disconnected. Try again.")
    }

    func testEmailRules() {
        XCTAssertTrue(AccountActions.canSend(new: " New@Mail.com ", current: "old@mail.com"))
        XCTAssertFalse(AccountActions.canSend(new: "OLD@mail.com", current: "old@mail.com"), "the same address is not a change")
        XCTAssertFalse(AccountActions.canSend(new: "nope", current: "old@mail.com"))
        XCTAssertFalse(AccountActions.canSend(new: "a@b.c", current: ""), "a one-letter top-level domain")
        XCTAssertFalse(AccountActions.canSend(new: "a <b>@c.com", current: ""))
        XCTAssertEqual(AccountActions.codeDigits("12 3-4a567"), "123456")
        XCTAssertEqual(AccountActions.codeDigits("١٢٣"), "", "only ASCII digits")
    }

    func testEmailAnswers() {
        XCTAssertEqual(AccountActions.start(status: 200, json: ["ok": true, "state": "code_sent", "email": "New@Mail.com"]), .codeSent(email: "new@mail.com"))
        XCTAssertEqual(AccountActions.start(status: 409, json: ["ok": false, "error": "email_in_use", "user_message": "Taken."]), .failed("Taken."))
        XCTAssertEqual(AccountActions.start(status: 429, json: [:]), .failed("Too many attempts. Wait a minute and try again."))
        XCTAssertEqual(AccountActions.start(status: 401, json: [:]), .failed("Your session ended. Sign in again."))
        let t = "eyA.eyB.sig"
        XCTAssertEqual(AccountActions.confirm(status: 200, json: ["ok": true, "state": "changed", "email": "n@m.com", "member_token": t]),
                       .changed(email: "n@m.com", memberToken: t))
        XCTAssertEqual(AccountActions.confirm(status: 200, json: ["ok": true, "state": "changed", "email": "n@m.com", "member_token": "x"]),
                       .changed(email: "n@m.com", memberToken: nil), "a token that is not a JWT is dropped")
        XCTAssertEqual(AccountActions.confirm(status: 400, json: ["user_message": "Wrong."]), .retry("Wrong."))
        XCTAssertEqual(AccountActions.confirm(status: 410, json: [:]), .restart("This change has expired. Your email was not changed."))
        XCTAssertEqual(AccountActions.confirm(status: 502, json: [:]), .failed("The email could not be changed. Try again."))
    }

    /// The token a change hands back replaces the stored one only for the same member.
    func testAdoptsTokenOnlyForTheSameMember() {
        func jwt(_ id: String) -> String {
            let p = Data("{\"id\":\"\(id)\"}".utf8).base64EncodedString().replacingOccurrences(of: "=", with: "")
            return "eyJhbGciOiJIUzI1NiJ9.\(p).sig"
        }
        XCTAssertTrue(AccountActions.adoptsToken(jwt("mem_abcdefgh12"), activeMember: "mem_abcdefgh12"))
        XCTAssertFalse(AccountActions.adoptsToken(jwt("mem_otherone99"), activeMember: "mem_abcdefgh12"))
        XCTAssertFalse(AccountActions.adoptsToken(nil, activeMember: "mem_abcdefgh12"))
        XCTAssertFalse(AccountActions.adoptsToken(jwt("mem_abcdefgh12"), activeMember: nil))
    }
}
