import XCTest
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
@testable import Liaison

/// The load-failure event (Shared/Core/LoadFailLog.swift).
final class LoadFailLogTests: XCTestCase {
    private let url = LoadFailure.urlDomain

    func testCardAndKeptCountRetriesAndIgnoresDoNot() {
        XCTAssertEqual(LoadFailLog.outcome(.show, domain: url, code: -1003, current: true, committed: false, showing: false), .card)
        XCTAssertNil(LoadFailLog.outcome(.retry(after: 1), domain: url, code: -1003, current: true, committed: false, showing: false))
        // the page at that address stays on screen after the tries: kept, reported
        let d = LoadFailure.decide(domain: url, code: -1003, attempt: 2, current: true, committed: false, showing: true)
        XCTAssertEqual(d, .ignore)
        XCTAssertEqual(LoadFailLog.outcome(d, domain: url, code: -1003, current: true, committed: false, showing: true), .kept)
        // cancelled, superseded, committed, not showing: nothing
        XCTAssertNil(LoadFailLog.outcome(.ignore, domain: url, code: -999, current: true, committed: false, showing: true))
        XCTAssertNil(LoadFailLog.outcome(.ignore, domain: url, code: -1003, current: false, committed: false, showing: true))
        XCTAssertNil(LoadFailLog.outcome(.ignore, domain: url, code: -1003, current: true, committed: true, showing: true))
        XCTAssertNil(LoadFailLog.outcome(.ignore, domain: url, code: -1003, current: true, committed: false, showing: false))
        XCTAssertNil(LoadFailLog.outcome(.ignore, domain: LoadFailure.webKitDomain, code: 102, current: true, committed: false, showing: true))
    }

    func testHostOnlyNeverPathOrQuery() {
        XCTAssertEqual(LoadFailLog.host(URL(string: "https://Admin.Example.com/leads/42?token=secret#x")), "admin.example.com")
        XCTAssertNil(LoadFailLog.host(URL(string: "about:blank")))
        XCTAssertNil(LoadFailLog.host(nil))
        let f = LoadFailLog.fields(host: "example.com", code: -1003, committed: false, showing: true, retries: 2, ms: 3120,
                                   client: LoadFailLog.client(version: "0.2.11"))
        XCTAssertEqual(Set(f.keys), ["host", "code", "phase", "showing", "retries", "ms", "client"])
        XCTAssertEqual(f["client"] as? String, "mac 0.2.11")
        XCTAssertEqual(LoadFailLog.client(version: nil), "mac ?")
        XCTAssertEqual(f["host"] as? String, "example.com")
        XCTAssertEqual(f["phase"] as? String, "provisional")
        XCTAssertEqual(f["showing"] as? Bool, true)
        XCTAssertEqual(f["retries"] as? Int, 2)
        let c = LoadFailLog.fields(host: "a", code: 0, committed: true, showing: false, retries: 0, ms: -5, client: "mac 1")
        XCTAssertEqual(c["ms"] as? Int, 0)
        XCTAssertEqual(c["phase"] as? String, "commit")
    }

    func testOnePerHostPerMinute() {
        var t = LoadFailLog.Throttle()
        let t0 = Date(timeIntervalSince1970: 1_000_000)
        XCTAssertTrue(t.allow("a.com", now: t0))
        XCTAssertFalse(t.allow("a.com", now: t0.addingTimeInterval(30)))
        XCTAssertTrue(t.allow("b.com", now: t0.addingTimeInterval(30)))
        XCTAssertFalse(t.allow("a.com", now: t0.addingTimeInterval(59.9)))
        XCTAssertTrue(t.allow("a.com", now: t0.addingTimeInterval(60)))
        // a clock set back never locks a host out
        XCTAssertTrue(t.allow("b.com", now: t0.addingTimeInterval(-500)))
        // a 429 stops every host for good
        t.stop()
        XCTAssertFalse(t.allow("c.com", now: t0.addingTimeInterval(1000)))
    }

    func testThrottleStaysBounded() {
        var t = LoadFailLog.Throttle()
        let t0 = Date(timeIntervalSince1970: 1_000_000)
        for i in 0..<(LoadFailLog.maxHosts * 2) { XCTAssertTrue(t.allow("h\(i).com", now: t0)) }
        XCTAssertTrue(t.last.count <= LoadFailLog.maxHosts)
    }

    /// The cookie_change event: names only, the site, who did it.
    func testCookieChangeEvent() {
        typealias F = SignInCookies.Fact
        let t0 = Date(timeIntervalSince1970: 1_800_000_000)
        func c(_ n: String, _ v: String, _ d: String = ".facebook.com", exp: TimeInterval? = 86_400) -> F {
            F(name: n, domain: d, path: "/", value: v, expires: exp.map { t0.addingTimeInterval($0) })
        }
        XCTAssertEqual(CookieChangeLog.store(ofKey: "acct|p:prof1"), .workspace)
        XCTAssertEqual(CookieChangeLog.store(ofKey: "acct|p:~panel:messenger.com"), .panelShared)
        XCTAssertEqual(CookieChangeLog.store(ofKey: "acct"), .account)
        let before = SignInCookies.index([c("xs", "SECRETVALUE1"), c("c_user", "1"), c("fr", "r"),
                                          c("CF_Authorization", "jwt", "panel.liaisone.com"), c("sid", "s", "a.example.com", exp: -5)])
        let after = SignInCookies.index([c("c_user", "2"), c("fr", "r2"), c("CF_Authorization", "jwt", "panel.liaisone.com"),
                                         c("SID", "g", ".google.com")])
        let ev = CookieChangeLog.diff(before: before, after: after, store: .workspace, now: t0) { id, _ in
            id.hasPrefix("c_user|") ? .sync : nil
        }
        XCTAssertEqual(ev, [
            CookieChangeLog.Event(host: "example.com", store: .workspace, names: ["sid"], change: .removed, by: .unknown),
            CookieChangeLog.Event(host: "facebook.com", store: .workspace, names: ["xs"], change: .removed, by: .site),
            CookieChangeLog.Event(host: "facebook.com", store: .workspace, names: ["c_user"], change: .replaced, by: .sync),
            CookieChangeLog.Event(host: "google.com", store: .workspace, names: ["SID"], change: .added, by: .site),
        ])
        // fr is no sign-in; CF_Authorization unchanged.
        let fields = CookieChangeLog.fields(ev[1], client: "mac 0.3")
        XCTAssertEqual(Set(fields.keys), ["host", "store", "names", "change", "by", "client"])
        XCTAssertEqual(fields["names"] as? [String], ["xs"])
        XCTAssertFalse(CookieChangeLog.line(ev[1]).contains("SECRETVALUE1"))
        XCTAssertFalse("\(fields)".contains("SECRETVALUE1"))
        XCTAssertEqual(CookieChangeLog.cleanName("__Secure-1PSID"), "__Secure-1PSID")
        XCTAssertNil(CookieChangeLog.cleanName("bad name"))
        XCTAssertNil(CookieChangeLog.cleanName(String(repeating: "a", count: 65)))
        XCTAssertEqual(CookieChangeLog.store(ofKey: "x").rawValue, "account")
        XCTAssertEqual(CookieChangeLog.Store.panelShared.rawValue, "panel-shared")
        // One per site per 30 s.
        var th = LoadFailLog.Throttle(interval: CookieChangeLog.interval)
        XCTAssertTrue(th.allow("facebook.com", now: t0))
        XCTAssertFalse(th.allow("facebook.com", now: t0.addingTimeInterval(29)))
        XCTAssertTrue(th.allow("facebook.com", now: t0.addingTimeInterval(30)))
    }
}
