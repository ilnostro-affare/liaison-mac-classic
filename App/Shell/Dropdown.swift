import SwiftUI
import AppKit

// The site's dropdowns (ai.js .ai__menu, shell.js .profile-menu): a dd-bg panel with a 1 px line-2 border, radius 11,
// no shadow (the hairline keeps the edge), 4 px inside; rows of 11.5 px regular text with a 17 px
// icon, the hover a surface-2 pill.
// A native NSMenu cannot be drawn this way, so a borderless panel hosts SwiftUI under the control that opened it.

enum DropdownEdge { case below, above }
enum DropdownAlign { case leading, trailing }

@MainActor
final class DropdownHost: ObservableObject {
    static let shared = DropdownHost()
    private var panel: DropdownPanel?
    private var sub: DropdownPanel?
    /// Whose menu is up: its trigger stays lit while it is (DropdownButton).
    @Published private(set) var owner: AnyHashable?
    private var monitors: [Any] = []
    private weak var parentWindow: NSWindow?

    private var resignToken: NSObjectProtocol?
    private var activeToken: NSObjectProtocol?
    private var anchorRect: NSRect = .zero
    /// The margin every panel view leaves around itself: 1 pt, so the hairline border is drawn whole (a stroke is
    /// half outside its shape). It held the shadow until asked for no shadow at all.
    nonisolated static let inset = EdgeInsets(top: 1, leading: 1, bottom: 1, trailing: 1)

    var isOpen: Bool { panel != nil }
    func isOpen(_ id: AnyHashable) -> Bool { panel != nil && owner == id }

    /// Opens `content` against `anchor` (screen coordinates); the same owner asking again closes it, as a click on the site's chip does.
    func toggle<C: View>(_ id: AnyHashable, anchor: NSRect, in window: NSWindow?, edge: DropdownEdge, align: DropdownAlign,
                         gap: CGFloat = 6, @ViewBuilder content: () -> C) {
        if isOpen(id) { close(); return }
        close()
        // A trigger whose frame could not be read (zero) opens its menu at the pointer, never at the screen's corner.
        var anchor = anchor
        if anchor.width <= 0 && anchor.height <= 0 && anchor.origin == .zero {
            anchor = NSRect(origin: NSEvent.mouseLocation, size: .zero)
        }
        owner = id
        parentWindow = window
        anchorRect = anchor
        let p = makePanel(AnyView(content()), window: window)
        let size = p.frame.size
        let i = Self.inset
        var flipped = false
        var x = align == .leading ? anchor.minX - i.leading : anchor.maxX - size.width + i.trailing
        var y = edge == .below ? anchor.minY - gap - size.height + i.top : anchor.maxY + gap - i.bottom
        if let screen = window?.screen ?? NSScreen.main {
            let v = screen.visibleFrame.insetBy(dx: 10, dy: 10)
            x = min(max(x, v.minX), v.maxX - size.width)
            if edge == .below && y < v.minY { y = anchor.maxY + gap - i.bottom; flipped = true }
            if edge == .above && y + size.height > v.maxY { y = anchor.minY - gap - size.height + i.top; flipped = true }
            y = min(max(y, v.minY), v.maxY - size.height)
        }
        p.setFrameOrigin(NSPoint(x: x, y: y))
        // Below the control the top edge stays put as the content grows; above it, the bottom edge does, so a menu
        // under the composer (the usage ring's categories) grows upward and never over the control or off screen.
        if (edge == .below) != flipped { p.keepTop = y + size.height } else { p.keepBottom = y }
        window?.addChildWindow(p, ordered: .above)
        p.makeKeyAndOrderFront(nil)
        panel = p
        watch()
    }

