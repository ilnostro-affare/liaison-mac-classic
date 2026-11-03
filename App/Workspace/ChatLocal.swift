import SwiftUI

// What the person marks on a conversation: tapbacks, pins, the person's own approval
// Decisions (this Mac only); the conversation's search and the reply quote.
// Verdicts, favourites and pins live on the server (GET /agents/marks, POST /agents/feedback), keyed by the
// message's server id, so every Mac shows them. The old UserDefaults copies are not read (start over).

// MARK: - feedback, favourites and pins

@MainActor
final class ChatLocal: ObservableObject {
    /// The dialogue's key on this Mac: "profile|dlg" (TeamChatModel.key).
    let key: String
    /// Server message id -> the person's marks on it (reaction and its verdict, favourite, pin time).
    @Published private(set) var marks: [String: DlgMark] = [:]
    /// Message keys the person hid on this Mac before real deletion. deletes on the server; this is
    /// only read, so a message hidden then stays hidden (keyed by its time, which the dialogue import keeps).
    @Published private(set) var hidden: [String]

    private var hiddenKey: String { "lia_ws_hidden_" + key }
    private var auth: AuthStore?
    /// Per message: changes sent and not answered yet. A newer change wins over an older answer.
    private var gen: [String: Int] = [:]
    private var inFlight: [String: Int] = [:]

    /// One per conversation for the app's life: the sheet switches conversations in place and picks the right one.
    private static var all: [String: ChatLocal] = [:]
    static func shared(_ key: String) -> ChatLocal {
        if let l = all[key] { return l }
        let l = ChatLocal(key: key)
        all[key] = l
        return l
    }

    /// Reset workspace: every dialogue's marks are gone on the server; forget what this Mac holds.
    static func resetAll() {
        for l in all.values { l.marks = [:]; l.gen = [:]; l.inFlight = [:] }
        all = [:]
    }

    init(key: String) {
        self.key = key
        hidden = (UserDefaults.standard.stringArray(forKey: "lia_ws_hidden_" + key) ?? []) + Self.legacyHidden
    }

    /// "profile|dlg": the dialogue id never has a "|", the profile might.
    private var profile: String { key.range(of: "|", options: .backwards).map { String(key[..<$0.lowerBound]) } ?? key }
    private var dlg: String { key.range(of: "|", options: .backwards).map { String(key[$0.upperBound...]) } ?? "" }

    /// Every message hidden under an old thread id (threads are gone; their messages live on in the dialogues).
    private static let legacyHidden: [String] = {
        let d = UserDefaults.standard.dictionaryRepresentation()
        var out = Set<String>()
        for (k, v) in d where k.hasPrefix("lia_ws_hidden_") && !k.contains("|") {
            for s in (v as? [String]) ?? [] where s.hasPrefix("t") { out.insert(s) }
        }
        return Array(out)
    }()

    /// The key of the legacy hidden list: a message's time (ms) when it has one, else its id.
    nonisolated static func hideKey(_ item: TeamItem) -> String {
        if let ts = item.message.ts { return "t" + String(Int64(ts)) }
        return "i" + item.id
    }

    /// The server id a mark is stored under; nil while the message is only drawn here (streaming, not stored yet):
    /// such a message cannot be marked until its stored copy arrives.
    nonisolated static func markId(_ item: TeamItem) -> String? { item.confirmed && !item.id.isEmpty ? item.id : nil }

    /// The dialogue's marks from the server (each time the conversation opens: another Mac may have changed them).
    /// A message with a change still on its way keeps what this Mac shows.
    func load(auth: AuthStore) async {
        self.auth = auth
        guard !dlg.isEmpty, let list = try? await LiaAPI(auth: auth).dialogMarks(profile: profile, dlg: dlg) else { return }
        var next: [String: DlgMark] = [:]
        for m in list where !m.isEmpty { next[m.id] = m }
        for (id, n) in inFlight where n > 0 { next[id] = marks[id] }
        marks = next
    }

    /// (the product's ask 2): ❤️ is the like and the like is the favourite; 👍/👎 are the feedback on the answer.
    nonisolated static let heart = "\u{2764}\u{FE0F}"
    nonisolated static let thumbs = ["\u{1F44D}", "\u{1F44E}"]

