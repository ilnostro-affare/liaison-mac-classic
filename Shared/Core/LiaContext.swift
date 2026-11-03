import Foundation

// Server: Lia, the person's main assistant, quietly knows what the person does, so she can
// see and offer tasks ("you spent 2 h in Ads Manager on Acme - want a summary of what changed?"). With every turn
// to Lia the Mac sends `context`: a Screen Time summary of about the last 24 hours (top sites, agents and parts of
// Liaison, in whole minutes) and the open tabs of the workspace's main browser (title and host only: never a path,
// a query or a page's text; private windows are not a workspace browser and never read; new-tab pages and non-web
// tabs are left out). The server puts only a short summary into Lia's turn (front tab, top three, the quarter hour)
// and serves the rest through her read-only tool my_activity, so the prompt cache is untouched. Only to Lia; never when the person turned "Lia uses Screen Time and open tabs" off
// (Settings > Screen Time). The pure shaping and caps are here, tested on Linux; the reading is
// App/Workspace/LiaContextMac.swift.

enum LiaContext {
    static let onKey = "lia_context_on"
    static let topCap = 12
    static let tabsCap = 20
    static let titleCap = 80
    /// The Screen Time part is computed at most once per this many seconds (per workspace).
    static let cacheSeconds: TimeInterval = 300

    /// On unless the person turned it off.
    static func isOn(_ d: UserDefaults = .standard) -> Bool { d.object(forKey: onKey) as? Bool ?? true }

    struct Item: Equatable {
        /// "site" (a registrable domain), "feature" (a part of Liaison: home, chats, notes, settings, browser) or
        /// "agent" (the conversation open: an agent id or "team").
        let kind: String
        let name: String
        let minutes: Int
    }

    struct ScreenTime: Equatable {
        var top: [Item] = []
        var totalMinutes: Int = 0

        /// Per day, oldest first (the 7-day rollup only).
        var days: [(day: String, minutes: Int)] = []

        func json(period: String) -> JSONObject {
            var j: JSONObject = ["period": period, "total_minutes": totalMinutes,
                                 "top": top.map { ["kind": $0.kind, "name": $0.name, "minutes": $0.minutes] as JSONObject }]
            if !days.isEmpty { j["days"] = days.map { ["day": $0.day, "minutes": $0.minutes] as JSONObject } }
            return j
        }
        var json: JSONObject { json(period: "24h") }

        static func == (a: ScreenTime, b: ScreenTime) -> Bool {
            a.top == b.top && a.totalMinutes == b.totalMinutes && a.days.map(\.day) == b.days.map(\.day)
                && a.days.map(\.minutes) == b.days.map(\.minutes)
        }
    }

    /// The `screen_time` object: about the last 24 hours at the top level (what Lia's short summary is made from),
    /// with `today` and `week` (the last 7 days, a bar per day) for the details she asks for (server tool my_activity).
    struct Rollup: Equatable {
        var last24h = ScreenTime()
        var today = ScreenTime()
        var week = ScreenTime()

        var json: JSONObject {
            var j = last24h.json(period: "24h")
            j["today"] = today.json(period: "today")
            j["week"] = week.json(period: "7d")
            return j
        }
    }

    static func rollup(_ ledger: ScreenTimeLedger, now: Date, calendar: Calendar = .current) -> Rollup {
        Rollup(last24h: screenTime(ledger, now: now, calendar: calendar),
               today: range(ledger, .today, now: now, calendar: calendar),
               week: range(ledger, .week, now: now, calendar: calendar))
    }

    /// Today or the last 7 days, from the ledger's own summary.
    static func range(_ ledger: ScreenTimeLedger, _ r: ScreenTimeLedger.Range, now: Date, calendar: Calendar = .current) -> ScreenTime {
        let s = ledger.summary(r, now: now, calendar: calendar)
        var rows: [(String, String, Double)] = []
        rows += s.sites.map { ("site", $0.id, $0.seconds) }
        rows += s.features.map { ("feature", $0.id, $0.seconds) }
        rows += s.agents.map { ("agent", $0.id, $0.seconds) }
        var st = ScreenTime(top: items(rows), totalMinutes: max(0, Int((s.total / 60).rounded())))
        if r == .week { st.days = s.perDay.map { ($0.day, Int(($0.seconds / 60).rounded())) } }
        return st
    }

    private static func items(_ rows: [(String, String, Double)]) -> [Item] {
        let all = rows.compactMap { r -> Item? in
            let name = cleanName(r.1)
            let m = Int((r.2 / 60).rounded())
            return name.isEmpty || m < 1 ? nil : Item(kind: r.0, name: name, minutes: m)
        }
        .sorted { $0.minutes != $1.minutes ? $0.minutes > $1.minutes : ($0.kind, $0.name) < ($1.kind, $1.name) }
        return Array(all.prefix(topCap))
    }

