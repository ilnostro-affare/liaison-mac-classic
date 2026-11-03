import SwiftUI

/// Where the main column is (ai.js setView / aiUrl: /new, /chat/<id>, /chats, /projects, /project/<id>, /relay).
enum Route: Hashable {
    case chat(String)
    case chats
    case projects
    case project(String)
    case relay
}

/// The browser's place in one chat: open or not, its share of the space right of the sidebar, full screen.
struct BrowserLayout: Codable, Equatable {
    var open = false
    var share = AppConfig.browserDefaultShare
    var full = false

    private static let key = "lia_browser_layouts"
    static func load() -> [String: BrowserLayout] {
        guard let d = UserDefaults.standard.data(forKey: key),
              let m = try? JSONDecoder().decode([String: BrowserLayout].self, from: d) else { return [:] }
        return m
    }
    static func save(_ m: [String: BrowserLayout]) {
        // Only chats that differ from the default are worth keeping; the newest few hundred is plenty.
        let kept = m.filter { $0.value != BrowserLayout() }
        if let d = try? JSONEncoder().encode(kept) { UserDefaults.standard.set(d, forKey: key) }
    }
}

/// The window's state: the route, one live view model per open chat (so a turn keeps streaming and
/// its sidebar dot keeps spinning while another chat is on screen), the library and the browser.
@MainActor
final class AppModel: ObservableObject {
    let auth: AuthStore
    let library: LibraryStore
    /// One browser per chat: its tabs, whether it is open, its width and full screen belong to that
    /// chat and come back with it; other screens show no browser. A new chat starts with it closed.
    private var browsers: [String: BrowserModel] = [:]
    /// Chat ids by last use, newest last: past `maxBrowsers` the oldest browser is let go (never the current chat's).
    private var browserOrder: [String] = []
    static let maxBrowsers = 8
    var browser: BrowserModel { browser(for: currentChatId ?? "_none") }
    func browser(for chat: String) -> BrowserModel {
        browserOrder.removeAll { $0 == chat }
        browserOrder.append(chat)
        if let b = browsers[chat] { return b }
        // The chat's saved tabs come back (BrowserMemory), only the selected one loading; "_none" has no chat.
        let b = BrowserModel(account: auth.activeId, chat: chat == "_none" ? nil : chat)
        browsers[chat] = b
        while browsers.count > Self.maxBrowsers,
              let old = browserOrder.first(where: { $0 != chat && $0 != currentChatId && browsers[$0] != nil }) {
            releaseBrowser(old)
        }
        return b
    }

    /// Lia 2.0 starts a change: the chat's browser opens (if it was closed) and plays the trace over Ads Manager.
    /// Reads do not open it. Stop on the overlay stops the turn.
    func agent(_ e: AgentEvent, chat: String, vm: ChatViewModel?) {
        if case let .browserTask(task, goal, tab, url) = e {   // The open web, in this chat's browser
            if !browserLayout(chat).open { withAnimation(.easeOut(duration: 0.18)) { updateBrowserLayout(chat) { $0.open = true } } }
            let b = browser(for: chat)
            let auth = self.auth
            b.agent.log.chatId = chat
            b.agent.log.send = { c, events in await LiaAPI(auth: auth).agentLog(chatId: c, events: events) }
            vm?.webRunning = true
            vm?.onStopWeb = { [weak b] in b?.agent.stop() }
            b.agent.onWebLabel = { [weak vm] s in vm?.webStatus = s }
            b.web.onEnd = { [weak vm, weak b] in vm?.webRunning = false; vm?.webStatus = ""; b?.agent.onWebLabel = nil }
            b.web.run(task: task, goal: goal, tab: tab, url: url, api: LiaAPI(auth: auth), chatId: chat) { [weak vm] message in
                vm?.sendBrowserResult(message)
            }
            return
        }
        if case let .intent(_, tool, _, door) = e, door || AgentRun.isDoor(tool) {
            if !browserLayout(chat).open { withAnimation(.easeOut(duration: 0.18)) { updateBrowserLayout(chat) { $0.open = true } } }
        } else if browsers[chat] == nil {
            return   // nothing to draw on, and nothing a read needs to open
        }
        let b = browser(for: chat)
        b.agent.onStop = { [weak vm] in vm?.stop() }
        let auth = self.auth
        b.agent.locator.ask = { input, questions in await LiaAPI(auth: auth).locateReply(input: input, questions: questions, chatId: chat) }
        b.agent.log.chatId = chat
        b.agent.log.send = { c, events in await LiaAPI(auth: auth).agentLog(chatId: c, events: events) }
        let live = vm?.live?.ents, doc = vm?.doc.ents
        b.agent.feed(e, defaultAccount: vm?.doc.accounts.first?.id ?? mainAccountId,
                     kindOf: { live?[$0]?.kind ?? doc?[$0]?.kind },
                     parentOf: { live?[$0]?.parent ?? doc?[$0]?.parent })
    }

