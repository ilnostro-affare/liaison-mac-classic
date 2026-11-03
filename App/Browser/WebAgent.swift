import SwiftUI
import AppKit
import WebKit

/// Lia 2.0 on the open web (server): a task Lia handed over (`browser_task`) is done in
/// the chat's own browser. Each call to /intelligence/browse-step sends the page as text and gets back a BATCH of up to
/// five actions (run in order; the batch stops early when the page changes in a way it could not foresee), a request
/// to LOOK (an annotated picture next step), a question for the person, or the end. Real clicks and keys go to the
/// page (WebInput) where the element is really on top; two composite actions handle widgets every site has (a field
/// with suggestions, a date). Buttons that pay, book, send or delete wait for the person's Allow by rule, whatever the
/// model said; passwords and card fields are never typed. The report goes back to the chat as "[browser_result]";
/// every step, with its time and cost, is in the chat's agent log.
@MainActor
final class WebAgent: ObservableObject {
    private weak var browser: BrowserModel?
    /// The call in progress ("Step 3") and the most it may take; nil when idle.
    @Published private(set) var step: Int?
    /// Paused by the person (the status plate's Pause): the loop waits before its next call.
    @Published var paused = false
    private var job: Task<Void, Never>?
    private var jobID: UUID?
    /// Called when the current task ends (any way): the chat's input drops its Stop.
    var onEnd: (() -> Void)?
    static let maxCalls = 30
    /// Set by the benchmark runner: each step's screenshot and the trajectory are written here.
    var traceDir: URL?
    /// The task as a card in the agent's history (title, outcome, a few human steps), kept after it ends.
    private var history: AgentHistoryStore?
    private var historyID: String?
    /// The page as the model saw it last: a click's step names the control it pressed.
    private var lastSnap: String?

    init(browser: BrowserModel) { self.browser = browser }

    var running: Bool { job != nil }

    func cancel() {
        job?.cancel()
        browser?.agent.webCancelAsk()   // a question waiting in the pill ends with the task
    }

    /// The person's Stop (the pill, the chat's Stop, the conversation's row): told to Lia as such.
    func stopByPerson() {
        stoppedByThePerson = true
        cancel()
    }
    private var stoppedByThePerson = false
    /// How long a gate waits for Allow before the task ends without pressing (incident: 5.6 minutes of
    /// silence), and how long a hand-over (a login, a captcha) waits.
    static let gateWait: TimeInterval = 120
    static let handOverWait: TimeInterval = 600
    /// Set when a wait for the person ran out: the task ends with this as its reason and what it found so far.
    private var waitedOut: String?

    func run(task: String, goal: String, tab: String, url: String?, api: LiaAPI, chatId: String,
             report: @escaping (String) -> Void) {
        cancel()
        let id = UUID()
        jobID = id
        job = Task { [weak self] in
            await self?.perform(id: id, task: task, goal: goal, tabRef: tab, start: url.flatMap(URL.init(string:)), api: api, chatId: chatId, report: report)
            if self?.jobID == id { self?.job = nil; self?.onEnd?() }
        }
    }

    private static let declined = "\u{0}declined"

    /// The tab Lia named, else the front tab if it is blank, else a new one.
    private static func tab(_ ref: String, in b: BrowserModel) -> BrowserTab {
        if ref != "new", let t = b.tabs.first(where: { $0.shortID == ref }) { return t }
        if let t = b.selected, t.isStart { return t }
        return b.newTab(url: nil)
    }

    // MARK: the task

