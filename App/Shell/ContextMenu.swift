import SwiftUI
import AppKit
import WebKit

// The site's right-click menu (ai.js liaCtx, .lia-ctx; the chart's copy is .blk-ctx) and its small confirm
// (ai.js bdModal / bdConfirm, .lia-confirm). A SwiftUI .contextMenu is an NSMenu and a confirmationDialog is an
// NSAlert sheet; neither can be drawn the way the site draws them, so both are ours. The menu opens through
// DropdownHost, at the pointer, so it closes on an outside click or Escape like every other dropdown.

/// One row of the menu, or a separator (.lia-ctx__sep).
struct LiaCtxItem: Identifiable {
    let id = UUID()
    var title: String = ""
    var icon: String? = nil
    var danger: Bool = false
    var separator: Bool = false
    /// A submenu shown beside the menu while this row is hovered (or clicked); the row's own action is not run.
    var sub: [LiaCtxItem]? = nil
    var action: () -> Void = {}

    static var sep: LiaCtxItem { LiaCtxItem(separator: true) }
}

extension View {
    /// Right click (or control-click) opens the site's context menu at the pointer. An empty list opens nothing.
    func liaContextMenu(_ items: @escaping () -> [LiaCtxItem]) -> some View {
        modifier(LiaContextMenuModifier(items: items))
    }
}

private struct LiaContextMenuModifier: ViewModifier {
    let items: () -> [LiaCtxItem]
    @State private var owner = UUID()
    /// The modal layer the view sits in: a scrim of a higher layer over it (TipOccluder) means the click is not its.
    @Environment(\.liaTipLayer) private var layer: Int

    func body(content: Content) -> some View {
        content.overlay(RightClickCatcher(layer: layer) { point, window in
            let list: [LiaCtxItem] = items()
            guard !list.isEmpty else { return }
            TipHost.shared.dismiss()
            let anchor = NSRect(x: point.x, y: point.y, width: 0, height: 0)
            DropdownHost.shared.toggle(AnyHashable(owner), anchor: anchor, in: window, edge: .below, align: .leading, gap: 2) {
                LiaCtxPanel(items: list)
            }
        })
    }
}

/// .lia-ctx: canvas ground, 1 px --line-2, radius 10, min-width 186, padding 4; no shadow.
struct LiaCtxPanel: View {
    let items: [LiaCtxItem]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(items) { it in
                if it.separator {
                    // .lia-ctx__sep: 1 px --line-2, margin 4 6.
                    Rectangle().fill(AppConfig.line2).frame(height: 1).padding(.vertical, 4).padding(.horizontal, 6)
                } else {
                    LiaCtxRow(item: it)
                }
            }
        }
        .padding(4)
        .frame(minWidth: 186, alignment: .leading)
        .fixedSize()
        .background(RoundedRectangle(cornerRadius: 10).fill(AppConfig.canvasBg))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(AppConfig.line2, lineWidth: 1))
        .padding(DropdownHost.inset)
        .background(GeometryReader { g in DropdownFitReader(size: g.size) })   // the panel follows a row removed
    }
}

/// The tab's and the group's menus in the newest dropdowns' look: the glass panel
/// (DropdownPanelView glass), DropdownItem rows (16 px icon, 12.5 px, ink, surface-2 under the pointer, radius 8),
/// DropdownDivider between sections, no shadow. Submenus open in the same panel.
struct LiaCtxGlassPanel: View {
    let items: [LiaCtxItem]

    var body: some View {
        DropdownPanelView(minWidth: 210, glass: true) {
            ForEach(items) { it in row(it) }
        }
        .fixedSize()
    }

    @ViewBuilder private func row(_ it: LiaCtxItem) -> some View {
        if it.separator {
            DropdownDivider()
        } else {
            DropdownItem(title: it.title, icon: it.icon, iconSize: 16, danger: it.danger, fontSize: 12.5,
                         sub: Self.subPanel(it), subGrowsUp: false, action: it.action)
        }
    }

    private static func subPanel(_ it: LiaCtxItem) -> (() -> AnyView)? {
        guard let list = it.sub, !list.isEmpty else { return nil }
        return { AnyView(LiaCtxGlassPanel(items: list)) }
    }
}