    /// Liked = a favourite. A ❤️ left as a reaction by an older Mac reads as the like too.
    nonisolated static func liked(_ m: DlgMark) -> Bool { m.fav || m.reaction == heart }

    func isFavourite(_ item: TeamItem) -> Bool { Self.markId(item).flatMap { marks[$0].map(Self.liked) } ?? false }
    func isPinned(_ item: TeamItem) -> Bool { Self.markId(item).flatMap { marks[$0]?.pinTs } != nil }

    /// Server ids of the pinned messages, in pin order.
    var pins: [String] {
        marks.values.compactMap { m in m.pinTs.map { (m.id, $0) } }.sorted { $0.1 < $1.1 }.map(\.0)
    }

    /// The person's thumb on a message (\u{1F44D} or \u{1F44E}), nil = none. A verdict set before reactions existed reads as
    /// its thumb; any other reaction (an older ❤️, which is the like, or 🔥 🤝 🤣) is not a thumb.
    func reaction(_ item: TeamItem) -> String? {
        guard let id = Self.markId(item), let m = marks[id] else { return nil }
        if let r = m.reaction { return Self.thumbs.contains(r) ? r : nil }
        switch m.verdict { case "up": return Self.thumbs[0]; case "down": return Self.thumbs[1]; default: return nil }
    }

    /// Sets the thumb (it replaces the other one); nil removes it. The server sets the verdict from it. A ❤️ an older
    /// Mac left as the reaction becomes the favourite in the same call, so the like is not lost.
    func react(_ emoji: String?, for item: TeamItem) {
        guard let id = Self.markId(item) else { return }
        let e = emoji.flatMap { Self.thumbs.contains($0) ? $0 : nil }
        let keepLike = marks[id].map { !$0.fav && $0.reaction == Self.heart } ?? false
        change(id) { m in
            m.reaction = e
            m.verdict = e.map { $0 == Self.thumbs[1] ? "down" : "up" }
            if keepLike { m.fav = true }
        } send: { api, p, d in
            try await api.dialogMark(profile: p, dlg: d, id: id, reaction: e ?? "", fav: keepLike ? true : nil)
        }
    }

    /// ❤️: likes the message (it goes to Favourites) or takes the like back. Taking it back also clears a ❤️ an older
    /// Mac left as the reaction.
    func toggleFavourite(_ item: TeamItem) {
        guard let id = Self.markId(item) else { return }
        let on = !(marks[id].map(Self.liked) ?? false)
        let clearOld = !on && marks[id]?.reaction == Self.heart
        change(id) { m in
            m.fav = on
            if clearOld { m.reaction = nil; m.verdict = nil }
        } send: { api, p, d in
            try await api.dialogMark(profile: p, dlg: d, id: id, reaction: clearOld ? "" : nil, fav: on)
        }
    }

    func togglePin(_ item: TeamItem) {
        guard let id = Self.markId(item) else { return }
        let on = marks[id]?.pinTs == nil
        change(id) { $0.pinTs = on ? Date() : nil } send: { api, p, d in try await api.dialogMark(profile: p, dlg: d, id: id, pin: on) }
    }

    /// Shown at once, then sent. The server's answer is the truth; on a failure the mark goes back and the dialogue's
    /// marks are read again (an earlier change may still have been on its way).
    private func change(_ id: String, _ edit: (inout DlgMark) -> Void,
                        send: @escaping (LiaAPI, String, String) async throws -> DlgMark?) {
        guard let auth, !dlg.isEmpty else { return }
        let before = marks[id]
        var m = before ?? DlgMark(id: id)
        edit(&m)
        marks[id] = m.isEmpty ? nil : m
        let g = (gen[id] ?? 0) + 1
        gen[id] = g
        inFlight[id, default: 0] += 1
        let api = LiaAPI(auth: auth), p = profile, d = dlg
        Task { @MainActor [weak self] in
            let result: Result<DlgMark?, Error>
            do { result = .success(try await send(api, p, d)) } catch { result = .failure(error) }
            guard let self else { return }
            self.inFlight[id, default: 1] -= 1
            switch result {
            case .success(let now):
                if self.gen[id] == g { self.marks[id] = (now?.isEmpty ?? true) ? nil : now }
            case .failure:
                if self.gen[id] == g { self.marks[id] = before }
                WorkspaceModel.current?.show("Couldn't save. Try again.", symbol: "exclamationmark.triangle")
                await self.load(auth: auth)
            }
        }
    }

