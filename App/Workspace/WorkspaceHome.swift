import SwiftUI

/// The new tab. One field for the team, a search or an address; the agents' latest words
/// as cards (an approval first); quick tasks; the conversations to go back to and this client's tabs. Every card is
/// an agent's own message from a real conversation - no numbers of ours, no dashboards.
struct WorkspaceHome: View {
    @ObservedObject var ws: WorkspaceModel
    @ObservedObject var browser: BrowserModel
    let go: (String) -> Void
    /// (item 12): the field is the tab's address field on this page - the same model, suggestions and
    /// "@" agent list; Enter opens or searches; only "@Name task" goes to an agent (its composer, unsent).
    @StateObject private var omni = OmniboxModel()
    /// The sky behind the page (time and weather): the header's text colour and the weather after the time.
    @ObservedObject private var sky = SkyModel.shared
    @FocusState private var focus: Bool
    /// Which placeholder shows (they take turns every 2.2 s, cross-fading).
    @State private var hint = 0
    /// The headline's pick for this open of the new tab (HomeGreeting).
    @State private var greetingSeed = Int.random(in: 0..<10_000)
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// The app's theme around Home. Home's own tone is this or the sky's (a dark evening sky is dark in Light too).
    @Environment(\.colorScheme) private var themeScheme
    /// What the field can do, in turns: the team, an agent by name, a search (more of them, faster).
    static let hints = [
        "Search or enter address",
        "@Met write 5 headlines",
        "@Lia find flights Milan\u{2013}Barcelona",
        "Type @ to ask an agent",
        "@Lia yesterday\u{2019}s report",
        "@Met new leads today",
        "@Crea 3 banners for the weekend",
        "@Lia why did CPL change?",
    ]
    /// The blocks the person chose to see (Customise, in the account menu).
    @AppStorage(HomeBlock.brief.key) private var showBrief = true
    @AppStorage(HomeBlock.feed.key) private var showFeed = true
    @AppStorage(HomeBlock.quick.key) private var showQuick = true
    @AppStorage(HomeBlock.conversations.key) private var showConversations = true
    @AppStorage(HomeBlock.tabs.key) private var showTabs = true
    /// Saved tasks show the quick tasks card even before a first conversation.
    @ObservedObject private var saved = SavedPrompts.shared
    /// Agents hidden in this workspace (Settings > Team) leave the team line under the field.
    @ObservedObject private var hiddenAgents = AgentShownStore.shared
    /// The order of the blocks under the field (Customise).
    @AppStorage(HomeBlock.orderKey) private var orderRaw = ""
    /// The page's width (a split pane is narrow; the page drops to one column there).
    @State private var width: CGFloat = 1200
    /// Under ~900 pt: two cards a row, the lists one under the other. Under ~600 pt: one column, smaller type.
    private var narrow: Bool { width < 900 }
    private var compact: Bool { width < 600 }

    var body: some View {
        ScrollView {
            column
                .frame(maxWidth: 1200)
                .padding(.horizontal, compact ? 16 : narrow ? 24 : 40)
                .frame(maxWidth: .infinity)
                // Customise moved to the account menu (under Settings), off the page.
        }
        .scrollIndicators(.hidden)
        .background(GeometryReader { g in
            Color.clear.onAppear { width = g.size.width }.onChange(of: g.size.width) { _, w in width = w }
        })
        // This week's tip in the corner (not in a narrow pane, where it would sit on the headline).
        .overlay(alignment: .topLeading) { if !narrow { HomeTipOfWeek().padding(.top, 18).padding(.leading, 24) } }
        // A living sky for the person's local time and weather (HomeSky), fading to the page's ground.
        .background { HomeSky(themeScheme: themeScheme) }
        .task { SkyModel.shared.start(auth: ws.auth) }
        .modifier(HomeTasks(ws: ws, focus: $focus, hint: $hint, count: Self.hints.count))
        .onChange(of: focus) { _, f in
            if f { ensureEditing() } else if !omni.hoverList { omni.end() }
        }
        .onChange(of: omni.text) { _, t in if focus, !t.isEmpty { ensureEditing() } }
        .onChange(of: ws.sheet) { _, s in if s != nil { omni.end() } }
        // The page left the new tab (an address, a search): the field's key handling stops with it.
        .onDisappear { omni.end() }
        // Every text, card and glass on Home takes the backdrop's tone: light text and dark glass
        // over a dark sky (evening, night, or the app in Dark), dark text and light glass over a light one.
        .environment(\.colorScheme, sky.look.homeDark(themeScheme) ? .dark : .light)
    }

