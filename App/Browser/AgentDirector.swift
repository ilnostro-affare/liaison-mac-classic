import SwiftUI
import WebKit

/// Plays Lia 2.0's trace over the real Ads Manager of a chat's browser:
/// A change: Meta's own editor of the object opens by address; the cursor goes to each real control (found by
/// the Decisions API, any language) and the new value is drawn over it - typed into a text field, picked from a
/// drawn menu under a dropdown, ticked on an option; after Yes the editor reloads with Meta's real values;
/// A new object: the list opens, the cursor presses Create (drawn) and says on its tag what it fills; after Yes
/// Meta's editor of the object that was made opens and the cursor walks the fields Lia set.
/// Pages change behind a picture of the last one, which fades when the new one is ready. Runs follow each other:
/// "Yes to all" queues the next change behind the walk of the last one instead of cutting it.
/// Everything is written to the chat's agent log (AgentLog). It loads addresses and scrolls; it never clicks or
/// types into the page.
@MainActor
final class AgentDirector: ObservableObject {
    enum Status: Equatable {
        case working
        case checking
        case ready
        case refused(String)
        case applied
        case failed(String)
    }

    /// A value drawn over one real control.
    struct Mark: Identifiable, Equatable {
        let key: String
        var rect: CGRect
        /// text, select (with a drawn menu while `menu`), toggle, show (a pass of the cursor after Yes)
        var kind: String
        var style: AgentBridge.Style?
        var value: String
        var typed: String
        var menu = false
        var id: String { key }
    }

    @Published private(set) var active = false
    @Published private(set) var visible = false
    @Published private(set) var label = ""
    @Published private(set) var cursor: CGPoint?
    @Published private(set) var press: CGPoint?
    @Published private(set) var caption: String?
    @Published private(set) var marks: [Mark] = []
    @Published private(set) var status: Status = .working
    @Published private(set) var curtain: NSImage?
    @Published private(set) var tabID: UUID?

    var onStop: () -> Void = {}
    let locator = AgentLocator()
    let log = AgentLog()
    private weak var browser: BrowserModel?
    private var run = AgentRun()

    /// What the player does: a beat, or the start of a run (which waits for the run before it to finish playing).
    private enum Step { case begin(String, String), beat(AgentBeat) }
    private var queue: [(gen: Int, step: Step)] = []
    private var playing = false
    private var player: Task<Void, Never>?
    /// The run being played, and the run new events belong to (ahead of it while a walk finishes).
    private var generation = 0
    private var feedGen = 0
    private var creating = false
    private var located: [String: AgentBridge.Control] = [:]
    private var asked: Set<String> = []
    private var setFields: [(key: String, label: String, value: String)] = []
    /// Settings of a new object filled without a tag of their own (said once, as "+N settings").
    private var quietFields = 0
    /// The chat has finished: the pause after the last run is short and the walk scrolls less (
    /// the animation ran 20 s past the chat). A turn ends at every question too, so this never skips a field.
    private var hurry = false

    static func tag(_ label: String, _ value: String) -> String { value.isEmpty ? label : label + " \u{00b7} " + value }
    /// The address the agent loaded; anything else in its tab is logged as a navigation it did not make.
    private var expected: URL?

    init(browser: BrowserModel) {
        self.browser = browser
        locator.log = log
        // A lookup refused for the person's limit stops silently; its words are said once, in the overlay's line.
        locator.onLimit = { [weak self] message in self?.webLabel(message) }
    }

    private static let letter: UInt64 = 34_000_000                                     // browser.js agType
    private static let move = Animation.timingCurve(0.4, 0.1, 0.2, 1, duration: 0.55)   // browser.js agMove

    // MARK: feeding

    func feed(_ e: AgentEvent, defaultAccount: String?, kindOf: @escaping (String) -> String?, parentOf: @escaping (String) -> String?) {
        if onWebStop != nil { return }   // a web task owns the overlay until it ends
        run.defaultAccount = defaultAccount
        run.kindOf = kindOf
        run.parentOf = parentOf
        // (incident): another turn of the same agent ending (a task, a teammate's hand-over) is not an
        // answer. The wait ends when the card is answered (`answered`), replaced (`begin`, `gateGone`) or stopped.
        if case .end = e {
            switch AgentWaitPolicy.onEnd(waiting: !active && !playing && status == .ready, gateOpen: gateOpen?(),
                                         ownChat: !AgentWaitPolicy.isAgentBrowser(chatID: browser?.chatID)) {
            case .expire: expireWaiting(); return
            case .keep: log.add("end_while_waiting"); return
            case .none: break
            }
        }
        if case .end = e { hurry = true; log.add("chat_end", ["queued": queue.count]) }
        if case .intent = e { hurry = false }
        if case let .intent(_, tool, label, door) = e, door || AgentRun.isDoor(tool) {
            feedGen += 1
            queue.append((feedGen, .begin(label, tool)))
            if !visible { withAnimation(.easeOut(duration: 0.2)) { visible = true; active = true } }
        }
        let beats = run.feed(e)
        guard !beats.isEmpty else { return }
        queue += beats.map { (feedGen, .beat($0)) }
        kick()
    }

