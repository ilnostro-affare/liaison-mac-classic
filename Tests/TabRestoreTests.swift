import XCTest
import Foundation
@testable import Liaison

/// A tab comes back at its NEWEST address, never the one it was opened or pinned with (Shared/Core/TabRestore.swift).
final class TabRestoreTests: XCTestCase {
    private func u(_ s: String) -> URL { URL(string: s)! }

    func testLatestPrefersPendingThenLiveThenKnown() {
        let a = u("https://a.com/1"), b = u("https://a.com/2"), c = u("https://a.com/3")
        XCTAssertEqual(TabRestore.latest(pending: a, live: b, known: c), a)
        XCTAssertEqual(TabRestore.latest(pending: nil, live: b, known: c), b)   // pushState already in webView.url
        XCTAssertEqual(TabRestore.latest(pending: nil, live: nil, known: c), c)
        XCTAssertNil(TabRestore.latest(pending: nil, live: nil, known: nil))
    }

    func testBlankAndNonWebNeverWin() {
        let c = u("https://a.com/3")
        XCTAssertEqual(TabRestore.latest(pending: nil, live: u("about:blank"), known: c), c)   // a sleeping tab's blank page
        XCTAssertEqual(TabRestore.latest(pending: u("file:///etc/hosts"), live: nil, known: c), c)
        XCTAssertNil(TabRestore.latest(pending: nil, live: u("about:blank"), known: nil))
    }

    func testMediaSampleOfTheSameVideoGoesIntoTheAddress() {
        let watch = u("https://www.youtube.com/watch?v=abc&t=120s")
        let saved = TabRestore.withMedia(watch, sample: (u("https://www.youtube.com/watch?v=abc&t=120s"), 300.7))
        XCTAssertEqual(saved.absoluteString, "https://www.youtube.com/watch?v=abc&t=300s")
        // The sample was taken before the address got a newer `t`: still the same video.
        let again = TabRestore.withMedia(u("https://www.youtube.com/watch?v=abc&t=300s"), sample: (watch, 310))
        XCTAssertEqual(again.absoluteString, "https://www.youtube.com/watch?v=abc&t=310s")
    }

    func testMediaSampleOfAnotherPageIsIgnored() {
        let other = u("https://www.youtube.com/watch?v=xyz")
        XCTAssertEqual(TabRestore.withMedia(other, sample: (u("https://www.youtube.com/watch?v=abc"), 300)), other)
        let plain = u("https://example.com/watch?v=abc")
        XCTAssertEqual(TabRestore.withMedia(plain, sample: (plain, 300)), plain)
        XCTAssertEqual(TabRestore.withMedia(other, sample: nil), other)
    }

    func testStateOnlyWhenItIsAboutTheSavedAddress() {
        XCTAssertEqual(TabRestore.source(savedURL: "https://a.com/2", stateURL: "https://a.com/2", stateBytes: 900), .state)
        XCTAssertEqual(TabRestore.source(savedURL: "https://a.com/2", stateURL: "https://a.com/1", stateBytes: 900), .url)
        XCTAssertEqual(TabRestore.source(savedURL: "https://a.com/2", stateURL: nil, stateBytes: 900), .url)
        XCTAssertEqual(TabRestore.source(savedURL: "https://a.com/2", stateURL: "https://a.com/2", stateBytes: 0), .url)
        XCTAssertEqual(TabRestore.source(savedURL: "https://a.com/2", stateURL: "https://a.com/2", stateBytes: TabRestore.maxStateBytes + 1), .url)
        // A YouTube position written into the address after the state was taken: the address (with its `t`) wins.
        XCTAssertEqual(TabRestore.source(savedURL: "https://www.youtube.com/watch?v=abc&t=300s",
                                         stateURL: "https://www.youtube.com/watch?v=abc&t=120s", stateBytes: 900), .url)
    }

