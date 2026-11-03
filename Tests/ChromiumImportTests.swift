import XCTest
import Foundation
@testable import Liaison

/// Import from Chromium browsers (Shared/Core/ChromiumImport.swift): times, cookie rows, Keychain names, SNSS tabs, Arc.
final class ChromiumImportTests: XCTestCase {
    func testDate() {
        XCTAssertNil(ChromiumImport.date(0))
        // 00:00:00 UTC = 1609459200 s since 1970.
        let v = Int64((1_609_459_200 + 11_644_473_600) * 1_000_000)
        XCTAssertTrue(abs(ChromiumImport.date(v)!.timeIntervalSince1970 - 1_609_459_200) < 0.001)
    }

    private func row(_ value: String = "", enc: Data = Data(), persistent: Bool = true, expires: Int64? = nil) -> ChromiumImport.Row {
        let future = Int64((Date().timeIntervalSince1970 + 86_400 + 11_644_473_600) * 1_000_000)
        return ChromiumImport.Row(host: ".google.com", name: "SID", value: value, encrypted: enc, path: "", expires: expires ?? future,
                                  secure: true, httpOnly: true, sameSite: 1, persistent: persistent)
    }

    func testCookiePlainAndExpiry() {
        let c = ChromiumImport.cookie(row("abc"), decrypted: nil, dbVersion: 18)
        XCTAssertEqual(c?.value, "abc")
        XCTAssertEqual(c?.path, "/")
        XCTAssertEqual(c?.sameSite, "lax")
        XCTAssertNotNil(c?.expires)
        XCTAssertNil(ChromiumImport.cookie(row("abc", expires: 1), decrypted: nil, dbVersion: 18))   // long expired
        let session = ChromiumImport.cookie(row("abc", persistent: false, expires: 0), decrypted: nil, dbVersion: 18)
        XCTAssertNotNil(session)
        XCTAssertNil(session?.expires)
    }

    func testCookieEncrypted() {
        let enc = Data("v10".utf8) + Data(repeating: 1, count: 32)
        XCTAssertEqual(ChromiumImport.ciphertext(enc)?.count, 32)
        XCTAssertNil(ChromiumImport.ciphertext(Data("v10".utf8) + Data(repeating: 1, count: 5)))
        XCTAssertNil(ChromiumImport.ciphertext(Data("xyz123".utf8)))
        // not decrypted: dropped
        XCTAssertNil(ChromiumImport.cookie(row(enc: enc), decrypted: nil, dbVersion: 24))
        // v24+: the 32-byte host hash goes
        let dec = Data(repeating: 7, count: 32) + Data("token".utf8)
        XCTAssertEqual(ChromiumImport.cookie(row(enc: enc), decrypted: dec, dbVersion: 24)?.value, "token")
        XCTAssertEqual(ChromiumImport.cookie(row(enc: enc), decrypted: Data("token".utf8), dbVersion: 23)?.value, "token")
        XCTAssertNil(ChromiumImport.plaintext(Data("short".utf8), dbVersion: 24))
    }

    func testSameSite() {
        XCTAssertEqual(ChromiumImport.sameSite(0), "none")
        XCTAssertEqual(ChromiumImport.sameSite(2), "strict")
        XCTAssertNil(ChromiumImport.sameSite(-1))
    }

    func testSafeStorageServices() {
        XCTAssertEqual(ChromiumImport.safeStorageServices("Google Chrome").first, "Chrome Safe Storage")
        XCTAssertEqual(ChromiumImport.safeStorageServices("Chrome Canary").first, "Chrome Safe Storage")
        XCTAssertEqual(ChromiumImport.safeStorageServices("Dia \u{00B7} Work").first, "Dia Safe Storage")
        XCTAssertEqual(ChromiumImport.safeStorageServices("Arc").first, "Arc Safe Storage")
        XCTAssertEqual(ChromiumImport.safeStorageServices("Microsoft Edge").first, "Microsoft Edge Safe Storage")
        XCTAssertEqual(ChromiumImport.safeStorageServices("Brave").first, "Brave Safe Storage")
        XCTAssertTrue(ChromiumImport.safeStorageServices("Comet Beta").contains("Comet Safe Storage"))
        let s = ChromiumImport.safeStorageServices("Vivaldi")
        XCTAssertEqual(s, ["Vivaldi Safe Storage"])
    }

