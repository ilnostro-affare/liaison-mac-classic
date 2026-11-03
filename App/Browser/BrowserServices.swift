import SwiftUI
import WebKit

/// The person's preferences the browser and the workspace read (Settings writes them).
enum Prefs {
    /// Google | bing | duckduckgo | perplexity.
    static let searchEngine = "lia_search_engine"
    /// Minutes before a tab nobody looks at goes to sleep; 0: never. Default 30.
    static let sleepMinutes = "lia_tab_sleep_min"
    /// MacOS notifications: an agent needs a Yes / an agent finished while the window is in the background (/03).
    static let notifyApprovals = "lia_notify_approvals"
    static let notifyDone = "lia_notify_done"
    /// Hours before an unpinned tab nobody used is closed into the archive; 0: never (default).
    static let archiveHours = "lia_tab_archive_hours"
    /// Text size in conversations (A11Y-04): 0 small, 1 default, 2 large, 3 extra large.
    static let chatTextSize = "lia_chat_text_size"
    /// The person's role from the welcome: marketer | agency | owner.
    static let role = "lia_role"
    /// Downloads into ~/Downloads/Liaison/<client>, on by default.
    static let downloadsPerClient = "lia_dl_per_client"
    /// The page zoom for sites without their own, 1 = 100 %.
    static let defaultZoom = "lia_default_zoom"
    /// Calmer agents (A11Y-07): no flowing shape while they work, eyes only.
    static let simpleBlobs = "lia_simple_blobs"
    /// Per-site styles the person wrote (Boosts): [host: css].
    static let boosts = "lia_boosts"
    /// Vertical tabs in a glass sidebar instead of the top row.
    static let verticalTabs = "lia_vertical_tabs"
    /// Compact mode: the top bar and the dock hide until the pointer reaches their edge.
    static let compactMode = "lia_compact_mode"
    /// Block third-party trackers, off by default; never on Meta / Google ad pages.
    static let blockTrackers = "lia_block_trackers"
    /// The app quit cleanly last time: false at launch means it did not.
    static let cleanExit = "lia_clean_exit"
    /// Interface sounds (SND, off by default).
    static let sounds = "lia_sounds"
    /// The screenshot card also for the Mac's own screenshots (saved files; the clipboard is only logged; ScreenshotWatcher), on by default.
    static let screenshotCard = "lia_screenshot_card"

    static var sleepAfter: TimeInterval {
        let d = UserDefaults.standard
        let m = d.object(forKey: sleepMinutes) == nil ? 30 : d.integer(forKey: sleepMinutes)
        return m <= 0 ? 0 : TimeInterval(m * 60)
    }
    static func flag(_ key: String, default value: Bool = true) -> Bool {
        UserDefaults.standard.object(forKey: key) == nil ? value : UserDefaults.standard.bool(forKey: key)
    }
    static var engine: String { UserDefaults.standard.string(forKey: searchEngine) ?? "google" }

    /// A search URL for typed words with the chosen engine (English results, as the app speaks English).
    static func searchURL(_ q: String) -> URL? {
        var c: URLComponents
        switch engine {
        case "bing": c = URLComponents(string: "https://www.bing.com/search")!; c.queryItems = [URLQueryItem(name: "q", value: q), URLQueryItem(name: "setlang", value: "en")]
        case "duckduckgo": c = URLComponents(string: "https://duckduckgo.com/")!; c.queryItems = [URLQueryItem(name: "q", value: q), URLQueryItem(name: "kl", value: "us-en")]
        case "perplexity": c = URLComponents(string: "https://www.perplexity.ai/search")!; c.queryItems = [URLQueryItem(name: "q", value: q)]
        default: c = URLComponents(string: "https://www.google.com/search")!; c.queryItems = [URLQueryItem(name: "q", value: q), URLQueryItem(name: "hl", value: "en")]
        }
        return c.url
    }
}

