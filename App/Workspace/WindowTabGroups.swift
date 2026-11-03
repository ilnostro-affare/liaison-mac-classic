import SwiftUI
import AppKit

// /15 (docs/UX-BACKLOG.md), redrawn by (Dia/Arc): a group is ONE rounded container (a faint fill
// and a hairline) around its header (its category's icon, or its first tab's favicon, and the name) and its tabs. No colour, no
// chevron. Collapsed, only the header shows. A click on the header collapses or expands it, a double-click renames,
// a right-click opens the group's menu (Rename, Collapse, Pin, New Tab in Group, Tidy, Ungroup, Put Away, Close).
// The model is BrowserModel's (groups, makeGroup, addTab, normalizeOrder...); this file draws, wires and names.

extension Notification.Name {
    /// object: the group's id. Its header turns into the rename field (posted right after "Add to New Group").
    static let wsRenameTabGroup = Notification.Name("wsRenameTabGroup")
}

/// One place in the vertical sidebar's list: a group's header or a tab (with its position among all tabs).
enum TabRowItem: Identifiable {
    case chip(BrowserModel.TabGroupInfo, Int)
    case tab(BrowserTab, Int)

    var id: String {
        switch self {
        case .chip(let g, _): return "group-" + g.id
        case .tab(let t, _): return t.id.uuidString
        }
    }
}

/// A tab a group shows in the strip, with its position among all tabs (VoiceOver, \u{2318}1...9).
struct ShownTab: Identifiable {
    let tab: BrowserTab
    let index: Int
    var id: UUID { tab.id }
}

/// One place in the horizontal strip after the workspace's cell: a loose tab, or a group with the tabs it shows.
enum TabStripItem: Identifiable {
    case tab(BrowserTab, Int)
    case group(BrowserModel.TabGroupInfo, count: Int, shown: [ShownTab])

    var id: String {
        switch self {
        case .tab(let t, _): return t.id.uuidString
        case .group(let g, _, _): return "group-" + g.id
        }
    }
}

/// The strip's quiet look: the pinned cell and every group are the same faint container.
enum StripLook {
    static let fill = Color.dyn(dark: (0xffffff, 0.07), light: (0x11141a, 0.045))
    static let hairline = Color.dyn(dark: (0xffffff, 0.13), light: (0x11141a, 0.10))
    static let radius: CGFloat = 14
}

enum TabRowLayout {
    /// The flat list (the vertical sidebar): each group's header before its first tab; a collapsed group's tabs
    /// hidden, except the tab in front and the one kept when the folder closed.
    @MainActor static func items(_ b: BrowserModel) -> [TabRowItem] {
        var out: [TabRowItem] = []
        var seen = Set<String>()
        for (i, t) in b.tabs.enumerated() {
            if let g = b.group(of: t) {
                if !seen.contains(g.id) {
                    seen.insert(g.id)
                    out.append(.chip(g, b.tabs(in: g).count))
                }
                if g.collapsed && !b.showsCollapsed(t) { continue }
            }
            out.append(.tab(t, i))
        }
        return out
    }

    /// The horizontal strip after the pinned cell: pinned groups first (BrowserModel keeps that order), then loose tabs
    /// and groups. A group's tabs are gathered under one item, so nothing can be drawn between them.
    @MainActor static func strip(_ b: BrowserModel) -> [TabStripItem] {
        var out: [TabStripItem] = []
        var index: [String: Int] = [:]
        var shown: [String: [ShownTab]] = [:]
        var counts: [String: Int] = [:]
        for (i, t) in b.tabs.enumerated() where !t.pinned {
            guard let g = b.group(of: t) else { out.append(.tab(t, i)); continue }
            counts[g.id, default: 0] += 1
            if index[g.id] == nil {
                index[g.id] = out.count
                out.append(.group(g, count: 0, shown: []))
            }
            if !g.collapsed || b.showsCollapsed(t) { shown[g.id, default: []].append(ShownTab(tab: t, index: i)) }
        }
        return out.map { item -> TabStripItem in
            guard case .group(let g, _, _) = item else { return item }
            return .group(g, count: counts[g.id] ?? 0, shown: shown[g.id] ?? [])
        }
    }

