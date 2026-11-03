import SwiftUI

// / Mac 0.2.7: Telegram-like search over the agents' dialogues (server search, /agents/search), a 340 pt
// column the conversation sheet hosts. Not Cmd+F: that finds on the loaded page (ChatLocal).

/// The filter chips: All plus the four item kinds, counted by /agents/search/counters.
private enum DSFilter: String, CaseIterable, Identifiable {
    case all, media, files, links, plans
    var id: String { rawValue }
    var title: String {
        switch self {
        case .all: return "All"
        case .media: return "Media"
        case .files: return "Files"
        case .links: return "Links"
        case .plans: return "Plans"
        }
    }
    var kind: DlgItem.Kind? { self == .all ? nil : DlgItem.Kind(rawValue: rawValue) }
}

/// The surfaces offered in "Sent from" (plain chat, page and schedule are not filters worth a row).
private let dsSurfaces: [(DlgOrigin.Surface, String)] = [
    (.addressBar, "Address bar"), (.notes, "Notes"), (.sidePanel, "Side panel"), (.handoff, "Hand-off"),
]

@MainActor
struct DialogueSearchPanel: View {
    let ws: WorkspaceModel
    let profile: String
    let dlg: String?
    let onJump: (SearchHit) -> Void
    let onClose: () -> Void

    @State private var text = ""
    @State private var thisChat: Bool
    @State private var filter: DSFilter = .all
    @State private var agent: String?
    @State private var origin: DlgOrigin.Surface?
    @State private var counts: [String: Int] = [:]
    @State private var hits: [SearchHit] = []
    @State private var total = 0
    /// The server stopped at its newest 1,000 matches: the count reads "1000+".
    @State private var capped = false
    @State private var loading = false
    @State private var loadingMore = false
    @State private var error: String?
    /// The days the search is narrowed to (the calendar's "Show messages").
    @State private var dates = LiaDateRange()
    /// The slide-in has finished: the field takes focus and the counters load only then, so nothing re-lays out the
    /// column (or the thread beside it) while it moves.
    @State private var settled = false
    @FocusState private var focused: Bool

    init(ws: WorkspaceModel, profile: String, dlg: String?, onJump: @escaping (SearchHit) -> Void, onClose: @escaping () -> Void) {
        self.ws = ws
        self.profile = profile
        self.dlg = dlg
        self.onJump = onJump
        self.onClose = onClose
        _thisChat = State(initialValue: dlg != nil)
        // The counters of the last open: the chips have their final width from the first frame.
        _counts = State(initialValue: DSCountsCache.get(profile: profile, dlg: dlg))
    }

    /// The dialogue searched: this chat's, or every agent's (nil).
    private var scopeDlg: String? { thisChat ? dlg : nil }

