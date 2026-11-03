import XCTest
import Foundation
@testable import Liaison

/// Sign in with Apple, the pure half (Shared/Core/AppleSignIn.swift). The server's half is tested in the
/// web repo.
final class AppleSignInTests: XCTestCase {
    private let tok = String(repeating: "a", count: 40) + "B-_"

    func testTokenShape() {
        XCTAssertTrue(AppleSignIn.isTokenLike(tok))
        XCTAssertFalse(AppleSignIn.isTokenLike(String(tok.dropLast())))
        XCTAssertFalse(AppleSignIn.isTokenLike(String(tok.dropLast()) + "="))
        XCTAssertFalse(AppleSignIn.isTokenLike(String(repeating: "\u{00E9}", count: 43)))
    }

    func testBase64urlHasNoPaddingOrUnsafeCharacters() {
        let d = Data([0xfb, 0xff, 0xfe, 0x00])
        XCTAssertEqual(AppleSignIn.base64url(d), "-__-AA")
        XCTAssertEqual(AppleSignIn.base64url(Data(repeating: 7, count: 32)).count, 43)
    }

    func testStartURL() {
        let u = AppleSignIn.startURL(base: "https://mcp.liaisone.com", challenge: tok)
        XCTAssertEqual(u?.absoluteString, "https://mcp.liaisone.com/auth/apple/start?app=mac&cc=" + tok)
        XCTAssertNil(AppleSignIn.startURL(base: "https://mcp.liaisone.com", challenge: "short"))
    }

    func testCallbackParsing() {
        XCTAssertEqual(AppleSignIn.callback(URL(string: "liaison://auth/apple?code=" + tok)!), .code(tok))
        XCTAssertEqual(AppleSignIn.callback(URL(string: "LIAISON://auth/apple?code=" + tok)!), .code(tok))
        XCTAssertEqual(AppleSignIn.callback(URL(string: "liaison://auth/apple?error=cancelled")!), .error("cancelled"))
        XCTAssertEqual(AppleSignIn.callback(URL(string: "liaison://auth/apple?code=short")!), .unrelated, "a malformed code is not a code")
        XCTAssertEqual(AppleSignIn.callback(URL(string: "liaison://settings/general?code=" + tok)!), .unrelated)
        XCTAssertEqual(AppleSignIn.callback(URL(string: "https://auth/apple?code=" + tok)!), .unrelated)
        XCTAssertEqual(AppleSignIn.callback(URL(string: "liaison://auth/apple?error=%3Cb%3E")!), .unrelated, "markup in an error is ignored")
    }

    func testErrorMessages() {
        XCTAssertNil(AppleSignIn.message(forError: "cancelled"), "cancelling says nothing")
        XCTAssertEqual(AppleSignIn.message(forError: "email_unverified"), "Apple did not confirm this email. Use your email.")
        XCTAssertEqual(AppleSignIn.message(forError: "whatever"), "Sign in with Apple did not finish. Try again.")
    }

    func testCollectSignedIn() {
        let r = AppleSignIn.collect(status: 200, json: ["ok": true, "state": "signed_in", "member_token": "eyA.bb.cc", "email": "a@icloud.com"])
        XCTAssertEqual(r, .signedIn(memberToken: "eyA.bb.cc", email: "a@icloud.com"))
        XCTAssertEqual(AppleSignIn.collect(status: 200, json: ["ok": true, "state": "signed_in", "member_token": "lsess_x"]),
                       .failed("Sign in with Apple did not finish. Try again."), "only a Memberstack JWT signs in")
    }

    func testCollectLinkRequired() {
        let r = AppleSignIn.collect(status: 200, json: ["ok": true, "state": "link_required", "link": tok, "email": "a@x.it", "user_message": "Sign in once."])
        XCTAssertEqual(r, .linkRequired(link: tok, email: "a@x.it", message: "Sign in once."))
        if case .linkRequired(_, _, let m) = AppleSignIn.collect(status: 200, json: ["ok": true, "state": "link_required", "link": tok]) {
            XCTAssertTrue(m.contains("already has a Liaison account"))
        } else { XCTFail("link without a message still links") }
    }

    func testCollectFailures() {
        XCTAssertEqual(AppleSignIn.collect(status: 410, json: ["ok": false]), .failed("This sign-in has expired. Try again."))
        XCTAssertEqual(AppleSignIn.collect(status: 429, json: [:]), .failed("Too many attempts. Wait a minute and try again."))
        XCTAssertEqual(AppleSignIn.collect(status: 403, json: ["ok": false, "error": "forbidden"]), .failed("Sign in with Apple did not finish. Try again."))
        XCTAssertEqual(AppleSignIn.collect(status: 410, json: ["ok": false, "user_message": "Gone."]), .failed("Gone."))
    }

    func testLinkMessage() {
        XCTAssertNil(AppleSignIn.linkMessage(status: 200, json: ["ok": true, "state": "linked"]))
        XCTAssertEqual(AppleSignIn.linkMessage(status: 409, json: ["ok": false, "user_message": "Has a password."]), "Has a password.")
        XCTAssertEqual(AppleSignIn.linkMessage(status: 502, json: [:]), "Apple could not be connected. You are signed in.")
    }
}