    /// A second panel beside the first (ai.js wireHoverSub / pickProjectFor: "the pair reads as one control").
    /// Against a row it grows up from the row's bottom (the + menu) or down from its top (the chat menu).
    func showSub<C: View>(row: NSRect, growsUp: Bool, @ViewBuilder content: () -> C) {
        subCloser?.cancel(); subCloser = nil
        closeSub()
        guard let main = panel else { return }
        let p = makePanel(AnyView(content()), window: parentWindow)
        let size = p.frame.size
        let i = Self.inset
        var x = main.frame.maxX - i.trailing - i.leading + 4
        if let screen = main.screen, x + size.width > screen.visibleFrame.maxX - 10 { x = main.frame.minX + i.leading + i.trailing - size.width - 4 }
        var y = growsUp ? row.minY - i.bottom : row.maxY + i.top - size.height
        if let v = main.screen?.visibleFrame { y = min(max(y, v.minY + 10 - i.bottom), v.maxY - size.height) }
        p.setFrameOrigin(NSPoint(x: x, y: y))
        if growsUp { p.keepBottom = y } else { p.keepTop = y + size.height }
        parentWindow?.addChildWindow(p, ordered: .above)
        p.orderFront(nil)
        sub = p
        subOwner = row
    }

    func closeSub() {
        guard let s = sub else { return }
        s.parent?.removeChildWindow(s)
        s.orderOut(nil)
        sub = nil; subOwner = nil
    }

    /// Hovering a plain row of the first menu puts the submenu away; a row inside the submenu keeps it.
    /// After 160 ms (ai.js wireHoverSub), so a diagonal move toward the submenu across another row does not lose it.
    func closeSub(unlessIn w: NSWindow?) {
        if let w, w === sub { subCloser?.cancel(); subCloser = nil; return }
        subCloser?.cancel()
        let job = DispatchWorkItem { [weak self] in self?.closeSub() }
        subCloser = job
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.16, execute: job)
    }
    private var subCloser: DispatchWorkItem?

    var subWindow: NSWindow? { sub }

    /// The row whose sub is showing, so hovering it again does not rebuild the panel.
    private(set) var subOwner: NSRect?

    func close() {
        let wasKey = panel?.isKeyWindow == true || sub?.isKeyWindow == true
        for m in monitors { NSEvent.removeMonitor(m) }
        monitors.removeAll()
        if let t = resignToken { NotificationCenter.default.removeObserver(t); resignToken = nil }
        for p in [sub, panel].compactMap({ $0 }) {
            p.parent?.removeChildWindow(p)
            p.orderOut(nil)
        }
        if let t = activeToken { NotificationCenter.default.removeObserver(t); activeToken = nil }
        sub = nil; panel = nil; owner = nil; subOwner = nil
        if wasKey { parentWindow?.makeKey() }
    }

    private func makePanel(_ view: AnyView, window: NSWindow?) -> DropdownPanel {
        let hc = NSHostingController(rootView: view.fixedSize())
        hc.sizingOptions = .preferredContentSize   // a step that grows the content grows the panel
        let size = hc.view.fittingSize
        let p = DropdownPanel(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless, .nonactivatingPanel],
                              backing: .buffered, defer: false)
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = false   // no shadow at all, the panel's hairline border is its edge
        p.level = .popUpMenu
        p.appearance = window?.effectiveAppearance
        p.isReleasedWhenClosed = false
        p.contentViewController = hc
        p.setContentSize(size)
        return p
    }

    private func watch() {
        if let m = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown], handler: { [weak self] e in
            guard let self else { return e }
            if e.window === self.panel || e.window === self.sub { return e }
            // A click on the control that opened the menu is left to its own toggle, which closes it on mouse-up.
            if let w = e.window, w === self.parentWindow, self.anchorRect.contains(w.convertPoint(toScreen: e.locationInWindow)) { return e }
            self.close()
            return e
        }) { monitors.append(m) }
        if let m = NSEvent.addLocalMonitorForEvents(matching: .keyDown, handler: { [weak self] e in
            if e.keyCode == 53 { self?.close(); return nil }
            return e
        }) { monitors.append(m) }
        if let m = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown], handler: { [weak self] _ in
            Task { @MainActor in self?.close() }
        }) { monitors.append(m) }
        activeToken = NotificationCenter.default.addObserver(forName: NSApplication.didResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.close() }
        }
        if let w = parentWindow {
            // The panel takes key for its search field; only a key window that is not ours closes it.
            resignToken = NotificationCenter.default.addObserver(forName: NSWindow.didResignKeyNotification, object: w, queue: .main) { [weak self] _ in
                Task { @MainActor in
                    guard let self else { return }
                    if let k = NSApp.keyWindow, k === self.panel || k === self.sub || k === self.parentWindow { return }
                    self.close()
                }
            }
        }
    }
}

