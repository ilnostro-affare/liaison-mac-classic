import Foundation
import WebKit
import CryptoKit
import os

/// Shared sign-ins. Every workspace keeps its own `WKWebsiteDataStore`; the cookies of the sites on
/// this list are kept the SAME in all of them: signed in to Google once, signed in in every workspace.
///
/// How: every persistent browser store (BrowserModel.dataStore) registers here; a private window's non-persistent
/// store never does. Stores are grouped by Liaison account (another Liaison account still starts clean). Per group
/// one in-memory "canonical" set of shared cookies is kept (never written to disk). A change in a store is debounced
/// (0.5 s), compared with the canonical set (name+domain+path+value) and only the difference is written into the
/// other stores. A store that joins later takes the canonical set (and adds what only it has), then is watched.
/// The canonical set starts from the store that changed shared cookies most recently (remembered across launches).
@MainActor
final class SharedSignIns: NSObject, WKHTTPCookieStoreObserver {
    static let shared = SharedSignIns()

    static let defaults = ["google.com", "facebook.com", "instagram.com", "meta.com"]
    private static let enabledKey = "lia_shared_signins"
    private static let extraKey = "lia_shared_signins_extra"
    private static let lastKey = "lia_shared_signins_last"

    // MARK: - the list

    /// The registrable domains whose cookies are shared (a domain covers its subdomains).
    static var domains: [String] {
        let d = UserDefaults.standard
        return d.object(forKey: enabledKey) == nil ? defaults : (d.stringArray(forKey: enabledKey) ?? [])
    }

    /// Sites the person added by hand (shown in Settings even when switched off).
    static var extras: [String] { UserDefaults.standard.stringArray(forKey: extraKey) ?? [] }

    static func isOn(_ domain: String) -> Bool { domains.contains(domain) }

    static func set(_ domain: String, on: Bool) {
        var list = domains
        if on { if !list.contains(domain) { list.append(domain) } } else { list.removeAll { $0 == domain } }
        UserDefaults.standard.set(list, forKey: enabledKey)
        shared.domainsChanged()
    }

    /// "Add site…": the registrable domain of what was typed, switched on. nil: not a web address.
    @discardableResult
    static func add(_ raw: String) -> String? {
        guard let d = normalize(raw) else { return nil }
        var x = extras
        if !x.contains(d), !defaults.contains(d) { x.append(d); UserDefaults.standard.set(x, forKey: extraKey) }
        set(d, on: true)
        return d
    }

    /// "https://accounts.google.com/x" or "mail.google.com" -> "google.com".
    static func normalize(_ raw: String) -> String? {
        let t = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !t.isEmpty else { return nil }
        let host: String
        if t.contains("://") {
            guard let h = URL(string: t)?.host else { return nil }
            host = h
        } else {
            host = String(t.split(separator: "/").first ?? "")
        }
        let h = host.split(separator: ":").first.map(String.init) ?? host
        guard h.contains("."), !h.contains(" ") else { return nil }
        return registrable(h)
    }

    /// Second-level public suffixes common enough to matter; anything else is "last two labels".
    private static let twoLevel: Set<String> = [
        "co.uk", "org.uk", "ac.uk", "gov.uk", "com.au", "net.au", "org.au", "co.jp", "ne.jp", "or.jp", "com.br",
        "com.mx", "co.nz", "co.in", "co.za", "com.tr", "com.cn", "com.hk", "com.sg", "co.kr", "com.ar", "com.ua", "co.il",
    ]

    static func registrable(_ host: String) -> String {
        var h = host.lowercased()
        while h.hasPrefix(".") { h.removeFirst() }
        let parts = h.split(separator: ".")
        guard parts.count > 2 else { return h }
        let last2 = parts.suffix(2).joined(separator: ".")
        return twoLevel.contains(last2) ? parts.suffix(3).joined(separator: ".") : last2
    }

    /// A cookie's domain (".google.com", "accounts.google.com") is on the list.
    static func matches(_ cookieDomain: String, _ list: [String]) -> Bool {
        var d = cookieDomain.lowercased()
        while d.hasPrefix(".") { d.removeFirst() }
        return list.contains { d == $0 || d.hasSuffix("." + $0) }
    }

    // MARK: - sync

    private final class Member {
        let key: String
        let group: String
        let cookies: WKHTTPCookieStore
        var ready = false
        /// The shared cookies this store had when last looked at (after our own writes into it): what it changes by
        /// itself is measured against this, never against the group's set (SignInCookies rule 1).
        var seen: [String: HTTPCookie] = [:]
        init(key: String, group: String, cookies: WKHTTPCookieStore) { self.key = key; self.group = group; self.cookies = cookies }
    }

    private var members: [String: Member] = [:]
    /// Group -> cookie id (name|domain|path) -> cookie.
    private var canonical: [String: [String: HTTPCookie]] = [:]
    private var booted: Set<String> = []
    private var busy: Set<String> = []
    private var debounce: [String: Task<Void, Never>] = [:]

    /// The Liaison account part of a browser key ("acct|p:profile" -> "acct"): sign-ins never cross accounts.
    static func group(of key: String) -> String {
        guard let r = key.range(of: "|p:") else { return key }
        return String(key[..<r.lowerBound])
    }

