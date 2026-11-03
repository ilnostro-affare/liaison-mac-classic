import SwiftUI
import AppKit
import WebKit
import UniformTypeIdentifiers
import Quartz
import TipKit

// The browser chrome of the workspace window: the tab group (tabs, history buttons, the
// address field and its suggestions), the page's own states (progress, error and crash cards, find, zoom,
// permissions), downloads, approvals, toasts and the reconnect banner. Item IDs: docs/UX-BACKLOG.md.

// MARK: - motion and geometry (/05)

/// One motion system: springs for navigation, a short ease-out for micro states, never linear.
enum WSMotion {
    static let spring = Animation.spring(response: 0.35, dampingFraction: 0.85)
    static let micro = Animation.easeOut(duration: 0.2)
    /// Reduce Motion: slides and flights become cross-fades.
    static func navigation(_ reduce: Bool) -> Animation { reduce ? micro : spring }
}

/// The window's root coordinate space: the downloads flight goes from the page to the button in it.
enum WSSpace { static let root = "wsRoot" }

/// Frames of named views in the root space (the page card, the downloads button).
struct WSFrameKey: PreferenceKey {
    static let defaultValue: [String: CGRect] = [:]
    static func reduce(value: inout [String: CGRect], nextValue: () -> [String: CGRect]) {
        value.merge(nextValue()) { $1 }
    }
}

/// The last frames seen, read when a flight starts (not observed: nothing redraws for it).
final class WSFrameBox {
    var frames: [String: CGRect] = [:]
}

extension View {
    func wsReportFrame(_ name: String) -> some View {
        background(GeometryReader { g in
            Color.clear.preference(key: WSFrameKey.self, value: [name: g.frame(in: .named(WSSpace.root))])
        })
    }
}

/// Where the address field is, for its suggestions drawn at window level (never clipped by the tab row).
struct OmniAnchorKey: PreferenceKey {
    static let defaultValue: Anchor<CGRect>? = nil
    static func reduce(value: inout Anchor<CGRect>?, nextValue: () -> Anchor<CGRect>?) { value = value ?? nextValue() }
}

/// A keyDown monitor for a field that needs keys SwiftUI does not hand over on macOS (arrows, Shift-Return).
/// The handler returns true when it used the key (the event is then swallowed).
final class WSKeyMonitor {
    private var token: Any?
    func start(_ handler: @escaping (NSEvent) -> Bool) {
        stop()
        token = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { e in
            let used = handler(e)
            return used ? nil : e
        }
    }
    func stop() {
        if let t = token { NSEvent.removeMonitor(t) }
        token = nil
    }
}

// MARK: - monogram

/// A workspace's avatar: its initials on its colour.
struct WSMonogram: View {
    let name: String
    let colorHex: UInt32
    var size: CGFloat = 18

    private var initials: String {
        let words = name.split(whereSeparator: { $0 == " " || $0 == "-" || $0 == "_" || $0 == "/" })
            .filter { $0.first.map { $0.isLetter || $0.isNumber } ?? false }
        let s = words.prefix(2).compactMap { $0.first }.map { String($0) }.joined()
        return s.isEmpty ? "?" : s.uppercased()
    }

    var body: some View {
        Circle().fill(Color(hex: colorHex))
            .frame(width: size, height: size)
            .overlay(
                Text(initials).font(LiaFont.ui(size * 0.42, .semibold)).foregroundStyle(Color.white)
                    .minimumScaleFactor(0.5).lineLimit(1)
            )
            .accessibilityHidden(true)
    }
}

/// Retired: workspaces live only in the switcher at the left of the bar (ProfileChip), never as
/// pills on the right. The type keeps its old initializer so the top bar's WorkspacePills still compiles; it draws
/// nothing, so that row is only the empty room that drags the window. The bar's owner should delete WorkspacePills.
struct WorkspacePill: View {
    let profile: CompanyProfile
    let fresh: Bool
    var approvals = 0
    var onTabDrop: ((String) -> Void)? = nil
    var settings: WorkspaceModel? = nil
    let action: () -> Void

    var body: some View {
        Color.clear.frame(width: 0, height: 0).accessibilityHidden(true)
    }
}

// MARK: - tab group (/02/04/05/06/07/09, )

/// The current workspace and its tabs: one cell at the far left with Back / Forward /
/// Reload, the workspace's name (its switcher) and the pinned tabs as icons; then the pinned groups, then the other
/// tabs and groups, +. The row NEVER scrolls every tab shares the room (TabFit, Shared/Core/TabStrip.swift),
/// narrowing to its favicon; past the minimums the last tabs wait in "All tabs". The toolbar's colour is behind it all
/// (ToolbarGlass.swift). A right-click on a tab opens that tab's history under it.
struct TabGroup: View {
    @ObservedObject var ws: WorkspaceModel
    let profile: CompanyProfile
    @ObservedObject var browser: BrowserModel
    @ObservedObject var omni: OmniboxModel
    @Environment(\.accessibilityReduceMotion) private var reduce
    @Environment(\.openWindow) private var openWindow
    @State private var dragging: UUID?
    /// Tabs whose page title changed while they were in the background; cleared when selected.
    @State private var unread: Set<UUID> = []
    /// Tabs picked with \u{2318}/\u{21E7}-click (two or more; empty: no multi-selection) and the last one picked.
    @State private var multi: Set<UUID> = []
    @State private var anchor: UUID?
    /// A tab closed by the pointer keeps the others at the width they had until the pointer leaves the row,
    /// so the next tab's \u{00D7} is under the pointer again (Chrome).
    @State private var frozenShare: CGFloat?
    /// The tabs live in the vertical sidebar; the bar keeps the selected tab (the address) only.
    @AppStorage(Prefs.verticalTabs) private var vertical = false
    /// The strip's frame on screen. Each tab's own frame comes from its right-click target (TabPill.targetKey).
    @State private var stripBox = AnchorBox()
    /// 's chip, when it shows: the row leaves room for it.

    private static let spacing: CGFloat = 2
    /// The + button and the "All tabs" chevron, with their gaps: always kept free at the row's end.
    private static let extrasRoom: CGFloat = 30 + 26 + 6 * 3

    /// The first Ads Manager tab, for the morning tour's spotlight.
    private var adsTabID: UUID? {
        browser.tabs.first { t in
            guard let u = t.savedURL, let host = u.host?.lowercased(), host.contains("facebook.com") else { return false }
            return u.path.lowercased().contains("adsmanager") || host.hasPrefix("adsmanager.")
        }?.id
    }

    /// The pinned tabs that are in no group: icons in the workspace's cell.
    private var pinnedLoose: [BrowserTab] { browser.tabs.filter(\.pinned) }

    /// TabFit's answer for this row, keyed back to tabs and group headers.
    private struct StripWidths {
        var tabs: [UUID: CGFloat] = [:]
        var headers: [String: CGFloat] = [:]
        var hiddenTabs: Set<UUID> = []
        var hiddenHeaders: Set<String> = []
        var share: CGFloat = TabFit.Limits().maxTab
        var hiddenCount: Int { hiddenTabs.count }
    }

    private func stripWidths(_ items: [TabStripItem], available: CGFloat) -> StripWidths {
        var fit: [TabFit.Item] = []
        var keys: [(tab: UUID?, header: String?)] = []
        var run = 0
        let sel = browser.selectedID
        for item in items {
            switch item {
            case .tab(let t, _):
                fit.append(.tab(selected: t.id == sel))
                keys.append((t.id, nil))
            case .group(let g, let n, let shown):
                // Pinned groups keep their compact size: the header as it is, the tabs as favicons.
                fit.append(.header(TabRowLayout.chipWidth(g, count: n), group: run, fixed: g.isPinned))
                keys.append((nil, g.id))
                for s in shown {
                    let isSel = s.tab.id == sel
                    fit.append(.tab(selected: isSel, group: run, fixed: g.isPinned && !isSel, width: TabMetrics.minWidth))
                    keys.append((s.tab.id, nil))
                }
                run += 1
            }
        }
        var limits = TabFit.Limits()
        if let f = frozenShare { limits.maxTab = max(limits.minTab, min(limits.maxTab, f)) }
        // The address being typed keeps a usable field; the others give way.
        if let e = omni.editingTab, e == sel { limits.minSelected = TabFit.Limits().maxTab }
        let r = TabFit.fit(fit, available: available, limits: limits)
        var out = StripWidths()
        out.share = r.share
        for (i, k) in keys.enumerated() {
            let hidden = r.hidden.contains(i)
            if let id = k.tab {
                if hidden { out.hiddenTabs.insert(id) } else { out.tabs[id] = r.widths[i] }
            } else if let g = k.header {
                if hidden { out.hiddenHeaders.insert(g) } else { out.headers[g] = r.widths[i] }
            }
        }
        return out
    }

    var body: some View {
        HStack(spacing: 6) {
            homeCell
                .layoutPriority(2)
            if vertical { addressOnly } else { tabRow.layoutPriority(0) }
            // Browser extensions' buttons (Bitwarden, 1Password...): ExtensionsToolbar.swift, empty without any.
            ExtensionsBar(browser: browser)
                .fixedSize()
                .layoutPriority(2)
        }
        .padding(3)
        // With many tabs nothing of the group may draw past its own frame (under the bar's right
        // items); suggestions and hover cards draw at window level.
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .background(AnchorReader(box: stripBox))
        .background { groupShortcut }
        // 0.2.11: the bar's free room outside the strip (between + and Share when the tabs fill
        // the row) asks for the same menu as the strip's own empty room (TabBarMenu.requestBar).
        // Review 0.2.11: one window can hold two strips (two TabGroups); only a strip on screen answers, and only
        // the first of them per request (the same post reaches every strip at once), so the menu is not opened and
        // closed again by the second.
        .onReceive(NotificationCenter.default.publisher(for: .wsTabBarMenu)) { n in
            guard let w = n.object as? NSWindow, let v = stripBox.view, w === v.window,
                  !v.isHiddenOrHasHiddenAncestor, !v.visibleRect.isEmpty, v.alphaValue > 0 else { return }
            let now = ProcessInfo.processInfo.systemUptime
            if let last = TabBarMenuClaim.last, last.window == ObjectIdentifier(w), now - last.at < 0.3 { return }
            TabBarMenuClaim.last = (ObjectIdentifier(w), now)
            openBarMenu("bar", at: nil, in: w)
        }
    }

    /// The far-left cell: Back / Forward / Reload, the workspace (a click opens the switcher) and the pinned tabs.
    private var homeCell: some View {
        HStack(spacing: 1) {
            if let t = browser.selected { NavCluster(tab: t).fixedSize() }
            ProfileChip(ws: ws, profile: profile)
            if !vertical {
                ForEach(pinnedLoose) { t in
                    pill(t, index: browser.tabs.firstIndex(where: { $0.id == t.id }) ?? 0, width: nil, ads: adsTabID)
                }
            }
        }
        .padding(.horizontal, 2)
        // The workspace's cell (and its pinned tabs) on the chrome's glass, its glyphs per region.
        .chromeGlass(RoundedRectangle(cornerRadius: StripLook.radius, style: .continuous))
        .barInkRegion()
        .animation(WSMotion.navigation(reduce), value: pinnedLoose.map(\.id))
        .fixedSize()
    }

    /// The selected tab alone (its pill is the address field).
    @ViewBuilder private var addressOnly: some View {
        if let t = browser.selected, let i = browser.tabs.firstIndex(where: { $0.id == t.id }) {
            pill(t, index: i, width: nil, ads: adsTabID)
        }
    }

