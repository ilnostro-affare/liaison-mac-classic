import SwiftUI
import AppKit

// Compact mode (Zen Compact Mode, Arc's hidden sidebar), when Prefs.compactMode is on: the top bar
// slides away and the page takes its room; a 6 pt strip at the top edge brings it back over the page, and it hides
// 1.2 s after the pointer leaves it. It stays out while the address is being typed or one of its popovers is open.
// The dock has its own auto-hide (DockAutoHide), not touched here.
// The traffic lights go and come with the bar (Arc's compact mode, Safari's full-screen bar):
// hidden while the bar is away, so nothing floats over the page; shown in the bar, left of the workspace chip (its
// WSLightsKeeper), while it is out. The lights' corner is a hover zone of its own, so reaching for the lights brings
// the bar and them back. Full screen is macOS's own (it hides the lights itself), untouched.

/// In the window's column, where the top bar was: the bar itself, or the strip in compact mode.
struct WSTopBarSlot: View {
    @ObservedObject var ws: WorkspaceModel
    let omni: OmniboxModel
    let lights: CGFloat
    @AppStorage(Prefs.compactMode) private var compact = false

    var body: some View {
        if compact {
            WSCompactStrip()
        } else {
            WSTopBar(ws: ws, omni: omni, lights: lights)
        }
    }
}

/// The 6 pt hover strip along the top edge (it also drags the window, as the bar would).
private struct WSCompactStrip: View {
    var body: some View {
        Color.clear
            .frame(height: 6)
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
            .background(WindowDragArea())
            .onHover { WSCompactTimer.shared.strip($0) }
            .accessibilityElement()
            .accessibilityLabel(Text("Show toolbar"))
            .accessibilityAddTraits(.isButton)
            .accessibilityAction { WSExtras.shared.compactShown = true }
    }
}

/// Over the column's top: the bar while it is out (compact mode only).
struct WSCompactBarOverlay: View {
    @ObservedObject var ws: WorkspaceModel
    @ObservedObject var omni: OmniboxModel
    let lights: CGFloat
    @ObservedObject private var extras = WSExtras.shared
    @ObservedObject private var win = WindowState.shared
    @AppStorage(Prefs.compactMode) private var compact = false
    @Environment(\.accessibilityReduceMotion) private var reduce

    /// Things that keep the bar out whatever the pointer does.
    private var held: Bool { omni.editingTab != nil || ws.showDownloads || ws.showApprovals }

    var body: some View {
        ZStack(alignment: .top) {
            if compact && (extras.compactShown || held) {
                WSTopBar(ws: ws, omni: omni, lights: lights)
                    .background(.regularMaterial)
                    .background(WS.ground.opacity(0.6))
                    .clipShape(UnevenRoundedRectangle(bottomLeadingRadius: 16, bottomTrailingRadius: 16, style: .continuous))
                    .shadow(color: Color.black.opacity(0.10), radius: 14, y: 6)
                    .onHover { WSCompactTimer.shared.bar($0) }
                    .transition(reduce ? AnyTransition.opacity : AnyTransition.move(edge: .top).combined(with: .opacity))
            }
        }
        .frame(maxWidth: .infinity, alignment: .top)
        // The lights' corner (hides them while the bar is away; hovering it brings the bar out).
        .overlay(alignment: .topLeading) {
            if compact && !win.fullScreen {
                WSLightsCorner(hidden: !(extras.compactShown || held))
                    .frame(width: AppConfig.lightsInset, height: AppConfig.barHeight)
                    .allowsHitTesting(false)
            }
        }
        .animation(WSMotion.navigation(reduce), value: extras.compactShown || held)
        .onChange(of: held) { _, h in if !h { WSCompactTimer.shared.recheck() } }
        .onChange(of: compact) { _, _ in extras.compactShown = false }
    }
}

/// The strip and the bar each say whether the pointer is in them; the bar hides 1.2 s after it is in neither.
@MainActor
final class WSCompactTimer {
    static let shared = WSCompactTimer()
    private var inStrip = false
    private var inBar = false
    private var inCorner = false
    private var token = 0

    func strip(_ inside: Bool) {
        inStrip = inside
        if inside { WSExtras.shared.compactShown = true }
        recheck()
    }

    /// The traffic lights' corner (WSLightsCorner) counts as the strip.
    func corner(_ inside: Bool) {
        inCorner = inside
        if inside { WSExtras.shared.compactShown = true }
        recheck()
    }

    func bar(_ inside: Bool) {
        inBar = inside
        recheck()
    }

    func recheck() {
        token += 1
        guard !inStrip, !inBar, !inCorner else { return }
        let t = token
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in
            guard let self, t == self.token, !self.inStrip, !self.inBar, !self.inCorner else { return }
            WSExtras.shared.compactShown = false
        }
    }
}

/// Over the traffic lights' corner in compact mode. While `hidden` (the bar away) it fades the window's close /
/// minimise / zoom out and keeps them out across key changes (AppKit re-shows them); when the bar is out, or compact
/// mode ends (the view leaves the window), it gives them back, and the bar's WSLightsKeeper keeps them shown. It takes
/// no clicks (hitTest nil); a tracking area tells WSCompactTimer when the pointer reaches for the lights. Faded, not
/// isHidden: a hidden close button makes performClose (\u{2318}W) beep. Position stays WindowChrome's (one writer).
struct WSLightsCorner: NSViewRepresentable {
    let hidden: Bool
    /// True while the corner holds the lights out; WSLightsKeeper (the bar's, mid slide-out) then leaves them alone.
    @MainActor static var suppressed = false