/// Why a page did not load, as the card shows it (/03).
struct PageError: Equatable {
    enum Kind: Equatable { case offline, notFound, unreachable, insecure, other }
    let kind: Kind
    let url: URL?
    let detail: String

    var title: String {
        switch kind {
        case .offline: return "You're offline"
        case .notFound: return "Can't find this site"
        case .unreachable: return "Can't reach this site"
        case .insecure: return "This connection isn't private"
        case .other: return "This page didn't load"
        }
    }
    var message: String {
        switch kind {
        case .offline: return "Check your connection. The page reloads by itself when you're back online."
        case .notFound: return "\(url?.host ?? "The server") could not be found. Check the address for a typo."
        case .unreachable: return "\(url?.host ?? "The server") didn't answer. It may be down for a moment; try again."
        case .insecure: return "\(url?.host ?? "This site") presented a certificate that can't be trusted. Someone could be trying to read what you send."
        case .other: return "Something went wrong while loading the page."
        }
    }

    /// nil: not worth a card (a cancelled load, a navigation the page replaced, a download).
    init?(_ error: Error, url: URL?) {
        let e = error as NSError
        if e.domain == NSURLErrorDomain && e.code == NSURLErrorCancelled { return nil }
        if e.domain == "WebKitErrorDomain" && (e.code == 102 || e.code == 204) { return nil }   // frame load interrupted / plug-in handled
        self.url = (e.userInfo[NSURLErrorFailingURLErrorKey] as? URL) ?? url
        self.detail = "\(e.domain) \(e.code)"
        switch (e.domain, e.code) {
        case (NSURLErrorDomain, NSURLErrorNotConnectedToInternet), (NSURLErrorDomain, NSURLErrorNetworkConnectionLost),
             (NSURLErrorDomain, NSURLErrorDataNotAllowed):
            kind = .offline
        case (NSURLErrorDomain, NSURLErrorCannotFindHost), (NSURLErrorDomain, NSURLErrorDNSLookupFailed):
            kind = .notFound
        // 1004: the name resolved, the connection did not open. Not "could not be found".
        case (NSURLErrorDomain, NSURLErrorCannotConnectToHost):
            kind = .unreachable
        case (NSURLErrorDomain, let c) where (-1206 ... -1200).contains(c):
            kind = .insecure
        default:
            kind = .other
        }
    }
}

/// Every download of the app, for the toolbar button and its popover (..05).
@MainActor
final class DownloadsCenter: NSObject, ObservableObject {
    static let shared = DownloadsCenter()

    final class Item: ObservableObject, Identifiable {
        enum State: Equatable { case running, done, failed, cancelled }
        let id = UUID()
        let started = Date()
        @Published var name: String
        @Published var dest: URL?
        @Published var state: State = .running
        @Published var fraction: Double = 0
        @Published var received: Int64 = 0
        @Published var total: Int64 = 0
        @Published var bytesPerSecond: Double = 0
        /// The agent whose browser downloaded it (nil: the person).
        var agent: String?
        weak var download: WKDownload?
        weak var webView: WKWebView?
        /// The address the download was requested from (WKDownload.originalRequest), for the installer warning.
        var sourceURL: URL?
        var resumeData: Data?
        var observation: NSKeyValueObservation?
        fileprivate var lastSample: (Date, Int64)?
        init(name: String) { self.name = name }

        var remaining: TimeInterval? {
            guard state == .running, bytesPerSecond > 1, total > 0 else { return nil }
            return Double(total - received) / bytesPerSecond
        }
    }

    @Published private(set) var items: [Item] = []
    /// Bumped when a download starts: the toolbar plays the flight of the file to its button.
    @Published private(set) var flight = 0
    /// Any download running: the button shows its ring.
    var active: [Item] { items.filter { $0.state == .running } }
    var overall: Double {
        let a = active
        guard !a.isEmpty else { return 1 }
        return a.map(\.fraction).reduce(0, +) / Double(a.count)
    }