    /// The header's width for 's measure: icon, name and padding.
    @MainActor static func chipWidth(_ g: BrowserModel.TabGroupInfo, count: Int) -> CGFloat {
        let font = NSFont.systemFont(ofSize: 12.5, weight: .semibold)
        let text = ceil((WSTabStacks.chipName(g, count: count) as NSString).size(withAttributes: [.font: font]).width)
        return min(150, text) + 16 + 6 + 10 + 10
    }
}

/// The icon a group shows. Never an emoji. The server's category (TabGroupCat) as the
/// app's own icon, in the header's ink; an older group that has only an emoji, the folder; a group with neither yet
/// (one tab, not named by the server), its first tab's favicon.
struct TabGroupIcon: View {
    let group: BrowserModel.TabGroupInfo
    @ObservedObject var browser: BrowserModel
    var size: CGFloat = 15

    var body: some View {
        Group {
            if group.cat != nil || (group.emoji?.isEmpty == false) {
                LiaIcon(TabGroupCat.icon(group.cat), size: size)
            } else if let t = browser.tabs(in: group).first {
                GroupFavicon(tab: t, size: size)
            } else {
                LiaIcon("folder-simple", size: size).foregroundStyle(WS.text2)
            }
        }
        .accessibilityHidden(true)
    }
}

/// A tab's favicon at a given size (no loading ring), from the same source the strip uses.
struct GroupFavicon: View {
    @ObservedObject var tab: BrowserTab
    var size: CGFloat = 15

    var body: some View {
        Group {
            if let f = tab.favicon ?? TabIconMemory.icon(tab: tab.id, host: tab.savedURL?.host) {
                Image(nsImage: f).resizable().interpolation(.high)
            } else {
                LiaIcon("globe-simple", size: size).foregroundStyle(WS.text3)
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: size * 0.27, style: .continuous))
    }
}

/// The group's header: its icon and name. A click collapses or expands; a double-click renames; right-click for the
/// group's menu; dragged, the whole group moves. Used by the strip (inside the group's container) and the sidebar.
struct TabGroupChip: View {
    let group: BrowserModel.TabGroupInfo
    let count: Int
    let browser: BrowserModel
    let ws: WorkspaceModel
    /// (TabFit) the header's width in the strip; nil: its natural size (the vertical sidebar). Narrow, the
    /// name truncates, then only the icon stays.
    var width: CGFloat? = nil
    /// In the horizontal strip (hovering shows the group's card: its tabs).
    var inStrip = false
    @Environment(\.accessibilityReduceMotion) private var reduce
    @Environment(\.wsBarOnDark) private var onDark
    @State private var renaming = false
    @State private var draft = ""
    /// A click waits a double-click's time (a second click renames instead of collapsing).
    @State private var clickToken = 0
    @State private var hover = false
    /// The group's card shows after half a second on its header (as a tab's does).
    @State private var preview = false
    @State private var hoverToken = 0
    @State private var box = AnchorBox()
    @FocusState private var focus: Bool
    @ObservedObject private var tidy = TabTidy.shared

    /// A stack's header reads "Stack of 3" (until renamed).
    private var title: String { WSTabStacks.chipName(group, count: count) }

    var body: some View {
        HStack(spacing: 4) {
            accessible(menued(face))
            if tidy.undoAnchor == group.id { TabTidyUndoPill(browser: browser) }
        }
    }

    @ViewBuilder private var face: some View {
        if renaming { field } else { label }
    }

