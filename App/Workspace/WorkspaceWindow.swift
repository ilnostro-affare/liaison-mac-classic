import SwiftUI
import AppKit
import WebKit
import Network
import UniformTypeIdentifiers
import TipKit

/// The new main window. No sidebar: the company profile's tab group on top (switched like
/// a browser profile), its browser in the middle, the agents in a dock at the bottom; a conversation opens as a
/// sheet over the page with the agent's own browser beside it. It is the only window (the classic one is in Legacy/).
struct WorkspaceWindow: View {
    @EnvironmentObject private var app: AppModel
    @StateObject private var ws: WorkspaceModel
    /// The address field's state (OMNI): the selected tab edits it, the window draws its suggestions.
    @StateObject private var omni = OmniboxModel()
    /// The network, for the offline banner.
    @StateObject private var net = WSNetworkMonitor()
    @ObservedObject private var win = WindowState.shared
    @Environment(\.accessibilityReduceMotion) private var reduce
    /// The page card's and the downloads button's frames, for the download flight.
    @State private var frames = WSFrameBox()
    /// A link from another app that came before the workspace was ready; shown in Peek once it is.
    @State private var pendingLink: URL?
    /// The dock's figures and the open conversation's header share it (one element flies between them).
    @Namespace private var hero

    init(auth: AuthStore) { _ws = StateObject(wrappedValue: WorkspaceModel(auth: auth)) }

    // The body is split in three steps: one chain of 30+ modifiers is too much for the type checker.
    var body: some View {
        lifecycle(chrome(layered))
    }

    /// The window's layers and the overlays that read preferences.
    private var layered: some View {
        ZStack(alignment: .bottom) {
            mainColumn
            sheetLayer
            // Peek sits above the conversation too (links in a reply open in it).
            peekAbove
            AgentDock(ws: ws)
                .padding(.bottom, 26)
        }
        .coordinateSpace(name: WSSpace.root)
        // No flight with Reduce Motion (no matched geometry at all).
        .environment(\.wsHero, reduce ? nil : hero)
        .onPreferenceChange(WSFrameKey.self) { f in frames.frames = f }
        .overlay { DownloadFlightLayer(frames: frames) }
        .overlayPreferenceValue(OmniAnchorKey.self) { anchor in omniLayer(anchor) }
        .overlayPreferenceValue(TabPreviewKey.self) { v in previewLayer(v) }
        .overlay(alignment: .top) { noticeLayer }
        .overlay { paletteLayer }
        .modifier(WSSwitcherHost(ws: ws))
        .modifier(WSWindowExtras(ws: ws, pendingLink: $pendingLink))
        // /10/11, screenshot card, notes, site style, diagnostics.
        .modifier(WSExtrasHost(ws: ws))
    }

    private var peekAbove: some View {
        peekLayer
            .padding(.top, AppConfig.barHeight + 2)
            .animation(WSMotion.navigation(reduce), value: ws.peek)
    }

    /// Animations, grounds, the modals, the tour and the welcome.
    private func chrome<V: View>(_ v: V) -> some View {
        v
        // A spring, so the figure's flight from the dock to the header reads; a fade with Reduce Motion.
        .animation(reduce ? WSMotion.micro : .spring(response: 0.42, dampingFraction: 0.84), value: ws.sheet)
        .animation(WSMotion.navigation(reduce), value: ws.toast)
        .animation(WSMotion.micro, value: ws.metaNeedsReconnect)
        .animation(WSMotion.micro, value: net.online)
        .animation(WSMotion.micro, value: ws.palette != nil)
        // The window's ground is the toolbar's reflected colour continued around the card (no line or step).
        .background(WindowTintBackground())
        .background(ToolbarTintDriver(ws: ws))
        .background(WindowChrome())
        .ignoresSafeArea(.container, edges: .top)
        // No forced light; the window follows the app's theme (WS tokens are light/dark).
        .modifier(WSWindowModals(ws: ws))
        // The one-time About you step (how they heard, what describes them), once the workspace is quiet.
        .modifier(AboutYouHost(ws: ws))
        // The morning tour's spotlight, under the welcome (it shows itself only while ws.touring).
        .overlay { TourOverlay(ws: ws) }
        // An agent's applied changes, walked through over the person's Ads Manager tab (shows itself only while one runs).
        .overlay { ChangeTourOverlay(ws: ws) }
        // The welcome under the modals: Settings ("Connect Meta") and \u{2318}/ open over it, not hidden behind it.
        .overlay { onboardingLayer }
        .animation(WSMotion.micro, value: ws.onboarding)
        .overlay { LiaModalHost() }
    }

    /// Links from other apps, boot, and the reactions to the model.
    private func lifecycle<V: View>(_ v: V) -> some View {
        v
        // Links from other apps open in the window in front; liaison://settings/<tab>
        // Opens Settings there. One window takes every link (no new window per link). a web link opens in
        // Peek over the page (Little Arc), not as a tab: "Open as Tab" or "Open in \u{25BE}" keeps it.
        .onOpenURL { url in
            if ["liaison", "liaison-dev"].contains(url.scheme?.lowercased() ?? "") {
                // Add Account's Google / Apple answer from the person's browser (Settings' sheet sees no links)
                if BrowserSignIn.deliver(url) { return }
                // Settings > Google > Connect's answer (intent=link), while that round is open
                if GoogleConnect.shared.deliver(url, auth: app.auth) { return }
                if GitHubFinish.isLink(url) {   // GitHub's answer from a browser other than our window
                    Task { await GitHubLink.shared.finishLink(url, auth: app.auth) }
                } else if url.host == "settings" {
                    let tab = url.pathComponents.filter { $0 != "/" }.joined(separator: "/")
                    app.openSettings(tab.isEmpty ? "general" : tab)
                } else if url.host == "agents", let id = url.pathComponents.dropFirst().first {
                    ws.openAgent(id)
                } else if url.host == "perf" {
                    WSExtras.shared.perfOpen = true
                }
                return
            }
            if ["http", "https"].contains(url.scheme?.lowercased() ?? "") { openExternal(url) }
            // An .html file from Finder or another app opens in a new tab (not Peek), like Chrome.
            if url.isFileURL, LocalFileOpen.opens(url) { openExternal(url) }
        }
        .handlesExternalEvents(preferring: ["*"], allowing: ["*"])
        .task {
            await app.boot()
            await ws.boot()
        }
        .onChange(of: ws.profileId) { _, _ in omni.end() }
        // The address field's key monitor would take the palette's arrows, Return and Esc.
        .onChange(of: ws.palette != nil) { _, open in
            guard open else { return }
            omni.end()
            PaletteTip().invalidate(reason: .actionPerformed)
        }
        .environment(\.openURL, OpenURLAction { url in
            // A link in an agent's answer opens in the person's browser, in a new tab of this profile.
            guard ["http", "https"].contains(url.scheme?.lowercased() ?? ""), let b = ws.currentBrowser else { return .systemAction }
            b.open(url)
            return .handled
        })
    }

