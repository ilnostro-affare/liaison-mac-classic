import SwiftUI
import WebKit

/// A conversation over the page: the thread on the left, the browser of the agent at work on the right
/// (its own tabs, the profile's sign-ins). The mode picker shows only where Met (the write agent) takes part.
/// One agent's endless dialogue (or Team); the magnifier opens the dialogue search and the agent's name or
/// Figure its profile, each as a 340 pt column on the right. \u{2318}F still finds on the loaded page.
struct ConversationSheet: View {
    @ObservedObject var ws: WorkspaceModel
    @ObservedObject var chat: TeamChatModel
    /// The agents that drove a browser here, and who is at work (debounced between tasks).
    @ObservedObject private var recent = AgentBrowserRecent.shared
    /// The Canvas (Dev's site, later documents and designs): while open it takes the agent browser's place.
    @ObservedObject private var canvas = CanvasStore.shared
    /// 10-21: a document opened from the composer's chips shows on the right (ComposerFileOverlay).
    @ObservedObject private var composerFile = ComposerFileViewer.shared
    /// (light): the header's figures rise and fade in when the sheet opens.
    @State private var appeared = false
    /// The conversation's search; /17: the person's tapbacks and pins (on the server).
    @StateObject private var search = ChatSearch()
    /// Per conversation, kept for the app's life: switching conversations in the open sheet picks the right one
    /// without re-creating the sheet.
    @ObservedObject private var local: ChatLocal
    /// The right column: the dialogue search or the agent's profile (nil: the agent's browser alone).
    enum SidePanel { case search, profile }
    @State private var panel: SidePanel?
    /// Whose profile the profile column shows: an agent whose figure was clicked in the thread (nil: the dialogue's).
    @State private var profileDlg: String?
    /// How far the grabber pulls the sheet down.
    @State private var pull: CGFloat = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// 8b: the dialogue rail on the left shows names and roles (else the figures alone).
    @AppStorage("lia_ws_dialogue_rail_wide") private var railWide = false
    /// "What did Dev do?" from the Canvas's Activity.
    @State private var devLog = false
    /// The agent's browser pane is built after the sheet's slide-in (it is the heaviest part to make).
    @State private var paneReady = false
    /// The cold thread allowed in (ThreadHostCache key), a frame after the sheet's first (threadColumn).
    @State private var coldReady: String?
    /// a page over the messenger, the sheet's own size (the branch chip's GitHub page).
    @State private var webPopup: URL?
    /// The kept thread's own hosting view inherits nothing: the app model goes in by hand (keptRoot).
    @EnvironmentObject private var app: AppModel
    /// The right side (the agent's browser or the Canvas) folded to a spine, per conversation, in memory.
    @ObservedObject private var fold = PaneFoldStore.shared
    /// The spine's leading edge lit in the agent's colour just before it unfolds by itself.
    @State private var spineFlash = false
    /// The right side's last unfolded width; folded, the pane keeps it (mounted, hidden behind the spine).
    /// A box, not a published value: noting the width while the window resizes re-renders nothing.
    @State private var paneWidth = PaneWidthBox()

    init(ws: WorkspaceModel, chat: TeamChatModel) {
        _ws = ObservedObject(wrappedValue: ws)
        _chat = ObservedObject(wrappedValue: chat)
        _local = ObservedObject(wrappedValue: ChatLocal.shared(chat.key))
    }

    /// The dialogue's own client (its agents' browsers and logs live under it), else the one in front.
    private var dialogueProfile: CompanyProfile? { ws.profiles.first { $0.id == chat.profile } ?? ws.profile }

    /// Whose browser the right side shows: the dialogue's own agent's, always ("each agent's
    /// dialogue shows only its own browser"). Before, Team showed the browser of whoever spoke last or drove one there -
    /// Met's after his acknowledgement of an @Met, and nothing at all when the last speaker was off the roster (a retired
    /// Rep or Seara in an old dialogue): with no pane the columns were narrower than the card and it centred them.
    private var shownAgent: String { AgentPaneChoice.shown(dlg: chat.dlg) }

    /// The shown agent as drawn: the roster's, else the app's own list (an agent this account's roster leaves out still
    /// gets its pane).
    private var shownInfo: AgentInfo? { AgentInfo.lookup(shownAgent, in: ws.roster) }

    /// "Open <Agent>'s Browser": this dialogue's own agent is on the right already; a teammate's browser is in
    /// the teammate's dialogue, which opens.
    private func openBrowser(of agent: String) {
        let d = AgentPaneChoice.owner(agent: agent)
        if d == chat.dlg {
            if canvas.state(chat.key) != nil { closeCanvas() }
        } else {
            ws.openDialogue(d)
        }
    }

    /// Esc stops a running answer or the agent's browser work before it closes the sheet.
    private var running: Bool { chat.busy || chat.webAgent != nil }

    // Split in steps (card, columns, thread pane): one long expression was too much for the type checker.
    var body: some View {
        card
            .overlay { webPopupLayer }
            .overlay(alignment: .top) { ChatGrabber(pull: $pull, onClose: close).padding(.top, 3) }
            // A click outside the messenger closes it and does nothing else (the click is used up).
            .background(SheetOutsideClick(onOutside: closeFromOutside))
            .shadow(color: Color.black.opacity(0.22), radius: 40, y: 20)
            .offset(y: pull)
            .opacity(pullOpacity)
            .background { escapeKeys }
            .background { foldKey }
            .latencyAppear("Conversation")   // the canary's click latency: a click to the messenger's first frame
        // Keyed by the conversation: the sheet stays open while the list or the dock switches what it shows.
        .task(id: chat.key) {
            // Dev's turns go on on the server while the app is away (each step stored): a dialogue opened
            // again shows what was done meanwhile.
            // A thread already in memory draws at once; its refresh waits for the slide-in (an
            // answer arriving mid-slide laid the thread out again under the animation).
            if chat.loaded {
                try? await Task.sleep(nanoseconds: UInt64(ThreadColumn.slideIn * 1_000_000_000))
                guard !Task.isCancelled else { return }
                await chat.refreshLatest()
            } else { await chat.load() }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            Task { await chat.refreshLatest() }
        }
        // The person's marks (verdicts, favourites, pins) from the server, read each time it opens.
        .task(id: chat.key) {
            try? await Task.sleep(nanoseconds: UInt64(ThreadColumn.slideIn * 1_000_000_000))
            guard !Task.isCancelled else { return }
            await ChatLocal.shared(chat.key).load(auth: chat.auth)
        }
        // Like Claude: a preview arriving live in the dialogue in front opens the Canvas (reloads it when open).
        .onReceive(NotificationCenter.default.publisher(for: .liaCanvasArrived)) { n in
            guard let key = n.userInfo?["key"] as? String, key == chat.key, let item = n.userInfo?["item"] as? CanvasItem else { return }
            showCanvas(item, arriving: true)
            autoUnfold(.canvasArrived)   // A preview, document or file arriving unfolds the right side
        }
        // Dev's first step of a turn in the dialogue in front opens the Canvas on its Activity.
        .onReceive(NotificationCenter.default.publisher(for: .liaCanvasActivity)) { n in
            guard let key = n.userInfo?["key"] as? String, key == chat.key else { return }
            let p = n.userInfo?["profile"] as? String
            canvas.note(chat)
            // Dev's Activity steps never unfold the right side; folded, they count on the spine.
            if paneFolded { fold.countStep(key) }
            if reduceMotion { canvas.showActivity(key: key, profile: p) } else {
                withAnimation(.easeOut(duration: 0.2)) { canvas.showActivity(key: key, profile: p) }
            }
        }
        .liaModal(isPresented: $devLog) {
            ChatAgentLogSheet(name: ws.agent("dev")?.name ?? "Dev", entries: [],
                              history: dialogueProfile.flatMap { AgentHistoryStore.shared(for: ws.agentBrowser("dev", in: $0)) },
                              work: ChatAgentLogSheet.WorkSource(auth: chat.auth, profile: chat.profile, dlg: "dev")) { devLog = false }
        }
        // An approval opening here unfolds the right side; so does a composer file the person opens.
        .onChange(of: chat.openGate?.item.id) { _, id in if id != nil { autoUnfold(.gateOpened) } }
        .onChange(of: composerFile.item != nil) { _, on in if on && paneFolded { setFolded(false) } }
        .onChange(of: chat.key) { _, _ in
            spineFlash = false
            AgentOpenTrace.shared.sheetVisible(chat.dlg)
            webPopup = nil
            ComposerFileViewer.shared.close()   // the file belonged to the other conversation's composer
            profileDlg = nil
            if search.open { search.close() }
        }
        .holdsComposerFiles()
        .onAppear {
            // the open's timing (AgentOpenTrace): a click the dock did not see starts it here
            AgentOpenTrace.shared.sheetVisible(chat.dlg)
            if reduceMotion { appeared = true } else { withAnimation(.spring(response: 0.35, dampingFraction: 0.85).delay(0.05)) { appeared = true } }
        }
        .task {
            guard !paneReady else { return }
            try? await Task.sleep(nanoseconds: UInt64(ThreadColumn.slideIn * 1_000_000_000))
            var t = Transaction()
            t.disablesAnimations = true
            withTransaction(t) { paneReady = true }
        }
        // What the dialogue's blocks say about its branches (repository, the turn's preview), for the
        // branch chips in its text and their cards; after the slide-in, and again as messages come in.
        .task(id: chat.key + "|" + String(chat.items.count)) {
            try? await Task.sleep(nanoseconds: UInt64(ThreadColumn.slideIn * 1_000_000_000))
            guard !Task.isCancelled else { return }
            GitHubRefCache.shared.learn(chat.items.map { GitHubDialogue.Entry(run: $0.run, blocks: $0.message.blocks,
                                                                               text: $0.agent == nil ? "" : $0.message.content) },
                                        profile: chat.profile)
        }
        // \u{2318}F from the menu while this conversation is open.
        .onChange(of: ws.chatFind) { _, _ in openSearch() }
    }

    private var card: some View {
        VStack(spacing: 0) {
            header
            Divider().overlay(WS.line)
            // Pinned to the leading edge: a dialogue whose columns are narrower than the card (no pane on the right)
            // keeps the rail at the left edge instead of being centred under the header.
            columns.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .background(WS.surface, in: RoundedRectangle(cornerRadius: 30, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 30, style: .continuous).stroke(WS.line, lineWidth: 1))
        .clipShape(RoundedRectangle(cornerRadius: 30, style: .continuous))
    }

    /// The sheet fades a little as it is pulled down.
    private var pullOpacity: Double {
        guard pull > 0 else { return 1 }
        let fade: Double = 1 - Double(pull) / 500
        return max(0.5, fade)
    }

    private var columns: some View {
        HStack(spacing: 0) {
            DialogueRail(ws: ws, current: chat.dlg, wide: railWide, onToggle: toggleRail)
            Divider().overlay(WS.line)
            threadPane
            Divider().overlay(WS.line)
            // The right side takes what is left and never more. A pane whose own minimum (a header of
            // fixed-size buttons, a page) was wider made the columns wider than the card, which centred them and cut
            // the thread at the left. Group: the frame and the clip go on whichever pane is shown.
            // Folded, the right side is a 54 pt spine and the thread takes the width.
            // (the fold lagged): the pane stays mounted in the same place, so unfolding rebuilds nothing
            // (no web view re-adopted); folded it keeps its last full width (FullHDHostView never gets a tiny width),
            // hidden and clipped behind the spine.
            ZStack(alignment: .topLeading) {
            Group {
            if let cs = canvas.state(chat.key) {
                CanvasPane(state: cs, auth: ws.auth,
                           onTab: { [canvas, key = chat.key] t in canvas.update(key) { $0.tab = t } },
                           onMobile: { [canvas, key = chat.key] m in canvas.update(key) { $0.mobile = m } },
                           onReload: { [canvas, key = chat.key] in canvas.update(key) { $0.reloads += 1 } },
                           onOpenInBrowser: { openPreviewInBrowser($0) },
                           onClose: { closeCanvas() },
                           activity: chat.devActivity, working: chat.busy && chat.liveAgent == "dev",
                           onHistory: { devLog = true },
                           onLive: { [canvas, key = chat.key] on in canvas.setLive(on, key: key) },
                           titleInSheet: true, onFold: { setFolded(true) })
                    // Dev's words in the Activity: links and site chips go where the thread's go
                    .environment(\.openURL, OpenURLAction { url in route(url) })
                    .transition(.opacity)
            } else if let p = dialogueProfile, let a = shownInfo {
                // ("opening an agent is slow"): the agent's browser (its model, a web view - Met's loads
                // Ads Manager) is made once the slide-in is over; until then its empty ground stands in its place.
                if paneReady {
                    AgentBrowserPane(agent: a, browser: ws.agentBrowser(a.id, in: p), status: chat.webAgent == a.id ? chat.webStatus : "",
                                     running: chat.webAgent == a.id || recent.isBusy(chat.key, a.id), onTakeOver: { chat.stop() },
                                     onOpenInMain: { openInMain($0) }, items: chat.items,
                                     seenChat: chat, seenName: chat.isTeam ? "Lia" : (ws.agent(chat.agentId)?.name ?? a.name),
                                     onFold: { setFolded(true) })
                        .transition(.opacity)
                } else {
                    Color.dyn(0x15181C, 0xF6F7F9).frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            } else if composerFile.item != nil {
                // No pane on the right: a composer file opens one of its own (the overlay below draws the file).
                Color.dyn(0x15181C, 0xF6F7F9).frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            }
            .frame(minWidth: 0, maxWidth: .infinity, maxHeight: .infinity)
            .clipped()
            // CanvasPane carries its own; the agent's browser and the file's own right side carry this one.
            .overlay { if canvas.state(chat.key) == nil { ComposerFileOverlay(auth: ws.auth) } }
            .background {
                GeometryReader { g in
                    Color.clear
                        .onAppear { notePaneWidth(g.size.width) }
                        .onChange(of: g.size.width) { _, w in notePaneWidth(w) }
                }
            }
            .frame(width: paneFolded ? max(paneWidth.width, 460) : nil)
            .opacity(paneFolded ? 0 : 1)
            .allowsHitTesting(!paneFolded)
            .accessibilityHidden(paneFolded)
            if paneFolded {
                foldSpine
            }
            }
            .frame(minWidth: paneFolded ? 54 : 0, maxWidth: paneFolded ? 54 : CGFloat.infinity, maxHeight: .infinity,
                   alignment: .topLeading)
            .clipped()
            sidePanel
        }
    }

    /// The search or the profile column (340 pt; the panels size themselves).
    @ViewBuilder private var sidePanel: some View {
        switch panel {
        case .search:
            Divider().overlay(WS.line)
            DialogueSearchPanel(ws: ws, profile: chat.profile, dlg: chat.dlg, onJump: { hit in jump(to: hit) }, onClose: { setPanel(nil) })
                .frame(width: 340)
                .transition(.move(edge: .trailing))   // no fade: fading a text field renders offscreen every frame
        case .profile:
            Divider().overlay(WS.line)
            // The header's "\u{2026}" menu (Export) lives in the profile, beside its close.
            AgentProfilePanel(ws: ws, profile: chat.profile, dlg: profileDlg ?? chat.dlg, onJump: { id in jumpFromProfile(id) },
                              onClose: { setPanel(nil) }, onExport: { export(pdf: $0) },
                              onOpenLink: { openProfileLink($0) },
                              onOpenDevFile: { openDevFile($0) },
                              onOpenDevPreview: { u, title in
                                  showCanvas(CanvasItem(kind: .devPreview, title: title, url: u, profile: chat.profile))
                              })
                .id(profileDlg ?? chat.dlg)
                .frame(width: 340)
                .transition(.move(edge: .trailing).combined(with: .opacity))
        case nil:
            EmptyView()
        }
    }

    /// A search hit: another dialogue's opens in this sheet at the hit; this one's scrolls to it.
    private func jump(to hit: SearchHit) {
        if hit.dlg == chat.dlg { chat.jump(to: hit.id) } else { ws.openDialogue(hit.dlg, jumpTo: hit.id) }
    }

    /// A message picked in the profile: in this dialogue's profile it scrolls there; in another agent's, that dialogue
    /// opens at it.
    private func jumpFromProfile(_ id: String) {
        if let d = profileDlg, d != chat.dlg { ws.openDialogue(d, jumpTo: id) } else { chat.jump(to: id) }
    }

    /// A click on an agent's figure in the thread: that agent's profile (again: it closes).
    private func openProfile(ofAgent id: String) {
        let d = DialogueSummary.dlg(forAgent: id)
        if panel == .profile && (profileDlg ?? chat.dlg) == d { setPanel(nil); return }
        profileDlg = d == chat.dlg ? nil : d
        if panel != .profile { setPanel(.profile) }
    }

    private func toggleRail() {
        if reduceMotion { railWide.toggle() } else { withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) { railWide.toggle() } }
    }

    private func setPanel(_ p: SidePanel?) {
        let next: SidePanel? = panel == p ? nil : p
        if reduceMotion { panel = next } else { withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) { panel = next } }
    }

    /// Another conversation picked: its thread replaces the one shown in the same frame. 
    /// the 0.18 s crossfade showed the previous dialogue's last messages over the new one ("an old message flashes").
    private var threadPane: some View {
        ZStack {
            threadColumn
                .id(chat.key)
                // With the right side folded the rows (and the composer) stay a readable column
                .frame(maxWidth: paneFolded ? 720 : CGFloat.infinity)
        }
            .frame(minWidth: paneFolded ? 0 : 460, idealWidth: 460, maxWidth: paneFolded ? CGFloat.infinity : 460)
            .overlay { ChatConfetti(trigger: chat.celebrate, color: celebrateColor) }
            // Links in the conversation open in Peek (\u{2318}-click: a new tab).
            .environment(\.openURL, OpenURLAction { url in route(url) })
            // Dev's Preview card: its Open opens the Canvas on the right.
            .environment(\.devPreviewOpen, devPreviewAction)
    }

    /// Dev's Preview card and a block's Open: the Canvas on the right.
    private var devPreviewAction: DevPreviewOpenAction {
        DevPreviewOpenAction(run: { preview in showCanvas(CanvasItem(preview: preview, profile: chat.profile)) },
                             block: { b in
            if let item = CanvasItem(block: b, profile: chat.profile) { showCanvas(item) }
        })
    }

    /// ("re-open instant"): each dialogue's thread is kept (ThreadHostCache): opened again it is the same
    /// view - rows, text views, scroll position - and only the newest messages are fetched behind it.
    /// (feedback: "still a delay on open"): a thread never built yet (cold) is built one frame after
    /// the sheet's own: the click's frame carries the card (header, rail, an empty column), the next one the whole
    /// thread at its end. Before, the first frame waited for every row's layout. No veil, no fade: the rows simply are
    /// there in the frame after. A kept thread shows in the first frame as before.
    @ViewBuilder private var threadColumn: some View {
        if ThreadHostCache.enabled {
            let key = ThreadHostCache.key(chat)
            if coldReady == key || ThreadHostCache.shared.has(key) {
                KeptThread(key: key, root: keptRoot())
            } else {
                Color.clear
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .onAppear { buildCold(key) }
            }
        } else if coldReady == ThreadHostCache.key(chat) {
            column(life: ThreadLife.unkept)
        } else {
            // Built anew on every open (the kept thread is off), still a frame after the sheet's own
            Color.clear
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .onAppear { buildCold(ThreadHostCache.key(chat)) }
        }
    }

    /// The cold thread goes in on the main loop's next pass, after the sheet's frame was committed, untouched by the
    /// sheet's slide (no animation in its transaction).
    private func buildCold(_ key: String) {
        DispatchQueue.main.async {
            var t = Transaction()
            t.disablesAnimations = true
            withTransaction(t) { coldReady = key }
        }
    }

    private func column(life: ThreadLife) -> ThreadColumn {
        ThreadColumn(ws: ws, chat: chat, search: search, local: local, onOpenBrowser: { openBrowser(of: $0) }, onClose: close,
                     onOpenAgent: { openProfile(ofAgent: $0) }, life: life)
    }

    /// The kept column with what the sheet around it gives (a hosting view of its own inherits none of it).
    private func keptRoot() -> AnyView {
        let life: ThreadLife = ThreadHostCache.shared.life(ThreadHostCache.key(chat))
        let col: ThreadColumn = column(life: life)
        let link = OpenURLAction { url in route(url) }
        let wired = col
            .environment(\.openURL, link)
            .environment(\.devPreviewOpen, devPreviewAction)
            .environment(\.liaTipLayer, 10)
            .environmentObject(app)
            .environmentObject(chat.auth)
        return AnyView(wired)
    }

    /// The Canvas on the right, in the agent browser's place (the same page again: it reloads). `arriving`: a
    /// preview that came live, shown on Preview whatever tab was in front.
    private func showCanvas(_ item: CanvasItem, arriving: Bool = false) {
        let key = chat.key
        canvas.note(chat)
        let go = { if arriving { canvas.arrive(item, key: key) } else { canvas.open(item, key: key) } }
        if reduceMotion { go() } else { withAnimation(.easeOut(duration: 0.2)) { go() } }
    }

    /// A click outside the sheet (SheetOutsideClick): only while nothing of ours floats over it (a popup, Peek,
    /// the palette, a menu), so those keep their own clicks.
    private func closeFromOutside() -> Bool {
        guard ws.sheet != nil, ws.peek == nil, ws.palette == nil, ws.switcher == nil,
              !LiaModalCenter.shared.isOpen, !DropdownHost.shared.isOpen else { return false }
        close()
        return true
    }

    private func closeCanvas() {
        let key = chat.key
        if reduceMotion { canvas.close(key) } else { withAnimation(.easeOut(duration: 0.2)) { canvas.close(key) } }
    }

    /// The Canvas's "Open in browser": a new, selected tab of the person's main browser (the
    /// workspace's tab strip), not Dev's browser on the right; the sheet steps aside.
    private func openPreviewInBrowser(_ url: URL) {
        DevPreviewOpener.openAsTab(url)
    }

    /// The page over the messenger, with the dialogue's workspace sign-ins (its browser's data store: GitHub's cookies).
    @ViewBuilder private var webPopupLayer: some View {
        if let u = webPopup {
            SheetWebPopup(url: u, account: popupAccount, title: canvas.state(chat.key)?.item.title ?? (u.host ?? ""),
                          onOpenAsTab: { url in
                              webPopup = nil
                              ws.currentBrowser?.open(url)
                          },
                          onClose: closeWebPopup)
                .transition(.opacity)
        }
    }

    /// The data store the workspace's own browser uses (never the Liaison session, never the main window's tabs).
    private var popupAccount: String? { dialogueProfile.map { ws.storeKey(for: $0) } }

    private func openWebPopup(_ url: URL) {
        if reduceMotion { webPopup = url } else { withAnimation(.easeOut(duration: 0.18)) { webPopup = url } }
    }

    private func closeWebPopup() {
        if reduceMotion { webPopup = nil } else { withAnimation(.easeOut(duration: 0.15)) { webPopup = nil } }
    }

    /// A file of Dev's project picked in Dev's profile (Files): the Canvas shows it on Code, "All files".
    private func openDevFile(_ path: String) {
        let key = chat.key, profile = chat.profile
        if reduceMotion { canvas.focusFile(path, profile: profile, key: key) } else {
            withAnimation(.easeOut(duration: 0.2)) { canvas.focusFile(path, profile: profile, key: key) }
        }
    }

    /// A link from the agent's profile (Links): that agent's browser loads it (a tab already on it comes to the front)
    /// and shows it on the right of that agent's own dialogue (a teammate's profile opens the
    /// teammate's dialogue); without a workspace or an agent, the default browser.
    private func openProfileLink(_ url: URL) {
        let dlg = profileDlg ?? chat.dlg
        let agent = DialogueSummary.agent(forDlg: dlg)
        guard let p = dialogueProfile, ws.agent(agent) != nil else { NSWorkspace.shared.open(url); return }
        DevPreviewOpener.open(url, in: ws.agentBrowser(agent, in: p))
        openBrowser(of: agent)
    }

    // MARK: the right side folded

    /// Something on the right to fold: the Canvas or the agent's browser.
    private var canFold: Bool { canvas.state(chat.key) != nil || (dialogueProfile != nil && shownInfo != nil) }
    private var paneFolded: Bool { canFold && fold.isFolded(chat.key) }

    /// The widths switch in one transaction with no animation (a spring on the thread's width laid
    /// out every message row each frame); only the spine fades and slides in by itself (FoldSpine).
    private func setFolded(_ on: Bool, key: String? = nil) {
        let k = key ?? chat.key
        var t = Transaction()
        t.disablesAnimations = true
        withTransaction(t) {
            spineFlash = false
            fold.set(on, key: k)
        }
    }

    /// The unfolded pane's width, kept for the fold (a folded pane reports the frozen width back: ignored).
    private func notePaneWidth(_ w: CGFloat) {
        guard !paneFolded, w > 1 else { return }
        paneWidth.width = w
    }

    private func toggleFold() {
        guard canFold else { return }
        setFolded(!paneFolded)
    }

    /// Something new on the right unfolds it (not in the 2 s after the person folded it, never on Activity steps);
    /// the spine's edge lights up in the agent's colour first.
    private func autoUnfold(_ t: PaneFold.Trigger) {
        let key = chat.key
        guard !spineFlash, PaneFold.autoUnfolds(t, folded: paneFolded, sinceFold: fold.sinceFold(key)) else { return }
        if reduceMotion { setFolded(false, key: key); return }
        withAnimation(.easeOut(duration: 0.15)) { spineFlash = true }
        // the person's own fold or unfold in between ends the flash, and wins
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { if spineFlash || chat.key != key { setFolded(false, key: key) } }
    }

    /// The spine: the agent, its browser's tabs and page (or the Canvas's title), the steps that came while folded.
    @ViewBuilder private var foldSpine: some View {
        let a = shownInfo
        let cs = canvas.state(chat.key)
        let browserRunning = a.map { chat.webAgent == $0.id || recent.isBusy(chat.key, $0.id) } ?? false
        FoldSpine(agent: a, browser: cs == nil ? spineBrowser : nil, canvasTitle: cs?.item.title,
                  running: cs == nil ? browserRunning : (chat.busy || browserRunning),
                  steps: fold.steps[chat.key] ?? 0, flash: spineFlash,
                  onUnfold: { setFolded(false) }, onNewPlace: { autoUnfold($0) })
    }

    /// The shown agent's browser for the spine, once the pane would have been built (paneReady).
    private var spineBrowser: BrowserModel? {
        guard paneReady, let p = dialogueProfile, let a = shownInfo else { return nil }
        return ws.agentBrowser(a.id, in: p)
    }

    /// \u{2318}\u{2325}B folds or unfolds the right side while the sheet is in front.
    @ViewBuilder private var foldKey: some View {
        if canFold {
            Button("") { toggleFold() }
                .keyboardShortcut("b", modifiers: [.command, .option])
                .opacity(0).frame(width: 0, height: 0)
                .accessibilityHidden(true)
        }
    }

    /// Esc: closes the search first, then stops what runs, then (the close button) closes the sheet.
    @ViewBuilder private var escapeKeys: some View {
        if search.open {
            Button("") { search.close() }
                .keyboardShortcut(.cancelAction)
                .opacity(0).frame(width: 0, height: 0)
                .accessibilityHidden(true)
        } else {
            Button("") { chat.stop() }
                .keyboardShortcut(running ? KeyboardShortcut.cancelAction : nil)
                .opacity(0).frame(width: 0, height: 0)
                .accessibilityHidden(true)
        }
    }

    /// The grabber dragged down, or Esc, closes the sheet (a scroll in the thread never does).
    private func close() {
        if reduceMotion { ws.sheet = nil } else { withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) { ws.sheet = nil } }
    }