final class DropdownPanel: NSPanel {
    /// A menu that opens downward keeps its top edge where it is when its content changes size.
    var keepTop: CGFloat?
    /// A menu that opens upward keeps its bottom edge, so it grows up; only the screen's top edge stops it.
    var keepBottom: CGFloat?
    override var canBecomeKey: Bool { true }
    private func pinned(_ frameRect: NSRect) -> NSRect {
        var r = frameRect
        if let t = keepTop { r.origin.y = t - r.height }
        else if let b = keepBottom {
            r.origin.y = b
            if let v = screen?.visibleFrame, r.maxY > v.maxY - 10 { r.origin.y = max(v.minY + 10, v.maxY - 10 - r.height) }
        }
        return r
    }
    /// macOS 27 (crashes of, 0.2.0 and 0.2.4): setFrame displays the window, the display lays out the
    /// hosting view, whose preferred content size sets the frame again - inside the first call, until the stack runs
    /// out. A frame asked for while one is being set is applied once on the next turn of the run loop, and a frame
    /// that is already the window's is not set again, so the size still follows the content without recursion.
    private var settingFrame = false
    private var pendingFrame: NSRect?
    private func apply(_ r: NSRect, _ set: (NSRect) -> Void) {
        if settingFrame {
            let first = pendingFrame == nil
            pendingFrame = r
            if first {
                DispatchQueue.main.async { [weak self] in
                    guard let self, let f = self.pendingFrame else { return }
                    self.pendingFrame = nil
                    // Only the size is taken from the deferred request: the place is where the panel was put since
                    // (DropdownHost positions it after creating it). Taking the whole old frame moved the menus to
                    // the screen's corner over the sidebar.
                    var r = self.frame
                    r.origin.y += r.height - f.height   // keep the top edge; `pinned` then applies keepTop / keepBottom
                    r.size = f.size
                    self.setFrame(r, display: true)
                }
            }
            return
        }
        guard !NSEqualRects(r.integral, frame.integral) else { return }
        settingFrame = true
        defer { settingFrame = false }
        set(r)
    }
    override func setFrame(_ frameRect: NSRect, display flag: Bool) {
        apply(pinned(frameRect)) { super.setFrame($0, display: flag) }
    }

    /// The content measured `size` (DropdownPanelView, after any row came or went): the frame takes that size and
    /// its kept edge stays (`pinned`), so a removed row leaves no empty band.
    func fitContent(_ size: CGSize) {
        guard size.width > 1, size.height > 1, !settingFrame else { return }
        let w = size.width.rounded(.up), h = size.height.rounded(.up)
        if abs(frame.width - w) >= 1 || abs(frame.height - h) >= 1 {
            var r = frame
            r.origin.y += r.height - h   // keep the top edge; `pinned` then applies keepTop / keepBottom
            r.size = NSSize(width: w, height: h)
            setFrame(r, display: true)
        }
    }
    override func setFrame(_ frameRect: NSRect, display displayFlag: Bool, animate animateFlag: Bool) {
        apply(pinned(frameRect)) { super.setFrame($0, display: displayFlag, animate: animateFlag) }
    }
}

/// Finds the control's place on screen at the moment it is clicked.
final class AnchorBox { weak var view: NSView? }

struct AnchorReader: NSViewRepresentable {
    let box: AnchorBox
    func makeNSView(context: Context) -> AnchorReaderView { let v = AnchorReaderView(); v.box = box; claim(v); return v }
    func updateNSView(_ v: AnchorReaderView, context: Context) { v.box = box; claim(v) }

    /// A reader that is not in a window (a copy SwiftUI builds and never shows) never takes the box from one
    /// that is: the box kept the last reader updated, and a window-less one made every menu open at the screen's corner.
    @MainActor private func claim(_ v: AnchorReaderView) {
        if v.window != nil || box.view?.window == nil { box.view = v }
    }
}