    private var mainColumn: some View {
        VStack(spacing: 0) {
            // The bar, or in compact mode a hover strip (the bar then comes over the page).
            WSTopBarSlot(ws: ws, omni: omni, lights: win.lights)
            if !net.online {
                WSOfflineBanner()
                    .padding(.horizontal, 10)
                    .padding(.bottom, 8)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
            if ws.metaNeedsReconnect {
                MetaReconnectBanner(onReconnect: { app.openSettings("meta") }, onClose: { ws.metaNeedsReconnect = false })
                    .padding(.horizontal, 10)
                    .padding(.bottom, 8)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
            // Vertical tabs | the page | web panel
            HStack(spacing: 10) {
                VerticalTabsSlot(ws: ws)
                stageCard
                WebPanelSlot(ws: ws)
            }
            .padding(.horizontal, 10)
            .padding(.bottom, 10)
            // Under an open conversation the page takes no clicks (a web view would swallow them).
            .allowsHitTesting(ws.sheet == nil)
        }
        .overlay(alignment: .top) { WSCompactBarOverlay(ws: ws, omni: omni, lights: win.lights) }
    }

    private var stageCard: some View {
        // Another workspace slides in from its side (a cross-fade with Reduce Motion).
        ZStack {
            stage
                .id(ws.profileId)
                .transition(reduce ? AnyTransition.opacity : AnyTransition.push(from: ws.switchForward ? .trailing : .leading))
        }
        .animation(WSMotion.navigation(reduce), value: ws.profileId)
        .modifier(WSStageExtras(ws: ws))
        .wsReportFrame("stage")
    }

    @ViewBuilder private var sheetLayer: some View {
        if ws.sheet != nil {
            // A click anywhere outside the conversation closes it. Below the top bar only: over the bar the dim ate
            // the first click on Notes, the pills or Downloads (it only closed the sheet; a second click was needed).
            VStack(spacing: 0) {
                Color.clear.frame(height: AppConfig.barHeight).allowsHitTesting(false)
                Color.black.opacity(0.10)
                    .background(TipOccluder(layer: 10))   // tooltips of what is under the dim stay quiet
                    .contentShape(Rectangle())
                    .onTapGesture { ws.sheet = nil }
            }
            .transition(.opacity)
            // Esc closes a sheet whose thread is not loaded yet. A shown ConversationSheet owns Esc itself (its
            // close button, or Stop while a run is going); a second .cancelAction here would race with it.
            if ws.sheet.flatMap({ ws.chat(for: $0) }) == nil {
                Button("") { ws.sheet = nil }
                    .keyboardShortcut(.cancelAction)
                    .buttonStyle(.liaPlain)
                    .opacity(0)
                    .frame(width: 0, height: 0)
                    .accessibilityHidden(true)
            }
        }
        if let id = ws.sheet, let c = ws.chat(for: id) {
            ConversationSheet(ws: ws, chat: c)
                .liaTipCover()
                .onExitCommand { ws.sheet = nil }
                // Opening Lia's (team) dialogue moved the messenger right - a dialogue with no browser
                // pane beside it made the card narrower and it re-centred. Pinned to the leading edge, the thread
                // keeps its place whichever dialogue is open.
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 56)
                .padding(.top, 84)
                .padding(.bottom, 112)
                .transition(reduce ? AnyTransition.opacity : AnyTransition.move(edge: .bottom).combined(with: .opacity))
                // no .id(t.id): switching agents keeps the sheet and only the thread crossfades
        }
    }

    /// The suggestions under the address field, above everything (never clipped by the tab row).
    private func omniLayer(_ anchor: Anchor<CGRect>?) -> some View {
        GeometryReader { g in
            if let a = anchor, omni.editingTab != nil, !omni.rows.isEmpty {
                let r = g[a]
                OmniDropdown(omni: omni)
                    .frame(width: max(r.width, 460))
                    .offset(x: r.minX, y: r.maxY + 6)
                    .transition(.opacity)
            }
        }
    }

    /// The hovered tab's card, under it, kept inside the window.
    private func previewLayer(_ v: TabPreviewKey.Item?) -> some View {
        GeometryReader { g in
            if let v, omni.editingTab == nil, ws.palette == nil {
                let r = g[v.anchor]
                TabPreviewCard(item: v)
                    .id(v.key)
                    .offset(x: max(8, min(r.minX, g.size.width - 284)), y: r.maxY + 8)
                    .transition(.opacity)
            }
        }
        .allowsHitTesting(false)
        .animation(WSMotion.micro, value: v?.key)
    }

    private var noticeLayer: some View {
        VStack(spacing: 8) {
            UpdateBanner()   // An update that waits for a restart says so here, in the inbox and on Home
            if let t = ws.toast {
                WSToastView(toast: t) { ws.toast = nil }
                    .transition(reduce ? AnyTransition.opacity : AnyTransition.move(edge: .top).combined(with: .opacity))
            }
            // Profile / conversation errors (nothing else shows WorkspaceModel.errorText). A click hides it.
            if let e = ws.errorText {
                Text(e).font(LiaFont.ui(13)).foregroundStyle(WS.bad)
                    .padding(.horizontal, 14).frame(height: 34)
                    .background(WS.surface, in: Capsule())
                    .overlay(Capsule().stroke(WS.line2, lineWidth: 1))
                    .onTapGesture { ws.errorText = nil }
            }
        }
        .padding(.top, AppConfig.barHeight + 14)
    }

    /// A link in Peek over the page; a click on the dimmed page closes it.
    @ViewBuilder private var peekLayer: some View {
        if let u = ws.peek {
            // PeekPanel draws its own dimmed backdrop (a click closes) and its own scale-in.
            PeekPanel(ws: ws, url: u)
                .clipShape(RoundedRectangle(cornerRadius: WS.radius, style: .continuous))
                .transition(.opacity)
        }
    }

    /// The command palette over a dimmed window; a click outside closes it.
    @ViewBuilder private var paletteLayer: some View {
        if ws.palette != nil {
            ZStack(alignment: .top) {
                Color.black.opacity(0.16)
                    .contentShape(Rectangle())
                    .onTapGesture { ws.palette = nil }
                    .accessibilityLabel(Text("Close command palette"))
                    .accessibilityAddTraits(.isButton)
                CommandPalette(ws: ws)
                    .padding(.top, 110)
                    .padding(.horizontal, 24)
                    .transition(reduce ? AnyTransition.opacity : AnyTransition.scale(scale: 0.97, anchor: .top).combined(with: .opacity))
            }
            .transition(.opacity)
        }
    }

    /// The first-launch welcome, above everything.
    @ViewBuilder private var onboardingLayer: some View {
        if ws.onboarding {
            OnboardingView(ws: ws)
                .transition(.opacity)
        }
    }

    private var lead: AgentInfo? { ws.roster.first(where: { $0.lead }) ?? ws.roster.first }

    /// A web link from another app: in Peek over the page, once the workspace is up and the welcome is done.
    private func openExternal(_ url: URL) {
        guard ws.booted, !ws.onboarding, ws.currentBrowser != nil else { pendingLink = url; return }
        ws.palette = nil
        ws.sheet = nil
        if url.isFileURL { ws.currentBrowser?.newTab(url: url); return }
        ws.peek = url
    }

    @ViewBuilder private var stage: some View {
        if let b = ws.currentBrowser {
            BrowserStage(browser: b, ws: ws)
        } else {
            VStack(spacing: 16) {
                if ws.booted {
                    // Lia asks for the one thing that makes everything else work.
                    if let a = lead { AgentAvatar(agent: a, size: 96) }
                    Text("Connect Meta and I'll make a workspace for every client.")
                        .font(LiaFont.ui(22, .semibold)).foregroundStyle(WS.ink)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 460)
                        .fixedSize(horizontal: false, vertical: true)
                    Text("Each workspace gets its own browser, sign-ins and agents.")
                        .font(LiaFont.ui(14)).foregroundStyle(WS.text2)
                        .multilineTextAlignment(.center)
                    Button("Connect Meta") { app.openSettings("meta") }
                        .buttonStyle(WSButtonStyle(primary: true))
                        .liaPointer()
                        .accessibilityHint(Text("Opens Settings at the Meta connection"))
                } else {
                    // 0.2.10: the sign-in's orbit, small, while the workspace boots (after 300 ms, so a quick boot never shows it)
                    LiaLoadingOrbit(size: 120, label: "Loading your workspace")
                }
            }
            .padding(32)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(WS.surface, in: RoundedRectangle(cornerRadius: WS.radius, style: .continuous))
        }
    }
}

/// The window's sheets (kept out of the body so the type checker stays quick).
private struct WSWindowModals: ViewModifier {
    @EnvironmentObject private var app: AppModel
    @ObservedObject var ws: WorkspaceModel