    func makeNSView(context: Context) -> CornerView { CornerView() }
    func updateNSView(_ v: CornerView, context: Context) { v.set(hidden: hidden) }

    final class CornerView: NSView {
        private var tokens: [NSObjectProtocol] = []
        private var hideLights = false
        private var area: NSTrackingArea?

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            if let area { removeTrackingArea(area) }
            let a = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                   owner: self, userInfo: nil)
            addTrackingArea(a)
            area = a
        }

        override func mouseEntered(with event: NSEvent) { WSCompactTimer.shared.corner(true) }
        override func mouseExited(with event: NSEvent) { WSCompactTimer.shared.corner(false) }

        override func viewWillMove(toWindow newWindow: NSWindow?) {
            super.viewWillMove(toWindow: newWindow)
            // Leaving (compact mode off, full screen): the lights come back, the pointer is no longer in the corner.
            if newWindow == nil {
                hideLights = false
                WSLightsCorner.suppressed = false
                apply(window, alpha: 1, animated: false)
                WSCompactTimer.shared.corner(false)
            }
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            tokens.forEach { NotificationCenter.default.removeObserver($0) }
            tokens = []
            guard let w = window else { return }
            for n in [NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification, NSWindow.didExitFullScreenNotification,
                      NSWindow.didEndLiveResizeNotification] {
                tokens.append(NotificationCenter.default.addObserver(forName: n, object: w, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.reapply() }
                })
            }
            DispatchQueue.main.async { [weak self] in self?.reapply() }
        }

        deinit { tokens.forEach { NotificationCenter.default.removeObserver($0) } }

        override func layout() { super.layout(); reapply() }

        func set(hidden: Bool) {
            guard hidden != hideLights else { reapply(); return }
            hideLights = hidden
            WSLightsCorner.suppressed = hidden
            apply(window, alpha: hidden ? 0 : 1, animated: true)
        }

        private func reapply() { if hideLights { apply(window, alpha: 0, animated: false) } }

        private func apply(_ w: NSWindow?, alpha: CGFloat, animated: Bool) {
            guard let w, !w.styleMask.contains(.fullScreen) else { return }
            let buttons = [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton].compactMap { w.standardWindowButton($0) }
            let reduce = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
            for b in buttons {
                if alpha > 0, b.isHidden { b.isHidden = false }
                guard abs(b.alphaValue - alpha) > 0.01 else { continue }
                if animated && !reduce {
                    NSAnimationContext.runAnimationGroup { c in
                        c.duration = 0.18
                        b.animator().alphaValue = alpha
                    }
                } else {
                    b.alphaValue = alpha
                }
            }
        }
    }
}

// MARK: - the lights in full screen

/// Full screen hides the window's title bar and its close / minimise / zoom with it. In the top bar, left of the
/// workspace, we draw the three ourselves while the window is in full screen (nothing otherwise): close
/// (performClose), minimise greyed out as macOS does in full screen, and the green one leaves full screen
/// (toggleFullScreen). The system look: 12 pt circles 8 pt apart, their glyphs while the pointer is over the group,
/// grey in a window that is not key.
struct WSFullScreenLights: View {
    @ObservedObject private var win = WindowState.shared
    @Environment(\.controlActiveState) private var active
    @State private var hover = false

    var body: some View {
        if win.fullScreen {
            HStack(spacing: 8) {
                light(Self.red, glyph: "xmark", label: "Close window") { window?.performClose(nil) }
                light(Self.yellow, glyph: "minus", label: "Minimize, not available in full screen", enabled: false) {}
                light(Self.green, glyph: "arrow.down.right.and.arrow.up.left", label: "Exit full screen") { window?.toggleFullScreen(nil) }
            }
            .padding(.leading, 8)
            .padding(.trailing, 4)
            .frame(height: 28)
            .contentShape(Rectangle())
            .onHover { hover = $0 }
            .transition(.opacity)
            .accessibilityElement(children: .contain)
        }
    }

    private var window: NSWindow? { NSApp.keyWindow ?? NSApp.mainWindow }

    private static let red = Color(red: 1, green: 95 / 255, blue: 87 / 255)
    private static let yellow = Color(red: 254 / 255, green: 188 / 255, blue: 46 / 255)
    private static let green = Color(red: 40 / 255, green: 200 / 255, blue: 64 / 255)
    private static let off = Color(white: 0.5).opacity(0.28)

    private func light(_ c: Color, glyph: String, label: String, enabled: Bool = true, action: @escaping () -> Void) -> some View {
        let lit = enabled && active != .inactive
        return Button(action: action) {
            ZStack {
                Circle().fill(lit ? c : Self.off)
                Circle().strokeBorder(Color.black.opacity(0.12), lineWidth: 0.5)
                if hover && enabled {
                    Image(systemName: glyph)
                        .font(.system(size: glyph == "minus" ? 8 : 6.5, weight: .bold))
                        .foregroundStyle(Color.black.opacity(0.55))
                }
            }
            .frame(width: 12, height: 12)
            .padding(4)
            .contentShape(Circle())
        }
        .buttonStyle(.liaPlain)
        .disabled(!enabled)
        .padding(-4)
        .accessibilityLabel(Text(label))
    }
}
