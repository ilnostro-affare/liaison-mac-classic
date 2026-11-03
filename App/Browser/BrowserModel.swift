import SwiftUI
import WebKit
import os

/// The right-hand browser: a plain browser, nothing of Liaison's own in it.
/// Always open, never closed; the person signs in to Meta, Google or anything else here.
///
/// Isolation rules:
/// Its own persistent data store, never `.default`: the Liaison session never reaches it,
/// and nothing the person signs into here reaches the app;
/// No script of ours runs in the page world. When the agent overlay arrives it talks to the
/// page only through scripts in a separate `WKContentWorld` (`BrowserModel.agentWorld`).
@MainActor
final class BrowserModel: NSObject, ObservableObject {
    @Published private(set) var tabs: [BrowserTab] = []
    @Published var selectedID: UUID? {
        didSet {
            guard selectedID != oldValue else { return }
            // A restored (or sleeping) tab loads the first time it is shown (lazy restore).
            if let o = oldValue, let old = tabs.first(where: { $0.id == o }) {
                old.lastActive = Date()
                old.passwords.hideSuggestions()   // the field's accounts belong to the tab going to the back
                // the tab going to the back: where its video is now, for the next save
                Task { @MainActor in await old.sampleMedia(); self.saveTabs() }
            }
            selected?.lastActive = Date()
            selected?.loadIfPending()
            // A hidden tab of a collapsed group that comes to front (\u{2318}1...9, the tab list, a link, the agent)
            // opens its group. Collapsing around the tab in front does not change the selection, so it stays closed.
            expandSelectedGroup()
            saveTabs()
        }
    }

    /// nil: a new tab opens on our own start page (browser.js: the wordmark over one search field), not on a
    /// search engine that picks its language from the IP and sets its cookies before the person typed anything.
    static let homeURL: URL? = nil
    /// Safari's own user agent. Google refuses sign-in from a bare WebKit agent it does not know.
    /// (Gmail says "this browser version is no longer supported"): the version is the installed
    /// Safari's, read from Safari itself; our web views run that same system WebKit, so sites get the truth and
    /// serve their current code. (The macOS part stays 10_15_7: Safari freezes it the same way.)
    static let userAgent: String = {
        let v = safariVersion ?? "18.0"
        return "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/\(v) Safari/605.1.15"
    }()

    /// "26.0.1" -> "26.0": the installed Safari's version (major.minor), as Safari puts it in its agent.
    static var safariVersion: String? {
        for path in ["/Applications/Safari.app", "/System/Cryptexes/App/System/Applications/Safari.app"] {
            guard let b = Bundle(path: path), let full = b.infoDictionary?["CFBundleShortVersionString"] as? String else { continue }
            let parts = full.split(separator: ".")
            return parts.count >= 2 ? "\(parts[0]).\(parts[1])" : full
        }
        return nil
    }
    /// The content world every script of ours runs in (the agent bridge, reading, passwords, translation, page
    /// tweaks). The page's own JavaScript cannot see or change anything defined here.
    static let agentWorld = WKContentWorld.world(name: "lia-agent")

    private static let storeKey = "lia_browser_store_id"          // 0.2.x: one store for the whole app
    private static let storesKey = "lia_browser_store_ids"        // Liaison account id -> store UUID
    private static var stores: [String: WKWebsiteDataStore] = [:]

    /// One store per Liaison account: every chat of an account shares its sign-ins (signed in to
    /// Google in one chat, signed in in all of them); another Liaison account starts clean. Identifiers persist, so
    /// sign-ins survive a restart. The first account to ask takes over the old app-wide store, keeping its sign-ins.
    static func dataStore(for account: String?) -> WKWebsiteDataStore {
        let key = account ?? "_none"
        if let s = stores[key] { return s }
        let d = UserDefaults.standard
        var ids = d.dictionary(forKey: storesKey) as? [String: String] ?? [:]
        let id: UUID
        if let s = ids[key], let u = UUID(uuidString: s) {
            id = u
        } else if let s = d.string(forKey: storeKey), let u = UUID(uuidString: s) {
            id = u
            d.removeObject(forKey: storeKey)
        } else {
            id = UUID()
        }
        ids[key] = id.uuidString
        d.set(ids, forKey: storesKey)
        let store = WKWebsiteDataStore(forIdentifier: id)
        stores[key] = store
        // Shared sign-ins: the listed sites' cookies are the same in every workspace of this Liaison account.
        SharedSignIns.shared.register(store, key: key)
        return store
    }

    /// The Liaison account whose browser profile this is.
    let account: String?
    /// Hosts already opened on the workspace's fixed account this launch (WorkspaceAccounts): after the first
    /// visit, an account the person switches to inside the service is theirs.
    var accountPinnedHosts: Set<String> = []
    /// When a host was last rewritten onto the fixed account (loop guard).
    var accountPinnedAt: [String: Date] = [:]
    /// The workspace's name: its downloads go to ~/Downloads/Liaison/<name> (; Settings can turn it off).
    var clientName: String?

    var selected: BrowserTab? { tabs.first { $0.id == selectedID } ?? tabs.first }
    /// Lia 2.0 at work over this chat's pages (AgentDirector).
    private(set) lazy var agent = AgentDirector(browser: self)
    /// Lia 2.0 on the open web: tasks done with real clicks and keys in this chat's tabs.
    private(set) lazy var web = WebAgent(browser: self)

    /// The chat whose tabs these are: they are saved under it (BrowserMemory) and come back with it after the panel
    /// closes, the LRU lets the browser go, the app quits or updates. nil: nothing is saved.
    let chatID: String?
    /// Off once the model is shut down: the blank pages it loads then must not overwrite the chat's saved tabs.
    private var persisting = true
    private var saveJob: Task<Void, Never>?

    init(account: String?, startURL: URL? = nil, chat: String? = nil) {
        self.account = account
        self.chatID = chat
        super.init()
        if let chat, let saved = BrowserMemory.load(chat: chat, account: account), restore(saved) {
            if let startURL { newTab(url: startURL) }
        } else {
            newTab(url: startURL ?? Self.homeURL)
        }
        startSleepTimer()
        loadArchive()
        loadGroups()
        Self.live.add(self)
        Self.observeLifecycle()
    }

    /// The chat's saved tabs, none of them loaded: only the selected one loads now, the others when first selected.
    /// A chat that was on a start page gets a fresh one. false: nothing usable was saved.
    private func restore(_ saved: SavedTabs) -> Bool {
        let config = Self.configuration(account: account)
        var made: [BrowserTab] = []
        for t in saved.tabs.prefix(BrowserMemory.maxTabs) {
            guard let u = URL(string: t.url) else { continue }
            let tab = BrowserTab(configuration: config, owner: self)
            tab.prepare(u, title: t.title)
            if let sid = t.sid, !sid.isEmpty { tab.sid = sid }
            // `url` is the page the tab was on; `home` the one it was pinned on (older saves: the same address).
            if t.pinned == true { tab.pinned = true; tab.pinnedURL = t.home.flatMap(URL.init(string:)) ?? u }
            tab.group = t.group
            tab.customTitle = t.name
            made.append(tab)
        }
        guard !made.isEmpty else { return false }
        tabs = made
        normalizeOrder(save: false)
        if let i = saved.selected, made.indices.contains(i) {
            selectedID = made[i].id
            made[i].loadIfPending()
        } else {
            newTab(url: Self.homeURL)
        }
        return true
    }