    /// The start tab this page is drawn in (the selected one when it is the start page).
    private var homeTab: BrowserTab? {
        if let t = browser.selected, t.isStart { return t }
        return browser.tabs.first { $0.isStart }
    }

    /// Starts the field's editing (suggestions, keys) without losing what was typed.
    private func ensureEditing() {
        guard omni.editingTab == nil, let t = homeTab else { return }
        let typed = omni.text
        omni.begin(tab: t, browser: browser, ws: ws)
        if !typed.isEmpty { omni.text = typed }
    }

    private var column: some View {
        VStack(spacing: 0) {
            header.padding(.top, compact ? 40 : 70)
            if showBrief { HomeBriefLine(ws: ws, open: { go($0.absoluteString) }) }
            UpdateHomeCard().padding(.top, 18).padding(.horizontal, 24)   // a downloaded update waiting for a restart
            omnibox.padding(.top, 22).zIndex(5)
            team.padding(.top, 12)
            blocks
            Color.clear.frame(height: 140)   // room for the dock
        }
        .onAppear { greetingSeed = Int.random(in: 0..<10_000) }
    }

    /// The blocks under the field in the person's order. Feed and quick tasks share a row of cards when they are next
    /// to each other, conversations and tabs share two columns, as before the order could change.
    private var blocks: some View {
        VStack(spacing: 0) {
            ForEach(Array(HomeSegment.build(visibleOrder).enumerated()), id: \.offset) { _, seg in
                segment(seg)
            }
        }
    }

    /// The movable blocks that show now. Feed and quick tasks wait for a first conversation in this workspace
    /// (no made-up content on an empty new tab); saved tasks show from the start.
    private var visibleOrder: [HomeBlock] {
        HomeBlock.order(orderRaw).filter { b in
            switch b {
            case .feed: return showFeed && hasHistory
            case .quick: return showQuick && hasQuickTasks
            case .conversations: return showConversations
            case .tabs: return showTabs
            case .brief: return false
            }
        }
    }

    /// At least one conversation in this workspace has a message.
    private var hasHistory: Bool {
        if !ws.feed.isEmpty { return true }
        return ws.dialogues.contains { $0.count > 0 }
    }

    private var hasQuickTasks: Bool {
        !saved.list.isEmpty || (hasHistory && !HomeSuggestions.list(for: ws).isEmpty)
    }

    @ViewBuilder private func segment(_ seg: HomeSegment) -> some View {
        switch seg {
        case .cards(let bs):
            cardsBlock(feed: bs.contains(.feed), quick: bs.contains(.quick), quickFirst: bs.first == .quick)
                .tourAnchor("feed").padding(.top, 40)
        case .columns(let bs):
            let layout = narrow ? AnyLayout(VStackLayout(alignment: .leading, spacing: 20)) : AnyLayout(HStackLayout(alignment: .top, spacing: 24))
            layout {
                ForEach(bs) { b in
                    if b == .conversations { conversations } else { tabsColumn }
                }
            }
            .padding(.top, 30)
        }
    }
}

/// A run of blocks drawn together: cards (feed, quick tasks) or columns (conversations, tabs).
enum HomeSegment {
    case cards([HomeBlock])
    case columns([HomeBlock])

