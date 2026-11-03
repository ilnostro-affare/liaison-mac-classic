import Foundation

/// The "ledger" of one assistant turn: thinking, tool calls, web searches and code runs, in the order
/// they happened. A line for line port of tlCollect / tlNormalize in ai.js, so a turn written by the
/// app and a turn written by the web read the same after a reload, in both places.
struct TimelineItem: Equatable {
    let id: String
    var label: String
    var durationMs: Int?
}

struct TimelinePhase: Equatable, Identifiable {
    enum Kind: String { case think, tools, web, code }

    let id: Int
    let kind: Kind
    var title: String
    var text = ""
    var query = ""
    var hosts: [String] = []
    var sources = 0
    var calls = 0
    var items: [TimelineItem] = []
    var code = ""
    var startedAt: Double = 0
    var durationMs: Int?
    var done = false
    var reasonOffset = 0

    init(id: Int, kind: Kind, title: String, startedAt: Double = 0) {
        self.id = id; self.kind = kind; self.title = title; self.startedAt = startedAt
    }
}

struct Timeline: Equatable {
    var phases: [TimelinePhase] = []
    var workMs: Int?
    private var nextId = 0

    init() {}

    var isEmpty: Bool { phases.isEmpty }
    var thinkMs: Int { phases.filter { $0.kind == .think }.reduce(0) { $0 + ($1.durationMs ?? 0) } }

    // MARK: titles, same wording as ai.js

    /// The last **bold heading** of a reasoning segment names the phase (thinkLabel).
    static func label(in text: String) -> String {
        var last = ""
        var rest = Substring(text)
        while let open = rest.range(of: "**") {
            let after = rest[open.upperBound...]
            guard let close = after.range(of: "**") else { break }
            let inner = after[..<close.lowerBound]
            if (2...80).contains(inner.count), !inner.contains("*") { last = String(inner).trimmingCharacters(in: .whitespaces) }
            rest = after[close.upperBound...]
        }
        return last
    }

    /// Removes the first occurrence of **title** and leading whitespace (tlStripTitle).
    static func strip(_ text: String, title: String) -> String {
        guard !title.isEmpty, let r = text.range(of: "**\(title)**") else { return text }
        var out = text
        out.removeSubrange(r)
        return String(out.drop(while: { $0.isWhitespace }))
    }

    static func webTitle(done: Bool, calls: Int, sources n: Int) -> String {
        let c = max(calls, 1)
        if !done && n == 0 { return "Searching the web" }
        if n == 0 { return "Searched the web, nothing found" }
        return "Searched the web" + (c > 1 ? ", \(c) queries" : "") + ", \(n) " + (n == 1 ? "source" : "sources")
    }

    static func toolsTitle(_ items: [TimelineItem]) -> String {
        items.count == 1 ? (items[0].label.isEmpty ? "Reading the data" : items[0].label) : "Reading the data, \(items.count) requests"
    }

    // MARK: collecting (tlCollect)

    private var openIndex: Int? {
        guard let i = phases.indices.last, !phases[i].done else { return nil }
        return i
    }

    private mutating func push(_ kind: TimelinePhase.Kind, title: String, now: Double) -> Int {
        nextId += 1
        phases.append(TimelinePhase(id: nextId, kind: kind, title: title, startedAt: now))
        return phases.count - 1
    }

    private mutating func close(_ i: Int, now: Double, reasoning: String) {
        phases[i].done = true
        phases[i].durationMs = max(0, Int(now - phases[i].startedAt))
        if phases[i].kind == .think { refreshThink(i, reasoning: reasoning) }
    }

    private mutating func refreshThink(_ i: Int, reasoning: String) {
        let off = min(phases[i].reasonOffset, reasoning.count)
        let raw = String(reasoning.dropFirst(off))
        let t = Timeline.label(in: raw)
        phases[i].title = t.isEmpty ? "Thinking" : t
        phases[i].text = Timeline.strip(raw, title: t)
    }

