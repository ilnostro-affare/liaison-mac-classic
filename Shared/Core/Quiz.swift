import Foundation

/// The "Quick answer" bar above the input (ai.js quizBarMount / quizBarSync / quizBarAnswered / quizOptOk / _qzPlain).
/// A turn that asks a choice stores a block `{tool, data: {kind: "quiz", question, options: [{label, send, hint}], answered}}`;
/// the bar offers its options as buttons until one is sent, the bar is dismissed, or the person writes anything.
struct QuizOption: Equatable, Identifiable {
    /// The button's text, markdown markers stripped.
    let label: String
    /// What a tap sends: `send`, or the label as written when there is none.
    let send: String
    let hint: String?
    var id: String { send + "|" + label }
}

struct Quiz: Equatable {
    /// The question line, nil for `targeting_fork` or none; 200 characters at most.
    let question: String?
    /// Up to five options that passed `optionOK`.
    let options: [QuizOption]
    /// Made up from prose that asked for an entity without ask_choice; offers only "Choose myself".
    let synthetic: Bool
    let answered: Bool
    /// A choice of campaign, ad set or template: the bar adds "Choose myself / search the whole account".
    let isEntity: Bool

    init(question: String?, options: [QuizOption], synthetic: Bool, answered: Bool, isEntity: Bool) {
        self.question = question; self.options = options; self.synthetic = synthetic
        self.answered = answered; self.isEntity = isEntity
    }

