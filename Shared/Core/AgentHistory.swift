import Foundation

// "What did <Agent> do?" read like a log (batches, raw steps) and was gone after the task. Here:
// each task an agent did in its own browser is one record (title, time, outcome) with a few short human steps
// ("Opened Ryanair", "Picked dates", "Chose «Rome»"), kept per workspace and agent on this Mac (200 tasks at most),
// grouped Today / Yesterday / earlier dates. Pure, so it is tested on Linux; the store and the view are the app's.

/// How a task ended. `waiting`: a change is prepared and waits for the person's Yes (Ads Manager runs).
enum AgentTaskOutcome: String, Codable, Equatable {
    case running, done, failed, stopped, waiting, declined

    var label: String {
        switch self {
        case .running: return "Working"
        case .done: return "Done"
        case .failed: return "Not finished"
        case .stopped: return "Stopped"
        case .waiting: return "Waiting for you"
        case .declined: return "Declined"
        }
    }
}

/// One human step. `kind` decides how a step merges with the one before it (two dates are "Picked dates").
struct AgentTaskStep: Codable, Equatable {
    var at: Date
    var text: String
    var kind: String
}

struct AgentTaskRecord: Codable, Equatable, Identifiable {
    var id: String
    var agent: String
    var title: String
    var started: Date
    var ended: Date?
    var outcome: AgentTaskOutcome
    /// What the agent reported at the end (or why it stopped), short.
    var summary: String = ""
    var steps: [AgentTaskStep] = []
    /// ("Go to"): the dialogue the task was given in ("profile|dlg"), nil outside one.
    var dialogue: String? = nil
    /// The agent's message that reported the task there, once found (resolved lazily, then kept).
    var resultId: String? = nil

    static let maxSteps = 40

    /// "Go to" has somewhere to go: a dialogue, and a task that ended.
    var canGoTo: Bool { dialogue != nil && ended != nil }

    init(id: String, agent: String, title: String, started: Date, outcome: AgentTaskOutcome = .running) {
        self.id = id
        self.agent = agent
        self.title = AgentStepPhrase.clip(title, 90)
        self.started = started
        self.outcome = outcome
    }

    /// A step, merged with the last one when it says the same thing again (three scrolls are one "Looked through
    /// the page"; two dates are "Picked dates"; a second field is "Filled in the form").
    mutating func add(_ p: AgentStepPhrase.Phrase, at: Date) {
        if var last = steps.last, last.kind == p.kind, let merged = AgentStepPhrase.merge(last.text, p) {
            last.text = merged
            last.at = at
            steps[steps.count - 1] = last
            return
        }
        steps.append(AgentTaskStep(at: at, text: p.text, kind: p.kind))
        if steps.count > Self.maxSteps { steps.removeFirst(steps.count - Self.maxSteps) }
    }

    mutating func end(_ outcome: AgentTaskOutcome, summary: String, at: Date) {
        self.outcome = outcome
        self.summary = AgentStepPhrase.clip(summary, 400)
        ended = at
    }

    /// "4 min", "35 s": how long it took (nil while it runs).
    var duration: String? {
        guard let ended else { return nil }
        let s = max(0, Int(ended.timeIntervalSince(started).rounded()))
        if s < 60 { return "\(s) s" }
        if s < 3600 { return "\(s / 60) min" }
        return "\(s / 3600) h \(s % 3600 / 60) min"
    }
}

/// An agent's tasks in one workspace, newest last, at most `cap`.
struct AgentHistoryLog: Codable, Equatable {
    var tasks: [AgentTaskRecord] = []
    static let cap = 200

    mutating func upsert(_ t: AgentTaskRecord) {
        if let i = tasks.firstIndex(where: { $0.id == t.id }) { tasks[i] = t } else { tasks.append(t) }
        if tasks.count > Self.cap { tasks.removeFirst(tasks.count - Self.cap) }
    }

    /// A task left running by a quit or a crash is not running any more.
    mutating func closeStale(at: Date) {
        for i in tasks.indices where tasks[i].outcome == .running {
            tasks[i].end(.stopped, summary: tasks[i].summary.isEmpty ? "Interrupted" : tasks[i].summary, at: tasks[i].steps.last?.at ?? at)
        }
    }

    func encoded() -> Data? {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .secondsSince1970
        return try? e.encode(self)
    }

    static func decode(_ d: Data) -> AgentHistoryLog? {
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .secondsSince1970
        return try? dec.decode(AgentHistoryLog.self, from: d)
    }