/// .lia-ctx__item: 13 px --text-2 (#e5484d when it deletes), 18 px icon, gap 9, padding 8 10, radius 7,
/// rgba(127,127,127,.09) under the pointer. A row with `sub` carries a caret and opens its submenu beside the menu.
private struct LiaCtxRow: View {
    let item: LiaCtxItem
    @State private var hover = false
    @State private var box = AnchorBox()

    private func openSub() {
        guard let sub = item.sub, !sub.isEmpty else { return }
        let r = box.screenRect
        if DropdownHost.shared.subOwner == r { return }
        DropdownHost.shared.showSub(row: r, growsUp: false) { LiaCtxPanel(items: sub) }
    }

    var body: some View {
        Button {
            if item.sub != nil { openSub(); return }
            DropdownHost.shared.close()
            item.action()
        } label: {
            HStack(spacing: 9) {
                if let icon = item.icon { LiaIcon(icon, size: 18).frame(width: 18) }
                Text(item.title).font(LiaFont.ui(13)).lineLimit(1)
                Spacer(minLength: 8)
                if item.sub != nil { LiaIcon("plus-caret-right", size: 14).foregroundStyle(AppConfig.text3) }
            }
            .foregroundStyle(item.danger ? Color(red: 229 / 255, green: 72 / 255, blue: 77 / 255) : AppConfig.text2)
            .padding(.horizontal, 10).padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 7).fill(hover ? Color(white: 0.5).opacity(0.09) : Color.clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.liaPlain)
        .background(AnchorReader(box: box))
        .onHover { h in
            hover = h
            guard h else { return }
            if item.sub != nil { openSub() } else { DropdownHost.shared.closeSub(unlessIn: box.window) }
        }
        .liaPointer()
    }
}

/// The secondary click (right button, or control-click) inside a view with liaContextMenu.
///
/// (item 1): the tabs never opened their menu. This view used to take the click through AppKit's hit
/// testing (hitTest answered only while NSApp.currentEvent was a right click). Inside the tab row the click never got
/// to it: the row sits in SwiftUI's NSScrollView under onDrag / onTapGesture / focusable, and SwiftUI's own hit
/// testing handed the right button elsewhere (the same reason the NSMenu .contextMenu never opened there either).
/// Now one app-wide local monitor sees every secondary click before any view does and gives it to the innermost
/// catcher under the pointer, if nothing else is on top there: a scrim of a higher modal layer (TipOccluder), or an
/// AppKit view that is not the catcher's host (a web view, a text view with its own menu, the window's buttons).
/// The catcher itself never takes a click (hitTest nil), so every other event goes to the view underneath as before.
private struct RightClickCatcher: NSViewRepresentable {
    var layer: Int = 0
    let fire: (NSPoint, NSWindow?) -> Void

    func makeNSView(context: Context) -> RightClickView {
        let v = RightClickView()
        v.fire = fire
        v.tipLayer = layer
        return v
    }

    func updateNSView(_ v: RightClickView, context: Context) {
        v.fire = fire
        v.tipLayer = layer
    }
}

final class RightClickView: NSView {
    var fire: ((NSPoint, NSWindow?) -> Void)?
    var tipLayer: Int = 0   // not `layer`: NSView.layer is the CALayer
    private static let all = NSHashTable<RightClickView>.weakObjects()
    private static var monitor: Any?

    nonisolated private static func isSecondary(_ e: NSEvent) -> Bool {
        if e.type == .rightMouseDown { return true }
        return e.type == .leftMouseDown && e.modifierFlags.contains(.control)
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil {
            Self.all.add(self)
            Self.install()
        } else {
            Self.all.remove(self)
        }
    }