    /// The all-tabs menu (shown when tabs had to leave the row, or past eight) and +.
    private func extras(hidden: Int) -> some View {
        HStack(spacing: 6) {
            if hidden > 0 || browser.tabs.count > 8 { AllTabsMenu(browser: browser, hidden: hidden).fixedSize() }
            Button { openNewTab() } label: {
                PlusGlyph()
                    .frame(width: 30, height: 30)
                    .chromeGlass(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .contentShape(Rectangle())
            }
            .buttonStyle(.liaPlain)
            .liaHover(.icon, radius: 10)
            // A right-click on + offers the other kinds of new tab (TabBarMenu.plus).
            .overlay(RightClickTarget(key: "tab-strip-plus") { frame, window in
                openBarMenu("plus", items: TabBarMenu.plus(browser: browser, hooks: barHooks), at: frame, in: window)
            })
            .accessibilityLabel(Text("New tab"))
            .accessibilityAction(named: Text("New Private Window")) { openWindow(id: "private") }
        }
        .fixedSize()
        .barInkRegion()
    }

    /// A new tab. Any address editing ends first, so the new tab's start page (its own field) gets the keys.
    private func openNewTab() {
        if omni.editingTab != nil { omni.end() }
        withAnimation(WSMotion.navigation(reduce)) { _ = browser.openHome() }
    }

    /// \u{2325}\u{2318}G groups the \u{2318}/\u{21E7}-click selection (\u{2318}\u{21E7}G stays Find Previous). Enabled only with a
    /// selection. The menu owner should give it a real item ("Group Selected Tabs").
    private var groupShortcut: some View {
        Button("") { groupSelection() }
            .keyboardShortcut("g", modifiers: [.command, .option])
            .disabled(multi.count < 2)
            .buttonStyle(.liaPlain)
            .opacity(0)
            .frame(width: 0, height: 0)
            .accessibilityHidden(true)
    }

    private func groupSelection() {
        let list = browser.tabs.filter { multi.contains($0.id) }
        guard list.count > 1, TabGroupActions.group(list, in: browser) != nil else { return }
        clearMulti()
    }

    /// The row takes the room the bar leaves it; the tabs share it (never a scroll), then +, then the free room that
    /// drags the window.
    private var tabRow: some View {
        GeometryReader { g in
            let items = TabRowLayout.strip(browser)
            let room = max(TabFit.Limits().minSelected, g.size.width - Self.extrasRoom)
            let w = stripWidths(items, available: room)
            HStack(spacing: 6) {
                HStack(spacing: Self.spacing) {
                    ForEach(items) { item in stripItem(item, widths: w, ads: adsTabID) }
                }
                .padding(.vertical, 1)
                .animation(WSMotion.navigation(reduce), value: browser.tabs.map(\.id))
                .animation(WSMotion.navigation(reduce), value: browser.groups)
                .animation(WSMotion.micro, value: w.share)
                // Each tab and each group header is its own right-click target (AppKit's hit test finds
                // it); this one, behind them, takes only the row's empty room.: the tab bar's own menu
                // there (TabBarMenu.bar; the selected tab's history is its "Tab History\u{2026}"), at the pointer.
                .background(RightClickTarget(key: "tab-strip-row") { _, window in openBarMenu("bar", at: nil, in: window) })
                extras(hidden: w.hiddenCount)
                WindowDragArea().frame(maxWidth: .infinity, maxHeight: 34)
                    // The free room after +: the same menu (left clicks still drag the window).
                    .overlay(RightClickTarget { _, window in openBarMenu("bar", at: nil, in: window) })
            }
            .frame(width: g.size.width, height: g.size.height, alignment: .leading)
        }
        .frame(minWidth: 120, maxWidth: .infinity)
        .frame(height: 34)
        .onHover { inside in if !inside { unfreeze() } }
        .onChange(of: browser.tabs.map(\.id)) { _, ids in pruneMulti(ids) }
        .onChange(of: browser.selectedID) { _, id in if let id { clearUnread(id) } }
        .onChange(of: browser.splitID) { _, id in if id != nil { SplitTip().invalidate(reason: .actionPerformed) } }
        .popoverTip(SplitTip())
    }

    /// A loose tab, or a group: ONE container (a faint fill and a hairline) around its header and its tabs.
    /// Items TabFit sent to the menu are not drawn.
    @ViewBuilder private func stripItem(_ item: TabStripItem, widths w: StripWidths, ads: UUID?) -> some View {
        switch item {
        case .tab(let t, let i):
            if !w.hiddenTabs.contains(t.id) { pill(t, index: i, width: w.tabs[t.id], ads: ads) }
        case .group(let g, let n, let shown):
            if !w.hiddenHeaders.contains(g.id) {
                HStack(spacing: Self.spacing) {
                    TabGroupChip(group: g, count: n, browser: browser, ws: ws, width: w.headers[g.id], inStrip: true)
                    ForEach(shown.filter { !w.hiddenTabs.contains($0.tab.id) }) { s in
                        pill(s.tab, index: s.index, width: w.tabs[s.tab.id], ads: ads)
                    }
                }
                .padding(.horizontal, 2)
                // A group's container is glass too.
                .chromeGlass(RoundedRectangle(cornerRadius: StripLook.radius, style: .continuous))
                .barInkRegion()
                .transition(reduce ? AnyTransition.opacity : AnyTransition.scale(scale: 0.9).combined(with: .opacity))
            }
        }
    }

    private func pill(_ t: BrowserTab, index i: Int, width: CGFloat?, ads: UUID?) -> some View {
        TabPill(tab: t, browser: browser, ws: ws, omni: omni, selected: t.id == browser.selectedID,
                index: i, count: browser.tabs.count, width: width, focusToken: ws.addressFocus,
                unread: unread.contains(t.id), tourAds: t.id == ads,
                marked: multi.count > 1 && multi.contains(t.id), group: selection(for: t),
                onTitleChange: { markUnread(t.id) },
                onModifiedClick: { shift in modifiedClick(t.id, shift: shift) },
                onPlainClick: { clearMulti() },
                onPointerClose: { pointerClose(t, width: width) },
                onGroupDone: { clearMulti() },
                onHistory: { frame, window in openHistory(t, at: frame, window: window) },
                onMenu: { openTabMenu(t) },
                onDragStart: { startDrag(t.id) })
            // Each tab's glyphs and glass by the colour right behind it.
            .barInkRegion()
            .id(t.id)
            .transition(reduce ? AnyTransition.opacity : AnyTransition.tabReveal)
            .onDrop(of: [UTType.text], delegate: TabDropDelegate(target: t.id, browser: browser, dragging: $dragging,
                                                                  animation: WSMotion.navigation(reduce)))
    }

    // MARK: the tab's history (right-click) and its menu ("Tab Options\u{2026}" in the history)

    /// A tab's frame on screen now, read from its own right-click target (nil: the tab is not drawn).
    private func tabFrame(_ t: BrowserTab) -> (rect: NSRect, window: NSWindow)? {
        RightClickTargetView.screenRect(key: TabPill.targetKey(t.id))
    }

    /// The tab's back/forward list, under the tab: at the frame its right-click target handed over, else the tab's
    /// frame read now. A tab that is not drawn has no history menu (never one at the strip's left start).
    private func openHistory(_ t: BrowserTab, at frame: NSRect? = nil, window: NSWindow? = nil) {
        TipHost.shared.dismiss()
        var rect = frame
        var win = window
        if rect == nil, let f = tabFrame(t) { rect = f.rect; win = f.window }
        guard let at = rect else { return }
        let host = win ?? stripBox.window
        DropdownHost.shared.toggle(AnyHashable("tab-history-" + t.id.uuidString), anchor: at, in: host,
                                   edge: .below, align: .leading, gap: 4) {
            TabHistoryPanel(tab: t, browser: browser, ws: ws) { openTabMenu(t, anchor: at, window: host) }
        }
    }

    /// The tab's own menu (rename, pin, mute, groups, move, close...), on the whole \u{2318}/\u{21E7} selection when it is in it.
    /// Under the tab (its frame read now when none is given).
    private func openTabMenu(_ t: BrowserTab, anchor: NSRect? = nil, window: NSWindow? = nil) {
        TipHost.shared.dismiss()
        var rect = anchor
        var win = window
        if rect == nil, let f = tabFrame(t) { rect = f.rect; win = f.window }
        guard let at = rect else { return }
        let items = TabRowMenu.items(tab: t, browser: browser, ws: ws, count: browser.tabs.count, selection: selection(for: t),
                                     done: { clearMulti() })
        DropdownHost.shared.toggle(AnyHashable("tab-menu-" + t.id.uuidString), anchor: at, in: win ?? stripBox.window,
                                   edge: .below, align: .leading, gap: 4) {
            LiaCtxGlassPanel(items: items)
        }
    }

    // MARK: the tab bar's menus (TabBarMenu)

    private var barHooks: TabBarMenu.Hooks {
        var history: (() -> Void)?
        if let t = browser.selected { history = { openHistory(t) } }
        return TabBarMenu.Hooks(newTab: { openNewTab() }, privateWindow: { openWindow(id: "private") }, tabHistory: history)
    }

    /// `items` nil: the strip's menu. `at` nil: under the pointer (the strip's empty room is wide; its frame is not
    /// where the click was).
    private func openBarMenu(_ key: String, items: [LiaCtxItem]? = nil, at frame: NSRect?, in window: NSWindow) {
        TipHost.shared.dismiss()
        let list = items ?? TabBarMenu.bar(browser: browser, ws: ws, hooks: barHooks)
        let p = NSEvent.mouseLocation
        let anchor = frame ?? NSRect(x: p.x, y: p.y - 1, width: 1, height: 1)
        DropdownHost.shared.toggle(AnyHashable("tab-bar-menu-" + key), anchor: anchor, in: window,
                                   edge: .below, align: .leading, gap: frame == nil ? 2 : 4) {
            LiaCtxGlassPanel(items: list)
        }
    }

    // MARK: middle-click and the width freeze

    private func pointerClose(_ t: BrowserTab, width: CGFloat?) {
        if frozenShare == nil, let width, t.id != browser.selectedID { frozenShare = width }
        withAnimation(WSMotion.navigation(reduce)) { browser.close(t) }
    }

    private func unfreeze() {
        guard frozenShare != nil else { return }
        withAnimation(WSMotion.navigation(reduce)) { frozenShare = nil }
    }

    // MARK: multi-selection

    /// \u{2318}-click adds or removes a tab; \u{21E7}-click adds the range from the last picked (or the selected) tab.
    private func modifiedClick(_ id: UUID, shift: Bool) {
        var next = multi
        if next.isEmpty, let s = browser.selectedID { next.insert(s) }
        let ids = browser.tabs.map(\.id)
        if shift, let from = anchor ?? browser.selectedID, let a = ids.firstIndex(of: from), let b = ids.firstIndex(of: id) {
            for x in ids[min(a, b)...max(a, b)] { next.insert(x) }
        } else {
            if next.contains(id) { next.remove(id) } else { next.insert(id) }
            anchor = id
        }
        withAnimation(WSMotion.micro) { multi = next.count > 1 ? next : [] }
        let said: String = multi.isEmpty ? "Selection cleared" : "\(multi.count) tabs selected"
        AccessibilityNotification.Announcement(said).post()
    }

    private func clearMulti() {
        anchor = nil
        guard !multi.isEmpty else { return }
        withAnimation(WSMotion.micro) { multi = [] }
    }

    private func pruneMulti(_ ids: [UUID]) {
        let next = multi.intersection(ids)
        if next != multi { multi = next.count > 1 ? next : [] }
    }

    /// The tabs a context menu acts on: the whole selection when the tab is part of it, else none (one tab).
    private func selection(for t: BrowserTab) -> [BrowserTab] {
        guard multi.count > 1, multi.contains(t.id) else { return [] }
        return browser.tabs.filter { multi.contains($0.id) }
    }

    /// A background tab's title changed ("(3) New leads").
    private func markUnread(_ id: UUID) {
        guard id != browser.selectedID, !unread.contains(id) else { return }
        withAnimation(WSMotion.micro) { _ = unread.insert(id) }
    }

    private func clearUnread(_ selected: UUID) {
        let alive = Set(browser.tabs.map(\.id))
        let next = unread.filter { $0 != selected && alive.contains($0) }
        if next != unread { withAnimation(WSMotion.micro) { unread = next } }
    }

    /// A drag that ends outside the tab row never reaches performDrop: forget the dragged tab once the mouse is up,
    /// or a later text drag onto the row (a link from a page) would move that stale tab.
    private func startDrag(_ id: UUID) {
        dragging = id
        Task { @MainActor in
            while NSEvent.pressedMouseButtons & 1 != 0 { try? await Task.sleep(nanoseconds: 200_000_000) }
            try? await Task.sleep(nanoseconds: 300_000_000)
            if dragging == id { dragging = nil }
        }
    }
}

/// Tab sizes outside the shared row (TabFit decides the row's): pinned icons, the address-only pill, the faces.
enum TabMetrics {
    /// The widest a tab is outside the row (the vertical mode's address pill keeps its old cap).
    static let maxWidth: CGFloat = 190
    /// The favicon-only tab (TabFit.Limits.minTab).
    static let minWidth: CGFloat = 36
    static let pinned: CGFloat = 34
    /// The trailing room the close button's slot takes (22 pt target, 4 pt from the edge, 4 pt from the title).
    static let closeSlot: CGFloat = 30
    /// Below this an unselected tab shows its favicon only.
    static let compactBelow: CGFloat = 80
    /// Below this the selected tab shows its favicon and \u{00D7} only.
    static let titleBelowSelected: CGFloat = 96
}

/// More than eight tabs: every tab in one list at the end of the row (our glass dropdown, not an NSMenu).
private struct AllTabsMenu: View {
    @ObservedObject var browser: BrowserModel
    /// Tabs that did not fit in the row even at their smallest (the row never scrolls).
    var hidden = 0
    @Environment(\.wsBarOnDark) private var onDark

    var body: some View {
        DropdownButton(align: .trailing, gap: 6, tip: hidden > 0 ? "All tabs (\(browser.tabs.count)), \(hidden) not shown" : "All tabs (\(browser.tabs.count))", radius: 9) {
            HStack(spacing: 1) {
                if hidden > 0 { Text("\(hidden)").font(LiaFont.ui(11, .semibold)).monospacedDigit() }
                Image(systemName: "chevron.down").font(.system(size: 11, weight: .semibold))
            }
            .foregroundStyle(BarInk.text2(onDark))
                .padding(.horizontal, 2)
                .frame(minWidth: 26, minHeight: 30)
                .chromeGlass(RoundedRectangle(cornerRadius: 9, style: .continuous))
                .contentShape(Rectangle())
        } menu: {
            DropdownPanelView(width: 300, glass: true) {
                DropdownTitle(text: "\(browser.tabs.count) tabs")
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(browser.tabs) { t in
                            WSGlassMenuRow(selected: t.id == browser.selectedID, action: { browser.selectedID = t.id }) {
                                TabFavicon(tab: t)
                                Text(t.chipTitle).font(LiaFont.ui(12.5)).lineLimit(1)
                            }
                        }
                    }
                }
                .frame(maxHeight: 380)
                .fixedSize(horizontal: false, vertical: browser.tabs.count < 12)
            }
        }
        .accessibilityLabel(Text(hidden > 0 ? "All tabs, \(browser.tabs.count), \(hidden) not shown in the row" : "All tabs, \(browser.tabs.count)"))
    }
}

/// The + glyph, reading the bar's ink where it sits (barInkRegion around the extras).
private struct PlusGlyph: View {
    @Environment(\.wsBarOnDark) private var onDark
    var body: some View {
        Image(systemName: "plus").font(.system(size: 12, weight: .semibold)).foregroundStyle(BarInk.text2(onDark))
    }
}

/// A row of our glass dropdowns (Dropdown.swift's look) with any leading content: a hover pill, a check when selected.
struct WSGlassMenuRow<Leading: View>: View {
    var selected = false
    var trailing: String? = nil
    let action: () -> Void
    @ViewBuilder var leading: () -> Leading
    @State private var hover = false

    var body: some View {
        Button {
            DropdownHost.shared.close()
            action()
        } label: {
            HStack(spacing: 8) {
                leading()
                Spacer(minLength: 8)
                if let trailing {
                    Text(trailing).font(LiaFont.ui(11, .semibold)).monospacedDigit().foregroundStyle(WS.amberInk)
                        .padding(.horizontal, 5).frame(minWidth: 17, minHeight: 17)
                        .background(WS.amberSoft, in: Capsule())
                }
                if selected { LiaIcon("check", size: 14).foregroundStyle(WS.blue) }
            }
            .foregroundStyle(AppConfig.ink)
            .padding(.horizontal, 8).padding(.vertical, 5)
            .background(RoundedRectangle(cornerRadius: 8).fill(hover ? AppConfig.surface2 : Color.clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.liaPlain)
        .onHover { h in
            hover = h
            if h { DropdownHost.shared.closeSub(unlessIn: nil) }
        }
        .liaPointer()
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// A tab dragged over another takes its place at once; the neighbours slide (spring).
struct TabDropDelegate: DropDelegate {
    let target: UUID
    let browser: BrowserModel
    @Binding var dragging: UUID?
    let animation: Animation

    func validateDrop(info: DropInfo) -> Bool {
        dragging != nil || MainActor.assumeIsolated { TabGroupDrag.current != nil }
    }

    func dropEntered(info: DropInfo) {
        MainActor.assumeIsolated {
            // A whole group dragged by its chip.
            if dragging == nil, let g = TabGroupDrag.current {
                withAnimation(animation) { TabGroupDrag.move(g, to: target, in: browser) }
                WSHaptics.alignment()
                return
            }
            guard let d = dragging, d != target else { return }
            withAnimation(animation) { browser.move(d, to: target) }
            WSHaptics.alignment()   // The tab clicked into its new slot
        }
    }

    func dropUpdated(info: DropInfo) -> DropProposal? { DropProposal(operation: .move) }

    func performDrop(info: DropInfo) -> Bool {
        dragging = nil
        MainActor.assumeIsolated { TabGroupDrag.end() }
        return true
    }
}

/// /02: a tab grows from zero width when it opens and shrinks to zero when it closes, so the neighbours move
/// with the spring instead of jumping.
private struct WidthReveal: Layout {
    var fraction: CGFloat
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard let s = subviews.first else { return .zero }
        let size = s.sizeThatFits(proposal)
        return CGSize(width: size.width * fraction, height: size.height)
    }
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard let s = subviews.first else { return }
        let size = s.sizeThatFits(proposal)
        s.place(at: bounds.origin, anchor: .topLeading, proposal: ProposedViewSize(size))
    }
}

private struct TabRevealModifier: ViewModifier, Animatable {
    var fraction: CGFloat
    var animatableData: CGFloat {
        get { fraction }
        set { fraction = newValue }
    }
    func body(content: Content) -> some View {
        // Clipped while it grows or shrinks; at rest the clip is a little larger, so the tab's shadow shows.
        WidthReveal(fraction: fraction) { content.opacity(Double(fraction)) }
            .clipShape(Rectangle().inset(by: fraction < 1 ? 0 : -4))
    }
}

extension AnyTransition {
    fileprivate static var tabReveal: AnyTransition {
        .modifier(active: TabRevealModifier(fraction: 0), identity: TabRevealModifier(fraction: 1))
    }
}

/// The workspace switcher, the only place workspaces live in the bar (no pills on the right):
/// Monogram, name and a glass dropdown of every workspace, with 's count of changes waiting for a Yes.
private struct ProfileChip: View {
    @ObservedObject var ws: WorkspaceModel
    let profile: CompanyProfile
    @Environment(\.wsBarOnDark) private var onDark

    private var waiting: [String: Int] {
        ws.approvals.reduce(into: [String: Int]()) { d, a in if let p = a.profileId { d[p, default: 0] += 1 } }
    }
    private var waitingElsewhere: Int { waiting.filter { $0.key != profile.id }.values.reduce(0, +) }

    var body: some View {
        DropdownButton(gap: 6, help: "Workspace", radius: 11) {
            // The workspace's name and nothing else (no caret, no dot); a click opens the switcher,
            // which lists the changes waiting elsewhere.
            Text(profile.name).font(LiaFont.ui(13, .semibold)).foregroundStyle(BarInk.ink(onDark)).lineLimit(1)
                .frame(maxWidth: 180, alignment: .leading)
                .padding(.horizontal, 8)
                .frame(height: 30)
                .contentShape(Rectangle())
        } menu: {
            WorkspaceSwitcherPanel(ws: ws, current: profile.id, waiting: waiting)
        }
        .fixedSize()
        .accessibilityLabel(Text(waitingElsewhere > 0 ? "Workspace \(profile.name), \(waitingElsewhere) changes waiting in other workspaces" : "Workspace \(profile.name)"))
        .accessibilityHint(Text("Switch to another workspace"))
    }
}

/// The switcher's list: every workspace (the main one from Settings first, as WorkspaceModel sorts them).
private struct WorkspaceSwitcherPanel: View {
    let ws: WorkspaceModel
    let current: String
    let waiting: [String: Int]

    var body: some View {
        DropdownPanelView(width: 280, glass: true) {
            DropdownTitle(text: "Workspaces")
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(ws.profiles) { p in
                        let n = waiting[p.id] ?? 0
                        WSGlassMenuRow(selected: p.id == current, trailing: n > 0 ? "\(n)" : nil, action: { ws.select(p.id) }) {
                            WorkspaceAvatar(profile: p, size: 20)   // Its picture, else the monogram
                            // A workspace by its name only; its ad accounts live in its settings.
                            Text(p.name).font(LiaFont.ui(12.5, p.id == current ? .semibold : .regular)).lineLimit(1)
                        }
                    }
                }
            }
            .frame(maxHeight: 360)
            .fixedSize(horizontal: false, vertical: ws.profiles.count < 9)
            DropdownDivider()
            // 12: an empty workspace, its settings open on Ad accounts.
            DropdownItem(title: "New Workspace", icon: "plus") { Task { await ws.newWorkspace() } }
            DropdownItem(title: "Workspace Settings\u{2026}", icon: "gear") {
                if let p = ws.profiles.first(where: { $0.id == current }) { ws.editingProfile = p }
            }
        }
    }
}

/// Back and Forward (a click goes, a long press or a right-click lists the history, newest first),
/// Reload that turns into Stop while the page loads.
private struct NavCluster: View {
    @ObservedObject var tab: BrowserTab
    @Environment(\.wsBarOnDark) private var onDark
    /// The second click of a quick double click on Reload hit Stop (the button had just turned
    /// into it) and cancelled the reload. For a moment after a Reload click the button stays Reload (ReloadButton).
    @State private var reloadedAt: Date?
    @State private var graceToken = 0