    private var label: some View {
        Button { clicked() } label: {
            HStack(spacing: 6) {
                TabGroupIcon(group: group, browser: browser)
                if let w = width {
                    if w >= 58 { Text(title).lineLimit(1).truncationMode(.tail) }
                } else {
                    Text(title).lineLimit(1).frame(maxWidth: 150, alignment: .leading).fixedSize()
                }
            }
            .font(LiaFont.ui(12.5, .semibold))
            .foregroundStyle(width == nil ? WS.ink : BarInk.ink(onDark))
            .padding(.horizontal, (width ?? 100) < 58 ? 0 : 10)
            .frame(width: width, height: 28)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(hover ? (width != nil && onDark ? BarInk.hover(true) : DropdownTrigger.hoverFill) : Color.clear))
            .frame(height: 32)
            .contentShape(Rectangle())
        }
        .buttonStyle(.liaPlain)
        .onHover { h in
            hover = h
            hoverChanged(h)
        }
        .liaPointer()
        .background(AnchorReader(box: box))
        .anchorPreference(key: TabPreviewKey.self, value: .bounds, transform: previewValue)
        .onDrag {
            endPreview()
            TabGroupDrag.begin(group.id)
            return NSItemProvider(object: (TabGroupDrag.prefix + group.id) as NSString)
        } preview: {
            TabGroupDragChip(group: group, browser: browser, name: title)
        }
        // No tooltip; hovering shows the group's card (TabGroupHoverCard).
    }

    private var previewValue: (Anchor<CGRect>) -> TabPreviewKey.Item? {
        let tabs: [BrowserTab] = preview && inStrip && !renaming ? browser.tabs(in: group) : []
        let card = TabGroupPreview(id: group.id, name: title, tabs: tabs)
        return { a in
            guard let first = tabs.first else { return nil }
            return TabPreviewKey.Item(tab: first, anchor: a, group: card)
        }
    }

    private func hoverChanged(_ h: Bool) {
        hoverToken += 1
        guard h, inStrip, !renaming else { preview = false; return }
        let token = hoverToken
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            if token == hoverToken, hover, !renaming, NSEvent.pressedMouseButtons == 0 { preview = true }
        }
    }

    private func endPreview() {
        hoverToken += 1
        preview = false
    }

    private var field: some View {
        TextField("Group name", text: $draft)
            .textFieldStyle(.plain)
            .font(LiaFont.ui(12.5, .semibold))
            .foregroundStyle(WS.ink)
            .focused($focus)
            .onSubmit { commitRename() }
            .onExitCommand { renaming = false }
            .padding(.horizontal, 8)
            .frame(width: 130, height: 24)
            .background(WS.surface, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).stroke(WS.line2, lineWidth: 1))
            .frame(height: 32)
            .onChange(of: focus) { _, f in if !f && renaming { commitRename() } }
            .accessibilityLabel(Text("Group name"))
    }

    private func menued<V: View>(_ v: V) -> some View {
        v
            // The group's own menu (right-click on its header; a right-click on a tab is that tab's history). Also
            // the header is its own right-click target (AppKit's hit test finds it) and the menu opens under the frame
            // it hands over.
            .overlay(RightClickTarget(key: "group-" + group.id, enabled: !renaming) { frame, window in
                endPreview()
                openMenu(at: frame, in: window)
            })
            .onReceive(NotificationCenter.default.publisher(for: .wsRenameTabGroup)) { n in
                if (n.object as? String) == group.id { startRename() }
            }
    }

    private func openMenu(at frame: NSRect? = nil, in window: NSWindow? = nil) {
        TipHost.shared.dismiss()
        let items = TabGroupMenu.items(group: group, browser: browser, ws: ws, rename: { startRename() }, toggle: { toggle() },
                                       putAway: { putAway() })
        DropdownHost.shared.toggle(AnyHashable("group-menu-" + group.id), anchor: frame ?? box.screenRect, in: window ?? box.window,
                                   edge: .below, align: .leading, gap: 4) {
            LiaCtxGlassPanel(items: items)
        }
    }

    private func accessible<V: View>(_ v: V) -> some View {
        v
            .accessibilityElement(children: renaming ? .contain : .ignore)
            .accessibilityLabel(Text(WSTabStacks.isStack(group) ? "Tab stack \(title), \(count) tabs" : "Tab group \(group.name), \(count) tabs"))
            .accessibilityValue(Text(group.collapsed ? "Collapsed" : "Expanded"))
            .accessibilityAddTraits(.isButton)
            .accessibilityAction { toggle() }
            .accessibilityAction(named: Text("Rename")) { startRename() }
            .accessibilityAction(named: Text(group.isPinned ? "Unpin group" : "Pin group")) { browser.setGroupPinned(group, !group.isPinned) }
            .accessibilityAction(named: Text("Ungroup")) { browser.ungroup(group) }
            .accessibilityAction(named: Text("Put Away")) { putAway() }
    }

    /// One click collapses or expands; a double-click renames.
    private func clicked() {
        endPreview()
        clickToken += 1
        if WSClicks.isDouble { startRename(); return }
        let t = clickToken
        DispatchQueue.main.asyncAfter(deadline: .now() + NSEvent.doubleClickInterval) {
            if t == clickToken, !renaming { toggle() }
        }
    }

    private func toggle() {
        withAnimation(WSMotion.navigation(reduce)) { browser.toggleCollapsed(group) }
        AccessibilityNotification.Announcement(group.collapsed ? "\(title) expanded" : "\(title) collapsed").post()
    }

    private func startRename() {
        endPreview()
        draft = group.name
        renaming = true
        DispatchQueue.main.async {
            focus = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                NSApp.sendAction(#selector(NSText.selectAll(_:)), to: nil, from: nil)
            }
        }
    }

    private func commitRename() {
        let name = draft.trimmingCharacters(in: .whitespaces)
        renaming = false
        if !name.isEmpty, name != group.name { browser.renameGroup(group, name) }
    }

    /// Its tabs close; the group waits in History \u{2192} Saved Groups.
    private func putAway() {
        let name = group.name
        withAnimation(WSMotion.navigation(reduce)) { browser.putAway(group) }
        ws.show("\u{201C}\(name)\u{201D} put away \u{00B7} History \u{2192} Saved Groups", symbol: "tray.and.arrow.down")
    }
}

