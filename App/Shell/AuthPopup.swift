import SwiftUI
import AppKit
import WebKit

/// Where our pop-up browser windows go ("Connect GitHub" from the workspace settings showed its
/// page under that popup). Every window of this kind (Meta's sign-in, GitHub's, a page's window.open with a size)
/// sits above every other window of ours: the workspace with its in-window popups and sheets, Settings. Only menus
/// and tooltips (.popUpMenu and up) stay above it. It is centred over the workspace window and takes key.
@MainActor
enum PopupPlacement {
    /// Above .normal (the workspace, Settings, their sheets), below the dropdown panels (.popUpMenu).
    static let level: NSWindow.Level = .floating

    /// The workspace window (WindowGroup "main"), else the window in front.
    static func mainWindow(excluding own: NSWindow? = nil) -> NSWindow? {
        let candidates = NSApp.windows.filter { w in w !== own && w.isVisible && !w.isMiniaturized && w.canBecomeMain && !(w is NSPanel) }
        return candidates.first { ($0.identifier?.rawValue ?? "").hasPrefix("main") }
            ?? [NSApp.mainWindow, NSApp.keyWindow].compactMap { $0 }.first { $0 !== own && $0.isVisible && !($0 is NSPanel) }
            ?? candidates.first
    }

    /// Settings (SettingsWindow, identifier "lia-settings") when it is the window in front, or its sheet is (Add
    /// Account): a pop-up opened from Settings is centred over Settings, not over the workspace behind it.
    static func settingsInFront(excluding own: NSWindow? = nil) -> NSWindow? {
        guard let key = NSApp.keyWindow, key !== own else { return nil }
        let w = key.sheetParent ?? key
        guard w !== own, w.isVisible, !w.isMiniaturized, w.identifier?.rawValue == "lia-settings" else { return nil }
        return w
    }

    /// Puts `w` at the pop-up level, over the middle of Settings when Settings is in front (else the workspace
    /// window), key, the app active. The level keeps it above Settings (.normal) and its sheets ("every
    /// popup while Settings is open must be above it").
    static func present(_ w: NSWindow) {
        w.level = level
        // A floating window would stay over other apps: it hides while Liaison is in the background.
        w.hidesOnDeactivate = true
        w.collectionBehavior.insert(.fullScreenAuxiliary)   // over a workspace window in full screen too
        if let m = settingsInFront(excluding: w) ?? mainWindow(excluding: w) {
            var r = w.frame
            r.origin = NSPoint(x: m.frame.midX - r.width / 2, y: m.frame.midY - r.height / 2)
            if let v = (m.screen ?? NSScreen.main)?.visibleFrame {
                r.origin.x = min(max(r.origin.x, v.minX), max(v.minX, v.maxX - r.width))
                r.origin.y = min(max(r.origin.y, v.minY), max(v.minY, v.maxY - r.height))
            }
            w.setFrameOrigin(r.origin)
        } else {
            w.center()
        }
        NSApp.activate(ignoringOtherApps: true)
        w.makeKeyAndOrderFront(nil)
    }
}

/// A small browser window of ours over the app (PopupPlacement): GitHub's install and settings pages, and a page's
/// own pop-up (window.open with a size: Google's or Facebook's sign-in), which keeps its opener so the sign-in
/// completes. Nothing of ours runs in the page: no user scripts, no message handlers (design rule: our scripts never enter the page world).
@MainActor
final class WebPopupWindow: NSObject, WKNavigationDelegate, WKUIDelegate, NSWindowDelegate {
    /// Open pop-ups keep themselves alive until they close.
    private static var open: [WebPopupWindow] = []

    let web: WKWebView
    let window: NSWindow
    /// A page finished loading (the address it is on). Return true to close the window.
    var onLoaded: (@MainActor (URL) -> Bool)?
    /// The window closed, whatever closed it (the person, the page, onLoaded).
    var onClose: (@MainActor () -> Void)?
    /// Every address the window is about to go to, before the scheme rule. Return true: the navigation is cancelled
    /// and the handler took it (the sign-in's liaison://auth/... answer, Stripe sending the window back to our site).
    var intercept: (@MainActor (URL) -> Bool)?
    /// A page's own pop-up (window.open: Memberstack's Google sign-in) opens as a window of ours that keeps its
    /// opener, instead of loading in this window. Off: it loads here, as before (GitHub).
    var keepsPopups = false
    private var titleWatch: NSKeyValueObservation?
    private var closed = false

    /// A window over the app that loads `url` in `configuration` (a fresh one of the browser's data store).
    /// `title`: a fixed title; nil follows the page's.
    @discardableResult
    static func show(_ url: URL, configuration: WKWebViewConfiguration, title: String?,
                     size: NSSize = NSSize(width: 560, height: 720)) -> WebPopupWindow {
        let p = make(configuration: configuration, title: title, size: size)
        p.load(url)
        return p
    }

    /// The window, shown, with nothing loaded yet: the caller sets `intercept` / `keepsPopups` (or fills the data
    /// store) first, then calls `load`.
    static func make(configuration: WKWebViewConfiguration, title: String?,
                     size: NSSize = NSSize(width: 560, height: 720)) -> WebPopupWindow {
        WebPopupWindow(configuration: configuration, title: title, size: size)
    }

    func load(_ url: URL) {
        guard !closed else { return }
        web.load(URLRequest(url: url))
    }

