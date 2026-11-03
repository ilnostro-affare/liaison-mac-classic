import Foundation

// Dev (lia-agents, behind a server flag): builds the person's site in its own sandbox and shows it. It needs no Meta
// account. Its tools: run, write_file, read_file, list_files, start_preview, check_preview. It sends one block of its
// own, `dev_preview` ({kind, url, title}), drawn as a card whose Open loads the url in the chat's agent browser.

/// A `dev_preview` block: the page Dev serves, and what to call it.
struct DevPreview: Equatable {
    let url: URL
    let title: String
    /// The artifact's record, its changes, steps and messages (DevArtMeta); `site` names a published site and
    /// `isNew` says it was published for the first time.
    let meta: DevArtMeta
    let site: String?
    let isNew: Bool

    /// Only http(s) addresses with a host; anything else draws nothing (as an unknown kind would).
    init?(_ b: ChatBlock) {
        guard b.kind == "dev_preview" || b.tool == "dev_preview",
              let raw = b.url?.trimmingCharacters(in: .whitespacesAndNewlines), let u = URL(string: raw),
              let scheme = u.scheme?.lowercased(), scheme == "https" || scheme == "http",
              let host = u.host, !host.isEmpty else { return nil }
        url = u
        let o = b.raw
        let t = JSONRead.string(o, "title")?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        title = t.isEmpty ? "Preview" : t
        meta = DevArtMeta(o)
        let st = JSONRead.string(o, "site")?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        site = st.isEmpty ? nil : st
        isNew = JSONRead.bool(o, "new")
    }

    /// A published site (`publish_site`) rather than the sandbox's preview.
    var isLive: Bool { title == "Live site" }

    /// The secondary line: host and path, no scheme, no trailing slash ("abc.dev.liaisone.com/contact").
    var shortAddress: String {
        var s = url.host ?? ""
        if let p = url.port { s += ":\(p)" }
        let path = url.path
        if !path.isEmpty, path != "/" { s += path.hasSuffix("/") ? String(path.dropLast()) : path }
        return s
    }
}

/// The live line's phrasings for Dev's tools (ToolPhrases is generated from the site; these are the Mac's own until
/// the site ships them). The server's `label` still names the step in the timeline.
enum DevToolPhrases {
    static let all: [String: [String]] = [
        "run": ["Running a command", "Working in the terminal", "Running it", "Checking the output"],
        "write_file": ["Editing a file", "Writing the code", "Changing the page", "Saving the file"],
        "read_file": ["Reading a file", "Looking at the code", "Checking the file", "Reading the page source"],
        "list_files": ["Looking at the files", "Checking the project", "Listing the files", "Finding the right file"],
        "start_preview": ["Starting the preview", "Putting the site up", "Getting the preview ready", "Serving the site"],
        "check_preview": ["Checking the page", "Opening the preview", "Looking at the site", "Checking it loads"],
        // A call to a service with one of the cloud's keys
        "http_request": ["Calling an API", "Talking to the service", "Sending the request", "Waiting for the answer"],
    ]
    /// The chip label for a tool when the server sent none.
    static let labels: [String: String] = [
        "run": "Terminal", "write_file": "Edit file", "read_file": "Read file", "list_files": "Files",
        "start_preview": "Preview", "check_preview": "Check page", "http_request": "Request",
    ]
}

// MARK: -: Dev's work as separate messages, its status, Manual mode, its activity

/// Auto: Dev works through. Manual: Dev asks before every change (the server stops on `dev_confirm`).
/// Kept per workspace on this Mac and sent as `dev_mode` with Dev's turns.
enum DevMode: String, Equatable, CaseIterable {
    case auto, manual

    var label: String { self == .auto ? "Auto" : "Manual" }
    var help: String { self == .auto ? "Auto: Dev works through" : "Manual: Dev asks before every change" }
    var symbol: String { self == .auto ? "bolt.fill" : "hand.raised.fill" }

    static func key(profile: String) -> String { "lia_dev_mode_" + profile }

    /// The stored value, Auto when nothing (or something unknown) is stored.
    static func stored(_ raw: String?) -> DevMode { DevMode(rawValue: raw ?? "") ?? .auto }
}

