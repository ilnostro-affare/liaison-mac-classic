import SwiftUI
import WebKit

/// A link looked at over the page without a new tab (\u{21E7}-click, or "Open in Peek"). A large glass
/// panel inset over the page with its own web view: the workspace's sign-ins (its data store), Safari's agent; links
/// Clicked inside stay inside. "Open as Tab", "Open in \u{25BE}" (another workspace, ), "Open in Split", \u{00D7} or Esc.
/// Links from other apps land here first (Little Arc), so a link from Slack never replaces the work in front.
struct PeekPanel: View {
    @ObservedObject var ws: WorkspaceModel
    let url: URL
    @StateObject private var page = PeekPage()
    @State private var keys = WSKeyMonitor()
    @State private var shown = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            Color.black.opacity(shown ? 0.18 : 0)
                .contentShape(Rectangle())
                .onTapGesture { close() }
                .accessibilityHidden(true)
            panel
                .padding(40)
                .scaleEffect(shown || reduceMotion ? 1 : 0.96)
                .opacity(shown ? 1 : 0)
        }
        .onAppear {
            page.start(url, account: ws.currentBrowser?.account)
            withAnimation(reduceMotion ? WSMotion.micro : WSMotion.spring) { shown = true }
            keys.start { e in
                guard e.keyCode == 53, e.window?.isKeyWindow ?? false,
                      e.modifierFlags.intersection(.deviceIndependentFlagsMask).isEmpty else { return false }
                close()
                return true
            }
        }
        .onDisappear { keys.stop(); page.stop() }
        .onChange(of: url) { _, u in page.start(u, account: ws.currentBrowser?.account) }
    }

    private var panel: some View {
        VStack(spacing: 0) {
            header
            ZStack(alignment: .top) {
                if let w = page.webView {
                    WebViewHost(webView: w).id(ObjectIdentifier(w))
                } else {
                    WS.surface
                }
                PeekProgress(progress: page.progress, loading: page.loading)
            }
            .clipShape(UnevenRoundedRectangle(bottomLeadingRadius: 16, bottomTrailingRadius: 16, style: .continuous))
            .padding([.horizontal, .bottom], 6)
        }
        .wsGlass(WS.radius)
        .shadow(color: Color.black.opacity(0.22), radius: 34, y: 16)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text("Peek"))
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "eye").font(.system(size: 12, weight: .medium)).foregroundStyle(WS.text3)
            VStack(alignment: .leading, spacing: 1) {
                Text(page.title.isEmpty ? (page.url?.host ?? url.host ?? "") : page.title)
                    .font(LiaFont.ui(13, .semibold)).foregroundStyle(WS.ink).lineLimit(1).truncationMode(.tail)
                Text(page.url?.host ?? url.host ?? "")
                    .font(LiaFont.ui(11.5)).foregroundStyle(WS.text3).lineLimit(1)
            }
            Spacer(minLength: 12)
            Button("Open as Tab") { openAsTab() }.buttonStyle(WSButtonStyle(small: true)).liaPointer()
                .accessibilityHint(Text("Opens this page as a tab of \(ws.profile?.name ?? "this workspace")"))
            workspaceMenu
            Button("Open in Split") { openInSplit() }.buttonStyle(WSButtonStyle(small: true)).liaPointer()
            Button { close() } label: {
                Image(systemName: "xmark").font(.system(size: 11, weight: .semibold)).foregroundStyle(WS.text2)
                    .frame(width: 28, height: 28)
                    .background(WS.surface, in: Circle())
                    .overlay(Circle().stroke(WS.line2, lineWidth: 1))
            }
            .buttonStyle(.liaPlain).liaPointer()
            .accessibilityLabel(Text("Close Peek"))
        }
        .padding(.horizontal, 14)
        .frame(height: 50)
    }

    private var current: URL { page.url ?? url }

    /// "Open in \u{25BE}": the page as a tab of another workspace (with that client's sign-ins).
    @ViewBuilder private var workspaceMenu: some View {
        let others = ws.profiles.filter { $0.id != ws.profileId }
        if !others.isEmpty {
            // Our glass dropdown, not the system menu.
            DropdownButton(align: .trailing, radius: 12, highlight: false) {
                HStack(spacing: 5) {
                    Text("Open in").font(LiaFont.ui(12.5, .medium))
                    Image(systemName: "chevron.down").font(.system(size: 8.5, weight: .bold))
                }
                .foregroundStyle(WS.ink)
                .padding(.horizontal, 11)
                .frame(height: 28)
                .background(WS.surface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(WS.line2, lineWidth: 1))
                .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            } menu: {
                DropdownPanelView {
                    ForEach(others) { p in
                        DropdownItem(title: p.name, fontSize: 13) { open(in: p) }
                    }
                }
            }
            .fixedSize()
            .accessibilityLabel(Text("Open in workspace"))
            .accessibilityHint(Text("Choose a workspace to open this page in as a tab"))
        }
    }

    private func open(in p: CompanyProfile) {
        let u = current
        close()
        ws.select(p.id)
        ws.browser(for: p).open(u)
        ws.show("Opened in \(p.name)", symbol: "arrow.right.square")
    }

    private func openAsTab() {
        ws.currentBrowser?.open(current)
        close()
    }

    private func openInSplit() {
        if let b = ws.currentBrowser {
            let cur = b.selected
            let t = b.newTab(url: current, select: false)
            if let cur { b.selectedID = cur.id }
            b.split(with: t)
        }
        close()
    }

    private func close() { ws.peek = nil }
}

