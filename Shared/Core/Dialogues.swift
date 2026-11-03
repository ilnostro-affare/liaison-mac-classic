import Foundation

// / Mac 0.2.7: one agent = one endless dialogue per workspace, plus Team with Lia.
// Contract: docs/DIALOGUES-API.md. Pure models over the lenient JSONRead readers (the same way every other
// lia-agents answer is read): a missing, null or mistyped field reads as absent and never drops the whole answer.

/// Milliseconds since 1970 (the server's `ts`) -> Date. A value that is plainly seconds is read as seconds.
enum DlgTime {
    static func date(_ v: Double?) -> Date? {
        guard let v, v > 0 else { return nil }
        return Date(timeIntervalSince1970: v < 100_000_000_000 ? v : v / 1000)
    }
    static func ms(_ d: Date) -> Int { Int((d.timeIntervalSince1970 * 1000).rounded()) }
}

/// What a message holds, as the server's bitmask: 1 photo, 2 video, 4 file, 8 link, 16 plan.
struct DlgKinds: OptionSet, Equatable, Hashable {
    let rawValue: Int
    init(rawValue: Int) { self.rawValue = rawValue }
    static let photo = DlgKinds(rawValue: 1)
    static let video = DlgKinds(rawValue: 2)
    static let file = DlgKinds(rawValue: 4)
    static let link = DlgKinds(rawValue: 8)
    static let plan = DlgKinds(rawValue: 16)
    static let media: DlgKinds = [.photo, .video]
}

/// Where a message came from.
struct DlgOrigin: Equatable {
    enum Surface: String, CaseIterable {
        case chat, addressBar = "address_bar", notes, page, sidePanel = "side_panel", handoff, schedule
    }
    var surface: Surface
    var fromAgent: String?
    var fromDlg: String?
    var taskId: String?
    /// An agent's acknowledgement of a task (its message in another agent's dialogue): where it works the task.
    var toDlg: String?
    /// A task's first row in its owner's dialogue - who wrote the words ("person" or an agent id) and the message
    /// of `fromDlg` they came from (the "Asked in Lia's dialogue" link back).
    var by: String?
    var fromMsg: String?

    init(surface: Surface, fromAgent: String? = nil, fromDlg: String? = nil, taskId: String? = nil, toDlg: String? = nil,
         by: String? = nil, fromMsg: String? = nil) {
        self.surface = surface; self.fromAgent = fromAgent; self.fromDlg = fromDlg; self.taskId = taskId; self.toDlg = toDlg
        self.by = by; self.fromMsg = fromMsg
    }

    /// nil when there is no object or the surface is one this build does not know.
    init?(json o: JSONObject?) {
        guard let o, let s = Surface(rawValue: JSONRead.string(o, "surface") ?? "") else { return nil }
        self.init(surface: s, fromAgent: JSONRead.string(o, "from_agent"), fromDlg: JSONRead.string(o, "from_dlg"),
                  taskId: JSONRead.string(o, "task_id"), toDlg: JSONRead.string(o, "to_dlg"),
                  by: JSONRead.string(o, "by"), fromMsg: JSONRead.string(o, "from_msg"))
    }

    /// The small caption under a message: "from the address bar", "from notes", "from Lee". `name` maps an agent
    /// id to its display name (the roster); without it the id is capitalised. Plain chat has no caption.
    func label(name: ((String) -> String?)? = nil) -> String? {
        switch surface {
        case .chat: return nil
        case .addressBar: return "from the address bar"
        case .notes: return "from notes"
        case .page: return "from the page"
        case .sidePanel: return "from the side panel"
        case .schedule: return "scheduled"
        case .handoff:
            guard let a = fromAgent, !a.isEmpty else { return "handed over" }
            return "from " + (name?(a) ?? DlgOrigin.displayName(a))
        }
    }
    var label: String? { label() }

    /// Agent id -> name from the fallback roster, else the id with a capital letter ("lee" -> "Lee").
    static func displayName(_ id: String) -> String {
        if let a = AgentInfo.lookup(id, in: []) { return a.name }
        return id.prefix(1).uppercased() + id.dropFirst()
    }

    /// The `origin` object /agents/turn takes.
    var body: JSONObject { ["surface": surface.rawValue] }
}

/// One stored message of a dialogue.
struct DlgMessage: Equatable, Identifiable {
    enum Role: String { case user, assistant, system }
    let id: String
    var seq: Int
    var ts: Date?
    var role: Role
    /// The agent who spoke (assistant messages, task cards).
    var agent: String?
    var text: String
    var blocks: [ChatBlock]
    var attachments: [ChatAttachment]
    var origin: DlgOrigin?
    /// A task card in the caller's dialogue (role system) or a message worked for a task.
    var taskId: String?
    var kinds: DlgKinds
    /// The approval card exactly as stored (parse with `gate`).
    var gateJSON: String?
    /// The message as the server sent it.
    var rawJSON: String?
    /// Dev's turn this message belongs to, its place in the turn (0, 1, 2...) and whether it is the turn's
    /// final message. Older messages have none (DevThread draws them as before).
    var run: String?
    var seg: Int?
    var fin: Bool
    /// Server: a long answer stored as several messages - the answer's `turn` id, this message's `part` (1...n)
    /// and the answer's `parts` (n). Blocks, plans, questions and sources are on the last part. nil: one message.
    var turn: String?
    var part: Int?
    var parts: Int?

