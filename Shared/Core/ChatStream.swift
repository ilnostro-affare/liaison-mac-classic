import Foundation

/// One frame of POST /intelligence/chat. The worker writes `data:{json}\n\n` per event
/// (the server). Event names and fields read from the server.
enum ChatEvent {
    case reason(String)
    case delta(String)
    case actStart(id: String, tool: String, label: String, fields: [String] = [], status: String? = nil)
    case actDone(id: String)
    case webStart(query: String)
    case webDone(query: String, count: Int, hosts: [String])
    case progStart
    case progDone
    case codeStart
    case codeDelta(String)
    case code
    case block(ChatBlock)
    /// A newer trend for the same period replaces the earlier ones.
    case blockSupersede(period: String)
    /// Lia 1.4 stopped on a change (Auto / Manual), on a setting (Manual) or with a plan (Plan).
    case gate(JSONObject)
    case ask(JSONObject)
    case plan(JSONObject)
    case ents([String: ChatEntity])
    case done(cites: [ChatCite], ms: Int?)
    case error(String)
    /// Lia 2.0's trace (AgentTrace.swift), yielded next to the ordinary event of the same line.
    case agent(AgentEvent)
    case ignored(String)

    /// nil for anything that is not a `data:` line with a JSON object carrying a `type`.
    static func parse(line: String) -> ChatEvent? {
        guard line.hasPrefix("data:") else { return nil }
        let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
        guard let o = JSONRead.object(Data(payload.utf8)), let type = JSONRead.string(o, "type") else { return nil }
        switch type {
        case "reason": return .reason(JSONRead.string(o, "text") ?? "")
        case "delta": return .delta(JSONRead.string(o, "text") ?? "")
        case "act_start":
            let tool = JSONRead.string(o, "tool") ?? ""
            return .actStart(id: JSONRead.string(o, "id") ?? tool, tool: tool, label: JSONRead.string(o, "label") ?? DevToolPhrases.labels[tool] ?? tool,
                             fields: JSONRead.strings(o, "fields"), status: JSONRead.string(o, "st"))
        case "act_done": return .actDone(id: JSONRead.string(o, "id") ?? "")
        case "web_start": return .webStart(query: JSONRead.string(o, "q") ?? "")
        case "web_done":
            return .webDone(query: JSONRead.string(o, "q") ?? "", count: JSONRead.int(o, "n") ?? 0, hosts: JSONRead.strings(o, "hosts"))
        case "prog_start": return .progStart
        case "prog_done": return .progDone
        case "code_start": return .codeStart
        case "code_delta": return .codeDelta(JSONRead.string(o, "text") ?? "")
        case "code": return .code
        case "block": return .block(ChatBlock(tool: JSONRead.string(o, "tool"), data: o["data"] as? JSONObject))
        case "ents": return .ents(ChatEntity.map(o["data"] as? JSONObject))
        case "block_supersede": return .blockSupersede(period: JSONRead.string(o, "period") ?? "")
        case "gate": return (o["gate"] as? JSONObject).map { .gate($0) } ?? .ignored(type)
        case "ask": return (o["ask"] as? JSONObject).map { .ask($0) } ?? .ignored(type)
        case "plan": return (o["plan"] as? JSONObject).map { .plan($0) } ?? .ignored(type)
        case "done":
            let usage = o["usage"] as? JSONObject
            return .done(cites: JSONRead.objects(o, "cites").compactMap(ChatCite.init(json:)), ms: JSONRead.int(usage, "ms"))
        case "error": return .error(JSONRead.string(o, "message") ?? "Something went wrong.")
        default: return .ignored(type)
        }
    }
}

/// The assistant turn while it streams. A pure reducer: the view model feeds events, the UI reads it.
struct LiveTurn: Equatable {
    var reasoning = ""
    var text = ""
    var timeline = Timeline()
    var blocks: [ChatBlock] = []
    var cites: [ChatCite] = []
    var ents: [String: ChatEntity] = [:]
    /// What the turn stopped on, as the stream sent it (kept whole on the message).
    var gateJSON: String?
    var askJSON: String?
    var planJSON: String?
    /// The write door at work right now, named for the step chip ("Budget", "Ad set").
    var actStep: String?
    var error: String?
    var finished = false
    var durationMs: Int?
    /// The line that says what she is doing now (ai.js).
    var status = LiveStatus()
    let startedAt: Double

