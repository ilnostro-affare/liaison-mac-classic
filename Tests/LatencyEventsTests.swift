import XCTest
import Foundation
@testable import Liaison

/// The day's slow events, their conditions and the factor blamed (Shared/Core/Latency.swift).
final class LatencyEventsTests: XCTestCase {
    private func ev(_ id: String, _ ms: Double, t: Int = 0) -> LatencyEvent { LatencyEvent(id: id, ms: ms, t: t) }

    func testThreshold() {
        XCTAssertFalse(LatencyEvent.isSlow("Send", ms: 250))
        XCTAssertTrue(LatencyEvent.isSlow("Send", ms: 251))
        XCTAssertTrue(LatencyEvent.isSlow("open:Settings", ms: 300))
        XCTAssertTrue(LatencyEvent.isSlow("agent_open:cold:settled", ms: 900))
        XCTAssertFalse(LatencyEvent.isSlow("Send", ms: .nan))
    }

    func testCapKeepsTheSlowest() {
        var d = LatencyDay(day: "2026-10-21")
        for i in 0..<LatencyDay.maxEvents { d.addEvent(ev("b\(i)", 300 + Double(i))) }
        XCTAssertEqual(d.events.count, LatencyDay.maxEvents)
        d.addEvent(ev("faster", 260))                      // slower than nothing kept: dropped
        XCTAssertFalse(d.events.contains { $0.id == "faster" })
        d.addEvent(ev("worst", 5000))                      // replaces the fastest (300)
        XCTAssertEqual(d.events.count, LatencyDay.maxEvents)
        XCTAssertTrue(d.events.contains { $0.id == "worst" })
        XCTAssertFalse(d.events.contains { $0.id == "b0" })
        XCTAssertEqual(d.events.map(\.ms).min(), 301)
        d.addEvent(ev("bad", -1))
        XCTAssertFalse(d.events.contains { $0.id == "bad" })
    }

    func testOldDayFileDecodesWithoutEvents() throws {
        let old = #"{"day":"2026-10-20","actions":{"Send":{"counts":[1,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0],"n":1,"max":5,"over100":0,"over400":0}}}"#
        let d = try JSONDecoder().decode(LatencyDay.self, from: Data(old.utf8))
        XCTAssertEqual(d.day, "2026-10-20")
        XCTAssertEqual(d.actions["Send"]?.n, 1)
        XCTAssertTrue(d.events.isEmpty)
        var n = d
        n.addEvent(LatencyEvent.make(id: "Send", ms: 400, at: Date(timeIntervalSince1970: 0), phases: ["handler": 380], ctx: LatencyCtx()))
        let back = try JSONDecoder().decode(LatencyDay.self, from: JSONEncoder().encode(n))
        XCTAssertEqual(back, n)                            // events survive the day file
    }