    private func perform(id: UUID, task: String, goal: String, tabRef: String, start: URL?, api: LiaAPI, chatId: String,
                         report: @escaping (String) -> Void) async {
        guard let b = browser else { return }
        let director = b.agent
        let log = director.log
        let tab = Self.tab(tabRef, in: b)
        b.selectedID = tab.id
        // Whoever had the keyboard (the chat's input, as a rule) gets it back when the task ends: a page that took it
        // kept it, and the person's paste meant for the chat landed in the site's field (chat cw5uyf7h8).
        let window = tab.webView.window
        weak var keyboardOwner = window?.firstResponder === tab.webView ? nil : window?.firstResponder
        func giveKeyboardBack() {
            guard let window, window.firstResponder === tab.webView else { return }
            window.makeFirstResponder(keyboardOwner)
            log.add("web_keyboard_back", ["to": keyboardOwner.map { String(describing: type(of: $0)) } ?? "none"])
        }
        director.webBegin(tab: tab, label: "Starting")
        director.onWebStop = { [weak self] in self?.stopByPerson() }
        stoppedByThePerson = false
        waitedOut = nil
        history = traceDir == nil ? AgentHistoryStore.shared(for: b) : nil
        historyID = history?.begin(agent: b.chatID.map { String($0.dropFirst("agent-".count)) } ?? "lia", title: goal)
        // Whose task (and money) this is, for browse-step: Met's browser is Met's, every other one Lia's.
        let agent = WebLimit.agent(b.chatID)
        lastSnap = nil
        log.begin(["tool": "browser_task", "label": String(goal.prefix(80)), "task": task])
        let t0 = Date()
        var steps: [(action: String, result: String)] = []
        var outcome: (ok: Bool, summary: String, why: String?) = (false, "", "stopped by the person")
        var stoppedByPerson: Bool { Task.isCancelled || outcome.why == "stopped by the person" }
        // What the task cost, for the log ("then we count money and speed").
        var cost = LiaAPI.BrowseUsage(), calls = 0, actionsRun = 0, thinkMs = 0, actMs = 0

        func finish() {
            guard jobID == id else { log.add("web_replaced", ["steps": steps.count]); return }
            giveKeyboardBack()
            let totals: [String: Any] = ["steps": steps.count, "calls": calls, "actions": actionsRun, "ms": Int(Date().timeIntervalSince(t0) * 1000),
                                         "think_ms": thinkMs, "act_ms": actMs, "tokens_in": cost.tokensIn, "cached": cost.cached,
                                         "tokens_out": cost.out, "usd": (cost.usd * 1_000_000).rounded() / 1_000_000]
            let soFar = BrowserSoFar.text(steps: steps.count, title: tab.webView.title ?? "", url: tab.webView.url?.absoluteString ?? "", snapshot: lastSnap)
            // Stop is the person's: the task ends here. Incident: Lia must still know it ended and what was
            // found ("Sorry, I didn't start the ticket search"), so the report goes, marked silent (after a Stop
            // she must not start it again - the server stores a silent report without a turn).
            if stoppedByPerson {
                let byPerson = stoppedByThePerson || outcome.why == "stopped by the person"
                let why = byPerson ? "stopped by the person" : "the browser closed"
                history?.end(historyID, .stopped, summary: byPerson ? "Stopped by you" : "The browser closed")
                log.add("web_end", totals.merging(["ok": false, "why": why]) { a, _ in a })
                log.flush()
                director.webEnd(ok: false, text: "Stopped")
                if traceDir == nil {
                    report(BrowserResult.message(goal: goal, ok: false, summary: (byPerson ? "Browser task stopped by you " : "Browser task ended when the browser closed ") + soFar,
                                                 why: why, url: tab.webView.url?.absoluteString, steps: steps.count, silent: true))
                }
                return
            }
            let ok = outcome.ok
            if !ok && outcome.summary.isEmpty { outcome.summary = "Stopped " + soFar }
            history?.end(historyID, ok ? .done : .failed, summary: ok ? outcome.summary : (outcome.why ?? outcome.summary))
            log.add("web_end", totals.merging(["ok": ok, "why": outcome.why ?? ""]) { a, _ in a })
            log.flush()
            if ok, let u = tab.webView.url { WebSiteNotes.remember(u, from: start) }
            director.webEnd(ok: ok, text: ok ? "Done" : (outcome.why ?? "Stopped"))
            if let dir = traceDir {
                let traj: [String: Any] = ["goal": goal, "ok": ok, "answer": outcome.summary, "why": outcome.why ?? "", "final_url": tab.webView.url?.absoluteString ?? "",
                                           "steps": steps.map { ["action": $0.action, "result": $0.result] }, "totals": totals]
                if let d = try? JSONSerialization.data(withJSONObject: traj, options: [.prettyPrinted]) { try? d.write(to: dir.appendingPathComponent("trajectory.json")) }
            }
            report(BrowserResult.message(goal: goal, ok: ok, summary: outcome.summary, why: ok ? nil : outcome.why,
                                         url: tab.webView.url?.absoluteString, steps: steps.count))
        }

        // a tab made just now joins the window a moment later; no pane shows it (the conversation closed): it works off screen
        for _ in 0..<20 where tab.webView.window == nil { try? await Task.sleep(nanoseconds: 50_000_000) }
        AgentParking.keep(tab.webView)
        if let start {
            director.webLabel("Opening " + (start.host ?? "the page"))
            history?.step(historyID, AgentStepPhrase.of(.navigate(start)))
            tab.load(start)
            await settle(tab, navigating: true, log: log, step: 0)
        }

        var failures = 0
        /// Where the person last pressed Continue: the same page's block hint is not passed on again (aviasales: ten
        /// "captcha" questions with no captcha on screen).
        var handedAt: URL?
        /// The page as the model saw it last call: what the batch changed is told with its result.
        var prevSnap: String?
        var wantPicture = false, wantFullText = false
        defer { if jobID == id { step = nil; paused = false } }   // a newer task keeps its own step and pause
        turns: for n in 1...Self.maxCalls {
            if Task.isCancelled { break }
            step = n
            // Pause holds the next call (the page stays the person's to look at); Stop still cancels.
            while paused && !Task.isCancelled { try? await Task.sleep(nanoseconds: 300_000_000) }
            if Task.isCancelled { break }
            let w = tab.webView
            // the tab out of the window (the conversation closed, another agent's browser in front, the panel re-laid
            // out): a moment for a pane to take it back, then it goes on off screen (the task died
            // after 10 s and looked like the browser had closed)
            if w.window == nil && b.tabs.contains(where: { $0.id == tab.id }) {
                log.add("web_wait_window", ["step": n])
                for _ in 0..<5 where w.window == nil && !Task.isCancelled { try? await Task.sleep(nanoseconds: 100_000_000) }
                if AgentParking.keep(w) { log.add("web_parked", ["step": n]) }
            }
            guard w.window != nil, b.tabs.contains(where: { $0.id == tab.id }) else {
                outcome = (false, "", b.tabs.contains(where: { $0.id == tab.id }) ? "the browser was hidden for 10 s" : "the browser tab was closed"); break
            }
            if AgentGuards.isAdTool(url: w.url) {
                outcome = (false, "", "Liaison never acts inside Meta or Google ad tools; Met does that through plans"); break
            }
            // The page the agent reads is the one the pane shows (the person picked another tab of
            // this browser meanwhile: the agent's comes back in front)
            if b.selectedID != tab.id { b.selectedID = tab.id }
            director.webLabel("Reading the page")
            let r0 = Date()
            // Diet: 4,000 characters of text unless the model asked to read the whole page
            let snap = await AgentBridge.snapshotFull(w, maxText: wantFullText ? 20000 : 4000, maxControls: 300)
            let blocked = (handedAt != nil && handedAt == w.url) ? "" : snap.blocked
            if let prev = prevSnap, !steps.isEmpty {
                let diff = PageDiff.describe(before: prev, after: snap.text)
                steps[steps.count - 1].result += " | " + diff
                log.add("web_diff", ["step": n - 1, "diff": String(diff.prefix(400))])
                // a batch that changed nothing: a picture of the page goes with the next call, once
                if diff.hasPrefix("nothing on the page changed") { wantPicture = true }
            }
            prevSnap = snap.text
            lastSnap = snap.text
            var image: String?
            if wantPicture { image = await picture(w, boxes: snap.boxes); log.add("web_look", ["step": n, "bytes": image?.count ?? 0]) }
            var read: [String: Any] = ["step": n, "ms": Int(Date().timeIntervalSince(r0) * 1000), "chars": snap.text.count,
                                       "blocked": snap.blocked, "blocked_sent": blocked, "url": w.url?.absoluteString ?? ""]
            if n == 1 || (steps.last.map { $0.result.contains("not ") || $0.result.contains("nothing on the page changed") } ?? false),
               let r = snap.text.range(of: "CONTROLS:\n") {
                read["controls"] = String(snap.text[r.upperBound...].prefix(2500))   // what the model saw, when it went wrong
            }
            log.add("web_read", read)
            if let dir = traceDir { await Self.saveShot(w, to: dir.appendingPathComponent(String(format: "step-%02d.jpg", n))) }
            wantPicture = false; wantFullText = false
            let s0 = Date()
            let reply = await api.browseStep(taskId: task, goal: goal, steps: steps, url: w.url?.absoluteString ?? "", title: w.title ?? "",
                                             text: PageTranslateCenter.shared.existing(w)?.agentNote.map { $0 + "\n" + snap.text } ?? snap.text,
                                             blocked: blocked, image: image, siteNotes: WebSiteNotes.notes(for: w.url),
                                             chatId: chatId, agent: agent)
            let call: (step: WebStep, ms: Int, usage: LiaAPI.BrowseUsage)
            switch reply {
            case let .step(st, ms, usage): call = (st, ms, usage)
            case .limit(let message):
                // The person's limit is reached. Not a failure to retry: the task ends now, with the server's
                // words in the overlay's status, the task's history card and the report to the agent.
                log.add("web_limit", ["step": n, "message": String(message.prefix(200))])
                outcome = (false, "", message)
                break turns
            case .failed:
                failures += 1
                log.add("web_step_failed", ["step": n, "in_a_row": failures])
                if failures >= 3 { outcome = (false, "", "the browsing model did not answer"); break turns }
                try? await Task.sleep(nanoseconds: 800_000_000)
                continue
            }
            failures = 0
            calls += 1
            let think = Int(Date().timeIntervalSince(s0) * 1000)
            thinkMs += think
            cost.tokensIn += call.usage.tokensIn; cost.cached += call.usage.cached; cost.out += call.usage.out; cost.usd += call.usage.usd
            if Task.isCancelled { break }
            switch call.step {
            case let .done(ok, summary):
                log.add("web_action", ["step": n, "kind": "done", "think_ms": think])
                outcome = (ok, summary, ok ? nil : summary)
                steps.append((ok ? "done" : "gave up", "finished"))
            case .look:
                log.add("web_action", ["step": n, "kind": "look", "think_ms": think])
                wantPicture = true
                steps.append(("look", "a picture of the page comes with the next page"))
                continue
            case let .ask(human, question):
                log.add("web_action", ["step": n, "kind": "ask", "think_ms": think])
                let a0 = Date()
                let result = await ask(question, human: human, tab: tab, director: director, log: log, step: n)
                actMs += Int(Date().timeIntervalSince(a0) * 1000)
                if let why = waitedOut { outcome = (false, "", why); break }
                if result == Self.declined { outcome = (false, "", "the person said stop"); break }
                history?.step(historyID, AgentStepPhrase.of(.ask(human: human, question: question)))
                if human { handedAt = w.url }
                steps.append(((human ? "hand over: " : "confirm: ") + question, result))
                continue
            case .act(let batch):
                log.add("web_action", ["step": n, "kind": "act", "n": batch.count, "actions": batch.map(\.described).joined(separator: " ; "), "think_ms": think])
                if batch.contains(where: { if case .read = $0 { return true }; return false }) { wantFullText = true }
                let a0 = Date()
                let res = await runBatch(batch, in: tab, director: director, log: log, step: n, history: steps)
                actMs += Int(Date().timeIntervalSince(a0) * 1000)
                actionsRun += res.ran
                if Task.isCancelled { break }
                if let why = waitedOut {
                    steps.append((batch.map(\.described).joined(separator: " ; "), res.result))
                    outcome = (false, "", why); break
                }
                if res.declined { outcome = (false, "", "the person said stop"); break }
                steps.append((batch.map(\.described).joined(separator: " ; "), res.result))
                if let end = res.done { outcome = (end.ok, end.summary, end.ok ? nil : end.summary); break }
                if res.stuck { outcome = (false, "", "stuck: the same step did nothing again and again (" + (batch.first?.described ?? "") + ")"); break }
                if n == Self.maxCalls { outcome = (false, "", "too many steps (\(Self.maxCalls) calls)") }
                continue
            }
            break
        }
        // the loop ran out without an end of its own: not the person's Stop
        if !Task.isCancelled && outcome.why == "stopped by the person" { outcome = (false, "", "too many steps (\(Self.maxCalls) calls)") }
        finish()
    }

