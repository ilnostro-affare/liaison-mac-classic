import AppKit

/// One saved tab: where it was and what it was called.
struct SavedTab: Codable, Equatable, Sendable {
    var url: String
    var title: String
    /// A pinned tab (kept first, never closed by \u{2318}W). nil in older saves.
    var pinned: Bool? = nil
    /// The tab group it belongs to (BrowserModel.groups), nil: none.
    var group: String? = nil
    /// The person's name for the tab.
    var name: String? = nil
    /// The address a pinned tab was pinned on (only for "Go to the Pinned Address"); `url` is always the
    /// page the tab is on now. nil in older saves and for unpinned tabs.
    var home: String? = nil
    /// The tab's id across launches: its interaction state file (TabStateStore). nil in older saves.
    var sid: String? = nil
}

/// A chat's tabs as they were. `selected` indexes `tabs`; nil: the person was on a start page.
struct SavedTabs: Codable, Equatable, Sendable {
    var tabs: [SavedTab]
    var selected: Int?
    var at: Double = 0

    static func == (a: SavedTabs, b: SavedTabs) -> Bool { a.tabs == b.tabs && a.selected == b.selected }
}

/// The browser lives in the chat: each chat's tabs survive closing the panel, quitting and
/// updating the app. Per Liaison account, per chat id, in UserDefaults (JSON). Changes land in memory at once; the
/// disk write is debounced (1 s) and encoded off the main thread; quitting flushes what is pending.
@MainActor
enum BrowserMemory {
    static let maxTabs = 30
    static let maxChats = 300

    private static var cache: [String: [String: SavedTabs]] = [:]   // account key -> chat id -> tabs
    private static var dirty: Set<String> = []
    private static var writeTask: Task<Void, Never>?
    private static let writeQueue = DispatchQueue(label: "lia.browser.memory", qos: .utility)
    private static var terminationObserver: NSObjectProtocol?

    private static func accountKey(_ account: String?) -> String { account ?? "_none" }
    private static func defaultsKey(_ accountKey: String) -> String { "lia_browser_tabs." + accountKey }

    private static func chats(_ key: String) -> [String: SavedTabs] {
        if let c = cache[key] { return c }
        var m: [String: SavedTabs] = [:]
        if let d = UserDefaults.standard.data(forKey: defaultsKey(key)),
           let decoded = try? JSONDecoder().decode([String: SavedTabs].self, from: d) { m = decoded }
        cache[key] = m
        return m
    }

    static func load(chat: String, account: String?) -> SavedTabs? {
        chats(accountKey(account))[chat]
    }

    /// nil or no tabs: the chat has nothing worth keeping.
    static func put(_ saved: SavedTabs?, chat: String, account: String?) {
        let key = accountKey(account)
        var m = chats(key)
        if let saved, !saved.tabs.isEmpty {
            if m[chat] == saved { return }
            var s = saved
            s.at = Date().timeIntervalSince1970
            m[chat] = s
            if m.count > maxChats {
                let keep = m.sorted { $0.value.at > $1.value.at }.prefix(maxChats)
                let dropped = Set(m.keys).subtracting(keep.map(\.key))
                m = Dictionary(uniqueKeysWithValues: keep.map { ($0.key, $0.value) })
                for c in dropped { TabStateStore.forget(account: account, chat: c) }
            }
        } else {
            guard m[chat] != nil else { return }
            m[chat] = nil
            TabStateStore.forget(account: account, chat: chat)
        }
        cache[key] = m
        dirty.insert(key)
        scheduleWrite()
    }

    /// The chat was deleted: its tabs go with it.
    static func forget(chat: String, account: String?) { put(nil, chat: chat, account: account) }

    private static func scheduleWrite() {
        observeTermination()
        writeTask?.cancel()
        writeTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            guard !Task.isCancelled else { return }
            let jobs = takeDirty()
            writeQueue.async { BrowserMemory.write(jobs) }
        }
    }

    private static func takeDirty() -> [(String, [String: SavedTabs])] {
        let jobs = dirty.map { (defaultsKey($0), cache[$0] ?? [:]) }
        dirty = []
        return jobs
    }

    nonisolated private static func write(_ jobs: [(String, [String: SavedTabs])]) {
        for (key, m) in jobs {
            if m.isEmpty { UserDefaults.standard.removeObject(forKey: key); continue }
            if let d = try? JSONEncoder().encode(m) { UserDefaults.standard.set(d, forKey: key) }
        }
    }

    /// Quitting within the debounce: what is pending is written before the app goes. The serial queue keeps an
    /// older write from landing after this one.
    static func flush() {
        writeTask?.cancel()
        writeTask = nil
        let jobs = takeDirty()
        guard !jobs.isEmpty else { return }
        writeQueue.sync { write(jobs) }
    }

    private static func observeTermination() {
        guard terminationObserver == nil else { return }
        terminationObserver = NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { BrowserMemory.flush() }
        }
    }
}