    static func build(_ order: [HomeBlock]) -> [HomeSegment] {
        var out: [HomeSegment] = []
        var i = 0
        while i < order.count {
            let b = order[i]
            let next: HomeBlock? = i + 1 < order.count ? order[i + 1] : nil
            let isCard = b == .feed || b == .quick
            let nextSameKind = next.map { ($0 == .feed || $0 == .quick) == isCard } ?? false
            if nextSameKind, let n = next {
                out.append(isCard ? .cards([b, n]) : .columns([b, n]))
                i += 2
            } else {
                out.append(isCard ? .cards([b]) : .columns([b]))
                i += 1
            }
        }
        return out
    }
}

/// The new tab's background work (kept out of the body so the type checker stays quick).
private struct HomeTasks: ViewModifier {
    @ObservedObject var ws: WorkspaceModel
    var focus: FocusState<Bool>.Binding
    @Binding var hint: Int
    let count: Int
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content
        .task(id: ws.profile?.id) { await ws.warmFeed() }
        .onAppear { focus.wrappedValue = true }
        .task {
            // The field takes the keys as soon as the new tab shows (once the window is key).
            try? await Task.sleep(nanoseconds: 150_000_000)
            if ws.sheet == nil { focus.wrappedValue = true }
        }
        .task {
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 2_200_000_000)
                if Task.isCancelled { break }
                if reduceMotion { hint = (hint + 1) % count }
                else { withAnimation(.easeOut(duration: 0.35)) { hint = (hint + 1) % count } }
            }
        }
    }
}

extension WorkspaceHome {

    // MARK: - top

    /// Text over the sky in Home's tone (item 6,: white on a dark sky, also in Light).
    private var ink: HomeInk { HomeInk(dark: sky.look.homeDark(themeScheme)) }