    // MARK: a batch

    /// Runs the actions in order. Stops early when the page changes in a way the batch could not foresee: another page,
    /// a pop-up or list that appeared (unless the action itself was meant to open one), or an action that failed.
    private func runBatch(_ batch: [WebAction], in tab: BrowserTab, director: AgentDirector, log: AgentLog, step: Int,
                          history: [(action: String, result: String)]) async -> (result: String, ran: Int, declined: Bool, stuck: Bool, done: (ok: Bool, summary: String)?) {
        let w = tab.webView
        var parts: [String] = [], ran = 0
        for (k, action) in batch.enumerated() {
            if Task.isCancelled || waitedOut != nil { break }
            if case let .done(ok, summary) = action { return (parts.joined(separator: "; "), ran, false, false, (ok, summary)) }
            // never the same no-op a third time (the model is told; on the fourth try the task ends)
            let noops = history.reversed().prefix(while: { $0.action.contains(action.described) && $0.result.contains("nothing on the page changed") }).count
            if noops >= 2 {
                parts.append("\(k + 1). \(action.described): not done - it already did nothing \(noops) times; do something else")
                log.add("web_refused", ["step": step, "action": action.described, "noops": noops])
                return (parts.joined(separator: "; "), ran, false, noops >= 3, nil)
            }
            let url0 = w.url
            let pop0 = await AgentBridge.overlays(w)
            let result = await execute(action, in: tab, director: director, log: log, step: step)
            if result == Self.declined { return (parts.joined(separator: "; "), ran, true, false, nil) }
            ran += 1
            if !(result.hasPrefix("no ") || result.hasPrefix("not ") || result.contains(Self.failMark)) {
                var name: String?
                if case .click(let id) = action { name = AgentStepPhrase.controlName(id, in: lastSnap) }
                self.history?.step(historyID, AgentStepPhrase.of(action, control: name))
            }
            parts.append("\(k + 1). \(action.described): \(result)")
            guard k < batch.count - 1 else { break }
            // unforeseen: stop and show the model the new page
            let failed = result.hasPrefix("no ") || result.hasPrefix("not ") || result.contains(Self.failMark)
            let moved = w.url != url0
            let opensByItself: Bool = { switch action { case .click, .select, .pick, .setDate: return true; default: return false } }()
            let popped = await AgentBridge.overlays(w) > pop0
            if failed || moved || (popped && !opensByItself) {
                let why = failed ? "an action did not work" : moved ? "the page changed" : "a pop-up or list appeared"
                parts.append("stopped after \(k + 1) of \(batch.count): \(why)")
                log.add("web_batch_stop", ["step": step, "after": k + 1, "of": batch.count, "why": why])
                break
            }
        }
        return (parts.joined(separator: "; "), ran, false, false, nil)
    }