    func isHidden(_ item: TeamItem) -> Bool { hidden.contains(Self.hideKey(item)) }

    /// The legacy "Delete" on a message: hidden from this conversation on this Mac. Never sent anywhere.
    func hide(_ item: TeamItem) {
        let k = Self.hideKey(item)
        guard !hidden.contains(k) else { return }
        hidden.append(k)
        if hidden.count > 2000 { hidden.removeFirst(hidden.count - 2000) }
        UserDefaults.standard.set(hidden, forKey: hiddenKey)
    }

    /// The thread without the messages deleted on this Mac.
    func visible(_ items: [TeamItem]) -> [TeamItem] {
        hidden.isEmpty ? items : items.filter { !isHidden($0) }
    }

    /// The pinned messages that are in the thread now, in pin order.
    func pinned(in items: [TeamItem]) -> [TeamItem] {
        pins.compactMap { id in items.first { $0.confirmed && $0.id == id } }
    }
}

// MARK: - delete with undo

/// A deleted message waits 10 s before the server delete (`TeamChatModel.delete` \u{2192} `LiaAPI.dialogDelete`) is sent:
/// its row shows "Message deleted \u{00B7} Undo (n)" meanwhile, and Undo drops it with nothing sent. Leaving the
/// conversation (the sheet closes, another dialogue opens) sends what waits at once (`flush`). App-wide, so a
/// countdown outlives the view that started it.
@MainActor
final class ChatPendingDeletes: ObservableObject {
    static let shared = ChatPendingDeletes()
    static let seconds = 10

    typealias Facts = [(id: String, text: String)]
    private struct Entry {
        let item: TeamItem
        let chat: TeamChatModel
        let done: (Facts?) -> Void
        let timer: Task<Void, Never>
    }

    /// "chat key \u{1} message id" \u{2192} when the countdown ends (it stays until the server has answered).
    @Published private(set) var until: [String: Date] = [:]
    private var entries: [String: Entry] = [:]

    private static func key(_ chatKey: String, _ id: String) -> String { chatKey + "\u{1}" + id }

    func deadline(_ item: TeamItem, in chatKey: String) -> Date? { until[Self.key(chatKey, item.id)] }

    /// Starts the countdown; `done` gets the server's answer (nil: it failed, the message is back).
    func start(_ item: TeamItem, in chat: TeamChatModel, done: @escaping (Facts?) -> Void) {
        let k = Self.key(chat.key, item.id)
        guard until[k] == nil else { return }
        let timer = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(Self.seconds) * 1_000_000_000)
            guard !Task.isCancelled else { return }
            self?.commit(k)
        }
        entries[k] = Entry(item: item, chat: chat, done: done, timer: timer)
        until[k] = Date().addingTimeInterval(Double(Self.seconds))
    }

    /// Undo: the message is back, nothing was sent.
    func undo(_ item: TeamItem, in chatKey: String) {
        let k = Self.key(chatKey, item.id)
        guard let e = entries.removeValue(forKey: k) else { return }
        e.timer.cancel()
        until[k] = nil
    }

    /// Everything waiting in this conversation goes now (the conversation is closing).
    func flush(_ chatKey: String) {
        let prefix = chatKey + "\u{1}"
        for k in entries.keys where k.hasPrefix(prefix) { commit(k) }
    }

    private func commit(_ k: String) {
        guard let e = entries.removeValue(forKey: k) else { return }
        e.timer.cancel()
        Task { @MainActor [weak self] in
            let facts = await e.chat.delete(e.item)
            // After the message has left the thread, so its row never flashes back in between.
            self?.until[k] = nil
            e.done(facts)
        }
    }
}

// MARK: - approval decisions

/// The person's answer to an approval, remembered by plan id (the stored gate only says `done`).
enum ChatDecisions {
    struct Decision: Equatable { let approved: Bool; let at: Date }
    private static let key = "lia_ws_decisions"

    static func record(planId: String, approved: Bool) {
        guard !planId.isEmpty else { return }
        var all = (UserDefaults.standard.dictionary(forKey: key) as? [String: [String: Any]]) ?? [:]
        all[planId] = ["a": approved, "ts": Date().timeIntervalSince1970]
        if all.count > 400 {
            // keep the newest 300
            let keep = all.sorted { (($0.value["ts"] as? Double) ?? 0) > (($1.value["ts"] as? Double) ?? 0) }.prefix(300)
            all = Dictionary(uniqueKeysWithValues: keep.map { ($0.key, $0.value) })
        }
        UserDefaults.standard.set(all, forKey: key)
    }

