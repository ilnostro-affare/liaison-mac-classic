import SwiftUI
import WebKit
import AppKit

// A private window. Its own tabs on one non-persistent data store (nothing is written to disk and
// everything is gone when the window closes), no history recorded (HistoryStore is never called), and no agents:
// none of the workspace's models, scripts or browser context reach it. Dark glass, "Private" in the bar.

/// The window's tabs: plain WKWebViews sharing one `WKWebsiteDataStore.nonPersistent`.
@MainActor
final class PrivateBrowser: ObservableObject {
    @Published private(set) var tabs: [PrivateTab] = []
    @Published var selectedID: UUID?
    private let store = WKWebsiteDataStore.nonPersistent()
    /// The last tab was closed: the window closes with it, as in Safari (closing it did nothing).
    var onLastClosed: (() -> Void)?

    init() { newTab(url: nil) }

    var selected: PrivateTab? { tabs.first { $0.id == selectedID } ?? tabs.first }

    private func configuration() -> WKWebViewConfiguration {
        let c = WKWebViewConfiguration()
        c.websiteDataStore = store
        c.preferences.isElementFullscreenEnabled = true
        c.defaultWebpagePreferences.allowsContentJavaScript = true
        return c
    }

    @discardableResult
    func newTab(url: URL?) -> PrivateTab {
        let t = PrivateTab(configuration: configuration(), owner: self)
        if let sel = selectedID, let i = tabs.firstIndex(where: { $0.id == sel }) { tabs.insert(t, at: i + 1) } else { tabs.append(t) }
        selectedID = t.id
        if let url { t.load(url) }
        return t
    }

    func close(_ t: PrivateTab) {
        guard let i = tabs.firstIndex(where: { $0.id == t.id }) else { return }
        t.tearDown()
        tabs.remove(at: i)
        if tabs.isEmpty {
            if let done = onLastClosed { done() } else { newTab(url: nil) }
        } else if selectedID == t.id { selectedID = tabs[min(i, tabs.count - 1)].id }
    }

    /// The window closed: every page stops (no sound left playing from a web view WebKit still holds).
    func shutDown() { for t in tabs { t.tearDown() } }
}

@MainActor
final class PrivateTab: NSObject, ObservableObject, Identifiable, WKNavigationDelegate, WKUIDelegate {
    let id = UUID()
    let webView: WKWebView
    @Published private(set) var title = ""
    @Published private(set) var url: URL?
    @Published private(set) var canGoBack = false
    @Published private(set) var canGoForward = false
    @Published private(set) var isLoading = false
    @Published private(set) var progress: Double = 0
    private weak var owner: PrivateBrowser?
    private var observers: [NSKeyValueObservation] = []

    init(configuration: WKWebViewConfiguration, owner: PrivateBrowser) {
        configuration.preferences.setValue(true, forKey: "developerExtrasEnabled")   // Inspect Element
        webView = PrivateWebView(frame: .zero, configuration: configuration)
        webView.isInspectable = true
        self.owner = owner
        super.init()
        webView.customUserAgent = BrowserModel.userAgent
        webView.navigationDelegate = self
        webView.uiDelegate = self
        webView.allowsBackForwardNavigationGestures = true
        webView.allowsMagnification = true
        observe()
    }

    var isBlank: Bool { url == nil }
    var displayTitle: String {
        if !title.isEmpty { return title }
        return url?.host ?? "New Private Tab"
    }

    private func observe() {
        observers = [
            webView.observe(\.title, options: [.new]) { [weak self] v, _ in
                let t = v.title ?? ""
                DispatchQueue.main.async { self?.title = t }
            },
            webView.observe(\.url, options: [.new]) { [weak self] v, _ in
                let u = v.url
                DispatchQueue.main.async { self?.url = u }
            },
            webView.observe(\.canGoBack, options: [.new]) { [weak self] v, _ in
                let b = v.canGoBack
                DispatchQueue.main.async { self?.canGoBack = b }
            },
            webView.observe(\.canGoForward, options: [.new]) { [weak self] v, _ in
                let f = v.canGoForward
                DispatchQueue.main.async { self?.canGoForward = f }
            },
            webView.observe(\.isLoading, options: [.new]) { [weak self] v, _ in
                let l = v.isLoading
                DispatchQueue.main.async { self?.isLoading = l }
            },
            webView.observe(\.estimatedProgress, options: [.new]) { [weak self] v, _ in
                let p = v.estimatedProgress
                DispatchQueue.main.async { self?.progress = p }
            },
        ]
    }

    func load(_ u: URL) { webView.load(URLRequest(url: u)) }