    func body(content: Content) -> some View {
        content
            .liaModal(isPresented: $ws.showJournal) { JournalSheet(ws: ws) }
            .liaModal(isPresented: $ws.showShortcuts) { ShortcutsSheet(ws: ws) }
            .liaModal(isPresented: $ws.showImport) { ImportBrowsersSheet(ws: ws) }
            // /04: \u{2318}Y
            .liaModal(isPresented: $ws.showHistory) { HistoryWindow(ws: ws, openSettings: { app.openSettings($0) }) }
            .liaModal(item: $ws.editingProfile) { p in NewProfileSheet(ws: ws, editing: p) }
            .liaModal(item: $ws.confirmDelete, style: .bare) { p in
                LiaConfirm(title: "Delete \(p.name)?", sub: "Its conversations and browser go. The ad account itself is not touched.", yes: "Delete", danger: true,
                           onYes: { ws.confirmDelete = nil; Task { await ws.deleteProfile(p) } }, onNo: { ws.confirmDelete = nil })
            }
            // Settings is its own window now (AppModel.showSettings opens SettingsWindow).
    }
}

// MARK: - tab overview, external links, tips

/// The tab overview over the window (\u{2318}\u{21E7}\\ or `.wsTabOverview` from the menu; the pinch was removed), the link
/// from another app that waited for the workspace, and the Peek tip's end.
private struct WSWindowExtras: ViewModifier {
    @ObservedObject var ws: WorkspaceModel
    @Binding var pendingLink: URL?
    @Environment(\.accessibilityReduceMotion) private var reduce
    @State private var overview = false

    private var ready: Bool { ws.booted && !ws.onboarding && ws.currentBrowser != nil }

    func body(content: Content) -> some View {
        content
            .overlay { overviewLayer }
            .background { shortcut }
            .animation(WSMotion.navigation(reduce), value: overview)
            .onReceive(NotificationCenter.default.publisher(for: .wsTabOverview)) { _ in toggleOverview() }
            .onChange(of: ws.profileId) { _, _ in overview = false }
            .onChange(of: ws.peek) { _, u in if u != nil { PeekTip().invalidate(reason: .actionPerformed) } }
            .onChange(of: ready) { _, r in if r { releaseLink() } }
            .onChange(of: pendingLink) { _, _ in if ready { releaseLink() } }
    }

    @ViewBuilder private var overviewLayer: some View {
        if overview, let b = ws.currentBrowser {
            TabOverview(browser: b, accent: Color(hex: ws.profile?.colorHex ?? 0x3B5BFD)) { overview = false }
                .transition(.opacity)
        }
    }

    /// \u{2318}\u{21E7}\\ until the menu has its own item (it would post `.wsTabOverview`).
    private var shortcut: some View {
        Button("") { toggleOverview() }
            .keyboardShortcut("\\", modifiers: [.command, .shift])
            .buttonStyle(.liaPlain)
            .opacity(0)
            .frame(width: 0, height: 0)
            .accessibilityHidden(true)
    }

    private func toggleOverview() {
        if overview { overview = false; return }
        guard ws.currentBrowser != nil, ws.sheet == nil, ws.palette == nil, !ws.onboarding else { return }
        ws.peek = nil
        overview = true
    }

    private func releaseLink() {
        guard let u = pendingLink else { return }
        pendingLink = nil
        ws.palette = nil
        ws.sheet = nil
        if u.isFileURL { ws.currentBrowser?.newTab(url: u); return }
        ws.peek = u
    }
}

/// The page card's own extras: the Peek tip. The pinch-in for the tab overview is gone (
/// "very inconvenient"); every pinch is the page's own zoom.
private struct WSStageExtras: ViewModifier {
    @ObservedObject var ws: WorkspaceModel

    func body(content: Content) -> some View {
        content
            .popoverTip(PeekTip(), arrowEdge: .top)
    }
}

// MARK: - \u{2303}Tab recent tabs switcher

/// The switcher over the window while `ws.switcher` is set: releasing \u{2303} picks, Esc closes, leaving the app closes.
private struct WSSwitcherHost: ViewModifier {
    @ObservedObject var ws: WorkspaceModel
    @Environment(\.accessibilityReduceMotion) private var reduce
    @State private var keys = WSSwitcherMonitor()

    func body(content: Content) -> some View {
        content
            .overlay { layer }
            .animation(WSMotion.micro, value: ws.switcher != nil)
            .onChange(of: ws.switcher != nil) { _, open in if open { start() } else { keys.stop() } }
            .onChange(of: ws.switcher) { _, i in announce(i) }
            .onReceive(NotificationCenter.default.publisher(for: NSApplication.didResignActiveNotification)) { _ in
                if ws.switcher != nil { ws.switcher = nil }
            }
            .onDisappear { keys.stop() }
    }

    @ViewBuilder private var layer: some View {
        if let i = ws.switcher, let b = ws.currentBrowser {
            MRUSwitcher(ws: ws, browser: b, index: i)
                .transition(reduce ? AnyTransition.opacity : AnyTransition.scale(scale: 0.96).combined(with: .opacity))
        }
    }

    private func start() {
        let ws = self.ws
        keys.start(onRelease: {
            MainActor.assumeIsolated { () -> Void in if ws.switcher != nil { ws.mruCommit() } }
        }, onCancel: {
            MainActor.assumeIsolated { () -> Bool in
                guard ws.switcher != nil else { return false }
                ws.switcher = nil
                return true
            }
        })
        // Opened from the menu with the mouse (no \u{2303} held): nothing will be released, so pick at once.
        DispatchQueue.main.async {
            if ws.switcher != nil, !NSEvent.modifierFlags.contains(.control) { ws.mruCommit() }
        }
    }

    /// VoiceOver hears the tab the switcher is on.
    private func announce(_ i: Int?) {
        guard let i, let tabs = ws.currentBrowser?.recentTabs, tabs.indices.contains(i) else { return }
        AccessibilityNotification.Announcement(tabs[i].displayTitle).post()
    }
}

/// \u{2303} released (flagsChanged) and Esc (keyDown) while the switcher is open.
final class WSSwitcherMonitor {
    private var tokens: [Any] = []

    func start(onRelease: @escaping () -> Void, onCancel: @escaping () -> Bool) {
        stop()
        if let t = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged, handler: { e in
            if !e.modifierFlags.contains(.control) { onRelease() }
            return e
        }) { tokens.append(t) }
        if let t = NSEvent.addLocalMonitorForEvents(matching: .keyDown, handler: { e in
            if e.keyCode == 53, onCancel() { return nil }
            return e
        }) { tokens.append(t) }
    }

    func stop() {
        for t in tokens { NSEvent.removeMonitor(t) }
        tokens = []
    }
}

// MARK: - top bar: the workspace's tab group

struct WSTopBar: View {
    @ObservedObject var ws: WorkspaceModel
    let omni: OmniboxModel
    let lights: CGFloat

    var body: some View {
        // One glass container for the bar, so neighbouring glass pieces merge on macOS 26.
        // The bar's text and glyphs turn light over a dark reflected colour.
        BarInkScope { WSGlassGroup(spacing: 8) { row } }
            .padding(.trailing, 14)
            // The row is centred on the lights' line (WindowChrome centres them on barHeight / 2).
            .frame(height: AppConfig.barHeight)
            // the page card a third closer to the tabs (was 6).
            .padding(.bottom, 2)
            // The bar reflects Home's sky top or the colour at the top of the page (ToolbarGlass.swift);
            // the window's ground continues it around the card.
            .background { ToolbarGlassBackground().ignoresSafeArea() }
        // Two fingers sideways on the bar switch workspace.
        .background(WSSwipeCatcher { forward in swiped(forward) })
    }

    /// A level change under the fingers when another workspace comes in.
    private func swiped(_ forward: Bool) {
        let before = ws.profileId
        ws.selectNextProfile(forward)
        if ws.profileId != before { WSHaptics.level() }
    }