    /// The chat's answer to "is this agent's Yes / No card still open?" (TeamChatModel.openGate), read at a turn's
    /// end. Unset: an agent's browser keeps its wait until the answer, a new change or Stop; a chat's own browser
    /// expires it at the next turn's end, as before.
    var gateOpen: (() -> Bool)?

    /// The chat's card went without an answer (the person wrote something else, the card was withdrawn).
    func gateGone() {
        guard !active, !playing, status == .ready, historyID != nil || visible else { return }
        expireWaiting()
    }

    private func expireWaiting() {
        log.add("expired_waiting"); log.flush()
        history?.end(historyID, .stopped, summary: "Not answered"); historyID = nil
        clear()
    }

    /// The person answered the change on screen: Yes (with what Meta returned) or nil for No.
    func answered(_ e: AgentEvent?, defaultAccount: String?) {
        if onWebStop != nil { return }
        guard visible, status == .ready || playing else { return }
        guard let e else { log.add("answer_no"); log.flush(); history?.end(historyID, .declined, summary: "You said No"); historyID = nil; clear(); return }
        log.add("answer_yes")
        run.defaultAccount = defaultAccount
        queue += run.feed(e).map { (feedGen, .beat($0)) }
        kick()
    }

    func stop() {
        log.add("stop_pressed")
        log.flush()
        if let web = onWebStop { web() } else { onStop() }
        resolveAsk(.no)
        clear()
    }

    // MARK: the open web (WebAgent)
    // The same cursor, pill and shield over an ordinary site; WebAgent decides and sends the real clicks.

    struct WebAsk: Equatable {
        let question: String
        let human: Bool
        /// The words of the button a gate holds (nil: the model's own question or a hand-over).
        var button: String? = nil
        /// The site the page is on ("tutu.ru").
        var site: String = ""
    }
    /// How a wait for the person ended: Allow / Continue, No or Stop, or nobody answered in time.
    enum WebReply { case yes, no, timedOut }
    /// A question in the pill: Allow (a step that pays, books or sends) or Continue (after the person's login/captcha).
    /// Incident: it is also shown in the conversation (WebAskCenter), never only in the page.
    @Published private(set) var webAsk: WebAsk?
    private var webAnswer: CheckedContinuation<WebReply, Never>?
    private var webAskSerial = 0
    /// Set while a web task runs: Stop ends it (not the chat's turn, which is already over).
    var onWebStop: (() -> Void)?

    func webBegin(tab: BrowserTab, label: String) {
        player?.cancel(); playing = false
        generation = feedGen + 1; feedGen = generation; queue = []
        tabID = tab.id
        self.label = label
        marks = []; caption = nil; press = nil; status = .working; curtain = nil
        if cursor == nil { cursor = CGPoint(x: tab.webView.bounds.midX, y: 44) }
        withAnimation(.easeOut(duration: 0.2)) { active = true; visible = true }
    }

