import Foundation

// The pure pieces of Home, the welcome and the tips: the person's role, one ad account's numbers
// (the sums are in BriefPeriod.swift), when tips may show, how the welcome's team row fits, and the repository rows' text.

// MARK: - the role

/// The person's role, saved in `Prefs.role` ("lia_role") on this Mac only; it shapes the quick tasks. The raw values
/// are stored, so they never change: `marketer`, `agency`, `owner` as before, `developer` new.
/// Designers are folded into Developer (its line says so) and studios into Agency; there is no separate Designer.
enum LiaRole: String, CaseIterable, Identifiable {
    case developer, marketer, agency, owner
    var id: String { rawValue }

    var title: String {
        switch self {
        case .developer: return "Developer"
        case .marketer: return "Marketer"
        case .agency: return "Agency or studio"
        case .owner: return "Founder or freelancer"
        }
    }
    var line: String {
        switch self {
        case .developer: return "I build or design sites and apps."
        case .marketer: return "I run ads and watch the numbers every day."
        case .agency: return "I work for clients: ads, sites or design."
        case .owner: return "I run my own business or work for myself."
        }
    }
    var symbol: String {
        switch self {
        case .developer: return "chevron.left.forwardslash.chevron.right"
        case .marketer: return "chart.line.uptrend.xyaxis"
        case .agency: return "person.3"
        case .owner: return "storefront"
        }
    }

    /// A stored value back to a role; unknown or empty: none.
    static func stored(_ raw: String?) -> LiaRole? {
        guard let r = raw?.trimmingCharacters(in: .whitespaces).lowercased(), !r.isEmpty else { return nil }
        return LiaRole(rawValue: r)
    }

    /// Whether the welcome offers GitHub before Meta.
    var githubFirst: Bool { self == .developer }
}

// MARK: - yesterday's numbers

/// get_account_stats {account, from, to} -> {ok, kpi: {spend, impressions, clicks, leads, ctr, cpl}, ov: {results, purchases, ...}, currency}.
struct TourStats: Codable, Equatable {
    var spend: Double
    var leads: Double
    var results: Double
    var cpl: Double?
    var currency: String?

    /// What the account buys: leads first, else other results (purchases, conversions).
    var outcome: Double { leads > 0 ? leads : results }
    var costPer: Double? {
        if leads > 0, let c = cpl, c > 0 { return c }
        return outcome > 0 ? spend / outcome : nil
    }

    static func parse(_ data: Data?) -> TourStats? {
        guard let data, let o = JSONRead.object(data) else { return nil }
        if o["ok"] as? Bool == false { return nil }
        let kpi = o["kpi"] as? JSONObject ?? o
        let ov = o["ov"] as? JSONObject
        guard let spend = JSONRead.double(kpi, "spend") else { return nil }
        let leads = JSONRead.double(kpi, "leads") ?? JSONRead.double(ov, "leads") ?? 0
        let results = max(JSONRead.double(ov, "results") ?? 0, JSONRead.double(ov, "purchases") ?? 0)
        return TourStats(spend: spend, leads: leads, results: results, cpl: JSONRead.double(kpi, "cpl"),
                         currency: JSONRead.string(o, "currency") ?? JSONRead.string(ov, "currency"))
    }

    func money(_ v: Double) -> String {
        let f = NumberFormatter()
        f.numberStyle = .currency
        f.currencyCode = currency ?? "EUR"
        f.maximumFractionDigits = v >= 100 ? 0 : 2
        return f.string(from: NSNumber(value: v)) ?? String(format: "%.2f", v)
    }
}

// The brief's periods, sums per currency and sentence: BriefPeriod.swift.

// MARK: - tips

/// When the little tips (TipKit popovers, the tip of the week) may show: after the welcome, and after the first
/// morning tour has been seen (or the tour is off), never while a tour runs.
enum TipGate {
    static func open(onboarded: Bool, touring: Bool, tourEnabled: Bool, tourSeen: Bool) -> Bool {
        onboarded && !touring && (tourSeen || !tourEnabled)
    }
}

// MARK: - the welcome's team row