    /// Debounced (1 s): a page changes its title and address several times while it loads.
    func tabDidChange() {
        guard persisting, chatID != nil else { return }
        saveJob?.cancel()
        saveJob = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(TabRestore.saveDelay * 1_000_000_000))
            guard !Task.isCancelled else { return }
            self?.saveTabs()
        }
    }

    /// The tabs worth keeping: real pages (no start page, no about:blank), at most `BrowserMemory.maxTabs`.
    /// The memory holds them at once; the disk write is BrowserMemory's, debounced and off the main thread.
    /// Every tab, pinned and grouped ones too, is saved at the page it is on NOW (TabRestore.latest:
    /// History API and #hash changes included), with a YouTube video's current position in its `t`. `capture`:
    /// WebKit's interaction state (back/forward, scroll, forms) of every loaded tab is taken now (resign, quit, sleep);
    /// otherwise only of tabs that navigated since the last save.
    func saveTabs(capture: Bool = false) {
        guard persisting, let chatID else { return }
        saveJob?.cancel(); saveJob = nil
        var kept: [SavedTab] = []
        var keptTabs: [BrowserTab] = []
        var sel: Int?
        let current = selected?.id
        for t in tabs {
            if capture || t.stateDirty { t.captureState() }
            guard let u0 = t.savedURL, TabRestore.isWeb(u0) else { continue }
            if t.id == current { sel = kept.count }
            let u = TabRestore.withMedia(u0, sample: t.mediaSample)
            kept.append(SavedTab(url: u.absoluteString, title: t.savedTitle, pinned: t.pinned ? true : nil, group: t.group, name: t.customTitle,
                                 home: t.pinned ? t.pinnedURL?.absoluteString : nil, sid: t.sid))
            keptTabs.append(t)
        }
        if kept.count > BrowserMemory.maxTabs {
            let drop = kept.count - BrowserMemory.maxTabs
            kept.removeFirst(drop)
            keptTabs.removeFirst(drop)
            sel = sel.flatMap { $0 >= drop ? $0 - drop : nil }
        }
        BrowserMemory.put(kept.isEmpty ? nil : SavedTabs(tabs: kept, selected: sel), chat: chatID, account: account)
        for t in keptTabs { t.writeStateIfNeeded(account: account, chat: chatID) }
        if capture, !kept.isEmpty { TabStateStore.prune(account: account, chat: chatID, keep: Set(keptTabs.map(\.sid))) }
    }

    // MARK: flushing on resign / quit / system sleep

    /// Every live browser of the app (weak): flushed together when the app resigns or quits and the Mac sleeps.
    private static let live = NSHashTable<BrowserModel>.weakObjects()
    /// Every live browser of the app (AuthCookieWatch reloads agent tabs after a sign-in change).
    static var liveModels: [BrowserModel] { live.allObjects }
    private static var lifecycleObservers: [NSObjectProtocol] = []

    /// The latest address of every tab of every chat, written now. `capture`: WebKit's interaction state of EVERY
    /// loaded tab is taken (quit, system sleep, power-off); otherwise only of tabs that navigated since the last save
    /// (`stateDirty`). `wait`: blocks until both stores are on disk (only where the process may not get another
    /// chance: quit, system sleep, power-off); otherwise the stores' own background writes carry it.
    static func flushAll(capture: Bool, wait: Bool) {
        for m in live.allObjects { m.saveTabs(capture: capture) }
        if wait { BrowserMemory.flush(); TabStateStore.flush() }
    }

    private static func observeLifecycle() {
        guard lifecycleObservers.isEmpty else { return }
        let nc = NotificationCenter.default
        lifecycleObservers.append(nc.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { BrowserModel.flushAll(capture: true, wait: true) }
        })
        // 0.2.11 review: a resign (every \u{2318}Tab) used to capture every tab's interaction state twice. Now only
        // tabs that changed are saved, then once more with where the selected tab's video is (the app keeps running).
        lifecycleObservers.append(nc.addObserver(forName: NSApplication.didResignActiveNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated {
                BrowserModel.flushAll(capture: false, wait: false)
                Task { @MainActor in
                    for m in BrowserModel.live.allObjects {
                        guard let t = m.selected else { continue }
                        await t.sampleMedia()
                        if t.mediaSample != nil { m.saveTabs() }
                    }
                }
            }
        })
        // System sleep and Shut Down: everything captured and written at once with the last video positions, then
        // once more after asking the videos where they are now.
        let ws = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.willSleepNotification, NSWorkspace.willPowerOffNotification] {
            lifecycleObservers.append(ws.addObserver(forName: name, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated {
                    BrowserModel.flushAll(capture: true, wait: true)
                    Task { @MainActor in
                        for m in BrowserModel.live.allObjects { await m.sampleMedia() }
                        BrowserModel.flushAll(capture: false, wait: true)
                    }
                }
            })
        }
        // Screens asleep, a switch to another user: the app keeps running, so nothing waits on the main thread and
        // only changed tabs are captured; a real system sleep after it gets the full flush above.
        for name in [NSWorkspace.screensDidSleepNotification, NSWorkspace.sessionDidResignActiveNotification] {
            lifecycleObservers.append(ws.addObserver(forName: name, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated {
                    BrowserModel.flushAll(capture: false, wait: false)
                    Task { @MainActor in
                        for m in BrowserModel.live.allObjects { await m.sampleMedia() }
                        BrowserModel.flushAll(capture: false, wait: false)
                    }
                }
            })
        }
    }

    /// The position of every loaded YouTube tab's video, read now (what a flush writes into its address).
    func sampleMedia() async {
        for t in tabs { await t.sampleMedia() }
    }

    static func configuration(account: String?) -> WKWebViewConfiguration {
        let c = WKWebViewConfiguration()
        c.websiteDataStore = dataStore(for: account)
        c.preferences.isElementFullscreenEnabled = true
        c.defaultWebpagePreferences.allowsContentJavaScript = true
        // Trackers blocked when the person turned it on (never on Meta and Google ad pages).
        if Prefs.flag(Prefs.blockTrackers, default: false), let list = Trackers.list { c.userContentController.add(list) }
        // Browser extensions (password managers first): macOS 15.4+, one controller for the app (ExtensionsHost).
        ExtensionsHost.shared.attach(to: c)
        // Passwords (PasswordTab.swift): the sign-in capture script and its handler, both in the agent world only.
        PasswordMessenger.install(on: c)
        return c
    }

    @discardableResult
    func newTab(url: URL?, configuration: WKWebViewConfiguration? = nil, select: Bool = true, opener: BrowserTab? = nil) -> BrowserTab {
        let tab = BrowserTab(configuration: configuration ?? Self.configuration(account: account), owner: self)
        // every new tab the person opens (\u{2318}T, +, menus, the palette, an address typed,
        // agents, the tour) goes to the END of the strip, after every tab and group, in no group. "New Tab in Group"
        // moves it into its group after. A tab a PAGE opens (`opener`) goes right after that page's tab,
        // after the tabs it opened before (TabStrip.linkTabPlace);: from a grouped tab, in that group next
        // to it; from a pinned tab, the end.: from a grouped tab, the end too, in no group.
        let slots = tabs.map { TabStrip.Slot(group: $0.group, pinned: $0.pinned) }
        let at: Int
        if let opener, let o = tabs.firstIndex(where: { $0.id == opener.id }) {
            let openedBy: [Bool] = tabs.map { $0.openerID == opener.id }
            let place = TabStrip.linkTabPlace(slots, opener: o, openedBy: openedBy)
            at = place.index
            // ("the first \u{2318}-click does nothing"): a link from a grouped tab went into that group
            // and a collapsed group hid it at once. TabStrip.linkTabPlace now sends it to the end, loose (group nil).
            if let g = place.group, groups.contains(where: { $0.id == g }) { tab.group = g }
            tab.openerID = opener.id
        } else {
            at = TabStrip.newTabIndex(slots)
        }
        tabs.insert(tab, at: at)
        normalizeOrder(save: false)
        if select { selectedID = tab.id }
        if let url { tab.load(url) }
        saveTabs()
        return tab
    }

    /// "+" / \u{2318}T / New Tab: one Home at a time. An existing Home (a loose start page) moves to the
    /// end of the strip, where a new tab would open, and comes to front; extra Homes left from before are closed.
    @discardableResult
    func openHome() -> BrowserTab {
        let slots = tabs.map { TabStrip.Slot(group: $0.group, pinned: $0.pinned) }
        let sel = selectedID.flatMap { id in tabs.firstIndex { $0.id == id } }
        guard let i = TabStrip.homeTab(slots, start: tabs.map(\.isStart), selected: sel) else { return newTab(url: Self.homeURL) }
        let home = tabs.remove(at: i)
        tabs.insert(home, at: TabStrip.newTabIndex(tabs.map { TabStrip.Slot(group: $0.group, pinned: $0.pinned) }))
        normalizeOrder(save: false)
        selectedID = home.id
        let extra = tabs.filter { $0.id != home.id && $0.isStart && !$0.pinned && $0.group == nil && agent.tabID != $0.id }
        for t in extra { close(t) }
        saveTabs()
        return home
    }

    /// "New Tab in Group" (the group's menu): a new tab at the end of the group's run, in the group.
    @discardableResult
    func newTab(inGroup g: TabGroupInfo) -> BrowserTab {
        let tab = newTab(url: nil, select: false)
        addTab(tab, to: g)
        selectedID = tab.id
        return tab
    }

    func close(_ tab: BrowserTab) {
        guard let i = tabs.firstIndex(where: { $0.id == tab.id }) else { return }
        // \u{2318}W never closes a pinned tab (unpin to really close it).: it is
        // unloaded (asleep) at the page it is on NOW and the next tab comes to front; it never goes back to the page it
        // was pinned on ("Go to the Pinned Address" in the tab menu is the only way there).
        let pinSlots = tabs.map { TabStrip.Slot(group: $0.group, pinned: $0.pinned) }
        switch TabRestore.closeAction(pinned: tab.pinned, force: forceClose, index: i, selected: selectedID == tab.id,
                                      hidden: TabStrip.hidden(pinSlots, collapsed: collapsedIDs, kept: keptIndices)) {
        case .close: break
        case .keep: return
        case .unload(let j):
            if let j { selectedID = tabs[j].id }
            let agentThere = agent.tabID == tab.id && agent.visible
            if !agentThere, !tab.isStart { tab.sleep() }
            saveTabs()
            return
        }
        if let u = tab.savedURL, let scheme = u.scheme?.lowercased(), scheme == "http" || scheme == "https" {
            tab.captureState()
            closed.append(ClosedTab(url: u, title: tab.savedTitle, index: i, back: (tab.loadedWebView?.backForwardList.backList.suffix(20).map(\.url)) ?? [],
                                    group: tab.group, state: tab.state(at: u)))
            if closed.count > 50 { closed.removeFirst(closed.count - 50) }
        }
        // A camera/microphone ask still open: WebKit raises if its decision handler is dropped without a call.
        tab.answerPermission(false, remember: false)
        tab.loadedWebView?.stopLoading()
        tab.loadedWebView?.pauseAllMediaPlayback(completionHandler: nil)
        tabs.remove(at: i)
        for k in groups.indices where groups[k].keep == tab.id.uuidString { groups[k].keep = nil }
        // The panel never closes: the last tab is replaced by a fresh one. The tab in front closed: its right
        // neighbour comes to front, passing over tabs a collapsed group hides (else a lone tab of it would show).
        if tabs.isEmpty { newTab(url: Self.homeURL) }
        else if selectedID == tab.id {
            let slots = tabs.map { TabStrip.Slot(group: $0.group, pinned: $0.pinned) }
            let at = min(i, tabs.count - 1)
            let kept = keptIndices
            let hide = TabStrip.hidden(slots, collapsed: collapsedIDs, kept: kept)
            if hide[at], let j = TabStrip.selectionAfterCollapse(slots, selected: at, collapsed: collapsedIDs, kept: kept) {
                selectedID = tabs[j].id
            } else if hide[at] {
                newTab(url: Self.homeURL)
            } else {
                selectedID = tabs[at].id
            }
        }
        // The group's last tab closed: the group goes too (else it lingers in "Add to Group").
        if tab.group != nil { pruneGroups() }
        saveTabs()
    }

    /// Before the model is dropped: every page stops loading and is replaced by a blank one, so no audio or video
    /// keeps playing from a web view that is still alive somewhere in WebKit.
    /// The panel was closed: pages stay (tabs come back with the chat), sound and video stop.
    func pauseMedia() {
        for t in tabs { t.loadedWebView?.pauseAllMediaPlayback(completionHandler: nil) }
    }

    func shutDown() {
        // The tabs are saved as they are now (with their interaction state), before the blank pages below replace them.
        saveTabs(capture: true)
        persisting = false
        web.cancel()   // A web task never drives a page that is going away
        for t in tabs {
            guard let w = t.loadedWebView else { continue }
            w.stopLoading()
            w.pauseAllMediaPlayback(completionHandler: nil)
            if let blank = URL(string: "about:blank") { w.load(URLRequest(url: blank)) }
        }
    }

    /// A link from Lia's text, or any URL handed to the panel: opens in a new tab and shows it.
    func open(_ url: URL) { newTab(url: url) }

    // MARK: - tab management (/04/07, )

    struct ClosedTab {
        let url: URL; let title: String; let index: Int; let back: [URL]
        /// The group it was in: reopened into it while the group is still open (Chrome).
        var group: String? = nil
        /// Its WebKit interaction state at `url` (Back and the scroll position come back with it).
        var state: Data? = nil
    }
    /// Recently closed tabs, newest last (\u{2318}\u{21E7}T), at most 50.
    @Published private(set) var closed: [ClosedTab] = []

    /// \u{2318}\u{21E7}T: the last closed tab back at its place, on its page.
    func reopenClosed() {
        reopenClosed(at: closed.count - 1)
    }

    /// One tab of the Recently Closed list (the tab bar's menu), newest last like `closed`.
    func reopenClosed(at n: Int) {
        guard closed.indices.contains(n) else { return }
        let c = closed.remove(at: n)
        let tab = BrowserTab(configuration: Self.configuration(account: account), owner: self)
        if let g = c.group, groups.contains(where: { $0.id == g }) { tab.group = g }
        tabs.insert(tab, at: min(c.index, tabs.count))
        normalizeOrder(save: false)
        selectedID = tab.id
        if let s = c.state, tab.restore(state: s, at: c.url) {} else { tab.restoreHistory(c.back, then: c.url) }
        saveTabs()
    }

    /// Drag to reorder: the tab moves to the position of another (live, while dragging).
    func move(_ id: UUID, to target: UUID) {
        guard id != target, let from = tabs.firstIndex(where: { $0.id == id }), let to = tabs.firstIndex(where: { $0.id == target }) else { return }
        var list = tabs
        let t = list.remove(at: from)
        list.insert(t, at: to)
        // Dropped among a group's tabs, it joins that group; dropped outside, it leaves its own. A pinned tab
        // stays in the pinned cell (normalizeOrder keeps it there), never in a group.
        if !t.pinned {
            let onto = list.first { $0.id == target }
            let joins = TabStrip.groupAfterDrop(list.map(\.group), index: to, target: onto?.pinned == true ? nil : onto?.group)
            if joins != t.group {
                t.group = joins
                groups.removeAll { g in !list.contains { $0.group == g.id } }
                saveGroups()
            }
        }
        tabs = list
        normalizeOrder(save: false)
        saveTabs()
    }

    /// A whole group dragged by its header: its tabs go where `target` is (after it moving right, before it
    /// moving left), keeping their order. Onto another group's tab: to that group's edge, never inside it.
    func moveGroup(_ id: String, to target: UUID) {
        let members = tabs.filter { $0.group == id }
        guard let first = tabs.firstIndex(where: { $0.group == id }), let at = tabs.firstIndex(where: { $0.id == target }),
              !members.contains(where: { $0.id == target }) else { return }
        let right = at > first
        var rest = tabs.filter { $0.group != id }
        guard var i = rest.firstIndex(where: { $0.id == target }), !rest[i].pinned else { return }
        if let tg = rest[i].group {
            i = right ? (rest.lastIndex { $0.group == tg } ?? i) + 1 : (rest.firstIndex { $0.group == tg } ?? i)
        } else if right {
            i += 1
        }
        rest.insert(contentsOf: members, at: min(i, rest.count))
        tabs = rest
        normalizeOrder(save: false)
        saveTabs()
    }

    /// The strip's order after every change: pinned tabs (the workspace's cell), pinned groups, the
    /// rest, every group's tabs side by side (TabStrip.order). Also asks the server, once, for the name of a group
    /// that has just reached two tabs.
    func normalizeOrder(save: Bool = true) {
        for t in tabs where t.pinned && t.group != nil { t.group = nil }
        let pinnedGroups = Set(groups.filter(\.isPinned).map(\.id))
        let order = TabStrip.order(tabs.map { TabStrip.Slot(group: $0.group, pinned: $0.pinned) }, pinnedGroups: pinnedGroups)
        if order != Array(tabs.indices) { tabs = order.map { tabs[$0] } }
        askNames()
        if save { saveTabs() }
    }

    func duplicate(_ tab: BrowserTab) {
        guard let u = tab.savedURL else { return }
        let i = tabs.firstIndex(where: { $0.id == tab.id }) ?? tabs.count - 1
        let t = BrowserTab(configuration: Self.configuration(account: account), owner: self)
        tabs.insert(t, at: i + 1)
        // Its copy stays in the original's group, next to it.
        if !tab.pinned { t.group = tab.group }
        normalizeOrder(save: false)
        selectedID = t.id
        t.load(u)
        saveTabs()
    }

    func closeOthers(_ tab: BrowserTab) { for t in tabs where t.id != tab.id && !t.pinned { close(t) } }
    func closeRight(_ tab: BrowserTab) {
        guard let i = tabs.firstIndex(where: { $0.id == tab.id }) else { return }
        for t in tabs.suffix(from: i + 1) where !t.pinned { close(t) }
    }

    /// A second tab shown beside the selected one (nil: no split), and the left pane's share.
    @Published var splitID: UUID?
    @Published var splitRatio: CGFloat = 0.5
    var splitTab: BrowserTab? { splitID.flatMap { id in tabs.first { $0.id == id && $0.id != selectedID } } }
    /// Split the selected tab with another (or a new one on the start page).
    func split(with other: BrowserTab? = nil) {
        if let other { splitID = other.id; return }
        guard let cur = selected else { return }
        let t = newTab(url: nil, select: false)
        splitID = t.id
        selectedID = cur.id
    }
    func unsplit() { splitID = nil }

    /// Set while a tab must really go (unpinned close, a move to another workspace).
    private var forceClose = false

    /// Pin (kept first, compact; \u{2318}W unloads it where it is, never closes it) or unpin.
    func setPinned(_ tab: BrowserTab, _ on: Bool) {
        guard let i = tabs.firstIndex(where: { $0.id == tab.id }) else { return }
        tab.pinned = on
        tab.pinnedURL = on ? tab.savedURL : nil   // the pinned address: only for the menu's "Go to the Pinned Address"
        // A pinned tab sits in the workspace's cell, out of any group.
        if on, tab.group != nil { tab.group = nil; pruneGroups() }
        var list = tabs
        let t = list.remove(at: i)
        let pinnedCount = list.filter(\.pinned).count
        list.insert(t, at: pinnedCount)   // the end of the pinned cell, or the first unpinned place
        tabs = list
        normalizeOrder()
    }
    var pinnedTabs: [BrowserTab] { tabs.filter(\.pinned) }

    /// The tab menu's "Go to the Pinned Address" (shown only when the pinned tab is elsewhere). An
    /// ordinary navigation: Back returns to where the tab was; nothing resets the tab by itself.
    func goToPinnedAddress(_ tab: BrowserTab) {
        guard let home = tab.pinnedURL, TabRestore.offersPinnedAddress(pinned: tab.pinned, home: home, current: tab.savedURL) else { return }
        selectedID = tab.id
        tab.load(home)
    }

    /// The tab goes away for good (move to another workspace), pinned or not; nothing is pushed to
    /// the reopen stack because the page lives on elsewhere.
    func remove(_ tab: BrowserTab) {
        forceClose = true
        defer { forceClose = false }
        let before = closed.count
        close(tab)
        if closed.count > before { closed.removeLast() }
    }

    /// The tabs in the order they were last looked at: the first is the one in front.
    var recentTabs: [BrowserTab] {
        // A strict order (never true for a tab against itself), the one in front first.
        let sel = selected?.id
        return tabs.sorted { a, b in a.id != b.id && (a.id == sel || (b.id != sel && a.lastActive > b.lastActive)) }
    }

    /// \u{2318}1...\u{2318}8 a tab by position, \u{2318}9 the last one.
    func select(index n: Int) {
        guard !tabs.isEmpty else { return }
        selectedID = n >= 8 ? tabs.last?.id : (tabs.indices.contains(n) ? tabs[n].id : selectedID)
    }
    /// \u{2318}\u{2325}\u{2192} / \u{2318}\u{2325}\u{2190} (and \u{2303}Tab): the next or previous tab, wrapping.
    /// Tabs a collapsed group hides are passed over (Chrome).
    func selectNext(_ forward: Bool) {
        guard let cur = selected, let i = tabs.firstIndex(where: { $0.id == cur.id }), tabs.count > 1 else { return }
        let slots = tabs.map { TabStrip.Slot(group: $0.group, pinned: $0.pinned) }
        guard let j = TabStrip.relativeTab(slots, from: i, forward: forward, collapsed: collapsedIDs, kept: keptIndices) else { return }
        selectedID = tabs[j].id
    }

    /// Tabs nobody looked at for a while go to sleep (their page is unloaded, a snapshot stays) and wake when shown.
    private var sleepTimer: Timer?
    private var soundTimer: Timer?
    private func startSleepTimer() {
        // No timer for video positions (battery); they are read on events only, and a crash is left
        // to YouTube's own resume.
        sleepTimer?.invalidate()
        sleepTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.sleepIdleTabs() }
        }
        // The speaker on tabs that play sound: asked every few seconds, only of loaded pages.
        soundTimer?.invalidate()
        soundTimer = Timer.scheduledTimer(withTimeInterval: 4, repeats: true) { [weak self] _ in
            Task { @MainActor in
                // only while Liaison is in front: in the background nobody looks at the speaker
                guard NSApp.isActive else { return }
                for t in self?.tabs ?? [] where !t.isStart && !t.asleep && t.pendingURL == nil && t.loadedWebView != nil { t.refreshPlaying() }
            }
        }
    }

    // MARK: tab groups (/15)

    struct TabGroupInfo: Codable, Identifiable, Equatable {
        let id: String
        var name: String
        /// Kept for stored groups only: a group is always drawn without colour.
        var color: UInt32
        var collapsed = false
        // (optional: groups stored before them still decode).
        /// Pinned: right after the workspace's cell, before the other tabs and groups.
        var pinned: Bool? = nil
        /// The server's emoji for a group of two or more tabs; nil: the first tab's favicon.
        var emoji: String? = nil
        /// The person named it: the server's name never replaces theirs.
        var userNamed: Bool? = nil
        /// The server was asked for a name already (once per group, when it reaches two tabs).
        var asked: Bool? = nil
        /// The server's category (TabGroupCat), drawn as the app's own icon; nil: an older group (an emoji
        /// only: the folder) or none yet (a one-tab group: its site's favicon).
        var cat: String? = nil
        /// The tab that was in front when the group collapsed (its uuid). It stays by the closed
        /// folder after you leave it, until the group is opened again; nil: every tab hidden.
        var keep: String? = nil

        var isPinned: Bool { pinned == true }
    }
    /// A group put away: its pages, restorable in one click.
    struct SavedGroup: Codable, Identifiable, Equatable {
        let id: String
        var name: String
        var color: UInt32
        var pages: [SavedTab]
        var emoji: String? = nil
        var cat: String? = nil
    }
    static let groupColors: [UInt32] = [0x3B5BFD, 0x11865A, 0xE8572A, 0x7B4DDB, 0xD6409F, 0xE8A317, 0x0E9AA7, 0x6B7280]
    private var groupsKey: String { "lia_tab_groups_" + (account ?? "_") + "_" + (chatID ?? "") }
    private var savedGroupsKey: String { "lia_tab_groups_saved_" + (account ?? "_") }
    @Published private(set) var groups: [TabGroupInfo] = []
    @Published private(set) var savedGroups: [SavedGroup] = []

    private func loadGroups() {
        let d = UserDefaults.standard
        if let data = d.data(forKey: groupsKey), let g = try? JSONDecoder().decode([TabGroupInfo].self, from: data) { groups = g }
        if let data = d.data(forKey: savedGroupsKey), let g = try? JSONDecoder().decode([SavedGroup].self, from: data) { savedGroups = g }
        // A group whose tabs are all gone is dropped.
        groups.removeAll { g in !tabs.contains { $0.group == g.id } }
        // Stored before the strip kept groups whole: put back in order, without asking the server about old groups.
        for i in groups.indices where groups[i].asked == nil { groups[i].asked = true }
        normalizeOrder(save: false)
    }
    private func saveGroups() {
        let d = UserDefaults.standard
        if let data = try? JSONEncoder().encode(groups) { d.set(data, forKey: groupsKey) }
    }
    /// Saved groups are the account's, shared by every chat's BrowserModel: each change reads the stored list first,
    /// so another chat's stale copy never overwrites a group put away elsewhere.
    /// The stored list again (History \u{2192} Saved Groups opens: another chat may have put a group away).
    func reloadSaved() { changeSaved { _ in } }
    private func changeSaved(_ change: (inout [SavedGroup]) -> Void) {
        let d = UserDefaults.standard
        var list = d.data(forKey: savedGroupsKey).flatMap { try? JSONDecoder().decode([SavedGroup].self, from: $0) } ?? savedGroups
        change(&list)
        if let data = try? JSONEncoder().encode(list) { d.set(data, forKey: savedGroupsKey) }
        savedGroups = list
    }
    func tabs(in g: TabGroupInfo) -> [BrowserTab] { tabs.filter { $0.group == g.id } }
    func group(of t: BrowserTab) -> TabGroupInfo? { t.group.flatMap { id in groups.first { $0.id == id } } }

    /// \u{2318}\u{21E7}G / the tab menu: a new group from these tabs, kept next to each other where the first one is.
    @discardableResult
    func makeGroup(_ members: [BrowserTab], name: String = "", cat: String? = nil) -> TabGroupInfo? {
        let ids = Set(members.map(\.id))
        let list = tabs.filter { ids.contains($0.id) && !$0.pinned }
        guard let first = list.first, let at = tabs.firstIndex(where: { $0.id == first.id }) else { return nil }
        // No name given: one word for the first tab's site ("GitHub"); with two or more tabs the
        // server is asked for a better one (askNames). A given name (Tidy's) is final.
        var g = TabGroupInfo(id: UUID().uuidString, name: name.isEmpty ? SiteName.word(host: first.savedURL?.host, title: first.savedTitle) : name,
                             color: Self.groupColors[groups.count % Self.groupColors.count])
        if !name.isEmpty { g.asked = true }
        g.cat = TabGroupCat.normalize(cat)
        groups.append(g)
        var rest = tabs.filter { !ids.contains($0.id) || $0.pinned }
        let insertAt = min(at - tabs.prefix(at).filter { ids.contains($0.id) && !$0.pinned }.count, rest.count)
        for t in list { t.group = g.id }
        rest.insert(contentsOf: list, at: insertAt)
        tabs = rest
        saveGroups()
        normalizeOrder()
        return groups.first { $0.id == g.id } ?? g
    }
    func addTab(_ t: BrowserTab, to g: TabGroupInfo) {
        guard !t.pinned else { return }
        objectWillChange.send()
        t.group = g.id
        if let last = tabs.lastIndex(where: { $0.group == g.id && $0.id != t.id }), let i = tabs.firstIndex(where: { $0.id == t.id }) {
            var list = tabs
            let moved = list.remove(at: i)
            list.insert(moved, at: min(last + (i <= last ? 0 : 1), list.count))
            tabs = list
        }
        pruneGroups()
        saveGroups()
        normalizeOrder()
    }
    func removeFromGroup(_ t: BrowserTab) {
        objectWillChange.send()
        let g = t.group
        t.group = nil
        // Out of the group: right after its run, never left between its tabs.
        if let g, let i = tabs.firstIndex(where: { $0.id == t.id }), let last = tabs.lastIndex(where: { $0.group == g }), last > i {
            var list = tabs
            let moved = list.remove(at: i)
            list.insert(moved, at: last)
            tabs = list
        }
        pruneGroups()
        normalizeOrder()
    }
    /// Groups none of whose tabs are left are dropped (and the change saved).
    private func pruneGroups() {
        let before = groups.count
        groups.removeAll { g in !tabs.contains { $0.group == g.id } }
        if groups.count != before { saveGroups() }
    }
    /// The person's own name: auto-naming stops for this group.
    func renameGroup(_ g: TabGroupInfo, _ name: String) { update(g) { $0.name = name; $0.userNamed = true } }
    func setGroupPinned(_ g: TabGroupInfo, _ on: Bool) {
        update(g) { $0.pinned = on ? true : nil }
        normalizeOrder()
    }

    /// The server's name and category (TabGroupNamer), unless the person named the group meanwhile. The
    /// category is the header's icon; an emoji is kept only as data (never drawn).
    func applySuggestedName(_ id: String, name: String, emoji: String?, cat: String?) {
        guard let g = groups.first(where: { $0.id == id }), g.userNamed != true else { return }
        update(g) {
            $0.name = name
            if let emoji { $0.emoji = emoji }
            $0.cat = TabGroupCat.normalize(cat) ?? $0.cat ?? TabGroupCat.normalize("folder")
        }
    }

    /// Groups that reached two tabs and were never asked about: asked once (TabGroupNamer), never again.
    private func askNames() {
        for g in groups where g.asked != true && g.userNamed != true && tabs.filter({ $0.group == g.id }).count >= 2 {
            update(g) { $0.asked = true }
            TabGroupNamer.ask(self, group: g.id)
        }
    }
    /// The ids of the collapsed groups.
    var collapsedIDs: Set<String> { Set(groups.filter(\.collapsed).map(\.id)) }
    /// The tab kept by its collapsed group's folder.
    func isKept(_ t: BrowserTab) -> Bool {
        guard let g = group(of: t), g.collapsed else { return false }
        return g.keep == t.id.uuidString
    }
    /// A tab of a collapsed group that still shows: the kept one, or the one in front.
    func showsCollapsed(_ t: BrowserTab) -> Bool { t.id == selectedID || isKept(t) }
    /// The indices of the kept tabs, for TabStrip's rules.
    var keptIndices: Set<Int> { Set(tabs.indices.filter { isKept(tabs[$0]) }) }

    /// a collapsed group hides its tabs except the one in front, which stays
    /// by its closed folder until another tab comes to front (Arc's folders); a click on the folder opens it.
    func toggleCollapsed(_ g: TabGroupInfo) {
        guard let i = groups.firstIndex(where: { $0.id == g.id }) else { return }
        let cur = groups[i]
        // A click on the closed folder while you are off its kept tab hides that tab too (the group
        // stays collapsed); the next click opens it (TabStrip.folderClick).
        switch TabStrip.folderClick(collapsed: cur.collapsed, kept: cur.keep, selected: selected?.id.uuidString) {
        case .hideKept:
            groups[i].keep = nil
            saveGroups()
        case .collapse: setCollapsed([cur.id], true)
        case .expand: setCollapsed([cur.id], false)
        }
    }

    /// Collapse or expand several groups at once (the tab bar's Collapse All / Expand All Groups).
    func setCollapsed(_ ids: Set<String>, _ on: Bool) {
        var changed = false
        for i in groups.indices where ids.contains(groups[i].id) && groups[i].collapsed != on {
            groups[i].collapsed = on
            // The tab you are on when its group closes stays fixed by the folder, also after you
            // leave it; opening the group lets it go (the next collapse keeps whatever is in front then).
            groups[i].keep = on && selected?.group == groups[i].id ? selected?.id.uuidString : nil
            changed = true
        }
        guard changed else { return }
        saveGroups()
        // Collapsing keeps the tab you are on in front, shown alone by its closed folder, and it
        // stays there after another tab comes to front (`keep`). A click on the folder opens it again.
    }

    /// The tab in front belongs to a collapsed group (selected by any route): that group opens.
    private func expandSelectedGroup() {
        guard let sel = selected, let at = tabs.firstIndex(where: { $0.id == sel.id }) else { return }
        let slots = tabs.map { TabStrip.Slot(group: $0.group, pinned: $0.pinned) }
        guard let g = TabStrip.groupToExpand(slots, selected: at, collapsed: collapsedIDs, kept: keptIndices),
              let i = groups.firstIndex(where: { $0.id == g }) else { return }
        groups[i].collapsed = false
        saveGroups()
    }

    /// Safari's "Arrange Tabs By" (the tab bar's menu): the loose tabs sorted in their places; pinned tabs and
    /// groups stay where they are (TabStrip.arranged).
    enum Arrange { case title, website }
    func arrange(by a: Arrange) {
        let slots = tabs.map { TabStrip.Slot(group: $0.group, pinned: $0.pinned) }
        let keys: [String] = tabs.map { t in
            let title = t.customTitle ?? t.savedTitle
            switch a {
            case .title: return title.isEmpty ? "\u{FFFF}" : title
            case .website: return TabStrip.siteKey(host: t.savedURL?.host, title: title)
            }
        }
        let order = TabStrip.arranged(slots, keys: keys)
        guard order != Array(tabs.indices) else { return }
        tabs = order.map { tabs[$0] }
        normalizeOrder()
    }

    /// Arc's "New Folder" / the tab bar's New Tab Group: a new tab on the start page in a new group of its own.
    @discardableResult
    func newGroupWithNewTab() -> TabGroupInfo? {
        let t = newTab(url: Self.homeURL)
        return makeGroup([t], name: "New Group")
    }

    func ungroup(_ g: TabGroupInfo) {
        for t in tabs where t.group == g.id { t.group = nil }
        groups.removeAll { $0.id == g.id }
        saveGroups()
        normalizeOrder()
    }
    /// The group's tabs close and the group waits under Saved Groups.
    func putAway(_ g: TabGroupInfo) {
        let members = tabs(in: g)
        let pages = members.compactMap { t in t.savedURL.map { SavedTab(url: $0.absoluteString, title: t.savedTitle) } }
        changeSaved { list in
            list.removeAll { $0.id == g.id }
            list.insert(SavedGroup(id: g.id, name: g.name, color: g.color, pages: pages, emoji: g.emoji, cat: g.cat), at: 0)
            if list.count > 30 { list.removeLast(list.count - 30) }
        }
        groups.removeAll { $0.id == g.id }
        for t in members { remove(t) }
        saveGroups()
    }
    func restore(_ s: SavedGroup) {
        changeSaved { list in list.removeAll { $0.id == s.id } }
        let g = TabGroupInfo(id: s.id, name: s.name, color: s.color, emoji: s.emoji, asked: true, cat: s.cat)
        groups.append(g)
        var first: BrowserTab?
        for p in s.pages {
            guard let u = URL(string: p.url) else { continue }
            let t = BrowserTab(configuration: Self.configuration(account: account), owner: self)
            t.prepare(u, title: p.title)
            t.group = g.id
            tabs.append(t)
            if first == nil { first = t }
        }
        if let first { selectedID = first.id } else { groups.removeAll { $0.id == g.id } }
        saveGroups()
        normalizeOrder()
    }
    func deleteSaved(_ s: SavedGroup) { changeSaved { list in list.removeAll { $0.id == s.id } } }
    private func update(_ g: TabGroupInfo, _ change: (inout TabGroupInfo) -> Void) {
        guard let i = groups.firstIndex(where: { $0.id == g.id }) else { return }
        change(&groups[i])
        saveGroups()
    }

    // MARK: archive (/18)

    struct ArchivedTab: Codable, Identifiable, Equatable { var id: String { url + "|\(at)" }; let url: String; let title: String; let at: Double }
    private var archiveKey: String { "lia_tab_archive_" + (account ?? "_") + "_" + (chatID ?? "") }
    /// Tabs closed by the archive rule, newest first (at most 100); restorable.
    @Published private(set) var archived: [ArchivedTab] = []

    private func loadArchive() {
        guard let d = UserDefaults.standard.data(forKey: archiveKey), let list = try? JSONDecoder().decode([ArchivedTab].self, from: d) else { return }
        archived = list
    }
    private func saveArchive() {
        if let d = try? JSONEncoder().encode(Array(archived.prefix(100))) { UserDefaults.standard.set(d, forKey: archiveKey) }
    }
    /// Unpinned tabs not looked at for the chosen time go to the archive (never the one in front, never one the agent uses).
    func archiveIdleTabs() {
        let hours = UserDefaults.standard.integer(forKey: Prefs.archiveHours)
        guard hours > 0 else { return }
        let cut = Date().addingTimeInterval(-Double(hours) * 3600)
        for t in tabs where !t.pinned && t.id != selected?.id && !t.isStart && t.lastActive < cut {
            if agent.tabID == t.id && agent.visible { continue }
            guard let u = t.savedURL else { continue }
            archived.insert(ArchivedTab(url: u.absoluteString, title: t.savedTitle, at: Date().timeIntervalSince1970), at: 0)
            remove(t)
        }
        saveArchive()
    }
    func restoreArchived(_ a: ArchivedTab) {
        archived.removeAll { $0 == a }
        saveArchive()
        if let u = URL(string: a.url) { open(u) }
    }
    func clearArchive() { archived = []; saveArchive() }

    func sleepIdleTabs(force: Bool = false) {
        archiveIdleTabs()
        let after = Prefs.sleepAfter
        guard force || after > 0 else { return }
        let now = Date()
        for t in tabs where t.id != selected?.id && !t.asleep && !t.isStart && t.pendingURL == nil {
            if agent.tabID == t.id && agent.visible { continue }   // the agent is working there
            if force || now.timeIntervalSince(t.lastActive) > after { t.sleep() }
        }
    }

    /// What the address bar typed: a URL, a bare host, or a search.
    static func resolve(_ typed: String) -> URL? {
        let t = typed.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return nil }
        if let u = URL(string: t), let scheme = u.scheme, ["http", "https", "about"].contains(scheme.lowercased()) { return u }
        if !t.contains(" "), t.contains("."), let u = URL(string: "https://" + t), u.host != nil { return u }
        if !t.contains(" "), t.hasPrefix("localhost"), let u = URL(string: "http://" + t) { return u }
        // The engine chosen in Settings; the app speaks English, the results page follows it.
        return Prefs.searchURL(t)
    }
}