    init(id: String, seq: Int = 0, ts: Date? = nil, role: Role = .assistant, agent: String? = nil, text: String = "",
         blocks: [ChatBlock] = [], attachments: [ChatAttachment] = [], origin: DlgOrigin? = nil, taskId: String? = nil,
         kinds: DlgKinds = [], gateJSON: String? = nil, rawJSON: String? = nil, run: String? = nil, seg: Int? = nil,
         fin: Bool = false) {
        self.id = id; self.seq = seq; self.ts = ts; self.role = role; self.agent = agent; self.text = text
        self.blocks = blocks; self.attachments = attachments; self.origin = origin; self.taskId = taskId
        self.kinds = kinds; self.gateJSON = gateJSON; self.rawJSON = rawJSON
        self.run = run; self.seg = seg; self.fin = fin
    }

    init?(json o: JSONObject?) {
        guard let o, let id = JSONRead.string(o, "id"), !id.isEmpty else { return nil }
        self.init(id: id,
                  seq: JSONRead.int(o, "seq") ?? 0,
                  ts: DlgTime.date(JSONRead.double(o, "ts")),
                  role: Role(rawValue: JSONRead.string(o, "role") ?? "") ?? .assistant,
                  agent: JSONRead.string(o, "agent"),
                  text: CreaTargetHead.shown(JSONRead.string(o, "text") ?? JSONRead.string(o, "content") ?? "",
                                             user: JSONRead.string(o, "role") == "user"),
                  blocks: JSONRead.objects(o, "blocks").map { ChatBlock(tool: JSONRead.string($0, "tool"), data: ($0["data"] as? JSONObject) ?? $0) },
                  attachments: JSONRead.objects(o, "att").compactMap(ChatAttachment.init(json:)),
                  origin: DlgOrigin(json: o["origin"] as? JSONObject),
                  taskId: JSONRead.string(o, "task_id"),
                  kinds: DlgKinds(rawValue: JSONRead.int(o, "kinds") ?? 0),
                  gateJSON: (o["gate"] as? JSONObject).flatMap(LiveTurn.encode),
                  rawJSON: LiveTurn.encode(o),
                  run: JSONRead.string(o, "run").flatMap { $0.isEmpty ? nil : $0 },
                  seg: JSONRead.int(o, "seg"),
                  fin: JSONRead.bool(o, "fin"))
        turn = JSONRead.string(o, "turn").flatMap { $0.isEmpty ? nil : $0 }
        part = JSONRead.int(o, "part")
        parts = JSONRead.int(o, "parts")
    }

    /// A part of a split answer that is not its last (more of the same answer is on its way).
    var morePartsFollow: Bool {
        guard turn != nil, let p = part, let n = parts else { return false }
        return p < n
    }

    /// The message as the thread rule reads it (DevThread).
    var threadEntry: DevThread.Entry {
        DevThread.Entry(id: id, agent: role == .user ? nil : (agent ?? ""), run: run, seg: seg, fin: fin)
    }

    var gate: Gate? { Gate(json: gateJSON.flatMap { JSONRead.object(Data($0.utf8)) }) }
    var isTaskCard: Bool { role == .system && taskId != nil }
    /// The task's first row in its owner's dialogue (the hand-over), not a card: drawn as the message as written
    /// (the person's bubble or the teammate's line) with a link back to where it was asked.
    var isHandedTask: Bool { role == .system && taskId != nil && origin?.surface == .handoff && !(origin?.fromDlg ?? "").isEmpty }

    /// The same message as the chat views draw it (system messages read as assistant; rawJSON keeps `agent`,
    /// so AgentOf.message still names the speaker).
    var chatMessage: ChatMessage {
        ChatMessage(id: id, role: role == .user ? .user : .assistant, content: text, blocks: blocks, cites: cites,
                    attachments: attachments, ts: ts.map { $0.timeIntervalSince1970 * 1000 }, gateJSON: gateJSON, rawJSON: rawJSON)
    }

    /// The web sources a stored answer carries (`cites`, as the chat doc's), when the server keeps them.
    var cites: [ChatCite] {
        guard let r = rawJSON, r.contains("\"cites\"") else { return [] }
        return JSONRead.objects(JSONRead.object(Data(r.utf8)), "cites").compactMap(ChatCite.init(json:))
    }

    /// The Meta objects the answer named (`ents`, the runner's map), when the server keeps them.
    var ents: [String: ChatEntity] {
        guard let r = rawJSON, r.contains("\"ents\"") else { return [:] }
        return ChatEntity.map(JSONRead.object(Data(r.utf8))?["ents"] as? JSONObject)
    }

    static func list(_ o: JSONObject?, _ key: String = "messages") -> [DlgMessage] {
        JSONRead.objects(o, key).compactMap(DlgMessage.init(json:))
    }
}

