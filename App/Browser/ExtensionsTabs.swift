import SwiftUI
import WebKit
import Combine

// Our browser as extensions see it: each BrowserModel is a WKWebExtensionWindow, each BrowserTab a
// WKWebExtensionTab. Every protocol method is optional (WKWebExtensionTab.h / WKWebExtensionWindow.h, `@optional`);
// only the ones a password manager uses are here. The tracker tells the controller about tab events of the browser
// the tab group shows (opened, closed, activated, URL / title / loading changed), re-following it when the workspace
// changes.

#if compiler(>=6.1)

@available(macOS 15.4, *)
@MainActor
final class ExtWindow: NSObject, WKWebExtensionWindow {
    weak var browser: BrowserModel?
    private unowned let tracker: ExtTabTracker

    init(browser: BrowserModel, tracker: ExtTabTracker) {
        self.browser = browser
        self.tracker = tracker
        super.init()
    }

    // https://developer.apple.com/documentation/webkit/wkwebextensionwindow/tabs(for:)
    @objc(tabsForWebExtensionContext:)
    func tabs(for context: WKWebExtensionContext) -> [any WKWebExtensionTab] {
        guard let b = browser else { return [] }
        return b.tabs.map { tracker.tab(for: $0, in: b) }
    }

    // https://developer.apple.com/documentation/webkit/wkwebextensionwindow/activetab(for:)
    @objc(activeTabForWebExtensionContext:)
    func activeTab(for context: WKWebExtensionContext) -> (any WKWebExtensionTab)? {
        guard let b = browser, let t = b.selected else { return nil }
        return tracker.tab(for: t, in: b)
    }

    // https://developer.apple.com/documentation/webkit/wkwebextensionwindow/windowtype(for:)
    @objc(windowTypeForWebExtensionContext:)
    func windowType(for context: WKWebExtensionContext) -> WKWebExtension.WindowType { .normal }

    // https://developer.apple.com/documentation/webkit/wkwebextensionwindow/windowstate(for:)
    @objc(windowStateForWebExtensionContext:)
    func windowState(for context: WKWebExtensionContext) -> WKWebExtension.WindowState { .normal }

    // https://developer.apple.com/documentation/webkit/wkwebextensionwindow/isprivate(for:)
    @objc(isPrivateForWebExtensionContext:)
    func isPrivate(for context: WKWebExtensionContext) -> Bool { false }

    // https://developer.apple.com/documentation/webkit/wkwebextensionwindow/focus(for:completionhandler:)
    @objc(focusForWebExtensionContext:completionHandler:)
    func focus(for context: WKWebExtensionContext, completionHandler: @escaping ((any Error)?) -> Void) {
        NSApp.activate(ignoringOtherApps: true)
        completionHandler(nil)
    }
}

@available(macOS 15.4, *)
@MainActor
final class ExtTab: NSObject, WKWebExtensionTab {
    weak var tab: BrowserTab?
    weak var browser: BrowserModel?
    private unowned let tracker: ExtTabTracker

    init(tab: BrowserTab, browser: BrowserModel, tracker: ExtTabTracker) {
        self.tab = tab
        self.browser = browser
        self.tracker = tracker
        super.init()
    }

    private static let gone = ExtensionsInstaller.Failure("The tab is closed.")

    // https://developer.apple.com/documentation/webkit/wkwebextensiontab/window(for:)
    @objc(windowForWebExtensionContext:)
    func window(for context: WKWebExtensionContext) -> (any WKWebExtensionWindow)? {
        browser.map { tracker.window(for: $0) }
    }

    // https://developer.apple.com/documentation/webkit/wkwebextensiontab/indexinwindow(for:)
    @objc(indexInWindowForWebExtensionContext:)
    func indexInWindow(for context: WKWebExtensionContext) -> Int {
        guard let t = tab, let i = browser?.tabs.firstIndex(where: { $0.id == t.id }) else { return 0 }
        return i
    }

    // https://developer.apple.com/documentation/webkit/wkwebextensiontab/webview(for:)
    @objc(webViewForWebExtensionContext:)
    func webView(for context: WKWebExtensionContext) -> WKWebView? { tab?.loadedWebView }

    // https://developer.apple.com/documentation/webkit/wkwebextensiontab/title(for:)
    @objc(titleForWebExtensionContext:)
    func title(for context: WKWebExtensionContext) -> String? { tab?.displayTitle }

    // https://developer.apple.com/documentation/webkit/wkwebextensiontab/url(for:)
    @objc(urlForWebExtensionContext:)
    func url(for context: WKWebExtensionContext) -> URL? { tab?.url ?? tab?.savedURL }

    // https://developer.apple.com/documentation/webkit/wkwebextensiontab/isloadingcomplete(for:)
    @objc(isLoadingCompleteForWebExtensionContext:)
    func isLoadingComplete(for context: WKWebExtensionContext) -> Bool { !(tab?.isLoading ?? false) }

    // https://developer.apple.com/documentation/webkit/wkwebextensiontab/isselected(for:)
    @objc(isSelectedForWebExtensionContext:)
    func isSelected(for context: WKWebExtensionContext) -> Bool {
        guard let t = tab else { return false }
        return browser?.selectedID == t.id
    }

