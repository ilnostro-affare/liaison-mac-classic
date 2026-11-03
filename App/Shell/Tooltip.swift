import SwiftUI
import AppKit

// The site's tooltips (shell.js initTooltips + shell.build2.css .lia-tip; ai.js [data-ftip]): one floating bubble at
// body level, so it is never clipped. 11 px semibold on --tip-bg (#383835 dark, white with a line-2 edge light),
// radius 7, 5 x 9 inside, no shadow (the panel cut it square); centred 8 px below the control, flipped above where there is no room,
// clamped 8 px inside the viewport. It shows on mouseover with no delay and a 120 ms fade, hides on mouseout,
// on any mouse down and on scroll. A text over 60 characters wraps at 320 px.
// Here the bubble is a borderless child-less panel that ignores the mouse, the same model as DropdownHost:
// nothing in the window (scroll views, clips, masks) can cut it, and it does not depend on `.help`.

enum TipPlacement { case below, above, right, left }

struct TipSpec: Equatable {
    var text: String
    var kbd: String? = nil
    var placement: TipPlacement = .below
    var light: Bool = false
    /// The modal layer the control sits in (0 = the window itself). A scrim above that layer hides its tips.
    var layer: Int = 0
}

@MainActor
final class TipHost {
    static let shared = TipHost()

    private struct Weak { weak var view: TipAnchorView? }
    private var panel: NSPanel?
    private var hosting: NSHostingView<AnyView>?
    /// The anchors under the pointer, outermost first; the innermost with a text wins (closest('[data-tip]')).
    private var hovered: [Weak] = []
    private weak var shown: TipAnchorView?
    /// A click or a scroll puts the tip away until the pointer leaves that control.
    private var muted: Set<ObjectIdentifier> = []
    private var monitors: [Any] = []
    private var tokens: [NSObjectProtocol] = []
    private var hideJob: DispatchWorkItem?
    private struct WeakOccluder { weak var view: TipOccluderView? }
    /// The scrims on screen (modal overlays, the chat popup's veil): a control under a scrim of a higher layer is
    /// covered, so its tip must not show (nothing behind a modal reacts to the pointer).
    private var occluders: [WeakOccluder] = []

    func addOccluder(_ v: TipOccluderView) {
        occluders.removeAll { $0.view == nil || $0.view === v }
        occluders.append(WeakOccluder(view: v))
        refresh()
    }

    func removeOccluder(_ v: TipOccluderView) {
        occluders.removeAll { $0.view == nil || $0.view === v }
        refresh()
    }

    private func covered(_ v: TipAnchorView) -> Bool {
        guard let w = v.window else { return true }
        let layer: Int = v.spec?.layer ?? 0
        let p: NSPoint = NSEvent.mouseLocation
        for o in occluders {
            guard let ov = o.view, ov.window === w, ov.tipLayer > layer else { continue }
            let r: NSRect = w.convertToScreen(ov.convert(ov.bounds, to: nil))
            if r.contains(p) { return true }
        }
        return false
    }

    /// A point of `w` (screen coordinates) under a scrim of a layer above `layer`: the right-click catchers ask this,
    /// so a menu of a view behind a popup never opens.
    func isCovered(_ p: NSPoint, in w: NSWindow, layer: Int) -> Bool {
        for o in occluders {
            guard let ov = o.view, ov.window === w, ov.tipLayer > layer, !ov.isHiddenOrHasHiddenAncestor else { continue }
            if w.convertToScreen(ov.convert(ov.bounds, to: nil)).contains(p) { return true }
        }
        return false
    }

    func enter(_ v: TipAnchorView) {
        installMonitors()
        hovered.removeAll { $0.view == nil || $0.view === v }
        hovered.append(Weak(view: v))
        refresh()
    }

    func exit(_ v: TipAnchorView) {
        hovered.removeAll { $0.view == nil || $0.view === v }
        muted.remove(ObjectIdentifier(v))
        refresh()
    }

    /// The anchor's text or placement changed (Syncing / Done), or it went away.
    func changed(_ v: TipAnchorView) {
        guard hovered.contains(where: { $0.view === v }) else { return }
        refresh()
    }

    /// Hides whatever shows and mutes it until the pointer leaves it.
    func dismiss() {
        if let s = shown { muted.insert(ObjectIdentifier(s)) }
        hide()
    }

    private func refresh() {
        hovered.removeAll { $0.view == nil || $0.view?.window == nil }
        guard let top = hovered.last(where: { w in
                  guard let v = w.view, v.spec?.text.isEmpty == false else { return false }
                  return !covered(v)
              })?.view,
              !muted.contains(ObjectIdentifier(top)), let spec = top.spec else { hide(); return }
        show(spec, for: top)
    }