/// a message sent with a Crea Studio image as its target starts with a line for Crea
/// (CreaStudioTargetText.message: "Edit the attached image \u{201C}Draft 1\u{201D} (id x) and make a new version of it.
/// <words>", "@Crea " before it in Team). The server stores and Crea reads the message as sent; the Mac shows only the
/// person's words - the bubble, copy, forward, quotes, search and previews all read the stripped text (DlgMessage is
/// parsed through `shown`, the local copy of a sent message too). The picture goes as the message's attachment and is
/// drawn above the words. Matched by the exact sentence the Mac writes, so messages sent before this are clean too.
enum CreaTargetHead {
    private static let pattern = #"^(?:@Crea )?Edit (?:the attached image|the image) \x{201C}([^\x{201D}\n]*)\x{201D}(?: \(id [^)\s]*\))? and make a new version of it\.(?: |$)"#
    private static let regex = try? NSRegularExpression(pattern: pattern, options: [])

    /// The image's label and the person's own words (empty when they wrote none); nil when `text` has no such head.
    static func split(_ text: String) -> (label: String, words: String)? {
        guard text.hasPrefix("Edit ") || text.hasPrefix("@Crea Edit "), let re = regex else { return nil }
        let ns = text as NSString
        guard let m = re.firstMatch(in: text, options: [.anchored], range: NSRange(location: 0, length: ns.length)) else { return nil }
        let label = m.range(at: 1).location == NSNotFound ? "" : ns.substring(with: m.range(at: 1))
        let words = ns.substring(from: m.range.location + m.range.length).trimmingCharacters(in: .whitespacesAndNewlines)
        return (label, words)
    }

    /// What the person's message shows: their words without the head (any other text as it is).
    static func strip(_ text: String) -> String { split(text)?.words ?? text }

    /// `strip` for the person's messages only (an agent quoting the sentence keeps it).
    static func shown(_ text: String, user: Bool) -> String { user ? strip(text) : text }
}

/// One row of GET /agents/dialogues.
struct DialogueSummary: Equatable, Identifiable {
    let dlg: String
    var last: DlgMessage?
    var count: Int
    var lastSeq: Int
    var id: String { dlg }
    var isTeam: Bool { dlg == "team" }

    init(dlg: String, last: DlgMessage? = nil, count: Int = 0, lastSeq: Int = 0) {
        self.dlg = dlg; self.last = last; self.count = count; self.lastSeq = lastSeq
    }
    init?(json o: JSONObject) {
        guard let d = JSONRead.string(o, "dlg"), !d.isEmpty else { return nil }
        self.init(dlg: d, last: DlgMessage(json: o["last"] as? JSONObject), count: JSONRead.int(o, "count") ?? 0,
                  lastSeq: JSONRead.int(o, "last_seq") ?? 0)
    }
    static func parseList(_ data: Data) -> [DialogueSummary]? {
        guard let o = JSONRead.object(data), JSONRead.bool(o, "ok") else { return nil }
        return JSONRead.objects(o, "dialogues").compactMap(DialogueSummary.init(json:))
    }

    /// The dialogue id for an agent id ("lia" is Team).
    static func dlg(forAgent a: String) -> String { a == "lia" || a.isEmpty ? "team" : a }
    /// The agent a dialogue belongs to (Team is Lia's).
    static func agent(forDlg d: String) -> String { d == "team" || d.isEmpty ? "lia" : d }
}

/// A hand-over: a job owned by one agent, started from another's dialogue.
struct AgentTask: Equatable, Identifiable {
    enum Status: String { case working, waiting, done, failed }
    let id: String
    var owner: String
    var originDlg: String?
    var originMsg: String?
    var status: Status
    var title: String
    var created: Date?
    var closed: Date?
    var isOpen: Bool { status == .working || status == .waiting }

    init(id: String, owner: String = "", originDlg: String? = nil, originMsg: String? = nil, status: Status = .working,
         title: String = "", created: Date? = nil, closed: Date? = nil) {
        self.id = id; self.owner = owner; self.originDlg = originDlg; self.originMsg = originMsg; self.status = status
        self.title = title; self.created = created; self.closed = closed
    }
    init?(json o: JSONObject?) {
        guard let o, let id = JSONRead.string(o, "id"), !id.isEmpty else { return nil }
        self.init(id: id, owner: JSONRead.string(o, "owner") ?? "", originDlg: JSONRead.string(o, "origin_dlg"),
                  originMsg: JSONRead.string(o, "origin_msg"),
                  status: Status(rawValue: JSONRead.string(o, "status") ?? "") ?? .working,
                  title: JSONRead.string(o, "title") ?? "", created: DlgTime.date(JSONRead.double(o, "created")),
                  closed: DlgTime.date(JSONRead.double(o, "closed")))
    }
    static func parseList(_ data: Data) -> [AgentTask]? {
        guard let o = JSONRead.object(data), JSONRead.bool(o, "ok") else { return nil }
        return JSONRead.objects(o, "tasks").compactMap(AgentTask.init(json:))
    }
}

/// One search result. `snippet` marks the match with «…».
struct SearchHit: Equatable, Identifiable {
    let id: String
    var dlg: String
    var seq: Int
    var ts: Date?
    var agent: String?
    var role: DlgMessage.Role
    var snippet: String

