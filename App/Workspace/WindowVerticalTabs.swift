import SwiftUI
import AppKit
import UniformTypeIdentifiers

// Vertical tabs (Edge, Arc, Zen), when Prefs.verticalTabs is on: a glass sidebar at the left of the
// page (240 pt, 200...320 by its edge): pinned tabs as a grid of icons, groups with their chips (collapsible,
// renamable), tabs with icon, title, sound and \u{00D7} on hover, + New Tab. The top bar then keeps the workspace, the
// history buttons and the selected tab's address only (TabGroup). The menus are the tab row's (TabContextMenu).

enum VerticalTabsMetrics {
    static let widthKey = "lia_vtabs_width"
    static let minWidth: CGFloat = 200
    static let maxWidth: CGFloat = 320
    static let defaultWidth: CGFloat = 240
}

/// The window's left column while vertical tabs are on (nothing otherwise).
struct VerticalTabsSlot: View {
    @ObservedObject var ws: WorkspaceModel
    @AppStorage(Prefs.verticalTabs) private var vertical = false

    var body: some View {
        if vertical, let b = ws.currentBrowser {
            VerticalTabsSidebar(ws: ws, browser: b)
                .id(ws.profileId)
                .transition(.move(edge: .leading).combined(with: .opacity))
        }
    }
}

struct VerticalTabsSidebar: View {
    @ObservedObject var ws: WorkspaceModel
    @ObservedObject var browser: BrowserModel
    @Environment(\.accessibilityReduceMotion) private var reduce
    @Environment(\.openWindow) private var openWindow
    @AppStorage(VerticalTabsMetrics.widthKey) private var width: Double = Double(VerticalTabsMetrics.defaultWidth)
    @State private var dragging: UUID?

    private var rows: [TabRowItem] {
        TabRowLayout.items(browser).filter { item in
            if case .tab(let t, _) = item { return !t.pinned }
            return true
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !browser.pinnedTabs.isEmpty { pinnedGrid }
            list
            newTab
        }
        .padding(8)
        .frame(width: CGFloat(width))
        .frame(maxHeight: .infinity, alignment: .top)
        .background(Color(hex: ws.profile?.colorHex ?? 0x3B5BFD).opacity(0.05), in: RoundedRectangle(cornerRadius: WS.radius, style: .continuous))
        .wsGlass(WS.radius)
        .overlay(alignment: .trailing) { VerticalTabsResizeHandle(width: $width) }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text("Tabs"))
    }

    private var pinnedGrid: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 40, maximum: 56), spacing: 4)], spacing: 4) {
            ForEach(browser.pinnedTabs) { t in
                VPinnedTab(tab: t, browser: browser, ws: ws, index: browser.tabs.firstIndex(where: { $0.id == t.id }) ?? 0)
            }
        }
        .padding(.bottom, 2)
    }

    private var list: some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical, showsIndicators: false) {
                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(rows) { item in row(item) }
                }
                .animation(WSMotion.navigation(reduce), value: browser.tabs.map(\.id))
                .animation(WSMotion.navigation(reduce), value: browser.groups)
            }
            .onChange(of: browser.selectedID) { _, id in
                guard let id else { return }
                withAnimation(WSMotion.micro) { proxy.scrollTo(id) }
            }
        }
    }

    @ViewBuilder private func row(_ item: TabRowItem) -> some View {
        switch item {
        case .chip(let g, let n):
            TabGroupChip(group: g, count: n, browser: browser, ws: ws)
                .padding(.top, 4)
                .frame(maxWidth: .infinity, alignment: .leading)
        case .tab(let t, let i):
            VTabRow(tab: t, browser: browser, ws: ws, index: i, count: browser.tabs.count,
                    groupColor: tint(t),
                    onDragStart: { startDrag(t.id) })
                .id(t.id)
                .onDrop(of: [UTType.text], delegate: TabDropDelegate(target: t.id, browser: browser, dragging: $dragging,
                                                                      animation: WSMotion.navigation(reduce)))
        }
    }

    /// Groups have no colour.
    private func tint(_ t: BrowserTab) -> Color? { nil }

    private var newTab: some View {
        Button { browser.openHome() } label: {
            HStack(spacing: 8) {
                Image(systemName: "plus").font(.system(size: 11, weight: .semibold)).frame(width: 21)
                Text("New Tab").font(LiaFont.ui(13))
                Spacer()
                Text("\u{2318}T").font(LiaFont.ui(11.5)).foregroundStyle(WS.text3)
            }
            .foregroundStyle(WS.text2)
            .padding(.horizontal, 8)
            .frame(height: 32)
            .contentShape(Rectangle())
        }
        .buttonStyle(.liaPlain)
        .liaHover(.fill, radius: 10)
        // The + menu of the bar (TabBarMenu.plus) on a right-click.
        .overlay(RightClickTarget(key: "vtabs-new-tab") { frame, window in
            let hooks = TabBarMenu.Hooks(newTab: { _ = browser.openHome() }, privateWindow: { openWindow(id: "private") }, tabHistory: nil)
            DropdownHost.shared.toggle(AnyHashable("vtabs-plus-menu"), anchor: frame, in: window, edge: .below, align: .leading, gap: 4) {
                LiaCtxGlassPanel(items: TabBarMenu.plus(browser: browser, hooks: hooks))
            }
        })
        .accessibilityLabel(Text("New tab"))
    }

    /// As in the row: a drag that ends outside never reaches performDrop; forget the tab once the mouse is up.
    private func startDrag(_ id: UUID) {
        dragging = id
        Task { @MainActor in
            while NSEvent.pressedMouseButtons & 1 != 0 { try? await Task.sleep(nanoseconds: 200_000_000) }
            try? await Task.sleep(nanoseconds: 300_000_000)
            if dragging == id { dragging = nil }
        }
    }
}