    private var row: some View {
        HStack(spacing: 8) {
            // The traffic lights' place, left of the workspace chip; it keeps them shown (never faded out).
            WSLightsKeeper().frame(width: max(lights - 10, 12), height: 1)
            // In full screen macOS hides its lights with the title bar; ours stand in their place.
            WSFullScreenLights()
            if let p = ws.profile { group(p).tourAnchor("workspaces") }
            // Workspaces live only on the left (the switcher chip in the tab group); the free room drags the window.
            WindowDragArea().frame(maxWidth: .infinity, maxHeight: 34)
                // 0.2.11: a right-click here (the room between + and Share, the row's gaps
                // included) opens the tab bar's menu, as the strip's own empty room does. Left clicks still drag.
                .overlay(RightClickTarget { _, window in TabBarMenu.requestBar(in: window) })
                .padding(.horizontal, -8)
            // The right items never give way to the tabs.
            Group {
                ApprovalsButton(ws: ws).barInkRegion()
                if let b = ws.currentBrowser { WSShareButton(browser: b).barInkRegion() }
                // Notes, web panel
                WSBarExtras(ws: ws).barInkRegion()
                DownloadsButton(ws: ws).barInkRegion()
                WSAccountButton(ws: ws).barInkRegion()
            }
            .fixedSize()
            .layoutPriority(2)
        }
    }

    /// The tab group takes the room it needs first; its tabs shrink, then scroll, inside it.
    private func group(_ p: CompanyProfile) -> some View {
        TabGroup(ws: ws, profile: p, browser: ws.browser(for: p), omni: omni)
            // The tab row keeps its own horizontal scrolling.
            .background(WSNoSwipeZone())
            .tourAnchor("tabs")
            // \u{2318}K, told where the tabs are.
            .popoverTip(PaletteTip())
            .layoutPriority(1)
    }
}

/// The window's close / minimise / zoom stay visible in the top bar. A hidden-title-bar
/// window may hide or fade its standard buttons; this puts them back each time the bar lays out or the window
/// changes key state. Position stays WindowChrome's (one writer).
struct WSLightsKeeper: NSViewRepresentable {
    func makeNSView(context: Context) -> KeeperView { KeeperView() }
    func updateNSView(_ v: KeeperView, context: Context) { v.show() }

    final class KeeperView: NSView {
        private var tokens: [NSObjectProtocol] = []

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            tokens.forEach { NotificationCenter.default.removeObserver($0) }
            tokens = []
            guard let w = window else { return }
            for n in [NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification, NSWindow.didExitFullScreenNotification,
                      NSWindow.didEndLiveResizeNotification] {
                tokens.append(NotificationCenter.default.addObserver(forName: n, object: w, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.show() }
                })
            }
            DispatchQueue.main.async { [weak self] in self?.show() }
        }

        deinit { tokens.forEach { NotificationCenter.default.removeObserver($0) } }

        override func layout() { super.layout(); show() }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        func show() {
            // Compact mode's bar on its way out, the lights fading with it (WSLightsCorner) - do not bring them back.
            guard !WSLightsCorner.suppressed else { return }
            guard let w = window, !w.styleMask.contains(.fullScreen) else { return }
            for k in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
                guard let b = w.standardWindowButton(k) else { continue }
                if b.isHidden { b.isHidden = false }
                if b.alphaValue < 1 { b.alphaValue = 1 }
                // The titlebar views above the buttons (SwiftUI's hidden title bar can fade them).
                var v = b.superview
                for _ in 0..<2 {
                    guard let s = v else { break }
                    if s.isHidden { s.isHidden = false }
                    if s.alphaValue < 1 { s.alphaValue = 1 }
                    v = s.superview
                }
            }
        }
    }
}

// MARK: - swipe between workspaces

/// Catches two-finger horizontal swipes over the top bar: one workspace per gesture, past ~60 pt. Pills are SwiftUI
/// buttons that never get scroll events to this view, so a local monitor routes the bar's scrolls here too; places
/// marked with WSNoSwipeZone (the tab row, which scrolls itself) are left alone.
struct WSSwipeCatcher: NSViewRepresentable {
    let onSwipe: (Bool) -> Void

    func makeNSView(context: Context) -> CatcherView {
        let v = CatcherView()
        v.onSwipe = onSwipe
        return v
    }

    func updateNSView(_ v: CatcherView, context: Context) { v.onSwipe = onSwipe }

    static func dismantleNSView(_ v: CatcherView, coordinator: ()) { v.stopMonitor() }

    final class CatcherView: NSView {
        var onSwipe: ((Bool) -> Void)?
        private var accX: CGFloat = 0
        private var accY: CGFloat = 0
        private var fired = false
        private var monitor: Any?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            stopMonitor()
            guard window != nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] e in
                guard let self, self.covers(e) else { return e }
                return self.handle(e) ? nil : e
            }
        }

        func stopMonitor() {
            if let m = monitor { NSEvent.removeMonitor(m) }
            monitor = nil
        }

        override func scrollWheel(with e: NSEvent) {
            if !handle(e) { super.scrollWheel(with: e) }
        }

        private func covers(_ e: NSEvent) -> Bool {
            guard let w = window, e.window === w, !isHiddenOrHasHiddenAncestor else { return false }
            guard bounds.contains(convert(e.locationInWindow, from: nil)) else { return false }
            return !WSNoSwipeZone.contains(e.locationInWindow, in: w)
        }

        /// True when the event belongs to a sideways swipe (it is then used up here).
        private func handle(_ e: NSEvent) -> Bool {
            if e.phase.contains(.began) || e.phase.contains(.mayBegin) { accX = 0; accY = 0; fired = false }
            // A mouse wheel and the momentum after a swipe have no phase: not a swipe.
            guard !e.phase.isEmpty else { return false }
            // Finger direction, whatever the natural-scrolling setting.
            let dx = e.isDirectionInvertedFromDevice ? e.scrollingDeltaX : -e.scrollingDeltaX
            accX += dx
            accY += e.scrollingDeltaY
            let ended = e.phase.contains(.ended) || e.phase.contains(.cancelled)
            defer { if ended { accX = 0; accY = 0; fired = false } }
            guard abs(accX) > abs(accY) * 1.2 else { return false }
            if !fired, abs(accX) >= 60 {
                fired = true
                // Fingers to the left bring the next workspace in from the right.
                onSwipe?(accX < 0)
            }
            return true
        }
    }
}

/// A place inside the top bar where horizontal scrolling is not a workspace swipe (the tab row).
struct WSNoSwipeZone: NSViewRepresentable {
    func makeNSView(context: Context) -> ZoneView { ZoneView() }
    func updateNSView(_ v: ZoneView, context: Context) {}

    static func contains(_ p: NSPoint, in w: NSWindow) -> Bool {
        ZoneView.all.allObjects.contains { z in
            z.window === w && !z.isHiddenOrHasHiddenAncestor && z.bounds.contains(z.convert(p, from: nil))
        }
    }

    final class ZoneView: NSView {
        static let all = NSHashTable<ZoneView>.weakObjects()
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if window != nil { Self.all.add(self) } else { Self.all.remove(self) }
        }
        /// Only a marker: never takes a click.
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }
}

// MARK: - the network

/// Whether the Mac is online (Network framework), for the banner under the top bar.
@MainActor
final class WSNetworkMonitor: ObservableObject {
    @Published private(set) var online = true
    private let monitor = NWPathMonitor()

    init() {
        monitor.pathUpdateHandler = { [weak self] path in
            let ok = path.status == .satisfied
            Task { @MainActor in
                if let self, self.online != ok { self.online = ok }
            }
        }
        monitor.start(queue: DispatchQueue(label: "com.liaisone.mac.network"))
    }

    deinit { monitor.cancel() }
}

/// Said plainly while the network is gone.
private struct WSOfflineBanner: View {
    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "wifi.slash").font(.system(size: 12, weight: .semibold)).foregroundStyle(WS.text2)
            Text("No connection \u{00B7} agents paused until you're back online")
                .font(LiaFont.ui(13)).foregroundStyle(WS.ink)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .frame(height: 34)
        .wsGlass(14)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isStaticText)
        .accessibilityLabel(Text("No connection. Agents are paused until you're back online."))
    }
}

// MARK: - share

/// The selected tab's address in the macOS share menu (AirDrop, Messages, Mail, Copy Link...).
private struct WSShareButton: View {
    @ObservedObject var browser: BrowserModel

    var body: some View {
        if let t = browser.selected { WSShareFace(tab: t) }
    }
}

private struct WSShareFace: View {
    @ObservedObject var tab: BrowserTab
    @State private var anchor = WSViewAnchor.Box()
    @Environment(\.wsBarOnDark) private var onDark

