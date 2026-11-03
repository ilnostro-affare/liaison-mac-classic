import XCTest
import Foundation
@testable import Liaison

/// The sign-in screen's pure rules (Shared/Core/MacSignIn.swift): the landing's new vs existing email, its
/// sources and Free plan, and Continue with Google through the default browser. The server's half is tested in the
/// web repo.
final class MacSignInTests: XCTestCase {
    private let tok = String(repeating: "a", count: 40) + "B-_"

    func testSourcesAreTheLandingsInItsOrder() {
        XCTAssertEqual(MacSignIn.sources.map(\.id), ["google", "instagram", "chatgpt", "claude", "direct", "other"])
        XCTAssertEqual(MacSignIn.sources.map(\.label), ["Google", "Instagram", "ChatGPT", "Claude", "Referral", "Other"])
        XCTAssertEqual(MacSignIn.sourceValue("direct"), "direct", "Referral is saved as direct, like the web")
        XCTAssertEqual(MacSignIn.sourceValue(nil), "other", "no answer is saved as other, like src||'other'")
        XCTAssertEqual(MacSignIn.sourceValue("tiktok"), "other", "a value the web does not offer is never saved")
    }

    func testSignupBodyIsTheLandings() {
        let b = MacSignIn.signupBody(email: "a@b.co", code: "123456", source: "claude")
        XCTAssertEqual(b["email"] as? String, "a@b.co")
        XCTAssertEqual(b["passwordlessToken"] as? String, "123456")
        XCTAssertEqual(b["plans"] as? [[String: String]], [["planId": "pln_free-example1"]])
        XCTAssertEqual(b["customFields"] as? [String: String], ["acquisition-source": "claude"])
        XCTAssertNil(b["captchaToken"], "passwordless signup takes no captcha (Memberstack checks it on the password branch only)")
        XCTAssertNotNil(try? JSONSerialization.data(withJSONObject: b), "the body serialises as JSON")
    }

    func testNewOrExistingFromTheSignupSend() {
        XCTAssertEqual(MacSignIn.signupSend(status: 200, json: ["data": ["success": true]]), .newMember)
        XCTAssertEqual(MacSignIn.signupSend(status: 400, json: ["code": "email-already-in-use", "message": "x"]), .existing)
        XCTAssertEqual(MacSignIn.signupSend(status: 400, json: ["error": ["code": "x", "message": "This email is already in use."]]), .existing)
        XCTAssertEqual(MacSignIn.signupSend(status: 409, json: ["message": "Member exists"]), .existing)
        XCTAssertEqual(MacSignIn.signupSend(status: 200, json: ["data": [:], "error": ["code": "email-already-in-use"]]), .existing,
                       "an error inside a 200 (the DOM's res.data.error) is an error")
        XCTAssertEqual(MacSignIn.signupSend(status: 400, json: ["code": "invalid-email"]), .failed)
        XCTAssertEqual(MacSignIn.signupSend(status: 429, json: [:]), .failed)
        XCTAssertEqual(MacSignIn.signupSend(status: 0, json: [:]), .failed)
    }

    func testErrorPartsReadBothShapes() {
        XCTAssertEqual(MacSignIn.errorParts(["code": "a", "message": "b"]).code, "a")
        XCTAssertEqual(MacSignIn.errorParts(["error": ["code": "c", "message": "d"]]).message, "d")
        XCTAssertEqual(MacSignIn.errorParts([:]).code, "")
    }

    func testAccessToken() {
        XCTAssertEqual(MacSignIn.accessToken(["data": ["tokens": ["accessToken": "eyA.B.C"]]]), "eyA.B.C")
        XCTAssertNil(MacSignIn.accessToken(["data": ["tokens": ["accessToken": "lsess_x"]]]))
        XCTAssertNil(MacSignIn.accessToken([:]))
    }

    /// The page (the fallback).
    func testGoogleURL() {
        let u = MacSignIn.googleURL(site: "https://liaisone.com", challenge: tok)
        XCTAssertEqual(u?.absoluteString, "https://liaisone.com/signin/mac/?provider=google&cc=" + tok)
        XCTAssertNil(MacSignIn.googleURL(site: "https://liaisone.com", challenge: "short"))
    }