enum TeamRowFit {
    /// The cell width and the gap for `count` agents in `width`: the preferred sizes when they fit, then a smaller gap,
    /// then smaller cells. The row is always centred by its parent.
    static func fit(count: Int, width: Double, cell: Double = 76, spacing: Double = 14,
                    minCell: Double = 52, minSpacing: Double = 6) -> (cell: Double, spacing: Double) {
        guard count > 1 else { return (cell, spacing) }
        let n = Double(count)
        if n * cell + (n - 1) * spacing <= width { return (cell, spacing) }
        let gap = max(minSpacing, (width - n * cell) / (n - 1))
        if n * cell + (n - 1) * gap <= width { return (cell, gap.rounded(.down)) }
        let c = max(minCell, (width - (n - 1) * minSpacing) / n)
        return (c.rounded(.down), minSpacing)
    }
}

// MARK: - the repository rows

enum RepoRowText {
    static let noCommits = "No commits yet"

    /// The left column's second line: the last commit's message, the same slot for every row.
    static func commitLine(_ r: RepoActivity, limit: Int = 90) -> String {
        guard let c = r.lastCommit else { return noCommits }
        let m = c.message.trimmingCharacters(in: .whitespacesAndNewlines)
        if m.isEmpty { return c.at == nil ? noCommits : "No message" }
        return clip(m, limit)
    }

    /// The open-PR badge's text; nil at 0 (the slot stays, empty).
    static func prBadge(_ n: Int) -> String? {
        n <= 0 ? nil : n > 99 ? "99+" : "\(n)"
    }

    /// "3 · 12" (7 days · 30 days), capped so the column's width holds.
    static func counts(_ r: RepoActivity) -> String {
        func cap(_ n: Int) -> String { n > 999 ? "999+" : "\(n)" }
        return cap(r.commits7d) + " \u{00b7} " + cap(r.commits30d)
    }

    /// At most `n` characters, the last one an ellipsis when cut (single line: newlines become spaces).
    static func clip(_ s: String, _ n: Int) -> String {
        let one = s.replacingOccurrences(of: "\n", with: " ")
        guard n > 1, one.count > n else { return one }
        return String(one.prefix(n - 1)).trimmingCharacters(in: .whitespaces) + "\u{2026}"
    }
}

/// The morning tour's GitHub step ("add a tip if GitHub is connected, or highlight the workspace and
/// talk about GitHub, the same as about Meta"). Connected: Dev and this workspace's repositories (the repositories on
/// Home, else the workspace chip); connected with no repositories picked: where to pick them; not connected: the
/// workspace chip and a Connect button. Unknown (status not read yet, no repositories): no step until it is read.
enum TourGitHub {
    enum Kind: Equatable { case repos, pick, connect }

    static func kind(connected: Bool?, repos: Int) -> Kind? {
        if connected == false { return .connect }
        if repos > 0 { return .repos }
        return connected == true ? .pick : nil
    }

    /// Where the spotlight goes, first on screen wins.
    static func anchors(_ k: Kind) -> [String] {
        k == .repos ? ["repos", "workspaces", "tabs"] : ["workspaces", "tabs"]
    }

    static func title(_ k: Kind) -> String {
        switch k {
        case .repos: return "Dev and your code"
        case .pick: return "Pick repositories"
        case .connect: return "Connect GitHub"
        }
    }

    /// `names`: the workspace's repositories ("owner/name"), in its order; `dev`: the developer agent's name.
    static func text(_ k: Kind, names: [String], dev: String = "Dev") -> String {
        switch k {
        case .repos:
            return "\(dev) works in \(list(names)) for this workspace. Type @\(dev) and a task to change the code."
        case .pick:
            return "GitHub is connected. Pick this workspace\u{2019}s repositories in Workspace Settings so \(dev) can work in them."
        case .connect:
            return "Connect GitHub and \(dev) can work in your code. Later: the workspace chip \u{2192} Workspace Settings."
        }
    }

    static func actionLabel(_ k: Kind) -> String? {
        switch k {
        case .repos: return nil
        case .pick: return "Open"
        case .connect: return "Connect"
        }
    }

    /// "site", "site and api", "site, api and 3 more" (short names; the owner is dropped).
    static func list(_ names: [String]) -> String {
        let short = names.map { n -> String in
            let s = n.split(separator: "/").last.map(String.init) ?? n
            return s.isEmpty ? n : s
        }
        switch short.count {
        case 0: return "your repositories"
        case 1: return short[0]
        case 2: return short[0] + " and " + short[1]
        default: return short[0] + ", " + short[1] + " and \(short.count - 2) more"
        }
    }
}
