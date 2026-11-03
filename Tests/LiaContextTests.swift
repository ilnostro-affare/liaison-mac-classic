import XCTest
import Foundation
@testable import Liaison

/// What Lia knows of the person's work - Screen Time and open tabs (Shared/Core/LiaContext.swift).
final class LiaContextTests: XCTestCase {
    private var cal: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "Europe/Rome")!
        return c
    }
    private func at(_ y: Int, _ mo: Int, _ d: Int, _ h: Int, _ mi: Int = 0) -> Date {
        cal.date(from: DateComponents(year: y, month: mo, day: d, hour: h, minute: mi))!
    }

    func testScreenTimeTodayPlusShareOfYesterday() {
        var l = ScreenTimeLedger()
        l.days["2026-10-21"] = ScreenTimeDay(day: "2026-10-21", sites: ["facebook.com": 7200], agents: ["lia": 600],
                                             features: ["browser": 7200, "chats": 600])
        l.days["2026-10-20"] = ScreenTimeDay(day: "2026-10-20", sites: ["google.com": 3600], agents: [:], features: ["browser": 3600])
        l.days["2026-10-19"] = ScreenTimeDay(day: "2026-10-19", sites: ["old.com": 99_999], agents: [:], features: ["browser": 99_999])
        // 12:00: half of yesterday is inside the last 24 hours
        let s = LiaContext.screenTime(l, now: at(2026, 10, 21, 12), calendar: cal)
        XCTAssertEqual(s.top.first, LiaContext.Item(kind: "feature", name: "browser", minutes: 150))
        XCTAssertTrue(s.top.contains(LiaContext.Item(kind: "site", name: "facebook.com", minutes: 120)))
        XCTAssertTrue(s.top.contains(LiaContext.Item(kind: "site", name: "google.com", minutes: 30)))
        XCTAssertTrue(s.top.contains(LiaContext.Item(kind: "agent", name: "lia", minutes: 10)))
        XCTAssertFalse(s.top.contains { $0.name == "old.com" })
        XCTAssertEqual(s.totalMinutes, 160)
        let j = s.json
        XCTAssertEqual(j["period"] as? String, "24h")
        XCTAssertEqual(j["total_minutes"] as? Int, 160)
        XCTAssertEqual((j["top"] as? [JSONObject])?.count, s.top.count)
    }

    func testScreenTimeCapsAndDropsTinyRows() {
        var l = ScreenTimeLedger()
        var sites: [String: Double] = [:]
        for i in 0..<30 { sites["s\(i).com"] = Double(60 * (i + 1)) }
        sites["tiny.com"] = 20
        l.days["2026-10-21"] = ScreenTimeDay(day: "2026-10-21", sites: sites, agents: [:], features: [:])
        let s = LiaContext.screenTime(l, now: at(2026, 10, 21, 23, 59), calendar: cal)
        XCTAssertEqual(s.top.count, LiaContext.topCap)
        XCTAssertEqual(s.top.first?.name, "s29.com")
        XCTAssertFalse(s.top.contains { $0.name == "tiny.com" })
        XCTAssertEqual(LiaContext.screenTime(ScreenTimeLedger(), now: Date(), calendar: cal), LiaContext.ScreenTime())
    }

    func testWeekRollup() {
        var l = ScreenTimeLedger()
        l.days["2026-10-21"] = ScreenTimeDay(day: "2026-10-21", sites: ["facebook.com": 600], agents: [:], features: ["browser": 600])
        l.days["2026-10-16"] = ScreenTimeDay(day: "2026-10-16", sites: ["facebook.com": 1200], agents: [:], features: ["browser": 1200])
        l.days["2026-10-10"] = ScreenTimeDay(day: "2026-10-10", sites: ["old.com": 6000], agents: [:], features: ["browser": 6000])
        let r = LiaContext.rollup(l, now: at(2026, 10, 21, 9), calendar: cal)
        XCTAssertEqual(r.week.totalMinutes, 30)
        XCTAssertEqual(r.week.days.count, 7)
        XCTAssertEqual(r.week.days.last?.day, "2026-10-21")
        XCTAssertEqual(r.week.days.last?.minutes, 10)
        XCTAssertTrue(r.week.top.contains(LiaContext.Item(kind: "site", name: "facebook.com", minutes: 30)))
        XCTAssertFalse(r.week.top.contains { $0.name == "old.com" })
        XCTAssertEqual(r.today.totalMinutes, 10)
        XCTAssertTrue(r.today.days.isEmpty)
        let j = r.json
        XCTAssertEqual(((j["week"] as? JSONObject)?["days"] as? [JSONObject])?.count, 7)
        XCTAssertNil((j["today"] as? JSONObject)?["days"])
    }

    func testFrontTabFirstAndMarkedOnce() {
        var many = (0..<25).map { LiaContext.TabIn(title: "t\($0)", url: URL(string: "https://h\($0).com/")) }
        many[24] = LiaContext.TabIn(title: "Ads Manager", url: URL(string: "https://adsmanager.facebook.com/x"), front: true)
        let t = LiaContext.tabs(many)
        XCTAssertEqual(t.count, LiaContext.tabsCap)
        XCTAssertEqual(t.first, LiaContext.Tab(title: "Ads Manager", host: "adsmanager.facebook.com", front: true))
        XCTAssertEqual(t.filter(\.front).count, 1)
    }

    func testCleanName() {
        XCTAssertEqual(LiaContext.cleanName("Facebook.COM"), "facebook.com")
        XCTAssertEqual(LiaContext.cleanName("a b/c?d=1"), "abcd1")
        XCTAssertEqual(LiaContext.cleanName(String(repeating: "x", count: 100)).count, 64)
    }

    func testTabsHostOnlyAndFiltered() {
        let input = [
            LiaContext.TabIn(title: "Ads Manager - Acme", url: URL(string: "https://adsmanager.facebook.com/adsmanager/manage?act=123&token=secret")),
            LiaContext.TabIn(title: "New tab", url: nil, isStart: true),
            LiaContext.TabIn(title: "Local", url: URL(string: "file:///Users/jdoe/a.html")),
            LiaContext.TabIn(title: "Hidden", url: URL(string: "https://secret.com/x"), isPrivate: true),
            LiaContext.TabIn(title: "  Line\none\t two  ", url: URL(string: "https://WWW.Example.com:8443/p?q=1")),
            LiaContext.TabIn(title: "", url: URL(string: "https://notitle.io/")),
        ]
        let t = LiaContext.tabs(input)
        XCTAssertEqual(t, [
            LiaContext.Tab(title: "Ads Manager - Acme", host: "adsmanager.facebook.com"),
            LiaContext.Tab(title: "Line one two", host: "example.com"),
            LiaContext.Tab(title: "notitle.io", host: "notitle.io"),
        ])
        XCTAssertFalse(t.contains { $0.host.contains("/") || $0.host.contains("?") || $0.title.contains("secret") })
    }

    func testTabsCapsTitleAndCount() {
        let long = String(repeating: "a", count: 200)
        let many = (0..<40).map { LiaContext.TabIn(title: long, url: URL(string: "https://h\($0).com/")) }
        let t = LiaContext.tabs(many)
        XCTAssertEqual(t.count, LiaContext.tabsCap)
        XCTAssertTrue(t.allSatisfy { $0.title.count <= LiaContext.titleCap })
        XCTAssertTrue(t[0].title.hasSuffix("\u{2026}"))
    }

    func testPayloadShape() {
        let now = at(2026, 10, 21, 14, 5)
        let r = LiaContext.Rollup(last24h: LiaContext.ScreenTime(top: [.init(kind: "site", name: "facebook.com", minutes: 5)], totalMinutes: 5))
        let p = LiaContext.payload(screenTime: r, tabs: [.init(title: "T", host: "h.com", front: true)], now: now, timeZone: TimeZone(identifier: "Europe/Rome")!)
        let st = p["screen_time"] as? JSONObject
        XCTAssertEqual((st?["week"] as? JSONObject)?["period"] as? String, "7d")
        XCTAssertEqual((st?["today"] as? JSONObject)?["period"] as? String, "today")
        XCTAssertEqual((p["tabs"] as? [JSONObject])?.first?["front"] as? Bool, true)
        XCTAssertEqual(p["local_time"] as? String, "2026-10-21 14:05")
        XCTAssertEqual(p["weekday"] as? String, "Wednesday")
        XCTAssertEqual((p["tabs"] as? [JSONObject])?.first?["host"] as? String, "h.com")
        XCTAssertEqual((p["screen_time"] as? JSONObject)?["total_minutes"] as? Int, 5)
        XCTAssertEqual(JSONSerialization.isValidJSONObject(p), true)
    }

    func testForLiaAndCache() {
        XCTAssertTrue(LiaContext.forLia(agent: nil, dialogueAgent: "lia"))
        XCTAssertTrue(LiaContext.forLia(agent: "lia", dialogueAgent: "met"))
        XCTAssertFalse(LiaContext.forLia(agent: "dev", dialogueAgent: "lia"))
        XCTAssertFalse(LiaContext.forLia(agent: nil, dialogueAgent: "met"))
        let now = Date()
        XCTAssertFalse(LiaContext.fresh(at: nil, now: now))
        XCTAssertTrue(LiaContext.fresh(at: now.addingTimeInterval(-299), now: now))
        XCTAssertFalse(LiaContext.fresh(at: now.addingTimeInterval(-301), now: now))
        XCTAssertFalse(LiaContext.fresh(at: now.addingTimeInterval(60), now: now))
    }

    func testOnByDefault() {
        let d = UserDefaults(suiteName: "lia-context-tests-\(UUID().uuidString)")!
        XCTAssertTrue(LiaContext.isOn(d))
        d.set(false, forKey: LiaContext.onKey)
        XCTAssertFalse(LiaContext.isOn(d))
    }
}
