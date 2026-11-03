import SwiftUI
import WebKit
import AppKit
import Combine

// Web panels (Vivaldi Web Panels, Opera sidebar messengers): a narrow panel at the right of the page
// with one of the person's sites (none to start; + adds one), each in its own WKWebView on the
// workspace's data store, so a sign-in stays with the client. A small switcher picks the site; + adds one by address.
// The first panel is fixed and cannot be closed: the agents' mini-messenger (talk to an agent while the page
// stays in view). + opens a glass list of sites known to work in a narrow panel, plus "Custom URL\u{2026}".
// (option 4): each service gets its own agent and width (Shared/Core/PanelProfiles.swift). The per-site
// behaviour there is from memory and must be verified on the product's Mac. The agent is set on the panel's own web view only;
// its data store is the same workspace store as before, and nothing of ours enters the page.
// The panel IS the workspace's browser: same data store, unless the person marks a service "Same
// sign-in in all workspaces" (one store for it across workspaces). One live session of a service at a time ("Open as
// tab" hands it to the main browser; a shared service open in two workspaces runs only in the one in front). Each
// workspace has its own panel (open, site in front). Links that leave the service or open a window, and downloads,
// go to the main browser (PanelWebDelegate). Rules: Shared/Core/WebPanelRules.swift.

@MainActor
final class WebPanelStore: ObservableObject {
    static let shared = WebPanelStore()
    private static let sitesKey = "lia_web_panels"
    private static let selectedKey = "lia_web_panel_selected"
    /// The site in front per workspace (profile id -> URL string).
    private static let selectedByKey = "lia_web_panel_selected_by"
    /// The services (WebPanelRules.serviceKey) the person switched to a sign-in per workspace. Every other
    /// service has the same sign-in in all workspaces (the default; the old "lia_web_panel_shared" list held only
    /// shared ones, which stay shared, so it needs no migration).
    private static let perWorkspaceKey = "lia_web_panel_per_workspace"
    static let width = CGFloat(PanelProfiles.narrowWidth)
    private static let wideKey = "lia_web_panel_wide"

    @Published private(set) var sites: [URL] = []
    /// The site in front in the workspace shown now; nil: the agents' panel (the first, fixed one).
    @Published var selected: URL? {
        didSet {
            UserDefaults.standard.set(selected?.absoluteString, forKey: Self.selectedKey)
            if let w = workspaceID {
                selectedBy[w] = selected?.absoluteString
                UserDefaults.standard.set(selectedBy, forKey: Self.selectedByKey)
            }
        }
    }
    /// "Wider": the panel at its second width (all sites; the setting outlives a restart).
    @Published var wide: Bool = UserDefaults.standard.bool(forKey: WebPanelStore.wideKey) {
        didSet { UserDefaults.standard.set(wide, forKey: Self.wideKey) }
    }
    var panelWidth: CGFloat { CGFloat(PanelProfiles.width(wide: wide)) }
    /// The person's zoom per site (PanelProfiles.zoomKey); a site without one is fitted (Fit).
    private static let zoomsKey = "lia_web_panel_zoom"
    @Published private(set) var zooms: [String: Double] =
        (UserDefaults.standard.dictionary(forKey: WebPanelStore.zoomsKey) as? [String: Double]) ?? [:] {
        didSet { UserDefaults.standard.set(zooms, forKey: Self.zoomsKey) }
    }
    /// Services signed in per workspace, on each workspace's own browser store (default: none, every service has one
    /// sign-in for all workspaces).
    @Published private(set) var perWorkspaceServices: Set<String> =
        Set(UserDefaults.standard.stringArray(forKey: WebPanelStore.perWorkspaceKey) ?? [])
    /// "Open as Tab": the panel's page went to the main browser (view key -> address) and its panel instance is
    /// unloaded, so one session runs. The panel offers "Open Here" to take it back.
    @Published private(set) var handedOff: [String: URL] = [:]

    /// One live web view per workspace and site (WebPanelRules.viewKey): switching keeps each page where it was.
    private var views: [String: WKWebView] = [:]
    private var delegates: [String: PanelWebDelegate] = [:]
    private var live: [String: WebPanelRules.Live] = [:]
    /// Where an unloaded panel page was: it reloads there when shown again.
    private var resume: [String: URL] = [:]
    /// The tabs "Open as Tab" made (Open Here closes them).
    private var handedTabs: [String: WeakTab] = [:]
    private struct WeakTab { weak var tab: BrowserTab? }