    var body: some View {
        if let u = tab.savedURL, ["http", "https"].contains(u.scheme?.lowercased() ?? "") {
            Button { anchor.share(u, title: tab.displayTitle, icon: tab.favicon) } label: {
                Image(systemName: "square.and.arrow.up")
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(BarInk.text2(onDark))
                    .frame(width: 30, height: 30)
                    .offset(y: -1)
            }
            .buttonStyle(.liaPlain)
            .background(WSViewAnchor(box: anchor))
            // 0.2.11: the picker is ready before the click (WSViewAnchor.Box.prepare).
            .task(id: u.absoluteString + "|" + tab.displayTitle + (tab.favicon == nil ? "" : "|i")) {
                anchor.prepare(u, title: tab.displayTitle, icon: tab.favicon)
            }
            .liaHover(.icon, radius: 10)
            .accessibilityLabel(Text("Share this page"))
        }
    }
}

/// An empty NSView behind a SwiftUI control, so an AppKit picker can show relative to it.
struct WSViewAnchor: NSViewRepresentable {
    final class Box {
        weak var view: NSView?
        /// 0.2.11 ("Share is slow on every click"): the slow part was the share item's header
        /// (see `share`), so the item is built once per page, ahead of the click (`prepare`, when the button shows
        /// or the page changes). The NSSharingServicePicker itself is new on every click: reusing one across
        /// shows is undocumented.
        private var item: NSPreviewRepresentingActivityItem?
        private var itemKey: String?
        private var picker: NSSharingServicePicker?

        @MainActor func prepare(_ url: URL, title: String? = nil, icon: NSImage? = nil) {
            let name = (title ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let key = url.absoluteString + "\u{1F}" + name + (icon == nil ? "" : "\u{1F}i")
            guard key != itemKey || item == nil else { return }
            let glyph = icon ?? NSImage(systemSymbolName: "globe", accessibilityDescription: nil)
            item = NSPreviewRepresentingActivityItem(item: url, title: name.isEmpty ? (url.host ?? url.absoluteString) : name,
                                                     image: glyph, icon: glyph)
            itemKey = key
        }

        /// A bare URL made the share popover fetch the page itself (LinkPresentation loads the
        /// whole site for its header: title, icon) before it appeared, seconds on a heavy page. The header now
        /// comes from what the tab already has, so the popover opens at once and nothing is downloaded; the
        /// shared item is still the plain URL.
        @MainActor func share(_ url: URL, title: String? = nil, icon: NSImage? = nil) {
            guard let v = view else { return }
            prepare(url, title: title, icon: icon)
            guard let item else { return }
            let p = NSSharingServicePicker(items: [item])
            picker = p   // held while it shows
            p.show(relativeTo: v.bounds, of: v, preferredEdge: .minY)
        }
    }

    let box: Box

    func makeNSView(context: Context) -> NSView {
        let v = NSView()
        box.view = v
        return v
    }

    func updateNSView(_ v: NSView, context: Context) { box.view = v }
}

// MARK: - account (/02)

/// The person at the right of the top bar: their initials; a click opens the account card.
private struct WSAccountButton: View {
    @EnvironmentObject private var app: AppModel
    @ObservedObject var ws: WorkspaceModel

    var body: some View {
        WSAccountFace(app: app, library: app.library, ws: ws)
    }
}

private struct WSAccountFace: View {
    let app: AppModel
    @ObservedObject var library: LibraryStore
    @ObservedObject var ws: WorkspaceModel
    @State private var open = false

    private var name: String {
        let p = library.profile
        let full = (p?.fullName ?? "").trimmingCharacters(in: .whitespaces)
        if !full.isEmpty { return full }
        return (p?.firstName ?? "").trimmingCharacters(in: .whitespaces)
    }

    private var email: String {
        if let e = library.profile?.email, !e.isEmpty { return e }
        return app.auth.activeEmail ?? ""
    }

    private var initials: String {
        let words = name.split(separator: " ").filter { $0.first?.isLetter ?? false }
        let s = words.prefix(2).compactMap { $0.first }.map { String($0) }.joined().uppercased()
        if !s.isEmpty { return s }
        if !library.avatarLetter.isEmpty { return library.avatarLetter }
        return email.first.map { String($0).uppercased() } ?? "A"
    }

    var body: some View {
        Button { open.toggle() } label: {
            WSInitials(text: initials, size: 26)
                .frame(width: 30, height: 30)
        }
        .buttonStyle(.liaPlain)
        .liaHover(.icon, radius: 15)
        .accessibilityLabel(Text("Account"))
        .accessibilityValue(Text([name, email].filter { !$0.isEmpty }.joined(separator: ", ")))
        .popover(isPresented: $open, arrowEdge: .bottom) {
            WSAccountCard(app: app, ws: ws, name: name, email: email, initials: initials,
                          plan: library.profile?.planName ?? "") { open = false }
        }
    }
}

/// The person's face (their photo, else their initials on their own palette colour; App/Settings/AvatarViews.swift).
private struct WSInitials: View {
    let text: String
    let size: CGFloat

    var body: some View { PersonFace(initials: text, size: size) }
}

/// /02: who is signed in, the plan, what the agents are connected to, and the account's actions.
private struct WSAccountCard: View {
    let app: AppModel
    @ObservedObject private var github = GitHubLink.shared
    @ObservedObject var ws: WorkspaceModel
    let name: String
    let email: String
    let initials: String
    let plan: String
    let close: () -> Void