    init(id: String, dlg: String = "team", seq: Int = 0, ts: Date? = nil, agent: String? = nil,
         role: DlgMessage.Role = .assistant, snippet: String = "") {
        self.id = id; self.dlg = dlg; self.seq = seq; self.ts = ts; self.agent = agent; self.role = role; self.snippet = snippet
    }
    init?(json o: JSONObject) {
        guard let id = JSONRead.string(o, "id"), !id.isEmpty else { return nil }
        self.init(id: id, dlg: JSONRead.string(o, "dlg") ?? "team", seq: JSONRead.int(o, "seq") ?? 0,
                  ts: DlgTime.date(JSONRead.double(o, "ts")), agent: JSONRead.string(o, "agent"),
                  role: DlgMessage.Role(rawValue: JSONRead.string(o, "role") ?? "") ?? .assistant,
                  snippet: CreaTargetHead.shown(JSONRead.string(o, "snippet") ?? "", user: JSONRead.string(o, "role") == "user"))
    }

    /// The snippet cut into (text, isMatch) runs at the «…» marks, for bold matches.
    var runs: [(text: String, match: Bool)] { SearchHit.runs(snippet) }
    static func runs(_ s: String) -> [(text: String, match: Bool)] {
        var out: [(text: String, match: Bool)] = []
        var cur = "", inMatch = false
        for ch in s {
            if ch == "\u{00AB}" || ch == "\u{00BB}" {
                if !cur.isEmpty { out.append((cur, inMatch)) }
                cur = ""; inMatch = ch == "\u{00AB}"
            } else { cur.append(ch) }
        }
        if !cur.isEmpty { out.append((cur, inMatch)) }
        return out
    }
}

/// One entry of an agent's profile tabs (media, files, links, plans).
struct DlgItem: Equatable, Identifiable {
    /// `code`: Dev's pushes to GitHub (title branch, name "owner/repo", key short sha, url compare page, bytes commits).
    enum Kind: String, CaseIterable { case media, files, links, plans, code }
    let msgId: String
    var dlg: String
    var kind: Kind
    var ts: Date?
    var name: String?
    var mime: String?
    var url: String?
    var key: String?
    var bytes: Int?
    var title: String?
    /// Several items can come from one message.
    var id: String { msgId + "|" + kind.rawValue + "|" + (key ?? url ?? name ?? title ?? "") }

    init(msgId: String, dlg: String = "team", kind: Kind, ts: Date? = nil, name: String? = nil, mime: String? = nil,
         url: String? = nil, key: String? = nil, bytes: Int? = nil, title: String? = nil) {
        self.msgId = msgId; self.dlg = dlg; self.kind = kind; self.ts = ts; self.name = name; self.mime = mime
        self.url = url; self.key = key; self.bytes = bytes; self.title = title
    }
    init?(json o: JSONObject) {
        guard let m = JSONRead.string(o, "msg_id"), !m.isEmpty, let k = Kind(rawValue: JSONRead.string(o, "kind") ?? "") else { return nil }
        self.init(msgId: m, dlg: JSONRead.string(o, "dlg") ?? "team", kind: k, ts: DlgTime.date(JSONRead.double(o, "ts")),
                  name: JSONRead.string(o, "name"), mime: JSONRead.string(o, "mime"), url: JSONRead.string(o, "url"),
                  key: JSONRead.string(o, "key"), bytes: JSONRead.int(o, "bytes"), title: JSONRead.string(o, "title"))
    }
    var isVideo: Bool { (mime ?? "").hasPrefix("video/") }

    /// A Code row's second line: "owner/repo \u{00B7} abc1234 \u{00B7} 2 commits" (what is known of it).
    var codeSubtitle: String {
        var parts: [String] = []
        if let n = name?.trimmingCharacters(in: .whitespaces), !n.isEmpty { parts.append(n) }
        if let k = key?.trimmingCharacters(in: .whitespaces), !k.isEmpty { parts.append(String(k.prefix(7))) }
        if let c = bytes, c > 0 { parts.append(c == 1 ? "1 commit" : "\(c) commits") }
        return parts.joined(separator: " \u{00B7} ")
    }
}

extension DlgItem.Kind {
    /// The profile's item tabs (Favourites follows them): Dev shows its pushes (Code) where the others show Plans.
    static func profileTabs(agent: String) -> [DlgItem.Kind] {
        agent == "dev" ? [.media, .files, .links, .code] : [.media, .files, .links, .plans]
    }
}

/// GET /agents/search's query.
struct SearchQuery: Equatable {
    var q: String = ""
    var dlg: String?
    var kind: DlgItem.Kind?
    var agent: String?
    var origin: DlgOrigin.Surface?
    var from: Date?
    var to: Date?
    var offset: Int = 0

    init(q: String = "", dlg: String? = nil, kind: DlgItem.Kind? = nil, agent: String? = nil,
         origin: DlgOrigin.Surface? = nil, from: Date? = nil, to: Date? = nil, offset: Int = 0) {
        self.q = q; self.dlg = dlg; self.kind = kind; self.agent = agent; self.origin = origin
        self.from = from; self.to = to; self.offset = offset
    }

    /// Without `profile`; only what is set, in a fixed order. Dates go as ms.
    var items: [URLQueryItem] {
        var out: [URLQueryItem] = []
        let t = q.trimmingCharacters(in: .whitespacesAndNewlines)
        if !t.isEmpty { out.append(URLQueryItem(name: "q", value: t)) }
        if let dlg, !dlg.isEmpty { out.append(URLQueryItem(name: "dlg", value: dlg)) }
        if let kind { out.append(URLQueryItem(name: "kind", value: kind.rawValue)) }
        if let agent, !agent.isEmpty { out.append(URLQueryItem(name: "agent", value: agent)) }
        if let origin { out.append(URLQueryItem(name: "origin", value: origin.rawValue)) }
        if let from { out.append(URLQueryItem(name: "from", value: String(DlgTime.ms(from)))) }
        if let to { out.append(URLQueryItem(name: "to", value: String(DlgTime.ms(to)))) }
        if offset > 0 { out.append(URLQueryItem(name: "offset", value: String(offset))) }
        return out
    }

