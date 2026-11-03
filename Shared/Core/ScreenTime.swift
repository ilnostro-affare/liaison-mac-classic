import Foundation

// 0.2.11: "like Screen Time on the iPhone, only in our browser: the person himself sees which sites
// and agents he spends most time on, and in agents or separate features". Local only: it is never uploaded, never
// logged, never leaves this Mac. The pure part: the registrable domain, the clock that turns ticks into counted
// seconds (paused when idle, locked or not in front), the per-day ledger kept 30 days, and the summaries Settings
// shows. The tracker (timers, idle, screen lock, the file per Liaison account) is App/Workspace/ScreenTimeTracker.swift.

enum ScreenTimeFeature: String, CaseIterable, Codable {
    case home, chats, notes, settings, browser

    var title: String {
        switch self {
        case .home: return "Home"
        case .chats: return "Chats"
        case .notes: return "Notes"
        case .settings: return "Settings"
        case .browser: return "Browser"
        }
    }
}

enum ScreenTimeDomain {
    /// Two-label public suffixes common enough to matter ("bbc.co.uk" is the site, not "co.uk"). Not the whole Public
    /// Suffix List: a host under an unlisted one is counted under its last two labels, which is at worst coarser.
    static let twoLabelSuffixes: Set<String> = [
        "co.uk", "org.uk", "ac.uk", "gov.uk", "me.uk", "ltd.uk", "plc.uk", "net.uk",
        "com.au", "net.au", "org.au", "edu.au", "gov.au", "co.nz", "org.nz", "net.nz",
        "co.jp", "ne.jp", "or.jp", "ac.jp", "go.jp", "co.kr", "or.kr", "com.cn", "net.cn", "org.cn", "com.hk", "com.tw",
        "com.sg", "com.my", "co.in", "net.in", "org.in", "co.id", "co.th", "com.vn", "com.ph", "com.pk",
        "com.br", "net.br", "org.br", "com.ar", "com.mx", "com.co", "com.pe", "com.uy", "com.ve", "com.ec",
        "co.za", "org.za", "com.ng", "co.ke", "com.eg", "com.tr", "com.sa", "co.il", "org.il", "com.ua", "org.ua",
        "com.ru", "org.ru", "net.ru", "spb.ru", "msk.ru", "com.pl", "co.at", "or.at", "com.es", "com.pt", "com.gr", "co.it",
        "github.io", "gitlab.io", "pages.dev", "workers.dev", "vercel.app", "netlify.app", "herokuapp.com", "web.app",
        "firebaseapp.com", "appspot.com", "blogspot.com", "cloudfront.net", "azurewebsites.net", "myshopify.com",
    ]

    /// The site a URL belongs to: its registrable domain ("www.facebook.com" and "business.facebook.com" are both
    /// "facebook.com"). An IP address or a single-label host (localhost) is itself. nil for no host (a new tab, a file,
    /// about: pages).
    static func registrable(_ url: URL?) -> String? {
        guard let url, let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else { return nil }
        return registrable(host: url.host)
    }

    static func registrable(host raw: String?) -> String? {
        guard var h = raw?.lowercased().trimmingCharacters(in: .whitespaces), !h.isEmpty else { return nil }
        while h.hasSuffix(".") { h.removeLast() }
        if h.hasPrefix("[") || h.contains(":") { return h }                      // IPv6
        let labels = h.split(separator: ".").map(String.init)
        guard !labels.isEmpty, labels.allSatisfy({ !$0.isEmpty }) else { return nil }
        if labels.count == 4, labels.allSatisfy({ Int($0).map { (0...255).contains($0) } ?? false }) { return h }   // IPv4
        if labels.count <= 2 { return labels.joined(separator: ".") }
        let last2 = labels.suffix(2).joined(separator: ".")
        if twoLabelSuffixes.contains(last2) { return labels.suffix(3).joined(separator: ".") }
        return last2
    }
}

/// What the person has in front at one moment. `active` is false when nothing should count (the window is not key,
/// the app is not in front, the screen is locked or asleep, or the person is idle).
struct ScreenTimeSample: Equatable {
    var active: Bool
    var feature: ScreenTimeFeature?
    var site: String?
    var agent: String?

    static let inactive = ScreenTimeSample(active: false, feature: nil, site: nil, agent: nil)
}

/// Turns periodic ticks into counted intervals. Each interval belongs to the sample taken at its START (what was in
/// front during it); it counts only when that sample was active, the person was not idle at the interval's end, and
/// the interval is no longer than `maxGap` (a longer one is a sleep or a stall: dropped, not guessed).
struct ScreenTimeClock {
    static let idleLimit: TimeInterval = 60
    var maxGap: TimeInterval = 30
    private(set) var last: (at: Date, sample: ScreenTimeSample)?

    init(maxGap: TimeInterval = 30) { self.maxGap = maxGap }