    @ObservedObject private var avatars = AvatarStore.shared
    @State private var avatarError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider().padding(.vertical, 8)
            AccountUsageBar(app: app, close: close)
            Divider().padding(.vertical, 8)
            connections
            Divider().padding(.vertical, 8)
            row("gearshape", "Settings\u{2026}", kbd: "\u{2318},") { app.openSettings() }
            // Customise left Home for this menu, right under Settings; Keyboard Shortcuts is in
            // Settings only; Report a Problem is our own form (ReportProblem.swift), not Mail.
            row("slider.horizontal.3", "Customize Home\u{2026}") { HomeCustomise.open() }
            // The journal (Relay on the site) of this workspace, under Settings.
            row("clock.arrow.circlepath", "Journal") { ws.showJournal = true; Task { await ws.loadJournal() } }
                .disabled(ws.profile == nil)
            row("exclamationmark.bubble", "Report a Problem\u{2026}") { ReportProblem.open(ws: ws) }
            Divider().padding(.vertical, 8)
            row("rectangle.portrait.and.arrow.right", "Sign Out") { app.auth.signOut() }
        }
        .padding(12)
        .frame(width: 300)
        .task { await ws.refreshMeta() }
    }

    private var header: some View {
        HStack(spacing: 12) {
            // The profile's face changes the person's photo (hover: a camera; a click: the picker).
            AvatarEditButton(size: 42, busy: avatars.busy.contains(AvatarWho.me.id), hasPicture: avatars.me != nil,
                             label: "Change your picture", pick: {
                let a = app.auth
                Task { avatarError = await AvatarStore.shared.pickAndSet(.me, auth: a) }
            }, remove: {
                let a = app.auth
                Task { avatarError = await AvatarStore.shared.remove(.me, auth: a) }
            }) { WSInitials(text: initials, size: 42) }
            VStack(alignment: .leading, spacing: 2) {
                Text(name.isEmpty ? "Your account" : name).font(LiaFont.ui(14, .semibold)).foregroundStyle(WS.ink).lineLimit(1)
                if !email.isEmpty {
                    Text(email).font(LiaFont.ui(12)).foregroundStyle(WS.text3).lineLimit(1).truncationMode(.middle)
                        .textSelection(.enabled)
                }
                if let avatarError {
                    Text(avatarError).font(LiaFont.ui(11.5)).foregroundStyle(WS.bad).lineLimit(2)
                }
            }
            Spacer(minLength: 4)
            if !plan.isEmpty {
                Text(plan).font(LiaFont.ui(11, .semibold)).foregroundStyle(WS.text2)
                    .padding(.horizontal, 8).frame(height: 20)
                    .background(WS.soft, in: Capsule())
                    .accessibilityLabel(Text("Plan \(plan)"))
            }
        }
        .padding(.horizontal, 4)
        .accessibilityElement(children: .contain)   // The picture button stays its own element
    }

    /// Meta as /meta/status says (read again each time the card opens); expired is not connected. Before
    /// the first read: what the workspace knows (the reconnect banner, workspaces on an ad account).
    private var metaState: (text: String, ok: Bool) {
        if let m = ws.meta {
            if m.expired { return ("Reconnect", false) }
            return m.connected ? ("Connected", true) : ("Connect", false)
        }
        if ws.metaNeedsReconnect { return ("Reconnect", false) }
        return ws.profiles.contains { $0.metaAccount != nil } ? ("Connected", true) : ("Connect", false)
    }

    private var connections: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Connections").font(LiaFont.ui(11, .semibold)).foregroundStyle(WS.text3).padding(.horizontal, 4)
            HStack(spacing: 8) {
                Text("Meta").font(LiaFont.ui(13, .medium)).foregroundStyle(WS.ink)
                Spacer()
                if metaState.ok {
                    Label(metaState.text, systemImage: "checkmark.circle.fill")
                        .font(LiaFont.ui(12)).foregroundStyle(AppConfig.accent)
                } else {
                    Button(metaState.text) { close(); app.openSettings("meta") }
                        .buttonStyle(WSButtonStyle(small: true))
                        .liaPointer()
                }
            }
            .padding(.horizontal, 4)
            .accessibilityElement(children: .combine)
            .accessibilityLabel(Text("Meta, \(metaState.ok ? "connected" : "not connected")"))
            // GitHub in Google Ads' place (Giggs is retired; Dev works with GitHub)
            HStack(spacing: 8) {
                Text("GitHub").font(LiaFont.ui(13, .medium)).foregroundStyle(WS.ink)
                Spacer()
                if github.status?.connected == true {
                    Label(github.status?.login ?? "Connected", systemImage: "checkmark.circle.fill")
                        .font(LiaFont.ui(12)).foregroundStyle(AppConfig.accent)
                } else {
                    Button("Connect") { close(); app.openSettings("integrations") }
                        .buttonStyle(WSButtonStyle(small: true))
                        .liaPointer()
                }
            }
            .padding(.horizontal, 4)
            .accessibilityElement(children: .combine)
            .accessibilityLabel(Text("GitHub, \(github.status?.connected == true ? "connected" : "not connected")"))
            .task { await github.refresh(app.auth) }
        }
    }

    private func row(_ symbol: String, _ title: String, kbd: String? = nil, _ action: @escaping () -> Void) -> some View {
        Button {
            close()
            action()
        } label: {
            HStack(spacing: 10) {
                Image(systemName: symbol).font(.system(size: 12, weight: .medium)).foregroundStyle(WS.text2).frame(width: 18)
                Text(title).font(LiaFont.ui(13)).foregroundStyle(WS.ink)
                Spacer()
                if let kbd { Text(kbd).font(LiaFont.ui(12)).foregroundStyle(WS.text3) }
            }
            .padding(.horizontal, 6)
            .frame(height: 30)
            .contentShape(Rectangle())
        }
        .buttonStyle(.liaPlain)
        .liaHover(.fill, radius: 8)
        .accessibilityLabel(Text(title))
    }
}

// MARK: - the page

/// The profile's browser: the selected tab's page on a rounded white card (or two pages side by side, ),
/// the Ads Manager overlay over it.
struct BrowserStage: View {
    @ObservedObject var browser: BrowserModel
    @ObservedObject var ws: WorkspaceModel
    @ObservedObject private var extras = WSExtras.shared
    /// The third pane's tab (kept outside BrowserModel, which has one split tab).
    @ObservedObject private var third = WSThirdPane.shared
    @Environment(\.accessibilityReduceMotion) private var reduce

    var body: some View {
        HStack(spacing: 10) {
            card
            // An agent's own browser beside the page, read-only.
            if let a = extras.agentBeside, let p = ws.profile {
                AgentBesidePane(ws: ws, agentID: a, profile: p)
                    .frame(maxWidth: .infinity)
                    .transition(.move(edge: .trailing).combined(with: .opacity))
            }
        }
        .animation(WSMotion.navigation(reduce), value: extras.agentBeside)
        // The split ends (from anywhere): the third pane goes with it.
        .onChange(of: browser.splitID) { _, id in if id == nil { third.set(nil, of: browser) } }
    }

    private var card: some View {
        ZStack {
            // The page's own colour under it (white only on Home), so no white shows at the clipped corners.
            CardBase()
            if let t = browser.selected {
                if let s = browser.splitTab, let x = third.tab(of: browser) {
                    // Three panes; one view for any focus change among them (the panes keep their places).
                    ThreePaneStage(browser: browser, ws: ws, selected: t, other: s, extra: x)
                } else if let s = browser.splitTab {
                    // Same pair, same view: a focus change (the two tabs trade roles) keeps the panes in place.
                    SplitStage(browser: browser, ws: ws, selected: t, other: s)
                        .id(Set([t.id, s.id]))
                } else {
                    StageTab(tab: t, browser: browser, ws: ws).id(t.id)
                }
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: WS.radius, style: .continuous))
        // No shadow; the card sits in the window's continuous colour without a visible edge.
        // No rim either: the window's ground runs a few feathered points over the card's edge.
        .overlay { CardEdgeFeather() }
    }
}

/// /02/03: two tabs side by side. The panes keep their places; the one in front (the selected tab, which the
/// address field and the menus act on) has a thin border in the workspace colour; a click on the other brings it
/// in front. The divider drags (25...75 %), a double-click sets it back to the middle; each pane's x leaves it.
private struct SplitStage: View {
    @ObservedObject var browser: BrowserModel
    @ObservedObject var ws: WorkspaceModel
    let selected: BrowserTab
    let other: BrowserTab
    @Environment(\.accessibilityReduceMotion) private var reduce
    /// The tab on the left (set at the first focus change, so the panes never swap places).
    @State private var leftID: UUID?
    @State private var dragStart: CGFloat?
    @State private var clicks = WSPaneClickWatcher()

    private static let gap: CGFloat = 10

    private var accent: Color { Color(hex: ws.profile?.colorHex ?? 0x3B5BFD) }
    private var ratio: CGFloat { min(0.75, max(0.25, browser.splitRatio)) }

    var body: some View {
        let selectedLeft = leftID != other.id
        let left = selectedLeft ? selected : other
        let right = selectedLeft ? other : selected
        GeometryReader { g in
            let usable = max(1, g.size.width - Self.gap)
            HStack(spacing: 0) {
                pane(left).frame(width: usable * ratio)
                SplitDivider(ratio: ratio, usable: usable, start: $dragStart) { r in browser.splitRatio = r } reset: {
                    withAnimation(WSMotion.navigation(reduce)) { browser.splitRatio = 0.5 }
                    WSHaptics.alignment()
                }
                .frame(width: Self.gap)
                pane(right)
            }
        }
        .padding(4)
        .onAppear {
            if leftID == nil { leftID = selected.id }
            let pair = [selected, other]
            clicks.start { [weak b = browser] e in
                MainActor.assumeIsolated {
                    guard let b else { return }
                    for t in pair where t.id != b.selectedID && WSPaneClickWatcher.hit(e, t.webView) { focus(t) }
                }
            }
        }
        .onDisappear { clicks.stop() }
    }

    private func pane(_ t: BrowserTab) -> some View {
        let front = t.id == browser.selectedID
        return StageTab(tab: t, browser: browser, ws: ws, active: front)
            .id(t.id)
            .clipShape(RoundedRectangle(cornerRadius: WS.radius - 4, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: WS.radius - 4, style: .continuous)
                    .stroke(front ? accent.opacity(0.85) : WS.line, lineWidth: front ? 1.5 : 1)
                    .allowsHitTesting(false)
            )
            .overlay(alignment: .topTrailing) { closeButton(t) }
            // A click on the start page (no web view to catch it) brings the pane in front too.
            .simultaneousGesture(TapGesture().onEnded { focus(t) })
            .accessibilityElement(children: .contain)
            .accessibilityLabel(Text(front ? "Split view, front pane: \(t.displayTitle)" : "Split view pane: \(t.displayTitle)"))
    }

