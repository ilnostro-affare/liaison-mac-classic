import Foundation
import WebKit

/// Finds what Lia means on a page without knowing its language or markup ("no buttons guessed in
/// advance - users have any language and Meta changes its markup"). The page's controls, in its own words, go to the
/// Decisions API (`/intelligence/locate`, gpt-6-luna) with one choice question per thing; each answer is an element
/// or "none". Below the confidence bar nothing is pointed at. An answer is remembered by the element's signature
/// (kind, label, name, section), so the same screen is not asked twice; a changed screen is asked again by itself.
@MainActor
final class AgentLocator {
    struct Want {
        let name: String
        let instructions: String
        /// Language-free filter on the kind of control (nil: any).
        let kinds: Set<String>?
    }

    /// Set by the app: LiaAPI.locateReply for the chat's account. `limit`: the server refused for the person's limit
    /// (429) and these are its words.
    var ask: @MainActor (String, [[String: Any]]) async -> (answers: [String: (choice: String, confidence: Double)], limit: String?) = { _, _ in ([:], nil) }
    /// Told once per limit spell (the director shows it where the overlay says what it is doing).
    var onLimit: (@MainActor (String) -> Void)?
    /// The limit's words while it holds: lookups stop silently (nothing pointed at) and are asked again a minute
    /// later; a lookup that is answered ends the spell.
    private(set) var limited: String?
    private var limitedAt = Date.distantPast
    static let limitPause: TimeInterval = 60
    static let threshold = 0.5
    /// Where each lookup is written: what was asked, what came back, how sure, how long, what was taken.
    weak var log: AgentLog?
    /// The last call brought nothing back at all (network, server): its questions may be asked again.
    private(set) var lastFailed = false
    private var memory: [String: [String: String]] = [:]   // page -> question -> control signature

    static func signature(_ c: AgentBridge.Control) -> String { [c.kind, c.label, c.name, c.section].joined(separator: "|") }

    static func page(_ url: URL?) -> String { url?.path ?? "" }

    func locate(_ wants: [Want], in webView: WKWebView) async -> [String: AgentBridge.Control] {
        guard !wants.isEmpty else { return [:] }
        let t0 = Date()
        var controls = await AgentBridge.controls(webView)
        // Meta's shell (a dozen controls) before the editor is drawn: asking it finds nothing, so wait for the page.
        for _ in 0..<8 where controls.count < 20 {
            try? await Task.sleep(nanoseconds: 400_000_000)
            controls = await AgentBridge.controls(webView)
        }
        let mapMs = Int(Date().timeIntervalSince(t0) * 1000)
        guard !controls.isEmpty else {
            log?.add("locate_empty_page", ["wants": wants.map(\.name), "map_ms": mapMs, "url": webView.url?.absoluteString ?? ""])
            return [:]
        }
        let page = Self.page(webView.url)
        var found: [String: AgentBridge.Control] = [:]
        var open: [Want] = []
        for w in wants {
            if let sig = memory[page]?[w.name], let c = controls.first(where: { Self.signature($0) == sig }) { found[w.name] = c }
            else { open.append(w) }
        }
        if !found.isEmpty { log?.add("locate_cached", ["hits": found.keys.sorted(), "page": page]) }
        guard !open.isEmpty else { return found }
        if limited != nil, Date().timeIntervalSince(limitedAt) < Self.limitPause {
            log?.add("locate_limited", ["wants": open.map(\.name), "page": page])
            return found
        }
        let input = "A Meta Ads Manager page (\(page)) as an assistive tool reads it. Each line is one element: its id, its kind, "
            + "and the page's own words (name, label beside it, section, current value) in the person's language.\n"
            + controls.map(\.line).joined(separator: "\n")
        let questions: [[String: Any]] = open.map { (w) -> [String: Any] in
            let pool = controls.filter { w.kinds?.contains($0.kind) ?? true }.prefix(390)
            var choices: [[String: Any]] = pool.map { ["value": "e\($0.ref)", "description": $0.line] }
            choices.append(["value": "none", "description": "not on this page"])
            return ["name": w.name, "instructions": w.instructions, "choices": choices]
        }.filter { (($0["choices"] as? [[String: Any]])?.count ?? 0) >= 2 }
        let t1 = Date()
        let reply = await ask(input, questions)
        if let limit = reply.limit {
            // No retry and nothing pointed at; the person reads the server's words once.
            let first = limited == nil
            limited = limit; limitedAt = Date()
            lastFailed = true
            log?.add("locate_limit", ["page": page, "message": String(limit.prefix(200)), "told": first])
            if first { onLimit?(limit) }
            return found
        }
        let answers = reply.answers
        lastFailed = answers.isEmpty && !questions.isEmpty
        if !lastFailed { limited = nil }
        var rows: [[String: Any]] = []
        for w in open {
            let a = answers[w.name]
            let c = a.flatMap { x in x.choice.hasPrefix("e") ? Int(x.choice.dropFirst()).flatMap { r in controls.first { $0.ref == r } } : nil }
            rows.append(["q": w.name, "choice": a?.choice ?? "-", "conf": a.map { (($0.confidence * 1000).rounded() / 1000) } ?? 0,
                         "taken": (a?.confidence ?? 0) >= Self.threshold && c != nil, "el": String((c?.line ?? "").prefix(140))])
        }
        log?.add("locate", ["page": page, "controls": controls.count, "map_ms": mapMs, "ms": Int(Date().timeIntervalSince(t1) * 1000),
                            "chars": input.count, "failed": lastFailed, "answers": rows])
        for w in open {
            guard let a = answers[w.name], a.confidence >= Self.threshold, a.choice.hasPrefix("e"),
                  let ref = Int(a.choice.dropFirst()), let c = controls.first(where: { $0.ref == ref }) else { continue }
            found[w.name] = c
            memory[page, default: [:]][w.name] = Self.signature(c)
        }
        return found
    }