    private var sinceReload: Double? { reloadedAt.map { Date().timeIntervalSince($0) } }
    private var showsStop: Bool { ReloadButton.showsStop(loading: tab.isLoading, sinceReload: sinceReload) }

    var body: some View {
        HStack(spacing: 0) {
            historyButton(back: true)
            historyButton(back: false)
            Button {
                switch ReloadButton.action(loading: tab.isLoading, sinceReload: sinceReload) {
                case .stop: tab.webView.stopLoading(); reloadedAt = nil
                case .reload: tab.reload(fromOrigin: NSEvent.modifierFlags.contains(.option)); startGrace()   // Option-click: from origin
                }
            } label: {
                Image(systemName: showsStop ? "xmark" : "arrow.clockwise")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(BarInk.text2(onDark))
                    .frame(width: 26, height: 28)
            }
            .buttonStyle(.liaPlain)
            .liaHover(.icon, radius: 9)
            .disabled(tab.isStart)
            .accessibilityLabel(Text(showsStop ? "Stop loading" : "Reload"))
            .onChange(of: tab.id) { _, _ in reloadedAt = nil }
        }
    }

    /// The Reload face for `ReloadButton.grace`, then the button redraws (Stop if the page is still loading).
    private func startGrace() {
        reloadedAt = Date()
        graceToken &+= 1
        let token = graceToken
        DispatchQueue.main.asyncAfter(deadline: .now() + ReloadButton.grace + 0.05) {
            if token == graceToken { reloadedAt = nil }
        }
    }

    private func historyButton(back: Bool) -> some View {
        HistoryButton(tab: tab, back: back)
    }
}

/// One history arrow. A click goes; a long press or a right-click lists the pages, newest first, in our
/// glass dropdown (no system menus in the bar).
private struct HistoryButton: View {
    @ObservedObject var tab: BrowserTab
    let back: Bool
    @Environment(\.wsBarOnDark) private var onDark
    @State private var box = AnchorBox()
    @State private var longFired = false
    @State private var key = UUID()

    private var enabled: Bool { back ? tab.canGoBack : tab.canGoForward }

    var body: some View {
        Button {
            if longFired { longFired = false; return }
            if back { tab.webView.goBack() } else { tab.webView.goForward() }
        } label: {
            Image(systemName: back ? "chevron.left" : "chevron.right")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(BarInk.text2(onDark))
                .frame(width: 26, height: 28)
                .contentShape(Rectangle())
        }
        .buttonStyle(.liaPlain)
        .background(AnchorReader(box: box))
        // A right-click target AppKit finds itself; the list opens under the frame it hands over.
        .overlay(RightClickTarget { frame, window in if enabled { openList(at: frame, in: window) } })
        // the history list: right-click (a long press on a Button can swallow the plain click on macOS)
        .liaHover(.icon, radius: 9)
        .disabled(!enabled)
        .accessibilityLabel(Text(back ? "Back" : "Forward"))
        .accessibilityHint(Text("Hold or right-click for history"))
        .accessibilityAction(named: Text("Show history")) { openList() }
    }

    private func items() -> [WKBackForwardListItem] {
        guard let list = tab.loadedWebView?.backForwardList else { return [] }   // no page yet: no history (and no view made for it)
        return back ? Array(list.backList.reversed().prefix(12)) : Array(list.forwardList.prefix(12))
    }

    private static func title(_ it: WKBackForwardListItem) -> String {
        if let t = it.title, !t.isEmpty { return t }
        return TabTitleRules.shortHost(it.url.host) ?? it.url.absoluteString
    }

    private func openList(at frame: NSRect? = nil, in window: NSWindow? = nil) {
        let list = items()
        guard !list.isEmpty else { return }
        let t = tab
        DropdownHost.shared.toggle(AnyHashable(key), anchor: frame ?? box.screenRect, in: window ?? box.window, edge: .below, align: .leading) {
            DropdownPanelView(width: 280, glass: true) {
                ForEach(Array(list.enumerated()), id: \.offset) { _, it in
                    WSGlassMenuRow(action: { t.webView.go(to: it) }) {
                        HistoryIcon(host: it.url.host)
                        HistoryRowText(title: Self.title(it), url: it.url, current: false)
                    }
                }
            }
        }
    }
}

/// A history row's site icon (the icon memory, else a globe).
private struct HistoryIcon: View {
    let host: String?
    var body: some View {
        Group {
            if let img = TabIconMemory.icon(tab: UUID(), host: host) { Image(nsImage: img).resizable().interpolation(.high) }
            else { LiaIcon("globe-simple", size: 15).foregroundStyle(WS.text3) }
        }
        .frame(width: 15, height: 15)
        .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
        .frame(width: 21, height: 21)
    }
}

/// A history row's two lines: the page's title, and under it its host and path, shortened,
/// so five rows titled "Acme CRM" read apart.
private struct HistoryRowText: View {
    let title: String
    let url: URL?
    let current: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(title).font(LiaFont.ui(12.5, current ? .semibold : .regular)).lineLimit(1)
            if let d = HistoryDetail.line(url) {
                Text(d).font(LiaFont.ui(11)).foregroundStyle(WS.text3).lineLimit(1).truncationMode(.middle)
            }
        }
    }
}

/// A tab's history, as holding Back in Safari: the pages ahead (furthest first), the one it is on
/// (marked), the pages behind (most recent first), each with its site's icon; a click goes there. At the bottom the
/// tab's own menu ("Tab Options\u{2026}"), which the right-click used to open.
private struct TabHistoryPanel: View {
    @ObservedObject var tab: BrowserTab
    let browser: BrowserModel
    let ws: WorkspaceModel
    let onOptions: () -> Void
    @ObservedObject private var reader = ReaderCenter.shared

    private struct Entry: Identifiable {
        let id: Int
        let item: WKBackForwardListItem?
        let title: String
        let host: String?
        let url: URL?
        let current: Bool
    }

    private var entries: [Entry] {
        var out: [Entry] = []
        let current = Entry(id: 0, item: nil, title: tab.chipTitle, host: tab.savedURL?.host, url: tab.isStart ? nil : tab.savedURL, current: true)
        guard let list = tab.loadedWebView?.backForwardList else { return [current] }   // not loaded: no web view made for it
        var n = 1
        for it in list.forwardList.prefix(10).reversed() {
            out.append(Entry(id: n, item: it, title: Self.title(it), host: it.url.host, url: it.url, current: false)); n += 1
        }
        out.append(current)
        for it in list.backList.reversed().prefix(15) {
            out.append(Entry(id: n, item: it, title: Self.title(it), host: it.url.host, url: it.url, current: false)); n += 1
        }
        return out
    }

    private static func title(_ it: WKBackForwardListItem) -> String {
        if let t = it.title, !t.isEmpty { return t }
        return TabTitleRules.shortHost(it.url.host) ?? it.url.absoluteString
    }

    var body: some View {
        let list = entries
        DropdownPanelView(width: 340, glass: true) {
            DropdownTitle(text: list.count > 1 ? "History" : "This tab")
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(list) { e in
                        WSGlassMenuRow(selected: e.current, action: { go(e) }) {
                            if e.current {
                                GroupFavicon(tab: tab, size: 15).frame(width: 21, height: 21)
                            } else {
                                HistoryIcon(host: e.host)
                            }
                            HistoryRowText(title: e.title, url: e.url, current: e.current)
                        }
                        .accessibilityLabel(Text(e.current ? "\(e.title), current page" : e.title))
                    }
                }
            }
            .frame(maxHeight: 420)
            .fixedSize(horizontal: false, vertical: list.count < 11)
            DropdownDivider()
            // The tab's buttons that left the tab (the selected one shows only its \u{00D7}; Reader only on wide tabs).
            if tab.playing || tab.muted {
                DropdownItem(title: tab.muted ? "Unmute Tab" : "Mute Tab", icon: tab.muted ? "speaker-high" : "speaker-slash",
                             iconSize: 16, fontSize: 12.5) { tab.setMuted(!tab.muted) }
            }
            if reader.isArticle(tab) {
                let on = reader.open?.tabID == tab.id
                DropdownItem(title: on ? "Close Reader" : "Show Reader", icon: "note", iconSize: 16, fontSize: 12.5) {
                    TabReaderGlyph.toggle(tab, browser: browser, ws: ws)
                }
            }
            DropdownItem(title: "Tab Options\u{2026}", icon: "dots-three", iconSize: 16, fontSize: 12.5, action: onOptions)
        }
    }

    private func go(_ e: Entry) {
        if browser.selectedID != tab.id { browser.selectedID = tab.id }
        if let it = e.item { tab.webView.go(to: it) }
    }
}

// MARK: - one tab (/07/08/09/10/11/20, ..05, A11Y-01)

/// One tab. The selected one is glass and is the address field too (click it, or \u{2318}L).
private struct TabPill: View {
    @ObservedObject var tab: BrowserTab
    let browser: BrowserModel
    let ws: WorkspaceModel
    @ObservedObject var omni: OmniboxModel
    let selected: Bool
    let index: Int
    let count: Int
    /// (TabFit) this tab's width in the row; nil outside it (pinned icons, the address-only pill).
    var width: CGFloat? = nil
    /// Bumped by \u{2318}L: the selected tab turns into the address field.
    var focusToken = 0
    /// The title changed while this tab was in the background.
    var unread = false
    /// This is the Ads Manager tab the morning tour points at.
    var tourAds = false
    /// Part of a \u{2318}/\u{21E7}-click selection (a ring), and that selection when the menu should act on all of it.
    var marked = false
    var group: [BrowserTab] = []
    var onTitleChange: () -> Void = {}
    /// \u{2318}-click (false) or \u{21E7}-click (true); a plain click clears the selection.
    var onModifiedClick: (Bool) -> Void = { _ in }
    var onPlainClick: () -> Void = {}
    /// Closed by the pointer (\u{00D7} or the middle button): the row keeps its widths while the pointer stays.
    var onPointerClose: (() -> Void)? = nil
    /// A menu action on the whole selection finished.
    var onGroupDone: () -> Void = {}
    /// A right-click opens the tab's history (under the tab); its menu is the history's
    /// "Tab Options\u{2026}" (no \u{22EF} on the tab). The tab's own frame on screen and its window,
    /// handed over by its right-click target (nil, nil: VoiceOver; the strip reads the frame itself).
    var onHistory: (NSRect?, NSWindow?) -> Void = { _, _ in }
    var onMenu: () -> Void = {}
    let onDragStart: () -> Void
    /// Reader's verdict on this tab's page (the Reader button and its menu row).
    @ObservedObject private var reader = ReaderCenter.shared
    @State private var hover = false
    /// The hover card shows after half a second on an unselected tab.
    @State private var preview = false
    @State private var hoverToken = 0
    /// The tab's name is being typed (double-click or "Rename Tab\u{2026}").
    @State private var renaming = false
    @FocusState private var focus: Bool
    /// The tab's width at rest. Editing the address keeps exactly this width, so the row never reflows
    /// (it grew to 360+ and the neighbours, the scroll and the sticky favicon jumped, worst on the last tab).
    @State private var restWidth: CGFloat = 0
    @Environment(\.wsBarOnDark) private var onDark

    /// A start page's own field (WorkspaceHome) is its address. The tab never turns into a
    /// second address field for it: the two fought over the keys (each ending the other's editing) and the clicks
    /// around them, which is how New Tab came to work only every other time.
    private var editing: Bool { omni.editingTab == tab.id && !tab.isStart }
    /// Pinned, or squeezed by the row: the favicon only.
    private var compact: Bool {
        !editing && !renaming && (tab.pinned || (!selected && (width ?? .infinity) < TabMetrics.compactBelow))
    }
    /// The selected tab narrower than a readable title: favicon and \u{00D7}.
    private var titleHidden: Bool {
        guard let w = width, !editing, !renaming else { return false }
        return selected && w < TabMetrics.titleBelowSelected
    }

    // The body is split in three steps: one long modifier chain was too much for the type checker.
    var body: some View {
        accessible(reactive(marking(decorated(face))))
    }

    /// The selection ring. the middle button closes the tab.
    private func marking<V: View>(_ v: V) -> some View {
        v
            .overlay {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(marked ? WS.blue : Color.clear, lineWidth: 2)
                    .allowsHitTesting(false)
            }
            .background(WSMouseZone(kind: .middle) { pointerClose() })
            // A right-click is the tab's history (back and forward), under the tab. The tab
            // is its own right-click target, found by AppKit's hit test, and the menu opens under the frame it hands
            // over. Off while a field is typed in (the field's own menu).
            .overlay(RightClickTarget(key: Self.targetKey(tab.id), enabled: !editing && !renaming) { frame, window in
                endPreview()
                onHistory(frame, window)
            })
            // A click anywhere outside the tab (or Esc) ends the address editing.
            .background(WSOutsideClickEnd(active: editing, keep: { omni.hoverList }, end: { omni.end() }, cancel: { omni.cancel() }))
    }

    /// The name of this tab's right-click target (the strip reads the tab's frame through it).
    static func targetKey(_ id: UUID) -> String { "tab-" + id.uuidString }

    /// The speaker and Reader buttons this tab shows besides its \u{00D7} (TabButtons in Shared/Core).
    private var buttons: TabButtons.Shown {
        TabButtons.shown(selected: selected, width: width, sound: tab.playing || tab.muted, article: reader.isArticle(tab))
    }

    private func pointerClose() {
        endPreview()
        if let onPointerClose { onPointerClose() } else { browser.close(tab) }
    }

    @ViewBuilder private var face: some View {
        if compact { compactFace } else { fullFace }
    }

    private var previewValue: (Anchor<CGRect>) -> TabPreviewKey.Item? {
        { a in preview && !selected && !editing ? TabPreviewKey.Item(tab: tab, anchor: a) : nil }
    }

    private func decorated<V: View>(_ v: V) -> some View {
        let shape = RoundedRectangle(cornerRadius: 12, style: .continuous)
        // (feedback: "the selected tab must be glass") strong glass, not opaque white; nearly solid only while
        // the address is typed, so the field reads over any page.
        let fill: Color = !selected && hover ? BarInk.hover(onDark) : Color.clear
        return v
            .background(fill, in: shape)
            .background { if selected { ChromeGlass(shape: shape, strong: true, solid: editing) } }
            .contentShape(shape)
            .anchorPreference(key: OmniAnchorKey.self, value: .bounds) { a in editing ? a : nil }
            .anchorPreference(key: TabPreviewKey.self, value: .bounds, transform: previewValue)
            .onHover { h in
                hover = h
                hoverChanged(h)
            }
            .onTapGesture { tapped() }
            // The tour's spotlights (behind the face, so the tab keeps its identity when they come and go).
            .background { if selected { Color.clear.tourAnchor("address") } }
            .background { if tourAds { Color.clear.tourAnchor("adsmanager") } }
    }

    private func tapped() {
        endPreview()
        // The second click of a double-click renames (an unselected tab: the first click selected it).
        if WSClicks.isDouble, !editing { startRename(); return }
        let mods = NSEvent.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if mods.contains(.command) || mods.contains(.shift) {
            onModifiedClick(mods.contains(.shift))
            return
        }
        onPlainClick()
        if selected { if !editing && !tab.isStart { omni.begin(tab: tab, browser: browser, ws: ws) } }
        else { browser.selectedID = tab.id }
    }

    private func reactive<V: View>(_ v: V) -> some View {
        v
            .onChange(of: tab.title) { old, new in
                // A page that renames itself in the background (not a navigation, not its first title).
                if !selected, !old.isEmpty, old != new, !tab.isLoading { onTitleChange() }
            }
            .onChange(of: editing) { _, e in
                if e { focusField() } else { focus = false }
            }
            .onChange(of: focus) { _, f in focusChanged(f) }
            .onChange(of: focusToken) { _, _ in
                guard selected, !tab.isStart else { return }
                if editing { focusField() } else { omni.begin(tab: tab, browser: browser, ws: ws) }
            }
            .onChange(of: selected) { _, s in
                if s { endPreview() }
                if !s && editing { omni.end() }
            }
            .onReceive(NotificationCenter.default.publisher(for: .wsRenameTab)) { n in
                // With vertical tabs the sidebar's row renames (the bar's pill is the address).
                if (n.object as? String) == tab.id.uuidString, !UserDefaults.standard.bool(forKey: Prefs.verticalTabs) { startRename() }
            }
            .liaPointer()
    }

    private func startRename() {
        if editing { omni.end() }
        renaming = true
    }