    private func show(_ spec: TipSpec, for v: TipAnchorView) {
        guard let w = v.window else { hide(); return }
        hideJob?.cancel(); hideJob = nil
        let p = ensurePanel()
        let wasShowing = shown === v && p.isVisible && p.alphaValue > 0.5
        p.appearance = w.effectiveAppearance
        hosting?.rootView = AnyView(TipBubble(spec: spec).padding(Self.margin))
        hosting?.layoutSubtreeIfNeeded()
        let fit: NSSize = hosting?.fittingSize ?? .zero
        let b = NSSize(width: fit.width - 2 * Self.margin, height: fit.height - 2 * Self.margin)
        let a: NSRect = w.convertToScreen(v.convert(v.bounds, to: nil))
        let vis: NSRect = (w.screen ?? NSScreen.main)?.visibleFrame ?? NSRect(x: -1e5, y: -1e5, width: 2e5, height: 2e5)
        var place = spec.placement
        if place == .below && a.minY - 8 - b.height < vis.minY + 8 { place = .above }
        else if place == .above && a.maxY + 8 + b.height > vis.maxY - 8 { place = .below }
        var x: CGFloat
        var y: CGFloat
        switch place {
        case .below: x = a.midX - b.width / 2; y = a.minY - 8 - b.height
        case .above: x = a.midX - b.width / 2; y = a.maxY + 8
        case .right: x = a.maxX + 10; y = a.midY - b.height / 2
        case .left: x = a.minX - 10 - b.width; y = a.midY - b.height / 2
        }
        x = max(vis.minX + 8, min(x, vis.maxX - 8 - b.width))
        y = max(vis.minY + 8, min(y, vis.maxY - 8 - b.height))
        let frame = NSRect(x: x - Self.margin, y: y - Self.margin, width: fit.width, height: fit.height)
        p.setFrame(frame, display: true)
        shown = v
        if wasShowing { p.alphaValue = 1; return }
        if !p.isVisible { p.alphaValue = 0 }
        p.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.12
            p.animator().alphaValue = 1
        }
    }

    private func hide() {
        shown = nil
        guard let p = panel, p.isVisible, hideJob == nil else { return }
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.12
            p.animator().alphaValue = 0
        }
        let job = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.hideJob = nil
            if self.shown == nil { self.panel?.orderOut(nil) }
        }
        hideJob = job
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.13, execute: job)
    }

    /// Room around the bubble for its hairline (the bubble has no shadow).
    private static let margin: CGFloat = 2

    private func ensurePanel() -> NSPanel {
        if let p = panel { return p }
        let p = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 40, height: 20), styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered, defer: false)
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = false
        p.ignoresMouseEvents = true
        p.isReleasedWhenClosed = false
        p.hidesOnDeactivate = true
        p.level = NSWindow.Level(rawValue: NSWindow.Level.popUpMenu.rawValue + 1)   // above the dropdown panels
        p.collectionBehavior = [.transient, .ignoresCycle, .fullScreenAuxiliary]
        let h = NSHostingView(rootView: AnyView(EmptyView()))
        p.contentView = h
        panel = p
        hosting = h
        return p
    }

    private func installMonitors() {
        guard monitors.isEmpty else { return }
        if let m = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown, .scrollWheel, .keyDown], handler: { [weak self] e in
            self?.dismiss()
            return e
        }) { monitors.append(m) }
        tokens.append(NotificationCenter.default.addObserver(forName: NSApplication.didResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.hovered.removeAll()
                self.muted.removeAll()
                self.hide()
            }
        })
    }
}

/// The bubble (.lia-tip, .lia-tip.is-wide, .lia-tip__kbd; .lia-tip--light over the browser's page).
struct TipBubble: View {
    let spec: TipSpec

    private static let bg = Color.dyn(0x383835, 0xffffff)
    private static let fg = Color.dyn(0xffffff, 0x3d3d3a)
    private static let edge = Color.dyn(dark: (0x000000, 0), light: (0xe2e2e1, 1))

    var body: some View {
        let wide = false   // Every tip is one short line
        HStack(alignment: wide ? .top : .center, spacing: 7) {
            if wide {
                Text(spec.text).font(LiaFont.ui(11, .medium)).lineSpacing(3)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(width: 300, alignment: .leading)
            } else {
                Text(spec.text).font(LiaFont.ui(11, .semibold)).lineLimit(1).fixedSize()
            }
            if let k = spec.kbd, !k.isEmpty {
                HStack(spacing: 3) {
                    ForEach(Array(k.split(separator: "+").enumerated()), id: \.offset) { _, part in
                        Text(part.trimmingCharacters(in: .whitespaces))
                            .font(LiaFont.ui(10.5, .medium)).foregroundStyle(AppConfig.text3)
                            .padding(.horizontal, 5).padding(.vertical, 3)
                            .background(RoundedRectangle(cornerRadius: 5).fill(AppConfig.surface2))
                            .overlay(RoundedRectangle(cornerRadius: 5).stroke(AppConfig.line2, lineWidth: 1))
                    }
                }
            }
        }
        .foregroundStyle(spec.light ? Color(hex: 0x1c2b33) : Self.fg)
        .padding(.horizontal, wide ? 10 : 9).padding(.vertical, wide ? 7 : 5)
        .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(spec.light ? Color.white : Self.bg))
        .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous)
            .stroke(spec.light ? Color(hex: 0xdadde1) : Self.edge, lineWidth: 1))
        .fixedSize()
    }
}

