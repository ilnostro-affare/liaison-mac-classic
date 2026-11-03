import SwiftUI
import WebKit

/// Hosts the tab's own WKWebView (kept alive by the tab, so switching tabs keeps each page as it was).
struct WebViewHost: NSViewRepresentable {
    let webView: WKWebView
    func makeNSView(context: Context) -> WKWebView {
        WebFocusKeeper.shared.install()
        return webView
    }
    func updateNSView(_ nsView: WKWebView, context: Context) {}
}

/// The keyboard belongs to the page the person clicked ("I click a code field and the Mac beeps").
///
/// Why keys went nowhere: a beep is a key that no responder took, so after the click something other than the web
/// view had the keys. Found in the code: (1) the address field's outside-click end (WSOutsideClickEnd) and Modal's
/// present call `makeFirstResponder(nil)`, and SwiftUI then drops focus a second time when the field's `@FocusState`
/// goes false a pass later, after WebKit already took the click - the window itself is left with the keys; (2) views
/// that come and go with SwiftUI state (the composer's `makeNSView`/`onAppear` and `focusTick`, the start page's
/// delayed focus, the find bar's `onAppear`) take the keys a moment later without any click of the person's; (3) a page
/// re-hosted by SwiftUI (a split, Peek, the agent pane showing the same web view) leaves its window and comes back
/// without the keys; (4) AgentDirector.begin takes them away while an agent works (kept: the page is the agent's then).
///
/// The rule now, for every web view of ours (tabs, panels, private windows):
/// A press on a page makes that page the "owner" of the keys and gives it the keys after the press (twice: at once
/// and 0.25 s later, after SwiftUI's own focus pass); a press anywhere else, a shortcut (with \u{2318} or \u{2303}), Esc
/// or a menu item is the person choosing something of ours: from then the page claims nothing;
/// A page tab that loses the keys without such a choice of the person's takes them back (WebFocusRules.takeBack);
/// A key pressed while the owner page is on screen and nothing that types has the keys goes to the page
/// (WebFocusRules.keyGoesToPage) instead of a beep.
/// Never while the page's agent is at work or a popup of ours is open; another page taking the keys is left alone.
@MainActor
final class WebFocusKeeper {
    static let shared = WebFocusKeeper()

    /// The page the person pressed last (nil after a press on anything else of ours).
    private weak var owner: WKWebView?
    /// When the person last chose something of ours (a press outside the page, a shortcut, Esc, a menu item).
    private var personActedAt = Date.distantPast
    private var reverts: [Date] = []
    private var monitors: [Any] = []
    private var observers: [NSObjectProtocol] = []

    func install() {
        guard monitors.isEmpty else { return }
        if let m = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown], handler: { e in
            MainActor.assumeIsolated { WebFocusKeeper.shared.pressed(e) }
            return e
        }) { monitors.append(m) }
        if let m = NSEvent.addLocalMonitorForEvents(matching: .keyDown, handler: { e in
            MainActor.assumeIsolated { WebFocusKeeper.shared.key(e) }
            return e
        }) { monitors.append(m) }
        let nc = NotificationCenter.default
        for n in [NSMenu.didSendActionNotification, NSMenu.didBeginTrackingNotification] {
            observers.append(nc.addObserver(forName: n, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { WebFocusKeeper.shared.personActedAt = Date() }
            })
        }
    }

    /// The web view under a press, if the press lands on a page (hit test from the window's frame view down).
    private static func page(at e: NSEvent) -> WKWebView? {
        guard let w = e.window, let root = w.contentView?.superview ?? w.contentView else { return nil }
        var v = root.hitTest(e.locationInWindow)
        while let x = v {
            if let web = x as? WKWebView { return web }
            v = x.superview
        }
        return nil
    }

    private static func onScreen(_ web: WKWebView, in w: NSWindow?) -> Bool {
        guard let w, web.window === w else { return false }
        return !web.isHiddenOrHasHiddenAncestor
    }

    private static func holds(_ web: WKWebView, _ r: NSResponder?) -> Bool {
        if r === web { return true }
        if let v = r as? NSView { return v.isDescendant(of: web) }
        return false
    }

    /// Something that types has the keys: an editable text view (a field's editor), a text field, another page.
    private static func takesText(_ r: NSResponder?) -> Bool {
        if let tv = r as? NSTextView { return tv.isEditable }
        if r is NSTextField { return true }
        if let v = r as? NSView { return v is WKWebView || v.enclosingWebView != nil }
        return false
    }

    private static func busy(_ web: WKWebView) -> Bool { (web as? DesktopWebView)?.tab?.agentBusy ?? false }
    private static var modalOpen: Bool { LiaModalCenter.shared.isOpen }

    private func pressed(_ e: NSEvent) {
        guard let web = Self.page(at: e) else {
            owner = nil
            personActedAt = Date()
            return
        }
        owner = web
        reverts = []
        guard e.type == .leftMouseDown else { return }
        // After the click is handled, and once more after SwiftUI's focus pass that follows it.
        for delay in [0.0, 0.25] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak web] in
                guard let web, let w = web.window, web === WebFocusKeeper.shared.owner, Self.onScreen(web, in: w),
                      !Self.holds(web, w.firstResponder), !Self.busy(web), !Self.modalOpen else { return }
                // Another page (a split pane, a pop-up) or a field the person reached since is theirs.
                if let other = w.firstResponder as? NSView, other is WKWebView || other.enclosingWebView != nil { return }
                w.makeFirstResponder(web)
            }
        }
    }

    private func key(_ e: NSEvent) {
        let mods = e.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let shortcut = mods.contains(.command) || mods.contains(.control) || e.keyCode == 53
        if shortcut { personActedAt = Date() }
        guard let web = owner, let w = e.window, w.isKeyWindow else { return }
        let r = w.firstResponder
        guard WebFocusRules.keyGoesToPage(pageOnScreen: Self.onScreen(web, in: w), responderIsPage: Self.holds(web, r),
                                          responderTakesText: Self.takesText(r), shortcut: shortcut,
                                          agentBusy: Self.busy(web), modalOpen: Self.modalOpen) else { return }
        // The window sends this very key to the new first responder.
        w.makeFirstResponder(web)
    }

    /// A page tab lost the keys (DesktopWebView.resignFirstResponder): back to it if nobody of the person's chose that.
    func resigned(_ web: WKWebView) {
        guard web === owner else { return }
        DispatchQueue.main.async { [weak web] in
            guard let web, web === self.owner, let w = web.window else { return }
            let r = w.firstResponder
            guard !Self.holds(web, r) else { return }
            let now = Date()
            self.reverts = self.reverts.filter { now.timeIntervalSince($0) < 2 }
            let otherPage = (r as? NSView).map { $0 is WKWebView || $0.enclosingWebView != nil } ?? false
            guard WebFocusRules.takeBack(pageOnScreen: Self.onScreen(web, in: w), personActedAgo: now.timeIntervalSince(self.personActedAt),
                                         agentBusy: Self.busy(web), modalOpen: Self.modalOpen, otherPageHasKeys: otherPage,
                                         recent: self.reverts.count) else { return }
            self.reverts.append(now)
            w.makeFirstResponder(web)
        }
    }
}

private extension NSView {
    /// The web view this view is inside, if any.
    var enclosingWebView: WKWebView? {
        var v = superview
        while let x = v {
            if let web = x as? WKWebView { return web }
            v = x.superview
        }
        return nil
    }
}