/// The lines of /agents/turn that only Dev sends (lia-dev.js), and Dev's own act_start / act_done (its act_done
/// `sum` is one line of text, not Lia 2.0's object).
enum DevLine: Equatable {
    /// One or two words of what Dev is doing now ("Editing files").
    case status(String)
    /// Dev finished one message (stored, its `msg` just before) and goes on working.
    case segmentEnd
    /// Manual: Dev wants to change something; the turn stops for the person.
    case confirm(id: String, tool: String, summary: String)
    case actStart(id: String, tool: String, args: [String: String])
    case actDone(id: String, sum: String)

    /// Dev's tools (lia-dev DEV_TOOLS + the GitHub ones).
    static let tools: Set<String> = ["run", "write_file", "read_file", "list_files", "start_preview", "check_preview",
                                     "git_clone", "git_push", "github_api", "publish_site", "http_request"]

    static func parse(line: String) -> DevLine? {
        guard line.hasPrefix("data:") else { return nil }
        let body = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
        guard let o = JSONRead.object(Data(body.utf8)), let type = JSONRead.string(o, "type") else { return nil }
        // Another agent's line in Team is never Dev's.
        if let a = JSONRead.string(o, "agent"), !a.isEmpty, a != "dev" { return nil }
        switch type {
        case "dev_status":
            let t = (JSONRead.string(o, "text") ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            return t.isEmpty ? nil : .status(t)
        case "segment_end":
            return .segmentEnd
        case "dev_confirm":
            return .confirm(id: JSONRead.string(o, "id") ?? "", tool: JSONRead.string(o, "tool") ?? "",
                            summary: JSONRead.string(o, "summary") ?? "")
        case "act_start":
            guard let tool = JSONRead.string(o, "tool"), tools.contains(tool), let targs = o["targs"] as? JSONObject else { return nil }
            var args: [String: String] = [:]
            for (k, v) in targs { args[k] = AgentValue.text(v) }
            return .actStart(id: JSONRead.string(o, "id") ?? "", tool: tool, args: args)
        case "act_done":
            guard let sum = o["sum"] as? String else { return nil }
            return .actDone(id: JSONRead.string(o, "id") ?? "", sum: sum)
        default:
            return nil
        }
    }
}

/// Dev's question in Manual mode, as the stored block `{tool:"dev_confirm", data:{kind, tool, summary, status}}`.
struct DevConfirm: Equatable {
    let tool: String
    let summary: String
    let status: String

    init(tool: String, summary: String, status: String = "pending") {
        self.tool = tool; self.summary = summary; self.status = status
    }

    init?(_ b: ChatBlock) {
        guard b.kind == "dev_confirm" || b.tool == "dev_confirm" else { return nil }
        let o = b.raw
        tool = JSONRead.string(o, "tool") ?? ""
        summary = (JSONRead.string(o, "summary") ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        status = JSONRead.string(o, "status") ?? "pending"
    }

    /// The first question card of a message (nil: none).
    static func first(in blocks: [ChatBlock]) -> DevConfirm? { blocks.lazy.compactMap { DevConfirm($0) }.first }

    /// A command reads as code; its summary comes as "Run: <command>".
    var isCommand: Bool { tool == "run" || tool == "github_api" || tool == "http_request" }

    /// What the card shows: the command alone for a command, else the summary ("Edit index.html").
    var shown: String {
        if tool == "run", summary.hasPrefix("Run: ") { return String(summary.dropFirst(5)) }
        return summary.isEmpty ? "Make a change" : summary
    }

    /// The card's heading.
    var title: String {
        switch tool {
        case "run": return "Dev wants to run a command"
        case "write_file": return "Dev wants to edit a file"
        case "start_preview": return "Dev wants to start the preview"
        case "git_clone": return "Dev wants to clone a repository"
        case "git_push": return "Dev wants to push code"
        case "github_api": return "Dev wants to change GitHub"
        case "publish_site": return "Dev wants to publish the site"
        case "http_request": return "Dev wants to call a service"
        default: return "Dev wants to make a change"
        }
    }

    /// The machine message that answers it (sent with `agent: "dev"`).
    static func reply(_ yes: Bool) -> String { "[gate_reply] {\"dev\":\"" + (yes ? "yes" : "no") + "\"}" }

    /// Where the person's answer is kept on this Mac (ChatDecisions), by the message that holds the card.
    static func decisionKey(_ messageId: String) -> String { "devc:" + messageId }
}

/// Dev's turn stopped at its bound (time, cost or steps): the block `{tool:"dev_continue", data:{kind, why, label, text,
/// minutes, spent_usd, steps}}`, live on the stream and stored in the message. Drawn under Dev's message as one button
/// (`label`); a click sends `text` as the person's message to Dev's dialogue. Gone once a newer message exists.
struct DevContinue: Equatable {
    /// "time", "cost" or "hops" (anything else: "").
    let why: String
    let label: String
    let text: String
    let minutes: Int?
    let spentUSD: Double?
    let steps: Int?

