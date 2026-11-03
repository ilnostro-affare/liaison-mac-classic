import XCTest
import Foundation
@testable import Liaison

/// 0.2.11: the canary's click latency (Shared/Core/Latency.swift).
final class LatencyTests: XCTestCase {
    func testHistogramCountsAndPercentiles() {
        var h = LatencyHistogram()
        for ms in [10.0, 12, 20, 30, 40, 45, 60, 90, 150, 520] { h.add(ms) }
        XCTAssertEqual(h.n, 10)
        XCTAssertEqual(h.max, 520)
        XCTAssertEqual(h.over100, 2)
        XCTAssertEqual(h.over400, 1)
        XCTAssertEqual(h.percentile(0.5), 50)        // the 5th press (40 ms) is in the <=50 bucket
        XCTAssertEqual(h.percentile(0.95), 520)      // the overflow of 500: the max, not the bucket edge
        XCTAssertEqual(h.percentile(1), 520)
        h.add(-1); h.add(.nan); h.add(.infinity)
        XCTAssertEqual(h.n, 10)                      // nonsense is not a press
        XCTAssertEqual(LatencyHistogram().percentile(0.95), 0)
    }

    func testPercentileNeverAboveMax() {
        var h = LatencyHistogram()
        h.add(3)
        XCTAssertEqual(h.percentile(0.95), 3)        // bucket edge 8, but the max seen is 3
    }

    func testMergeAddsUp() {
        var a = LatencyHistogram(), b = LatencyHistogram()
        a.add(20); a.add(130)
        b.add(450); b.add(30)
        a.merge(b)
        XCTAssertEqual(a.n, 4)
        XCTAssertEqual(a.over100, 2)
        XCTAssertEqual(a.over400, 1)
        XCTAssertEqual(a.max, 450)
        XCTAssertEqual(a.counts.reduce(0, +), 4)
    }

    func testDayCapsIdsIntoOther() {
        var d = LatencyDay(day: "2026-10-19")
        for i in 0..<(LatencyDay.maxActions + 10) { d.add("b\(i)", ms: 10) }
        XCTAssertEqual(d.actions.count, LatencyDay.maxActions + 1)
        XCTAssertEqual(d.actions[LatencyDay.otherId]?.n, 10)
        d.add("b0", ms: 10)
        XCTAssertEqual(d.actions["b0"]?.n, 2)        // a known id keeps counting past the cap
    }

    func testPayloadShapeSlowestFirst() throws {
        var d = LatencyDay(day: "2026-10-18")
        d.add("Send", ms: 20); d.add("Send", ms: 25)
        d.add("Open Settings", ms: 480)
        let p = d.payload(client: "mac/0.2.11")
        XCTAssertEqual(p["day"] as? String, "2026-10-18")
        let rows = try XCTUnwrapRows(p["actions"])
        XCTAssertEqual(rows.first?["id"] as? String, "Open Settings")
        XCTAssertEqual(rows.first?["o400"] as? Int, 1)
        XCTAssertEqual(rows.last?["n"] as? Int, 2)
        XCTAssertTrue(JSONSerialization.isValidJSONObject(p))
        XCTAssertEqual(d.slow().map(\.id), ["Open Settings"])
    }

    private func XCTUnwrapRows(_ v: Any?) throws -> [[String: Any]] {
        guard let r = v as? [[String: Any]] else { XCTFail("no rows"); return [] }
        return r
    }

    func testIdsAreCleaned() {
        XCTAssertEqual(LatencyID.clean("Refresh usage"), "Refresh usage")
        XCTAssertEqual(LatencyID.clean("  Open   creative \n"), "Open creative")
        XCTAssertEqual(LatencyID.clean("3 unread, 12 new"), "# unread # new")   // digits: one id for every count
        XCTAssertNil(LatencyID.clean("jdoe@example.com"))
        XCTAssertNil(LatencyID.clean("https://facebook.com/ads"))
        XCTAssertNil(LatencyID.clean("   "))
        XCTAssertNil(LatencyID.clean("1234"))
        XCTAssertNil(LatencyID.clean(nil))
        XCTAssertEqual(LatencyID.clean("Don\u{2019}t ask"), "Don't ask")
        XCTAssertEqual(LatencyID.clean(String(repeating: "a", count: 100))?.count, 64)
        XCTAssertEqual(LatencyID.clean("Лиа Send"), "Send")                     // the server takes ASCII ids only
    }

    func testDueDays() {
        let due = LatencyUpload.due(stored: ["2026-10-19", "2026-10-18", "2026-10-15", "junk", "2026-10-17"],
                                    uploaded: ["2026-10-17"], today: "2026-10-19")
        XCTAssertEqual(due, ["2026-10-15", "2026-10-18"])                         // not today, not sent, oldest first
        let many = (1...20).map { String(format: "2026-10-%02d", $0) }
        XCTAssertEqual(LatencyUpload.due(stored: many, uploaded: [], today: "2026-10-21").count, 7)
        XCTAssertEqual(LatencyUpload.due(stored: many, uploaded: [], today: "2026-10-21").last, "2026-10-20")
    }

    func testPartialToday() {
        XCTAssertFalse(LatencyUpload.partialDue(recordedSince: false, leaving: true, lastSent: nil, now: 100))   // nothing new
        XCTAssertTrue(LatencyUpload.partialDue(recordedSince: true, leaving: true, lastSent: 90, now: 100))      // background
        XCTAssertTrue(LatencyUpload.partialDue(recordedSince: true, leaving: false, lastSent: nil, now: 100))    // never sent
        XCTAssertFalse(LatencyUpload.partialDue(recordedSince: true, leaving: false, lastSent: 100, now: 100 + 60))
        XCTAssertTrue(LatencyUpload.partialDue(recordedSince: true, leaving: false, lastSent: 100, now: 100 + LatencyUpload.partialEvery))
    }

    func testConfigAnswer() {
        XCTAssertTrue(LatencyUpload.isOn(Data(#"{"ok":true,"on":true}"#.utf8)))
        XCTAssertFalse(LatencyUpload.isOn(Data(#"{"ok":true,"on":false}"#.utf8)))
        XCTAssertFalse(LatencyUpload.isOn(Data(#"{"ok":false,"error":"unauthorized"}"#.utf8)))
        XCTAssertFalse(LatencyUpload.isOn(Data("<html>".utf8)))
    }

    func testDayKeys() {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "Europe/Rome")!
        let d = Date(timeIntervalSince1970: 1_760_918_400)   // 00:00 UTC = 02:00 in Rome
        XCTAssertEqual(LiaDay.key(d, calendar: cal), "2025-10-20")
        XCTAssertEqual(LiaDay.key(daysBefore: 1, d, calendar: cal), "2025-10-19")
        XCTAssertTrue(LiaDay.valid("2026-01-02"))
        XCTAssertFalse(LiaDay.valid("2026-1-02"))
        XCTAssertFalse(LiaDay.valid("today"))
    }
}
