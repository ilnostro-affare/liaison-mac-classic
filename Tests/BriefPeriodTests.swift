import XCTest
import Foundation
@testable import Liaison

/// Home's Meta brief: rolling periods and their day ranges, sums per currency (never across), the
/// comparison with the equal period before, the template sentence; and the next-task chips' fingerprint.
final class BriefPeriodTests: XCTestCase {
    private func st(_ spend: Double, _ leads: Double, results: Double = 0, cpl: Double? = nil, _ cur: String? = "EUR") -> TourStats {
        TourStats(spend: spend, leads: leads, results: results, cpl: cpl, currency: cur)
    }

    private var utc: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }

    /// 10:30 UTC.
    private var now: Date { Date(timeIntervalSince1970: 1_792_405_800) }

    func testPeriodsCycleAndRemember() {
        XCTAssertEqual(BriefPeriod.allCases.map(\.title), ["Today", "Yesterday", "Last 7 days", "Last 30 days"])
        XCTAssertEqual(BriefPeriod.today.next, .yesterday)
        XCTAssertEqual(BriefPeriod.yesterday.next, .week)
        XCTAssertEqual(BriefPeriod.week.next, .month)
        XCTAssertEqual(BriefPeriod.month.next, .today)
        XCTAssertEqual(BriefPeriod.stored("week"), .week)
        XCTAssertEqual(BriefPeriod.stored(" Month "), .month)
        XCTAssertEqual(BriefPeriod.stored(nil), .yesterday)
        XCTAssertEqual(BriefPeriod.stored("calendar-week"), .yesterday)
        XCTAssertTrue(BriefPeriod.key(profile: "p1").hasSuffix("p1|"))   // Reset this workspace clears it
        XCTAssertTrue(BriefPeriod.key(profile: "p1") != BriefPeriod.key(profile: "p2"))
    }

    func testRangesAreRollingWholeDays() {
        XCTAssertEqual(BriefPeriod.stamp(now, calendar: utc), "2026-10-19")
        XCTAssertTrue(BriefPeriod.today.range(now: now, calendar: utc) == ("2026-10-19", "2026-10-19"))
        XCTAssertNil(BriefPeriod.today.previousRange(now: now, calendar: utc))
        XCTAssertNil(BriefPeriod.today.comparison)
        XCTAssertTrue(BriefPeriod.yesterday.range(now: now, calendar: utc) == ("2026-10-18", "2026-10-18"))
        XCTAssertTrue(BriefPeriod.yesterday.previousRange(now: now, calendar: utc)! == ("2026-10-17", "2026-10-17"))
        // Seven whole days ending yesterday, not Monday to today.
        XCTAssertTrue(BriefPeriod.week.range(now: now, calendar: utc) == ("2026-10-12", "2026-10-18"))
        XCTAssertTrue(BriefPeriod.week.previousRange(now: now, calendar: utc)! == ("2026-10-05", "2026-10-11"))
        // Thirty days across a month end, not "this October".
        XCTAssertTrue(BriefPeriod.month.range(now: now, calendar: utc) == ("2026-09-19", "2026-10-18"))
        XCTAssertTrue(BriefPeriod.month.previousRange(now: now, calendar: utc)! == ("2026-08-20", "2026-09-18"))
        // The day is the calendar's: 23:30 in Tokyo is already the next day.
        var tokyo = Calendar(identifier: .gregorian)
        tokyo.timeZone = TimeZone(identifier: "Asia/Tokyo")!
        let late = Date(timeIntervalSince1970: 1_792_405_800 + 14 * 3600)   // 09:30 Tokyo
        XCTAssertEqual(BriefPeriod.today.range(now: late, calendar: tokyo).from, "2026-10-20")
    }

    func testOneAccountStaysAsTheServerSaid() {
        let g = BriefTotals.groups(current: [st(100, 4, cpl: 25)], previous: [st(90, 3, cpl: 30)])
        XCTAssertEqual(g.count, 1)
        XCTAssertEqual(g[0].stats.spend, 100)
        XCTAssertEqual(g[0].stats.cpl, 25)
        XCTAssertEqual(g[0].prev?.costPer, 30)
        XCTAssertEqual(g[0].accounts, 1)
    }

    func testAccountsInOneCurrencyAreSummed() {
        let g = BriefTotals.groups(current: [st(100, 4, cpl: 25), st(50, 1, cpl: 50), st(30, 0, results: 3)],
                                   previous: [st(80, 4), st(20, 1), st(10, 0)])
        XCTAssertEqual(g.count, 1)
        XCTAssertEqual(g[0].stats.spend, 180)
        XCTAssertEqual(g[0].stats.leads, 5)
        XCTAssertEqual(g[0].stats.results, 3)
        XCTAssertTrue(abs((g[0].stats.cpl ?? 0) - 36) < 0.0001)
        XCTAssertTrue(abs((g[0].prev?.costPer ?? 0) - 22) < 0.0001)   // 110 / 5
        XCTAssertEqual(g[0].accounts, 3)
        XCTAssertEqual(g[0].spendChange, 64)   // 180 vs 110
        XCTAssertEqual(g[0].costChange, 64)    // 36 vs 22
    }

    func testCurrenciesAreNeverSummedTogether() {
        let g = BriefTotals.groups(current: [st(100, 4, "EUR"), st(500, 2, "USD"), st(10, 1, "eur"), st(1, 1, nil), st(7, 0, "USD")],
                                   previous: [st(100, 4), st(1, 1, "USD"), st(10, 1), st(1, 1), st(7, 1, "USD")])
        XCTAssertEqual(g.count, 2)
        XCTAssertEqual(g[0].stats.currency, "EUR")
        XCTAssertEqual(g[0].stats.spend, 111)      // EUR + eur + the one without a currency (joins the first)
        XCTAssertEqual(g[0].accounts, 3)
        XCTAssertEqual(g[1].stats.currency, "USD")
        XCTAssertEqual(g[1].stats.spend, 507)
        XCTAssertEqual(g[1].accounts, 2)
        XCTAssertEqual(g[1].prev?.spend, 8)
        XCTAssertEqual(g.reduce(0) { $0 + $1.stats.spend }, 618)   // nothing lost, nothing counted twice
    }

    func testFailedAccountsAndMissingPrevious() {
        XCTAssertTrue(BriefTotals.groups(current: [nil, nil], previous: [nil, nil]).isEmpty)
        let g = BriefTotals.groups(current: [nil, st(40, 2)], previous: [st(1, 1), nil])
        XCTAssertEqual(g[0].stats.spend, 40)
        XCTAssertNil(g[0].prev)          // the summed account had no previous period
        XCTAssertNil(g[0].spendChange)
        // No comparison asked (Today): no previous at all.
        XCTAssertNil(BriefTotals.groups(current: [st(5, 1)], previous: [])[0].prev)
        XCTAssertEqual(BriefTotals.accounts(["act_12", "34", "12", ""], first: "56"), ["12", "34", "56"])
        XCTAssertEqual(BriefTotals.accounts([], first: nil), [])
    }

    func testGroupsSurviveTheDiskCopy() throws {
        let g = BriefTotals.groups(current: [st(100, 4, cpl: 25), st(5, 0, results: 1, "USD")], previous: [st(90, 3, cpl: 30), nil])
        let back = try JSONDecoder().decode([BriefGroup].self, from: JSONEncoder().encode(g))
        XCTAssertEqual(back, g)
    }

    func testSentenceIsATemplate() {
        let eur = BriefTotals.groups(current: [st(35.59, 5, cpl: 7.118)], previous: [st(40, 4, cpl: 10)])[0]
        let y = BriefText.sentence(eur, period: .yesterday)
        XCTAssertTrue(y.hasPrefix("Yesterday you spent "))
        XCTAssertTrue(y.contains("and got 5 leads at "))
        XCTAssertTrue(BriefText.sentence(eur, period: .week).hasPrefix("In the last 7 days you spent "))
        XCTAssertTrue(BriefText.sentence(eur, period: .today).hasPrefix("Today so far you spent "))
        XCTAssertEqual(BriefText.change(eur, period: .yesterday), "Spend \u{2212}11%, cost per lead \u{2212}29% vs the day before.")
        XCTAssertEqual(BriefText.change(eur, period: .week), "Spend \u{2212}11%, cost per lead \u{2212}29% vs the previous 7 days.")
        XCTAssertNil(BriefText.change(eur, period: .today))
        let none = BriefTotals.groups(current: [st(0, 0)], previous: [])[0]
        XCTAssertEqual(BriefText.sentence(none, period: .month), "Nothing ran over the last 30 days: no spend, no results.")
        XCTAssertEqual(BriefText.sentence(none, period: .today), "Nothing has run today yet: no spend, no results.")
        let one = BriefTotals.groups(current: [st(10, 0, results: 1)], previous: [])[0]
        XCTAssertTrue(BriefText.sentence(one, period: .yesterday).contains("got 1 result at "))
        XCTAssertEqual(BriefText.pct(0), "flat")
        XCTAssertEqual(BriefText.pct(12), "+12%")
        XCTAssertEqual(BriefText.arrow(-8), "\u{2193}8%")
        XCTAssertNil(BriefText.arrow(0))
        XCTAssertNil(BriefText.arrow(nil))
    }

    func testSuggestFingerprintChangesOnlyWithTheMessages() {
        let a: [(agent: String?, text: String)] = [(agent: "lia", text: "CPL rose"), (agent: nil, text: "why?")]
        XCTAssertEqual(Suggest.fingerprint(a), Suggest.fingerprint(a))
        XCTAssertEqual(Suggest.fingerprint(a), Suggest.fingerprint(a + [(agent: nil, text: "   ")]))   // empty is not news
        XCTAssertTrue(Suggest.fingerprint(a) != Suggest.fingerprint(a + [(agent: "met", text: "Paused")]))
        XCTAssertTrue(Suggest.fingerprint([(agent: nil, text: "ab"), (agent: nil, text: "c")])
                      != Suggest.fingerprint([(agent: nil, text: "a"), (agent: nil, text: "bc")]))
        XCTAssertTrue(Suggest.fingerprint([(agent: "lia", text: "x")]) != Suggest.fingerprint([(agent: "met", text: "x")]))
    }
}
