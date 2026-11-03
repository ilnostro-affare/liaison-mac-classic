import Foundation

// Sign-ins in the browser's data stores, the rules without WebKit ("Google, our admin, Apple,
// Facebook sign me out every day"; "Met worked in a signed-out Facebook after I signed in in my browser").
//
// 1. Shared sign-ins (App/Browser/SharedSignIns.swift) copy a site's cookies between the account's stores. Sites rotate
// their session cookies on their own (Google's __Secure-1PSIDTS every few minutes, each store separately). A copy
// that puts an OLDER rotation over a newer one presents a cookie the site already retired, which Google and
// Facebook treat as a stolen session and sign out. So: a store's own changes are measured against what that store
// had (not against the group's set), a copy never replaces a later-expiring value, and a removal reaches only the
// stores that hold the very same value.
// 2. Session cookies (no expiry) die with WebKit's network process at every quit: an update a day was a sign-out a
// day on sites that keep their sign-in in one. They (and auth-looking cookies) are kept on this Mac and put back
// at launch only where the store has nothing under that name.
// 3. An agent's tab on a site reloads once when the person signs in or out of that site in the same sign-in.

enum SignInCookies {
    /// A cookie as these rules see it.
    struct Fact: Equatable, Codable {
        var name: String
        var domain: String
        var path: String
        var value: String
        var expires: Date?
        /// The cookie's flags (the generic sign-in rule for sites not in `known`); false when unknown.
        var httpOnly = false
        var secure = false
        /// No expiry: WebKit keeps it only in its network process (dropped at every quit).
        var session = false

        /// name|domain|path, the domain without its leading dot: one cookie in a store.
        var id: String { SignInCookies.id(name: name, domain: domain, path: path) }
    }

    static func id(name: String, domain: String, path: String) -> String {
        var d = domain.lowercased()
        while d.hasPrefix(".") { d.removeFirst() }
        return name + "|" + d + "|" + path
    }

    static func index(_ list: [Fact]) -> [String: Fact] {
        var out: [String: Fact] = [:]
        for f in list { out[f.id] = f }
        return out
    }

    // MARK: - copying between stores

    /// `a` expires later than `b` (more than a second): `a` is the newer rotation. Session cookies (nil) are never
    /// "newer" than anything: there is nothing to compare.
    static func fresher(_ a: Date?, than b: Date?) -> Bool {
        guard let a, let b else { return false }
        return a.timeIntervalSince(b) > 1
    }

    /// What one store changed by itself since it was last looked at (`seen`): values that differ or are new, and
    /// cookies it no longer has. A store that suddenly reports none of a large set never counts as signing out.
    static func ownChanges(seen: [String: Fact], now: [String: Fact]) -> (changed: [String: Fact], removed: [String: Fact]) {
        let changed = now.filter { seen[$0.key]?.value != $0.value.value }
        var removed = seen.filter { now[$0.key] == nil }
        if now.isEmpty, seen.count > 5 { removed = [:] }
        return (changed, removed)
    }

    /// Whether `c` goes into a store that holds `target` under the same id: never over the same value, never over a
    /// newer rotation.
    static func shouldWrite(_ c: Fact, over target: Fact?) -> Bool {
        guard let t = target else { return true }
        if t.value == c.value { return false }
        return !fresher(t.expires, than: c.expires)
    }

    /// A cookie one store lost: deleted in another only when that one holds the same value (the same session). A
    /// different value there is another sign-in and stays.
    static func shouldDelete(_ removed: Fact, target: Fact?) -> Bool {
        guard let t = target else { return false }
        return t.value == removed.value
    }

    /// A store joins with `have`; the group knows `want`. The value that goes into the joining store per id (`take`)
    /// and the ones the joining store brings to the group (`give`): the newer rotation wins, the group's value wins a
    /// tie; ids only one side has go to the other.
    static func merge(want: [String: Fact], have: [String: Fact]) -> (take: [Fact], give: [Fact]) {
        var take: [Fact] = []
        var give: [Fact] = []
        for (k, c) in want {
            guard let h = have[k] else { take.append(c); continue }
            if h.value == c.value { continue }
            if fresher(h.expires, than: c.expires) { give.append(h) } else { take.append(c) }
        }
        for (k, h) in have where want[k] == nil { give.append(h) }
        return (take, give)
    }

