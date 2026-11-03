import SwiftUI

// Which blocks the new tab shows. the person's saved prompts ("skills"). quick task
// defaults by role.

// MARK: - layout

/// The new tab's blocks; each can be hidden (UserDefaults, on by default) and moved (Customise; the order is saved in
/// `lia_home_block_order`). The brief stays under the headline; the order is that of the blocks under the field.
enum HomeBlock: String, CaseIterable, Identifiable {
    case brief, feed, quick, conversations, tabs
    var id: String { rawValue }
    var title: String {
        switch self {
        case .brief: return "Brief"
        case .feed: return "Feed"
        case .quick: return "Quick tasks"
        case .conversations: return "Conversations"
        case .tabs: return "Tabs"
        }
    }
    var symbol: String {
        switch self {
        case .brief: return "chart.line.uptrend.xyaxis"
        case .feed: return "text.bubble"
        case .quick: return "bolt"
        case .conversations: return "bubble.left.and.bubble.right"
        case .tabs: return "square.on.square"
        }
    }
    var key: String { "lia_home_show_" + rawValue }

    static let orderKey = "lia_home_block_order"
    /// The blocks a person can move (everything under the field).
    static let movable: [HomeBlock] = [.feed, .quick, .conversations, .tabs]

    /// The saved order ("feed,quick,..."), unknown names dropped, missing blocks added at the end.
    static func order(_ raw: String) -> [HomeBlock] {
        var out: [HomeBlock] = []
        for part in raw.split(separator: ",") {
            if let b = HomeBlock(rawValue: String(part)), movable.contains(b), !out.contains(b) { out.append(b) }
        }
        for b in movable where !out.contains(b) { out.append(b) }
        return out
    }

    static func raw(_ order: [HomeBlock]) -> String { order.map(\.rawValue).joined(separator: ",") }
}

/// Customise (in the account menu, under Settings; no button on the page any more): a small popup
/// with a row per block, a switch to show or hide it and a handle to drag it up or down (the brief stays first).
@MainActor
enum HomeCustomise {
    static func open() {
        let id = UUID()
        LiaModalCenter.shared.present(id, style: .card, content: AnyView(HomeCustomiseSheet()),
                                      onDismiss: { LiaModalCenter.shared.remove(id) })
    }
}

private struct HomeCustomiseSheet: View {
    @Environment(\.liaDismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("Customize Home").font(LiaFont.ui(15, .semibold)).foregroundStyle(WS.ink)
                Spacer()
                LiaModalCloseButton(size: 26) { dismiss() }
            }
            .padding(.horizontal, 4).padding(.bottom, 2)
            HomeCustomisePanel()
        }
        .padding(14)
        .frame(width: 300)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text("Customize Home"))
    }
}

/// The dropdown's rows: Brief (fixed), then the movable blocks in their saved order.
struct HomeCustomisePanel: View {
    @AppStorage(HomeBlock.orderKey) private var orderRaw = ""
    @State private var order: [HomeBlock] = HomeBlock.order(UserDefaults.standard.string(forKey: HomeBlock.orderKey) ?? "")
    private static let rowHeight: CGFloat = 40

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            DropdownTitle(text: "On the new tab")
            HomeBlockRow(block: .brief, movable: false)
                .frame(height: Self.rowHeight)
                .padding(.horizontal, 4)
            List {
                ForEach(order) { b in
                    HomeBlockRow(block: b, movable: true, move: { up in move(b, up: up) })
                        .frame(height: Self.rowHeight)
                        .listRowInsets(EdgeInsets(top: 0, leading: 4, bottom: 0, trailing: 4))
                        .listRowSeparator(.hidden)
                        .listRowBackground(Color.clear)
                }
                .onMove { from, to in
                    order.move(fromOffsets: from, toOffset: to)
                    orderRaw = HomeBlock.raw(order)
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .scrollDisabled(true)
            .environment(\.defaultMinListRowHeight, Self.rowHeight)
            .frame(height: Self.rowHeight * CGFloat(order.count) + 4)
            Text("Drag to reorder").font(LiaFont.ui(11)).foregroundStyle(WS.text3)
                .padding(.horizontal, 10).padding(.top, 2).padding(.bottom, 6)
        }
        .onAppear { order = HomeBlock.order(orderRaw) }
    }

    private func move(_ b: HomeBlock, up: Bool) {
        guard let i = order.firstIndex(of: b) else { return }
        let j = up ? i - 1 : i + 1
        guard order.indices.contains(j) else { return }
        order.swapAt(i, j)
        orderRaw = HomeBlock.raw(order)
    }
}

/// One block in Customise: a drag handle, its icon and name, a small switch.
private struct HomeBlockRow: View {
    let block: HomeBlock
    let movable: Bool
    var move: (Bool) -> Void = { _ in }
    @AppStorage private var on: Bool

