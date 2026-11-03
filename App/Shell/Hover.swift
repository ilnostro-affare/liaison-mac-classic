import SwiftUI
import AppKit

// One hover for every clickable thing: under the pointer a control lights and the pointer is the
// pointing hand, as on the site (cursor: pointer). Controls that already paint their own hover keep it and take only
// the hand (`.liaPointer`, or `.liaHover(.pointer, isHovered: $hover)` to drive their own look).
// .fill a row or a text button: the site's surface-2 ground under it (the sidebar rows' hover).
// .icon an icon button: the dropdown triggers' hover ground; pass `tint` (its resting colour) and the glyph
// goes to full ink under the pointer.
// .text a text-like toggle (Worked, a tool or thought row, Saved to memory): no ground; the caller brightens
// its own text through `isHovered` (its colours carry alpha, which no generic filter can lift).
// .solid a filled button (accent, ink, red): the face eases back a touch (the site's :hover opacity .88).
// .pointer the hand only.
// .off nothing (a row that opens nothing right now), so a call site can switch the hover off in place.
// `tint`, with any style, is the resting foreground; it goes to full ink under the pointer.
// A clickable control never selects text: `.textSelection(.disabled)` under it, so a label is never an I-beam.

enum LiaHoverStyle { case fill, icon, text, solid, pointer, off }

extension View {
    /// The hover and the pointing hand for a clickable view. `radius` shapes the ground of .fill and .icon; `tint`
    /// is the resting foreground, ink under the pointer; `isHovered` mirrors the hover for a caller that paints part
    /// of the look itself.
    func liaHover(_ style: LiaHoverStyle = .fill, radius: CGFloat = 8, tint: Color? = nil,
                  isHovered: Binding<Bool>? = nil) -> some View {
        modifier(LiaHoverModifier(style: style, radius: radius, tint: tint, mirror: isHovered))
    }

    /// The pointing hand only, for a control that already lights itself.
    func liaPointer() -> some View { liaHover(.pointer) }
}

/// The hand is pushed once while any control is under the pointer and popped when none is, so nested controls (a
/// row and the dots on it) never unbalance the cursor stack or flicker between them.
/// 0.2.11 ("sometimes an arrow, sometimes a finger"): on macOS 15 and later the hand is SwiftUI's
/// own `.pointerStyle(.link)`, which the hosting view keeps through redraws and tracking-area updates (a pushed
/// NSCursor was reset to the arrow by the hosting view's cursor update whenever the view under it redrew - the dock
/// redraws on every pointer move - and came back only on the next move). macOS 14 keeps the balanced stack below.
@MainActor
enum LiaCursor {
    /// SwiftUI's pointer style draws the hand (macOS 15+); the stack below is not used then.
    static var native: Bool {
        if #available(macOS 15.0, *) { return true }
        return false
    }

    private static var active: Set<UUID> = []

    static func enter(_ id: UUID) {
        let was = active.isEmpty
        active.insert(id)
        if was { NSCursor.pointingHand.push() } else { NSCursor.pointingHand.set() }
    }

    /// A move inside: a text view under an overlay may have set its I-beam since; the hand takes it back.
    static func moved(_ id: UUID) {
        if active.contains(id) { NSCursor.pointingHand.set() } else { enter(id) }
    }

    static func leave(_ id: UUID) {
        guard active.remove(id) != nil else { return }
        if active.isEmpty { NSCursor.pop() }
    }
}

struct LiaHoverModifier: ViewModifier {
    let style: LiaHoverStyle
    let radius: CGFloat
    let tint: Color?
    let mirror: Binding<Bool>?
    @Environment(\.isEnabled) private var enabled
    @State private var hover = false
    @State private var id = UUID()

    func body(content: Content) -> some View {
        let on = hover && enabled && style != .off
        tinted(content.textSelection(.disabled), on: on)
            .opacity(style == .solid && on ? 0.88 : 1)
            .background {
                if style == .fill || style == .icon {
                    RoundedRectangle(cornerRadius: radius, style: .continuous)
                        .fill(on ? (style == .icon ? DropdownTrigger.hoverFill : AppConfig.surface2) : Color.clear)
                        .allowsHitTesting(false)
                }
            }
            .modifier(LiaPointerStyle(on: enabled && style != .off))
            .onContinuousHover(coordinateSpace: .local) { phase in
                switch phase {
                case .active:
                    if !hover { set(true) }
                    if !LiaCursor.native { if enabled && style != .off { LiaCursor.moved(id) } else { LiaCursor.leave(id) } }
                case .ended:
                    set(false)
                    if !LiaCursor.native { LiaCursor.leave(id) }
                }
            }
            .onChange(of: enabled) { _, e in if !e && !LiaCursor.native { LiaCursor.leave(id) } }
            .onChange(of: style) { _, st in if st == .off && !LiaCursor.native { LiaCursor.leave(id) } }
            .onDisappear {
                if !LiaCursor.native { LiaCursor.leave(id) }
                if hover { set(false) }
            }
    }