    /// An existing member's Google goes on to the page by itself (auto=google, the email's hint); Liaison Dev's scheme.
    func testGoogleURLForAnExistingMember() {
        let h = String(repeating: "h", count: 43)
        XCTAssertEqual(MacSignIn.googleURL(site: "https://liaisone.com", challenge: tok, scheme: "liaison", auto: true, hint: h)?.absoluteString,
                       "https://liaisone.com/signin/mac/?provider=google&cc=\(tok)&auto=google&eh=\(h)")
        XCTAssertEqual(MacSignIn.googleURL(site: "https://liaisone.com", challenge: tok, scheme: "liaison-dev", auto: true, hint: nil)?.absoluteString,
                       "https://liaisone.com/signin/mac/?provider=google&cc=\(tok)&scheme=liaison-dev&auto=google", "no hint: no eh")
        XCTAssertEqual(MacSignIn.googleURL(site: "https://liaisone.com", challenge: tok, scheme: "liaison", auto: true, hint: "short")?.absoluteString,
                       "https://liaisone.com/signin/mac/?provider=google&cc=\(tok)&auto=google", "a malformed hint is never sent")
        XCTAssertEqual(MacSignIn.googleURL(site: "https://liaisone.com", challenge: tok, scheme: "liaison", auto: false, hint: h)?.absoluteString,
                       "https://liaisone.com/signin/mac/?provider=google&cc=" + tok, "the hint only goes with auto")
        XCTAssertEqual(MacSignIn.googleURL(site: "https://liaisone.com", challenge: tok, scheme: "javascript")?.absoluteString,
                       "https://liaisone.com/signin/mac/?provider=google&cc=" + tok, "only liaison-dev is ever sent as a scheme")
    }

    /// Link_required after Google -> the page (no email step); Apple, or a page that could not open -> ask.
    func testLinkNext() {
        XCTAssertEqual(MacSignIn.linkNext(google: true, pageOpened: true), .page)
        XCTAssertEqual(MacSignIn.linkNext(google: true, pageOpened: false), .ask, "no browser could open the page: the email way")
        XCTAssertEqual(MacSignIn.linkNext(google: false, pageOpened: false), .ask, "Apple has no Memberstack equivalent")
        XCTAssertEqual(MacSignIn.linkNext(google: false, pageOpened: true), .ask)
    }

    /// The page's eh is sha256(cc + ":" + email); the page lowercases and trims the same way.
    func testEmailHintInput() {
        XCTAssertEqual(MacSignIn.emailHintInput(challenge: tok, email: "  Ann@Gmail.COM "), tok + ":ann@gmail.com")
        XCTAssertNil(MacSignIn.emailHintInput(challenge: tok, email: ""))
        XCTAssertNil(MacSignIn.emailHintInput(challenge: tok, email: "nobody"))
        XCTAssertNil(MacSignIn.emailHintInput(challenge: "short", email: "a@b.co"))
    }

    /// The pending link connects only the sign-in it belongs to.
    func testLinkApplies() {
        XCTAssertTrue(MacSignIn.linkApplies(pendingEmail: "ann@gmail.com", email: "Ann@Gmail.com", age: 30))
        XCTAssertTrue(MacSignIn.linkApplies(pendingEmail: "", email: "x@y.co", age: 30), "no email known: the server checks it")
        XCTAssertFalse(MacSignIn.linkApplies(pendingEmail: "ann@gmail.com", email: "bob@gmail.com", age: 30),
                       "another account signed in on the page: not linked")
        XCTAssertFalse(MacSignIn.linkApplies(pendingEmail: "ann@gmail.com", email: "ann@gmail.com", age: 29 * 60))
        XCTAssertFalse(MacSignIn.linkApplies(pendingEmail: "ann@gmail.com", email: "ann@gmail.com", age: -60))
    }