    private static func id(_ c: HTTPCookie) -> String { SignInCookies.id(name: c.name, domain: c.domain, path: c.path) }

    static func fact(_ c: HTTPCookie) -> SignInCookies.Fact {
        SignInCookies.Fact(name: c.name, domain: c.domain, path: c.path, value: c.value, expires: c.isSessionOnly ? nil : c.expiresDate,
                           httpOnly: c.isHTTPOnly, secure: c.isSecure, session: c.isSessionOnly)
    }

    private static func indexed(_ list: [HTTPCookie]) -> [String: HTTPCookie] {
        var out: [String: HTTPCookie] = [:]
        for c in list { out[id(c)] = c }
        return out
    }

    /// id -> cookie, split per site (SignInCookies.site).
    private static func bySite(_ all: [String: HTTPCookie]) -> [String: [String: HTTPCookie]] {
        var out: [String: [String: HTTPCookie]] = [:]
        for (k, c) in all { out[SignInCookies.site(fact(c)), default: [:]][k] = c }
        return out
    }

    private static func session(_ jar: [String: HTTPCookie]) -> String? { SignInCookies.session(jar.mapValues(fact)) }

    /// The store has joined its group (its kept session cookies restored, the shared sign-ins copied in).
    /// The Google account list waits for this, or a store made just to read it had no Google cookie yet.
    func isReady(_ key: String) -> Bool { members[key]?.ready ?? false }

    /// Called once per persistent store as BrowserModel makes it.
    func register(_ store: WKWebsiteDataStore, key: String) {
        guard store.isPersistent, members[key] == nil else { return }
        let cs = store.httpCookieStore
        let m = Member(key: key, group: Self.group(of: key), cookies: cs)
        members[key] = m
        cs.add(self)
        // In order: the watch's first read, then the session cookies kept over the last quit (only where
        // the store has nothing of that site's sign-in), then the shared sign-ins. Before, the three ran at once and
        // the vault's cookies arriving after the join were taken for the site's own change and copied everywhere.
        Task { @MainActor [weak self] in
            await AuthCookieWatch.shared.watch(key: key, cookies: cs)
            await SessionCookieVault.shared.restore(key: key, into: cs)
            await self?.join(m)
            // An agent tab (Met's Ads Manager, restored at launch) loaded before the two writes above landed;
            // it is reloaded once if its site's sign-in arrived meanwhile (AuthCookieWatch.booted).
            await AuthCookieWatch.shared.booted(key: key, cookies: cs)
        }
    }

    nonisolated func cookiesDidChange(in cookieStore: WKHTTPCookieStore) {
        let oid = ObjectIdentifier(cookieStore)
        Task { @MainActor in SharedSignIns.shared.changed(oid) }
    }