    private func item(for d: WKDownload) -> Item? { items.first { $0.download === d } }

    func started(_ d: WKDownload, name: String, dest: URL, webView: WKWebView?, agent: String? = nil) {
        let it = item(for: d) ?? Item(name: name)
        if let agent { it.agent = agent }
        it.name = name; it.dest = dest; it.download = d; it.webView = webView; it.state = .running
        if let u = d.originalRequest?.url { it.sourceURL = u }
        it.observation = d.progress.observe(\.fractionCompleted) { [weak it] p, _ in
            let f = p.fractionCompleted, done = p.completedUnitCount, total = p.totalUnitCount
            Task { @MainActor in
                guard let it else { return }
                it.fraction = f; it.received = done; it.total = max(total, 0)
                let now = Date()
                if let (t0, b0) = it.lastSample, now.timeIntervalSince(t0) > 0.5 {
                    let speed = Double(done - b0) / now.timeIntervalSince(t0)
                    it.bytesPerSecond = it.bytesPerSecond == 0 ? speed : it.bytesPerSecond * 0.6 + speed * 0.4
                    it.lastSample = (now, done)
                } else if it.lastSample == nil { it.lastSample = (now, done) }
            }
        }
        if !items.contains(where: { $0 === it }) { items.insert(it, at: 0) }
        if items.count > 40 { items.removeLast(items.count - 40) }
        flight += 1
        objectWillChange.send()
    }

    func finished(_ d: WKDownload) {
        guard let it = item(for: d) else { return }
        it.state = .done; it.fraction = 1; it.observation = nil
        objectWillChange.send()
    }

    func failed(_ d: WKDownload, resumeData: Data?) {
        guard let it = item(for: d) else { return }
        if it.state != .cancelled { it.state = .failed }
        it.resumeData = resumeData; it.observation = nil
        objectWillChange.send()
    }

    func cancel(_ it: Item) {
        it.state = .cancelled
        it.download?.cancel { data in Task { @MainActor in it.resumeData = data } }
        objectWillChange.send()
    }

    /// Retry a failed or cancelled download where it stopped (resume data), in the web view that started it.
    func retry(_ it: Item) {
        guard let data = it.resumeData, let w = it.webView else { return }
        w.resumeDownload(fromResumeData: data) { [weak self] d in
            Task { @MainActor in
                guard let self else { return }
                it.download = d
                d.delegate = (w.navigationDelegate as? WKDownloadDelegate)
                if let dest = it.dest { self.started(d, name: it.name, dest: dest, webView: w) }
            }
        }
    }

    // MARK: the app's own files ("everything must drop automatically, the path is set")

