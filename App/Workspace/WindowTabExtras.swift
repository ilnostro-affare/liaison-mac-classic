import SwiftUI
import AppKit

// Tab row extras: renaming a tab, the selected tab's favicon held at the row's edge while it is
// Scrolled out of view, the duplicates suggestion, Meta IDs in the address field and
// Its microphone.

// MARK: - rename

/// The inline name field over a tab: Return keeps it (empty: the page's own title again), Esc leaves it as it was.
struct TabRenameField: View {
    @ObservedObject var tab: BrowserTab
    let browser: BrowserModel
    var width: CGFloat? = 170
    let done: () -> Void
    @State private var draft = ""
    @State private var finished = false
    @FocusState private var focus: Bool

    var body: some View {
        TextField("Tab name", text: $draft)
            .textFieldStyle(.plain)
            .font(LiaFont.ui(13, .medium))
            .foregroundStyle(WS.ink)
            .focused($focus)
            .onSubmit { commit() }
            .onExitCommand { finish() }
            .frame(width: width)
            .onAppear {
                draft = tab.customTitle ?? tab.displayTitle
                DispatchQueue.main.async {
                    focus = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                        NSApp.sendAction(#selector(NSText.selectAll(_:)), to: nil, from: nil)
                    }
                }
            }
            .onChange(of: focus) { _, f in if !f { commit() } }
            .accessibilityLabel(Text("Tab name"))
            .accessibilityHint(Text("Leave empty to use the page's title"))
    }

    private func commit() {
        guard !finished else { return }
        let name = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        // The page's own title typed back is no custom name.
        let pageTitle = tab.title.trimmingCharacters(in: .whitespacesAndNewlines)
        tab.customTitle = name.isEmpty || (tab.customTitle == nil && name == pageTitle) ? nil : name
        browser.saveTabs()
        AccessibilityNotification.Announcement(tab.customTitle == nil ? "Tab name reset" : "Tab renamed \(name)").post()
        finish()
    }

    private func finish() {
        guard !finished else { return }
        finished = true
        done()
    }
}

/// A double-click (the second click of one) in a tap handler: SwiftUI's count-2 gesture would delay every click.
@MainActor
enum WSClicks {
    static var isDouble: Bool { (NSApp.currentEvent?.clickCount ?? 1) >= 2 }
}

// MARK: - sticky favicon

/// The selected tab's place in the tab row's visible coordinates (zero: not measured).
struct SelectedTabSpanKey: PreferenceKey {
    static let defaultValue: CGRect = .zero
    static func reduce(value: inout CGRect, nextValue: () -> CGRect) {
        let n = nextValue()
        if n != .zero { value = n }
    }
}

enum TabRowSpace { static let name = "wsTabRowViewport" }

/// The edge the selected tab went past, nil while it is (mostly) visible.
enum TabStickyEdge {
    static func edge(_ span: CGRect, rowWidth: CGFloat) -> HorizontalEdge? {
        guard span != .zero, rowWidth > 60 else { return nil }
        if span.maxX < 14 { return .leading }
        if span.minX > rowWidth - 14 { return .trailing }
        return nil
    }
}

/// A small copy of the selected tab's favicon at the row's edge; a click scrolls back to the tab.
struct TabStickyFavicon: View {
    @ObservedObject var tab: BrowserTab
    let edge: HorizontalEdge
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 2) {
                if edge == .leading { chevron("chevron.left") }
                TabFavicon(tab: tab)
                if edge == .trailing { chevron("chevron.right") }
            }
            .padding(.horizontal, 4)
            .frame(height: 28)
            .background(WS.surface, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .shadow(color: Color.black.opacity(0.14), radius: 4, y: 1)
        }
        .buttonStyle(.liaPlain)
        .liaPointer()
        .padding(.horizontal, 2)
        .liaTip("Back to \(tab.displayTitle)")
        .accessibilityLabel(Text("Scroll to the selected tab, \(tab.displayTitle)"))
    }

    private func chevron(_ s: String) -> some View {
        Image(systemName: s).font(.system(size: 7, weight: .bold)).foregroundStyle(WS.text3).accessibilityHidden(true)
    }
}

// MARK: - duplicates: removed (every link opens its own tab, a duplicate too; no
// "Close duplicates" chip).

// MARK: - Meta IDs