    /// The file name for a "workspace|agent" key: letters, digits, - and _ only.
    static func fileName(_ key: String) -> String {
        let safe = String(key.map { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" ? $0 : "_" }.prefix(120))
        return (safe.isEmpty ? "_" : safe) + ".json"
    }
}

/// A task card's "Go to" opens the dialogue at the agent's message that reported the task.
enum AgentTaskLink {
    /// A message that may be the report: the server's id and order, its time, who wrote it.
    struct Candidate: Equatable {
        let id: String
        let seq: Int
        let ts: Date?
        /// The agent who wrote it; nil for the person's own or a machine message.
        let agent: String?
    }

    /// "dlg:<profile>:<dlg>" (TeamChatModel.sessionId) -> "<profile>|<dlg>"; nil for anything else (a chat's id).
    static func dialogueKey(session: String?) -> String? {
        guard let s = session, s.hasPrefix("dlg:") else { return nil }
        let rest = s.dropFirst(4)
        guard let i = rest.lastIndex(of: ":") else { return nil }
        let p = rest[..<i], d = rest[rest.index(after: i)...]
        guard !p.isEmpty, !d.isEmpty else { return nil }
        return String(p) + "|" + String(d)
    }

    static func split(_ key: String) -> (profile: String, dlg: String)? {
        let parts = key.split(separator: "|", maxSplits: 1).map(String.init)
        guard parts.count == 2, !parts[0].isEmpty, !parts[1].isEmpty else { return nil }
        return (parts[0], parts[1])
    }

    /// The first agent message at or after the task's end (a few seconds of clock slack), the task's own agent first;
    /// only stored messages (a local "l-" copy has no id to come back to); a message without a time is not one.
    static func result(_ c: [Candidate], ended: Date, agent: String, slack: TimeInterval = 3) -> String? {
        let after = c.filter { $0.agent != nil && !$0.id.hasPrefix("l-") && ($0.ts.map { $0 >= ended.addingTimeInterval(-slack) } ?? false) }
            .sorted { $0.seq != $1.seq ? $0.seq < $1.seq : ($0.ts ?? .distantFuture) < ($1.ts ?? .distantFuture) }
        return (after.first { $0.agent == agent } ?? after.first)?.id
    }
}

/// Tasks by day for the history list: Today, Yesterday, then "Mon, 12 Oct" (newest first, inside a day too).
enum AgentHistoryDays {
    struct Group: Equatable { let title: String; let tasks: [AgentTaskRecord] }

    static func groups(_ tasks: [AgentTaskRecord], now: Date, calendar: Calendar = .current) -> [Group] {
        var order: [Date] = []
        var byDay: [Date: [AgentTaskRecord]] = [:]
        for t in tasks.sorted(by: { $0.started > $1.started }) {
            let d = calendar.startOfDay(for: t.started)
            if byDay[d] == nil { order.append(d) }
            byDay[d, default: []].append(t)
        }
        let today = calendar.startOfDay(for: now)
        let fmt = DateFormatter()
        fmt.calendar = calendar
        fmt.timeZone = calendar.timeZone
        fmt.locale = Locale(identifier: "en_US_POSIX")
        return order.map { d in
            let title: String
            if d == today { title = "Today" }
            else if let y = calendar.date(byAdding: .day, value: -1, to: today), d == y { title = "Yesterday" }
            else {
                fmt.dateFormat = calendar.component(.year, from: d) == calendar.component(.year, from: today) ? "EEE, d MMM" : "d MMM yyyy"
                title = fmt.string(from: d)
            }
            return Group(title: title, tasks: byDay[d] ?? [])
        }
    }
}

/// A web action, or an overlay beat, as a short past-tense step a person reads.
enum AgentStepPhrase {
    struct Phrase: Equatable { let text: String; let kind: String }

    static func clip(_ s: String, _ n: Int) -> String {
        let t = s.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        return t.count > n ? String(t.prefix(n - 1)) + "\u{2026}" : t
    }

    /// "www.ryanair.com" -> "Ryanair", "flights.google.com" -> "Google Flights", "booking.com" -> "Booking".
    static func site(_ url: URL?) -> String {
        guard var h = url?.host?.lowercased(), !h.isEmpty else { return "the page" }
        for p in ["www.", "m.", "en.", "www2."] where h.hasPrefix(p) { h = String(h.dropFirst(p.count)) }
        if let known = known[h] { return known }
        var parts = h.split(separator: ".").map(String.init)
        guard parts.count >= 2 else { return cap(h) }
        // co.uk, com.au ...: the name is the part before them
        let second: Set<String> = ["co", "com", "net", "org", "gov", "ac"]
        if parts.count >= 3, second.contains(parts[parts.count - 2]) { parts.removeLast() }
        parts.removeLast()
        let name = parts.last ?? h
        if parts.count >= 2 {
            let sub = parts[parts.count - 2]
            if !["www", "app", "secure", "my", "accounts", "login"].contains(sub) { return cap(name) + " " + cap(sub) }
        }
        return cap(name)
    }

    private static let known: [String: String] = [
        "adsmanager.facebook.com": "Ads Manager", "business.facebook.com": "Meta Business Suite",
        "facebook.com": "Facebook", "ads.google.com": "Google Ads", "google.com": "Google",
    ]

    private static func cap(_ s: String) -> String { s.prefix(1).uppercased() + s.dropFirst() }

    private static let months = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]

    /// The control's name in a page snapshot ("[k3f] button «Search»" -> "Search").
    static func controlName(_ id: String, in snapshot: String?) -> String? {
        guard let snapshot, !id.isEmpty, let r = snapshot.range(of: "\n[" + id + "]") ?? (snapshot.hasPrefix("[" + id + "]") ? snapshot.range(of: "[" + id + "]") : nil) else { return nil }
        let line = snapshot[r.upperBound...].prefix(while: { $0 != "\n" })
        guard let a = line.range(of: "\u{00ab}"), let b = line.range(of: "\u{00bb}", range: a.upperBound..<line.endIndex) else { return nil }
        let n = String(line[a.upperBound..<b.lowerBound]).trimmingCharacters(in: .whitespaces)
        return n.isEmpty ? nil : n
    }

    /// nil: nothing worth a line (a wait, a look, the end itself, a refused action).
    static func of(_ a: WebAction, control: String? = nil) -> Phrase? {
        let name = control.map { clip($0, 40) }
        switch a {
        case .navigate(let u): return Phrase(text: "Opened " + site(u), kind: "open:" + site(u))
        case .click:
            return Phrase(text: name.map { "Clicked \u{00ab}\($0)\u{00bb}" } ?? "Clicked on the page", kind: "click:" + (name ?? ""))
        case let .type(_, text, enter):
            let t = "\u{00ab}" + clip(text, 32) + "\u{00bb}"
            return enter ? Phrase(text: "Searched for " + t, kind: "search") : Phrase(text: "Typed " + t, kind: "type")
        case let .pick(_, _, option): return Phrase(text: "Chose \u{00ab}\(clip(option, 40))\u{00bb}", kind: "choose")
        case let .select(_, option): return Phrase(text: "Chose \u{00ab}\(clip(option, 40))\u{00bb}", kind: "choose")
        case let .setDate(_, _, m, d):
            return Phrase(text: "Picked \(d) " + (months.indices.contains(m - 1) ? months[m - 1] : "\(m)"), kind: "date")
        case .scroll: return Phrase(text: "Looked through the page", kind: "scroll")
        case .read: return Phrase(text: "Read the page", kind: "read")
        case .back: return Phrase(text: "Went back", kind: "back")
        case let .ask(human, _):
            return human ? Phrase(text: "Asked you to take over", kind: "ask") : Phrase(text: "Asked your OK", kind: "ask")
        case .wait, .done, .invalid: return nil
        }
    }

    /// An Ads Manager field the overlay set: "Set Daily budget".
    static func field(_ label: String) -> Phrase { Phrase(text: "Set " + label, kind: "field") }

    /// The last step's new text when `p` repeats its kind, nil when both stay.
    static func merge(_ last: String, _ p: Phrase) -> String? {
        switch p.kind {
        case "date": return "Picked dates"
        case "type": return "Filled in the form"
        case "choose": return last == p.text ? last : "Chose options"
        case "field": return last == p.text ? last : "Set the fields"
        case "scroll", "read", "back", "ask": return last
        default: return last == p.text ? last : nil   // the same click or page again is one line
        }
    }
}

extension ToolPhrases {
    /// A tool's first phrasing, for a task title when the trace gave no label.
    static func title(_ tool: String) -> String { all[tool]?.first ?? DevToolPhrases.all[tool]?.first ?? all["_default"]?.first ?? tool }
}

/// Whose browser the conversation's right side shows (in Team with Lia it said "Met's browser").
/// ("Lia's dialogue must not show Met's browser - each agent's dialogue shows only its own"):
/// a dialogue shows its own agent's browser and no other - never the one of a teammate who spoke, acknowledged a
/// mention or worked a hand-over there. A teammate's browser work belongs to that teammate's dialogue (`owner`).
enum AgentPaneChoice {
    /// The agent whose browser `dlg` shows: Team's is Lia's, an agent's dialogue its agent's.
    static func shown(dlg: String) -> String { DialogueSummary.agent(forDlg: dlg) }

    /// The dialogue an agent's browser work (a browser task, a screen look, its Ads Manager trace) belongs to.
    static func owner(agent: String) -> String { DialogueSummary.dlg(forAgent: agent) }
}