    /// Where a download lands: ~/Downloads, or ~/Downloads/Liaison/<workspace> with on (BrowserModel's rule).
    static func folder(client: String?) -> URL {
        var dir = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Downloads", isDirectory: true)
        if Prefs.flag(Prefs.downloadsPerClient), let name = client?.trimmingCharacters(in: .whitespaces), !name.isEmpty {
            let safe = name.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
            let sub = dir.appendingPathComponent("Liaison", isDirectory: true).appendingPathComponent(safe, isDirectory: true)
            if (try? FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)) != nil { dir = sub }
        }
        return dir
    }

    /// A free name in `dir`: "name.png", then "name (1).png" ...
    static func destination(_ name: String, in dir: URL) -> URL {
        let clean = name.components(separatedBy: CharacterSet(charactersIn: "/\\:")).joined(separator: "-")
        var dest = dir.appendingPathComponent(clean.isEmpty ? "download" : clean)
        let base = dest.deletingPathExtension().lastPathComponent, ext = dest.pathExtension
        var n = 1
        while FileManager.default.fileExists(atPath: dest.path) {
            dest = dir.appendingPathComponent("\(base) (\(n))" + (ext.isEmpty ? "" : ".\(ext)")); n += 1
        }
        return dest
    }

    /// The workspace in front's name (its downloads folder).
    static var currentClient: String? { WorkspaceModel.current?.profile?.name }

    /// Bytes the app made or holds (a Crea picture, a chart, a screenshot, a CSV): into the downloads folder with no
    /// save panel, listed like any download (the toolbar's flight and ring, the popover's row with Open / Show in
    /// Finder). The file's URL, nil when it could not be written.
    @discardableResult
    /// `client` nil: the workspace in front (resolved here: a default argument is evaluated off the main actor).
    func save(_ data: Data, name: String, client: String? = nil, agent: String? = nil) -> URL? {
        let dest = Self.destination(name, in: Self.folder(client: client ?? Self.currentClient))
        let it = Item(name: dest.lastPathComponent)
        it.dest = dest
        it.agent = agent
        it.total = Int64(data.count)
        insert(it)
        do {
            try data.write(to: dest, options: .atomic)
            it.received = it.total; it.fraction = 1; it.state = .done
        } catch {
            it.state = .failed
        }
        objectWillChange.send()
        return it.state == .done ? dest : nil
    }

    /// A file at an address that needs no sign-in (a signed link): fetched into the downloads folder, listed like a
    /// download while it comes (the ring), instead of handing it to the default browser.
    func fetch(_ url: URL, name: String, client: String? = nil) {
        let dir = Self.folder(client: client ?? Self.currentClient)
        let it = Item(name: name.isEmpty ? "Download" : name)
        insert(it)
        Task { @MainActor in
            do {
                let (tmp, resp) = try await URLSession.shared.download(from: url)
                let status = (resp as? HTTPURLResponse)?.statusCode ?? 200
                guard (200..<300).contains(status) else { throw URLError(.badServerResponse) }
                guard it.state != .cancelled else { try? FileManager.default.removeItem(at: tmp); return }
                // The name the server gave wins over ours when ours was a guess.
                let suggested = resp.suggestedFilename.flatMap { $0.isEmpty || $0 == "Unknown" ? nil : $0 }
                let dest = Self.destination(name.isEmpty ? (suggested ?? "download") : name, in: dir)
                try? FileManager.default.removeItem(at: dest)
                try FileManager.default.moveItem(at: tmp, to: dest)
                it.dest = dest; it.name = dest.lastPathComponent
                let size = (try? dest.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
                it.total = Int64(size); it.received = it.total
                it.fraction = 1; it.state = .done
            } catch {
                if it.state != .cancelled { it.state = .failed }
            }
            self.objectWillChange.send()
        }
    }

    private func insert(_ it: Item) {
        items.insert(it, at: 0)
        if items.count > 40 { items.removeLast(items.count - 40) }
        flight += 1
        objectWillChange.send()
    }

    func remove(_ it: Item) { items.removeAll { $0 === it }; objectWillChange.send() }
    func clearFinished() { items.removeAll { $0.state != .running }; objectWillChange.send() }
    func reveal(_ it: Item) { if let u = it.dest { NSWorkspace.shared.activateFileViewerSelecting([u]) } }
    func open(_ it: Item) { if let u = it.dest, it.state == .done { NSWorkspace.shared.open(u) } }
}

/// Pages the person visited, per browser profile (the omnibox suggests from it; HIST). Newest first, capped.
@MainActor
enum HistoryStore {
    struct Entry: Codable, Equatable { let url: String; var title: String; var visits: Int; var last: Double }
    private static var cache: [String: [Entry]] = [:]
    private static func key(_ account: String?) -> String { "lia_hist_" + (account ?? "_") }
    static let cap = 1500

    static func entries(_ account: String?) -> [Entry] {
        let k = key(account)
        if let c = cache[k] { return c }
        let list = (UserDefaults.standard.data(forKey: k)).flatMap { try? JSONDecoder().decode([Entry].self, from: $0) } ?? []
        cache[k] = list
        return list
    }

