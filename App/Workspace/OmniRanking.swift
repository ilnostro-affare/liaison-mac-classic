import Foundation

// The address bar's ranking. Every page ever visited (HistoryStore) is a candidate, scored by frecency
// (visits weighted with a 30-day half-life); the index is built off the main thread when the field opens and
// matched per keystroke over precomputed lowercased strings. OmniPicks keeps what the person typed and where it led:
// the inline completion only offers a URL the same fragment led to at least twice.

/// One page the field can suggest.
struct OmniCandidate: Sendable {
    let url: String
    /// Lowercased, no scheme, no "www.", no trailing slash: what a typed fragment is compared with.
    let shown: String
    let host: String
    let title: String
    let titleLower: String
    let frecency: Double
}

struct OmniIndex: Sendable {
    struct Source: Sendable { let url: String; let title: String; let visits: Int; let last: Double }

    private(set) var items: [OmniCandidate] = []
    static let empty = OmniIndex()
    static let halfLife: Double = 30 * 86400

    /// "https://www.Meta.com/" -> "meta.com".
    static func strip(_ s: String) -> String {
        var t = s.lowercased()
        for p in ["https://", "http://", "www."] where t.hasPrefix(p) { t.removeFirst(p.count) }
        if t.hasSuffix("/") { t.removeLast() }
        return t
    }

    static func frecency(visits: Int, last: Double, now: Double) -> Double {
        let age = max(0, now - last)
        return Double(max(1, visits)) * pow(0.5, age / halfLife)
    }

    /// Runs off the main thread (OmniboxModel.begin).
    static func build(_ src: [Source], now: Double) -> OmniIndex {
        var out = OmniIndex()
        out.items.reserveCapacity(src.count)
        for e in src {
            let shown = strip(e.url)
            guard !shown.isEmpty else { continue }
            let host = String(shown.prefix(while: { $0 != "/" && $0 != "?" && $0 != "#" }))
            out.items.append(OmniCandidate(url: e.url, shown: shown, host: host, title: e.title, titleLower: e.title.lowercased(),
                                           frecency: frecency(visits: e.visits, last: e.last, now: now)))
        }
        out.items.sort { $0.frecency > $1.frecency }
        return out
    }

    mutating func remove(_ url: String) { items.removeAll { $0.url == url } }

    /// The address starting with the fragment ranks first, then a host part or the address containing it, then the
    /// title; within each, frecency. `skip`: stripped addresses already shown above.
    func matches(_ typed: String, limit: Int, skip: Set<String>) -> [OmniCandidate] {
        let q = OmniIndex.strip(typed.trimmingCharacters(in: .whitespaces))
        guard !q.isEmpty, limit > 0 else { return [] }
        let dotted = "." + q
        var scored: [(OmniCandidate, Double)] = []
        for c in items where !skip.contains(c.shown) {
            let w: Double
            if c.shown.hasPrefix(q) { w = 8 }
            else if c.host.contains(dotted) { w = 4 }
            else if c.shown.contains(q) { w = 2 }
            else if c.titleLower.contains(q) { w = 1.5 }
            else { continue }
            scored.append((c, w * c.frecency))
        }
        scored.sort { $0.1 > $1.1 }
        return scored.prefix(limit).map(\.0)
    }
}

/// What the person typed in the address bar and where it took them, per browser profile, in UserDefaults (capped).
@MainActor
enum OmniPicks {
    struct Pick: Codable, Equatable { var url: String; var count: Int; var last: Double }
    struct Store: Codable { var frag: [String: [Pick]] = [:]; var typed: [Pick] = [] }

    static let maxFragments = 600
    static let maxPerFragment = 3
    static let maxTyped = 300
    static let maxFragmentLength = 40

    private static var cache: [String: Store] = [:]
    private static var saveJobs: [String: Task<Void, Never>] = [:]
    private static func key(_ account: String?) -> String { "lia_omni_picks_" + (account ?? "_") }

    private static func store(_ account: String?) -> Store {
        let k = key(account)
        if let s = cache[k] { return s }
        let s = UserDefaults.standard.data(forKey: k).flatMap { try? JSONDecoder().decode(Store.self, from: $0) } ?? Store()
        cache[k] = s
        return s
    }

