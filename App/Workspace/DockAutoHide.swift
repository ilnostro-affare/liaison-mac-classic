import SwiftUI
import AppKit

// In full screen the dock hides below the window's bottom edge and slides up when the pointer comes within
// ~6 pt of that edge (a thin hover strip); it hides again 1.5 s after the pointer leaves it. An agent's message that
// needs the person peeks it for 2.5 s.

/// Whether the dock's own window is in full screen (enter/exit notifications filtered to that window).
@MainActor
final class DockFullScreen: ObservableObject {
    @Published private(set) var on = false
    weak var window: NSWindow? {
        didSet { on = window?.styleMask.contains(.fullScreen) ?? false }
    }

    func update(_ n: Notification, entering: Bool) {
        guard let w = n.object as? NSWindow, w === window else { return }
        on = entering
    }
}

/// Finds the NSWindow a view lives in.
struct DockWindowReader: NSViewRepresentable {
    let found: (NSWindow?) -> Void
    func makeNSView(context: Context) -> NSView {
        let v = NSView()
        DispatchQueue.main.async { [weak v] in found(v?.window) }
        return v
    }
    func updateNSView(_ v: NSView, context: Context) {
        DispatchQueue.main.async { [weak v] in found(v?.window) }
    }
}

struct DockAutoHide: ViewModifier {
    /// The space under the dock to the window's bottom edge (WorkspaceWindow pads the dock by 26).
    var bottomGap: CGFloat = 26
    @StateObject private var fs = DockFullScreen()
    @State private var shown = false
    @State private var height: CGFloat = 90
    @State private var hideTask: Task<Void, Never>?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// With VoiceOver on the dock never hides (it would be out of reach).
    private var hidden: Bool { fs.on && !shown && !NSWorkspace.shared.isVoiceOverEnabled }

    func body(content: Content) -> some View {
        content
            .background(GeometryReader { g in Color.clear.onAppear { height = g.size.height }
                .onChange(of: g.size.height) { _, h in height = h } })
            // Hover on the dock itself (before the offset), so its empty place never brings it back.
            .onHover { inside in hover(inside) }
            .offset(y: hidden ? height + bottomGap + 12 : 0)
            .opacity(hidden ? 0 : 1)
            .overlay(alignment: .bottom) { strip }
            .background(DockWindowReader { w in if fs.window !== w { fs.window = w } }.frame(width: 0, height: 0))
            .onReceive(NotificationCenter.default.publisher(for: NSWindow.didEnterFullScreenNotification)) { fs.update($0, entering: true) }
            .onReceive(NotificationCenter.default.publisher(for: NSWindow.didExitFullScreenNotification)) { fs.update($0, entering: false) }
            .onChange(of: fs.on) { _, _ in set(false); hideTask?.cancel() }
            // An agent's message that needs the person while the dock is hidden: the dock peeks for a
            // moment, so the agent's jump and its count are seen; it hides again by itself (not under the pointer).
            .onReceive(NotificationCenter.default.publisher(for: .liaAgentAttention)) { _ in peek() }
    }

    /// The hover strip along the window's bottom edge, only while the dock is hidden in full screen, with a small
    /// glass chip at the centre so the person knows where the dock went.
    @ViewBuilder private var strip: some View {
        if hidden {
            ZStack(alignment: .bottom) {
                Color.clear
                    .frame(width: max(NSScreen.main?.frame.width ?? 1600, 800), height: 6)
                    .contentShape(Rectangle())
                DockHintChip()
            }
            .onHover { if $0 { reveal(); scheduleHide() } }
            .offset(y: bottomGap)
            .transition(.opacity)
            .accessibilityHidden(true)
        }
    }

    private func hover(_ inside: Bool) {
        guard fs.on else { return }
        if inside { reveal() } else { scheduleHide() }
    }

    private func reveal() {
        hideTask?.cancel()
        set(true)
    }

    /// Shown for 2.5 s when hidden (the figure's jump plays meanwhile); a pointer over it keeps it as usual.
    private func peek() {
        guard fs.on, !shown else { return }
        reveal()
        scheduleHide(after: 2.5)
    }

    private func scheduleHide(after seconds: Double = 1.5) {
        hideTask?.cancel()
        hideTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            guard !Task.isCancelled else { return }
            set(false)
        }
    }

    private func set(_ on: Bool) {
        guard shown != on else { return }
        if reduceMotion { shown = on } else { withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) { shown = on } }
    }
}


/// The hidden dock's hint: a 44x6 glass capsule at the bottom centre; it brightens a little under the pointer.
private struct DockHintChip: View {
    @State private var over = false
    var body: some View {
        Color.clear
            .frame(width: 44, height: 6)
            .wsGlass(3)
            .opacity(over ? 1 : 0.7)
            .padding(.vertical, 6)
            .padding(.horizontal, 10)
            .contentShape(Rectangle())
            .onHover { over = $0 }
            .animation(.easeOut(duration: 0.15), value: over)
    }
}