    /// Http(s) links go to Peek; with \u{2318} held, to a new tab of the workspace's browser.
    private func route(_ url: URL) -> OpenURLAction.Result {
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else { return .systemAction }
        // One of Dev's sites (or its preview) named in the text opens in the Canvas, on Live.
        if !NSEvent.modifierFlags.contains(.command), !chat.profile.isEmpty,
           DevSites.isPrivatePreview(url) || DevSites.siteURL(url.absoluteString) != nil {
            let live = !DevSites.isPrivatePreview(url)
            showCanvas(CanvasItem(kind: .devPreview, title: live ? "Live site" : "Preview", url: url, profile: chat.profile)
                .withPrivatePage(chat.latestDevPage))
            return .handled
        }
        if NSEvent.modifierFlags.contains(.command), let b = ws.currentBrowser {
            b.open(url)
            ws.show("Opened in a new tab", symbol: "plus.square.on.square")
        } else {
            ws.peek = url
        }
        return .handled
    }

    /// The burst takes the colour of the agent that succeeded.
    private var celebrateColor: Color { Color(hex: ws.agent(chat.celebrateAgent ?? shownAgent)?.colorHex ?? 0x3B5BFD) }

    /// The conversation as Markdown or PDF.
    private func export(pdf: Bool) {
        let lines = ChatExport.lines(chat) { ws.agent($0)?.name ?? ($0 ?? "Agent").capitalized }
        var name = title
        if let p = ws.profile { name = "\(title) \u{00b7} \(p.name)" }
        let ok = pdf ? ChatExport.savePDF(title: name, lines: lines) : ChatExport.saveMarkdown(title: name, lines: lines)
        if ok { ws.show(pdf ? "Exported as PDF" : "Exported as Markdown", symbol: "square.and.arrow.up") }
    }

    /// The page the agent was on opens in the workspace's own browser, and the sheet steps aside.
    private func openInMain(_ url: URL) {
        guard let b = ws.currentBrowser else { return }
        b.open(url)
        ws.sheet = nil
    }

    private func openSearch() {
        if reduceMotion { search.open = true } else { withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) { search.open = true } }
    }

    private var header: some View {
        HStack(spacing: 12) {
            identity
            // Dev's dialogue shows its cloud (internet, keys, sites). The other agents show nothing there
            // (the workspace chip told nothing - the window already says which workspace it is).
            if chat.isDev, !search.open {
                DevCloudCell(profile: chat.profile, auth: chat.auth)
            }
            Spacer()
            // The Canvas's title (a branch path) and Open on GitHub sit here, not over its tabs.
            if !search.open, let cs = canvas.state(chat.key) {
                CanvasHeaderCrumb(item: cs.item, onOpenInBrowser: { openWebPopup($0) })
                    .transition(.opacity)
            }
            if search.open {
                ChatSearchField(search: search, count: search.hits(in: local.visible(chat.threadItems)).count)
                    .id(ws.chatFind)
                    .transition(.opacity.combined(with: .scale(scale: 0.96, anchor: .trailing)))
            } else {
                headerIcon("magnifyingglass", label: "Search messages", active: panel == .search, action: { setPanel(.search) })
            }
            // One glass mode control in the header for every agent with modes (Team, Met, Dev).
            if chat.hasWriter {
                GlassModeControl(options: Self.approvalModes, selection: $chat.mode, name: "Approval mode")
            } else if chat.isDev {
                GlassModeControl(options: Self.devModes, selection: $chat.devMode, name: "Dev mode")
            }
            Button { ws.sheet = nil } label: {
                Image(systemName: "xmark").font(.system(size: 12, weight: .bold)).foregroundStyle(WS.text2)
                    .frame(width: 32, height: 32)
                    .background(WS.soft, in: Circle())
                    .contentShape(Circle())
            }
            .buttonStyle(.liaPlain)
            .keyboardShortcut(running || search.open ? nil : KeyboardShortcut.cancelAction)
            // (the close did not react to the pointer): the wash in its own circle.
            .liaHoverWash(Circle())
            .accessibilityLabel(Text("Close"))
        }
        .padding(.horizontal, 18)
        .frame(height: 64)
        // A GitHub chip (branch, commit, repository) in the thread opens its page in this popup
        .onAppear { SheetGitHubRoute.shared.attach(ws) { openWebPopup($0) } }
        .onDisappear { SheetGitHubRoute.shared.detach(ws) }
    }

    /// Team's and Met's approvals.
    private static let approvalModes: [GlassModeControl<RunMode>.Option] = [
        .init(label: "Auto", value: .auto, help: "Auto: one Yes per task"),
        .init(label: "Manual", value: .manual, help: "Manual: a Yes for every change"),
    ]

    /// Dev's: works through, or asks before every change (sent as `dev_mode`).
    private static let devModes: [GlassModeControl<DevMode>.Option] = DevMode.allCases.map {
        GlassModeControl<DevMode>.Option(label: $0.label, value: $0, help: $0.help)
    }

    /// The agent's figure, name and role: a click opens its profile.
    private var identity: some View {
        Button {
            if panel == .profile && profileDlg != nil { profileDlg = nil } else { profileDlg = nil; setPanel(.profile) }
        } label: {
            HStack(spacing: 12) {
                figures
                VStack(alignment: .leading, spacing: 1) {
                    Text(title).font(LiaFont.ui(15.5, .semibold)).foregroundStyle(WS.ink)
                    Text(subtitle).font(LiaFont.ui(12)).foregroundStyle(WS.text2).lineLimit(1)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.liaPlain)
        // The wash a few points past the figure and the name (drawn outside the frame: nothing moves).
        .liaHoverWash(RoundedRectangle(cornerRadius: 12, style: .continuous).inset(by: -5))
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
        .accessibilityHint(Text("Opens the profile"))
    }

    private var figures: some View {
        Group {
            if let a = ws.agent(chat.agentId) { headerFigure(a) }
        }
        .scaleEffect(appeared || reduceMotion ? 1 : 0.5, anchor: .bottom)
        .offset(y: appeared || reduceMotion ? 0 : 26)
        .opacity(appeared ? 1 : 0)
    }

    /// The dialogue's figure (it rises in as the sheet opens; the dock keeps its own, marked open:).
    private func headerFigure(_ a: AgentInfo) -> some View {
        AgentAvatar(agent: a, size: 34, status: ws.status(of: a.id)).padding(2).background(Circle().fill(WS.surface))
    }

    private func headerIcon(_ symbol: String, label: String, kbd: String? = nil, active: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 13, weight: .medium)).foregroundStyle(active ? WS.ink : WS.text2)
                .frame(width: 32, height: 32)
                .background(active ? WS.ink.opacity(0.08) : WS.soft, in: Circle())
                .contentShape(Circle())
        }
        .buttonStyle(.liaPlain)
        .liaHoverWash(Circle())   // search and the other header icons react to the pointer
        .accessibilityLabel(Text(label))
    }

    private var title: String { ws.dialogueTitle(chat.dlg) }
    private var subtitle: String {
        // The role alone, short (Lia: "Assistant"); no "\u{00b7}" chains.
        if chat.isTeam { return "Assistant" }
        return ws.agent(chat.dlg)?.shownRole ?? ""
    }
}

// MARK: - the dialogue rail (8b)

/// The product's 8b: every dialogue of the workspace at the sheet's left edge, Team first, then the agents in dock order,
/// each with its figure and an unread dot; a click switches the sheet to it. Narrow (figures) by default, wide
/// (names and roles) by the toggle on top. Restores the conversation list removed with threads (0ce6c70).
private struct DialogueRail: View {
    @ObservedObject var ws: WorkspaceModel
    let current: String
    let wide: Bool
    let onToggle: () -> Void

    struct Row: Identifiable {
        let dlg: String
        let agent: AgentInfo
        var id: String { dlg }
    }

    /// An agent hidden from the dock in this workspace (Settings > Team) is hidden here too (Met in a
    /// workspace without Meta). The dialogue open now stays listed, so the person always sees where they are.
    @ObservedObject private var shown = AgentShownStore.shared

    private var rows: [Row] {
        _ = shown.rev
        var out: [Row] = []
        if let lia = ws.roster.first(where: { $0.lead }) { out.append(Row(dlg: "team", agent: lia)) }
        let all = DockOrder.sorted(ws.roster.filter { !$0.lead })
        let visible = Set(ws.shownAgents(all).map(\.id))
        for a in all where visible.contains(a.id) || DialogueSummary.dlg(forAgent: a.id) == current {
            out.append(Row(dlg: DialogueSummary.dlg(forAgent: a.id), agent: a))
        }
        return out
    }

    var body: some View {
        VStack(alignment: wide ? .leading : .center, spacing: 0) {
            toggle
            ScrollView {
                VStack(spacing: 2) {
                    ForEach(rows) { r in
                        DialogueRailRow(ws: ws, row: r, selected: r.dlg == current, wide: wide)
                    }
                }
                .padding(.horizontal, 6).padding(.bottom, 10)
            }
            .scrollIndicators(.hidden)
        }
        .frame(width: wide ? 196 : 56)
        .background(Color.dyn(0x15181C, 0xF8F9FA))
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text("Dialogues"))
    }

    private var toggle: some View {
        HStack(spacing: 6) {
            if wide {
                Text("Dialogues").font(LiaFont.ui(12, .semibold)).foregroundStyle(WS.text2)
                    .accessibilityAddTraits(.isHeader)
                Spacer(minLength: 0)
            }
            Button(action: onToggle) {
                Image(systemName: wide ? "chevron.left.2" : "chevron.right.2")
                    .font(.system(size: 10.5, weight: .semibold)).foregroundStyle(WS.text2)
                    .frame(width: 26, height: 26)
                    .background(WS.ink.opacity(0.05), in: Circle())
                    .contentShape(Circle())
            }
            .buttonStyle(.liaPlain)
            .liaHoverWash(Circle())
            .accessibilityLabel(Text(wide ? "Collapse dialogues" : "Expand dialogues"))
        }
        .padding(.horizontal, wide ? 12 : 0)
        .padding(.top, 12).padding(.bottom, 8)
    }
}

private struct DialogueRailRow: View {
    @ObservedObject var ws: WorkspaceModel
    @EnvironmentObject private var app: AppModel
    let row: DialogueRail.Row
    let selected: Bool
    let wide: Bool
    @State private var hover = false

    private var name: String { row.dlg == "team" ? "Lia" : row.agent.name }
    /// Needs Meta and this workspace has no ad account: a click opens Settings > Meta.
    private var locked: Bool { row.dlg != "team" && ws.isLocked(row.agent.id) }
    private var detail: String { locked ? "Connect Meta" : row.agent.shownRole }
    private var unread: Bool { ws.unread(dlg: row.dlg) }

    var body: some View {
        Button {
            if locked { if !ws.openLockedTarget() { app.openSettings("meta") } } else if !selected { ws.openDialogue(row.dlg) }
        } label: {
            HStack(spacing: 9) {
                figure
                if wide {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(name).font(LiaFont.ui(13, unread || selected ? .semibold : .medium)).foregroundStyle(WS.ink).lineLimit(1)
                        Text(detail).font(LiaFont.ui(11)).foregroundStyle(WS.text3).lineLimit(1)
                    }
                    Spacer(minLength: 0)
                }
            }
            .padding(.horizontal, wide ? 8 : 0).padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: wide ? .leading : .center)
            .background(selected ? Color(hex: row.agent.colorHex).opacity(0.14) : (hover ? WS.hover : Color.clear),
                        in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.liaPlain)
        .onHover { hover = $0 }
        .liaPointer()
        .liaTip(locked ? "Connect Meta" : (wide ? nil : name))
        .opacity(row.agent.soon && !locked ? 0.6 : 1)
        .accessibilityLabel(Text([name, detail, locked ? "locked" : nil, unread ? "unread" : nil].compactMap { $0 }.joined(separator: ", ")))
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
    }

    private var figure: some View {
        AgentAvatar(agent: row.agent, size: 28, status: ws.status(of: row.agent.id))
            // Locked = grey and faded, no lock badge.
            .saturation(locked ? 0 : 1)
            .opacity(locked ? 0.45 : 1)
            .overlay(alignment: .topTrailing) {
                if unread {
                    Circle().fill(WS.red).frame(width: 9, height: 9)
                        .overlay(Circle().stroke(Color.dyn(0x15181C, 0xF8F9FA), lineWidth: 1.5))
                        .offset(x: 2, y: -2)
                }
            }
            .accessibilityHidden(true)
    }
}