    private mutating func closeThink(now: Double, reasoning: String) {
        if let i = openIndex, phases[i].kind == .think { close(i, now: now, reasoning: reasoning) }
    }

    private mutating func closeOpenTools(now: Double, reasoning: String) {
        if let i = openIndex, phases[i].kind == .tools { close(i, now: now, reasoning: reasoning) }
    }

    /// `reasoning` is the full reasoning text AFTER the event was applied to the turn.
    mutating func collect(_ event: ChatEvent, reasoning: String, now: Double) {
        switch event {
        case .reason(let s):
            if let i = openIndex, phases[i].kind == .think {
                refreshThink(i, reasoning: reasoning)
            } else {
                if let i = openIndex { close(i, now: now, reasoning: reasoning) }
                let i = push(.think, title: "Thinking", now: now)
                phases[i].reasonOffset = max(0, reasoning.count - s.count)
                refreshThink(i, reasoning: reasoning)
            }
        case let .actStart(id, _, label, _, _):
            closeThink(now: now, reasoning: reasoning)
            let i: Int
            if let o = openIndex, phases[o].kind == .tools { i = o } else { i = push(.tools, title: "", now: now) }
            phases[i].items.append(TimelineItem(id: id, label: label, durationMs: nil))
            phases[i].title = Timeline.toolsTitle(phases[i].items)
        case .actDone(let id):
            for i in phases.indices.reversed() where phases[i].kind == .tools {
                if let j = phases[i].items.firstIndex(where: { $0.id == id && $0.durationMs == nil }) {
                    phases[i].items[j].durationMs = max(0, Int(now - phases[i].startedAt))
                    return
                }
            }
        case .webStart(let q):
            closeThink(now: now, reasoning: reasoning)
            closeOpenTools(now: now, reasoning: reasoning)
            let i = push(.web, title: "Searching the web", now: now)
            phases[i].query = q
        case let .webDone(q, n, hosts):
            var idx = phases.indices.last(where: { phases[$0].kind == .web && !phases[$0].done })
            if idx == nil {
                closeThink(now: now, reasoning: reasoning)
                idx = push(.web, title: "", now: now)
            }
            let i = idx!
            if !q.isEmpty { phases[i].query = q }
            phases[i].sources += n
            phases[i].calls += 1
            for h in hosts where !phases[i].hosts.contains(h) && phases[i].hosts.count < 8 { phases[i].hosts.append(h) }
            close(i, now: now, reasoning: reasoning)
            phases[i].title = Timeline.webTitle(done: true, calls: phases[i].calls, sources: phases[i].sources)
        case .codeStart:
            closeThink(now: now, reasoning: reasoning)
            closeOpenTools(now: now, reasoning: reasoning)
            _ = push(.code, title: "Writing code", now: now)
        case .codeDelta(let s):
            let i = phases.indices.last(where: { phases[$0].kind == .code && !phases[$0].done }) ?? {
                closeThink(now: now, reasoning: reasoning)
                closeOpenTools(now: now, reasoning: reasoning)
                return push(.code, title: "Writing code", now: now)
            }()
            phases[i].code = String((phases[i].code + s).prefix(4000))
        case .code:
            let i = phases.indices.last(where: { phases[$0].kind == .code && !phases[$0].done }) ?? push(.code, title: "", now: now)
            close(i, now: now, reasoning: reasoning)
            phases[i].title = "Running python"
        case .delta, .done, .error:
            closeThink(now: now, reasoning: reasoning)
            if let i = openIndex, phases[i].kind != .think { close(i, now: now, reasoning: reasoning) }
        case .progStart, .progDone, .block, .blockSupersede, .ents, .gate, .ask, .plan, .ignored, .agent:
            break
        }
    }

    mutating func finish(now: Double, startedAt: Double, reasoning: String) {
        for i in phases.indices where !phases[i].done { close(i, now: now, reasoning: reasoning) }
        workMs = max(0, Int(now - startedAt))
    }

    // MARK: persistence (tlNormalize and chat-save whitelist)