final class AnchorReaderView: NSView {
    weak var box: AnchorBox?
    /// Only a marker: never takes a click.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil { box?.view = self }
    }
}

extension AnchorBox {
    var screenRect: NSRect {
        guard let v = view, let w = v.window else { return .zero }
        return w.convertToScreen(v.convert(v.bounds, to: nil))
    }
    var window: NSWindow? { view?.window }
}

/// A control that opens a site-styled dropdown. Every trigger lights the same way: the site's
/// hover ground (surface-2, .ai__mb / .ai__tool / .bd__ubtn / .ainav__dots :hover) under the pointer, and a firmer
/// grey for as long as its own menu is up. A tooltip only where the site has one; it steps aside while the menu is open (ai.js).
struct DropdownButton<Label: View, Menu: View>: View {
    var edge: DropdownEdge = .below
    var align: DropdownAlign = .leading
    var gap: CGFloat = 6
    /// What the trigger is (the site's aria-label). Not a tooltip: most of the site's dropdown triggers have none.
    var help: String? = nil
    /// The tooltip, only where the site's trigger has one (data-tip). Steps aside while the menu is open.
    var tip: String? = nil
    /// The highlight's corner radius (8 on the site's triggers, 7 on the title caret).
    var radius: CGFloat = 8
    /// Off for a trigger that paints its own hover and open state.
    var highlight: Bool = true
    var tipPlacement: TipPlacement? = nil
    /// A stable owner, for a view that asks DropdownHost.isOpen(key) itself (a row that keeps its dots up).
    var key: AnyHashable? = nil
    @ViewBuilder var label: () -> Label
    @ViewBuilder var menu: () -> Menu
    @State private var box = AnchorBox()
    @State private var id = UUID()
    @State private var hover = false
    @ObservedObject private var host = DropdownHost.shared

    private var ownerKey: AnyHashable { key ?? AnyHashable(id) }
    private var open: Bool { host.owner == ownerKey }

    var body: some View {
        Button {
            TipHost.shared.dismiss()
            DropdownHost.shared.toggle(ownerKey, anchor: box.screenRect, in: box.window, edge: edge, align: align, gap: gap) { menu() }
        } label: {
            label()
                .overlay(RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .fill(highlight ? (open ? DropdownTrigger.openFill : hover ? DropdownTrigger.hoverFill : Color.clear) : Color.clear)
                    .allowsHitTesting(false))
        }
        .buttonStyle(.liaPlain)
        .background(AnchorReader(box: box))
        .onHover { hover = $0 }
        .liaPointer()
        .liaTip(open ? nil : tip, placement: tipPlacement)
    }
}

/// The trigger grounds: hover is the site's surface-2; open is a step firmer so it reads while the pointer is in the menu.
enum DropdownTrigger {
    static let hoverFill = Color.dyn(dark: (0xffffff, 0.06), light: (0x11141a, 0.05))
    static let openFill = Color.dyn(dark: (0xffffff, 0.11), light: (0x11141a, 0.09))
}

/// The panel itself.
struct DropdownPanelView<Content: View>: View {
    var width: CGFloat? = nil
    var minWidth: CGFloat = 164
    var padding: CGFloat = 4
    var radius: CGFloat = 11
    /// The workspace's glass (wsGlass: Liquid Glass on macOS 26, a material before) instead
    /// of the solid ground; the bar's menus (tab history, tab and group menus, workspaces, Back/Forward, all tabs).
    var glass = false
    @ViewBuilder var content: () -> Content
    var body: some View {
        VStack(alignment: .leading, spacing: 0) { content() }
            .padding(padding)
            .frame(width: width)
            .frame(minWidth: width == nil ? minWidth : nil, alignment: .leading)
            // No shadow: the 1 px line-2 border is the panel's edge.
            .modifier(DropdownGround(radius: radius, glass: glass))
            .padding(DropdownHost.inset)   // the hairline drawn whole
            // The panel follows the content's size after every change (a row deleted inside the menu).
            .background(GeometryReader { g in DropdownFitReader(size: g.size) })
    }
}

