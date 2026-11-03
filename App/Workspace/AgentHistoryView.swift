import SwiftUI

// The agent's tasks stay after they end (a history of cards, Today / Yesterday / dates), the steps
// read as a person says them, and the conversation keeps the browser of the agent that actually worked.

// MARK: - the store

/// One agent's tasks in one workspace, on this Mac: ~/Library/Application Support/Liaison/AgentHistory/<key>.json,
/// 200 tasks at most. Kept in memory for the app's life; the disk write is debounced and off the main thread.
@MainActor
final class AgentHistoryStore: ObservableObject {
    @Published private(set) var log = AgentHistoryLog()
    let key: String
    /// The browser the agent works in: its log's chatId ("dlg:profile:dlg") names the dialogue a task belongs to.
    private weak var browser: BrowserModel?
    private var saveJob: Task<Void, Never>?

    private static var stores: [String: AgentHistoryStore] = [:]
    private static let io = DispatchQueue(label: "lia.agent-history", qos: .utility)

    /// "workspace browser key|agent-<id>" for an agent's own browser; nil for the person's browser.
    static func key(for b: BrowserModel) -> String? {
        guard let c = b.chatID, c.hasPrefix("agent-") else { return nil }
        return (b.account ?? "_") + "|" + c
    }

    static func shared(_ key: String) -> AgentHistoryStore {
        if let s = stores[key] { return s }
        let s = AgentHistoryStore(key: key)
        stores[key] = s
        return s
    }

    static func shared(for b: BrowserModel) -> AgentHistoryStore? {
        guard let k = key(for: b) else { return nil }
        let s = shared(k)
        s.browser = b
        return s
    }

    private init(key: String) {
        self.key = key
        if let d = try? Data(contentsOf: file), var l = AgentHistoryLog.decode(d) {
            l.closeStale(at: Date())
            log = l
        }
    }

    static var folder: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("Liaison/AgentHistory", isDirectory: true)
    }
    private var file: URL { Self.folder.appendingPathComponent(AgentHistoryLog.fileName(key)) }

    var running: AgentTaskRecord? { log.tasks.last { $0.outcome == .running } }

    // MARK: writing

    /// `dialogue`: "profile|dlg" of the task; nil takes it from the browser's log (set before every run).
    @discardableResult
    func begin(agent: String, title: String, dialogue: String? = nil) -> String {
        // one task at a time per browser: a run left open ends here
        if var r = running { r.end(.stopped, summary: "Replaced by a new task", at: Date()); log.upsert(r) }
        let id = UUID().uuidString
        var t = AgentTaskRecord(id: id, agent: agent, title: title.isEmpty ? "Task" : title, started: Date())
        t.dialogue = dialogue ?? AgentTaskLink.dialogueKey(session: browser?.agent.log.chatId)
        log.upsert(t)
        save()
        return id
    }

    func step(_ id: String?, _ p: AgentStepPhrase.Phrase?) {
        guard let id, let p, var r = log.tasks.last(where: { $0.id == id }), r.outcome == .running || r.outcome == .waiting else { return }
        let before = r.steps
        r.add(p, at: Date())
        guard r.steps != before else { return }
        log.upsert(r)
        save()
    }

    func end(_ id: String?, _ outcome: AgentTaskOutcome, summary: String = "") {
        guard let id, var r = log.tasks.last(where: { $0.id == id }) else { return }
        r.end(outcome, summary: summary, at: Date())
        log.upsert(r)
        save()
    }

    /// The report message found for a task (Go to), kept so the next Go to needs no lookup.
    func setResult(_ id: String, message: String) {
        guard var r = log.tasks.last(where: { $0.id == id }), r.resultId != message else { return }
        r.resultId = message
        log.upsert(r)
        save()
    }

    private func save() {
        saveJob?.cancel()
        saveJob = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            guard let self, !Task.isCancelled, let data = self.log.encoded() else { return }
            let dir = Self.folder, file = self.file
            Self.io.async {
                try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                try? data.write(to: file, options: .atomic)
            }
        }
    }
}

// MARK: - whose browser the conversation shows

/// Per conversation ("profile|dlg"): the agents that drove a browser in it, oldest first, and which of them is at work
/// now. "Working" ends 3 s after a task ends, so the border does not blink between two tasks of one job.
@MainActor
final class AgentBrowserRecent: ObservableObject {
    static let shared = AgentBrowserRecent()
    @Published private(set) var used: [String: [String]] = [:]
    @Published private(set) var busy: Set<String> = []
    private var cooling: [String: Task<Void, Never>] = [:]