    private static func install() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.rightMouseDown, .leftMouseDown]) { e in
            guard isSecondary(e) else { return e }
            let used: Bool = MainActor.assumeIsolated {
                guard let v = catcher(for: e), let w = v.window else { return false }
                v.fire?(w.convertPoint(toScreen: e.locationInWindow), w)
                return true
            }
            return used ? nil : e
        }
    }

    /// The innermost visible catcher under the pointer in the event's window, when nothing covers it there.
    @MainActor private static func catcher(for e: NSEvent) -> RightClickView? {
        guard let w = e.window else { return nil }
        let hits = all.allObjects.filter { v in
            v.window === w && !v.isHiddenOrHasHiddenAncestor && v.fire != nil
                && v.visibleRect.contains(v.convert(e.locationInWindow, from: nil))
        }
        guard let best = hits.min(by: { $0.visibleRect.width * $0.visibleRect.height < $1.visibleRect.width * $1.visibleRect.height })
        else { return nil }
        let screen = w.convertPoint(toScreen: e.locationInWindow)
        if TipHost.shared.isCovered(screen, in: w, layer: best.tipLayer) { return nil }
        // An AppKit view on top with a right click of its own (a web page, a text field or text view, the window's
        // buttons) keeps it. SwiftUI's own views and the catcher's hosts do not count.
        if let frame = w.contentView?.superview ?? w.contentView,
           let top = frame.hitTest(frame.convert(e.locationInWindow, from: nil)) {
            var x: NSView? = top
            while let v = x, v !== frame, !best.isDescendant(of: v) {
                if v is WKWebView || v is NSText || v is NSTextField || v is NSButton { return nil }
                x = v.superview
            }
        }
        return best
    }
}

/// ai.js bdConfirm in bdModal: a rgba(8,10,14,.44) veil; the card --dd-bg, 1 px --line-2, radius 16, padding 18 20,
/// 280 to 360 wide; the title 13.5 / 700, the line under it 12 --text-3; Cancel outlined, the answer filled
/// (#C25454 when it destroys, --nav-sel otherwise), both 12 / 600, padding 7 14, radius 10. A click on the veil cancels.
struct LiaConfirm: View {
    let title: String
    var sub: String = ""
    var yes: String = "Confirm"
    var danger: Bool = false
    let onYes: () -> Void
    let onNo: () -> Void

    var body: some View {
        ZStack {
            Color(red: 8 / 255, green: 10 / 255, blue: 14 / 255).opacity(0.44)
                .contentShape(Rectangle())
                .onTapGesture { onNo() }
            VStack(alignment: .leading, spacing: 0) {
                Text(title).font(LiaFont.ui(13.5, .bold)).foregroundStyle(AppConfig.ink)
                if !sub.isEmpty {
                    Text(sub).font(LiaFont.ui(12)).foregroundStyle(AppConfig.text3)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, 6)
                }
                HStack(spacing: 8) {
                    Spacer(minLength: 0)
                    Button(action: onNo) {
                        Text("Cancel").font(LiaFont.ui(12, .semibold)).foregroundStyle(AppConfig.text2)
                            .padding(.horizontal, 14).padding(.vertical, 7)
                            .overlay(RoundedRectangle(cornerRadius: 10).stroke(AppConfig.line2, lineWidth: 1))
                            .contentShape(RoundedRectangle(cornerRadius: 10))
                    }
                    .buttonStyle(.liaPlain)
                    .liaHover(.fill, radius: 10)
                    Button(action: onYes) {
                        Text(yes).font(LiaFont.ui(12, .semibold)).foregroundStyle(danger ? Color.white : AppConfig.navSelText)
                            .padding(.horizontal, 14).padding(.vertical, 7)
                            .background(RoundedRectangle(cornerRadius: 10)
                                .fill(danger ? Color(red: 194 / 255, green: 84 / 255, blue: 84 / 255) : AppConfig.navSel))
                            .contentShape(RoundedRectangle(cornerRadius: 10))
                    }
                    .buttonStyle(.liaPlain)
                    .liaHover(.solid)
                }
                .padding(.top, 16)
            }
            .padding(.horizontal, 20).padding(.vertical, 18)
            .frame(minWidth: 280, maxWidth: 360, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
            .background(RoundedRectangle(cornerRadius: 16).fill(AppConfig.ddBg)
                .shadow(color: .black.opacity(0.35), radius: 30, y: 18))
            .overlay(RoundedRectangle(cornerRadius: 16).stroke(AppConfig.line2, lineWidth: 1))
            .padding(24)
        }
    }
}

// MARK: - the tab strip's right-click targets

/// A right-click target AppKit finds itself: an NSView over the control (an overlay) that AppKit's hit test returns
/// only for a secondary click (the right button, or control-click), so left clicks, drags and hovers reach the
/// SwiftUI view underneath exactly as before. On a right-click it hands its OWN frame on screen and its window to
/// `fire`, and the menu opens under that frame: never a frame looked up elsewhere, never the pointer compared with
/// stored frames (an earlier resolver of the strip did that and opened menus at the strip's left start).
/// `key` names the target, so a menu opened another way (the strip's empty room, VoiceOver) finds the frame of the
/// control it belongs to (`RightClickTargetView.screenRect(key:)`).
struct RightClickTarget: NSViewRepresentable {
    var key: String? = nil
    var enabled = true
    let fire: (NSRect, NSWindow) -> Void