// MARK: - the thread

/// The messenger's thread and composer. Internal so the side panel's agents page (PanelMessenger.swift) shows the same
/// thread in a narrow column (`compact`); the sheet uses the defaults.
struct ThreadColumn: View {
    @ObservedObject var ws: WorkspaceModel
    @ObservedObject var chat: TeamChatModel
    @ObservedObject var search: ChatSearch
    @ObservedObject var local: ChatLocal
    let onOpenBrowser: (String) -> Void
    /// The sheet's close (kept for the call site;: a scroll in the thread never closes the sheet).
    var onClose: () -> Void = {}
    /// The side panel (about 380 pt): tighter margins; no tour anchor; popups' "Use" only while no sheet is open.
    var compact = false
    /// Where the person's messages come from when this is not the sheet (the side panel: "from the side panel").
    var origin: DispatchOrigin? = nil
    /// A click on an agent's figure in the thread (the sheet opens that agent's profile). Nil (the
    /// side panel): it opens that agent's dialogue.
    var onOpenAgent: ((String) -> Void)? = nil
    /// The sheet's kept thread hears when it is shown again or hidden (ThreadHostCache).
    var life: ThreadLife = ThreadLife.unkept
    /// A deleted message's 10 s countdown (Undo) before the server delete.
    @ObservedObject private var pendingDeletes = ChatPendingDeletes.shared
    @EnvironmentObject private var app: AppModel
    /// 0.2.11: what the widgets and blocks of this conversation open (the creatives / ad / leads popups over this
    /// column, files and charts in the document viewer); before, every one of them did nothing here.
    @StateObject private var widgetRouter = ChatWidgetRouter()
    @State private var text = ""
    @State private var busyKey = UUID().uuidString   // AppBusy: an unsent message holds an automatic update back
    /// The message being forwarded (its picker shows over it).
    @State private var forwarding: String?
    /// Facts Lia saved from a deleted message, asked about before they go.
    @State private var forget: ChatForgetFacts?
    /// The custom Send Later / Remind Me picker (nil: closed).
    @State private var laterKind: ChatScheduled.Kind?
    @ObservedObject private var scheduler = ChatScheduler.shared
    /// The person's own scrolling (a streaming answer never pulls against it; pages load only on it).
    @State private var scrollWatch = ChatScrollMonitor()
    /// When the last older page came in (the next one waits until its scroll correction has landed).
    @State private var olderAt = Date.distantPast
    /// The first appearance ran (a kept thread shown again does not stage or settle a second time).
    @State private var opened = false
    /// (telemetry: a thread's first build took 500-1000 ms for 20-100 rows, every row laid out in the
    /// click's frames): an opened thread lays out only its newest `firstRows`; the rows above come in as the person
    /// scrolls to the top (then the older pages, as before). `windowFrom`: the first row laid out (nil: all), decided
    /// once the rows are there; until then the newest `firstRows`.
    @State private var windowFrom: String?
    @State private var windowed = false
    static let firstRows = 24
    static let moreRows = 30
    /// ("the first frame must already show the end"): while the thread opens, the scroll view
    /// keeps its bottom pinned as the content grows or measures itself (macOS 15 `.sizeChanges`; on 14 the end is put
    /// back without animation). Ends when the open settles or the person scrolls. No veil, no orbit over a thread.
    @State private var pinEnd = true
    @State private var pinGen = 0
    /// The open's first frame was reported (AgentOpenTrace), once per view.
    @State private var openReported = false
    /// (like Telegram): selection mode - a check beside each message, a bar with what to do.
    @State private var selecting = false
    @State private var selection = DlgSelection()
    @State private var forwardingSelection = false
    /// An answer split into several messages shows them one after another.
    @State private var stagger = DlgStagger()
    @State private var staggerPumping = false
    /// The newest row the thread had seen (what is new when `appended` moves).
    @State private var lastKnown: String?
    /// no staging any more - every loaded row is laid out in the first pass, so the first
    /// frame is the finished thread at its end (rows added above in visible passes moved the scroller). The cost of a
    /// first build is paid once per dialogue: the thread is kept (ThreadHostCache) and the dock prefetches on hover.
    /// How long the sheet's slide-in runs (WorkspaceWindow's spring, response 0.42) before the full thread is laid out.
    static let slideIn: TimeInterval = 0.5
    /// Bumped to put the keyboard in the message box (ComposerTextView).
    @State private var focusTick = 0
    /// The box's height (one line to its max; it scrolls inside beyond that).
    @State private var inputHeight: CGFloat = 28
    /// 0.2.11: the box hands its words to `text` when the typing pauses; Send takes them first.
    @State private var composerFlush = ComposerFlush()
    /// Long pastes waiting as chips (sent inline under the words), and the preview popup.
    @State private var pastes: [ChatPastedText] = []
    @State private var attachPreview: AttachmentPreviewPopup.Item?
    /// The person is at the end of the thread (else new messages count up on the "\u{2193} N new" button).
    @State private var atBottom = true
    /// When the thread last grew: right after, the end marker sits below the view for a frame, which is not the
    /// person scrolling up (without this the thread stopped following and jumped).
    @State private var grewAt = Date.distantPast
    @State private var newCount = 0
    /// The streaming answer grew while the person was reading above.
    @State private var liveUnseen = false
    /// The composer floats over the thread's bottom (rows scroll under it, fading just above the box);
    /// its measured height is the thread's bottom inset (0: not measured yet, `composerInset` estimates it).
    @State private var composerH: CGFloat = 0
    /// The thread is about a screen or more above its end (the round \u{2193} button shows).
    @State private var farFromEnd = false
    /// Files waiting for the next message, and a drag over the conversation.
    @State private var files: [ChatAttach.File] = []
    @State private var dropping = false
    /// The message being answered (its quote goes before the person's words).
    @State private var replyTo: TeamItem?
    /// "Quote & Reply" with text selected in the message: only that fragment is quoted (nil: the message).
    @State private var replyQuote: String?
    /// "Forward" with text selected: only that fragment is forwarded.
    @State private var forwardFragment: String?
    /// The media library over the conversation (the paperclip).
    @State private var library = false
    /// A message forwarded here waits in the composer as a chip until Send.
    @ObservedObject private var forwards = ChatForwardDraft.shared
    /// Dictation, and the field's text when it started (the transcript goes after it).
    @StateObject private var dictation = ChatDictation()
    @State private var dictationBase = ""
    @State private var dictationOn = false
    /// A11Y-04: the conversation's text size (Settings).
    @AppStorage(Prefs.chatTextSize) private var textSize = 1
    /// The highlighted row of the @mention list (\u{2191}/\u{2193} move it, \u{23CE} or Tab picks it).
    @State private var mentionIndex = 0
    /// Esc closed the list for exactly this text; typing on opens it again.
    @State private var mentionClosedFor: String?
    /// The "@..." at the caret, wherever it is in the text (ComposerTextView.onMention).
    @State private var mentionSpot: AgentMention.Spot?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// The unsent text of this conversation survives closing it.
    private var draftKey: String { "lia_ws_draft_" + chat.key }

