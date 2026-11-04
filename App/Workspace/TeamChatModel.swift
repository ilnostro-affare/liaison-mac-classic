import SwiftUI
import Combine

/// One message of a dialogue, with the agent that said it (nil: the person).
struct TeamItem: Identifiable, Equatable {
    /// The server's id once stored; a local id ("l-...") while it is only drawn here.
    let id: String
    var agent: String?
    var message: ChatMessage
    /// The server's order (0 while the message is only local).
    var seq: Int = 0
    /// Where the person's message came from (the server's `origin`, or the surface it was sent from here).
    var origin: DlgOrigin? = nil
    /// A task card (role system) or a message worked for a task.
    var taskId: String? = nil
    var isTask = false
    /// Stored on the server (it came from a page or a `msg` line).
    var confirmed = false
    /// Dev's turn, the message's place in it and whether it is the turn's final one (DevThread).
    var run: String? = nil
    var seg: Int? = nil
    var fin = false
    /// A task's first row in this (its owner's) dialogue: the words as written, drawn with "Asked in <dialogue>"
    /// Back to where it was asked. Never the person's own message here (no retry, no delivery merge, no edit).
    var handed = false
    /// The answer this message is a part of (its parts are picked and forwarded together).
    var turn: String? = nil

    var threadEntry: DevThread.Entry { DevThread.Entry(id: id, agent: agent, run: run, seg: seg, fin: fin) }

    /// The message as AgentAttention reads it (a local, unstored copy has seq 0 and never counts).
    var attention: AgentAttention.Message {
        AgentAttention.Message(agent: agent, seq: seq, hasGate: message.gateJSON != nil, isTask: isTask, handed: handed,
                               toDlg: origin?.toDlg, run: run, fin: fin)
    }
}

/// One agent's endless dialogue in a workspace, or Team with Lia (lia-agents /agents/turn,
/// Docs/DIALOGUES-API.md). The newest 50 messages load first; older pages come in as the top scrolls into view; a
/// Search hit or a task card jumps to a window around its message. Each agent's answer is Lia 2.0's own stream,
/// So LiveTurn reduces it exactly as in the chat; a `msg` line then puts the stored copy in its place.
/// Approvals (Met's changes) are applied here as in ChatViewModel and told back to the agent that asked.
@MainActor
final class TeamChatModel: ObservableObject {
    let auth: AuthStore
    let profile: String
    /// "team" or an agent id.
    let dlg: String
    /// The cache key everywhere on this Mac (drafts, pins, schedules, notifications).
    var key: String { profile + "|" + dlg }
    var isTeam: Bool { dlg == "team" }
    /// The dialogue's own agent ("lia" for Team).
    var agentId: String { isTeam ? "lia" : dlg }
    /// The write agent takes part: the mode picker shows here only (Team and Met).
    /// Met answers only in its own dialogue now (an @Met elsewhere is a task worked there), so only there.
    var hasWriter: Bool { dlg == "met" }
    /// What the journal, the locator and the agent log know this dialogue by.
    var sessionId: String { "dlg:" + profile + ":" + dlg }
    /// The account name as it was when the model was made; `currentAccountName` (the profile now) wins when set.
    private let initialAccountName: String?
    /// Reads the dialogue's profile at the moment of use, so a changed account is never applied under the old name.
    var currentAccountName: (() -> String?)?
    var accountName: String? {
        if let read = currentAccountName { return read() }
        return initialAccountName
    }
    @Published private(set) var items: [TeamItem] = [] {
        didSet { rethread(); notePages() }
    }
    /// Dev's messages between the first and the last of a turn: in the artifact's Activity, not in the thread.
    private(set) var hiddenInThread: Set<String> = []
    /// The rows the thread draws (the thread rule applied; hidden messages stay in `items` for search and export).
    /// Stored, not computed (the messenger lagged): the thread read it several times per redraw, and
    /// It redraws on every streamed token.
    private(set) var threadItems: [TeamItem] = []
    /// The thread rule again (DevThread): Dev's turn running now hides every message but its first and its final one.
    private func rethread() {
        hiddenInThread = DevThread.hidden(items.map(\.threadEntry), liveRun: devRun)
        threadItems = hiddenInThread.isEmpty ? items : items.filter { !hiddenInThread.contains($0.id) }
    }
    /// Parsed approval cards by message id (with the JSON they came from): `openGate` and every row asked for the
    /// Gate, and each ask parsed its JSON again, on every streamed token.
    private var gateCache: [String: (json: String, gate: Gate?)] = [:]
    /// The approval card of `item` (nil: none), parsed once per stored JSON.
    func gate(of item: TeamItem) -> Gate? {
        guard let j = item.message.gateJSON else { return nil }
        if let c = gateCache[item.id], c.json == j { return c.gate }
        let g = item.message.gate
        if gateCache.count > 400 { gateCache.removeAll() }
        gateCache[item.id] = (j, g)
        return g
    }
    @Published private(set) var live: LiveTurn?
    /// After the first `segment_end` of Dev's turn its words never show in the chat, not even while
    /// They stream: they go to the live Activity, and the chat shows only the typing line until the final message.
    @Published private(set) var devQuiet = false
    /// How many `segment_end`s Dev's turn has had.
    private var devSegEnds = 0
    /// The answer the chat draws streaming now: nothing of it while Dev is quiet (an empty turn: the typing line).
    var chatLive: LiveTurn? {
        guard let l = live else { return nil }
        return devQuiet && liveAgent == "dev" ? LiveTurn(startedAt: l.startedAt) : l
    }
    /// The dialogue's newest preview or live site (a Preview card, or `preview` on Changes / a push),
    /// The Canvas's Preview for an item with no page of its own. Never cleared by an older window.
    private(set) var latestDevPage: URL?
    private var latestDevPageSeq = -1

    /// The newest page among the stored messages, when newer than the one known (the window at the newest only).
    private func notePages() {
        guard !hasMoreAfter else { return }
        for it in items.reversed() {
            guard let u = it.message.blocks.reversed().lazy.compactMap({ CanvasItem.page(of: $0) }).first else { continue }
            if it.seq >= latestDevPageSeq { latestDevPage = u; latestDevPageSeq = it.seq }
            return
        }
    }
    @Published private(set) var liveAgent: String?
    @Published private(set) var busy = false
    @Published private(set) var loaded = false
    @Published var errorText: String?
    /// CHAT-14: the person's messages written while a run is going, sent one by one after it (editable, removable).
    @Published var queue: [String] = []
    /// Tasks given this agent while it was working (an @Name in another dialogue): drawn as queued lines,
    /// Each started as soon as the run in front of it ends, with the packet the server kept (the context at the mention).
    @Published private(set) var queuedTasks: [AgentTask] = []
    /// CHAT-15: files uploaded for a queued message (by its text), sent with it when its turn comes.
    private var queuedAttachments: [String: [ChatAttachment]] = [:]
    /// ERR-01: items that are an agent's error (drawn as an error card, not as a bubble).
    @Published private(set) var errorItems: Set<String> = []
    /// ERR-03: seconds left before a busy/limit error is retried by itself (nil: no retry waiting).
    @Published private(set) var retryIn: Int?
    @Published private(set) var applying = false
    /// CHAT-27: bumped for a success worth a small burst (an applied change, an agent's \u{2705} first line).
    @Published private(set) var celebrate = 0
    /// CHAT-27: whose colour the burst takes.
    private(set) var celebrateAgent: String?

    // MARK: the loaded window