@MainActor
enum OmniMetaID {
    /// 12+ digits (spaces allowed, nothing else): a campaign, ad set or ad ID. Best effort: Ads Manager is asked to
    /// select it as a campaign; Met can find it whatever it is.
    static func rows(_ q: String, account: String?, met: AgentInfo?) -> [OmniboxModel.Row] {
        let compact = q.replacingOccurrences(of: " ", with: "")
        guard compact.count >= 12, compact.allSatisfy(\.isASCIIDigit) else { return [] }
        var r: [OmniboxModel.Row] = []
        var c = URLComponents(string: "https://adsmanager.facebook.com/adsmanager/manage/campaigns")
        var items: [URLQueryItem] = []
        if let account, !account.isEmpty { items.append(URLQueryItem(name: "act", value: account)) }
        items.append(URLQueryItem(name: "selected_campaign_ids", value: compact))
        c?.queryItems = items
        if let u = c?.url {
            r.append(OmniboxModel.Row(id: "meta-open", title: "Open campaign \(compact) in Ads Manager",
                                      detail: account == nil ? "Campaign, ad set or ad ID" : "Campaign, ad set or ad ID \u{00B7} act \(account ?? "")",
                                      symbol: "megaphone", action: .go(u)))
        }
        r.append(OmniboxModel.Row(id: "meta-ask", title: "Ask Met about \(compact)", detail: "Finds the campaign, ad set or ad",
                                  symbol: "bubble.left", agent: met,
                                  action: .askAgent("met", "Find \(compact) in this ad account (campaign, ad set or ad) and tell me how it's doing.")))
        return r
    }
}

private extension Character {
    var isASCIIDigit: Bool { ("0"..."9").contains(self) }
}

// MARK: - the address field's microphone

/// 's dictation in the address field: what is heard replaces the field's text (the suggestions follow).
struct OmniMic: View {
    @ObservedObject var omni: OmniboxModel

    var body: some View {
        ChatMicButton(dictation: omni.dictation)
            .scaleEffect(0.88)
            .frame(width: 24, height: 28)
            .modifier(DictationHooks(dictation: omni.dictation, onStart: {}, onHeard: { t in omni.dictated(t) },
                                     onError: { e in omni.dictationFailed(e) }))
    }
}

// MARK: - tab label, icon memory, drag chip

extension BrowserTab {
    /// What a tab shows: the person's name for it or the page's title, never an address. A title that is an address
    /// (pages without a <title>, images, a load that has not titled itself yet) shows the host instead.
    var chipTitle: String {
        if let c = customTitle, !c.isEmpty { return c }
        let t = displayTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        let host = TabTitleRules.shortHost(savedURL?.host)
        if t.isEmpty { return host ?? "New tab" }
        if TabTitleRules.looksLikeAddress(t) { return host ?? TabTitleRules.shortHost(URL(string: t)?.host) ?? t }
        return t
    }
}

enum TabTitleRules {
    /// "https://x.com/a", "www.x.com", "x.com/a/b", "about:blank": an address, not a title.
    static func looksLikeAddress(_ s: String) -> Bool {
        let l = s.lowercased()
        if l.contains("://") || l.hasPrefix("www.") || l.hasPrefix("about:") { return true }
        return !l.contains(" ") && l.contains(".") && l.contains("/")
    }

    static func shortHost(_ h: String?) -> String? {
        guard let h, !h.isEmpty else { return nil }
        return h.lowercased().hasPrefix("www.") ? String(h.dropFirst(4)) : h
    }
}

/// The last icon seen per tab and per host, for the session: a sleeping, unloaded or restored tab keeps its icon
/// even when BrowserTab drops its own (sleep loads about:blank, which clears it). A tab's icon counts only while the
/// tab is still on the host it came from, so a new site never shows the old site's icon.
@MainActor
enum TabIconMemory {
    private static var byTab: [UUID: (image: NSImage, host: String)] = [:]
    private static var byHost: [String: NSImage] = [:]

    static func remember(_ img: NSImage, tab: UUID, host: String?) {
        guard let h = host?.lowercased(), !h.isEmpty else { return }
        byTab[tab] = (img, h)
        byHost[h] = img
    }

    /// The icon to draw for a tab on `host` when the tab has none of its own.
    static func icon(tab: UUID, host: String?) -> NSImage? {
        guard let h = host?.lowercased(), !h.isEmpty else { return nil }
        if let t = byTab[tab], t.host == h { return t.image }
        return byHost[h] ?? Favicons.cached(h)
    }
}

/// What follows the pointer while a tab is dragged (in the row, to another workspace, out of the window):
/// the tab's own chip, not the text of its id.
struct TabDragChip: View {
    @ObservedObject var tab: BrowserTab

    var body: some View {
        HStack(spacing: 7) {
            TabFavicon(tab: tab)
            Text(tab.chipTitle).font(LiaFont.ui(13, .medium)).foregroundStyle(WS.ink)
                .lineLimit(1).frame(maxWidth: 170, alignment: .leading).fixedSize()
        }
        .padding(.horizontal, 11)
        .frame(height: 32)
        .background(WS.surface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(WS.line2, lineWidth: 1))
        .padding(2)
    }
}

// MARK: - the tab's menu