/// One tab: a WKWebView and what the chrome shows about it.
@MainActor
final class BrowserTab: NSObject, ObservableObject, Identifiable, WKNavigationDelegate, WKUIDelegate, WKDownloadDelegate {
    let id = UUID()
    @Published private(set) var title = ""
    @Published private(set) var url: URL?
    @Published private(set) var isLoading = false
    @Published private(set) var progress: Double = 0
    @Published private(set) var canGoBack = false
    @Published private(set) var canGoForward = false
    /// The site's icon (Favicons); nil: the chip shows a globe.
    @Published private(set) var favicon: NSImage?
    private var faviconHost: String?
    /// The page's `<meta name="theme-color">` (0xRRGGBB), read in our own world after each load; nil: none.
    /// The toolbar's glass takes it as its accent.
    @Published private(set) var themeColor: UInt32?
    /// A restored tab not loaded yet: it loads the first time it is selected, showing its saved title until then.
    private(set) var pendingURL: URL?
    /// The tab's id across launches (SavedTab.sid): the name of its interaction-state file (TabStateStore).
    var sid = UUID().uuidString
    /// WebKit's interaction state (back/forward list, scroll, forms) and the address it was taken at.
    private var stateData: Data?
    private var stateURL: URL?
    private var stateUnwritten = false
    private var stateReadFromDisk = false
    /// The page navigated since its state was last taken (committed or same-document: the `url` KVO).
    private(set) var stateDirty = false
    /// The last read position of this tab's YouTube video and the address it was read at.
    private(set) var mediaSample: (url: URL, seconds: Double)?
    private var restoredTitle = ""
    private weak var owner: BrowserModel?
    private var observations: [NSKeyValueObservation] = []
    /// alert/confirm budget for the current page load.
    private var dialogs = DialogThrottle()