    /// The reason a task ends with when a gate waited two minutes for nobody.
    static func gateOut(_ button: String) -> String { "I stopped before pressing \u{201C}\(button)\u{201D}: it needs your OK" }

    /// Composite actions that did not reach their end say so with this word (a batch stops on it).
    static let failMark = "did not work:"

    // MARK: one action

    /// Does one action for real and says what came of it. Every part is logged: the element and where it is, the
    /// cursor's move, the click, the keys, the wait, with their times.
    private func execute(_ action: WebAction, in tab: BrowserTab, director: AgentDirector, log: AgentLog, step: Int) async -> String {
        let w = tab.webView
        let before = w.url
        var hiddenTarget: String?
        var coveredBy: (id: String, by: String)?
        var gateRefused: String?
        func ms(_ t: Date) -> Int { Int(Date().timeIntervalSince(t) * 1000) }
        func changed() -> String {
            guard let now = w.url, now != before else { return "ok" }
            return "ok; now on «\(w.title ?? "")» \(now.absoluteString.prefix(160))"
        }
        func point(ref: Int, id: String, t0: Date = Date()) async -> (ref: Int, point: CGPoint)? {
            guard let at = await AgentBridge.reveal(w, ref: ref), at.rect.width >= 1, at.rect.height >= 1 else {
                log.add("web_target", ["step": step, "id": id, "ref": ref, "found": false, "why": "element gone or has no size"]); return nil
            }
            let c = CGPoint(x: at.rect.midX, y: at.rect.midY)
            guard w.bounds.insetBy(dx: 1, dy: 1).contains(c) else {
                log.add("web_target", ["step": step, "id": id, "ref": ref, "found": true, "inside": false,
                                       "rect": [Int(at.rect.minX), Int(at.rect.minY), Int(at.rect.width), Int(at.rect.height)]])
                hiddenTarget = id
                return nil
            }
            let hit = await AgentBridge.hitPoint(w, ref: ref)
            let p = hit.map { $0.ok ? $0.point : c } ?? c
            log.add("web_target", ["step": step, "id": id, "ref": ref, "found": true, "ms": ms(t0),
                                   "rect": [Int(at.rect.minX), Int(at.rect.minY), Int(at.rect.width), Int(at.rect.height)],
                                   "point": [Int(p.x), Int(p.y)], "hit_ok": hit?.ok ?? false, "cover": hit?.cover ?? ""])
            if let hit, !hit.ok { coveredBy = (id, hit.cover); return nil }
            return (ref, p)
        }
        func target(_ id: String) async -> (ref: Int, point: CGPoint)? {
            let t0 = Date()
            guard let ref = await AgentBridge.ref(w, id: id) else {
                log.add("web_target", ["step": step, "id": id, "found": false, "why": "id not in the last snapshot"]); return nil
            }
            return await point(ref: ref, id: id, t0: t0)
        }
        func missing(_ id: String, _ what: String) -> String {
            if let c = coveredBy, c.id == id {
                return "not clicked: [\(id)] is covered on screen" + (c.by.isEmpty ? "" : " by «\(c.by)»") + " - close or move what covers it, or use another control"
            }
            return hiddenTarget == id ? "not clicked: [\(id)] is not in view (hidden to the side): show it first - an arrow or a tab - then click it"
                : "no \(what) [\(id)] on this page now"
        }
        func move(_ p: CGPoint, _ caption: String) async {
            let t0 = Date(), from = director.cursor ?? .zero
            await director.webMove(to: p, caption: caption)
            log.add("web_move", ["step": step, "from": [Int(from.x), Int(from.y)], "to": [Int(p.x), Int(p.y)], "ms": ms(t0)])
        }
        /// A click, after the rule check: a button that pays, books, sends or deletes waits for the person's Allow.
        func click(_ p: CGPoint, ref: Int) async -> Bool? {
            let risky = await AgentBridge.risk(w, ref: ref)
            if !risky.isEmpty && traceDir != nil {   // a benchmark run never pays, books or sends
                log.add("web_gate", ["step": step, "button": risky, "unattended": true])
                gateRefused = risky; return false
            }
            if !risky.isEmpty {
                log.add("web_gate", ["step": step, "button": risky])
                let reply = await director.webAskPerson("Press «\(risky)»? This may pay, book, send or delete something.", human: false,
                                                        button: risky, timeout: Self.gateWait)
                log.add("web_gate_answer", ["step": step, "yes": reply == .yes, "timed_out": reply == .timedOut])
                if reply == .timedOut { waitedOut = Self.gateOut(risky); gateRefused = risky; return false }
                if reply != .yes { gateRefused = risky; return false }
            }
            let t0 = Date()
            director.webPress(at: p)
            let ok = await WebInput.click(at: p, in: w)
            log.add("web_click", ["step": step, "at": [Int(p.x), Int(p.y)], "sent": ok, "window": w.window != nil,
                                  "first_responder": w.window?.firstResponder === w, "ms": ms(t0)])
            return ok
        }
        func settled(_ navigating: Bool) async { await settle(tab, navigating: navigating, log: log, step: step) }
        var off: String { gateRefused.map { "not done: the person did not allow pressing «\($0)» - finish with what you have, or ask them" } ?? "not done: the browser is not on screen" }
        func typeInto(_ t: (ref: Int, point: CGPoint), text: String, enter: Bool) async -> String? {
            let secretRefusal = "not typed: this is a password or card field - ask the person (kind human) to fill it"
            if await AgentBridge.isSecretField(w, ref: t.ref) {
                log.add("web_secret_refused", ["step": step])
                return secretRefusal
            }
            await move(t.point, String(text.prefix(28)))
            guard let c = await click(t.point, ref: t.ref) else { return Self.declined }
            guard c else { return off }
            let prepared = await AgentBridge.prepareTyping(w, ref: t.ref)
            // the click may have moved the focus (a page that hands it to another field): checked again where the keys land
            if AgentGuards.isAdTool(url: w.url) { return AgentGuards.adToolRefusal }
            if await AgentBridge.activeIsSecret(w) {
                log.add("web_secret_refused", ["step": step, "active": true])
                return secretRefusal
            }
            // Enter submits the form: a form whose submit button pays, books or sends waits for the person's Allow
            var pressEnter = enter
            if pressEnter {
                let risky = await AgentBridge.enterRisk(w, ref: t.ref)
                if !risky.isEmpty {
                    if traceDir != nil {
                        log.add("web_gate", ["step": step, "button": risky, "enter": true, "unattended": true])
                        gateRefused = risky; pressEnter = false
                    } else {
                        log.add("web_gate", ["step": step, "button": risky, "enter": true])
                        let reply = await director.webAskPerson("Press Enter? It submits «\(risky)», which may pay, book, send or delete something.",
                                                                human: false, button: risky, timeout: Self.gateWait)
                        log.add("web_gate_answer", ["step": step, "yes": reply == .yes, "enter": true, "timed_out": reply == .timedOut])
                        if reply == .timedOut { waitedOut = Self.gateOut(risky) }
                        if reply != .yes { gateRefused = risky; pressEnter = false }
                    }
                }
            }
            let k0 = Date()
            let sent = await WebInput.type(text, in: w, enter: pressEnter)
            log.add("web_keys", ["step": step, "chars": text.count, "enter": pressEnter, "selected_first": prepared, "sent": sent, "ms": ms(k0)])
            if let g = gateRefused {
                if waitedOut != nil { return "typed without Enter: «\(g)» waited for the person's OK and nobody answered" }
                return "typed without Enter: the person did not allow submitting «\(g)» - finish with what you have, or ask them"
            }
            return sent ? nil : off
        }

        // Meta's and Google's ad tools: never a click, key, pick or date there - checked against the page as it is now,
        // before every action (an earlier action of the batch may have landed there), and before opening one
        switch action {
        case .click, .type, .pick, .setDate, .select:
            if AgentGuards.isAdTool(url: w.url) {
                log.add("web_refused", ["step": step, "action": action.described, "why": "ad_tool", "url": w.url?.host ?? ""])
                return AgentGuards.adToolRefusal
            }
        case .navigate(let u):
            if AgentGuards.isAdTool(url: u) {
                log.add("web_refused", ["step": step, "action": "navigate", "why": "ad_tool", "url": u.host ?? ""])
                return AgentGuards.adToolRefusal
            }
        default: break
        }

        switch action {
        case .click(let id):
            director.webLabel("Clicking")
            guard let t = await target(id) else { return missing(id, "element") }
            await move(t.point, action.caption)
            guard let c = await click(t.point, ref: t.ref) else { return Self.declined }
            guard c else { return off }
            await settled(false)
            return changed()
        case let .type(id, text, enter):
            director.webLabel("Typing")
            guard let t = await target(id) else { return missing(id, "field") }
            if let stop = await typeInto(t, text: text, enter: enter) { return stop }
            await settled(enter)
            return enter ? changed() : "typed; the field now reads «\(await AgentBridge.value(w, ref: t.ref))»"
        case let .pick(id, text, option):
            // a field with suggestions: type, wait for the list, choose the one meant, check the field
            director.webLabel("Choosing «\(option)»")
            guard let t = await target(id) else { return missing(id, "field") }
            if let stop = await typeInto(t, text: text, enter: false) { return stop }
            // the list often first shows recent searches or the half-typed query's matches: wait for one that fits
            var opts: [(ref: Int, text: String)] = []
            let w0 = Date()
            repeat {
                try? await Task.sleep(nanoseconds: 150_000_000)
                opts = await AgentBridge.options(w, field: t.ref)
            } while (WebOptions.bestScored(opts, for: option)?.score ?? 999) >= 100 && Date().timeIntervalSince(w0) < 3
            log.add("web_pick_options", ["step": step, "n": opts.count, "ms": ms(w0), "first": opts.prefix(5).map { $0.text }])
            guard let best = WebOptions.best(opts, for: option) else {
                return Self.failMark + " typed «\(text)» but no suggestion like «\(option)» appeared" + (opts.isEmpty ? "" : " (offered: " + opts.prefix(5).map { "«\($0.text)»" }.joined(separator: ", ") + ")")
            }
            guard let p = await point(ref: best.ref, id: "option") else { return Self.failMark + " the suggestion «\(best.text)» could not be clicked" }
            await move(p.point, option)
            guard let c = await click(p.point, ref: best.ref) else { return Self.declined }
            guard c else { return off }
            await settled(false)
            let now = await AgentBridge.value(w, ref: t.ref)
            log.add("web_pick", ["step": step, "chose": best.text, "field_now": now])
            return "chose «\(best.text)»; the field now reads «\(now)»"
        case let .setDate(id, y, m, d):
            director.webLabel("Setting the date")
            guard let t = await target(id) else { return missing(id, "date field") }
            await move(t.point, action.caption)
            guard let c = await click(t.point, ref: t.ref) else { return Self.declined }
            guard c else { return off }
            await settled(false)
            // a native date input has no calendar in the page: its value is set like a person's pick
            if await AgentBridge.setNativeDate(w, ref: t.ref, iso: String(format: "%04d-%02d-%02d", y, m, d)) {
                log.add("web_date_native", ["step": step])
                return "set " + String(format: "%04d-%02d-%02d", y, m, d) + " in the date field"
            }
            for turn in 0..<14 {
                let day = await AgentBridge.dayRef(w, y: y, m: m, d: d)
                log.add("web_date_look", ["step": step, "turn": turn, "found": day.day != nil, "in_view": day.inView, "target": day.target, "shown": day.shown])
                // no calendar on the page at all, or the month is shown but its day is not usable: no arrows clicked blindly
                if day.shown.isEmpty && day.day == nil {
                    return Self.failMark + " no calendar opened from [\(id)] - look at the page, or type the date into the field"
                }
                if day.shown.contains(day.target) && !(day.day != nil && day.inView) {
                    return Self.failMark + " the month is shown but the day " + String(format: "%04d-%02d-%02d", y, m, d) + " cannot be chosen (disabled or not found) - look at the page"
                }
                if let ref = day.day, day.inView, let p = await point(ref: ref, id: "day") {
                    await move(p.point, action.caption)
                    guard let c2 = await click(p.point, ref: ref) else { return Self.declined }
                    guard c2 else { return off }
                    await settled(false)
                    return "chose " + String(format: "%04d-%02d-%02d", y, m, d) + "; the date field now reads «\(await AgentBridge.value(w, ref: t.ref))»"
                }
                // not on screen: one month forward or back, by the calendar's own arrow
                let forward = day.shown.isEmpty ? true : day.target > (day.shown.max() ?? 0)
                guard let arrow = await AgentBridge.calendarArrow(w, forward: forward, near: day.day ?? t.ref), let ap = await point(ref: arrow, id: "arrow") else {
                    return Self.failMark + " the calendar is open but the day " + String(format: "%04d-%02d-%02d", y, m, d) + " is not shown and no month arrow was found - look at the page"
                }
                await move(ap.point, forward ? "›" : "‹")
                guard let c3 = await click(ap.point, ref: arrow) else { return Self.declined }
                guard c3 else { return off }
                await settled(false)
            }
            return Self.failMark + " the day " + String(format: "%04d-%02d-%02d", y, m, d) + " did not appear after 14 months - look at the page"
        case let .select(id, option):
            director.webLabel("Choosing")
            guard let t = await target(id) else { return missing(id, "dropdown") }
            await move(t.point, action.caption)
            if await AgentBridge.isNativeSelect(w, ref: t.ref) {
                director.webPress(at: t.point)
                let ok = await AgentBridge.pick(w, ref: t.ref, option: option)
                log.add("web_pick", ["step": step, "option": option, "ok": ok])
                return ok ? "chosen «\(option)»" : "no option «\(option)» in [\(id)]"
            }
            guard let c = await click(t.point, ref: t.ref) else { return Self.declined }
            guard c else { return off }
            await settled(false)
            return "opened [\(id)]; choose «\(option)» from what appeared"
        case .scroll(let down):
            director.webLabel("Scrolling")
            let t0 = Date()
            let moved = await AgentBridge.scrollPage(w, by: down ? 0.8 : -0.8)
            log.add("web_scroll", ["step": step, "down": down, "moved": moved, "ms": ms(t0)])
            return moved ? "scrolled" : "the page did not move (at its " + (down ? "end" : "top") + ")"
        case .navigate(let u):
            director.webLabel("Opening " + (u.host ?? "the page"))
            tab.load(u)
            await settled(true)
            return changed()
        case .back:
            director.webLabel("Going back")
            guard w.canGoBack else { return "nothing to go back to" }
            w.goBack()
            await settled(true)
            return changed()
        case .wait(let s):
            director.webLabel("Waiting")
            try? await Task.sleep(nanoseconds: UInt64(s * 1_000_000_000))
            return "waited"
        case .read:
            return "the whole page text comes with the next page"
        case let .ask(human, question):
            return await ask(question, human: human, tab: tab, director: director, log: log, step: step)
        case .done:
            return "finished"
        case .invalid(let why):
            log.add("web_invalid", ["step": step, "why": why])
            return "not done: " + why
        }
    }