    /// The person typed `fragment` and went to `url` from the address bar.
    static func record(fragment: String, url: URL, account: String?) {
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else { return }
        let f = fragment.lowercased().trimmingCharacters(in: .whitespaces)
        let u = url.absoluteString
        let now = Date().timeIntervalSince1970
        var s = store(account)
        if let i = s.typed.firstIndex(where: { $0.url == u }) { s.typed[i].count += 1; s.typed[i].last = now }
        else { s.typed.append(Pick(url: u, count: 1, last: now)) }
        if s.typed.count > maxTyped { s.typed = Array(s.typed.sorted { $0.last > $1.last }.prefix(maxTyped)) }
        if !f.isEmpty, !f.contains(" "), f.count <= maxFragmentLength {
            var list = s.frag[f] ?? []
            if let i = list.firstIndex(where: { $0.url == u }) { list[i].count += 1; list[i].last = now }
            else { list.append(Pick(url: u, count: 1, last: now)) }
            list.sort { ($0.count, $0.last) > ($1.count, $1.last) }
            s.frag[f] = Array(list.prefix(maxPerFragment))
            if s.frag.count > maxFragments {
                let keep = s.frag.sorted { ($0.value.map(\.last).max() ?? 0) > ($1.value.map(\.last).max() ?? 0) }.prefix(maxFragments)
                s.frag = Dictionary(uniqueKeysWithValues: keep.map { ($0.key, $0.value) })
            }
        }
        cache[key(account)] = s
        save(account)
    }

    /// The inline completion: an address a fragment led to at least twice, continuing exactly what is typed. The
    /// longest remembered fragment the typed text starts with decides ("fa" twice -> facebook.com also for "fac").
    static func completion(_ typed: String, account: String?) -> (shown: String, url: URL)? {
        let f = typed.lowercased()
        guard !f.isEmpty, !f.contains(" "), f.count <= maxFragmentLength,
              !f.hasPrefix("http"), !f.hasPrefix("www.") else { return nil }
        let frag = store(account).frag
        var n = f.count
        while n > 0 {
            if let list = frag[String(f.prefix(n))] {
                for p in list where p.count >= 2 {
                    let shown = OmniIndex.strip(p.url)
                    if shown.hasPrefix(f), shown != f, let u = URL(string: p.url) { return (shown, u) }
                }
            }
            n -= 1
        }
        return nil
    }

    /// Addresses the person typed or picked before, starting with or containing the fragment, best first.
    static func typed(_ q: String, account: String?, limit: Int) -> [Pick] {
        let k = OmniIndex.strip(q.trimmingCharacters(in: .whitespaces))
        guard !k.isEmpty, limit > 0 else { return [] }
        let now = Date().timeIntervalSince1970
        return store(account).typed
            .compactMap { p -> (Pick, Double)? in
                let s = OmniIndex.strip(p.url)
                let w: Double = s.hasPrefix(k) ? 4 : (s.contains(k) ? 1 : 0)
                guard w > 0 else { return nil }
                return (p, w * OmniIndex.frecency(visits: p.count, last: p.last, now: now))
            }
            .sorted { $0.1 > $1.1 }
            .prefix(limit).map(\.0)
    }

    /// \u{21E7}\u{232B} on a suggestion: it stops coming back from here too.
    static func forget(_ url: String, account: String?) {
        var s = store(account)
        s.typed.removeAll { $0.url == url }
        for (k, v) in s.frag {
            let left = v.filter { $0.url != url }
            s.frag[k] = left.isEmpty ? nil : left
        }
        cache[key(account)] = s
        save(account)
    }

    private static func save(_ account: String?) {
        let k = key(account)
        saveJobs[k]?.cancel()
        saveJobs[k] = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            guard !Task.isCancelled, let s = cache[k], let data = try? JSONEncoder().encode(s) else { return }
            UserDefaults.standard.set(data, forKey: k)
        }
    }
}

/// The ad account's campaign, ad set and ad names for the address bar, in memory per account. Read once
/// when the field first opens on a workspace with a Meta account, again at most every ten minutes; never per keystroke.
@MainActor
enum OmniEntityCache {
    private static var books: [String: OmniEntityBook] = [:]

    /// Per signed-in Liaison account and ad account: another login never sees these names.
    private static func key(_ account: String, _ auth: AuthStore) -> String { (auth.activeId ?? "_") + "|" + account }

    static func entities(_ account: String?, auth: AuthStore) -> [OmniEntity] {
        guard let account, !account.isEmpty else { return [] }
        return books[key(account, auth)]?.items ?? []
    }

    /// Starts a read when one is due; `loaded` runs on the main actor after a read that brought names.
    static func prepare(account: String?, auth: AuthStore, loaded: @escaping @MainActor () -> Void) {
        guard let account, !account.isEmpty else { return }
        let k = key(account, auth)
        let now = Date().timeIntervalSince1970
        var book = books[k] ?? OmniEntityBook()
        guard book.due(now: now) else { return }
        book.triedAt = now
        books[k] = book
        let api = LiaAPI(auth: auth)
        Task { @MainActor in
            guard let items = try? await api.accountEntities(account: account) else { return }
            var b = books[k] ?? OmniEntityBook()
            b.items = items
            b.loadedAt = Date().timeIntervalSince1970
            books[k] = b
            loaded()
        }
    }
}