    // Page states (LOAD, FIND, ZOOM, PERM, )
    /// The last load failed: the card shows this instead of the page (/03).
    @Published private(set) var loadError: PageError?
    /// The page's process died: the card offers a reload; the window lives on.
    @Published private(set) var crashed = false
    /// Unloaded to save memory; the snapshot shows until it wakes.
    @Published private(set) var asleep = false
    @Published private(set) var snapshot: NSImage?
    /// Last time the tab was in front (sleep counts from it).
    var lastActive = Date()
    /// The person's own name for the tab, shown instead of the page title; nil: the page's.
    @Published var customTitle: String?
    /// The tab group it belongs to, nil: none.
    @Published var group: String?
    /// The tab whose page opened this one (a link, window.open); nil: the person opened it. Later tabs that
    /// page opens line up after this one.
    var openerID: UUID?
    /// Pinned: kept first and compact; \u{2318}W unloads it at its current page, never closes it. `pinnedURL`: where it was pinned, used
    /// only by the explicit "Go to the Pinned Address" (nothing resets a tab to it by itself).
    @Published var pinned = false
    var pinnedURL: URL?
    /// Sound off for this tab, kept across its pages.
    @Published private(set) var muted = false
    /// Something is playing sound right now (the speaker on the tab).
    @Published private(set) var playing = false
    /// The person's zoom for this site (1: default), on top of the desktop-width fit.
    @Published private(set) var zoom: CGFloat = 1
    /// A camera/microphone request waiting for the person.
    @Published var permission: PermissionAsk?
    /// Camera or microphone in use right now.
    @Published private(set) var capturing = false
    /// Passwords (PasswordTab.swift): this page's sign-in form, its accounts, the offer to save. Per workspace.
    private(set) lazy var passwords = TabPasswords(tab: self, workspace: owner?.account)

    init(configuration: WKWebViewConfiguration, owner: BrowserModel) {
        self.configuration = configuration
        self.owner = owner
        super.init()
    }