    init(block: HomeBlock, movable: Bool, move: @escaping (Bool) -> Void = { _ in }) {
        self.block = block
        self.movable = movable
        self.move = move
        _on = AppStorage(wrappedValue: true, block.key)
    }

    var body: some View {
        HStack(spacing: 9) {
            Image(systemName: "line.3.horizontal").font(.system(size: 11, weight: .semibold))
                .foregroundStyle(movable ? WS.text3 : Color.clear)
                .frame(width: 14)
                .accessibilityHidden(true)
            Image(systemName: block.symbol).font(.system(size: 12, weight: .medium)).foregroundStyle(WS.text2)
                .frame(width: 18)
                .accessibilityHidden(true)
            Text(block.title).font(LiaFont.ui(13, .medium)).foregroundStyle(on ? WS.ink : WS.text3)
            Spacer(minLength: 8)
            HomeSwitch(on: $on)
        }
        .padding(.horizontal, 8)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(WS.soft.opacity(0.7), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text(block.title))
        .accessibilityValue(Text(on ? "Shown" : "Hidden"))
        .accessibilityAction(named: Text(on ? "Hide" : "Show")) { on.toggle() }
        .accessibilityAction(named: Text("Move up")) { if movable { move(true) } }
        .accessibilityAction(named: Text("Move down")) { if movable { move(false) } }
    }
}

/// A small switch in our blue (32x18, white knob).
struct HomeSwitch: View {
    @Binding var on: Bool

    var body: some View {
        Button { withAnimation(.easeOut(duration: 0.15)) { on.toggle() } } label: {
            ZStack(alignment: on ? .trailing : .leading) {
                Capsule().fill(on ? WS.blue : WS.line2)
                Circle().fill(Color.white).frame(width: 14, height: 14)
                    .shadow(color: Color.black.opacity(0.22), radius: 1, y: 0.5)
                    .padding(2)
            }
            .frame(width: 32, height: 18)
            .contentShape(Capsule())
        }
        .buttonStyle(.liaPlain)
        .liaPointer()
        .accessibilityAddTraits(.isToggle)
        .accessibilityValue(Text(on ? "On" : "Off"))
    }
}

// MARK: - the headline

/// The new tab's headline: by the time of day, a different one on each open.
enum HomeGreeting {
    enum Part { case morning, afternoon, evening, night }

    static func part(_ d: Date = .now, calendar: Calendar = .current) -> Part {
        switch calendar.component(.hour, from: d) {
        case 5..<12: return .morning
        case 12..<17: return .afternoon
        case 17..<22: return .evening
        default: return .night
        }
    }

    static func lines(_ p: Part) -> [String] {
        switch p {
        case .morning: return morning + anytime
        case .afternoon: return afternoon + anytime
        case .evening: return evening + anytime
        case .night: return night + anytime
        }
    }

    static let morning = [
        "Good morning. What\u{2019}s first?",
        "Morning. Where do we start?",
        "Good morning. What\u{2019}s on today?",
        "Fresh start. What\u{2019}s the plan?",
    ]
    static let afternoon = [
        "Good afternoon. What\u{2019}s next?",
        "Afternoon. What needs doing?",
        "What should we tackle now?",
        "Halfway there. What\u{2019}s next?",
    ]
    static let evening = [
        "Evening. Anything to wrap up?",
        "Good evening. What\u{2019}s left?",
        "Before you go, anything else?",
        "Evening. Shall we close the day?",
    ]
    static let night = [
        "Working late? What\u{2019}s up?",
        "Late one. What do you need?",
        "Quiet hours. What shall we do?",
    ]
    static let anytime = [
        "What should we do today?",
        "What are we working on?",
        "Where shall we begin?",
        "What\u{2019}s on your mind?",
    ]

    /// One line for this moment; `seed` changes per open of the new tab.
    static func pick(_ d: Date = .now, seed: Int) -> String {
        let l = lines(part(d))
        return l[abs(seed) % l.count]
    }
}

// MARK: - suggested tasks

/// Quick tasks the team suggests for this workspace (no made-up prompts). Drawn from the last
/// messages of this workspace's own conversations (the same shared memory the agents work from) by POST
/// /agents/suggest: at most three, each tied to something said there, each for the agent whose job it is. Cached per
/// workspace for 30 minutes; nothing at all when the workspace has no conversations yet. QuickCard shows them under
/// the saved tasks. (cheaper): asked again only when the messages changed since the last good answer
/// (Suggest.fingerprint), and then at most every 30 minutes; the server answers the same messages from its own cache
/// (lia-agents agSuggestKey) and runs them on gpt-6-luna (LIA_SUGGEST_MODEL).
@MainActor
enum HomeSuggestions {
    private struct Entry {
        var tasks: [SuggestedTask]
        var at: Date
        var ok: Bool
        /// The messages this answer was asked for.
        var fp: String
    }
    private static var cache: [String: Entry] = [:]
    private static var inFlight: Set<String> = []
    static let ttl: TimeInterval = 30 * 60
    /// A failed call or an empty answer is asked again sooner than a good answer goes stale.
    static let retry: TimeInterval = 5 * 60