/// The group's menu (right-click on its header): everything the old chip menu had, without Colour.
@MainActor
enum TabGroupMenu {
    static func items(group g: BrowserModel.TabGroupInfo, browser: BrowserModel, ws: WorkspaceModel,
                      rename: @escaping () -> Void, toggle: @escaping () -> Void, putAway: @escaping () -> Void) -> [LiaCtxItem] {
        var out: [LiaCtxItem] = [
            LiaCtxItem(title: "Rename\u{2026}", icon: "menu-rename") { rename() },
            LiaCtxItem(title: g.collapsed ? "Expand Group" : "Collapse Group", icon: g.collapsed ? "menu-expand" : "collapse") { toggle() },
            LiaCtxItem(title: g.isPinned ? "Unpin Group" : "Pin Group", icon: g.isPinned ? "menu-unpin" : "menu-pin") {
                withAnimation(WSMotion.spring) { browser.setGroupPinned(g, !g.isPinned) }
            },
            LiaCtxItem(title: "New Tab in Group", icon: "plus") { withAnimation(WSMotion.spring) { _ = browser.newTab(inGroup: g) } },
        ]
        if TabTidy.canRun(browser), !TabTidy.shared.running {
            out.append(LiaCtxItem(title: "Tidy Tabs", icon: "folders") { TabTidy.shared.run(browser, ws: ws) })
        }
        out.append(.sep)
        out.append(LiaCtxItem(title: "Ungroup", icon: "folder-open") { withAnimation(WSMotion.spring) { browser.ungroup(g) } })
        out.append(LiaCtxItem(title: "Put Away", icon: "archive") { putAway() })
        out.append(LiaCtxItem(title: "Close Group", icon: "menu-close", danger: true) {
            withAnimation(WSMotion.spring) { for t in browser.tabs(in: g) { browser.close(t) } }
        })
        return out
    }
}