    private let configuration: WKWebViewConfiguration
    /// The page's web view, made the first time something needs it (speed: a new tab on our own start page,
    /// or a restored tab not shown yet, costs no WebKit view and no web process until it loads a page).
    private(set) lazy var webView: WKWebView = makeWebView()
    /// In front in its browser (the selected tab or the other pane of a split): the password suggestions show only here.
    var isSelectedTab: Bool { owner.map { $0.selectedID == id || $0.splitID == id } ?? false }
    /// An agent is working in this tab now: no password suggestions over its steps (agents never get passwords).
    var agentWorksHere: Bool { owner.map { $0.agent.tabID == id && $0.agent.visible } ?? false }

    /// The web view if it was made already (nil: nothing loaded yet); for code that must not make one.
    var loadedWebView: WKWebView? { madeWebView ? webView : nil }
    /// When the page last started loading (AuthCookieWatch: a page loaded around a sign-in change is not reloaded).
    private(set) var navigationStartedAt: Date?
    /// Its browser's agent is at work on this browser (the page is the agent's: WebFocusKeeper leaves the keys alone).
    var agentBusy: Bool {
        guard let o = owner else { return false }
        return (o.agent.active && o.agent.tabID == id) || o.web.running
    }
    private var madeWebView = false

    private func makeWebView() -> WKWebView {
        // Developers want the standard Inspect Element on right-click (Safari's Web Inspector).
        // isInspectable alone does not put it in the page menu; WebKit's developer extras do.
        configuration.preferences.setValue(true, forKey: "developerExtrasEnabled")
        let webView = DesktopWebView(frame: .zero, configuration: configuration)
        webView.tab = self
        madeWebView = true
        webView.customUserAgent = BrowserModel.userAgent
        webView.allowsBackForwardNavigationGestures = true
        webView.allowsMagnification = true
        webView.navigationDelegate = self
        webView.uiDelegate = self
        PasswordMessenger.register(webView, tab: self)
        // Inspect Element in the page menu: WebKit shows it with the inspector enabled.
        webView.isInspectable = true   // macOS 13.3+; the app targets 14
        observations = [
            webView.observe(\.title) { [weak self] w, _ in Task { @MainActor in self?.title = w.title ?? ""; self?.owner?.tabDidChange() } },
            webView.observe(\.url) { [weak self] w, _ in Task { @MainActor in self?.url = w.url; self?.stateDirty = true; self?.owner?.tabDidChange() } },
            webView.observe(\.isLoading) { [weak self] w, _ in
                Task { @MainActor in
                    self?.isLoading = w.isLoading
                    if w.isLoading { self?.navigationStartedAt = Date() }
                }
            },
            webView.observe(\.estimatedProgress) { [weak self] w, _ in Task { @MainActor in self?.progress = w.estimatedProgress } },
            webView.observe(\.canGoBack) { [weak self] w, _ in Task { @MainActor in self?.canGoBack = w.canGoBack } },
            webView.observe(\.canGoForward) { [weak self] w, _ in Task { @MainActor in self?.canGoForward = w.canGoForward } },
            webView.observe(\.cameraCaptureState) { [weak self] w, _ in Task { @MainActor in self?.updateCapture(w) } },
            webView.observe(\.microphoneCaptureState) { [weak self] w, _ in Task { @MainActor in self?.updateCapture(w) } },
        ]
        return webView
    }

    /// Nothing loaded yet: the panel shows the start page.
    @Published private(set) var isStart = true

    /// The tab's id as Lia sees it (browser context): short, stable while the tab lives.
    var shortID: String { String(id.uuidString.prefix(6)).lowercased() }

    var displayTitle: String {
        if let c = customTitle, !c.isEmpty { return c }
        if isStart { return "New tab" }
        if !title.isEmpty { return title }
        if !restoredTitle.isEmpty { return restoredTitle }
        return url?.host ?? "New tab"
    }

    /// `fresh`: the person's Reload of a page that had nothing to reload (a failure, a crash, a restored tab):
    /// revalidated with the server or from origin, never a cached copy taken as current (LoadFailure.cachePolicy).
    func load(_ url: URL, fresh: LoadFailure.Fresh = .normal) {
        pendingURL = nil; isStart = false; loadError = nil; crashed = false; asleep = false
        retryJob?.cancel(); retryJob = nil; retries = 0
        requestedURL = url
        retryFresh = fresh
        revalidateItem = nil
        // An .html file opened from another app (Finder, Claude) shows in a tab. WebKit reads a
        // file only through loadFileURL, and only inside the folder it is given (the file's own, for its images/css).
        if url.isFileURL {
            localRoot = url.deletingLastPathComponent()
            currentNavigation = webView.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
            return
        }
        currentNavigation = webView.load(URLRequest(url: url, cachePolicy: LoadFailure.cachePolicy(fresh)))
    }

    /// The folder a local file tab may read (set by `load` for a file the person opened); nil for web tabs, so a web
    /// page can never navigate to file:.
    private(set) var localRoot: URL?

    /// How the address failing now was asked for (a retry asks the same way: a Reload's retry still revalidates).
    private var retryFresh: LoadFailure.Fresh = .normal
    /// The address of the page WebKit last committed in this tab (nil: none, or its process died): a failed
    /// navigation to this same address leaves that page on screen instead of covering it with a card.
    private var committedURL: URL?
    /// A tab restored from WebKit's interaction state: its back/forward item comes from the cache, so it is reloaded
    /// (revalidating) once it has finished loading, not before (a reload before the item committed reloaded the
    /// empty initial document, or cancelled the restore).
    private weak var revalidateItem: WKBackForwardListItem?

    /// The address the tab last asked WebKit for: what Reload loads when WebKit has no page to reload (the first
    /// load was stopped or cancelled before it committed, so `webView.reload` does nothing).
    private var requestedURL: URL?