    /// The workspace shown now (WorkspaceModel.profileId) and each workspace's own panel state.
    private var workspaceID: String?
    private var selectedBy: [String: String] =
        (UserDefaults.standard.dictionary(forKey: WebPanelStore.selectedByKey) as? [String: String]) ?? [:]
    private var openBy: [String: Bool] = [:]
    private var followed: ObjectIdentifier?
    private var subs: [AnyCancellable] = []

    private init() {
        let saved = (UserDefaults.standard.array(forKey: Self.sitesKey) as? [String])?.compactMap(URL.init(string:))
        // Empty by default: the person adds sites with +. Next round: the agents' mini-messenger.
        sites = saved ?? []
        let list = sites
        var pick: URL? = nil
        if let s = UserDefaults.standard.string(forKey: Self.selectedKey), let u = URL(string: s), list.contains(u) { pick = u }
        selected = pick
    }

    // MARK: - per workspace (open in one workspace is not open in another)

    /// Called by the panel when it appears: from now on a workspace switch brings that workspace's own panel state
    /// (open or closed, the site in front).
    func follow(_ ws: WorkspaceModel) {
        guard followed != ObjectIdentifier(ws) else { return }
        followed = ObjectIdentifier(ws)
        subs = []
        workspaceID = ws.profileId
        if let w = workspaceID {
            openBy[w] = WSExtras.shared.panelOpen
            if selectedBy[w] == nil { selectedBy[w] = selected?.absoluteString } else { selected = siteURL(selectedBy[w]) }
        }
        // @Published sends on willSet: `id` is the workspace coming, `workspaceID` still the one going.
        ws.$profileId.removeDuplicates().sink { [weak self] id in MainActor.assumeIsolated { self?.switchTo(id) } }
            .store(in: &subs)
        WSExtras.shared.$panelOpen.removeDuplicates().sink { [weak self] on in
            MainActor.assumeIsolated {
                guard let self, let w = self.workspaceID else { return }
                self.openBy[w] = on
            }
        }
        .store(in: &subs)
    }

    private func switchTo(_ id: String?) {
        guard id != workspaceID else { return }
        if let w = workspaceID { openBy[w] = WSExtras.shared.panelOpen }
        workspaceID = id
        selected = id.flatMap { siteURL(selectedBy[$0]) }
        let open = id.flatMap { openBy[$0] } ?? false
        if WSExtras.shared.panelOpen != open { WSExtras.shared.panelOpen = open }
    }

    private func siteURL(_ s: String?) -> URL? {
        guard let s, let u = URL(string: s), sites.contains(u) else { return nil }
        return u
    }

    // MARK: - sites

    func add(_ typed: String) -> Bool {
        guard let u = BrowserModel.resolve(typed), u.host != nil, ["http", "https"].contains(u.scheme?.lowercased() ?? "") else { return false }
        if !sites.contains(u) { sites.append(u); persist() }
        selected = u
        return true
    }

    func remove(_ u: URL) {
        sites.removeAll { $0 == u }
        for k in views.keys where k.hasSuffix("|" + u.absoluteString) { unload(k, keepPlace: false) }
        for k in handedOff.keys where k.hasSuffix("|" + u.absoluteString) { handedOff[k] = nil; handedTabs[k] = nil }
        if selected == u { selected = nil }
        for (w, s) in selectedBy where s == u.absoluteString { selectedBy[w] = nil }
        UserDefaults.standard.set(selectedBy, forKey: Self.selectedByKey)
        persist()
    }

    // MARK: - sign-in scope

    func scope(_ u: URL) -> WebPanelScope {
        WebPanelRules.scope(service: WebPanelRules.serviceKey(u), perWorkspace: perWorkspaceServices)
    }

    /// Changes where the service signs in. Its open pages are unloaded and come back on the other store (the person
    /// signs in there once).
    func setScope(_ u: URL, _ s: WebPanelScope) {
        guard let svc = WebPanelRules.serviceKey(u), scope(u) != s else { return }
        perWorkspaceServices = WebPanelRules.choosing(s, for: svc, perWorkspace: perWorkspaceServices)
        UserDefaults.standard.set(Array(perWorkspaceServices).sorted(), forKey: Self.perWorkspaceKey)
        for (k, l) in live where l.service == svc { unload(k, keepPlace: true) }
    }

