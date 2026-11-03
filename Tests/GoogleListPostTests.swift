import XCTest
import Foundation
@testable import Liaison

/// The Google account card said "Sign in to Google" to a signed-in person. ListAccounts answers a GET
/// with 400 (an HTML page): the list is read with a POST; it is read again when the sign-in cookies change.
final class GoogleListPostTests: XCTestCase {
    func testListIsAPost() {
        XCTAssertEqual(GoogleAccounts.listMethod, "POST")
        XCTAssertFalse(GoogleAccounts.listBody.isEmpty)
        XCTAssertEqual(GoogleAccounts.listURL.host, "accounts.google.com")
    }

    func testFingerprintFollowsTheSignInOnly() {
        let past = Date(timeIntervalSince1970: 1)
        let base = [
            GoogleCookie(name: "SID", value: "s1", domain: ".google.com", path: "/"),
            GoogleCookie(name: "__Secure-1PSIDTS", value: "rot1", domain: ".google.com", path: "/"),
            GoogleCookie(name: "NID", value: "n1", domain: ".google.com", path: "/"),
        ]
        let f = GoogleAccounts.sessionFingerprint(base)
        XCTAssertEqual(f, "SID@.google.com=s1")
        // rotating cookies change nothing
        var rotated = base
        rotated[1] = GoogleCookie(name: "__Secure-1PSIDTS", value: "rot2", domain: ".google.com", path: "/")
        rotated[2] = GoogleCookie(name: "NID", value: "n2", domain: ".google.com", path: "/")
        XCTAssertEqual(GoogleAccounts.sessionFingerprint(rotated), f)
        // another sign-in does
        var other = base
        other[0] = GoogleCookie(name: "SID", value: "s2", domain: ".google.com", path: "/")
        XCTAssertTrue(GoogleAccounts.sessionFingerprint(other) != f)
        // signed out (expired or gone): empty
        XCTAssertEqual(GoogleAccounts.sessionFingerprint([GoogleCookie(name: "SID", value: "s1", domain: ".google.com", path: "/", expires: past)]), "")
        XCTAssertEqual(GoogleAccounts.sessionFingerprint([]), "")
        // order never matters
        let two = [GoogleCookie(name: "LSID", value: "l", domain: "accounts.google.com", path: "/"), base[0]]
        XCTAssertEqual(GoogleAccounts.sessionFingerprint(two), GoogleAccounts.sessionFingerprint(two.reversed()))
    }
}
