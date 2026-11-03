import XCTest
import Foundation
@testable import Liaison

/// 0.2.11: Screen Time, local only (Shared/Core/ScreenTime.swift).
final class ScreenTimeTests: XCTestCase {
    private var cal: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "Europe/Rome")!
        return c
    }
    private func at(_ y: Int, _ mo: Int, _ d: Int, _ h: Int, _ mi: Int = 0, _ s: Int = 0) -> Date {
        cal.date(from: DateComponents(year: y, month: mo, day: d, hour: h, minute: mi, second: s))!
    }
    private let web = ScreenTimeSample(active: true, feature: .browser, site: "facebook.com", agent: nil)

    func testRegistrableDomain() {
        XCTAssertEqual(ScreenTimeDomain.registrable(URL(string: "https://www.facebook.com/ads")), "facebook.com")
        XCTAssertEqual(ScreenTimeDomain.registrable(URL(string: "https://business.facebook.com/")), "facebook.com")
        XCTAssertEqual(ScreenTimeDomain.registrable(URL(string: "https://www.bbc.co.uk/news")), "bbc.co.uk")
        XCTAssertEqual(ScreenTimeDomain.registrable(URL(string: "https://jdoe.github.io/x")), "jdoe.github.io")
        XCTAssertEqual(ScreenTimeDomain.registrable(URL(string: "http://localhost:8080/")), "localhost")
        XCTAssertEqual(ScreenTimeDomain.registrable(URL(string: "http://192.168.1.10/")), "192.168.1.10")
        XCTAssertEqual(ScreenTimeDomain.registrable(URL(string: "https://Liaisone.COM./")), "liaisone.com")
        XCTAssertNil(ScreenTimeDomain.registrable(URL(string: "about:blank")))
        XCTAssertNil(ScreenTimeDomain.registrable(URL(string: "file:///Users/jdoe/a.html")))
        XCTAssertNil(ScreenTimeDomain.registrable(nil))
    }

    func testClockCountsOnlyActiveIntervals() {
        var c = ScreenTimeClock(maxGap: 30)
        let t0 = at(2026, 10, 19, 10)
        XCTAssertNil(c.tick(now: t0, sample: web, idle: 0))                                   // the first tick only starts
        let r = c.tick(now: t0.addingTimeInterval(10), sample: web, idle: 2)
        XCTAssertEqual(r.map { $0.to.timeIntervalSince($0.from) }, 10)
        XCTAssertEqual(r?.sample.site, "facebook.com")
        XCTAssertNotNil(c.tick(now: t0.addingTimeInterval(20), sample: .inactive, idle: 0))  // counted: it was active
        XCTAssertNil(c.tick(now: t0.addingTimeInterval(30), sample: web, idle: 0))           // was inactive: nothing
        XCTAssertNotNil(c.tick(now: t0.addingTimeInterval(40), sample: web, idle: 0))
    }

    func testIdlePausesAndLongGapsDrop() {
        var c = ScreenTimeClock(maxGap: 30)
        let t0 = at(2026, 10, 19, 10)
        _ = c.tick(now: t0, sample: web, idle: 0)
        XCTAssertNil(c.tick(now: t0.addingTimeInterval(10), sample: web, idle: 61))         // idle past 60 s: not counted
        XCTAssertNil(c.tick(now: t0.addingTimeInterval(20), sample: web, idle: 0))          // and the idle tick was inactive
        XCTAssertNotNil(c.tick(now: t0.addingTimeInterval(30), sample: web, idle: 0))
        XCTAssertNil(c.tick(now: t0.addingTimeInterval(400), sample: web, idle: 0))         // a sleep: dropped
        XCTAssertNotNil(c.pause(now: t0.addingTimeInterval(405)))                           // screen locked: closed
        XCTAssertNil(c.tick(now: t0.addingTimeInterval(410), sample: web, idle: 0))         // nothing during the lock
    }

    func testLedgerSplitsAtMidnight() {
        var l = ScreenTimeLedger()
        l.add(from: at(2026, 10, 18, 23, 59, 50), to: at(2026, 10, 19, 0, 0, 20), sample: web, calendar: cal)
        XCTAssertEqual(l.days["2026-10-18"]?.sites["facebook.com"], 10)
        XCTAssertEqual(l.days["2026-10-19"]?.sites["facebook.com"], 20)
        XCTAssertEqual(l.days["2026-10-19"]?.features["browser"], 20)
        l.add(from: at(2026, 10, 19, 9), to: at(2026, 10, 19, 8), sample: web, calendar: cal)            // backwards
        l.add(from: at(2026, 10, 19, 9), to: at(2026, 10, 19, 10), sample: .inactive, calendar: cal)      // inactive
        XCTAssertEqual(l.days["2026-10-19"]?.total, 20)
    }

    func testPruneKeepsThirtyDays() {
        var l = ScreenTimeLedger()
        for d in 1...40 {
            let day = cal.date(byAdding: .day, value: -d + 1, to: at(2026, 10, 19, 12))!
            l.add(from: day, to: day.addingTimeInterval(5), sample: web, calendar: cal)
        }
        l.prune(now: at(2026, 10, 19, 12), calendar: cal)
        XCTAssertEqual(l.days.count, ScreenTimeLedger.keepDays)
        XCTAssertNotNil(l.days["2026-09-20"])
        XCTAssertNil(l.days["2026-09-19"])
    }

    func testSummaryTodayAndWeek() {
        var l = ScreenTimeLedger()
        let chat = ScreenTimeSample(active: true, feature: .chats, site: "facebook.com", agent: "met")
        let home = ScreenTimeSample(active: true, feature: .home, site: nil, agent: nil)
        l.add(from: at(2026, 10, 19, 9), to: at(2026, 10, 19, 9, 30), sample: web, calendar: cal)
        l.add(from: at(2026, 10, 19, 10), to: at(2026, 10, 19, 10, 10), sample: chat, calendar: cal)
        l.add(from: at(2026, 10, 15, 10), to: at(2026, 10, 15, 11), sample: home, calendar: cal)
        l.add(from: at(2026, 10, 1, 10), to: at(2026, 10, 1, 11), sample: web, calendar: cal)              // outside the week
        let today = l.summary(.today, now: at(2026, 10, 19, 12), calendar: cal)
        XCTAssertEqual(today.total, 40 * 60)
        XCTAssertEqual(today.sites.map(\.id), ["facebook.com"])
        XCTAssertEqual(today.sites.first?.seconds, 40 * 60)
        XCTAssertEqual(today.agents.map(\.id), ["met"])
        XCTAssertEqual(today.features.map(\.id), ["browser", "chats"])
        let week = l.summary(.week, now: at(2026, 10, 19, 12), calendar: cal)
        XCTAssertEqual(week.total, 100 * 60)
        XCTAssertEqual(week.features.first?.id, "home")
        XCTAssertEqual(week.perDay.count, 7)
        XCTAssertEqual(week.perDay.first?.day, "2026-10-13")
        XCTAssertEqual(week.perDay.last?.day, "2026-10-19")
        XCTAssertEqual(week.todaySeconds, 40 * 60)
        XCTAssertEqual(ScreenTimeSummary.share(week.features[1], of: week.features), 0.5)
    }

    func testFormat() {
        XCTAssertEqual(ScreenTimeSummary.format(0), "0 min")
        XCTAssertEqual(ScreenTimeSummary.format(45), "45 s")
        XCTAssertEqual(ScreenTimeSummary.format(12 * 60 + 20), "12 min")
        XCTAssertEqual(ScreenTimeSummary.format(2 * 3600 + 5 * 60), "2 h 05 min")
    }

    func testLedgerRoundTrips() throws {
        var l = ScreenTimeLedger()
        l.add(from: at(2026, 10, 19, 9), to: at(2026, 10, 19, 9, 1), sample: web, calendar: cal)
        let back = try JSONDecoder().decode(ScreenTimeLedger.self, from: JSONEncoder().encode(l))
        XCTAssertEqual(back, l)
    }
}
