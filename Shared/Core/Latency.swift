import Foundation

// 0.2.11: "track button latency so we see in logs which buttons took more than 100-400 ms over a
// week, at least for the canary (only my account)". The pure part: one action's presses as a mergeable histogram,
// a day of actions, the action id rule, and the upload's shape (lia-agents /agents/telemetry/latency). The
// recorder (the event monitor, the sheet appearances, the daily file and the upload) is App/Shell/LatencyProbe.swift.
// Nothing here runs unless the server says the member is on the canary.

/// One action's presses on one day. Exact count, max and the counts over 100 / 400 ms; the percentiles from fixed
/// buckets (an upper edge, the max for the last one), so two histograms add and the file stays small.
struct LatencyHistogram: Codable, Equatable {
    /// Upper bucket edges in ms; a press of `x` ms falls in the first bucket whose edge is >= x, past the last one in
    /// the overflow bucket.
    static let edges: [Double] = [8, 16, 25, 33, 50, 67, 83, 100, 125, 150, 200, 250, 300, 400, 500, 650, 800, 1000, 1500, 2000, 3000, 5000]
    var counts: [Int] = Array(repeating: 0, count: LatencyHistogram.edges.count + 1)
    var n = 0
    var max: Double = 0
    var over100 = 0
    var over400 = 0

    mutating func add(_ ms: Double) {
        guard ms.isFinite, ms >= 0 else { return }
        let i = Self.edges.firstIndex(where: { ms <= $0 }) ?? Self.edges.count
        if counts.count != Self.edges.count + 1 { counts = Array(repeating: 0, count: Self.edges.count + 1) }
        counts[i] += 1
        n += 1
        if ms > max { max = ms }
        if ms > 100 { over100 += 1 }
        if ms > 400 { over400 += 1 }
    }

    mutating func merge(_ o: LatencyHistogram) {
        guard o.n > 0 else { return }
        if counts.count != o.counts.count { counts = Array(repeating: 0, count: Swift.max(counts.count, o.counts.count)) }
        for i in o.counts.indices { counts[i] += o.counts[i] }
        n += o.n
        max = Swift.max(max, o.max)
        over100 += o.over100
        over400 += o.over400
    }

    /// The `p` (0...1) percentile, read as its bucket's upper edge, never above the max seen.
    func percentile(_ p: Double) -> Double {
        guard n > 0 else { return 0 }
        let rank = Swift.max(1, Int((p * Double(n)).rounded(.up)))
        var seen = 0
        for (i, c) in counts.enumerated() {
            seen += c
            if seen >= rank { return i < Self.edges.count ? Swift.min(Self.edges[i], max) : max }
        }
        return max
    }
}

/// One local day of actions (yyyy-MM-dd), capped in how many ids it keeps: past the cap the presses go to "other".
struct LatencyDay: Codable, Equatable {
    static let maxActions = 250
    static let otherId = "other"
    /// At most this many slow events a day; when full a slower one replaces the fastest kept.
    static let maxEvents = 200
    var day: String
    var actions: [String: LatencyHistogram] = [:]
    /// The day's slow actions one by one (LatencyEvent), at most `maxEvents`, the slowest kept.
    var events: [LatencyEvent] = []

    mutating func add(_ id: String, ms: Double) {
        let key = actions[id] != nil || actions.count < Self.maxActions ? id : Self.otherId
        actions[key, default: LatencyHistogram()].add(ms)
    }

    mutating func merge(_ o: LatencyDay) {
        for (id, h) in o.actions {
            if actions[id] != nil || actions.count < Self.maxActions { actions[id, default: LatencyHistogram()].merge(h) }
            else { actions[Self.otherId, default: LatencyHistogram()].merge(h) }
        }
        for e in o.events { addEvent(e) }
    }

    /// Keeps a slow event: appended while there is room, else it replaces the fastest kept one if it is slower.
    mutating func addEvent(_ e: LatencyEvent) {
        guard e.ms.isFinite, e.ms >= 0 else { return }
        if events.count < Self.maxEvents { events.append(e); return }
        guard let i = events.indices.min(by: { events[$0].ms < events[$1].ms }), events[i].ms < e.ms else { return }
        events[i] = e
    }