    static func record(_ url: URL, title: String, account: String?) {
        guard let s = url.scheme?.lowercased(), s == "http" || s == "https" else { return }
        var list = entries(account)
        let u = url.absoluteString
        let now = Date().timeIntervalSince1970
        if let i = list.firstIndex(where: { $0.url == u }) {
            var e = list.remove(at: i); e.visits += 1; e.last = now; if !title.isEmpty { e.title = title }
            list.insert(e, at: 0)
        } else {
            list.insert(Entry(url: u, title: title, visits: 1, last: now), at: 0)
        }
        if list.count > cap { list.removeLast(list.count - cap) }
        cache[key(account)] = list
        save(account)
    }

    /// Forget this profile's pages visited since a moment (nil: all of them).
    static func clear(account: String?, since: Date? = nil) {
        let k = key(account)
        let cut = since?.timeIntervalSince1970 ?? 0
        cache[k] = since == nil ? [] : entries(account).filter { $0.last < cut }
        save(account)
    }

    /// Imported bookmarks join the suggestions behind real history (old dates, one visit), never crowding it out.
    static func importEntries(_ items: [(url: URL, title: String)], account: String?) -> Int {
        importEntries(items.map { (url: $0.url, title: $0.title, visits: 1, last: nil as Date?) }, account: account)
    }

    /// Pages from another browser's history keep their visit count; their date is the visit's but never newer than
    /// 30 days ago, so the person's own browsing here always ranks first.
    static func importEntries(_ items: [(url: URL, title: String, visits: Int, last: Date?)], account: String?) -> Int {
        var list = entries(account)
        let have = Set(list.map(\.url))
        var added = 0
        let old = Date().addingTimeInterval(-90 * 86400).timeIntervalSince1970
        let newest = Date().addingTimeInterval(-30 * 86400).timeIntervalSince1970
        for it in items {
            guard let s = it.url.scheme?.lowercased(), s == "http" || s == "https" else { continue }
            let u = it.url.absoluteString
            guard !have.contains(u), list.count < cap else { continue }
            let when = it.last.map { min($0.timeIntervalSince1970, newest) } ?? old
            list.append(Entry(url: u, title: it.title, visits: max(1, it.visits), last: when))
            added += 1
        }
        cache[key(account)] = list
        save(account)
        return added
    }

    static func remove(_ url: String, account: String?) {
        var list = entries(account); list.removeAll { $0.url == url }
        cache[key(account)] = list; save(account)
    }

    private static var saveJobs: [String: Task<Void, Never>] = [:]
    private static func save(_ account: String?) {
        let k = key(account)
        saveJobs[k]?.cancel()
        saveJobs[k] = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            guard !Task.isCancelled, let list = cache[k], let data = try? JSONEncoder().encode(list) else { return }
            UserDefaults.standard.set(data, forKey: k)
        }
    }

    /// The best matches for typed text: host or title words, frequent and recent first.
    static func matches(_ typed: String, account: String?, limit: Int = 6) -> [Entry] {
        let q = typed.lowercased().trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return [] }
        let stripped = { (s: String) -> String in
            var t = s.lowercased()
            for p in ["https://", "http://", "www."] where t.hasPrefix(p) { t.removeFirst(p.count) }
            return t
        }
        let now = Date().timeIntervalSince1970
        return entries(account)
            .filter { stripped($0.url).hasPrefix(q) || stripped($0.url).contains(q) || $0.title.lowercased().contains(q) }
            .sorted { a, b in
                func score(_ e: Entry) -> Double {
                    let prefix = stripped(e.url).hasPrefix(q) ? 4.0 : 0
                    let age = max(1, (now - e.last) / 3600)
                    return prefix + log(Double(e.visits) + 1) * 2 - log(age) * 0.5
                }
                return score(a) > score(b)
            }
            .prefix(limit).map { $0 }
    }

    /// The host the person most likely means, for inline completion ("fa" -> "facebook.com"; ).
    static func completion(_ typed: String, account: String?) -> String? {
        let q = typed.lowercased()
        guard q.count >= 2, !q.contains(" "), !q.contains("/") else { return nil }
        for e in entries(account).sorted(by: { $0.visits > $1.visits }) {
            guard var host = URL(string: e.url)?.host?.lowercased() else { continue }
            if host.hasPrefix("www.") { host.removeFirst(4) }
            if host.hasPrefix(q), host != q { return host }
        }
        return nil
    }
}