    // MARK: - whole sites (Facebook still signed out)
    //
    // The per-cookie rules above decide each cookie on its own. Between two stores that hold two DIFFERENT sessions of
    // a site (Facebook signed in separately in the Acme and the Liaison workspace) that mixes them: the later-expiring
    // `datr` of one store next to the later-expiring `xs` / `c_user` of the other, a cookie set Facebook never issued,
    // which it answers with a forced sign-out (and may end both sessions). Session cookies (no expiry) were copied over
    // whatever the other store had. So a site is now synced per session: cookie by cookie only between stores holding
    // the SAME session (rotations, as before), otherwise the site's whole jar at once or nothing.

    /// The site a cookie belongs to (registrable domain).
    static func site(_ f: Fact) -> String { WebPanelRules.registrable(f.domain) }

    /// id -> cookie, split per site.
    static func bySite(_ all: [String: Fact]) -> [String: [String: Fact]] {
        var out: [String: [String: Fact]] = [:]
        for (k, f) in all { out[site(f), default: [:]][k] = f }
        return out
    }

    /// Which session a site's cookies hold: its sign-in cookies (`isAuth`, not expired, not empty) as sorted
    /// "name=value"; nil: not signed in there.
    static func session(_ jar: [String: Fact], now: Date = Date()) -> String? {
        let parts = jar.values.filter { f in
            if let e = f.expires, e <= now { return false }
            return !f.value.isEmpty && isAuth(f)
        }.map { $0.name + "=" + $0.value }.sorted()
        return parts.isEmpty ? nil : parts.joined(separator: ";")
    }

    enum SiteSync: Equatable {
        /// Leave the other store's cookies of the site alone.
        case none
        /// The same session: cookie by cookie (shouldWrite / shouldDelete).
        case merge
        /// The other store's whole jar of the site becomes the source's (deleted what the source lacks).
        case replace
    }

    /// A store changed a site by itself, its session going `before` -> `now`; another store holds `target`.
    static func siteSync(before: String?, now: String?, target: String?) -> SiteSync {
        if let now {
            if target == now { return .merge }
            if target == nil || target == before { return .replace }
            // The other store has a session of its own: only the person's new sign-in here replaces it, a rotation of
            // a session it never had does not.
            return before != now ? .replace : .none
        }
        // Signed out here: reaches only a store on the very session that ended.
        if let before, target == before { return .replace }
        return .none
    }

    enum JoinSync: Equatable { case none, merge, take, give }

    /// A store joins with session `joining` of a site; the group's set holds `group`. Never mixes two sessions, never
    /// signs a store out.
    static func joinSync(group: String?, joining: String?) -> JoinSync {
        if group == joining { return group == nil ? .none : .merge }
        if joining == nil { return .take }
        if group == nil { return .give }
        return .none
    }

    /// The whole jar of a site from `source` into a store that holds `target` of it: what to set, what to delete.
    static func replacePlan(source: [String: Fact], target: [String: Fact]) -> (set: [Fact], delete: [Fact]) {
        let set = source.values.filter { f in
            guard let t = target[f.id] else { return true }
            return t.value != f.value || t.expires != f.expires
        }
        let delete = target.filter { source[$0.key] == nil }.map(\.value)
        return (set.sorted { $0.id < $1.id }, delete.sorted { $0.id < $1.id })
    }

    // MARK: - which cookies are a sign-in

    /// Per site: the cookies whose VALUE is the account (a change is a sign-in, a sign-out or another account) and
    /// the ones whose PRESENCE is the session. Rotating cookies (Google's *SIDTS, SIDCC; Facebook's fr, presence) are
    /// in neither, so their rotation never reloads anything.
    private static let known: [String: (value: Set<String>, presence: Set<String>)] = [
        "google.com": (["SID"], ["__Secure-1PSID", "__Secure-3PSID", "SAPISID", "HSID", "SSID", "APISID", "LSID"]),
        "youtube.com": ([], ["__Secure-1PSID", "__Secure-3PSID", "SID", "LOGIN_INFO"]),
        "facebook.com": (["c_user"], ["xs"]),
        "messenger.com": (["c_user"], ["xs"]),
        "instagram.com": (["ds_user_id"], ["sessionid"]),
        "threads.net": (["ds_user_id"], ["sessionid"]),
        "meta.com": ([], ["xs", "c_user"]),
        "apple.com": ([], ["myacinfo", "dqsid"]),
        "icloud.com": (["X-APPLE-WEBAUTH-USER"], ["X-APPLE-WEBAUTH-TOKEN", "X-APPLE-DS-WEB-SESSION-TOKEN"]),
        "x.com": (["twid"], ["auth_token"]),
        "twitter.com": (["twid"], ["auth_token"]),
        "linkedin.com": ([], ["li_at"]),
        "github.com": (["dotcom_user", "logged_in"], ["user_session"]),
        "tiktok.com": ([], ["sessionid", "sid_tt"]),
        "liaisone.com": ([], ["CF_Authorization"]),
        "cloudflareaccess.com": ([], ["CF_Authorization"]),
    ]

