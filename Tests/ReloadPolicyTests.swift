import XCTest
import Foundation
@testable import Liaison

/// Reload pressed twice did not reload; YouTube went back to the old time (Shared/Core/ReloadPolicy.swift).
final class ReloadPolicyTests: XCTestCase {
    func testQuickSecondClickReloadsAgainInsteadOfStopping() {
        XCTAssertEqual(ReloadButton.action(loading: true, sinceReload: 0.2), .reload)
        XCTAssertEqual(ReloadButton.action(loading: true, sinceReload: 1.0), .reload)
        XCTAssertFalse(ReloadButton.showsStop(loading: true, sinceReload: 0.5))
    }

    func testStopAfterTheGraceAndForOtherLoads() {
        XCTAssertEqual(ReloadButton.action(loading: true, sinceReload: 3), .stop)
        XCTAssertEqual(ReloadButton.action(loading: true, sinceReload: nil), .stop)   // a link's load, not ours
        XCTAssertEqual(ReloadButton.action(loading: false, sinceReload: nil), .reload)
        XCTAssertEqual(ReloadButton.action(loading: false, sinceReload: 0.1), .reload)
        XCTAssertEqual(ReloadButton.action(loading: true, sinceReload: -5), .stop)     // a clock that went back
    }

    func testAppliesOnlyToYouTubeVideos() {
        XCTAssertTrue(MediaResume.applies(to: URL(string: "https://www.youtube.com/watch?v=abc&t=120s")!))
        XCTAssertTrue(MediaResume.applies(to: URL(string: "https://m.youtube.com/watch?v=abc")!))
        XCTAssertTrue(MediaResume.applies(to: URL(string: "https://youtu.be/abc?t=5")!))
        XCTAssertTrue(MediaResume.applies(to: URL(string: "https://www.youtube.com/live/abc")!))
        XCTAssertFalse(MediaResume.applies(to: URL(string: "https://www.youtube.com/")!))
        XCTAssertFalse(MediaResume.applies(to: URL(string: "https://www.youtube.com/watch")!))
        XCTAssertFalse(MediaResume.applies(to: URL(string: "https://www.youtube.com/shorts/abc")!))
        XCTAssertFalse(MediaResume.applies(to: URL(string: "https://youtu.be/")!))
        XCTAssertFalse(MediaResume.applies(to: URL(string: "https://example.com/watch?v=abc&t=3")!))
        XCTAssertFalse(MediaResume.applies(to: URL(string: "https://notyoutube.com/watch?v=abc")!))
    }

    func testTheOldTimestampIsReplacedByTheCurrentOne() {
        let u = URL(string: "https://www.youtube.com/watch?v=abc&t=120s&list=L1")!
        XCTAssertEqual(MediaResume.url(u, at: 754.8)?.absoluteString, "https://www.youtube.com/watch?v=abc&t=754s&list=L1")
        let plain = URL(string: "https://www.youtube.com/watch?v=abc")!
        XCTAssertEqual(MediaResume.url(plain, at: 61)?.absoluteString, "https://www.youtube.com/watch?v=abc&t=61s")
        XCTAssertEqual(MediaResume.url(URL(string: "https://youtu.be/abc?t=9")!, at: 300)?.absoluteString, "https://youtu.be/abc?t=300s")
    }

    func testAtTheStartTheTimestampGoes() {
        let u = URL(string: "https://www.youtube.com/watch?v=abc&t=120s")!
        XCTAssertEqual(MediaResume.url(u, at: 0.4)?.absoluteString, "https://www.youtube.com/watch?v=abc")
        XCTAssertEqual(MediaResume.url(URL(string: "https://youtu.be/abc?t=9")!, at: 0)?.absoluteString, "https://youtu.be/abc")
    }

    func testFragmentTimestampAndBadTimes() {
        let u = URL(string: "https://www.youtube.com/watch?v=abc#t=1m30s")!
        XCTAssertEqual(MediaResume.url(u, at: 200)?.absoluteString, "https://www.youtube.com/watch?v=abc&t=200s")
        XCTAssertNil(MediaResume.url(u, at: .nan))
        XCTAssertNil(MediaResume.url(u, at: .infinity))
        XCTAssertNil(MediaResume.url(u, at: -1))
        XCTAssertNil(MediaResume.url(URL(string: "https://example.com/v?t=3")!, at: 50))
    }

    func testDuplicateTimestampsCollapse() {
        let u = URL(string: "https://www.youtube.com/watch?v=abc&t=1s&t=2s")!
        XCTAssertEqual(MediaResume.url(u, at: 40)?.absoluteString, "https://www.youtube.com/watch?v=abc&t=40s")
        XCTAssertEqual(MediaResume.url(u, at: 0)?.absoluteString, "https://www.youtube.com/watch?v=abc")
    }
}