/// An invisible view behind the control: a tracking area tells TipHost when the pointer is over it.
/// It takes no clicks (hitTest nil), so the control under it behaves as before.
final class TipAnchorView: NSView {
    var spec: TipSpec? {
        didSet { if spec != oldValue { TipHost.shared.changed(self) } }
    }
    private var area: NSTrackingArea?

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let a = area { removeTrackingArea(a) }
        let a = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect], owner: self, userInfo: nil)
        addTrackingArea(a)
        area = a
    }

    override func mouseEntered(with event: NSEvent) { TipHost.shared.enter(self) }
    override func mouseExited(with event: NSEvent) { TipHost.shared.exit(self) }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil { TipHost.shared.exit(self) }
    }

    override func viewDidHide() {
        super.viewDidHide()
        TipHost.shared.exit(self)
    }
}

/// A scrim's footprint for TipHost: takes no clicks, only says "everything below layer N here is covered".
final class TipOccluderView: NSView {
    var tipLayer: Int = 1
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil { TipHost.shared.removeOccluder(self) } else { TipHost.shared.addOccluder(self) }
    }
}

struct TipOccluder: NSViewRepresentable {
    let layer: Int
    func makeNSView(context: Context) -> TipOccluderView {
        let v = TipOccluderView()
        v.tipLayer = layer
        return v
    }
    func updateNSView(_ v: TipOccluderView, context: Context) { v.tipLayer = layer }
    static func dismantleNSView(_ v: TipOccluderView, coordinator: ()) { TipHost.shared.removeOccluder(v) }
}

struct TipAnchor: NSViewRepresentable {
    let spec: TipSpec?
    func makeNSView(context: Context) -> TipAnchorView {
        let v = TipAnchorView()
        v.spec = spec
        return v
    }
    func updateNSView(_ v: TipAnchorView, context: Context) { v.spec = spec }
    static func dismantleNSView(_ v: TipAnchorView, coordinator: ()) { TipHost.shared.exit(v) }
}

private struct TipPlacementKey: EnvironmentKey { static let defaultValue: TipPlacement? = nil }
private struct TipLightKey: EnvironmentKey { static let defaultValue: Bool = false }
private struct TipLayerKey: EnvironmentKey { static let defaultValue: Int = 0 }

extension EnvironmentValues {
    /// A subtree's default side for its tips: the row under the composer opens them above (ai.js), the
    /// collapsed rail to the right (shell.js toRight).
    var liaTipPlacement: TipPlacement? {
        get { self[TipPlacementKey.self] }
        set { self[TipPlacementKey.self] = newValue }
    }
    /// Tips over the browser's light page (.lia-tip--light).
    var liaTipLight: Bool {
        get { self[TipLightKey.self] }
        set { self[TipLightKey.self] = newValue }
    }
    /// The modal layer of this subtree (LiaModalHost, ChatPopupOverlay set it); 0 is the window.
    var liaTipLayer: Int {
        get { self[TipLayerKey.self] }
        set { self[TipLayerKey.self] = newValue }
    }
}

struct LiaTipModifier: ViewModifier {
    let text: String?
    let kbd: String?
    let placement: TipPlacement?
    @Environment(\.liaTipPlacement) private var envPlacement: TipPlacement?
    @Environment(\.liaTipLight) private var envLight: Bool
    @Environment(\.liaTipLayer) private var envLayer: Int

    func body(content: Content) -> some View {
        let t: String = (text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let spec: TipSpec? = t.isEmpty ? nil : TipSpec(text: t, kbd: kbd, placement: placement ?? envPlacement ?? .below, light: envLight, layer: envLayer)
        return content.background(TipAnchor(spec: spec))
    }
}

extension View {
    /// The site's tooltip on hover (data-tip / data-ftip). nil or empty shows nothing.
    func liaTip(_ text: String?, kbd: String? = nil, placement: TipPlacement? = nil) -> some View {
        modifier(LiaTipModifier(text: text, kbd: kbd, placement: placement))
    }

    /// Sets the side the tips in this subtree open on.
    func liaTipPlacement(_ p: TipPlacement) -> some View { environment(\.liaTipPlacement, p) }

    /// A sheet or popup drawn in the window itself (the conversation over the side panel):
    /// the tips of everything under its frame stay hidden, its own tips (this layer) show, and so do the right-click
    /// menus (liaContextMenu asks the same scrims). Layers: the window 0, this 10, ChatPopupHost 50, modals 100+.
    func liaTipCover(_ layer: Int = 10) -> some View {
        background(TipOccluder(layer: layer)).environment(\.liaTipLayer, layer)
    }
}