/// The page zoom the person chose per site. 1: the default.
enum ZoomStore {
    static let steps: [CGFloat] = [0.5, 0.67, 0.75, 0.8, 0.9, 1, 1.1, 1.25, 1.5, 1.75, 2, 2.5, 3]
    private static let key = "lia_zoom_by_host"
    static func zoom(for host: String?) -> CGFloat {
        let fallback = UserDefaults.standard.object(forKey: Prefs.defaultZoom) == nil ? 1 : CGFloat(UserDefaults.standard.double(forKey: Prefs.defaultZoom))
        guard let host, let d = UserDefaults.standard.dictionary(forKey: key) as? [String: Double], let z = d[host] else { return fallback }
        return CGFloat(z)
    }
    static func set(_ z: CGFloat, for host: String?) {
        guard let host else { return }
        var d = UserDefaults.standard.dictionary(forKey: key) as? [String: Double] ?? [:]
        // Back to the default zoom (Settings, ): the site keeps no zoom of its own.
        let fallback = UserDefaults.standard.object(forKey: Prefs.defaultZoom) == nil ? 1 : CGFloat(UserDefaults.standard.double(forKey: Prefs.defaultZoom))
        if abs(z - fallback) < 0.01 { d.removeValue(forKey: host) } else { d[host] = Double(z) }
        UserDefaults.standard.set(d, forKey: key)
    }
    static func next(_ z: CGFloat, up: Bool) -> CGFloat {
        if up { return steps.first { $0 > z + 0.001 } ?? steps.last! }
        return steps.last { $0 < z - 0.001 } ?? steps.first!
    }
}

/// Camera and microphone decisions per browser profile and site (/02).
enum PermissionStore {
    enum Kind: String { case camera, microphone, cameraAndMicrophone }
    private static func key(_ account: String?) -> String { "lia_perm_" + (account ?? "_") }
    static func decision(_ kind: Kind, host: String, account: String?) -> Bool? {
        (UserDefaults.standard.dictionary(forKey: key(account)) as? [String: Bool])?[host + "|" + kind.rawValue]
    }
    static func set(_ allow: Bool?, _ kind: Kind, host: String, account: String?) {
        var d = UserDefaults.standard.dictionary(forKey: key(account)) as? [String: Bool] ?? [:]
        d[host + "|" + kind.rawValue] = allow
        UserDefaults.standard.set(d, forKey: key(account))
    }
    /// Everything decided for this profile, for Settings and the site sheet: (host, kind, allowed).
    static func all(account: String?) -> [(host: String, kind: Kind, allow: Bool)] {
        let d = UserDefaults.standard.dictionary(forKey: key(account)) as? [String: Bool] ?? [:]
        return d.compactMap { k, v in
            let p = k.split(separator: "|", maxSplits: 1).map(String.init)
            guard p.count == 2, let kind = Kind(rawValue: p[1]) else { return nil }
            return (p[0], kind, v)
        }.sorted { $0.host < $1.host }
    }
}

/// A page asking for the camera or microphone, waiting for the person (the card under the address; ).
@MainActor
final class PermissionAsk: Identifiable {
    let id = UUID()
    let host: String
    let kind: PermissionStore.Kind
    private var handler: ((WKPermissionDecision) -> Void)?
    init(host: String, kind: PermissionStore.Kind, handler: @escaping (WKPermissionDecision) -> Void) {
        self.host = host; self.kind = kind; self.handler = handler
    }
    var what: String {
        switch kind {
        case .camera: return "use your camera"
        case .microphone: return "use your microphone"
        case .cameraAndMicrophone: return "use your camera and microphone"
        }
    }
    func answer(_ allow: Bool) { handler?(allow ? .grant : .deny); handler = nil }
}