    func tearDown() {
        observers = []
        webView.stopLoading()
        webView.pauseAllMediaPlayback(completionHandler: nil)
        webView.navigationDelegate = nil
        webView.uiDelegate = nil
    }

    /// window.outerWidth/outerHeight: the real window, never 0x0 (PageWindowFrame.swift).
    @objc(_webView:getWindowFrameWithCompletionHandler:)
    func webViewGetWindowFrame(_ webView: WKWebView, completionHandler: @escaping (CGRect) -> Void) {
        completionHandler(PageWindowFrame.of(webView))
    }

    // A link asking for a new window opens as a new private tab (same data store). A sized pop-up (a sign-in)
    // opens in a window of ours over the app with WebKit's configuration: the private store, and its opener.
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        if WebPopupWindow.wantsWindow(windowFeatures) {
            return WebPopupWindow.adopt(configuration: configuration, features: windowFeatures)
        }
        if let u = navigationAction.request.url { owner?.newTab(url: u) }
        return nil
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        // Web pages only: no app links, mailto: or file: from a private window.
        let scheme = navigationAction.request.url?.scheme?.lowercased() ?? ""
        decisionHandler(["http", "https", "about", "blob", "data"].contains(scheme) ? .allow : .cancel)
    }
}

/// The private tab's web view: the page menu of the main window's tabs (DesktopWebView) minus everything that is an
/// agent's or the workspace's. Apple's extras go (PageMenu.isNoise), and translation is ours, on this Mac
/// (PageTranslator with isPrivate, the same one the tab's Translate button drives): "Translate" with text selected,
/// "Translate Page" without, "Show Original" while translated. No Ask Lia, no Dev picker, nothing read for an agent.
final class PrivateWebView: WKWebView {
    override func willOpenMenu(_ menu: NSMenu, with event: NSEvent) {
        super.willOpenMenu(menu, with: event)
        for item in menu.items where PageMenu.isNoise(item) { menu.removeItem(item) }
        // A new window from here opens as a new private tab (PrivateTab.createWebViewWith).
        if let link = menu.items.first(where: { $0.identifier?.rawValue == "WKMenuItemIdentifierOpenLinkInNewWindow" }) {
            link.title = "Open Link in New Tab"
        }
        PageMenu.addTranslateItems(to: menu, webView: self, target: self,
                                   page: #selector(translatePage(_:)), selection: #selector(translateSelection(_:)))
        if let inspect = menu.items.first(where: { $0.identifier?.rawValue == "WKMenuItemIdentifierInspectElement" }) {
            menu.removeItem(inspect)
            menu.addItem(.separator())
            menu.addItem(inspect)
        }
        PageMenu.tidySeparators(menu)
    }

    @objc private func translatePage(_ sender: Any?) {
        Task { @MainActor in PageTranslateCenter.shared.model(for: self, isPrivate: true).toggle() }
    }

    @objc private func translateSelection(_ sender: Any?) {
        Task { @MainActor in PageTranslateCenter.shared.model(for: self, isPrivate: true).translateSelection() }
    }
}

extension PageMenu {
    /// The translation items after a separator, on a web page only (PageMenu.translateTitles). Shared by any page
    /// menu that wants them; the actions are the caller's.
    @MainActor
    static func addTranslateItems(to menu: NSMenu, webView: WKWebView, target: AnyObject, page: Selector, selection: Selector) {
        guard isWebPage(webView.url) else { return }
        let hasSelection = menu.items.contains { $0.identifier?.rawValue == "WKMenuItemIdentifierCopy" }
        let on = PageTranslateCenter.shared.existing(webView)?.phase.isActive ?? false
        menu.addItem(.separator())
        for t in translateTitles(hasSelection: hasSelection, translated: on) {
            let item = NSMenuItem(title: t, action: t == translateSelectionTitle ? selection : page, keyEquivalent: "")
            item.target = target
            menu.addItem(item)
        }
    }
}

// MARK: - the window

/// The private window's content (the scene owner shows it in its own WindowGroup, \u{2318}\u{21E7}N).
struct PrivateBrowserWindow: View {
    @StateObject private var browser = PrivateBrowser()
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            PrivateTopBar(browser: browser)
            PrivateStage(browser: browser)
                .padding([.horizontal, .bottom], 10)
        }
        .frame(minWidth: 720, minHeight: 480)
        .background(PrivateTheme.ground)
        .environment(\.colorScheme, .dark)
        .onAppear { browser.onLastClosed = { dismiss() } }
        .onDisappear { browser.shutDown() }
        .navigationTitle("Private")
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text("Private window"))
    }
}