    var body: some View {
        // (no white gap above the box): the composer floats over the thread's bottom; the rows scroll
        // under it and fade out just above its edge (composerLayer), the thread's bottom inset is its height.
        ZStack(alignment: .bottom) {
            ScrollViewReader { proxy in
                thread(proxy)
                    .overlay(alignment: .top) { topStrip(proxy).padding(.top, 8).padding(.horizontal, 16) }
                // Only messages joining the end follow (older pages coming in above never scroll or count).
                .onChange(of: chat.appended) { old, _ in
                    // While the thread opens, what came in is shown at once (no one-by-one bubbles, no animated scroll).
                    if pinEnd { lastKnown = chat.threadItems.last?.id } else { arrived(proxy) }
                    let follow = atBottom
                    grewAt = Date()
                    // The person's own message always brings the end into view; anyone else's only if they are there.
                    if old == 0 { settleAtEnd(proxy); decideWindow(); if !compact { coldRowsArrived() } }
                    else if pinEnd && follow { toEnd(proxy) }
                    else if follow || chat.items.last?.agent == nil { scroll(proxy, animated: true) }
                    else { newCount += 1 }
                    if chat.loaded, old > 0, let last = chat.items.last, let a = last.agent {
                        ChatA11y.announce("New message from \(ws.agent(a)?.name ?? "the agent")")
                    }
                }
                // A first read that brought no rows (an empty dialogue) still ends the open.
                .onChange(of: chat.loaded) { _, now in if now { coldRowsArrived() } }
                // A jump (a search hit, a task card, the profile) brings its message into view.
                .onChange(of: chat.scrollRequest) { _, r in if let r { pinEnd = false; reveal(proxy, r.id) } }
                // No words stream into the thread (the typing line stands for them): it follows only
                // when an agent starts writing.
                .onChange(of: chat.liveAgent) { _, a in
                    // The person's own message just went (the scroll to it may still be on its way): the answer follows.
                    let mine = chat.items.last?.agent == nil
                    if a != nil && (atBottom || mine) && !scrollWatch.scrolled(within: 0.5) { scroll(proxy, animated: true) }
                    // The person reading above is never taken down; the arrow lights up instead.
                    else if a != nil && !atBottom { liveUnseen = true }
                }
                .onChange(of: chat.queue.count) { _, _ in if atBottom { scroll(proxy, animated: true) } }
                .onChange(of: chat.queuedTasks.count) { _, _ in if atBottom { scroll(proxy, animated: true) } }
                // The selected match comes into view.
                .onChange(of: search.current) { _, _ in scrollToHit(proxy) }
                .onChange(of: search.query) { _, _ in scrollToHit(proxy) }
                .onAppear { firstAppear(proxy) }
                .onReceive(life.events) { shown in if shown { shownAgain(proxy) } else { wentAway() } }
                // The box grew or shrank (a line more, a tray, a reply strip): a thread at its end keeps its last row
                // in view above it.
                .onChange(of: composerH) { _, _ in if atBottom { toEnd(proxy) } }
            }
            composerLayer
        }
        // A deletion still counting down goes to the server when the conversation closes or another one opens.
        .onDisappear { pendingDeletes.flush(chat.key) }
        .liaModal(item: $forget) { f in
            ChatForgetFactsSheet(facts: f, auth: chat.auth, onDone: { forgot in
                forget = nil
                if forgot > 0 { ws.show(forgot == 1 ? "Forgotten" : "\(forgot) facts forgotten", symbol: "brain") }
            })
        }
        .modifier(ChatScrollHooks(monitor: scrollWatch))
        // Files dropped anywhere on the conversation wait under the composer.
        .onDrop(of: ChatAttach.dropTypes, isTargeted: $dropping) { ps in ChatAttach.receive(ps) { add($0) } }
        .overlay { if dropping { dropHint } }
        // A11Y-04: agent replies (MarkdownView and the rest) scale with the Settings text size.
        .environment(\.liaTextScale, ChatTextScale.factor(textSize))
        // Crea's block buttons answer in this conversation (CreaBlock).
        .environment(\.creaThread, CreaThread(chat: chat))
        .environment(\.chatWidgets, ChatWidgetLink(router: widgetRouter))
        // Creatives / ad / leads open over this column only, as they did in the old chat (ChatPopupOverlay).
        .overlay { ChatPopupOverlay(popups: widgetRouter.popups, auth: chat.auth, library: app.library) }
        .liaModal(item: $widgetRouter.doc) { item in AttachmentDocSheet(item: item) }
        .onAppear { bindWidgets() }
        .onChange(of: chat.key) { _, _ in
            widgetRouter.popups.close()
            bindWidgets()
        }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.15), value: dropping)
    }

    private func bindWidgets() {
        let a = app
        widgetRouter.bind(ws: ws, chat: chat, library: a.library, openSettings: { a.openSettings($0) })
    }

    /// Crea's "Make an ad": the picture waits in this composer's tray, already uploaded (its R2 key). Only the composer
    /// that takes "Use" from popups takes it (the side panel stands aside while a sheet is open).
    private func takeCreaFiles() {
        guard !compact || ws.sheet == nil else { return }
        for f in CreaDraftFiles.take(chat.key) where files.count < ChatAttach.maxFiles && !files.contains(where: { $0.id == f.id }) {
            files.append(f)
        }
    }

    private var dropHint: some View {
        RoundedRectangle(cornerRadius: 16, style: .continuous)
            .strokeBorder(WS.ink.opacity(0.5), style: StrokeStyle(lineWidth: 2, dash: [6, 5]))
            .background(WS.soft.opacity(0.6), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(Label("Drop to attach", systemImage: "paperclip").font(LiaFont.ui(14, .semibold)).foregroundStyle(WS.ink))
            .padding(10)
            .allowsHitTesting(false)
            .transition(.opacity)
            .accessibilityHidden(true)
    }

    /// Media library picks: already stored (R2 or Meta), they wait in the tray and go as markers.
    private func addLibrary(_ items: [MediaItem]) {
        for m in items where files.count < ChatAttach.maxFiles {
            let f = ChatAttach.File.fromLibrary(m)
            guard !files.contains(where: { $0.id == f.id }) else { continue }
            CreativePreviews.shared.remember(m)
            withAnimation(reduceMotion ? nil : .spring(response: 0.3, dampingFraction: 0.85)) { files.append(f) }
        }
        focusTick += 1
    }

    /// The thread's own ad account (the library lists its Meta images and videos).
    private var libraryAccount: String? {
        ws.profiles.first { $0.id == chat.profile }?.metaAccount ?? ws.profile?.metaAccount
    }

    /// Files from a drop or the paperclip (at most 6; the same file once). Each one uploads at once; one the
    /// server would not take (or that fails) goes as text, and its chip says why.
    private func add(_ urls: [URL]) {
        for u in urls where files.count < ChatAttach.maxFiles && !files.contains(where: { $0.url == u }) {
            guard var f = ChatAttach.load(u) else { continue }
            if let why = ChatAttach.refusal(f, with: files) { f.state = .fallback(why) }
            withAnimation(reduceMotion ? nil : .spring(response: 0.3, dampingFraction: 0.85)) { files.append(f) }
            if f.uploading { upload(f) }
        }
        focusTick += 1
    }

    private func upload(_ f: ChatAttach.File) {
        let auth = chat.auth
        Task { @MainActor in
            let state = await ChatAttach.upload(f, auth: auth)
            // Removed while it was on its way: nothing to update.
            guard let i = files.firstIndex(where: { $0.id == f.id }) else { return }
            files[i].state = state
            if case .fallback(let why) = state { ChatA11y.announce("\(f.name): \(why)") }
        }
    }

    private var attachButton: some View {
        Button { library = true } label: {
            Image(systemName: "paperclip").font(.system(size: 14, weight: .medium))
                .frame(width: 28, height: 34)
        }
        .buttonStyle(.liaPlain).liaHover(.icon, radius: 9, tint: WS.text2)
        .disabled(files.count >= ChatAttach.maxFiles)
        .liaTip(files.count >= ChatAttach.maxFiles ? "Up to \(ChatAttach.maxFiles) files per message" : nil)
        .accessibilityLabel(Text("Attach files"))
        .liaModal(isPresented: $library) {
            MediaLibrarySheet(auth: chat.auth, account: libraryAccount, limit: max(1, ChatAttach.maxFiles - files.count)) { items, urls in
                addLibrary(items)
                add(urls)
            }
        }
    }

    @ViewBuilder private func pinnedStrip(_ proxy: ScrollViewProxy) -> some View {
        let pinned = local.pinned(in: chat.threadItems)
        if !pinned.isEmpty {
            ChatPinnedStrip(pinned: pinned, agentOf: { ws.agent($0) },
                            onJump: { p in jump(proxy, to: p.id) },
                            onUnpin: { p in withAnimation(.easeOut(duration: 0.2)) { local.togglePin(p) } })
                .transition(.opacity.combined(with: .move(edge: .top)))
        }
    }

    /// a dialogue never read yet has nothing to lay out; the scroll view is made only once
    /// its rows are here, so `.defaultScrollAnchor(.bottom)` places its first layout - the first frame - at the end
    /// (made empty and filled later, it kept its top offset and was scrolled down afterwards, which showed).
    @ViewBuilder private func thread(_ proxy: ScrollViewProxy) -> some View {
        if !chat.loaded && chat.items.isEmpty && chat.live == nil {
            // 0.2.10: the first read of a dialogue: our orbit (after 300 ms), not an empty sheet
            LiaLoadingOrbit(size: 96, label: "Loading messages")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            threadScroll(proxy)
        }
    }

    private func threadScroll(_ proxy: ScrollViewProxy) -> some View {
        GeometryReader { geo in
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    messages(proxy)
                        .padding(.horizontal, compact ? 12 : 20)
                        .padding(.top, topInset)
                    // ("the arrow stops just short of the end"): the thread's true end, under the
                    // composer's inset. Scrolling to "end" (the marker above the inset) left the last row under the box.
                    Color.clear.frame(height: composerInset).id("floor")
                }
            }
            .defaultScrollAnchor(.bottom)
            .modifier(ChatEndPin(on: pinEnd))
            .coordinateSpace(name: "chatScroll")
            .onPreferenceChange(ChatTopKey.self) { y in
                // The top of the loaded window is in view: the next older page comes in above it.: only
                // when the person scrolled there - a layout pass while the dialogue opens showed the top for a frame,
                // loaded a page and scrolled to its old first message, so a dialogue opened at its top.
                if y > -60, !pinEnd, chat.loaded, !chat.loadingOlder, scrollWatch.scrolled(within: 1),
                   Date().timeIntervalSince(olderAt) > 0.8 {
                    if hiddenAbove { revealOlderRows(proxy) } else if chat.hasMoreBefore { loadOlder(proxy) }
                }
            }
            .onPreferenceChange(ChatBottomKey.self) { y in
                // The end marker sits `composerInset` above the scroll view's bottom (the composer floats over it).
                let shown = geo.size.height - composerInset
                let bottom = y <= shown + 60
                let far = y - shown > max(160, shown * 0.75)
                if far != farFromEnd { farFromEnd = far }
                // the person scrolled while it opened: the end lets go
                if pinEnd && !bottom && scrollWatch.scrolled(within: 0.3) { pinEnd = false }
                // Content that just grew is not the person leaving the end - unless the person is scrolling.
                if !bottom && Date().timeIntervalSince(grewAt) < 0.6 && !scrollWatch.scrolled(within: 0.3) { return }
                if bottom != atBottom { atBottom = bottom }
                if bottom && newCount != 0 { newCount = 0 }
                if bottom && liveUnseen { liveUnseen = false }
                // After a jump the window is not the newest part: the person scrolling to its end loads more.
                if bottom, chat.hasMoreAfter, !chat.loadingNewer, scrollWatch.scrolled(within: 1) { Task { await chat.loadNewer() } }
            }
            // The button's own animation only - on the scroll view it animated the whole thread whenever the
            // person scrolled away from the end with something new below (the messages slid and flickered).
            .overlay(alignment: .bottom) {
                newButton(proxy)
                    .padding(.bottom, jumpLift)
                    .animation(reduceMotion ? nil : .easeOut(duration: 0.2), value: showsJump)
            }
        }
    }

    private func messages(_ proxy: ScrollViewProxy) -> some View {
        // Messages hidden on this Mac before real deletion stay left out: grouping, search, the status.
        let list = shownItems
        let hits = search.hits(in: list)
        let hit: ChatSearch.Hit? = hits.isEmpty ? nil : hits[min(search.current, hits.count - 1)]
        let status = ChatDelivery.status(chat) { ws.agent($0)?.name ?? $0.capitalized }
        let days = dayLabels(list)
        // once per redraw, not once per row (each read parsed the last message's card)
        let openGateId = chat.openGate?.item.id
        let sel: Bool = selecting
        // A plain VStack, not a LazyVStack. The window is paged (50 a page) and every agent message is
        // NSTextView-backed (AnswerText) or a web view (charts): a lazy stack created those views while the person
        // scrolled, AppKit's live scroll drew them only when the scroll stopped (messages vanished and came back),
        // and the stack's estimated heights moved the content under the pointer. Laid out once, scrolling only
        // moves layers. Each row is an EquatableView (`ThreadRowSlot`), so a streamed token no longer redraws them.
        return VStack(alignment: .leading, spacing: 4) {
            Color.clear.frame(height: 0)
                .background(GeometryReader { g in
                    Color.clear.preference(key: ChatTopKey.self, value: g.frame(in: .named("chatScroll")).minY)
                })
            if chat.hasMoreBefore || hiddenAbove { olderLoader }
            if chat.loaded && chat.items.isEmpty && chat.live == nil && chat.queue.isEmpty && chat.queuedTasks.isEmpty && !chat.hasMoreBefore { empty }
            ForEach(Array(list.enumerated()), id: \.element.id) { i, item in
                let st: String? = i == list.count - 1 ? status : nil
                if let until = pendingDeletes.deadline(item, in: chat.key) {
                    if let day = days[i] { ChatDaySeparator(label: day) }
                    ChatDeletedLine(until: until, mine: item.agent == nil) {
                        withAnimation(reduceMotion ? nil : .easeOut(duration: 0.15)) { pendingDeletes.undo(item, in: chat.key) }
                        ChatA11y.announce("Message restored")
                    }
                } else {
                    ThreadRowSlot(key: slotKey(i, item, in: list, day: days[i], hit: hit, status: st, openGateId: openGateId)) {
                        selectable(item, on: sel) { row(i, item, in: list, day: days[i], hit: hit, status: st) }
                    }
                    .equatable()
                }
                // No second check under the message; the one by its time says it.
            }
            if chat.hasMoreAfter { newerLoader } else { tail }
            Color.clear.frame(height: 1).id("end")
                .background(GeometryReader { g in
                    Color.clear.preference(key: ChatBottomKey.self, value: g.frame(in: .named("chatScroll")).minY)
                })
        }
    }

    /// What follows the stored messages: the answer streaming now, the open approval, the run's error, the queue.
    @ViewBuilder private var tail: some View {
        // Dev's words after its first message never draw here (chatLive is empty: the typing line).
        if let l = chat.chatLive, let a = ws.agent(chat.liveAgent) {
            LiveBubble(turn: l, agent: a, auth: chat.auth, first: chat.items.last?.agent != a.id, status: chat.typingStatus, onAvatar: openAgent)
                .padding(.top, chat.items.last?.agent != a.id ? 12 : 0)
        }
        if let g = chat.openGate {
            GateCard(gate: g.gate, agent: ws.agent(g.item.agent), account: chat.accountName, applying: chat.applying,
                     auth: chat.auth,
                     onEdit: { text = "Change: "; focusTick += 1 },
                     onSendChanges: { chat.send($0) })
                .padding(.top, 8)
        }
        // Incident: the browser agent waiting on the person shows here, not only in the page's pill.
        if let wg = chat.webGate {
            WebAskRow(pending: wg, agentName: ws.agent(chat.webAgent)?.name ?? "Lia") { chat.answerWebGate(allow: $0) }
                .padding(.top, 8)
                .transition(.opacity)
        }
        // No running "Copying 3 of 5" line; only where a copy job stopped (a result, not a status).
        // While the browser runs between turns, the agent is "writing" too.
        // Speed: the agent expected to answer is "writing" the moment the message is sent.
        if chat.live == nil,
           let a = ws.agent(chat.webAgent ?? (chat.busy ? chat.pendingAgent : nil)) {
            HStack(alignment: .bottom, spacing: 8) {
                AgentAvatar(agent: a, size: 30, status: .working).accessibilityHidden(true)
                ChatTypingIndicator(agent: a, status: chat.webAgent == a.id ? nil : chat.typingStatus)
                Spacer(minLength: 40)
            }
            .padding(.top, 12)
            .transition(.opacity)
        }
        if let jp = chat.jobProgress, jp.error != nil { ChatJobProgress(progress: jp).padding(.top, 6) }
        if let e = chat.errorText {
            ChatErrorCard(text: e, agent: ws.agent(chat.liveAgent ?? chat.items.last(where: { $0.agent != nil })?.agent),
                          retryIn: chat.retryIn,
                          onRetry: chat.busy || chat.lastUserText == nil ? nil : { chat.retry() },
                          onOpenBrowser: openBrowser(for: chat.items.last(where: { $0.agent != nil })?.agent))
        }
        // Tasks given this agent while it works, started one by one after the run (not editable: they are another
        // dialogue's words)
        ForEach(chat.queuedTasks) { t in
            ChatQueuedTaskRow(task: t, from: ws.agent(DialogueSummary.agent(forDlg: t.originDlg ?? "team"))?.name)
                .padding(.top, 6)
                .transition(.opacity)
        }
        ForEach(Array(chat.queue.enumerated()), id: \.offset) { i, q in
            ChatQueuedBubble(text: CreaTargetHead.strip(q), onEdit: { editQueued(i) }, onRemove: { removeQueued(i) })
                .padding(.top, 6)
                .transition(.opacity)
        }
        ForEach(scheduler.pending(in: chat.key)) { s in
            ChatScheduledBubble(item: s, onEdit: { editScheduled(s) }, onCancel: { scheduler.cancel(s) })
                .padding(.top, 6)
                .transition(.opacity)
        }
    }

    /// Older messages exist above the loaded window (they load as the top comes into view).
    private var olderLoader: some View {
        HStack { Spacer(); ProgressView().controlSize(.small).opacity(chat.loadingOlder ? 1 : 0.4); Spacer() }
            .frame(height: 30)
            .accessibilityLabel(Text("Earlier messages"))
    }

    /// The next older page comes in above; the message that was first stays where it was (corrected in the same
    /// update as the page arrives, without animation, so nothing is drawn shifted in between).
    private func loadOlder(_ proxy: ScrollViewProxy) {
        let first = local.visible(chat.threadItems).first?.id
        olderAt = Date()
        Task { @MainActor in
            await chat.loadOlder()
            olderAt = Date()
            guard let first else { return }
            var t = Transaction()
            t.disablesAnimations = true
            withTransaction(t) { proxy.scrollTo(first, anchor: .top) }
        }
    }

    /// The window is not the newest part (after a jump): newer messages come in at the bottom as the person
    /// scrolls to it (the bottom marker decides; in a plain VStack `onAppear` fired at once).
    private var newerLoader: some View {
        HStack { Spacer(); ProgressView().controlSize(.small); Spacer() }
            .frame(height: 30)
            .accessibilityLabel(Text("Loading newer messages"))
    }

    /// The end of the thread in view, without animation.
    private func toEnd(_ proxy: ScrollViewProxy) {
        grewAt = Date()
        var still = Transaction()
        still.disablesAnimations = true
        withTransaction(still) { proxy.scrollTo("floor", anchor: .bottom) }
    }

    // MARK: opening, shown again, hidden

    /// The rows drawn: what this Mac hides left out, and a split answer's bubbles still waiting their turn.
    private var allItems: [TeamItem] {
        let all = local.visible(chat.threadItems)
        return stagger.held.isEmpty ? all : all.filter { !stagger.isHeld($0.id) }
    }

    /// The rows laid out: the window's (search sees every loaded row).
    private var shownItems: [TeamItem] { windowOf(allItems) }

    private func windowOf(_ all: [TeamItem]) -> [TeamItem] {
        if search.active { return all }
        if !windowed { return all.count > Self.firstRows ? Array(all.suffix(Self.firstRows)) : all }
        guard let f = windowFrom else { return all }
        // the first row went (deleted, a reload): the newest rows again, never the whole thread at once
        guard let i = all.firstIndex(where: { $0.id == f }) else {
            return all.count > Self.firstRows ? Array(all.suffix(Self.firstRows)) : all
        }
        return Array(all[i...])
    }

    /// Loaded rows above the window (they come in before an older page is asked for).
    private var hiddenAbove: Bool {
        let all = allItems
        return windowOf(all).count < all.count
    }

    /// The window is fixed at the newest `firstRows` once the rows are there (new ones below then add to it).
    private func decideWindow() {
        guard !windowed else { return }
        let all = allItems
        guard !all.isEmpty else { return }
        windowed = true
        windowFrom = all.count > Self.firstRows ? all[all.count - Self.firstRows].id : nil
    }

    /// Every loaded row (a jump to a message that may sit above the window).
    private func showAllRows() {
        windowed = true
        windowFrom = nil
    }

    /// The top of the window in view: `moreRows` more rows above; the row that was first stays where it was.
    private func revealOlderRows(_ proxy: ScrollViewProxy) {
        let all = allItems
        guard let first = windowOf(all).first?.id, let i = all.firstIndex(where: { $0.id == first }) else { return }
        olderAt = Date()
        var t = Transaction()
        t.disablesAnimations = true
        withTransaction(t) {
            windowed = true
            windowFrom = i > Self.moreRows ? all[i - Self.moreRows].id : nil
        }
        DispatchQueue.main.async {
            var t = Transaction()
            t.disablesAnimations = true
            withTransaction(t) { proxy.scrollTo(first, anchor: .top) }
        }
    }

    private var topInset: CGFloat {
        if selecting { return 52 }
        return local.pinned(in: chat.threadItems).isEmpty ? (compact ? 10 : 18) : 52
    }

    /// How long the end stays pinned after an open (images and late measures), unless the person scrolls first.
    private static let pinFor: TimeInterval = 0.8

    /// The first appearance: a jump asked for just before wins over the end; else the end - there from the first frame
    /// (the scroll view's bottom anchor, every row laid out in that pass), checked once more without animation.
    private func firstAppear(_ proxy: ScrollViewProxy) {
        guard !opened else { return }
        opened = true
        lastKnown = chat.threadItems.last?.id
        if let r = chat.scrollRequest, Date().timeIntervalSince(r.at) < 3 {
            pinEnd = false
            reveal(proxy, r.id)
            coldRowsArrived()
        } else if chat.loaded || !chat.items.isEmpty {
            settleAtEnd(proxy)
            coldRowsArrived()
        }
        // else nothing is read yet: the first page's `appended` calls coldRowsArrived
    }

    /// The first frame with this thread's rows is on screen (the main loop's next pass: the frame was committed);
    /// once the end was checked again the open counts as settled (AgentOpenTrace, DockOpenClock).
    private func coldRowsArrived() {
        decideWindow()
        guard !openReported else { return }
        openReported = true
        let dlg = chat.dlg
        let rows = shownItems.count
        let sheet = !compact
        if sheet { DispatchQueue.main.async { AgentOpenTrace.shared.firstFrame(dlg, kept: false, rows: rows) } }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { if sheet { DockOpenClock.shared.settled(dlg) } }
        releasePin(after: Self.pinFor)
    }

    /// The end lets go of its pin after `t` (a newer pin's own timer wins).
    private func releasePin(after t: TimeInterval) {
        pinGen += 1
        let gen = pinGen
        DispatchQueue.main.asyncAfter(deadline: .now() + t) { if gen == pinGen { pinEnd = false } }
    }

    /// The kept thread is on screen again: nothing is rebuilt. It opens at the end when the person left it there (or
    /// at a message asked for meanwhile), else exactly where they were; a draft put in from outside is taken. The end
    /// was put in place before the first frame (ThreadHostBox.pinToEnd); this only checks it, without animation.
    private func shownAgain(_ proxy: ScrollViewProxy) {
        let dlg = chat.dlg
        AgentOpenTrace.shared.firstFrame(dlg, kept: true, rows: shownItems.count)
        scrollWatch.start()
        let saved = UserDefaults.standard.string(forKey: draftKey) ?? ""
        if saved != text { text = saved }
        AppBusy.shared.setDraft(busyKey, hasText: !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        takeCreaFiles()
        focusTick += 1
        if let r = chat.scrollRequest, Date().timeIntervalSince(r.at) < 3 {
            pinEnd = false
            reveal(proxy, r.id)
        } else if life.atEndWhenHidden, !chat.hasMoreAfter {
            pinEnd = true
            toEnd(proxy)
            atBottom = true
            newCount = 0
            DispatchQueue.main.async { toEnd(proxy) }
            releasePin(after: Self.pinFor)
        }
        DispatchQueue.main.async { DockOpenClock.shared.settled(dlg) }
    }

    /// The kept thread left the screen: what waits goes now (the draft, the deletions), the selection ends.
    private func wentAway() {
        life.atEndWhenHidden = atBottom
        ChatDraftSave.flush(draftKey)
        AppBusy.shared.setDraft(busyKey, hasText: false)
        pendingDeletes.flush(chat.key)
        if selecting { endSelecting() }
        if !stagger.held.isEmpty { stagger.flush() }
    }

    // MARK: a split answer, one bubble after another

    /// New rows came in at the end: the agents' messages among them show one by one (DlgStagger).
    private func arrived(_ proxy: ScrollViewProxy) {
        let items = chat.threadItems
        let known = lastKnown
        lastKnown = items.last?.id
        guard let known, let i = items.firstIndex(where: { $0.id == known }), i + 1 < items.count else {
            if !stagger.held.isEmpty { stagger.flush() }
            return
        }
        let fresh: [String] = items[(i + 1)...].filter { $0.agent != nil && !$0.isTask }.map(\.id)
        _ = stagger.arrive(fresh, at: Date())
        if !stagger.held.isEmpty { pumpStagger(proxy) }
    }

    private func pumpStagger(_ proxy: ScrollViewProxy) {
        guard !staggerPumping else { return }
        staggerPumping = true
        let wait: TimeInterval = max(0.02, stagger.nextAt.timeIntervalSinceNow)
        DispatchQueue.main.asyncAfter(deadline: .now() + wait) {
            staggerPumping = false
            let follow = atBottom
            var shown = false
            withAnimation(reduceMotion ? nil : .easeOut(duration: 0.18)) { shown = stagger.pop(at: Date()) != nil }
            if shown {
                grewAt = Date()
                if follow { scroll(proxy, animated: true) }
            }
            if !stagger.held.isEmpty { pumpStagger(proxy) }
        }
    }

    // MARK: selection mode

    @ViewBuilder private func topStrip(_ proxy: ScrollViewProxy) -> some View {
        if selecting {
            selectionBar
        } else {
            pinnedStrip(proxy)
        }
    }

    private var selectionBar: some View {
        ChatSelectionBar(count: selection.count,
                         onCopy: copySelected,
                         onForward: { forwardingSelection = true },
                         onDelete: deleteSelected,
                         onCancel: endSelecting)
            .popover(isPresented: $forwardingSelection, arrowEdge: .bottom) {
                ChatSelectForwardPicker(ws: ws, from: chat.dlg) { d in forwardSelected(to: d) }
            }
            .transition(.opacity.combined(with: .move(edge: .top)))
    }

    /// The row menu's Select: the mode starts with this message (and the other parts of its answer) picked.
    private func beginSelecting(_ item: TeamItem) {
        var sel = DlgSelection()
        sel.toggle(item.id, group: turnGroup(item))
        let go = { selecting = true; selection = sel }
        if reduceMotion { go() } else { withAnimation(.easeOut(duration: 0.18)) { go() } }
    }

    private func endSelecting() {
        let go = { selecting = false; selection.clear(); forwardingSelection = false }
        if reduceMotion { go() } else { withAnimation(.easeOut(duration: 0.18)) { go() } }
    }

    /// The parts of one answer (server: one `turn`, parts 1..n) are picked together.
    private func turnGroup(_ item: TeamItem) -> [String] {
        guard let t = item.turn, !t.isEmpty else { return [item.id] }
        return shownItems.filter { $0.turn == t }.map(\.id)
    }

    /// A click on a row in selection mode: it toggles; with Shift, the run from the last click joins.
    private func pick(_ item: TeamItem) {
        let order = shownItems.map(\.id)
        if NSEvent.modifierFlags.contains(.shift) {
            selection.extend(to: item.id, in: order, group: turnGroup(item))
        } else {
            selection.toggle(item.id, group: turnGroup(item))
        }
        if selection.isEmpty { endSelecting() }
    }

    private var selectedItems: [TeamItem] {
        shownItems.filter { selection.contains($0.id) && pendingDeletes.deadline($0, in: chat.key) == nil }
    }

    private func quotePart(_ item: TeamItem) -> DlgQuoteText.Part {
        let who: String = item.agent.map { ws.agent($0)?.name ?? "Agent" } ?? "You"
        let words: String = item.agent == nil ? ChatAttach.split(ChatQuote.split(item.message.content).body).text : ChatSearch.text(of: item)
        return DlgQuoteText.Part(who: who, ts: item.message.ts, text: words)
    }

    private func copySelected() {
        let t = DlgQuoteText.copy(selectedItems.map(quotePart))
        guard !t.isEmpty else { return }
        Clipboard.copy(t)
        ws.show(selection.count == 1 ? "Copied" : "\(selection.count) messages copied", symbol: "doc.on.doc")
        endSelecting()
    }

    /// Forward: the picked messages, quoted under their authors and times, go to the other agent as the person's
    /// message; that dialogue opens.
    private func forwardSelected(to dlg: String) {
        let msg = DlgQuoteText.forward(selectedItems.map(quotePart))
        forwardingSelection = false
        guard !msg.isEmpty, let c = ws.chat(for: dlg) else { return }
        endSelecting()
        c.send(msg)
        ws.openDialogue(dlg)
    }

    /// Delete: asked once; each message is then a "Message deleted \u{00B7} Undo" line and goes to the server
    /// (/agents/dlg/delete) when its count ends. The facts Lia saved from them are asked about once, together.
    private func deleteSelected() {
        let items = selectedItems
        guard !items.isEmpty, Self.confirmDelete(items.count) else { return }
        endSelecting()
        if let r = replyTo, items.contains(where: { $0.id == r.id }) { replyTo = nil }
        let ws = ws
        let forgetBinding = $forget
        let tally = ChatDeleteTally(count: items.count)
        ChatA11y.announce("\(items.count) messages deleted. Undo for \(ChatPendingDeletes.seconds) seconds")
        withAnimation(reduceMotion ? nil : .easeOut(duration: 0.15)) {
            for it in items {
                pendingDeletes.start(it, in: chat) { facts in
                    guard tally.done(facts) else { return }
                    if tally.failed { ws.show("Could not delete every message", symbol: "exclamationmark.triangle") }
                    if !tally.facts.isEmpty { forgetBinding.wrappedValue = ChatForgetFacts(facts: tally.facts) }
                }
            }
        }
        // One taken back with Undo never answers: the others' facts are asked about after the countdown.
        DispatchQueue.main.asyncAfter(deadline: .now() + Double(ChatPendingDeletes.seconds) + 8) {
            guard tally.finish(), !tally.facts.isEmpty else { return }
            forgetBinding.wrappedValue = ChatForgetFacts(facts: tally.facts)
        }
    }

    /// Opening a dialogue: its end (the newest), again after the first layout passes (an answer's text measures
    /// itself as it is placed), unless the person has started scrolling.
    private func settleAtEnd(_ proxy: ScrollViewProxy) {
        // never animated - the end is there from the first frame; these only hold it.
        DispatchQueue.main.async { toEnd(proxy) }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            guard !scrollWatch.scrolled(within: 0.3), !chat.hasMoreAfter else { return }
            toEnd(proxy)
        }
    }

    /// The message a jump landed on glows for a moment.
    private func flashBackground(_ id: String) -> some View {
        RoundedRectangle(cornerRadius: 14, style: .continuous)
            .fill(WS.blue.opacity(chat.flash == id ? 0.12 : 0))
            .padding(-4)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.35), value: chat.flash)
    }

    private func reveal(_ proxy: ScrollViewProxy, _ id: String) {
        // The message may sit above the laid-out rows.
        if !shownItems.contains(where: { $0.id == id }) { showAllRows() }
        // After the window changed the row exists only on the next layout pass.
        DispatchQueue.main.async {
            if reduceMotion { proxy.scrollTo(id, anchor: .center) }
            else { withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) { proxy.scrollTo(id, anchor: .center) } }
        }
    }

    /// (the web's \u{2193}, forgotten here): a round button over the faded rows, just above the box. It
    /// shows about a screen above the end (or with new messages below, or after a jump), and takes the thread to its end.
    @ViewBuilder private func newButton(_ proxy: ScrollViewProxy) -> some View {
        if showsJump {
            Button { jumpToEnd(proxy) } label: { ChatJumpToEndFace(count: newCount, lit: newCount > 0 || liveUnseen) }
                .buttonStyle(.liaPlain)
                .liaHoverWash(Circle())
                .transition(.opacity.combined(with: .scale(scale: 0.85)))
                .accessibilityLabel(Text(jumpLabel))
        }
    }

    private var showsJump: Bool {
        chat.hasMoreAfter || (!atBottom && (farFromEnd || newCount > 0 || liveUnseen))
    }

    private var jumpLabel: String {
        if chat.hasMoreAfter { return "Jump to the latest messages" }
        if newCount > 0 { return "\(newCount) new messages. Scroll to the end" }
        if liveUnseen { return "A reply is coming in. Scroll to the end" }
        return "Scroll to the end"
    }

    private func jumpToEnd(_ proxy: ScrollViewProxy) {
        newCount = 0
        liveUnseen = false
        // After a jump the window is not the newest part: the newest page comes in first.
        if chat.hasMoreAfter { Task { await chat.reloadLatest() }; return }
        scroll(proxy, animated: true)
    }

    /// The fade above the box: rows go under the composer and fade out over this height just above its top edge.
    private static let fadeH: CGFloat = 12
    /// The composer's own top padding (its first element - the box, a tray, a strip - starts this far below its top).
    private var composerTopPad: CGFloat { compact ? 6 : 8 }
    /// The composer's height: measured, else its one-line height (the first frame already has the right inset).
    private var composerMeasured: CGFloat { composerH > 0 ? composerH : (compact ? 60 : 70) }
    /// The thread's bottom inset: at the end the last row stands fully above the fade.
    private var composerInset: CGFloat { composerMeasured + max(0, Self.fadeH - composerTopPad) + 2 }
    /// The \u{2193} button floats this far above the thread's bottom: just over the box's top edge.
    private var jumpLift: CGFloat { composerMeasured - composerTopPad + 10 }

    /// The composer over the thread's bottom: the surface under it, and a 12 pt fade from clear to the surface right
    /// above its first element (the rows scrolling under it fade out there). The fade never takes the mouse.
    private var composerLayer: some View {
        composer
            .background(alignment: .top) {
                VStack(spacing: 0) {
                    LinearGradient(colors: [WS.surface.opacity(0), WS.surface], startPoint: .top, endPoint: .bottom)
                        .frame(height: Self.fadeH)
                        .allowsHitTesting(false)
                    WS.surface
                }
                .padding(.top, composerTopPad - Self.fadeH)
                .accessibilityHidden(true)
            }
            .background(GeometryReader { g in Color.clear.preference(key: ChatComposerHeightKey.self, value: g.size.height) })
            .onPreferenceChange(ChatComposerHeightKey.self) { h in
                if abs(h - composerH) > 0.5 { composerH = h }
            }
    }

    private func scroll(_ proxy: ScrollViewProxy, animated: Bool) {
        // while the thread opens nothing scrolls with an animation (the end is held still)
        if pinEnd { toEnd(proxy); return }
        if animated && !reduceMotion {
            withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) { proxy.scrollTo("floor", anchor: .bottom) }
        } else {
            proxy.scrollTo("floor", anchor: .bottom)
        }
    }

    private func jump(_ proxy: ScrollViewProxy, to id: String) {
        if reduceMotion { proxy.scrollTo(id, anchor: .center) }
        else { withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) { proxy.scrollTo(id, anchor: .center) } }
    }

    private func scrollToHit(_ proxy: ScrollViewProxy) {
        let hits = search.hits(in: local.visible(chat.threadItems))
        guard !hits.isEmpty else { return }
        // a hit above the laid-out rows: every row stays, so closing the search keeps the place
        showAllRows()
        jump(proxy, to: hits[min(search.current, hits.count - 1)].item)
    }

    /// Each row's day separator in one pass (it was a backwards search per row, per redraw).
    private func dayLabels(_ list: [TeamItem]) -> [String?] {
        var out: [String?] = []
        out.reserveCapacity(list.count)
        var prevTs: Double?
        // A row with no time of its own (a local copy not yet stored, a stored row the server sent
        // without `ts`) was left out, so today's message stood under an older day's line. A local one is now; a
        // stored one without a time takes the day of the row before it (it never opens a day of its own).
        let now: Double = Date().timeIntervalSince1970 * 1000
        for item in list {
            let ts: Double? = item.message.ts ?? (item.seq == 0 ? now : nil)
            out.append(ChatDay.label(ts, after: prevTs))
            if let ts { prevTs = ts }
        }
        return out
    }

    /// Everything one row draws from outside itself; the row is redrawn only when this changes.
    private func slotKey(_ i: Int, _ item: TeamItem, in list: [TeamItem], day: String?, hit: ChatSearch.Hit?, status: String?,
                         openGateId: String?) -> ThreadRowKey {
        let isLast = i == list.count - 1
        let next: String? = i + 1 < list.count ? list[i + 1].agent : (chat.live != nil ? chat.liveAgent : "\u{0}")
        let gate = chat.gate(of: item)
        return ThreadRowKey(
            item: item, day: day, index0: i == 0, isLast: isLast,
            prev: i > 0 ? list[i - 1].agent : "\u{0}", next: next,
            agentName: ws.agent(item.agent)?.name,
            task: item.taskId.flatMap { chat.tasks[$0] },
            isError: chat.errorItems.contains(item.id),
            retryIn: isLast ? chat.retryIn : nil,
            canRetry: isLast && !chat.busy && chat.lastUserText != nil,
            status: status,
            query: search.active ? search.query : nil,
            occ: hit?.item == item.id ? hit?.n : nil,
            reaction: local.reaction(item), canMark: ChatLocal.markId(item) != nil,
            favourite: local.isFavourite(item), pinned: local.isPinned(item),
            flash: chat.flash == item.id, forwarding: forwarding == item.id,
            openGate: openGateId == item.id,
            decision: gate.flatMap { ChatDecisions.get($0.planId) },
            origin: item.agent == nil && !item.handed ? originLabel(item) : nil,
            devConfirm: devConfirmKey(item),
            selecting: selecting, picked: selection.contains(item.id))
    }

    /// Selection mode: a round check on the leading side of the row; a click anywhere on it toggles (Shift: a run).
    /// Outside it the row is as it was (the same view: entering the mode never rebuilds the messages).
    private func selectable<C: View>(_ item: TeamItem, on: Bool, @ViewBuilder _ content: () -> C) -> some View {
        let picked: Bool = on && selection.contains(item.id)
        return HStack(alignment: .center, spacing: on ? 10 : 0) {
            if on { ChatSelectCheck(on: picked).transition(.opacity.combined(with: .move(edge: .leading))) }
            // The row's pieces (day line, message, its chips) stack; in this HStack on their own they
            // stood side by side and squeezed the bubble into a strip of one word per line.
            VStack(alignment: .leading, spacing: 0) { content() }
                .frame(maxWidth: .infinity, alignment: .leading)
                .allowsHitTesting(!on)
        }
        .background(picked ? WS.blue.opacity(0.07) : Color.clear, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay {
            if on {
                Color.clear.contentShape(Rectangle())
                    .onTapGesture { pick(item) }
                    .liaHoverWash(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .accessibilityElement()
                    .accessibilityLabel(Text(picked ? "Selected message" : "Message"))
                    .accessibilityAddTraits(picked ? [.isButton, .isSelected] : .isButton)
            }
        }
    }

    /// Dev's question on this message for the row key: open, its answer, or closed (nil: none). Kept out of the
    /// initializer above so its long argument list stays cheap for the type checker.
    private func devConfirmKey(_ item: TeamItem) -> String? {
        guard DevConfirm.first(in: item.message.blocks) != nil else { return nil }
        if chat.devConfirmOpen(item) { return "open" }
        guard let d: Bool = chat.devDecision(item.id) else { return "closed" }
        return d ? "yes" : "no"
    }

    /// A message with its day separator above it when it starts a new day; an agent's error as a card.
    @ViewBuilder private func row(_ i: Int, _ item: TeamItem, in list: [TeamItem], day: String?, hit: ChatSearch.Hit?, status: String? = nil) -> some View {
        if let day { ChatDaySeparator(label: day) }
        // A run of messages from one speaker reads as one group: name and figure once.
        let prev = i > 0 ? list[i - 1].agent : "\u{0}"
        let next = i + 1 < list.count ? list[i + 1].agent : (chat.live != nil ? chat.liveAgent : "\u{0}")
        if item.isTask {
            ChatTaskCard(item: item, task: chat.tasks[item.taskId ?? ""], agent: ws.agent(item.agent)) { t in ws.openTask(t) }
                .padding(.top, 8)
        } else if chat.errorItems.contains(item.id) {
            let isLast = i == list.count - 1
            ChatErrorCard(text: item.message.content, agent: ws.agent(item.agent),
                          retryIn: isLast ? chat.retryIn : nil,
                          onRetry: isLast && !chat.busy && chat.lastUserText != nil ? { chat.retry() } : nil,
                          onOpenBrowser: openBrowser(for: item.agent))
        } else {
            teamRow(item, hit: hit, first: prev != item.agent, last: next != item.agent, status: status)
                .background(flashBackground(item.id))
                .padding(.top, prev != item.agent && i > 0 ? 12 : 0)
                .popover(isPresented: forwardBinding(item.id), arrowEdge: .top) {
                    ChatForwardPicker(ws: ws, from: chat.dlg, item: item, fragment: forwardFragment) { forwarding = nil }
                }
            // An agent's acknowledgement of a task given it here: a click opens its dialogue at that task.
            if !item.handed, DlgMention.isAck(agent: item.agent, taskId: item.taskId, isTaskCard: item.isTask, dlg: chat.dlg),
               let tid = item.taskId, let a = ws.agent(item.agent) {
                ChatAckLink(agent: a) { ws.openTask(chat.tasks[tid] ?? AgentTask(id: tid, owner: a.id)) }
            }
            // A task handed to this agent: where it was asked, a click goes back there (to the message it came from)
            if item.handed, let from = item.origin?.fromDlg, let host = ws.agent(DialogueSummary.agent(forDlg: from)) {
                ChatAckLink(agent: host, caption: ChatAckLink.askedIn(host.name), trailing: item.agent == nil) {
                    let back = item.origin?.fromMsg ?? chat.tasks[item.taskId ?? ""]?.originMsg
                    if let back, !back.isEmpty { ws.openDialogue(from, jumpTo: back) } else { ws.openDialogue(from) }
                }
            }
            // An approval already answered folds into one line.
            if let g = chat.gate(of: item), item.id != chat.openGate?.item.id, g.done || i < list.count - 1 {
                ChatDecidedRow(gate: g, decision: ChatDecisions.get(g.planId))
            }
            // Dev's question in Manual mode (also drawn again on reload): Allow / Deny, then its answer.
            if item.agent != nil, let c = DevConfirm.first(in: item.message.blocks) {
                DevConfirmCard(confirm: c, open: chat.devConfirmOpen(item), decision: chat.devDecision(item.id)) { allow in
                    chat.answerDev(item, allow: allow)
                }
            }
            // Dev stopped at its bound (time, cost, steps): Continue under its message, until a newer message exists.
            if item.agent == "dev", chat.devContinueOpen(item), let c = DevContinue.first(in: item.message.blocks) {
                DevContinueButton(cont: c) { chat.continueDev(item) }
            }
        }
    }

    /// One message (split out of `row`: with its modifiers it was too much for the type checker).
    private func teamRow(_ item: TeamItem, hit: ChatSearch.Hit?, first: Bool, last: Bool, status: String?) -> TeamRow {
        let save: (() -> Void)? = item.agent == nil ? { saveAsTask(item) } : nil
        let occ: Int? = hit?.item == item.id ? hit?.n : nil
        // In steps: one expression with all of these closures and ternaries is heavy for the type checker.
        let origin: String? = item.agent == nil && !item.handed ? originLabel(item) : nil   // The link back says it
        let onDelete: () -> Void = { delete(item) }
        let onForward: () -> Void = { forwardFragment = nil; forwarding = item.id }
        let onQuote: (String) -> Void = { q in reply(to: item, quote: q) }
        let onForwardPart: (String) -> Void = { q in forwardFragment = q; forwarding = item.id }
        return TeamRow(item: item, agent: ws.agent(item.agent), auth: chat.auth, first: first, last: last,
                       origin: origin,
                       query: search.active ? search.query : nil, currentOcc: occ,
                       reaction: local.reaction(item), canMark: ChatLocal.markId(item) != nil,
                       favourite: local.isFavourite(item), pinned: local.isPinned(item),
                       selecting: selecting,
                       status: item.agent == nil ? status : nil,
                       onReply: { reply(to: item) },
                       onSave: save,
                       onForward: onForward,
                       onQuoteReply: onQuote,
                       onForwardPart: onForwardPart,
                       onPin: { withAnimation(.easeOut(duration: 0.2)) { local.togglePin(item) } },
                       onReact: { e in withAnimation(.spring(response: 0.3, dampingFraction: 0.75)) { local.react(e, for: item) } },
                       onFavourite: { withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) { local.toggleFavourite(item) } },
                       onDelete: onDelete,
                       onAvatar: openAgent,
                       onSelect: { beginSelecting(item) })
    }

    /// A click on an agent's figure: its profile in the sheet; in the side panel, its dialogue.
    private func openAgent(_ id: String) {
        if let onOpenAgent { onOpenAgent(id) } else { ws.openDialogue(DialogueSummary.dlg(forAgent: id)) }
    }

    /// Where the person's message came from when it was sent from outside this dialogue ("from notes"): the
    /// server's `origin`; the copy kept on this Mac for a message drawn before the server's arrived.
    private func originLabel(_ item: TeamItem) -> String? {
        if let o = item.origin { return o.label(name: { ws.agent($0)?.name }) }
        return DispatchOriginStore.shared.origin(thread: chat.key, text: item.message.content)?.label
    }

    /// "Delete": asked first; then the row is a "Message deleted \u{00B7} Undo (10)" line and the server
    /// delete (gone from the server and the agents' memory of the dialogue) goes when the count ends. Facts saved from
    /// it are asked about after that.
    private func delete(_ item: TeamItem) {
        guard Self.confirmDelete() else { return }
        if replyTo?.id == item.id { replyTo = nil }
        let ws = ws
        let forgetBinding = $forget
        ChatA11y.announce("Message deleted. Undo for \(ChatPendingDeletes.seconds) seconds")
        withAnimation(reduceMotion ? nil : .easeOut(duration: 0.15)) {
            pendingDeletes.start(item, in: chat) { facts in
                guard let facts else { ws.show("Could not delete the message", symbol: "exclamationmark.triangle"); return }
                if !facts.isEmpty {
                    forgetBinding.wrappedValue = ChatForgetFacts(facts: facts.map { ChatForgetFacts.Fact(id: $0.id, text: $0.text) })
                }
            }
        }
    }

    private static func confirmDelete(_ n: Int = 1) -> Bool {
        let a = NSAlert()
        a.alertStyle = .warning
        a.messageText = n == 1 ? "Delete message?" : "Delete \(n) messages?"
        a.informativeText = "It is removed for good on every device."
        let del = a.addButton(withTitle: "Delete")
        del.hasDestructiveAction = true
        a.addButton(withTitle: "Cancel")
        return a.runModal() == .alertFirstButtonReturn
    }

    private func forwardBinding(_ id: String) -> Binding<Bool> {
        Binding(get: { forwarding == id }, set: { if !$0, forwarding == id { forwarding = nil } })
    }

    /// The person's own words (without a quoted reply or attached files) become a saved quick task.
    private func saveAsTask(_ item: TeamItem) {
        let body = ChatAttach.split(ChatQuote.split(item.message.content).body).text
        if SavedPrompts.shared.add(body) {
            ws.show("Saved to Quick tasks", symbol: "bookmark")
            ChatA11y.announce("Saved to Quick tasks")
        }
    }

    private func reply(to item: TeamItem, quote: String? = nil) {
        replyQuote = quote.map(Self.quoteLine)
        replyTo = item
        focusTick += 1
    }

    /// A selected fragment as the quote line: whole (not cut at 120 like a message's first line), on one line
    /// (the quote is the first line of what is sent), at most 2,000 characters.
    private static func quoteLine(_ s: String) -> String {
        let t = s.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression).trimmingCharacters(in: .whitespaces)
        return t.count > 2000 ? String(t.prefix(1999)) + "\u{2026}" : t
    }

    /// The reply strip shows the fragment being quoted, when there is one.
    private func replyShown(_ r: TeamItem) -> TeamItem {
        guard let q = replyQuote else { return r }
        var shown = r
        shown.message.content = q
        return shown
    }

    private func openBrowser(for agent: String?) -> (() -> Void)? {
        guard let agent, agent != "lia" else { return nil }
        return { onOpenBrowser(agent) }
    }

    private func editQueued(_ i: Int) {
        guard let raw = chat.dropQueued(at: i) else { return }
        let q = raw == TeamChatModel.filesOnly ? "" : CreaTargetHead.strip(raw)
        text = text.isEmpty ? q : text + "\n" + q
        focusTick += 1
    }

    /// A scheduled message back in the field (its schedule goes).
    private func editScheduled(_ s: ChatScheduled) {
        scheduler.cancel(s)
        text = text.isEmpty ? s.text : text + "\n" + s.text
        focusTick += 1
    }

    /// The field's text (and files) scheduled instead of sent now.
    private func schedule(_ at: Date, _ kind: ChatScheduled.Kind) {
        laterKind = nil
        guard canSend else { return }
        // Uploaded files go with the message when it is sent; the rest the text way (inline or by name).
        for f in files where f.library == nil { ChatAttach.local[f.name] = f.url }
        let uploaded = files.compactMap(\.uploaded)
        let t = ChatAttach.compose(text, files: files.filter { $0.uploaded == nil })
        let msg = outgoing(t)
        scheduler.add(msg, thread: chat.key, at: at, kind: kind, attachments: uploaded)
        text = ""
        files = []
        replyTo = nil
    }

    private func removeQueued(_ i: Int) {
        _ = withAnimation(.easeOut(duration: 0.2)) { chat.dropQueued(at: i) }
    }

    /// An empty conversation offers prompts that fit its agent; a click sends one.
    private var empty: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(chat.isTeam ? "Give Lia a task" : "Ask \(ws.agent(chat.dlg)?.name ?? "the agent")")
                .font(LiaFont.ui(17, .semibold)).foregroundStyle(WS.ink)
            Text(chat.isTeam
                 ? "Lia hands each part to the right agent. Write @Met, @Rep or any name to ask one directly."
                 : "Write @Name to bring another agent into this conversation.")
                .font(LiaFont.ui(13)).foregroundStyle(WS.text2)
            VStack(alignment: .leading, spacing: 6) {
                ForEach(ChatStarters.list(for: chat.dlg), id: \.self) { s in
                    ChatStarterButton(starter: s) { chat.send(s.text) }
                }
            }
            .padding(.top, 8)
        }
        .padding(.top, 8)
    }

    /// The agents matching the "@..." being typed (by name, then by role), all of them right after "@".
    private var mentionList: [AgentInfo] {
        // The "@..." at the caret, anywhere in the text (the box tells it: mentionSpot)
        guard mentionClosedFor != text, let p = mentionSpot?.query.lowercased() else { return [] }
        if p.isEmpty { return ws.roster }
        let byName = ws.roster.filter { $0.name.lowercased().hasPrefix(p) }
        let byRole = ws.roster.filter { !$0.name.lowercased().hasPrefix(p) && $0.role.lowercased().contains(p) }
        return byName + byRole
    }

    private func pickMention(_ a: AgentInfo) {
        if let s = mentionSpot, composerFlush.complete(s, name: a.name) {
            mentionSpot = nil
        } else {
            text = AgentMention.complete(text, with: a)
        }
        mentionIndex = 0
        focusTick += 1
    }

    /// A vertical list over the field: figure, full name, role; filtered as the person types.
    @ViewBuilder private var mentions: some View {
        let list = mentionList
        if !list.isEmpty {
            let sel = min(mentionIndex, list.count - 1)
            VStack(alignment: .leading, spacing: 0) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(Array(list.enumerated()), id: \.element.id) { i, a in
                            ChatMentionRow(agent: a, selected: i == sel) { pickMention(a) }
                        }
                    }
                    .padding(5)
                }
                .frame(maxHeight: min(CGFloat(list.count) * 42 + 10, 230))
                .scrollIndicators(.hidden)
            }
            .wsGlass(14)
            .shadow(color: .black.opacity(0.10), radius: 14, y: 4)
            .transition(.opacity.combined(with: .move(edge: .bottom)))
            .accessibilityElement(children: .contain)
            .accessibilityLabel(Text("Mention an agent"))
        }
    }

    private var composer: some View {
        VStack(alignment: .leading, spacing: 6) {
            mentions
            CreaTargetChip(thread: chat.key)
            // 0.2.11: "Saw your tab" is no longer here (it covered the text) - it is the chip "<Agent>
            // sees this tab" in the browser pane's header (ScreenSeenChip).
            // No "<Name> is working in the browser · step" line here; the browser pane shows its step
            // and the thread shows "<Name> is writing".
            if let d = forwards.draft(chat.key) {
                ChatForwardChip(draft: d, agent: ws.agent(d.agent)) {
                    withAnimation(reduceMotion ? nil : .easeOut(duration: 0.15)) { forwards.clear(chat.key) }
                }
                .transition(.opacity.combined(with: .move(edge: .bottom)))
            } else if let r = replyTo {
                ChatReplyStrip(item: replyShown(r), agent: ws.agent(r.agent)) { replyTo = nil; replyQuote = nil }
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
            }
            if !files.isEmpty {
                ChatAttachTray(files: files, auth: chat.auth) { f in
                    withAnimation(reduceMotion ? nil : .easeOut(duration: 0.15)) { files.removeAll { $0.id == f.id } }
                }
                .transition(.opacity.combined(with: .move(edge: .bottom)))
            }
            if !pastes.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(pastes) { p in
                            ChatPastedChip(paste: p,
                                           onOpen: { attachPreview = AttachmentPreviewPopup.Item(name: p.name, source: .text(p.text)) },
                                           onRemove: { withAnimation(reduceMotion ? nil : .easeOut(duration: 0.15)) { pastes.removeAll { $0.id == p.id } } })
                        }
                    }
                }
                .transition(.opacity.combined(with: .move(edge: .bottom)))
            }
            // The open approval answers here, above the input, Yes / No (no hold card).
            if let g = chat.openGate {
                GateBar(gate: g.gate, mode: chat.mode, applying: chat.applying) { chat.answer($0) }
                    .transition(.opacity)
            }
            if compact { inputRow } else {
                inputRow
                    .tourAnchor("composer")
            }
        }
        .padding(.horizontal, compact ? 8 : 16)
        .padding(.bottom, compact ? 8 : 16)
        .padding(.top, compact ? 6 : 8)
        .animation(reduceMotion ? nil : .spring(response: 0.3, dampingFraction: 0.85), value: replyTo?.id)
        .animation(reduceMotion ? nil : .spring(response: 0.3, dampingFraction: 0.85), value: forwards.draft(chat.key))
        .animation(reduceMotion ? nil : .easeOut(duration: 0.15), value: mentionList.isEmpty)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.15), value: chat.openGate?.gate.planId)
        .onChange(of: text) { _, _ in if mentionIndex != 0 { mentionIndex = 0 } }
        .onAppear {
            if text.isEmpty, let d = UserDefaults.standard.string(forKey: draftKey) { text = d }
            if files.isEmpty { files = ChatDraftFiles.restore(chat.key) }   // Files stay like text
            takeCreaFiles()
            focusTick += 1
        }
        .onReceive(NotificationCenter.default.publisher(for: .liaCreaAttach)) { _ in takeCreaFiles() }
        .onChange(of: files) { _, f in ChatDraftFiles.save(f, thread: chat.key) }
        .liaModal(item: $attachPreview) { item in AttachmentPreviewPopup(item: item, auth: chat.auth) }
        .onChange(of: text) { _, t in
            // 0.2.11: the draft is written when the typing pauses (each write told every defaults observer).
            ChatDraftSave.save(t, key: draftKey)
            AppBusy.shared.setDraft(busyKey, hasText: !t.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
        .onDisappear { ChatDraftSave.flush(draftKey); AppBusy.shared.setDraft(busyKey, hasText: false) }
        .modifier(DictationHooks(dictation: dictation, onStart: { dictationBase = text; dictationOn = true; dictation.agent = chat.agentId }, onHeard: dictated,
                                 onError: { ws.show($0, symbol: "mic.slash") },
                                 onCleared: { if dictationOn { text = dictationBase } }))
    }

    /// The live transcript after what was in the field when dictation started.
    private func dictated(_ words: String) {
        guard dictationOn, !words.isEmpty else { return }
        let base = dictationBase
        let gap = base.isEmpty || base.hasSuffix(" ") || base.hasSuffix("\n") ? "" : " "
        text = base + gap + words
    }

    /// The box's padding above and below the text view, and the side buttons' height.
    private static let boxPad: CGFloat = 5
    private static let sideButtonH: CGFloat = 34
    /// (the paperclip, mic and send sat lower than the words): the side buttons stand this
    /// far off the row's bottom, so their centre is the one-line box's centre (5 + 28 / 2 = 19 from the bottom, the
    /// button's 2 + 34 / 2); a taller box keeps them at the bottom, on its last line's centre. The row's height is
    /// unchanged (5 + 28 + 5 = 38 >= 2 + 34).
    private static var sideLift: CGFloat {
        max(0, (ComposerTextView.Coordinator.lineBox + boxPad * 2 - sideButtonH) / 2)
    }

    private var inputRow: some View {
        HStack(alignment: .bottom, spacing: 8) {
            attachButton
                .padding(.bottom, Self.sideLift)
            // An NSTextView box - a long message scrolls inside it and Shift-Return keeps the caret in
            // view; a long paste becomes a chip, a pasted picture a file.
            ComposerTextView(text: $text, height: $inputHeight, placeholder: placeholder, focusTick: focusTick,
                             onSubmit: send, onEscape: escape, onDigit: { _ in false },
                             onPasteImage: pastedImage, onPasteLongText: pastedText, onPasteFiles: { add($0) }, onNav: nav,
                             fontSize: (14 * ChatTextScale.factor(textSize)).rounded(), maxHeight: compact ? 150 : 180,
                             publishDelay: 0.12, flush: composerFlush, draftTail: dictationOn ? dictation.draftTail : 0,
                             onMention: { mentionSpot = $0 })
                .frame(height: inputHeight)
                .padding(.vertical, Self.boxPad)
                .accessibilityLabel(Text(chat.isTeam ? "Message Lia" : "Message"))
                .accessibilityHint(Text("Return sends, Shift-Return adds a line"))
            ChatMicButton(dictation: dictation)
                .liaHover(.icon, radius: 9)
                .padding(.bottom, Self.sideLift)
            sendButtons
                .padding(.bottom, Self.sideLift)
        }
        .padding(.leading, 6).padding(.trailing, 6).padding(.vertical, 4)
        .background(WS.surface, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).stroke(WS.line2, lineWidth: 1))
        .modifier(PopupSignals(text: $text, onFocus: { focusTick += 1 }, ws: ws, active: !compact || ws.sheet == nil))
    }

    /// Arrows, Return, Tab and Esc in the box: the @mention list first, then \u{2191} in an empty box brings
    /// The last own message back, Esc drops the forward or the reply.
    private func nav(_ n: ComposerTextView.Nav) -> Bool {
        let list = mentionList
        switch n {
        case .up:
            if !list.isEmpty { mentionIndex = (min(mentionIndex, list.count - 1) + list.count - 1) % list.count; return true }
            guard text.isEmpty, let last = chat.lastUserText else { return false }
            text = last
            return true
        case .down:
            guard !list.isEmpty else { return false }
            mentionIndex = (min(mentionIndex, list.count - 1) + 1) % list.count
            return true
        case .pick:
            guard !list.isEmpty else { return false }
            pickMention(list[min(mentionIndex, list.count - 1)])
            return true
        case .close:
            if !list.isEmpty { mentionClosedFor = text; return true }
            if forwards.draft(chat.key) != nil { forwards.clear(chat.key); return true }
            if replyTo != nil { replyTo = nil; replyQuote = nil; return true }
            return false
        }
    }

    /// Esc with nothing to drop in the box: the search closes, else a run stops, else the sheet closes.
    private func escape() {
        if selecting { endSelecting(); return }
        if search.open { search.close(); return }
        if chat.busy || chat.webAgent != nil { chat.stop(); return }
        if !compact { onClose() }
    }

    /// A long paste: a chip over the box (sent inline under the words).
    private func pastedText(_ s: String) {
        let p = ChatPastedText.make(s)
        withAnimation(reduceMotion ? nil : .spring(response: 0.3, dampingFraction: 0.85)) { pastes.append(p) }
        focusTick += 1
    }

    /// A pasted picture: a file in the tray, uploaded like a dropped one.
    private func pastedImage(_ data: Data, _ name: String) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("lia-paste-" + UUID().uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let u = dir.appendingPathComponent(name)
        guard (try? data.write(to: u, options: .atomic)) != nil else { return }
        add([u])
    }

    @ViewBuilder private var sendButtons: some View {
        if chat.busy {
            if canSend {
                Button(action: send) {
                    Image(systemName: "text.append").font(.system(size: 12, weight: .bold)).foregroundStyle(WS.ink)
                        .frame(width: 34, height: 34).background(WS.soft, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                }
                .buttonStyle(ChatPressStyle())
                .liaHoverWash(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .liaTip("Queue: sent when the answer finishes", kbd: "\u{23CE}")
                .accessibilityLabel(Text("Queue message"))
            }
            Button { chat.stop() } label: {
                Image(systemName: "stop.fill").font(.system(size: 11)).foregroundStyle(WS.onInk)
                    .frame(width: 34, height: 34).background(WS.ink, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
            .buttonStyle(ChatPressStyle())
            .liaHoverWash(RoundedRectangle(cornerRadius: 12, style: .continuous), ink: true)
            .accessibilityLabel(Text("Stop"))
        } else {
            sendNowButton
            // Right-click Send: later, or a reminder.
            .contextMenu { ChatSendLaterMenu(enabled: canSend, onPick: schedule, onCustom: { laterKind = $0 }) }
            .accessibilityAction(named: Text("Send Later")) { if canSend { laterKind = .send } }
            .accessibilityAction(named: Text("Remind Me")) { if canSend { laterKind = .remind } }
            .popover(isPresented: laterBinding, arrowEdge: .top) {
                ChatSendLaterPicker(kind: laterKind ?? .send, onSchedule: schedule, onCancel: { laterKind = nil })
            }
        }
    }

    private var sendNowButton: some View {
        Button(action: send) {
            Image(systemName: "arrow.up").font(.system(size: 13, weight: .bold)).foregroundStyle(.white)
                .frame(width: 34, height: 34).background(canSend ? WS.blue : WS.text3, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(ChatPressStyle())
        .liaHoverWash(RoundedRectangle(cornerRadius: 12, style: .continuous), enabled: canSend)
        .disabled(!canSend).accessibilityLabel(Text("Send"))
    }

    private var laterBinding: Binding<Bool> {
        Binding(get: { laterKind != nil }, set: { if !$0 { laterKind = nil } })
    }

    private var placeholder: String {
        if forwards.draft(chat.key) != nil { return "Add a comment (optional)" }
        if replyTo != nil { return "Reply\u{2026}" }
        if chat.busy { return "Write next \u{00b7} it waits for this answer" }
        return chat.isTeam ? "Message Lia \u{00b7} @ to call an agent" : "Message \u{00b7} @ to call another agent"
    }

    /// Send waits while a file is still uploading (its chip shows the spinner), and while dictation's
    /// last words are still being replaced by the server's text (the mic shows its dots), for 6 s at most.
    private var canSend: Bool {
        let has = !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !files.isEmpty || !pastes.isEmpty
            || forwards.draft(chat.key) != nil
        return has && !files.contains(where: ChatAttach.holdsSend) && !dictation.sendHeld
    }

    private func send() {
        composerFlush.now()   // the words typed in the last moment (ComposerTextView.publishDelay)
        guard canSend else { return }
        dictationOn = false
        if dictation.listening { dictation.stop() }
        // Uploaded files go in the turn's `attachments`; library picks as markers; the rest inline (small
        // text) or by name (ChatAttach).
        for f in files where f.library == nil { ChatAttach.local[f.name] = f.url }
        let uploadedFiles = files.compactMap(\.uploaded)
        var t = ChatAttach.compose(text, files: files.filter { $0.uploaded == nil })
        // Long pastes go inline under the words (the bubble shows each as a card that opens the text).
        for p in pastes {
            p.remember()
            t += (t.isEmpty ? "" : "\n\n") + LongPaste.block(name: p.name, text: p.text)
        }
        let (msg, uploaded) = CreaStudioStore.shared.outgoing(outgoing(t), attachments: uploadedFiles, thread: chat.key)
        text = ""
        files = []
        pastes = []
        replyTo = nil
        if let origin {
            // Kept on this Mac as well, for a bubble drawn before the server's copy (with its origin) arrives.
            DispatchOriginStore.shared.record(thread: chat.key, text: CreaTargetHead.strip(msg.trimmingCharacters(in: .whitespacesAndNewlines)), origin: origin)
            chat.send(msg, attachments: uploaded, origin: origin.surface)
        } else {
            chat.send(msg, attachments: uploaded)
        }
    }

    /// The words with what they carry: a forwarded message's quote, else the reply's quote.
    /// The forward is used up here.
    private func outgoing(_ t: String) -> String {
        if let d = forwards.draft(chat.key) {
            forwards.clear(chat.key)
            return d.compose(t)
        }
        if let r = replyTo {
            if let q = replyQuote { return "> " + q + "\n\n" + t }
            return ChatQuote.compose(t, quoting: r)
        }
        return t
    }
}

/// 0.2.11: a conversation's unsent text, written to the defaults half a second after the typing pauses (cleared at
/// once); `flush` writes what waits (the conversation closing).
@MainActor
enum ChatDraftSave {
    private static var waiting: [String: String] = [:]
    private static var gen: [String: Int] = [:]

    static func save(_ t: String, key: String) {
        let g = (gen[key] ?? 0) &+ 1
        gen[key] = g
        if t.isEmpty {
            waiting[key] = nil
            UserDefaults.standard.removeObject(forKey: key)
            return
        }
        waiting[key] = t
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 500_000_000)
            guard gen[key] == g else { return }
            flush(key)
        }
    }

    static func flush(_ key: String) {
        guard let t = waiting.removeValue(forKey: key) else { return }
        UserDefaults.standard.set(t, forKey: key)
    }
}

private struct AgentName: View {
    let agent: AgentInfo
    var body: some View {
        HStack(spacing: 7) {
            AgentAvatar(agent: agent, size: 22)
            // Ask 10: the name only; the role is in the header's chip.
            Text(agent.name).font(LiaFont.ui(13, .semibold)).foregroundStyle(WS.ink)
        }
    }
}

/// The composer's height over the thread (ThreadColumn.composerLayer).
private struct ChatComposerHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

/// The scroll-to-end button's face, as on the web: a white circle with a soft shadow and a thin
/// \u{2193}; the count of messages that came in below, when there are some, on a small blue badge.
private struct ChatJumpToEndFace: View {
    let count: Int
    /// Something new is below (an answer started or came in while the person read above).
    var lit = false

    var body: some View {
        Image(systemName: "arrow.down")
            .font(.system(size: 14, weight: lit ? .semibold : .regular))
            .foregroundStyle(lit ? Color.white : WS.ink)
            .frame(width: 36, height: 36)
            .background(Circle().fill(lit ? WS.blue : WS.raised))
            .overlay(Circle().stroke(lit ? Color.clear : WS.line, lineWidth: 1))
            .shadow(color: Color.black.opacity(0.13), radius: 10, y: 3)
            .overlay(alignment: .topTrailing) { badge }
    }

    @ViewBuilder private var badge: some View {
        if count > 0 {
            Text(verbatim: count > 99 ? "99+" : String(count))
                .font(LiaFont.ui(10.5, .semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, 5)
                .frame(minWidth: 18, minHeight: 18)
                .background(WS.blue, in: Capsule())
                .offset(x: 6, y: -6)
                .allowsHitTesting(false)
        }
    }
}

/// One row of the thread behind an equality check. The thread's body runs on every streamed token (it observes
/// the chat model); without this every message re-ran its Markdown and text layout each time, which made scrolling
/// stutter while an agent wrote. `Key` holds what the row shows; the closures inside are not compared (they act on
/// the same state either way).
private struct ThreadRowKey: Equatable {
    let item: TeamItem
    let day: String?
    let index0: Bool
    let isLast: Bool
    let prev: String?
    let next: String?
    let agentName: String?
    let task: AgentTask?
    let isError: Bool
    let retryIn: Int?
    let canRetry: Bool
    let status: String?
    let query: String?
    let occ: Int?
    let reaction: String?
    let canMark: Bool
    let favourite: Bool
    let pinned: Bool
    let flash: Bool
    let forwarding: Bool
    let openGate: Bool
    let decision: ChatDecisions.Decision?
    let origin: String?
    /// Dev's question on this message: open, its answer, or closed (nil: none).
    let devConfirm: String?
    /// Selection mode is on, and this row is picked.
    let selecting: Bool
    let picked: Bool
}

private struct ThreadRowSlot<Content: View>: View, Equatable {
    let key: ThreadRowKey
    @ViewBuilder let content: () -> Content

    var body: some View { content() }

    static func == (a: ThreadRowSlot, b: ThreadRowSlot) -> Bool { a.key == b.key }
}

/// One message in the messenger: the person's on the right (our blue, glass-smooth bubble), an agent's on the left
/// (light bubble, its figure beside the last of a group, its name in its colour over the first: ). The time
/// sits inside the bubble, bottom right, small (iMessage/Telegram); the date is in its tip. Agent text renders as
/// Markdown (MarkdownView via AssistantMessageView); while a search matches it, as plain text with the matches marked
/// . (the product's ask 9): no action row; on an agent's message the hover shows a round heart beside the
/// bubble's bottom-right corner (ChatReactButton: click reacts, hover opens the picker) and a reaction shows as a chip
/// under the bubble; every other action (Reply, Forward, Copy, Pin, Save, Delete) is the context menu;: ❤️ is the favourite.
private struct TeamRow: View {
    let item: TeamItem
    let agent: AgentInfo?
    var auth: AuthStore? = nil
    /// 0.2.11: what this conversation's widgets open (ThreadColumn's ChatWidgetRouter).
    @Environment(\.chatWidgets) private var widgets
    /// The dialogue (its Meta objects, for the entity chips of stored messages).
    @Environment(\.creaThread) private var thread
    var first = true
    var last = true
    /// The person's message sent from outside the conversation: where from ("from notes").
    var origin: String? = nil
    var query: String? = nil
    var currentOcc: Int? = nil
    /// The person's thumb (\u{1F44D}/\u{1F44E}, the feedback; ❤️ is `favourite`); `canMark`: the message is stored
    /// (an unconfirmed one cannot be marked yet).
    var reaction: String? = nil
    var canMark = false
    var favourite = false
    var pinned = false
    /// Selection mode is on. The check (30 pt) beside the row comes out of the row's free side, never
    /// out of the bubble: the side's minimum spacer gives it up.
    var selecting = false
    /// The person's last message: "Sent" (a tiny check inside the bubble).
    var status: String? = nil
    var onReply: () -> Void = {}
    /// "Save as Quick Task" (the person's own messages only).
    var onSave: (() -> Void)? = nil
    /// "Forward\u{2026}".
    var onForward: (() -> Void)? = nil
    /// "Quote & Reply" / "Forward" with text selected in the message: only that fragment.
    var onQuoteReply: (String) -> Void = { _ in }
    var onForwardPart: ((String) -> Void)? = nil
    var onPin: () -> Void = {}
    /// The thumb to set (it replaces the other one); nil takes it back.
    var onReact: (String?) -> Void = { _ in }
    /// ❤️: likes the message (= Favourites) or takes the like back.
    var onFavourite: () -> Void = {}
    /// Deletes the message (asked first, then undoable for 10 s: ThreadColumn.delete).
    var onDelete: () -> Void = {}
    /// A click on an agent's figure opens that agent's profile.
    var onAvatar: (String) -> Void = { _ in }
    /// The menu's Select starts the thread's selection mode (nil: it selects the text, as before).
    var onSelect: (() -> Void)? = nil
    @State private var hover = false
    /// A11Y-04: the conversation's text size.
    @AppStorage(Prefs.chatTextSize) private var textSize = 1
    /// The message's text views (their menu, their selection) and the text selected in them now.
    @State private var hooks = AnswerTextHooks()
    @State private var selected = ""

    var body: some View {
        let _ = wireHooks()
        Group {
            if item.agent == nil { mine } else { theirs }
        }
        .environment(\.answerTextHooks, hooks)
        .onHover { hover = $0 }
        .contextMenu { ChatMsgMenuContent(menu: menuModel(selected: selected, in: nil)) }
        .accessibilityAction(named: Text("Reply"), onReply)
        .accessibilityAction(named: Text(pinned ? "Unpin" : "Pin"), onPin)
        .accessibilityAction(named: Text(favourite ? "Unlike" : "Like"), onFavourite)
        .accessibilityAction(named: Text("Copy")) { copy() }
        .accessibilityAction(named: Text("Save as Quick Task")) { onSave?() }
        .accessibilityAction(named: Text("Forward")) { onForward?() }
        .accessibilityAction(named: Text("Delete"), onDelete)
    }

    /// The text views of this message show the same menu as the bubble (built for their selection).
    private func wireHooks() {
        let row = self
        hooks.menu = { sel, view in row.menuModel(selected: sel, in: view).nsMenu() }
        hooks.onSelection = { sel in if row.selected != sel { row.selected = sel } }
    }

    /// The right-click menu (Telegram-like, with icons, the same on the text and around it). With text
    /// selected the first item is Quote & Reply and Forward / Copy take only the selection.: no separate
    /// favourite: ❤️ is it (an agent's message: React \u{25B8} ❤️ 👍 👎; the person's own: Like).
    private func menuModel(selected raw: String, in view: AnswerTextNSView?) -> ChatMsgMenu {
        let sel = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        typealias E = ChatMsgMenu.Entry
        var first: [E] = []
        if sel.isEmpty {
            first.append(E(title: "Reply", symbol: "arrowshape.turn.up.left", action: onReply))
        } else {
            first.append(E(title: "Quote & Reply", symbol: "text.quote", action: { onQuoteReply(sel) }))
        }
        if canMark { first.append(E(title: pinned ? "Unpin" : "Pin", symbol: pinned ? "pin.slash" : "pin", action: onPin)) }
        if !sel.isEmpty, let onForwardPart {
            first.append(E(title: "Forward\u{2026}", symbol: "arrowshape.turn.up.right", action: { onForwardPart(sel) }))
        } else if let onForward {
            first.append(E(title: "Forward\u{2026}", symbol: "arrowshape.turn.up.right", action: onForward))
        }
        first.append(E(title: sel.isEmpty ? "Copy" : "Copy Selection", symbol: "doc.on.doc",
                       action: { if sel.isEmpty { copy() } else { Clipboard.copy(sel) } }))
        var second: [E] = []
        if canMark {
            if item.agent != nil {
                var kids: [E] = ChatReaction.offered.map { e in
                    E(title: e + "  " + reactTitle(e), symbol: isOn(e) ? "checkmark" : (e == ChatLocal.heart ? "heart" : (e == "\u{1F44E}" ? "hand.thumbsdown" : "hand.thumbsup")),
                      action: { toggle(e) })
                }
                if reaction != nil { kids.append(E(title: "Remove Reaction", symbol: "xmark", action: { onReact(nil) })) }
                second.append(E(title: "React", symbol: "face.smiling", children: kids))
            } else {
                second.append(E(title: favourite ? "Unlike" : "Like", symbol: favourite ? "heart.slash" : "heart", action: onFavourite))
            }
        }
        if let onSave { second.append(E(title: "Save as Quick Task", symbol: "bookmark", action: onSave)) }
        let h = hooks
        let pickMode = onSelect
        second.append(E(title: "Select", symbol: "checkmark.circle", action: {
            if let pickMode { pickMode() } else if let view { view.selectAllText() } else { h.selectFirst() }
        }))
        let third: [E] = [E(title: "Delete", symbol: "trash", destructive: true, action: onDelete)]
        return ChatMsgMenu(sections: [first, second, third])
    }

    private func copy() {
        Clipboard.copy(ChatSearch.text(of: item))
    }

    /// ❤️ toggles the like (the favourite); a thumb toggles itself (replacing the other one).
    private func toggle(_ e: String) {
        if e == ChatLocal.heart { onFavourite() } else { onReact(reaction == e ? nil : e) }
    }

    private func isOn(_ e: String) -> Bool { e == ChatLocal.heart ? favourite : reaction == e }

    private func reactTitle(_ e: String) -> String {
        if e == ChatLocal.heart { return favourite ? "Unlike" : "Like" }
        return isOn(e) ? "Remove \(ChatReaction.name(e))" : ChatReaction.name(e)
    }

    /// The person's marks (the like, ❤️ = in Favourites, and the thumb, each a small chip with the person's
    /// face; a click takes one back); empty when there is none.
    private var marks: [ChatReaction] { ChatReaction.mine(liked: favourite, thumb: reaction) }

    /// The bubble's bottom row: the time at the right.: the marks sit at the row's LEFT end (drawn by
    /// `marksOverlay` at the bubble's bottom-left); here an invisible copy only keeps their width and height, so the
    /// bubble is wide enough for both and grows taller only when it has a mark (no mark: the time's height, as before).
    private func bottomRow(onDark: Bool) -> some View {
        HStack(spacing: 8) {
            if !marks.isEmpty {
                ChatReactionChips(reactions: marks, onDark: onDark, onToggle: { _ in })
                    .hidden()
                    .accessibilityHidden(true)
            }
            ChatBubbleTime(ts: item.message.ts, onDark: onDark, pinned: pinned, status: onDark ? status : nil)
        }
    }

    /// The marks at the bottom-left of the bubble's content, on the bottom row's place.
    @ViewBuilder private func marksOverlay(onDark: Bool) -> some View {
        if !marks.isEmpty {
            ChatReactionChips(reactions: marks, onDark: onDark, onToggle: toggle)
        }
    }

    // MARK: the person's

    private var mine: some View {
        VStack(alignment: .trailing, spacing: 3) {
            HStack {
                Spacer(minLength: mineGap)
                myBubble
            }
            if let origin { ChatOriginChip(label: origin) }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text("You: " + spoken + (origin.map { ", sent " + $0 } ?? "") + (pinned ? ". Pinned" : "")
                                 + (status.map { ". " + $0 } ?? "")))
    }

    /// The free side's minimum (selection mode: less by the check's 30 pt, so the bubble keeps its width).
    private var mineGap: CGFloat { selecting ? 40 : 70 }
    private var theirGap: CGFloat { selecting ? 10 : 40 }

    /// VoiceOver reads the words and names the files, never an inlined file's raw text.
    private var spoken: String {
        let att = ChatAttach.split(item.message.content)
        let all = item.message.attachments.map(\.name) + att.refs.map(\.name)
        guard !all.isEmpty else { return item.message.content }
        let names = all.joined(separator: ", ")
        return att.text + (att.text.isEmpty ? "" : ". ") + "Attached: " + names
    }

    @ViewBuilder private var myBubble: some View {
        let split = ChatQuote.split(item.message.content)
        VStack(alignment: .trailing, spacing: 4) {
            VStack(alignment: .leading, spacing: 6) {
                if let query {
                    Text(ChatSearch.highlighted(item.message.content, query: query, current: currentOcc, dark: true))
                } else {
                    // pictures over the words (a Crea Studio target's image first), files under.
                    // Two or more pictures are a fan of cards (ChatPhotoFan); one stays a single tile.
                    let pics = item.message.attachments.filter(\.isImage)
                    if pics.count > 1 {
                        ChatPhotoFan(images: pics, auth: auth)
                    } else {
                        ForEach(pics) { a in ChatAttachmentTile(attachment: a, auth: auth) }
                    }
                    if let q = split.quote {
                        HStack(spacing: 6) {
                            RoundedRectangle(cornerRadius: 1).fill(Color.white.opacity(0.6)).frame(width: 2)
                            Text(q).font(ChatTextScale.ui(12, level: textSize)).foregroundStyle(.white.opacity(0.8))
                                .lineLimit(q.hasPrefix(ChatForwardDraft.prefix) ? 4 : 2)
                        }
                        .fixedSize(horizontal: false, vertical: true)
                    }
                    let att = ChatAttach.split(split.body)
                    // A text view (press-and-drag selection, our menu on it), not a selectable Text.
                    if !att.text.isEmpty {
                        ChatPlainText(text: att.text, size: (14 * ChatTextScale.factor(textSize)).rounded())
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    // Uploaded files (this Mac's or the thread's stored `att`) as tiles, then the ones that went
                    // as text as preview cards (the raw inlined text stays out of the bubble).
                    ForEach(item.message.attachments.filter { !$0.isImage }) { a in ChatAttachmentTile(attachment: a, auth: auth) }
                    ForEach(att.refs) { r in
                        if r.creative != nil { ChatCreativeCard(ref: r, auth: auth) } else { ChatAttachCard(ref: r) }
                    }
                }
            }
            bottomRow(onDark: true)
        }
        .overlay(alignment: .bottomLeading) { marksOverlay(onDark: true) }
        .font(ChatTextScale.ui(14, level: textSize))
        .foregroundStyle(.white)
        .padding(.horizontal, 14).padding(.top, 9).padding(.bottom, 6)
        .background(
            UnevenRoundedRectangle(topLeadingRadius: 18, bottomLeadingRadius: 18,
                                   bottomTrailingRadius: last ? 6 : 18, topTrailingRadius: 18, style: .continuous)
                .fill(LinearGradient(colors: [Color(hex: 0x5470FF), WS.blue], startPoint: .top, endPoint: .bottom))
        )
        .overlay(
            UnevenRoundedRectangle(topLeadingRadius: 18, bottomLeadingRadius: 18,
                                   bottomTrailingRadius: last ? 6 : 18, topTrailingRadius: 18, style: .continuous)
                .stroke(Color.white.opacity(0.18), lineWidth: 1)
        )
        .shadow(color: WS.blue.opacity(0.18), radius: 6, y: 2)
    }

    // MARK: an agent's

    private var theirs: some View {
        HStack(alignment: .bottom, spacing: 8) {
            Group {
                if last, let agent { ChatAgentFace(agent: agent, onOpen: onAvatar) } else { Color.clear }
            }
            .frame(width: 30, height: 30)
            // No name over the messages; the figure says who (its tip names it, a click opens the profile).
            VStack(alignment: .leading, spacing: 3) {
                agentBubble
                    .overlay(alignment: .bottomTrailing) {
                        if canMark {
                            ChatReactButton(liked: favourite, thumb: reaction, rowHover: hover, onToggle: toggle)
                                .offset(x: 34)
                                .accessibilityHidden(true)
                        }
                    }
            }
            Spacer(minLength: theirGap)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text("\(agent?.name ?? "Agent") said" + (pinned ? ", pinned" : "")))
        .accessibilityActions {
            if canMark {
                ForEach(ChatReaction.offered, id: \.self) { e in
                    Button(e == ChatLocal.heart ? (favourite ? "Unlike" : "Like")
                           : (isOn(e) ? "Remove \(ChatReaction.name(e)) Reaction" : "React with \(ChatReaction.name(e))")) {
                        toggle(e)
                    }
                }
            }
        }
    }

    @ViewBuilder private var agentBubble: some View {
        let plain = ChatSearch.text(of: item)
        let router = widgets.router   // read here, in the body: the closures below run on a click, outside it
        VStack(alignment: .trailing, spacing: 2) {
            Group {
                if let query, !ChatSearch.ranges(query, in: plain).isEmpty {
                    Text(ChatSearch.highlighted(plain, query: query, current: currentOcc, dark: false))
                        .font(ChatTextScale.ui(14, level: textSize)).foregroundStyle(WS.ink)
                        .fixedSize(horizontal: false, vertical: true)
                } else if let info = artifact {
                    // A long report or a big table folds into a card (Open shows it whole).
                    ChatArtifactCard(message: item.message, info: info, auth: auth)
                } else {
                    // `continues` keeps the old chat's footer (thumbs, Copy, time) out of the bubble: the time
                    // is the bubble's own, the rest is the reaction button and the context menu.
                    AssistantMessageView(message: item.message, ents: DialogueEnts.shared.ents(for: item.message, key: thread.chat?.key),
                                         onOpenBlock: { router?.openBlock($0) },
                                         auth: auth, widgets: router?.actions ?? WidgetActions(), continues: true)
                }
            }
            bottomRow(onDark: false)
        }
        .overlay(alignment: .bottomLeading) { marksOverlay(onDark: false) }
        .padding(.horizontal, 14).padding(.top, 10).padding(.bottom, 6)
        .background(WS.soft, in: UnevenRoundedRectangle(topLeadingRadius: first ? 18 : 8, bottomLeadingRadius: last ? 6 : 8,
                                                       bottomTrailingRadius: 18, topTrailingRadius: 18, style: .continuous))
    }

    /// Only plain text folds (an answer with charts, an approval or a plan keeps its own drawing).
    private var artifact: ChatArtifact.Info? {
        let m = item.message
        guard m.blocks.isEmpty, m.gateJSON == nil, m.planJSON == nil, m.askJSON == nil else { return nil }
        return ChatArtifact.detect(m.content)
    }
}

/// The agent answering now: "<Name> is writing" with dots until words come (ChatTypingIndicator in
/// TeamHuddle.swift), then its words as they stream, in its bubble.
private struct LiveBubble: View {
    let turn: LiveTurn
    let agent: AgentInfo
    var auth: AuthStore? = nil
    var first = true
    /// What it is doing now (Dev's status, a tool's phrase); nil: "is writing".
    var status: String? = nil
    var onAvatar: (String) -> Void = { _ in }

    /// ("streamed token by token, crammed"): the messenger never shows the words being written - the
    /// agent's figure and the typing dots, with what it is doing now (a tool's phrase, Dev's status) updating live; the
    /// message is drawn once it is complete (its stored copy, or the finished turn).
    var body: some View {
        HStack(alignment: .bottom, spacing: 8) {
            ChatAgentFace(agent: agent, status: .working, onOpen: onAvatar)
            ChatTypingIndicator(agent: agent, status: status)
            Spacer(minLength: 40)
        }
    }
}

/// /02: Met's change, waiting for the person: what changes (a diff), where, who asks, and the risk. It answers
/// nothing itself: ("we remove the cards where you have to press and hold, and make only Yes or No"),
/// As the web's gate (ai.js gateShow), the answers are Yes / No above the input (GateBar). Edit opens the new
/// values as fields and sends the agent what to change (it re-plans; nothing edited is applied here).
private struct GateCard: View {
    let gate: Gate
    let agent: AgentInfo?
    let account: String?
    let applying: Bool
    /// For the ad preview.
    var auth: AuthStore? = nil
    let onEdit: () -> Void
    var onSendChanges: (String) -> Void = { _ in }
    @State private var editing = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var risk: GateRisk { GateRisk.of(gate) }
    private var heading: String { gate.title.isEmpty ? gate.stepName : gate.title }
    private var who: String { agent?.name ?? "Met" }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            top
            Text(heading).font(LiaFont.ui(15, .semibold)).foregroundStyle(WS.ink)
            if !whereLine.isEmpty {
                HStack(spacing: 6) {
                    Image(systemName: "mappin.and.ellipse").font(.system(size: 10.5)).foregroundStyle(WS.text3)
                    Text(whereLine).font(LiaFont.ui(12)).foregroundStyle(WS.text2).lineLimit(1)
                }
            }
            if editing {
                ChatGateEditor(gate: gate, who: who,
                               onSend: { m in setEditing(false); onSendChanges(m) },
                               onCancel: { setEditing(false) })
                    .transition(.opacity)
            } else {
                if !gate.diff.isEmpty { GateDiffList(gate: gate) }
                tools
            }
            Text("Goes to the journal \u{00b7} you can undo it").font(LiaFont.ui(11.5)).foregroundStyle(WS.text3)
        }
        .padding(14)
        .background(WS.surface, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).stroke(risk.color.opacity(0.55), lineWidth: 1))
        .overlay(alignment: .leading) {
            UnevenRoundedRectangle(topLeadingRadius: 18, bottomLeadingRadius: 18, style: .continuous)
                .fill(risk.color).frame(width: 4)
        }
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text(a11yLabel))
        .accessibilityAction(named: Text("Edit")) { edit() }
        .onAppear { ChatA11y.announce("\(who) needs your approval: \(heading). \(risk.label).", once: gate.planId) }
    }

    private var top: some View {
        HStack(spacing: 8) {
            if let agent { AgentAvatar(agent: agent, size: 22, status: .waiting) }
            Text("\(who) prepared a change").font(LiaFont.ui(12.5)).foregroundStyle(WS.text2)
            Spacer()
            HStack(spacing: 5) {
                Image(systemName: risk.symbol).font(.system(size: 10, weight: .semibold))
                Text(gate.final ? "Turns it on" : risk.label)
            }
            .font(LiaFont.ui(11.5, .semibold)).foregroundStyle(risk.ink)
            .padding(.horizontal, 9).frame(height: 22).background(risk.soft, in: Capsule())
        }
    }

    /// Edit and the ad preview only; Yes / No are above the input.
    private var tools: some View {
        HStack(spacing: 8) {
            Button("Edit", action: edit)
                .buttonStyle(WSButtonStyle(small: true))
                .liaHoverWash(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .disabled(applying)
            if let auth, let id = ChatAdPreviewButton.adId(gate) { ChatAdPreviewButton(adId: id, auth: auth) }
            Spacer()
        }
    }

    private func edit() {
        guard !applying else { return }
        if gate.diff.isEmpty { onEdit() } else { setEditing(true) }
    }

    private func setEditing(_ on: Bool) {
        if reduceMotion { editing = on } else { withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) { editing = on } }
    }

    /// Where the change lands: the client's account and the kind of object, when the gate names them.
    private var whereLine: String {
        var parts: [String] = []
        if let account, !account.isEmpty { parts.append(account) }
        let kind = gate.entityType.isEmpty ? gate.entity : gate.entityType
        if !kind.isEmpty { parts.append(kind.replacingOccurrences(of: "_", with: " ").capitalized) }
        return parts.joined(separator: " \u{00b7} ")
    }

    private var a11yLabel: String {
        var s = "Approval from \(who): \(heading). \(risk.label)."
        if !whereLine.isEmpty { s += " In \(whereLine)." }
        s += " Answer Yes or No above the message box."
        return s
    }
}

/// The open approval's answers, one line above the input (ai.js gateShow: "Waiting for your answer" and the answers
/// as segments). Yes is the filled one. Every answer is a click: no keyboard shortcut answers here, a
/// digit typed into the box stays text (onDigit is false; Gate.digitAnswer never applies a write), and Return in the
/// box sends the message. The answer goes through TeamChatModel.answer exactly as before.
private struct GateBar: View {
    let gate: Gate
    let mode: RunMode
    let applying: Bool
    let answer: (GateAnswer) -> Void

    var body: some View {
        HStack(spacing: 10) {
            PulseDot()
            Text(applying ? "Applying" : "Waiting for your answer")
                .font(LiaFont.ui(13)).foregroundStyle(WS.text2).lineLimit(1).layoutPriority(-1)
            Spacer(minLength: 8)
            if applying { ProgressView().controlSize(.small) }
            HStack(spacing: 6) {
                ForEach(gate.options(mode: mode), id: \.self) { a in
                    Button(a.label) { answer(a) }
                        .buttonStyle(WSButtonStyle(primary: a == .yes, small: true))
                        .liaHoverWash(RoundedRectangle(cornerRadius: 12, style: .continuous), ink: a == .yes)
                        .disabled(applying)
                        .liaTip(a == .all || (a == .yes && gate.final) ? tip(a) : nil)
                        .accessibilityLabel(Text(a.label))
                }
            }
            .fixedSize()
            .layoutPriority(1)
        }
        .frame(minHeight: 34)
        .padding(.horizontal, 6)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text("Waiting for your answer"))
    }

    private func tip(_ a: GateAnswer) -> String {
        switch a {
        case .yes: return gate.final ? "Turn it on" : "Apply this change"
        case .all: return "Apply this and the next changes of this task"
        case .no: return "Decline: nothing is sent"
        }
    }
}