    func saved() -> JSONObject? {
        let ph: [JSONObject] = phases
            .filter { $0.done && ($0.kind != .think || !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) }
            .prefix(60)
            .map { p in
                var o: JSONObject = ["k": p.kind.rawValue, "d": p.durationMs ?? 0, "t": p.title]
                if p.kind == .web {
                    o["q"] = String(p.query.prefix(200)); o["hosts"] = Array(p.hosts.prefix(8)); o["n"] = p.sources; o["calls"] = max(p.calls, 1)
                }
                if !p.text.isEmpty { o["txt"] = String(p.text.prefix(6000)) }
                if p.kind == .tools { o["items"] = p.items.prefix(20).map { ["label": String($0.label.prefix(120)), "d": $0.durationMs ?? 0] as JSONObject } }
                if !p.code.isEmpty { o["src"] = String(p.code.prefix(4000)) }
                return o
            }
        guard !ph.isEmpty else { return nil }
        return ["work": workMs ?? 0, "think": thinkMs, "ph": ph]
    }

    init?(json: JSONObject?) {
        let ph = JSONRead.objects(json, "ph")
        guard !ph.isEmpty else { return nil }
        self.init()
        for p in ph {
            guard let k = JSONRead.string(p, "k"), let kind = TimelinePhase.Kind(rawValue: k) else { continue }
            nextId += 1
            var phase = TimelinePhase(id: nextId, kind: kind, title: JSONRead.string(p, "t") ?? "")
            phase.done = true
            phase.durationMs = JSONRead.int(p, "d")
            phase.text = JSONRead.string(p, "txt") ?? ""
            phase.query = JSONRead.string(p, "q") ?? ""
            phase.hosts = JSONRead.strings(p, "hosts")
            phase.sources = JSONRead.int(p, "n") ?? 0
            phase.calls = JSONRead.int(p, "calls") ?? 0
            phase.code = JSONRead.string(p, "src") ?? ""
            phase.items = JSONRead.objects(p, "items").enumerated().map { TimelineItem(id: "i\($0.offset)", label: JSONRead.string($0.element, "label") ?? "", durationMs: JSONRead.int($0.element, "d")) }
            if phase.title.isEmpty {
                phase.title = kind == .tools ? Timeline.toolsTitle(phase.items) : (kind == .web ? Timeline.webTitle(done: true, calls: phase.calls, sources: phase.sources) : (kind == .code ? "Running python" : "Thinking"))
            }
            phases.append(phase)
        }
        if phases.isEmpty { return nil }
        workMs = JSONRead.int(json, "work")
    }

    /// Older turns (or turns saved without a ledger) only carry the reasoning text. Each **heading**
    /// starts a thinking block, so the reader still gets blocks, not one wall of text.
    static func fromReasoning(_ reasoning: String) -> Timeline? {
        let text = reasoning.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        var t = Timeline()
        var sections: [(String, String)] = []
        var currentTitle = ""
        var body: [String] = []
        for line in text.components(separatedBy: "\n") {
            let s = line.trimmingCharacters(in: .whitespaces)
            if s.hasPrefix("**"), s.hasSuffix("**"), s.count > 4, !s.dropFirst(2).dropLast(2).contains("*") {
                if !currentTitle.isEmpty || !body.joined().trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    sections.append((currentTitle, body.joined(separator: "\n")))
                }
                currentTitle = String(s.dropFirst(2).dropLast(2)).trimmingCharacters(in: .whitespaces)
                body = []
            } else {
                body.append(line)
            }
        }
        sections.append((currentTitle, body.joined(separator: "\n")))
        for (title, b) in sections {
            let bodyText = b.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !title.isEmpty || !bodyText.isEmpty else { continue }
            t.nextId += 1
            var p = TimelinePhase(id: t.nextId, kind: .think, title: title.isEmpty ? "Thinking" : title)
            p.text = bodyText
            p.done = true
            t.phases.append(p)
        }
        return t.phases.isEmpty ? nil : t
    }
}
