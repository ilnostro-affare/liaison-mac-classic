import XCTest
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
@testable import Liaison

/// "Can't find this site" for a site that works (Shared/Core/LoadFailure.swift).
final class LoadFailureTests: XCTestCase {
    private let url = LoadFailure.urlDomain

    func testCancelledAndSupersededNeverShow() {
        XCTAssertEqual(LoadFailure.decide(domain: url, code: -999, attempt: 0, current: true, committed: false), .ignore)
        XCTAssertEqual(LoadFailure.decide(domain: LoadFailure.webKitDomain, code: 102, attempt: 0, current: true, committed: false), .ignore)
        // A newer navigation replaced this one: even a real not-found is not this tab's problem any more.
        XCTAssertEqual(LoadFailure.decide(domain: url, code: -1003, attempt: 5, current: false, committed: false), .ignore)
    }

    func testTransientFailuresAreTriedTwiceThenShown() {
        for code in [-1001, -1003, -1004, -1005, -1006, -1009] {
            XCTAssertEqual(LoadFailure.decide(domain: url, code: code, attempt: 0, current: true, committed: false), .retry(after: 1.0))
            XCTAssertEqual(LoadFailure.decide(domain: url, code: code, attempt: 1, current: true, committed: false), .retry(after: 2.0))
            XCTAssertEqual(LoadFailure.decide(domain: url, code: code, attempt: 2, current: true, committed: false), .show)
        }
    }

    func testCommittedPageNeverGetsACard() {
        for code in [-1001, -1003, -1004, -1005, -1009, -1202, -1100] {
            XCTAssertEqual(LoadFailure.decide(domain: url, code: code, attempt: 0, current: true, committed: true), .ignore)
        }
    }

    /// "Can't find this site" over admin.example.com that had loaded. A reload (or the reload after
    /// a restore) that fails while the page at that address is still on screen keeps the page after its tries.
    func testPageStillShownKeepsItsPlace() {
        XCTAssertEqual(LoadFailure.decide(domain: url, code: -1003, attempt: 0, current: true, committed: false, showing: true), .retry(after: 1.0))
        XCTAssertEqual(LoadFailure.decide(domain: url, code: -1003, attempt: 2, current: true, committed: false, showing: true), .ignore)
        XCTAssertEqual(LoadFailure.decide(domain: url, code: -1009, attempt: 2, current: true, committed: false, showing: true), .ignore)
        // Not a network failure (a certificate): shown even over the old page.
        XCTAssertEqual(LoadFailure.decide(domain: url, code: -1202, attempt: 0, current: true, committed: false, showing: true), .show)
        // A newer navigation replaced it.
        XCTAssertEqual(LoadFailure.decide(domain: url, code: -1003, attempt: 2, current: false, committed: false, showing: false), .ignore)
    }

    func testSameAddress() {
        let a = URL(string: "https://admin.example.com/students?x=1#top")
        XCTAssertTrue(LoadFailure.sameAddress(a, URL(string: "https://Admin.Example.com/students?x=1")))
        XCTAssertFalse(LoadFailure.sameAddress(a, URL(string: "https://admin.example.com/students?x=2")))
        XCTAssertTrue(LoadFailure.sameAddress(URL(string: "https://a.com/"), URL(string: "https://a.com")))
        XCTAssertFalse(LoadFailure.sameAddress(nil, a))
    }

    func testReloadIsNeverACachedCopy() {
        XCTAssertEqual(LoadFailure.cachePolicy(.normal), .useProtocolCachePolicy)
        XCTAssertEqual(LoadFailure.cachePolicy(.revalidate), .reloadRevalidatingCacheData)
        XCTAssertEqual(LoadFailure.cachePolicy(.origin), .reloadIgnoringLocalCacheData)
    }

    func testOtherErrorsShowAtOnce() {
        XCTAssertEqual(LoadFailure.decide(domain: url, code: -1202, attempt: 0, current: true, committed: false), .show)
        XCTAssertEqual(LoadFailure.decide(domain: url, code: -1003, attempt: 0, current: true, committed: false, web: false), .show)
    }
}