    /// The upload's body: {day, client, actions:[{id, n, p50, p95, max, o100, o400}], events:[...]}, the slowest
    /// first, ms rounded. The events go slowest first while the whole body stays under `maxBytes` (the server keeps
    /// 200; a body near 64 KB is the limit agreed for it), so a cut drops the fastest ones.
    func payload(client: String, maxBytes: Int = LatencyEvent.payloadBudget) -> [String: Any] {
        let rows: [[String: Any]] = actions
            .sorted { ($0.value.percentile(0.95), $0.key) > ($1.value.percentile(0.95), $1.key) }
            .map { id, h in
                ["id": id, "n": h.n, "p50": Int(h.percentile(0.5).rounded()), "p95": Int(h.percentile(0.95).rounded()),
                 "max": Int(h.max.rounded()), "o100": h.over100, "o400": h.over400]
            }
        var body: [String: Any] = ["day": day, "client": client, "actions": rows]
        let base = (try? JSONSerialization.data(withJSONObject: body).count) ?? 0
        var room = maxBytes - base - 12   // "events":[]
        var out: [[String: Any]] = []
        for e in events.sorted(by: { ($0.ms, $1.t) > ($1.ms, $0.t) }) {
            let j = e.json
            guard let n = try? JSONSerialization.data(withJSONObject: j).count else { continue }
            if n + 1 > room { break }
            room -= n + 1
            out.append(j)
        }
        body["events"] = out
        return body
    }

    /// The actions that went over `ms` at least once, worst p95 first (for a local look; the server logs the same).
    func slow(over ms: Double = 100) -> [(id: String, h: LatencyHistogram)] {
        actions.filter { $0.value.max > ms }
            .map { (id: $0.key, h: $0.value) }
            .sorted { ($0.h.percentile(0.95), $0.id) > ($1.h.percentile(0.95), $1.id) }
    }
}

extension LatencyDay {
    /// A day file written before the events (0.2.11 up to) has none: decoded with an empty list.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        day = try c.decode(String.self, forKey: .day)
        actions = try c.decodeIfPresent([String: LatencyHistogram].self, forKey: .actions) ?? [:]
        events = try c.decodeIfPresent([LatencyEvent].self, forKey: .events) ?? []
    }
}

// MARK: - slow events

// "For the day, besides the metrics, list the problem cases: in which places, under which conditions and because of
// which factor it happened; tomorrow we compare, and for other users too." Every measured action over its threshold
// is kept as one event: the action id, its time, the phases it split into, the conditions of the app at that moment
// (enumerated, never content: no text, URLs, titles or names) and the factor the classifier below blames. The recorder
// (App/Shell/LatencyProbe.swift) measures and reads the conditions; everything here is pure.

/// The conditions an event happened under. Every value is an enumerated string, a bucket, a small count or a bool.
struct LatencyCtx: Codable, Equatable {
    /// Agent opens: whose conversation (lia / dev / crea / met / other).
    var agent: String?
    /// Agent opens: "kept" (the thread's view was cached from an earlier open) or "cold" (built now).
    var thread: String?
    /// Agent opens: the thread's rows, bucketed (LatencyBucket.rows).
    var rows: String?
    /// The first time this action (and agent) was measured since the app launched.
    var firstSinceLaunch: Bool?
    /// The app's uptime, bucketed: lt60, lt600, ge600.
    var uptime: String?
    /// An agent is working (a run, its browser) at that moment.
    var busy: Bool?
    /// Open browser tabs over the workspace's browsers, bucketed (LatencyBucket.count); tabs loading now; windows.
    var tabs: String?
    var loading: Int?
    var windows: Int?
    var lowPower: Bool?
    /// ProcessInfo.thermalState: nominal / fair / serious / critical.
    var thermal: String?
    /// The app's own phys_footprint, floored to 250 MB (web pages are other processes and not counted).
    var memMb: Int?
    var onBattery: Bool?

    enum CodingKeys: String, CodingKey {
        case agent, thread, rows, busy, tabs, loading, windows, thermal
        case firstSinceLaunch = "first_since_launch", uptime = "uptime_s", lowPower = "low_power", memMb = "mem_mb", onBattery = "on_battery"
    }

    /// The upload's object, short (200 events must fit in the body): what is unknown is left out, and so are the
    /// usual values - a bool that is false, no tab loading, thermal "nominal". Absent reads as false / 0 / nominal.
    var json: [String: Any] {
        var d: [String: Any] = [:]
        if let v = agent { d["agent"] = v }
        if let v = thread { d["thread"] = v }
        if let v = rows { d["rows"] = v }
        if firstSinceLaunch == true { d["first_since_launch"] = true }
        if let v = uptime { d["uptime_s"] = v }
        if busy == true { d["busy"] = true }
        if let v = tabs { d["tabs"] = v }
        if let v = loading, v > 0 { d["loading"] = v }
        if let v = windows { d["windows"] = v }
        if lowPower == true { d["low_power"] = true }
        if let v = thermal, v != "nominal" { d["thermal"] = v }
        if let v = memMb { d["mem_mb"] = v }
        if onBattery == true { d["on_battery"] = true }
        return d
    }
}