    private func focusChanged(_ f: Bool) {
        guard !f, editing else { return }
        // A click on a suggestion lands after the field let go: wait, and keep editing while the pointer is on the list
        // (or while 's dictation is listening).
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            if !focus, omni.editingTab == tab.id, !omni.hoverList, !omni.dictation.listening { omni.end() }
        }
    }

    // A11Y-01/02
    private func accessible<V: View>(_ v: V) -> some View {
        v
            .accessibilityElement(children: editing || renaming ? .contain : .ignore)
            .accessibilityLabel(Text(a11yLabel))
            .accessibilityAddTraits(.isButton)
            .accessibilityAddTraits(selected || marked ? .isSelected : [])
            .accessibilityAction { browser.selectedID = tab.id }
            .accessibilityAction(named: Text(marked ? "Remove from selection" : "Add to selection")) { onModifiedClick(false) }
            .accessibilityAction(named: Text(tab.pinned ? "Unpin tab" : "Pin tab")) { browser.setPinned(tab, !tab.pinned) }
            .accessibilityAction(named: Text(tab.muted ? "Unmute tab" : "Mute tab")) { tab.setMuted(!tab.muted) }
            .accessibilityAction(named: Text("Close tab")) { browser.close(tab) }
            .accessibilityAction(named: Text("Rename tab")) { startRename() }
            .accessibilityAction(named: Text("Show history")) { onHistory(nil, nil) }
            .accessibilityAction(named: Text("Tab options")) { onMenu() }
            // Reachable with keyboard navigation (never focused by a click); off while the address field has the keys.
            .focusable(!editing && !renaming, interactions: .activate)
    }

    /// / the favicon alone, centred (a pinned tab is 34 pt and has no close button; a squeezed one
    /// shows its \u{00D7} on hover once there is room for both).
    private var compactFace: some View {
        let w = tab.pinned ? TabMetrics.pinned : max(TabMetrics.minWidth, width ?? TabMetrics.minWidth)
        return favicon
            .overlay(alignment: .bottomTrailing) {
                if buttons.speaker {
                    SpeakerGlyph(tab: tab, small: true).offset(x: 6, y: 5)
                }
            }
            .frame(width: w, height: 32)
            .overlay(alignment: .trailing) {
                if hover && !tab.pinned && w >= 56 { closeButton }
            }
            .contentShape(Rectangle())
            .onDrag {
                endPreview()
                onDragStart()
                return NSItemProvider(object: tab.id.uuidString as NSString)
            } preview: {
                TabDragChip(tab: tab)
            }
            // No tooltip; hovering shows the tab's card (TabHoverCard).
    }

    /// In the row: exactly TabFit's width (the rename field takes a little more, briefly). Outside it: the address
    /// field and the rename field need room; the selected tab may be wider than the others.
    private var faceMinWidth: CGFloat? {
        if let w = width { return renaming ? max(w, 150) : w }
        if editing { return restWidth > 0 ? restWidth : 200 }
        if renaming { return 210 }
        // The selected tab is the address field: wide enough to type in before it is clicked.
        return selected ? 200 : nil
    }
    private var faceMaxWidth: CGFloat {
        if let w = width { return renaming ? max(w, 150) : w }
        if editing { return restWidth > 0 ? restWidth : 420 }
        return selected || renaming ? 420 : TabMetrics.maxWidth
    }
    /// The \u{00D7}'s slot: kept on the selected and the hovered tab; in the row the others give it to the title.
    private var trailingRoom: CGFloat {
        if renaming { return 11 }
        if width != nil, !selected, !hover, !editing { return 11 }
        return TabMetrics.closeSlot
    }

    private var fullFace: some View {
        HStack(spacing: 7) {
            if renaming {
                TabFavicon(tab: tab)
                TabRenameField(tab: tab, browser: browser) { renaming = false }
            } else if editing {
                TabFavicon(tab: tab)
                field
            } else {
                HStack(spacing: 7) {
                    favicon
                    if !titleHidden { label }
                }
                .contentShape(Rectangle())
                // Dragged by its face (never while the address is being typed).
                .onDrag {
                    endPreview()
                    onDragStart()
                    return NSItemProvider(object: tab.id.uuidString as NSString)
                } preview: {
                    TabDragChip(tab: tab)
                }
            }
            // The selected tab shows only its \u{00D7} (the speaker, Reader and the zoom
            // badge overlapped it); another tab keeps its speaker and shows Reader only when wide enough. Mute and
            // Reader stay in the right-click menu (TabHistoryPanel) and the tab's menu.
            if buttons.speaker, !editing {
                // Sound from this tab; a click mutes or unmutes it.
                SpeakerGlyph(tab: tab, small: false)
            }
            if selected, !editing, !tab.isStart {
                // Passwords: the key while the page has a sign-in form with saved accounts (PasswordBar.swift);
                // Not on a narrow tab, where it lay over the close button (TabButtons.showsKey). The
                // hidden key keeps Command-Backslash working.
                PasswordKeyButton(pw: tab.passwords, glyphShown: TabButtons.showsKey(selected: selected, width: width))
                // 0.2.11: Translate when the page is in a language the person does not read (TranslateLayer.swift).
                if let w = tab.loadedWebView { TranslatePageButton(webView: w) }
            }
            if tab.capturing {
                // Camera or microphone live in this tab.
                Image(systemName: "video.fill")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(Color.red)
                    .accessibilityLabel(Text("Using camera or microphone"))
            }
            if buttons.reader, !editing {
                // Reader on pages that read like an article.
                TabReaderGlyph(tab: tab, browser: browser, ws: ws)
            }
        }
        .padding(.leading, (width ?? 100) < 70 ? 8 : 11)
        // The \u{00D7} has its own slot at the tab's right edge (an overlay, below), so the title and the
        // address field always end before it and it sits in the same place on every tab, edited or not.
        .padding(.trailing, trailingRoom)
        .frame(height: 32)
        .frame(minWidth: faceMinWidth, maxWidth: faceMaxWidth, alignment: .leading)
        .clipped()
        .overlay(alignment: .trailing) {
            if !renaming { closeButton }
        }
        .background(GeometryReader { g in
            Color.clear
                .onAppear { if !editing { restWidth = g.size.width } }
                .onChange(of: g.size.width) { _, w in if !editing && !renaming { restWidth = w } }
        })
        // The page in front is looked at once per load (article? video?).
        .background { if selected { ReaderProbe(tab: tab) } }
    }

    /// A 22 pt target at a fixed 4 pt from the tab's right edge, shown on the hovered and
    /// the selected tab and while the address is typed; on the others it keeps its room but takes no clicks. Its own
    /// contentShape, so a click a little off the glyph still closes rather than opening the address field.
    private var closeButton: some View {
        let shown = hover || selected || editing
        return Button { pointerClose() } label: {
            Image(systemName: "xmark").font(.system(size: 9, weight: .bold)).foregroundStyle(editing ? WS.text3 : BarInk.text3(onDark))
                .frame(width: 22, height: 22)
                .contentShape(Rectangle())
        }
        .buttonStyle(.liaPlain)
        .liaHover(.icon, radius: 6)
        .padding(.trailing, 4)
        .opacity(shown ? 1 : 0)
        .allowsHitTesting(shown)
        .accessibilityHidden(!shown)
        .accessibilityLabel(Text("Close tab"))
    }

    /// The field's placeholder and VoiceOver label (a site search names its site).
    private var omniPlaceholder: String {
        if let site = omni.siteSearch { return "Search " + site.name }
        if let a = omni.agentChip, omni.text.isEmpty { return "Task for " + a.name }
        return "Search, enter address, or @agent"
    }
    private var omniLabel: String {
        if let site = omni.siteSearch { return "Search " + site.name }
        return "Address and search"
    }

    /// The favicon with a dot while the page has news the person has not looked at.
    private var favicon: some View {
        TabFavicon(tab: tab)
            .overlay(alignment: .topTrailing) {
                if unread && !selected {
                    Circle().fill(WS.blue)
                        .frame(width: 7, height: 7)
                        .overlay(Circle().stroke(WS.surface, lineWidth: 1.5))
                        .offset(x: 2, y: -1)
                        .transition(.scale.combined(with: .opacity))
                        .accessibilityHidden(true)
                }
            }
    }

    /// Half a second on an unselected tab shows its card; leaving hides it at once.
    private func hoverChanged(_ h: Bool) {
        hoverToken += 1
        guard h, !selected, !editing else { preview = false; return }
        let token = hoverToken
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            if token == hoverToken, hover, !selected, NSEvent.pressedMouseButtons == 0 { preview = true }
        }
    }

    private func endPreview() {
        hoverToken += 1
        preview = false
    }

    private var a11yLabel: String {
        var s = "Tab \(index + 1) of \(count), \(tab.chipTitle)"
        if tab.pinned { s += ", pinned" }
        if marked { s += ", in selection" }
        if unread && !selected { s += ", new activity" }
        if tab.playing { s += tab.muted ? ", muted" : ", playing sound" } else if tab.muted { s += ", muted" }
        if tab.isLoading { s += ", loading" }
        if tab.asleep { s += ", sleeping" }
        if tab.capturing { s += ", using camera or microphone" }
        if tab.url?.scheme?.lowercased() == "http" { s += ", not secure" }
        return s
    }

    private func focusField() {
        DispatchQueue.main.async {
            focus = true
            // The whole address is selected, so typing replaces it.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                NSApp.sendAction(#selector(NSText.selectAll(_:)), to: nil, from: nil)
            }
        }
    }

    /// The page's title only, never its address (that shows while the address is edited);
    /// an http page keeps its "Not secure" warning.
    @ViewBuilder private var label: some View {
        Text(tab.chipTitle).font(LiaFont.ui(13, selected ? .medium : .regular))
            .foregroundStyle(selected ? BarInk.ink(onDark) : BarInk.text2(onDark)).lineLimit(1)
        if selected, !tab.isStart, tab.url?.scheme?.lowercased() == "http" {
            HStack(spacing: 3) {
                Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 9)).foregroundStyle(WS.amber)
                Text("Not secure").font(LiaFont.ui(12, .medium)).foregroundStyle(WS.amberInk)
            }
            .fixedSize()
        }
    }

    /// /03/04: the address field; the agent's chip when an @name is recognised; the completed host's tail.
    private var field: some View {
        HStack(spacing: 6) {
            if let a = omni.agentChip {
                HStack(spacing: 4) {
                    AgentAvatar(agent: a, size: 16)
                    Text(a.name).font(LiaFont.ui(12, .medium)).foregroundStyle(WS.ink)
                }
                .padding(.horizontal, 6)
                .frame(height: 22)
                .background(WS.soft, in: Capsule())
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(Text("To \(a.name)"))
            }
            if let site = omni.siteSearch { SiteSearchChip(site: site) }
            ZStack(alignment: .leading) {
                TextField(omniPlaceholder, text: $omni.text)
                    .textFieldStyle(.plain)
                    .font(LiaFont.ui(13))
                    .focused($focus)
                    .onSubmit { omni.commit() }
                    .onExitCommand { omni.cancel() }
                    .contextMenu { OmniFieldMenu(omni: omni) }
                    // "@Name task" - the agent's name as the message box's pill while typing
                    .background { AgentMentionFieldPaint(text: omni.text, focused: focus) }
                    .accessibilityLabel(Text(omniLabel))
                    .accessibilityHint(Text("Type a keyword such as meta or yt, then Tab, to search that site"))
                if !omni.tail.isEmpty {
                    HStack(spacing: 0) {
                        Text(omni.text).hidden()
                        Text(omni.tail)
                            .foregroundStyle(WS.text2)
                            .background(Color.accentColor.opacity(0.22))
                    }
                    .font(LiaFont.ui(13))
                    .lineLimit(1)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
                }
            }
            OmniMic(omni: omni)
        }
    }
}

/// One tab's menu, shared by the tab row and the vertical sidebar. Trimmed to the essentials
/// Split view, rename, screenshot, Reader and the rest live in the menu bar, \u{2318}K and double-click.
struct TabContextMenu: View {
    let tab: BrowserTab
    let browser: BrowserModel
    let ws: WorkspaceModel
    let selected: Bool
    let index: Int
    let count: Int

    var body: some View {
        let u = tab.savedURL
        Button("Reload") { tab.reload() }.disabled(tab.isStart)
        Button("Duplicate") { browser.duplicate(tab) }.disabled(u == nil)
        Button(tab.pinned ? "Unpin" : "Pin") { browser.setPinned(tab, !tab.pinned) }
        if TabRestore.offersPinnedAddress(pinned: tab.pinned, home: tab.pinnedURL, current: u) {
            Button("Go to the Pinned Address") { browser.goToPinnedAddress(tab) }
        }
        Button(tab.muted ? "Unmute" : "Mute") { tab.setMuted(!tab.muted) }
        Button("Copy Link") {
            guard let u else { return }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(u.absoluteString, forType: .string)
            ws.show("Link copied", symbol: "link")
        }
        .disabled(u == nil)
        Divider()
        moveMenu(u)
        TabGroupMenuItems(tab: tab, browser: browser, submenu: true)
        Divider()
        Button("Close") { browser.close(tab) }
        Button("Close Other Tabs") { browser.closeOthers(tab) }.disabled(count < 2)
    }

    /// The page moves to another client's workspace (opened there, with that client's sign-ins).
    @ViewBuilder private func moveMenu(_ u: URL?) -> some View {
        let others = ws.profiles.filter { $0.id != ws.profileId }
        if !others.isEmpty {
            Menu("Move to Workspace") {
                ForEach(others) { p in
                    Button(p.name) { ws.moveTab(tab, from: browser, to: p.id) }
                }
            }
            .disabled(u == nil)
        }
    }
}

/// A speaker on a tab that plays sound (or is muted); a click toggles mute.
struct SpeakerGlyph: View {
    @ObservedObject var tab: BrowserTab
    let small: Bool

    var body: some View {
        Button { tab.setMuted(!tab.muted) } label: {
            Image(systemName: tab.muted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                .font(.system(size: small ? 7.5 : 10, weight: .semibold))
                .foregroundStyle(tab.muted ? WS.text3 : WS.text2)
                .frame(width: small ? 13 : 18, height: small ? 13 : 18)
                .background(small ? AnyShapeStyle(WS.surface) : AnyShapeStyle(Color.clear), in: Circle())
        }
        .buttonStyle(.liaPlain)
        .liaHover(.icon, radius: small ? 6.5 : 5)
        // No tooltip on a tab's buttons (the tab's card is its hover).
        .accessibilityLabel(Text(tab.muted ? "Unmute tab" : "Mute tab"))
    }
}

/// The Reader button on an unselected tab wide enough for it (TabButtons); no tooltip. A click brings the tab
/// to the front and opens Reader over it (or closes it).
private struct TabReaderGlyph: View {
    @ObservedObject var tab: BrowserTab
    let browser: BrowserModel
    let ws: WorkspaceModel
    @ObservedObject private var center = ReaderCenter.shared

    var body: some View {
        let on = center.open?.tabID == tab.id
        Button { Self.toggle(tab, browser: browser, ws: ws) } label: {
            Group {
                if center.loading == tab.id { ProgressView().controlSize(.mini) }
                else { Image(systemName: "text.alignleft").font(.system(size: 11, weight: .semibold)) }
            }
            .foregroundStyle(on ? WS.onInk : WS.text2)
            .frame(width: 22, height: 18)
            .background(on ? WS.ink : WS.soft, in: Capsule())
        }
        .buttonStyle(.liaPlain)
        .liaPointer()
        .accessibilityLabel(Text(on ? "Close Reader" : "Show Reader"))
        .transition(.opacity)
    }

    @MainActor static func toggle(_ tab: BrowserTab, browser: BrowserModel, ws: WorkspaceModel) {
        let center = ReaderCenter.shared
        if center.open?.tabID == tab.id { center.open = nil; return }
        if browser.selectedID != tab.id { browser.selectedID = tab.id }
        center.show(tab, ws: ws)
    }
}

// MARK: - hover card

/// The hovered tab and where it is, for its card drawn at window level (never clipped by the tab row).
struct TabPreviewKey: PreferenceKey {
    struct Item {
        let tab: BrowserTab
        let anchor: Anchor<CGRect>
        /// A group header's card (its tabs) instead of a tab's; `tab` is then the group's first tab.
        var group: TabGroupPreview? = nil
        var key: String { group.map { "group-" + $0.id } ?? tab.id.uuidString }
    }
    // A nested type named Value clashed with the protocol's own Value (the build error); Item? is the value.
    static let defaultValue: Item? = nil
    static func reduce(value: inout Item?, nextValue: () -> Item?) { value = value ?? nextValue() }
}

/// What a group header's hover card lists.
struct TabGroupPreview {
    let id: String
    let name: String
    let tabs: [BrowserTab]
}

/// The window's hover card: a tab's (TabHoverCard) or a group's (TabGroupHoverCard).
struct TabPreviewCard: View {
    let item: TabPreviewKey.Item

    var body: some View {
        if let g = item.group { TabGroupHoverCard(group: g) } else { TabHoverCard(tab: item.tab) }
    }
}

/// Hovering a group's header lists its tabs (favicon and title), up to eight, then "+N more".
struct TabGroupHoverCard: View {
    let group: TabGroupPreview
    static let maxRows = 8