    private var header: some View {
        VStack(spacing: 10) {
            // "Tue 14 Oct · 18:42 · ☀︎ 21° Milan" (the weather replaces the workspace's name, which the
            // window always shows).
            TimelineView(.everyMinute) { tl in
                HStack(spacing: 8) {
                    Text(tl.date.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated)))
                    dot
                    Text(tl.date.formatted(date: .omitted, time: .shortened))
                    if sky.weather != nil {
                        dot
                        HomeWeatherLabel()
                    }
                }
            }
            .font(LiaFont.ui(13)).foregroundStyle(ink.text2)
            .lineLimit(1)
            .animation(.easeOut(duration: 0.3), value: sky.weather?.text)
            Text(HomeGreeting.pick(seed: greetingSeed))
                .font(LiaFont.ui(compact ? 28 : 40, .bold)).foregroundStyle(ink.ink)
                .tracking(compact ? -0.6 : -1.2)
                .lineLimit(compact ? 2 : 1)
                .multilineTextAlignment(.center)
                .minimumScaleFactor(0.7)
                .accessibilityAddTraits(.isHeader)
        }
        .shadow(color: .black.opacity(sky.look.homeDark(themeScheme) ? 0.25 : 0), radius: 8, y: 1)
    }

    private var dot: some View {
        Circle().fill(ink.text3).frame(width: 3, height: 3).accessibilityHidden(true)
    }

    private var omnibox: some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 10, style: .continuous).fill(WS.ink)
                Image(systemName: "sparkle").font(.system(size: 13, weight: .semibold)).foregroundStyle(WS.onInk)
            }
            .frame(width: 30, height: 30)
            if let a = omni.agentChip {
                HStack(spacing: 5) {
                    AgentAvatar(agent: a, size: 18)
                    Text(a.name).font(LiaFont.ui(13, .medium)).foregroundStyle(WS.ink)
                }
                .padding(.horizontal, 7)
                .frame(height: 26)
                .background(WS.soft, in: Capsule())
                .fixedSize()
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(Text("To \(a.name)"))
            }
            if let site = omni.siteSearch { SiteSearchChip(site: site) }
            TextField("", text: $omni.text)
                .textFieldStyle(.plain)
                .font(LiaFont.ui(16))
                .focused($focus)
                .onSubmit(submit)
                .contextMenu { OmniFieldMenu(omni: omni) }
                .background(alignment: .leading) {
                    if omni.text.isEmpty {
                        // The example's "@Lia" is the message box's pill
                        MentionPillText(text: placeholder, font: LiaFont.ui(16), color: ink.text3)
                            .id(placeholder)
                            .transition(.opacity)
                            .allowsHitTesting(false)
                            .accessibilityHidden(true)
                    }
                }
                // "@Lia find flights" - the agent's name as the message box's pill while typing
                .background { AgentMentionFieldPaint(text: omni.text, focused: focus) }
                .accessibilityLabel(Text("Search, enter an address, or @agent and a task"))
            // No "@ agent" / "\u{2318}\u{23CE} search" hint pills; the placeholder tells both.
            Button(action: submit) {
                Image(systemName: "return").font(.system(size: 11, weight: .bold)).foregroundStyle(WS.onInk)
                    .frame(width: 26, height: 22).background(WS.ink, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            }
            .buttonStyle(.liaPlain)
            .accessibilityLabel(Text("Go"))
            // Off under an open conversation: there \u{2318}\u{23CE} approves a red change.
            Button("") { search() }.keyboardShortcut(.return, modifiers: .command).disabled(ws.sheet != nil).opacity(0).frame(width: 0, height: 0)
                .accessibilityHidden(true)
        }
        .padding(.leading, 14).padding(.trailing, 12)
        .frame(maxWidth: 760)
        .frame(height: compact ? 52 : 60)
        // Everything on Home is glass over the sky.
        .homeGlass(RoundedRectangle(cornerRadius: 18, style: .continuous))
        // The address field's suggestions (OmniDropdown), over the blocks below.
        .overlay(alignment: .topLeading) {
            if omni.editingTab != nil, !omni.rows.isEmpty {
                OmniDropdown(omni: omni)
                    .frame(maxWidth: .infinity)
                    .fixedSize(horizontal: false, vertical: true)
                    .offset(y: compact ? 58 : 66)
                    .transition(.opacity)
            }
        }
    }

    /// The rotating hint; with an agent picked, what the field is for now.
    private var placeholder: String {
        if let a = omni.agentChip { return "Task for \(a.name)" }
        if let site = omni.siteSearch { return "Search \(site.name)" }
        return Self.hints[hint]
    }

    private var team: some View {
        HStack(spacing: 8) {
            HStack(spacing: -6) {
                ForEach(ws.shownAgents(ws.roster.filter { !$0.lead })) { a in AgentAvatar(agent: a, size: 18).padding(1.5).background(Circle().fill(WS.avatarRing)) }
            }
            Text("Type @ to give an agent a task").font(LiaFont.ui(12.5)).foregroundStyle(ink.text2)
        }
        // A quiet glass under the line: the sky behind it changes.
        .padding(.leading, 6).padding(.trailing, 10).frame(height: 28)
        .homeGlass(Capsule())
    }

    /// Enter: as in the address field - the highlighted suggestion, else the address or a search; "@Name task" opens
    /// that agent's conversation with the task in its composer (WorkspaceModel.draft).
    private func submit() {
        ensureEditing()
        omni.commit()
    }
    /// \u{2318}Enter: always a web search (or the address).
    private func search() {
        let t = omni.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        omni.end()
        omni.text = ""
        go(t)
    }

    // MARK: - feed

    /// Feed cards and/or the quick tasks card in one row of five.
    private func cardsBlock(feed: Bool, quick: Bool, quickFirst: Bool) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            if feed { feedHeader }
            feedGrid(feed: feed, quick: quick, quickFirst: quickFirst)
        }
    }

    private var feedHeader: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text("Feed").font(LiaFont.ui(15, .semibold)).foregroundStyle(ink.ink).accessibilityAddTraits(.isHeader)
            Text("from your agents").font(LiaFont.ui(12.5)).foregroundStyle(ink.text2)
            Spacer()
            ApprovalsChip(ws: ws)
        }
    }

    private func feedGrid(feed: Bool, quick: Bool, quickFirst: Bool) -> some View {
        let room = compact ? 2 : narrow ? 3 : 5
        let items = feed ? Array(ws.feed.prefix(quick ? room - 1 : room)) : []
        let count = compact ? 1 : narrow ? 2 : 5
        return LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 14, alignment: .top), count: count), spacing: 14) {
            if quick && quickFirst { QuickCard(ws: ws) }
            ForEach(items) { item in FeedCard(ws: ws, item: item) }
            if feed && items.isEmpty { EmptyFeedCard() }
            if quick && !quickFirst { QuickCard(ws: ws) }
        }
    }

    // MARK: - below

    private var conversations: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Continue a conversation").font(LiaFont.ui(13, .semibold)).foregroundStyle(ink.text2).padding(.leading, 12).padding(.bottom, 6)
                .accessibilityAddTraits(.isHeader)
            let list = ws.dialogues.filter { $0.count > 0 }
                .sorted { ($0.last?.ts ?? .distantPast) > ($1.last?.ts ?? .distantPast) }.prefix(4)
            if list.isEmpty { Text("No conversations yet").font(LiaFont.ui(13)).foregroundStyle(ink.text3).padding(.leading, 12) }
            ForEach(Array(list)) { d in DialogueRow(ws: ws, dialogue: d) }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var tabsColumn: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("This client's tabs").font(LiaFont.ui(13, .semibold)).foregroundStyle(ink.text2).padding(.leading, 12).padding(.bottom, 6)
                .accessibilityAddTraits(.isHeader)
            let tabs = browser.tabs.filter { !$0.isStart }.prefix(4)
            if tabs.isEmpty { Text("No open tabs").font(LiaFont.ui(13)).foregroundStyle(ink.text3).padding(.leading, 12) }
            ForEach(Array(tabs)) { t in TabRow(tab: t) { browser.selectedID = t.id } }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - cards