/// A group that reaches two tabs asks the server once for a name and a category (POST /agents/suggest,
/// kind "tab_name"; `cat`, drawn as the app's own icon, never an emoji). A failure keeps the one-word name; a name the person typed is never replaced (BrowserModel).
@MainActor
enum TabGroupNamer {
    static func ask(_ b: BrowserModel, group id: String) {
        guard let ws = WorkspaceModel.current, let p = ws.profile else { return }
        let tabs = b.tabs.filter { $0.group == id }.prefix(Suggest.maxTabs).map { t in
            (id: t.id.uuidString, title: t.customTitle ?? t.savedTitle, host: t.savedURL?.host ?? "")
        }
        guard tabs.count >= 2 else { return }
        let api = LiaAPI(auth: ws.auth)
        let list = Array(tabs)
        Task { @MainActor [weak b] in
            guard let r = try? await api.agentSuggestTabName(profile: p.id, tabs: list), let b else { return }
            withAnimation(WSMotion.micro) { b.applySuggestedName(id, name: r.name, emoji: r.emoji, cat: r.cat) }
        }
    }
}

/// A whole group dragged by its header: the drop delegates move every tab of it at once, in order.
@MainActor
enum TabGroupDrag {
    static let prefix = "lia-tab-group:"
    private(set) static var current: String?

    static func begin(_ id: String) {
        current = id
        // A drag that ends outside the row never reaches performDrop: forget it once the mouse is up.
        Task { @MainActor in
            while NSEvent.pressedMouseButtons & 1 != 0 { try? await Task.sleep(nanoseconds: 200_000_000) }
            try? await Task.sleep(nanoseconds: 300_000_000)
            if current == id { current = nil }
        }
    }

    static func end() { current = nil }

    /// The group's tabs go where `target` is; onto another group, to that group's edge (BrowserModel.moveGroup).
    static func move(_ groupID: String, to target: UUID, in b: BrowserModel) {
        b.moveGroup(groupID, to: target)
    }
}

/// The group's header as it follows the pointer.
private struct TabGroupDragChip: View {
    let group: BrowserModel.TabGroupInfo
    let browser: BrowserModel
    let name: String

    var body: some View {
        HStack(spacing: 6) {
            TabGroupIcon(group: group, browser: browser)
            Text(name).lineLimit(1).frame(maxWidth: 150, alignment: .leading).fixedSize()
        }
        .font(LiaFont.ui(12.5, .semibold))
        .foregroundStyle(WS.ink)
        .padding(.horizontal, 10)
        .frame(height: 28)
        .background(WS.surface, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(WS.line2, lineWidth: 1))
        .padding(2)
    }
}

/// The tab menu's group items (the vertical sidebar's NSMenu): a new group (from the \u{2318}/\u{21E7}-click selection when
/// the tab is in it), an existing group, out of its group.
struct TabGroupMenuItems: View {
    let tab: BrowserTab
    let browser: BrowserModel
    /// The selection the menu acts on (empty: this tab alone).
    var selection: [BrowserTab] = []
    /// One "Add to Group" submenu holding every group item (the trimmed tab menu).
    var submenu = false
    var done: () -> Void = {}

    private var members: [BrowserTab] { selection.count > 1 ? selection : [tab] }

    var body: some View {
        if submenu {
            Menu("Add to Group") { items }
                .disabled(members.allSatisfy(\.pinned))
        } else {
            items
        }
    }