/// The tab's menu in our drawn style.: a right-click on a tab is its history now, so this menu opens
/// from the tab's \u{22EF} (on hover) and from "Tab Options\u{2026}" at the bottom of the history menu.
/// One tab: Reload, Duplicate, Rename, Pin / Unpin, Mute, New Group with Tab, Add to Group \u{25B8}, Move to <workspace>,
/// Copy Link, Close, Close Other Tabs. A \u{2318}/\u{21E7} selection: pin, move or close all of it. Items that
/// cannot act are left out (the menu has no disabled rows).
@MainActor
enum TabRowMenu {
    static func items(tab: BrowserTab, browser: BrowserModel, ws: WorkspaceModel, count: Int,
                      selection: [BrowserTab], done: @escaping () -> Void) -> [LiaCtxItem] {
        if selection.count > 1 { return group(selection, browser: browser, ws: ws, done: done) }
        let u = tab.savedURL
        var out: [LiaCtxItem] = []
        if !tab.isStart { out.append(LiaCtxItem(title: "Reload", icon: "arrow-clockwise") { tab.reload() }) }
        if u != nil { out.append(LiaCtxItem(title: "Duplicate", icon: "duplicate") { browser.duplicate(tab) }) }
        out.append(LiaCtxItem(title: "Rename Tab\u{2026}", icon: "menu-rename") {
            NotificationCenter.default.post(name: .wsRenameTab, object: tab.id.uuidString)
        })
        out.append(LiaCtxItem(title: tab.pinned ? "Unpin" : "Pin", icon: tab.pinned ? "menu-unpin" : "menu-pin") {
            withAnimation(WSMotion.spring) { browser.setPinned(tab, !tab.pinned) }
        })
        // Back to where the tab was pinned only when asked (a navigation; Back returns).
        if TabRestore.offersPinnedAddress(pinned: tab.pinned, home: tab.pinnedURL, current: u) {
            out.append(LiaCtxItem(title: "Go to the Pinned Address", icon: "menu-pin") { browser.goToPinnedAddress(tab) })
        }
        if tab.playing || tab.muted {
            out.append(LiaCtxItem(title: tab.muted ? "Unmute" : "Mute", icon: tab.muted ? "speaker-high" : "speaker-slash") { tab.setMuted(!tab.muted) })
        }
        // Reader left the selected tab (only its \u{00D7} there) and narrow tabs; it is here instead.
        let reader = ReaderCenter.shared
        if reader.isArticle(tab) {
            let on = reader.open?.tabID == tab.id
            out.append(LiaCtxItem(title: on ? "Close Reader" : "Show Reader", icon: "note") {
                if on { reader.open = nil; return }
                if browser.selectedID != tab.id { browser.selectedID = tab.id }
                reader.show(tab, ws: ws)
            })
        }
        out.append(contentsOf: groupItems([tab], browser: browser, done: done))
        if let u {
            let others = ws.profiles.filter { $0.id != ws.profileId }
            if !others.isEmpty {
                out.append(.sep)
                for p in others {
                    out.append(LiaCtxItem(title: "Move to \(p.name)", icon: "arrow-right") { ws.moveTab(tab, from: browser, to: p.id) })
                }
            }
            out.append(.sep)
            out.append(LiaCtxItem(title: "Copy Link", icon: "menu-copy") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(u.absoluteString, forType: .string)
                ws.show("Link copied", symbol: "link")
            })
        }
        out.append(.sep)
        out.append(LiaCtxItem(title: "Close", icon: "menu-close") { browser.close(tab) })
        if count > 1 { out.append(LiaCtxItem(title: "Close Other Tabs", icon: "x") { browser.closeOthers(tab) }) }
        return out
    }

    private static func group(_ list: [BrowserTab], browser: BrowserModel, ws: WorkspaceModel,
                              done: @escaping () -> Void) -> [LiaCtxItem] {
        let n = list.count
        let allPinned = list.allSatisfy(\.pinned)
        var out: [LiaCtxItem] = [
            LiaCtxItem(title: allPinned ? "Unpin \(n) Tabs" : "Pin \(n) Tabs", icon: allPinned ? "menu-unpin" : "menu-pin") {
                for t in list { browser.setPinned(t, !allPinned) }
                done()
            },
        ]
        out.append(contentsOf: groupItems(list, browser: browser, done: done))
        let movable = list.filter { $0.savedURL != nil }
        let others = ws.profiles.filter { $0.id != ws.profileId }
        if !movable.isEmpty, !others.isEmpty {
            out.append(.sep)
            for p in others {
                out.append(LiaCtxItem(title: "Move \(n) to \(p.name)", icon: "arrow-right") {
                    done()
                    for t in movable { ws.moveTab(t, from: browser, to: p.id) }
                })
            }
        }
        out.append(.sep)
        out.append(LiaCtxItem(title: "Close \(n) Tabs", icon: "menu-close", danger: true) {
            done()
            for t in list { browser.close(t) }
        })
        return out
    }

    /// In the drawn menu: "New Group with Tab" and "Add to Group \u{25B8}" (the open groups, and Remove from
    /// Group when a tab is in one). Pinned tabs stay out of groups, so a pinned tab alone gets none of these.
    private static func groupItems(_ list: [BrowserTab], browser: BrowserModel, done: @escaping () -> Void) -> [LiaCtxItem] {
        let groupable = list.filter { !$0.pinned }
        guard !groupable.isEmpty else { return [] }
        let n = groupable.count
        var out: [LiaCtxItem] = [.sep]
        out.append(LiaCtxItem(title: n > 1 ? "New Group with \(n) Tabs" : "New Group with Tab", icon: "folders") {
            done()
            _ = TabGroupActions.group(groupable, in: browser)
        })
        var sub: [LiaCtxItem] = []
        for g in browser.groups where !groupable.allSatisfy({ $0.group == g.id }) {
            sub.append(LiaCtxItem(title: WSTabStacks.chipName(g, count: browser.tabs(in: g).count), icon: "folder-simple") {
                withAnimation(WSMotion.spring) { for t in groupable where t.group != g.id { browser.addTab(t, to: g) } }
                browser.objectWillChange.send()   // a tab's group changed without the tab list changing: chips recount
                done()
            })
        }
        let grouped = groupable.filter { $0.group != nil }
        if !grouped.isEmpty {
            if !sub.isEmpty { sub.append(.sep) }
            sub.append(LiaCtxItem(title: grouped.count > 1 ? "Remove \(grouped.count) Tabs from Group" : "Remove from Group", icon: "x") {
                withAnimation(WSMotion.spring) { for t in grouped { browser.removeFromGroup(t) } }
                browser.objectWillChange.send()
                done()
            })
        }
        if !sub.isEmpty { out.append(LiaCtxItem(title: "Add to Group", icon: "folder-simple", sub: sub)) }
        return out
    }
}

