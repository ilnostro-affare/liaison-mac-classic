import Foundation

// "Can't find this site" over sites that work. Each time the card is shown, or a failure is kept off a
// page that is still on screen (LoadFailure.decide's `showing`), the app logs it locally and sends one small event to
// lia-agents (`/agents/log`, kind "load_fail"), so the server can tell a real outage from our own false cards.
// The pure part: which failures count, what is sent (the host only: never a path or a query), and at most one event
// per host per minute.
enum LoadFailLog {
    static let kind = "load_fail"
    /// At most one event per host in this many seconds.
    static let interval: TimeInterval = 60
    /// Hosts remembered by the throttle before old entries are dropped.
    static let maxHosts = 256

    enum Outcome: String, Equatable {
        /// The card was shown.
        case card
        /// The failure was suppressed because the page at that address is still showing.
        case kept
    }

    /// What the failure became, nil when it is not worth an event (cancelled, superseded, a retry still to come, a
    /// failure after commit). `decision` is LoadFailure.decide's answer for the same arguments.
    static func outcome(_ decision: LoadFailure.Decision, domain: String, code: Int, current: Bool, committed: Bool,
                        showing: Bool) -> Outcome? {
        switch decision {
        case .show: return .card
        case .retry: return nil
        case .ignore:
            guard current, !committed, showing, domain == LoadFailure.urlDomain, LoadFailure.transient.contains(code) else { return nil }
            return .kept
        }
    }

    /// The host, lowercased; nil for an address without one (file:, about:, a data URL).
    static func host(_ url: URL?) -> String? {
        guard let h = url?.host?.lowercased(), !h.isEmpty else { return nil }
        return h
    }

    /// "mac 0.2.11": the event's `client`.
    static func client(version: String?) -> String { "mac " + ((version?.isEmpty == false) ? version! : "?") }

    /// The event's fields (LiaAPI.logEvent adds `kind`). `ms`: from the address's first failure to this one. `phase`
    /// is the server's word: "provisional" (didFailProvisionalNavigation) or "commit" (didFail after commit).
    static func fields(host: String, code: Int, committed: Bool, showing: Bool, retries: Int, ms: Int,
                       client: String) -> [String: Any] {
        ["host": host, "code": code, "phase": committed ? "commit" : "provisional", "showing": showing,
         "retries": retries, "ms": max(0, ms), "client": client]
    }

    struct Throttle {
        /// Seconds between two events for one host (LoadFailLog.interval; CookieChangeLog.interval).
        var interval: TimeInterval = LoadFailLog.interval
        private(set) var last: [String: Date] = [:]
        /// The server answered 429: nothing more is sent until the app quits (never retried).
        private(set) var stopped = false

        mutating func stop() { stopped = true }

        /// true when an event for `host` may go now (and records it).
        mutating func allow(_ host: String, now: Date = Date()) -> Bool {
            if stopped { return false }
            if let t = last[host], now.timeIntervalSince(t) < interval, now >= t { return false }
            if last.count >= LoadFailLog.maxHosts {
                last = last.filter { now.timeIntervalSince($0.value) < interval }
                if last.count >= LoadFailLog.maxHosts, let oldest = last.min(by: { $0.value < $1.value }) { last[oldest.key] = nil }
            }
            last[host] = now
            return true
        }
    }
}

// (Facebook and an admin site still signed the person out): every sign-in cookie that disappears or changes
// in a browser store is logged locally (os_log com.liaisone.mac / cookies) and sent as one small event to lia-agents,
// kind "cookie_change", so the next sign-out says who did it. Never a value: the site (registrable domain), the kind
// of store, the cookie NAMES, what happened and who did it (our own writes are tagged where they are made).
enum CookieChangeLog {
    static let kind = "cookie_change"
    /// At most one event per site in this many seconds.
    static let interval: TimeInterval = 30
    static let maxNames = 20

    enum Change: String, Equatable, CaseIterable { case removed, replaced, added }
    /// Who changed it: the site itself, our shared sign-ins, the vault at launch, the Chromium import; `unknown`: a
    /// cookie that ran out (WebKit drops it) or anything we cannot tell.
    enum By: String, Equatable, CaseIterable { case site, sync, vault, `import`, unknown }
    enum Store: String, Equatable, CaseIterable {
        /// A workspace's browser (the person's tabs and its agents' browsers share it).
        case workspace
        case agent
        /// A side-panel service's store shared by every workspace.
        case panelShared = "panel-shared"
        /// The account's own store (chat browsers).
        case account
    }

    /// The kind of a browser store from its key, never the key: "acct|p:~panel:svc", "acct|p:profile", "acct".
    static func store(ofKey key: String) -> Store {
        if key.contains("|p:~panel:") { return .panelShared }
        return key.contains("|p:") ? .workspace : .account
    }

    struct Event: Equatable {
        var host: String
        var store: Store
        var names: [String]
        var change: Change
        var by: By
    }

    /// A cookie name as sent: [A-Za-z0-9_.-]{1,64}, anything else dropped (the server applies the same rule).
    static func cleanName(_ n: String) -> String? {
        guard (1...64).contains(n.utf8.count) else { return nil }
        let ok = n.unicodeScalars.allSatisfy { c in
            (c >= "a" && c <= "z") || (c >= "A" && c <= "Z") || (c >= "0" && c <= "9") || c == "_" || c == "." || c == "-"
        }
        return ok ? n : nil
    }

    /// The sign-in cookies (SignInCookies.isAuth) that changed between two reads of one store, one event per site,
    /// change and author. `by` names who wrote that cookie id (nil: nobody of ours, so the site). A removed cookie
    /// that had run out is `unknown`.
    static func diff(before: [String: SignInCookies.Fact], after: [String: SignInCookies.Fact], store: Store,
                     now: Date = Date(), by: (String, Change) -> By?) -> [Event] {
        struct K: Hashable { let site: String; let change: Change; let by: By }
        var groups: [K: Set<String>] = [:]
        func note(_ f: SignInCookies.Fact, _ c: Change, _ who: By) {
            guard SignInCookies.isAuth(f) else { return }
            groups[K(site: SignInCookies.site(f), change: c, by: who), default: []].insert(f.name)
        }
        for (k, a) in after {
            if let b = before[k] {
                if b.value != a.value { note(a, .replaced, by(k, .replaced) ?? .site) }
            } else {
                note(a, .added, by(k, .added) ?? .site)
            }
        }
        for (k, b) in before where after[k] == nil {
            let expired = b.expires.map { $0 <= now } ?? false
            note(b, .removed, by(k, .removed) ?? (expired ? .unknown : .site))
        }
        return groups.map { k, names in
            Event(host: k.site, store: store, names: Array(names.compactMap(cleanName).sorted().prefix(maxNames)), change: k.change, by: k.by)
        }
        .filter { !$0.names.isEmpty && !$0.host.isEmpty }
        .sorted { ($0.host, $0.change.rawValue, $0.by.rawValue) < ($1.host, $1.change.rawValue, $1.by.rawValue) }
    }

    /// The event's fields (LiaAPI.logEvent adds `kind`).
    static func fields(_ e: Event, client: String) -> [String: Any] {
        ["host": e.host, "store": e.store.rawValue, "names": e.names, "change": e.change.rawValue, "by": e.by.rawValue, "client": client]
    }

    /// The os_log line.
    static func line(_ e: Event) -> String {
        "cookie_change \(e.change.rawValue) host=\(e.host) store=\(e.store.rawValue) by=\(e.by.rawValue) names=\(e.names.joined(separator: ","))"
    }
}
