import SwiftUI
import AppKit

/// Moves the traffic lights onto the window's top row, centred on `AppConfig.barHeight / 2`, as the Claude desktop app
/// does, so they share one line with the sidebar, the chat title and the browser tabs.
/// AppKit lays the buttons out again on resize, full screen and key changes, so the position is re-applied each time.
/// The window's full-screen state, for the layouts that make room for the traffic lights (none in full screen).
final class WindowState: ObservableObject {
    static let shared = WindowState()
    @Published var fullScreen = false
    /// Room the lights take at the left of the top row: none in full screen, where macOS hides them.
    var lights: CGFloat { fullScreen ? 0 : AppConfig.lightsInset }
}

struct WindowChrome: NSViewRepresentable {
    func makeNSView(context: Context) -> ChromeView { ChromeView() }
    func updateNSView(_ v: ChromeView, context: Context) { v.apply() }

    final class ChromeView: NSView {
        private var tokens: [NSObjectProtocol] = []

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            tokens.forEach { NotificationCenter.default.removeObserver($0) }
            tokens = []
            guard let w = window else { return }
            let names: [Notification.Name] = [NSWindow.didResizeNotification, NSWindow.didEndLiveResizeNotification,
                                              NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification,
                                              NSWindow.didExitFullScreenNotification, NSWindow.didChangeScreenNotification]
            for n in names {
                tokens.append(NotificationCenter.default.addObserver(forName: n, object: w, queue: .main) { [weak self] _ in self?.apply() })
            }
            tokens.append(NotificationCenter.default.addObserver(forName: NSWindow.willEnterFullScreenNotification, object: w, queue: .main) { _ in
                withAnimation(.easeOut(duration: 0.2)) { WindowState.shared.fullScreen = true }
            })
            tokens.append(NotificationCenter.default.addObserver(forName: NSWindow.willExitFullScreenNotification, object: w, queue: .main) { _ in
                withAnimation(.easeOut(duration: 0.2)) { WindowState.shared.fullScreen = false }
            })
            WindowState.shared.fullScreen = w.styleMask.contains(.fullScreen)
            DispatchQueue.main.async { [weak self] in self?.apply() }
        }

        deinit { tokens.forEach { NotificationCenter.default.removeObserver($0) } }

        override func layout() { super.layout(); apply() }

        func apply() {
            guard let w = window, !w.styleMask.contains(.fullScreen),
                  let close = w.standardWindowButton(.closeButton),
                  let container = close.superview?.superview else { return }
            let bar = AppConfig.barHeight
            // Only as wide as the lights: the titlebar view swallowed clicks meant for the controls on the same row
            // (the collapsed sidebar's button answered only sometimes). The row drags the window via WindowDragArea.
            let want = NSRect(x: 0, y: w.frame.height - bar, width: AppConfig.lightsInset, height: bar)
            if container.frame != want { container.frame = want }
            let kinds: [NSWindow.ButtonType] = [.closeButton, .miniaturizeButton, .zoomButton]
            for (i, k) in kinds.enumerated() {
                guard let b = w.standardWindowButton(k), let sup = b.superview else { continue }
                let h = b.frame.height
                // The buttons' own superview is the titlebar view inside the container; centre within the bar.
                let y = sup.isFlipped ? (bar - h) / 2 : sup.bounds.height - bar + (bar - h) / 2
                let origin = NSPoint(x: 16 + CGFloat(i) * 20, y: y)
                if b.frame.origin != origin { b.setFrameOrigin(origin) }
            }
        }
    }
}

/// How much of the main column's top row, from its left edge, belongs to the window: the traffic lights and the
/// collapsed sidebar's control. A screen's title starts after it.
private struct BarLeadKey: EnvironmentKey { static let defaultValue: CGFloat = 0 }
extension EnvironmentValues {
    var barLead: CGFloat {
        get { self[BarLeadKey.self] }
        set { self[BarLeadKey.self] = newValue }
    }
}

/// The empty parts of the window's top row: drag to move the window, double-click to zoom, as a title bar does.
/// Sits behind the row's controls, so they keep their clicks.
struct WindowDragArea: NSViewRepresentable {
    func makeNSView(context: Context) -> DragView { DragView() }
    func updateNSView(_ v: DragView, context: Context) {}

    final class DragView: NSView {
        override var mouseDownCanMoveWindow: Bool { true }
        override func mouseDown(with e: NSEvent) {
            guard let w = window else { return }
            if e.clickCount == 2 {
                let action = UserDefaults.standard.string(forKey: "AppleActionOnDoubleClick") ?? "Maximize"
                if action == "Minimize" { w.miniaturize(nil) } else if action != "None" { w.zoom(nil) }
                return
            }
            w.performDrag(with: e)
        }
    }
}