    /// The quiet link's outcome is a log word, never a message.
    func testLinkOutcome() {
        XCTAssertEqual(MacSignIn.linkOutcome(status: 200, json: ["ok": true, "state": "linked", "email": "a@b.co"]), .linked)
        XCTAssertEqual(MacSignIn.linkOutcome(status: 409, json: ["ok": false, "error": "has_password", "user_message": "Own password."]),
                       .notLinked("has_password"))
        XCTAssertEqual(MacSignIn.linkOutcome(status: 403, json: ["error": "email_mismatch"]), .notLinked("email_mismatch"))
        XCTAssertEqual(MacSignIn.linkOutcome(status: 502, json: [:]), .notLinked("http_502"))
        XCTAssertEqual(MacSignIn.linkOutcome(status: 0, json: [:]), .notLinked("network"))
        XCTAssertEqual(MacSignIn.linkOutcome(status: 400, json: ["error": "<b>x</b>"]), .notLinked("http_400"), "only a plain word is logged")
        XCTAssertEqual(MacSignIn.linkOutcome(status: 200, json: ["ok": true, "state": "pending"]), .notLinked("http_200"))
    }

    func testHandoffCallback() {
        XCTAssertEqual(MacSignIn.callback(URL(string: "liaison://auth/handoff?code=" + tok)!), .code(tok))
        XCTAssertEqual(MacSignIn.callback(URL(string: "LIAISON://Auth/handoff?code=" + tok)!), .code(tok))
        XCTAssertEqual(MacSignIn.callback(URL(string: "liaison://auth/handoff?error=cancelled")!), .error("cancelled"))
        XCTAssertEqual(MacSignIn.callback(URL(string: "liaison://auth/handoff?code=short")!), .unrelated)
        XCTAssertEqual(MacSignIn.callback(URL(string: "liaison://auth/apple?code=" + tok)!), .unrelated, "Apple's answer is not Google's")
        XCTAssertEqual(MacSignIn.callback(URL(string: "liaison://github/connect?code=" + tok)!), .unrelated)
        XCTAssertEqual(MacSignIn.callback(URL(string: "https://auth/handoff?code=" + tok)!), .unrelated)
        XCTAssertEqual(MacSignIn.callback(URL(string: "liaison://auth/handoff?error=%3Cb%3E")!), .unrelated)
    }

    func testPendingLivesTenMinutes() {
        let t0 = Date(timeIntervalSince1970: 1_800_000_000)
        XCTAssertTrue(MacSignIn.pendingValid(startedAt: t0, now: t0))
        XCTAssertTrue(MacSignIn.pendingValid(startedAt: t0, now: t0.addingTimeInterval(599)))
        XCTAssertFalse(MacSignIn.pendingValid(startedAt: t0, now: t0.addingTimeInterval(600)))
        XCTAssertFalse(MacSignIn.pendingValid(startedAt: t0, now: t0.addingTimeInterval(-60)), "a clock moved back is not trusted")
    }

    func testCollect() {
        XCTAssertEqual(MacSignIn.collect(status: 200, json: ["ok": true, "state": "signed_in", "member_token": "eyA.B.C", "email": "Ann@X.com"]),
                       .signedIn(memberToken: "eyA.B.C", email: "ann@x.com"))
        XCTAssertEqual(MacSignIn.collect(status: 200, json: ["ok": true, "state": "signed_in", "member_token": "nope"]),
                       .failed("Google sign-in did not finish. Try again."))
        XCTAssertEqual(MacSignIn.collect(status: 410, json: [:]), .failed("This sign-in has expired. Choose Continue with Google again."))
        XCTAssertEqual(MacSignIn.collect(status: 410, json: ["user_message": "Gone."]), .failed("Gone."))
        XCTAssertEqual(MacSignIn.collect(status: 429, json: [:]), .failed("Too many attempts. Wait a minute and try again."))
        XCTAssertEqual(MacSignIn.collect(status: 403, json: ["ok": false, "error": "forbidden"]), .failed("Google sign-in did not finish. Try again."))
    }