    /// Nothing to search for: no text and no filter.
    var isEmpty: Bool { items.filter { $0.name != "dlg" }.isEmpty }
}

/// Parsers for the dialogue routes' answers (nil: not ok / unreadable).
enum DlgParse {
    static func page(_ data: Data) -> (messages: [DlgMessage], hasMore: Bool)? {
        guard let o = JSONRead.object(data), JSONRead.bool(o, "ok") else { return nil }
        return (DlgMessage.list(o), JSONRead.bool(o, "has_more"))
    }
    static func around(_ data: Data) -> (messages: [DlgMessage], hasMoreBefore: Bool, hasMoreAfter: Bool)? {
        guard let o = JSONRead.object(data), JSONRead.bool(o, "ok") else { return nil }
        return (DlgMessage.list(o), JSONRead.bool(o, "has_more_before"), JSONRead.bool(o, "has_more_after"))
    }
    static func at(_ data: Data) -> Int? {
        guard let o = JSONRead.object(data), JSONRead.bool(o, "ok") else { return nil }
        return JSONRead.int(o, "seq")
    }
    static func deleted(_ data: Data) -> (deleted: [String], facts: [(id: String, text: String)])? {
        guard let o = JSONRead.object(data), JSONRead.bool(o, "ok") else { return nil }
        let facts: [(id: String, text: String)] = JSONRead.objects(o, "facts").compactMap { f in
            guard let id = JSONRead.string(f, "id"), let t = JSONRead.string(f, "text") else { return nil }
            return (id, t)
        }
        return (JSONRead.strings(o, "deleted"), facts)
    }
    /// `capped`: the server stopped at its newest 1,000 matches, so `count` reads "1000+".
    static func search(_ data: Data) -> (hits: [SearchHit], count: Int, capped: Bool)? {
        guard let o = JSONRead.object(data), JSONRead.bool(o, "ok") else { return nil }
        let hits = JSONRead.objects(o, "hits").compactMap(SearchHit.init(json:))
        return (hits, JSONRead.int(o, "count") ?? hits.count, JSONRead.bool(o, "capped"))
    }
    /// {ok, mark: DlgMark|null}. nil = the call failed; .some(nil) = the message has no marks now.
    static func mark(_ data: Data) -> DlgMark??  {
        guard let o = JSONRead.object(data), JSONRead.bool(o, "ok") else { return nil }
        return .some((o["mark"] as? JSONObject).flatMap(DlgMark.init(json:)))
    }
    static func marks(_ data: Data) -> [DlgMark]? {
        guard let o = JSONRead.object(data), JSONRead.bool(o, "ok") else { return nil }
        return JSONRead.objects(o, "marks").compactMap(DlgMark.init(json:))
    }
    /// {all, media, files, links, plans}; non-numbers dropped.
    static func counters(_ data: Data) -> [String: Int]? {
        guard let o = JSONRead.object(data), JSONRead.bool(o, "ok") else { return nil }
        let c = o["counts"] as? JSONObject
        var out: [String: Int] = [:]
        for k in (c ?? [:]).keys { if let v = JSONRead.int(c, k) { out[k] = v } }
        return out
    }
    static func items(_ data: Data) -> (items: [DlgItem], hasMore: Bool)? {
        guard let o = JSONRead.object(data), JSONRead.bool(o, "ok") else { return nil }
        return (JSONRead.objects(o, "items").compactMap(DlgItem.init(json:)), JSONRead.bool(o, "has_more"))
    }
}

/// The dialogue lines of /agents/turn. Every other line is a TeamLine or a Lia 2.0 event.
enum DlgStreamEvent: Equatable {
    /// A stored message: the person's first, then each agent's when it ends.
    case message(DlgMessage)
    case task(AgentTask)
    case taskUpdate(AgentTask)
    /// A task this turn made, to be started in its owner's own dialogue (POST /agents/turn with `task_run`).
    /// (team_huddle / team_route lines are gone with the Team router.)
    case taskRun(dlg: String, task: AgentTask)

    /// Takes the raw SSE line ("data: {...}") as streamTeam yields it, or the bare JSON.
    static func parse(line: String) -> DlgStreamEvent? {
        let o: JSONObject?
        if line.hasPrefix("data:") { o = TeamLine.object(line) } else { o = JSONRead.object(Data(line.utf8)) }
        guard let o, let type = JSONRead.string(o, "type") else { return nil }
        switch type {
        case "msg": return DlgMessage(json: o["message"] as? JSONObject).map { .message($0) }
        case "task": return AgentTask(json: o["task"] as? JSONObject).map { .task($0) }
        case "task_update": return AgentTask(json: o["task"] as? JSONObject).map { .taskUpdate($0) }
        case "task_run":
            guard let d = JSONRead.string(o, "dlg"), !d.isEmpty, let t = AgentTask(json: o["task"] as? JSONObject) else { return nil }
            return .taskRun(dlg: d, task: t)
        default: return nil
        }
    }
}