    init(startedAt: Double = Date().timeIntervalSince1970 * 1000) {
        self.startedAt = startedAt
    }

    /// Nothing visible is happening yet: no open phase and no text.
    var isThinking: Bool { !finished && text.isEmpty && timeline.phases.allSatisfy(\.done) }

    mutating func apply(_ event: ChatEvent, now: Double = Date().timeIntervalSince1970 * 1000) {
        switch event {
        case .reason(let s): reasoning += s
        case .delta(let s): text += s
        case .block(let b):
            if !blocks.contains(where: { $0.id == b.id }) { blocks.append(b) }
        case .ents(let m):
            ents.merge(m) { _, new in new }
        case .blockSupersede(let period):
            // Earlier trend blocks for this period go; the newest one stays (the server).
            guard !period.isEmpty else { break }
            let trends = blocks.indices.filter { blocks[$0].tool == "trend" || blocks[$0].kind == "trend" }
                .filter { JSONRead.string(blocks[$0].raw, "period") == period }
            for i in trends.dropLast().reversed() { blocks.remove(at: i) }
        case let .actStart(_, tool, _, fields, status):
            if RunSteps.doors.contains(tool) { actStep = RunSteps.actName(tool: tool, fields: fields, status: status) }
        case .gate(let o): gateJSON = LiveTurn.encode(o)
        case .ask(let o): askJSON = LiveTurn.encode(o)
        case .plan(let o): planJSON = LiveTurn.encode(o)
        case let .done(cites, ms):
            self.cites = cites
            durationMs = ms
        case .error(let message):
            error = message
        default:
            break
        }
        timeline.collect(event, reasoning: reasoning, now: now)
        let think = timeline.phases.last(where: { $0.kind == .think && !$0.done })?.title
        status.on(event, thinkTitle: think, now: now)
        switch event {
        case .done, .error: finish(now: now)
        default: break
        }
    }

    mutating func finish(now: Double = Date().timeIntervalSince1970 * 1000) {
        finished = true
        timeline.finish(now: now, startedAt: startedAt, reasoning: reasoning)
    }

    /// What the thread keeps once the stream is over.
    func message(id: String) -> ChatMessage {
        ChatMessage(id: id, role: .assistant, content: text, reasoning: reasoning.isEmpty ? nil : reasoning,
                    blocks: blocks, cites: cites, timeline: timeline.isEmpty ? nil : timeline,
                    gateJSON: gateJSON, askJSON: askJSON, planJSON: planJSON)
    }

    static func encode(_ o: JSONObject) -> String? {
        (try? JSONSerialization.data(withJSONObject: o)).flatMap { String(data: $0, encoding: .utf8) }
    }
}


extension ChatEvent: Equatable {
    static func == (a: ChatEvent, b: ChatEvent) -> Bool {
        switch (a, b) {
        case let (.reason(x), .reason(y)), let (.delta(x), .delta(y)), let (.codeDelta(x), .codeDelta(y)), let (.error(x), .error(y)),
             let (.ignored(x), .ignored(y)), let (.webStart(x), .webStart(y)), let (.actDone(x), .actDone(y)), let (.blockSupersede(x), .blockSupersede(y)):
            return x == y
        case let (.actStart(i1, t1, l1, f1, s1), .actStart(i2, t2, l2, f2, s2)):
            return i1 == i2 && t1 == t2 && l1 == l2 && f1 == f2 && s1 == s2
        case let (.webDone(q1, n1, h1), .webDone(q2, n2, h2)): return q1 == q2 && n1 == n2 && h1 == h2
        case (.progStart, .progStart), (.progDone, .progDone), (.codeStart, .codeStart), (.code, .code): return true
        case let (.block(x), .block(y)): return x == y
        case let (.ents(x), .ents(y)): return x == y
        case let (.done(c1, m1), .done(c2, m2)): return c1 == c2 && m1 == m2
        case let (.gate(x), .gate(y)), let (.ask(x), .ask(y)), let (.plan(x), .plan(y)):
            return NSDictionary(dictionary: x).isEqual(to: y)
        default: return false
        }
    }
}
