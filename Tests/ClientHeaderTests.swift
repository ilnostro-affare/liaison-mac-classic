import XCTest
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking   // URLRequest on Linux (the Core tests)
#endif
@testable import Liaison

/// The X-Lia-Client header (Shared/Core/ClientHeader.swift); the server's parser is lia-client.js in
/// the web repo, whose regexes these values must pass.
final class ClientHeaderTests: XCTestCase {
    func testReleaseValue() {
        let v = LiaClient.value(version: "0.2.10", build: "202610190001", os: "macOS 26.0", arch: "arm64", channel: .release)
        XCTAssertEqual(v, "mac/0.2.10 (202610190001; macOS 26.0; arm64; release)")
    }

    func testDevAndUnknownFields() {
        XCTAssertEqual(LiaClient.value(version: "0.2.11", build: "1", os: "macOS 15.6.1", arch: "x86_64", channel: .dev),
                       "mac/0.2.11 (1; macOS 15.6.1; x86_64; dev)")
        XCTAssertEqual(LiaClient.value(version: "", build: "", os: "", arch: "", channel: .dev), "mac/0 (-; -; -; dev)")
        XCTAssertEqual(LiaClient.value(version: "$(MARKETING_VERSION)", build: "$(X)", os: " 26", arch: "ARM", channel: .dev),
                       "mac/0 (X; -; -; dev)")
    }

    func testFieldsCannotBreakTheFormatOrCarryPersonalData() {
        let v = LiaClient.value(version: "1.0;(x)", build: "12:34; ok", os: "macOS (Sam's Mac); a@b", arch: "arm64;", channel: .release)
        XCTAssertEqual(v, "mac/1.0x (1234ok; macOS Sams Mac ab; arm64; release)")
        XCTAssertFalse(v.contains("@"))
        let long = LiaClient.value(version: String(repeating: "9", count: 40), build: String(repeating: "1", count: 40),
                                   os: "macOS " + String(repeating: "8", count: 40), arch: String(repeating: "a", count: 20), channel: .release)
        XCTAssertTrue(long.count <= 160)
        XCTAssertTrue(long.hasPrefix("mac/" + String(repeating: "9", count: 24) + " (" + String(repeating: "1", count: 24) + "; "))
    }

    func testOSName() {
        XCTAssertEqual(LiaClient.osName(OperatingSystemVersion(majorVersion: 26, minorVersion: 0, patchVersion: 0)), "macOS 26.0")
        XCTAssertEqual(LiaClient.osName(OperatingSystemVersion(majorVersion: 15, minorVersion: 6, patchVersion: 1)), "macOS 15.6.1")
    }

    func testChannel() {
        XCTAssertEqual(LiaClient.channel(urlScheme: "liaison", feed: "https://updates.example.com/mac/appcast.xml"), .release)
        XCTAssertEqual(LiaClient.channel(urlScheme: "liaison-dev", feed: "https://updates.example.com/mac/appcast.xml"), .dev)
        XCTAssertEqual(LiaClient.channel(urlScheme: "liaison", feed: ""), .dev)          // no feed: a local or CI build
        XCTAssertEqual(LiaClient.channel(urlScheme: nil, feed: "$(LIA_SPARKLE_FEED)"), .dev)
    }

    func testStampOnlyOurHosts() {
        let v = "mac/1.0 (1; macOS 26.0; arm64; dev)"
        for s in ["https://mcp.liaisone.com/call/x", "https://lia.liaisone.com/agents/roster", "https://api.liaisone.com/meta/status",
                  "https://ai.liaisone.com/intelligence/state", "https://liaisone.com/x"] {
            var r = URLRequest(url: URL(string: s)!)
            LiaClient.stamp(&r, value: v)
            XCTAssertEqual(r.value(forHTTPHeaderField: "X-Lia-Client"), v, s)
        }
        for s in ["https://client.memberstack.com/member", "https://evilliaisone.com/", "https://graph.facebook.com/v26.0/me",
                  "https://updates.example.com.example.org/"] {
            var r = URLRequest(url: URL(string: s)!)
            LiaClient.stamp(&r, value: v)
            XCTAssertNil(r.value(forHTTPHeaderField: "X-Lia-Client"), s)
        }
    }
}