/// One slow action. `t`: seconds since the UTC day began. `phases` in ms, whichever apply:
/// queue a click: its event's timestamp -> our handler starting (the main thread was busy before the click)
/// handler a click: our handler's own work
/// render a click: the handler's end -> the main thread free again after the frame was committed
/// sheet / first_frame / settled an agent open, as SEGMENTS: click -> the sheet on screen, the sheet -> the first
/// frame with the thread's rows, the first frame -> settled (AgentOpenTrace; its log lines are cumulative)
/// stall the longest single main-thread block (one run-loop pass) inside the action's window
struct LatencyEvent: Codable, Equatable {
    var id: String
    var ms: Double
    var t: Int
    var phases: [String: Double] = [:]
    var ctx = LatencyCtx()
    var cause = LatencyCause.unknown
    var also: [String] = []

    /// Clicks, `open:*` and `agent_open:*` alike: slower than this is an event.
    static let thresholdMs: Double = 250
    /// The upload body's budget (bytes), events included: under 64 KB.
    static let payloadBudget = 63_000

    static func threshold(_ id: String) -> Double { thresholdMs }
    static func isSlow(_ id: String, ms: Double) -> Bool { ms.isFinite && ms > threshold(id) }

    /// Seconds since the UTC day of `d` began.
    static func secondsOfUTCDay(_ d: Date) -> Int {
        let s = d.timeIntervalSince1970
        return Int((s - (s / 86400).rounded(.down) * 86400).rounded(.down))
    }

    /// Builds the event with its cause (LatencyCause.classify).
    static func make(id: String, ms: Double, at d: Date, phases: [String: Double], ctx: LatencyCtx) -> LatencyEvent {
        let clean = phases.filter { $0.value.isFinite && $0.value >= 0 }
        let c = LatencyCause.classify(id: id, ms: ms, phases: clean, ctx: ctx)
        return LatencyEvent(id: id, ms: ms, t: secondsOfUTCDay(d), phases: clean, ctx: ctx, cause: c.cause, also: c.also)
    }

    /// The upload's object: {id, ms, t, phases, ctx, cause, also}, ms rounded.
    var json: [String: Any] {
        var p: [String: Any] = [:]
        for (k, v) in phases { p[k] = Int(v.rounded()) }
        var d: [String: Any] = ["id": id, "ms": Int(ms.rounded()), "t": t, "phases": p, "ctx": ctx.json, "cause": cause]
        if !also.isEmpty { d["also"] = also }
        return d
    }
}

/// Buckets for the conditions (strings in [a-z0-9_.-], what the server accepts).
enum LatencyBucket {
    static func rows(_ n: Int) -> String {
        n < 20 ? "0-20" : n < 100 ? "20-100" : n < 500 ? "100-500" : "500up"
    }
    static func uptime(_ s: TimeInterval) -> String {
        s < 60 ? "lt60" : s < 600 ? "lt600" : "ge600"
    }
    /// Tabs: 0, 1, 2-5, 6-20, 21up.
    static func count(_ n: Int) -> String {
        n <= 0 ? "0" : n == 1 ? "1" : n <= 5 ? "2-5" : n <= 20 ? "6-20" : "21up"
    }
    /// Megabytes floored to a multiple of 250.
    static func memory(bytes: UInt64) -> Int { Int(bytes / 1_048_576) / 250 * 250 }
    /// The agent of a dialogue id (the roster's ids; "team" and anything custom are "other").
    static func agent(_ dlg: String?) -> String {
        let a = (dlg ?? "").lowercased()
        return ["lia", "dev", "crea", "met"].contains(a) ? a : "other"
    }
}

/// The main thread's long blocks: each run-loop pass from waking to going to sleep that took at least `minSpan`, the
/// last `capacity` of them (the recorder's CFRunLoopObserver feeds it; a pass still running is `open`).
struct LatencySpans: Equatable {
    struct Span: Equatable { var start: TimeInterval; var end: TimeInterval }
    static let capacity = 128
    static let minSpan: TimeInterval = 0.016
    private(set) var spans: [Span] = []

    mutating func add(start: TimeInterval, end: TimeInterval) {
        guard end - start >= Self.minSpan else { return }
        spans.append(Span(start: start, end: end))
        if spans.count > Self.capacity { spans.removeFirst(spans.count - Self.capacity) }
    }