    func testPayloadCarriesEventsSlowestFirstAndStaysSmall() {
        var d = LatencyDay(day: "2026-10-21")
        d.add("Send", ms: 400)
        var ctx = LatencyCtx()
        ctx.agent = "lia"; ctx.thread = "cold"; ctx.rows = "20-100"; ctx.firstSinceLaunch = true; ctx.uptime = "lt600"
        ctx.busy = false; ctx.tabs = "2-5"; ctx.loading = 0; ctx.windows = 1; ctx.lowPower = false; ctx.thermal = "nominal"
        ctx.memMb = 750; ctx.onBattery = false
        for i in 0..<LatencyDay.maxEvents {
            d.addEvent(LatencyEvent.make(id: "agent_open:cold:settled", ms: 300 + Double(i), at: Date(),
                                         phases: ["sheet": 40, "first_frame": 200 + Double(i), "settled": 60, "stall": 150], ctx: ctx))
        }
        let p = d.payload(client: "mac/0.2.12")
        guard let evs = p["events"] as? [[String: Any]] else { XCTFail("no events"); return }
        XCTAssertTrue(evs.count >= 180, "\(evs.count) events")
        XCTAssertEqual(evs.first?["ms"] as? Int, 499)
        let size = (try? JSONSerialization.data(withJSONObject: p).count) ?? 999_999
        XCTAssertTrue(size <= LatencyEvent.payloadBudget, "body \(size) bytes")
        let small = d.payload(client: "x", maxBytes: 2_000)
        let few = (small["events"] as? [[String: Any]]) ?? []
        XCTAssertTrue(few.count < 10)
        XCTAssertEqual(few.first?["ms"] as? Int, 499)       // a cut drops the fastest
        XCTAssertTrue(JSONSerialization.isValidJSONObject(p))
        let one = evs[0]
        XCTAssertEqual(one["cause"] as? String, "cold_thread_layout")
        XCTAssertEqual((one["ctx"] as? [String: Any])?["mem_mb"] as? Int, 750)
        XCTAssertEqual((one["ctx"] as? [String: Any])?["first_since_launch"] as? Bool, true)
        XCTAssertNil((one["ctx"] as? [String: Any])?["low_power"])      // false is left out (absent = false)
        XCTAssertNil((one["ctx"] as? [String: Any])?["thermal"])        // nominal too
        XCTAssertEqual((one["phases"] as? [String: Any])?["first_frame"] as? Int, 399)
    }

    func testBuckets() {
        XCTAssertEqual(LatencyBucket.rows(0), "0-20")
        XCTAssertEqual(LatencyBucket.rows(20), "20-100")
        XCTAssertEqual(LatencyBucket.rows(499), "100-500")
        XCTAssertEqual(LatencyBucket.rows(500), "500up")
        XCTAssertEqual(LatencyBucket.uptime(59), "lt60")
        XCTAssertEqual(LatencyBucket.uptime(300), "lt600")
        XCTAssertEqual(LatencyBucket.uptime(601), "ge600")
        XCTAssertEqual(LatencyBucket.count(0), "0")
        XCTAssertEqual(LatencyBucket.count(1), "1")
        XCTAssertEqual(LatencyBucket.count(5), "2-5")
        XCTAssertEqual(LatencyBucket.count(20), "6-20")
        XCTAssertEqual(LatencyBucket.count(21), "21up")
        XCTAssertEqual(LatencyBucket.memory(bytes: 1_048_576 * 749), 500)
        XCTAssertEqual(LatencyBucket.memory(bytes: 1_048_576 * 750), 750)
        XCTAssertEqual(LatencyBucket.agent("Lia"), "lia")
        XCTAssertEqual(LatencyBucket.agent("team"), "other")
        XCTAssertEqual(LatencyBucket.agent(nil), "other")
    }

    func testUTCSeconds() {
        XCTAssertEqual(LatencyEvent.secondsOfUTCDay(Date(timeIntervalSince1970: 86400 * 3 + 3661)), 3661)
        XCTAssertEqual(LatencyEvent.secondsOfUTCDay(Date(timeIntervalSince1970: 0)), 0)
    }

    func testSpans() {
        var s = LatencySpans()
        s.add(start: 10.0, end: 10.01)                     // under 16 ms: not a block
        XCTAssertTrue(s.spans.isEmpty)
        s.add(start: 10.0, end: 10.3)
        s.add(start: 11.0, end: 11.1)
        XCTAssertEqual(Int(s.longest(from: 9, to: 12).rounded()), 300)
        XCTAssertEqual(Int(s.longest(from: 10.2, to: 12).rounded()), 100)   // only the part inside the window
        XCTAssertEqual(s.longest(from: 12, to: 13), 0)
        XCTAssertEqual(Int(s.longest(from: 12, to: 13, open: 12.5).rounded()), 500)   // the pass running now
        XCTAssertEqual(s.longest(from: 13, to: 12), 0)
        for i in 0..<(LatencySpans.capacity + 5) { s.add(start: Double(100 + i), end: Double(100 + i) + 0.05) }
        XCTAssertEqual(s.spans.count, LatencySpans.capacity)
    }