    private func changed(_ oid: ObjectIdentifier) {
        guard let m = members.values.first(where: { ObjectIdentifier($0.cookies) == oid }) else { return }
        SessionCookieVault.shared.changed(key: m.key, cookies: m.cookies)
        AuthCookieWatch.shared.changed(key: m.key, cookies: m.cookies)
        NotificationCenter.default.post(name: GoogleSignedIn.cookiesChanged, object: m.key)
        // Our own writes notify too; they leave nothing to copy (`seen` is updated as we write), so no time window
        // swallows the site's own changes any more (the 60 s "quiet" one lost rotations made meanwhile).
        guard m.ready else { return }
        let key = m.key
        debounce[key]?.cancel()
        debounce[key] = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 500_000_000)
            guard !Task.isCancelled, let self, let m = self.members[key] else { return }
            await self.process(m)
        }
    }

    /// One writer per group at a time.
    private func lock(_ g: String) async {
        while busy.contains(g) { try? await Task.sleep(nanoseconds: 50_000_000) }
        busy.insert(g)
    }
    private func unlock(_ g: String) { busy.remove(g) }

    private func join(_ m: Member) async {
        let g = m.group
        if !booted.contains(g) {
            // The most recently used store of the group joins first and becomes the starting point.
            let last = (UserDefaults.standard.dictionary(forKey: Self.lastKey) as? [String: String])?[g]
            // Only a store that exists already (a deleted workspace's key never makes a new empty store).
            let known = (UserDefaults.standard.dictionary(forKey: "lia_browser_store_ids") as? [String: String])?[last ?? ""] != nil
            if let last, known, last != m.key, members[last] == nil, Self.group(of: last) == g {
                _ = BrowserModel.dataStore(for: last)   // registers it (its own join waits for the lock)
            }
            // The starting store's kept session cookies go back first, or the group starts without them (5 s at most).
            if let last, members[last] != nil {
                var waited = 0
                while !SessionCookieVault.shared.isRestored(last), waited < 100 { try? await Task.sleep(nanoseconds: 50_000_000); waited += 1 }
            }
            await lock(g)
            if !booted.contains(g) {
                let source = last.flatMap { members[$0] } ?? m
                let set = Self.indexed(await sharedCookies(source.cookies))
                canonical[g] = set
                source.seen = set
                source.ready = true
                booted.insert(g)
            }
            unlock(g)
        }
        guard !m.ready else { return }
        await lock(g)
        await seed(m)
        unlock(g)
    }

    /// A store joins, per site (SignInCookies.joinSync): the same session as the group's merges cookie by
    /// cookie (the newer rotation wins, the group's value on a tie); a store with no sign-in of the site takes the
    /// group's whole jar of it; a sign-in only it has goes to the group and to the stores without one. Two different
    /// sessions are never mixed (each store keeps its own), and nothing is deleted from a signed-in site on joining:
    /// a store that was closed can never sign everyone out; sign-outs travel only as live changes.
    private func seed(_ m: Member) async {
        let g = m.group
        var want = canonical[g] ?? [:]
        let have = Self.indexed(await sharedCookies(m.cookies))
        let wantSites = Self.bySite(want), haveSites = Self.bySite(have)
        var giveMerge: [String: [HTTPCookie]] = [:]   // site -> cookies of the group's session, newer here
        var giveWhole: [String: [String: HTTPCookie]] = [:]   // site -> this store's jar (a sign-in only it has)
        for site in Set(wantSites.keys).union(haveSites.keys).sorted() {
            let w = wantSites[site] ?? [:], h = haveSites[site] ?? [:]
            switch SignInCookies.joinSync(group: Self.session(w), joining: Self.session(h)) {
            case .none:
                continue
            case .merge:
                let plan = SignInCookies.merge(want: w.mapValues(Self.fact), have: h.mapValues(Self.fact))
                for f in plan.take { if let c = w[f.id] { await setCookie(c, in: m, by: .sync) } }
                let give = plan.give.compactMap { h[$0.id] }
                for c in give { want[Self.id(c)] = c }
                if !give.isEmpty { giveMerge[site] = give }
            case .take:
                await replace(w, into: m, have: h)
            case .give:
                for k in w.keys { want[k] = nil }
                for (k, c) in h { want[k] = c }
                giveWhole[site] = h
            }
        }
        m.seen = Self.indexed(await sharedCookies(m.cookies))
        canonical[g] = want
        if !giveMerge.isEmpty || !giveWhole.isEmpty {
            for t in members.values where t.group == g && t.key != m.key && t.ready {
                let theirs = Self.bySite(Self.indexed(await sharedCookies(t.cookies)))
                for (site, give) in giveMerge {
                    let tj = theirs[site] ?? [:]
                    if Self.session(tj) == Self.session(want.filter { SignInCookies.site(Self.fact($0.value)) == site }) {
                        await write(give, removed: [], into: t, have: tj)
                    }
                }
                for (site, jar) in giveWhole {
                    let tj = theirs[site] ?? [:]
                    switch SignInCookies.joinSync(group: Self.session(jar), joining: Self.session(tj)) {
                    case .take: await replace(jar, into: t, have: tj)
                    case .merge: await write(Array(jar.values), removed: [], into: t, have: tj)
                    default: break
                    }
                }
            }
        }
        m.ready = true
    }

    /// A store changed by itself: per site (SignInCookies.siteSync), what it changed goes cookie by cookie into the
    /// stores on the same session, and its whole jar of the site into a store with no sign-in there, a store still on
    /// the session it had, or (only when the person signed in here) a store with another session. Never a mix.
    private func process(_ m: Member) async {
        let g = m.group
        await lock(g)
        defer { unlock(g) }
        guard m.ready else { return }
        let now = Self.indexed(await sharedCookies(m.cookies))
        let before = m.seen
        m.seen = now
        let nowSites = Self.bySite(now), beforeSites = Self.bySite(before)
        var set = canonical[g] ?? [:]
        let targets = members.values.filter { $0.group == g && $0.key != m.key && $0.ready }
        var theirs: [String: [String: [String: HTTPCookie]]] = [:]   // target key -> site -> jar (read once)
        var touched = false
        for site in Set(nowSites.keys).union(beforeSites.keys).sorted() {
            let b = beforeSites[site] ?? [:], n = nowSites[site] ?? [:]
            // A store that suddenly reports none of a large set never counts as signing out.
            if n.isEmpty, b.count > 5 { continue }
            let diff = SignInCookies.ownChanges(seen: b.mapValues(Self.fact), now: n.mapValues(Self.fact))
            guard !diff.changed.isEmpty || !diff.removed.isEmpty else { continue }
            touched = true
            let sb = Self.session(b), sn = Self.session(n)
            let groupSite = set.filter { SignInCookies.site(Self.fact($0.value)) == site }
            let sg = Self.session(groupSite)
            var changed: [HTTPCookie] = []
            var jar = n
            if sn != nil, sn == sg {
                // The group's session: per cookie, an older rotation than the group's newest goes back to the newer.
                for k in diff.changed.keys.sorted() {
                    guard let c = n[k] else { continue }
                    if let newer = set[k], SignInCookies.fresher(newer.expiresDate, than: c.expiresDate) {
                        await setCookie(newer, in: m, by: .sync)
                        m.seen[k] = newer
                        jar[k] = newer
                    } else {
                        changed.append(c)
                        set[k] = c
                    }
                }
                for (k, f) in diff.removed where set[k]?.value == f.value { set[k] = nil }
            } else {
                changed = diff.changed.keys.sorted().compactMap { n[$0] }
                // Another sign-in here, or the group's session ended here: the group's jar of the site is this one.
                if sn != nil || sg == sb {
                    for k in groupSite.keys { set[k] = nil }
                    for (k, c) in n { set[k] = c }
                }
            }
            for t in targets {
                if theirs[t.key] == nil { theirs[t.key] = Self.bySite(Self.indexed(await sharedCookies(t.cookies))) }
                let tj = theirs[t.key]?[site] ?? [:]
                switch SignInCookies.siteSync(before: sb, now: sn, target: Self.session(tj)) {
                case .none: continue
                case .merge: await write(changed, removed: Array(diff.removed.values), into: t, have: tj)
                case .replace: await replace(jar, into: t, have: tj)
                }
            }
        }
        canonical[g] = set
        guard touched else { return }
        var last = UserDefaults.standard.dictionary(forKey: Self.lastKey) as? [String: String] ?? [:]
        last[g] = m.key
        UserDefaults.standard.set(last, forKey: Self.lastKey)
    }

    /// Our copy into one store (`have`: its jar of the site): a cookie only where it is not the same value and not over
    /// a newer rotation; a removal only where the store holds that very value. `seen` follows, so the notifications
    /// this causes copy nothing back.
    private func write(_ changed: [HTTPCookie], removed: [SignInCookies.Fact], into t: Member, have: [String: HTTPCookie]) async {
        for c in changed {
            let k = Self.id(c)
            guard SignInCookies.shouldWrite(Self.fact(c), over: have[k].map(Self.fact)) else { continue }
            await setCookie(c, in: t, by: .sync)
            t.seen[k] = c
        }
        for f in removed {
            guard let c = have[f.id], SignInCookies.shouldDelete(f, target: Self.fact(c)) else { continue }
            await deleteCookie(c, in: t, by: .sync)
            t.seen[f.id] = nil
        }
    }

    /// The whole jar of a site into one store (`have`: its jar of that site): set first, then what the source lacks
    /// deleted, so the site never sees a half of each session.
    private func replace(_ source: [String: HTTPCookie], into t: Member, have: [String: HTTPCookie]) async {
        let plan = SignInCookies.replacePlan(source: source.mapValues(Self.fact), target: have.mapValues(Self.fact))
        for f in plan.set { if let c = source[f.id] { await setCookie(c, in: t, by: .sync); t.seen[f.id] = c } }
        for f in plan.delete { if let c = have[f.id] { await deleteCookie(c, in: t, by: .sync); t.seen[f.id] = nil } }
    }

    /// The list changed: every group starts again from its most recent store (a site switched on takes that
    /// store's sign-in everywhere; a site switched off simply stops being synced, nothing is deleted).
    private func domainsChanged() {
        let all = Array(members.values)
        booted.removeAll()
        canonical.removeAll()
        for m in all { m.ready = false; m.seen = [:] }
        for m in all { Task { @MainActor [weak self] in await self?.join(m) } }
    }

    // MARK: - WKHTTPCookieStore (main thread)

    private func sharedCookies(_ cs: WKHTTPCookieStore) async -> [HTTPCookie] {
        let list = Self.domains
        guard !list.isEmpty else { return [] }
        let all: [HTTPCookie] = await withCheckedContinuation { c in cs.getAllCookies { c.resume(returning: $0) } }
        return all.filter { Self.matches($0.domain, list) }
    }

    private func setCookie(_ cookie: HTTPCookie, in m: Member, by: CookieChangeLog.By) async {
        CookieWrites.note(m.key, Self.id(cookie), by)
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in m.cookies.setCookie(cookie) { c.resume() } }
    }

    private func deleteCookie(_ cookie: HTTPCookie, in m: Member, by: CookieChangeLog.By) async {
        CookieWrites.note(m.key, Self.id(cookie), by)
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in m.cookies.delete(cookie) { c.resume() } }
    }
}