/// Beside the feed: how many changes wait for a Yes (a click opens the approvals list), or "All approved \u{2713}"
/// with a small pop when the last one is answered.
private struct ApprovalsChip: View {
    @ObservedObject var ws: WorkspaceModel
    @State private var popped = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let n = ws.approvals.count
        Group {
            if n > 0 {
                Button { ws.showApprovals = true } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "exclamationmark.circle.fill").font(.system(size: 11, weight: .semibold))
                        Text(n == 1 ? "1 waiting for your Yes" : "\(n) waiting for your Yes")
                    }
                    .font(LiaFont.ui(12, .semibold)).foregroundStyle(WS.amberInk)
                    .padding(.horizontal, 10).frame(height: 26)
                    .background(WS.amberSoft, in: Capsule())
                }
                .buttonStyle(.liaPlain).liaPointer()
                .accessibilityLabel(Text("\(n) changes waiting for your approval"))
                .accessibilityHint(Text("Opens the approvals list"))
            } else {
                HStack(spacing: 5) {
                    Image(systemName: "checkmark.circle.fill").font(.system(size: 11, weight: .semibold))
                        .scaleEffect(popped || reduceMotion ? 1 : 0.4)
                    Text("All approved")
                }
                .font(LiaFont.ui(12, .medium)).foregroundStyle(WS.blue)
                .padding(.horizontal, 10).frame(height: 26)
                .background(WS.blue.opacity(0.10), in: Capsule())
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(Text("All approved. Nothing waits for your approval"))
                .onAppear {
                    guard !reduceMotion else { return }
                    popped = false
                    withAnimation(.spring(response: 0.4, dampingFraction: 0.55).delay(0.1)) { popped = true }
                }
            }
        }
        .transition(.opacity)
    }
}