    private func ask(_ question: String, human: Bool, tab: BrowserTab, director: AgentDirector, log: AgentLog, step: Int) async -> String {
        // a benchmark run has no one to answer: the model is told so and goes on or finishes
        if traceDir != nil {
            log.add("web_ask_unattended", ["step": step, "human": human])
            return human ? "no one can help in this run: go on without it, or finish with done ok false" : "not allowed in this run: finish with what you have"
        }
        let t0 = Date()
        log.add("web_ask", ["step": step, "human": human, "question": String(question.prefix(200))])
        let q = question.isEmpty ? (human ? "Your turn on this page" : "Go on?") : question
        let reply = await director.webAskPerson(q, human: human, button: nil, timeout: human ? Self.handOverWait : Self.gateWait)
        log.add("web_answer", ["step": step, "yes": reply == .yes, "timed_out": reply == .timedOut, "waited_ms": Int(Date().timeIntervalSince(t0) * 1000)])
        if reply == .timedOut {
            waitedOut = human ? "I waited \(Int(Self.handOverWait / 60)) minutes for you on the page («\(String(q.prefix(120)))») and stopped"
                : "I stopped before going on: «\(String(q.prefix(120)))» needs your OK"
            return Self.declined
        }
        guard reply == .yes else { return Self.declined }
        await settle(tab, navigating: false, log: log, step: step)
        return human ? "the person pressed Continue: treat it as done and go on" : "the person allowed it"
    }