    private var query: SearchQuery {
        SearchQuery(q: text, dlg: scopeDlg, kind: filter.kind, agent: agent, origin: origin,
                    from: dates.bounds?.start, to: dates.bounds?.end)
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            filters
            Divider().overlay(WS.line)
            results
        }
        .frame(width: 340)
        .frame(maxHeight: .infinity)
        .background(WS.surface)
        .onExitCommand(perform: onClose)
        .task {
            // About the length of the host's slide-in spring: focusing a text field and changing the chips' widths
            // mid-move is what made the column stutter in.
            try? await Task.sleep(nanoseconds: 360_000_000)
            settled = true
            focused = true
        }
        .task(id: query) { await debouncedSearch(query) }
        .task(id: settled ? (scopeDlg ?? "*") : nil) { if settled { await loadCounters() } }
    }

    // MARK: - header

    private var header: some View {
        VStack(spacing: 10) {
            HStack(spacing: 8) {
                Text("Search").font(LiaFont.ui(15, .bold)).foregroundStyle(WS.ink)
                Spacer()
                dateButton
                closeButton
            }
            field
            if dlg != nil { scopeToggle }
        }
        .padding(.horizontal, 14)
        .padding(.top, 14)
        .padding(.bottom, 10)
    }

    private var field: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass").font(.system(size: 12, weight: .semibold)).foregroundStyle(WS.text3)
            TextField("Search messages", text: $text)
                .textFieldStyle(.plain)
                .font(LiaFont.ui(13))
                .focused($focused)
            if !text.isEmpty {
                Button { text = "" } label: {
                    Image(systemName: "xmark.circle.fill").font(.system(size: 12)).foregroundStyle(WS.text3)
                }
                .buttonStyle(.liaPlain)
                .accessibilityLabel(Text("Clear"))
            }
        }
        .padding(.horizontal, 10)
        .frame(height: 32)
        .background(WS.soft, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(focused ? WS.blue.opacity(0.5) : WS.line, lineWidth: 1))
    }

    private var scopeToggle: some View {
        HStack(spacing: 2) {
            scopeSegment("This chat", on: thisChat) { thisChat = true }
            scopeSegment("All agents", on: !thisChat) { thisChat = false }
        }
        .padding(2)
        .background(WS.soft, in: Capsule())
    }

    private func scopeSegment(_ title: String, on: Bool, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(LiaFont.ui(12, on ? .semibold : .regular))
                .foregroundStyle(on ? WS.ink : WS.text2)
                .frame(maxWidth: .infinity)
                .frame(height: 24)
                .background(on ? WS.surface : Color.clear, in: Capsule())
                .shadow(color: on ? Color.black.opacity(0.08) : .clear, radius: 2, y: 1)
                .contentShape(Capsule())
        }
        .buttonStyle(.liaPlain)
    }

    private var closeButton: some View {
        Button(action: onClose) {
            Image(systemName: "xmark").font(.system(size: 11, weight: .bold)).foregroundStyle(WS.text2)
                .frame(width: 26, height: 26)
                .background(WS.soft, in: Circle())
        }
        .buttonStyle(.liaPlain)
        .accessibilityLabel(Text("Close"))
    }

    // MARK: - date jump

    private var dateButton: some View {
        let on = !dates.isEmpty
        return DropdownButton(align: .trailing, help: "Dates", tip: on ? dates.label : "Jump to a date or search by dates", highlight: false) {
            Image(systemName: "calendar").font(.system(size: 12, weight: .semibold)).foregroundStyle(on ? WS.blue : WS.text2)
                .frame(width: 26, height: 26)
                .background(on ? WS.blue.opacity(0.1) : WS.soft, in: Circle())
                .contentShape(Circle())
        } menu: {
            LiaPanel(padding: 12) {
                DSDatePanel(initial: dates, canClear: !dates.isEmpty,
                            onShow: { r in dates = r },
                            onJump: { d in await jump(to: d) })
            }
        }
    }

    /// This chat: /agents/dlg/at gives the seq; a search from that day gives the message's id. All agents: the
    /// first hit from that day.
    /// nil when it jumped; else why not (the panel shows it).
    private func jump(to date: Date) async -> String? {
        let api = LiaAPI(auth: ws.auth)
        let start = Calendar.current.startOfDay(for: date)
        var seq: Int?
        if let d = scopeDlg { seq = try? await api.dialogAt(profile: profile, dlg: d, ts: start) }
        let q = SearchQuery(dlg: scopeDlg, from: start)
        let found = (try? await api.search(profile: profile, q))?.hits ?? []
        let hit: SearchHit?
        if let seq, let d = scopeDlg {
            if let h = found.first(where: { $0.seq == seq && $0.dlg == d }) {
                hit = h
            } else if let m = (try? await api.dialogPage(profile: profile, dlg: d, before: seq + 1, limit: 1))?.messages.last {
                // the message at that seq, so the host can jump by its id
                hit = SearchHit(id: m.id, dlg: d, seq: m.seq, ts: m.ts ?? start)
            } else {
                hit = nil
            }
        } else {
            hit = found.min { ($0.ts ?? .distantFuture) < ($1.ts ?? .distantFuture) }
        }
        guard let hit else { return "No messages from this date on." }
        DropdownHost.shared.close()
        onJump(hit)
        return nil
    }

    // MARK: - filters

    private var filters: some View {
        VStack(alignment: .leading, spacing: 8) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(DSFilter.allCases) { f in chip(f) }
                }
                .padding(.horizontal, 14)
            }
            HStack(spacing: 6) {
                agentMenu
                originMenu
                if !dates.isEmpty { datesChip }
                Spacer()
            }
            .padding(.horizontal, 14)
        }
        .padding(.bottom, 10)
    }

    private func chip(_ f: DSFilter) -> some View {
        let on = filter == f
        let n = counts[f.rawValue]
        return Button { filter = f } label: {
            HStack(spacing: 4) {
                Text(f.title).font(LiaFont.ui(12, on ? .semibold : .regular))
                if let n { Text(String(n)).font(LiaFont.ui(11)).opacity(0.7) }
            }
            .foregroundStyle(on ? Color.white : WS.text2)
            .padding(.horizontal, 10)
            .frame(height: 26)
            .background(on ? WS.blue : WS.soft, in: Capsule())
            .contentShape(Capsule())
        }
        .buttonStyle(.liaPlain)
    }

    private var agentMenu: some View {
        LiaDropdown(title: "From", selection: $agent, noneTitle: "Anyone",
                    options: ws.roster.map { LiaOption($0.id, $0.name) }, label: { "From " + $0 })
    }

    private var originMenu: some View {
        LiaDropdown(title: "Sent from", selection: $origin, noneTitle: "Anywhere",
                    options: dsSurfaces.map { LiaOption($0.0, $0.1) })
    }

    /// The days the search is narrowed to; the cross clears them.
    private var datesChip: some View {
        Button { dates = LiaDateRange() } label: {
            HStack(spacing: 4) {
                Text(dates.label).font(LiaFont.ui(12, .semibold)).lineLimit(1)
                Image(systemName: "xmark").font(.system(size: 8, weight: .bold))
            }
            .foregroundStyle(WS.blue)
            .padding(.horizontal, 10)
            .frame(height: 26)
            .background(WS.blue.opacity(0.1), in: Capsule())
            .contentShape(Capsule())
        }
        .buttonStyle(.liaPlain)
        .liaPointer()
        .accessibilityHint(Text("Clear dates"))
    }

    // MARK: - results

    @ViewBuilder private var results: some View {
        if query.isEmpty {
            placeholder("magnifyingglass", "Search this chat's messages, media, files, links and plans.")
        } else if let error, hits.isEmpty {
            errorState(error)
        } else if loading && hits.isEmpty {
            LiaLoadingOrbit(size: 72, label: "Searching").frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if hits.isEmpty {
            placeholder("text.magnifyingglass", "Nothing found.")
        } else {
            list
        }
    }

    private var list: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 2) {
                Text(capped ? "\(total)+ results" : total == 1 ? "1 result" : "\(total) results")
                    .font(LiaFont.ui(11, .semibold)).foregroundStyle(WS.text3)
                    .padding(.horizontal, 14).padding(.vertical, 6)
                ForEach(hits) { h in
                    DSHitRow(hit: h, agent: ws.agent(h.agent), showDialogue: scopeDlg == nil,
                             dialogueName: name(of: h.dlg == "team" ? "lia" : h.dlg)) { onJump(h) }
                }
                if hits.count < total { moreFooter }
            }
            .padding(.vertical, 6)
        }
    }

    private var moreFooter: some View {
        HStack { Spacer(); ProgressView().controlSize(.small); Spacer() }
            .frame(height: 36)
            .onAppear { Task { await loadMore() } }
    }

    private func placeholder(_ icon: String, _ line: String) -> some View {
        VStack(spacing: 8) {
            Image(systemName: icon).font(.system(size: 22)).foregroundStyle(WS.text3)
            Text(line).font(LiaFont.ui(12)).foregroundStyle(WS.text2).multilineTextAlignment(.center)
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func errorState(_ message: String) -> some View {
        VStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle").font(.system(size: 20)).foregroundStyle(WS.bad)
            Text("Search failed.").font(LiaFont.ui(13, .semibold)).foregroundStyle(WS.ink)
            Text(message).font(LiaFont.ui(11)).foregroundStyle(WS.text3).multilineTextAlignment(.center).lineLimit(3)
            Button("Try again") { Task { await search(query) } }.buttonStyle(WSButtonStyle(small: true)).liaPointer()
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - loading

    private func name(of id: String) -> String { ws.agent(id)?.name ?? DlgOrigin.displayName(id) }

    private func debouncedSearch(_ q: SearchQuery) async {
        if q.isEmpty { hits = []; total = 0; capped = false; error = nil; loading = false; return }
        try? await Task.sleep(nanoseconds: 250_000_000)
        if Task.isCancelled { return }
        await search(q)
    }

    private func search(_ q: SearchQuery) async {
        loading = true
        error = nil
        defer { loading = false }
        do {
            let r = try await LiaAPI(auth: ws.auth).search(profile: profile, q)
            if Task.isCancelled || q != query { return }
            hits = r.hits
            total = max(r.count, r.hits.count)
            capped = r.capped
        } catch {
            if Task.isCancelled { return }
            hits = []
            total = 0
            capped = false
            self.error = error.localizedDescription
        }
    }

    private func loadMore() async {
        guard !loadingMore, hits.count < total else { return }
        loadingMore = true
        defer { loadingMore = false }
        var q = query
        q.offset = hits.count
        guard let r = try? await LiaAPI(auth: ws.auth).search(profile: profile, q), q.dlg == scopeDlg else { return }
        let known = Set(hits.map(\.id))
        let fresh = r.hits.filter { !known.contains($0.id) }
        if fresh.isEmpty { total = hits.count; return }   // the server has no more: stop asking
        hits += fresh
    }

    private func loadCounters() async {
        let d = scopeDlg
        guard let c = try? await LiaAPI(auth: ws.auth).searchCounters(profile: profile, dlg: d), !Task.isCancelled else { return }
        DSCountsCache.put(c, profile: profile, dlg: d)
        if c != counts { counts = c }
    }
}

/// The chips' counters by profile and scope, for the next open of the column (this run only).
@MainActor
private enum DSCountsCache {
    private static var store: [String: [String: Int]] = [:]
    static func get(profile: String, dlg: String?) -> [String: Int] { store[profile + "|" + (dlg ?? "*")] ?? [:] }
    static func put(_ c: [String: Int], profile: String, dlg: String?) { store[profile + "|" + (dlg ?? "*")] = c }
}

/// The calendar's panel: a day or a range, then "Go to date" (the first day, in the thread) or "Show messages"
/// (the search narrowed to those days). Its own state: the panel is hosted apart from the column.
@MainActor
private struct DSDatePanel: View {
    let canClear: Bool
    let onShow: (LiaDateRange) -> Void
    let onJump: (Date) async -> String?
    @State private var range: LiaDateRange
    @State private var note: String?
    @State private var jumping = false

    init(initial: LiaDateRange, canClear: Bool, onShow: @escaping (LiaDateRange) -> Void, onJump: @escaping (Date) async -> String?) {
        self.canClear = canClear
        self.onShow = onShow
        self.onJump = onJump
        _range = State(initialValue: initial)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            LiaCalendar(range: $range)
            Text(note ?? (range.isEmpty ? "Pick a day, or two for a range." : range.label))
                .font(LiaFont.ui(12)).foregroundStyle(note == nil ? WS.text2 : WS.bad)
                .lineLimit(2)
                .padding(.horizontal, 4)
            HStack(spacing: 6) {
                if canClear {
                    Button("Clear") { DropdownHost.shared.close(); onShow(LiaDateRange()) }
                        .buttonStyle(WSButtonStyle(small: true)).liaPointer()
                }
                Spacer(minLength: 0)
                Button("Go to date") { go() }
                    .buttonStyle(WSButtonStyle(small: true)).liaPointer()
                    .disabled(range.isEmpty || jumping)
                    .opacity(range.isEmpty ? 0.5 : 1)
                Button("Show messages") { DropdownHost.shared.close(); onShow(range) }
                    .buttonStyle(WSButtonStyle(primary: true, small: true)).liaPointer()
                    .disabled(range.isEmpty)
                    .opacity(range.isEmpty ? 0.5 : 1)
            }
        }
        .frame(width: 252)
        .onChange(of: range) { _, _ in note = nil }
    }

    private func go() {
        guard let d = range.from else { return }
        jumping = true
        Task {
            let why = await onJump(d)
            jumping = false
            note = why
        }
    }
}

/// One result: who spoke, when, the snippet with the matches in bold.
@MainActor
private struct DSHitRow: View {
    let hit: SearchHit
    let agent: AgentInfo?
    let showDialogue: Bool
    let dialogueName: String
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: 10) {
                figure
                VStack(alignment: .leading, spacing: 3) {
                    topLine
                    snippet
                        .font(LiaFont.ui(12))
                        .foregroundStyle(WS.text2)
                        .lineLimit(3)
                        .multilineTextAlignment(.leading)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(hover ? WS.soft : Color.clear, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.liaPlain)
        .padding(.horizontal, 4)
        .onHover { hover = $0 }
    }

    @ViewBuilder private var figure: some View {
        if hit.role == .user {
            Circle().fill(WS.soft)
                .overlay(Image(systemName: "person.fill").font(.system(size: 13)).foregroundStyle(WS.text3))
                .frame(width: 30, height: 30)
        } else if let agent {
            AgentAvatar(agent: agent, size: 30)
        } else {
            Circle().fill(WS.soft).frame(width: 30, height: 30)
        }
    }

    private var who: String {
        if hit.role == .user { return "You" }
        if let agent { return agent.name }
        return hit.agent.map(DlgOrigin.displayName) ?? "Lia"
    }

    private var topLine: some View {
        HStack(spacing: 4) {
            Text(who).font(LiaFont.ui(12, .semibold)).foregroundStyle(WS.ink).lineLimit(1)
            if showDialogue {
                Text("in " + dialogueName).font(LiaFont.ui(11)).foregroundStyle(WS.text3).lineLimit(1)
            }
            Spacer(minLength: 4)
            if let ts = hit.ts {
                Text(DSDate.short(ts)).font(LiaFont.ui(11)).foregroundStyle(WS.text3)
            }
        }
    }

    /// The «…» runs: matches bold and ink, the rest as is.
    private var snippet: Text {
        let runs = hit.runs
        if runs.isEmpty { return Text(" ") }
        return runs.reduce(Text(verbatim: "")) { acc, r in
            let t = r.match ? Text(verbatim: r.text).bold().foregroundStyle(WS.ink) : Text(verbatim: r.text)
            return Text("\(acc)\(t)")
        }
    }
}

/// Dates as Telegram shows them in lists: time today, weekday this week, else the date.
enum DSDate {
    static func short(_ d: Date) -> String {
        let cal = Calendar.current
        let f = DateFormatter()
        if cal.isDateInToday(d) {
            f.timeStyle = .short
            f.dateStyle = .none
        } else if let days = cal.dateComponents([.day], from: d, to: Date()).day, days < 7 {
            f.setLocalizedDateFormatFromTemplate("EEE")
        } else if cal.component(.year, from: d) == cal.component(.year, from: Date()) {
            f.setLocalizedDateFormatFromTemplate("d MMM")
        } else {
            f.setLocalizedDateFormatFromTemplate("d MMM yyyy")
        }
        return f.string(from: d)
    }
}
