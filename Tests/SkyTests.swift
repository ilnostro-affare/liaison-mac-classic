import XCTest
import Foundation
@testable import Liaison

/// Home's living sky (phase + weather -> gradient) and the repositories' activity in the brief.
final class SkyTests: XCTestCase {
    private let utc = TimeZone(identifier: "UTC")!

    private func at(_ h: Int, _ m: Int = 0, day: Int = 14) -> Date {
        var c = DateComponents()
        c.year = 2026; c.month = 10; c.day = day; c.hour = h; c.minute = m
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = utc
        return cal.date(from: c)!
    }

    func testParseReport() {
        let json = #"{"ok":true,"city":"Milan","temp_c":21.4,"code":0,"is_day":1,"condition":"Rain","sunrise":1792044000000,"sunset":1792083600000,"tz":"Europe/Rome"}"#
        let r = SkyReport.parse(Data(json.utf8))
        XCTAssertEqual(r?.city, "Milan")
        XCTAssertEqual(r?.condition, .rain)
        XCTAssertEqual(r?.isDay, true)
        XCTAssertEqual(r?.tz, "Europe/Rome")
        XCTAssertEqual(r?.sunrise?.timeIntervalSince1970, 1792044000)
        XCTAssertNil(SkyReport.parse(Data(#"{"ok":false}"#.utf8)))
        let odd = SkyReport.parse(Data(#"{"ok":true,"condition":"hail","city":"  ","is_day":false}"#.utf8))
        XCTAssertEqual(odd?.condition, .clear)
        XCTAssertNil(odd?.city)
        XCTAssertEqual(odd?.isDay, false)
        XCTAssertNil(odd?.tempC)
    }

    func testPhaseFromSunriseAndSunset() {
        let rise = at(7, 20), set = at(18, 30)
        func p(_ h: Int, _ m: Int = 0) -> SkyPhase { Sky.phase(now: at(h, m), sunrise: rise, sunset: set, timeZone: utc) }
        XCTAssertEqual(p(3), .night)
        XCTAssertEqual(p(6, 50), .dawn)
        XCTAssertEqual(p(8, 30), .morning)
        XCTAssertEqual(p(13), .day)
        XCTAssertEqual(p(17, 30), .golden)
        XCTAssertEqual(p(18, 50), .dusk)
        XCTAssertEqual(p(21), .night)
        // Yesterday's report: compared by time of day.
        XCTAssertEqual(Sky.phase(now: at(13, day: 15), sunrise: rise, sunset: set, timeZone: utc), .day)
    }

    func testPhaseFallsBackToTheClock() {
        XCTAssertEqual(Sky.phase(now: at(12), sunrise: nil, sunset: nil, timeZone: utc), .day)
        XCTAssertEqual(Sky.phase(now: at(23), sunrise: nil, sunset: nil, timeZone: utc), .night)
        // Sunset before sunrise: unusable, defaults (06:30 / 19:00).
        XCTAssertEqual(Sky.phase(now: at(6, 20), sunrise: at(18), sunset: at(6), timeZone: utc), .dawn)
        // A very short day never traps on crossed bounds.
        for h in 0..<24 { _ = Sky.phase(now: at(h), sunrise: at(11, 30), sunset: at(12, 31), timeZone: utc) }
    }

    func testLooks() {
        for p in SkyPhase.allCases {
            for c in SkyCondition.allCases {
                let l = Sky.look(phase: p, condition: c)
                XCTAssertTrue(l.stops.count >= 3)
                XCTAssertEqual(l.stops.first?.location, 0)
                XCTAssertEqual(l.stops.last?.location, 1)
            }
        }
        XCTAssertTrue(Sky.look(phase: .night, condition: .clear).lightText)
        XCTAssertEqual(Sky.look(phase: .night, condition: .clear).motion, .stars)
        XCTAssertFalse(Sky.look(phase: .morning, condition: .clear).lightText)
        XCTAssertFalse(Sky.look(phase: .day, condition: .snow).lightText)
        XCTAssertEqual(Sky.look(phase: .day, condition: .rain).motion, .rain)
        XCTAssertNil(Sky.look(phase: .day, condition: .storm).glow)
        // Weather greys the sky: rain is darker than the clear day.
        XCTAssertTrue(Sky.look(phase: .day, condition: .rain).top.luminance < Sky.look(phase: .day, condition: .clear).top.luminance)
        // From a report with its own time zone.
        let r = SkyReport(city: "Milan", tempC: 21, code: 0, isDay: true, condition: .cloudy, sunrise: nil, sunset: nil, tz: "UTC")
        XCTAssertEqual(Sky.look(now: at(12), report: r).phase, .day)
        XCTAssertEqual(Sky.look(now: at(12), report: r).condition, .cloudy)
        XCTAssertEqual(Sky.look(now: at(12), report: nil, timeZone: utc).condition, .clear)
    }

    // The sky's gradients in OKLab, the glow's bell, the clouds' light, the shooting star.
    func testSmootherSky() {
        let a = SkyRGB(0x4466AE), b = SkyRGB(0xF6CB95)
        XCTAssertEqual(a.okMix(b, 0).hex, a.hex)
        XCTAssertEqual(a.okMix(b, 1).hex, b.hex)
        // OKLab keeps the middle of blue to orange brighter than plain RGB does (no muddy band).
        XCTAssertTrue(a.okMix(b, 0.5).luminance > a.mix(b, 0.5).luminance)
        for p in SkyPhase.allCases {
            let l = Sky.look(phase: p, condition: .clear)
            XCTAssertEqual(l.stops.count, Sky.gradientSamples)
            XCTAssertTrue(zip(l.stops, l.stops.dropFirst()).allSatisfy { $0.location < $1.location })
        }
        let g = Sky.glowStops(peak: 0.6)
        XCTAssertTrue(abs((g.first?.alpha ?? 0) - 0.6) < 1e-9)
        XCTAssertTrue(abs(g.last?.alpha ?? 1) < 1e-9)
        XCTAssertTrue(zip(g, g.dropFirst()).allSatisfy { $0.alpha >= $1.alpha })
        XCTAssertTrue(Sky.glowShape(Sky.look(phase: .night, condition: .clear)).radius < Sky.glowShape(Sky.look(phase: .golden, condition: .clear)).radius)
        // A low sun warms the clouds' bases; a day keeps them white.
        let golden = Sky.look(phase: .golden, condition: .cloudy)
        let base = Sky.cloudColor(golden, shade: 1)
        XCTAssertTrue(base.r > base.b)
        XCTAssertEqual(Sky.cloudColor(Sky.look(phase: .day, condition: .cloudy), shade: 0).hex, 0xFFFFFF)
        // The shooting star: there at the start of its period, gone a second later.
        XCTAssertNotNil(Sky.meteor(t: Sky.meteorPeriod * 3 + 0.4, width: 1200, skyHeight: 500))
        XCTAssertNil(Sky.meteor(t: Sky.meteorPeriod * 3 + 2, width: 1200, skyHeight: 500))
    }

    func testWeatherText() {
        let r = SkyReport(city: "Milan", tempC: 21.4, code: 0, isDay: true, condition: .clear, sunrise: nil, sunset: nil, tz: nil)
        XCTAssertEqual(Sky.weatherText(r, fahrenheit: false), "21\u{00b0} Milan")
        XCTAssertEqual(Sky.weatherText(r, fahrenheit: true), "71\u{00b0} Milan")
        XCTAssertEqual(Sky.temperature(-0.3, fahrenheit: false), "0\u{00b0}")
        XCTAssertNil(Sky.weatherText(SkyReport(condition: .fog), fahrenheit: false))
        XCTAssertEqual(Sky.symbol(.clear, day: false), "moon.stars")
        XCTAssertFalse(Sky.isDay(nil, phase: .night))
        XCTAssertEqual(SkyRGB(0x3B5BFD).hex, 0x3B5BFD)
        XCTAssertEqual(SkyRGB(0x000000).mix(SkyRGB(0xFFFFFF), 2).hex, 0xFFFFFF)
        let a = SkyNoise.unit(5, 1), b = SkyNoise.unit(5, 1)
        XCTAssertEqual(a, b)
        XCTAssertTrue((0..<1).contains(a))
    }

    func testRepoActivity() {
        let json = #"{"ok":true,"repos":[{"full_name":"jdoe/site","html_url":"https://github.com/jdoe/site","commits_7d":3,"commits_30d":"12","weeks":[1,0,true,-2,5],"last_commit":{"message":"Fix the header\n\nlong body","at":1792044000000,"author":"jdoe"},"open_prs":2},{"full_name":"JDOE/site"},{"full_name":"bad"},{"full_name":"acme/app","html_url":"javascript:x","last_commit":null}]}"#
        let list = RepoActivity.parseList(Data(json.utf8)) ?? []
        XCTAssertEqual(list.map(\.fullName), ["jdoe/site", "acme/app"])
        XCTAssertEqual(list[0].commits30d, 12)
        XCTAssertEqual(list[0].weeks, [1, 0, 0, 0, 5])
        XCTAssertEqual(list[0].lastCommit?.message, "Fix the header")
        XCTAssertEqual(list[0].openPRs, 2)
        XCTAssertEqual(list[0].name, "site")
        XCTAssertNil(list[1].htmlURL)
        XCTAssertNil(list[1].lastCommit)
        XCTAssertEqual(list[1].weekLine, "No commits this week")
        XCTAssertEqual(list[0].weekLine, "3 commits this week")
        XCTAssertEqual(list[0].strip(8), [0, 0, 0, 1, 0, 0, 0, 5])
        XCTAssertEqual(RepoActivity.sorted(list.reversed()).first?.fullName, "jdoe/site")
        XCTAssertEqual(RepoActivity.parseList(Data(#"{"ok":true,"repos":[]}"#.utf8)), [])
        XCTAssertNil(RepoActivity.parseList(Data(#"{"ok":false}"#.utf8)))
        let many = #"{"ok":true,"repos":[{"full_name":"a/b","weeks":[\#((0..<40).map(String.init).joined(separator: ","))]}]}"#
        XCTAssertEqual(RepoActivity.parseList(Data(many.utf8))?.first?.weeks.count, RepoActivity.maxWeeks)
    }

    func testLevelsAndHint() {
        XCTAssertEqual(RepoActivity.level(0, max: 10), 0)
        XCTAssertEqual(RepoActivity.level(2, max: 10), 1)
        XCTAssertEqual(RepoActivity.level(5, max: 10), 2)
        XCTAssertEqual(RepoActivity.level(7, max: 10), 3)
        XCTAssertEqual(RepoActivity.level(10, max: 10), 4)
        XCTAssertEqual(RepoActivity.level(3, max: 0), 0)
        XCTAssertEqual(RepoActivity.firstLine(String(repeating: "x", count: 200)).count, 120)
        XCTAssertTrue(RepoActivityHint.showConnect(workspaceRepos: 0, connected: false))
        XCTAssertFalse(RepoActivityHint.showConnect(workspaceRepos: 0, connected: nil))
        XCTAssertFalse(RepoActivityHint.showConnect(workspaceRepos: 1, connected: false))
        XCTAssertFalse(RepoActivityHint.showConnect(workspaceRepos: 0, connected: true))
    }

    // The clouds sit on a fixed track in points; the view's width only crops it.
    func testCloudsDoNotMoveWhenTheWidthChanges() {
        let t = 12_345.6
        let wide = SkyClouds.layout(cover: 0.7, t: t, viewWidth: 1400, skyHeight: 600, night: false)
        let narrow = SkyClouds.layout(cover: 0.7, t: t, viewWidth: 900, skyHeight: 600, night: false)
        XCTAssertFalse(narrow.isEmpty)
        // Every cloud of the narrow view is in the wide one, at the same place and the same size.
        for c in narrow { XCTAssertTrue(wide.contains(c), "cloud \(c.index) moved") }
        // The wide view only adds clouds whose edge reaches past the narrow one.
        for c in wide where !narrow.contains(c) { XCTAssertTrue(c.x + SkyClouds.spill > 900) }
        // How many clouds exist does not depend on the view.
        XCTAssertEqual(SkyClouds.count(cover: 0.7), 9)
    }

    func testCloudsDriftSmoothlyAndWrapSeamlessly() {
        for i in 0..<SkyClouds.count(cover: 1) {
            let a = SkyClouds.trackX(i, t: 500), b = SkyClouds.trackX(i, t: 501)
            let d = b - a
            // One second: a few points to the right, or the wrap, where it jumps back by exactly one track.
            XCTAssertTrue((d > 0 && d < 10) || abs(d + SkyClouds.track) < 10, "cloud \(i) jumped \(d)")
            XCTAssertTrue(a >= -SkyClouds.width(i))
            XCTAssertTrue(a < SkyClouds.track - SkyClouds.width(i))
        }
        // A view wider than the track still has the copies standing where the wrap lands.
        let wide = SkyClouds.layout(cover: 0.7, t: 0, viewWidth: 3000, skyHeight: 600, night: false)
        XCTAssertTrue(wide.filter { $0.x > SkyClouds.track - 300 }.count > 0)
    }

    func testCloudsAreSoftAndVaried() {
        XCTAssertTrue(SkyClouds.layout(cover: 0, t: 0, viewWidth: 1000, skyHeight: 600, night: false).isEmpty)
        var counts = Set<Int>()
        for i in 0..<SkyClouds.count(cover: 1) {
            let p = SkyClouds.puffs(i)
            counts.insert(p.count)
            XCTAssertTrue(p.count >= 7)
            XCTAssertEqual(p, SkyClouds.puffs(i))   // deterministic
            XCTAssertTrue(Set(p.map { ($0.rx * 10).rounded() }).count > 3)   // varied puff sizes
            XCTAssertTrue(p.allSatisfy { $0.shade >= 0 && $0.shade <= 1 && $0.alpha > 0 && $0.alpha <= 1 })
            XCTAssertTrue(SkyClouds.blur(i) >= 6)
            XCTAssertTrue(SkyClouds.blur(i) <= 14)
        }
        XCTAssertTrue(counts.count > 1)
        let day = SkyClouds.alpha(0, cover: 0.7, night: false), night = SkyClouds.alpha(0, cover: 0.7, night: true)
        XCTAssertTrue(night < day)
    }
}