    var body: some View {
        let shown = Array(group.tabs.prefix(Self.maxRows))
        let more = group.tabs.count - shown.count
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text(group.name).font(LiaFont.ui(13, .semibold)).foregroundStyle(WS.ink).lineLimit(1)
                Spacer(minLength: 6)
                Text(group.tabs.count == 1 ? "1 tab" : "\(group.tabs.count) tabs")
                    .font(LiaFont.ui(11.5)).foregroundStyle(WS.text3).monospacedDigit()
            }
            VStack(alignment: .leading, spacing: 2) {
                ForEach(shown, id: \.id) { t in TabGroupHoverRow(tab: t) }
            }
            if more > 0 {
                Text("+\(more) more").font(LiaFont.ui(11.5, .medium)).foregroundStyle(WS.text3)
                    .padding(.leading, 2)
            }
        }
        .padding(10)
        .frame(width: 260, alignment: .leading)
        .wsGlass(14)
        .shadow(color: Color.black.opacity(0.12), radius: 16, y: 6)
        .allowsHitTesting(false)
        .accessibilityElement(children: .combine)
    }
}

private struct TabGroupHoverRow: View {
    @ObservedObject var tab: BrowserTab

    var body: some View {
        HStack(spacing: 8) {
            GroupFavicon(tab: tab, size: 15)
            Text(tab.chipTitle).font(LiaFont.ui(12.5)).foregroundStyle(WS.text2).lineLimit(1)
        }
        .frame(height: 22)
    }
}

/// Page pictures for the hover cards: taken when first asked, kept 60 s per tab.
@MainActor
final class TabSnapshotCache {
    static let shared = TabSnapshotCache()
    private var items: [UUID: (image: NSImage, at: Date)] = [:]

    func image(for tab: BrowserTab) async -> NSImage? {
        if let c = items[tab.id], Date().timeIntervalSince(c.at) < 60 { return c.image }
        // A sleeping tab has no live page: its last picture.
        if tab.asleep || tab.pendingURL != nil { return tab.snapshot }
        if tab.isStart { return nil }
        // A tab whose page was never loaded has no view to picture (asking would make one): the placeholder.
        if tab.loadedWebView == nil { return tab.snapshot }
        let config = WKSnapshotConfiguration()
        config.snapshotWidth = NSNumber(value: 560)
        let img: NSImage? = await withCheckedContinuation { cont in
            tab.webView.takeSnapshot(with: config) { image, _ in cont.resume(returning: image) }
        }
        items = items.filter { Date().timeIntervalSince($0.value.at) < 60 }
        if let img { items[tab.id] = (img, Date()) }
        return img ?? tab.snapshot
    }
}

/// Title, host and a picture of the page, under the hovered tab.
struct TabHoverCard: View {
    @ObservedObject var tab: BrowserTab
    @State private var image: NSImage?
    /// The picture's place shimmers while it is taken.
    @State private var loading = true

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 8) {
                GroupFavicon(tab: tab, size: 16).padding(.top, 1)
                VStack(alignment: .leading, spacing: 2) {
                    Text(tab.chipTitle).font(LiaFont.ui(13, .semibold)).foregroundStyle(WS.ink).lineLimit(2)
                    if let h = tab.savedURL?.host {
                        Text(h).font(LiaFont.ui(11.5)).foregroundStyle(WS.text3).lineLimit(1)
                    }
                    if tab.asleep {
                        Text("Sleeping to save memory").font(LiaFont.ui(11)).foregroundStyle(WS.text3)
                    }
                }
            }
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: 256, height: 150, alignment: .top)
                    .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).stroke(WS.line, lineWidth: 1))
                    .transition(.opacity)
            } else if loading && !tab.isStart {
                WSSkeletonBlock(width: 256, height: 150, radius: 9).wsShimmer().transition(.opacity)
            } else {
                // No picture (a tab never loaded, a start page): its place holds the site's icon.
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(WS.soft)
                    .frame(width: 256, height: 96)
                    .overlay { GroupFavicon(tab: tab, size: 28).opacity(0.85) }
                    .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).stroke(WS.line, lineWidth: 1))
                    .transition(.opacity)
            }
        }
        .padding(10)
        .frame(width: 276, alignment: .leading)
        .wsGlass(14)
        .shadow(color: Color.black.opacity(0.12), radius: 16, y: 6)
        .animation(WSMotion.micro, value: image == nil)
        .task(id: tab.id) {
            image = await TabSnapshotCache.shared.image(for: tab)
            loading = false
        }
        .allowsHitTesting(false)
        .accessibilityElement(children: .combine)
    }
}

/// Loading is a thin ring around the icon. a sleeping tab keeps its icon (it
/// vanished when the tab slept), slightly softened; the last icon seen for the tab or its host stands in.
struct TabFavicon: View {
    @ObservedObject var tab: BrowserTab

    /// The live icon, else the tab's last one, else its host's (memory, then the disk cache).
    private var icon: NSImage? {
        if let f = tab.favicon { return f }
        return TabIconMemory.icon(tab: tab.id, host: tab.savedURL?.host)
    }

    var body: some View {
        ZStack {
            Group {
                if let f = icon { Image(nsImage: f).resizable().interpolation(.high) }
                else { Image(systemName: "globe").resizable().foregroundStyle(WS.text3) }
            }
            .frame(width: 15, height: 15)
            .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
            .opacity(tab.asleep ? 0.7 : 1)
            if tab.isLoading {
                Circle().stroke(WS.line2, lineWidth: 1.6)
                Circle()
                    .trim(from: 0, to: CGFloat(max(0.06, min(1, tab.progress))))
                    .stroke(WS.blue, style: StrokeStyle(lineWidth: 1.6, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .animation(.easeOut(duration: 0.25), value: tab.progress)
            }
        }
        .frame(width: 21, height: 21)
        .animation(WSMotion.micro, value: tab.isLoading)
        .onAppear { remember(tab.favicon) }
        .onChange(of: tab.favicon) { _, f in remember(f) }
        .accessibilityHidden(true)
    }

    private func remember(_ f: NSImage?) {
        guard let f else { return }
        TabIconMemory.remember(f, tab: tab.id, host: tab.url?.host ?? tab.savedURL?.host)
    }
}

// MARK: - omnibox (..05)

/// The address field's state, shared by the tab that edits and the suggestions drawn at window level.
@MainActor
final class OmniboxModel: ObservableObject {
    enum Action { case go(URL), switchTab(UUID), askTeam(String), askAgent(String, String), pickAgent(String), siteMode(String) }
    struct Row: Identifiable {
        let id: String
        let title: String
        let detail: String
        let symbol: String
        var agent: AgentInfo? = nil
        var icon: NSImage? = nil
        let action: Action
    }

    /// At most this many suggestions.
    static let maxRows = 8

    @Published private(set) var editingTab: UUID?
    @Published var text = "" {
        didSet { if !quiet, text != oldValue { changed(from: oldValue) } }
    }
    /// The inline completion's tail, shown selected after the typed text.
    @Published private(set) var tail = ""
    @Published private(set) var rows: [Row] = []
    @Published var index = 0 { didSet { picked = true } }
    /// The person moved to a row (arrows or pointer) since the list was built; only then \u{21E7}\u{232B} forgets it.
    private var picked = false
    /// The agent the field writes to (/21): picked from the "@" list (then the text is the task) or named in
    /// a typed "@name task". Shown as a chip at the start of the field.
    @Published private(set) var agentChip: AgentInfo?
    /// The agent picked from the "@" list; Backspace on the empty field takes it away.
    private var pinnedAgent: AgentInfo?
    /// The site the field searches (keyword + Tab), nil: the usual field.
    @Published private(set) var siteSearch: SiteSearch?
    /// The pointer is on the suggestions: losing focus to a click there does not end the editing.
    var hoverList = false
    /// The address field's dictation ('s engine).
    lazy var dictation = ChatDictation()

    private var quiet = false
    private var original = ""
    /// The completion's address (stripped, as shown) and where it goes.
    private var completedShown: String?
    private var completedURL: URL?
    /// Every visited page, ranked; built off the main thread when the field opens.
    private var history = OmniIndex.empty
    private var pins: [SavedTab] = []
    private var indexToken = 0
    private weak var tab: BrowserTab?
    private weak var browser: BrowserModel?
    private weak var ws: WorkspaceModel?
    private let keys = WSKeyMonitor()

    func begin(tab: BrowserTab, browser: BrowserModel, ws: WorkspaceModel) {
        self.tab = tab; self.browser = browser; self.ws = ws
        original = tab.isStart ? "" : (tab.url?.absoluteString ?? "")
        quiet = true; text = original; quiet = false
        clearCompletion(); rows = []; index = 0; agentChip = nil; pinnedAgent = nil; hoverList = false; siteSearch = nil
        editingTab = tab.id
        prepareIndex(account: browser.account)
        prepareEntities(ws)
        keys.start { [weak self] e in
            MainActor.assumeIsolated { self?.handle(e) ?? false }
        }
    }

    /// The history snapshot is copied here (cached in memory, cheap); stripping, lowercasing and sorting run
    /// detached. Until it lands the list has no history rows; then it is rebuilt unless the person moved in it.
    private func prepareIndex(account: String?) {
        indexToken += 1
        let token = indexToken
        let src = HistoryStore.entries(account).map { OmniIndex.Source(url: $0.url, title: $0.title, visits: $0.visits, last: $0.last) }
        pins = BrowserMemory.pinned(account: account)
        let now = Date().timeIntervalSince1970
        Task { [weak self] in
            let built = await Task.detached(priority: .userInitiated) { OmniIndex.build(src, now: now) }.value
            guard let self, self.indexToken == token, self.editingTab != nil else { return }
            self.history = built
            if !self.picked, !self.text.isEmpty { self.rebuild() }
        }
    }

    /// The workspace's campaign, ad set and ad names, read in the background when due (OmniEntityCache);
    /// when they land the list is rebuilt unless the person moved in it.
    private func prepareEntities(_ ws: WorkspaceModel) {
        OmniEntityCache.prepare(account: ws.profile?.metaAccount, auth: ws.auth) { [weak self] in
            guard let self, self.editingTab != nil, !self.picked, !self.text.isEmpty else { return }
            self.rebuild()
        }
    }

    /// What dictation heard replaces the text (the suggestions follow).
    func dictated(_ t: String) {
        guard editingTab != nil, !t.isEmpty else { return }
        text = t
    }

    func dictationFailed(_ e: String) { ws?.show(e, symbol: "mic.slash") }

    func end() {
        editingTab = nil
        indexToken += 1
        clearCompletion(); rows = []; agentChip = nil; pinnedAgent = nil; hoverList = false; siteSearch = nil
        history = .empty; pins = []
        keys.stop()
    }

    /// Esc puts the address back and leaves.
    func cancel() {
        quiet = true; text = original; quiet = false
        end()
    }

    func move(_ d: Int) {
        guard !rows.isEmpty else { return }
        index = (index + d + rows.count) % rows.count
    }

    func commit() {
        guard editingTab != nil else { return }
        if rows.indices.contains(index) { perform(rows[index]); return }
        if let a = pinnedAgent {
            // A chip and no text: nothing to send yet.
            let task = text.trimmingCharacters(in: .whitespaces)
            guard !task.isEmpty else { return }
            send(task, to: a.id)
        } else if let site = siteSearch {
            if let u = site.url(text), !text.trimmingCharacters(in: .whitespaces).isEmpty { tab?.load(u) } else { return }
        } else if let u = BrowserModel.resolve(text) {
            remember(u)
            tab?.load(u)
        }
        end()
    }

    private func clearCompletion() { tail = ""; completedShown = nil; completedURL = nil }

    // MARK: site search, forget a suggestion, paste and go

    /// A keyword the field knows: the field turns into that site's search.
    private func enterSite(_ site: SiteSearch) {
        siteSearch = site
        quiet = true; text = ""; quiet = false
        clearCompletion(); rebuild()
        AccessibilityNotification.Announcement("Search \(site.name)").post()
    }

    private func leaveSite() {
        siteSearch = nil
        rebuild()
        AccessibilityNotification.Announcement("Site search off").post()
    }

    /// \u{21E7}\u{232B} on a history or typed suggestion: forgotten (HistoryStore, OmniPicks), the list rebuilt at the same place.
    private func forgetHighlighted() -> Bool {
        guard picked, rows.indices.contains(index) else { return false }
        let id = rows[index].id
        guard id.hasPrefix("h-") || id.hasPrefix("t-") else { return false }
        let url = String(id.dropFirst(2))
        HistoryStore.remove(url, account: browser?.account)
        OmniPicks.forget(url, account: browser?.account)
        history.remove(url)
        let keep = index
        rebuild()
        if !rows.isEmpty { index = min(keep, rows.count - 1) } else { picked = false }
        AccessibilityNotification.Announcement("Removed from history").post()
        return true
    }

    static func looksLikeAddress(_ s: String) -> Bool {
        guard !s.isEmpty, !s.contains(" "), !s.contains("\n") else { return false }
        if let u = URL(string: s), let scheme = u.scheme?.lowercased(), ["http", "https"].contains(scheme) { return true }
        return s.contains(".") && BrowserModel.resolve(s)?.host != nil
    }

    private var clipboard: String {
        NSPasteboard.general.string(forType: .string)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    /// Paste and Go (an address) or Paste and Search (anything else; in a site search, that site).
    func pasteAndGo() {
        let s = clipboard
        guard !s.isEmpty, editingTab != nil else { return }
        if let site = siteSearch, let u = site.url(s) { tab?.load(u) }
        else if let u = BrowserModel.resolve(s) { tab?.load(u) }
        end()
    }

    func pasteAndAsk() {
        let s = clipboard
        guard !s.isEmpty else { return }
        ws?.askTeam(s)
        end()
    }

    func perform(_ row: Row) {
        switch row.action {
        case .go(let u):
            // What was typed and where it led (never a search: its address is not what the person meant).
            if row.id != "search", !row.id.hasPrefix("site"), !row.id.hasPrefix("meta-") { remember(u) }
            tab?.load(u)
        case .switchTab(let id): browser?.selectedID = id
        case .askTeam(let s): ws?.askTeam(s)
        case .askAgent(let id, let s): send(s, to: id)
        case .pickAgent(let name):
            if let a = roster.first(where: { $0.name == name || $0.id == name }) { pin(a, rest: "") }
            return
        case .siteMode(let id):
            if let site = SiteSearch.all.first(where: { $0.id == id }) { enterSite(site) }
            return
        }
        end()
    }

    private var roster: [AgentInfo] { (ws?.roster ?? []).filter { !$0.soon } }

    /// The agent's conversation opens with the task in its composer; the person sends it.
    private func send(_ task: String, to agent: String) {
        ws?.draft(task, toAgent: agent)
    }

    private func remember(_ u: URL) {
        let typed = text.trimmingCharacters(in: .whitespaces)
        guard !typed.isEmpty, typed != original else { return }
        OmniPicks.record(fragment: typed, url: u, account: browser?.account)
    }

    /// The agent becomes the field's chip; the text left is the task.
    private func pin(_ a: AgentInfo, rest: String) {
        pinnedAgent = a
        quiet = true; text = rest; quiet = false
        clearCompletion()
        rebuild()
        AccessibilityNotification.Announcement("To \(a.name)").post()
    }

    /// Keys the field does not give SwiftUI: \u{2191}/\u{2193} through the list, Return, Esc, Backspace and \u{2192} on the completion.
    private func handle(_ e: NSEvent) -> Bool {
        guard editingTab != nil, e.window?.firstResponder is NSTextView else { return false }
        let mods = e.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if mods.contains(.command) || mods.contains(.control) || mods.contains(.option) { return false }
        // \u{21E7}\u{232B} (or \u{21E7}\u{2326}) forgets the highlighted history suggestion.
        if mods.contains(.shift), e.keyCode == 51 || e.keyCode == 117 { return forgetHighlighted() }
        // A keyword then Tab searches that site; Backspace on the empty field leaves.
        if e.keyCode == 48, !mods.contains(.shift), siteSearch == nil, pinnedAgent == nil, let site = SiteSearch.match(text) { enterSite(site); return true }
        if e.keyCode == 51, siteSearch != nil, text.isEmpty { leaveSite(); return true }
        // Backspace on the empty field takes the agent's chip away.
        if e.keyCode == 51, pinnedAgent != nil, text.isEmpty { pinnedAgent = nil; rebuild(); return true }
        switch e.keyCode {
        case 125: guard !rows.isEmpty else { return false }; move(1); return true
        case 126: guard !rows.isEmpty else { return false }; move(-1); return true
        case 36, 76: commit(); return true
        case 53: cancel(); return true
        case 51:
            // Backspace takes the completed tail away, not a typed letter.
            guard !tail.isEmpty else { return false }
            clearCompletion(); rebuild(); return true
        case 124:
            guard !tail.isEmpty, let shown = completedShown else { return false }
            quiet = true; text = shown; quiet = false
            clearCompletion(); rebuild(); return true
        default:
            return false
        }
    }

    private func changed(from old: String) {
        // "@name " with a known agent turns into the chip.
        if pinnedAgent == nil, siteSearch == nil, case let (a, rest)? = typedAgent(), text.hasSuffix(" ") || !rest.isEmpty,
           text.drop(while: { $0 == " " }).dropFirst().split(separator: " ", maxSplits: 1, omittingEmptySubsequences: false).count > 1 {
            pin(a, rest: rest)
            return
        }
        // Only while typing forward, and only where this fragment led to the same address at least twice;
        // deleting never brings the completion back. Never in a site search or to an agent.
        if siteSearch == nil, pinnedAgent == nil, text.count > old.count,
           let c = OmniPicks.completion(text, account: browser?.account), c.shown.hasPrefix(text.lowercased()) {
            completedShown = c.shown
            completedURL = c.url
            tail = String(c.shown.dropFirst(text.count))
        } else {
            clearCompletion()
        }
        rebuild()
    }

    /// "@met task" -> (Met, "task"); nil when the text names no agent.
    private func typedAgent() -> (AgentInfo, String)? {
        let trimmed = text.drop(while: { $0 == " " })
        guard trimmed.hasPrefix("@") else { return nil }
        let parts = trimmed.dropFirst().split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
        guard let name = parts.first.map({ String($0).lowercased() }),
              let a = roster.first(where: { $0.name.lowercased() == name || $0.id == name }) else { return nil }
        let rest = parts.count > 1 ? String(parts[1]).trimmingCharacters(in: .whitespaces) : ""
        return (a, rest)
    }

    private static var engineName: String {
        switch Prefs.engine {
        case "bing": return "Bing"
        case "duckduckgo": return "DuckDuckGo"
        case "perplexity": return "Perplexity"
        default: return "Google"
        }
    }

    private static func shown(_ url: String) -> String {
        var s = url
        for p in ["https://", "http://", "www."] where s.hasPrefix(p) { s.removeFirst(p.count) }
        if s.hasSuffix("/") { s.removeLast() }
        return s
    }

    /// /20: one ranked list. Navigation first (the completion or the address typed), then open tabs, addresses
    /// Typed before, pinned tabs, history by frecency, Meta names, the search, and the team last. At most `maxRows`.
    private func rebuild() {
        index = 0
        picked = false
        agentChip = pinnedAgent
        let q = text.trimmingCharacters(in: .whitespaces)
        // In a site search the one row is that site's search.
        if let site = siteSearch {
            rows = q.isEmpty ? [] : site.url(q).map { [Row(id: "site", title: q, detail: "Search \(site.name)", symbol: site.symbol, action: .go($0))] } ?? []
            return
        }
        if let a = pinnedAgent {
            rows = q.isEmpty ? [] : [Row(id: "agent-send", title: q, detail: "Write to \(a.name)", symbol: "paperplane", agent: a, action: .askAgent(a.id, q))]
            return
        }
        guard !q.isEmpty, q != original, let browser, let ws else { rows = []; return }
        if q.hasPrefix("@") { rows = agentRows(q); return }

        let lead = roster.first(where: { $0.lead })
        // A long number is a Meta campaign, ad set or ad ID.
        let met = roster.first(where: { $0.id == "met" })
        var head = OmniMetaID.rows(q, account: ws.profile?.metaAccount, met: met)
        let typedID = !head.isEmpty
        let spaced = q.contains(" ")
        let lower = q.lowercased()
        var seen: Set<String> = []
        if let shown = completedShown, let u = completedURL {
            head.append(Row(id: "complete", title: shown, detail: "Open", symbol: "globe",
                            icon: u.host.flatMap { Favicons.cached($0) }, action: .go(u)))
            seen.insert(OmniIndex.strip(u.absoluteString))
        } else if !spaced, q.contains(".") || q.contains("://") || lower.hasPrefix("localhost"), let u = BrowserModel.resolve(q), u.host != nil {
            head.append(Row(id: "open", title: Self.shown(u.absoluteString), detail: "Open address", symbol: "globe",
                            icon: u.host.flatMap { Favicons.cached($0) }, action: .go(u)))
            seen.insert(OmniIndex.strip(u.absoluteString))
        }

        var tailRows: [Row] = []
        if let s = Prefs.searchURL(q) {
            let search = Row(id: "search", title: q, detail: "Search \(Self.engineName)", symbol: "magnifyingglass", action: .go(s))
            // Navigation wins Enter; with nothing to open, Enter searches what was typed (it leads the list).
            if head.isEmpty { head.append(search) } else { tailRows.append(search) }
        }
        // A keyword offers its site's search (Tab, or pick the row).
        if let site = SiteSearch.match(q) {
            tailRows.append(Row(id: "site-\(site.id)", title: "Search \(site.name)", detail: "Press Tab", symbol: site.symbol, action: .siteMode(site.id)))
        }
        tailRows.append(Row(id: "team", title: "Ask Lia: \(q)", detail: "Lia hands it to the right agent", symbol: "sparkles",
                            agent: lead, action: .askTeam(q)))

        var budget = max(0, Self.maxRows - head.count - tailRows.count)
        var mid: [Row] = []
        func add(_ row: Row, key: String) {
            guard budget > 0, !seen.contains(key) else { return }
            seen.insert(key); mid.append(row); budget -= 1
        }

        // Open tabs in this workspace.
        let open = browser.tabs.filter { t in
            t.id != editingTab && !t.isStart &&
                (t.displayTitle.lowercased().contains(lower) || (t.url.map { OmniIndex.strip($0.absoluteString).contains(lower) } ?? false))
        }
        for t in open.prefix(3) {
            add(Row(id: "tab-\(t.id.uuidString)", title: t.displayTitle, detail: "Switch to tab", symbol: "square.on.square",
                    icon: t.favicon, action: .switchTab(t.id)), key: t.url.map { OmniIndex.strip($0.absoluteString) } ?? t.id.uuidString)
        }
        // Addresses the person typed or picked here before.
        for p in OmniPicks.typed(q, account: browser.account, limit: 3) {
            guard let u = URL(string: p.url) else { continue }
            let s = Self.shown(p.url)
            let known = history.items.first(where: { $0.url == p.url })?.title ?? ""
            let title = known.isEmpty ? s : known
            add(Row(id: "t-\(p.url)", title: title, detail: s, symbol: "arrow.up.right",
                    icon: u.host.flatMap { Favicons.cached($0) }, action: .go(u)), key: OmniIndex.strip(p.url))
        }
        // Pinned tabs (the workspace's bookmarks).
        var pinCount = 0
        for p in pins where pinCount < 2 {
            let s = OmniIndex.strip(p.url)
            guard s.contains(lower) || p.title.lowercased().contains(lower) || (p.name?.lowercased().contains(lower) ?? false),
                  let u = URL(string: p.url) else { continue }
            pinCount += 1
            add(Row(id: "p-\(p.url)", title: p.name ?? (p.title.isEmpty ? Self.shown(p.url) : p.title), detail: Self.shown(p.url),
                    symbol: "pin", icon: u.host.flatMap { Favicons.cached($0) }, action: .go(u)), key: s)
        }
        // Campaigns, ad sets and ads of the workspace's account by name. Shown after history, but history
        // cannot take every slot: up to half of what is left (at least one) is kept for them.
        var entities: [(row: Row, e: OmniEntity)] = []
        if !typedID {
            let account = ws.profile?.metaAccount
            for e in OmniEntities.matches(q, in: OmniEntityCache.entities(account, auth: ws.auth)) {
                guard let u = OmniEntities.adsManagerURL(e, account: account) else { continue }
                let symbol = e.level == .campaign ? "megaphone" : (e.level == .adSet ? "square.stack.3d.up" : "photo.on.rectangle")
                entities.append((Row(id: "meta-e-\(e.id)", title: e.name, detail: OmniEntities.detail(e), symbol: symbol, action: .go(u)), e))
            }
        }
        let reserve = min(entities.count, max(1, budget / 2), budget)
        budget -= reserve
        // History by frecency: every page ever visited.
        for c in history.matches(q, limit: budget + 2, skip: seen) {
            guard let u = URL(string: c.url) else { continue }
            let s = Self.shown(c.url)
            add(Row(id: "h-\(c.url)", title: c.title.isEmpty ? s : c.title, detail: s, symbol: "clock",
                    icon: Favicons.cached(c.host), action: .go(u)), key: c.shown)
        }
        budget += reserve
        for x in entities { add(x.row, key: "meta:" + x.e.id) }
        // Met finds the best match whatever it is (as for a typed ID, ).
        if let top = entities.first?.e, mid.contains(where: { $0.id == "meta-e-\(top.id)" }) {
            add(Row(id: "meta-ask-e", title: "Ask Met about \(top.name)", detail: "Reads it in this ad account", symbol: "bubble.left",
                    agent: met, action: .askAgent("met", OmniEntities.askMet(top))), key: "meta-ask")
        }
        rows = head + mid + tailRows
    }

    /// "@" lists the agents (figure, name, role); "@name task" offers to send it.
    private func agentRows(_ q: String) -> [Row] {
        let body = q.dropFirst()
        let parts = body.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
        let name = parts.first.map { String($0).lowercased() } ?? ""
        let rest = parts.count > 1 ? String(parts[1]).trimmingCharacters(in: .whitespaces) : ""
        if case let (a, task)? = typedAgent(), !task.isEmpty {
            agentChip = a
            return [Row(id: "agent-send", title: task, detail: "Write to \(a.name)", symbol: "paperplane", agent: a, action: .askAgent(a.id, task))]
        }
        var r: [Row] = []
        if rest.isEmpty {
            for a in roster where name.isEmpty || a.name.lowercased().hasPrefix(name) || a.id.hasPrefix(name) {
                r.append(Row(id: "agent-\(a.id)", title: a.name, detail: a.shownRole, symbol: "person", agent: a, action: .pickAgent(a.name)))
            }
        }
        if r.isEmpty, !rest.isEmpty {
            r.append(Row(id: "team", title: "Ask Lia: \(q)", detail: "Lia hands it to the right agent", symbol: "sparkles",
                         agent: roster.first(where: { $0.lead }), action: .askTeam(q)))
        }
        return Array(r.prefix(Self.maxRows))
    }
}

/// The suggestions under the address field (glass; \u{2191}/\u{2193}/Return or the mouse).
struct OmniDropdown: View {
    @ObservedObject var omni: OmniboxModel

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            ForEach(Array(omni.rows.enumerated()), id: \.element.id) { i, row in
                OmniRowView(row: row, selected: i == omni.index)
                    .contentShape(Rectangle())
                    .onHover { if $0 { omni.index = i } }
                    .onTapGesture { omni.perform(row) }
                    .liaPointer()
                    .accessibilityElement(children: .combine)
                    .accessibilityAddTraits(.isButton)
                    .accessibilityAddTraits(i == omni.index ? .isSelected : [])
                    .accessibilityAction { omni.perform(row) }
            }
        }
        .padding(6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .wsGlass(14)
        // No shadow on any dropdown: a 1 px hairline is the edge, as DropdownPanelView's.
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(AppConfig.line2, lineWidth: 1).allowsHitTesting(false))
        .onHover { omni.hoverList = $0 }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text("Suggestions"))
    }
}