    @ViewBuilder private var items: some View {
        let list = members
        Button(submenu ? "New Group" : (list.count > 1 ? "Add \(list.count) Tabs to New Group" : "Add to New Group")) { newGroup(list) }
            .disabled(list.allSatisfy(\.pinned))
        if !browser.groups.isEmpty {
            if submenu {
                Divider()
                groupButtons(list)
            } else {
                Menu("Add to Group") { groupButtons(list) }
            }
        }
        if list.contains(where: { $0.group != nil }) {
            if submenu { Divider() }
            Button(list.count > 1 ? "Remove \(list.count) Tabs from Group" : "Remove from Group") { remove(list) }
        }
        if let ws = WorkspaceModel.current {
            Divider()
            Button("Tidy Tabs") { TabTidy.shared.run(browser, ws: ws); done() }
                .disabled(!TabTidy.canRun(browser) || TabTidy.shared.running)
        }
    }

    @ViewBuilder private func groupButtons(_ list: [BrowserTab]) -> some View {
        ForEach(browser.groups) { g in
            Button(WSTabStacks.chipName(g, count: browser.tabs(in: g).count)) { add(list, to: g) }
                .disabled(list.allSatisfy { $0.group == g.id || $0.pinned })
        }
    }

    private func newGroup(_ list: [BrowserTab]) {
        _ = TabGroupActions.group(list, in: browser)
        done()
    }

    private func add(_ list: [BrowserTab], to g: BrowserModel.TabGroupInfo) {
        withAnimation(WSMotion.spring) { for t in list { browser.addTab(t, to: g) } }
        browser.objectWillChange.send()   // a tab's group changed without the tab list changing: headers recount
        done()
    }

    private func remove(_ list: [BrowserTab]) {
        withAnimation(WSMotion.spring) { for t in list where t.group != nil { browser.removeFromGroup(t) } }
        browser.objectWillChange.send()
        done()
    }
}

enum TabGroupActions {
    /// \u{2318}\u{21E7}G and "Add to New Group": a group from these tabs (pinned ones stay out), named after the first tab's
    /// site (one word); with two or more tabs the server's name follows on its own (TabGroupNamer).
    @MainActor @discardableResult
    static func group(_ list: [BrowserTab], in browser: BrowserModel) -> BrowserModel.TabGroupInfo? {
        var made: BrowserModel.TabGroupInfo?
        withAnimation(WSMotion.spring) { made = browser.makeGroup(list) }
        if let g = made { AccessibilityNotification.Announcement("New tab group \(g.name)").post() }
        return made
    }

    /// The new group's header turns into its name field once it is in the row.
    @MainActor static func askName(_ g: BrowserModel.TabGroupInfo) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            NotificationCenter.default.post(name: .wsRenameTabGroup, object: g.id)
        }
    }
}

// MARK: - Tidy

/// "Tidy Tabs" (the tab menu and a group chip's menu): the workspace's ungrouped tabs go to POST /agents/suggest, and
/// the groups that come back are made with their name and category (the category's icon, TabGroupCat). Only ungrouped, unpinned, loaded-or-restored tabs are
/// sent, so a group the person made or named is never touched. One click on the Undo pill (next to the first new
/// group's chip, 10 s) ungroups what Tidy made, except a group the person has renamed since.
@MainActor
final class TabTidy: ObservableObject {
    static let shared = TabTidy()
    @Published private(set) var running = false
    /// The chip that carries the Undo pill (the first group Tidy made); nil: none.
    @Published private(set) var undoAnchor: String?
    /// What Undo takes back: the group ids Tidy made and the names it gave them.
    private var made: [(id: String, name: String)] = []
    private var undoToken = 0


    /// The tabs Tidy may move: not pinned, in no group, with a page.
    static func candidates(_ b: BrowserModel) -> [BrowserTab] {
        b.tabs.filter { !$0.pinned && $0.group == nil && !$0.isStart && $0.savedURL != nil }
    }
    static func canRun(_ b: BrowserModel) -> Bool { candidates(b).count >= 2 }

