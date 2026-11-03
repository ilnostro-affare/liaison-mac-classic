import Foundation
import Combine

/// A message typed while a turn runs (ai.js _queue).
struct QueuedMessage: Identifiable, Equatable {
    let id = UUID()
    let text: String
}

struct PendingAttachment: Identifiable, Equatable {
    /// `creative`: it went to the media library and travels as an [attached_creative] marker.
    enum State: Equatable { case uploading, ready(ChatAttachment), creative(MediaItem), failed(String) }
    let id = UUID()
    let name: String
    let isImage: Bool
    var preview: Data?
    /// "Pasted content": long text pasted into the box becomes a file (ai.js, 1200+ characters).
    var pasted = false
    /// A document's own bytes, kept so its tile opens a preview before (and after) the upload (ai.js).
    var data: Data? = nil
    var state: State
}

/// One chat on screen: its document, the live turn, and Lia 1.4's questions.
/// Ported from liappstore ChatViewModel and ai.js sendMessage / gateAnswer / askAnswer / queueFlush.
@MainActor
final class ChatViewModel: ObservableObject {
    let chatId: String
    @Published var doc: ChatDoc
    @Published private(set) var messages: [ChatMessage] = []
    @Published private(set) var live: LiveTurn?
    @Published private(set) var liveStartedAt: Date?
    @Published private(set) var loading = false
    @Published private(set) var pending: [PendingAttachment] = []
    @Published var creatives: [MediaItem] = []
    /// The [+] menu's Media library sheet.
    @Published var showLibrary = false
    /// "Type / in the message box": the box takes focus.
    @Published var focusRequest = 0
    /// A quick action being filled above the input (ai.js buildBar).
    @Published var quick: QuickBar?
    @Published private(set) var entities: [SlashEntity]?
    @Published private(set) var entitiesNoScope = false
    private(set) var manyAccounts = false
    private var entitiesAt: Date?

    func startQuick(_ c: SlashCommand) {
        quick = QuickBar(c)
        Task { await loadEntities() }
    }

    /// /call/entity_options for the chat's accounts, kept a minute (ai.js entOptions).
    func loadEntities() async {
        let ids = doc.accounts.map { $0.id.filter(\.isNumber) }.filter { !$0.isEmpty }
        guard !ids.isEmpty else { entitiesNoScope = true; entities = []; return }
        entitiesNoScope = false
        if let at = entitiesAt, Date().timeIntervalSince(at) < 60, entities != nil { return }
        guard let d = try? await LiaAPI(auth: auth, account: owner).mcpCall("entity_options", ["accounts": ids.joined(separator: ",")], noCache: true),
              let r = SlashEntity.parse(d) else { if entities == nil { entities = [] }; return }
        entities = r.entities
        manyAccounts = r.accounts > 1
        entitiesAt = Date()
    }

    /// Library picks join the message, six at most, each once (ai.js liaLibToComposer).
    func addCreatives(_ items: [MediaItem]) {
        for it in items where !creatives.contains(where: { $0.id == it.id }) && creatives.count < 6 {
            CreativePreviews.shared.remember(it)
            creatives.append(it)
        }
    }
    @Published private(set) var scrollTick = 0
    /// Streaming and the end of a turn: the thread follows only when the reader is at its end (ChatScreen).
    @Published private(set) var followTick = 0
    @Published var errorText: String?
    /// Messages typed while Lia works; they go out one by one when the turn ends (desktop queue, ai.js).
    /// Each has its own id, so the x removes that message even after the one before it went out.
    @Published private(set) var queue: [QueuedMessage] = []
    /// The line above the input while an answer is being applied ("Working · yes to all").
    @Published private(set) var applying: String? { didSet { busyChanged() } }
    /// Limits and this chat's share, for the strip above the box and the ring under it.
    @Published private(set) var usage: UsageInfo?
    @Published var limitHidden = false

    func refreshUsage() async { usage = await LiaAPI(auth: auth, account: owner).usage(chat: chatId) }

    private let auth: AuthStore
    /// Lia 2.0's live trace, for the chat's browser (AppModel hands it to AgentDirector).
    var onAgent: ((AgentEvent) -> Void)?
    /// The person answered a change: Yes (with what Meta returned) or nil for No.
    var onAgentAnswer: ((AgentEvent?) -> Void)?
    /// The chat's browser as Lia sees it with a message (tabs and page snapshots), from AppModel; nil: none.
    var browserContext: (() async -> [String: Any]?)?
    /// A browser task of this chat is running (AppModel); the input's Stop ends it.
    @Published var webRunning = false
    /// What the browser is doing right now (the agent's pill text), for the working line in the thread.
    @Published var webStatus = ""
    var onStopWeb: (() -> Void)?
    /// Incident: the browser task waits on the person (WebAskCenter, by this chat's id): the chat shows it
    /// above the input (WebAskRow) instead of only in the page's pill.
    @Published private(set) var webGate: WebAskCenter.Pending?
    private var webGateSub: AnyCancellable?
    func answerWebGate(allow: Bool) { WebAskCenter.shared.answer(chat: chatId, allow: allow) }
    /// The account that opened this chat; its calls never run under another account's session.
    private let owner: String?
    var authStore: AuthStore { auth }
    private var streamTask: Task<Void, Never>? { didSet { busyChanged() } }
    private var wasBusy = false
    /// The sidebar's busy dot listens here, so the whole window does not repaint on every streamed word.
    var onBusyChanged: ((Bool) -> Void)?
    private func busyChanged() {
        if isBusy != wasBusy { wasBusy = isBusy; onBusyChanged?(isBusy) }
    }
    private var stopRequested = false
    private var lastScrollLength = 0
    private var lastPhaseCount = 0
    private var runStop = false
    var onTurnFinished: (() -> Void)?
    var onTitled: ((String) -> Void)?
    /// The chat's ad account name for the journal, or the member's main account (ai.js accNameForApply).
    var fallbackAccountName: () -> String? = { nil }

