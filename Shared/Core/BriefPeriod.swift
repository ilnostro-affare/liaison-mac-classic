import Foundation

// Home's Meta brief is direct reads and a fixed sentence, no model. "Switch the period by tapping:
// yesterday, today, week, month - rolling, not calendar. Several ad accounts in a workspace: sum them." Pure pieces:
// the periods and their day ranges, the sums per currency (never across currencies, server rules 11/12) and the
// sentence. The reads are get_account_stats {account, from, to} (meta-mcp -> meta-auth /meta/stats -> Graph insights).

/// The brief's period, rolling: "Last 7 days" is the seven whole days that end yesterday, never "this week".
enum BriefPeriod: String, CaseIterable, Identifiable {
    case today, yesterday, week, month
    var id: String { rawValue }

    static let fallback: BriefPeriod = .yesterday

    /// Days in the period.
    var days: Int {
        switch self {
        case .today, .yesterday: return 1
        case .week: return 7
        case .month: return 30
        }
    }

    /// The switch's label.
    var title: String {
        switch self {
        case .today: return "Today"
        case .yesterday: return "Yesterday"
        case .week: return "Last 7 days"
        case .month: return "Last 30 days"
        }
    }

    /// A tap moves to the next one, in Today, Yesterday, Last 7 days, Last 30 days order, and round again.
    var next: BriefPeriod {
        let all = Self.allCases
        let i = all.firstIndex(of: self) ?? 0
        return all[(i + 1) % all.count]
    }

    /// The range as days before today, both ends included (0 = today). Today is so far; the others end yesterday,
    /// as Ads Manager's "Last 7 days" does, so a period is whole days only.
    var offsets: (from: Int, to: Int) {
        switch self {
        case .today: return (0, 0)
        case .yesterday: return (1, 1)
        case .week: return (7, 1)
        case .month: return (30, 1)
        }
    }

    /// The equal period just before. Today has none: part of a day against a whole one says nothing.
    var previousOffsets: (from: Int, to: Int)? {
        guard self != .today else { return nil }
        let o = offsets
        return (o.from + days, o.to + days)
    }

    /// "vs the day before" / "vs the previous 7 days"; nil for Today.
    var comparison: String? {
        switch self {
        case .today: return nil
        case .yesterday: return "vs the day before"
        case .week: return "vs the previous 7 days"
        case .month: return "vs the previous 30 days"
        }
    }

    /// The sentence's opening: "Yesterday you spent..." / "In the last 7 days you spent...".
    var lead: String {
        switch self {
        case .today: return "Today so far"
        case .yesterday: return "Yesterday"
        case .week: return "In the last 7 days"
        case .month: return "In the last 30 days"
        }
    }

    /// What "Explain the spend ..." ends with.
    var askSuffix: String {
        switch self {
        case .today: return "today so far"
        case .yesterday: return "yesterday"
        case .week: return "over the last 7 days"
        case .month: return "over the last 30 days"
        }
    }

    /// The saved choice back to a period; unknown or empty: Yesterday.
    static func stored(_ raw: String?) -> BriefPeriod {
        BriefPeriod(rawValue: (raw ?? "").trimmingCharacters(in: .whitespaces).lowercased()) ?? fallback
    }

    /// Per workspace; contains "<profile>|", so Reset this workspace clears it with the rest of `lia_ws_*`.
    static func key(profile: String) -> String { "lia_ws_brief_period_" + profile + "|" }

    /// yyyy-MM-dd in the calendar's time zone.
    static func stamp(_ d: Date, calendar: Calendar) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.calendar = Calendar(identifier: .gregorian)
        f.timeZone = calendar.timeZone
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: d)
    }

    private static func range(_ o: (from: Int, to: Int), now: Date, calendar: Calendar) -> (from: String, to: String) {
        let day = calendar.startOfDay(for: now)
        func back(_ n: Int) -> String {
            stamp(calendar.date(byAdding: .day, value: -n, to: day) ?? day, calendar: calendar)
        }
        return (back(o.from), back(o.to))
    }

    func range(now: Date = Date(), calendar: Calendar = .current) -> (from: String, to: String) {
        Self.range(offsets, now: now, calendar: calendar)
    }

    func previousRange(now: Date = Date(), calendar: Calendar = .current) -> (from: String, to: String)? {
        previousOffsets.map { Self.range($0, now: now, calendar: calendar) }
    }
}

/// One currency's accounts over the period, summed, and the same accounts over the period before.
struct BriefGroup: Codable, Equatable {
    var stats: TourStats
    /// The previous equal period over the same accounts; nil when there is no comparison or one of them had no answer.
    var prev: TourStats?
    /// Accounts summed.
    var accounts: Int

    var currency: String? { stats.currency }

    /// Whole percent from b to a; nil when b is 0 or missing.
    static func pct(_ a: Double?, _ b: Double?) -> Int? {
        guard let a, let b, b > 0 else { return nil }
        return Int(((a - b) / b * 100).rounded())
    }