    /// The panel's own data store key for a site in a workspace browser.
    func storeKey(_ u: URL, browser b: BrowserModel) -> String? {
        WebPanelRules.storeKey(workspace: b.account, service: WebPanelRules.serviceKey(u) ?? u.absoluteString, scope: scope(u))
    }

    // MARK: - zoom

    /// The page's zoom and width in the panel now.
    func layout(_ u: URL) -> PanelLayout {
        PanelProfiles.layout(PanelProfiles.profile(for: u), panelWidth: Double(panelWidth),
                             userZoom: PanelProfiles.zoomKey(u).flatMap { zooms[$0] })
    }

    /// + / - from the current zoom (Fit's included); nil `up`: back to Fit.
    func zoom(_ u: URL, up: Bool?) {
        guard let k = PanelProfiles.zoomKey(u) else { return }
        guard let up else { zooms[k] = nil; return }
        zooms[k] = PanelProfiles.step(layout(u).zoom, up: up)
    }

    func isFit(_ u: URL) -> Bool { PanelProfiles.zoomKey(u).map { zooms[$0] == nil } ?? true }

    // MARK: - web views

    func key(_ u: URL, browser b: BrowserModel) -> String { WebPanelRules.viewKey(workspace: b.account, site: u) }

    /// The live page if there is one (never creates one).
    func existing(_ u: URL, browser b: BrowserModel) -> WKWebView? { views[key(u, browser: b)] }

    /// The panel's page of `u` in workspace browser `b`, made when needed. Showing a shared service unloads its
    /// instance in any other workspace first (one live session: WhatsApp and Telegram drop a second one).
    func webView(for u: URL, browser b: BrowserModel) -> WKWebView {
        let k = key(u, browser: b)
        let svc = WebPanelRules.serviceKey(u) ?? u.absoluteString
        let me = WebPanelRules.Live(key: k, service: svc, workspace: b.account ?? "_none", scope: scope(u))
        // A workspace that is going away (its panel fading out) never takes the session back.
        let front = WorkspaceModel.current?.currentBrowser.map { $0 === b } ?? true
        if let v = views[k] {
            if front { for o in WebPanelRules.toUnload(live: Array(live.values), showing: me) { unload(o, keepPlace: true) } }
            return v
        }
        guard front else { return WKWebView(frame: .zero) }
        for o in WebPanelRules.toUnload(live: Array(live.values), showing: me) { unload(o, keepPlace: true) }
        let config = BrowserModel.configuration(account: WebPanelRules.storeKey(workspace: b.account, service: svc, scope: me.scope))
        let v = WKWebView(frame: .zero, configuration: config)
        // The site's profile picks the agent (Gmail: iPhone Safari) before the first load.
        v.customUserAgent = PanelProfiles.userAgent(PanelProfiles.profile(for: u), desktop: BrowserModel.userAgent)
        v.allowsBackForwardNavigationGestures = true
        let d = PanelWebDelegate(site: u, browser: b)
        v.navigationDelegate = d
        v.uiDelegate = d
        v.load(URLRequest(url: resume.removeValue(forKey: k) ?? u))
        views[k] = v
        delegates[k] = d
        live[k] = me
        return v
    }