    func makeNSView(context: Context) -> RightClickTargetView {
        let v = RightClickTargetView()
        update(v)
        return v
    }

    func updateNSView(_ v: RightClickTargetView, context: Context) { update(v) }

    @MainActor private func update(_ v: RightClickTargetView) {
        v.fire = fire
        v.key = key
        v.enabled = enabled
    }
}

final class RightClickTargetView: NSView {
    var fire: ((NSRect, NSWindow) -> Void)?
    var key: String?
    var enabled = true
    private static let all = NSHashTable<RightClickTargetView>.weakObjects()
    private static var monitor: Any?

    nonisolated private static func isSecondary(_ e: NSEvent) -> Bool {
        if e.type == .rightMouseDown || e.type == .rightMouseUp { return true }
        return (e.type == .leftMouseDown || e.type == .leftMouseUp) && e.modifierFlags.contains(.control)
    }

    /// Itself, for a secondary click inside it; nil for everything else (the view underneath keeps it).
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard enabled, fire != nil, let e = NSApp.currentEvent, Self.isSecondary(e) else { return nil }
        return frame.contains(point) ? self : nil
    }

    override func rightMouseDown(with event: NSEvent) { trigger() }
    override func rightMouseUp(with event: NSEvent) {}

    override func mouseDown(with event: NSEvent) {
        if event.modifierFlags.contains(.control) { trigger() } else { super.mouseDown(with: event) }
    }

    /// No system menu ever (ours opens instead).
    override func menu(for event: NSEvent) -> NSMenu? { nil }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil {
            Self.all.add(self)
            Self.install()
        } else {
            Self.all.remove(self)
        }
    }

    /// Its frame on screen, now.
    var screenFrame: NSRect? {
        guard let w = window, !isHiddenOrHasHiddenAncestor, bounds.width > 0 else { return nil }
        return w.convertToScreen(convert(bounds, to: nil))
    }

    private func trigger() {
        guard let w = window, let r = screenFrame else { return }
        // A sheet or popup drawn in the window itself over the target (a scrim of a higher layer): not its click.
        if TipHost.shared.isCovered(NSEvent.mouseLocation, in: w, layer: 0) { return }
        fire?(r, w)
    }

    /// The frame on screen of the target named `key` that is in a window and shown (nil: none drawn).
    @MainActor static func screenRect(key: String, in window: NSWindow? = nil) -> (rect: NSRect, window: NSWindow)? {
        for v in all.allObjects where v.key == key {
            guard let w = v.window, window == nil || w === window, let r = v.screenFrame else { continue }
            return (r, w)
        }
        return nil
    }

    /// A safety net, not the path: when SwiftUI's own hit testing hands the secondary click to a view of its own
    /// (a gesture or focus host over the target, as liaContextMenu once found), the click still goes to the target
    /// under the pointer: the smallest one whose frame holds it (a tab over the strip's row). When AppKit's hit test
    /// finds a target itself, or an AppKit view with a right click of its own (a web page, a text field), nothing is
    /// done here.
    private static func install() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.rightMouseDown, .leftMouseDown]) { e in
            guard isSecondary(e) else { return e }
            let used: Bool = MainActor.assumeIsolated { () -> Bool in
                guard let w = e.window, let frame = w.contentView?.superview ?? w.contentView else { return false }
                let top = frame.hitTest(frame.convert(e.locationInWindow, from: nil))
                var x: NSView? = top
                while let v = x {
                    if v is RightClickTargetView { return false }   // AppKit delivers it there
                    if v is WKWebView || v is NSText || v is NSTextField || v is NSButton { return false }
                    x = v.superview
                }
                let hits = all.allObjects.filter { v in
                    guard v.window === w, v.enabled, v.fire != nil, !v.isHiddenOrHasHiddenAncestor else { return false }
                    return v.convert(v.bounds, to: nil).contains(e.locationInWindow)
                }
                guard let best = hits.min(by: { $0.bounds.width * $0.bounds.height < $1.bounds.width * $1.bounds.height })
                else { return false }
                best.trigger()
                return true
            }
            return used ? nil : e
        }
    }
}