enum PrivateTheme {
    static let ground = Color(red: 0.10, green: 0.10, blue: 0.13)
    static let ink = Color.white
    static let text2 = Color.white.opacity(0.68)
    static let text3 = Color.white.opacity(0.45)
    static let chip = Color.white.opacity(0.10)
    static let line = Color.white.opacity(0.14)
}

private struct PrivateTopBar: View {
    @ObservedObject var browser: PrivateBrowser

    var body: some View {
        VStack(spacing: 8) {
            HStack(spacing: 8) {
                PrivateBadge()
                PrivateTabStrip(browser: browser)
                Button { browser.newTab(url: nil) } label: {
                    Image(systemName: "plus").font(.system(size: 12, weight: .semibold)).foregroundStyle(PrivateTheme.text2)
                        .frame(width: 30, height: 30)
                }
                .buttonStyle(.liaPlain)
                .liaHover(.icon, radius: 10)
                .accessibilityLabel(Text("New private tab"))
            }
            if let t = browser.selected { PrivateNavRow(tab: t).id(t.id) }
        }
        .padding(8)
        .wsGlass(16)
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
    }
}

/// "Private" with its symbol, and the rule said once: no agents here.
private struct PrivateBadge: View {
    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "eye.slash.fill").font(.system(size: 11, weight: .semibold))
            Text("Private").font(LiaFont.ui(12.5, .semibold))
        }
        .foregroundStyle(PrivateTheme.ink)
        .padding(.horizontal, 10)
        .frame(height: 28)
        .background(Color.white.opacity(0.14), in: Capsule())
        .liaTip("Private: no history, no cookies kept")
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text("Private window. No history is saved, and cookies are cleared when it closes."))
    }
}

private struct PrivateTabStrip: View {
    @ObservedObject var browser: PrivateBrowser

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 4) {
                ForEach(Array(browser.tabs.enumerated()), id: \.element.id) { i, t in
                    PrivateTabChip(tab: t, selected: t.id == browser.selected?.id, index: i, count: browser.tabs.count,
                                   select: { browser.selectedID = t.id }, close: { browser.close(t) })
                }
            }
        }
        .frame(height: 32)
    }
}

private struct PrivateTabChip: View {
    @ObservedObject var tab: PrivateTab
    let selected: Bool
    let index: Int
    let count: Int
    let select: () -> Void
    let close: () -> Void
    @State private var hover = false

    var body: some View {
        HStack(spacing: 6) {
            Text(tab.displayTitle).font(LiaFont.ui(12.5, selected ? .medium : .regular))
                .foregroundStyle(selected ? PrivateTheme.ink : PrivateTheme.text2).lineLimit(1)
            if hover || selected {
                Button(action: close) {
                    Image(systemName: "xmark").font(.system(size: 8.5, weight: .bold)).foregroundStyle(PrivateTheme.text3)
                        .frame(width: 16, height: 16)
                }
                .buttonStyle(.liaPlain)
                .liaHover(.icon, radius: 5)
                .accessibilityHidden(true)
            }
        }
        .padding(.horizontal, 10)
        .frame(height: 30)
        .frame(maxWidth: 200)
        .background(selected ? Color.white.opacity(0.16) : (hover ? PrivateTheme.chip : Color.clear),
                    in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .onHover { hover = $0 }
        .onTapGesture(perform: select)
        .background(WSMouseZone(kind: .middle, action: close))
        .liaPointer()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("Private tab \(index + 1) of \(count), \(tab.displayTitle)"))
        .accessibilityAddTraits(.isButton)
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityAction { select() }
        .accessibilityAction(named: Text("Close tab"), close)
    }
}

/// Back, Forward, Reload, the address field and the agents-off note.
private struct PrivateNavRow: View {
    @ObservedObject var tab: PrivateTab
    @State private var text = ""
    @FocusState private var focused: Bool
    @State private var reloadedAt: Date?
    private var showsStop: Bool { ReloadButton.showsStop(loading: tab.isLoading, sinceReload: reloadedAt.map { Date().timeIntervalSince($0) }) }