    /// Older messages exist above the first one loaded (the top loads them when it comes into view).
    @Published private(set) var hasMoreBefore = false
    /// The window is not the newest part (after a jump): newer messages load at the bottom, or "Jump to latest".
    @Published private(set) var hasMoreAfter = false
    @Published private(set) var loadingOlder = false
    @Published private(set) var loadingNewer = false
    /// Bumped whenever a message joins the end (not when older pages come in above).
    @Published private(set) var appended = 0
    /// Tasks this dialogue handed over or works, by id (task cards show their status).
    @Published private(set) var tasks: [String: AgentTask] = [:]
    /// A message to bring into view (a jump); the thread scrolls to it and flashes it.
    struct ScrollRequest: Equatable { let id: String; let n: Int; let at: Date }
    @Published private(set) var scrollRequest: ScrollRequest?
    @Published private(set) var flash: String?
    /// The newest seq seen (pages and stream), for unread dots.
    private(set) var latestSeq = 0
    var onSeq: ((Int) -> Void)?
    private var windowOldestSeq: Int?
    private var windowNewestSeq = 0
    private var windowNewestId: String?
    private var scrollN = 0

    /// The agent running a browser task in its own browser, and what it is doing.
    @Published var webAgent: String? {
        didSet {
            report()
            // SND-01: the agent's browser task ended.
            if oldValue != nil && webAgent == nil { ChatSounds.play(.done) }
        }
    }
    @Published var webStatus = ""
    /// Incident 2026-10-16: the web agent waits on the person (a press that may pay or send, a hand-over). Drawn above
    /// The input (WebAskRow), counted as waiting for the menu bar, the dock and the background notification.
    @Published private(set) var webGate: WebAskCenter.Pending? {
        didSet { if (oldValue == nil) != (webGate == nil) { report() } }
    }
    private var webGateSub: AnyCancellable?

    /// The person's answer to the web agent's question from the conversation: Allow goes on, Stop ends the task.
    func answerWebGate(allow: Bool) {
        WebAskCenter.shared.answer(chat: sessionId, allow: allow)
    }
    /// Auto: one Yes per task. Manual: a Yes per step. Only where the write agent takes part.
    @Published var mode: RunMode {
        didSet {
            UserDefaults.standard.set(mode.rawValue, forKey: "lia_ws_mode_" + key)
            // Leaving Auto ends the task's one Yes.
            if mode != .auto { taskYes = false }
        }
    }

    /// Dev's Auto / Manual, per workspace (sent as `dev_mode` with Dev's turns).
    @Published var devMode: DevMode {
        didSet { UserDefaults.standard.set(devMode.rawValue, forKey: DevMode.key(profile: profile)) }
    }
    /// What Dev is doing now ("Editing files"), from `dev_status`; nil between steps and after the turn.
    @Published private(set) var devStatus: String?
    /// Dev's steps of its last turn that worked (the Canvas's Activity).
    @Published private(set) var devActivity = DevActivity()
    /// The agent expected to answer, drawn "writing" the moment the person sends, before
    /// The server names it (cleared when it starts).
    @Published private(set) var pendingAgent: String?
    /// The person's answers to Dev's questions in this session, by message id (also kept in ChatDecisions).
    @Published private(set) var devAnswers: [String: Bool] = [:]
    /// The agent whose answer the run is streaming (kept across Dev's steps, which close and reopen the bubble).
    private var turnAgent: String?
    /// Dev's task in "What did Dev do?" for the turn running now.
    private var devHistoryID: String?
    /// The `run` of Dev's turn going now (from its first stored message), so its messages written before the
    /// First step stay in the live Activity.
    private var devRun: String? { didSet { if devRun != oldValue { rethread() } } }

    var browserContext: (() async -> [String: Any]?)?
    /// Screen Time and the open tabs, with turns to Lia only (nil: the person turned it off).
    var liaContext: (() async -> [String: Any]?)?
    /// An agent asked for a picture of the front tab (the turn stopped on `screen_look`).
    var onScreenLook: ((String, ScreenLook) -> Void)?
    /// The page the last turn carried to the agents (the small line under the composer), and whether an agent
    /// Looked at a picture of it.
    @Published private(set) var screenSeen: ScreenShare.Seen?
    @Published private(set) var screenLooked = false
    func noteLooked(_ on: Bool) { screenLooked = on }
    var onBrowserTask: ((String, String, String, String, String?) -> Void)?
    var onActivity: ((Set<String>, Set<String>) -> Void)?
    /// A task this turn made for another agent: start it in that agent's own dialogue (WorkspaceModel).
    var onTaskRun: ((String, AgentTask) -> Void)?
    var onStopWeb: (() -> Void)?
    /// The write agent's trace (act_intent / act_arg / applied ...) for the drawing over its Ads Manager.
    var onTrace: ((String, AgentEvent) -> Void)?
    /// The person's answer to an approval, for the drawing (nil: No).
    var onTraceAnswer: ((String, AgentEvent?) -> Void)?
    private var traced: Set<String> = []

    /// The person said Yes to this task (Auto): the write agent goes on without asking until the person writes again.
    private var taskYes = false
    /// Answers the person does not type (approvals, browser reports), each for the agent that asked; before `queue`.
    private var machineQueue: [(text: String, agent: String, attachments: [ChatAttachment])] = []
    private var retryTask: Task<Void, Never>?
    private var autoRetries = 0
    private var runTask: Task<Void, Never>?
    private var loadStarted = false
    /// The last run exactly as sent (text, agent, files), so a busy retry repeats it - a gate reply stays a gate reply.
    private var lastRun: (text: String, agent: String?, attachments: [ChatAttachment], origin: DlgOrigin.Surface?)?