/// A dropdown's ground: the solid one (ddBg), or glass; both edged by the 1 px line-2 hairline, never a shadow.
private struct DropdownGround: ViewModifier {
    let radius: CGFloat
    let glass: Bool

    func body(content: Content) -> some View {
        Group {
            if glass {
                content.wsGlass(radius)
            } else {
                content.background(RoundedRectangle(cornerRadius: radius).fill(AppConfig.ddBg))
            }
        }
        .overlay(RoundedRectangle(cornerRadius: radius, style: glass ? .continuous : .circular)
            .stroke(AppConfig.line2, lineWidth: 1).allowsHitTesting(false))
    }
}

/// Reports the panel content's size to its DropdownPanel, which fits its frame to it (DropdownPanelView,
/// LiaCtxPanel).
struct DropdownFitReader: NSViewRepresentable {
    let size: CGSize
    func makeNSView(context: Context) -> NSView { NSView() }
    func updateNSView(_ v: NSView, context: Context) {
        let want = size
        DispatchQueue.main.async { [weak v] in
            (v?.window as? DropdownPanel)?.fitContent(want)
        }
    }
}

/// A row (ai.js .ai__menu button): 17 px icon, 8 px gap, 11.5 px regular, 6x9 padding, radius 8.
struct DropdownItem: View {
    let title: String
    var icon: String? = nil
    var iconSize: CGFloat = 17
    var danger = false
    var trailing: String? = nil          // a caret name, or "check"
    var fontSize: CGFloat = 11.5
    var keepOpen = false
    /// A submenu shown beside the menu while this row is hovered (or clicked).
    var sub: (() -> AnyView)? = nil
    var subGrowsUp = true
    var action: () -> Void = {}
    @State private var hover = false
    @State private var box = AnchorBox()

    private func openSub() {
        guard let sub else { return }
        let r = box.screenRect
        if DropdownHost.shared.subOwner == r { DropdownHost.shared.closeSub(unlessIn: DropdownHost.shared.subWindow); return }
        DropdownHost.shared.showSub(row: r, growsUp: subGrowsUp) { sub() }
    }

    var body: some View {
        Button {
            if sub != nil { openSub(); return }
            if !keepOpen { DropdownHost.shared.close() }
            action()
        } label: {
            HStack(spacing: 8) {
                if let icon { LiaIcon(icon, size: iconSize).frame(width: 17) }
                Text(title).font(LiaFont.ui(fontSize)).lineLimit(1)
                // The site's submenu caret follows the label; a check sits at the far right.
                if sub != nil && trailing == nil { LiaIcon("plus-caret-right", size: 14).foregroundStyle(AppConfig.text3) }
                Spacer(minLength: 8)
                if let trailing { LiaIcon(trailing, size: 14).foregroundStyle(AppConfig.text3) }
            }
            .foregroundStyle(danger ? AppConfig.bad : AppConfig.ink)
            .padding(.horizontal, 9).padding(.vertical, 6)
            .background(RoundedRectangle(cornerRadius: 8).fill(hover ? (danger ? AppConfig.bad.opacity(0.1) : AppConfig.surface2) : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.liaPlain)
        .background(AnchorReader(box: box))
        .onHover { h in
            hover = h
            guard h else { return }
            if sub != nil { openSub() } else { DropdownHost.shared.closeSub(unlessIn: box.window) }
        }
        .liaPointer()
    }
}

struct DropdownDivider: View {
    var body: some View { Rectangle().fill(AppConfig.line).frame(height: 1).padding(.vertical, 4).padding(.horizontal, 6) }
}

/// .ai__menu-title: 9.5 px, heavy, spaced capitals.
struct DropdownTitle: View {
    let text: String
    var body: some View {
        Text(text.uppercased()).font(LiaFont.ui(9.5, .heavy)).tracking(0.76).foregroundStyle(AppConfig.text3)
            .padding(.horizontal, 10).padding(.top, 7).padding(.bottom, 4)
    }
}