/// Where a GitHub chip's page opens - the open messenger's popup (SheetWebPopup, the workspace's
/// cookies) of the workspace in front. The conversation sheet's header attaches while it is on screen.
@MainActor
final class SheetGitHubRoute {
    static let shared = SheetGitHubRoute()
    private var handlers: [ObjectIdentifier: (URL) -> Void] = [:]

    func attach(_ ws: WorkspaceModel, _ handler: @escaping (URL) -> Void) { handlers[ObjectIdentifier(ws)] = handler }
    func detach(_ ws: WorkspaceModel) { handlers[ObjectIdentifier(ws)] = nil }

    /// True when a messenger took the page.
    func open(_ url: URL) -> Bool {
        guard let ws = WorkspaceModel.current, ws.sheet != nil, let h = handlers[ObjectIdentifier(ws)] else { return false }
        h(url)
        return true
    }
}

/// a page in a popup over the messenger, the sheet's own size (the branch chip's GitHub
/// page). Its web view uses the workspace browser's data store (`account`), so the person's GitHub sign-in applies;
/// never the Liaison session, never the main browser window, never the default browser. \u{00D7} or Esc closes.
struct SheetWebPopup: View {
    let url: URL
    let account: String?
    let title: String
    let onOpenAsTab: (URL) -> Void
    let onClose: () -> Void
    @StateObject private var page = PeekPage()
    @State private var keys = WSKeyMonitor()
    @State private var shown = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(spacing: 0) {
            header
            ZStack(alignment: .top) {
                if let w = page.webView {
                    WebViewHost(webView: w).id(ObjectIdentifier(w))
                } else {
                    WS.surface
                }
                PeekProgress(progress: page.progress, loading: page.loading)
            }
            .clipShape(UnevenRoundedRectangle(bottomLeadingRadius: 16, bottomTrailingRadius: 16, style: .continuous))
            .padding([.horizontal, .bottom], 6)
        }
        .wsGlass(WS.radius)
        .clipShape(RoundedRectangle(cornerRadius: WS.radius, style: .continuous))
        .scaleEffect(shown || reduceMotion ? 1 : 0.98)
        .opacity(shown ? 1 : 0)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text("GitHub page"))
        .onAppear {
            page.start(url, account: account)
            withAnimation(reduceMotion ? WSMotion.micro : WSMotion.spring) { shown = true }
            keys.start { e in
                guard e.keyCode == 53, e.window?.isKeyWindow ?? false,
                      e.modifierFlags.intersection(.deviceIndependentFlagsMask).isEmpty else { return false }
                onClose()
                return true
            }
        }
        .onDisappear { keys.stop(); page.stop() }
        .onChange(of: url) { _, u in page.start(u, account: account) }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: symbol).font(.system(size: 12, weight: .semibold)).foregroundStyle(WS.text2)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                Text(verbatim: shownTitle).font(LiaFont.ui(13, .semibold)).foregroundStyle(WS.ink)
                    .lineLimit(1).truncationMode(.middle)
                Text(verbatim: page.title.isEmpty ? (page.url?.host ?? url.host ?? "") : page.title)
                    .font(LiaFont.ui(11.5)).foregroundStyle(WS.text3).lineLimit(1).truncationMode(.tail)
            }
            Spacer(minLength: 12)
            Button("Open as Tab") { onOpenAsTab(page.url ?? url) }
                .buttonStyle(WSButtonStyle(small: true)).liaPointer()
            Button(action: onClose) {
                Image(systemName: "xmark").font(.system(size: 11, weight: .semibold)).foregroundStyle(WS.text2)
                    .frame(width: 28, height: 28)
                    .background(WS.surface, in: Circle())
                    .overlay(Circle().stroke(WS.line2, lineWidth: 1))
            }
            .buttonStyle(.liaPlain).liaPointer()
            .accessibilityLabel(Text("Close"))
        }
        .padding(.horizontal, 14)
        .frame(height: 50)
    }

    /// What the address names on GitHub (a branch, commit, pull request or repository), nil for any other page.
    private var ref: GitHubRef? { GitHubRef.parse(url.absoluteString) ?? GitHubRef.parseRepo(url.absoluteString) }

    private var symbol: String { ref.map { ChipSpec.gitHubSymbol($0.kind) } ?? "globe" }

    /// The ref's words ("dev/x", "Commit 1a2b3c4", "owner/name", "site#12"), else the title the sheet gave.
    private var shownTitle: String {
        guard let r = ref else { return title }
        switch r.kind {
        case .commit: return "Commit " + r.label + " \u{00b7} " + r.repo
        case .branch: return r.label + " \u{00b7} " + r.repo
        case .pr, .repo: return r.label
        }
    }
}