    /// Mirrors the label into the chat's working line (set by AppModel while a web task runs).
    var onWebLabel: ((String) -> Void)?
    /// (lag): the label changes several times an action ("Reading the page", "Clicking", ...), and the
    /// chat's line is a published value the whole conversation sheet redraws on. The same text is never sent again,
    /// and the chat hears at most one change every 0.6 s (the last one wins).
    func webLabel(_ s: String) {
        guard s != label else { return }
        label = s
        guard onWebLabel != nil else { return }
        let since = Date().timeIntervalSince(labelSentAt)
        if since >= 0.6 && labelJob == nil { labelSentAt = Date(); onWebLabel?(s); return }
        labelPending = s
        guard labelJob == nil else { return }
        labelJob = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(max(0.05, 0.6 - since) * 1_000_000_000))
            guard let self else { return }
            self.labelJob = nil
            if let p = self.labelPending { self.labelPending = nil; self.labelSentAt = Date(); self.onWebLabel?(p) }
        }
    }
    private var labelSentAt = Date.distantPast
    private var labelPending: String?
    private var labelJob: Task<Void, Never>?

    // A change drawn over Ads Manager is a task in the agent's history too (title, outcome, steps).
    private var historyID: String?
    private var history: AgentHistoryStore? { browser.flatMap { AgentHistoryStore.shared(for: $0) } }

    /// The glide takes longer the farther it goes (0.2-0.45 s) and always ends before the click, so the cursor is where
    /// the page reacts (the screen looked faster than the cursor).
    func webMove(to p: CGPoint, caption: String?) async {
        let from = cursor ?? p
        let d = Double(hypot(p.x - from.x, p.y - from.y))
        let dur = min(0.45, max(0.2, 0.15 + d / 2000))
        withAnimation(.timingCurve(0.4, 0.1, 0.2, 1, duration: dur)) { cursor = p }
        withAnimation(.easeOut(duration: 0.1)) { self.caption = (caption ?? "").isEmpty ? nil : caption }
        try? await Task.sleep(nanoseconds: UInt64((dur + 0.04) * 1_000_000_000))
    }

    func webPress(at p: CGPoint) {
        withAnimation(.easeOut(duration: 0.1)) { press = p }
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 220_000_000)
            withAnimation(.easeOut(duration: 0.15)) { self.press = nil }
        }
    }

    /// Waits for the person. A hand-over lifts the shield so they can use the page themselves.
    func webAskPerson(_ question: String, human: Bool) async -> Bool {
        await webAskPerson(question, human: human, button: nil, timeout: nil) == .yes
    }

    /// The same, shown in the conversation as well (WebAskCenter: a row above the input, the menu bar's "Waiting for
    /// your OK", a notification when the app is in the background), and ended by itself after `timeout` seconds.
    func webAskPerson(_ question: String, human: Bool, button: String?, timeout: TimeInterval?) async -> WebReply {
        resolveAsk(.no)   // never two waits at once
        webAskSerial += 1
        let serial = webAskSerial
        let host = browser?.tabs.first(where: { $0.id == tabID })?.webView.url?.host?.lowercased() ?? ""
        let ask = WebAsk(question: question, human: human, button: button, site: host.hasPrefix("www.") ? String(host.dropFirst(4)) : host)
        withAnimation(.easeOut(duration: 0.15)) { webAsk = ask; active = !human; caption = nil }
        labelBeforeAsk = label
        webLabel(human ? "Waiting for you on the page" : "Waiting for your OK")
        if let chat = log.chatId {
            WebAskCenter.shared.post(chat: chat, ask: ask, serial: serial, deadline: timeout.map { Date().addingTimeInterval($0) }) { [weak self] allow in
                guard let self, self.webAskSerial == serial else { return }
                if allow { self.webAnswered(true) } else { self.stop() }
            }
        }
        if let timeout {
            Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                guard let self, self.webAskSerial == serial, self.webAnswer != nil else { return }
                self.log.add("web_ask_timeout", ["seconds": Int(timeout), "gate": button != nil])
                self.resolveAsk(.timedOut)
            }
        }
        return await withCheckedContinuation { webAnswer = $0 }
    }

    /// Ends the wait in progress, if any: the pill and the conversation's row go, the waiting task hears `reply`.
    private func resolveAsk(_ reply: WebReply) {
        if let chat = log.chatId { WebAskCenter.shared.clear(chat: chat, serial: webAskSerial) }
        guard let k = webAnswer else { if webAsk != nil { withAnimation(.easeOut(duration: 0.15)) { webAsk = nil } }; return }
        webAnswer = nil
        withAnimation(.easeOut(duration: 0.15)) { webAsk = nil; if reply == .yes { active = true } }
        // the menu bar and the chat's line say what the agent does again, not "Waiting for your OK"
        if let l = labelBeforeAsk, onWebStop != nil { webLabel(l) }
        labelBeforeAsk = nil
        k.resume(returning: reply)
    }
    private var labelBeforeAsk: String?

    /// The task ended while its question waited: the question goes, and the waiting task hears No.
    func webCancelAsk() {
        guard webAnswer != nil else { return }
        resolveAsk(.no)
    }

    func webAnswered(_ yes: Bool) {
        resolveAsk(yes ? .yes : .no)
        withAnimation(.easeOut(duration: 0.15)) { active = yes }
    }

    func webEnd(ok: Bool, text: String) {
        onWebStop = nil
        labelJob?.cancel(); labelJob = nil; labelPending = nil
        resolveAsk(.no)
        withAnimation(.easeOut(duration: 0.2)) { active = false; caption = nil; press = nil; webAsk = nil; status = ok ? .applied : .failed(text) }
        let gen = generation
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_800_000_000)
            if self.generation == gen, !self.active { self.clear() }
        }
    }

    private func clear() {
        generation = feedGen + 1
        feedGen = generation
        queue = []
        player?.cancel()
        run = AgentRun(defaultAccount: run.defaultAccount, kindOf: run.kindOf, parentOf: run.parentOf)
        withAnimation(.easeOut(duration: 0.25)) {
            active = false; visible = false; cursor = nil; press = nil; caption = nil; marks = []; curtain = nil
        }
    }

    private func kick() {
        guard !playing else { return }
        playing = true
        player = Task { await play() }
    }

    private func play() async {
        defer { playing = false }
        while !queue.isEmpty {
            let item = queue.removeFirst()
            switch item.step {
            case let .begin(label, tool):
                guard item.gen > generation else { continue }
                generation = item.gen
                begin(label: label, tool: tool)
            case .beat(let b):
                guard item.gen == generation else { continue }
                await perform(b, gen: item.gen)
            }
        }
    }

    private func begin(label: String, tool: String) {
        // A change whose run finished waiting for its answer (its row says so) when the next one begins was
        // replaced, never answered (a second door inside one turn is not: its row is still running)
        let rowWaits = historyID.flatMap { id in history?.log.tasks.last(where: { $0.id == id })?.outcome } == .waiting
        if AgentWaitPolicy.supersedes(waiting: status == .ready, hasHistoryRow: rowWaits) {
            log.add("superseded_waiting")
            history?.end(historyID, .stopped, summary: "Not answered"); historyID = nil
        }
        self.label = label
        creating = tool.hasPrefix("create_")
        marks = []; caption = nil; press = nil; status = .working; setFields = []; quietFields = 0
        if let b = browser, !(tabID.map { id in b.tabs.contains { $0.id == id } } ?? false) { tabID = b.selected?.id }
        if cursor == nil, let w = webView { cursor = CGPoint(x: w.bounds.midX, y: 44) }
        withAnimation(.easeOut(duration: 0.2)) { active = true; visible = true }
        if let w = webView, w.window?.firstResponder === w { w.window?.makeFirstResponder(nil) }
        log.begin(["tool": tool, "label": label, "gen": generation])
        if let h = history {
            let agent = browser?.chatID.map { String($0.dropFirst("agent-".count)) } ?? "met"
            historyID = h.begin(agent: agent, title: label.isEmpty || label == tool ? ToolPhrases.title(tool) : label)
        }
    }

    private var webView: WKWebView? {
        guard let b = browser else { return nil }
        if let id = tabID, let t = b.tabs.first(where: { $0.id == id }) { return t.webView }
        return b.selected?.webView
    }

    // MARK: beats

    private func perform(_ beat: AgentBeat, gen: Int) async {
        func live() -> Bool { gen == generation }
        checkNavigation()
        switch beat {
        case .open(let url):
            history?.step(historyID, AgentStepPhrase.of(.navigate(url)))
            await open(url, gen: gen)
        case .point(let target):
            await point(target, gen: gen)
        case .ghostRow(let title):
            // A new object: no drawn row over the real table (it covered the page and ran off its edge);
            // the cursor's tag says what is being filled.
            await say(title, ms: 700, gen: gen)
        case let .field(key, label, value, done):
            await field(key: key, label: label, value: value, done: done, gen: gen)
        case .checking:
            log.add("meta_check")
            history?.step(historyID, AgentStepPhrase.Phrase(text: "Checked it with Meta", kind: "check"))
            if quietFields > 0 { await say("+\(quietFields) settings", ms: 500, gen: gen); quietFields = 0 }
            withAnimation(.easeOut(duration: 0.15)) { status = .checking; caption = nil }
        case let .result(ok, error, diff):
            log.add("result", ["ok": ok, "error": error ?? "", "diff": diff.count])
            // A door Lia's own guard turned back is her course correction, not the person's error: it is logged, the
            // pill keeps working (the guard's long text showed as an error in the pill).
            if ok { withAnimation(.easeOut(duration: 0.15)) { status = .ready } }
            else { withAnimation(.easeOut(duration: 0.15)) { status = .working; caption = nil } }
        case let .applied(url, ok, error, walk):
            log.add("applied", ["ok": ok, "error": error ?? "", "url": url?.absoluteString ?? "", "walk": walk])
            history?.end(historyID, ok ? .done : .failed, summary: ok ? "Applied in Meta" : (error ?? "Not applied"))
            if ok, let url { await change(to: url, gen: gen) }
            guard live() else { return }
            withAnimation(.easeOut(duration: 0.2)) { marks = []; status = ok ? .applied : .failed(error ?? "Not applied") }
            if ok, walk { await walkFields(gen: gen) }
        case .finish:
            log.add("finish", ["status": "\(status)"])
            log.flush()
            withAnimation(.easeOut(duration: 0.2)) { active = false; press = nil; caption = nil }
            if let h = history, let id = historyID, h.log.tasks.last(where: { $0.id == id })?.outcome == .running {
                switch status {
                case .ready: h.end(id, .waiting, summary: "Waiting for your answer in the chat")
                case .failed(let why), .refused(let why): h.end(id, .failed, summary: why); historyID = nil
                default: h.end(id, .done); historyID = nil
                }
            }
            if status == .ready { return }   // the change waits for an answer: ours stays readable
            // Another run already waits in the queue: it takes over without a gap.
            if queue.contains(where: { if case .begin = $0.step { return true }; return false }) { return }
            try? await Task.sleep(nanoseconds: hurry ? 700_000_000 : 1_600_000_000)
            if live(), !active, queue.isEmpty { clear() }
        }
    }

    /// A load in the agent's tab that the agent did not ask for (a redirect, a page script): logged with its address.
    private func checkNavigation() {
        guard let exp = expected, let now = webView?.url, now.host != exp.host || now.path != exp.path else { return }
        log.add("nav_unexpected", ["expected": exp.absoluteString, "now": now.absoluteString])
        expected = now
    }

    private func glide(to p: CGPoint, gen: Int, why: String) async {
        guard gen == generation else { return }
        if cursor == nil, let w = webView {
            cursor = CGPoint(x: w.bounds.midX, y: 44)
            try? await Task.sleep(nanoseconds: 30_000_000)
        }
        let from = cursor ?? .zero
        withAnimation(Self.move) { cursor = p }
        log.add("move", ["why": why, "from": [Int(from.x), Int(from.y)], "to": [Int(p.x), Int(p.y)], "ms": 550])
        try? await Task.sleep(nanoseconds: 600_000_000)
    }

    /// A drawn press: the ring where the cursor is, then a short pause (browser.js agClick, 300 + 380 ms).
    private func drawPress(at p: CGPoint, gen: Int) async {
        guard gen == generation else { return }
        withAnimation(.easeOut(duration: 0.12)) { press = p }
        try? await Task.sleep(nanoseconds: 300_000_000)
        withAnimation(.easeOut(duration: 0.2)) { press = nil }
        try? await Task.sleep(nanoseconds: 380_000_000)
    }

    /// The cursor's tag says something for a moment.
    private func say(_ text: String, ms: UInt64, gen: Int) async {
        guard gen == generation else { return }
        withAnimation(.easeOut(duration: 0.12)) { caption = text }
        try? await Task.sleep(nanoseconds: ms * 1_000_000)
    }

    /// A control brought into view and measured where it rests. A list that drew it again leaves the old element
    /// detached (it measured at the corner, so the cursor went to the top left): it is found again by its signature
    /// on the page as it is now, or skipped. A point outside the view is never used.
    private func reach(_ c: AgentBridge.Control, in w: WKWebView, why: String) async -> CGRect? {
        let ok = { (r: CGRect) -> Bool in r.width >= 2 && r.height >= 2 && w.bounds.insetBy(dx: -2, dy: -2).contains(CGPoint(x: r.midX, y: r.midY)) }
        if let at = await AgentBridge.reveal(w, ref: c.ref), ok(at.rect) { return at.rect }
        let sig = AgentLocator.signature(c)
        if let again = await AgentBridge.controls(w).first(where: { AgentLocator.signature($0) == sig }),
           let at = await AgentBridge.reveal(w, ref: again.ref), ok(at.rect) {
            log.add("refound", ["why": why, "old": c.ref, "new": again.ref])
            return at.rect
        }
        log.add("lost", ["why": why, "el": String(c.line.prefix(100))])
        return nil
    }

    private func aim(_ r: CGRect) -> CGPoint { CGPoint(x: r.width > 160 ? r.minX + 60 : r.midX, y: r.midY) }   // browser.js agAim

    private func point(_ target: AgentTarget, gen: Int) async {
        guard let w = webView else { return }
        switch target {
        case .create(let level):
            guard let c = await locator.locate([AgentLocator.create(level)], in: w)["create"] else {
                log.add("miss", ["target": "create"]); return
            }
            guard let at = await reach(c, in: w, why: "create"), gen == generation else { return }
            await glide(to: aim(at), gen: gen, why: "create")
            await drawPress(at: aim(at), gen: gen)
        case let .row(id, name):
            var rect: CGRect?
            if let id { rect = await AgentBridge.row(w, id: id)?.rect }
            if rect == nil, let name, let c = await locator.locate([AgentLocator.row(name: name)], in: w)["row"] {
                rect = await reach(c, in: w, why: "row")
            }
            if let rect, gen == generation { await glide(to: aim(rect), gen: gen, why: "row") }
            else { log.add("miss", ["target": "row", "id": id ?? "", "name": name ?? ""]) }
        }
    }

    private func field(key: String, label: String, value: String, done: Bool, gen: Int) async {
        if done { setFields.removeAll { $0.key == key }; setFields.append((key, label, value)) }
        if done { history?.step(historyID, AgentStepPhrase.field(label)) }
        // A new object has no page of its own yet: by Create, the cursor names it and its budget, and how many other
        // settings it fills; the walk after Yes shows each of them on Meta's real editor (a tag per setting
        // read as the cursor checking fields it never went to).
        if creating {
            guard done else { return }
            log.add("fill", ["key": key, "value": value])
            if key == "name" || key.hasSuffix("budget") { await say(Self.tag(label, value), ms: 650, gen: gen) }
            else { quietFields += 1 }
            return
        }
        guard let w = webView else { return }
        if located[key] == nil && !asked.contains(key) {
            // This field and every field already waiting: one question each, one call.
            var wants: [AgentLocator.Want] = [AgentLocator.field(key: key, label: label, value: value, level: run.level)]
            for item in queue where item.gen == gen {
                if case let .beat(.field(k, l, v, _)) = item.step, k != key, located[k] == nil, !asked.contains(k) {
                    wants.append(AgentLocator.field(key: k, label: l, value: v, level: run.level))
                }
            }
            let found = await locator.locateScrolling(wants, in: w, pages: 2)
            guard gen == generation else { return }
            if !locator.lastFailed { for want in wants { asked.insert(String(want.name.dropFirst(2))) } }
            for (n, c) in found { located[String(n.dropFirst(2))] = c }
        }
        // Not on this page: nothing is drawn and nothing is said (tags for fields it never went to confused).
        guard let c = located[key] else { log.add("miss", ["target": "field", "key": key]); return }
        guard let rect = await reach(c, in: w, why: "field:" + key), gen == generation else { return }
        let at = (ref: c.ref, rect: rect)
        await glide(to: aim(at.rect), gen: gen, why: "field:" + key)
        guard gen == generation else { return }
        withAnimation(.easeOut(duration: 0.12)) { caption = Self.tag(label, value) }
        let t0 = log.now
        switch c.kind {
        case "text", "number":
            await typeMark(key: key, rect: at.rect, kind: "text", style: c.style, value: value, gen: gen)
        case "select":
            await drawPress(at: aim(at.rect), gen: gen)
            upsert(Mark(key: key, rect: at.rect, kind: "select", style: c.style, value: value, typed: value, menu: true))
            try? await Task.sleep(nanoseconds: 850_000_000)   // browser.js agFakeOpen
            if gen == generation, let i = marks.firstIndex(where: { $0.key == key }) { withAnimation(.easeOut(duration: 0.15)) { marks[i].menu = false } }
        case "radio", "checkbox", "switch":
            await drawPress(at: aim(at.rect), gen: gen)
            upsert(Mark(key: key, rect: at.rect, kind: "toggle", style: nil, value: value, typed: value))
        default:
            upsert(Mark(key: key, rect: at.rect, kind: "show", style: nil, value: value, typed: value))
            try? await Task.sleep(nanoseconds: 500_000_000)
        }
        log.add("draw", ["key": key, "kind": c.kind, "chars": value.count, "ms": log.now - t0])
    }

    private func upsert(_ m: Mark) {
        withAnimation(.easeOut(duration: 0.15)) {
            if let i = marks.firstIndex(where: { $0.key == m.key }) { marks[i] = m } else { marks.append(m) }
        }
    }

    private func typeMark(key: String, rect: CGRect, kind: String, style: AgentBridge.Style?, value: String, gen: Int) async {
        let had = marks.first(where: { $0.key == key })?.typed ?? ""
        upsert(Mark(key: key, rect: rect, kind: kind, style: style, value: value, typed: value.hasPrefix(had) ? had : ""))
        let target = Array(value)
        let step = max(1, target.count / 35)
        while gen == generation, let i = marks.firstIndex(where: { $0.key == key }), marks[i].typed.count < target.count {
            let n = min(target.count, marks[i].typed.count + step)
            marks[i].typed = String(target[0..<n])
            try? await Task.sleep(nanoseconds: Self.letter)
        }
    }

    /// After Yes on a new object: the cursor passes over each field Lia set, on Meta's real editor (agentShow).
    private func walkFields(gen: Int) async {
        guard let w = webView, !setFields.isEmpty else { return }
        // Short when more is coming or the chat is done: the walk never holds the next change back.
        let next = queue.contains { if case .begin = $0.step { return true }; return false }
        let cap = next ? 3 : 5
        let fields = Array(setFields.prefix(cap))
        let found = await locator.locateScrolling(fields.map { AgentLocator.field(key: $0.key, label: $0.label, value: $0.value, level: run.level) }, in: w, pages: hurry ? 1 : 2)
        log.add("walk", ["fields": fields.map(\.key), "found": found.keys.sorted(), "cap": cap, "of": setFields.count])
        for f in fields {
            guard gen == generation else { return }
            guard let c = found["f_" + f.key], let rect = await reach(c, in: w, why: "walk:" + f.key) else { continue }
            await glide(to: aim(rect), gen: gen, why: "walk:" + f.key)
            upsert(Mark(key: f.key, rect: rect, kind: "show", style: nil, value: f.value, typed: f.value))
            await say(Self.tag(f.label, f.value), ms: 450, gen: gen)
            withAnimation(.easeOut(duration: 0.2)) { marks.removeAll { $0.key == f.key } }
        }
        withAnimation(.easeOut(duration: 0.15)) { caption = nil }
    }

    // MARK: pages

    /// The agent's tab: its own Ads Manager tab, or the current tab when it is blank, or a new one. Only an Ads
    /// Manager page is reused (an Events Manager tab is the person's).
    private func agentTab() -> BrowserTab? {
        guard let b = browser else { return nil }
        let isAds = { (t: BrowserTab) -> Bool in t.url?.host == "adsmanager.facebook.com" }
        if let id = tabID, let t = b.tabs.first(where: { $0.id == id }), t.isStart || isAds(t) { return t }
        if let t = b.tabs.first(where: isAds) { return t }
        if let t = b.selected, t.isStart { return t }
        return b.newTab(url: nil)
    }

    private func open(_ url: URL, gen: Int) async {
        guard let b = browser, let tab = agentTab() else { return }
        tabID = tab.id
        b.selectedID = tab.id
        located = [:]; asked = []
        guard gen == generation else { return }
        // Already there (a restored tab starts loading when it is selected above): read it once it has drawn.
        if tab.url == url {
            let n = tab.webView.isLoading ? await ready(tab) : -1
            log.add("open_same", ["url": url.absoluteString, "controls": n]); return
        }
        await change(to: url, gen: gen)
    }

    /// A page change behind a picture of the old page: the new one loads under it and shows once it has drawn.
    private func change(to url: URL, gen: Int) async {
        guard let b = browser, let id = tabID, let tab = b.tabs.first(where: { $0.id == id }) else { return }
        let t0 = log.now
        if !tab.isStart {
            let shot: NSImage? = await withCheckedContinuation { k in
                tab.webView.takeSnapshot(with: nil) { img, _ in k.resume(returning: img) }
            }
            guard gen == generation else { return }
            curtain = shot
        }
        withAnimation(.easeOut(duration: 0.2)) { marks = []; press = nil }
        located = [:]; asked = []
        expected = url
        tab.load(url)
        let controls = await ready(tab)
        log.add("open", ["url": url.absoluteString, "ms": log.now - t0, "controls": controls, "landed": tab.webView.url?.absoluteString ?? ""])
        withAnimation(.easeInOut(duration: 0.4)) { curtain = nil }
        try? await Task.sleep(nanoseconds: 250_000_000)
    }

    /// Loaded, and drawn. Meta paints a shell of ~10 controls first and the table or editor after it (chat
    /// cu51pw5wo: the shell was taken for the page, every lookup came back empty and the cursor never moved), so the
    /// page counts as ready when it has a real number of controls (20+) and two readings 300 ms apart agree; a page
    /// that never gets there is taken as it is after 10 s. Meta's own endless loading is not waited for.
    private func ready(_ tab: BrowserTab) async -> Int {
        let t0 = Date()
        for _ in 0..<5 where !tab.webView.isLoading { try? await Task.sleep(nanoseconds: 60_000_000) }
        var last = -1, n = 0, stable = 0
        for _ in 0..<34 {
            try? await Task.sleep(nanoseconds: 300_000_000)
            n = await AgentBridge.controls(tab.webView, limit: 400).count
            if n >= 20 && abs(n - last) <= 2 { stable += 1; if stable >= 1 { break } } else { stable = 0 }
            last = n
        }
        log.add("ready", ["ms": Int(Date().timeIntervalSince(t0) * 1000), "controls": n, "loading": tab.webView.isLoading])
        return n
    }
}