    /// A screenshot of the page as the model sees it at this step (benchmark trajectories).
    private static func saveShot(_ w: WKWebView, to file: URL) async {
        let shot: NSImage? = await withCheckedContinuation { k in w.takeSnapshot(with: nil) { img, _ in k.resume(returning: img) } }
        guard let shot, let tiff = shot.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
              let jpg = rep.representation(using: .jpeg, properties: [.compressionFactor: 0.55]) else { return }
        try? jpg.write(to: file)
    }

    // MARK: waiting and looking

    /// Until the page is usable again: a load that started finishes (10 s at most), then the page holds still - no DOM
    /// change for 150 ms (2.5 s at most), measured in the page instead of a fixed wait.
    private func settle(_ tab: BrowserTab, navigating: Bool, log: AgentLog, step: Int) async {
        let w = tab.webView, t0 = Date(), url0 = w.url
        for _ in 0..<(navigating ? 8 : 2) where !w.isLoading { try? await Task.sleep(nanoseconds: 50_000_000) }
        for _ in 0..<100 where w.isLoading { try? await Task.sleep(nanoseconds: 100_000_000) }
        let calm = await AgentBridge.quiet(w, calm: navigating ? 250 : 150, max: navigating ? 4000 : 2500)
        log.add("web_settle", ["step": step, "ms": Int(Date().timeIntervalSince(t0) * 1000), "quiet_ms": calm, "navigated": w.url != url0, "loading": w.isLoading])
    }