    // Every other site ("for EVERY site, not just the list"): a generic rule by name and flags.
    private static let authWords = ["sess", "auth", "login", "logged", "token", "jwt", "sid", "user"]
    /// Never a sign-in, whatever else the name holds: anti-forgery, consent, preferences, analytics and ad tags, bot
    /// and load-balancer cookies, and the rotating halves of a sign-in (Google's *SIDTS / SIDCC style).
    private static let notAuth = [
        "csrf", "xsrf", "consent", "cookieyes", "optanon", "cookielaw", "locale", "lang", "theme", "timezone",
        "_ga", "_gid", "_gat", "_gcl", "__utm", "_fbp", "_fbc", "_hj", "_clck", "_clsk", "amplitude",
        "optimizely", "intercom-", "__stripe", "_uet", "_ttp", "_scid", "_pin_", "_rdt",
        "analytics", "tracking", "visitor", "sidts", "sidcc", "__cf_bm", "cf_clearance", "_cfuvid", "awsalb", "ak_bmsc",
        "datadome", "_dd_s",
    ]
    /// Name starts that are never a sign-in (analytics SDKs, bot managers).
    private static let notAuthPrefix = ["mp_", "ajs_", "_pk_", "amp_", "bm_s", "incap_", "visid_", "nlbi_", "_tt_", "muid"]
    /// Exact names that are never a sign-in (too short to match safely by part).
    private static let notAuthExact: Set<String> = ["fr", "nid", "tz", "presence", "wd", "dpr", "aec"]
    /// Exact names whose VALUE is the account on any site (another value: another account).
    private static let accountNames: Set<String> = [
        "uid", "user", "userid", "user_id", "username", "logged_in", "loggedin", "account_id", "accountid", "member_id",
        "memberid", "customer_id", "dotcom_user", "c_user", "ds_user_id", "twid",
    ]

    private static func excluded(_ name: String) -> Bool {
        let n = name.lowercased()
        return notAuthExact.contains(n) || notAuth.contains(where: { n.contains($0) }) || notAuthPrefix.contains(where: { n.hasPrefix($0) })
    }

    /// Whether a cookie on any other site looks like its sign-in (by name).
    static func looksLikeAuth(_ name: String) -> Bool {
        if excluded(name) { return false }
        let n = name.lowercased()
        return accountNames.contains(n) || authWords.contains { n.contains($0) }
    }

    /// The generic rule by flags: an HttpOnly + Secure cookie that lives only for the session with a long opaque value,
    /// or an HttpOnly `__Host-` / `__Secure-` one, is how most sites keep a sign-in whatever they call it.
    static func looksLikeSession(_ f: Fact) -> Bool {
        if excluded(f.name) { return false }
        let n = f.name.lowercased()
        if f.httpOnly, n.hasPrefix("__host-") || n.hasPrefix("__secure-") { return true }
        return f.httpOnly && f.secure && f.session && f.value.count >= 16
    }

    /// Whether a cookie is part of a sign-in on its site (kept over a quit; part of the sign-in signature).
    static func isAuth(_ f: Fact) -> Bool {
        let site = WebPanelRules.registrable(f.domain)
        if let k = known[site] { return k.value.contains(f.name) || k.presence.contains(f.name) }
        return looksLikeAuth(f.name) || looksLikeSession(f)
    }

    /// Registrable domain -> what its sign-in is now: sorted "name=value" for account cookies, "name" for session
    /// cookies. Sites with no sign-in cookie are absent.
    static func signatures(_ cookies: [Fact], now: Date = Date()) -> [String: String] {
        var parts: [String: Set<String>] = [:]
        for f in cookies {
            if let e = f.expires, e <= now { continue }
            let site = WebPanelRules.registrable(f.domain)
            let entry: String?
            if let k = known[site] {
                entry = k.value.contains(f.name) ? f.name + "=" + f.value : (k.presence.contains(f.name) ? f.name : nil)
            } else if accountNames.contains(f.name.lowercased()), !excluded(f.name) {
                entry = f.name + "=" + f.value
            } else {
                entry = looksLikeAuth(f.name) || looksLikeSession(f) ? f.name : nil
            }
            if let entry, !f.value.isEmpty { parts[site, default: []].insert(entry) }
        }
        return parts.mapValues { $0.sorted().joined(separator: ";") }
    }

