import SwiftUI
import AppKit

// Crea's pictures on a board in the Canvas, moved and zoomed. Since that board is
// Crea Studio (CreaStudioView.swift); the dots and the scroll / pinch / key monitor below are shared with it.

// The board is Crea Studio now - the whole project as one graph (CreaStudioView.swift). This view
// keeps the Canvas's call (CanvasPane mounts it for a Crea item) and hands the block over to the studio.

struct CanvasImageBoard: View {
    let board: CreaBoard
    let auth: AuthStore
    /// Bumped by the store when the board is opened again (another picture clicked in the chat): show that one.
    let refits: Int
    let ctx: CreaContext?
    let onSelect: (String) -> Void

    init(board: CreaBoard, auth: AuthStore, refits: Int, ctx: CreaContext?, onSelect: @escaping (String) -> Void) {
        self.board = board; self.auth = auth; self.refits = refits; self.ctx = ctx; self.onSelect = onSelect
    }

    var body: some View {
        CreaStudioView(board: board, profile: profile, auth: auth, refits: refits, onSelect: onSelect)
    }

    private var profile: String { board.chatProfile ?? ctx?.profile ?? WorkspaceModel.current?.profileId ?? "" }
}

/// The board's dots, moving and spreading with the pan and the zoom (none when they would be a haze).
struct BoardDots: View {
    let scale: Double
    let offset: CGSize

    var body: some View {
        Canvas { ctx, size in
            let step = 32 * scale
            guard step >= 10 else { return }
            let ox = (size.width / 2 + offset.width).truncatingRemainder(dividingBy: step)
            let oy = (size.height / 2 + offset.height).truncatingRemainder(dividingBy: step)
            var path = Path()
            var x = ox < 0 ? ox + step : ox
            while x < size.width {
                var y = oy < 0 ? oy + step : oy
                while y < size.height {
                    path.addEllipse(in: CGRect(x: x - 0.75, y: y - 0.75, width: 1.5, height: 1.5))
                    y += step
                }
                x += step
            }
            ctx.fill(path, with: .color(WS.text3.opacity(0.35)))
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// Scroll, pinch and the zoom keys over the board, seen before AppKit delivers them (a local monitor): SwiftUI has
/// no scroll-wheel or cursor-anchored pinch of its own on macOS. The view takes no clicks (hitTest nil).
struct BoardEvents: NSViewRepresentable {
    var onScroll: (NSEvent, CGPoint) -> Bool
    var onMagnify: (CGFloat, CGPoint) -> Void
    var onKey: (NSEvent) -> Bool

    func makeNSView(context: Context) -> BoardEventView {
        let v = BoardEventView()
        v.handlers = self
        return v
    }

    func updateNSView(_ v: BoardEventView, context: Context) { v.handlers = self }

    static func dismantleNSView(_ v: BoardEventView, coordinator: ()) { v.stop() }
}

final class BoardEventView: NSView {
    var handlers: BoardEvents?
    private var monitor: Any?
    /// The last click in the window was on the board (the zoom keys then work without the pointer over it).
    private var active = false

    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        stop()
        guard window != nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.scrollWheel, .magnify, .leftMouseDown, .keyDown]) { [weak self] e in
            guard let self else { return e }
            return self.handle(e)
        }
    }

    func stop() {
        if let m = monitor { NSEvent.removeMonitor(m) }
        monitor = nil
    }

    deinit { if let m = monitor { NSEvent.removeMonitor(m) } }

    private func inside(_ e: NSEvent) -> CGPoint? {
        guard let w = window, e.window === w, !isHiddenOrHasHiddenAncestor else { return nil }
        let p = convert(e.locationInWindow, from: nil)
        return bounds.contains(p) ? p : nil
    }

    private var pointerInside: Bool {
        guard let w = window else { return false }
        return bounds.contains(convert(w.mouseLocationOutsideOfEventStream, from: nil))
    }

    private func handle(_ e: NSEvent) -> NSEvent? {
        guard let h = handlers else { return e }
        switch e.type {
        case .leftMouseDown:
            active = inside(e) != nil
            return e
        case .scrollWheel:
            guard let p = inside(e) else { return e }
            return h.onScroll(e, p) ? nil : e
        case .magnify:
            guard let p = inside(e) else { return e }
            h.onMagnify(e.magnification, p)
            return nil
        case .keyDown:
            guard let w = window, e.window === w, w.isKeyWindow, !isHiddenOrHasHiddenAncestor, active || pointerInside else { return e }
            return h.onKey(e) ? nil : e
        default:
            return e
        }
    }
}