// MARK: - the agent's browser

private struct AgentBrowserPane: View {
    let agent: AgentInfo
    @ObservedObject var browser: BrowserModel
    let status: String
    let running: Bool
    let onTakeOver: () -> Void
    /// Continue in the main window where the agent was.
    var onOpenInMain: (URL) -> Void = { _ in }
    /// This conversation's messages (the agent's tools, from each answer's timeline, join the browser's steps).
    var items: [TeamItem] = []
    /// The agents whose browsers this conversation can show, and the switch between them.
    var chips: [AgentInfo] = []
    var busy: @MainActor (String) -> Bool = { _ in false }
    var onPickBrowser: (String) -> Void = { _ in }
    /// 0.2.11: the conversation whose agents see this pane's tab, and the name its chip says (ScreenSeenChip).
    var seenChat: TeamChatModel? = nil
    var seenName = "Lia"
    /// Folds the right side to a spine (nil: no button).
    var onFold: (() -> Void)? = nil
    /// The log sheet, with the steps as they were when it opened.
    @State private var logEntries: [AgentLog.Entry]?
    /// Server: the agent's own dialogue's work items join its browser tasks in "What did <Agent> do?".
    private var workSource: ChatAgentLogSheet.WorkSource? {
        guard let c = seenChat else { return nil }
        return ChatAgentLogSheet.WorkSource(auth: c.auth, profile: c.profile, dlg: DialogueSummary.dlg(forAgent: agent.id))
    }