    func testEnvelopeRoundTripAndCorruption() {
        let state = Data((0..<1000).map { UInt8($0 % 251) })
        let d = TabRestore.encode(url: "https://a.com/é?q=1", state: state)!
        let back = TabRestore.decode(d)!
        XCTAssertEqual(back.url, "https://a.com/é?q=1")
        XCTAssertEqual(back.state, state)
        XCTAssertNil(TabRestore.decode(Data()))
        XCTAssertNil(TabRestore.decode(Data("XXXX0000abc".utf8)))
        XCTAssertNil(TabRestore.decode(d.prefix(10)))                       // cut short
        var bad = d; bad[7] = 0xFF                                         // length past the end
        XCTAssertNil(TabRestore.decode(bad))
        XCTAssertNil(TabRestore.encode(url: "https://a.com", state: Data()))
        XCTAssertNil(TabRestore.encode(url: "https://a.com", state: Data(count: TabRestore.maxStateBytes + 1)))
        XCTAssertNil(TabRestore.encode(url: "", state: state))
    }

    func testFileNamesAndOrphans() {
        XCTAssertEqual(TabRestore.fileName("ab-12_C.d"), "ab-12_C.d")
        XCTAssertEqual(TabRestore.fileName("a/b:c"), "a_b_c")
        XCTAssertNil(TabRestore.fileName(""))
        XCTAssertNil(TabRestore.fileName(".."))
        XCTAssertEqual(TabRestore.fileName(String(repeating: "x", count: 200))?.count, 80)
        XCTAssertEqual(TabRestore.orphans(files: ["b", "a", "c"], keep: ["a"]), ["b", "c"])
        XCTAssertEqual(TabRestore.orphans(files: [], keep: ["a"]), [])
    }

    func testPinnedAddressOfferedOnlyWhenTheTabMovedOn() {
        let home = u("https://mail.google.com/")
        XCTAssertFalse(TabRestore.offersPinnedAddress(pinned: true, home: home, current: u("https://mail.google.com")))
        XCTAssertTrue(TabRestore.offersPinnedAddress(pinned: true, home: home, current: u("https://mail.google.com/mail/u/0/#inbox/1")))
        XCTAssertFalse(TabRestore.offersPinnedAddress(pinned: false, home: home, current: u("https://x.com")))
        XCTAssertFalse(TabRestore.offersPinnedAddress(pinned: true, home: nil, current: u("https://x.com")))
    }

    func testPinnedCloseUnloadsInPlace() {
        // Ordinary tabs close; an unpinned close (force) closes a pinned one too.
        XCTAssertEqual(TabRestore.closeAction(pinned: false, force: false, index: 0, selected: true, hidden: [false, false]), .close)
        XCTAssertEqual(TabRestore.closeAction(pinned: true, force: true, index: 0, selected: true, hidden: [false, false]), .close)
        // A pinned tab in front: unloaded, the right neighbour comes to front (else the left one).
        XCTAssertEqual(TabRestore.closeAction(pinned: true, force: false, index: 0, selected: true, hidden: [false, false, false]), .unload(select: 1))
        XCTAssertEqual(TabRestore.closeAction(pinned: true, force: false, index: 2, selected: true, hidden: [false, false, false]), .unload(select: 1))
        // Tabs a collapsed group hides are passed over.
        XCTAssertEqual(TabRestore.closeAction(pinned: true, force: false, index: 0, selected: true, hidden: [false, true, false]), .unload(select: 2))
        // Not in front: unloaded, the selection stays.
        XCTAssertEqual(TabRestore.closeAction(pinned: true, force: false, index: 1, selected: false, hidden: [false, false]), .unload(select: nil))
        // The only tab, or nothing else visible: left as it is.
        XCTAssertEqual(TabRestore.closeAction(pinned: true, force: false, index: 0, selected: true, hidden: [false]), .keep)
        XCTAssertEqual(TabRestore.closeAction(pinned: true, force: false, index: 0, selected: true, hidden: [false, true]), .keep)
    }
}