    // "Can't find this site" for a site that works. A failed main-frame load goes through
    // LoadFailure.decide: a failure of a navigation a newer one replaced is ignored, a transient lookup/connect
    // failure is tried again (twice, short pauses) before the card shows.
    /// The tab's latest main-frame navigation (set as each one starts); a failure of any other one is stale.
    private var currentNavigation: WKNavigation?
    /// Automatic tries made for the address that is failing now.
    private var retries = 0
    private var retryJob: Task<Void, Never>?
    /// When the address failing now first failed (the load_fail event's `ms`, LoadFailReport).
    private var failSince: Date?

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        // Our own retry set `currentNavigation` when it called load, before this callback; anything else (a link,
        // Back, the page's own location change) is a new navigation: a pending retry is dropped, tries start over.
        if let navigation, navigation !== currentNavigation {
            currentNavigation = navigation
            retryJob?.cancel(); retryJob = nil
            retries = 0
            retryFresh = .normal
        }
    }

    private func failed(_ navigation: WKNavigation?, error: Error, committed: Bool) {
        let e = error as NSError
        let current = navigation == nil || currentNavigation == nil || navigation === currentNavigation
        let failing = (e.userInfo[NSURLErrorFailingURLErrorKey] as? URL) ?? webView.url ?? url
        let web = ["http", "https"].contains(failing?.scheme?.lowercased() ?? "")
        // The page committed before at this very address is still what the web view shows (a provisional failure
        // leaves it there): a reload or a restore's revalidation that failed keeps it.
        let showing = !crashed && !asleep && LoadFailure.sameAddress(committedURL, failing) && LoadFailure.sameAddress(webView.url, failing)
        let decision = LoadFailure.decide(domain: e.domain, code: e.code, attempt: retries, current: current, committed: committed,
                                          web: web, showing: showing)
        if current, retries == 0 { failSince = Date() }
        switch decision {
        case .ignore:
            // A failure kept off the page that is still showing is logged too (LoadFailLog).
            if LoadFailLog.outcome(decision, domain: e.domain, code: e.code, current: current, committed: committed, showing: showing) == .kept {
                LoadFailReport.report(.kept, url: failing, domain: e.domain, code: e.code, committed: committed, retries: retries, since: failSince)
            }
            return
        case .retry(let pause) where failing != nil:
            let failing = failing!
            retries += 1
            let expected = navigation
            retryJob?.cancel()
            retryJob = Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(pause * 1_000_000_000))
                guard let self, !Task.isCancelled else { return }
                // The person (or the page) went elsewhere meanwhile: nothing to retry.
                guard expected == nil || self.currentNavigation === expected, !self.webView.isLoading else { self.retryJob = nil; return }
                self.retryJob = nil
                self.currentNavigation = self.webView.load(URLRequest(url: failing, cachePolicy: LoadFailure.cachePolicy(self.retryFresh)))
            }
        case .retry, .show:
            guard let pe = PageError(error, url: failing) else { return }
            LoadFailReport.report(.card, url: failing, domain: e.domain, code: e.code, committed: committed, retries: retries, since: failSince)
            retries = 0
            loadError = pe
            if pe.kind == .offline { retryWhenOnline() }
        }
    }

    /// Reload, or after a failure / crash / sleep load the page again.
    /// Every press reloads (WebKit's reload cancels the one in flight; nothing here waits on a flag),
    /// a page with nothing committed loads its address again, and a YouTube video comes back at the position it is
    /// at now, not at the `t` the tab was opened with (ReloadPolicy.swift).
    func reload(fromOrigin: Bool = false) {
        reloadSeq &+= 1
        let fresh: LoadFailure.Fresh = fromOrigin ? .origin : .revalidate
        if let u = pendingURL { load(u, fresh: fresh); return }
        if crashed || loadError != nil, let u = loadError?.url ?? url ?? requestedURL { load(u, fresh: fresh); return }
        guard let current = webView.url, MediaResume.applies(to: current) else { plainReload(fromOrigin); return }
        let seq = reloadSeq
        Task { @MainActor [weak self] in
            guard let self else { return }
            let at = await self.mediaPosition()
            guard seq == self.reloadSeq else { return }   // pressed again meanwhile: the newer press reloads
            guard self.webView.url == current else { self.plainReload(fromOrigin); return }   // went elsewhere meanwhile
            guard let at, let next = MediaResume.url(current, at: at), next != current else { self.plainReload(fromOrigin); return }
            // The current history entry takes the new address (no extra Back step), then a plain reload of it. If
            // the page did not take it, the address is loaded instead.
            _ = await self.agentJS("history.replaceState(history.state, '', u); return location.href;", ["u": next.absoluteString], within: 0.4)
            guard seq == self.reloadSeq else { return }
            if self.webView.url == next { self.plainReload(fromOrigin) } else { self.load(next, fresh: fresh) }
        }
    }

    /// Bumped by each Reload: an older press still reading the video's position gives way to the newer one.
    private var reloadSeq = 0

    private func plainReload(_ fromOrigin: Bool) {
        loadError = nil; crashed = false
        retryJob?.cancel(); retryJob = nil; retries = 0
        revalidateItem = nil
        retryFresh = fromOrigin ? .origin : .revalidate
        // WebKit's reload revalidates the page and its resources with the server; reloadFromOrigin skips the cache.
        let nav = fromOrigin ? webView.reloadFromOrigin() : webView.reload()
        if let nav { currentNavigation = nav }
        else if let u = webView.url ?? url ?? requestedURL { load(u, fresh: fromOrigin ? .origin : .revalidate) }   // nothing committed to reload
    }

    /// The position of the page's main video in seconds; nil: none, an ad is playing, a live stream, or the page did
    /// not answer within a moment (a busy page never holds a reload up).
    private func mediaPosition() async -> Double? {
        let js = """
        const p = document.querySelector('#movie_player');
        if (p && p.classList.contains('ad-showing')) return null;
        const v = document.querySelector('#movie_player video, video.html5-main-video') || [...document.querySelectorAll('video')].find((x) => x.duration > 0);
        if (!v || !isFinite(v.duration) || !isFinite(v.currentTime)) return null;
        return v.currentTime;
        """
        let r = await agentJS(js, within: 0.35)
        return (r as? Double) ?? (r as? NSNumber)?.doubleValue
    }

    /// Runs `js` in our own world (never the page's) and gives up after `seconds`: a page whose main thread is busy
    /// (or a navigation that dropped the call) answers nil instead of leaving the caller waiting forever.
    func agentJS(_ js: String, _ args: [String: Any] = [:], within seconds: Double) async -> Any? {
        guard let wv = loadedWebView else { return nil }
        return await withCheckedContinuation { (k: CheckedContinuation<Any?, Never>) in
            let once = OnceResume(k)
            wv.callAsyncJavaScript(js, arguments: args, in: nil, in: BrowserModel.agentWorld) { r in
                if case .success(let v) = r { once.resume(v) } else { once.resume(nil) }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { once.resume(nil) }
        }
    }

    /// A reopened tab: the pages it had behind it first (so Back works), then the page itself.
    func restoreHistory(_ back: [URL], then url: URL) {
        // WebKit has no API to rebuild a back list; the closest honest thing: load the page, keep its own history.
        load(url)
    }

    /// \u{2318}P: the system print panel for the page (Save as PDF included).
    func printPage() {
        guard let w = webView.window else { return }
        let op = webView.printOperation(with: NSPrintInfo.shared)
        op.view?.frame = webView.bounds
        op.runModal(for: w, delegate: nil, didRun: nil, contextInfo: nil)
    }

    // MARK: sound

    /// Mutes every audio/video element of the page, now and as new ones appear (our own world, never the page's).
    func setMuted(_ on: Bool) {
        muted = on
        applyMute()
    }

    private func applyMute() {
        let js = """
        const m = muted;
        const apply = () => document.querySelectorAll('video,audio').forEach(e => { e.muted = m; });
        apply();
        if (!window.__liaMuteObs) { window.__liaMuteObs = new MutationObserver(() => { if (window.__liaMuted) document.querySelectorAll('video,audio').forEach(e => { e.muted = true; }); }); window.__liaMuteObs.observe(document.documentElement, {childList: true, subtree: true}); }
        window.__liaMuted = m;
        return true;
        """
        webView.callAsyncJavaScript(js, arguments: ["muted": muted], in: nil, in: BrowserModel.agentWorld) { _ in }
    }

    /// Asks WebKit whether the page plays media now (the speaker on the tab).
    func refreshPlaying() {
        webView.requestMediaPlaybackState { [weak self] state in
            Task { @MainActor in self?.playing = state == .playing }
        }
    }

    /// The text the person selected on the page (\u{2318}E, "Ask Lia about this").
    func selectedText() async -> String {
        let r = try? await webView.callAsyncJavaScript("return String(window.getSelection ? window.getSelection() : '').slice(0, 4000);", arguments: [:], in: nil, contentWorld: BrowserModel.agentWorld)
        // The agents get this text: a password Liaison filled or saw submitted never goes with it.
        return PasswordSecrets.scrub((r as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines))
    }

    private func updateCapture(_ w: WKWebView) {
        capturing = w.cameraCaptureState == .active || w.microphoneCaptureState == .active
    }

    // MARK: sleep

    func sleep() {
        guard let u0 = url ?? pendingURL, !asleep else { return }
        let keepTitle = displayTitle
        // A sleeping YouTube tab wakes at the position it was at, not at the `t` it was opened with.
        guard pendingURL == nil, MediaResume.applies(to: u0) else { sleep(u0, title: keepTitle); return }
        Task { @MainActor [weak self] in
            guard let self else { return }
            let at = await self.mediaPosition()
            guard !self.asleep, self.pendingURL == nil, self.url == u0 else { return }   // woke or moved meanwhile
            let next = at.flatMap { MediaResume.url(u0, at: $0) } ?? u0
            // The current history entry takes the new `t` first, so the state taken below is at it too.
            if next != u0 {
                _ = await self.agentJS("history.replaceState(history.state, '', u); return location.href;", ["u": next.absoluteString], within: 0.4)
                guard !self.asleep, self.pendingURL == nil else { return }
            }
            self.sleep(next, title: keepTitle)
        }
    }

    private func sleep(_ u: URL, title keepTitle: String) {
        // Back, the scroll position and forms come back on wake (loadIfPending), not just the address.
        captureState()
        if let o = owner, let chat = o.chatID { writeStateIfNeeded(account: o.account, chat: chat) }
        webView.takeSnapshot(with: nil) { [weak self] img, _ in
            Task { @MainActor in
                guard let self, !self.asleep else { return }
                self.snapshot = img
                self.webView.pauseAllMediaPlayback(completionHandler: nil)
                self.prepare(u, title: keepTitle)
                self.asleep = true
                if let blank = URL(string: "about:blank") { self.webView.load(URLRequest(url: blank)) }
            }
        }
    }

    // MARK: zoom

    func setZoom(_ z: CGFloat) {
        zoom = z
        ZoomStore.set(z, for: url?.host)
        (webView as? DesktopWebView)?.userZoom = z
    }
    func zoomIn() { setZoom(ZoomStore.next(zoom, up: true)) }
    func zoomOut() { setZoom(ZoomStore.next(zoom, up: false)) }
    func zoomReset() { setZoom(1) }

    // MARK: find (/02)

    /// How many times the text is on the page (counted in our own world, never the page's).
    func countMatches(_ text: String) async -> Int {
        guard !text.isEmpty else { return 0 }
        let js = "const t=(document.body&&document.body.innerText||'').toLowerCase();const q=s.toLowerCase();let n=0,i=0;while((i=t.indexOf(q,i))!==-1){n++;i+=q.length;}return n;"
        // (find bar stuck): a busy page (a playing YouTube, a page mid-reload) could keep this await
        // open; the bar then never showed a count. A moment at most, then "no answer" (0).
        let r = await agentJS(js, ["s": text], within: 1.5)
        return (r as? Int) ?? (r as? NSNumber)?.intValue ?? 0
    }

    /// The next (or previous) match selected and scrolled to; false: none (or WebKit did not answer in a moment).
    func find(_ text: String, backwards: Bool = false) async -> Bool {
        guard !text.isEmpty, let wv = loadedWebView else { return false }
        let c = WKFindConfiguration()
        c.backwards = backwards
        c.caseSensitive = false
        c.wraps = true
        let r: Any? = await withCheckedContinuation { (k: CheckedContinuation<Any?, Never>) in
            let once = OnceResume(k)
            wv.find(text, configuration: c) { result in once.resume(result.matchFound) }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { once.resume(nil) }
        }
        return (r as? Bool) ?? false
    }

    /// A restored tab: its address and title without loading it; its icon from the disk cache if there is one.
    func prepare(_ url: URL, title: String) {
        pendingURL = url
        restoredTitle = title
        self.url = url
        isStart = false
        if let host = url.host {
            // A tab going to sleep keeps the icon it has (the memory cache may not hold its host).
            let keep = faviconHost == host && favicon != nil
            faviconHost = host
            if !keep { favicon = Favicons.cached(host) }
            if favicon == nil {
                // A restored tab whose icon was never saved asks the site's /favicon.ico,
                // so the tab lists (Home's "This client's tabs", the history menu) show it before the tab is opened.
                let scheme = url.scheme?.lowercased() == "http" ? "http" : "https"
                let fallback = URL(string: scheme + "://" + host + "/favicon.ico").map { [$0] } ?? []
                Task { @MainActor [weak self] in
                    let img = await Favicons.icon(host: host, candidates: fallback)
                    if let self, self.faviconHost == host, let img { self.favicon = img }
                }
            }
        }
    }

    /// A restored or sleeping tab, shown: back from its interaction state when that is about this same address
    /// (Back, the scroll position and the form come back), else loaded from the address.
    func loadIfPending() {
        guard let u = pendingURL else { return }
        if let s = pendingState(for: u), restore(state: s, at: u) { return }
        load(u)
    }

    private func pendingState(for u: URL) -> Data? {
        if stateData == nil, !stateReadFromDisk, let o = owner, let chat = o.chatID {
            stateReadFromDisk = true
            if let r = TabStateStore.read(account: o.account, chat: chat, tab: sid) { stateData = r.state; stateURL = URL(string: r.url) }
        }
        guard let s = stateData,
              TabRestore.source(savedURL: u.absoluteString, stateURL: stateURL?.absoluteString, stateBytes: s.count) == .state else { return nil }
        return s
    }

    /// The page from WebKit's interaction state. false: WebKit did not take it (the caller loads `u`).
    @discardableResult
    func restore(state: Data, at u: URL) -> Bool {
        pendingURL = nil; isStart = false; loadError = nil; crashed = false; asleep = false
        retryJob?.cancel(); retryJob = nil; retries = 0
        requestedURL = u
        retryFresh = .normal
        webView.interactionState = state
        guard let item = webView.backForwardList.currentItem, TabRestore.isWeb(item.url) else { return false }
        // (the agent's pane after an update showed our landing as it was before the redeploy): WebKit
        // shows a restored back/forward item from the cache without asking the server. Reloaded once, revalidating
        // (Back, the scroll position stay), when the restored item has finished (didFinish); a navigation started
        // meanwhile is left alone. Before, the reload ran at once, before the item committed, and raced its load.
        revalidateItem = item
        return true
    }

    /// WebKit's interaction state of the page shown now, with the address it is at (resign, quit, sleep, close, and
    /// each save after a navigation). Over the cap, or not readable: none (the address alone restores the tab).
    func captureState() {
        guard let wv = loadedWebView, !asleep, pendingURL == nil, let u = wv.url, TabRestore.isWeb(u) else { return }
        stateDirty = false
        guard let d = wv.interactionState as? Data, TabRestore.keeps(stateBytes: d.count) else {
            stateData = nil; stateURL = nil
            return
        }
        if d != stateData || u != stateURL { stateData = d; stateURL = u; stateUnwritten = true }
    }

    /// The state taken at `u` (nil: none, or taken at another address).
    func state(at u: URL) -> Data? { stateURL == u ? stateData : nil }

    func writeStateIfNeeded(account: String?, chat: String) {
        guard stateUnwritten, let d = stateData, let u = stateURL else { return }
        stateUnwritten = false
        TabStateStore.write(d, url: u.absoluteString, account: account, chat: chat, tab: sid)
    }

    /// Reads where this tab's YouTube video is (a loaded, awake tab only).
    func sampleMedia() async {
        guard let wv = loadedWebView, !asleep, pendingURL == nil, let u = wv.url, MediaResume.applies(to: u) else { return }
        if let at = await mediaPosition(), loadedWebView?.url == u { mediaSample = (u, at) }
    }

    /// What BrowserMemory keeps: the tab's LATEST address (TabRestore.latest: what the web view shows now, History
    /// API changes included) and title, or the saved ones while the tab is not loaded.
    var savedURL: URL? { isStart ? nil : TabRestore.latest(pending: pendingURL, live: asleep ? nil : loadedWebView?.url, known: url) }
    var savedTitle: String { pendingURL != nil || title.isEmpty ? restoredTitle : title }

    /// A popup WebKit created for us starts loading on its own.
    func markLoaded() { isStart = false }

    // MARK: WKUIDelegate

    /// window.outerWidth/outerHeight: the real window, never 0x0 (PageWindowFrame.swift).
    @objc(_webView:getWindowFrameWithCompletionHandler:)
    func webViewGetWindowFrame(_ webView: WKWebView, completionHandler: @escaping (CGRect) -> Void) {
        completionHandler(PageWindowFrame.of(webView))
    }

    /// window.open and target=_blank. The new tab must use the configuration WebKit hands over, or a
    /// sign-in popup (Google, Facebook) loses its opener and the login never completes.
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        guard let owner else { return nil }
        // A target=_blank link to mailto:/tel:/app schemes: no empty tab, the same "Open in …?" as a plain link.
        if let u = navigationAction.request.url, let scheme = u.scheme?.lowercased(),
           !["http", "https", "about", "blob", "data"].contains(scheme) {
            if scheme != "file", navigationAction.navigationType == .linkActivated { askToOpenExternally(u, in: webView.window) }
            return nil
        }
        // A sized window.open (OAuth / sign-in pop-ups): a pop-up window above our modals, not a tab.
        if WebPopupWindow.wantsWindow(windowFeatures) {
            return WebPopupWindow.adopt(configuration: configuration, features: windowFeatures)
        }
        let tab = owner.newTab(url: nil, configuration: configuration, opener: self)
        tab.markLoaded()
        return tab.webView
    }

    func webViewDidClose(_ webView: WKWebView) {
        owner?.close(self)
    }

    /// Page dialogs are sheets on this window, never app-modal: a page cannot freeze the whole app. Without a
    /// window, or past the budget (3 within 10 s for this page load), the dialog is denied.
    func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping () -> Void) {
        guard let window = webView.window, dialogs.allow() else { completionHandler(); return }
        let a = NSAlert()
        a.messageText = frame.request.url?.host ?? ""
        a.informativeText = message
        a.addButton(withTitle: "OK")
        a.beginSheetModal(for: window) { (_: NSApplication.ModalResponse) in completionHandler() }
    }

    func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping (Bool) -> Void) {
        guard let window = webView.window, dialogs.allow() else { completionHandler(false); return }
        let a = NSAlert()
        a.messageText = frame.request.url?.host ?? ""
        a.informativeText = message
        a.addButton(withTitle: "OK")
        a.addButton(withTitle: "Cancel")
        a.beginSheetModal(for: window) { (r: NSApplication.ModalResponse) in completionHandler(r == .alertFirstButtonReturn) }
    }

    func webView(_ webView: WKWebView, runOpenPanelWith parameters: WKOpenPanelParameters,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping ([URL]?) -> Void) {
        let p = NSOpenPanel()
        p.allowsMultipleSelection = parameters.allowsMultipleSelection
        p.canChooseDirectories = parameters.allowsDirectories
        p.canChooseFiles = true
        completionHandler(p.runModal() == .OK ? p.urls : nil)
    }

    // MARK: downloads (Ads Manager exports, reports): into ~/Downloads, as Safari does

    func webView(_ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse,
                 decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void) {
        // Exports (CSV, reports) come as Content-Disposition: attachment even when WebKit could show them.
        if let http = navigationResponse.response as? HTTPURLResponse,
           let cd = http.value(forHTTPHeaderField: "Content-Disposition"),
           cd.lowercased().hasPrefix("attachment") {
            decisionHandler(.download); return
        }
        decisionHandler(navigationResponse.canShowMIMEType ? .allow : .download)
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        if navigationAction.shouldPerformDownload { decisionHandler(.download); return }
        // \u{2318}-click or the middle button on a link opens it in a new tab next to this one (in the
        // background; \u{21E7}\u{2318} brings it to front), as Chrome and Safari do. WebKit would load it right here.
        if navigationAction.navigationType == .linkActivated,
           TabStrip.linkWantsNewTab(command: navigationAction.modifierFlags.contains(.command), button: navigationAction.buttonNumber),
           let u = navigationAction.request.url, ["http", "https"].contains(u.scheme?.lowercased() ?? ""), let owner {
            decisionHandler(.cancel)
            owner.newTab(url: u, select: navigationAction.modifierFlags.contains(.shift), opener: self)
            return
        }
        // \u{21E7}-click on a link opens it in Peek over the page instead of leaving it.
        // A link on a pinned tab that leaves its site opens in Peek; the pinned page stays put.
        if pinned, navigationAction.navigationType == .linkActivated, navigationAction.targetFrame?.isMainFrame ?? false,
           let u = navigationAction.request.url, ["http", "https"].contains(u.scheme?.lowercased() ?? ""),
           let to = u.host?.lowercased(), let from = webView.url?.host?.lowercased(),
           !(to == from || to.hasSuffix("." + from) || from.hasSuffix("." + to)), let ws = WorkspaceModel.current {
            decisionHandler(.cancel)
            ws.peek = u
            return
        }
        if navigationAction.navigationType == .linkActivated, navigationAction.modifierFlags.contains(.shift),
           !navigationAction.modifierFlags.contains(.command), let u = navigationAction.request.url,
           ["http", "https"].contains(u.scheme?.lowercased() ?? ""), let ws = WorkspaceModel.current {
            decisionHandler(.cancel)
            ws.peek = u
            return
        }
        // A local file tab (the person opened an .html file) may follow links inside its own folder.
        if let u = navigationAction.request.url, u.isFileURL, let root = localRoot, webView.url?.isFileURL ?? false,
           u.standardizedFileURL.path.hasPrefix(root.standardizedFileURL.path) {
            decisionHandler(.allow)
            return
        }
        // mailto:, tel:, facetime: and app links belong to the system, but only from a link the person clicked in
        // the page itself, and only after they say yes. file: is never opened from a web page.
        if let u = navigationAction.request.url, let scheme = u.scheme?.lowercased(), !["http", "https", "about", "blob", "data"].contains(scheme) {
            decisionHandler(.cancel)
            if scheme != "file", navigationAction.navigationType == .linkActivated,
               navigationAction.targetFrame?.isMainFrame ?? false {
                askToOpenExternally(u, in: webView.window)
            }
            return
        }
        // Workspace accounts: Google services and Ads Manager open on the workspace's fixed account.
        if let u = pinnedAccountURL(navigationAction) {
            decisionHandler(.cancel)
            webView.load(URLRequest(url: u))
            return
        }
        decisionHandler(.allow)
    }

    /// The same address with `authuser` / `business_id` of the workspace this browser belongs to (Workspace
    /// settings); nil: go on as asked. Main frame GETs only. It never loops: the new address carries the parameter,
    /// and a parameter already there (the person's own choice) is never replaced.
    private func pinnedAccountURL(_ action: WKNavigationAction) -> URL? {
        guard let owner, action.targetFrame?.isMainFrame ?? true, (action.request.httpMethod ?? "GET") == "GET",
              let u = action.request.url, ["http", "https"].contains(u.scheme?.lowercased() ?? ""),
              let host = u.host?.lowercased(),
              WorkspaceAccounts.googleHosts.contains(host) || WorkspaceAccounts.metaHosts.contains(host),
              let profile = WorkspaceAccounts.profile(ofBrowserKey: owner.account) else { return nil }
        // Loop guard: one rewrite per host per 5 s (a service that strips the parameter again is left alone).
        if let t = owner.accountPinnedAt[host], Date().timeIntervalSince(t) < 5 { return nil }
        // The first visit to a host this launch: the fixed account wins over the one the last session ended on.
        let first = owner.accountPinnedHosts.insert(host).inserted
        guard let to = WorkspaceAccounts.pinned(u, profile: profile, force: first), to != u else { return nil }
        owner.accountPinnedAt[host] = Date()
        return to
    }

    /// "Open in Mail?" as a sheet on this window. No window or no app for the link: nothing happens.
    private func askToOpenExternally(_ url: URL, in window: NSWindow?) {
        guard let window, let app = NSWorkspace.shared.urlForApplication(toOpen: url) else { return }
        let name = FileManager.default.displayName(atPath: app.path).replacingOccurrences(of: ".app", with: "")
        let a = NSAlert()
        a.messageText = "Open in \(name)?"
        a.informativeText = url.scheme.map { $0 + ": link" } ?? ""
        a.addButton(withTitle: "Open")
        a.addButton(withTitle: "Cancel")
        a.beginSheetModal(for: window) { (r: NSApplication.ModalResponse) in
            if r == .alertFirstButtonReturn { NSWorkspace.shared.open(url) }
        }
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        failed(navigation, error: error, committed: false)
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        failed(navigation, error: error, committed: true)
    }

    /// The page's process ended (WebKit crash or memory): a card with Reload instead of a blank page.
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        committedURL = nil
        if asleep { return }
        crashed = true
    }

    /// Offline: try again every few seconds until the page loads or the person goes elsewhere.
    private func retryWhenOnline() {
        Task { @MainActor [weak self] in
            for _ in 0..<60 {
                try? await Task.sleep(nanoseconds: 5_000_000_000)
                guard let self, let e = self.loadError, e.kind == .offline else { return }
                if let u = e.url, await Self.reachable(u) { self.load(u); return }
            }
        }
    }

    private static func reachable(_ u: URL) async -> Bool {
        var r = URLRequest(url: u, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 4)
        r.httpMethod = "HEAD"
        return (try? await URLSession.shared.data(for: r)) != nil
    }

    /// Camera / microphone (/02): asked once per site in this profile, remembered.
    func webView(_ webView: WKWebView, requestMediaCapturePermissionFor origin: WKSecurityOrigin, initiatedByFrame frame: WKFrameInfo,
                 type: WKMediaCaptureType, decisionHandler: @escaping (WKPermissionDecision) -> Void) {
        let kind: PermissionStore.Kind = type == .camera ? .camera : (type == .microphone ? .microphone : .cameraAndMicrophone)
        let host = origin.host
        if let d = PermissionStore.decision(kind, host: host, account: owner?.account) { decisionHandler(d ? .grant : .deny); return }
        permission?.answer(false)
        permission = PermissionAsk(host: host, kind: kind) { [weak self] d in
            decisionHandler(d)
            Task { @MainActor in self?.permission = nil }
        }
    }

    /// The person answered the card: remembered for this site in this profile when asked to.
    func answerPermission(_ allow: Bool, remember: Bool) {
        guard let p = permission else { return }
        if remember { PermissionStore.set(allow, p.kind, host: p.host, account: owner?.account) }
        p.answer(allow)
        permission = nil
    }

    /// A new page: its dialog budget starts over; another site's page drops the old site's icon.
    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        // The toolbar looks at the new page as soon as it has painted (~150 ms), not after the whole load.
        ToolbarTint.shared.committed(self)
        passwords.committed()
        dialogs.reset()
        loadError = nil
        retries = 0
        retryJob?.cancel(); retryJob = nil
        crashed = false
        committedURL = webView.url
        // The page that asked for the camera/microphone is gone: its ask is answered (No), never left hanging.
        if permission != nil { answerPermission(false, remember: false) }
        if webView.url?.absoluteString != "about:blank" { asleep = false; snapshot = nil }
        let z = ZoomStore.zoom(for: webView.url?.host)
        if z != zoom { zoom = z; (webView as? DesktopWebView)?.userZoom = z }
        let host = webView.url?.host
        // The blank page a sleeping tab loads (and any page without a host) keeps the tab's icon; before,
        // sleep dropped it and every list that reads `favicon` showed a globe.
        if let host, host != faviconHost {
            faviconHost = host
            favicon = Favicons.cached(host)
            themeColor = nil
        }
    }

    /// The page has loaded: its icon, asked in our own world (never the page's), fetched off the main thread.
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        // The page is here: no card over it, whatever an earlier navigation said.
        loadError = nil
        retries = 0
        if let u = webView.url { committedURL = u }
        if let item = revalidateItem {
            revalidateItem = nil
            if webView.backForwardList.currentItem === item, TabRestore.isWeb(webView.url) {
                retryFresh = .revalidate
                if let nav = webView.reload() { currentNavigation = nav }
            }
        }
        guard let host = webView.url?.host, let scheme = webView.url?.scheme?.lowercased(),
              scheme == "http" || scheme == "https" else { return }
        restoredTitle = ""   // the page is here: its own title (or its host) from now on
        stateDirty = true
        passwords.finished()
        if let u = webView.url { HistoryStore.record(u, title: webView.title ?? "", account: owner?.account) }
        if muted { applyMute() }
        refreshPlaying()
        if let css = Boosts.css(for: host) {
            webView.callAsyncJavaScript(Boosts.script, arguments: ["css": css], in: nil, in: BrowserModel.agentWorld) { _ in }
        }
        // The page's theme-color, for the toolbar's accent (our own world; the page never sees it).
        let themeJS = "const m = document.querySelector('meta[name=\"theme-color\"]'); return m ? String(m.content || '') : '';"
        webView.callAsyncJavaScript(themeJS, arguments: [:], in: nil, in: BrowserModel.agentWorld) { [weak self] result in
            var raw: String?
            if case .success(let v) = result { raw = v as? String }
            let c = CSSColor.parse(raw)
            Task { @MainActor [weak self] in
                guard let self, self.faviconHost == host else { return }
                if self.themeColor != c { self.themeColor = c }
            }
        }
        faviconHost = host
        if let img = Favicons.cached(host) { favicon = img; return }
        webView.callAsyncJavaScript(Favicons.script, arguments: [:], in: nil, in: BrowserModel.agentWorld) { [weak self] result in
            var found: [URL] = []
            if case .success(let v) = result, let list = v as? [String] { found = list.compactMap { URL(string: $0) } }
            if found.isEmpty, let u = URL(string: scheme + "://" + host + "/favicon.ico") { found = [u] }
            let candidates = found
            Task { @MainActor [weak self] in
                let img = await Favicons.icon(host: host, candidates: candidates)
                if let self, self.faviconHost == host, let img { self.favicon = img }
            }
        }
    }

    func webView(_ webView: WKWebView, navigationResponse: WKNavigationResponse, didBecome download: WKDownload) { download.delegate = self }
    func webView(_ webView: WKWebView, navigationAction: WKNavigationAction, didBecome download: WKDownload) { download.delegate = self }
    /// The page menu's Download Image / Download Linked File: WebKit hands the download to this (private, stable
    /// since macOS 11.3) navigation-delegate method; without it the download has no delegate and goes nowhere.
    @objc(_webView:contextMenuDidCreateDownload:)
    func webViewContextMenuDidCreateDownload(_ webView: WKWebView, download: WKDownload) { download.delegate = self }

    func download(_ download: WKDownload, decideDestinationUsing response: URLResponse, suggestedFilename: String,
                  completionHandler: @escaping (URL?) -> Void) {
        var dir = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0]
        // One folder per client so exports of two clients never mix.
        if Prefs.flag(Prefs.downloadsPerClient), let name = owner?.clientName?.trimmingCharacters(in: .whitespaces), !name.isEmpty {
            let safe = name.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
            let sub = dir.appendingPathComponent("Liaison", isDirectory: true).appendingPathComponent(safe, isDirectory: true)
            if (try? FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)) != nil { dir = sub }
        }
        var dest = dir.appendingPathComponent(suggestedFilename)
        let base = dest.deletingPathExtension().lastPathComponent, ext = dest.pathExtension
        var n = 1
        while FileManager.default.fileExists(atPath: dest.path) {
            dest = dir.appendingPathComponent("\(base) (\(n))" + (ext.isEmpty ? "" : ".\(ext)")); n += 1
        }
        let agent = owner?.chatID.flatMap { $0.hasPrefix("agent-") ? String($0.dropFirst(6)) : nil }
        DownloadsCenter.shared.started(download, name: dest.lastPathComponent, dest: dest, webView: webView, agent: agent)
        completionHandler(dest)
    }

    func downloadDidFinish(_ download: WKDownload) { DownloadsCenter.shared.finished(download) }

    func download(_ download: WKDownload, didFailWithError error: Error, resumeData: Data?) {
        DownloadsCenter.shared.failed(download, resumeData: resumeData)
    }
}