/// A compact tracker block list, compiled once at launch (WKContentRuleList). Third-party loads only, and
/// never while the page itself is Meta's or Google's (Ads Manager, Business Suite, Google Ads keep working).
@MainActor
enum Trackers {
    private(set) static var list: WKContentRuleList?
    static let domains = [
        "doubleclick.net", "googlesyndication.com", "google-analytics.com", "googletagservices.com", "scorecardresearch.com",
        "quantserve.com", "taboola.com", "outbrain.com", "criteo.com", "criteo.net", "adnxs.com", "rubiconproject.com",
        "pubmatic.com", "openx.net", "hotjar.com", "mouseflow.com", "fullstory.com", "mixpanel.com", "amplitude.com",
        "segment.io", "adsrvr.org", "moatads.com", "bidswitch.net", "casalemedia.com", "yieldmo.com", "zemanta.com",
    ]
    static func prepare() {
        let unless: [String] = ["facebook.com", "instagram.com", "google.com", "googleadservices.com", "liaisone.com"].map(topURL)
        let rules: [[String: Any]] = domains.map { d in rule(d, unless: unless) }
        guard let data = try? JSONSerialization.data(withJSONObject: rules), let json = String(data: data, encoding: .utf8) else { return }
        WKContentRuleListStore.default().compileContentRuleList(forIdentifier: "lia-trackers-1", encodedContentRuleList: json) { l, _ in
            Task { @MainActor in Trackers.list = l }
        }
    }

    /// A regex backslash (the rule list is JSON; JSONSerialization escapes it once more).
    private static let bs = "\u{5C}"

    /// A top-level page on that site (any subdomain), as an unless-top-url regex.
    private static func topURL(_ host: String) -> String {
        let escaped: String = host.replacingOccurrences(of: ".", with: bs + ".")
        return "^https?://.*" + escaped + ".*"
    }

    /// One block rule: third-party loads from `domain` or its subdomains, unless the page is one of `unless`.
    private static func rule(_ domain: String, unless: [String]) -> [String: Any] {
        let escaped: String = domain.replacingOccurrences(of: ".", with: bs + ".")
        let filter: String = "^https?://([^/]*" + bs + ".)?" + escaped + "[:/]"
        var trigger: [String: Any] = [:]
        trigger["url-filter"] = filter
        trigger["load-type"] = ["third-party"]
        trigger["unless-top-url"] = unless
        let action: [String: Any] = ["type": "block"]
        return ["trigger": trigger, "action": action]
    }
}

/// The last run ended without quitting (a crash or a force quit): the workspace says its tabs are back.
enum CrashNotice { static var previousRunCrashed = false }

/// Boosts: the person's own CSS per site, applied from our content world (it styles the page; no script of
/// ours enters the page's world). Matched by host suffix ("facebook.com" covers business.facebook.com).
enum Boosts {
    static var all: [String: String] { UserDefaults.standard.dictionary(forKey: Prefs.boosts) as? [String: String] ?? [:] }
    static func set(_ css: String?, for host: String) {
        var d = all
        let h = host.lowercased().trimmingCharacters(in: .whitespaces)
        if let css, !css.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { d[h] = css } else { d.removeValue(forKey: h) }
        UserDefaults.standard.set(d, forKey: Prefs.boosts)
    }
    static func css(for host: String?) -> String? {
        guard let host = host?.lowercased() else { return nil }
        let list = all.filter { host == $0.key || host.hasSuffix("." + $0.key) }.map(\.value)
        return list.isEmpty ? nil : list.joined(separator: "\n")
    }
    static let script = "let s=document.getElementById('lia-boost');if(!s){s=document.createElement('style');s.id='lia-boost';(document.head||document.documentElement).appendChild(s);}s.textContent=css;return true;"
}