    /// A picture of the page with the snapshot's ids drawn on the controls on screen (look), as a JPEG data URL.
    /// The drawing and the JPEG are made off the main thread (they took 50-150 ms of it per look).
    private func picture(_ w: WKWebView, boxes: [(id: String, rect: CGRect)]) async -> String? {
        let shot: NSImage? = await withCheckedContinuation { k in w.takeSnapshot(with: nil) { img, _ in k.resume(returning: img) } }
        guard let cg = shot?.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        let size = w.bounds.size
        let sendable = PictureInput(image: cg, size: size, boxes: boxes.map { PictureBox(id: $0.id, rect: $0.rect) })
        return await Task.detached(priority: .userInitiated) { WebAgent.draw(sendable) }.value
    }

    private struct PictureBox: @unchecked Sendable { let id: String; let rect: CGRect }
    private struct PictureInput: @unchecked Sendable { let image: CGImage; let size: CGSize; let boxes: [PictureBox] }

    private nonisolated static func draw(_ input: PictureInput) -> String? {
        let shot = NSImage(cgImage: input.image, size: input.size)
        let boxes = input.boxes
        let size = input.size
        let scale = min(1, 1100 / max(1, size.width))
        let out = NSSize(width: size.width * scale, height: size.height * scale)
        // drawn into a bitmap of exactly these pixels (lockFocus would double them on a Retina screen)
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(out.width), pixelsHigh: Int(out.height), bitsPerSample: 8,
                                         samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
              let ctx = NSGraphicsContext(bitmapImageRep: rep) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = ctx
        shot.draw(in: NSRect(origin: .zero, size: out))
        let font = NSFont.boldSystemFont(ofSize: 11)
        for b in boxes {
            // the web view's top-left points -> the picture's bottom-left points
            let r = NSRect(x: b.rect.minX * scale, y: out.height - b.rect.maxY * scale, width: b.rect.width * scale, height: b.rect.height * scale)
            NSColor.systemPink.withAlphaComponent(0.9).setStroke()
            let path = NSBezierPath(rect: r); path.lineWidth = 1; path.stroke()
            let label = NSAttributedString(string: b.id, attributes: [.font: font, .foregroundColor: NSColor.white])
            let ls = label.size()
            let tag = NSRect(x: r.minX, y: min(out.height - ls.height - 2, r.maxY), width: ls.width + 4, height: ls.height + 1)
            NSColor.systemPink.setFill(); NSBezierPath(rect: tag).fill()
            label.draw(at: NSPoint(x: tag.minX + 2, y: tag.minY))
        }
        NSGraphicsContext.restoreGraphicsState()
        guard let jpg = rep.representation(using: .jpeg, properties: [.compressionFactor: 0.6]) else { return nil }
        return "data:image/jpeg;base64," + jpg.base64EncodedString()
    }
}