    var spendChange: Int? { prev.flatMap { Self.pct(stats.spend, $0.spend) } }
    var costChange: Int? { prev.flatMap { Self.pct(stats.costPer, $0.costPer) } }
    var outcomeChange: Int? { prev.flatMap { Self.pct(stats.outcome, $0.outcome) } }
}

enum BriefTotals {
    /// `current[i]` and `previous[i]` are account i's reads (nil: no answer), in the workspace's order; `previous` is
    /// empty when the period has no comparison. One group per currency, in the order the currencies first appear,
    /// never summed across currencies. An account without a currency joins the first group. No answer at all: [].
    static func groups(current: [TourStats?], previous: [TourStats?]) -> [BriefGroup] {
        var order: [String?] = []
        var members: [String?: [Int]] = [:]
        let firstCur = current.compactMap { $0?.currency?.uppercased() }.first
        for (i, s) in current.enumerated() {
            guard let s else { continue }
            let c = s.currency?.uppercased() ?? firstCur
            if members[c] == nil { order.append(c); members[c] = [] }
            members[c]?.append(i)
        }
        return order.map { c in
            let idx = members[c] ?? []
            let shown = current[idx[0]]?.currency ?? c
            let stats = add(idx.compactMap { current[$0] }, currency: shown)
            var prev: TourStats? = nil
            let b = idx.map { previous.indices.contains($0) ? previous[$0] : nil }
            if !previous.isEmpty, !b.isEmpty, b.allSatisfy({ $0 != nil }) {
                prev = add(b.compactMap { $0 }, currency: shown)
            }
            return BriefGroup(stats: stats, prev: prev, accounts: idx.count)
        }
    }

    /// One account stays as the server said it (its own CPL); several are summed, CPL = spend / leads.
    static func add(_ list: [TourStats], currency: String?) -> TourStats {
        if list.count == 1, var one = list.first { one.currency = one.currency ?? currency; return one }
        let spend = list.reduce(0) { $0 + $1.spend }
        let leads = list.reduce(0) { $0 + $1.leads }
        let results = list.reduce(0) { $0 + $1.results }
        return TourStats(spend: spend, leads: leads, results: results, cpl: leads > 0 ? spend / leads : nil, currency: currency)
    }

    /// The accounts to read: every ad account of the workspace (digits, no repeats), else the first one alone.
    static func accounts(_ list: [String], first: String?) -> [String] {
        var out: [String] = []
        for a in list + [first].compactMap({ $0 }) {
            let d = a.filter(\.isNumber)
            if !d.isEmpty, !out.contains(d) { out.append(d) }
        }
        return out
    }
}

/// The brief's words, from a template (never a model).
enum BriefText {
    /// "+12%" / "−8%" (a real minus) / "flat".
    static func pct(_ p: Int) -> String {
        p == 0 ? "flat" : (p > 0 ? "+\(p)%" : "\u{2212}\(-p)%")
    }

    /// "↓8%" / "↑12%"; nil when flat.
    static func arrow(_ p: Int?) -> String? {
        guard let p, p != 0 else { return nil }
        return p < 0 ? "\u{2193}\(-p)%" : "\u{2191}\(p)%"
    }

    /// "Yesterday you spent €35.59 and got 5 leads at €7.12 each." / "In the last 7 days you spent ...".
    static func sentence(_ g: BriefGroup, period: BriefPeriod) -> String {
        let s = g.stats
        let n = Int(s.outcome.rounded())
        if s.spend <= 0 && n == 0 {
            return period == .today ? "Nothing has run today yet: no spend, no results."
                : "Nothing ran \(period.askSuffix): no spend, no results."
        }
        let what = s.leads > 0 ? (n == 1 ? "lead" : "leads") : (n == 1 ? "result" : "results")
        if n == 0 { return "\(period.lead) you spent \(s.money(s.spend)) and got no leads." }
        let each = s.costPer.map { " at \(s.money($0)) each" } ?? ""
        return "\(period.lead) you spent \(s.money(s.spend)) and got \(n) \(what)\(each)."
    }

    /// "Spend −23%, cost per lead −8% vs the previous 7 days."; nil without a comparison.
    static func change(_ g: BriefGroup, period: BriefPeriod) -> String? {
        guard let vs = period.comparison, g.prev != nil else { return nil }
        let leads = g.stats.leads > 0
        var parts: [String] = []
        if let p = g.spendChange { parts.append("spend \(pct(p))") }
        if let p = g.costChange { parts.append("cost per \(leads ? "lead" : "result") \(pct(p))") }
        else if let p = g.outcomeChange { parts.append("\(leads ? "leads" : "results") \(pct(p))") }
        guard !parts.isEmpty else { return nil }
        let t = parts.joined(separator: ", ")
        return t.prefix(1).uppercased() + t.dropFirst() + " " + vs + "."
    }
}