/// Sites made for a desktop screen (Ads Manager first) lose buttons below ~1100 CSS px. A panel narrower than that
/// keeps a desktop page (1100 px) and shows it smaller (page zoom), down to 75 % (55 % was too small to read), instead of a cramped one.
/// Height is not touched: the page is as tall as the panel. The agent's rectangles already account for the zoom.
final class DesktopWebView: WKWebView {
    static let desktopWidth: CGFloat = 1100
    static let minZoom: CGFloat = 0.75

    /// The person's zoom for the site, times the fit below.
    var userZoom: CGFloat = 1 { didSet { applyZoom() } }
    private var fit: CGFloat = 1
    /// The tab this page belongs to (WebFocusKeeper asks whether its agent is at work).
    weak var tab: BrowserTab?

    /// (the Mac beeps on typing into a field just clicked): a press on the page always gives the page
    /// the keys, whatever had them (NSWindow does it only for the view its hit test found).
    override func mouseDown(with event: NSEvent) {
        if let w = window, w.firstResponder !== self, !((w.firstResponder as? NSView)?.isDescendant(of: self) ?? false) {
            w.makeFirstResponder(self)
        }
        super.mouseDown(with: event)
    }

    override func resignFirstResponder() -> Bool {
        let done = super.resignFirstResponder()
        if done { WebFocusKeeper.shared.resigned(self) }
        return done
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        guard newSize.width > 50 else { return }
        fit = min(1, max(Self.minZoom, newSize.width / Self.desktopWidth))
        applyZoom()
    }