    static let maxUploadBytes = 10 * 1024 * 1024
    /// ai.js _autoYesChats: "Yes to all" lives for this run in this app session, by chat id.
    private static var autoYesChats = Set<String>()

    init(auth: AuthStore, chatId: String) {
        self.auth = auth
        self.owner = auth.activeId
        self.chatId = chatId
        self.doc = ChatDoc(id: chatId)
        doc.accounts = Self.loadLocalAccounts(chatId)
        let cid = chatId
        webGateSub = WebAskCenter.shared.$pending
            .map { $0[cid] }
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] p in MainActor.assumeIsolated { self?.webGate = p } }
    }

    var isStreaming: Bool { streamTask != nil }
    /// Busy for the Stop button: a turn streams, or an auto "yes to all" run sits between two steps.
    var isBusy: Bool { streamTask != nil || applying != nil || planBusy }
    var isEmpty: Bool { messages.isEmpty && live == nil }
    var isUploading: Bool { pending.contains { $0.state == .uploading } }
    var accounts: [ChatAccount] { doc.accounts }

    // MARK: mode (the model picker)

    var mode: RunMode { LiaModel.mode(model: doc.model, rmode: doc.rmode) }

    func setMode(_ m: RunMode) {
        doc.model = LiaModel.id
        doc.rmode = m.rawValue
        Task { await save(force: true) }
    }

    // MARK: questions above the input

    /// The change Lia stopped on, unanswered (ai.js gateOpen).
    var openGate: (index: Int, gate: Gate)? {
        guard let i = messages.indices.last, messages[i].role == .assistant, let g = messages[i].gate, !g.done else { return nil }
        return (i, g)
    }

    /// Manual's open question (ai.js askOpen).
    var openAsk: (index: Int, ask: AskQuestion)? {
        guard let i = messages.indices.last, messages[i].role == .assistant, let a = messages[i].ask, !a.done else { return nil }
        return (i, a)
    }

    /// The newest plan of a Plan chat, until the person writes something else (ai.js planOpenMsg).
    var openPlan: Int? {
        guard mode == .plan else { return nil }
        for i in messages.indices.reversed() {
            let m = messages[i]
            if m.role == .assistant, let p = PlanState(json: m.plan) { return p.done ? nil : i }
            if m.role == .user, !m.content.hasPrefix(ModeReply.gateTag), !m.content.hasPrefix(ModeReply.planTag) { return nil }
        }
        return nil
    }

    func planState(at i: Int) -> PlanState? { messages.indices.contains(i) ? PlanState(json: messages[i].plan) : nil }

    @Published private(set) var planBusy = false { didSet { busyChanged() } }
    @Published var planError: String?
    /// The plan shown in the plan sheet (a message index), nil when it is closed.
    @Published var planShown: Int?

    private func storePlan(_ p: PlanState, at i: Int) {
        guard messages.indices.contains(i), let stored = messages[i].plan else { return }
        messages[i].planJSON = LiveTurn.encode(p.merged(into: stored))
    }

    /// After an await the thread may have moved: the plan message is found by its id, and only when that id is gone
    /// (the server copy renumbers ids) by its old place, if a plan still sits there.
    private func storePlan(_ p: PlanState, messageId: String, at i: Int) {
        if let k = messages.firstIndex(where: { $0.id == messageId }) { storePlan(p, at: k); return }
        storePlan(p, at: i)
    }

    func togglePlanItem(_ id: String, at i: Int) {
        guard i == openPlan, !planBusy, var p = planState(at: i), let k = p.items.firstIndex(where: { $0.id == id }) else { return }
        p.items[k].off.toggle()
        storePlan(p, at: i)
        Task { await save() }
    }

    func pickVariant(_ id: String, at i: Int) {
        guard i == openPlan, !planBusy, var p = planState(at: i) else { return }
        p.pick = id
        storePlan(p, at: i)
        Task { await save() }
    }

    /// ai.js planAnswer, with the new tree re-planned through the gateway instead of browser.js screens.
    func answerPlan(_ answer: PlanAnswer) {
        guard let i = openPlan, !planBusy, !isStreaming, var p = planState(at: i) else { return }
        if answer == .no {
            p.done = true; p.answer = "no"
            storePlan(p, at: i)
            Task { await save() }
            if !p.creates.isEmpty || !p.edits.isEmpty { sendRaw(ModeReply.planNo()) }
            return
        }
        planBusy = true
        planError = nil
        Task { await publish(p, answer: answer, at: i) }
    }

    private func publish(_ p0: PlanState, answer: PlanAnswer, at i: Int) async {
        var p = p0
        guard messages.indices.contains(i) else { planBusy = false; return }
        let msgId = messages[i].id
        let api = LiaAPI(auth: auth, account: owner)
        // No ad account: nothing is applied (an empty account_name never reaches apply_write_plan).
        guard let account = doc.accounts.first?.name ?? fallbackAccountName(), !account.isEmpty else {
            planError = "Choose the ad account first."; planBusy = false
            return
        }
        var out: [PlanResult] = []
        func call(_ tool: String, _ params: [String: Any]) async throws -> JSONObject {
            let o = JSONRead.object(try await api.mcpCall(tool, params, noCache: true, acceptErrors: true)) ?? [:]
            guard JSONRead.bool(o, "ok") else {
                throw UploadError(message: JSONRead.string(o, "user_message") ?? JSONRead.string(o, "user_msg")
                                  ?? JSONRead.string(o, "error") ?? JSONRead.string(o, "message") ?? (tool + " failed"))
            }
            return o
        }
        /// Plan one part, apply it at once, return the new object's id (browser.js crPublish `one`).
        func make(_ tool: String, _ params: [String: Any]) async throws -> (id: String, planId: String) {
            let pl = try await call(tool, params)
            guard let pid = JSONRead.string(pl, "plan_id") else { throw UploadError(message: tool + " returned no plan") }
            let r = try await call("apply_write_plan", ["plan_id": pid, "mode": "single", "session_id": chatId, "account_name": account])
            let id = JSONRead.string(r, "created_id") ?? JSONRead.string(r["result"] as? JSONObject, "created_id") ?? ""
            guard !id.isEmpty else { throw UploadError(message: "Meta did not return the new object's id") }
            return (id, pid)
        }

        if !p.creates.isEmpty { p.publishing = Date().timeIntervalSince1970 * 1000; storePlan(p, messageId: msgId, at: i); await save() }
        var stopError: String?
        var campaignId: String?, adSetId: String?
        let words = ["campaign": "Campaign", "adset": "Ad set", "ad": "Ad"]
        for kind in ["campaign", "adset", "ad"] {
            guard stopError == nil, let it = p.create(kind) else { continue }
            let a = it.args
            let tool: String, params: [String: Any]
            switch kind {
            case "campaign": tool = "plan_create_campaign"; params = PlanLogic.campaignParams(a)
            case "adset": tool = "plan_create_ad_set_panel"; params = PlanLogic.adSetParams(a, campaignId: campaignId)
            default: tool = "plan_create_ad_panel"; params = PlanLogic.adParams(a, adSetId: adSetId)
            }
            do {
                let made = try await make(tool, params)
                if kind == "campaign" { campaignId = made.id } else if kind == "adset" { adSetId = made.id }
                out.append(PlanResult(kind: kind, k: words[kind]!, title: it.title.isEmpty ? (JSONRead.string(a, "name") ?? "") : it.title,
                                      ok: true, createdId: made.id, entity: kind == "adset" ? "ad set" : kind, planId: made.planId))
            } catch {
                stopError = userMessage(for: error)
            }
        }
        if !p.creates.isEmpty && out.isEmpty, let e = stopError {
            // Nothing went out: the plan stays open with the reason.
            p.publishing = nil; storePlan(p, messageId: msgId, at: i); await save()
            planError = e; planBusy = false
            return
        }
        if let e = stopError { out.append(PlanResult(kind: "change", k: "Stopped", title: "The rest of the new tree", error: e)) }
        if answer == .publishOn && stopError == nil {
            // The parent first: delivery needs every level on; a tree that stopped partway is not turned on.
            for k in out.indices where out[k].createdId != nil {
                do {
                    let pl = try await call("plan_activate_entity", ["entity_id": out[k].createdId!, "entity_type": out[k].kind == "adset" ? "ad_set" : out[k].kind])
                    _ = try await call("apply_write_plan", ["plan_id": JSONRead.string(pl, "plan_id") ?? "", "mode": "single", "session_id": chatId, "account_name": account])
                    out[k].on = true
                } catch {
                    let e = String(userMessage(for: error).prefix(200))
                    out[k].activateError = e
                    out[k].what = "Created, paused - turning it on failed: " + e
                }
            }
        }
        for x in p.edits where !x.off {
            var o = PlanResult(kind: "change", k: x.kindWord, title: x.title, what: x.diffLine, entity: x.entity.isEmpty ? "change" : x.entity,
                               planId: x.planId, entityId: x.entityId)
            do {
                var res: JSONObject
                if let pid = x.planId, pid.hasPrefix("undo:") {
                    res = try await call("undo_write", ["journal_id": String(pid.dropFirst(5))])
                    if !JSONRead.bool(res, "applied_directly"), let np = JSONRead.string(res, "plan_id") {
                        res = try await call("apply_write_plan", ["plan_id": np, "mode": "double", "session_id": chatId, "account_name": account])
                    }
                } else {
                    res = try await call("apply_write_plan", ["plan_id": x.planId ?? "", "mode": "single", "session_id": chatId, "account_name": account])
                }
                o.ok = true
                let id = JSONRead.string(res, "created_id") ?? JSONRead.string(res["result"] as? JSONObject, "created_id")
                o.createdId = (id?.isEmpty == false) ? id : nil
            } catch {
                o.error = String(userMessage(for: error).prefix(300))
            }
            out.append(o)
        }
        for x in p.edits where x.off {
            out.append(PlanResult(kind: "change", k: x.kindWord, title: x.title, off: true, entity: x.entity))
        }
        p.done = true
        p.answer = answer.rawValue
        p.publishing = nil
        p.results = Array(out.prefix(20))
        storePlan(p, messageId: msgId, at: i)
        planBusy = false
        await save()
        sendRaw(PlanLogic.reply(answer, out))
    }

    var steps: [RunStep] {
        RunSteps.from(messages: messages.map { ($0.role, $0.content, $0.gate) },
                      liveStep: isStreaming ? live?.actStep : nil, gateOpen: openGate != nil)
    }

    var autoYes: Bool { Self.autoYesChats.contains(chatId) }

    func answerGate(_ answer: GateAnswer) {
        guard let og = openGate, !isStreaming, applying == nil, !answeringGate else { return }
        answeringGate = true
        let id = messages[og.index].id
        Task { await applyGate(messageId: id, gate: og.gate, answer: answer, auto: false) }
    }

    /// A gate answer between the tap and the reply to Lia: the server copy must not overwrite the thread meanwhile.
    private var answeringGate = false

    func answerAsk(index: Int?, typed: String? = nil) {
        guard let oa = openAsk else { return }
        let i = oa.index, a = oa.ask
        let ans: String
        if let typed { ans = typed } else if let index, index < a.options.count { ans = a.options[index] } else { return }
        messages[i].markAskDone(answer: String(ans.prefix(typed != nil ? 4000 : 200)))
        Task { await save() }
        sendRaw(ModeReply.ask(a, answer: ans, index: index, typed: typed != nil))
    }

    /// ai.js gateAnswer: marked answered and saved first, then applied here, then told to Lia.
    private func applyGate(messageId: String, gate g: Gate, answer: GateAnswer, auto: Bool) async {
        defer { answeringGate = false }
        answeringGate = true
        guard let i = messages.firstIndex(where: { $0.id == messageId }), messages[i].gate?.done == false else { return }
        if auto { applying = "Working \u{00b7} yes to all"; runStop = false }
        messages[i].markGateDone()
        await save()
        // Auto: the first Yes answers the rest of this task (until the person writes again); turning on still asks.
        if answer == .all || (answer == .yes && mode == .auto && !g.final) { Self.autoYesChats.insert(chatId) }
        var outcome: ModeReply.ApplyOutcome? = nil
        if answer != .no {
            outcome = await apply(g)
            onAgentAnswer?(.applied(entityType: g.entityType.isEmpty ? g.entity : g.entityType,
                                    entityId: g.entityId.isEmpty ? nil : g.entityId, createdId: outcome?.createdId,
                                    account: nil, error: outcome?.error))
        } else {
            onAgentAnswer?(nil)
        }
        let stopped = auto && runStop
        applying = nil
        runStop = false
        if stopped { return }
        // Auto's Yes is a Yes to the task: Lia hears it as "all" and goes on to the next part without stopping to ask.
        let told: GateAnswer = (answer == .yes && mode == .auto && !g.final) ? .all : answer
        sendRaw(ModeReply.gate(g, answer: told, auto: auto, outcome: outcome))
    }

    private func apply(_ g: Gate) async -> ModeReply.ApplyOutcome {
        let api = LiaAPI(auth: auth, account: owner)
        var out = ModeReply.ApplyOutcome()
        // No ad account: refuse rather than apply under an empty name.
        guard let account = doc.accounts.first?.name ?? fallbackAccountName(), !account.isEmpty else {
            out.error = "Choose the ad account first."
            errorText = out.error
            return out
        }
        var res: JSONObject
        do {
            if g.isUndo {
                res = try await api.undoPlan(journalId: g.journalId)
                if JSONRead.bool(res, "ok"), !JSONRead.bool(res, "applied_directly"), let pid = JSONRead.string(res, "plan_id") {
                    res = try await api.applyWritePlan(planId: pid, mode: "double", sessionId: chatId, accountName: account)
                }
            } else {
                res = try await api.applyWritePlan(planId: g.planId, mode: "single", sessionId: chatId, accountName: account)
            }
        } catch {
            res = ["ok": false, "error": userMessage(for: error)]
        }
        // A copy is a job: poll every 3 s until it finishes, fails, or stops moving for a minute.
        if JSONRead.bool(res, "ok"), let job = JSONRead.string(res, "job") {
            out.job = job
            var last = -1, still = 0
            for _ in 0..<400 {
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                let st = await api.copyStatus(job: job)
                if JSONRead.bool(st, "ok"), JSONRead.string(st, "status") == "completed" {
                    res["job"] = nil; res["created_id"] = JSONRead.string(st, "created_id"); break
                }
                if JSONRead.string(st, "status") == "failed" {
                    res = ["ok": false, "error": JSONRead.string(st, "error") ?? "The copy stopped partway"]; break
                }
                if JSONRead.string(st, "error_class") == "job_gone" { res = ["ok": false, "error": "The copy job expired"]; break }
                let d = JSONRead.int(st, "done") ?? 0
                if d > last { last = d; still = 0 } else { still += 1; if still >= 20 { out.pending = true; break } }
            }
        }
        if !JSONRead.bool(res, "ok") {
            out.error = JSONRead.string(res, "user_msg") ?? JSONRead.string(res, "error") ?? JSONRead.string(res, "message") ?? "refused"
        } else {
            let id = JSONRead.string(res, "created_id") ?? JSONRead.string(res["result"] as? JSONObject, "created_id")
            out.createdId = (id?.isEmpty == false) ? id : nil
        }
        return out
    }

    /// After a turn: with "yes to all" on, Auto answers for the person, except turning something on.
    private func autoAnswerIfAsked() {
        guard autoYes, let og = openGate, !og.gate.final, !answeringGate else { return }
        answeringGate = true
        let id = messages[og.index].id
        Task { await applyGate(messageId: id, gate: og.gate, answer: .yes, auto: true) }
    }

    // MARK: load

    func load() async {
        if messages.isEmpty, let cached = ChatDocCache.load(id: chatId) {
            let local = doc.accounts
            doc = cached
            if doc.accounts.isEmpty { doc.accounts = local }
            messages = cached.messages
            scrollTick += 1
        }
        loading = messages.isEmpty
        defer { loading = false }
        do {
            let d = try await LiaAPI(auth: auth, account: owner).chatDoc(id: chatId)
            // A save of ours is still on its way: the local copy is newer than this one.
            guard pendingSaves == 0 else { errorText = nil; return }
            let local = doc.accounts
            // The server's copy may not have our title or mode yet (a new chat named a second ago): never empty them
            // (chat c8iphi6cm lost its name this way).
            let title = doc.title, model = doc.model, rmode = doc.rmode
            doc = d
            if doc.title.isEmpty { doc.title = title }
            if doc.model == nil { doc.model = model }
            if doc.rmode == nil { doc.rmode = rmode }
            if doc.accounts.isEmpty { doc.accounts = local } else { Self.storeLocalAccounts(chatId, doc.accounts) }
            // Not while a turn, a plan publish or an answer is in flight: they write into the thread on screen.
            // The same thread as the cache showed: nothing to redraw and no second jump to the end.
            if live == nil, !isBusy, !answeringGate {
                let merged = ChatMerge.preferLocalAnswers(server: d.messages, local: messages)
                if messages != merged { messages = merged; scrollTick += 1 }
            }
            errorText = nil
        } catch {
            if messages.isEmpty { errorText = userMessage(for: error) }
        }
    }

    // MARK: attachments (ai.js composerUpload,: no lanes)

    func attach(name: String, mime: String, data: Data, pasted: Bool = false) {
        switch AttachRoute.route(name: name, mime: mime, bytes: data.count) {
        case .refuse(let why): errorText = why
        case .read: attachRead(name: name, mime: mime, data: data, pasted: pasted)
        case .creativeImage: attachCreative(name: name, mime: mime, data: data, video: false)
        case .creativeVideo: attachCreative(name: name, mime: mime, data: data, video: true)
        }
    }

    /// Lia reads it (/intelligence/attach): documents, and pictures Meta would not take as an ad.
    private func attachRead(name: String, mime: String, data: Data, pasted: Bool) {
        guard data.count <= Self.maxUploadBytes else {
            errorText = "Up to 10 MB per file"
            return
        }
        let isImage = mime.hasPrefix("image/")
        var item = PendingAttachment(name: name, isImage: isImage, preview: isImage ? data : nil, state: .uploading)
        item.pasted = pasted
        if !isImage { item.data = data }
        let preview = isImage ? data : nil
        pending.append(item)
        let api = LiaAPI(auth: auth, account: owner)
        Task {
            let result: PendingAttachment.State
            do {
                var att = try await api.uploadAttachment(filename: name, mime: mime, data: data)
                att.preview = preview
                result = .ready(att)
            } catch {
                result = .failed(userMessage(for: error))
            }
            if let i = pending.firstIndex(where: { $0.id == item.id }) { pending[i].state = result }
        }
    }

    /// Into the media library: Lia sees it and an ad can use it. A video also gets its poster and the 2x2 storyboard
    /// (the four frames are what Lia sees of a video), both hidden in the library.
    private func attachCreative(name: String, mime: String, data: Data, video: Bool) {
        let item = PendingAttachment(name: name, isImage: true, preview: video ? nil : data, state: .uploading)
        pending.append(item)
        let api = LiaAPI(auth: auth, account: owner)
        Task {
            // The poster is drawn off the main thread; the tile shows it once it is ready.
            let poster: Data? = video ? await VideoFrames.poster(data) : nil
            if let poster, let i = pending.firstIndex(where: { $0.id == item.id }) { pending[i].preview = poster }
            let preview: Data? = video ? poster : data
            var result: PendingAttachment.State = .failed("Upload failed")
            var key: String?
            do {
                let r = video ? try await api.creativeUploadStream(mime: mime, data: data)
                              : try await api.creativeUpload(filename: name, mime: mime, data: data)
                if JSONRead.bool(r, "ok"), let k = JSONRead.string(r, "r2_key") {
                    key = k
                    result = .creative(MediaItem(id: k, source: .upload, name: name, preview: JSONRead.string(r, "preview"), seconds: nil))
                    if let p = preview { CreativePreviews.shared.store(p, for: k) }
                } else {
                    result = .failed(JSONRead.string(r, "error") ?? "Upload failed")
                }
            } catch {
                result = .failed(userMessage(for: error))
            }
            if let i = pending.firstIndex(where: { $0.id == item.id }) { pending[i].state = result }
            if case .failed(let why) = result { errorText = why; pending.removeAll { $0.id == item.id } }
            guard video, let key else { return }
            if let poster { _ = try? await api.creativeUpload(filename: "poster.jpg", mime: "image/jpeg", data: poster, extra: ["poster_for": key]) }
            if let board = await VideoFrames.board(data) {
                _ = try? await api.creativeUpload(filename: "board.jpg", mime: "image/jpeg", data: board, extra: ["board_for": key])
            }
        }
    }

    func removeAttachment(_ id: UUID) { pending.removeAll { $0.id == id } }

    // MARK: ad accounts

    func toggleAccount(_ a: AdAccount) {
        if doc.accounts.contains(where: { $0.id == a.id }) {
            doc.accounts.removeAll { $0.id == a.id }
        } else if doc.accounts.count < 6 {
            doc.accounts.append(ChatAccount(id: a.id, name: a.name))
        }
        Self.storeLocalAccounts(chatId, doc.accounts)
        if !messages.isEmpty { Task { await save() } }
    }

    func setSingleAccount(_ a: AdAccount) {
        doc.accounts = [ChatAccount(id: a.id, name: a.name)]
        Self.storeLocalAccounts(chatId, doc.accounts)
    }

    func seedDefaultAccount(from list: [AdAccount]) async {
        guard doc.accounts.isEmpty else { return }
        // The main ad account; with none set and a single account connected, that one.
        let main = await LiaAPI(auth: auth, account: owner).defaultAccountId()
        guard let def = main ?? (list.count == 1 ? list[0].id : nil), doc.accounts.isEmpty else { return }
        let name = list.first(where: { $0.id == def })?.name ?? def
        doc.accounts = [ChatAccount(id: def, name: name)]
        Self.storeLocalAccounts(chatId, doc.accounts)
    }

    private static func localKey(_ id: String) -> String { "lia_haccs_\(id)" }
    private static func loadLocalAccounts(_ id: String) -> [ChatAccount] {
        guard let rows = UserDefaults.standard.array(forKey: localKey(id)) as? [[String: String]] else { return [] }
        return rows.compactMap { r in r["id"].map { ChatAccount(id: $0, name: r["name"] ?? $0) } }
    }
    private static func storeLocalAccounts(_ id: String, _ list: [ChatAccount]) {
        if list.isEmpty { UserDefaults.standard.removeObject(forKey: localKey(id)); return }
        UserDefaults.standard.set(list.map { ["id": $0.id, "name": $0.name] }, forKey: localKey(id))
    }

    // MARK: feedback

    func sendFeedbackDetails(messageId: String, verdict: String, topic: String, note: String) {
        guard let i = messages.firstIndex(where: { $0.id == messageId }) else { return }
        let text = messages[i].content
        let api = LiaAPI(auth: auth, account: owner)
        Task { await api.feedback(chatId: chatId, index: i, verdict: verdict, text: text, topic: topic.isEmpty ? nil : topic, note: note) }
    }

    func setFeedback(messageId: String, verdict: String) {
        guard let i = messages.firstIndex(where: { $0.id == messageId }) else { return }
        let current = messages[i].feedback
        let sent = current == verdict ? "\(verdict)-undo" : verdict
        messages[i].feedback = current == verdict ? nil : verdict
        let text = messages[i].content
        let api = LiaAPI(auth: auth, account: owner)
        Task {
            await api.feedback(chatId: chatId, index: i, verdict: sent, text: text)
            await save()
        }
    }

    // MARK: sending

    /// What the person typed. While a turn runs it is queued; while Manual asks, plain text answers.
    func send(_ raw: String, projectAccount: String?) {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        // An open quick action goes first; what was typed follows it.
        if let q = quick {
            guard q.complete else { errorText = "Pick the highlighted chips first"; return }
            text = ModeReply.quickTag + " " + q.text + (text.isEmpty ? "" : "\n" + text)
            quick = nil
        }
        dispatch(text, projectAccount: projectAccount)
    }

    private func dispatch(_ text: String, projectAccount: String?) {
        if isBusy {
            if !text.isEmpty { queue.append(QueuedMessage(text: text)) }
            return
        }
        if openAsk != nil, !text.isEmpty, !text.hasPrefix("["), pending.isEmpty, creatives.isEmpty {   // a typed answer, nothing attached
            answerAsk(index: nil, typed: text)
            return
        }
        // The person's own words start a new run: "yes to all" ends, an open question is left unanswered.
        Self.autoYesChats.remove(chatId)
        if let og = openGate { messages[og.index].markGateDone() }
        if let oa = openAsk { messages[oa.index].markAskDone(answer: oa.ask.answer ?? "") }
        sendRaw(text, projectAccount: projectAccount, withAttachments: true)
    }

    // MARK: quick answer (ai.js quizBarSync / quizBarMount / quizBarAnswered)

    /// The quiz the bar above the input offers: while a turn streams, the one its block event carried;
    /// otherwise the newest assistant message's.
    var quizBar: QuizSpot? {
        if let live { return QuizFind.live(live.blocks) }
        return QuizFind.active(messages)
    }

    /// A tap on an option or a pick from "Choose myself". Refused (false) while a turn runs: the bar stays and the
    /// tap flashes. On success sendRaw has already marked the quiz answered.
    func answerQuiz(_ text: String, projectAccount: String?) -> Bool {
        guard !isBusy, !isUploading, !text.isEmpty else { return false }
        dispatch(text, projectAccount: projectAccount)
        return streamTask != nil
    }

    /// The x: a dismissed quiz stays dismissed. Mid-stream the turn carries it into its saved message.
    func dismissQuiz() {
        if live != nil {
            guard let k = live?.blocks.lastIndex(where: { $0.kind == "quiz" }) else { return }
            live?.blocks[k] = live!.blocks[k].patched { $0["answered"] = 1 }
            return
        }
        if markQuizAnswered() { Task { await save() } }
    }

    /// Any send answers the open quiz - a tap, typed words, a pick from the tree.
    @discardableResult
    private func markQuizAnswered() -> Bool {
        guard let i = QuizFind.toClose(messages) else { return false }
        messages[i].markQuizAnswered()
        return true
    }

    func removeQueued(_ id: UUID) { queue.removeAll { $0.id == id } }

    /// ai.js queueFlush: the first queued message goes out, if nothing holds the chat. It leaves the queue only when it
    /// is actually sent; Send on an empty box asks again after an error (the site: "the queue waits for Send").
    @discardableResult
    func flushQueue(projectAccount: String?) -> Bool {
        guard let next = queue.first, !isBusy, !isUploading, openGate == nil, openAsk == nil else { return false }
        if let q = quick, !q.complete { return false }
        queue.removeFirst()
        send(next.text, projectAccount: projectAccount ?? lastProjectAccount)
        return true
    }

    /// Resends the person's last message after a stop (ai.js Retry).
    func retry(projectAccount: String?) {
        guard !isBusy, let last = messages.last(where: { $0.role == .user && !ModeReply.isReply($0.content) }) else { return }
        sendRaw(last.content, projectAccount: projectAccount, withAttachments: false)
    }

    private var lastProjectAccount: String?
    private var statusTask: Task<Void, Never>?

    private func sendRaw(_ text: String, projectAccount: String? = nil, withAttachments: Bool = false) {
        let ready = withAttachments ? pending.compactMap { p -> ChatAttachment? in
            if case .ready(let a) = p.state { return a }
            return nil
        } : []
        let uploaded = withAttachments ? pending.compactMap { p -> MediaItem? in
            if case .creative(let m) = p.state { return m }
            return nil
        } : []
        let picked = withAttachments ? creatives + uploaded : []
        guard !text.isEmpty || !ready.isEmpty || !picked.isEmpty, streamTask == nil, !isUploading else { return }
        markQuizAnswered()   // saved with the turn (finishTurn)
        let markers = picked.map(\.marker).joined(separator: "\n")
        if withAttachments { creatives = []; pending.removeAll() }
        errorText = nil
        stopRequested = false
        if let projectAccount { lastProjectAccount = projectAccount }
        let firstText = messages.isEmpty && !text.isEmpty
        let body = [text, markers].filter { !$0.isEmpty }.joined(separator: "\n\n")
        messages.append(ChatMessage(role: .user, content: UserText.outgoing(body, hasAttachments: !ready.isEmpty),
                                    attachments: ready, ts: Date().timeIntervalSince1970 * 1000))
        live = LiveTurn()
        liveStartedAt = Date()
        scrollTick += 1
        lastScrollLength = 0
        lastPhaseCount = 0
        if firstText, doc.title.isEmpty { nameChat(from: text) }

        // ai.js runGeneration body. The whole thread travels; the server trims to its window.
        var payload: [String: Any] = [
            "chat_id": chatId,
            "mode": "lia12",
            "model": LiaModel.id,
            "run_mode": mode.rawValue,
            "tz": TimeZone.current.identifier,
            "messages": messages.map { $0.requestJSON() },
            "accounts": doc.accounts.map { ["id": $0.id, "name": $0.name] },
        ]
        if let mid = auth.memberId { payload["member_id"] = mid }
        // The server names an untitled chat from this, never from a [gate_reply] it is answering
        if !doc.title.isEmpty { payload["title"] = doc.title }
        if let acc = lastProjectAccount, !acc.isEmpty { payload["account"] = acc }
        if !WebSearchSetting.isOn { payload["web_search"] = false }
        // The task is approved (Auto's one Yes, Manual's Yes to all): the server applies each part and goes on
        if autoYes { payload["task_yes"] = true }

        let api = LiaAPI(auth: auth, account: owner)
        // The live line moves with time as well as with events: a waiting line comes up, a long call rotates.
        statusTask?.cancel()
        statusTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 300_000_000)
                guard let self, var t = self.live, !t.finished else { return }
                if t.status.tick(now: Date().timeIntervalSince1970 * 1000) { self.live = t }
            }
        }
        let browserContext = self.browserContext
        let basePayload = payload
        streamTask = Task { [weak self] in
            var body = basePayload
            // The browser as it is at the moment of sending (read here, off the send path; ~100 ms a tab)
            if let ctx = await browserContext?() { body["browser"] = ctx }
            do {
                for try await event in api.streamChat(body) {
                    guard let self else { return }
                    if case .agent(let a) = event { self.onAgent?(a); continue }
                    self.live?.apply(event)
                    self.bumpScrollIfNeeded()
                }
            } catch {
                // Cancelled (the account was switched or signed out mid-turn): ends quietly, like Stop, no error text.
                if error is CancellationError { self?.stopRequested = true }
                if let self, !(error is CancellationError), !self.stopRequested {
                    self.live?.apply(.error(userMessage(for: error)))
                }
            }
            await self?.finishTurn()
        }
    }

    /// A browser task ended - its report goes to Lia as a machine reply once the chat is free (the turn that
    /// started it may still be closing).
    func sendBrowserResult(_ message: String) {
        Task { @MainActor [weak self] in
            for _ in 0..<1200 {   // up to 10 minutes: a long turn or an upload may hold the chat
                guard let self else { return }
                if self.streamTask == nil && !self.isUploading { self.sendRaw(message); return }
                try? await Task.sleep(nanoseconds: 500_000_000)
            }
        }
    }

    /// The chat's name from its first message, made on this Mac (ChatTitle).: the desktop's chats are
    /// endless dialogues, so no model is asked for a title (/intelligence/title stays the web's only).
    private func nameChat(from text: String) {
        let stopgap = ChatTitle.from(text)
        let t = stopgap.isEmpty ? String(text.prefix(60)) : stopgap
        guard !t.isEmpty else { return }
        doc.title = t
        onTitled?(t)
    }

    private func bumpScrollIfNeeded() {
        guard let t = live else { return }
        if t.text.count - lastScrollLength > 60 || t.timeline.phases.count != lastPhaseCount {
            lastScrollLength = t.text.count
            lastPhaseCount = t.timeline.phases.count
            followTick += 1
        }
    }

    func stop() {
        if webRunning { onStopWeb?() }
        if applying != nil { runStop = true; Self.autoYesChats.remove(chatId) }
        stopRequested = true
        streamTask?.cancel()
    }

    private func finishTurn() async {
        onAgent?(.end)
        let stopped = stopRequested
        // Only this turn's own failure holds the queue: an older errorText (an upload refused, a chip not picked) does not.
        var failed = false
        if var t = live {
            if !t.finished {
                if stopped { t.finish() } else { t.apply(.error("The connection closed before Lia finished.")) }
            }
            failed = !stopped && t.error != nil
            if !t.text.isEmpty || !t.blocks.isEmpty || !t.timeline.isEmpty || t.gateJSON != nil || t.askJSON != nil || t.planJSON != nil {
                var m = t.message(id: "a\(messages.count)-\(chatId)")
                m.stopped = stopped
                m.ts = Date().timeIntervalSince1970 * 1000
                if let e = t.error, !stopped { m.content += (m.content.isEmpty ? "" : "\n\n") + "Something went wrong: \(e). Try again." }
                messages.append(m)
            } else if let e = t.error, !stopped {
                errorText = e
            }
        }
        live = nil
        liveStartedAt = nil
        streamTask = nil
        followTick += 1
        let gate = openGate != nil
        // ai.js queueFlush: 260 ms after the turn, the next queued message goes - after a stop too, not after an error,
        // never over a question. It does not wait for the save below, which can take seconds; the bubble left the
        // queue only once that message was actually sent.
        if !gate, !failed, !queue.isEmpty {
            Task { [weak self] in
                try? await Task.sleep(nanoseconds: 260_000_000)
                guard let self else { return }
                self.flushQueue(projectAccount: self.lastProjectAccount)
            }
        }
        await save()
        onTurnFinished?()
        Task { await refreshUsage() }
        if gate { autoAnswerIfAsked(); return }
        // After a Plan turn the plan opens by itself, as it does over Ads Manager on the site (planAfterTurn).
        if let i = openPlan { planShown = i }
    }

    /// chat-saves still on their way (load keeps the local thread meanwhile).
    private var pendingSaves = 0

    /// chat-save after every turn, like the web. A fresh chat with nothing in it is not saved (ai.js saveChat).
    func save(force: Bool = false) async {
        guard !messages.isEmpty || (force && !doc.title.isEmpty) else { return }
        pendingSaves += 1
        defer { pendingSaves -= 1 }
        do {
            try await LiaAPI(auth: auth, account: owner).chatSave(doc.saveBody(messages: messages))
        } catch {
            // Not shown: the runner stores the answer itself.
        }
    }
}

enum WebSearchSetting {
    private static let key = "lia_web_search"
    static var isOn: Bool {
        get { UserDefaults.standard.object(forKey: key) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: key) }
    }
}
