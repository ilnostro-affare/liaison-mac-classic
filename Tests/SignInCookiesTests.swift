import XCTest
import Foundation
@testable import Liaison

/// Sign-ins across the browser's stores, agent tab reloads, the keyboard and a page (Shared/Core/SignInCookies.swift).
final class SignInCookiesTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    private func f(_ name: String, _ value: String, domain: String = ".google.com", expires: TimeInterval? = 86_400) -> SignInCookies.Fact {
        SignInCookies.Fact(name: name, domain: domain, path: "/", value: value, expires: expires.map { t0.addingTimeInterval($0) })
    }

    func testIdIgnoresLeadingDot() {
        XCTAssertEqual(f("SID", "a").id, f("SID", "b", domain: "google.com").id)
    }

    func testNeverWritesAnOlderRotationOverANewerOne() {
        let older = f("__Secure-1PSIDTS", "v1", expires: 100)
        let newer = f("__Secure-1PSIDTS", "v2", expires: 600)
        XCTAssertFalse(SignInCookies.shouldWrite(older, over: newer))
        XCTAssertTrue(SignInCookies.shouldWrite(newer, over: older))
        XCTAssertFalse(SignInCookies.shouldWrite(newer, over: newer))
        XCTAssertTrue(SignInCookies.shouldWrite(older, over: nil))
        // Session cookies: nothing to compare, the copy goes.
        XCTAssertTrue(SignInCookies.shouldWrite(f("s", "1", expires: nil), over: f("s", "0", expires: nil)))
    }

    func testOwnChangesAreMeasuredAgainstWhatTheStoreHad() {
        let seen = SignInCookies.index([f("SID", "a"), f("HSID", "h"), f("NID", "n")])
        let now = SignInCookies.index([f("SID", "a"), f("HSID", "h2"), f("OTZ", "o")])
        let d = SignInCookies.ownChanges(seen: seen, now: now)
        XCTAssertEqual(Set(d.changed.values.map(\.name)), ["HSID", "OTZ"])
        XCTAssertEqual(Set(d.removed.values.map(\.name)), ["NID"])
        // A store that suddenly has none of a large set signs nobody out.
        let many = SignInCookies.index((0..<8).map { f("c\($0)", "v") })
        XCTAssertTrue(SignInCookies.ownChanges(seen: many, now: [:]).removed.isEmpty)
    }

    func testRemovalOnlyWhereTheSameValueIs() {
        let gone = f("SID", "a")
        XCTAssertTrue(SignInCookies.shouldDelete(gone, target: f("SID", "a")))
        XCTAssertFalse(SignInCookies.shouldDelete(gone, target: f("SID", "b")))
        XCTAssertFalse(SignInCookies.shouldDelete(gone, target: nil))
    }

    func testJoiningStoreKeepsItsNewerRotation() {
        let want = SignInCookies.index([f("SID", "a"), f("__Secure-1PSIDTS", "old", expires: 100), f("HSID", "g")])
        let have = SignInCookies.index([f("SID", "a"), f("__Secure-1PSIDTS", "new", expires: 900), f("HSID", "x"), f("OTZ", "o")])
        let m = SignInCookies.merge(want: want, have: have)
        XCTAssertEqual(Set(m.take.map { $0.name + "=" + $0.value }), ["HSID=g"])
        XCTAssertEqual(Set(m.give.map { $0.name + "=" + $0.value }), ["__Secure-1PSIDTS=new", "OTZ=o"])
    }

    func testSignaturesIgnoreRotation() {
        let a = SignInCookies.signatures([f("SID", "s1"), f("__Secure-1PSID", "p"), f("__Secure-1PSIDTS", "r1"), f("SIDCC", "c1")], now: t0)
        let b = SignInCookies.signatures([f("SID", "s1"), f("__Secure-1PSID", "p2"), f("__Secure-1PSIDTS", "r2"), f("SIDCC", "c2")], now: t0)
        XCTAssertTrue(SignInCookies.changedSites(old: a, new: b).isEmpty)
        // Signed out: SID gone.
        let out = SignInCookies.signatures([f("__Secure-1PSIDTS", "r2")], now: t0)
        XCTAssertEqual(SignInCookies.changedSites(old: a, new: out), ["google.com"])
        // Facebook: another account (c_user) is a change, fr is not.
        let fb1 = SignInCookies.signatures([f("c_user", "1", domain: ".facebook.com"), f("xs", "x", domain: ".facebook.com"), f("fr", "a", domain: ".facebook.com")], now: t0)
        let fb2 = SignInCookies.signatures([f("c_user", "1", domain: ".facebook.com"), f("xs", "y", domain: ".facebook.com"), f("fr", "b", domain: ".facebook.com")], now: t0)
        let fb3 = SignInCookies.signatures([f("c_user", "2", domain: ".facebook.com"), f("xs", "y", domain: ".facebook.com")], now: t0)
        XCTAssertTrue(SignInCookies.changedSites(old: fb1, new: fb2).isEmpty)
        XCTAssertEqual(SignInCookies.changedSites(old: fb2, new: fb3), ["facebook.com"])
        // Signed in on a facebook page that had no sign-in.
        XCTAssertEqual(SignInCookies.changedSites(old: [:], new: fb1), ["facebook.com"])
        // Expired cookies are not a sign-in.
        XCTAssertTrue(SignInCookies.signatures([f("SID", "s", expires: -10)], now: t0).isEmpty)
    }

    func testOtherSitesByName() {
        XCTAssertTrue(SignInCookies.looksLikeAuth("PHPSESSID"))
        XCTAssertTrue(SignInCookies.looksLikeAuth("auth_token"))
        XCTAssertFalse(SignInCookies.looksLikeAuth("csrftoken"))
        XCTAssertFalse(SignInCookies.looksLikeAuth("_ga"))
        XCTAssertTrue(SignInCookies.isAuth(f("CF_Authorization", "j", domain: "panel.liaisone.com")))
        XCTAssertFalse(SignInCookies.isAuth(f("NID", "n")))
    }

    /// The rules hold for every site, not only the known ones.
    func testGenericSignInOnAnySite() {
        func g(_ name: String, _ value: String = "v", httpOnly: Bool = false, secure: Bool = false, session: Bool = false) -> SignInCookies.Fact {
            SignInCookies.Fact(name: name, domain: "admin.example.com", path: "/", value: value, expires: session ? nil : t0.addingTimeInterval(86_400),
                               httpOnly: httpOnly, secure: secure, session: session)
        }
        let opaque = String(repeating: "a1", count: 16)
        // By name.
        for n in ["PHPSESSID", "connect.sid", "laravel_session", "remember_user_token", "access_token", "jwt", "wordpress_logged_in_x"] {
            XCTAssertTrue(SignInCookies.isAuth(g(n)), n)
        }
        // Analytics, consent, anti-forgery, bot managers, rotating halves: never.
        for n in ["_ga", "_ga_ABC", "_gid", "_fbp", "fr", "_uetsid", "__cf_bm", "cf_clearance", "XSRF-TOKEN", "csrftoken",
                  "mp_123_mixpanel", "ajs_user_id", "__Secure-1PSIDTS", "SIDCC", "OptanonConsent", "_hjSessionUser_1"] {
            XCTAssertFalse(SignInCookies.isAuth(g(n, opaque, httpOnly: true, secure: true, session: true)), n)
        }
        // By flags: an HttpOnly + Secure session cookie with an opaque value, whatever its name.
        XCTAssertTrue(SignInCookies.isAuth(g("app", opaque, httpOnly: true, secure: true, session: true)))
        XCTAssertFalse(SignInCookies.isAuth(g("app", "short", httpOnly: true, secure: true, session: true)))
        XCTAssertFalse(SignInCookies.isAuth(g("app", opaque, httpOnly: false, secure: true, session: true)))
        XCTAssertTrue(SignInCookies.isAuth(g("__Host-app", "x", httpOnly: true)))
        // The watch sees a sign-in on that site appear, and another account by an account-id cookie's value.
        let out = SignInCookies.signatures([g("_ga", "1"), g("theme", "dark")], now: t0)
        let inn = SignInCookies.signatures([g("_ga", "1"), g("app", opaque, httpOnly: true, secure: true, session: true), g("user_id", "7")], now: t0)
        let other = SignInCookies.signatures([g("_ga", "2"), g("app", opaque + "b", httpOnly: true, secure: true, session: true), g("user_id", "8")], now: t0)
        XCTAssertEqual(SignInCookies.changedSites(old: out, new: inn), ["example.com"])
        XCTAssertEqual(SignInCookies.changedSites(old: inn, new: other), ["example.com"])
        // The session cookie's value rotating (same account) is not a change.
        let rotated = SignInCookies.signatures([g("app", opaque + "c", httpOnly: true, secure: true, session: true), g("user_id", "7")], now: t0)
        XCTAssertTrue(SignInCookies.changedSites(old: inn, new: rotated).isEmpty)
        XCTAssertTrue(AgentTabReload.concerns(host: "admin.example.com", changed: ["example.com"]))
    }

    /// Two Facebook sessions (Acme and Liaison workspaces) are never mixed cookie by cookie.
    func testSitesSyncPerSessionNeverMixed() {
        func fb(_ name: String, _ value: String, _ exp: TimeInterval = 86_400 * 300) -> SignInCookies.Fact { f(name, value, domain: ".facebook.com", expires: exp) }
        let a = SignInCookies.index([fb("c_user", "1"), fb("xs", "xa"), fb("datr", "da", 86_400 * 700), fb("fr", "r1")])
        let b = SignInCookies.index([fb("c_user", "1"), fb("xs", "xb", 86_400 * 360), fb("datr", "db", 86_400 * 720)])
        let sa = SignInCookies.session(a), sb = SignInCookies.session(b)
        XCTAssertEqual(sa, "c_user=1;xs=xa")
        XCTAssertFalse(sa == sb)
        XCTAssertNil(SignInCookies.session(SignInCookies.index([fb("datr", "d"), fb("fr", "r")])))
        XCTAssertNil(SignInCookies.session(SignInCookies.index([fb("xs", "x", -10)]), now: t0), "expired is no session")
        // A rotation (fr) in A never reaches B, which holds another session.
        XCTAssertEqual(SignInCookies.siteSync(before: sa, now: sa, target: sb), .none)
        // The same session: cookie by cookie.
        XCTAssertEqual(SignInCookies.siteSync(before: sa, now: sa, target: sa), .merge)
        // A store with no sign-in there, or still on the session A had: A's whole jar.
        XCTAssertEqual(SignInCookies.siteSync(before: sa, now: sa, target: nil), .replace)
        XCTAssertEqual(SignInCookies.siteSync(before: sa, now: "c_user=1;xs=new", target: sa), .replace)
        // The person signs in in A: B's other session is replaced as a whole.
        XCTAssertEqual(SignInCookies.siteSync(before: nil, now: sa, target: sb), .replace)
        // Signed out in A: only the very session that ended.
        XCTAssertEqual(SignInCookies.siteSync(before: sa, now: nil, target: sa), .replace)
        XCTAssertEqual(SignInCookies.siteSync(before: sa, now: nil, target: sb), .none)
        XCTAssertEqual(SignInCookies.siteSync(before: nil, now: nil, target: sb), .none)
        // Joining: never mixes, never signs out.
        XCTAssertEqual(SignInCookies.joinSync(group: sa, joining: sb), .none)
        XCTAssertEqual(SignInCookies.joinSync(group: sa, joining: sa), .merge)
        XCTAssertEqual(SignInCookies.joinSync(group: sa, joining: nil), .take)
        XCTAssertEqual(SignInCookies.joinSync(group: nil, joining: sb), .give)
        XCTAssertEqual(SignInCookies.joinSync(group: nil, joining: nil), .none)
        // The whole jar: the source's datr with its xs, the target's leftovers deleted.
        let r = SignInCookies.replacePlan(source: a, target: b)
        XCTAssertEqual(Set(r.set.map { $0.name + "=" + $0.value }), ["xs=xa", "datr=da", "fr=r1"])
        XCTAssertFalse(r.set.contains { $0.name == "c_user" }, "same value and expiry: not written again")
        XCTAssertTrue(r.delete.isEmpty)
        let r2 = SignInCookies.replacePlan(source: SignInCookies.index([fb("datr", "da")]), target: b)
        XCTAssertEqual(Set(r2.delete.map(\.name)), ["c_user", "xs"])
        XCTAssertEqual(SignInCookies.site(fb("xs", "x")), "facebook.com")
        XCTAssertEqual(Set(SignInCookies.bySite(a.merging(SignInCookies.index([f("SID", "s")])) { x, _ in x }).keys), ["facebook.com", "google.com"])
    }

    /// The vault never puts back a sign-in next to a newer one of the site, nor a variant of a name.
    func testVaultRestoreIsPerSite() {
        let kept = [f("xs", "old", domain: "www.facebook.com", expires: nil), f("c_user", "1", domain: ".facebook.com", expires: nil),
                    f("presence", "p", domain: ".facebook.com", expires: nil),
                    f("CF_Authorization", "jwt-old", domain: "panel.liaisone.com", expires: nil)]
        let later = t0.addingTimeInterval(60)
        // The site signed in again since (another xs under .facebook.com): nothing of the kept Facebook set goes back.
        let newer = [f("xs", "new", domain: ".facebook.com"), f("c_user", "1", domain: ".facebook.com")]
        let back = SignInCookies.restore(kept, savedAt: t0, store: newer, now: later)
        XCTAssertEqual(back.map(\.name), ["CF_Authorization"])
        // Same session kept (c_user persisted, the session-only xs dropped at quit): xs goes back, c_user is there.
        let same = SignInCookies.restore(kept, savedAt: t0, store: [f("c_user", "1", domain: ".facebook.com")], now: later)
        XCTAssertEqual(Set(same.map(\.name)), ["xs", "presence", "CF_Authorization"])
        // A CF_Authorization the store has under another variant (path) is never doubled.
        let cf = SignInCookies.Fact(name: "CF_Authorization", domain: "panel.liaisone.com", path: "/app", value: "jwt-old", expires: nil)
        XCTAssertFalse(SignInCookies.restore(kept, savedAt: t0, store: [cf], now: later).contains { $0.name == "CF_Authorization" })
        // Nothing there: everything goes back.
        XCTAssertEqual(SignInCookies.restore(kept, savedAt: t0, store: [], now: later).count, 4)
    }

    func testVaultCaps() {
        var list: [SignInCookies.Fact] = []
        for i in 0..<120 { list.append(f("c\(i)", "v", domain: "a.example.com", expires: nil)) }
        list.append(f("PHPSESSID", "s", domain: "a.example.com", expires: nil))
        list.append(f("big", String(repeating: "x", count: 5000), domain: "b.example.org", expires: nil))
        list.append(f("sid", "1", domain: "b.example.org", expires: nil))
        let kept = SignInCookies.capped(list, perSite: 80, total: 3000)
        XCTAssertEqual(kept.filter { $0.domain == "a.example.com" }.count, 80)
        XCTAssertTrue(kept.contains { $0.name == "PHPSESSID" })   // the sign-in one is kept first
        XCTAssertFalse(kept.contains { $0.name == "big" })
        XCTAssertTrue(kept.contains { $0.name == "sid" })
        XCTAssertEqual(SignInCookies.capped(list, perSite: 80, total: 10).count, 10)
        XCTAssertEqual(SignInCookies.capped(list).map(\.id), SignInCookies.capped(list.reversed()).map(\.id))
    }

    /// The vault never puts a kept cookie over one the store has, on any site (a newer value, or one set since).
    func testVaultNeverOverwritesAnySite() {
        let kept = [f("PHPSESSID", "old", domain: "shop.example.it", expires: nil), f("anything", "a", domain: ".site.dev", expires: nil),
                    f("SID", "s")]
        let have: Set<String> = [f("PHPSESSID", "new", domain: "shop.example.it").id, f("SID", "x").id]
        let back = SignInCookies.restore(kept, savedAt: t0, have: have, now: t0.addingTimeInterval(60))
        XCTAssertEqual(back.map(\.name), ["anything"])
    }

    func testKeptOverAQuit() {
        let session = f("myacinfo", "m", domain: ".apple.com", expires: nil)
        let plain = f("NID", "n")
        let auth = f("SID", "s")
        let expired = f("LSID", "l", expires: -5)
        let kept = SignInCookies.keep([session, plain, auth, expired], sessionOnly: { $0.expires == nil }, now: t0)
        XCTAssertEqual(Set(kept.map(\.name)), ["myacinfo", "SID"])
        // Back only where the store has nothing under the id, only from a recent save.
        let back = SignInCookies.restore(kept, savedAt: t0, have: [auth.id], now: t0.addingTimeInterval(3600))
        XCTAssertEqual(back.map(\.name), ["myacinfo"])
        XCTAssertTrue(SignInCookies.restore(kept, savedAt: t0, have: [], now: t0.addingTimeInterval(30 * 86_400)).isEmpty)
    }

    func testAgentTabReload() {
        let change = t0
        let after = t0.addingTimeInterval(3)
        func go(_ host: String?, loading: Bool = false, busy: Bool = false, nav: Date? = nil, last: Date? = nil) -> Bool {
            AgentTabReload.shouldReload(host: host, changed: ["facebook.com"], changedAt: change, isLoading: loading, agentBusy: busy,
                                        navigationStartedAt: nav, lastReload: last, now: after)
        }
        XCTAssertTrue(go("adsmanager.facebook.com", nav: t0.addingTimeInterval(-600)))
        XCTAssertTrue(go("www.messenger.com"))
        XCTAssertFalse(go("www.google.com"))
        XCTAssertFalse(go(nil))
        XCTAssertFalse(go("www.facebook.com", loading: true))
        XCTAssertFalse(go("www.facebook.com", busy: true))
        // Its own page load around the change (it caused it, or has the new sign-in already).
        XCTAssertFalse(go("www.facebook.com", nav: t0.addingTimeInterval(-2)))
        XCTAssertFalse(go("www.facebook.com", nav: t0.addingTimeInterval(1)))
        // Once per 20 s.
        XCTAssertFalse(go("www.facebook.com", last: t0.addingTimeInterval(-5)))
        XCTAssertTrue(go("www.facebook.com", last: t0.addingTimeInterval(-60)))
    }

    func testAgentTabReloadLater() {
        let change = t0, after = t0.addingTimeInterval(3), old = t0.addingTimeInterval(-600)
        func d(loading: Bool = false, busy: Bool = false, nav: Date? = old, own: TimeInterval = 5) -> AgentTabReload.Decision {
            AgentTabReload.decide(host: "adsmanager.facebook.com", changed: ["facebook.com"], changedAt: change, isLoading: loading,
                                  agentBusy: busy, navigationStartedAt: nav, lastReload: nil, now: after, own: own)
        }
        XCTAssertEqual(d(), .reload)
        // Mid-load or the agent at work: asked again, not dropped.
        XCTAssertEqual(d(loading: true), .later)
        XCTAssertEqual(d(busy: true), .later)
        // A page that started after the change has it.
        XCTAssertEqual(d(nav: t0.addingTimeInterval(1)), .never)
        // Launch: our own restore landed 1 s after the page started; with own 0 the page is stale and reloads.
        XCTAssertEqual(d(nav: t0.addingTimeInterval(-1)), .never)
        XCTAssertEqual(d(nav: t0.addingTimeInterval(-1), own: 0), .reload)
    }

    func testPaneStore() {
        let ws = "m1|p:prof"
        XCTAssertEqual(PaneStore.of(pane: ws, workspace: ws), .workspace)
        XCTAssertEqual(PaneStore.of(pane: "m1|p:~panel:facebook.com", workspace: ws), .panel)
        XCTAssertEqual(PaneStore.of(pane: "m1|p:prof|agent-met", workspace: ws), .agent)
        XCTAssertEqual(PaneStore.of(pane: "_none|p:prof", workspace: ws), .other)
        XCTAssertEqual(PaneStore.of(pane: "m1", workspace: ws), .other)
        XCTAssertEqual(PaneStore.of(pane: nil, workspace: ws), .other)
    }

    func testKeysGoToThePage() {
        XCTAssertTrue(WebFocusRules.keyGoesToPage(pageOnScreen: true, responderIsPage: false, responderTakesText: false, shortcut: false,
                                                  agentBusy: false, modalOpen: false))
        XCTAssertFalse(WebFocusRules.keyGoesToPage(pageOnScreen: true, responderIsPage: false, responderTakesText: true, shortcut: false,
                                                   agentBusy: false, modalOpen: false))
        XCTAssertFalse(WebFocusRules.keyGoesToPage(pageOnScreen: true, responderIsPage: false, responderTakesText: false, shortcut: true,
                                                   agentBusy: false, modalOpen: false))
        XCTAssertFalse(WebFocusRules.keyGoesToPage(pageOnScreen: false, responderIsPage: false, responderTakesText: false, shortcut: false,
                                                   agentBusy: false, modalOpen: false))
        XCTAssertFalse(WebFocusRules.keyGoesToPage(pageOnScreen: true, responderIsPage: false, responderTakesText: false, shortcut: false,
                                                   agentBusy: true, modalOpen: false))
    }

    func testPageTakesTheKeysBack() {
        XCTAssertTrue(WebFocusRules.takeBack(pageOnScreen: true, personActedAgo: 5, agentBusy: false, modalOpen: false, otherPageHasKeys: false, recent: 0))
        // The person chose something of ours just now.
        XCTAssertFalse(WebFocusRules.takeBack(pageOnScreen: true, personActedAgo: 0.1, agentBusy: false, modalOpen: false, otherPageHasKeys: false, recent: 0))
        XCTAssertFalse(WebFocusRules.takeBack(pageOnScreen: true, personActedAgo: 5, agentBusy: false, modalOpen: true, otherPageHasKeys: false, recent: 0))
        XCTAssertFalse(WebFocusRules.takeBack(pageOnScreen: true, personActedAgo: 5, agentBusy: false, modalOpen: false, otherPageHasKeys: true, recent: 0))
        // Never a fight: at most 3 in 2 s.
        XCTAssertFalse(WebFocusRules.takeBack(pageOnScreen: true, personActedAgo: 5, agentBusy: false, modalOpen: false, otherPageHasKeys: false, recent: 3))
    }
}