    /// Google directly - the server's start address, not the liaisone.com page - is the default.
    func testGoogleGoesStraightToTheServer() {
        XCTAssertEqual(MacSignIn.googleFlow, .direct, "the /signin/mac/ page is the fallback, not the default")
        XCTAssertEqual(MacSignIn.googleStartURL(base: "https://mcp.liaisone.com", challenge: tok)?.absoluteString,
                       "https://mcp.liaisone.com/auth/google/start?cc=\(tok)&scheme=liaison&next=ms")
        XCTAssertEqual(MacSignIn.googleStartURL(base: "https://mcp.liaisone.com", challenge: tok, scheme: "liaison-dev")?.absoluteString,
                       "https://mcp.liaisone.com/auth/google/start?cc=\(tok)&scheme=liaison-dev&next=ms", "Liaison Dev gets its answer back")
        XCTAssertEqual(MacSignIn.googleStartURL(base: "https://mcp.liaisone.com", challenge: tok, scheme: "javascript")?.absoluteString,
                       "https://mcp.liaisone.com/auth/google/start?cc=\(tok)&scheme=liaison&next=ms", "only our two schemes are ever sent")
        XCTAssertNil(MacSignIn.googleStartURL(base: "https://mcp.liaisone.com", challenge: "short"))
        XCTAssertFalse(MacSignIn.googleStartURL(base: "https://mcp.liaisone.com", challenge: tok)!.absoluteString.contains("liaisone.com/signin"))
    }

    func testGoogleCallback() {
        XCTAssertEqual(MacSignIn.googleCallback(URL(string: "liaison://auth/google?code=" + tok)!), .code(tok))
        XCTAssertEqual(MacSignIn.googleCallback(URL(string: "LIAISON://Auth/google?code=" + tok)!), .code(tok))
        XCTAssertEqual(MacSignIn.googleCallback(URL(string: "liaison://auth/google?error=email_unverified")!), .error("email_unverified"))
        XCTAssertEqual(MacSignIn.googleCallback(URL(string: "liaison://auth/google?code=short")!), .unrelated)
        XCTAssertEqual(MacSignIn.googleCallback(URL(string: "liaison://auth/handoff?code=" + tok)!), .unrelated, "the fallback's answer has its own parser")
        XCTAssertEqual(MacSignIn.googleCallback(URL(string: "liaison://auth/apple?code=" + tok)!), .unrelated, "Apple's answer is not Google's")
        XCTAssertEqual(MacSignIn.googleCallback(URL(string: "https://auth/google?code=" + tok)!), .unrelated)
        XCTAssertEqual(MacSignIn.googleCallback(URL(string: "liaison-dev://auth/google?code=" + tok)!), .unrelated,
                       "the release build does not take Liaison Dev's answer")
        XCTAssertEqual(MacSignIn.googleCallback(URL(string: "liaison://auth/google?error=%3Cb%3E")!), .unrelated)
        XCTAssertEqual(MacSignIn.callback(URL(string: "liaison://auth/google?code=" + tok)!), .unrelated, "and the fallback parser does not take it")
        XCTAssertEqual(MacSignIn.incoming(URL(string: "liaison://auth/google?code=" + tok)!), .google)
        XCTAssertEqual(MacSignIn.incoming(URL(string: "liaison://auth/google?error=cancelled")!), .google)
        XCTAssertEqual(MacSignIn.incoming(URL(string: "https://mcp.liaisone.com/auth/google/start?cc=" + tok)!), .web,
                       "the start address coming back to Liaison is a web page, not Google's answer")
    }