    init(why: String, label: String = "Continue", text: String = "continue", minutes: Int? = nil, spentUSD: Double? = nil, steps: Int? = nil) {
        self.why = why; self.label = label; self.text = text; self.minutes = minutes; self.spentUSD = spentUSD; self.steps = steps
    }

    init?(_ b: ChatBlock) {
        guard b.kind == "dev_continue" || b.tool == "dev_continue" else { return nil }
        let o = b.raw
        let w = (JSONRead.string(o, "why") ?? "").lowercased()
        why = ["time", "cost", "hops"].contains(w) ? w : ""
        let l = (JSONRead.string(o, "label") ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        label = l.isEmpty ? "Continue" : l
        let t = (JSONRead.string(o, "text") ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        text = t.isEmpty ? "continue" : t
        minutes = JSONRead.int(o, "minutes")
        spentUSD = JSONRead.double(o, "spent_usd")
        steps = JSONRead.int(o, "steps")
    }

    /// The first one of a message (nil: none).
    static func first(in blocks: [ChatBlock]) -> DevContinue? { blocks.lazy.compactMap { DevContinue($0) }.first }

    /// The line above the button: why Dev stopped.
    var reason: String {
        switch why {
        case "time": return minutes.map { "Dev paused after \($0) minutes of work" } ?? "Dev paused: the time limit for one run"
        case "cost":
            if let c = spentUSD { return "Dev paused after spending $" + String(format: "%.2f", c) }
            return "Dev paused: the cost limit for one run"
        case "hops": return steps.map { "Dev paused after \($0) steps" } ?? "Dev paused: the step limit for one run"
        default: return "Dev paused"
        }
    }
}

/// One of Dev's coding steps, readable in one line with an icon (the Canvas's Activity, "What did Dev do?").
struct DevStep: Equatable, Identifiable {
    enum Kind: String, Equatable {
        case edit, read, list, command, preview, check, clone, push, github, publish, request, task, other
    }

    let id: String
    let kind: Kind
    let tool: String
    /// The line ("Edited index.html", the command itself for a command).
    let text: String
    /// Monospace (a command, a GitHub call).
    let code: Bool
    var at: Double
    /// The server's one line once it ended ("Exit 1", "Saved index.html"); nil while it runs.
    var result: String?
    var failed = false
    /// What the step was about (a file's path, a repository), for the Activity's plain sentence.
    var subject: String? = nil

    var running: Bool { result == nil }

    var symbol: String { DevStep.symbol(kind) }

    static func symbol(_ k: Kind) -> String {
        switch k {
        case .edit: return "pencil"
        case .read: return "doc.text"
        case .list: return "folder"
        case .command: return "terminal"
        case .preview: return "macwindow"
        case .check: return "eye"
        case .clone: return "square.and.arrow.down"
        case .push: return "arrow.up.circle"
        case .github: return "chevron.left.forwardslash.chevron.right"
        case .publish: return "globe"
        case .request: return "network"
        case .task: return "checklist"
        case .other: return "gearshape"
        }
    }

    /// A project path without the box's prefix ("/workspace/project/src/a.js" -> "src/a.js").
    static func path(_ p: String?) -> String {
        var s = (p ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        for pre in ["/workspace/project/", "./"] where s.hasPrefix(pre) { s = String(s.dropFirst(pre.count)) }
        return s
    }

    /// The step for an act_start of Dev (its `targs`: never a file's content).
    static func start(id: String, tool: String, args: [String: String], at: Double) -> DevStep {
        let p = path(args["path"])
        func one(_ k: Kind, _ t: String, code: Bool = false) -> DevStep {
            var s = DevStep(id: id, kind: k, tool: tool, text: AgentStepPhrase.clip(t, 160), code: code, at: at)
            switch k {
            case .edit, .read: s.subject = p.isEmpty ? nil : p
            case .clone, .push: s.subject = (args["repo"] ?? "").isEmpty ? nil : args["repo"]
            case .request: s.subject = DevStep.requestHost(args["url"])
            default: break
            }
            return s
        }
        switch tool {
        case "write_file": return one(.edit, p.isEmpty ? "Edited a file" : "Edited " + p)
        case "read_file": return one(.read, p.isEmpty ? "Read a file" : "Read " + p)
        case "list_files": return one(.list, p.isEmpty ? "Looked at the files" : "Looked at " + p)
        case "run":
            let c = (args["command"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            // The cloud's keys the command used (as env vars; Dev never sees their values)
            let keys = DevStep.secretNames(args["secrets"])
            let uses = keys.isEmpty ? "" : " \u{00b7} uses " + keys.joined(separator: ", ")
            return c.isEmpty ? one(.command, "Ran a command" + uses) : one(.command, c + uses, code: true)
        case "http_request":
            let m = (args["method"] ?? "GET").trimmingCharacters(in: .whitespaces).uppercased()
            let u = DevStep.requestAddress(args["url"])
            if u.isEmpty { return one(.request, m.isEmpty || m == "GET" ? "Called a service" : m + " to a service") }
            return one(.request, m.isEmpty || m == "GET" ? "Called " + u : m + " " + u)
        case "start_preview":
            if let c = args["command"], !c.isEmpty { return one(.preview, "Started the preview: " + c) }
            if let d = args["dir"], !d.isEmpty { return one(.preview, "Opened the preview of " + path(d)) }
            return one(.preview, "Opened the preview")
        case "check_preview":
            return one(.check, p.isEmpty || p == "/" ? "Checked the page" : "Checked " + p)
        case "git_clone":
            let r = args["repo"] ?? ""
            return one(.clone, r.isEmpty ? "Cloned a repository" : "Cloned " + r)
        case "git_push":
            let r = args["repo"] ?? "", b = args["branch"] ?? ""
            if b.isEmpty { return one(.push, r.isEmpty ? "Pushed the code" : "Pushed to " + r) }
            return one(.push, "Pushed " + b + (r.isEmpty ? "" : " to " + r))
        case "publish_site":
            let d = path(args["dir"])
            return one(.publish, d.isEmpty ? "Published the site" : "Published " + d)
        case "github_api":
            let m = (args["method"] ?? "GET").uppercased(), p2 = args["path"] ?? ""
            return one(.github, "GitHub " + m + (p2.isEmpty ? "" : " " + p2), code: true)
        default:
            return one(.other, DevToolPhrases.labels[tool] ?? tool)
        }
    }

    /// An http_request's address as the line shows it: no scheme, no query, no trailing slash
    /// ("https://api.stripe.com/v1/charges?x=1" -> "api.stripe.com/v1/charges").
    static func requestAddress(_ raw: String?) -> String {
        var s = (raw ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if let r = s.range(of: "://") { s = String(s[r.upperBound...]) }
        if let q = s.firstIndex(where: { $0 == "?" || $0 == "#" }) { s = String(s[..<q]) }
        while s.hasSuffix("/") { s.removeLast() }
        return s
    }

    /// The host of an http_request's address (nil: none).
    static func requestHost(_ raw: String?) -> String? {
        let a = requestAddress(raw)
        let h = String(a.prefix { $0 != "/" }).lowercased()
        return h.isEmpty ? nil : h
    }

    /// run's `secrets` ("A,B", or a list as text) -> ["A", "B"].
    static func secretNames(_ raw: String?) -> [String] {
        let junk = CharacterSet(charactersIn: "[]\"' \n\t")
        var out: [String] = []
        for part in (raw ?? "").split(whereSeparator: { $0 == "," || $0 == "\n" }) {
            let n = part.trimmingCharacters(in: junk)
            if !n.isEmpty, !out.contains(n) { out.append(n) }
        }
        return out
    }

    /// A task Dev took ("Took the task «Fix the footer»").
    static func task(id: String, title: String, at: Double) -> DevStep {
        DevStep(id: "task-" + id, kind: .task, tool: "task", text: "Took the task \u{00ab}" + AgentStepPhrase.clip(title, 80) + "\u{00bb}",
                code: false, at: at)
    }

    /// act_done's line: a failure reads as one ("Exit 1", "Failed", "GitHub 403", an error).
    static func failed(_ sum: String) -> Bool {
        let s = sum.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("Exit ") { return s != "Exit 0" }
        // An http_request's "Status 200"; a 4xx or 5xx answer is a failed call
        if s.hasPrefix("Status "), let code = Int(s.dropFirst(7).prefix { $0.isNumber }) { return code >= 400 }
        return s == "Failed" || s == "Did not start" || s == "Not published" || s.hasPrefix("GitHub ") || s.hasSuffix("page errors")
            || s.lowercased().contains("error") || s.lowercased().contains("failed")
    }

    /// The step as a line of the agent's task history ("What did Dev do?"): kind "dev.<kind>|<text>", so the same
    /// line twice is one and two different files are two.
    var phrase: AgentStepPhrase.Phrase {
        let line = code ? (kind == .command ? "Ran " : "") + text : text
        return AgentStepPhrase.Phrase(text: line + (failed ? " \u{00b7} " + (result ?? "") : ""), kind: "dev." + kind.rawValue + "|" + text)
    }

    /// The icon of a history step whose kind came from `phrase` (nil: not one of Dev's).
    static func symbol(historyKind k: String) -> String? {
        guard k.hasPrefix("dev.") else { return nil }
        let raw = k.dropFirst(4).prefix { $0 != "|" }
        return Kind(rawValue: String(raw)).map(symbol)
    }
}

/// A turn's steps, as they stream: started, ended with their line, in order.
struct DevActivity: Equatable {
    private(set) var steps: [DevStep] = []
    /// Dev's messages of the turn, each placed after the steps that came before it.
    private(set) var notes: [DevNote] = []
    /// The words Dev is writing now after its first message of the turn. They never show in the
    /// chat: they stream here until their stored copy (a note) takes their place, or the turn's final message ends them.
    private(set) var draft: DevNote?
    /// What Dev is doing now (`dev_status`), nil between steps.
    private(set) var status: String?
    static let cap = 200
    /// The draft's id in the entries (DevActivityGroup.streaming).
    static let draftId = "live-draft"

    var isEmpty: Bool { steps.isEmpty }
    /// Nothing to show at all: no step and no message.
    var isBlank: Bool { steps.isEmpty && notes.isEmpty && draft == nil }

    /// Messages and steps in the order they came (the Activity groups them, DevActivityGroups.make).
    var entries: [DevArtEntry] { DevActivityGroups.entries(steps: steps, notes: draft.map { notes + [$0] } ?? notes) }

    /// One of Dev's messages of this turn (a stored copy arriving again replaces its text, in its place). A new one
    /// takes the place of the draft it was streamed as.
    mutating func note(id: String, text: String, run: String?, at: Double = 0) {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let i = notes.firstIndex(where: { $0.id == id }) {
            if t.isEmpty { notes.remove(at: i) } else { notes[i].text = t }
            return
        }
        let d = draft
        draft = nil
        guard !t.isEmpty else { return }
        notes.append(DevNote(id: id, text: t, run: run, afterSteps: d?.afterSteps ?? steps.count, at: d?.at ?? at))
        if notes.count > Self.cap { notes.removeFirst(notes.count - Self.cap) }
    }

    /// The words streaming now (all of them so far); empty text drops the draft.
    mutating func stream(_ text: String, run: String?, at: Double) {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { draft = nil; return }
        if draft == nil { draft = DevNote(id: Self.draftId, text: t, run: run, afterSteps: steps.count, at: at) } else { draft?.text = t }
    }

    /// The draft ended without a stored copy: kept as a message of the turn under `id`.
    mutating func keepDraft(id: String) {
        guard let d = draft else { return }
        draft = nil
        notes.append(DevNote(id: id, text: d.text, run: d.run, afterSteps: d.afterSteps, at: d.at))
        if notes.count > Self.cap { notes.removeFirst(notes.count - Self.cap) }
    }

    /// The draft was the turn's final message (the chat shows it now): it leaves the Activity.
    mutating func dropDraft() { draft = nil }

    mutating func on(_ line: DevLine, at: Double) {
        switch line {
        case .status(let t): status = t
        case let .actStart(id, tool, args):
            let s = DevStep.start(id: id, tool: tool, args: args, at: at)
            if let i = steps.lastIndex(where: { $0.id == id && $0.running }) { steps[i] = s } else { steps.append(s) }
            if steps.count > Self.cap {
                let k = steps.count - Self.cap
                steps.removeFirst(k)
                for i in notes.indices { notes[i].afterSteps = max(0, notes[i].afterSteps - k) }
                if let d = draft { draft?.afterSteps = max(0, d.afterSteps - k) }
            }
        case let .actDone(id, sum):
            guard let i = steps.lastIndex(where: { $0.id == id && $0.running }) else { return }
            steps[i].result = sum
            steps[i].failed = DevStep.failed(sum)
            status = nil
        case .segmentEnd, .confirm:
            break
        }
    }

    mutating func add(_ step: DevStep) {
        guard !steps.contains(where: { $0.id == step.id }) else { return }
        steps.append(step)
    }

    /// The turn is over: nothing is running any more.
    mutating func end() {
        status = nil
        for i in steps.indices where steps[i].running { steps[i].result = "Stopped" }
    }

    mutating func clear() { steps = []; notes = []; draft = nil; status = nil }

    /// A new turn: the steps go; Dev's messages of `run` (written before its first step) stay, and so do the words
    /// it is writing now.
    mutating func clear(keepingRun run: String?) {
        steps = []; status = nil
        notes = run.map { r in notes.filter { $0.run == r }.map { var n = $0; n.afterSteps = 0; return n } } ?? []
        draft?.afterSteps = 0
    }
}

/// The line under the person's message while an agent works: Dev's `dev_status` ("Editing
/// files"); another agent's current tool phrase while a tool runs; nil: "<Name> is writing".
enum TypingLine {
    static func text(devStatus: String?, live: LiveTurn?) -> String? {
        if let s = devStatus?.trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty { return s }
        guard let l = live, !l.finished, let last = l.timeline.phases.last, !last.done,
              last.kind == .tools || last.kind == .web || last.kind == .code else { return nil }
        let t = l.status.text
        // A thought's heading or the writing line still standing its dwell is not a tool phrase.
        let think = l.timeline.phases.last(where: { $0.kind == .think })?.title
        if t.isEmpty || t == "Thinking" || t == "Writing the answer" || t == think { return nil }
        return t
    }
}

/// A paste long enough to become a chip in the composer (over 1,500 characters or 20 lines).
enum LongPaste {
    static let chars = 1500
    static let lines = 20

    static func isLong(_ s: String) -> Bool {
        if s.count > chars { return true }
        var n = 1
        for c in s where c == "\n" { n += 1; if n > lines { return true } }
        return false
    }

    /// "2,345 chars".
    static func size(_ s: String) -> String {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        f.locale = Locale(identifier: "en_US")
        return (f.string(from: NSNumber(value: s.count)) ?? "\(s.count)") + (s.count == 1 ? " char" : " chars")
    }

    /// The text as it goes with the message: a mention the bubble shows as a card, then the text in a fence.
    static func block(name: String, text: String) -> String {
        let fence = text.contains("```") ? "````" : "```"
        return "[attached: \(name), \(size(text))]\n" + fence + "\n" + text + (text.hasSuffix("\n") ? "" : "\n") + fence
    }
}

/// What `segment_end` does to the bubble at the end of the thread (each of Dev's steps is its own
/// message). Its stored copy (`msg`) normally came just before and already closed the live bubble: a new one starts
/// below for the same agent (the typing line comes back). Without the `msg`, what streamed is kept as it is first.
enum DevSegment {
    enum Step: Equatable {
        case restart(String)
        case finishAndRestart(String)
        case ignore
    }

    static func onEnd(liveAgent: String?, liveOpen: Bool, turnAgent: String?) -> Step {
        if liveOpen, let a = liveAgent ?? turnAgent { return .finishAndRestart(a) }
        if let a = turnAgent ?? liveAgent { return .restart(a) }
        return .ignore
    }
}
