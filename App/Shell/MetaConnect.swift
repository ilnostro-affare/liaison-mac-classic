import SwiftUI
import AppKit
import WebKit

/// Connect Meta inside the app ("Connect Meta does nothing visible"). Meta's OAuth runs in a small
/// window over the app (PopupPlacement: above our popups, Settings and sheets), in a WKWebView on
/// the workspace's OWN data store: Facebook cookies imported or shared (SharedSignIns) sign the person in at once;
/// otherwise they sign in here, and that sign-in stays in the workspace. The window closes when the callback sends
/// the browser back to our site (that page is never loaded: the Liaison session never enters a browser store), then
/// Meta's state and the workspaces are read again.
/// Nothing of ours runs in the page: no user scripts, no message handlers (design rule: our scripts never enter the page world).
@MainActor
final class MetaConnect: NSObject, WKNavigationDelegate, WKUIDelegate, NSWindowDelegate {
    private static var current: MetaConnect?

    private let web: WKWebView
    private let window: NSWindow
    private weak var ws: WorkspaceModel?
    private let onDone: (Bool) -> Void
    private var done = false

    /// Opens the window (or brings back the one already open). `onDone(true)`: Meta answered connected.
    static func open(auth: AuthStore, ws wsIn: WorkspaceModel? = nil, onDone: @escaping (Bool) -> Void = { _ in }) {
        let ws = wsIn ?? WorkspaceModel.current   // a default argument is evaluated outside the main actor
        if let c = current {
            if c.window.isMiniaturized { c.window.deminiaturize(nil) }
            PopupPlacement.present(c.window)
            return
        }
        guard let url = LiaAPI(auth: auth).metaConnectURL else {
            ws?.show("Sign in to Liaison first")
            return
        }
        let c = MetaConnect(store: BrowserModel.dataStore(for: storeKey(auth: auth, ws: ws)), ws: ws, onDone: onDone)
        current = c
        c.present()
        c.web.load(URLRequest(url: url))
    }

    /// The workspace in front, else the account's first workspace store, else the account's own store (same
    /// shared sign-in group either way).
    static func storeKey(auth: AuthStore, ws: WorkspaceModel?) -> String {
        let acct = auth.activeId
        if let ws, let p = ws.profile ?? ws.profiles.first { return CompanyProfile.browserKey(account: acct, profile: p.id) }
        let group = acct ?? "_none"
        let known = (UserDefaults.standard.dictionary(forKey: "lia_browser_store_ids") as? [String: String] ?? [:]).keys
        if let k = known.filter({ $0.contains("|p:") && SharedSignIns.group(of: $0) == group }).sorted().first { return k }
        return group
    }

    private init(store: WKWebsiteDataStore, ws: WorkspaceModel?, onDone: @escaping (Bool) -> Void) {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = store
        config.defaultWebpagePreferences.allowsContentJavaScript = true
        let view = WKWebView(frame: NSRect(x: 0, y: 0, width: 520, height: 640), configuration: config)
        view.customUserAgent = BrowserModel.userAgent
        web = view
        self.ws = ws
        self.onDone = onDone
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 520, height: 700),
                          styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        super.init()
        web.navigationDelegate = self
        web.uiDelegate = self
        window.title = "Connect Meta"
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.minSize = NSSize(width: 420, height: 520)
        window.contentViewController = NSHostingController(rootView: MetaConnectSheet(web: web) { [weak self] in self?.finish(false, quiet: true) })
    }

    /// Never a sheet: a sheet sits on its parent, under a window of ours in front of it (Settings), and on the
    /// workspace its parent may be behind Settings. A window over the app, centred on the workspace, key.
    private func present() {
        PopupPlacement.present(window)
    }

    /// Closes the window once, then reads Meta again. `quiet`: the person cancelled, no toast.
    private func finish(_ ok: Bool, quiet: Bool = false) {
        guard !done else { return }
        done = true
        web.stopLoading()
        window.close()
        Self.current = nil
        let ws = self.ws, onDone = self.onDone
        Task { @MainActor in
            if let ws {
                let was = ws.metaLive
                await ws.refreshMeta()
                // refreshMeta makes the workspaces itself when Meta went from off to on.
                if was != false, ws.metaLive == true { await ws.reloadAccounts() }
                if !ok, !quiet { ws.show("Meta did not connect") }
            }
            onDone(ok)
        }
    }

    /// Our site after the callback: connected (or an error page of ours). Never loaded here.
    static func isReturn(_ url: URL) -> Bool {
        guard let host = url.host?.lowercased() else { return false }
        let site = URL(string: AppConfig.siteBase)?.host ?? "liaisone.com"
        return host == site || host == "www." + site
    }

    // MARK: - WKNavigationDelegate

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        guard let url = navigationAction.request.url else { decisionHandler(.allow); return }
        if Self.isReturn(url) {
            decisionHandler(.cancel)
            let q = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
            let failed = q.contains { $0.name == "error" || ($0.name == "connected" && $0.value != "meta") }
            finish(!failed)
            return
        }
        decisionHandler(.allow)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        // The callback answered with its own error (the person said No to Meta, a missing code): nothing to wait for.
        if let u = webView.url, u.host == URL(string: AppConfig.apiBase)?.host, u.path.hasSuffix("/meta/oauth/callback") {
            finish(false)
        }
    }

    // MARK: - WKUIDelegate

    /// Meta's pop-ups (two-factor, "Continue as") open in the same view.
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        if navigationAction.targetFrame == nil { webView.load(navigationAction.request) }
        return nil
    }

    // MARK: - NSWindowDelegate

    func windowWillClose(_ notification: Notification) {
        if !done { done = true; Self.current = nil; onDone(false) }
    }
}

/// The window's content: a short bar (title, Cancel) over Meta's page.
private struct MetaConnectSheet: View {
    let web: WKWebView
    let cancel: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Connect Meta").font(LiaFont.ui(13, .semibold)).foregroundStyle(WS.ink)
                Spacer()
                Button("Cancel", action: cancel).keyboardShortcut(.cancelAction)
            }
            .padding(.horizontal, 14).frame(height: 40)
            Rectangle().fill(WS.line).frame(height: 1)
            MetaConnectWeb(web: web)
        }
        .frame(minWidth: 420, idealWidth: 520, minHeight: 520, idealHeight: 700)
    }
}

private struct MetaConnectWeb: NSViewRepresentable {
    let web: WKWebView
    func makeNSView(context: Context) -> WKWebView { web }
    func updateNSView(_ nsView: WKWebView, context: Context) {}
}