    /// (title, message) pairs: the task as shown, and what goes to the team (an @mention routes it to its agent).
    /// ("quick tasks sometimes vanish"): what was shown stays. An empty or failed answer keeps the
    /// last non-empty set (Suggest.kept), the set is kept on disk per workspace and member so a relaunch shows it at
    /// once, and conversations not loaded yet (no recent messages read) only skip the call, never hide the chips.
    static func list(for ws: WorkspaceModel) -> [(String, String)] {
        guard let p = ws.profile else { return [] }
        let member = ws.auth.activeId ?? "_"
        let key = member + "|" + p.id   // another member's suggestions never show
        if cache[key] == nil, let disk = Suggest.decodeKept(UserDefaults.standard.data(forKey: Suggest.keptKey(profile: p.id, member: member))) {
            // From the last run: shown at once, and asked again on the first look below (`at` is the distant past).
            cache[key] = Entry(tasks: disk, at: .distantPast, ok: false, fp: "")
        }
        let e = cache[key]
        let recent = messages(ws)
        if !recent.isEmpty {
            let age = e.map { Date().timeIntervalSince($0.at) } ?? .infinity
            let fp = Suggest.fingerprint(recent)
            // Nothing new said since a good answer: keep it, ask nothing (however old it is).
            let news = !(e.map { $0.ok && $0.fp == fp } ?? false)
            if news, age > ((e?.ok ?? true) ? ttl : retry) { fetch(ws, key: key, profile: p.id, member: member, recent: recent, fp: fp) }
        }
        return (e?.tasks ?? []).map { t in (t.text, message(t, ws: ws)) }
    }

    /// The text sent for a suggestion: Lia's as is; another agent's with its @name so it answers.
    static func message(_ t: SuggestedTask, ws: WorkspaceModel) -> String {
        guard t.agent != "lia", let a = ws.agent(t.agent), !a.soon else { return t.text }
        return "@\(a.name) \(t.text)"
    }

    /// The newest messages of this workspace's loaded dialogues (the feed warms the newest eight), oldest first.
    private static func messages(_ ws: WorkspaceModel) -> [(agent: String?, text: String)] {
        var all: [(Double, String?, String)] = []
        for d in ws.dialogues {
            guard let c = ws.chatIfOpen(d.dlg) else { continue }
            let updated = (d.last?.ts?.timeIntervalSince1970 ?? 0) * 1000
            for (i, it) in c.items.suffix(Suggest.maxRecent).enumerated() where !it.isTask {
                let text = it.message.content.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty else { continue }
                // A message with no time sorts by the dialogue's last message, in its own order.
                all.append(((it.message.ts ?? updated) + Double(i) * 0.001, it.agent, text))
            }
        }
        return all.sorted { $0.0 < $1.0 }.suffix(Suggest.maxRecent).map { (agent: $0.1, text: $0.2) }
    }

    private static func fetch(_ ws: WorkspaceModel, key: String, profile: String, member: String,
                              recent: [(agent: String?, text: String)], fp: String) {
        guard !inFlight.contains(key) else { return }
        inFlight.insert(key)
        let api = LiaAPI(auth: ws.auth)
        Task { @MainActor [weak ws] in
            let tasks = try? await api.agentSuggestTasks(profile: profile, recent: recent)
            inFlight.remove(key)
            let old = cache[key]?.tasks ?? []
            // Only a non-empty answer is kept for `ttl`; an empty one (the server often answers 0 or 1 task) or a
            // failed call is asked again after `retry`, and neither takes the chips off the screen.
            let shown = Suggest.kept(shown: old, answer: tasks)
            cache[key] = Entry(tasks: shown, at: Date(), ok: !(tasks ?? []).isEmpty, fp: fp)
            guard shown != old else { return }
            if let d = try? JSONEncoder().encode(shown) {
                UserDefaults.standard.set(d, forKey: Suggest.keptKey(profile: profile, member: member))
            }
            ws?.objectWillChange.send()
        }
    }
}

// MARK: - saved prompts

struct SavedPrompt: Codable, Identifiable, Equatable {
    var id: String
    var title: String
    var text: String
}

/// The person's saved prompts (at most 12, newest first) of the workspace in front.: they belong
/// to the workspace (`lia_ws_saved_prompts_<profile>|`), so Start over and Reset this workspace clear them with the
/// rest of `lia_ws_*`; the old key shared by every workspace (`lia_saved_prompts`) is dropped, not migrated.
@MainActor
final class SavedPrompts: ObservableObject {
    static let shared = SavedPrompts()
    static let limit = 12

