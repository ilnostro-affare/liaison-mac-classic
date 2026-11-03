import Foundation
import AppKit
import SwiftUI
import WebKit

/// The page side of the password manager. Everything runs in `BrowserModel.agentWorld` (never the page's world): the
/// page's scripts cannot see the listener, cannot post to the handler (it exists only in that world) and cannot read
/// what we fill except as the field's own value, which is theirs to read anyway.
enum PasswordScripts {
    static let handlerName = "liaPw"

    /// Injected at document end in every frame (the handler drops frames of another origin): reports whether the page
    /// has a sign-in form, a focus on one, a user name typed on its own (Google's two-step sign-in), and the user name +
    /// password at a submit (the form's submit, a press of its button, Enter in a field).
    static let capture = #"""
    (() => {
      if (window.__liaPwCap) return; window.__liaPwCap = true;
      const post = (m) => { try { window.webkit.messageHandlers.liaPw.postMessage(m); } catch (e) {} };
      const vis = (el) => { const r = el.getBoundingClientRect(); if (r.width < 2 || r.height < 2) return false;
        const cs = getComputedStyle(el); return cs.visibility !== 'hidden' && cs.display !== 'none'; };
      const isPw = (el) => !!el && el.tagName === 'INPUT' && String(el.type || '').toLowerCase() === 'password';
      const userish = (el) => !!el && el.tagName === 'INPUT' && /^(text|email|tel)$/i.test(el.type || 'text')
        && !/one-time-code|cc-|search/i.test(el.getAttribute('autocomplete') || '') && String(el.type).toLowerCase() !== 'search';
      const pwFields = () => [...document.querySelectorAll('input[type=password]')].filter(vis);
      const idFields = () => [...document.querySelectorAll('input[autocomplete*=username],input[type=email]')].filter((e) => userish(e) && vis(e));
      /* the user name of a password field: the nearest visible field before it, in its form (else the page) */
      const userFor = (pw) => {
        const scope = pw.form || document;
        let best = null;
        for (const i of scope.querySelectorAll('input')) {
          if (i === pw) break;
          if (userish(i) && vis(i) && String(i.value || '').trim()) best = i;
        }
        if (!best) best = [...scope.querySelectorAll('input[autocomplete*=username],input[type=email]')].find((i) => userish(i) && String(i.value || '').trim()) || null;
        return best ? String(best.value).trim().slice(0, 200) : '';
      };
      let lastSent = '';
      const capture = (why) => {
        if (!/^https?:$/.test(location.protocol)) return;
        const pws = pwFields().filter((p) => p.value);
        if (!pws.length) {
          const u = idFields().find((i) => String(i.value || '').trim());
          if (u) post({ kind: 'user', user: String(u.value).trim().slice(0, 200) });
          return;
        }
        /* one field: a sign-in; two or three: a sign-up or a change, the new password is the one to keep */
        const ac = pws.map((p) => String(p.getAttribute('autocomplete') || '').toLowerCase());
        let pw = pws[0], isNew = ac[0].indexOf('new-password') >= 0;
        if (pws.length >= 2) {
          const n = ac.findIndex((a) => a.indexOf('new-password') >= 0);
          if (n >= 0) pw = pws[n];
          else if (pws.length >= 3) pw = pws[1];
          else if (pws[0].value !== pws[1].value) pw = pws[1];
          isNew = true;
        }
        const msg = { kind: 'submit', user: userFor(pws[0]), pw: String(pw.value).slice(0, 512), isNew, path: location.pathname, why };
        const key = msg.user + '\u0001' + msg.pw;
        if (key === lastSent && why !== 'submit') return;
        lastSent = key;
        post(msg);
      };
      document.addEventListener('submit', () => capture('submit'), true);
      document.addEventListener('click', (e) => {
        const t = e.target; const b = t && t.closest ? t.closest('button,input[type=submit],input[type=image],[role=button]') : null;
        if (b) capture('click');
      }, true);
      document.addEventListener('keydown', (e) => { if (e.key === 'Enter' && e.target && e.target.tagName === 'INPUT') capture('enter'); }, true);
      let last = '';
      const report = () => {
        const pw = pwFields().length > 0, id = idFields().length > 0;
        const s = (pw ? 'p' : '') + (id ? 'i' : '');
        if (s !== last) { last = s; post({ kind: 'form', has: pw || id, pw }); }
      };
      report();
      let t = null;
      try { new MutationObserver(() => { if (t) return; t = setTimeout(() => { t = null; report(); }, 400); })
        .observe(document.documentElement, { subtree: true, childList: true, attributes: true, attributeFilter: ['type', 'style', 'class', 'hidden'] }); } catch (e) {}
      /* The focused sign-in field's box (CSS px of this frame's viewport) goes with the focus, so the
         saved accounts show AT the field; a focus elsewhere, typing in it or a scroll takes them away. */
      const loginField = (el) => isPw(el) || (userish(el) && (/username|email/i.test((el.getAttribute('autocomplete') || '') + ' ' + el.type)
        || (/user|login|email|account/i.test((el.name || '') + ' ' + (el.id || '')) && pwFields().length > 0)
        || (!!el.form && [...el.form.querySelectorAll('input[type=password]')].some(vis))));
      let shown = false;
      const away = () => { if (shown) { shown = false; post({ kind: 'unfocus' }); } };
      document.addEventListener('focusin', (e) => {
        const el = e.target;
        if (loginField(el) && vis(el)) {
          const r = el.getBoundingClientRect();
          shown = true;
          post({ kind: 'focus', rect: [r.left, r.top, r.width, r.height] });
        } else away();
      }, true);
      document.addEventListener('input', (e) => { if (e.isTrusted && shown) away(); }, true);
      window.addEventListener('scroll', () => away(), { capture: true, passive: true });
    })();
    """#

    /// Fills the top page's sign-in form, React-safe: the value is set through HTMLInputElement's own setter (from this
    /// world the page's overrides are not seen) and announced with input and change events, as typing would.
    /// Refuses when the page is no longer on `host` or not https. Returns which fields were filled.
    static let fill = #"""
    if (location.protocol !== 'https:' || location.hostname.toLowerCase() !== host) return { user: false, pw: false };
    const vis = (el) => { const r = el.getBoundingClientRect(); if (r.width < 2 || r.height < 2) return false;
      const cs = getComputedStyle(el); return cs.visibility !== 'hidden' && cs.display !== 'none'; };
    const userish = (el) => el.tagName === 'INPUT' && /^(text|email|tel)$/i.test(el.type || 'text') && !/one-time-code|cc-|search/i.test(el.getAttribute('autocomplete') || '');
    const setter = Object.getOwnPropertyDescriptor(HTMLInputElement.prototype, 'value').set;
    const put = (el, v) => {
      el.focus();
      setter.call(el, v);
      el.dispatchEvent(new InputEvent('input', { bubbles: true, inputType: 'insertReplacementText', data: v }));
      el.dispatchEvent(new Event('change', { bubbles: true }));
    };
    const pws = [...document.querySelectorAll('input[type=password]')].filter((p) => vis(p) && !p.disabled && !p.readOnly);
    const pw = pws.find((p) => /current-password/i.test(p.getAttribute('autocomplete') || '')) || pws.find((p) => !/new-password/i.test(p.getAttribute('autocomplete') || '')) || pws[0] || null;
    let userEl = null;
    if (pw) {
      for (const i of (pw.form || document).querySelectorAll('input')) { if (i === pw) break; if (userish(i) && vis(i) && !i.disabled && !i.readOnly) userEl = i; }
    }
    if (!userEl) userEl = [...document.querySelectorAll('input[autocomplete*=username],input[type=email]')].find((i) => userish(i) && vis(i) && !i.disabled && !i.readOnly) || null;
    let u = false, p = false;
    if (user && userEl) { put(userEl, user); u = true; }
    if (password && pw) { put(pw, password); p = true; }
    if (p) pw.focus();
    return { user: u, pw: p };
    """#

    /// A visible password field on the top page right now.
    static let formShown = #"""
    return [...document.querySelectorAll('input[type=password]')].some((e) => { const r = e.getBoundingClientRect(); return r.width > 1 && r.height > 1; });
    """#

    @MainActor
    static func run(_ w: WKWebView, _ js: String, _ args: [String: Any] = [:]) async -> Any? {
        await withCheckedContinuation { (k: CheckedContinuation<Any?, Never>) in
            w.callAsyncJavaScript(js, arguments: args, in: nil, in: BrowserModel.agentWorld) { result in
                switch result {
                case .success(let v): k.resume(returning: v)
                case .failure: k.resume(returning: nil)
                }
            }
        }
    }
}

/// Receives the capture script's messages (agent world only) and hands each to its tab.
final class PasswordMessenger: NSObject, WKScriptMessageHandler {
    static let shared = PasswordMessenger()

    /// Called for every new tab configuration (BrowserModel.configuration): a fresh WKUserContentController each time,
    /// so the handler name is added once per controller (WebKit raises on a second add).
    @MainActor
    static func install(on c: WKWebViewConfiguration) {
        let script = WKUserScript(source: PasswordScripts.capture, injectionTime: .atDocumentEnd, forMainFrameOnly: false,
                                  in: BrowserModel.agentWorld)
        c.userContentController.addUserScript(script)
        c.userContentController.add(shared, contentWorld: BrowserModel.agentWorld, name: PasswordScripts.handlerName)
    }

    @MainActor private static let tabs = NSMapTable<WKWebView, BrowserTab>(keyOptions: .weakMemory, valueOptions: .weakMemory)

    /// The tab a web view belongs to (BrowserTab.makeWebView). A pop-up window's web view has none: ignored.
    @MainActor
    static func register(_ w: WKWebView, tab: BrowserTab) { tabs.setObject(tab, forKey: w) }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        MainActor.assumeIsolated {
            guard let w = message.webView, let tab = Self.tabs.object(forKey: w), let body = message.body as? [String: Any] else { return }
            let frame = message.frameInfo
            tab.passwords.received(body, isMain: frame.isMainFrame, frameHost: frame.securityOrigin.host)
        }
    }
}

/// One tab's password state: the sign-in form on its page, the accounts it can fill, and the offer to save.
@MainActor
final class TabPasswords: ObservableObject {
    struct Offer: Identifiable, Equatable {
        let id = UUID()
        let workspace: String
        let scheme: String
        let host: String
        let user: String
        let update: Bool
        fileprivate let password: String
        var site: String { PasswordMatch.bareHost(host) }
    }

    /// "Save password for site.com?" under the address bar.
    @Published private(set) var offer: Offer?
    /// The page has a sign-in form (a password field or a user-name field).
    @Published private(set) var hasForm = false
    /// The page is http: nothing is filled, the key says why.
    @Published private(set) var insecure = false
    @Published var popoverOpen = false
    /// A short line in the popover after a fill that did not happen.
    @Published private(set) var notice: String?

    private weak var tab: BrowserTab?
    /// The workspace's browser key (BrowserModel.account). nil: no store (a browser outside a workspace).
    let workspace: String?

    private struct Capture {
        let host: String
        let scheme: String
        let user: String
        let password: String
        let path: String
        let at: Date
    }
    private var capture: Capture?
    private var decideJob: Task<Void, Never>?
    private var offerJob: Task<Void, Never>?
    private var offerAt = Date.distantPast
    /// A user name typed on its own (the first step of a two-step sign-in), for the password step that follows.
    private var lastUser: (host: String, user: String, at: Date)?
    /// A fill picked on a user-name step: its password goes into the password step when that appears (2 minutes).
    private var pendingFill: (site: String, password: String, until: Date)?
    /// The popover opened by itself once for this page (a sign-in field got the focus).
    private var autoOpened = false

    init(tab: BrowserTab, workspace: String?) {
        self.tab = tab
        self.workspace = workspace
    }

    private var pageURL: URL? { tab?.loadedWebView?.url ?? tab?.url }
    var pageHost: String? { pageURL?.host?.lowercased() }

    /// Saved accounts for the page: this host's first, then the same site's.
    var matches: (exact: [PasswordItem], related: [PasswordItem]) {
        guard let ws = workspace, let h = pageHost else { return ([], []) }
        return PasswordMatch.split(PasswordStore.shared.items(ws), host: h) { $0.host }
    }

    /// The key in the address bar: a sign-in form, and accounts to fill (or an http page that gets none).
    var showsKey: Bool {
        guard hasForm, workspace != nil else { return false }
        if insecure { return true }
        let m = matches
        return !m.exact.isEmpty || !m.related.isEmpty
    }

    // MARK: - the page's messages

    func received(_ body: [String: Any], isMain: Bool, frameHost: String?) {
        guard workspace != nil, let w = tab?.loadedWebView, let top = w.url, let topHost = top.host?.lowercased() else { return }
        guard PasswordMatch.frameAllowed(topHost: topHost, frameHost: frameHost, isMain: isMain) else { return }
        let scheme = top.scheme?.lowercased() ?? ""
        guard scheme == "https" || scheme == "http" else { return }
        switch body["kind"] as? String {
        case "form":
            let has = body["has"] as? Bool ?? false
            if isMain || has { hasForm = has }
            insecure = PasswordMatch.fillCheck(scheme: scheme) == .insecure
            if body["pw"] as? Bool == true { fillPending(w, host: topHost) }
            if !hasForm { popoverOpen = false }
        case "focus":
            // The accounts show at the field itself (PasswordFieldSuggestions). A field in a frame has
            // no box in the top page: the key's popover opens once instead, as before.
            if isMain, let r = body["rect"] as? [Double], r.count == 4 {
                showSuggestions(at: r, in: w)
                return
            }
            guard !autoOpened, hasForm, !insecure, !matches.exact.isEmpty else { return }
            autoOpened = true
            popoverOpen = true
        case "unfocus":
            if isMain { hideSuggestions() }
        case "user":
            if let u = body["user"] as? String, !u.isEmpty { lastUser = (topHost, u, Date()) }
        case "submit":
            guard let pw = body["pw"] as? String, !pw.isEmpty else { return }
            var user = (body["user"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            if user.isEmpty, let l = lastUser, PasswordMatch.sameSite(l.host, topHost), Date().timeIntervalSince(l.at) < 600 { user = l.user }
            PasswordSecrets.remember(pw)
            capture = Capture(host: topHost, scheme: scheme, user: user, password: pw, path: top.path, at: Date())
            scheduleDecide(after: 2.5)
        default:
            break
        }
    }

    /// A new page: its form is not known yet; an offer shown for a while goes (it belonged to the page before).
    func committed() {
        hideSuggestions()
        hasForm = false
        popoverOpen = false
        autoOpened = false
        notice = nil
        insecure = PasswordMatch.fillCheck(scheme: pageURL?.scheme) == .insecure
        // The person went on browsing past the page the offer came with.
        if offer != nil, Date().timeIntervalSince(offerAt) > 8 { offer = nil }
    }

    /// The page finished loading: a submit waiting for its answer is decided now.
    func finished() {
        if capture != nil { scheduleDecide(after: 0.8) }
    }

    // MARK: - offering to save

    private func scheduleDecide(after seconds: Double) {
        decideJob?.cancel()
        decideJob = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            guard !Task.isCancelled else { return }
            await self?.decide()
        }
    }

    private func decide() async {
        guard let c = capture, let ws = workspace, let w = tab?.loadedWebView else { return }
        if Date().timeIntervalSince(c.at) > 120 { capture = nil; return }
        let nowHost = w.url?.host?.lowercased() ?? ""
        if nowHost == c.host {
            let shown = (await PasswordScripts.run(w, PasswordScripts.formShown) as? Bool) ?? false
            // Still the same sign-in form: a wrong password or a captcha. The next load (or the next submit) decides.
            if PasswordOffer.loginFailed(submitPath: c.path, nowPath: w.url?.path ?? "", passwordFieldShown: shown) { return }
        }
        guard capture?.at == c.at else { return }
        capture = nil
        let store = PasswordStore.shared
        let d = PasswordOffer.decide(user: c.user, password: c.password, known: store.known(workspace: ws, host: c.host),
                                     never: store.isNever(workspace: ws, host: c.host), enabled: PasswordStore.offerEnabled)
        switch d {
        case .none: return
        case .save: show(Offer(workspace: ws, scheme: c.scheme, host: c.host, user: c.user, update: false, password: c.password))
        case .update(let u): show(Offer(workspace: ws, scheme: c.scheme, host: c.host, user: u, update: true, password: c.password))
        }
    }

    private func show(_ o: Offer) {
        offer = o
        offerAt = Date()
        offerJob?.cancel()
        // Not answered in a minute and a half: it goes, as Safari's does.
        offerJob = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 90_000_000_000)
            guard !Task.isCancelled, self?.offer?.id == o.id else { return }
            self?.offer = nil
        }
    }

    func saveOffer() {
        guard let o = offer else { return }
        PasswordStore.shared.save(workspace: o.workspace, scheme: o.scheme, host: o.host, user: o.user, password: o.password)
        offer = nil
    }

    func neverOffer() {
        guard let o = offer else { return }
        PasswordStore.shared.setNever(workspace: o.workspace, host: o.host, true)
        offer = nil
    }

    func dismissOffer() { offer = nil }

    // MARK: - filling

    /// Touch ID (or the Mac's password), then the user name and password into the top page's form. Never into a
    /// frame, never over http, never into a page that moved to another site meanwhile.
    func fill(_ item: PasswordItem) async {
        notice = nil
        guard let w = tab?.loadedWebView, let u = w.url, let host = u.host?.lowercased() else { return }
        switch PasswordMatch.fillCheck(scheme: u.scheme) {
        case .ok: break
        case .insecure: notice = "This page is not secure (http). Liaison fills passwords only on https pages."; return
        case .notWeb: return
        }
        guard PasswordMatch.sameSite(item.host, host) else { return }
        guard await PasswordStore.shared.authenticate("fill your password for \(item.site)") else {
            notice = "Not filled: Touch ID or your Mac password is needed."
            return
        }
        guard w.url?.host?.lowercased() == host else { return }
        guard let pw = PasswordStore.shared.secret(item) else { notice = "This password could not be read from the Keychain."; return }
        PasswordSecrets.remember(pw)
        popoverOpen = false
        hideSuggestions()
        filledAt = Date()   // the fill focuses the fields: that focus opens nothing
        let r = await PasswordScripts.run(w, PasswordScripts.fill, ["host": host, "user": item.user, "password": pw]) as? [String: Any]
        let filledUser = r?["user"] as? Bool ?? false, filledPw = r?["pw"] as? Bool ?? false
        if filledUser && !filledPw {
            pendingFill = (PasswordMatch.registrableDomain(host), pw, Date().addingTimeInterval(120))
        } else if !filledUser && !filledPw {
            notice = "No sign-in field to fill on this page."
            popoverOpen = true
        }
    }

    // MARK: - the accounts at the field

    /// The suggestions under the focused sign-in field: a native popover anchored at the field's box, listing this
    /// page's accounts; a pick asks for Touch ID and fills (`fill`). Nothing is filled by itself and nothing is
    /// submitted. Never while an agent works in the tab (agents never get passwords).
    private var fieldPopover: NSPopover?
    private var filledAt = Date.distantPast

    private func showSuggestions(at r: [Double], in w: WKWebView) {
        let m = matches
        let agentHere = tab?.agentWorksHere ?? false
        guard PasswordSuggest.shows(isMain: true, insecure: insecure, accounts: m.exact.count + m.related.count,
                                    visible: w.window != nil && !w.isHiddenOrHasHiddenAncestor && tab?.isSelectedTab == true,
                                    agentHere: agentHere, justFilled: Date().timeIntervalSince(filledAt) < PasswordSuggest.afterFill),
              let rect = PasswordSuggest.anchor(x: r[0], y: r[1], width: r[2], height: r[3],
                                                zoom: Double(w.pageZoom * w.magnification), view: w.bounds.size)
        else { hideSuggestions(); return }
        let anchor = w.isFlipped ? rect : CGRect(x: rect.minX, y: w.bounds.height - rect.maxY, width: rect.width, height: rect.height)
        let p = fieldPopover ?? {
            let p = NSPopover()
            p.behavior = .transient
            p.animates = false
            p.contentViewController = NSHostingController(rootView: PasswordFieldSuggestions(pw: self))
            fieldPopover = p
            return p
        }()
        // Below the field (a flipped view's max Y is its bottom edge on screen).
        p.show(relativeTo: anchor, of: w, preferredEdge: w.isFlipped ? .maxY : .minY)
        // The person goes on typing in the field: the keys stay with the page's window, never the popover's.
        if let win = w.window, !win.isKeyWindow {
            Task { @MainActor [weak win] in if let win, !win.isKeyWindow { win.makeKey() } }
        }
    }

    /// Closed and let go (the popover's view holds this object).
    func hideSuggestions() {
        guard let p = fieldPopover else { return }
        fieldPopover = nil
        if p.isShown { p.performClose(nil) }
    }

    /// A pick in the field's suggestions.
    func pickSuggestion(_ item: PasswordItem) {
        hideSuggestions()
        Task { await fill(item) }
    }

    /// Command-Backslash: the first account for this page.
    func fillFirst() async {
        let m = matches
        if let i = m.exact.first ?? m.related.first { await fill(i) }
    }

    /// The password step of a two-step sign-in after a fill on its user-name step: filled without asking again.
    private func fillPending(_ w: WKWebView, host: String) {
        guard let p = pendingFill else { return }
        guard Date() < p.until, PasswordMatch.registrableDomain(host) == p.site, w.url?.scheme?.lowercased() == "https" else {
            if Date() >= p.until { pendingFill = nil }
            return
        }
        pendingFill = nil
        Task { @MainActor in _ = await PasswordScripts.run(w, PasswordScripts.fill, ["host": host, "user": "", "password": p.password]) }
    }
}