/// ("a strange service line 'Handoff ...'"): the words a hand-over row shows. A row stored holds
/// the message as written; an older one holds the model's packet ("[handoff] X → Y (task t): words\n\nWhat was said
/// just before ..."), read back here to its words. Who wrote it: the server's `by`, else the old head's "The person".
enum DlgHandoff {
    static func shown(_ text: String) -> String {
        guard text.hasPrefix("[handoff]") else { return text }
        let head = text.components(separatedBy: "\n\nWhat was said just before").first ?? text
        guard let r = head.range(of: "): ") ?? head.range(of: "):") else {
            // "[handoff] Lia → Met: words" (a thread's hand-over)
            if let c = head.range(of: ": ") { return String(head[c.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines) }
            return ""
        }
        return String(head[r.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
    }
    static func byPerson(_ m: DlgMessage) -> Bool {
        if let b = m.origin?.by, !b.isEmpty { return b == "person" }
        return m.text.hasPrefix("[handoff] The person")
    }
}

extension DlgStreamEvent {
    /// The dialogue a stream line belongs to (its top-level `dlg`), nil when it names none (task lines, the
    /// run's own lines). A line naming another dialogue is never drawn in this one (an older server worked a task inside
    /// the caller's stream, and its messages went into the caller's chat). Fast path: the line names `own`.
    static func dlg(of line: String, own: String) -> String? {
        if line.contains("\"dlg\":\"" + own + "\"") { return own }
        guard line.contains("\"dlg\":\"") else { return nil }
        let o: JSONObject? = line.hasPrefix("data:") ? TeamLine.object(line) : JSONRead.object(Data(line.utf8))
        return o.flatMap { JSONRead.string($0, "dlg") }
    }
}

/// Keeping a loaded window of a dialogue in order as pages and stream messages arrive.
enum DlgMerge {
    /// Union by id, newer copy wins, sorted by seq (then ts).
    static func merge(_ a: [DlgMessage], _ b: [DlgMessage]) -> [DlgMessage] {
        var byId: [String: DlgMessage] = [:]
        var order: [String] = []
        for m in a + b {
            if byId[m.id] == nil { order.append(m.id) }
            byId[m.id] = m
        }
        return order.compactMap { byId[$0] }.enumerated().sorted { l, r in
            if l.element.seq != r.element.seq { return l.element.seq < r.element.seq }
            return l.offset < r.offset
        }.map(\.element)
    }
    /// The `before` cursor for the next older page: the smallest seq loaded.
    static func before(_ list: [DlgMessage]) -> Int? { list.map(\.seq).filter { $0 > 0 }.min() }
}

/// The body of POST /agents/turn for a dialogue.
enum DlgTurn {
    static func body(profile: String, dlg: String, text: String, origin: DlgOrigin.Surface? = nil,
                     extra: JSONObject = [:]) -> JSONObject {
        var b = extra
        b["profile"] = profile
        b["dlg"] = dlg
        b["text"] = text
        if let origin { b["origin"] = ["surface": origin.rawValue] }
        b.removeValue(forKey: "thread_id")
        // This Mac starts a task in its owner's own dialogue (task_run); the server then never works it here.
        b["handoff"] = "deferred"
        return b
    }
    /// The text and extra of the turn that starts a task in its owner's dialogue.
    static let taskRunPrefix = "[task_run] "
    static func taskRunText(_ id: String) -> String { taskRunPrefix + id }
    static func taskRunId(_ text: String) -> String? {
        guard text.hasPrefix(taskRunPrefix) else { return nil }
        let id = String(text.dropFirst(taskRunPrefix.count)).trimmingCharacters(in: .whitespaces)
        return id.isEmpty ? nil : id
    }
}

/// Who answers the person's message in a dialogue. Every dialogue is one agent's (Lia's is
/// "team"); no router. An @Name of another agent goes to that agent (it says here, in one sentence, that it took the
/// task, then works it in its own dialogue); the dialogue's agent answers only when nobody else is named or it is
/// named itself. The same rule as the server's agDlgRoute, used for who is drawn "writing" before the server says.
enum DlgMention {
    /// The agent ids named with "@Name" in order (names matched case-insensitively against `names`: id -> name).
    static func named(_ text: String, names: [String: String]) -> [String] {
        var out: [String] = []
        let byName = Dictionary(names.map { ($0.value.lowercased(), $0.key) }, uniquingKeysWith: { a, _ in a })
        guard let rx = try? NSRegularExpression(pattern: #"@([A-Za-z]{2,12})\b"#) else { return [] }
        let ns = text as NSString
        for m in rx.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            let n = ns.substring(with: m.range(at: 1)).lowercased()
            if let id = byName[n], !out.contains(id) { out.append(id) }
        }
        return out
    }
    /// The agent drawn "writing" first: the dialogue's own agent, unless only others are named (then the first of them,
    /// whose acknowledgement comes first).
    static func firstAnswerer(_ text: String, dlg: String, names: [String: String]) -> String {
        let own = DialogueSummary.agent(forDlg: dlg)
        let n = named(text, names: names)
        let others = n.filter { $0 != own }
        if others.isEmpty || n.contains(own) { return own }
        return others[0]
    }
    /// An agent's acknowledgement of a task in another agent's dialogue: its own message there carrying the task.
    static func isAck(agent: String?, taskId: String?, isTaskCard: Bool, dlg: String) -> Bool {
        guard let a = agent, !a.isEmpty, let t = taskId, !t.isEmpty, !isTaskCard else { return false }
        return a != DialogueSummary.agent(forDlg: dlg)
    }
}

// MARK: -: the person's marks on a message (server-side, every Mac shows them)

/// 👍/👎, favourite and pin of one dialogue message (GET /agents/marks, POST /agents/feedback). `id` is the message's
/// server id (`DlgMessage.id`).
struct DlgMark: Equatable {
    let id: String
    /// "up" | "down" | nil (follows the reaction - 👎 down, any other up)
    var verdict: String?
    /// The emoji the person reacted with (one of `DlgMark.reactions`), nil = none.
    var reaction: String?
    var fav: Bool
    /// When it was pinned; pins sort by it. nil = not pinned.
    var pinTs: Date?
    /// The marked message's time, first 200 characters and agent (GET /agents/marks), for the Favourites list.
    var messageTs: Date?
    var text: String = ""
    var agent: String?

    /// What the Mac offers, in picker order (the server accepts exactly these). The first is the quick one.
    static let reactions = ["❤️", "👍", "👎", "🔥", "🤝", "🤣"]

    init(id: String, verdict: String? = nil, reaction: String? = nil, fav: Bool = false, pinTs: Date? = nil) {
        self.id = id; self.verdict = verdict; self.reaction = reaction; self.fav = fav; self.pinTs = pinTs
    }
    init?(json o: JSONObject) {
        guard let id = JSONRead.string(o, "id"), !id.isEmpty else { return nil }
        let v = JSONRead.string(o, "verdict")
        let r = JSONRead.string(o, "reaction")
        self.init(id: id, verdict: v == "up" || v == "down" ? v : nil, reaction: r.flatMap { DlgMark.reactions.contains($0) ? $0 : nil }, fav: JSONRead.bool(o, "fav"),
                  pinTs: JSONRead.double(o, "pin_ts").map { Date(timeIntervalSince1970: $0 / 1000) })
        messageTs = JSONRead.double(o, "ts").flatMap { $0 > 0 ? Date(timeIntervalSince1970: $0 / 1000) : nil }
        text = JSONRead.string(o, "text") ?? ""
        agent = JSONRead.string(o, "agent")
    }
    var isEmpty: Bool { verdict == nil && reaction == nil && !fav && pinTs == nil }
}

// MARK: - the messenger's selection mode

/// The messages picked in the thread's selection mode: a click toggles one, a shift-click picks every message between
/// the last one clicked and this one (thread order).
struct DlgSelection: Equatable {
    private(set) var picked: Set<String> = []
    /// The last message clicked (where a shift-click's range starts).
    private(set) var anchor: String?

    var count: Int { picked.count }
    var isEmpty: Bool { picked.isEmpty }
    func contains(_ id: String) -> Bool { picked.contains(id) }

    mutating func toggle(_ id: String) {
        if picked.contains(id) { picked.remove(id) } else { picked.insert(id) }
        anchor = id
    }

    /// Server: the parts of one answer go together - all of `group` (which holds `id`) on, or all off.
    mutating func toggle(_ id: String, group: [String]) {
        let g = group.contains(id) ? group : group + [id]
        if picked.contains(id) { picked.subtract(g) } else { picked.formUnion(g) }
        anchor = id
    }

    /// Shift-click with the clicked message's answer parts joining the run.
    mutating func extend(to id: String, in order: [String], group: [String]) {
        extend(to: id, in: order)
        if picked.contains(id) { picked.formUnion(group) }
    }

    /// Shift-click: the run from the anchor to `id` joins the selection; with no anchor in `order`, a plain toggle.
    mutating func extend(to id: String, in order: [String]) {
        guard let a = anchor, let i = order.firstIndex(of: a), let j = order.firstIndex(of: id) else { toggle(id); return }
        for k in min(i, j)...max(i, j) { picked.insert(order[k]) }
        anchor = id
    }

    /// The picked ids in thread order (an id no longer in `order` is left out).
    func ordered(_ order: [String]) -> [String] { order.filter { picked.contains($0) } }

    /// Only the ids still in the thread stay picked (a deleted message leaves the selection).
    mutating func keep(_ order: [String]) {
        let s = Set(order)
        picked.formIntersection(s)
        if let a = anchor, !s.contains(a) { anchor = nil }
    }

    mutating func clear() { picked = []; anchor = nil }
}

/// Picked messages as one text, each under its author and time: Forward (sent as the person's message, quoted) and
/// Copy (plain).
enum DlgQuoteText {
    struct Part: Equatable {
        let who: String
        /// The message's time (ms since 1970, as `ChatMessage.ts`); nil: none known.
        let ts: Double?
        let text: String
        init(who: String, ts: Double?, text: String) { self.who = who; self.ts = ts; self.text = text }
    }

    /// The quote line every forward starts with (the bubble's quote strip reads it: ChatForwardDraft.prefix).
    static let forwardPrefix = "Forwarded from "

    /// "14:02" on the day of `now`, else "Oct 21, 14:02" ("Oct 21 2025, 14:02" in another year).
    static func time(_ ts: Double?, now: Date = Date(), zone: TimeZone = .current) -> String {
        guard let d = DlgTime.date(ts) else { return "" }
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = zone
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = zone
        if cal.isDate(d, inSameDayAs: now) { f.dateFormat = "HH:mm" }
        else if cal.component(.year, from: d) == cal.component(.year, from: now) { f.dateFormat = "MMM d, HH:mm" }
        else { f.dateFormat = "MMM d yyyy, HH:mm" }
        return f.string(from: d)
    }

    /// "Met, 14:02:" (no time known: "Met:").
    static func head(_ p: Part, now: Date = Date(), zone: TimeZone = .current) -> String {
        let t = time(p.ts, now: now, zone: zone)
        return p.who + (t.isEmpty ? "" : ", " + t) + ":"
    }

    private static func body(_ s: String) -> String { s.trimmingCharacters(in: .whitespacesAndNewlines) }

    /// The message that goes to another agent: a quote line naming who is forwarded (and how many), then each message
    /// under its author and time, its lines quoted.
    static func forward(_ parts: [Part], now: Date = Date(), zone: TimeZone = .current) -> String {
        let kept = parts.filter { !body($0.text).isEmpty }
        guard !kept.isEmpty else { return "" }
        var names: [String] = []
        for p in kept where !names.contains(p.who) { names.append(p.who) }
        var first = "> " + forwardPrefix + names.joined(separator: ", ")
        if kept.count > 1 { first += " (\(kept.count) messages)" }
        let blocks = kept.map { p -> String in
            let lines = body(p.text).components(separatedBy: "\n").map { $0.isEmpty ? ">" : "> " + $0 }
            return head(p, now: now, zone: zone) + "\n" + lines.joined(separator: "\n")
        }
        return first + "\n\n" + blocks.joined(separator: "\n\n")
    }

    /// Copy: one message is its words alone; several are each under its author and time, a blank line between.
    static func copy(_ parts: [Part], now: Date = Date(), zone: TimeZone = .current) -> String {
        let kept = parts.filter { !body($0.text).isEmpty }
        if kept.count == 1 { return body(kept[0].text) }
        return kept.map { head($0, now: now, zone: zone) + "\n" + body($0.text) }.joined(separator: "\n\n")
    }
}

/// An answer the server splits into several messages (by paragraphs) shows as consecutive bubbles
/// with a short stagger, not all at once. The thread asks this queue which new agent messages show now and which wait.
struct DlgStagger: Equatable {
    /// The pause between two bubbles of one answer.
    static let gap: TimeInterval = 0.28
    /// More new messages than this at once is a page (loaded, not arriving): it shows whole.
    static let maxBurst = 4

    /// The messages waiting to show, oldest first.
    private(set) var held: [String] = []
    /// When the next one may show.
    private(set) var nextAt: Date = .distantPast

    /// New agent messages arrived (thread order); returns the ones that show now (the rest are `held`).
    mutating func arrive(_ ids: [String], at now: Date) -> [String] {
        guard !ids.isEmpty else { return [] }
        if ids.count > Self.maxBurst && held.isEmpty { return ids }
        var shown: [String] = []
        for id in ids where !held.contains(id) {
            if held.isEmpty && now >= nextAt {
                shown.append(id)
                nextAt = now.addingTimeInterval(Self.gap)
            } else {
                held.append(id)
            }
        }
        return shown
    }

    /// The next held message, when its time has come (nil: none, or not yet).
    mutating func pop(at now: Date) -> String? {
        guard !held.isEmpty, now >= nextAt.addingTimeInterval(-0.02) else { return nil }
        nextAt = now.addingTimeInterval(Self.gap)
        return held.removeFirst()
    }

    /// Everything shows at once (the dialogue closed, the window was replaced).
    mutating func flush() { held = []; nextAt = .distantPast }

    func isHeld(_ id: String) -> Bool { held.contains(id) }
}

/// Server: what an agent did, from the server (GET /agents/items?kind=work) - "Searched the web: ...",
/// "Made 4 drafts", "Made flights.xlsx", "Prepared a change: ..." - for "What did <Agent> do?", newest first.
struct DlgWork: Equatable, Identifiable {
    let msgId: String
    var dlg: String
    var ts: Date?
    var title: String
    var id: String { msgId + "|" + title }

    init(msgId: String, dlg: String, ts: Date?, title: String) {
        self.msgId = msgId; self.dlg = dlg; self.ts = ts; self.title = title
    }
    init?(json o: JSONObject) {
        let k = JSONRead.string(o, "kind") ?? "work"
        let t = (JSONRead.string(o, "title") ?? JSONRead.string(o, "name") ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard k == "work", !t.isEmpty else { return nil }
        self.init(msgId: JSONRead.string(o, "msg_id") ?? "", dlg: JSONRead.string(o, "dlg") ?? "team",
                  ts: DlgTime.date(JSONRead.double(o, "ts")), title: t)
    }

    /// The answer's items, newest first (nil: not an ok answer).
    static func parse(_ data: Data) -> [DlgWork]? {
        guard let o = JSONRead.object(data), JSONRead.bool(o, "ok") else { return nil }
        let all = JSONRead.objects(o, "items").compactMap(DlgWork.init(json:))
        return all.enumerated().sorted { a, b in
            let x = a.element.ts ?? .distantPast, y = b.element.ts ?? .distantPast
            return x != y ? x > y : a.offset < b.offset
        }.map(\.element)
    }
}