// MARK: - the address field ends on any click outside it

/// Behind the tab whose address is being typed: a left click anywhere else in the window (the bar, the page, the
/// dock, a SwiftUI area that takes no focus) ends the editing, as Esc does. The field's own focus loss did not fire
/// for clicks on views that never take the keys, so only another tab could end it. The suggestions list under the
/// field (`keep`) and other windows (menus, the field's own context menu) are not "outside". Takes no clicks itself.
struct WSOutsideClickEnd: NSViewRepresentable {
    let active: Bool
    /// True while a click must not end it (the pointer is on the suggestions).
    let keep: () -> Bool
    let end: () -> Void
    let cancel: () -> Void

    func makeNSView(context: Context) -> WatchView {
        let v = WatchView()
        update(v)
        return v
    }

    func updateNSView(_ v: WatchView, context: Context) { update(v) }

    static func dismantleNSView(_ v: WatchView, coordinator: ()) { v.set(active: false) }

    private func update(_ v: WatchView) {
        v.keep = keep
        v.end = end
        v.cancel = cancel
        v.set(active: active)
    }

    final class WatchView: NSView {
        var keep: (() -> Bool)?
        var end: (() -> Void)?
        var cancel: (() -> Void)?
        private var monitors: [Any] = []

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if window == nil { set(active: false) }
        }

        func set(active: Bool) {
            if active == !monitors.isEmpty { return }
            for m in monitors { NSEvent.removeMonitor(m) }
            monitors = []
            guard active else { return }
            if let m = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown], handler: { [weak self] e in
                MainActor.assumeIsolated { self?.mouse(e) }
                return e
            }) { monitors.append(m) }
            // Esc ends it even when the field never got the keys (the omnibox's own Esc needs its text view first).
            if let m = NSEvent.addLocalMonitorForEvents(matching: .keyDown, handler: { [weak self] e in
                let used: Bool = MainActor.assumeIsolated {
                    guard let self, e.keyCode == 53, let w = self.window, e.window === w,
                          !DropdownHost.shared.isOpen else { return false }
                    self.cancel?()
                    return true
                }
                return used ? nil : e
            }) { monitors.append(m) }
        }

        private func mouse(_ e: NSEvent) {
            guard let w = window, e.window === w, !isHiddenOrHasHiddenAncestor else { return }
            if bounds.contains(convert(e.locationInWindow, from: nil)) { return }
            if keep?() == true { return }
            end?()
            // A click on a part of the window that takes no keys leaves the field editor first responder otherwise.
            if w.firstResponder is NSTextView { w.makeFirstResponder(nil) }
        }

        deinit { for m in monitors { NSEvent.removeMonitor(m) } }
    }
}