    private func applyZoom() {
        let z = fit * userZoom
        if abs(pageZoom - z) > 0.005 { pageZoom = z }
    }

    /// The page menu. WebKit's useful items stay (Back/Forward/Reload, Copy/Paste, links, images,
    /// downloads, Inspect Element); Apple's system extras go (Look Up, Translate, Speech, Share, Services,
    /// Writing Tools, Summarize); ours are added: Ask Lia About This, and translation.
    /// 0.2.11: translation lives here first, on every web page whatever the language detection
    /// said (the tab's button shows only when it recognised a foreign page): "Translate" with text selected (the
    /// system popover at the selection), "Translate Page" without, "Show Original" while the page is translated.
    /// All on this Mac (PageTranslator); no agent and no server ever translates.
    override func willOpenMenu(_ menu: NSMenu, with event: NSEvent) {
        super.willOpenMenu(menu, with: event)
        for item in menu.items where PageMenu.isNoise(item) { menu.removeItem(item) }
        DevPickerMenuHook.add(to: menu, webView: self, event: event)
        if let link = menu.items.first(where: { $0.identifier?.rawValue == "WKMenuItemIdentifierOpenLinkInNewWindow" }) {
            link.title = "Open Link in New Tab"
        }
        menu.addItem(.separator())
        let ask = NSMenuItem(title: "Ask Lia About This", action: #selector(askLia(_:)), keyEquivalent: "")
        ask.target = self
        menu.addItem(ask)
        if PageMenu.isWebPage(url) {
            let hasSelection = menu.items.contains { $0.identifier?.rawValue == "WKMenuItemIdentifierCopy" }
            let on = PageTranslateCenter.shared.existing(self)?.phase.isActive ?? false
            for t in PageMenu.translateTitles(hasSelection: hasSelection, translated: on) {
                let action: Selector = t == PageMenu.translateSelectionTitle ? #selector(translateSelection(_:)) : #selector(translatePage(_:))
                let item = NSMenuItem(title: t, action: action, keyEquivalent: "")
                item.target = self
                menu.addItem(item)
            }
        }
        // Inspect Element last, after ours (WebKit puts it wherever it likes).
        if let inspect = menu.items.first(where: { $0.identifier?.rawValue == "WKMenuItemIdentifierInspectElement" }) {
            menu.removeItem(inspect)
            menu.addItem(.separator())
            menu.addItem(inspect)
        }
        PageMenu.tidySeparators(menu)
    }

    @objc private func askLia(_ sender: Any?) {
        Task { @MainActor in WorkspaceModel.current?.askAboutSelection() }
    }

    /// Translate Page / Show Original: on this Mac, in place (PageTranslator, 0.2.11). It used to go to an agent.
    @objc private func translatePage(_ sender: Any?) {
        Task { @MainActor in PageTranslateCenter.shared.model(for: self).toggle() }
    }

    /// Translate (text selected): the system's translation popover at the selection.
    @objc private func translateSelection(_ sender: Any?) {
        Task { @MainActor in PageTranslateCenter.shared.model(for: self).translateSelection() }
    }
}

/// What the page menu drops and how it tidies up after.
enum PageMenu {
    /// WebKit identifiers of Apple's extras (macOS 14-26).
    static let noiseIDs: Set<String> = [
        "WKMenuItemIdentifierLookUp", "WKMenuItemIdentifierTranslate", "WKMenuItemIdentifierSearchWeb",
        "WKMenuItemIdentifierShareMenu", "WKMenuItemIdentifierSpeechMenu", "WKMenuItemIdentifierWritingTools",
        "WKMenuItemIdentifierSummarize", "WKMenuItemIdentifierCopyLinkWithHighlight",
    ]
    /// Titles for the ones with no identifier (AppKit adds Services, Writing Tools and Siri items itself).
    static let noiseTitles = ["Look Up", "Translate", "Search with", "Share", "Speech", "Services",
                              "Writing Tools", "Show Writing Tools", "Summarize", "Proofread", "Rewrite",
                              "Siri", "Ask Siri", "Make Summary", "Font", "Copy Link with Highlight"]

    static func isNoise(_ item: NSMenuItem) -> Bool {
        if let id = item.identifier?.rawValue, noiseIDs.contains(id) { return true }
        if item.isSeparatorItem { return false }
        let t = item.title
        return noiseTitles.contains { t == $0 || t.hasPrefix($0 + " ") || t.hasPrefix($0 + "\u{2026}") }
    }

    static let translateSelectionTitle = "Translate"
    static let translatePageTitle = "Translate Page"
    static let showOriginalTitle = "Show Original"

    /// Our translation items, in order: "Translate" with a selection, "Translate Page" without; "Show Original"
    /// instead of "Translate Page" while the page is translated (also beside "Translate").
    static func translateTitles(hasSelection: Bool, translated: Bool) -> [String] {
        var out: [String] = []
        if hasSelection { out.append(translateSelectionTitle) }
        if translated { out.append(showOriginalTitle) } else if !hasSelection { out.append(translatePageTitle) }
        return out
    }

    /// A page from the web (not the start page, a blank tab or a local file): translation is offered there.
    static func isWebPage(_ url: URL?) -> Bool { ["http", "https"].contains(url?.scheme?.lowercased() ?? "") }

    /// No separator first, last or twice in a row.
    static func tidySeparators(_ menu: NSMenu) {
        var prevSep = true
        for item in menu.items {
            if item.isSeparatorItem {
                if prevSep { menu.removeItem(item) } else { prevSep = true }
            } else { prevSep = false }
        }
        while let last = menu.items.last, last.isSeparatorItem { menu.removeItem(last) }
    }

    /// The person's language in English ("Italian"), for Translate Page.
    static var systemLanguage: String {
        let code = Locale.preferredLanguages.first.map { Locale(identifier: $0).language.languageCode?.identifier ?? "en" } ?? "en"
        return Locale(identifier: "en").localizedString(forLanguageCode: code) ?? "English"
    }
}

/// A continuation resumed by whichever comes first (WebKit's answer or a deadline), exactly once.
/// Callable from any thread (WebKit's completion, a GCD deadline).
final class OnceResume: @unchecked Sendable {
    private let lock = NSLock()
    private var k: CheckedContinuation<Any?, Never>?
    init(_ k: CheckedContinuation<Any?, Never>) { self.k = k }
    func resume(_ v: Any?) {
        lock.lock()
        let k = self.k
        self.k = nil
        lock.unlock()
        k?.resume(returning: v)
    }
}

// MARK: -: the page the person is looking at

extension BrowserModel {
    /// What the person is looking at in this browser now: a tab (the one in front), or the Peek panel's page over it.
    struct LookedAt {
        let tab: BrowserTab?
        let peek: WKWebView?
    }

    /// (incident: agents answered about a tab nobody was looking at). `third`: the third pane of a
    /// three-pane view (WSThirdPane); `peekOpen`: the workspace's Peek panel is open over this browser. Read only:
    /// the window is the one the stage's web views sit in; in it the pane whose web view holds the keyboard focus
    /// wins over the selected tab (ScreenShare.frontID has the order). Peek's page is the plain web view on this
    /// browser's data store over the stage (the largest one: web panels share the store but are narrow). A private
    /// window has its own store and window, so nothing of it is found here.
    func lookedAt(third: BrowserTab?, peekOpen: Bool) -> LookedAt {
        let panes = [selected, splitTab, third].compactMap { $0 }
        let window = panes.lazy.compactMap { $0.loadedWebView?.window }.first
        var peekView: WKWebView?
        if peekOpen, let root = (window ?? NSApp.keyWindow ?? NSApp.mainWindow)?.contentView {
            var found: [WKWebView] = []
            Self.plainWebViews(in: root, store: Self.dataStore(for: account), into: &found)
            peekView = found.max { $0.bounds.width * $0.bounds.height < $1.bounds.width * $1.bounds.height }
        }
        var focused: String?
        if let r = window?.firstResponder as? NSView {
            focused = panes.first { t in t.loadedWebView.map { r === $0 || r.isDescendant(of: $0) } ?? false }?.id.uuidString
        }
        let id = ScreenShare.frontID(peek: peekView != nil, focused: focused, panes: panes.map(\.id.uuidString),
                                     selected: selectedID?.uuidString, tabs: tabs.map(\.id.uuidString))
        return LookedAt(tab: peekView == nil ? tabs.first { $0.id.uuidString == id } : nil, peek: peekView)
    }

    private static func plainWebViews(in v: NSView, store: WKWebsiteDataStore, into out: inout [WKWebView]) {
        if let w = v as? WKWebView {
            if type(of: w) == WKWebView.self, w.configuration.websiteDataStore === store, w.window != nil, !w.isHiddenOrHasHiddenAncestor { out.append(w) }
            return
        }
        for s in v.subviews { plainWebViews(in: s, store: store, into: &out) }
    }
}

/// Which data store a browser pane got (Met's pane signed out of Ads Manager): one os_log line per pane
/// made (subsystem com.liaisone.mac, category stores) naming the store's kind (PaneStore), never an id or a key.
@MainActor
enum StoreLog {
    private static let log = Logger(subsystem: "com.liaisone.mac", category: "stores")

    static func pane(_ what: String, browser b: BrowserModel, workspace: String?) {
        let kind = PaneStore.of(pane: b.account, workspace: workspace)
        let persistent = BrowserModel.dataStore(for: b.account).isPersistent
        log.notice("\(what, privacy: .public): store=\(kind.rawValue, privacy: .public) persistent=\(persistent, privacy: .public)")
    }

    static func replaced(agent: String) {
        log.notice("agent pane \(agent, privacy: .public): was on another store, made again on the workspace store")
    }
}