/// Our own writes into a browser store, by store key and cookie id, for a short while: the cookie_change log says who
/// changed a sign-in cookie. Anything not noted here was the site.
@MainActor
enum CookieWrites {
    private static var notes: [String: (by: CookieChangeLog.By, at: Date)] = [:]
    static let window: TimeInterval = 30

    static func note(_ key: String, _ id: String, _ by: CookieChangeLog.By) {
        let now = Date()
        if notes.count > 4000 { notes = notes.filter { now.timeIntervalSince($0.value.at) < window } }
        notes[key + "\u{1}" + id] = (by, now)
    }

    static func who(_ key: String, _ id: String, now: Date = Date()) -> CookieChangeLog.By? {
        guard let n = notes[key + "\u{1}" + id], now.timeIntervalSince(n.at) < window else { return nil }
        return n.by
    }
}

/// Session cookies kept over a quit. WebKit keeps a cookie without an expiry date
/// only in its network process: every quit (an update a day) dropped them, and with them the sign-in of every site
/// that keeps it in one. Per persistent browser store the session cookies and the sign-in ones (SignInCookies.keep)
/// are written, encrypted (AES-GCM, the key in the keychain; never plain on disk), a second after they change; at
/// launch the ones the store has nothing under go back (SignInCookies.restore: the store always wins). A private
/// window's store never registers, so nothing of it is kept.
@MainActor
final class SessionCookieVault {
    static let shared = SessionCookieVault()

    private struct Kept: Codable {
        var name: String, domain: String, path: String, value: String
        var expires: Date?
        var secure: Bool, httpOnly: Bool
        var sameSite: String?