    /// As `locate`, and for what is not on screen yet: the page is scrolled on (up to `pages` times) and asked again
    /// only about what is still missing - an editor draws its lower parts when they are reached. Then back to the top.
    func locateScrolling(_ wants: [Want], in webView: WKWebView, pages: Int = 2) async -> [String: AgentBridge.Control] {
        var found = await locate(wants, in: webView)
        var missing = wants.filter { found[$0.name] == nil }
        var moved = 0
        while !missing.isEmpty, moved < pages, await AgentBridge.scrollPage(webView, by: 0.75) {
            moved += 1
            let more = await locate(missing, in: webView)
            log?.add("locate_scrolled", ["step": moved, "asked": missing.map(\.name), "found": more.keys.sorted()])
            found.merge(more) { a, _ in a }
            missing = missing.filter { found[$0.name] == nil }
        }
        if moved > 0 { _ = await AgentBridge.scrollPage(webView, by: -Double(moved) * 0.75) }
        return found
    }

    // The questions, in plain English; the page's words stay in the page's language.

    static func field(key: String, label: String, value: String, level: AdsLevel) -> Want {
        let what = level == .campaigns ? "campaign" : level == .adsets ? "ad set" : "ad"
        return Want(name: "f_" + key,
                    instructions: "An assistant is about to set the \(what) setting `\(key)` (in English: \(label)) to «\(value)». "
                        + "Which element on this page is the control where a person sets it? For a choice between options, the option "
                        + "that means «\(value)». Answer none if it is not on this page.",
                    kinds: ["text", "number", "select", "radio", "checkbox", "switch", "button", "other"])
    }

    static func create(_ level: AdsLevel) -> Want {
        let what = level == .campaigns ? "campaign" : level == .adsets ? "ad set" : "ad"
        return Want(name: "create", instructions: "Which element on this page starts creating a new \(what)? Answer none if there is none.",
                    kinds: ["button", "link", "other", "menuitem"])
    }

    static func row(name: String) -> Want {
        Want(name: "row", instructions: "Which element is the table row (or the name in it) of the object named «\(name)»? Answer none if it is not listed.",
             kinds: ["row", "link", "other", "button"])
    }
}