    var body: some View {
        VStack(spacing: 10) {
            paneHeader
            pageArea
        }
        .padding(12)
        .background(Color.dyn(0x15181C, 0xF6F7F9))
        .liaModal(isPresented: logBinding) {
            ChatAgentLogSheet(name: agent.name, entries: logEntries ?? [], history: AgentHistoryStore.shared(for: browser),
                              work: workSource) { logEntries = nil }
        }
    }

    private var logBinding: Binding<Bool> {
        Binding(get: { logEntries != nil }, set: { if !$0 { logEntries = nil } })
    }

    private var logButton: some View {
        Button { logEntries = ChatAgentSteps.entries(agent: agent.id, items: items, browser: browser.agent.log.recent) } label: {
            Label("What did \(agent.name) do?", systemImage: "list.bullet.rectangle")
        }
        .buttonStyle(WSButtonStyle(small: true))
        .liaHoverWash(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .accessibilityHint(Text("Lists \(agent.name)'s last steps, newest first"))
    }

    private var paneHeader: some View {
        HStack(spacing: 6) {
            AgentBrowserChips(agents: chips, shown: agent.id, busy: busy, onPick: onPickBrowser)
            Text("\(agent.name)'s browser").font(LiaFont.ui(12, .semibold)).foregroundStyle(WS.text2).padding(.trailing, 6)
            ForEach(browser.tabs.prefix(5)) { t in AgentPaneTabChip(tab: t, browser: browser) }
            Spacer(minLength: 6)
            logButton
            // One control: Take over (steps, Stop in a progress ring) while working, Open in main window after.
            AgentTakeOverButton(browser: browser, name: agent.name, tint: Color(hex: agent.colorHex), running: running,
                                onTakeOver: onTakeOver, onOpenInMain: onOpenInMain)
            if let onFold { foldButton(onFold) }
        }
    }

    /// The fold at the header's far right.
    private func foldButton(_ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: "sidebar.right").font(.system(size: 13, weight: .medium)).foregroundStyle(WS.text2)
                .frame(width: 28, height: 28)
                .contentShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
        }
        .buttonStyle(.liaPlain)
        .liaHoverWash(RoundedRectangle(cornerRadius: 9, style: .continuous))
        .liaTip("Hide \(agent.name)'s browser", kbd: "\u{2318}\u{2325}B")
        .accessibilityLabel(Text("Hide \(agent.name)'s browser"))
    }

    private var pageArea: some View {
        ZStack {
            WS.surface
            if let t = browser.selected {
                AgentPage(tab: t, browser: browser, agent: agent, onTakeOver: onTakeOver).id(t.id)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous)
            .stroke(running ? Color(hex: agent.colorHex).opacity(0.55) : WS.line, lineWidth: running ? 2 : 1))
        .shadow(color: running ? Color(hex: agent.colorHex).opacity(0.25) : .clear, radius: 14)
    }
}