private struct OmniRowView: View {
    let row: OmniboxModel.Row
    let selected: Bool

    var body: some View {
        HStack(spacing: 10) {
            Group {
                if let a = row.agent { AgentAvatar(agent: a, size: 20) }
                else if let img = row.icon { Image(nsImage: img).resizable().interpolation(.high).frame(width: 16, height: 16)
                    .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous)) }
                else { Image(systemName: row.symbol).font(.system(size: 12, weight: .medium)).foregroundStyle(WS.text2) }
            }
            .frame(width: 22, height: 22)
            Text(row.title).font(LiaFont.ui(13, .medium)).foregroundStyle(WS.ink).lineLimit(1).truncationMode(.middle)
            Text(row.detail).font(LiaFont.ui(12)).foregroundStyle(WS.text3).lineLimit(1)
            Spacer(minLength: 6)
            if selected {
                Image(systemName: "return").font(.system(size: 10, weight: .semibold)).foregroundStyle(WS.text3)
            }
        }
        .padding(.horizontal, 8)
        .frame(height: 34)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(selected ? WS.soft : Color.clear, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
    }
}

// MARK: - the page's states (..04, /02, )

/// 2 pt along the top edge of the page card in the workspace colour: quick start, smooth finish, fade.
struct PageLoadBar: View {
    @ObservedObject var tab: BrowserTab
    let color: Color
    @State private var value: Double = 0
    @State private var visible = false
    @State private var run = 0

    var body: some View {
        GeometryReader { g in
            Rectangle().fill(color)
                .frame(width: g.size.width * CGFloat(value), height: 2)
        }
        .frame(height: 2)
        .opacity(visible ? 1 : 0)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
        .onAppear { if tab.isLoading { start() } }
        .onChange(of: tab.isLoading) { _, l in if l { start() } else { finish() } }
        .onChange(of: tab.progress) { _, p in
            guard tab.isLoading else { return }
            withAnimation(.easeOut(duration: 0.3)) { value = max(value, p) }
        }
    }

    private func start() {
        run += 1
        var t = Transaction()
        t.disablesAnimations = true
        withTransaction(t) { value = 0; visible = true }
        withAnimation(.easeOut(duration: 0.35)) { value = max(0.2, tab.progress) }
    }

    private func finish() {
        let r = run
        withAnimation(.easeOut(duration: 0.25)) { value = 1 }
        withAnimation(.easeOut(duration: 0.3).delay(0.3)) { visible = false }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) {
            if run == r, !tab.isLoading {
                var t = Transaction()
                t.disablesAnimations = true
                withTransaction(t) { value = 0 }
            }
        }
    }
}

/// /03/04: the page could not load, or its process died: a calm native card instead of a blank page.
struct PageProblemCard: View {
    let agent: AgentInfo?
    let title: String
    let message: String
    var detail: String? = nil
    var retrying = false
    let actionTitle: String
    let action: () -> Void
    @State private var showDetail = false

    var body: some View {
        VStack(spacing: 14) {
            if let a = agent { AgentAvatar(agent: a, size: 72) }
            Text(title).font(LiaFont.ui(22, .semibold)).foregroundStyle(WS.ink).multilineTextAlignment(.center)
            Text(message).font(LiaFont.ui(14)).foregroundStyle(WS.text2).multilineTextAlignment(.center)
                .frame(maxWidth: 440)
                .fixedSize(horizontal: false, vertical: true)
            if retrying {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("Trying again by itself").font(LiaFont.ui(12)).foregroundStyle(WS.text3)
                }
            }
            Button(actionTitle, action: action)
                .buttonStyle(WSButtonStyle(primary: true))
                .liaPointer()
            if let d = detail {
                DisclosureGroup("Details", isExpanded: $showDetail) {
                    Text(d).font(LiaFont.mono(12)).foregroundStyle(WS.text2)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.top, 4)
                }
                .font(LiaFont.ui(12.5))
                .foregroundStyle(WS.text2)
                .frame(maxWidth: 320)
            }
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(WS.surface)
        .accessibilityElement(children: .contain)
    }
}

/// /02: the find bar at the top right of the page card. WebKit selects and scrolls to each match.
struct FindBar: View {
    @ObservedObject var tab: BrowserTab
    @ObservedObject var ws: WorkspaceModel
    @State private var query = ""
    @State private var total = 0
    @State private var current = 0
    @State private var job: Task<Void, Never>?
    @State private var keys = WSKeyMonitor()
    /// Also count the matches in every loaded tab of the workspace.
    @State private var allTabs = false
    @FocusState private var focus: Bool

    private var counter: String {
        if query.isEmpty { return "" }
        return total == 0 ? "No matches" : "\(current) of \(total)"
    }

    var body: some View {
        VStack(alignment: .trailing, spacing: 6) {
            bar
            if allTabs, let b = ws.currentBrowser {
                FindAllTabsList(browser: b, query: query, current: tab.id) { t in pick(t) }
                    .transition(.opacity)
            }
        }
        .animation(WSMotion.micro, value: allTabs)
    }

    /// That tab in front, its find bar on the same text.
    private func pick(_ t: BrowserTab) {
        guard t.id != tab.id else { step(false); return }
        WSFindCarry.query = query
        WSFindCarry.allTabs = true
        ws.currentBrowser?.selectedID = t.id
    }