    func agents(_ chat: String) -> [String] { used[chat] ?? [] }
    func isBusy(_ chat: String, _ agent: String) -> Bool { busy.contains(chat + "|" + agent) }

    func began(_ agent: String, chat: String) {
        var list = used[chat] ?? []
        if list.last != agent {
            list.removeAll { $0 == agent }
            list.append(agent)
            used[chat] = list
        }
        let k = chat + "|" + agent
        cooling[k]?.cancel(); cooling[k] = nil
        if !busy.contains(k) { busy.insert(k) }
    }

    func ended(_ agent: String, chat: String) {
        let k = chat + "|" + agent
        cooling[k]?.cancel()
        cooling[k] = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            guard let self, !Task.isCancelled else { return }
            self.busy.remove(k)
            self.cooling[k] = nil
        }
    }

    /// A conversation's state goes (Start over, a workspace deleted).
    func forget(_ match: (String) -> Bool) {
        for k in used.keys where match(k) { used[k] = nil }
        for k in busy where match(k) { busy.remove(k) }
    }
}

/// The agents whose browsers the conversation can show, as small chips (only when there are two or more).
struct AgentBrowserChips: View {
    let agents: [AgentInfo]
    let shown: String
    let busy: @MainActor (String) -> Bool
    let onPick: (String) -> Void

    var body: some View {
        if agents.count > 1 {
            HStack(spacing: 4) {
                ForEach(agents) { a in
                    Button { onPick(a.id) } label: {
                        HStack(spacing: 5) {
                            AgentAvatar(agent: a, size: 14, status: busy(a.id) ? .working : .idle)
                            Text(a.name).font(LiaFont.ui(11.5, a.id == shown ? .semibold : .regular))
                                .foregroundStyle(a.id == shown ? WS.ink : WS.text2).lineLimit(1)
                        }
                        .padding(.horizontal, 8).frame(height: 24)
                        .background(a.id == shown ? WS.surface : Color.clear, in: Capsule())
                        .overlay(Capsule().stroke(a.id == shown ? Color(hex: a.colorHex).opacity(0.5) : Color.clear))
                    }
                    .buttonStyle(.liaPlain)
                    .liaPointer()
                    .accessibilityLabel(Text("\(a.name)\u{2019}s browser"))
                    .accessibilityAddTraits(a.id == shown ? .isSelected : [])
                }
            }
        }
    }
}

// MARK: - the history list

/// The agent's tasks, newest first, by day; the running one open on top, the others collapsed to title, time
/// and outcome, opened with a click.
struct AgentHistoryList: View {
    @ObservedObject var store: AgentHistoryStore
    /// A card's Go to (nil: no button).
    var onGoTo: ((AgentTaskRecord) -> Void)? = nil
    @State private var open: Set<String> = []

    var body: some View {
        let groups = AgentHistoryDays.groups(store.log.tasks, now: Date())
        LazyVStack(alignment: .leading, spacing: 6) {
            ForEach(groups, id: \.title) { g in
                Text(g.title).font(LiaFont.ui(11.5, .semibold)).foregroundStyle(WS.text3)
                    .padding(.top, 10).padding(.horizontal, 4)
                    .accessibilityAddTraits(.isHeader)
                ForEach(g.tasks) { t in
                    AgentTaskCard(task: t, expanded: t.outcome == .running || open.contains(t.id),
                                  onGoTo: onGoTo.map { f in { f(t) } }) {
                        if open.contains(t.id) { open.remove(t.id) } else { open.insert(t.id) }
                    }
                }
            }
        }
        .padding(.horizontal, 14).padding(.bottom, 12)
    }
}

private struct AgentTaskCard: View {
    let task: AgentTaskRecord
    let expanded: Bool
    var onGoTo: (() -> Void)? = nil
    let toggle: () -> Void

    private var tint: Color {
        switch task.outcome {
        case .done: return AppConfig.accent
        case .failed: return AppConfig.bad
        case .running, .waiting: return AppConfig.accent
        case .stopped, .declined: return WS.text3
        }
    }