    private func closeButton(_ t: BrowserTab) -> some View {
        Button { leave(t) } label: {
            Image(systemName: "xmark")
                .font(.system(size: 8.5, weight: .bold))
                .foregroundStyle(WS.text2)
                .frame(width: 18, height: 18)
                .background(.regularMaterial, in: Circle())
                .overlay(Circle().stroke(WS.line, lineWidth: 1))
        }
        .buttonStyle(.liaPlain)
        .liaPointer()
        .padding(7)
        .accessibilityLabel(Text("Close this pane of the split view"))
    }

    private func focus(_ t: BrowserTab) {
        guard t.id != browser.selectedID, let cur = browser.selectedID else { return }
        if leftID == nil { leftID = cur }
        browser.splitID = cur
        browser.selectedID = t.id
    }

    /// The pane's tab leaves the split; the other one stays in front.
    private func leave(_ t: BrowserTab) {
        let keep = t.id == selected.id ? other : selected
        browser.unsplit()
        browser.selectedID = keep.id
    }
}

/// Three tabs side by side (the selected one, the split one, the third from WSThirdPane). Each tab keeps
/// its place whichever is in front; two dividers drag (each pane at least 20 %), a double-click sets thirds.
private struct ThreePaneStage: View {
    @ObservedObject var browser: BrowserModel
    @ObservedObject var ws: WorkspaceModel
    let selected: BrowserTab
    let other: BrowserTab
    let extra: BrowserTab
    @Environment(\.accessibilityReduceMotion) private var reduce
    /// The tabs' places, left to right (kept while the same three tabs are on screen).
    @State private var slots: [UUID] = []
    /// The two dividers, as shares of the usable width.
    @State private var cutA: CGFloat = 1.0 / 3
    @State private var cutB: CGFloat = 2.0 / 3
    @State private var dragA: CGFloat?
    @State private var dragB: CGFloat?
    @State private var clicks = WSPaneClickWatcher()

    private static let gap: CGFloat = 10
    private static let minShare: CGFloat = 0.2

    private var members: [BrowserTab] { [selected, other, extra] }
    private var accent: Color { Color(hex: ws.profile?.colorHex ?? 0x3B5BFD) }

    /// The three tabs in their screen order.
    private var ordered: [BrowserTab] {
        let m = members
        guard Set(slots) == Set(m.map(\.id)) else { return m }
        return slots.compactMap { id in m.first { $0.id == id } }
    }

    var body: some View {
        let o = ordered
        GeometryReader { g in
            let usable = max(1, g.size.width - Self.gap * 2)
            HStack(spacing: 0) {
                pane(o[0]).frame(width: usable * cutA)
                dividerA(usable)
                pane(o[1]).frame(width: usable * (cutB - cutA))
                dividerB(usable)
                pane(o[2])
            }
        }
        .padding(4)
        .onAppear { keepSlots(); startClicks() }
        .onChange(of: Set(members.map(\.id))) { _, _ in keepSlots() }
        .onDisappear { clicks.stop() }
    }

    private func dividerA(_ usable: CGFloat) -> some View {
        SplitDivider(ratio: cutA, usable: usable, start: $dragA, set: { cutA = $0 }, reset: equalize,
                     range: Self.minShare...max(Self.minShare, cutB - Self.minShare), notch: 1.0 / 3,
                     label: "First split view divider", valuePrefix: "First pane ends at")
            .frame(width: Self.gap)
    }

    private func dividerB(_ usable: CGFloat) -> some View {
        SplitDivider(ratio: cutB, usable: usable, start: $dragB, set: { cutB = $0 }, reset: equalize,
                     range: min(cutA + Self.minShare, 1 - Self.minShare)...(1 - Self.minShare), notch: 2.0 / 3,
                     label: "Second split view divider", valuePrefix: "Second pane ends at")
            .frame(width: Self.gap)
    }

    private func equalize() {
        withAnimation(WSMotion.navigation(reduce)) { cutA = 1.0 / 3; cutB = 2.0 / 3 }
        WSHaptics.alignment()
    }

    private func pane(_ t: BrowserTab) -> some View {
        let front = t.id == browser.selectedID
        return StageTab(tab: t, browser: browser, ws: ws, active: front)
            .id(t.id)
            .clipShape(RoundedRectangle(cornerRadius: WS.radius - 4, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: WS.radius - 4, style: .continuous)
                    .stroke(front ? accent.opacity(0.85) : WS.line, lineWidth: front ? 1.5 : 1)
                    .allowsHitTesting(false)
            )
            .overlay(alignment: .topTrailing) { closeButton(t) }
            .simultaneousGesture(TapGesture().onEnded { WSThirdPane.shared.focus(t, in: browser) })
            .accessibilityElement(children: .contain)
            .accessibilityLabel(Text(front ? "Split view, front pane: \(t.displayTitle)" : "Split view pane: \(t.displayTitle)"))
            .accessibilityAction(named: Text("Bring to Front")) { WSThirdPane.shared.focus(t, in: browser) }
    }

    private func closeButton(_ t: BrowserTab) -> some View {
        Button { withAnimation(WSMotion.navigation(reduce)) { WSThirdPane.shared.leave(t, in: browser) } } label: {
            Image(systemName: "xmark")
                .font(.system(size: 8.5, weight: .bold))
                .foregroundStyle(WS.text2)
                .frame(width: 18, height: 18)
                .background(.regularMaterial, in: Circle())
                .overlay(Circle().stroke(WS.line, lineWidth: 1))
        }
        .buttonStyle(.liaPlain)
        .liaPointer()
        .padding(7)
        .accessibilityLabel(Text("Close this pane of the split view"))
    }

    /// A new tab in the trio takes the place of the one that left; the first time, the current order.
    private func keepSlots() {
        let ids = members.map(\.id)
        if slots.count != 3 { slots = ids; return }
        let gone = slots.filter { !ids.contains($0) }
        let new = ids.filter { !slots.contains($0) }
        guard gone.count == new.count else { slots = ids; return }
        for (g, n) in zip(gone, new) { if let i = slots.firstIndex(of: g) { slots[i] = n } }
    }

    /// A click into a background pane's page (WebKit keeps it) brings that pane in front.
    private func startClicks() {
        clicks.start { [weak b = browser] e in
            MainActor.assumeIsolated {
                guard let b, let sel = b.selectedID else { return }
                let trio = [b.splitID, WSThirdPane.shared.tab(of: b)?.id].compactMap { $0 }
                for t in b.tabs where trio.contains(t.id) && t.id != sel && WSPaneClickWatcher.hit(e, t.webView) {
                    WSThirdPane.shared.focus(t, in: b)
                    return
                }
            }
        }
    }
}

/// The split's divider: a grip; drag to resize, double-click for 50/50, arrow keys with VoiceOver.
private struct SplitDivider: View {
    let ratio: CGFloat
    let usable: CGFloat
    @Binding var start: CGFloat?
    let set: (CGFloat) -> Void
    let reset: () -> Void
    /// A three-pane stage gives each divider its own range, notch and name.
    var range: ClosedRange<CGFloat> = 0.25...0.75
    var notch: CGFloat = 0.5
    var label = "Split view divider"
    var valuePrefix = "Left pane"
    @State private var hover = false
    /// The drag sits in the 50 % notch (one haptic tap on the way in).
    @State private var snapped = false

    var body: some View {
        ZStack {
            Color.clear
            Capsule().fill(hover || start != nil ? WS.text3 : WS.line2)
                .frame(width: 3, height: 40)
        }
        .contentShape(Rectangle())
        .onHover { h in hover = h }
        .liaCursor(.resizeLeftRight)   // one cursor approach (Hover.swift): no push / pop of our own here
        .onDisappear { hover = false }
        .onTapGesture(count: 2, perform: reset)
        .gesture(
            DragGesture(minimumDistance: 1, coordinateSpace: .global)
                .onChanged { v in
                    let s = start ?? ratio
                    if start == nil { start = s }
                    set(snap(clamp(s + v.translation.width / usable)))
                }
                .onEnded { _ in start = nil; snapped = false }
        )
        .accessibilityElement()
        .accessibilityLabel(Text(label))
        .accessibilityValue(Text("\(valuePrefix) \(Int((ratio * 100).rounded())) percent"))
        .accessibilityAdjustableAction { d in
            switch d {
            case .increment: set(clamp(ratio + 0.05))
            case .decrement: set(clamp(ratio - 0.05))
            @unknown default: break
            }
        }
        .accessibilityAction(named: Text("Make equal")) { reset() }
    }