    /// The page is let go (its web content process ends with it): not just hidden. `keepPlace`: it reloads where it
    /// was when shown again. The blank load waits for a fading panel to finish showing it.
    private func unload(_ k: String, keepPlace: Bool) {
        guard let v = views.removeValue(forKey: k) else { return }
        if keepPlace, let u = v.url, ["http", "https"].contains(u.scheme?.lowercased() ?? "") { resume[k] = u } else if !keepPlace { resume[k] = nil }
        delegates[k] = nil
        live[k] = nil
        v.pauseAllMediaPlayback(completionHandler: nil)
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 350_000_000)
            v.stopLoading()
            if let blank = URL(string: "about:blank") { v.load(URLRequest(url: blank)) }
        }
    }

    // MARK: - Open as Tab / Open Here (one session at a time)

    /// The panel's current page (where it is now, not where it started) in a tab of this workspace's browser, on the
    /// same sign-in; the panel's own instance is unloaded so only one session runs.
    func handOff(_ site: URL, browser b: BrowserModel) {
        let k = key(site, browser: b)
        let now = views[k]?.url ?? resume[k]
        let target = now.flatMap { ["http", "https"].contains($0.scheme?.lowercased() ?? "") ? $0 : nil } ?? site
        // A shared service's tab must be on the service's store, or it opens signed out.
        let config = scope(site) == .shared ? BrowserModel.configuration(account: storeKey(site, browser: b)) : nil
        let tab = b.newTab(url: target, configuration: config)
        unload(k, keepPlace: true)
        handedOff[k] = target
        handedTabs[k] = WeakTab(tab: tab)
    }

    /// The tab "Open as Tab" made, while it is still open.
    func handedTab(_ site: URL, browser b: BrowserModel) -> BrowserTab? {
        guard let t = handedTabs[key(site, browser: b)]?.tab, b.tabs.contains(where: { $0.id == t.id }) else { return nil }
        return t
    }

    /// "Open Here": the page back in the panel, where the tab is now; that tab is closed (one session).
    func takeBack(_ site: URL, browser b: BrowserModel) {
        let k = key(site, browser: b)
        if let t = handedTab(site, browser: b) {
            if let u = t.url, WebPanelRules.sameService(u, site: site) { resume[k] = u }
            b.close(t)
        }
        handedOff[k] = nil
        handedTabs[k] = nil
    }

    static func name(_ u: URL) -> String {
        let h = (u.host ?? u.absoluteString).lowercased()
        if h.contains("whatsapp") { return "WhatsApp" }
        if h.contains("telegram") { return "Telegram" }
        if h.contains("calendar.google") { return "Calendar" }
        if h.contains("slack") { return "Slack" }
        if h.contains("mail.google") { return "Gmail" }
        if h.contains("instagram") { return "Instagram" }
        if h.contains("messenger") { return "Messenger" }
        if h.contains("notion") { return "Notion" }
        return h.hasPrefix("www.") ? String(h.dropFirst(4)) : h
    }

    /// Sites that work in a 380 pt panel (no AI sites: the agents are the panel's first page).
    static let catalogue: [(name: String, url: String)] = [
        ("WhatsApp", "https://web.whatsapp.com/"),
        ("Telegram", "https://web.telegram.org/a/"),
        ("Instagram", "https://www.instagram.com/direct/inbox/"),
        ("Messenger", "https://www.messenger.com/"),
        ("Slack", "https://app.slack.com/client"),
        ("Gmail", "https://mail.google.com/"),
        ("Calendar", "https://calendar.google.com/"),
        ("Notion", "https://www.notion.so/"),
    ]

    private func persist() { UserDefaults.standard.set(sites.map(\.absoluteString), forKey: Self.sitesKey) }
}

/// A panel page's navigation, new windows and downloads. Nothing of ours enters the page: this is
/// the web view's own delegate, no scripts, no message handlers (design rule: our scripts never enter the page world).
/// A link that leaves the service, \u{2318}-click, target=_blank and window.open open in a tab of the current
/// workspace's browser (WebPanelRules.route); a sized window.open (a sign-in pop-up) stays a pop-up window of ours,
/// which keeps its opener.
/// Downloads go into the browser's pipeline: the same folder (per client) and DownloadsCenter's toolbar.
@MainActor
final class PanelWebDelegate: NSObject, WKNavigationDelegate, WKUIDelegate, WKDownloadDelegate {
    let site: URL
    /// The workspace browser the panel belongs to (its client folder; where links open when no window is in front).
    weak var browser: BrowserModel?
    /// Kept while a download runs: the panel page may be unloaded meanwhile.
    private static var downloading: [PanelWebDelegate] = []

    init(site: URL, browser: BrowserModel?) {
        self.site = site
        self.browser = browser
    }

    private func openInMain(_ u: URL) {
        if let b = WorkspaceModel.current?.currentBrowser ?? browser { b.open(u) } else { NSWorkspace.shared.open(u) }
    }