// MARK: - the right side folded

/// The unfolded pane's last width (see ConversationSheet.paneWidth).
private final class PaneWidthBox {
    var width: CGFloat = 0
}

/// Which conversations have their right side folded, for the app's life only (never stored): a conversation opens
/// unfolded unless it was folded earlier in this run. Also the Activity steps that came in while folded.
@MainActor
private final class PaneFoldStore: ObservableObject {
    static let shared = PaneFoldStore()
    @Published private(set) var folded: Set<String> = []
    @Published private(set) var steps: [String: Int] = [:]
    private var foldedAt: [String: Date] = [:]

    func isFolded(_ key: String) -> Bool { folded.contains(key) }

    func set(_ on: Bool, key: String) {
        if on {
            guard !folded.contains(key) else { return }
            folded.insert(key)
            foldedAt[key] = Date()
        } else {
            guard folded.contains(key) else { return }
            folded.remove(key)
            steps[key] = nil
        }
    }

    /// Seconds since the person folded it (nil: not folded).
    func sinceFold(_ key: String) -> Double? {
        guard folded.contains(key), let d = foldedAt[key] else { return nil }
        return Date().timeIntervalSince(d)
    }

    func countStep(_ key: String) { steps[key, default: 0] += 1 }
}

/// The folded right side, 54 pt (the mockup agent-browser-collapse.html): unfold on top, the agent with a green dot
/// while it works, up to 4 of its browser's tabs (or nothing for the Canvas), the Activity steps that came while
/// folded, and the page's title (the Canvas item's) written up the spine.
private struct FoldSpine: View {
    let agent: AgentInfo?
    let browser: BrowserModel?
    let canvasTitle: String?
    let running: Bool
    let steps: Int
    let flash: Bool
    let onUnfold: () -> Void
    let onNewPlace: (PaneFold.Trigger) -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// The spine's own entrance (opacity and a short slide), the only animated part of the fold.
    @State private var shown = false