    // https://developer.apple.com/documentation/webkit/wkwebextensiontab/ispinned(for:)
    @objc(isPinnedForWebExtensionContext:)
    func isPinned(for context: WKWebExtensionContext) -> Bool { tab?.pinned ?? false }

    // https://developer.apple.com/documentation/webkit/wkwebextensiontab/ismuted(for:)
    @objc(isMutedForWebExtensionContext:)
    func isMuted(for context: WKWebExtensionContext) -> Bool { tab?.muted ?? false }

    // https://developer.apple.com/documentation/webkit/wkwebextensiontab/setmuted(_:for:completionhandler:)
    @objc(setMuted:forWebExtensionContext:completionHandler:)
    func setMuted(_ muted: Bool, for context: WKWebExtensionContext, completionHandler: @escaping ((any Error)?) -> Void) {
        guard let t = tab else { completionHandler(Self.gone); return }
        t.setMuted(muted)
        completionHandler(nil)
    }

    // https://developer.apple.com/documentation/webkit/wkwebextensiontab/isplayingaudio(for:)
    @objc(isPlayingAudioForWebExtensionContext:)
    func isPlayingAudio(for context: WKWebExtensionContext) -> Bool { tab?.playing ?? false }

    // https://developer.apple.com/documentation/webkit/wkwebextensiontab/size(for:)
    @objc(sizeForWebExtensionContext:)
    func size(for context: WKWebExtensionContext) -> CGSize { tab?.loadedWebView?.bounds.size ?? .zero }

    // https://developer.apple.com/documentation/webkit/wkwebextensiontab/zoomfactor(for:)
    @objc(zoomFactorForWebExtensionContext:)
    func zoomFactor(for context: WKWebExtensionContext) -> Double { Double(tab?.loadedWebView?.pageZoom ?? 1) }

    // https://developer.apple.com/documentation/webkit/wkwebextensiontab/loadurl(_:for:completionhandler:)
    @objc(loadURL:forWebExtensionContext:completionHandler:)
    func loadURL(_ url: URL, for context: WKWebExtensionContext, completionHandler: @escaping ((any Error)?) -> Void) {
        guard let t = tab else { completionHandler(Self.gone); return }
        t.load(url)
        completionHandler(nil)
    }

    // https://developer.apple.com/documentation/webkit/wkwebextensiontab/reload(fromorigin:for:completionhandler:)
    @objc(reloadFromOrigin:forWebExtensionContext:completionHandler:)
    func reload(fromOrigin: Bool, for context: WKWebExtensionContext, completionHandler: @escaping ((any Error)?) -> Void) {
        guard let t = tab else { completionHandler(Self.gone); return }
        t.reload(fromOrigin: fromOrigin)
        completionHandler(nil)
    }

    // https://developer.apple.com/documentation/webkit/wkwebextensiontab/goback(for:completionhandler:)
    @objc(goBackForWebExtensionContext:completionHandler:)
    func goBack(for context: WKWebExtensionContext, completionHandler: @escaping ((any Error)?) -> Void) {
        tab?.loadedWebView?.goBack()
        completionHandler(nil)
    }

    // https://developer.apple.com/documentation/webkit/wkwebextensiontab/goforward(for:completionhandler:)
    @objc(goForwardForWebExtensionContext:completionHandler:)
    func goForward(for context: WKWebExtensionContext, completionHandler: @escaping ((any Error)?) -> Void) {
        tab?.loadedWebView?.goForward()
        completionHandler(nil)
    }

    // https://developer.apple.com/documentation/webkit/wkwebextensiontab/activate(for:completionhandler:)
    @objc(activateForWebExtensionContext:completionHandler:)
    func activate(for context: WKWebExtensionContext, completionHandler: @escaping ((any Error)?) -> Void) {
        guard let t = tab, let b = browser else { completionHandler(Self.gone); return }
        b.selectedID = t.id
        completionHandler(nil)
    }

    // https://developer.apple.com/documentation/webkit/wkwebextensiontab/close(for:completionhandler:)
    @objc(closeForWebExtensionContext:completionHandler:)
    func close(for context: WKWebExtensionContext, completionHandler: @escaping ((any Error)?) -> Void) {
        guard let t = tab, let b = browser else { completionHandler(Self.gone); return }
        b.close(t)
        completionHandler(nil)
    }

    /// A click on the extension's button counts as consent for the page in front (activeTab).
    // https://developer.apple.com/documentation/webkit/wkwebextensiontab/shouldgrantpermissionsonusergesture(for:)
    @objc(shouldGrantPermissionsOnUserGestureForWebExtensionContext:)
    func shouldGrantPermissionsOnUserGesture(for context: WKWebExtensionContext) -> Bool { true }
}

/// Keeps one adapter per tab and per browser (WebKit tells them apart by identity) and forwards tab events.
@available(macOS 15.4, *)
@MainActor
final class ExtTabTracker {
    private let controller: WKWebExtensionController
    private var tabsByID: [UUID: ExtTab] = [:]
    private var windows: [ObjectIdentifier: ExtWindow] = [:]
    private weak var followed: BrowserModel?
    private weak var workspace: WorkspaceModel?
    private var browserSubs: Set<AnyCancellable> = []
    private var tabSubs: [UUID: AnyCancellable] = [:]
    private var wsSub: AnyCancellable?
    private var known: [UUID] = []
    private var activeID: UUID?