    private func follow(_ r: WebPanelRoute) -> Bool {
        switch r {
        case .stay: return true
        case .openInMain(let u): openInMain(u)
        case .external(let u): NSWorkspace.shared.open(u)
        case .ignore: break
        }
        return false
    }

    // MARK: WKNavigationDelegate

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        if navigationAction.shouldPerformDownload { decisionHandler(.download); return }
        // No target frame: a new window; createWebViewWith below decides it (with the window's size).
        guard let frame = navigationAction.targetFrame else { decisionHandler(.allow); return }
        let r = WebPanelRules.route(navigationAction.request.url, site: site, mainFrame: frame.isMainFrame, newWindow: false,
                                    userClick: navigationAction.navigationType == .linkActivated,
                                    newTabGesture: TabStrip.linkWantsNewTab(command: navigationAction.modifierFlags.contains(.command),
                                                                            button: navigationAction.buttonNumber))
        decisionHandler(follow(r) ? .allow : .cancel)
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse,
                 decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void) {
        // As the browser's tabs: an attachment, or anything WebKit cannot show, is a download.
        if let http = navigationResponse.response as? HTTPURLResponse,
           let cd = http.value(forHTTPHeaderField: "Content-Disposition"), cd.lowercased().hasPrefix("attachment") {
            decisionHandler(.download); return
        }
        decisionHandler(navigationResponse.canShowMIMEType ? .allow : .download)
    }

    func webView(_ webView: WKWebView, navigationResponse: WKNavigationResponse, didBecome download: WKDownload) { download.delegate = self }
    func webView(_ webView: WKWebView, navigationAction: WKNavigationAction, didBecome download: WKDownload) { download.delegate = self }
    /// The page menu's Download Image / Download Linked File (the same private hook the browser's tabs use).
    @objc(_webView:contextMenuDidCreateDownload:)
    func webViewContextMenuDidCreateDownload(_ webView: WKWebView, download: WKDownload) { download.delegate = self }

    // MARK: WKUIDelegate

    /// window.outerWidth/outerHeight: the real window, never 0x0 (PageWindowFrame.swift).
    @objc(_webView:getWindowFrameWithCompletionHandler:)
    func webViewGetWindowFrame(_ webView: WKWebView, completionHandler: @escaping (CGRect) -> Void) {
        completionHandler(PageWindowFrame.of(webView))
    }

    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        // A sized window.open (Google's or Facebook's sign-in): a pop-up of ours that keeps its opener.
        if WebPopupWindow.wantsWindow(windowFeatures) {
            return WebPopupWindow.adopt(configuration: configuration, features: windowFeatures)
        }
        let u = navigationAction.request.url
        if let u, ["http", "https"].contains(u.scheme?.lowercased() ?? "") {
            _ = follow(WebPanelRules.route(u, site: site, mainFrame: true, newWindow: true,
                                           userClick: navigationAction.navigationType == .linkActivated))
            return nil
        }
        // window.open with no address yet (the page sets it next): an unseen catcher takes the first address.
        if u == nil || u?.absoluteString == "about:blank" || u?.absoluteString.isEmpty == true {
            return PanelPopupCatcher(configuration: configuration) { [weak self] to in self?.openInMain(to) }.web
        }
        _ = follow(WebPanelRules.route(u, site: site, mainFrame: true, newWindow: true,
                                       userClick: navigationAction.navigationType == .linkActivated))
        return nil
    }

    /// <input type=file> (attachments in a messenger).
    func webView(_ webView: WKWebView, runOpenPanelWith parameters: WKOpenPanelParameters,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping ([URL]?) -> Void) {
        let p = NSOpenPanel()
        p.allowsMultipleSelection = parameters.allowsMultipleSelection
        p.canChooseDirectories = parameters.allowsDirectories
        p.canChooseFiles = true
        completionHandler(p.runModal() == .OK ? p.urls : nil)
    }

    // MARK: WKDownloadDelegate (the browser's folder and DownloadsCenter)

    func download(_ download: WKDownload, decideDestinationUsing response: URLResponse, suggestedFilename: String,
                  completionHandler: @escaping (URL?) -> Void) {
        let base = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0]
        let client = browser?.clientName ?? WorkspaceModel.current?.currentBrowser?.clientName
        var dir = WebPanelRules.downloadFolder(base: base, client: client, perClient: Prefs.flag(Prefs.downloadsPerClient))
        if dir != base, (try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)) == nil { dir = base }
        let dest = WebPanelRules.uniqueFile(in: dir, name: suggestedFilename) { FileManager.default.fileExists(atPath: $0.path) }
        if !Self.downloading.contains(where: { $0 === self }) { Self.downloading.append(self) }
        DownloadsCenter.shared.started(download, name: dest.lastPathComponent, dest: dest, webView: download.webView)
        completionHandler(dest)
    }

    func downloadDidFinish(_ download: WKDownload) {
        DownloadsCenter.shared.finished(download)
        release()
    }

    func download(_ download: WKDownload, didFailWithError error: Error, resumeData: Data?) {
        DownloadsCenter.shared.failed(download, resumeData: resumeData)
        release()
    }

    private func release() {
        guard !DownloadsCenter.shared.active.contains(where: { $0.download?.delegate === self }) else { return }
        Self.downloading.removeAll { $0 === self }
    }
}