    /// About the last 24 hours from a per-day ledger: today in full plus the share of yesterday that falls inside
    /// the window (yesterday's time spread evenly over its day - the ledger keeps days, not hours). Rows under half
    /// a minute are dropped; the longest `topCap` rows of any kind, longest first.
    static func screenTime(_ ledger: ScreenTimeLedger, now: Date, calendar: Calendar = .current) -> ScreenTime {
        let todayKey = LiaDay.key(now, calendar: calendar)
        let yKey = LiaDay.key(daysBefore: 1, now, calendar: calendar)
        let elapsed = now.timeIntervalSince(calendar.startOfDay(for: now))
        let yShare = max(0, min(1, (86_400 - elapsed) / 86_400))
        var sites: [String: Double] = [:], agents: [String: Double] = [:], features: [String: Double] = [:]
        for (key, w) in [(todayKey, 1.0), (yKey, yShare)] where w > 0 {
            guard let d = ledger.days[key] else { continue }
            for (k, v) in d.sites { sites[k, default: 0] += v * w }
            for (k, v) in d.agents { agents[k, default: 0] += v * w }
            for (k, v) in d.features { features[k, default: 0] += v * w }
        }
        var rows: [(String, String, Double)] = []
        for (k, v) in sites { rows.append(("site", k, v)) }
        for (k, v) in features { rows.append(("feature", k, v)) }
        for (k, v) in agents { rows.append(("agent", k, v)) }
        let total = Int((features.values.reduce(0, +) / 60).rounded())
        return ScreenTime(top: items(rows), totalMinutes: max(0, total))
    }

    /// A name as sent: lowercased letters, digits, dots, dashes and underscores, at most 64 characters.
    static func cleanName(_ s: String) -> String {
        let ok = s.lowercased().unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) || ".-_".unicodeScalars.contains($0) }
        return String(String(ok).prefix(64))
    }

    struct TabIn {
        let title: String
        let url: URL?
        var isStart = false
        var isPrivate = false
        /// The browser's selected tab (what the person is looking at in it).
        var front = false
    }

    struct Tab: Equatable {
        let title: String
        let host: String
        var front = false
    }

    /// The tabs as sent: web tabs only (no new-tab page, no file / about: / data: page, no private tab), the host
    /// alone (lowercased, no "www.", no port, never a path or a query), the title trimmed to one line of at most
    /// `titleCap` characters (the host when there is none), at most `tabsCap`: the front tab first (marked, kept
    /// ahead of the cap), then the others in the browser's order.
    static func tabs(_ input: [TabIn]) -> [Tab] {
        var out: [Tab] = []
        let fi = input.firstIndex { $0.front }
        let ordered = fi.map { [input[$0]] + input.enumerated().filter { $0.offset != fi }.map(\.element) } ?? input
        for t in ordered where !t.isStart && !t.isPrivate {
            guard let u = t.url, let scheme = u.scheme?.lowercased(), scheme == "http" || scheme == "https",
                  var host = u.host?.lowercased(), !host.isEmpty else { continue }
            if host.hasPrefix("www.") { host.removeFirst(4) }
            var title = t.title.replacingOccurrences(of: "\n", with: " ").replacingOccurrences(of: "\r", with: " ")
                .replacingOccurrences(of: "\t", with: " ").trimmingCharacters(in: .whitespaces)
            while title.contains("  ") { title = title.replacingOccurrences(of: "  ", with: " ") }
            if title.isEmpty { title = host }
            if title.count > titleCap { title = String(title.prefix(titleCap - 1)).trimmingCharacters(in: .whitespaces) + "\u{2026}" }
            out.append(Tab(title: title, host: host, front: t.front && !out.contains { $0.front }))
            if out.count >= tabsCap { break }
        }
        return out
    }

    /// " 14:05" in the Mac's time zone, and the weekday in English.
    static func localTime(_ now: Date, timeZone: TimeZone = .current) -> (time: String, weekday: String) {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = timeZone
        f.dateFormat = "yyyy-MM-dd HH:mm"
        let t = f.string(from: now)
        f.dateFormat = "EEEE"
        return (t, f.string(from: now))
    }

    /// The `context` object of POST /agents/turn (to Lia only).
    static func payload(screenTime: Rollup, tabs: [Tab], now: Date, timeZone: TimeZone = .current) -> JSONObject {
        let lt = localTime(now, timeZone: timeZone)
        return ["screen_time": screenTime.json,
                "tabs": tabs.map { t -> JSONObject in
                    var j: JSONObject = ["title": t.title, "host": t.host]
                    if t.front { j["front"] = true }
                    return j
                },
                "local_time": lt.time, "weekday": lt.weekday]
    }

    /// The turn goes to Lia: the agent named for it, else the dialogue's own agent.
    static func forLia(agent: String?, dialogueAgent: String) -> Bool { (agent ?? dialogueAgent) == "lia" }

    /// A cached Screen Time part is still good.
    static func fresh(at: Date?, now: Date) -> Bool {
        guard let at else { return false }
        let age = now.timeIntervalSince(at)
        return age >= 0 && age < cacheSeconds
    }
}