    /// > the interval to add (start, end, the sample it belongs to), or nil. `idle` is the seconds since the last
    /// input event at `now`.
    mutating func tick(now: Date, sample: ScreenTimeSample, idle: TimeInterval) -> (from: Date, to: Date, sample: ScreenTimeSample)? {
        let current = idle >= Self.idleLimit ? ScreenTimeSample.inactive : sample
        defer { last = (now, current) }
        guard let l = last, l.sample.active else { return nil }
        let dt = now.timeIntervalSince(l.at)
        guard dt > 0, dt <= maxGap, idle < Self.idleLimit else { return nil }
        return (l.at, now, l.sample)
    }

    /// Something stopped the counting at once (screen locked, app in the background): the open interval is closed
    /// with what was in front, and nothing counts until the next active tick.
    mutating func pause(now: Date, idle: TimeInterval = 0) -> (from: Date, to: Date, sample: ScreenTimeSample)? {
        let r = tick(now: now, sample: .inactive, idle: idle)
        return r
    }
}

/// Seconds per site, agent and feature on one local day.
struct ScreenTimeDay: Codable, Equatable {
    var day: String
    var sites: [String: Double] = [:]
    var agents: [String: Double] = [:]
    var features: [String: Double] = [:]

    var total: Double { features.values.reduce(0, +) }
}

struct ScreenTimeLedger: Codable, Equatable {
    static let keepDays = 30
    var days: [String: ScreenTimeDay] = [:]

    /// Adds `from..<to` for `sample`, split at local midnights so each day gets its own part.
    mutating func add(from: Date, to: Date, sample: ScreenTimeSample, calendar: Calendar = .current) {
        guard sample.active, to > from else { return }
        var start = from
        while start < to {
            let next = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: start)) ?? to
            let end = min(next, to)
            let s = end.timeIntervalSince(start)
            let key = LiaDay.key(start, calendar: calendar)
            var d = days[key] ?? ScreenTimeDay(day: key)
            if let f = sample.feature { d.features[f.rawValue, default: 0] += s }
            if let site = sample.site, !site.isEmpty { d.sites[site, default: 0] += s }
            if let a = sample.agent, !a.isEmpty { d.agents[a, default: 0] += s }
            days[key] = d
            start = end
        }
    }

    /// Drops the days older than `keepDays` before `now`'s day.
    mutating func prune(now: Date, calendar: Calendar = .current) {
        let cut = LiaDay.key(daysBefore: Self.keepDays - 1, now, calendar: calendar)
        days = days.filter { $0.key >= cut }
    }

    enum Range: Int { case today = 0, week = 1 }

    /// The day keys a range covers: today, or the last 7 days (today included).
    static func keys(_ r: Range, now: Date, calendar: Calendar = .current) -> [String] {
        (0..<(r == .today ? 1 : 7)).map { LiaDay.key(daysBefore: $0, now, calendar: calendar) }
    }

    func summary(_ r: Range, now: Date, calendar: Calendar = .current) -> ScreenTimeSummary {
        var s = ScreenTimeSummary()
        let ks = Self.keys(r, now: now, calendar: calendar)
        var sites: [String: Double] = [:], agents: [String: Double] = [:], features: [String: Double] = [:]
        for (i, k) in ks.enumerated() {
            let d = days[k]
            s.perDay.append((day: k, seconds: d?.total ?? 0))
            if i == 0 { s.todaySeconds = d?.total ?? 0 }
            guard let d else { continue }
            for (k, v) in d.sites { sites[k, default: 0] += v }
            for (k, v) in d.agents { agents[k, default: 0] += v }
            for (k, v) in d.features { features[k, default: 0] += v }
        }
        s.perDay.reverse()   // oldest first, for a left-to-right chart
        func rows(_ m: [String: Double]) -> [ScreenTimeRow] {
            m.filter { $0.value >= 1 }.map { ScreenTimeRow(id: $0.key, seconds: $0.value) }
                .sorted { $0.seconds != $1.seconds ? $0.seconds > $1.seconds : $0.id < $1.id }
        }
        s.sites = rows(sites); s.agents = rows(agents); s.features = rows(features)
        s.total = features.values.reduce(0, +)
        return s
    }
}

struct ScreenTimeRow: Equatable, Identifiable {
    let id: String
    let seconds: Double
}

struct ScreenTimeSummary {
    var total: Double = 0
    var todaySeconds: Double = 0
    var perDay: [(day: String, seconds: Double)] = []
    var sites: [ScreenTimeRow] = []
    var agents: [ScreenTimeRow] = []
    var features: [ScreenTimeRow] = []

    /// A row's share of the longest row (0...1), for its bar.
    static func share(_ r: ScreenTimeRow, of rows: [ScreenTimeRow]) -> Double {
        guard let top = rows.first?.seconds, top > 0 else { return 0 }
        return min(1, max(0, r.seconds / top))
    }

    /// "2 h 05 min", "12 min", "45 s", "0 min".
    static func format(_ seconds: Double) -> String {
        let s = Int(max(0, seconds).rounded())
        if s < 60 { return s == 0 ? "0 min" : "\(s) s" }
        let h = s / 3600, m = (s % 3600) / 60
        return h > 0 ? String(format: "%d h %02d min", h, m) : "\(m) min"
    }
}