    func testGoogleCollect() {
        XCTAssertEqual(MacSignIn.googleCollect(status: 200, json: ["ok": true, "state": "signed_in", "member_token": "eyA.B.C", "email": "Ann@Gmail.com"]),
                       .signedIn(memberToken: "eyA.B.C", email: "ann@gmail.com"))
        XCTAssertEqual(MacSignIn.googleCollect(status: 200, json: ["ok": true, "state": "link_required", "link": tok, "email": "ann@gmail.com",
                                                                  "user_message": "Sign in once the usual way to connect Google."]),
                       .linkRequired(link: tok, email: "ann@gmail.com", message: "Sign in once the usual way to connect Google."))
        XCTAssertEqual(MacSignIn.googleCollect(status: 200, json: ["ok": true, "state": "link_required", "link": tok]),
                       .linkRequired(link: tok, email: "", message: "This email already has a Liaison account. Sign in once with your email to connect Google."))
        XCTAssertEqual(MacSignIn.googleCollect(status: 200, json: ["ok": true, "state": "link_required", "link": "short"]),
                       .failed("Google sign-in did not finish. Try again."))
        XCTAssertEqual(MacSignIn.googleCollect(status: 200, json: ["ok": true, "state": "signed_in", "member_token": "lsess_x"]),
                       .failed("Google sign-in did not finish. Try again."))
        XCTAssertEqual(MacSignIn.googleCollect(status: 410, json: [:]), .failed("This sign-in has expired. Choose Continue with Google again."))
        XCTAssertEqual(MacSignIn.googleCollect(status: 410, json: ["user_message": "Gone."]), .failed("Gone."))
        XCTAssertEqual(MacSignIn.googleCollect(status: 429, json: [:]), .failed("Too many attempts. Wait a minute and try again."))
        XCTAssertEqual(MacSignIn.googleCollect(status: 403, json: ["ok": false, "error": "forbidden"]), .failed("Google sign-in did not finish. Try again."))
    }

    func testGoogleErrorsAndLink() {
        XCTAssertNil(MacSignIn.googleMessage(forError: "cancelled"), "the person said no on Google's page: nothing to say")
        XCTAssertEqual(MacSignIn.googleMessage(forError: "unavailable"), "Continue with Google is not available right now. Use your email.")
        XCTAssertEqual(MacSignIn.googleMessage(forError: "email_unverified"), "Google did not confirm this email. Use your email.")
        XCTAssertEqual(MacSignIn.googleMessage(forError: "busy"), "Too many sign-ins right now. Try again in a minute.")
        XCTAssertEqual(MacSignIn.googleMessage(forError: "memberstack"), "Google sign-in did not finish. Try again.")
        XCTAssertNil(MacSignIn.googleLinkMessage(status: 200, json: ["ok": true, "state": "linked"]))
        XCTAssertEqual(MacSignIn.googleLinkMessage(status: 409, json: ["error": "has_password", "user_message": "Own password."]), "Own password.")
        XCTAssertEqual(MacSignIn.googleLinkMessage(status: 502, json: [:]), "Google could not be connected. You are signed in.")
    }

    func testGoogleBrowserNeverLiaison() {
        let own: Set<String> = ["com.liaisone.mac"]
        let installed = ["com.liaisone.mac", "com.apple.Safari", "com.google.Chrome"]
        XCTAssertNil(MacSignIn.googleBrowser(defaultId: "com.google.Chrome", ownIds: own, previousId: nil, installed: installed))
        XCTAssertEqual(MacSignIn.googleBrowser(defaultId: "com.liaisone.mac", ownIds: own, previousId: "com.apple.Safari", installed: installed), "com.apple.Safari")
        XCTAssertEqual(MacSignIn.googleBrowser(defaultId: "com.liaisone.mac", ownIds: own, previousId: nil, installed: installed), "com.google.Chrome")
        XCTAssertEqual(MacSignIn.googleBrowser(defaultId: "com.liaisone.mac", ownIds: own, previousId: "org.gone", installed: ["com.liaisone.mac", "com.apple.Safari"]), "com.apple.Safari")
        XCTAssertNil(MacSignIn.googleBrowser(defaultId: "com.liaisone.mac", ownIds: own, previousId: nil, installed: ["com.liaisone.mac"]))
    }

    /// Liaison as the default browser hands the signed-out window web pages; they are never an auth answer.
    func testIncomingLinks() {
        XCTAssertEqual(MacSignIn.incoming(URL(string: "liaison://auth/handoff?code=" + tok)!), .google)
        XCTAssertEqual(MacSignIn.incoming(URL(string: "liaison://auth/apple?code=" + tok)!), .apple)
        XCTAssertEqual(MacSignIn.incoming(URL(string: "liaison://auth/apple?error=cancelled")!), .apple)
        XCTAssertEqual(MacSignIn.incoming(URL(string: "https://mcp.liaisone.com/auth/apple/start?app=mac&cc=" + tok)!), .web,
                       "the start address coming back to Liaison is a web page, not Apple's answer")
        XCTAssertEqual(MacSignIn.incoming(URL(string: "HTTP://example.com/")!), .web)
        XCTAssertEqual(MacSignIn.incoming(URL(string: "liaison://settings/general")!), .other)
        XCTAssertEqual(MacSignIn.incoming(URL(string: "mailto:a@b.co")!), .other)
    }