/// The sidebar's right edge: drag for 200...320 pt, double-click for 240; arrows with VoiceOver.
private struct VerticalTabsResizeHandle: View {
    @Binding var width: Double
    @State private var start: Double?

    var body: some View {
        Color.clear
            .frame(width: 6)
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .liaCursor(.resizeLeftRight)   // one cursor approach (Hover.swift): no push / pop of its own
            .onTapGesture(count: 2) { width = Double(VerticalTabsMetrics.defaultWidth) }
            .gesture(DragGesture(minimumDistance: 1, coordinateSpace: .global)
                .onChanged { v in
                    let s = start ?? width
                    if start == nil { start = s }
                    width = Self.clamp(s + Double(v.translation.width))
                }
                .onEnded { _ in start = nil })
            .offset(x: 3)
            .accessibilityElement()
            .accessibilityLabel(Text("Tab sidebar width"))
            .accessibilityValue(Text("\(Int(width)) points"))
            .accessibilityAdjustableAction { d in
                switch d {
                case .increment: width = Self.clamp(width + 20)
                case .decrement: width = Self.clamp(width - 20)
                @unknown default: break
                }
            }
    }

    static func clamp(_ w: Double) -> Double {
        min(Double(VerticalTabsMetrics.maxWidth), max(Double(VerticalTabsMetrics.minWidth), w))
    }
}

/// A pinned tab in the sidebar's grid: its icon on a tile.
private struct VPinnedTab: View {
    @ObservedObject var tab: BrowserTab
    let browser: BrowserModel
    let ws: WorkspaceModel
    let index: Int

    private var selected: Bool { browser.selectedID == tab.id }