    private var icon: String {
        switch task.outcome {
        case .done: return "checkmark.circle.fill"
        case .failed: return "exclamationmark.circle.fill"
        case .stopped, .declined: return "stop.circle.fill"
        case .waiting: return "hand.raised.circle.fill"
        case .running: return "circle.dotted"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                header
                if let onGoTo, task.canGoTo {
                    // The task's result in the dialogue (the agent's message that reported it).
                    Button(action: onGoTo) {
                        Label("Go to", systemImage: "arrow.turn.down.right").font(LiaFont.ui(11.5, .semibold))
                    }
                    .buttonStyle(WSButtonStyle(small: true))
                    .liaPointer()
                    .accessibilityHint(Text("Opens the dialogue at the message that reported this task"))
                    .padding(.trailing, 10)
                }
            }
            if expanded { steps }
        }
        .background(WS.soft.opacity(0.6), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private var header: some View {
            Button(action: toggle) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Image(systemName: icon).font(.system(size: 12)).foregroundStyle(tint)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(task.title).font(LiaFont.ui(13, .semibold)).foregroundStyle(WS.ink).lineLimit(expanded ? 3 : 1)
                        Text(meta).font(LiaFont.ui(11.5)).foregroundStyle(WS.text3).lineLimit(1)
                    }
                    Spacer(minLength: 0)
                    Image(systemName: expanded ? "chevron.up" : "chevron.down").font(.system(size: 9, weight: .semibold)).foregroundStyle(WS.text3)
                }
                .padding(.horizontal, 12).padding(.vertical, 9)
                .contentShape(Rectangle())
            }
            .buttonStyle(.liaPlain)
            .liaPointer()
            .accessibilityLabel(Text("\(task.title). \(meta)"))
            .accessibilityHint(Text(expanded ? "Hides the steps" : "Shows the steps"))
    }

    private var meta: String {
        var parts = [task.started.formatted(date: .omitted, time: .shortened), task.outcome.label]
        if let d = task.duration { parts.append(d) }
        return parts.joined(separator: " \u{00b7} ")
    }

    private var steps: some View {
        VStack(alignment: .leading, spacing: 5) {
            if task.steps.isEmpty {
                Text(task.outcome == .running ? "Starting\u{2026}" : "No steps").font(LiaFont.ui(12)).foregroundStyle(WS.text3)
            }
            ForEach(Array(task.steps.enumerated()), id: \.offset) { _, s in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    // Dev's coding steps carry their icon (a file edited, a command run, a push ...).
                    if let sym = DevStep.symbol(historyKind: s.kind) {
                        Image(systemName: sym).font(.system(size: 10, weight: .medium)).foregroundStyle(WS.text3)
                            .frame(width: 14).accessibilityHidden(true)
                    } else {
                        Circle().fill(WS.text3.opacity(0.6)).frame(width: 4, height: 4).alignmentGuide(.firstTextBaseline) { $0[.bottom] + 1 }
                    }
                    Text(s.text).font(LiaFont.ui(12.5)).foregroundStyle(WS.text2).fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                }
            }
            if !task.summary.isEmpty {
                Text(task.summary).font(LiaFont.ui(12)).foregroundStyle(WS.ink).textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true).padding(.top, 3)
            }
        }
        .padding(.leading, 32).padding(.trailing, 12).padding(.bottom, 10)
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Go to

/// A task card's Go to. The dialogue opens; the report is the kept id, else the first agent message
/// after the task's end among those loaded, else the server's (/agents/dlg/at from the end, then that page).
@MainActor
enum AgentTaskGoTo {
    static func go(_ t: AgentTaskRecord, store: AgentHistoryStore?, ws: WorkspaceModel) async {
        guard let key = t.dialogue, let pd = AgentTaskLink.split(key), let ended = t.ended else { return }
        let p = pd.profile, d = pd.dlg
        ws.openDialogue(key: key)
        guard let chat = ws.chat(for: d, profile: p) else { return }
        if let id = t.resultId { chat.jump(to: id); return }
        let loaded = chat.items.filter { !$0.isTask && $0.confirmed }.map { it in
            AgentTaskLink.Candidate(id: it.id, seq: it.seq, ts: it.message.ts.map { Date(timeIntervalSince1970: $0 / 1000) }, agent: it.agent)
        }
        var found = AgentTaskLink.result(loaded, ended: ended, agent: t.agent)
        if found == nil {
            let api = LiaAPI(auth: ws.auth)
            if let seq = try? await api.dialogAt(profile: p, dlg: d, ts: ended.addingTimeInterval(-3)),
               let page = try? await api.dialogPage(profile: p, dlg: d, before: seq + 8, limit: 8) {
                let c = page.messages.filter { $0.seq >= seq && !$0.isTaskCard }.map { m in
                    AgentTaskLink.Candidate(id: m.id, seq: m.seq, ts: m.ts ?? ended,
                                            agent: m.role == .user ? nil : (m.agent ?? d))
                }
                found = AgentTaskLink.result(c, ended: ended, agent: t.agent)
            }
        }
        guard let found else { return }   // not reported yet: the dialogue is open at its newest
        store?.setResult(t.id, message: found)
        chat.jump(to: found)
    }
}