    private var showLabel: String {
        if canvasTitle != nil { return "Show the canvas" }
        return agent.map { "Show \($0.name)'s browser" } ?? "Show the browser"
    }

    private var tint: Color { Color(hex: agent?.colorHex ?? 0x3B5BFD) }

    var body: some View {
        VStack(spacing: 10) {
            Button(action: onUnfold) {
                Image(systemName: "sidebar.left").font(.system(size: 14, weight: .medium)).foregroundStyle(WS.text2)
                    .frame(width: 34, height: 34)
                    .contentShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
            }
            .buttonStyle(.liaPlain)
            .liaHoverWash(RoundedRectangle(cornerRadius: 11, style: .continuous))
            .liaTip(showLabel, kbd: "\u{2318}\u{2325}B")
            .accessibilityLabel(Text(showLabel))
            if let a = agent {
                AgentAvatar(agent: a, size: 28)
                    .overlay(alignment: .bottomTrailing) {
                        if running {
                            Circle().fill(Color(hex: 0x2BB673)).frame(width: 9, height: 9)
                                .overlay(Circle().stroke(Color.dyn(0x15181C, 0xF6F7F9), lineWidth: 2))
                                .offset(x: 2, y: 1)
                        }
                    }
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(Text(running ? "\(a.name) is working" : a.name))
            }
            if let b = browser {
                SpineBrowser(browser: b, steps: steps, onNewPlace: onNewPlace)
            } else {
                SpineSteps(count: steps)
                SpineVerticalTitle(text: canvasTitle ?? "")
            }
        }
        .padding(.vertical, 12)
        .frame(width: 54)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(Color.dyn(0x15181C, 0xF6F7F9))
        .overlay(alignment: .leading) {
            Rectangle().fill(tint).frame(width: 3).opacity(flash ? 1 : 0).allowsHitTesting(false)
        }
        .opacity(shown || reduceMotion ? 1 : 0)
        .offset(x: shown || reduceMotion ? 0 : 10)
        .onAppear {
            guard !shown, !reduceMotion else { return }
            withAnimation(.easeOut(duration: 0.18)) { shown = true }
        }
        .accessibilityElement(children: .contain)
    }
}

/// The agent's open tabs (favicons) and the page in front; it also tells the sheet when the agent opens a tab, brings
/// another to the front or goes to another page (each unfolds the right side).
private struct SpineBrowser: View {
    @ObservedObject var browser: BrowserModel
    let steps: Int
    let onNewPlace: (PaneFold.Trigger) -> Void

    var body: some View {
        VStack(spacing: 10) {
            if !browser.tabs.isEmpty {
                VStack(spacing: 7) {
                    ForEach(browser.tabs.prefix(4)) { t in SpineFavicon(tab: t) }
                }
                .padding(.vertical, 8)
                .overlay(alignment: .top) { Rectangle().fill(WS.line).frame(width: 30, height: 1) }
                .overlay(alignment: .bottom) { Rectangle().fill(WS.line).frame(width: 30, height: 1) }
            }
            SpineSteps(count: steps)
            if let t = browser.selected {
                SpineTabPlace(tab: t, onNewPlace: onNewPlace).id(t.id)
            } else {
                Spacer(minLength: 0)
            }
        }
        .onChange(of: browser.tabs.count) { old, new in if new > old { onNewPlace(.newTab) } }
        .onChange(of: browser.selectedID) { _, _ in onNewPlace(.newTab) }
    }
}

private struct SpineFavicon: View {
    @ObservedObject var tab: BrowserTab
    var body: some View {
        Group {
            if let img = tab.favicon {
                Image(nsImage: img).resizable().interpolation(.high).aspectRatio(contentMode: .fit)
            } else {
                Image(systemName: "globe").font(.system(size: 12, weight: .medium)).foregroundStyle(WS.text3)
            }
        }
        .frame(width: 18, height: 18)
        .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
        .opacity(0.85)
        .accessibilityLabel(Text(tab.displayTitle))
    }
}

/// The selected tab's title (or host) up the spine; its page moving to another host or path is a new place.
private struct SpineTabPlace: View {
    @ObservedObject var tab: BrowserTab
    let onNewPlace: (PaneFold.Trigger) -> Void
    var body: some View {
        SpineVerticalTitle(text: tab.isStart ? "" : tab.displayTitle)
            .onChange(of: tab.url) { old, new in if PaneFold.isNewPlace(from: old, to: new) { onNewPlace(.navigated) } }
    }
}

/// The steps that came while folded (hidden at 0).
private struct SpineSteps: View {
    let count: Int
    var body: some View {
        if count > 0 {
            Text(verbatim: count > 99 ? "99+" : String(count))
                .font(LiaFont.ui(10.5, .bold)).foregroundStyle(WS.text2)
                .padding(.horizontal, 5).frame(minWidth: 18, minHeight: 18)
                .background(WS.soft, in: Capsule())
                .accessibilityLabel(Text(count == 1 ? "1 new step" : "\(count) new steps"))
        }
    }
}

/// One line written up the spine (rotated -90\u{00b0}), from the top, cut at the spine's end.
private struct SpineVerticalTitle: View {
    let text: String
    var body: some View {
        GeometryReader { g in
            Text(verbatim: text)
                .font(LiaFont.ui(11.5, .semibold)).foregroundStyle(WS.text3)
                .lineLimit(1).truncationMode(.tail)
                .frame(width: max(0, g.size.height - 4), alignment: .trailing)
                .rotationEffect(.degrees(-90))
                .frame(width: g.size.width, height: g.size.height)
        }
        .padding(.top, 4)
        .accessibilityHidden(text.isEmpty)
        .accessibilityLabel(Text(verbatim: text))
    }
}

/// "Open in Main Window" for the agent's current page (hidden while nothing is open).
private struct AgentOpenInMainButton: View {
    @ObservedObject var tab: BrowserTab
    let action: (URL) -> Void

    var body: some View {
        if !tab.isStart, let url = tab.url {
            Button { action(url) } label: {
                Label("Open in Main Window", systemImage: "arrow.up.forward.app")
            }
            .buttonStyle(WSButtonStyle(small: true))
            .liaHoverWash(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .accessibilityHint(Text("Opens \(url.host ?? "this page") in a new tab of the main window"))
        }
    }
}

private struct AgentTabChip: View {
    @ObservedObject var tab: BrowserTab
    let selected: Bool
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            Text(tab.displayTitle).font(LiaFont.ui(12)).lineLimit(1).foregroundStyle(selected ? WS.ink : WS.text2)
                .padding(.horizontal, 10).frame(height: 28).frame(maxWidth: 170)
                .background(selected ? WS.surface : Color.clear, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .buttonStyle(.liaPlain)
        .liaHoverWash(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}

/// The agent's page laid out as a full-HD screen (1920 points wide) and scaled down to fit the pane, so the whole
/// page shows as on a desktop. The scale is the host view's bounds (AppKit), so a click after Take over lands where
/// it was aimed; the overlay is drawn in the same 1920-wide space and scaled with it.
private struct AgentPage: View {
    @ObservedObject var tab: BrowserTab
    let browser: BrowserModel
    let agent: AgentInfo
    let onTakeOver: () -> Void
    var body: some View {
        ZStack {
            if tab.isStart {
                Text("Nothing open yet").font(LiaFont.ui(13)).foregroundStyle(WS.text3)
            } else {
                GeometryReader { g in
                    let k = max(0.05, g.size.width / FullHDWebHost.width)
                    ZStack(alignment: .topLeading) {
                        FullHDWebHost(webView: tab.webView)
                        // /03/04: the glow in the agent's colour; a click on the page takes over.
                        AgentOverlay(agent: browser.agent, tabID: tab.id, tint: Color(hex: agent.colorHex), name: agent.name,
                                     onTakeOver: onTakeOver, web: browser.web)
                            .frame(width: FullHDWebHost.width, height: g.size.height / k)
                            .scaleEffect(k, anchor: .topLeading)
                            .frame(width: g.size.width, height: g.size.height, alignment: .topLeading)
                    }
                    .clipped()
                }
                // Our translation works in the pane too (the agent reads and sees it as shown)
                TranslateTabLayer(webView: tab.webView, url: tab.url, isLoading: tab.isLoading)
            }
        }
        .onAppear { tab.loadIfPending() }
    }
}

/// Hosts the tab's web view at a fixed logical width (1920) inside a view whose bounds are scaled to the pane.
struct FullHDWebHost: NSViewRepresentable {
    static let width: CGFloat = 1670   // the page drawn ~15% larger than full HD (too small)
    let webView: WKWebView

    func makeNSView(context: Context) -> FullHDHostView { FullHDHostView(webView: webView) }
    func updateNSView(_ nsView: FullHDHostView, context: Context) { nsView.adopt(webView) }
}

final class FullHDHostView: NSView {
    private(set) var webView: WKWebView

    init(webView: WKWebView) {
        self.webView = webView
        super.init(frame: .zero)
        wantsLayer = true
        adopt(webView)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override var isFlipped: Bool { true }

    /// A web view lives in one place at a time: take it back if another host had it.
    func adopt(_ w: WKWebView) {
        if w !== webView { webView = w }
        guard w.superview !== self else { return }
        w.removeFromSuperview()
        w.translatesAutoresizingMaskIntoConstraints = true
        w.autoresizingMask = []
        addSubview(w)
        fit()
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        fit()
    }

    override func layout() {
        super.layout()
        fit()
    }

    /// Bounds 1920 wide (and as tall as the pane's shape allows); the web view fills them, so its CSS viewport is
    /// 1920 wide and AppKit scales drawing and hit-testing together.
    private func fit() {
        guard frame.width > 1, frame.height > 1 else { return }
        let k = frame.width / FullHDWebHost.width
        let size = NSSize(width: FullHDWebHost.width, height: (frame.height / k).rounded())
        if bounds.size != size { setBoundsSize(size) }
        let r = NSRect(origin: .zero, size: size)
        if webView.superview === self, webView.frame != r { webView.frame = r }
    }
}

/// The entity / namesake popups (EntityPopup) post these: "Use" puts the text into this composer,
/// "Open creative" opens the ad in Ads Manager in the workspace's browser.
private struct PopupSignals: ViewModifier {
    @Binding var text: String
    let onFocus: () -> Void
    let ws: WorkspaceModel
    /// The side panel's composer stands aside while a sheet is open (the popup's "Use" goes to one composer).
    var active = true

    func body(content: Content) -> some View {
        content
            .onReceive(NotificationCenter.default.publisher(for: .liaPutText)) { n in
                guard active, let s = n.userInfo?["text"] as? String else { return }
                text = EntityChips.putText(text, s)
                onFocus()
            }
            .onReceive(NotificationCenter.default.publisher(for: .liaOpenAd)) { n in
                guard active, let id = n.userInfo?["id"] as? String, !id.isEmpty,
                      let url = URL(string: "https://adsmanager.facebook.com/adsmanager/manage/ads?selected_ad_ids=" + id),
                      let b = ws.currentBrowser else { return }
                b.open(url)
                ws.sheet = nil
            }
    }
}