    /// Read from UserDefaults each time: a reset removes the key, and the list must not outlive it in memory.
    var list: [SavedPrompt] {
        guard let k = key, let d = UserDefaults.standard.data(forKey: k),
              let l = try? JSONDecoder().decode([SavedPrompt].self, from: d) else { return [] }
        return l
    }

    private init() {
        UserDefaults.standard.removeObject(forKey: "lia_saved_prompts")
    }

    /// nil with no workspace open (nothing is saved then).
    private var key: String? {
        guard let p = WorkspaceModel.current?.profileId else { return nil }
        return Self.key(profile: p)
    }

    /// Contains "<profile>|", the pattern Reset this workspace removes.
    nonisolated static func key(profile: String) -> String { "lia_ws_saved_prompts_" + profile + "|" }

    /// A short title from the message's first line (the person renames it later).
    static func title(for text: String) -> String {
        let line = text.split(whereSeparator: \.isNewline).first.map(String.init) ?? text
        let t = line.trimmingCharacters(in: .whitespaces)
        return t.count > 36 ? String(t.prefix(35)) + "\u{2026}" : t
    }

    /// Saves `text` (the same text once; the oldest goes past 12). Returns false for empty text.
    @discardableResult
    func add(_ text: String) -> Bool {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty, key != nil else { return false }
        var list = self.list
        list.removeAll { $0.text == t }
        list.insert(SavedPrompt(id: UUID().uuidString, title: Self.title(for: t), text: t), at: 0)
        if list.count > Self.limit { list.removeLast(list.count - Self.limit) }
        save(list)
        return true
    }

    func rename(_ id: String, to title: String) {
        let t = title.trimmingCharacters(in: .whitespacesAndNewlines)
        var list = self.list
        guard !t.isEmpty, let i = list.firstIndex(where: { $0.id == id }) else { return }
        list[i].title = t
        save(list)
    }

    func remove(_ id: String) {
        var list = self.list
        list.removeAll { $0.id == id }
        save(list)
    }

    private func save(_ list: [SavedPrompt]) {
        guard let k = key else { return }
        objectWillChange.send()
        if list.isEmpty { UserDefaults.standard.removeObject(forKey: k) }
        else if let d = try? JSONEncoder().encode(list) { UserDefaults.standard.set(d, forKey: k) }
    }
}

/// A saved prompt in the quick tasks: a click sends it; the context menu renames or deletes it.
struct SavedPromptChip: View {
    let prompt: SavedPrompt
    let send: () -> Void
    @ObservedObject private var store = SavedPrompts.shared
    @State private var renaming = false
    @State private var name = ""

    var body: some View {
        Button(action: send) { label }
            .buttonStyle(.liaPlain)
            .liaPointer()
            .liaTip(prompt.text)
            .liaContextMenu { menuItems() }
            .popover(isPresented: $renaming, arrowEdge: .bottom) { renameField }
            .accessibilityLabel(Text("Saved task: \(prompt.title)"))
            .accessibilityHint(Text("Sends it to Lia"))
            .accessibilityAction(named: Text("Rename")) { startRename() }
            .accessibilityAction(named: Text("Delete")) { store.remove(prompt.id) }
    }

    private var label: some View {
        HStack(spacing: 6) {
            Image(systemName: "bookmark.fill").font(.system(size: 9.5, weight: .semibold)).foregroundStyle(WS.text2)
            Text(prompt.title).font(LiaFont.ui(13)).foregroundStyle(WS.ink).lineLimit(1)
            Spacer(minLength: 4)
        }
        .padding(.horizontal, 10).padding(.vertical, 7)
        // Liquid Glass like the suggested tasks under it (was WS.soft with a 1 pt line).
        .wsGlass(10, interactive: true)
        .contentShape(Rectangle())
    }

    /// Our right-click menu (not the system one).
    private func menuItems() -> [LiaCtxItem] {
        let id = prompt.id
        let s = store
        return [
            LiaCtxItem(title: "Rename\u{2026}", action: { startRename() }),
            LiaCtxItem(title: "Delete", danger: true, action: { s.remove(id) }),
        ]
    }

    private var renameField: some View {
        HStack(spacing: 8) {
            TextField("Name", text: $name)
                .textFieldStyle(.roundedBorder)
                .frame(width: 220)
                .onSubmit(commit)
                .accessibilityLabel(Text("Name of the saved task"))
            Button("Save", action: commit).keyboardShortcut(.defaultAction)
        }
        .padding(12)
    }

    private func startRename() {
        name = prompt.title
        renaming = true
    }

    private func commit() {
        store.rename(prompt.id, to: name)
        renaming = false
    }
}