    func testCausePhases() {
        let ctx = LatencyCtx()
        XCTAssertEqual(LatencyCause.classify(id: "Send", ms: 400, phases: ["queue": 300, "handler": 60, "render": 40], ctx: ctx).cause, "queue_wait")
        XCTAssertEqual(LatencyCause.classify(id: "Send", ms: 400, phases: ["queue": 5, "handler": 350, "render": 45], ctx: ctx).cause, "handler_work")
        XCTAssertEqual(LatencyCause.classify(id: "Send", ms: 400, phases: ["queue": 5, "handler": 45, "render": 350], ctx: ctx).cause, "render")
        var cold = LatencyCtx(); cold.thread = "cold"; cold.rows = "20-100"
        let c = LatencyCause.classify(id: "agent_open:cold:settled", ms: 800, phases: ["sheet": 250, "first_frame": 450, "settled": 100], ctx: cold)
        XCTAssertEqual(c.cause, "cold_thread_layout")
        XCTAssertEqual(c.also, ["sheet_build"])          // a quarter or more
        var kept = LatencyCtx(); kept.thread = "kept"; kept.rows = "100-500"
        XCTAssertEqual(LatencyCause.classify(id: "agent_open:kept:settled", ms: 600, phases: ["sheet": 50, "first_frame": 450, "settled": 100], ctx: kept).cause, "many_rows")
        XCTAssertEqual(LatencyCause.classify(id: "agent_open:kept:settled", ms: 600, phases: ["sheet": 400, "first_frame": 100, "settled": 100], ctx: kept).cause, "sheet_build")
    }

    func testCauseStallAndConditions() {
        // no phase holds half; one block does
        let s = LatencyCause.classify(id: "open:Settings", ms: 500, phases: ["stall": 300], ctx: LatencyCtx())
        XCTAssertEqual(s.cause, "main_stall")
        var hot = LatencyCtx(); hot.thermal = "serious"; hot.busy = true; hot.loading = 2
        let h = LatencyCause.classify(id: "open:Settings", ms: 500, phases: ["stall": 40], ctx: hot)
        XCTAssertEqual(h.cause, "thermal")
        XCTAssertEqual(h.also, ["busy_agent", "page_loading"])
        var mem = LatencyCtx(); mem.memMb = 1500; mem.lowPower = true
        XCTAssertEqual(LatencyCause.classify(id: "x", ms: 300, phases: [:], ctx: mem).cause, "low_power")
        mem.lowPower = false
        XCTAssertEqual(LatencyCause.classify(id: "x", ms: 300, phases: [:], ctx: mem).cause, "memory")
        var first = LatencyCtx(); first.firstSinceLaunch = true
        XCTAssertEqual(LatencyCause.classify(id: "x", ms: 300, phases: ["handler": 100, "render": 100], ctx: first).cause, "first_open_after_launch")
        // a strong phase wins over a condition, the condition goes to also
        let q = LatencyCause.classify(id: "Send", ms: 400, phases: ["queue": 350, "handler": 50, "stall": 340], ctx: hot)
        XCTAssertEqual(q.cause, "queue_wait")
        XCTAssertEqual(q.also, ["main_stall", "thermal"])
        XCTAssertEqual(LatencyCause.classify(id: "x", ms: 300, phases: [:], ctx: LatencyCtx()).cause, "unknown")
        XCTAssertEqual(LatencyCause.classify(id: "x", ms: 300, phases: ["handler": 100, "render": 60], ctx: LatencyCtx()).cause, "handler_work")
        var many = LatencyCtx(); many.rows = "500up"
        XCTAssertEqual(LatencyCause.classify(id: "x", ms: 300, phases: [:], ctx: many).cause, "many_rows")
        for f in [s.cause, h.cause, q.cause] + h.also + q.also { XCTAssertTrue(LatencyCause.all.contains(f)) }
    }
}