    /// What Lia sees of this chat's browser with a message - only a browser the chat has: every tab's address
    /// and title, the front tab's page (text and controls), the others' first lines. Tabs not loaded yet go by name.
    func browserContext(chat: String) async -> [String: Any]? {
        guard let b = browsers[chat] else { return BrowserContext.payload([]) }   // no tabs yet: Lia can still open one
        var tabs: [BrowserContext.Tab] = []
        for t in b.tabs where !t.isStart {
            let front = t.id == b.selectedID
            var text = ""
            // loadedWebView, never webView: reading a tab that has no WebKit view yet must not make one
            if t.pendingURL == nil, let wv = t.loadedWebView, wv.url != nil {
                text = await AgentBridge.snapshot(wv, maxText: front ? 9000 : 1500, maxControls: front ? 150 : 0, store: false).text
            }
            tabs.append(.init(id: t.shortID, title: t.displayTitle, url: (t.loadedWebView?.url ?? t.pendingURL ?? t.url)?.absoluteString ?? "", active: front, text: text))
        }
        return BrowserContext.payload(tabs)
    }

    /// Lets a chat's browser go: its pages stop (media too) before the web views are dropped. Its tabs stay saved
    /// (BrowserMemory) and come back when the chat is opened again; only `delete` forgets them.
    func releaseBrowser(_ chat: String) {
        browserOrder.removeAll { $0 == chat }
        guard let b = browsers.removeValue(forKey: chat) else { return }
        b.shutDown()
    }
    @Published private(set) var browserLayouts: [String: BrowserLayout] = BrowserLayout.load()
    func browserLayout(_ chat: String) -> BrowserLayout { browserLayouts[chat] ?? BrowserLayout() }
    func updateBrowserLayout(_ chat: String, _ change: (inout BrowserLayout) -> Void) {
        var l = browserLayout(chat)
        let wasOpen = l.open
        change(&l)
        browserLayouts[chat] = l
        BrowserLayout.save(browserLayouts)
        // Closing the panel keeps the chat's tabs (decision 3: they come back with it); media stops so nothing plays
        // behind a closed panel. The LRU of 8 and chat deletion still release the web views.
        if wasOpen && !l.open { browsers[chat]?.pauseMedia() }
    }

    /// ⌘T: a new tab in the current chat's browser, which opens if it was closed. No chat on screen: nothing.
    func newBrowserTab() {
        guard let c = currentChatId else { return }
        if !browserLayout(c).open { withAnimation(.easeOut(duration: 0.18)) { updateBrowserLayout(c) { $0.open = true } } }
        browser(for: c).openHome()
    }
    /// A link from Lia's text: the current chat's browser, opened if it was closed.
    func openInBrowser(_ url: URL) {
        guard let c = currentChatId else { ExternalLink.openInSystemBrowser(url); return }
        browser(for: c).open(url)
        if !browserLayout(c).open { withAnimation(.easeOut(duration: 0.18)) { updateBrowserLayout(c) { $0.open = true } } }
    }
    @Published var route: Route { didSet { if route != .relay { relayPeek = false } } }
    /// On the Relay the sidebar steps aside; the rail's burger brings it back over the page (ai.js .jrn-side.is-peek).
    @Published var relayPeek = false
    /// The collapsed sidebar shown over the page while its control or the sidebar itself is hovered.
    @Published var sidebarPeek = false
    private var peekJob: DispatchWorkItem?