    /// The longest block's part inside [from, to] in ms; `open` is the pass running now (since that time, up to `to`).
    func longest(from: TimeInterval, to: TimeInterval, open: TimeInterval? = nil) -> Double {
        guard to > from else { return 0 }
        var best: TimeInterval = 0
        for s in spans where s.end > from && s.start < to { best = max(best, min(s.end, to) - max(s.start, from)) }
        if let o = open, o < to { best = max(best, to - max(o, from)) }
        return best * 1000
    }
}

/// The factor an event is blamed on: one `cause` and up to two more (`also`).
///
/// The rules, in order:
///  1. Each phase is a factor with its milliseconds: queue -> queue_wait, handler -> handler_work, render -> render,
/// sheet -> sheet_build, first_frame -> cold_thread_layout when the thread was cold, else many_rows when it had 100
/// rows or more, else render; settled -> many_rows with 100 rows or more, else render. (`stall` is not a phase:
/// it overlaps them.)
///  2. The largest phase factor is the cause when it holds at least half of the event's ms.
///  3. Else a single main-thread block (`stall`) of at least half the ms is the cause: main_stall.
///  4. Else the first condition that holds, in this order: thermal (serious or critical), low_power, memory (the app
/// at 1500 MB or more), first_open_after_launch, busy_agent, page_loading (a tab loading), many_rows (500 rows or
/// more, when no phase said so).
///  5. Else the largest phase factor, however small its share; with no phases at all: unknown.
///  `also` (two at most, never the cause, no repeats): the other phase factors holding a quarter of the ms or more
///  (largest first), then main_stall when its block is half the ms or more, then the conditions of rule 4 that hold.
enum LatencyCause {
    static let queueWait = "queue_wait", mainStall = "main_stall", coldThreadLayout = "cold_thread_layout"
    static let manyRows = "many_rows", sheetBuild = "sheet_build", handlerWork = "handler_work", render = "render"
    static let firstOpen = "first_open_after_launch", thermal = "thermal", lowPower = "low_power", memory = "memory"
    static let busyAgent = "busy_agent", pageLoading = "page_loading", unknown = "unknown"
    static let all: [String] = [queueWait, mainStall, coldThreadLayout, manyRows, sheetBuild, handlerWork, render,
                                firstOpen, thermal, lowPower, memory, busyAgent, pageLoading, unknown]
    static let memoryMb = 1500

    private static func rowsAtLeast100(_ r: String?) -> Bool { r == "100-500" || r == "500up" }

    /// Rule 1: the phase factors with their ms, largest first (ties by name, so the result is stable).
    static func phaseFactors(_ phases: [String: Double], ctx: LatencyCtx) -> [(String, Double)] {
        var w: [String: Double] = [:]
        func add(_ f: String, _ v: Double?) { if let v, v > 0 { w[f, default: 0] += v } }
        add(queueWait, phases["queue"])
        add(handlerWork, phases["handler"])
        add(render, phases["render"])
        add(sheetBuild, phases["sheet"])
        if let f = phases["first_frame"] {
            add(ctx.thread == "cold" ? coldThreadLayout : rowsAtLeast100(ctx.rows) ? manyRows : render, f)
        }
        if let s = phases["settled"] { add(rowsAtLeast100(ctx.rows) ? manyRows : render, s) }
        return w.sorted { ($0.value, $1.key) > ($1.value, $0.key) }.map { ($0.key, $0.value) }
    }

    /// Rule 4: the conditions that hold, in priority order.
    static func conditions(_ ctx: LatencyCtx, phaseSaidRows: Bool) -> [String] {
        var out: [String] = []
        if ctx.thermal == "serious" || ctx.thermal == "critical" { out.append(thermal) }
        if ctx.lowPower == true { out.append(lowPower) }
        if let m = ctx.memMb, m >= memoryMb { out.append(memory) }
        if ctx.firstSinceLaunch == true { out.append(firstOpen) }
        if ctx.busy == true { out.append(busyAgent) }
        if let l = ctx.loading, l > 0 { out.append(pageLoading) }
        if ctx.rows == "500up" && !phaseSaidRows { out.append(manyRows) }
        return out
    }