    private func clamp(_ r: CGFloat) -> CGFloat { min(range.upperBound, max(range.lowerBound, r)) }

    /// Within 1.5 % of the notch (the middle; a third in a three-pane stage) the divider holds there and
    /// the trackpad taps once.
    private func snap(_ r: CGFloat) -> CGFloat {
        let inNotch = abs(r - notch) < 0.015
        if inNotch && !snapped { WSHaptics.alignment() }
        snapped = inNotch
        return inNotch ? notch : r
    }
}

/// Mouse-downs in the window, so a click into a split pane's page (which WebKit keeps) brings that pane in front.
final class WSPaneClickWatcher {
    private var token: Any?

    func start(_ handler: @escaping (NSEvent) -> Void) {
        stop()
        token = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { e in
            handler(e)
            return e
        }
    }

    func stop() {
        if let t = token { NSEvent.removeMonitor(t) }
        token = nil
    }

    @MainActor static func hit(_ e: NSEvent, _ view: NSView) -> Bool {
        guard let w = view.window, e.window === w, !view.isHiddenOrHasHiddenAncestor else { return false }
        return view.bounds.contains(view.convert(e.locationInWindow, from: nil))
    }
}

/// The selected tab on the card, with its states over it: the progress line, the error and crash cards
/// (/03/04), the sleeping snapshot, find, zoom and the permission card.
/// In a split both panes use it; only the pane in front (`active`) shows the find bar.
private struct StageTab: View {
    @ObservedObject var tab: BrowserTab
    let browser: BrowserModel
    @ObservedObject var ws: WorkspaceModel
    var active = true
    @Environment(\.accessibilityReduceMotion) private var reduce
    /// False until a page that never drew has painted (the card stays white over it, no flash).
    @State private var painted = true
    /// The tab was restored and not loaded yet when it was first shown: its skeleton until the first paint.
    @State private var restored = false
    /// The person chose the new tab page over the split pane's tab picker.
    @State private var showHome = false

    private var lead: AgentInfo? { ws.roster.first(where: { $0.lead }) ?? ws.roster.first }

    var body: some View {
        ZStack {
            if tab.isStart {
                // A split pane on the start page offers the open tabs first.
                if browser.splitTab != nil, !showHome, !SplitPickPane.candidates(browser, except: tab).isEmpty {
                    SplitPickPane(tab: tab, browser: browser) { showHome = true }
                } else {
                    WorkspaceHome(ws: ws, browser: browser) { typed in if let u = BrowserModel.resolve(typed) { tab.load(u) } }
                }
            } else {
                page
            }
        }
        // An agent dragged from the dock onto the page works on this page.
        .onDrop(of: DockDrop.types, isTargeted: nil) { providers in DockDrop.handle(providers, ws: ws) }
        .overlay(alignment: .top) {
            if !tab.isStart {
                PageLoadBar(tab: tab, color: Color(hex: ws.profile?.colorHex ?? 0x3B5BFD))
                // An agent changed this Ads Manager account after the page was loaded: "Met changed 2 things · Reload".
                ChangeBanner(tab: tab, ws: ws)
                // "Save password for site.com?" after a sign-in (PasswordBar.swift).
                PasswordBar(pw: tab.passwords)
            }
        }
        .overlay(alignment: .topLeading) {
            if let p = tab.permission {
                PermissionCard(tab: tab, ask: p)
                    .id(p.id)
                    .padding(12)
                    .transition(reduce ? AnyTransition.opacity : AnyTransition.move(edge: .top).combined(with: .opacity))
            }
        }
        .overlay(alignment: .topTrailing) {
            if ws.findOpen && active && !tab.isStart {
                FindBar(tab: tab, ws: ws)
                    .padding(10)
                    .transition(reduce ? AnyTransition.opacity : AnyTransition.move(edge: .top).combined(with: .opacity))
            }
        }
        .overlay {
            ZoomFlash(tab: tab)
            // Reader over this tab's page.
            if !tab.isStart { ReaderLayer(tab: tab, ws: ws) }
        }
        .animation(WSMotion.micro, value: tab.snapshot == nil)
        .animation(WSMotion.micro, value: tab.crashed)
        .animation(WSMotion.micro, value: tab.loadError)
        .animation(WSMotion.micro, value: painted)
        .animation(WSMotion.navigation(reduce), value: ws.findOpen)
        .animation(WSMotion.navigation(reduce), value: tab.permission?.id)
        .onAppear {
            painted = tab.isStart || tab.webView.url != nil
            restored = tab.pendingURL != nil
            tab.loadIfPending()
            if !painted {
                // Never keep a slow page hidden for long.
                DispatchQueue.main.asyncAfter(deadline: .now() + 4) { painted = true }
            }
        }
        .onChange(of: tab.progress) { _, p in if p >= 0.3 { painted = true } }
        .onChange(of: tab.isLoading) { _, l in if !l { painted = true } }
        .onChange(of: tab.url) { _, u in ws.pageChanged(u) }
    }

    @ViewBuilder private var page: some View {
        WebViewHost(webView: tab.webView)
        // 0.2.11: Select element on Dev's own sites (nothing on any other page).
        DevPickerTabLayer(webView: tab.webView, url: tab.url, isLoading: tab.isLoading, auth: ws.auth, profile: ws.profileId)
        // 0.2.11: page and selection translation, on device (TranslateLayer.swift).
        if !tab.isStart { TranslateTabLayer(webView: tab.webView, url: tab.url, isLoading: tab.isLoading) }
        if let s = tab.snapshot {
            TabSnapshot(image: s).transition(.opacity)
        } else if !painted {
            if restored {
                // Its saved icon and title on a skeleton, not plain white.
                RestoreSkeleton(tab: tab).transition(.opacity)
            } else {
                // The card's own white until the page's first paint.
                WS.surface.allowsHitTesting(false).accessibilityHidden(true).transition(.opacity)
            }
        }
        AgentOverlay(agent: browser.agent, tabID: tab.id, web: browser.web)
        // The site answered 4xx/5xx.
        PageStatusCard(tab: tab, ws: ws)
        if tab.crashed {
            PageProblemCard(agent: lead, title: "This page stopped responding",
                            message: "Its process ended. The rest of Liaison is fine; reload to bring the page back.",
                            actionTitle: "Reload") { tab.reload() }
                .transition(.opacity)
        } else if let e = tab.loadError {
            PageProblemCard(agent: lead, title: e.title, message: e.message,
                            detail: e.kind == .insecure ? [e.url?.host, e.detail].compactMap { $0 }.joined(separator: "\n") : nil,
                            retrying: e.kind == .offline,
                            actionTitle: "Try Again") { tab.reload() }
                .transition(.opacity)
        }
    }
}

/// The workspace's buttons: ink primary (black in light, near-white in dark), surface secondary, rounded.
struct WSButtonStyle: ButtonStyle {
    var primary = false
    var small = false
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(LiaFont.ui(small ? 12.5 : 13.5, .medium))
            .foregroundStyle(primary ? WS.onInk : WS.ink)
            .padding(.horizontal, small ? 11 : 15)
            .frame(height: small ? 28 : 34)
            .background(primary ? WS.ink : WS.surface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(primary ? Color.clear : WS.line2, lineWidth: 1))
            .opacity(configuration.isPressed ? 0.75 : 1)
            .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .liaPointer()   // 0.2.11: every styled button shows the hand, not only those that remembered to ask
            .modifier(LatencyPressMark(isPressed: configuration.isPressed))   // the canary's click latency (LatencyProbe)
    }
}