        var fact: SignInCookies.Fact {
            SignInCookies.Fact(name: name, domain: domain, path: path, value: value, expires: expires,
                               httpOnly: httpOnly, secure: secure, session: expires == nil)
        }

        init(_ c: HTTPCookie) {
            name = c.name; domain = c.domain; path = c.path; value = c.value
            expires = c.isSessionOnly ? nil : c.expiresDate
            secure = c.isSecure; httpOnly = c.isHTTPOnly
            sameSite = c.sameSitePolicy?.rawValue
        }

        var cookie: HTTPCookie? {
            var p: [HTTPCookiePropertyKey: Any] = [.name: name, .domain: domain, .path: path, .value: value]
            if secure { p[.secure] = "TRUE" }
            if httpOnly { p[HTTPCookiePropertyKey("HttpOnly")] = "TRUE" }
            if let e = expires { p[.expires] = e } else { p[.discard] = "TRUE" }
            if let s = sameSite { p[.sameSitePolicy] = s }
            return HTTPCookie(properties: p)
        }
    }

    private struct File: Codable { var at: Date; var cookies: [Kept] }

    private static let keyAccount = "lia_cookie_vault_key"
    private var jobs: [String: Task<Void, Never>] = [:]
    private var restored: Set<String> = []

    private static var folder: URL? {
        guard let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else { return nil }
        let dir = base.appendingPathComponent(Bundle.main.bundleIdentifier ?? "com.liaisone.mac", isDirectory: true)
            .appendingPathComponent("CookieVault", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        return dir
    }

    private static func file(_ key: String) -> URL? {
        let name = SHA256.hash(data: Data(key.utf8)).map { String(format: "%02x", $0) }.joined()
        return folder?.appendingPathComponent(name + ".vault")
    }

    /// The vault's key; made on first use. nil: the keychain refused it (nothing is then written).
    private static var cachedKey: SymmetricKey?
    private static func key(create: Bool) -> SymmetricKey? {
        if let k = cachedKey { return k }
        if let s = Keychain.get(keyAccount), let d = Data(base64Encoded: s), d.count == 32 {
            cachedKey = SymmetricKey(data: d)
            return cachedKey
        }
        guard create else { return nil }
        let k = SymmetricKey(size: .bits256)
        let d = k.withUnsafeBytes { Data($0) }
        guard Keychain.set(d.base64EncodedString(), for: keyAccount) else { return nil }
        cachedKey = k
        return k
    }

    /// The store's cookies changed: written a second later (the last of a burst).
    func changed(key: String, cookies: WKHTTPCookieStore) {
        guard restored.contains(key) else { return }   // never overwrite the kept set before it went back in
        jobs[key]?.cancel()
        jobs[key] = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            guard !Task.isCancelled else { return }
            await self?.save(key: key, cookies: cookies)
        }
    }

    private func save(key: String, cookies: WKHTTPCookieStore) async {
        let all: [HTTPCookie] = await withCheckedContinuation { c in cookies.getAllCookies { c.resume(returning: $0) } }
        let byId = Dictionary(all.map { (SharedSignIns.fact($0).id, $0) }, uniquingKeysWith: { a, _ in a })
        // Every site of this (persistent) store, capped per site and in all (SignInCookies.capped).
        let keep = SignInCookies.capped(SignInCookies.keep(all.map(SharedSignIns.fact), sessionOnly: { byId[$0.id]?.isSessionOnly == true }))
        guard let url = Self.file(key) else { return }
        if keep.isEmpty { try? FileManager.default.removeItem(at: url); return }
        guard let k = Self.key(create: true) else { return }
        let rows = keep.compactMap { byId[$0.id].map(Kept.init) }
        guard let plain = try? JSONEncoder().encode(File(at: Date(), cookies: rows)),
              let sealed = try? AES.GCM.seal(plain, using: k).combined else { return }
        try? sealed.write(to: url, options: [.atomic])
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    /// The store's kept cookies are back in (or there were none): the shared sign-ins may start from it.
    func isRestored(_ key: String) -> Bool { restored.contains(key) }

    /// Once per store and launch, as the store is made: the kept cookies it has nothing under go back in. Per site
    /// (SignInCookies.restore(store:)): nothing of a site that signed in again since the save, and a kept
    /// sign-in cookie never next to one of the same name under another domain or path variant.
    func restore(key: String, into cookies: WKHTTPCookieStore) async {
        guard !restored.contains(key) else { return }
        defer { restored.insert(key) }
        guard let url = Self.file(key), let sealed = try? Data(contentsOf: url), let k = Self.key(create: false),
              let box = try? AES.GCM.SealedBox(combined: sealed), let plain = try? AES.GCM.open(box, using: k),
              let saved = try? JSONDecoder().decode(File.self, from: plain) else { return }
        // The store always wins, for every site. It is read again before each small batch, so a cookie a page set
        // while the earlier ones went in (a sign-in at launch) is not replaced by the older kept copy.
        let rows = saved.cookies
        var at = 0
        while at < rows.count {
            let batch = Array(rows[at..<min(at + 20, rows.count)])
            at += batch.count
            let all: [HTTPCookie] = await withCheckedContinuation { c in cookies.getAllCookies { c.resume(returning: $0) } }
            let back = Set(SignInCookies.restore(batch.map(\.fact), savedAt: saved.at, store: all.map(SharedSignIns.fact)).map(\.id))
            for row in batch where back.contains(row.fact.id) {
                guard let c = row.cookie else { continue }
                CookieWrites.note(key, row.fact.id, .vault)
                await withCheckedContinuation { (k: CheckedContinuation<Void, Never>) in cookies.setCookie(c) { k.resume() } }
            }
        }
    }
}

/// The person signs in or out of a site: an agent's tab on that site, in the same sign-in,
/// reloads once, so Met does not keep working in a signed-out Facebook. The agents' browsers of a workspace are on the
/// workspace browser's own data store (WorkspaceModel.agentBrowser), so they have the person's cookies at once; only
/// their pages, loaded before, did not know. Per store, a change (debounced 2.5 s, the last of a sign-in's redirects)
/// compares each site's sign-in cookies (SignInCookies.signatures: no rotating cookie counts) with before; an agent tab
/// on a site that changed reloads when AgentTabReload allows (not loading, its agent not at work, not loaded around
/// the change, once per 20 s).
@MainActor
final class AuthCookieWatch {
    static let shared = AuthCookieWatch()
    private var signatures: [String: [String: String]] = [:]
    private var jobs: [String: Task<Void, Never>] = [:]
    private var firstChange: [String: Date] = [:]
    private var lastReload: [UUID: Date] = [:]

