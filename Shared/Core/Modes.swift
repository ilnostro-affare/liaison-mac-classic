import Foundation

// Lia 1.4: the model picker's three modes, the question a turn stops on (gate / ask / plan),
// the replies the person sends back, and how those replies read in the thread.
// Ported from ai.js: MODELS 2188, chatModel 2194, liaStepName 2325,
// liaSteps 2342, gateShow 2816, askDock 2847, askAnswer 2857, gateAnswer 2877, userBubble 9953.

enum RunMode: String, CaseIterable, Identifiable {
    case auto, plan, manual
    var id: String { rawValue }

    /// The grey word after the model name on the model button.
    var word: String {
        switch self { case .auto: return "Auto"; case .plan: return "Plan"; case .manual: return "Manual" }
    }

    /// The line under each row of the Mode menu, verbatim (ai.js MODELS).
    var sub: String {
        switch self {
        case .auto: return "One Yes for the whole task"
        case .plan: return "Prepares a plan before making changes"
        case .manual: return "Asks at every step"
        }
    }
}

enum LiaModel {
    /// Lia 2.0: the desktop's model on the same /intelligence/chat, told apart by
    /// `model`. A copy of Lia 1.4 with Auto and Manual, no Plan; the web keeps Lia 1.4.
    static let id = "lia20"
    static let name = "Lia 2.0"
    /// The models whose stored run mode we read: a chat started on the web (1.4) keeps its Manual here.
    static let known: Set<String> = ["lia14", "lia20"]
    /// The modes the Mac offers.
    static let modes: [RunMode] = [.auto, .manual]

    /// A chat with nothing chosen, anything unknown, or Plan (not in 2.0) is Auto.
    static func mode(model: String?, rmode: String?) -> RunMode {
        guard let model, known.contains(model), let r = rmode, let m = RunMode(rawValue: r), modes.contains(m) else { return .auto }
        return m
    }
}

/// One row of a gate's diff: what changes, from what, to what.
struct GateDiffRow: Equatable {
    let label: String
    let old: String
    let new: String
}

/// A change Lia prepared and stopped on (SSE `gate`, kept on the message as `gate`).
/// Shape: lia14GateKeep, the server.
struct Gate: Equatable {
    let planId: String
    let tool: String
    let entity: String
    let title: String
    let final: Bool
    var done: Bool
    let entityId: String
    let entityType: String
    let diff: [GateDiffRow]

    init?(json o: JSONObject?) {
        guard let o, let pid = JSONRead.string(o, "plan_id"), !pid.isEmpty else { return nil }
        planId = pid
        tool = JSONRead.string(o, "tool") ?? ""
        entity = JSONRead.string(o, "entity") ?? ""
        title = JSONRead.string(o, "title") ?? ""
        final = JSONRead.bool(o, "final")
        done = JSONRead.bool(o, "done")
        entityId = JSONRead.string(o, "entity_id") ?? ""
        entityType = JSONRead.string(o, "entity_type") ?? ""
        diff = JSONRead.objects(o, "diff").map {
            GateDiffRow(label: JSONRead.string($0, "label") ?? "", old: JSONRead.string($0, "old") ?? "", new: JSONRead.string($0, "new") ?? "")
        }
    }

    var isUndo: Bool { planId.hasPrefix("undo:") }
    var journalId: String { String(planId.dropFirst(5)) }

    /// The answers above the input. Manual and a final step (turning on) never offer "Yes to all".
    func options(mode: RunMode) -> [GateAnswer] {
        // Lia 2.0: Auto asks once - its Yes covers the whole task; Manual is 1.4's Auto, a Yes per
        // step with Yes to all. Turning something on always asks.
        (final || mode == .auto) ? [.yes, .no] : [.yes, .all, .no]
    }

    /// What a bare digit typed into the empty box may answer (1-n, in the order of `options`). Anything that
    /// applies a write to Meta (Yes, Yes to all, a final Turn on) needs a click or Enter on the focused button,
    /// so only No answers by digit; any other digit is typed into the box as text.
    func digitAnswer(_ n: Int, mode: RunMode) -> GateAnswer? {
        let opts = options(mode: mode)
        guard n >= 1, n <= opts.count, !opts[n - 1].appliesWrite else { return nil }
        return opts[n - 1]
    }