    private var allTabsToggle: some View {
        Button { allTabs.toggle(); WSFindCarry.allTabs = allTabs } label: {
            Image(systemName: "square.stack")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(allTabs ? WS.blue : WS.text2)
                .frame(width: 24, height: 24)
                .background(allTabs ? WS.blue.opacity(0.12) : Color.clear, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
        }
        .buttonStyle(.liaPlain)
        .liaHover(.icon, radius: 7)
        .liaTip(allTabs ? "Search this tab only" : "Search All Tabs")
        .accessibilityLabel(Text("Search All Tabs"))
        .accessibilityValue(Text(allTabs ? "On" : "Off"))
    }

    // In two steps: one chain with the field, the toggle and the hooks was long for the type checker.
    private var bar: some View {
        barHooks(barFace)
    }

    private var barFace: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass").font(.system(size: 12, weight: .medium)).foregroundStyle(WS.text3)
            TextField("Find on page", text: $query)
                .textFieldStyle(.plain)
                .font(LiaFont.ui(13))
                .focused($focus)
                .frame(width: 180)
                .onSubmit { step(false) }
                .onExitCommand { close() }
                .accessibilityLabel(Text("Find on page"))
            Text(counter)
                .font(LiaFont.ui(12)).monospacedDigit()
                .foregroundStyle(total == 0 && !query.isEmpty ? WS.bad : WS.text3)
                .fixedSize()
                .accessibilityLabel(Text(counter.isEmpty ? "" : counter))
            allTabsToggle
            Divider().frame(height: 16)
            icon("chevron.up", "Previous match") { step(true) }
            icon("chevron.down", "Next match") { step(false) }
            icon("xmark", "Close find bar") { close() }
        }
        .padding(.leading, 12)
        .padding(.trailing, 6)
        .frame(height: 38)
        .wsGlass(14)
        .shadow(color: Color.black.opacity(0.10), radius: 14, y: 6)
    }

    private func barHooks<V: View>(_ v: V) -> some View {
        v
        .onAppear {
            DispatchQueue.main.async { focus = true }
            keys.start { e in handleKey(e) }
            // Opened from another tab's "all tabs" list: the same text, the same mode.
            allTabs = WSFindCarry.allTabs
            if let q = WSFindCarry.query { WSFindCarry.query = nil; query = q }
        }
        .onDisappear { keys.stop(); job?.cancel() }
        .onChange(of: query) { _, q in search(q) }
        .onChange(of: ws.findAgain) { _, _ in
            focus = true
            step(ws.findAgainBackwards)
        }
        // (find bar stuck): \u{2318}F with the bar already open did nothing (findOpen was already
        // true), so after a click into the page the bar kept no keys and could not be got back. Now it takes the
        // keys again with its text selected, as in Safari.
        .onChange(of: ws.findFocus) { _, _ in
            focus = true
            DispatchQueue.main.async { NSApp.sendAction(#selector(NSText.selectAll(_:)), to: nil, from: nil) }
        }
        // A reload or a new page: the count was the old page's; counted again once the page is here.
        .onChange(of: tab.isLoading) { _, loading in if !loading, !query.isEmpty { recount() } }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text("Find bar"))
    }

    private func icon(_ name: String, _ label: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: name).font(.system(size: 11, weight: .semibold)).foregroundStyle(WS.text2)
                .frame(width: 24, height: 24)
        }
        .buttonStyle(.liaPlain)
        .liaHover(.icon, radius: 7)
        .accessibilityLabel(Text(label))
    }

    /// Return: next, Shift-Return: previous, Esc: close (only while the find field has the keys).
    private func handleKey(_ e: NSEvent) -> Bool {
        // Only while the field really has the keys: a stale focus flag (the page was clicked) must never eat the
        // page's own Return / Esc.
        guard focus, let editor = e.window?.firstResponder as? NSTextView, editor.isFieldEditor else { return false }
        switch e.keyCode {
        case 36, 76: step(e.modifierFlags.contains(.shift)); return true
        case 53: close(); return true
        default: return false
        }
    }

    private func search(_ q: String) {
        job?.cancel()
        guard !q.isEmpty else { total = 0; current = 0; return }
        job = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 120_000_000)
            guard !Task.isCancelled else { return }
            let n = await tab.countMatches(q)
            guard !Task.isCancelled else { return }
            var found = false
            if n > 0 { found = await tab.find(q) }
            guard !Task.isCancelled else { return }
            total = n
            current = found ? 1 : 0
        }
    }

    /// The count again without moving the page (a reload finished under the open bar).
    private func recount() {
        job?.cancel()
        let q = query
        job = Task { @MainActor in
            let n = await tab.countMatches(q)
            guard !Task.isCancelled, q == query else { return }
            total = n
            current = n == 0 ? 0 : min(max(current, 1), n)
        }
    }

    private func step(_ back: Bool) {
        guard !query.isEmpty else { return }
        guard total > 0 else { search(query); return }   // the page changed since it was counted: count again
        let q = query
        Task { @MainActor in
            guard await tab.find(q, backwards: back) else { return }
            if back { current = current <= 1 ? total : current - 1 } else { current = current >= total ? 1 : current + 1 }
        }
    }

    private func close() {
        WSFindCarry.allTabs = false
        ws.findOpen = false
    }
}

/// A short centred pill with the new zoom.
struct ZoomFlash: View {
    @ObservedObject var tab: BrowserTab
    @State private var shown = false
    @State private var token = 0

    var body: some View {
        ZStack {
            if shown {
                Text("\(Int((tab.zoom * 100).rounded()))%")
                    .font(LiaFont.ui(15, .semibold)).monospacedDigit()
                    .foregroundStyle(WS.ink)
                    .padding(.horizontal, 18)
                    .frame(height: 38)
                    .wsGlass(19)
                    .transition(.scale(scale: 0.9).combined(with: .opacity))
                    .accessibilityLabel(Text("Zoom \(Int((tab.zoom * 100).rounded())) percent"))
            }
        }
        .allowsHitTesting(false)
        .onChange(of: tab.zoom) { _, _ in
            token += 1
            let t = token
            withAnimation(WSMotion.micro) { shown = true }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
                if token == t { withAnimation(WSMotion.micro) { shown = false } }
            }
        }
    }
}

/// A page asks for the camera or microphone: a glass card under the top bar, never a modal.
struct PermissionCard: View {
    let tab: BrowserTab
    let ask: PermissionAsk
    @State private var remember = true

    private var symbol: String {
        switch ask.kind {
        case .camera, .cameraAndMicrophone: return "video.fill"
        case .microphone: return "mic.fill"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: symbol)
                    .font(.system(size: 13, weight: .semibold)).foregroundStyle(WS.ink)
                    .frame(width: 30, height: 30)
                    .background(WS.soft, in: Circle())
                (Text(ask.host).fontWeight(.semibold) + Text(" wants to \(ask.what)"))
                    .font(LiaFont.ui(13)).foregroundStyle(WS.ink)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Toggle("Remember for this site", isOn: $remember)
                .toggleStyle(.checkbox)
                .font(LiaFont.ui(12))
                .foregroundStyle(WS.text2)
            HStack(spacing: 8) {
                Spacer()
                Button("Don't Allow") { tab.answerPermission(false, remember: remember) }
                    .buttonStyle(WSButtonStyle(small: true))
                Button("Allow") { tab.answerPermission(true, remember: remember) }
                    .buttonStyle(WSButtonStyle(primary: true, small: true))
            }
        }
        .padding(14)
        .frame(width: 330)
        .wsGlass(16)
        .shadow(color: Color.black.opacity(0.12), radius: 16, y: 6)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text("\(ask.host) wants to \(ask.what)"))
    }
}

/// A sleeping tab shows its last picture until the page is back.
struct TabSnapshot: View {
    let image: NSImage
    var body: some View {
        GeometryReader { g in
            Image(nsImage: image)
                .resizable()
                .aspectRatio(contentMode: .fill)
                .frame(width: g.size.width, height: g.size.height, alignment: .top)
                .clipped()
        }
        .background(WS.surface)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

// MARK: - downloads (..05)

/// Shows once there is a download; a ring while any runs. Click: the popover.
struct DownloadsButton: View {
    @ObservedObject var ws: WorkspaceModel
    @ObservedObject private var center = DownloadsCenter.shared
    @Environment(\.accessibilityReduceMotion) private var reduce
    @Environment(\.wsBarOnDark) private var onDark
    @State private var pulse = false
    /// Hidden by itself 10 minutes after the last download finished; back when a new one starts.
    @State private var idle = false
    @State private var idleToken = 0
    /// When the popover last closed: the mouse-down that closes it must not reopen it on mouse-up.
    @State private var closedAt = Date.distantPast

    private static let hideAfter: TimeInterval = 600

    var body: some View {
        face
            .animation(WSMotion.micro, value: idle)
            .onAppear { if center.active.isEmpty { scheduleHide() } }
            .onChange(of: center.active.count) { _, n in
                if n > 0 { idleToken += 1; idle = false } else { scheduleHide() }
            }
            .onChange(of: center.flight) { _, _ in idle = false }
            .onChange(of: ws.showDownloads) { _, open in if open { idle = false } else { closedAt = Date() } }
    }

    /// After the quiet period (not while the list is open: then a minute later).
    private func scheduleHide(after delay: TimeInterval = DownloadsButton.hideAfter) {
        idleToken += 1
        let t = idleToken
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            guard t == idleToken, center.active.isEmpty else { return }
            if ws.showDownloads { scheduleHide(after: 60) } else { idle = true }
        }
    }

    @ViewBuilder private var face: some View {
        if !center.items.isEmpty && !idle {
            Button {
                // Explicit, and never a reopen right after the popover closed on this same click (it closes on the
                // mouse-down outside it, and a toggle on mouse-up brought it straight back).
                if ws.showDownloads { ws.showDownloads = false }
                else if Date().timeIntervalSince(closedAt) > 0.3 { ws.showDownloads = true }
            } label: {
                ZStack {
                    if !center.active.isEmpty {
                        // Items publish their own progress; the ring reads the total twice a second.
                        TimelineView(.periodic(from: .now, by: 0.5)) { _ in
                            ring(center.overall)
                        }
                    }
                    Image(systemName: "arrow.down")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(BarInk.text2(onDark))
                }
                .frame(width: 30, height: 30)
                // The whole 30 pt square takes the click (it was only the glyph's pixels: ~1 click in 5 landed).
                .contentShape(Rectangle())
                .scaleEffect(pulse ? 1.22 : 1)
            }
            .buttonStyle(.liaPlain)
            .liaHover(.icon, radius: 10)
            .wsReportFrame("downloads")
            .tourAnchor("downloads")
            .transition(.opacity)
            .popover(isPresented: $ws.showDownloads, arrowEdge: .bottom) { DownloadsPopover(ws: ws) }
            .onChange(of: center.flight) { _, _ in
                // The button answers when the file lands (at once with Reduce Motion).
                DispatchQueue.main.asyncAfter(deadline: .now() + (reduce ? 0.05 : 0.75)) {
                    withAnimation(.spring(response: 0.25, dampingFraction: 0.5)) { pulse = true }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { withAnimation(WSMotion.micro) { pulse = false } }
                }
            }
            .accessibilityLabel(Text("Downloads"))
            .accessibilityValue(Text(center.active.isEmpty ? "\(center.items.count) items" : "\(center.active.count) running, \(Int(center.overall * 100)) percent"))
        }
    }

    private func ring(_ p: Double) -> some View {
        ZStack {
            Circle().stroke(WS.line2, lineWidth: 2)
            Circle()
                .trim(from: 0, to: CGFloat(max(0.04, min(1, p))))
                .stroke(WS.blue, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                .rotationEffect(.degrees(-90))
        }
        .frame(width: 24, height: 24)
    }
}

/// /04/05: every download with its state; Cancel, Retry, Show in Finder; double-click opens; drag a finished one out.
private struct DownloadsPopover: View {
    /// The roster, for the avatar of the agent that started a download.
    let ws: WorkspaceModel
    @ObservedObject private var center = DownloadsCenter.shared
    /// The row Space previews (a click selects; \u{2191}/\u{2193} move).
    @State private var selected: UUID?
    @State private var keys = WSKeyMonitor()
    @State private var quickLook = WSQuickLookHost.Box()

    var body: some View {
        content
            .background(WSQuickLookHost(box: quickLook))
            .onAppear { keys.start { e in MainActor.assumeIsolated { handleKey(e) } } }
            .onDisappear { keys.stop(); quickLook.close() }
    }

    private var selectedItem: DownloadsCenter.Item? { center.items.first { $0.id == selected } }

    /// Rows with the installer warning are taller.
    private var riskyCount: Int { center.items.filter { $0.state == .done && WSDownloadSafety.isRisky($0) }.count }

    /// Space: Quick Look of the selected finished file; \u{2191}/\u{2193}: the selection; Esc closes Quick Look first.
    private func handleKey(_ e: NSEvent) -> Bool {
        let mods = e.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard mods.isDisjoint(with: [.command, .control, .option]), quickLook.owns(e) else { return false }
        switch e.keyCode {
        case 49:
            guard let it = selectedItem else { return false }
            preview(it)
            return true
        case 53:
            return quickLook.close()
        case 125, 126:
            let ids = center.items.map(\.id)
            guard !ids.isEmpty else { return false }
            let cur = selected.flatMap { ids.firstIndex(of: $0) }
            let next = cur.map { min(ids.count - 1, max(0, $0 + (e.keyCode == 125 ? 1 : -1))) } ?? 0
            selected = ids[next]
            if quickLook.isOpen, let it = selectedItem { preview(it) }
            return true
        default:
            return false
        }
    }

    private func preview(_ it: DownloadsCenter.Item) {
        guard it.state == .done, let u = it.dest, FileManager.default.fileExists(atPath: u.path) else { return }
        quickLook.toggle(u)
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Downloads").font(LiaFont.ui(14, .semibold)).foregroundStyle(WS.ink)
                Spacer()
                Button("Clear") { center.clearFinished() }
                    .buttonStyle(WSButtonStyle(small: true))
                    .disabled(!center.items.contains { $0.state != .running })
                    .accessibilityLabel(Text("Clear finished downloads"))
            }
            .padding(.horizontal, 14)
            .padding(.top, 12)
            .padding(.bottom, 8)
            LastDownloadCard(ws: ws)
                .padding(.horizontal, 10)
                .padding(.bottom, 8)
            if center.items.isEmpty {
                VStack(spacing: 4) {
                    Text("No downloads").font(LiaFont.ui(13, .medium)).foregroundStyle(WS.text2)
                    Text("Files you or the agents download land here.").font(LiaFont.ui(12)).foregroundStyle(WS.text3)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 24)
                .accessibilityElement(children: .combine)
            } else {
                ScrollView {
                    VStack(spacing: 2) {
                        ForEach(center.items) { it in
                            DownloadRow(item: it, agent: ws.agent(it.agent), selected: it.id == selected,
                                        onSelect: { selected = it.id }, onQuickLook: { selected = it.id; preview(it) })
                        }
                    }
                    .padding(.horizontal, 6)
                    .padding(.bottom, 8)
                }
                .frame(height: min(CGFloat(center.items.count) * 48 + CGFloat(riskyCount) * 30 + 8, 380))
            }
        }
        .frame(width: 390)
    }
}

private struct DownloadRow: View {
    @ObservedObject var item: DownloadsCenter.Item
    /// The agent whose browser downloaded it (nil: the person).
    var agent: AgentInfo? = nil
    var selected = false
    var onSelect: () -> Void = {}
    var onQuickLook: () -> Void = {}
    @State private var hover = false
    private var center: DownloadsCenter { DownloadsCenter.shared }

    private var icon: NSImage {
        if item.state == .done, let d = item.dest, FileManager.default.fileExists(atPath: d.path) {
            return NSWorkspace.shared.icon(forFile: d.path)
        }
        let ext = item.dest?.pathExtension ?? (item.name as NSString).pathExtension
        return NSWorkspace.shared.icon(for: UTType(filenameExtension: ext) ?? .data)
    }

    private static func bytes(_ n: Int64) -> String { ByteCountFormatter.string(fromByteCount: n, countStyle: .file) }

    private var status: String {
        switch item.state {
        case .running:
            var parts: [String] = []
            parts.append(item.total > 0 ? "\(Self.bytes(item.received)) of \(Self.bytes(item.total))" : Self.bytes(item.received))
            if item.bytesPerSecond > 1 { parts.append(Self.bytes(Int64(item.bytesPerSecond)) + "/s") }
            if let r = item.remaining {
                parts.append(r < 60 ? "\(max(1, Int(r))) s left" : "\(Int((r / 60).rounded(.up))) min left")
            }
            return parts.joined(separator: " \u{00B7} ")
        case .done: return item.total > 0 ? "Done \u{00B7} \(Self.bytes(item.total))" : "Done"
        case .failed: return "Failed"
        case .cancelled: return "Cancelled"
        }
    }