private struct FeedCard: View {
    @ObservedObject var ws: WorkspaceModel
    let item: WorkspaceModel.FeedItem
    @State private var hover = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                if let a = ws.agent(item.agent) {
                    AgentAvatar(agent: a, size: 22)
                    Text(a.name).font(LiaFont.ui(12, .semibold)).foregroundStyle(WS.ink)
                }
                if item.gate {
                    Text("needs your Yes").font(LiaFont.ui(12, .semibold)).foregroundStyle(WS.amberInk)
                } else if let ts = item.ts {
                    Text(Date(timeIntervalSince1970: ts / 1000).formatted(date: .omitted, time: .shortened)).font(LiaFont.ui(12)).foregroundStyle(WS.text2)
                }
            }
            Text(item.title).font(LiaFont.ui(15, .semibold)).foregroundStyle(WS.ink).lineLimit(3)
            if !item.body.isEmpty {
                Text(item.body).font(LiaFont.ui(13)).foregroundStyle(WS.text2).lineLimit(4)
            }
            Spacer(minLength: 6)
            HStack(spacing: 6) {
                if item.gate {
                    Button("Review") { ws.openDialogue(item.id) }.buttonStyle(WSButtonStyle(primary: true, small: true))
                } else {
                    // Liquid Glass like the rest of Home (was WSButtonStyle's solid surface).
                    Button("Open") { ws.openDialogue(item.id) }.buttonStyle(HomeGlassButtonStyle())
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, minHeight: 196, alignment: .topLeading)
        .homeGlass(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(item.gate ? WS.amberLine : Color.clear, lineWidth: 1))
        .background(item.gate ? RoundedRectangle(cornerRadius: 19, style: .continuous).fill(WS.amberSoft).padding(-3) : nil)
        .shadow(color: Color.black.opacity(hover ? 0.10 : 0.05), radius: hover ? 18 : 10, y: hover ? 8 : 4)
        .onHover { h in withAnimation(.easeOut(duration: 0.15)) { hover = h } }
        .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .onTapGesture { ws.openDialogue(item.id) }
        .liaPointer()
    }
}

/// A secondary button on Home in Liquid Glass (wsGlass: the system glassEffect on macOS 26, the material before it,
/// opaque with Reduce Transparency); the same size as WSButtonStyle(small: true).
private struct HomeGlassButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(LiaFont.ui(12.5, .medium))
            .foregroundStyle(WS.ink)
            .padding(.horizontal, 11)
            .frame(height: 28)
            .wsGlass(12, interactive: true)
            .opacity(configuration.isPressed ? 0.75 : 1)
            .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .liaPointer()
            .modifier(LatencyPressMark(isPressed: configuration.isPressed))
    }
}

private struct EmptyFeedCard: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Nothing from your agents yet").font(LiaFont.ui(15, .semibold)).foregroundStyle(WS.ink)
            Text("Rep writes here every morning and evening. Ask Lia anything in the field above.")
                .font(LiaFont.ui(13)).foregroundStyle(WS.text2)
            Spacer()
        }
        .padding(14)
        .frame(maxWidth: .infinity, minHeight: 196, alignment: .topLeading)
        .homeGlass(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}

/// Tasks a click away: each goes to the team chat as the person's own message. the person's saved prompts
/// always first (chips; rename/delete in their menu), then the team's suggestions (HomeSuggestions, empty until the
/// next round; no made-up defaults).
private struct QuickCard: View {
    @ObservedObject var ws: WorkspaceModel
    @ObservedObject private var saved = SavedPrompts.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                if let lia = ws.roster.first(where: { $0.lead }) { AgentAvatar(agent: lia, size: 22).accessibilityHidden(true) }
                Text("Quick tasks").font(LiaFont.ui(12, .semibold)).foregroundStyle(WS.ink).accessibilityAddTraits(.isHeader)
            }
            ForEach(saved.list) { p in SavedPromptChip(prompt: p) { ws.askTeam(p.text) } }
            ForEach(HomeSuggestions.list(for: ws), id: \.0) { t in QuickTaskRow(title: t.0) { ws.askTeam(t.1) } }
        }
        .padding(14)
        .frame(maxWidth: .infinity, minHeight: 196, alignment: .topLeading)
        .homeGlass(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}

