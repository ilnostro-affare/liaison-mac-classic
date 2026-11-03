import XCTest
import Foundation
@testable import Liaison

/// The in-app browser's passwords (Shared/Core/PasswordCSV.swift, PasswordMatch.swift): CSV import, site matching,
/// the save/update offer and the masking that keeps passwords away from the agents.
final class PasswordTests: XCTestCase {
    // MARK: CSV

    func testRowsQuotedCommasNewlinesAndBOM() {
        let text = "\u{FEFF}a,b,c\r\n\"x, y\",\"he said \"\"hi\"\"\",\"line1\nline2\"\n\nlast,,\n"
        let r = PasswordCSV.rows(text)
        XCTAssertEqual(r.count, 3)
        XCTAssertEqual(r[0], ["a", "b", "c"])
        XCTAssertEqual(r[1], ["x, y", "he said \"hi\"", "line1\nline2"])
        XCTAssertEqual(r[2], ["last", "", ""])
    }

    func testRowsWithoutTrailingNewlineAndCR() {
        XCTAssertEqual(PasswordCSV.rows("a,b\rc,d"), [["a", "b"], ["c", "d"]])
        XCTAssertEqual(PasswordCSV.rows("only"), [["only"]])
        XCTAssertEqual(PasswordCSV.rows(""), [])
    }

    func testAppleExport() {
        let csv = """
        Title,URL,Username,Password,Notes,OTPAuth
        accounts.google.com (me@x.com),https://accounts.google.com/,me@x.com,p@ss,"note, with comma
        and a second line",
        Shop,shop.example.co.uk,bob,"se""cret",,otpauth://totp/x
        App only,,app,pw,,
        No password,https://a.com,u,,,
        """
        let r = PasswordCSV.parse(csv)
        XCTAssertEqual(r.format, .apple)
        XCTAssertEqual(r.entries.count, 2)
        XCTAssertEqual(r.skipped, 2)
        XCTAssertEqual(r.entries[0].host, "accounts.google.com")
        XCTAssertEqual(r.entries[0].scheme, "https")
        XCTAssertEqual(r.entries[0].username, "me@x.com")
        XCTAssertEqual(r.entries[0].password, "p@ss")
        XCTAssertEqual(r.entries[0].note, "note, with comma\nand a second line")
        XCTAssertEqual(r.entries[1].host, "shop.example.co.uk")
        XCTAssertEqual(r.entries[1].password, "se\"cret")
    }

    func testChromiumExportWithBOMAndDuplicates() {
        let csv = "\u{FEFF}name,url,username,password,note\r\n"
            + "example.com,http://example.com/login,alice,one,\r\n"
            + "example.com,http://example.com/login,alice,two,\r\n"
            + "android,android://abc@com.app/,x,y,\r\n"
        let r = PasswordCSV.parse(csv)
        XCTAssertEqual(r.format, .chromium)
        XCTAssertEqual(r.entries.count, 1)
        XCTAssertEqual(r.entries[0].scheme, "http")
        XCTAssertEqual(r.entries[0].password, "two")      // the later row wins
        XCTAssertEqual(r.skipped, 1)
    }

    func testNotAPasswordFile() {
        XCTAssertNil(PasswordCSV.parse("a,b\n1,2\n").format)
        XCTAssertNil(PasswordCSV.parse("").format)
        XCTAssertEqual(PasswordCSV.parse("url,username,password\nhttps://x.io,u,p\n").format, .other)
    }

    func testSite() {
        XCTAssertEqual(PasswordCSV.site("Example.COM")?.host, "example.com")
        XCTAssertEqual(PasswordCSV.site("https://a.b.com:8443/x")?.host, "a.b.com")
        XCTAssertNil(PasswordCSV.site("android://x@com.app"))
        XCTAssertNil(PasswordCSV.site(""))
        XCTAssertNil(PasswordCSV.site("notes"))
    }

    func testChromiumLoginRow() {
        let e = PasswordCSV.chromiumLogin(origin: "https://www.facebook.com/", username: " me ", decrypted: Data("pw".utf8))
        XCTAssertEqual(e?.host, "www.facebook.com")
        XCTAssertEqual(e?.username, "me")
        XCTAssertNil(PasswordCSV.chromiumLogin(origin: "https://x.com", username: "a", decrypted: nil))
        XCTAssertNil(PasswordCSV.chromiumLogin(origin: "https://x.com", username: "a", decrypted: Data()))
        XCTAssertNil(PasswordCSV.chromiumLogin(origin: "android://x", username: "a", decrypted: Data("p".utf8)))
    }