    static func get(_ planId: String) -> Decision? {
        guard let all = UserDefaults.standard.dictionary(forKey: key) as? [String: [String: Any]], let o = all[planId],
              let a = o["a"] as? Bool, let ts = o["ts"] as? Double else { return nil }
        return Decision(approved: a, at: Date(timeIntervalSince1970: ts))
    }
}

// MARK: - search

@MainActor
final class ChatSearch: ObservableObject {
    @Published var open = false
    @Published var query = ""
    /// The selected hit (index into `hits`).
    @Published var current = 0

    /// One occurrence: the message and which occurrence inside its text.
    struct Hit: Equatable { let item: String; let n: Int }

    var active: Bool { open && !query.trimmingCharacters(in: .whitespaces).isEmpty }

    func hits(in items: [TeamItem]) -> [Hit] {
        guard active else { return [] }
        var out: [Hit] = []
        for it in items {
            let c = Self.ranges(query, in: Self.text(of: it)).count
            for n in 0..<c { out.append(Hit(item: it.id, n: n)) }
        }
        return out
    }

    func step(_ by: Int, count: Int) {
        guard count > 0 else { return }
        current = ((current + by) % count + count) % count
    }

    func close() { open = false; query = ""; current = 0 }

    /// What the search reads of a message: the person's text as typed, an agent's without Markdown marks.
    nonisolated static func text(of item: TeamItem) -> String {
        item.agent == nil ? item.message.content : FeedText.plain(item.message.content)
    }

    nonisolated static func ranges(_ q: String, in s: String) -> [Range<String.Index>] {
        let q = q.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return [] }
        var out: [Range<String.Index>] = []
        var from = s.startIndex
        while from < s.endIndex, let r = s.range(of: q, options: [.caseInsensitive, .diacriticInsensitive], range: from..<s.endIndex) {
            out.append(r)
            from = r.upperBound
        }
        return out
    }

    /// The text with every match marked; `current` (an occurrence index) marked stronger.
    nonisolated static func highlighted(_ s: String, query: String, current: Int?, dark: Bool) -> AttributedString {
        var out = AttributedString()
        var at = s.startIndex
        for (i, r) in ranges(query, in: s).enumerated() {
            out += AttributedString(String(s[at..<r.lowerBound]))
            var m = AttributedString(String(s[r]))
            let strong = i == current
            // SwiftUI's keys by name: AppKit's NSColor attributes of the same names are in scope too.
            // Our blue, never yellow: on the person's blue bubble (dark) the marks are white.
            let bg: Color
            let fg: Color
            if dark {
                bg = strong ? Color.white : Color.white.opacity(0.32)
                fg = strong ? WS.blue : Color.white
            } else {
                bg = strong ? WS.blue : WS.blue.opacity(0.16)
                fg = strong ? Color.white : WS.ink
            }
            m[AttributeScopes.SwiftUIAttributes.BackgroundColorAttribute.self] = bg
            m[AttributeScopes.SwiftUIAttributes.ForegroundColorAttribute.self] = fg
            out += m
            at = r.upperBound
        }
        out += AttributedString(String(s[at...]))
        return out
    }
}