/// What worked on a site before: addresses of finished tasks that carry a search in them, per site, so the
/// next task can open the result by address instead of clicking through the form. Kept on this Mac only.
@MainActor
enum WebSiteNotes {
    private static let key = "lia_web_site_notes"
    private static func host(_ u: URL?) -> String? { u?.host?.lowercased().replacingOccurrences(of: "www.", with: "") }

    static func remember(_ end: URL, from start: URL?) {
        guard let h = host(end), end != start, (end.query?.isEmpty == false) || end.path.count > 1 else { return }
        // never an address that may carry a session, a token or an order (only search-like addresses are kept)
        if end.absoluteString.range(of: "(token|session|sid=|auth|key=|code=|order|confirm|checkout|payment|account|login|password|email)", options: [.regularExpression, .caseInsensitive]) != nil { return }
        var all = (UserDefaults.standard.dictionary(forKey: key) as? [String: [String]]) ?? [:]
        var list = all[h] ?? []
        list.removeAll { $0 == end.absoluteString }
        list.insert(String(end.absoluteString.prefix(400)), at: 0)
        all[h] = Array(list.prefix(3))
        var order = (UserDefaults.standard.stringArray(forKey: key + ".order") ?? []).filter { $0 != h }
        order.append(h)
        while order.count > 200 { all[order.removeFirst()] = nil }   // the least recently used site goes
        UserDefaults.standard.set(all, forKey: key)
        UserDefaults.standard.set(order, forKey: key + ".order")
    }

    static func notes(for url: URL?) -> String? {
        guard let h = host(url), let list = (UserDefaults.standard.dictionary(forKey: key) as? [String: [String]])?[h], !list.isEmpty else { return nil }
        return "Addresses of searches that worked on this site: " + list.joined(separator: "  |  ")
    }
}

/// A task kept dying "the browser was hidden for 10 s" when the conversation closed or another
/// agent's browser came to the front, and it looked as if the browser had closed. A web view a task drives and no pane
/// shows waits in one off-screen window (full-HD, as the conversation lays it out) and goes on there; the next pane
/// that shows the tab takes it back (a view lives in one place at a time). Nothing of the page changes.
@MainActor
enum AgentParking {
    private static var window: NSWindow?
    private static var tokens: [NSObjectProtocol] = []
    /// The conversation lays an agent's page out 1920 points wide (FullHDWebHost): the same here.
    static let width: CGFloat = 1920
    /// Far from every screen.
    private static let away = NSPoint(x: -40000, y: -40000)

    /// true when the view was parked now.
    @discardableResult
    static func keep(_ w: WKWebView) -> Bool {
        guard w.window == nil else { return false }
        let win = window ?? make()
        window = win
        w.removeFromSuperview()
        w.translatesAutoresizingMaskIntoConstraints = true
        w.frame = NSRect(x: 0, y: 0, width: AgentParking.width, height: 1080)
        win.contentView?.addSubview(w)
        pin(win)
        if !win.isVisible { win.orderBack(nil) }
        return true
    }

    /// (item 14): a white sheet over most of the screen after an agent's look at a page, behind the
    /// other windows and still there with Liaison minimised. That was this window: AppKit brings a window that is
    /// entirely off every screen back onto one (a display change, waking, a Space or full-screen change), and the
    /// window stayed ordered in for good, even with nothing parked. Now it is put back far away whenever it moves or the
    /// screens change, it is ordered out as soon as its last page leaves, and it draws nothing of its own.
    private static func pin(_ win: NSWindow) {
        if win.frame.origin != away { win.setFrameOrigin(away) }
    }

    private static func make() -> NSWindow {
        let win = NSWindow(contentRect: NSRect(origin: away, size: NSSize(width: AgentParking.width, height: 1080)),
                           styleMask: [.borderless], backing: .buffered, defer: false)
        win.isReleasedWhenClosed = false
        win.ignoresMouseEvents = true
        win.isExcludedFromWindowsMenu = true
        win.collectionBehavior = [.transient, .ignoresCycle, .fullScreenAuxiliary]
        win.hasShadow = false
        win.isOpaque = false
        win.backgroundColor = .clear
        let root = ParkingRoot(frame: NSRect(x: 0, y: 0, width: AgentParking.width, height: 1080))
        root.emptied = { [weak win] in
            // A pane took the last page back: nothing left to keep rendering here.
            DispatchQueue.main.async { [weak win] in
                guard let win, win.contentView?.subviews.isEmpty ?? true else { return }
                win.orderOut(nil)
            }
        }
        win.contentView = root
        for n in [NSWindow.didMoveNotification, NSWindow.didChangeScreenNotification] {
            tokens.append(NotificationCenter.default.addObserver(forName: n, object: win, queue: .main) { [weak win] _ in
                MainActor.assumeIsolated { if let win { pin(win) } }
            })
        }
        tokens.append(NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil,
                                                             queue: .main) { [weak win] _ in
            MainActor.assumeIsolated { if let win { pin(win) } }
        })
        return win
    }

    /// The parking window's content: says when its last subview has gone.
    private final class ParkingRoot: NSView {
        var emptied: (() -> Void)?
        override func willRemoveSubview(_ subview: NSView) {
            super.willRemoveSubview(subview)
            if subviews.count <= 1 { emptied?() }
        }
    }
}