    // MARK: matching

    func testRegistrableDomain() {
        XCTAssertEqual(PasswordMatch.registrableDomain("accounts.google.com"), "google.com")
        XCTAssertEqual(PasswordMatch.registrableDomain("GOOGLE.com."), "google.com")
        XCTAssertEqual(PasswordMatch.registrableDomain("login.bbc.co.uk"), "bbc.co.uk")
        XCTAssertEqual(PasswordMatch.registrableDomain("me.github.io"), "me.github.io")
        XCTAssertEqual(PasswordMatch.registrableDomain("192.168.1.10"), "192.168.1.10")
        XCTAssertEqual(PasswordMatch.registrableDomain("localhost"), "localhost")
    }

    func testSplitExactThenSameSite() {
        let saved = ["accounts.google.com", "www.google.com", "mail.google.com", "evil-google.com", "google.com.evil.io"]
        let m = PasswordMatch.split(saved, host: "accounts.google.com") { $0 }
        XCTAssertEqual(m.exact, ["accounts.google.com"])
        XCTAssertEqual(m.related, ["www.google.com", "mail.google.com"])
        let w = PasswordMatch.split(["example.com"], host: "www.example.com") { $0 }
        XCTAssertEqual(w.exact, ["example.com"])                  // www. is the same host
    }

    func testFrameAndScheme() {
        XCTAssertTrue(PasswordMatch.frameAllowed(topHost: "a.com", frameHost: "ads.net", isMain: true))
        XCTAssertTrue(PasswordMatch.frameAllowed(topHost: "a.com", frameHost: "A.com", isMain: false))
        XCTAssertFalse(PasswordMatch.frameAllowed(topHost: "a.com", frameHost: "login.a.com", isMain: false))
        XCTAssertFalse(PasswordMatch.frameAllowed(topHost: "a.com", frameHost: nil, isMain: false))
        XCTAssertEqual(PasswordMatch.fillCheck(scheme: "HTTPS"), .ok)
        XCTAssertEqual(PasswordMatch.fillCheck(scheme: "http"), .insecure)
        XCTAssertEqual(PasswordMatch.fillCheck(scheme: "file"), .notWeb)
    }

    // MARK: offer

    func testDecide() {
        let k = [PasswordOffer.Known(user: "Me@x.com", password: "old")]
        XCTAssertEqual(PasswordOffer.decide(user: "new@x.com", password: "p", known: k, never: false, enabled: true), .save)
        XCTAssertEqual(PasswordOffer.decide(user: "me@x.com", password: "old", known: k, never: false, enabled: true), .none)
        XCTAssertEqual(PasswordOffer.decide(user: "me@x.com", password: "new", known: k, never: false, enabled: true), .update(user: "Me@x.com"))
        XCTAssertEqual(PasswordOffer.decide(user: "", password: "new", known: k, never: false, enabled: true), .update(user: "Me@x.com"))
        XCTAssertEqual(PasswordOffer.decide(user: "", password: "old", known: k, never: false, enabled: true), .none)
        XCTAssertEqual(PasswordOffer.decide(user: "", password: "p", known: [], never: false, enabled: true), .save)
        XCTAssertEqual(PasswordOffer.decide(user: "a", password: "p", known: [], never: true, enabled: true), .none)
        XCTAssertEqual(PasswordOffer.decide(user: "a", password: "p", known: [], never: false, enabled: false), .none)
        XCTAssertEqual(PasswordOffer.decide(user: "a", password: "", known: [], never: false, enabled: true), .none)
    }

    func testLoginFailed() {
        XCTAssertTrue(PasswordOffer.loginFailed(submitPath: "/login/", nowPath: "/Login", passwordFieldShown: true))
        XCTAssertFalse(PasswordOffer.loginFailed(submitPath: "/login", nowPath: "/home", passwordFieldShown: true))
        XCTAssertFalse(PasswordOffer.loginFailed(submitPath: "/login", nowPath: "/login", passwordFieldShown: false))   // a 2FA step
    }