    static func classify(id: String, ms: Double, phases: [String: Double], ctx: LatencyCtx) -> (cause: String, also: [String]) {
        let total = max(ms, 1)
        let factors = phaseFactors(phases, ctx: ctx)
        let stall = phases["stall"] ?? 0
        let stalled = stall >= total * 0.5
        let conds = conditions(ctx, phaseSaidRows: factors.contains { $0.0 == manyRows })
        let cause: String
        if let top = factors.first, top.1 >= total * 0.5 { cause = top.0 }
        else if stalled { cause = mainStall }
        else if let c = conds.first { cause = c }
        else if let top = factors.first { cause = top.0 }
        else { cause = unknown }
        var also: [String] = []
        func push(_ f: String) { if also.count < 2, f != cause, !also.contains(f) { also.append(f) } }
        for f in factors where f.1 >= total * 0.25 { push(f.0) }
        if stalled { push(mainStall) }
        for c in conds { push(c) }
        return (cause, also)
    }
}

enum LatencyID {
    /// An action id from a button's accessibility identifier or label: letters, digits, space and. _: / # - ' & +
    /// only, runs of digits become "#" (a count in a label must not split one button into a hundred ids), spaces
    /// collapsed, 64 characters at most. nil for nothing usable or anything that looks like an email or an address.
    static func clean(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.isEmpty || s.contains("@") || s.lowercased().contains("http") || s.contains("://") { return nil }
        var out = ""
        var lastSpace = false, lastDigit = false
        for ch in s {
            if ch.isASCII && ch.isNumber {
                if !lastDigit { out.append("#") }
                lastDigit = true; lastSpace = false
                continue
            }
            lastDigit = false
            if ch == " " || ch == "\n" || ch == "\t" {
                if !lastSpace && !out.isEmpty { out.append(" ") }
                lastSpace = true
                continue
            }
            lastSpace = false
            if (ch.isASCII && (ch.isLetter)) || ".:_/#-'&+".contains(ch) { out.append(ch) }
            else if ch == "\u{2019}" { out.append("'") }
            else if ch == "\u{2026}" { out.append("...") }
        }
        let t = String(out.trimmingCharacters(in: .whitespaces).prefix(64)).trimmingCharacters(in: .whitespaces)
        return t.isEmpty || t.allSatisfy({ $0 == "#" || $0 == " " }) ? nil : t
    }
}

enum LatencyUpload {
    /// The finished days to send: stored, before today, not sent yet, the most recent `limit` (the server keeps 30
    /// days and refuses older than 31), oldest first.
    static func due(stored: [String], uploaded: Set<String>, today: String, limit: Int = 7) -> [String] {
        Array(stored.filter { $0 < today && !uploaded.contains($0) && LiaDay.valid($0) }.sorted().suffix(limit))
    }

    /// Today's opens never reached the server (only a finished day went). Today's aggregate so far
    /// goes too, when the app goes to the background and every `every` seconds while it runs, if anything was recorded
    /// since the last send. The server keeps one record per member and day and a re-send replaces it with the newer
    /// aggregate (lia-telemetry.js latencyApi: `kv.put` of the whole day), so a partial day is safe to send again and
    /// the finished day's own upload (`due`) still sends the complete one. A partial send never marks the day sent.
    static let partialEvery: TimeInterval = 30 * 60

    /// Whether today's partial aggregate goes now: something new since the last send (`recordedSince`), and either the
    /// app is going to the background (`leaving`) or `every` has passed since the last send (never sent: now).
    static func partialDue(recordedSince: Bool, leaving: Bool, lastSent: TimeInterval?, now: TimeInterval,
                           every: TimeInterval = LatencyUpload.partialEvery) -> Bool {
        guard recordedSince else { return false }
        if leaving { return true }
        guard let t = lastSent else { return true }
        return now - t >= every
    }

    /// GET /agents/telemetry/latency -> on (false for anything else).
    static func isOn(_ data: Data) -> Bool {
        JSONRead.bool(JSONRead.object(data), "ok") && JSONRead.bool(JSONRead.object(data), "on")
    }
}

/// Local calendar days as yyyy-MM-dd (what the latency and Screen Time files are keyed by).
enum LiaDay {
    static func key(_ d: Date, calendar: Calendar = .current) -> String {
        let c = calendar.dateComponents([.year, .month, .day], from: d)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }

    static func valid(_ s: String) -> Bool {
        let p = s.split(separator: "-")
        return s.count == 10 && p.count == 3 && p[0].count == 4 && p[1].count == 2 && p[2].count == 2 && p.allSatisfy { $0.allSatisfy(\.isNumber) }
    }

    /// The day `n` days before `d` (0 = d's own day).
    static func key(daysBefore n: Int, _ d: Date, calendar: Calendar = .current) -> String {
        key(calendar.date(byAdding: .day, value: -n, to: calendar.startOfDay(for: d)) ?? d, calendar: calendar)
    }
}