    /// The sites whose sign-in differs between two signature sets.
    static func changedSites(old: [String: String], new: [String: String]) -> Set<String> {
        Set(old.keys).union(new.keys).filter { old[$0] != new[$0] }
    }

    // MARK: - kept over a quit

    /// The cookies worth keeping over a quit: every session cookie (WebKit drops them with its process) and the
    /// sign-in ones (in case the last write had not reached the disk). Expired ones never.
    static func keep(_ cookies: [Fact], sessionOnly: (Fact) -> Bool, now: Date = Date()) -> [Fact] {
        cookies.filter { f in
            if let e = f.expires, e <= now { return false }
            return sessionOnly(f) || isAuth(f)
        }
    }

    /// The vault's caps: a value longer than a cookie may be (4096 bytes) is not kept; per site at most `perSite`
    /// cookies, sign-in ones first; at most `total` in all. Ordered by id within each rank, so the same input keeps
    /// the same set.
    static func capped(_ list: [Fact], perSite: Int = 80, total: Int = 3000, maxBytes: Int = 4096) -> [Fact] {
        let fit = list.filter { $0.name.utf8.count + $0.value.utf8.count <= maxBytes && !$0.name.isEmpty }
        let ranked = fit.sorted { a, b in
            let ra = isAuth(a), rb = isAuth(b)
            return ra != rb ? ra : a.id < b.id
        }
        var perCount: [String: Int] = [:]
        var out: [Fact] = []
        for f in ranked where out.count < total {
            let site = WebPanelRules.registrable(f.domain)
            let n = perCount[site, default: 0]
            guard n < perSite else { continue }
            perCount[site] = n + 1
            out.append(f)
        }
        return out
    }

    /// The vault's restore against the store's cookies: per site, nothing of the kept set goes back when
    /// the store holds a sign-in the kept one did not (another value under a sign-in name, or a sign-in cookie the kept
    /// set never had: the site signed in again since); and a kept sign-in cookie never goes in next to one of the same
    /// name under another domain or path variant (".facebook.com" vs "www.facebook.com": two `xs`, one of them stale).
    static func restore(_ kept: [Fact], savedAt: Date, store: [Fact], now: Date = Date(), maxAge: TimeInterval = 14 * 86_400) -> [Fact] {
        func live(_ f: Fact) -> Bool { (f.expires.map { $0 > now } ?? true) && !f.value.isEmpty }
        var storeAuth: [String: Set<String>] = [:]   // site -> "name=value"
        var storeNames: [String: Set<String>] = [:]
        for f in store where live(f) && isAuth(f) {
            storeAuth[site(f), default: []].insert(f.name + "=" + f.value)
            storeNames[site(f), default: []].insert(f.name)
        }
        var keptAuth: [String: Set<String>] = [:]
        for f in kept where live(f) && isAuth(f) { keptAuth[site(f), default: []].insert(f.name + "=" + f.value) }
        let consistent = { (s: String) -> Bool in (storeAuth[s] ?? []).isSubset(of: keptAuth[s] ?? []) }
        let ok = kept.filter { f in
            let s = site(f)
            if !consistent(s) { return false }
            if isAuth(f), storeNames[s]?.contains(f.name) == true { return false }
            return true
        }
        return restore(ok, savedAt: savedAt, have: Set(store.map(\.id)), now: now, maxAge: maxAge)
    }

    /// What goes back into a store at launch: kept cookies the store has nothing under (by id), not expired, saved
    /// within `maxAge`. A store that has the cookie (a newer value, or one the site set since) always wins.
    static func restore(_ kept: [Fact], savedAt: Date, have: Set<String>, now: Date = Date(), maxAge: TimeInterval = 14 * 86_400) -> [Fact] {
        guard now.timeIntervalSince(savedAt) <= maxAge else { return [] }
        return kept.filter { f in
            if let e = f.expires, e <= now { return false }
            return !have.contains(f.id)
        }
    }
}

/// An agent's tab and a sign-in change of the person's (rule 3 above).
enum AgentTabReload {
    /// Sites whose sign-in is another site's cookies.
    static let signsInWith: [String: String] = ["messenger.com": "facebook.com", "youtube.com": "google.com"]