    /// liaStepName: what this step changes, for the step chip.
    var stepName: String {
        if final { return "Turn on" }
        if tool.range(of: #"^update_(entity|ad)$"#, options: .regularExpression) != nil {
            let labels = diff.map(\.label).filter { !$0.isEmpty && $0 != "Estimated audience" }
            if let first = labels.first { return first + (labels.count > 1 ? " +\(labels.count - 1)" : "") }
        }
        switch tool {
        case "create_campaign": return "Campaign"
        case "create_ad_set": return "Ad set"
        case "create_ad", "create_ad_from_creative": return "Ad"
        case "copy_entity": return "Copy"
        case "undo_write": return "Undo"
        case "create_ab_test": return "A/B test"
        case "create_ad_rule": return "Rule"
        default: break
        }
        if tool.hasPrefix("update_") {
            return "Edit" + (entity.isEmpty ? "" : " \u{00b7} " + entity.replacingOccurrences(of: #" change$"#, with: "", options: .regularExpression))
        }
        return entity.isEmpty ? "Change" : entity.prefix(1).uppercased() + entity.dropFirst()
    }

    /// Up to three new values, for the step's second line (liaSteps `d`).
    var stepDetail: String {
        diff.filter { !$0.new.isEmpty && !$0.label.hasPrefix("New ") }.prefix(3).map(\.new).joined(separator: " \u{00b7} ")
    }
}

enum GateAnswer: String, Equatable {
    case yes, all, no
    var label: String {
        switch self { case .yes: return "Yes"; case .all: return "Yes to all"; case .no: return "No" }
    }
    /// Yes and Yes to all send the change to Meta; No sends nothing.
    var appliesWrite: Bool { self != .no }
}

/// Manual's question (SSE `ask`, kept as `ask`). Shape: lia14AskKeep, the server.
struct AskQuestion: Equatable {
    let id: String
    let question: String
    let field: String
    let options: [String]
    var done: Bool
    var answer: String?

    init?(json o: JSONObject?) {
        guard let o, let q = JSONRead.string(o, "question"), !q.isEmpty else { return nil }
        id = JSONRead.string(o, "id") ?? ""
        question = q
        field = JSONRead.string(o, "field") ?? "other"
        options = JSONRead.strings(o, "options")
        done = JSONRead.bool(o, "done")
        answer = JSONRead.string(o, "answer")
    }
}

/// The person's answers travel as user messages with a tag and a JSON body.
enum ModeReply {
    static let gateTag = "[gate_reply]"
    static let askTag = "[ask_reply]"
    static let planTag = "[plan_reply]"
    static let quickTag = "[quick_action]"

    /// What gateAnswer learned from the apply (or nothing, for No).
    struct ApplyOutcome: Equatable {
        var error: String?
        var createdId: String?
        var job: String?
        var pending = false
    }

    /// `[gate_reply] {plan_id, entity, title, answer, how?, final?, job?, pending?, error?|created_id?}`,
    /// keys in the order ai.js builds them.
    static func gate(_ g: Gate, answer: GateAnswer, auto: Bool, outcome: ApplyOutcome?) -> String {
        var pairs: [(String, Any)] = [("plan_id", g.planId), ("entity", g.entity), ("title", g.title)]
        let word: String
        if answer == .no { word = "no" } else if outcome?.error != nil { word = "error" } else { word = "yes" }
        pairs.append(("answer", word))
        if auto { pairs.append(("how", "auto")) } else if answer == .all { pairs.append(("how", "all")) }
        if g.final { pairs.append(("final", true)) }
        if answer != .no, let o = outcome {
            if let job = o.job { pairs.append(("job", job)) }
            if o.pending { pairs.append(("pending", true)) }
            if let e = o.error { pairs.append(("error", String(e.prefix(300)))) }
            else { pairs.append(("created_id", (o.createdId?.isEmpty == false ? o.createdId! : NSNull()) as Any)) }
        }
        return gateTag + " " + OrderedJSON.object(pairs)
    }

    /// `[ask_reply] {question, field, answer, i}` or `{…, typed: true}`. 200 / 4000 characters.
    static func ask(_ a: AskQuestion, answer: String, index: Int?, typed: Bool) -> String {
        let ans = String(answer.prefix(typed ? 4000 : 200))
        var pairs: [(String, Any)] = [("question", a.question), ("field", a.field), ("answer", ans)]
        if typed { pairs.append(("typed", true)) } else { pairs.append(("i", index.map { $0 as Any } ?? NSNull())) }
        return askTag + " " + OrderedJSON.object(pairs)
    }

    static func planNo() -> String { planTag + " " + OrderedJSON.object([("answer", "no")]) }

    /// How a user message reads in the thread: a quoted question over a small answer bubble.
    /// nil for an ordinary message.
    static func quote(for content: String) -> (question: String, answer: String, planId: String?)? {
        func body(_ tag: String) -> JSONObject {
            let raw = content.dropFirst(tag.count).trimmingCharacters(in: .whitespaces)
            return JSONRead.object(Data(raw.utf8)) ?? [:]
        }
        if content.hasPrefix(gateTag) {
            let g = body(gateTag)
            let title = JSONRead.string(g, "title") ?? ""
            let ti = title.isEmpty ? "" : " \u{00ab}" + title + "\u{00bb}"
            let entity = JSONRead.string(g, "entity") ?? ""
            let q: String
            if JSONRead.bool(g, "final") { q = "Turn on" + ti + "?" }
            else if entity == "undo" { q = "Undo the change to" + ti + "?" }
            else if entity == "copy" { q = "Make the copy" + ti + "?" }
            else if entity.contains("change") { q = "Apply the change to" + ti + "?" }
            else { q = "Create the " + (entity.isEmpty ? "object" : entity) + ti + "?" }
            let a = JSONRead.string(g, "answer"), how = JSONRead.string(g, "how")
            let w = a == "no" ? "No, I will edit it" : a == "error" ? "Yes \u{00b7} Meta refused it"
                : how == "all" ? "Yes to all" : how == "auto" ? "Yes \u{00b7} yes to all" : "Yes"
            return (q, w, JSONRead.string(g, "plan_id"))
        }
        if content.hasPrefix(askTag) {
            let g = body(askTag)
            let labels = ["objective": "Objective", "budget_level": "Where the budget sits", "budget": "Budget",
                          "locations": "Locations", "age": "Age", "advantage_audience": "Advantage+ audience",
                          "placements": "Placements", "creative": "Media", "text": "Text", "name": "Name", "audience": "Audience"]
            let ql = labels[JSONRead.string(g, "field") ?? ""] ?? (JSONRead.string(g, "question") ?? "Question")
            let q = ql.count > 70 ? String(ql.prefix(68)) + "\u{2026}" : ql
            return (q, JSONRead.string(g, "answer") ?? "", nil)
        }
        if content.hasPrefix(planTag) {
            let g = body(planTag)
            let items = JSONRead.objects(g, "items")
            let a = JSONRead.string(g, "answer")
            let w = a == "no" ? "No" : a == "publish_on" ? "Publish and turn on"
                : (!items.isEmpty && !items.contains { ($0["created_id"] as? String)?.isEmpty == false } ? "Apply" : "Publish paused")
            return ("Publish the plan?", w, nil)
        }
        if content.hasPrefix(BrowserResult.tag) {
            let g = body(BrowserResult.tag)
            let goal = JSONRead.string(g, "goal") ?? ""
            let q = "Browser \u{00b7} " + (goal.count > 60 ? String(goal.prefix(58)) + "\u{2026}" : goal)
            return (q, (g["ok"] as? Bool ?? true) ? "Done" : "Stopped", nil)
        }
        if content.hasPrefix(quickTag) {
            return ("Quick action", content.dropFirst(quickTag.count).trimmingCharacters(in: .whitespacesAndNewlines), nil)
        }
        return nil
    }

    /// A reply continues the run; anything else the person types starts a new one.
    static func isReply(_ content: String) -> Bool {
        content.hasPrefix(gateTag) || content.hasPrefix(askTag) || content.hasPrefix(BrowserResult.tag)
    }
}

/// One step of this run, for the chip above the input (liaSteps).
struct RunStep: Equatable {
    enum State: String { case done, cur, no }
    let name: String
    let subtitle: String
    let state: State
    let planId: String
}

enum RunSteps {
    /// The gates since the person's own last message (answers to questions continue a run), last 8.
    static func from(messages: [(role: ChatMessage.Role, content: String, gate: Gate?)], liveStep: String?, gateOpen: Bool) -> [RunStep] {
        var from = 0
        for (i, m) in messages.enumerated() where m.role == .user && !ModeReply.isReply(m.content) { from = i + 1 }
        var out: [RunStep] = []
        for (i, m) in messages.enumerated() where i >= from && m.role == .assistant {
            guard let g = m.gate else { continue }
            var st = RunStep.State.cur
            if i + 1 < messages.count, messages[i + 1].role == .user {
                let nx = messages[i + 1].content
                st = nx.hasPrefix(ModeReply.gateTag) ? (nx.contains("\"answer\":\"no\"") ? .no : .done) : .no
            }
            let sub = [g.title, g.stepDetail].filter { !$0.isEmpty }.joined(separator: " \u{00b7} ")
            out.append(RunStep(name: g.stepName, subtitle: sub, state: st, planId: g.planId))
        }
        if let live = liveStep, !gateOpen { out.append(RunStep(name: live, subtitle: "", state: .cur, planId: "")) }
        return Array(out.suffix(8))
    }

    /// liaActName: a write door at work, named by the fields it was called with.
    static func actName(tool: String, fields: [String], status: String?) -> String {
        if tool == "update_entity" || tool == "update_ad" {
            let keys = fields.map { $0 == "status" && status != nil ? "status:" + status! : $0 }
            var acts: [String] = []
            for (ks, nm) in fieldActs where ks.contains(where: keys.contains) && !acts.contains(nm) { acts.append(nm) }
            if let a = acts.first { return a + (acts.count > 1 ? " +\(acts.count - 1)" : "") }
            return tool == "update_ad" ? "Edit \u{00b7} ad" : "Edit"
        }
        return doorNames[tool] ?? "Change"
    }

    /// Tools that write; while one runs the line above the input says "Working".
    static let doors: Set<String> = ["create_campaign", "create_ad_set", "create_ad", "update_entity", "update_ad", "copy_entity",
                                     "undo_write", "create_ab_test", "create_ad_rule", "create_ad_from_creative"]

    static let doorNames = ["create_campaign": "Campaign", "create_ad_set": "Ad set", "create_ad": "Ad", "update_entity": "Edit",
                            "update_ad": "Edit \u{00b7} ad", "copy_entity": "Copy", "undo_write": "Undo", "create_ab_test": "A/B test",
                            "create_ad_rule": "Rule", "create_ad_from_creative": "Ad"]

    static let fieldActs: [([String], String)] = [
        (["status:PAUSED"], "Pause"), (["status:ACTIVE"], "Turn on"), (["name"], "Rename"),
        (["daily_budget", "lifetime_budget", "adset_budgets"], "Budget"), (["budget_mode"], "Budget mode"), (["bid_strategy", "bid_amount"], "Bid"),
        (["spend_cap"], "Spending limit"), (["start_time", "end_time", "schedule"], "Schedule"), (["geo"], "Locations"),
        (["age_min", "age_max", "age_range"], "Age"), (["genders"], "Gender"), (["interests"], "Interests"), (["locales"], "Languages"),
        (["placements"], "Placements"), (["device_platforms"], "Devices"), (["primary_text", "headline", "description"], "Texts"),
        (["call_to_action"], "Button"), (["link", "display_link", "url_tags"], "Link"), (["lead_form_id"], "Form"),
        (["image_hash", "video_id", "r2_key"], "Media"), (["multi_advertiser"], "Multi-advertiser"),
    ]
}

/// JSON.stringify for a flat object whose key order matters to a reader of the thread.
enum OrderedJSON {
    static func object(_ pairs: [(String, Any)]) -> String {
        "{" + pairs.map { value($0.0) + ":" + value($0.1) }.joined(separator: ",") + "}"
    }

    static func value(_ v: Any) -> String {
        if v is NSNull { return "null" }
        if let b = v as? Bool { return b ? "true" : "false" }
        if let i = v as? Int { return String(i) }
        if let s = v as? String { return string(s) }
        if let d = try? JSONSerialization.data(withJSONObject: v), let s = String(data: d, encoding: .utf8) { return s }
        return "null"
    }

    /// Escapes like JSON.stringify: quote, backslash, control characters; "/" and non-ASCII stay as they are.
    static func string(_ s: String) -> String {
        var out = "\""
        for u in s.unicodeScalars {
            switch u {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"   // escape-ok: JSON writes a backslash and n
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            case "\u{08}": out += "\\b"
            case "\u{0C}": out += "\\f"
            default:
                if u.value < 0x20 { out += String(format: "\\u%04x", u.value) } else { out.unicodeScalars.append(u) }
            }
        }
        return out + "\""
    }
}