    @ViewBuilder
    private func tinted<V: View>(_ v: V, on: Bool) -> some View {
        if let tint { v.foregroundStyle(on ? AppConfig.ink : tint) } else { v }
    }

    private func set(_ h: Bool) {
        withAnimation(.easeOut(duration: 0.12)) {
            hover = h
            mirror?.wrappedValue = h && enabled && style != .off
        }
    }
}

/// The hand where the view takes clicks (its hit shape), from SwiftUI itself on macOS 15+; nothing on macOS 14 (the
/// stack in LiaCursor does it there).
private struct LiaPointerStyle: ViewModifier {
    let on: Bool

    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(macOS 15.0, *) {
            content.pointerStyle(on ? .link : nil)
        } else {
            content
        }
    }
}

// MARK: - one way to set a cursor ("between lines and words the cursor flickers endlessly")
//
// Every cursor in the app now comes from one of three places, and none of them sets the cursor on a mouse move:
//  1. text views (answers, the composer, the code viewer): AppKit's own cursor rects - the system I-beam, the hand
// on a chip from the text's `.cursor` attribute. Under something of ours drawn over them (a modal, a popup) they
// take their rects back (LiaTextCursorRects), they never set a cursor themselves.
//  2. clickable SwiftUI views: `.liaHover` / `.liaPointer` (SwiftUI's pointer style on macOS 15+, the balanced stack
// above on 14).
//  3. other shapes (resize handles, a chart's crosshair): `.liaCursor(_:)` below - SwiftUI's pointer style on 15+,
// one push on enter and one pop on exit (or when the view goes) on 14.
// Before, text views set the I-beam on every mouse move and the arrow on every exit, re-made their tracking area on
// every layout pass, and the hosting view's own cursor update set the arrow in between: the two fought on every move.

enum LiaCursorKind { case resizeLeftRight, crosshair }

extension View {
    /// The cursor over this view (its hit shape) while `active`.
    func liaCursor(_ kind: LiaCursorKind, active: Bool = true) -> some View {
        modifier(LiaCursorModifier(kind: kind, active: active))
    }
}

struct LiaCursorModifier: ViewModifier {
    let kind: LiaCursorKind
    let active: Bool
    @State private var inside = false
    @State private var pushed = false

    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(macOS 15.0, *) {
            content.pointerStyle(active ? style : nil)
        } else {
            content
                .onHover { h in inside = h; sync() }
                .onChange(of: active) { _, _ in sync() }
                .onDisappear { inside = false; sync() }
        }
    }

    @available(macOS 15.0, *)
    private var style: PointerStyle {
        switch kind {
        case .resizeLeftRight: return .columnResize
        case .crosshair: return .rectSelection
        }
    }

    private var cursor: NSCursor {
        switch kind {
        case .resizeLeftRight: return .resizeLeftRight
        case .crosshair: return .crosshair
        }
    }

    /// One push while inside and active, its one pop when either ends.
    private func sync() {
        let want = inside && active
        if want && !pushed { cursor.push(); pushed = true }
        else if !want && pushed { NSCursor.pop(); pushed = false }
    }
}

/// A text view's cursor rects only while nothing of ours is drawn over it. The view asks `covered(by:)` on its mouse
/// events; when the answer changes, its rects are rebuilt (AppKit then shows the overlay's cursor, or the I-beam again).
@MainActor
struct LiaTextCursorRects {
    private(set) var covered = false

    /// Called from mouseEntered / mouseMoved: true when the rects must be rebuilt.
    mutating func update(_ view: NSView, _ event: NSEvent) -> Bool {
        let now = !view.liaIsTopmost(event)
        guard now != covered else { return false }
        covered = now
        view.window?.invalidateCursorRects(for: view)
        return true
    }
}

extension NSView {
    /// The pointer of `event` is on this view, not on SwiftUI drawn over it in the same window (a modal, a popup, the
    /// media library). AppKit keeps a text view's I-beam under such an overlay; a text view asks this before it sets
    /// its cursor.
    func liaIsTopmost(_ event: NSEvent) -> Bool {
        guard let root = window?.contentView else { return false }
        let p: NSPoint = root.superview?.convert(event.locationInWindow, from: nil) ?? event.locationInWindow
        guard let hit = root.hitTest(p) else { return false }
        return hit === self || hit.isDescendant(of: self)
    }
}