    /// Per store, its sign-in cookies (SignInCookies.isAuth) at the last read: the cookie_change log's "before".
    private var auth: [String: [String: SignInCookies.Fact]] = [:]
    /// Per store, the sign-in signatures of its first read (before the vault and the shared sign-ins wrote into it).
    private var firstRead: [String: [String: String]] = [:]
    private var retries: [UUID: Int] = [:]

    private static func read(_ cs: WKHTTPCookieStore) async -> [SignInCookies.Fact] {
        let all: [HTTPCookie] = await withCheckedContinuation { c in cs.getAllCookies { c.resume(returning: $0) } }
        return all.map(SharedSignIns.fact)
    }

    private static func authOnly(_ all: [SignInCookies.Fact]) -> [String: SignInCookies.Fact] {
        SignInCookies.index(all.filter(SignInCookies.isAuth))
    }

    /// The first read of a store, before anything of ours writes into it.
    func watch(key: String, cookies: WKHTTPCookieStore) async {
        let all = await Self.read(cookies)
        if signatures[key] == nil { signatures[key] = SignInCookies.signatures(all) }
        if auth[key] == nil { auth[key] = Self.authOnly(all) }
        if firstRead[key] == nil { firstRead[key] = SignInCookies.signatures(all) }
    }

    /// The store's launch writes are done (the vault's session cookies, the shared sign-ins). A sign-in they brought
    /// arrived after the agent tabs had started loading (BrowserModel loads the selected tab as the store is made), so
    /// the "loaded around the change" rule (`own` 5 s) would keep those pages signed out: here every agent tab on a
    /// site whose sign-in differs from the first read, whose page started before now, reloads once.
    func booted(key: String, cookies: WKHTTPCookieStore) async {
        guard let before = firstRead.removeValue(forKey: key) else { return }
        let at = Date()
        let sites = SignInCookies.changedSites(old: before, new: SignInCookies.signatures(await Self.read(cookies)))
        if !sites.isEmpty { reloadAgentTabs(store: key, sites: sites, changedAt: at, own: 0) }
    }

    func changed(key: String, cookies: WKHTTPCookieStore) {
        if firstChange[key] == nil { firstChange[key] = Date() }
        jobs[key]?.cancel()
        jobs[key] = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 2_500_000_000)
            guard !Task.isCancelled, let self else { return }
            let at = self.firstChange.removeValue(forKey: key) ?? Date()
            let all = await Self.read(cookies)
            let nowAuth = Self.authOnly(all)
            if let was = self.auth[key] { CookieChangeReport.report(key: key, before: was, after: nowAuth) }
            self.auth[key] = nowAuth
            let now = SignInCookies.signatures(all)
            let before = self.signatures[key]
            self.signatures[key] = now
            guard let before else { return }
            let sites = SignInCookies.changedSites(old: before, new: now)
            if !sites.isEmpty { self.reloadAgentTabs(store: key, sites: sites, changedAt: at) }
        }
    }

    private func reloadAgentTabs(store key: String, sites: Set<String>, changedAt: Date, own: TimeInterval = 5) {
        let now = Date()
        var later = false
        var seen: [UUID] = []
        for b in BrowserModel.liveModels where b.account == key && (b.chatID?.hasPrefix("agent-") ?? false) {
            let busy = b.agent.active || b.web.running
            for t in b.tabs where t.loadedWebView != nil && !t.asleep && !t.isStart {
                seen.append(t.id)
                switch AgentTabReload.decide(host: t.url?.host, changed: sites, changedAt: changedAt, isLoading: t.isLoading,
                                             agentBusy: busy, navigationStartedAt: t.navigationStartedAt,
                                             lastReload: lastReload[t.id], now: now, own: own) {
                case .reload:
                    lastReload[t.id] = now
                    retries[t.id] = nil
                    t.reload()
                case .later:
                    // Loading or its agent at work: asked again in 3 s, 10 times at most (then the page is the agent's).
                    let n = (retries[t.id] ?? 0) + 1
                    retries[t.id] = n
                    if n <= 10 { later = true }
                case .never:
                    break
                }
            }
        }
        lastReload = lastReload.filter { now.timeIntervalSince($0.value) < 120 }
        if later {
            Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                self?.reloadAgentTabs(store: key, sites: sites, changedAt: changedAt, own: own)
            }
        } else {
            for id in seen { retries[id] = nil }
        }
    }
}