/// Incident (dlg:pncnhjyjam4:team): a web agent's question waited only as a small pill inside the page; the
/// person never saw it and the task sat for minutes. Every wait is posted here by the chat it belongs to (AgentLog's
/// chatId: a dialogue's `sessionId`, a chat's id), and the conversation draws it above its input (WebAskRow).
@MainActor
final class WebAskCenter: ObservableObject {
    static let shared = WebAskCenter()

    struct Pending: Identifiable, Equatable {
        let chat: String
        let serial: Int
        let ask: AgentDirector.WebAsk
        let since: Date
        let deadline: Date?
        var id: String { chat + "#" + String(serial) }
        static func == (a: Pending, b: Pending) -> Bool { a.id == b.id && a.ask == b.ask }
    }

    @Published private(set) var pending: [String: Pending] = [:]
    private var respond: [String: (Bool) -> Void] = [:]

    func post(chat: String, ask: AgentDirector.WebAsk, serial: Int, deadline: Date?, respond r: @escaping (Bool) -> Void) {
        pending[chat] = Pending(chat: chat, serial: serial, ask: ask, since: Date(), deadline: deadline)
        respond[chat] = r
    }

    func clear(chat: String, serial: Int) {
        guard let p = pending[chat], p.serial <= serial else { return }
        pending[chat] = nil
        respond[chat] = nil
    }