/// The peek's own web view and what the header shows of it.
@MainActor
final class PeekPage: NSObject, ObservableObject, WKNavigationDelegate, WKUIDelegate {
    @Published private(set) var title = ""
    @Published private(set) var url: URL?
    @Published private(set) var progress: Double = 0
    @Published private(set) var loading = false
    @Published private(set) var webView: WKWebView?
    private var account: String?
    private var observers: [NSKeyValueObservation] = []

    func start(_ u: URL, account: String?) {
        if webView == nil || account != self.account { make(account: account) }
        webView?.load(URLRequest(url: u))
    }

    private func make(account: String?) {
        self.account = account
        observers = []
        let w = WKWebView(frame: .zero, configuration: BrowserModel.configuration(account: account))
        w.customUserAgent = BrowserModel.userAgent
        w.navigationDelegate = self
        w.uiDelegate = self
        w.allowsBackForwardNavigationGestures = true
        observers = [
            w.observe(\.title, options: [.new]) { [weak self] v, _ in
                let t = v.title ?? ""
                DispatchQueue.main.async { self?.title = t }
            },
            w.observe(\.url, options: [.new]) { [weak self] v, _ in
                let u = v.url
                DispatchQueue.main.async { if let u { self?.url = u } }
            },
            w.observe(\.estimatedProgress, options: [.new]) { [weak self] v, _ in
                let p = v.estimatedProgress
                DispatchQueue.main.async { self?.progress = p }
            },
            w.observe(\.isLoading, options: [.new]) { [weak self] v, _ in
                let l = v.isLoading
                DispatchQueue.main.async { self?.loading = l }
            },
        ]
        webView = w
    }

    func stop() {
        webView?.stopLoading()
        webView?.navigationDelegate = nil
        webView?.uiDelegate = nil
        observers = []
    }

    /// window.outerWidth/outerHeight: the real window, never 0x0 (PageWindowFrame.swift).
    @objc(_webView:getWindowFrameWithCompletionHandler:)
    func webViewGetWindowFrame(_ webView: WKWebView, completionHandler: @escaping (CGRect) -> Void) {
        completionHandler(PageWindowFrame.of(webView))
    }

    // Navigation stays in the peek: a link asking for a new window loads here instead. A sized pop-up (a sign-in)
    // opens in a window of ours over the app with WebKit's configuration, so it keeps its opener.
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        if WebPopupWindow.wantsWindow(windowFeatures) {
            return WebPopupWindow.adopt(configuration: configuration, features: windowFeatures)
        }
        if let u = navigationAction.request.url { webView.load(URLRequest(url: u)) }
        return nil
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        // Only web pages here: mailto:, app links and file: are not opened from a peek.
        let scheme = navigationAction.request.url?.scheme?.lowercased() ?? ""
        decisionHandler(["http", "https", "about", "blob", "data"].contains(scheme) ? .allow : .cancel)
    }
}

/// A thin bar along the top of the peek's page while it loads.
private struct PeekProgress: View {
    let progress: Double
    let loading: Bool

    var body: some View {
        GeometryReader { g in
            Rectangle().fill(WS.blue)
                .frame(width: g.size.width * CGFloat(max(0.08, min(1, progress))), height: 2)
                .animation(.easeOut(duration: 0.25), value: progress)
        }
        .frame(height: 2)
        .opacity(loading ? 1 : 0)
        .animation(WSMotion.micro, value: loading)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}