    var body: some View {
        Button { browser.selectedID = tab.id } label: {
            TabFavicon(tab: tab)
                .frame(maxWidth: .infinity)
                .frame(height: 34)
                .background(selected ? WS.surface : WS.wash, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .shadow(color: selected ? Color.black.opacity(0.08) : .clear, radius: 1, y: 1)
        }
        .buttonStyle(.liaPlain)
        .liaPointer()
        .liaTip("\(tab.chipTitle) (pinned)")
        .contextMenu {
            TabContextMenu(tab: tab, browser: browser, ws: ws, selected: selected, index: index, count: browser.tabs.count)
        }
        .accessibilityLabel(Text("Pinned tab, \(tab.chipTitle)"))
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// One tab in the sidebar: icon, title (or the rename field), sound, \u{00D7} on hover.
private struct VTabRow: View {
    @ObservedObject var tab: BrowserTab
    @ObservedObject var browser: BrowserModel
    let ws: WorkspaceModel
    let index: Int
    let count: Int
    let groupColor: Color?
    let onDragStart: () -> Void
    @State private var hover = false
    @State private var renaming = false

    private var selected: Bool { browser.selectedID == tab.id }

    var body: some View {
        accessible(decorated(face))
    }

    private var face: some View {
        HStack(spacing: 8) {
            TabFavicon(tab: tab)
            if renaming {
                TabRenameField(tab: tab, browser: browser, width: nil) { renaming = false }
            } else {
                Text(tab.chipTitle).font(LiaFont.ui(13, selected ? .medium : .regular))
                    .foregroundStyle(selected ? WS.ink : WS.text2).lineLimit(1)
            }
            Spacer(minLength: 2)
            if tab.playing || tab.muted { SpeakerGlyph(tab: tab, small: false) }
            if tab.capturing {
                Image(systemName: "video.fill").font(.system(size: 9, weight: .bold)).foregroundStyle(Color.red)
                    .accessibilityLabel(Text("Using camera or microphone"))
            }
            if (hover || selected) && !renaming { closeButton }
        }
        .padding(.leading, groupColor == nil ? 8 : 14)
        .padding(.trailing, 6)
        .frame(height: 32)
    }

    private var closeButton: some View {
        Button { browser.close(tab) } label: {
            Image(systemName: "xmark").font(.system(size: 9, weight: .bold)).foregroundStyle(WS.text3)
                .frame(width: 16, height: 16)
        }
        .buttonStyle(.liaPlain)
        .liaHover(.icon, radius: 5)
        .accessibilityLabel(Text("Close tab"))
    }

    private func decorated<V: View>(_ v: V) -> some View {
        let shape = RoundedRectangle(cornerRadius: 10, style: .continuous)
        return v
            .background(selected ? WS.surface : (hover ? WS.washHover : Color.clear), in: shape)
            .shadow(color: selected ? Color.black.opacity(0.08) : .clear, radius: 1, y: 1)
            .overlay(alignment: .leading) {
                if let c = groupColor { Capsule().fill(c).frame(width: 3, height: 18).padding(.leading, 5).allowsHitTesting(false) }
            }
            .contentShape(shape)
            .onHover { hover = $0 }
            .onTapGesture { tapped() }
            .background(WSMouseZone(kind: .middle) { browser.close(tab) })
            .onDrag {
                onDragStart()
                return NSItemProvider(object: tab.id.uuidString as NSString)
            } preview: {
                TabDragChip(tab: tab)
            }
            .contextMenu {
                TabContextMenu(tab: tab, browser: browser, ws: ws, selected: selected, index: index, count: count)
            }
            .onReceive(NotificationCenter.default.publisher(for: .wsRenameTab)) { n in
                if (n.object as? String) == tab.id.uuidString { renaming = true }
            }
            .liaPointer()
    }

    /// The second click of a double-click renames.
    private func tapped() {
        if WSClicks.isDouble { renaming = true; return }
        browser.selectedID = tab.id
    }

    private func accessible<V: View>(_ v: V) -> some View {
        v
            .accessibilityElement(children: renaming ? .contain : .ignore)
            .accessibilityLabel(Text(label))
            .accessibilityAddTraits(.isButton)
            .accessibilityAddTraits(selected ? .isSelected : [])
            .accessibilityAction { browser.selectedID = tab.id }
            .accessibilityAction(named: Text("Rename")) { renaming = true }
            .accessibilityAction(named: Text("Close tab")) { browser.close(tab) }
    }

    private var label: String {
        var s = "Tab \(index + 1) of \(count), \(tab.chipTitle)"
        if let g = browser.group(of: tab) { s += WSTabStacks.isStack(g) ? ", in a stack" : ", in group \(g.name)" }
        if tab.playing { s += tab.muted ? ", muted" : ", playing sound" } else if tab.muted { s += ", muted" }
        if tab.isLoading { s += ", loading" }
        if tab.asleep { s += ", sleeping" }
        return s
    }
}