    /// The person's answer from the conversation: Allow (Continue) lets the task go on, Stop ends it.
    func answer(chat: String, allow: Bool) {
        guard let r = respond[chat] else { return }
        r(allow)
    }
}

/// The conversation's row for a web agent waiting on the person: "Lia wants to press «Pay» on site.com - Allow / Stop".
struct WebAskRow: View {
    let pending: WebAskCenter.Pending
    var agentName = "Lia"
    let answer: (Bool) -> Void

    private var ask: AgentDirector.WebAsk { pending.ask }
    private var place: String { ask.site.isEmpty ? "" : " on " + ask.site }
    private var heading: String {
        if let b = ask.button { return "\(agentName) wants to press \u{201C}\(b)\u{201D}\(place)" }
        return ask.human ? "\(agentName) needs you on the page\(place)" : "\(agentName) asks before going on\(place)"
    }
    private var detail: String {
        ask.button != nil ? "This may pay, book, send or delete something. Nothing is pressed until you allow it." : ask.question
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: ask.human ? "hand.raised.fill" : "exclamationmark.shield.fill")
                    .font(.system(size: 13)).foregroundStyle(AppConfig.accent)
                Text(heading).font(LiaFont.ui(14, .semibold)).foregroundStyle(WS.ink).lineLimit(2)
            }
            Text(detail).font(LiaFont.ui(12.5)).foregroundStyle(WS.text2).lineLimit(3)
            HStack(spacing: 8) {
                Button { answer(true) } label: {
                    Text(ask.human ? "Continue" : "Allow").font(LiaFont.ui(12.5, .semibold)).foregroundStyle(AppConfig.onAccent)
                        .padding(.horizontal, 14).padding(.vertical, 6).background(Capsule().fill(AppConfig.accent))
                }
                .buttonStyle(.liaPlain)
                Button { answer(false) } label: {
                    Text("Stop").font(LiaFont.ui(12.5, .semibold)).foregroundStyle(WS.ink)
                        .padding(.horizontal, 14).padding(.vertical, 6)
                        .background(Capsule().fill(WS.surface)).overlay(Capsule().stroke(AppConfig.line2))
                }
                .buttonStyle(.liaPlain)
                Spacer(minLength: 0)
                if let d = pending.deadline, ask.button != nil {
                    Text("No answer by " + d.formatted(date: .omitted, time: .shortened) + ": \(agentName) stops before pressing it")
                        .font(LiaFont.ui(11.5)).foregroundStyle(WS.text3)
                }
            }
        }
        .padding(14)
        .background(WS.surface, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).stroke(AppConfig.accent.opacity(0.55), lineWidth: 1))
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text(heading + ". " + detail))
    }
}