/// window.open with no address: WebKit needs a web view on its configuration at once; the page then sets the
/// address. This one is never shown: its first web address opens in the main browser and it goes away.
@MainActor
final class PanelPopupCatcher: NSObject, WKNavigationDelegate {
    private static var live: [PanelPopupCatcher] = []
    let web: WKWebView
    private let open: (URL) -> Void

    init(configuration: WKWebViewConfiguration, open: @escaping (URL) -> Void) {
        web = WKWebView(frame: .zero, configuration: configuration)
        self.open = open
        super.init()
        web.navigationDelegate = self
        Self.live.append(self)
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 15_000_000_000)
            self?.done()
        }
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        if let u = navigationAction.request.url, ["http", "https"].contains(u.scheme?.lowercased() ?? "") {
            decisionHandler(.cancel)
            open(u)
            done()
            return
        }
        decisionHandler(.allow)
    }

    private func done() {
        web.stopLoading()
        Self.live.removeAll { $0 === self }
    }
}

/// The panel itself (shown by the window while WSExtras.panelOpen).
struct WebPanelView: View {
    @ObservedObject var ws: WorkspaceModel
    /// This workspace's browser: the panel's pages are on its data store (or the service's shared one).
    let browser: BrowserModel
    @ObservedObject private var store = WebPanelStore.shared
    @State private var adding = false
    @State private var draft = ""