    init(auth: AuthStore, profile: String, dlg: String, accountName: String?) {
        self.auth = auth
        self.profile = profile
        self.dlg = dlg
        self.initialAccountName = accountName
        mode = RunMode(rawValue: UserDefaults.standard.string(forKey: "lia_ws_mode_" + profile + "|" + dlg) ?? "") == .manual ? .manual : .auto
        devMode = DevMode.stored(UserDefaults.standard.string(forKey: DevMode.key(profile: profile)))
        let sid = "dlg:" + profile + ":" + dlg
        webGateSub = WebAskCenter.shared.$pending
            .map { $0[sid] }
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] p in MainActor.assumeIsolated { self?.webGate = p } }
    }

    /// Dev answers in this dialogue (its own, or Team when the run names it).
    var isDev: Bool { dlg == "dev" }

    /// The line under the agent writing now: Dev's status, another agent's tool phrase, else nil ("is writing").
    var typingStatus: String? {
        TypingLine.text(devStatus: liveAgent == "dev" ? devStatus : nil, live: live)
    }

    private var api: LiaAPI { LiaAPI(auth: auth) }

    /// The open approval: only the last message can hold one (an older one was answered by what came after it).
    var openGate: (item: TeamItem, gate: Gate)? {
        // While the Yes is being applied the card stays (buttons off, spinner); markGateDone already flipped `done`.
        guard !busy, !hasMoreAfter, let last = items.last, last.agent != nil, let g = gate(of: last), !g.done || applying else { return nil }
        return (last, g)
    }

    // MARK: - loading (newest page, older pages, a window around a message)

    func load() async {
        guard !loaded, !loadStarted else { return }
        loadStarted = true
        if let r = try? await api.dialogPage(profile: profile, dlg: dlg) {
            window(r.messages, keepLocal: true)
            hasMoreBefore = r.hasMore
            hasMoreAfter = false
        }
        loaded = true
        report()
        // Dev's turn still running on the server: its intermediate messages stay out of the chat.
        if devRun == nil, let r = await api.devLiveRun(profile: profile) { devRun = r }
        if let t = try? await api.agentTasks(profile: profile, dlg: dlg) {
            for x in t where tasks[x.id] == nil { tasks[x.id] = x }
        }
    }

    /// Waits for a load already on its way (a jump into a dialogue that is opening now).
    private func loadAndWait() async {
        await load()
        var n = 0
        while !loaded && n < 100 { try? await Task.sleep(nanoseconds: 100_000_000); n += 1 }
    }

    /// The stored message as a row (nil: a machine reply, stored but never shown).
    private func item(_ m: DlgMessage) -> TeamItem? {
        var msg = m.chatMessage
        if m.role == .user && AgentOf.isMachine(msg) { return nil }
        // A task handed to this agent - the words as written (the person's bubble, or the teammate's line), never
        // The "[handoff] ..." packet the model reads, never a task card with a status
        if m.isHandedTask {
            let person = DlgHandoff.byPerson(m)
            let words = DlgHandoff.shown(m.text)
            let shown = ChatMessage(id: m.id, role: person ? .user : .assistant, content: person ? words : AgentPrefix.strip(words),
                                    attachments: m.attachments, ts: m.ts.map { $0.timeIntervalSince1970 * 1000 })
            return TeamItem(id: m.id, agent: person ? nil : (m.agent ?? m.origin?.fromAgent ?? agentId), message: shown, seq: m.seq,
                            origin: m.origin, taskId: m.taskId, isTask: false, confirmed: true, handed: true)
        }
        // An assistant or system message stored without "agent" is still an agent's (never the person's bubble).
        let agent: String? = m.role == .user ? nil : (m.agent ?? agentId)
        if agent != nil { msg.content = AgentPrefix.strip(msg.content) }
        return TeamItem(id: m.id, agent: agent, message: msg, seq: m.seq, origin: m.origin, taskId: m.taskId,
                        isTask: m.isTaskCard, confirmed: true, run: m.run, seg: m.seg, fin: m.fin, turn: m.turn)
    }

    private func track(_ raw: [DlgMessage], notify: Bool = true) {
        guard let mx = raw.map(\.seq).max(), mx > latestSeq else { return }
        let before = latestSeq
        latestSeq = mx
        onSeq?(mx)
        // A notification and the dock's bounce only for what needs the person (AgentAttention), and
        // Only for messages new since this dialogue was read (never its history on the first load: `notify` false).
        guard notify, let cb = onAttention else { return }
        for m in raw where m.seq > before {
            if let k = AgentAttention.kind(AgentAttention.Message(m), in: dlg) { cb(m, k) }
        }
    }

    /// A stored message that needs the person arrived (a final answer, a question, an approval card).
    var onAttention: ((DlgMessage, AgentAttention.Kind) -> Void)?

    /// How many loaded messages after `seen` need the person (the dock's red count, the Inbox's total).
    func attentionCount(after seen: Int) -> Int {
        AgentAttention.count(items.map(\.attention), in: dlg, after: seen)
    }

    /// Replaces the loaded window with `raw` (oldest -> newest). `keepLocal`: messages drawn here and not stored
    /// Yet stay after it, unless the stored copy is already in the page.
    private func window(_ raw: [DlgMessage], keepLocal: Bool, follow: Bool = true) {
        track(raw, notify: loaded)
        windowOldestSeq = DlgMerge.before(raw)
        windowNewestSeq = raw.map(\.seq).max() ?? 0
        windowNewestId = raw.last?.id
        let server = raw.compactMap { item($0) }
        var local = keepLocal ? items.filter { !$0.confirmed } : []
        let recent = server.suffix(12)
        local.removeAll { l in
            if l.isTask, let t = l.taskId { return server.contains { $0.isTask && $0.taskId == t } }
            let t = l.message.ts ?? 0
            return recent.contains { s in
                s.agent == l.agent && s.message.content == l.message.content && abs((s.message.ts ?? t) - t) < 600_000
            }
        }
        let merged = server + local
        if merged != items {
            let grew = merged.last?.id != items.last?.id
            items = merged
            if grew && follow { appended += 1 }
        }
    }

    /// The next older page above the first message loaded.
    func loadOlder() async {
        guard hasMoreBefore, !loadingOlder, let before = windowOldestSeq else { return }
        loadingOlder = true
        defer { loadingOlder = false }
        guard let r = try? await api.dialogPage(profile: profile, dlg: dlg, before: before) else { return }
        track(r.messages)
        if let o = DlgMerge.before(r.messages) { windowOldestSeq = min(o, windowOldestSeq ?? o) }
        let known = Set(items.map(\.id))
        let older = r.messages.compactMap { item($0) }.filter { !known.contains($0.id) }
        if !older.isEmpty { items = older + items }
        hasMoreBefore = r.hasMore && !r.messages.isEmpty
    }

    /// The next newer messages after the window (only after a jump left the newest part).
    func loadNewer() async {
        guard hasMoreAfter, !loadingNewer, let last = windowNewestId else { return }
        loadingNewer = true
        defer { loadingNewer = false }
        guard let r = try? await api.dialogAround(profile: profile, dlg: dlg, id: last, span: 30) else { return }
        track(r.messages)
        let known = Set(items.map(\.id))
        let newer = r.messages.filter { $0.seq > windowNewestSeq && !known.contains($0.id) }
        if newer.isEmpty {
            await reloadLatest()
            return
        }
        windowNewestSeq = newer.map(\.seq).max() ?? windowNewestSeq
        windowNewestId = newer.last?.id ?? windowNewestId
        let rows = newer.compactMap { item($0) }
        if !rows.isEmpty { items += rows; appended += 1 }
        hasMoreAfter = r.hasMoreAfter
    }

    /// "Jump to latest": the newest page replaces the window.
    func reloadLatest() async {
        guard let r = try? await api.dialogPage(profile: profile, dlg: dlg) else { return }
        window(r.messages, keepLocal: true, follow: false)
        hasMoreBefore = r.hasMore
        hasMoreAfter = false
        if let last = items.last { requestScroll(last.id, flash: false) }
    }

    /// Something newer is on the server (an agent wrote first, another device): the newest page joins the window.
    func refreshLatest() async {
        guard loaded, !busy, !loadingNewer else { return }
        guard let r = try? await api.dialogPage(profile: profile, dlg: dlg) else { return }
        guard !busy else { return }
        if hasMoreAfter { track(r.messages); return }
        let pageOldest = DlgMerge.before(r.messages) ?? 0
        // A gap between what is loaded and the newest page: the page becomes the window.
        if r.hasMore && pageOldest > windowNewestSeq + 1 && windowNewestSeq > 0 {
            window(r.messages, keepLocal: true)
            hasMoreBefore = true
            return
        }
        for m in r.messages where m.seq > windowNewestSeq { receive(m) }
    }

    /// Brings a message into view: scrolls to it when it is loaded, else loads the window around it first.
    func jump(to messageId: String) {
        if items.contains(where: { $0.id == messageId }) { requestScroll(messageId); return }
        Task { await self.loadAround(messageId) }
    }

    private func loadAround(_ id: String) async {
        await loadAndWait()
        if items.contains(where: { $0.id == id }) { requestScroll(id); return }
        guard let r = try? await api.dialogAround(profile: profile, dlg: dlg, id: id) else {
            errorText = "Could not open that message."
            return
        }
        // While a run streams the window stays the newest part (its answer is drawn at the end).
        guard !busy else { return }
        window(r.messages, keepLocal: !r.hasMoreAfter, follow: false)
        hasMoreBefore = r.hasMoreBefore
        hasMoreAfter = r.hasMoreAfter
        if items.contains(where: { $0.id == id }) { requestScroll(id) }
    }

    /// A task card's Open: the first message of the task in this (the owner's) dialogue.
    func jumpToTask(_ taskId: String) async {
        await loadAndWait()
        for _ in 0..<8 {
            if let it = items.first(where: { $0.origin?.taskId == taskId || ($0.taskId == taskId && !$0.isTask) }) {
                requestScroll(it.id)
                return
            }
            guard hasMoreBefore else { break }
            await loadOlder()
        }
    }

    /// A message the thread rule hides is brought into view as its turn's last shown message.
    private func shownId(_ id: String) -> String {
        guard hiddenInThread.contains(id), let r = items.first(where: { $0.id == id })?.run else { return id }
        return items.last(where: { $0.run == r && !hiddenInThread.contains($0.id) })?.id ?? id
    }

    private func requestScroll(_ raw: String, flash on: Bool = true) {
        let id = shownId(raw)
        scrollN += 1
        scrollRequest = ScrollRequest(id: id, n: scrollN, at: Date())
        guard on else { return }
        flash = id
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 1_600_000_000)
            if self?.flash == id { self?.flash = nil }
        }
    }

    // MARK: - the stream's dialogue lines

    private func receive(_ e: DlgStreamEvent) {
        switch e {
        case .message(let m):
            receive(m)
        case let .taskRun(d, t):
            // The task goes on in its owner's dialogue; this one is free again once its own lines end.
            tasks[t.id] = t
            if isTeam, t.owner != "lia" {
                NotificationCenter.default.post(name: .liaHandOff, object: nil, userInfo: ["agent": t.owner, "profile": profile])
            }
            onTaskRun?(d, t)
        case .task(let t), .taskUpdate(let t):
            // A task Dev takes is one of its steps ("What did Dev do?", the Canvas's Activity).
            if t.owner == "dev", tasks[t.id] == nil {
                let step = DevStep.task(id: t.id, title: t.title, at: Date().timeIntervalSince1970 * 1000)
                devActivity.add(step)
                devHistory?.step(devHistoryID, step.phrase)
            }
            tasks[t.id] = t
            // The card is a stored message too; until its `msg` comes, one is drawn from the task.
            // The owner's acknowledgement (its message carrying the task) stands for the card.
            if t.originDlg == nil || t.originDlg == dlg, t.owner != agentId,
               !items.contains(where: { $0.taskId == t.id }) {
                let m = ChatMessage(role: .assistant, content: t.title, ts: Date().timeIntervalSince1970 * 1000)
                items.append(TeamItem(id: "l-task-" + t.id, agent: t.owner, message: m, taskId: t.id, isTask: true))
                appended += 1
            }
        }
    }

    private func receive(_ m: DlgMessage) {
        track([m])
        if !hasMoreAfter, m.seq > windowNewestSeq { windowNewestSeq = m.seq; windowNewestId = m.id }
        // Dev's messages of the running turn also read in the live Activity, between its steps.
        if busy, m.role != .user, m.agent == "dev", let r = m.run {
            devRun = r
            if m.fin {
                // The final message: the words buffered for it leave the Activity; the chat shows it now.
                devActivity.dropDraft()
                devQuiet = false
            } else {
                devActivity.note(id: m.id, text: AgentPrefix.strip(m.text), run: r,
                                 at: (m.ts ?? Date()).timeIntervalSince1970 * 1000)
            }
        }
        guard let it = item(m) else { return }   // a machine reply: stored, never shown
        if let i = items.firstIndex(where: { $0.id == it.id }) { items[i] = it; return }
        if it.handed { append(it); return }   // a task's first row stands for nobody's local copy
        // A card drawn from the task gives way to the stored card or to the owner's acknowledgement.
        if let t = it.taskId, it.isTask || it.agent != agentId,
           let i = items.firstIndex(where: { !$0.confirmed && $0.isTask && $0.taskId == t }) {
            items[i] = it
            return
        }
        if it.agent == nil && !it.handed {
            // The person's message sent here: the stored copy takes the place of the one drawn when it was sent.
            let t = it.message.content.trimmingCharacters(in: .whitespacesAndNewlines)
            let mine = items.firstIndex { !$0.confirmed && $0.agent == nil && $0.message.content.trimmingCharacters(in: .whitespacesAndNewlines) == t }
                ?? items.firstIndex { !$0.confirmed && $0.agent == nil }
            if let i = mine {
                var s = it
                if s.origin == nil { s.origin = items[i].origin }
                items[i] = s
                return
            }
            append(it)
            return
        }
        // An agent's answer ends its live turn here: the stored copy is the one kept.
        if liveAgent == it.agent, live != nil { finishLive(stored: it); report(); return }
        if let i = items.lastIndex(where: { !$0.confirmed && !$0.isTask && $0.agent == it.agent }) {
            if errorItems.contains(items[i].id) { errorItems.remove(items[i].id) }
            items[i] = it
            return
        }
        append(it)
    }

    private func append(_ it: TeamItem) {
        items.append(it)
        appended += 1
    }

    private static func localId() -> String { "l-" + UUID().uuidString }

    /// The person's last own message (CHAT-07 \u{2191} puts it back in the field; ERR-01 Try Again sends it again).
    /// A handed task's words are not the person's message here.
    var lastUserText: String? { items.last(where: { $0.agent == nil && !$0.handed })?.message.content }

    /// The person's message. While a run is going it waits its turn in `queue` (CHAT-14).
    /// CHAT-15: `attachments` are files already uploaded (R2 keys); they go in the turn's payload and the model reads them.
    /// `origin`: the surface it was sent from outside this dialogue (the address bar, notes, the side panel).
    func send(_ text: String, attachments: [ChatAttachment] = [], origin: DlgOrigin.Surface? = nil) {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty || !attachments.isEmpty else { return }
        if busy {
            let key = t.isEmpty ? Self.filesOnly : t
            queue.append(key)
            if !attachments.isEmpty { queuedAttachments[key, default: []] += attachments }
            return
        }
        cancelRetry()
        autoRetries = 0
        taskYes = false
        let shown = t == Self.filesOnly ? "" : t
        guard !shown.isEmpty || !attachments.isEmpty else { return }
        // Reading an older window: the conversation goes back to its newest part first.
        if hasMoreAfter {
            items = []
            hasMoreAfter = false
            Task { [weak self] in await self?.reloadLatestKeepingLocal() }
        }
        // The bubble shows the person's words; a Crea Studio target's line goes to the server only.
        let mine = ChatMessage(role: .user, content: CreaTargetHead.strip(shown), attachments: attachments,
                               ts: Date().timeIntervalSince1970 * 1000)
        append(TeamItem(id: Self.localId(), agent: nil, message: mine, origin: origin.map { DlgOrigin(surface: $0) }))
        run(shown, to: nil, attachments: attachments, origin: origin)
    }

    private func reloadLatestKeepingLocal() async {
        guard let r = try? await api.dialogPage(profile: profile, dlg: dlg) else { return }
        window(r.messages, keepLocal: true)
        hasMoreBefore = r.hasMore
    }

    /// "Delete" on a message: gone from the server (and so from the agents' memory of the dialogue). Returns the
    /// Facts Lia saved from it (not deleted: the person is asked), or nil when the server refused.
    func delete(_ item: TeamItem) async -> [(id: String, text: String)]? {
        guard item.confirmed else {
            // Only drawn here (never stored): nothing to delete on the server.
            items.removeAll { $0.id == item.id }
            errorItems.remove(item.id)
            return []
        }
        do {
            let r = try await api.dialogDelete(profile: profile, dlg: dlg, ids: [item.id])
            let gone = Set(r.deleted.isEmpty ? [item.id] : r.deleted)
            items.removeAll { gone.contains($0.id) }
            return r.facts
        } catch {
            errorText = userMessage(for: error)
            return nil
        }
    }

    /// A queued message that is only files (its line in the queue).
    static let filesOnly = "(attached files)"

    /// The next queued message with the files uploaded for it.
    private func sendQueued(_ text: String) {
        let att = queuedAttachments.removeValue(forKey: text) ?? []
        send(text, attachments: att)
    }

    /// An answer the person does not type (approval, browser report): back to the agent that asked, not shown.
    func sendMachine(_ text: String, agent: String, attachments: [ChatAttachment] = []) {
        if busy { machineQueue.append((text, agent, attachments)); return }
        run(text, to: agent, attachments: attachments)
    }

    /// A task another dialogue gave this agent (the person's @Name there, or a teammate's hand-over) starts here,
    /// In this agent's own dialogue: its hand-over note, then its answer, stream in as in any turn. The server takes a
    /// Task once (409 for a second Mac). After this dialogue's own run, if one is going.
    /// An agent working now gets it next - a queued line the person sees - not mid-turn: a running model turn (Lia
    /// 2.0's response chain, Dev's DevRun loop, Met waiting on an approval) has no safe way to take a new message in.
    func startTask(_ t: AgentTask) {
        tasks[t.id] = t
        Task { [weak self] in
            guard let self else { return }
            await self.loadAndWait()
            if self.busy || self.openGate != nil {
                if !self.queuedTasks.contains(where: { $0.id == t.id }) { self.queuedTasks.append(t) }
                return
            }
            self.run(DlgTurn.taskRunText(t.id), to: self.agentId)
        }
    }

    /// A stored message of this dialogue that came on another dialogue's stream (an older server worked a task
    /// Inside the caller's stream): it joins this dialogue, never the caller's.
    func receiveForeign(_ m: DlgMessage) {
        guard loaded else { return }   // not open yet: its first page brings it
        receive(m)
    }

    func stop() {
        // Dev keeps working on the server after the stream is gone (DevRun); Stop must reach it there too.
        if busy, liveAgent == "dev" || pendingAgent == "dev" || devRun != nil || agentId == "dev" {
            let api = self.api, profile = self.profile
            Task { await api.devStop(profile: profile) }
        }
        cancelRetry()
        taskYes = false
        runTask?.cancel()
        if webAgent != nil { onStopWeb?() }
    }

    private func run(_ text: String, to agent: String?, attachments: [ChatAttachment] = [], origin: DlgOrigin.Surface? = nil) {
        lastRun = (text: text, agent: agent, attachments: attachments, origin: origin)
        busy = true
        errorText = nil
        // The answering agent is "writing" at once, before the server's first line.
        // An @Name of another agent: that agent's one-line acknowledgement comes first, this dialogue's agent is silent.
        pendingAgent = agent ?? DlgMention.firstAnswerer(text, dlg: dlg, names: WorkspaceModel.current?.agentNames ?? [:])
        devStatus = nil
        devRun = nil
        devQuiet = false; devSegEnds = 0
        report()
        runTask = Task { [weak self] in
            guard let self else { return }
            let words = text.isEmpty && !attachments.isEmpty ? "See the attached file\(attachments.count == 1 ? "" : "s")." : text
            var extra: JSONObject = ["tz": TimeZone.current.identifier]
            if let agent { extra["agent"] = agent }
            // The agents hidden / turned off in this dialogue's workspace (never Lia), on every turn and task_run
            extra["agents_off"] = WorkspaceModel.current?.agentsOff(profile: self.profile) ?? []
            if let tid = DlgTurn.taskRunId(text) {
                extra["task_run"] = tid   // a task started in this dialogue
                // Review 2026-10-19: a task the person did not approve never inherits an earlier "Yes to all".
                self.taskYes = false
            }
            // CHAT-15: the files the model reads (metadata only; the bytes stay in R2).
            if !attachments.isEmpty { extra["attachments"] = attachments.map(\.meta) }
            if self.taskYes && self.hasWriter { extra["task_yes"] = true }
            // Dev's Auto / Manual with every turn of Dev's dialogue (and an answer sent to Dev).
            if self.isDev || agent == "dev" {
                extra["dev_mode"] = self.devMode.rawValue
                // The person's e-mail names their live site (publish_site: jane-doe@... -> jane-doe.liaisone.com).
                let e = AppModel.current?.library.profile?.email ?? ""
                if let mail = e.isEmpty ? self.auth.activeEmail : e, !mail.isEmpty { extra["email"] = mail }
            }
            if let b = await self.browserContext?() { extra["browser"] = b }
            if LiaContext.forLia(agent: agent, dialogueAgent: self.agentId), let c = await self.liaContext?() { extra["context"] = c }
            let seen = ScreenShare.seen(extra["browser"])
            if seen != self.screenSeen { self.screenSeen = seen }
            if !text.hasPrefix(ScreenShare.tag) { self.screenLooked = false }
            var tasks: [(String, String, String, String, String?)] = []
            var looks: [(String, ScreenLook)] = []
            let stream = self.api.streamDialogue(profile: self.profile, dlg: self.dlg, text: words, origin: origin, extra: extra)
            do {
                for try await line in stream {
                    if Task.isCancelled { break }
                    // A line of another dialogue is never drawn here - its stored messages go to that dialogue, its live words are not shown here.
                    let lineDlg = DlgStreamEvent.dlg(of: line, own: self.dlg)
                    let foreign = lineDlg != nil && lineDlg != self.dlg
                    if let d = DlgStreamEvent.parse(line: line) {
                        if case .taskRun = d { self.receive(d); continue }
                        if foreign {
                            if case .message(let m) = d, let fd = lineDlg {
                                WorkspaceModel.current?.chat(for: fd, profile: self.profile)?.receiveForeign(m)
                            }
                            continue
                        }
                        self.receive(d); continue
                    }
                    if foreign { continue }
                    if let t = TeamLine.parse(line: line) {
                        self.teamLine(t)
                        continue
                    }
                    // Dev's status, steps and question; its act_start / act_done go on to the timeline too.
                    if let d = DevLine.parse(line: line), self.devLine(d, text: text) { continue }
                    if let lk = ScreenLook.parse(line: line) { looks.append((lk.agent ?? self.liveAgent ?? "lia", lk)); continue }
                    if let ev = ChatEvent.parse(line: line) {
                        self.live?.apply(ev)
                        // The objects the turn named stay known after it is stored (entity chips)
                        if case .ents(let m) = ev { DialogueEnts.shared.merge(m, key: self.key) }
                        // Dev quiet - what it writes now streams in the Activity, never in the chat.
                        if self.devQuiet, self.liveAgent == "dev", let l = self.live {
                            let t = AgentPrefix.strip(l.text).trimmingCharacters(in: .whitespacesAndNewlines)
                            if t != (self.devActivity.draft?.text ?? "") {
                                self.devActivity.stream(t, run: self.devRun, at: Date().timeIntervalSince1970 * 1000)
                            }
                        }
                        // The status line's waiting phrase comes up once the current one has stood its time.
                        self.live?.status.tick(now: Date().timeIntervalSince1970 * 1000)
                        // The Canvas: a preview arriving live opens (or reloads) it in the sheet showing this dialogue.
                        // An event, not state: history never posts it, and a sheet switched to another dialogue later
                        // Has nothing stale to replay.
                        if case .block(let b) = ev, let item = CanvasItem(block: b, profile: self.profile) {
                            if let u = CanvasItem.page(of: b) { self.latestDevPage = u; self.latestDevPageSeq = self.latestSeq + 1 }
                            NotificationCenter.default.post(name: .liaCanvasArrived, object: nil,
                                                            userInfo: ["key": self.key, "item": item])
                        }
                    }
                    // A change the server applied under the task's Yes: the person's Ads Manager tabs are told.
                    if line.contains("\"applied\""), let o = TeamLine.object(line), JSONRead.string(o, "type") == "applied" {
                        self.postApplied(serverEvent: o, agent: self.liveAgent ?? TeamLine.agent(line: line) ?? "met")
                    }
                    if let ae = AgentEvent.parse(line: line) {
                        let who = self.liveAgent ?? TeamLine.agent(line: line) ?? "lia"
                        if case let .browserTask(task, goal, tab, url) = ae {
                            // The task is its asker's (the line's own agent first);
                            // WorkspaceModel runs it in that agent's dialogue, not necessarily this one
                            tasks.append((TeamLine.agent(line: line) ?? who, task, goal, tab, url))
                        } else {
                            self.traced.insert(who)
                            self.onTrace?(who, ae)
                        }
                    }
                }
            } catch {
                if !Task.isCancelled {
                    // An agent that needs Meta in a workspace without an ad account (HTTP 409 needs_meta).
                    if let e = error as? ChatStreamError, case let .http(409, code) = e, code == "task_taken" {
                        // Another Mac (or an earlier try) already started this task: nothing to show.
                    } else if let e = error as? ChatStreamError, case let .http(409, code) = e, code == "needs_meta" {
                        let id = agent ?? self.dlg
                        let name = WorkspaceModel.current?.agent(id)?.name ?? id.capitalized
                        self.errorText = "Connect Meta to work with \(name)."
                        WorkspaceModel.current?.show("Connect Meta to work with \(name).", symbol: "lock.fill")
                    } else {
                        self.errorText = userMessage(for: error)
                    }
                }
            }
            let cancelled = Task.isCancelled
            // A Dev turn that ended without its final `msg`: the words buffered for it are the final bubble (kept in
            // The chat, so they leave the Activity); a finished turn shows its highest message again (DevThread).
            if self.devQuiet, self.liveAgent == "dev", !(self.live?.text.isEmpty ?? true) { self.devActivity.dropDraft() }
            self.finishLive()
            self.devQuiet = false; self.devSegEnds = 0
            self.endDevTurn(cancelled: cancelled)
            self.devRun = nil
            self.busy = false
            self.pendingAgent = nil; self.turnAgent = nil
            self.report()
            // A turn the person stopped starts no browser task it had asked for.
            if !cancelled { for t in tasks { self.onBrowserTask?(t.0, t.1, t.2, t.3, t.4) } }
            if !cancelled, let l = looks.first { self.onScreenLook?(l.0, l.1) }   // one picture per stop
            if !self.machineQueue.isEmpty {
                let next = self.machineQueue.removeFirst()
                self.run(next.text, to: next.agent, attachments: next.attachments)
            } else if !self.queuedTasks.isEmpty, self.openGate == nil {
                // A task given while this agent worked starts now, before the person's own queued messages
                let t = self.queuedTasks.removeFirst()
                self.run(DlgTurn.taskRunText(t.id), to: self.agentId)
            } else if !self.queue.isEmpty {
                self.sendQueued(self.queue.removeFirst())
            } else if !cancelled, let e = self.turnError {
                self.scheduleRetry(after: e)
            } else if self.turnError == nil {
                self.autoRetries = 0
            }
        }
    }

    private func teamLine(_ t: TeamLine) {
        switch t {
        case let .agentStart(a, _):
            let before = liveAgent
            finishLive()
            // DOCK-08: Lia hands this part to another agent: the dock draws a spark from her to it.
            if isTeam, a != "lia", a != before {
                NotificationCenter.default.post(name: .liaHandOff, object: nil, userInfo: ["agent": a, "profile": profile])
            }
            live = LiveTurn()
            liveAgent = a
            if a != turnAgent { devSegEnds = 0; devQuiet = false }
            turnAgent = a; pendingAgent = nil
            if a != "dev" { devStatus = nil }
            report()
        case let .error(_, message):
            if live != nil { live?.apply(.error(message)) } else { errorText = message }
        case .wait, .cap, .done:
            break
        }
    }

    // MARK: - Dev: steps as their own messages, its status, Manual's question, its activity

    /// Handles one of Dev's lines; true when nothing else reads it (act_start / act_done also feed the timeline).
    private func devLine(_ d: DevLine, text: String) -> Bool {
        let now = Date().timeIntervalSince1970 * 1000
        switch d {
        case .status(let t):
            devStatus = t
            return true
        case .segmentEnd:
            // The step's stored copy (`msg`) came just before: the next words start their own bubble below it.
            // Only the first message of the turn is a bubble; after it Dev is quiet in the chat (its
            // Words go to the Activity) until the final message.
            let quiet = devSegEnds > 0
            devSegEnds += 1
            switch DevSegment.onEnd(liveAgent: liveAgent, liveOpen: live != nil, turnAgent: turnAgent) {
            case .finishAndRestart(let a):
                if quiet {
                    // No stored copy came: the words stay a message of the Activity, never a bubble
                    devActivity.keepDraft(id: Self.localId())
                    for t in traced { onTrace?(t, .end) }
                    traced = []
                    live = nil
                } else {
                    finishLive()
                }
                live = LiveTurn(); liveAgent = a
            case .restart(let a):
                live = LiveTurn(); liveAgent = a
            case .ignore:
                break
            }
            devQuiet = true
            report()
            return true
        case .confirm:
            devStatus = nil
            return true
        case .actStart:
            if devActivity.isEmpty || devHistoryID == nil { beginDevTurn(text: text) }
            devActivity.on(d, at: now)
            return false
        case let .actDone(id, _):
            devActivity.on(d, at: now)
            if let step = devActivity.steps.last(where: { $0.id == id }) { devHistory?.step(devHistoryID, step.phrase) }
            return false
        }
    }

    /// Dev's own history store: the one "What did Dev do?" reads for Dev's browser in this workspace.
    private var devHistory: AgentHistoryStore? {
        AgentHistoryStore.shared(CompanyProfile.browserKey(account: auth.activeId, profile: profile) + "|agent-dev")
    }

    /// Dev's first step of a turn: a fresh activity, a task in its history, and the Canvas opens on Activity
    /// (in the conversation sheet showing this dialogue).
    private func beginDevTurn(text: String) {
        devActivity.clear(keepingRun: devRun)
        let title: String
        if text.hasPrefix(ModeReply.gateTag) { title = "Went on after your answer" }
        else if AgentOf.isMachine(ChatMessage(role: .user, content: text)) { title = "Went on with the task" }
        else { title = text.isEmpty ? "Coding" : text }
        devHistoryID = devHistory?.begin(agent: "dev", title: title, dialogue: profile + "|" + dlg)
        NotificationCenter.default.post(name: .liaCanvasActivity, object: nil, userInfo: ["key": key, "profile": profile])
    }

    /// The turn is over: nothing runs, the task in the history ends with how it went.
    private func endDevTurn(cancelled: Bool) {
        devStatus = nil
        guard devHistoryID != nil || !devActivity.isEmpty else { return }
        devActivity.end()
        if let id = devHistoryID {
            let last = items.last(where: { $0.agent == "dev" })
            let waiting = last.map { DevConfirm.first(in: $0.message.blocks) != nil } ?? false
            let outcome: AgentTaskOutcome = cancelled ? .stopped : errorText != nil ? .failed : waiting ? .waiting : .done
            let summary = cancelled ? "You stopped it" : errorText ?? AgentStepPhrase.clip(last?.message.content ?? "", 300)
            devHistory?.end(id, outcome, summary: summary)
        }
        devHistoryID = nil
    }

    /// The open question of Dev (Manual): only on the last message, with no answer yet and nothing running.
    func devConfirmOpen(_ item: TeamItem) -> Bool {
        guard !busy, !hasMoreAfter, item.agent == "dev", items.last?.id == item.id,
              let c = DevConfirm.first(in: item.message.blocks), c.status == "pending" else { return false }
        return devDecision(item.id) == nil
    }

    /// Dev's Continue (its turn stopped at a time / cost / step bound): offered only on the last message, while nothing
    /// Runs; a newer message hides it.
    func devContinueOpen(_ item: TeamItem) -> Bool {
        guard !busy, !hasMoreAfter, item.agent == "dev", items.last?.id == item.id else { return false }
        return DevContinue.first(in: item.message.blocks) != nil
    }

    /// Continue: its words go to Dev as the person's own message (the composer's path, POST /agents/turn).
    func continueDev(_ item: TeamItem) {
        guard devContinueOpen(item), let c = DevContinue.first(in: item.message.blocks) else { return }
        send(c.text)
    }

    /// The person's answer to the question on `id` (this session, else kept on this Mac).
    func devDecision(_ id: String) -> Bool? {
        if let a = devAnswers[id] { return a }
        return ChatDecisions.get(DevConfirm.decisionKey(id))?.approved
    }

    /// Allow / Deny on Dev's question: told to Dev as a machine reply; Dev goes on (never answered by itself).
    func answerDev(_ item: TeamItem, allow: Bool) {
        guard devConfirmOpen(item) else { return }
        devAnswers[item.id] = allow
        ChatDecisions.record(planId: DevConfirm.decisionKey(item.id), approved: allow)
        sendMachine(DevConfirm.reply(allow), agent: "dev")
    }

    // MARK: - errors and retries (ERR-01, ERR-03)

    /// The error the last turn ended on: the run's own, or the agent's (its last item).
    private var turnError: String? {
        if let e = errorText { return e }
        if let last = items.last, errorItems.contains(last.id) { return last.message.content }
        return nil
    }

    /// Sends the person's last message again (Try Again); the error card it replaces goes.
    func retry() {
        // Review 2026-10-19: when the failed turn was an automatically started task, Try Again repeats that task,
        // Not the person's last message in this dialogue.
        if let r = lastRun, DlgTurn.taskRunId(r.text) != nil { taskYes = false; retryLastRun(); return }
        guard !busy, let t = lastUserText else { return }
        cancelRetry()
        if let last = items.last, errorItems.contains(last.id) { items.removeLast(); errorItems.remove(last.id) }
        taskYes = false
        run(t, to: nil, attachments: items.last(where: { $0.agent == nil })?.message.attachments ?? [])
    }

    /// ERR-03: the automatic retry repeats the last run exactly (a gate reply to its agent, not the person's message).
    private func retryLastRun() {
        guard !busy, let r = lastRun else { return }
        cancelRetry()
        if let last = items.last, errorItems.contains(last.id) { items.removeLast(); errorItems.remove(last.id) }
        run(r.text, to: r.agent, attachments: r.attachments, origin: r.origin)
    }

    /// CHAT-14: a queued message taken back to edit or removed drops the files uploaded for it.
    func dropQueued(at i: Int) -> String? {
        guard queue.indices.contains(i) else { return nil }
        let q = queue.remove(at: i)
        if !queue.contains(q) { queuedAttachments[q] = nil }
        return q
    }

    /// A busy or limit error retries by itself after 30 s, with a countdown (at most 3 times in a row).
    private func scheduleRetry(after error: String) {
        guard ChatError.kind(of: error) == .busy, autoRetries < 3, lastRun != nil else { return }
        autoRetries += 1
        retryIn = 30
        retryTask = Task { [weak self] in
            for s in stride(from: 29, through: 0, by: -1) {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                guard !Task.isCancelled, let me = self else { return }
                me.retryIn = s
            }
            guard !Task.isCancelled, let me = self else { return }
            me.retryIn = nil
            me.retryLastRun()
        }
    }

    private func cancelRetry() {
        retryTask?.cancel()
        retryTask = nil
        retryIn = nil
    }

    /// Ends the live answer. `stored`: the server's copy of it (a `msg` line), kept in its place; else the answer
    /// As streamed is kept under a local id until the next page brings the stored one.
    private func finishLive(stored: TeamItem? = nil) {
        // The drawing ends with the turn (also a turn that never got its own agent_start).
        for a in traced { onTrace?(a, .end) }
        traced = []
        guard var l = live else {
            if let stored { append(stored) }
            return
        }
        if !l.finished { l.finish() }
        let m = l.message(id: UUID().uuidString)
        if let stored {
            append(stored)
            // Dev's intermediate message (hidden in the thread, it reads in the Activity) makes no sound.
            if !hiddenInThread.contains(stored.id) {
                if stored.message.gateJSON != nil { ChatSounds.play(.approval) } else { ChatSounds.play(.message) }
                if ChatConfetti.isSuccess(stored.message.content) { cheer(stored.agent) }
            }
        } else if !m.content.isEmpty || !m.blocks.isEmpty || m.gateJSON != nil || l.error != nil {
            var msg = m
            msg.content = AgentPrefix.strip(msg.content)
            if msg.ts == nil { msg.ts = Date().timeIntervalSince1970 * 1000 }
            let rowId = Self.localId()
            var isError = false
            if msg.content.isEmpty, let e = l.error { msg.content = e; errorItems.insert(rowId); isError = true }
            append(TeamItem(id: rowId, agent: liveAgent, message: msg))
            // SND-01: a soft pop for an agent's words, a double tone when it waits for a Yes (not for an error card).
            if msg.gateJSON != nil { ChatSounds.play(.approval) } else if !isError { ChatSounds.play(.message) }
            if !isError, ChatConfetti.isSuccess(msg.content) { cheer(liveAgent) }
        }
        live = nil
        liveAgent = nil
    }

    /// CHAT-27: a light burst in the agent's colour over the thread.
    private func cheer(_ agent: String?) {
        celebrateAgent = agent
        celebrate += 1
    }

    /// DOCK-10: what `agent` is doing in this conversation right now, in a few words (nil: not at work here).
    func activity(of agent: String) -> String? {
        if webAgent == agent, let g = webGate { return g.ask.human ? "Waiting for you on the page" : "Waiting for your OK" }
        if webAgent == agent { return webStatus.isEmpty ? "Working in the browser\u{2026}" : webStatus }
        if agent == "dev", liveAgent == "dev", let s = devStatus { return s }
        guard liveAgent == agent, let l = live else { return nil }
        if !l.status.text.isEmpty { return l.status.text }
        return l.text.isEmpty ? "Thinking\u{2026}" : "Writing\u{2026}"
    }

    /// DOCK-07 "Pause All Tasks": stops this conversation's run when `agent` is the one at work in it.
    func stop(agent: String) {
        guard liveAgent == agent || webAgent == agent || (agent == "lia" && busy) else { return }
        queue.removeAll()
        stop()
    }

    /// Working and waiting agents, for the dock.
    private func report() {
        var w = Set<String>(), q = Set<String>()
        if let a = liveAgent { w.insert(a) }
        if let a = webAgent { w.insert(a) }
        if !applying, let g = openGate, let a = g.item.agent { q.insert(a) }
        // The web agent waiting on the person: "needs your Yes" (a notification when the app is in the background)
        if webGate != nil, let a = webAgent { q.insert(a) }
        onActivity?(w, q)
    }

    // MARK: - approvals

    func answer(_ answer: GateAnswer) {
        guard let og = openGate, !applying, let i = items.firstIndex(where: { $0.id == og.item.id }) else { return }
        let g = og.gate, agent = og.item.agent ?? "met"
        // No ends the task's one Yes before anything is sent.
        if answer == .no { taskYes = false }
        items[i].message.markGateDone()
        // APPR-07: the card folds into "Approved by you \u{00b7} 10:42" / "Declined \u{00b7} 10:42" (kept on this Mac).
        ChatDecisions.record(planId: g.planId, approved: answer != .no)
        applying = true
        report()
        Task { [weak self] in
            guard let self else { return }
            var outcome: ModeReply.ApplyOutcome? = nil
            if answer != .no { outcome = await self.apply(g) }
            self.onTraceAnswer?(agent, answer == .no ? nil : .applied(entityType: g.entityType.isEmpty ? g.entity : g.entityType,
                entityId: g.entityId.isEmpty ? nil : g.entityId, createdId: outcome?.createdId, account: nil, error: outcome?.error))
            self.applying = false
            if answer != .no, outcome?.error == nil { ChatSounds.play(.done); self.cheer(agent) }
            if answer != .no, let o = outcome, o.error == nil, !o.pending { self.postApplied(gate: g, agent: agent) }
            if answer == .all || (answer == .yes && self.mode == .auto && !g.final) { self.taskYes = true }
            let told: GateAnswer = (answer == .yes && self.mode == .auto && !g.final) ? .all : answer
            self.sendMachine(ModeReply.gate(g, answer: told, auto: false, outcome: outcome), agent: agent)
        }
    }

    private func apply(_ g: Gate) async -> ModeReply.ApplyOutcome {
        let api = LiaAPI(auth: auth)
        var out = ModeReply.ApplyOutcome()
        var res: JSONObject
        jobProgress = nil   // a failed copy's card goes once the next approval runs
        do {
            if g.isUndo {
                res = try await api.undoPlan(journalId: g.journalId)
                if JSONRead.bool(res, "ok"), !JSONRead.bool(res, "applied_directly"), let pid = JSONRead.string(res, "plan_id") {
                    res = try await api.applyWritePlan(planId: pid, mode: "double", sessionId: sessionId, accountName: accountName)
                }
            } else {
                res = try await api.applyWritePlan(planId: g.planId, mode: "single", sessionId: sessionId, accountName: accountName)
            }
        } catch {
            res = ["ok": false, "error": userMessage(for: error)]
        }
        // ERR-04: a copy runs as a job on Meta's side: follow it, with "3 of 5" while it runs and how far it got if it fails.
        if JSONRead.bool(res, "ok"), let job = JSONRead.string(res, "job"), !job.isEmpty {
            jobProgress = JobProgress(done: 0, total: 0, error: nil)
            var last = -1, still = 0
            for _ in 0..<400 {
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                if Task.isCancelled { out.pending = true; out.job = job; break }
                let st = await api.copyStatus(job: job)
                let d = JSONRead.int(st, "done") ?? 0, t = JSONRead.int(st, "total") ?? 0
                jobProgress = JobProgress(done: d, total: t, error: nil)
                if JSONRead.bool(st, "ok"), JSONRead.string(st, "status") == "completed" {
                    res["job"] = nil; res["created_id"] = JSONRead.string(st, "created_id"); break
                }
                if JSONRead.string(st, "status") == "failed" {
                    let why = JSONRead.string(st, "error") ?? "The copy stopped partway"
                    let part = t > 0 ? "\(d) of \(t) copied. " : ""
                    res = ["ok": false, "error": part + why]
                    jobProgress = JobProgress(done: d, total: t, error: why)
                    break
                }
                if JSONRead.string(st, "error_class") == "job_gone" { res = ["ok": false, "error": "The copy job expired"]; break }
                if d > last { last = d; still = 0 } else { still += 1; if still >= 20 { out.pending = true; out.job = job; break } }
            }
            // Still running after the polling ran out: the change is pending on Meta's side, not done
            if JSONRead.bool(res, "ok"), res["job"] != nil, !out.pending { out.pending = true; out.job = job }
            if jobProgress?.error == nil { jobProgress = nil }
        }
        if !JSONRead.bool(res, "ok") {
            out.error = JSONRead.string(res, "user_msg") ?? JSONRead.string(res, "error") ?? JSONRead.string(res, "message") ?? "refused"
        } else {
            let id = JSONRead.string(res, "created_id") ?? JSONRead.string(res["result"] as? JSONObject, "created_id")
            out.createdId = (id?.isEmpty == false) ? id : nil
            if out.job == nil { out.job = JSONRead.string(res, "job") }
        }
        return out
    }

    // MARK: - applied writes, for the person's own Ads Manager tabs (ChangeBanner)

    private func postApplied(gate g: Gate, agent: String) {
        let c = AppliedChange(agent: agent, profile: profile, accountId: nil,
                              entityId: g.entityId.isEmpty ? nil : g.entityId,
                              entityType: g.entityType.isEmpty ? (g.entity.isEmpty ? nil : g.entity) : g.entityType,
                              title: g.title, diff: g.diff, at: Date())
        NotificationCenter.default.post(name: .liaWriteApplied, object: nil, userInfo: ["change": c])
    }

    /// Proaimain `applied`: {ok, entity, entity_type, entity_id, title, diff, created_id, error}.
    private func postApplied(serverEvent o: JSONObject, agent: String) {
        guard (o["ok"] as? Bool) ?? true else { return }
        let diff = JSONRead.objects(o, "diff").map {
            GateDiffRow(label: JSONRead.string($0, "label") ?? "", old: JSONRead.string($0, "old") ?? "", new: JSONRead.string($0, "new") ?? "")
        }
        let id = JSONRead.string(o, "entity_id") ?? JSONRead.string(o, "created_id")
        let type = JSONRead.string(o, "entity_type") ?? JSONRead.string(o, "entity")
        let c = AppliedChange(agent: agent, profile: profile, accountId: nil,
                              entityId: (id?.isEmpty ?? true) ? nil : id, entityType: (type?.isEmpty ?? true) ? nil : type,
                              title: JSONRead.string(o, "title") ?? "", diff: diff, at: Date())
        NotificationCenter.default.post(name: .liaWriteApplied, object: nil, userInfo: ["change": c])
    }

    /// ERR-04: a running copy job ("3 of 5"), or how far a failed one got.
    struct JobProgress: Equatable { var done: Int; var total: Int; var error: String? }
    @Published private(set) var jobProgress: JobProgress?
}