    func run(_ b: BrowserModel, ws: WorkspaceModel) {
        guard !running, let p = ws.profile else { return }
        let tabs = Self.candidates(b)
        guard tabs.count >= 2 else { ws.show("Nothing to tidy: fewer than two ungrouped tabs", symbol: "square.on.square"); return }
        running = true
        let payload = tabs.prefix(Suggest.maxTabs).map { t in
            (id: t.id.uuidString, title: t.customTitle ?? t.savedTitle, host: t.savedURL?.host ?? "")
        }
        let api = LiaAPI(auth: ws.auth)
        Task { @MainActor [weak self, weak b, weak ws] in
            let groups = try? await api.agentSuggestGroups(profile: p.id, tabs: payload)
            guard let self else { return }
            self.running = false
            guard let b, let ws else { return }
            guard let groups else { ws.show("Couldn\u{2019}t tidy the tabs. Try again.", symbol: "exclamationmark.triangle"); return }
            self.apply(groups, to: b, ws: ws)
        }
    }

    /// Makes the groups (re-checked against the tabs as they are now: one may have been grouped or closed meanwhile).
    private func apply(_ groups: [SuggestedGroup], to b: BrowserModel, ws: WorkspaceModel) {
        let now = Self.candidates(b)
        let byID = Dictionary(uniqueKeysWithValues: now.map { ($0.id.uuidString, $0) })
        let ok = Suggest.applicable(groups, available: Array(byID.keys))
        guard !ok.isEmpty else { ws.show("Your tabs already look tidy", symbol: "checkmark"); return }
        var out: [(id: String, name: String)] = []
        var moved = 0
        withAnimation(WSMotion.spring) {
            for g in ok {
                let members = g.tabIds.compactMap { byID[$0] }
                // The group's category is its icon (the app's own set, as the named groups'); none: the folder.
                guard members.count >= 2, let made = b.makeGroup(members, name: g.name, cat: g.cat ?? "folder") else { continue }
                out.append((made.id, g.name))
                moved += members.count
            }
        }
        guard let first = out.first else { return }
        made = out
        undoToken += 1
        let token = undoToken
        undoAnchor = first.id
        b.objectWillChange.send()
        let text = "Tidied \(moved) tabs into \(out.count) group\(out.count == 1 ? "" : "s")"
        ws.show(text, symbol: "wand.and.stars")
        AccessibilityNotification.Announcement(text + ". Undo is next to the first group.").post()
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 10_000_000_000)
            guard let self, self.undoToken == token else { return }
            self.undoAnchor = nil
            self.made = []
        }
    }

    /// Ungroups what Tidy made; a group renamed since is the person's now and stays.
    func undo(_ b: BrowserModel) {
        let list = made
        made = []
        undoAnchor = nil
        undoToken += 1
        withAnimation(WSMotion.spring) {
            for m in list {
                guard let g = b.groups.first(where: { $0.id == m.id }), g.name == m.name else { continue }
                b.ungroup(g)
            }
        }
        b.objectWillChange.send()
        AccessibilityNotification.Announcement("Tidy undone").post()
    }
}

/// The one-click Undo next to the first group Tidy made.
private struct TabTidyUndoPill: View {
    let browser: BrowserModel

    var body: some View {
        Button { TabTidy.shared.undo(browser) } label: {
            HStack(spacing: 4) {
                Image(systemName: "arrow.uturn.backward").font(.system(size: 9.5, weight: .semibold))
                Text("Undo").font(LiaFont.ui(12, .medium))
            }
            .foregroundStyle(WS.ink)
            .padding(.horizontal, 8)
            .frame(height: 22)
            .background(WS.surface, in: Capsule())
            .overlay(Capsule().stroke(WS.line, lineWidth: 1))
            .frame(height: 32)
            .contentShape(Rectangle())
        }
        .buttonStyle(.liaPlain)
        .liaPointer()
        .transition(.opacity)
        .accessibilityLabel(Text("Undo Tidy"))
    }
}