    func testSessionFile() {
        XCTAssertEqual(ChromiumImport.sessionFile(["Tabs_13300000000000000", "Session_13300000000000000", "Session_13400000000000000"]),
                       "Session_13400000000000000")
        XCTAssertNil(ChromiumImport.sessionFile(["Tabs_1"]))
    }

    // MARK: - SNSS

    private func le32(_ v: Int32) -> [UInt8] { let u = UInt32(bitPattern: v); return [UInt8(u & 0xff), UInt8(u >> 8 & 0xff), UInt8(u >> 16 & 0xff), UInt8(u >> 24)] }
    private func command(_ id: UInt8, _ payload: [UInt8]) -> [UInt8] {
        let size = payload.count + 1
        return [UInt8(size & 0xff), UInt8(size >> 8)] + [id] + payload
    }
    private func nav(_ tab: Int32, _ index: Int32, _ url: String) -> [UInt8] {
        var s = [UInt8](url.utf8)
        let len = Int32(s.count)
        while s.count % 4 != 0 { s.append(0) }
        var body = le32(tab) + le32(index) + le32(len) + s
        body += le32(0)   // an empty title (string16 length 0)
        return command(6, le32(Int32(body.count)) + body)
    }
    private func pair(_ id: UInt8, _ a: Int32, _ b: Int32) -> [UInt8] { command(id, le32(a) + le32(b)) }

    func testSessionTabs() {
        var f: [UInt8] = Array("SNSS".utf8) + le32(3)
        f += pair(0, 1, 10)                       // tab 10 in window 1
        f += pair(2, 10, 1)                       // index 1
        f += nav(10, 0, "https://a.example/")
        f += nav(10, 1, "https://b.example/")
        f += pair(7, 10, 1)                       // selected: b
        f += pair(0, 1, 11)
        f += pair(2, 11, 0)                       // tab 11 first in the window
        f += nav(11, 0, "https://first.example/")
        f += pair(0, 1, 12)
        f += nav(12, 0, "chrome://newtab/")       // not http
        f += pair(0, 1, 13)
        f += nav(13, 0, "https://closed.example/")
        f += command(16, le32(13) + le32(0) + le32(0) + le32(0))
        f += pair(0, 2, 14)                       // a window that was closed
        f += nav(14, 0, "https://gone.example/")
        f += command(17, le32(2) + le32(0) + le32(0) + le32(0))
        f += pair(0, 1, 15)
        f += nav(15, 0, "https://first.example/") // a duplicate
        f += [0x40, 0x00, 6, 1, 2]                // a truncated tail
        let tabs = ChromiumImport.sessionTabs(Data(f))
        XCTAssertEqual(tabs, ["https://first.example/", "https://b.example/"])
        XCTAssertNil(ChromiumImport.sessionTabs(Data("NOPE1234".utf8)))
        XCTAssertEqual(ChromiumImport.sessionTabs(Data(Array("SNSS".utf8) + le32(1))), [])
    }

    func testSessionTabsCap() {
        var f: [UInt8] = Array("SNSS".utf8) + le32(1)
        for t in 0..<80 { f += nav(Int32(t), 0, "https://s\(t).example/") }
        XCTAssertEqual(ChromiumImport.sessionTabs(Data(f))?.count, ChromiumImport.tabCap)
    }

    func testArcTabs() {
        let json = #"{"sidebar":{"containers":[{"global":{}},{"items":["id1",{"id":"id1","data":{"tab":{"savedURL":"https://one.example/","savedTitle":"One"}}},"id2",{"data":{"tab":{"savedURL":"about:blank"}}},"id3",{"data":{"tab":{"savedURL":"https://two.example/x"}}}]}]}}"#
        XCTAssertEqual(ChromiumImport.arcTabs(Data(json.utf8)), ["https://one.example/", "https://two.example/x"])
        XCTAssertNil(ChromiumImport.arcTabs(Data("{}".utf8)))
    }
}