    init?(data: JSONObject?) {
        guard let data, JSONRead.string(data, "kind") == "quiz" else { return nil }
        let rows = ((data["options"] as? [Any]) ?? []).compactMap { $0 as? JSONObject }
        let ok = Array(rows.filter { Quiz.optionOK(JSONRead.string($0, "label") ?? "") }.prefix(5))
        let opts: [QuizOption] = ok.map { o in
            let label = JSONRead.string(o, "label") ?? ""
            let send = JSONRead.string(o, "send") ?? ""
            let hint = JSONRead.string(o, "hint") ?? ""
            return QuizOption(label: Quiz.plain(label), send: send.isEmpty ? label : send, hint: hint.isEmpty ? nil : Quiz.plain(hint))
        }
        let synthetic = Quiz.truthy(data["synthetic"])
        let rawQ = JSONRead.string(data, "question") ?? ""
        let byId = ok.contains { Quiz.matches(JSONRead.string($0, "send") ?? "", #"\(id \d{13,18}\)"#) }
        self.init(question: rawQ.isEmpty || rawQ == "targeting_fork" ? nil : String(rawQ.prefix(200)),
                  options: opts,
                  synthetic: synthetic,
                  answered: Quiz.truthy(data["answered"]),
                  isEntity: synthetic || byId || Quiz.matches(rawQ, Quiz.entityWords))
    }

    /// quizBarMount's early return: fewer than two options (unless synthetic) or already answered.
    var shows: Bool { !answered && (options.count >= 2 || synthetic) }

    /// Tells two quizzes apart for the view (a new quiz resets the bar).
    var key: String { (question ?? "") + "|" + options.map(\.send).joined(separator: "|") + (synthetic ? "|s" : "") }

    /// The block data a synthetic quiz is stored with once it is answered (ai.js pushes `{kind, synthetic, options}`).
    static let syntheticAnsweredData: JSONObject = ["kind": "quiz", "synthetic": 1, "options": [Any](), "answered": 1]

    // MARK: pure rules

    /// quizOptOk: labels that are JSON debris (old chats persisted a malformed parse) never render.
    static func optionOK(_ l: String) -> Bool {
        if l.isEmpty || l.utf16.count > 90 { return false }
        if matches(l, #"[\[\]{}]|":"|^"|"$"#) { return false }
        let open = l.contains("("), close = l.contains(")")
        if open != close { return false }   // "pause)" (Russian) shreds
        return true
    }

    /// _qzPlain: **bold** loses its markers, then any stray * _ ` goes; trimmed.
    static func plain(_ s: String) -> String {
        let unbold = s.replacingOccurrences(of: #"\*\*([^*]+)\*\*"#, with: "$1", options: .regularExpression)
        return unbold.replacingOccurrences(of: "[*_`]", with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The Russian words for template | ad set | campaign, then ad set | adset | campaign | template (case-insensitive).
    static let entityWords = "\u{0448}\u{0430}\u{0431}\u{043b}\u{043e}\u{043d}|\u{0430}\u{0434}\u{0441}\u{0435}\u{0442}|\u{043a}\u{0430}\u{043c}\u{043f}\u{0430}\u{043d}|ad set|adset|campaign|template"

    /// Russian: "choose (template|ad set|campaign)" | "based on which" | "which (ad set|template)".
    static let proseWords = "\u{0432}\u{044b}\u{0431}\u{0435}\u{0440}\u{0438}\u{0442}\u{0435} (\u{0448}\u{0430}\u{0431}\u{043b}\u{043e}\u{043d}|\u{0430}\u{0434}\u{0441}\u{0435}\u{0442}|\u{043a}\u{0430}\u{043c}\u{043f}\u{0430}\u{043d}\u{0438})|\u{043d}\u{0430} \u{043e}\u{0441}\u{043d}\u{043e}\u{0432}\u{0435} \u{043a}\u{0430}\u{043a}\u{043e}\u{0433}\u{043e}|\u{043a}\u{0430}\u{043a}\u{043e}\u{0439} (\u{0430}\u{0434}\u{0441}\u{0435}\u{0442}|\u{0448}\u{0430}\u{0431}\u{043b}\u{043e}\u{043d})"

    /// The model asked an entity choice in prose, without ask_choice.
    static func proseAsksEntity(_ content: String) -> Bool { matches(content, proseWords) }

    /// What "Choose myself" sends for a picked ad set.
    static func pickText(name: String, id: String) -> String { "[quick_action] " + name + " (id " + id + ")" }

    static func matches(_ s: String, _ pattern: String) -> Bool {
        s.range(of: pattern, options: [.regularExpression, .caseInsensitive]) != nil
    }

    /// JavaScript truthiness for the stored flags (`answered: 1`, `true`, ...).
    static func truthy(_ v: Any?) -> Bool {
        guard let v, !(v is NSNull) else { return false }
        if let s = v as? String { return !s.isEmpty }
        if let b = v as? Bool { return b }
        if let i = v as? Int { return i != 0 }
        if let d = v as? Double { return d != 0 && !d.isNaN }
        if let n = v as? NSNumber { return n.doubleValue != 0 }
        return true
    }
}

/// Where the bar's quiz lives: the turn still streaming, or a stored message.
struct QuizSpot: Equatable {
    enum Place: Equatable { case live, message(Int) }
    let place: Place
    let quiz: Quiz
    var key: String {
        switch place {
        case .live: return "live|" + quiz.key
        case .message(let i): return "m\(i)|" + quiz.key
        }
    }
}

enum QuizFind {
    /// ai.js: mid-stream the bar comes from the block event; the newest quiz of the turn wins.
    static func live(_ blocks: [ChatBlock]) -> QuizSpot? {
        guard let q = blocks.reversed().lazy.compactMap({ Quiz(data: $0.raw) }).first, !q.answered else { return nil }
        return QuizSpot(place: .live, quiz: q)
    }

    /// quizBarSync, in its exact shape: walking back from the end, a user message ends the search; the first assistant
    /// message decides - its quiz (when unanswered), or a synthetic one when its prose asked for an entity; nothing else.
    static func active(_ messages: [ChatMessage]) -> QuizSpot? {
        for i in messages.indices.reversed() {
            let m = messages[i]
            if m.role == .user { return nil }
            if let q = m.quizBlock.flatMap({ Quiz(data: $0.raw) }) {
                return q.answered ? nil : QuizSpot(place: .message(i), quiz: q)
            }
            if Quiz.proseAsksEntity(m.content) {
                return QuizSpot(place: .message(i), quiz: Quiz(question: nil, options: [], synthetic: true, answered: false, isEntity: true))
            }
            return nil
        }
        return nil
    }

    /// quizBarAnswered: the message whose quiz any send answers - the newest one holding a quiz block before a user
    /// message, or the last message when its prose made a synthetic one. Nil when nothing is open to close.
    static func toClose(_ messages: [ChatMessage]) -> Int? {
        for i in messages.indices.reversed() {
            let m = messages[i]
            if let q = m.quizBlock.flatMap({ Quiz(data: $0.raw) }) { return q.answered ? nil : i }
            if m.role == .user { return nil }
            if i == messages.count - 1, Quiz.proseAsksEntity(m.content) { return i }
        }
        return nil
    }
}

extension ChatBlock {
    /// A copy with `data` changed; blocks are immutable values.
    func patched(_ f: (inout JSONObject) -> Void) -> ChatBlock {
        var d = raw ?? [:]
        f(&d)
        return ChatBlock(tool: tool, data: d)
    }
}

extension ChatMessage {
    /// The newest quiz block of the message: the one the stream showed in the bar (QuizFind.live) is the one the
    /// saved message offers and marks answered, so a turn with two quizzes does not bring the earlier one back.
    var quizBlock: ChatBlock? { blocks.last { $0.kind == "quiz" } }

    /// Sets `answered: 1` on the quiz block, or stores the synthetic quiz answered, in `blocks` AND in the stored copy
    /// chat-save re-sends, so the bar does not come back on the next open.
    mutating func markQuizAnswered() {
        if let k = blocks.lastIndex(where: { $0.kind == "quiz" }) {
            blocks[k] = blocks[k].patched { $0["answered"] = 1 }
        } else {
            blocks.append(ChatBlock(tool: "quiz", data: Quiz.syntheticAnsweredData))
        }
        guard let stored = rawJSON, var o = JSONRead.object(Data(stored.utf8)) else { return }
        var bs: [Any] = (o["blocks"] as? [Any]) ?? []
        let k = bs.lastIndex { b in JSONRead.string((b as? JSONObject)?["data"] as? JSONObject, "kind") == "quiz" }
        if let k, var b = bs[k] as? JSONObject, var d = b["data"] as? JSONObject {
            d["answered"] = 1
            b["data"] = d
            bs[k] = b
        } else {
            bs.append(["tool": "quiz", "data": Quiz.syntheticAnsweredData] as JSONObject)
        }
        o["blocks"] = bs
        rawJSON = LiveTurn.encode(o) ?? stored
    }
}