    /// WKUIDelegate createWebViewWith for a page's pop-up: the web view WebKit asked for, in a window of ours over
    /// the app. Must be handed WebKit's own configuration, or the page loses its opener.
    static func adopt(configuration: WKWebViewConfiguration, features: WKWindowFeatures) -> WKWebView {
        WebPopupWindow(configuration: configuration, title: nil, size: popupSize(features)).web
    }

    private static func popupSize(_ features: WKWindowFeatures) -> NSSize {
        var size = NSSize(width: 520, height: 640)
        if let w = features.width?.doubleValue, w > 0 { size.width = min(max(CGFloat(w), 320), 1400) }
        if let h = features.height?.doubleValue, h > 0 { size.height = min(max(CGFloat(h), 240), 1000) }
        return size
    }

    /// A pop-up asked for with a size (window.open(url, name, "width=...,height=...")) opens as a window, as in
    /// Safari; any other new window stays a tab.
    static func wantsWindow(_ features: WKWindowFeatures) -> Bool {
        features.width != nil || features.height != nil
    }

    private init(configuration: WKWebViewConfiguration, title: String?, size: NSSize) {
        let view = WKWebView(frame: NSRect(origin: .zero, size: size), configuration: configuration)
        view.customUserAgent = BrowserModel.userAgent
        web = view
        window = NSWindow(contentRect: NSRect(origin: .zero, size: size),
                          styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
        super.init()
        web.navigationDelegate = self
        web.uiDelegate = self
        window.title = title ?? "Loading\u{2026}"
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.minSize = NSSize(width: 320, height: 240)
        window.contentView = web
        if title == nil {
            titleWatch = web.observe(\.title, options: [.new]) { [weak self] v, _ in
                let t = v.title ?? ""
                DispatchQueue.main.async { if let self, !t.isEmpty { self.window.title = t } }
            }
        }
        Self.open.append(self)
        PopupPlacement.present(window)
    }

    func close() {
        guard !closed else { return }
        window.close()   // windowWillClose tidies up
    }

    /// Brings it back in front (a second click on the same Connect).
    func front() {
        if window.isMiniaturized { window.deminiaturize(nil) }
        PopupPlacement.present(window)
    }

    // MARK: - WKNavigationDelegate

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        if let u = navigationAction.request.url, let take = intercept, take(u) {
            decisionHandler(.cancel)
            return
        }
        // Web pages only: no app links, mailto: or file: from a pop-up.
        let scheme = navigationAction.request.url?.scheme?.lowercased() ?? ""
        decisionHandler(["http", "https", "about", "blob", "data"].contains(scheme) ? .allow : .cancel)
    }

    /// A server redirect to an address WebKit cannot load (liaison://...) can fail here without a policy question.
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        let ns = error as NSError
        let failing = (ns.userInfo[NSURLErrorFailingURLErrorKey] as? URL)
            ?? (ns.userInfo[NSURLErrorFailingURLStringErrorKey] as? String).flatMap(URL.init(string:))
        if let u = failing, let take = intercept { _ = take(u) }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard let u = webView.url, let check = onLoaded else { return }
        if check(u) { close() }
    }

    // MARK: - WKUIDelegate

    /// A pop-up of the pop-up loads in the same window.
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        if keepsPopups, navigationAction.targetFrame == nil {
            // WebKit's own configuration, so the page keeps its opener; the child window intercepts the same answers.
            let child = WebPopupWindow(configuration: configuration, title: nil, size: Self.popupSize(windowFeatures))
            child.intercept = intercept
            return child.web
        }
        if navigationAction.targetFrame == nil { webView.load(navigationAction.request) }
        return nil
    }

    /// The page closed itself (window.close after a sign-in answered its opener).
    func webViewDidClose(_ webView: WKWebView) { close() }

    // MARK: - NSWindowDelegate

    func windowWillClose(_ notification: Notification) {
        guard !closed else { return }
        closed = true
        titleWatch = nil
        web.stopLoading()
        web.navigationDelegate = nil
        web.uiDelegate = nil
        let done = onClose
        onClose = nil
        onLoaded = nil
        intercept = nil
        Self.open.removeAll { $0 === self }
        done?()
    }
}

/// A web page in a pop-up window of ours (WebPopupWindow, PopupPlacement: above Settings and its sheets) on the
/// workspace's browser profile, so the person's sign-ins there (Claude, ChatGPT, Stripe's Link) are the same
/// Used for what Settings opens: Stripe's checkout and portal, an invoice, MCP's connector pages.
/// `isReturn`: the address that ends the round (cancelled, never loaded); the window closes there.
@MainActor
enum PopupBrowser {
    @discardableResult
    static func open(_ url: URL, auth: AuthStore, title: String? = nil, size: NSSize = NSSize(width: 1000, height: 760),
                     isReturn: ((URL) -> Bool)? = nil, onClose: (@MainActor () -> Void)? = nil) -> WebPopupWindow {
        let key = MetaConnect.storeKey(auth: auth, ws: WorkspaceModel.current)
        let p = WebPopupWindow.make(configuration: BrowserModel.configuration(account: key), title: title, size: size)
        if let isReturn {
            p.intercept = { [weak p] u in
                guard isReturn(u) else { return false }
                // not inside WebKit's policy question: the window closes after it is answered
                DispatchQueue.main.async { p?.close() }
                return true
            }
        }
        p.onClose = onClose
        p.load(url)
        return p
    }
}