    func testAppleStartAddressGoesToTheServer() {
        let u = AppleSignIn.startURL(base: "https://mcp.liaisone.com", challenge: tok)
        XCTAssertEqual(u?.absoluteString, "https://mcp.liaisone.com/auth/apple/start?app=mac&cc=" + tok)
        XCTAssertNil(AppleSignIn.startURL(base: "https://mcp.liaisone.com", challenge: "short"))
    }

    func testLegalPages() {
        XCTAssertEqual(MacSignIn.termsURL.absoluteString, "https://liaisone.com/terms/")
        XCTAssertEqual(MacSignIn.privacyURL.absoluteString, "https://liaisone.com/privacy/")
    }

    /// Memberstack's /auth/login answers (measured: a wrong password is 401 invalid-credentials).
    func testPasswordFailures() {
        let wrong: [String: Any] = ["code": "invalid-credentials", "message": "The provided credentials are invalid."]
        XCTAssertEqual(MacSignIn.passwordFailure(status: 401, json: wrong), .wrongPassword)
        XCTAssertEqual(MacSignIn.passwordFailure(status: 400, json: ["error": ["code": "invalid-password", "message": "x"]]), .wrongPassword)
        XCTAssertEqual(MacSignIn.passwordFailure(status: 429, json: [:]), .rateLimited)
        XCTAssertEqual(MacSignIn.passwordFailure(status: 0, json: [:]), .network)
        XCTAssertEqual(MacSignIn.passwordFailure(status: 503, json: [:]), .network)
        XCTAssertEqual(MacSignIn.passwordFailure(status: 400, json: ["code": "bad", "message": "Email is not valid."]), .other("Email is not valid."))
        XCTAssertEqual(MacSignIn.passwordFailure(status: 403, json: ["code": "captcha-required"]), .other("captcha-required"))
        XCTAssertEqual(MacSignIn.passwordFailure(status: 400, json: [:]), .other("HTTP 400"))
    }
    /// Adding an account: only while signed in (it opens the person's browser too; only the routing differs).
    func testAddsAccountOnlyWhenSignedIn() {
        XCTAssertTrue(MacSignIn.addsAccount(signedIn: true, sessionExpired: false))
        XCTAssertFalse(MacSignIn.addsAccount(signedIn: false, sessionExpired: false), "first launch")
        XCTAssertFalse(MacSignIn.addsAccount(signedIn: true, sessionExpired: true), "the session ended: the first window")
    }

    /// Stripe in our pop-up window: the way back to our site ends it.
    func testStripeReturnIsOurSite() {
        XCTAssertTrue(StripeCheckout.isReturn(URL(string: StripeCheckout.successURL)!))
        XCTAssertTrue(StripeCheckout.isReturn(URL(string: StripeCheckout.cancelURL)!))
        XCTAssertTrue(StripeCheckout.isReturn(URL(string: "https://www.liaisone.com/settings/billing")!))
        XCTAssertFalse(StripeCheckout.isReturn(URL(string: "https://checkout.stripe.com/c/pay/cs_x")!))
        XCTAssertFalse(StripeCheckout.isReturn(URL(string: "https://billing.stripe.com/p/session/x")!))
        XCTAssertFalse(StripeCheckout.isReturn(URL(string: "https://liaisone.com.evil.io/")!))
    }

    func testPageFirstAfterHasPassword() {
        XCTAssertTrue(MacSignIn.flow(pageFirst: false) == .direct)
        // The page is never opened any more, even after has_password (the code is asked in the app)
        XCTAssertTrue(MacSignIn.flow(pageFirst: true) == .direct)
        XCTAssertTrue(MacSignIn.remembersPageFirst(.notLinked("has_password")))
        XCTAssertFalse(MacSignIn.remembersPageFirst(.notLinked("network")))
        XCTAssertFalse(MacSignIn.remembersPageFirst(.linked))
    }
}