    var body: some View {
        HStack(spacing: 4) {
            navButton("chevron.left", "Back", enabled: tab.canGoBack) { tab.webView.goBack() }
            navButton("chevron.right", "Forward", enabled: tab.canGoForward) { tab.webView.goForward() }
            // A quick second click reloads again instead of hitting Stop (ReloadButton).
            navButton(showsStop ? "xmark" : "arrow.clockwise", showsStop ? "Stop loading" : "Reload", enabled: !tab.isBlank) {
                switch ReloadButton.action(loading: tab.isLoading, sinceReload: reloadedAt.map { Date().timeIntervalSince($0) }) {
                case .stop: tab.webView.stopLoading(); reloadedAt = nil
                case .reload:
                    if tab.webView.reload() == nil, let u = tab.webView.url ?? tab.url { tab.load(u) }
                    reloadedAt = Date()
                    let mark = reloadedAt
                    DispatchQueue.main.asyncAfter(deadline: .now() + ReloadButton.grace + 0.05) { if reloadedAt == mark { reloadedAt = nil } }
                }
            }
            address
            if !tab.isBlank { TranslatePageButton(webView: tab.webView, isPrivate: true, onDark: true) }
            agentsOff
        }
        .onAppear {
            text = tab.url?.absoluteString ?? ""
            if tab.isBlank { DispatchQueue.main.async { focused = true } }
        }
        .onChange(of: tab.url) { _, u in if !focused { text = u?.absoluteString ?? "" } }
    }

    private var address: some View {
        HStack(spacing: 6) {
            Image(systemName: tab.url?.scheme?.lowercased() == "http" ? "exclamationmark.triangle.fill" : "magnifyingglass")
                .font(.system(size: 11)).foregroundStyle(PrivateTheme.text3)
                .accessibilityHidden(true)
            TextField("Search or enter address", text: $text)
                .textFieldStyle(.plain)
                .font(LiaFont.ui(13))
                .foregroundStyle(PrivateTheme.ink)
                .focused($focused)
                .onSubmit(go)
                .onExitCommand { text = tab.url?.absoluteString ?? ""; focused = false }
                .accessibilityLabel(Text("Address and search"))
        }
        .padding(.horizontal, 10)
        .frame(height: 30)
        .background(PrivateTheme.chip, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(alignment: .bottom) { PrivateProgress(tab: tab) }
    }

    private var agentsOff: some View {
        HStack(spacing: 5) {
            Image(systemName: "person.crop.circle.badge.xmark").font(.system(size: 11))
            Text("Agents are off in private windows").font(LiaFont.ui(11.5))
        }
        .foregroundStyle(PrivateTheme.text3)
        .padding(.leading, 8)
        .fixedSize()
        .accessibilityElement(children: .combine)
    }

    private func navButton(_ symbol: String, _ label: String, enabled: Bool, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 12, weight: .semibold)).foregroundStyle(PrivateTheme.text2)
                .frame(width: 28, height: 28)
        }
        .buttonStyle(.liaPlain)
        .liaHover(.icon, radius: 9)
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.4)
        .accessibilityLabel(Text(label))
    }

    private func go() {
        guard let u = BrowserModel.resolve(text) else { return }
        tab.load(u)
        focused = false
    }
}

private struct PrivateProgress: View {
    @ObservedObject var tab: PrivateTab

    var body: some View {
        GeometryReader { g in
            Rectangle().fill(Color.white.opacity(0.7))
                .frame(width: g.size.width * CGFloat(max(0.06, min(1, tab.progress))), height: 2)
        }
        .frame(height: 2)
        .opacity(tab.isLoading ? 1 : 0)
        .animation(WSMotion.micro, value: tab.isLoading)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// The selected tab's page, or the private start page.
private struct PrivateStage: View {
    @ObservedObject var browser: PrivateBrowser

    var body: some View {
        ZStack {
            PrivateTheme.ground
            if let t = browser.selected { PrivatePage(tab: t).id(t.id) }
        }
        .clipShape(RoundedRectangle(cornerRadius: WS.radius, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: WS.radius, style: .continuous).stroke(PrivateTheme.line, lineWidth: 1))
    }
}

private struct PrivatePage: View {
    @ObservedObject var tab: PrivateTab

    var body: some View {
        ZStack {
            WebViewHost(webView: tab.webView)
            // 0.2.11: translation is on device, so it works here too (nothing remembered about the site).
            if !tab.isBlank { TranslateTabLayer(webView: tab.webView, url: tab.url, isLoading: tab.isLoading, isPrivate: true) }
            if tab.isBlank && !tab.isLoading { PrivateStart() }
        }
    }
}

private struct PrivateStart: View {
    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "eye.slash").font(.system(size: 40, weight: .light)).foregroundStyle(PrivateTheme.text2)
                .accessibilityHidden(true)
            Text("Private browsing").font(LiaFont.ui(22, .semibold)).foregroundStyle(PrivateTheme.ink)
                .accessibilityAddTraits(.isHeader)
            Text("Pages you visit here are not added to history, and their cookies and sign-ins are gone when you close this window. Workspaces and agents can't see it.")
                .font(LiaFont.ui(13.5)).foregroundStyle(PrivateTheme.text2)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 440)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(PrivateTheme.ground)
        .accessibilityElement(children: .combine)
    }
}