/// The side of CookieChangeLog that touches the world. Every sign-in cookie a store lost or changed is an
/// os_log line (subsystem com.liaisone.mac, category cookies), and at most one `cookie_change` event per site per 30 s
/// goes to lia-agents (LiaAPI.logEvent). Names only, never a value; the site, never the address.
@MainActor
enum CookieChangeReport {
    private static let log = Logger(subsystem: "com.liaisone.mac", category: "cookies")
    private static var throttle = LoadFailLog.Throttle(interval: CookieChangeLog.interval)
    private static let client = LoadFailLog.client(version: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String)

    static func report(key: String, before: [String: SignInCookies.Fact], after: [String: SignInCookies.Fact]) {
        guard before != after else { return }
        let events = CookieChangeLog.diff(before: before, after: after, store: CookieChangeLog.store(ofKey: key)) { id, _ in
            CookieWrites.who(key, id)
        }
        var sent: Set<String> = []
        // A removal says most about a sign-out, then a replaced value: the one sent when a site has several.
        let rank: [CookieChangeLog.Change: Int] = [.removed: 0, .replaced: 1, .added: 2]
        for e in events.sorted(by: { (rank[$0.change] ?? 3) < (rank[$1.change] ?? 3) }) {
            log.notice("\(CookieChangeLog.line(e), privacy: .public)")
            // One event per site per 30 s: the first change of a burst (a sign-out is usually several cookies at once).
            guard !sent.contains(e.host), throttle.allow(e.host), let auth = WorkspaceModel.current?.auth else { continue }
            sent.insert(e.host)
            let fields = CookieChangeLog.fields(e, client: client)
            let api = LiaAPI(auth: auth)
            Task {
                if await api.logEvent(kind: CookieChangeLog.kind, fields: fields) == 429 { CookieChangeReport.throttle.stop() }
            }
        }
    }
}

/// The accounts a workspace is fixed to (Workspace settings): a Google account and a Meta Business. Kept on this Mac
/// only. The person's tabs and the agents' browsers of the workspace open Google services and Ads Manager on them.
@MainActor
enum WorkspaceAccounts {
    static func googleKey(_ profile: String) -> String { "lia_ws_google_" + profile }
    /// The business that owns the workspace's ad account (derived, never typed: 17). A new key: the old
    /// free-text "lia_ws_bm_" values are no longer read, so a mistyped ID stops pinning Ads Manager.
    static func businessKey(_ profile: String) -> String { "lia_ws_bm2_" + profile }

    static func google(_ profile: String) -> String? { value(googleKey(profile)) }
    static func business(_ profile: String) -> String? { value(businessKey(profile)) }
    static func setGoogle(_ v: String?, _ profile: String) { store(v, googleKey(profile)) }
    static func setBusiness(_ v: String?, _ profile: String) { store(v, businessKey(profile)) }

    private static func value(_ k: String) -> String? {
        let s = (UserDefaults.standard.string(forKey: k) ?? "").trimmingCharacters(in: .whitespaces)
        return s.isEmpty ? nil : s
    }
    private static func store(_ v: String?, _ k: String) {
        let s = (v ?? "").trimmingCharacters(in: .whitespaces)
        if s.isEmpty { UserDefaults.standard.removeObject(forKey: k) } else { UserDefaults.standard.set(s, forKey: k) }
    }

    /// "acct|p:profile" -> "profile"; nil for a browser that is not a workspace's.
    static func profile(ofBrowserKey key: String?) -> String? {
        guard let key, let r = key.range(of: "|p:") else { return nil }
        let p = String(key[r.upperBound...])
        return p.isEmpty ? nil : p
    }

    static let googleHosts: Set<String> = [
        "ads.google.com", "analytics.google.com", "mail.google.com", "drive.google.com", "docs.google.com",
        "calendar.google.com", "myaccount.google.com",
    ]
    static let metaHosts: Set<String> = ["adsmanager.facebook.com", "business.facebook.com"]

    /// The same address on the workspace's account; nil: leave the navigation alone.
    /// `force`: the first time this browser opens the host this launch, the fixed account wins even over an account
    /// index in the path (/mail/u/0/); later, an index there is the person's own switch and is respected.
    static func pinned(_ url: URL, profile: String, force: Bool) -> URL? {
        guard let host = url.host?.lowercased(), var comps = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        let name: String
        let value: String
        if googleHosts.contains(host) {
            guard let email = google(profile) else { return nil }
            if !force, hasAccountIndex(url.path) { return nil }
            name = "authuser"; value = email
        } else if metaHosts.contains(host) {
            guard let bm = business(profile) else { return nil }
            name = "business_id"; value = bm
        } else {
            return nil
        }
        var items = comps.queryItems ?? []
        if let old = items.first(where: { $0.name == name }) {
            // Already there: the person's (or the service's) choice, except on the first visit of the launch, when
            // a different account restored from the last session gives way to the fixed one. Never a loop: the
            // replacement carries exactly `value`.
            guard force, old.value != value else { return nil }
            items.removeAll { $0.name == name }
        }
        items.append(URLQueryItem(name: name, value: value))
        comps.queryItems = items
        return comps.url
    }