    var body: some View {
        HStack(spacing: 9) {
            fileIcon
            VStack(alignment: .leading, spacing: 2) {
                Text(item.name).font(LiaFont.ui(13, .medium)).foregroundStyle(WS.ink).lineLimit(1).truncationMode(.middle)
                if item.state == .running {
                    ProgressView(value: min(1, max(0, item.fraction)))
                        .progressViewStyle(.linear)
                        .controlSize(.small)
                        .tint(WS.blue)
                }
                Text(statusLine).font(LiaFont.ui(11.5)).foregroundStyle(item.state == .failed ? WS.bad : WS.text3).lineLimit(1)
                DownloadRiskLine(item: item)
            }
            Spacer(minLength: 4)
            // Compact, native: 22 pt bordered buttons, the whole shape clickable.
            if item.state == .running {
                rowButton("xmark.circle.fill", "Cancel download") { center.cancel(item) }
            }
            if item.state == .failed || item.state == .cancelled {
                rowButton("arrow.clockwise", "Retry download") { center.retry(item) }
                    .disabled(item.resumeData == nil || item.webView == nil)
            }
            if item.dest != nil && item.state != .running {
                rowButton("magnifyingglass", "Show in Finder") { center.reveal(item) }
            }
        }
        .padding(.horizontal, 8).padding(.vertical, 6)
        .background(selected ? WS.blue.opacity(0.10) : (hover ? WS.soft : Color.clear),
                    in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .contentShape(Rectangle())
        .onHover { hover = $0 }
        // 0.2.11: one tap gesture; the second click of a double click opens (LiaClicks.kind).
        .liaClicks(single: onSelect, double: { WSDownloadSafety.open(item) })
        .onDrag {
            guard item.state == .done, let d = item.dest, let p = NSItemProvider(contentsOf: d) else { return NSItemProvider() }
            return p
        }
        .contextMenu {
            Button("Open") { WSDownloadSafety.open(item) }.disabled(item.state != .done)
            Button("Quick Look") { onQuickLook() }.disabled(item.state != .done)
            Button("Show in Finder") { center.reveal(item) }.disabled(item.dest == nil)
            Divider()
            Button("Remove from List") { center.remove(item) }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text("\(item.name), \(statusLine)"))
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityHint(Text(item.state == .done ? "Space previews with Quick Look" : ""))
        .accessibilityAction(named: Text("Open")) { WSDownloadSafety.open(item) }
        .accessibilityAction(named: Text("Quick Look")) { onQuickLook() }
        .accessibilityAction(named: Text("Show in Finder")) { center.reveal(item) }
    }

    /// The file's icon; the agent's small avatar on its corner when an agent downloaded it.
    private var fileIcon: some View {
        Image(nsImage: icon).resizable().interpolation(.high).frame(width: 26, height: 26)
            .opacity(item.state == .failed || item.state == .cancelled ? 0.55 : 1)
            .overlay(alignment: .bottomTrailing) {
                if let agent {
                    AgentAvatar(agent: agent, size: 14)
                        .background(Circle().fill(WS.surface).padding(-1.5))
                        .offset(x: 4, y: 4)
                        .accessibilityHidden(true)
                }
            }
    }

    /// The state, and who downloaded it when it was an agent ("by Met").
    private var statusLine: String {
        guard let agent else { return status }
        return status + " \u{00B7} by \(agent.name)"
    }

    private func rowButton(_ name: String, _ label: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: name).font(.system(size: 11, weight: .semibold))
                .frame(width: 22, height: 22)
                .contentShape(Rectangle())
        }
        .buttonStyle(DownloadMiniButtonStyle(square: true))
        .liaTip(name == "magnifyingglass" ? label : nil)
        .accessibilityLabel(Text(label))
    }
}

/// A document flies along an arc from the page to the downloads button. Reduce Motion: no flight (the
/// button pulses instead).
struct DownloadFlightLayer: View {
    let frames: WSFrameBox
    @ObservedObject private var center = DownloadsCenter.shared
    @Environment(\.accessibilityReduceMotion) private var reduce
    private struct Flight: Identifiable { let id = UUID(); let from: CGPoint; let to: CGPoint }
    @State private var flights: [Flight] = []

    var body: some View {
        ZStack {
            ForEach(flights) { f in FlightGlyph(from: f.from, to: f.to) }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
        .onChange(of: center.flight) { _, _ in
            guard !reduce else { return }
            // The button may have just appeared: its frame arrives on the next pass.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                guard let page = frames.frames["stage"], let button = frames.frames["downloads"], button.width > 0 else { return }
                let f = Flight(from: CGPoint(x: page.midX, y: page.midY), to: CGPoint(x: button.midX, y: button.midY))
                flights.append(f)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.85) { flights.removeAll { $0.id == f.id } }
            }
        }
    }
}

private struct FlightGlyph: View {
    let from: CGPoint
    let to: CGPoint
    @State private var t: CGFloat = 0

    var body: some View {
        FlightPath(t: t, from: from, to: to)
            .onAppear { withAnimation(.easeInOut(duration: 0.7)) { t = 1 } }
    }
}

private struct FlightPath: View, Animatable {
    var t: CGFloat
    let from: CGPoint
    let to: CGPoint
    var animatableData: CGFloat {
        get { t }
        set { t = newValue }
    }

    var body: some View {
        let c = CGPoint(x: (from.x + to.x) / 2, y: min(from.y, to.y) - 140)
        let u = 1 - t
        let p = CGPoint(x: u * u * from.x + 2 * u * t * c.x + t * t * to.x,
                        y: u * u * from.y + 2 * u * t * c.y + t * t * to.y)
        Image(systemName: "doc.fill")
            .font(.system(size: 30))
            .foregroundStyle(WS.blue)
            .shadow(color: Color.black.opacity(0.18), radius: 6, y: 3)
            .scaleEffect(1 - 0.6 * t)
            .opacity(t > 0.9 ? Double((1 - t) / 0.1) : 1)
            .position(p)
    }
}

// MARK: - approvals, toasts, banners

/// Changes waiting for a Yes in any workspace: an amber count; the popover opens each one.
struct ApprovalsButton: View {
    @ObservedObject var ws: WorkspaceModel

    var body: some View {
        let list = ws.approvals
        if !list.isEmpty {
            Button { ws.showApprovals.toggle() } label: {
                HStack(spacing: 5) {
                    Image(systemName: "hand.raised.fill").font(.system(size: 11, weight: .semibold))
                    Text("\(list.count)").font(LiaFont.ui(12, .semibold)).monospacedDigit()
                }
                .foregroundStyle(WS.amberInk)
                .padding(.horizontal, 10)
                .frame(height: 28)
                .background(WS.amberSoft, in: Capsule())
                .overlay(Capsule().stroke(WS.amber.opacity(0.5), lineWidth: 1))
            }
            .buttonStyle(.liaPlain)
            .liaPointer()
            .liaTip("Waiting for your Yes")
            .tourAnchor("approvals")
            .popover(isPresented: $ws.showApprovals, arrowEdge: .bottom) { ApprovalsPopover(ws: ws) }
            .accessibilityLabel(Text(list.count == 1 ? "1 change waiting for your approval" : "\(list.count) changes waiting for your approval"))
        }
    }
}

private struct ApprovalsPopover: View {
    @ObservedObject var ws: WorkspaceModel

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Waiting for your Yes").font(LiaFont.ui(14, .semibold)).foregroundStyle(WS.ink)
                .padding(.horizontal, 8).padding(.bottom, 4)
            if ws.approvals.isEmpty {
                Label("All approved", systemImage: "checkmark.circle.fill")
                    .font(LiaFont.ui(13, .medium)).foregroundStyle(WS.blue)
                    .padding(8)
            }
            ForEach(ws.approvals) { a in
                Button { ws.openApproval(a) } label: {
                    HStack(spacing: 10) {
                        if let ag = ws.agent(a.agent) { AgentAvatar(agent: ag, size: 28, status: .waiting) }
                        VStack(alignment: .leading, spacing: 2) {
                            Text(a.title).font(LiaFont.ui(13, .medium)).foregroundStyle(WS.ink).lineLimit(2)
                                .multilineTextAlignment(.leading)
                            Text([ws.agent(a.agent)?.name ?? a.agent.capitalized, a.profileName].filter { !$0.isEmpty }.joined(separator: " \u{00B7} "))
                                .font(LiaFont.ui(11.5)).foregroundStyle(WS.text3).lineLimit(1)
                        }
                        Spacer(minLength: 0)
                        Image(systemName: "chevron.right").font(.system(size: 10, weight: .semibold)).foregroundStyle(WS.text3)
                    }
                    .padding(8)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.liaPlain)
                .liaHover(.fill, radius: 10)
                .accessibilityLabel(Text("\(a.title), \(a.profileName)"))
            }
        }
        .padding(10)
        .frame(width: 340)
    }
}

/// A glass pill at the top centre for events that need nothing; a click hides it.
struct WSToastView: View {
    let toast: WorkspaceModel.Toast
    let onTap: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            if let s = toast.symbol { Image(systemName: s).font(.system(size: 12, weight: .semibold)) }
            Text(toast.text).font(LiaFont.ui(13, .medium)).lineLimit(1)
        }
        .foregroundStyle(WS.ink)
        .padding(.horizontal, 16)
        .frame(height: 36)
        .wsGlass(18)
        .shadow(color: Color.black.opacity(0.10), radius: 14, y: 5)
        .contentShape(Capsule())
        .onTapGesture(perform: onTap)
        .liaPointer()
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isStaticText)
    }
}

/// Meta stopped answering for this member: one banner under the top bar until it is reconnected.
struct MetaReconnectBanner: View {
    let onReconnect: () -> Void
    let onClose: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 13)).foregroundStyle(WS.amber)
            Text("Meta stopped answering for your account. Reconnect to keep the agents working.")
                .font(LiaFont.ui(13)).foregroundStyle(WS.amberInk)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            Button("Reconnect Meta", action: onReconnect)
                .buttonStyle(WSButtonStyle(primary: true, small: true))
                .liaPointer()
            Button(action: onClose) {
                Image(systemName: "xmark").font(.system(size: 10, weight: .bold)).foregroundStyle(WS.amberInk)
                    .frame(width: 22, height: 22)
            }
            .buttonStyle(.liaPlain)
            .liaHover(.icon, radius: 6)
            .accessibilityLabel(Text("Dismiss"))
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(WS.amberSoft, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(WS.amber.opacity(0.35), lineWidth: 1))
        .accessibilityElement(children: .contain)
    }
}

// MARK: - Quick Look in the downloads popover

/// An invisible view in the popover that takes Quick Look's panel control through the responder chain (the panel
/// asks the key window's responders), and is its data source: one file at a time.
struct WSQuickLookHost: NSViewRepresentable {
    final class Box {
        weak var view: HostView?

        @MainActor var isOpen: Bool {
            QLPreviewPanel.sharedPreviewPanelExists() && (QLPreviewPanel.shared()?.isVisible ?? false)
        }

        /// The key event belongs to the popover or to the panel (not to another window).
        @MainActor func owns(_ e: NSEvent) -> Bool {
            guard let w = e.window else { return false }
            return w === view?.window || w is QLPreviewPanel
        }

        /// Space: show this file; the same file again closes the panel.
        @MainActor func toggle(_ url: URL) {
            guard let v = view, let panel = QLPreviewPanel.shared() else { NSWorkspace.shared.open(url); return }
            if isOpen && v.url == url { panel.orderOut(nil); return }
            v.url = url
            v.window?.makeFirstResponder(v)
            panel.updateController()
            if (panel.dataSource as AnyObject?) !== v {
                // No controller found in the responder chain: open the file instead of showing an empty panel.
                NSWorkspace.shared.open(url)
                return
            }
            panel.reloadData()
            // Not key: the popover keeps the keys (Space again, arrows, Esc).
            panel.orderFront(nil)
        }

        /// True when there was a panel to close.
        @MainActor @discardableResult func close() -> Bool {
            guard isOpen, let panel = QLPreviewPanel.shared(), (panel.dataSource as AnyObject?) === view else { return false }
            panel.orderOut(nil)
            return true
        }
    }

    final class HostView: NSView, QLPreviewPanelDataSource {
        var url: URL?

        override var acceptsFirstResponder: Bool { true }

        override func acceptsPreviewPanelControl(_ panel: QLPreviewPanel!) -> Bool { url != nil }

        override func beginPreviewPanelControl(_ panel: QLPreviewPanel!) {
            panel.dataSource = self
        }

        override func endPreviewPanelControl(_ panel: QLPreviewPanel!) {
            if (panel.dataSource as AnyObject?) === self { panel.dataSource = nil }
        }

        func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int { url == nil ? 0 : 1 }

        func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> QLPreviewItem! {
            url.map { $0 as NSURL }
        }
    }

    let box: Box

    func makeNSView(context: Context) -> HostView {
        let v = HostView()
        box.view = v
        return v
    }

    func updateNSView(_ v: HostView, context: Context) { box.view = v }
}

// MARK: - recent tabs switcher

/// \u{2303}Tab: up to six of the workspace's tabs in the order they were last used, the picked one highlighted;
/// releasing \u{2303} switches to it (the window's monitor), Esc closes, a click picks.
struct MRUSwitcher: View {
    @ObservedObject var ws: WorkspaceModel
    @ObservedObject var browser: BrowserModel
    let index: Int

    private static let shown = 6

    var body: some View {
        let tabs = browser.recentTabs
        // Past the sixth the strip slides so the picked card stays in view.
        let start = index < Self.shown ? 0 : index - Self.shown + 1
        let end = min(tabs.count, start + Self.shown)
        HStack(spacing: 10) {
            ForEach(start..<max(start, end), id: \.self) { i in
                MRUCard(tab: tabs[i], selected: i == index) {
                    ws.switcher = i
                    ws.mruCommit()
                }
            }
        }
        .padding(12)
        .wsGlass(20)
        .shadow(color: Color.black.opacity(0.16), radius: 24, y: 10)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text("Recent tabs"))
        .accessibilityHint(Text("Release Control to switch, Escape to cancel"))
    }
}

private struct MRUCard: View {
    @ObservedObject var tab: BrowserTab
    let selected: Bool
    let action: () -> Void
    @State private var image: NSImage?
    @State private var loading = true

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 7) {
                thumb
                HStack(spacing: 6) {
                    TabFavicon(tab: tab)
                    Text(tab.chipTitle).font(LiaFont.ui(12, selected ? .semibold : .regular))
                        .foregroundStyle(selected ? WS.ink : WS.text2).lineLimit(1)
                }
            }
            .padding(7)
            .frame(width: 164, alignment: .leading)
            .background(selected ? WS.surface : WS.wash, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(selected ? WS.blue : Color.clear, lineWidth: 2))
            .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .buttonStyle(.liaPlain)
        .liaPointer()
        .animation(WSMotion.micro, value: selected)
        .task(id: tab.id) {
            image = await TabSnapshotCache.shared.image(for: tab)
            loading = false
        }
        .accessibilityLabel(Text(tab.displayTitle))
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    @ViewBuilder private var thumb: some View {
        ZStack {
            WS.soft
            if let image {
                Image(nsImage: image).resizable().aspectRatio(contentMode: .fill)
                    .frame(width: 150, height: 94, alignment: .top)
                    .transition(.opacity)
            } else if loading && !tab.isStart {
                WSSkeletonBlock(width: 150, height: 94, radius: 0).wsShimmer()
            } else {
                Image(systemName: tab.isStart ? "plus" : "globe")
                    .font(.system(size: 22, weight: .light)).foregroundStyle(WS.text3)
            }
        }
        .frame(width: 150, height: 94)
        .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).stroke(WS.line, lineWidth: 1))
        .animation(WSMotion.micro, value: image == nil)
        .accessibilityHidden(true)
    }
}

// MARK: - restored tab skeleton

/// A restored tab before its page first paints: its saved icon and title, and our orbit in the middle (0.2.10: was a
/// page-shaped grey skeleton; the orbit comes in after 300 ms, so a quick paint never shows it), instead of plain white.
struct RestoreSkeleton: View {
    @ObservedObject var tab: BrowserTab

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 10) {
                TabFavicon(tab: tab).scaleEffect(1.3)
                Text(tab.chipTitle).font(LiaFont.ui(16, .semibold)).foregroundStyle(WS.text2).lineLimit(1)
            }
            .padding(.bottom, 6)
            LiaLoadingOrbit(size: 120, label: "Loading")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(.bottom, 40)
        }
        .padding(28)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(WS.surface)
        .allowsHitTesting(false)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("Loading \(tab.displayTitle)"))
    }
}

/// Which window's bar menu request was answered last, and when (BrowserChrome's `.wsTabBarMenu` receiver).
@MainActor
private enum TabBarMenuClaim {
    static var last: (window: ObjectIdentifier, at: TimeInterval)?
}

// MARK: - the agent's browser pane: its tabs

/// One tab of an agent's browser in a dialogue's pane: its title (a click brings it to front) and, like a tab of the
/// main browser, a close \u{2715} (shown on hover and on the tab in front). Closing the tab an agent works in ends that
/// browser task ("the browser tab was closed", WebAgent); the pane never closes - the last tab becomes a new one.
struct AgentPaneTabChip: View {
    @ObservedObject var tab: BrowserTab
    @ObservedObject var browser: BrowserModel
    @State private var hover = false

    private var selected: Bool { tab.id == browser.selectedID }

    var body: some View {
        HStack(spacing: 2) {
            Button { browser.selectedID = tab.id } label: {
                Text(tab.displayTitle).font(LiaFont.ui(12)).lineLimit(1).foregroundStyle(selected ? WS.ink : WS.text2)
                    .padding(.leading, 10).frame(height: 28).frame(maxWidth: 150, alignment: .leading)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.liaPlain)
            .liaPointer()
            .accessibilityAddTraits(selected ? .isSelected : [])
            Button { browser.close(tab) } label: {
                Image(systemName: "xmark").font(.system(size: 8.5, weight: .bold)).foregroundStyle(WS.text3)
                    .frame(width: 18, height: 18)
                    .background(hover ? WS.ink.opacity(0.06) : Color.clear, in: Circle())
                    .contentShape(Circle())
            }
            .buttonStyle(.liaPlain)
            .liaPointer()
            .opacity(hover || selected ? 1 : 0)
            .accessibilityLabel(Text("Close \(tab.displayTitle)"))
            .padding(.trailing, 5)
        }
        .background(selected ? WS.surface : Color.clear, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .onHover { hover = $0 }
    }
}