/// The search field in the conversation's header: "2 of 5", \u{2191}/\u{2193} (and \u{23CE}/\u{21E7}\u{23CE}) step, Esc closes.
struct ChatSearchField: View {
    @ObservedObject var search: ChatSearch
    let count: Int
    @FocusState private var focus: Bool

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass").font(.system(size: 11, weight: .semibold)).foregroundStyle(WS.text3)
            TextField("Search this conversation", text: $search.query)
                .textFieldStyle(.plain)
                .font(LiaFont.ui(13))
                .focused($focus)
                .frame(minWidth: 120)
                .onKeyPress(.downArrow) { search.step(1, count: count); return .handled }
                .onKeyPress(.upArrow) { search.step(-1, count: count); return .handled }
                .onKeyPress(.return, phases: .down) { p in
                    search.step(p.modifiers.contains(.shift) ? -1 : 1, count: count)
                    return .handled
                }
                .onKeyPress(.escape) { search.close(); return .handled }
                .onExitCommand { search.close() }
                .onChange(of: search.query) { _, _ in search.current = 0 }
                .accessibilityLabel(Text("Search this conversation"))
                .accessibilityValue(Text(countText))
            if search.active {
                Text(countText).font(LiaFont.ui(11.5)).foregroundStyle(WS.text3).monospacedDigit().fixedSize()
                    .accessibilityHidden(true)
                stepButton("chevron.up", "Previous match") { search.step(-1, count: count) }
                stepButton("chevron.down", "Next match") { search.step(1, count: count) }
            }
            Button { search.close() } label: {
                Image(systemName: "xmark.circle.fill").font(.system(size: 12)).foregroundStyle(WS.text3)
            }
            .buttonStyle(.liaPlain).liaPointer()
            .accessibilityLabel(Text("Close search"))
        }
        .padding(.horizontal, 10).frame(width: 290, height: 30)
        .background(WS.soft, in: Capsule())
        .overlay(Capsule().stroke(WS.line2, lineWidth: 1))
        .onAppear { focus = true }
    }

    private var countText: String {
        count == 0 ? "No matches" : "\(min(search.current, count - 1) + 1) of \(count)"
    }

    private func stepButton(_ symbol: String, _ label: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 10, weight: .bold)).foregroundStyle(count == 0 ? WS.text3 : WS.text2)
                .frame(width: 20, height: 20).contentShape(Rectangle())
        }
        .buttonStyle(.liaPlain).disabled(count == 0).liaPointer()
        .accessibilityLabel(Text(label))
    }
}

// MARK: - reply quote

enum ChatQuote {
    /// The first line of a message, at most `max` characters, for the quote strip and the quote line.
    static func firstLine(_ item: TeamItem, max: Int = 120) -> String {
        let t = ChatSearch.text(of: item).replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
        return t.count > max ? String(t.prefix(max - 1)) + "\u{2026}" : t
    }

    /// The text that goes to the agent: "> <quoted>" on its own line, then the person's words.
    static func compose(_ text: String, quoting item: TeamItem) -> String {
        "> " + firstLine(item) + "\n\n" + text
    }

    /// A sent message that starts with a quote line: (the quote, the rest).
    static func split(_ content: String) -> (quote: String?, body: String) {
        guard content.hasPrefix("> ") else { return (nil, content) }
        let parts = content.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false)
        let q = String(parts[0].dropFirst(2))
        let rest = parts.count > 1 ? String(parts[1]).trimmingCharacters(in: .whitespacesAndNewlines) : ""
        // A forward with no comment is still a quote (its body is empty).
        if rest.isEmpty && q.hasPrefix(ChatForwardDraft.prefix) { return (q, "") }
        return rest.isEmpty ? (nil, content) : (q, rest)
    }
}

/// The strip over the composer while replying: who said it, its first line, \u{00d7}.
struct ChatReplyStrip: View {
    let item: TeamItem
    let agent: AgentInfo?
    let onClose: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            RoundedRectangle(cornerRadius: 1.5).fill(agent.map { Color(hex: $0.colorHex) } ?? WS.ink).frame(width: 3, height: 30)
            VStack(alignment: .leading, spacing: 1) {
                Text("Reply to \(agent?.name ?? "yourself")").font(LiaFont.ui(11.5, .semibold))
                    .foregroundStyle(agent.map { Color(hex: $0.colorHex) } ?? WS.text2)
                Text(ChatQuote.firstLine(item)).font(LiaFont.ui(12)).foregroundStyle(WS.text2).lineLimit(1)
            }
            Spacer(minLength: 6)
            Button(action: onClose) {
                Image(systemName: "xmark").font(.system(size: 9, weight: .bold)).foregroundStyle(WS.text2)
                    .frame(width: 20, height: 20).background(WS.soft, in: Circle())
            }
            .buttonStyle(.liaPlain).liaPointer()
            .accessibilityLabel(Text("Cancel reply"))
        }
        .padding(.horizontal, 10).padding(.vertical, 6)
        .background(WS.surface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(WS.line2, lineWidth: 1))
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text("Replying to \(agent?.name ?? "your message"): \(ChatQuote.firstLine(item))"))
    }
}