    init(controller: WKWebExtensionController) {
        self.controller = controller
    }

    var currentBrowser: BrowserModel? { followed ?? WorkspaceModel.current?.currentBrowser }

    var focusedWindow: ExtWindow? { currentBrowser.map { window(for: $0) } }

    var currentTab: ExtTab? {
        guard let b = currentBrowser, let t = b.selected else { return nil }
        return tab(for: t, in: b)
    }

    /// The followed browser first (the focused window), then the person's other open workspaces (agents' own
    /// browsers are left out: keys "profile|agent").
    var allWindows: [ExtWindow] {
        var out: [ExtWindow] = []
        if let b = currentBrowser { out.append(window(for: b)) }
        for (key, b) in WorkspaceModel.current?.openBrowsers ?? [:] where !key.contains("|") && b !== currentBrowser {
            out.append(window(for: b))
        }
        return out
    }

    func window(for b: BrowserModel) -> ExtWindow {
        let k = ObjectIdentifier(b)
        if let w = windows[k], w.browser === b { return w }
        let w = ExtWindow(browser: b, tracker: self)
        windows[k] = w
        return w
    }

    func tab(for t: BrowserTab, in b: BrowserModel) -> ExtTab {
        if let x = tabsByID[t.id], x.tab === t { return x }
        let x = ExtTab(tab: t, browser: b, tracker: self)
        tabsByID[t.id] = x
        return x
    }

    /// Binds to the current workspace (its profile switches change the browser) and follows its browser.
    func refresh() {
        if let ws = WorkspaceModel.current, ws !== workspace {
            workspace = ws
            wsSub = ws.$profileId.removeDuplicates().receive(on: RunLoop.main).sink { [weak self] _ in
                guard let self, let b = self.workspace?.currentBrowser else { return }
                self.follow(b)
            }
        }
        if followed == nil, let b = WorkspaceModel.current?.currentBrowser { follow(b) }
    }

    func follow(_ b: BrowserModel) {
        if workspace == nil { refresh() }
        guard b !== followed else { return }
        followed = b
        browserSubs = []
        let isNew = windows[ObjectIdentifier(b)] == nil
        let w = window(for: b)
        if isNew {
            controller.didOpenWindow(w)
            for t in b.tabs { controller.didOpenTab(tab(for: t, in: b)) }
        }
        controller.didFocusWindow(w)
        known = b.tabs.map(\.id)
        activeID = b.selectedID
        for t in b.tabs { observe(t, in: b) }
        // @Published sends before the value is stored: read the model on the next turn of the run loop.
        b.$tabs.receive(on: RunLoop.main).sink { [weak self, weak b] _ in
            guard let self, let b, b === self.followed else { return }
            self.tabsChanged(b)
        }.store(in: &browserSubs)
        b.$selectedID.removeDuplicates().receive(on: RunLoop.main).sink { [weak self, weak b] _ in
            guard let self, let b, b === self.followed else { return }
            self.selectionChanged(b)
        }.store(in: &browserSubs)
    }

    private func tabsChanged(_ b: BrowserModel) {
        let now = b.tabs.map(\.id)
        let before = Set(known), after = Set(now)
        for t in b.tabs where !before.contains(t.id) {
            observe(t, in: b)
            controller.didOpenTab(tab(for: t, in: b))
        }
        for id in known where !after.contains(id) {
            if let x = tabsByID[id] { controller.didCloseTab(x, windowIsClosing: false) }
            tabsByID[id] = nil
            tabSubs[id] = nil
        }
        known = now
    }

    private func selectionChanged(_ b: BrowserModel) {
        guard b.selectedID != activeID else { return }
        let previous = activeID.flatMap { tabsByID[$0] }
        activeID = b.selectedID
        if let t = b.selected { controller.didActivateTab(tab(for: t, in: b), previousActiveTab: previous) }
    }

    /// URL, title and loading state (WKWebExtension.TabChangedProperties: loading 1<<1, title 1<<7, URL 1<<8,
    /// raw values from WKWebExtensionTab.h, so the Swift spelling of the URL member does not matter).
    private func observe(_ t: BrowserTab, in b: BrowserModel) {
        guard tabSubs[t.id] == nil else { return }
        let url = t.$url.dropFirst().map { _ in UInt(1 << 8) }
        let title = t.$title.dropFirst().map { _ in UInt(1 << 7) }
        let loading = t.$isLoading.dropFirst().map { _ in UInt(1 << 1) }
        tabSubs[t.id] = Publishers.Merge3(url, title, loading)
            .receive(on: RunLoop.main)
            .sink { [weak self, weak t, weak b] bits in
                guard let self, let t, let b else { return }
                self.controller.didChangeTabProperties(WKWebExtension.TabChangedProperties(rawValue: bits), for: self.tab(for: t, in: b))
            }
    }
}

#endif