/// Site icons for the tab chips: in memory by host for the session, on disk in Caches so restored tabs show theirs
/// offline. Fetched off the page (its own ephemeral session: no cookies, neither the browser's nor Liaison's).
@MainActor
enum Favicons {
    private static var memory: [String: NSImage] = [:]
    /// Hosts whose icon could not be fetched this session: not asked again on every page load.
    private static var missing: Set<String> = []
    private static var inFlight: Set<String> = []

    private static let session: URLSession = {
        let c = URLSessionConfiguration.ephemeral
        c.timeoutIntervalForRequest = 8
        c.httpShouldSetCookies = false
        c.httpCookieAcceptPolicy = .never
        c.httpAdditionalHeaders = ["User-Agent": BrowserModel.userAgent]
        return URLSession(configuration: c)
    }()

    private static let dir: URL? = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?
        .appendingPathComponent("LiaisonFavicons", isDirectory: true)

    private static func file(_ host: String) -> URL? {
        let safe = String(host.lowercased().map { $0.isLetter || $0.isNumber || $0 == "." || $0 == "-" ? $0 : "_" })
        guard !safe.isEmpty else { return nil }
        return dir?.appendingPathComponent(safe + ".icon")
    }

    static func cached(_ host: String) -> NSImage? { memory[host] }

    /// Memory, then disk, then the candidates in order (none given: memory and disk only).
    static func icon(host: String, candidates: [URL]) async -> NSImage? {
        if let m = memory[host] { return m }
        if let f = file(host) {
            let data: Data? = await Task.detached(priority: .utility) { try? Data(contentsOf: f) }.value
            if let data, let img = decode(data) { memory[host] = img; return img }
        }
        guard !candidates.isEmpty, !missing.contains(host), !inFlight.contains(host) else { return nil }
        inFlight.insert(host)
        defer { inFlight.remove(host) }
        for u in candidates.prefix(4) {
            guard let s = u.scheme?.lowercased(), s == "http" || s == "https" else { continue }
            var req = URLRequest(url: u)
            req.timeoutInterval = 8
            guard let fetched = try? await session.data(for: req),
                  (fetched.1 as? HTTPURLResponse)?.statusCode == 200 else { continue }
            let data = fetched.0
            guard !data.isEmpty, data.count < 512 * 1024, let img = decode(data) else { continue }
            memory[host] = img
            if let f = file(host) {
                Task.detached(priority: .utility) {
                    try? FileManager.default.createDirectory(at: f.deletingLastPathComponent(), withIntermediateDirectories: true)
                    try? data.write(to: f, options: .atomic)
                }
            }
            return img
        }
        missing.insert(host)
        return nil
    }

    private static func decode(_ data: Data) -> NSImage? {
        guard let img = NSImage(data: data), img.isValid, img.size.width > 0, img.size.height > 0 else { return nil }
        return img
    }

    /// Runs in `BrowserModel.agentWorld`, never in the page's world. Always an array: declared icons (no SVG, which
    /// NSImage may not draw), nearest to 32 px first, then /favicon.ico.
    static let script = #"""
    const out = [];
    const score = (l) => { const n = parseInt(((l.getAttribute('sizes') || '').split('x')[0]), 10) || 0; return n === 0 ? 100 : Math.abs(n - 32); };
    Array.from(document.querySelectorAll('link[rel~="icon"],link[rel="shortcut icon"],link[rel~="apple-touch-icon"]'))
      .filter((l) => l.href && !/svg/i.test(l.type || '') && !/\.svg(\?|#|$)/i.test(l.href))
      .sort((a, b) => score(a) - score(b))
      .slice(0, 3)
      .forEach((l) => out.push(l.href));
    out.push(location.origin + '/favicon.ico');
    return out;
    """#
}

extension BrowserMemory {
    /// The tabs the person pinned in any chat of this account, newest chat first, one per address, for the
    /// address bar's suggestions.
    static func pinned(account: String?) -> [SavedTab] {
        var seen: Set<String> = []
        var out: [SavedTab] = []
        for (_, saved) in chats(accountKey(account)).sorted(by: { $0.value.at > $1.value.at }) {
            for t in saved.tabs where t.pinned == true && !seen.contains(t.url) {
                seen.insert(t.url)
                out.append(t)
            }
        }
        return out
    }
}