private struct QuickTaskRow: View {
    let title: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack {
                Text(title).font(LiaFont.ui(13)).foregroundStyle(WS.ink).multilineTextAlignment(.leading)
                Spacer(minLength: 6)
                Image(systemName: "arrow.right").font(.system(size: 11, weight: .semibold)).foregroundStyle(WS.text2)
                    .accessibilityHidden(true)
            }
            .padding(.horizontal, 10).padding(.vertical, 8)
            // ("a crude solid plate behind the text"): the same Liquid Glass as the dock that holds
            // the Inbox (wsGlass: the system glassEffect on macOS 26, the material before it, opaque with Reduce
            // Transparency). Was WS.soft.
            .wsGlass(10, interactive: true)
            .contentShape(Rectangle())
        }
        .buttonStyle(.liaPlain)
        .liaPointer()
        .accessibilityLabel(Text(title))
        .accessibilityHint(Text("Sends this task to Lia"))
    }
}

private struct DialogueRow: View {
    @ObservedObject var ws: WorkspaceModel
    let dialogue: DialogueSummary
    @State private var hover = false

    private var agentId: String { dialogue.isTeam ? "lia" : dialogue.dlg }

    var body: some View {
        Button { ws.openDialogue(dialogue.dlg) } label: {
            HStack(spacing: 12) {
                Group {
                    if let a = ws.agent(agentId) { AgentAvatar(agent: a, size: 26).padding(1.5).background(Circle().fill(WS.avatarRing)) }
                }
                .frame(width: 48, alignment: .leading)
                VStack(alignment: .leading, spacing: 2) {
                    Text(ws.dialogueTitle(dialogue.dlg)).font(LiaFont.ui(13.5, .semibold)).foregroundStyle(WS.ink)
                    Text(lastLine).font(LiaFont.ui(12.5)).foregroundStyle(WS.text2).lineLimit(1)
                }
                Spacer()
                if ws.unread(dlg: dialogue.dlg) { Circle().fill(WS.red).frame(width: 8, height: 8) }
                if let ts = dialogue.last?.ts {
                    Text(ts.formatted(.relative(presentation: .named)))
                        .font(LiaFont.ui(12)).foregroundStyle(WS.text2)
                }
            }
            .padding(.horizontal, 12).padding(.vertical, 9)
            .background(hover ? WS.hover : Color.clear, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.liaPlain)
        .onHover { hover = $0 }
        .liaPointer()
    }

    private var lastLine: String {
        if let c = ws.chatIfOpen(dialogue.dlg), let last = c.items.last {
            let who = last.agent.flatMap { ws.agent($0)?.name } ?? "You"
            return who + ": " + FeedText.plain(last.message.content).replacingOccurrences(of: "\n", with: " ")
        }
        guard let last = dialogue.last else { return ws.agent(agentId)?.shownRole ?? "" }
        let who = last.role == .user ? "You" : (ws.agent(last.agent ?? agentId)?.name ?? "")
        return who + ": " + FeedText.plain(last.text).replacingOccurrences(of: "\n", with: " ")
    }
}

private struct TabRow: View {
    @ObservedObject var tab: BrowserTab
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Group {
                    if let f = tab.favicon { Image(nsImage: f).resizable().interpolation(.high) }
                    else { Image(systemName: "globe").resizable().foregroundStyle(WS.text3) }
                }
                .frame(width: 18, height: 18)
                .padding(5)
                .background(WS.soft, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                VStack(alignment: .leading, spacing: 2) {
                    Text(tab.displayTitle).font(LiaFont.ui(13.5, .semibold)).foregroundStyle(WS.ink).lineLimit(1)
                    Text(tab.url?.host ?? "").font(LiaFont.ui(12.5)).foregroundStyle(WS.text2).lineLimit(1)
                }
                Spacer()
            }
            .padding(.horizontal, 12).padding(.vertical, 9)
            .background(hover ? WS.hover : Color.clear, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.liaPlain)
        .onHover { hover = $0 }
        .liaPointer()
    }
}
