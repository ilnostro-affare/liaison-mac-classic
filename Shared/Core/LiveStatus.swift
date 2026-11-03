import Foundation

/// The live line above a running turn (ai.js stOnEvent): what Lia is doing now. The thought's heading while
/// she thinks, one of ten phrasings for the tool that runs (a new one every 2.8 s, never repeated within the turn),
/// "Writing the answer" once text streams. Every line stays at least 1.2 s; only the latest waiting one is shown.
struct LiveStatus: Equatable {
    static let dwellMs = 1200.0
    static let rotateMs = 2800.0

    private(set) var text = ""
    private var shownAt = 0.0
    private var req = ""
    private var pending: String?
    private var rotTool: String?
    private var rotKey: String?
    private var rotAt = 0.0
    private var used: [String: [String]] = [:]
    private var stopped = false
    /// For tests: picks among the phrasings not used yet. Not part of equality.
    var pick: ([String]) -> String = { $0.randomElement() ?? "" }

    static func == (a: LiveStatus, b: LiveStatus) -> Bool {
        a.text == b.text && a.shownAt == b.shownAt && a.req == b.req && a.pending == b.pending && a.rotTool == b.rotTool
            && a.rotKey == b.rotKey && a.rotAt == b.rotAt && a.used == b.used && a.stopped == b.stopped
    }

    mutating func on(_ event: ChatEvent, thinkTitle: String?, now: Double) {
        switch event {
        case .reason: request(thinkTitle?.isEmpty == false ? thinkTitle! : "Thinking", now: now)
        case .actStart(let id, let tool, _, _, _): rotate(tool, key: "a:" + id, now: now)
        case .actDone(let id): rotStop("a:" + id)
        case .webStart: rotate("web_search", key: "web", now: now)   // never the query: it arrives in any language
        case .webDone: rotStop("web")
        case .codeStart: rotate("code", key: "code", now: now)
        case .code: rotStop("code")
        case .delta: rotStop(nil); request("Writing the answer", now: now)
        case .done, .error: stopped = true; pending = nil; rotStop(nil)
        default: break
        }
    }

    /// Time passing: a waiting line comes up once the current one has stood its 1.2 s; a call still running moves on.
    @discardableResult
    mutating func tick(now: Double) -> Bool {
        let before = text
        if let p = pending, now - shownAt >= Self.dwellMs { pending = nil; set(p, now: now, force: true) }
        if let tool = rotTool, !stopped, now - rotAt >= Self.rotateMs { rotAt = now; set(phrase(tool), now: now) }
        return text != before
    }

    private mutating func request(_ t: String, now: Double) {
        guard req != t else { return }
        req = t
        set(t, now: now)
    }

    private mutating func rotate(_ tool: String, key: String, now: Double) {
        rotStop(nil)
        req = ""
        set(phrase(tool), now: now)
        rotTool = tool; rotKey = key; rotAt = now
    }

    private mutating func rotStop(_ key: String?) {
        if let key, rotKey != key { return }
        rotTool = nil; rotKey = nil
    }

    private mutating func set(_ t: String, now: Double, force: Bool = false) {
        guard !stopped, !t.isEmpty else { return }
        if !force && shownAt > 0 && now - shownAt < Self.dwellMs { pending = t; return }
        guard text != t else { return }
        text = t; shownAt = now
    }

    private mutating func phrase(_ tool: String) -> String {
        let list = ToolPhrases.all[tool] ?? DevToolPhrases.all[tool] ?? ToolPhrases.all["_default"] ?? ["Working"]
        var u = used[tool] ?? []
        var pool = list.filter { !u.contains($0) }
        if pool.isEmpty { u = []; pool = list }
        let p = pick(pool)
        u.append(p)
        used[tool] = u
        return p
    }
}