    var body: some View {
        VStack(spacing: 0) {
            switcher
            page
        }
        .frame(width: store.panelWidth)
        .background(WS.surface)
        .clipShape(RoundedRectangle(cornerRadius: WS.radius, style: .continuous))
        .shadow(color: Color.black.opacity(0.06), radius: 12, y: 6)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text("Web panel"))
        .onAppear { store.follow(ws) }
    }

    @ViewBuilder private var page: some View {
        if let u = store.selected, let to = store.handedOff[store.key(u, browser: browser)] {
            handedOffPage(u, to: to)
        } else if let u = store.selected {
            let v = store.webView(for: u, browser: browser)
            // Every site at the panel's width and its zoom (WhatsApp fitted from 1000 px); vertical scroll only.
            PanelPageHost(webView: v, zoom: CGFloat(store.layout(u).zoom))
                .id(ObjectIdentifier(v))
        } else {
            AgentsMiniMessenger(ws: ws)
        }
    }

    private var switcher: some View {
        HStack(spacing: 4) {
            agentsButton
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 4) { ForEach(store.sites, id: \.self) { u in siteButton(u) } }
            }
            .fixedSize(horizontal: false, vertical: true)
            addButton
            Spacer(minLength: 0)
            if let u = store.selected, store.handedOff[store.key(u, browser: browser)] == nil {
                Button { store.webView(for: u, browser: browser).reload() } label: {
                    Image(systemName: "arrow.clockwise").font(.system(size: 11, weight: .semibold)).foregroundStyle(WS.text2)
                        .frame(width: 26, height: 26)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.liaPlain)
                .liaHover(.icon, radius: 8)
                .accessibilityLabel(Text("Reload \(WebPanelStore.name(u))"))
            }
            moreButton
        }
        .padding(.horizontal, 8)
        .frame(height: 40)
        .background(WS.soft)
    }

    private func siteButton(_ u: URL) -> some View {
        let on = store.selected == u
        return Button { store.selected = u } label: {
            Text(WebPanelStore.name(u))
                .font(LiaFont.ui(12, on ? .semibold : .regular))
                .foregroundStyle(on ? WS.ink : WS.text2)
                .lineLimit(1)
                .padding(.horizontal, 9)
                .frame(height: 26)
                .background(on ? WS.surface : Color.clear, in: Capsule())
                .contentShape(Capsule())
        }
        .buttonStyle(.liaPlain)
        .liaPointer()
        .liaContextMenu { [
            // Signed in per workspace (the default) or once for every workspace.
            LiaCtxItem(title: store.scope(u) == .shared ? "Separate Sign-in per Workspace" : "Same Sign-in in All Workspaces",
                       action: { store.setScope(u, store.scope(u) == .shared ? .workspace : .shared) }),
            .sep,
            LiaCtxItem(title: "Remove \(WebPanelStore.name(u))", danger: true, action: { store.remove(u) }),
        ] }
        .accessibilityLabel(Text(WebPanelStore.name(u)))
        .accessibilityAddTraits(on ? .isSelected : [])
        .accessibilityAction(named: Text("Remove")) { store.remove(u) }
    }

    /// The fixed first panel: the agents. No remove.
    private var agentsButton: some View {
        let on = store.selected == nil
        return Button { store.selected = nil } label: {
            HStack(spacing: 5) {
                Image(systemName: "bubble.left.and.bubble.right").font(.system(size: 10.5, weight: .semibold))
                Text("Agents").font(LiaFont.ui(12, on ? .semibold : .regular))
            }
            .foregroundStyle(on ? WS.ink : WS.text2)
            .padding(.horizontal, 9)
            .frame(height: 26)
            .background(on ? WS.surface : Color.clear, in: Capsule())
            .contentShape(Capsule())
        }
        .buttonStyle(.liaPlain)
        .liaPointer()
        .accessibilityLabel(Text("Agents"))
        .accessibilityAddTraits(on ? .isSelected : [])
    }

    private var addButton: some View {
        DropdownButton(align: .trailing, radius: 8, highlight: false) {
            Image(systemName: "plus").font(.system(size: 11, weight: .semibold)).foregroundStyle(WS.text2)
                .frame(width: 26, height: 26)
                .contentShape(Rectangle())
        } menu: {
            DropdownPanelView(width: 210) {
                DropdownTitle(text: "Add to the panel")
                ForEach(WebPanelStore.catalogue, id: \.url) { c in
                    let u = URL(string: c.url)
                    DropdownItem(title: c.name, trailing: u.map { store.sites.contains($0) } == true ? "check" : nil, fontSize: 13) {
                        _ = store.add(c.url)
                    }
                }
                DropdownDivider()
                DropdownItem(title: "Custom URL\u{2026}", fontSize: 13) {
                    DispatchQueue.main.async { adding = true }
                }
            }
        }
        .accessibilityLabel(Text("Add a site to the panel"))
        .popover(isPresented: $adding, arrowEdge: .bottom) { addForm }
    }

    /// The panel's quick actions: the page in a normal tab, and the panel's width.
    private var moreButton: some View {
        DropdownButton(align: .trailing, radius: 8, highlight: false) {
            Image(systemName: "ellipsis").font(.system(size: 11, weight: .semibold)).foregroundStyle(WS.text2)
                .frame(width: 26, height: 26)
                .contentShape(Rectangle())
        } menu: {
            DropdownPanelView(width: 190) {
                if let u = store.selected, store.handedOff[store.key(u, browser: browser)] == nil {
                    DropdownItem(title: "Open as tab", fontSize: 13) { store.handOff(u, browser: browser) }
                }
                if let u = store.selected {
                    DropdownItem(title: "Same sign-in in all workspaces", trailing: store.scope(u) == .shared ? "check" : nil, fontSize: 13) {
                        store.setScope(u, store.scope(u) == .shared ? .workspace : .shared)
                    }
                }
                DropdownItem(title: store.wide ? "Narrower" : "Wider", fontSize: 13) { store.wide.toggle() }
                if let u = store.selected {
                    // The page's zoom, remembered per site; Fit fits the page into the panel's width.
                    let z = store.layout(u).zoom
                    DropdownDivider()
                    DropdownTitle(text: "Zoom \(PanelProfiles.percent(z))")
                    DropdownItem(title: "Zoom in", fontSize: 13) { store.zoom(u, up: true) }
                        .disabled(z >= PanelProfiles.maxUserZoom - 0.001)
                    DropdownItem(title: "Zoom out", fontSize: 13) { store.zoom(u, up: false) }
                        .disabled(z <= PanelProfiles.minUserZoom + 0.001)
                    DropdownItem(title: "Fit", trailing: store.isFit(u) ? "check" : nil, fontSize: 13) { store.zoom(u, up: nil) }
                }
            }
        }
        .accessibilityLabel(Text("Panel actions"))
    }

    /// After "Open as tab": the service runs in the tab only (WhatsApp and Telegram sign out a
    /// second session); the panel offers it back.
    private func handedOffPage(_ u: URL, to: URL) -> some View {
        let name = WebPanelStore.name(u)
        let tab = store.handedTab(u, browser: browser)
        return VStack(spacing: 12) {
            Spacer(minLength: 0)
            Image(systemName: "rectangle.portrait.and.arrow.right").font(.system(size: 22, weight: .regular)).foregroundStyle(WS.text2)
            Text("\(name) is open in a tab").font(LiaFont.ui(14, .semibold)).foregroundStyle(WS.ink)
            Text("One session at a time, so it is not loaded here.")
                .font(LiaFont.ui(12)).foregroundStyle(WS.text2).multilineTextAlignment(.center)
            HStack(spacing: 8) {
                if let tab {
                    Button("Show Tab") { browser.selectedID = tab.id }
                        .buttonStyle(WSButtonStyle(primary: false, small: true))
                }
                Button("Open Here") { store.takeBack(u, browser: browser) }
                    .buttonStyle(WSButtonStyle(primary: true, small: true))
                    .liaTip(tab == nil ? "Load \(name) in the panel again" : "Close the tab and load \(name) in the panel")
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text("\(name) is open in a tab"))
    }

    private var addForm: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Add a site").font(LiaFont.ui(13, .semibold)).foregroundStyle(WS.ink)
            TextField("calendar.google.com", text: $draft)
                .textFieldStyle(.roundedBorder)
                .frame(width: 240)
                .onSubmit { add() }
                .accessibilityLabel(Text("Site address"))
            HStack {
                Spacer()
                Button("Add") { add() }.buttonStyle(WSButtonStyle(primary: true, small: true))
                    .disabled(draft.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(14)
    }

    private func add() {
        if store.add(draft) { draft = ""; adding = false }
    }
}

/// A panel page at the panel's own width, zoomed by `zoom` (WKWebView.pageZoom; the page's layout width is
/// panel / zoom CSS px, so WhatsApp at 0.38 lays out at 1000 px and fits). No scroll view around it: the page scrolls
/// vertically itself and never sideways (sideways-scrolling host hid WhatsApp's login QR code). Nothing is
/// injected into the page; the zoom is the web view's own.
struct PanelPageHost: NSViewRepresentable {
    let webView: WKWebView
    let zoom: CGFloat

    func makeNSView(context: Context) -> WKWebView {
        apply()
        return webView
    }

    func updateNSView(_ v: WKWebView, context: Context) { apply() }

    private func apply() {
        if abs(webView.pageZoom - zoom) > 0.005 { webView.pageZoom = zoom }
    }
}

/// The window's right column while the web panel is open (nothing otherwise).
struct WebPanelSlot: View {
    @ObservedObject var ws: WorkspaceModel
    @ObservedObject private var extras = WSExtras.shared

    var body: some View {
        if extras.panelOpen, let b = ws.currentBrowser {
            // Each workspace has its own panel; on a switch the old one fades out, the new one in.
            ZStack {
                WebPanelView(ws: ws, browser: b)
                    .id(ws.profileId ?? "_")
                    .transition(.opacity)
            }
            .animation(.easeInOut(duration: 0.22), value: ws.profileId)
            .transition(.move(edge: .trailing).combined(with: .opacity))
        }
    }
}

// The agents' messenger (the side panel's first, fixed page): `AgentsMiniMessenger` in PanelMessenger.swift.