    /// Whether the page's site is one of `changed` (registrable domains), directly or through `signsInWith`.
    static func concerns(host: String?, changed: Set<String>) -> Bool {
        guard let h = host?.lowercased(), !h.isEmpty else { return false }
        let site = WebPanelRules.registrable(h)
        return changed.contains(site) || signsInWith[site].map(changed.contains) == true
    }

    /// Reload the tab once: its site's sign-in changed at `changedAt`; the tab is not loading and its agent is not at
    /// work (never in the middle of a navigation the agent started); its page started loading well before the change
    /// (a page that loaded around it caused it or has the new sign-in already: `own` seconds); and it was not reloaded
    /// for this in the last `gap` seconds.
    static func shouldReload(host: String?, changed: Set<String>, changedAt: Date, isLoading: Bool, agentBusy: Bool,
                             navigationStartedAt: Date?, lastReload: Date?, now: Date,
                             own: TimeInterval = 5, gap: TimeInterval = 20) -> Bool {
        decide(host: host, changed: changed, changedAt: changedAt, isLoading: isLoading, agentBusy: agentBusy,
               navigationStartedAt: navigationStartedAt, lastReload: lastReload, now: now, own: own, gap: gap) == .reload
    }

    enum Decision: Equatable {
        /// Reload now.
        case reload
        /// Not now (the tab is loading, its agent is at work): asked again a little later.
        case later
        /// Never for this change.
        case never
    }

    /// `shouldReload` with the reason: a tab skipped only because it was loading or its agent was at work
    /// is asked again, so a page that was mid-load when the person signed in does not stay signed out.
    static func decide(host: String?, changed: Set<String>, changedAt: Date, isLoading: Bool, agentBusy: Bool,
                       navigationStartedAt: Date?, lastReload: Date?, now: Date,
                       own: TimeInterval = 5, gap: TimeInterval = 20) -> Decision {
        guard concerns(host: host, changed: changed) else { return .never }
        if let n = navigationStartedAt, n >= changedAt.addingTimeInterval(-own) { return .never }
        if let r = lastReload, now.timeIntervalSince(r) < gap { return .never }
        if isLoading || agentBusy { return .later }
        return .reload
    }
}

/// Which data store a browser pane is on (Met's pane signed out of Ads Manager): every agent pane of a
/// workspace is on the workspace browser's own store. Named for the "stores" log only, never an id.
enum PaneStore: String, Equatable {
    /// The workspace browser's own store (the main browser, every agent pane of the workspace).
    case workspace
    /// A store of an agent's own (none exists today: the line says so if one ever appears).
    case agent
    /// A side-panel service's shared store ("~panel:").
    case panel
    /// Not a workspace store (no key, a bare Liaison account, another workspace).
    case other

    /// `pane`: the key the pane's store was made for; `workspace`: the workspace browser's key.
    static func of(pane: String?, workspace: String?) -> PaneStore {
        guard let pane, !pane.isEmpty else { return .other }
        if let workspace, pane == workspace { return .workspace }
        if pane.contains("|p:~panel:") { return .panel }
        if pane.contains("|agent") || pane.contains("|a:") { return .agent }
        return .other
    }
}

/// The keyboard and a web page (App/Workspace/WebViewHost.swift WebFocusKeeper).
enum WebFocusRules {
    /// A key pressed while the page the person clicked last is on screen and nothing that types has the keys (the
    /// window itself, a SwiftUI host, a view that ignores keys: the Mac beeps): the key goes to the page instead.
    static func keyGoesToPage(pageOnScreen: Bool, responderIsPage: Bool, responderTakesText: Bool, shortcut: Bool,
                              agentBusy: Bool, modalOpen: Bool) -> Bool {
        pageOnScreen && !responderIsPage && !responderTakesText && !shortcut && !agentBusy && !modalOpen
    }

    /// The page the person clicked lost the keys: it takes them back unless the person did something of ours just now
    /// (a click outside the page, a shortcut, a menu), the page is gone from screen, its agent is at work, a popup is
    /// open, another page took the keys, or it was taken back too often already (`recent` reverts in the last 2 s).
    static func takeBack(pageOnScreen: Bool, personActedAgo: TimeInterval, agentBusy: Bool, modalOpen: Bool,
                         otherPageHasKeys: Bool, recent: Int, quiet: TimeInterval = 0.35, budget: Int = 3) -> Bool {
        pageOnScreen && personActedAgo > quiet && !agentBusy && !modalOpen && !otherPageHasKeys && recent < budget
    }
}