    func startSidebarPeek() {
        // At once (the peek came with a delay).
        peekJob?.cancel(); peekJob = nil
        guard !sidebarPeek else { return }
        withAnimation(.easeOut(duration: 0.14)) { sidebarPeek = true }
    }
    func keepSidebarPeek() { peekJob?.cancel(); peekJob = nil }
    /// The Relay's burger opens its peek on hover too (a short dwell, so passing over it does nothing).
    func hoverRelayPeek(_ inside: Bool) {
        peekJob?.cancel(); peekJob = nil
        guard inside, !relayPeek else { return }
        let job = DispatchWorkItem { [weak self] in withAnimation(.easeOut(duration: 0.16)) { self?.relayPeek = true } }
        peekJob = job
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: job)
    }
    func endSidebarPeek() {
        peekJob?.cancel()
        let job = DispatchWorkItem { [weak self] in withAnimation(.easeOut(duration: 0.16)) { self?.sidebarPeek = false } }
        peekJob = job
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: job)   // time to reach the sidebar from the button
    }
    /// A chat the person opened with New and has not written in yet (ai.js _isNewDraft).
    @Published private(set) var draftId: String
    @Published var searchOpen = false
    @Published var sidebarSearch = ""
    /// Settings opens in its own window (SettingsWindow); false closes it.
    @Published var showSettings = false {
        didSet {
            guard showSettings != oldValue else { return }
            if showSettings {
                SettingsWindow.shared.closing = { [weak self] in self?.showSettings = false }
                SettingsWindow.shared.show(app: self, tab: settingsTab)
            } else { SettingsWindow.shared.close() }
        }
    }
    var settingsTab = "general"
    func openSettings(_ tab: String = "general") {
        settingsTab = tab
        if showSettings { SettingsWindow.shared.show(app: self, tab: tab) } else { showSettings = true }
    }
    /// The chat menu's Rename and Delete, asked from the sidebar or the chat header; answered by the window.
    @Published var renameRequest: ChatSummary?
    /// The + menu's "Start a new project".
    @Published var newProjectRequest = false
    @Published var deleteRequest: ChatSummary?
    @Published private(set) var doneDots: Set<String> = []
    @Published private(set) var busyIds: Set<String> = []
    private var models: [String: ChatViewModel] = [:]

    /// The app's one model, for views drawn outside the main window's environment (a chat block in another window).
    static weak var current: AppModel?

    init(auth: AuthStore) {
        self.auth = auth
        self.library = LibraryStore(auth: auth)
        let id = ChatID.make()
        draftId = id
        route = .chat(id)
        AppModel.current = self
    }

    var currentChatId: String? { if case .chat(let id) = route { return id } else { return nil } }

    func model(for id: String) -> ChatViewModel {
        if let m = models[id] { return m }
        let m = ChatViewModel(auth: auth, chatId: id)
        m.fallbackAccountName = { [weak self] in self?.mainAccountName }
        m.onTurnFinished = { [weak self] in
            guard let self else { return }
            if self.currentChatId != id { self.doneDots.insert(id) }
            if self.draftId == id { self.draftId = ChatID.make() }
            Task { await self.library.reload() }
        }
        m.onAgent = { [weak self, weak m] e in self?.agent(e, chat: id, vm: m) }
        m.browserContext = { [weak self] in await self?.browserContext(chat: id) }
        m.onAgentAnswer = { [weak self, weak m] e in
            guard let self, let b = self.browsers[id] else { return }
            b.agent.answered(e, defaultAccount: m?.doc.accounts.first?.id ?? self.mainAccountId)
        }
        m.onBusyChanged = { [weak self] busy in
            if busy { self?.busyIds.insert(id) } else { self?.busyIds.remove(id) }
        }
        m.onTitled = { [weak self] _ in Task { await self?.library.reload() } }
        models[id] = m
        return m
    }

    /// Sidebar dot: busy while a turn runs, done once it finished off screen (ai.js navDotState).
    func dotState(_ id: String) -> ChatDot {
        if busyIds.contains(id) { return .busy }
        if doneDots.contains(id) { return .done }
        return .idle
    }

    func open(_ id: String) {
        doneDots.remove(id)
        route = .chat(id)
    }

    /// New (⌘N): the current empty draft, or a fresh one.
    func newChat(project: String? = nil) {
        if let m = models[draftId], !m.messages.isEmpty || m.isBusy { draftId = ChatID.make() }
        let m = model(for: draftId)
        if let project { m.doc.project = project }
        route = .chat(draftId)
    }

    var isDraftOnScreen: Bool { currentChatId == draftId && (models[draftId]?.messages.isEmpty ?? true) }

    // MARK: main ad account (Settings), used when a chat has none of its own

    @Published private(set) var mainAccountId: String?
    var mainAccountName: String? {
        guard let id = mainAccountId else { return nil }
        return library.accounts.first { $0.id == id }?.name ?? id
    }

    func setMainAccount(_ id: String?) { mainAccountId = id }

    func boot() async {
        async let s: Void = library.reload()
        async let p: Void = library.loadProfile()
        async let a: Void = library.loadAccounts()
        _ = await (s, p, a)
        mainAccountId = await LiaAPI(auth: auth).defaultAccountId()
        await library.loadRelayUnread()
        await checkMetaNudge()
    }

    /// "Connect Meta to see your data" / "Your Meta connection expired" (shell.js cxMaybePrompt): asked once per launch,
    /// a little after the first paint; expired is news and shows even while a snooze runs.
    @Published var metaNudge: String?
    private static var nudgeAsked = false

    func checkMetaNudge() async {
        guard !Self.nudgeAsked else { return }
        Self.nudgeAsked = true
        try? await Task.sleep(nanoseconds: 1_200_000_000)
        let api = LiaAPI(auth: auth)
        if let s = await api.metaConnectionState(), s.state != "connected", s.prompt || s.state == "expired", !showSettings {
            metaNudge = s.state == "expired" ? "expired" : "missing"
        }
        // The billing prompt waits behind the Meta one and never stacks on it.
        try? await Task.sleep(nanoseconds: 1_400_000_000)
        guard metaNudge == nil, !showSettings, let b = await api.billingState(), b.prompt else { return }
        billingNudge = BillingNudge(plan: b.plan?.isEmpty == false ? b.plan! : "Your plan", pastDue: b.state == "past_due")
    }

    struct BillingNudge: Equatable { let plan: String; let pastDue: Bool }
    /// "Your payment did not go through" / "Your plan is no longer active" (shell.js bxRender).
    @Published var billingNudge: BillingNudge?

    /// "Fix payment" goes to Stripe, not to our Billing tab. On hold: Stripe's open invoice
    /// (settings.js "Renew", data-payurl), else the portal where the card is changed. Ended: Checkout for the plan
    /// it named. A plan the app cannot name falls back to Billing, where the plans are chosen.
    func fixPayment(_ b: BillingNudge) {
        billingNudge = nil
        let auth = self.auth
        Task {
            if b.pastDue {
                if let u = await LiaAPI(auth: auth).billingDetail()?.openInvoiceURL.flatMap(URL.init(string:)) {
                    ExternalLink.openInSystemBrowser(u)
                } else {
                    await StripeOpen.portal(auth: auth)
                }
            } else if let pid = StripeCheckout.planId(named: b.plan) {
                await StripeOpen.checkout(planId: pid, auth: auth)
            } else {
                openSettings("billing")
            }
        }
    }

    // MARK: chat ops (ai.js openChatMenu)

    func pin(_ c: ChatSummary) { chatOp(c.starred ? "unstar" : "star", id: c.id) }

    func rename(_ id: String, to title: String) {
        let t = String(title.trimmingCharacters(in: .whitespacesAndNewlines).prefix(120))
        guard !t.isEmpty else { return }
        models[id]?.doc.title = t
        chatOp("rename", id: id, value: t)
    }

    func move(_ id: String, toProject p: String?) {
        models[id]?.doc.project = p
        chatOp("set_project", id: id, value: p)
    }

    func delete(_ id: String) {
        UserDefaults.standard.removeObject(forKey: "lia_haccs_\(id)")
        models[id]?.stop()
        models[id] = nil
        releaseBrowser(id)
        BrowserMemory.forget(chat: id, account: auth.activeId)
        if browserLayouts[id] != nil { browserLayouts[id] = nil; BrowserLayout.save(browserLayouts) }
        if currentChatId == id { newChat() }
        chatOp("delete", id: id)
    }

    private func chatOp(_ op: String, id: String, value: String? = nil) {
        let api = LiaAPI(auth: auth)
        Task {
            try? await api.chatOp(op, id: id, value: value)
            await library.reload()
        }
    }

    func createProject(name: String, account: String? = nil) async {
        try? await LiaAPI(auth: auth).createProject(name: name, account: account)
        await library.reload()
    }
}

enum ChatDot { case idle, busy, done }