/// Agents sometimes open their words with their own name in brackets ("[Met] Done."). The bubble already says who
/// Speaks, so a leading "[Name] " (one capitalised word, not a Markdown link) is dropped from what is shown.
enum AgentPrefix {
    private static let pattern = #"^\s*(\*\*)?\[[A-Z][A-Za-z]{1,15}\](\*\*)?(?!\()\s*:?[ \t]*"#

    static func strip(_ s: String) -> String {
        var t = s
        // At most twice ("[Lia] [Met] ..."), never into the text itself.
        for _ in 0..<2 {
            guard let r = t.range(of: pattern, options: .regularExpression) else { break }
            t.removeSubrange(r)
        }
        return t
    }
}

extension Notification.Name {
    /// DOCK-08: posted when Lia hands a part of a team task to another agent. userInfo: "agent", "profile".
    static let liaHandOff = Notification.Name("lia.ws.handoff")
    /// A stored message that needs the person (AgentAttention) arrived; userInfo "agent", "profile".
    /// The dock's figure jumps, a hidden dock peeks.
    static let liaAgentAttention = Notification.Name("lia.ws.attention")
    /// The Canvas: an item (Dev's preview) came in a dialogue's live stream. userInfo: key (the dialogue), item.
    static let liaCanvasArrived = Notification.Name("lia.ws.canvas")
    /// Dev took its first step of a turn in a dialogue. userInfo: key (the dialogue), profile.
    static let liaCanvasActivity = Notification.Name("lia.ws.canvas.activity")
}