    // MARK: masking for the agents

    func testMaskedValue() {
        XCTAssertEqual(SecretMask.maskedValue("hunter22", kind: "text", words: "Password"), SecretMask.dots)
        XCTAssertEqual(SecretMask.maskedValue("hunter22", kind: "text", words: "Пароль"), SecretMask.dots)
        XCTAssertEqual(SecretMask.maskedValue("4242", kind: "number", words: "CVC"), SecretMask.dots)
        XCTAssertEqual(SecretMask.maskedValue("me@x.com", kind: "text", words: "Email"), "me@x.com")
        XCTAssertEqual(SecretMask.maskedValue("", kind: "text", words: "password"), "")
        XCTAssertEqual(SecretMask.maskedValue("Sign in", kind: "button", words: "password"), "Sign in")
        XCTAssertEqual(SecretMask.maskedValue("x", kind: "text", words: "hotpot"), "x")   // "otp" inside a word
    }

    func testScrub() {
        let text = "Your password is hunter22. Again: hunter22! pin 12 abc"
        let s = SecretMask.scrub(text, secrets: ["hunter22", "12", "hunter22"])
        XCTAssertFalse(s.contains("hunter22"))
        XCTAssertTrue(s.contains("pin 12"))          // too short to scrub
        XCTAssertEqual(s, "Your password is \(SecretMask.dots). Again: \(SecretMask.dots)! pin 12 abc")
        // the longer secret first, so a password containing another is not left half-shown
        XCTAssertEqual(SecretMask.scrub("abcdefgh", secrets: ["abcd", "abcdefgh"]), SecretMask.dots)
        XCTAssertEqual(SecretMask.scrub("", secrets: ["abcd"]), "")
    }

    // The accounts are offered at the field.
    func testSuggestAnchor() {
        XCTAssertEqual(PasswordSuggest.anchor(x: 10, y: 20, width: 200, height: 30, zoom: 1, view: CGSize(width: 800, height: 600)),
                       CGRect(x: 10, y: 20, width: 200, height: 30))
        XCTAssertEqual(PasswordSuggest.anchor(x: 10, y: 20, width: 200, height: 30, zoom: 0.5, view: CGSize(width: 800, height: 600)),
                       CGRect(x: 5, y: 10, width: 100, height: 15))
        // clipped to the view; outside it, none
        XCTAssertEqual(PasswordSuggest.anchor(x: 700, y: 20, width: 200, height: 30, zoom: 1, view: CGSize(width: 800, height: 600)),
                       CGRect(x: 700, y: 20, width: 100, height: 30))
        XCTAssertNil(PasswordSuggest.anchor(x: 10, y: 700, width: 200, height: 30, zoom: 1, view: CGSize(width: 800, height: 600)))
        XCTAssertNil(PasswordSuggest.anchor(x: 10, y: 20, width: 0, height: 30, zoom: 1, view: CGSize(width: 800, height: 600)))
        XCTAssertNil(PasswordSuggest.anchor(x: .nan, y: 20, width: 200, height: 30, zoom: 1, view: CGSize(width: 800, height: 600)))
    }

    func testSuggestShows() {
        XCTAssertTrue(PasswordSuggest.shows(isMain: true, insecure: false, accounts: 1, visible: true, agentHere: false, justFilled: false))
        XCTAssertFalse(PasswordSuggest.shows(isMain: false, insecure: false, accounts: 1, visible: true, agentHere: false, justFilled: false))
        XCTAssertFalse(PasswordSuggest.shows(isMain: true, insecure: true, accounts: 1, visible: true, agentHere: false, justFilled: false))
        XCTAssertFalse(PasswordSuggest.shows(isMain: true, insecure: false, accounts: 0, visible: true, agentHere: false, justFilled: false))
        XCTAssertFalse(PasswordSuggest.shows(isMain: true, insecure: false, accounts: 2, visible: false, agentHere: false, justFilled: false))
        XCTAssertFalse(PasswordSuggest.shows(isMain: true, insecure: false, accounts: 2, visible: true, agentHere: true, justFilled: false))
        XCTAssertFalse(PasswordSuggest.shows(isMain: true, insecure: false, accounts: 2, visible: true, agentHere: false, justFilled: true))
    }
}