    /// "/mail/u/1/", "/drive/u/0/home": a Google account index in the path.
    private static func hasAccountIndex(_ path: String) -> Bool {
        let parts = path.split(separator: "/")
        for (i, p) in parts.enumerated() where p == "u" && i + 1 < parts.count {
            if Int(parts[i + 1]) != nil { return true }
        }
        return false
    }
}

/// The Google accounts signed in in a workspace's browser (Workspace settings, 17). Read from
/// `accounts.google.com/ListAccounts` with the store's own Google cookies, by URLSession outside any page: nothing is
/// injected anywhere, no web view loads it, and Google's answer sets no cookie back (ephemeral session, cookies off).
/// The last good list per Liaison account is kept on this Mac, so the dropdown still has the accounts seen before
/// when Google can't be reached.
@MainActor
enum GoogleSignedIn {
    private static let cacheKey = "lia_google_signed_in"

    /// `fingerprint`: the sign-in cookies the list was read with (GoogleAccounts.sessionFingerprint).
    struct Result { let accounts: [GoogleAccount]; let fresh: Bool; var fingerprint = "" }

    /// A cookie of a browser store changed (object: its browser key).: Workspace settings read the
    /// list again when the person signs in or out meanwhile.
    static let cookiesChanged = Notification.Name("lia.signins.cookiesChanged")

    /// nil: nothing known (no answer now, none before).
    static func list(browserKey key: String) async -> Result? {
        let group = SharedSignIns.group(of: key)
        let cookies = await googleCookies(key)
        let fp = GoogleAccounts.sessionFingerprint(cookies)
        if cookies.isEmpty { return Result(accounts: [], fresh: true) }   // no Google cookie at all: nobody signed in
        if let got = await fetch(cookies) {
            save(got, group: group)
            return Result(accounts: got, fresh: true, fingerprint: fp)
        }
        return cached(group).map { Result(accounts: $0, fresh: false, fingerprint: fp) }
    }

    /// The sign-in cookies' fingerprint now (cheap: no request to Google).
    static func fingerprint(browserKey key: String) async -> String {
        GoogleAccounts.sessionFingerprint(await googleCookies(key))
    }

    /// The store's Google cookies once the store has joined its group (5 s at most): a store made here, for a
    /// workspace whose browser was not open yet, gets its kept and shared sign-ins asynchronously (SharedSignIns.register).
    private static func googleCookies(_ key: String) async -> [GoogleCookie] {
        let store = BrowserModel.dataStore(for: key)
        var waited = 0
        while !SharedSignIns.shared.isReady(key), waited < 100 { try? await Task.sleep(nanoseconds: 50_000_000); waited += 1 }
        let all: [HTTPCookie] = await withCheckedContinuation { c in store.httpCookieStore.getAllCookies { c.resume(returning: $0) } }
        return all.filter { SharedSignIns.matches($0.domain, ["google.com"]) }
            .map { GoogleCookie(name: $0.name, value: $0.value, domain: $0.domain, path: $0.path, expires: $0.expiresDate) }
    }

    private static func fetch(_ cookies: [GoogleCookie]) async -> [GoogleAccount]? {
        let url = GoogleAccounts.listURL
        let header = GoogleAccounts.cookieHeader(cookies, for: url)
        guard !header.isEmpty else { return [] }
        let cfg = URLSessionConfiguration.ephemeral
        cfg.httpCookieStorage = nil
        cfg.httpShouldSetCookies = false
        cfg.httpCookieAcceptPolicy = .never
        cfg.urlCache = nil
        let session = URLSession(configuration: cfg)
        defer { session.finishTasksAndInvalidate() }
        var r = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 8)
        r.httpShouldHandleCookies = false
        // A POST, as Chromium sends it; a GET gets 400 and the list never parsed.
        r.httpMethod = GoogleAccounts.listMethod
        r.httpBody = GoogleAccounts.listBody
        r.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        r.setValue(header, forHTTPHeaderField: "Cookie")
        r.setValue(BrowserModel.userAgent, forHTTPHeaderField: "User-Agent")   // the same browser Google signed in
        guard let res = try? await session.data(for: r), (res.1 as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return GoogleAccounts.parse(res.0)
    }

    private static func save(_ list: [GoogleAccount], group: String) {
        var all = UserDefaults.standard.dictionary(forKey: cacheKey) as? [String: [String]] ?? [:]
        all[group] = list.map { $0.email + "\t" + $0.name }
        UserDefaults.standard.set(all, forKey: cacheKey)
    }

    private static func cached(_ group: String) -> [GoogleAccount]? {
        guard let rows = (UserDefaults.standard.dictionary(forKey: cacheKey) as? [String: [String]])?[group] else { return nil }
        return rows.enumerated().compactMap { i, row in
            let p = row.components(separatedBy: "\t")
            guard let e = p.first, e.contains("@") else { return nil }
            return GoogleAccount(email: e, name: p.count > 1 ? p[1] : "", index: i)
        }
    }
}
