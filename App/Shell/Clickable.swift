import SwiftUI
import AppKit

// 0.2.11: "buttons are hard to press; the pointer is sometimes an arrow,
// sometimes a finger". Two causes everywhere in the app, fixed in one place:
//  1. `.buttonStyle(.plain)` on macOS takes clicks only on the label's drawn pixels: the glyphs of a word, the strokes
// of an icon. Padding, the gaps between letters and a background drawn with `allowsHitTesting(false)` did nothing,
// and the pointer turned from finger to arrow and back as it crossed them. `.liaPlain` is the same plain look
// with the whole label's frame clickable, the hand over all of it, and the press shown at once.
//  2. A view with a single and a double click (`onTapGesture(count: 2)` + `onTapGesture`) waited the double-click
// interval (300-500 ms) before every single click. `.liaClicks(single:double:)` fires the single click at once
// and the double one from AppKit's click count (LiaClicks.kind, Shared/Core/Clicks.swift).

/// `.buttonStyle(.plain)` with the label's whole frame clickable, the pointing hand over it (LiaHover), and the press
/// visible on mouse-down (no animation: the first frame after the press already shows it). Disabled, the label fades
/// as the plain style fades it.
struct LiaPlainButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        LiaPlainButtonFace(configuration: configuration)
    }
}

private struct LiaPlainButtonFace: View {
    let configuration: ButtonStyleConfiguration
    @Environment(\.isEnabled) private var enabled

    var body: some View {
        configuration.label
            .contentShape(Rectangle())
            .opacity(!enabled ? 0.45 : (configuration.isPressed ? 0.7 : 1))
            .liaPointer()
            .modifier(LatencyPressMark(isPressed: configuration.isPressed))   // the canary's click latency (LatencyProbe)
    }
}

extension ButtonStyle where Self == LiaPlainButtonStyle {
    /// The app's plain button: see LiaPlainButtonStyle.
    static var liaPlain: LiaPlainButtonStyle { LiaPlainButtonStyle() }
}

extension View {
    /// A custom clickable view (an `onTapGesture` one): the whole `shape` takes the click and shows the hand.
    func clickable<S: Shape>(_ shape: S) -> some View {
        contentShape(shape).liaPointer()
            // the canary's click latency (LatencyProbe): a tap here is one of ours; for everyone else the gesture is off
            .simultaneousGesture(TapGesture().onEnded { LatencyProbe.markTap() }, including: LatencyProbe.enabled ? .all : .subviews)
    }

    /// A custom clickable view, its whole frame.
    func clickable() -> some View { clickable(Rectangle()) }

    /// A single click that fires at once, and a double click: the second click of a double click fires `double` (the
    /// first one has already fired `single`). Use instead of `onTapGesture(count: 2)` next to `onTapGesture`.
    func liaClicks(single: @escaping () -> Void, double: @escaping () -> Void) -> some View {
        onTapGesture {
            LatencyProbe.markTap()
            switch LiaClicks.kind(clickCount: NSApp.currentEvent?.clickCount ?? 1) {
            case .single: single()
            case .double: double()
            }
        }
    }
}

// ("nothing in the messenger reacts to the pointer; like the tabs: darken a little or outline"): the
// hover for a control that paints its own face - a filled button, a chip, a tile, a card. A wash over the face, in the
// face's own shape (darker in light, lighter in dark), and the pointing hand. Nothing moves: no padding, size or
// border width changes, so a row of chips never jitters. Plain icons and text links take `.liaHover(.icon)` /
// `.liaHover(.text, tint:)` (Hover.swift) instead.

enum LiaWash {
    /// Over a light face (white, soft grey, blue): the darkening the tabs use.
    static let color = Color.dyn(dark: (0xFFFFFF, 0.08), light: (0x000000, 0.055))
    /// The outline a hovered card takes (its own 1 pt line, a step stronger).
    static let line = Color.dyn(dark: (0xFFFFFF, 0.22), light: (0x0E1014, 0.2))
    /// Over an ink face (dark in light, light in dark: Stop, a primary button): the face eases toward the ground.
    static let onInk = Color.dyn(dark: (0x000000, 0.14), light: (0xFFFFFF, 0.16))
}

extension View {
    /// The wash and the hand over this control's face (`shape`: the face's own outline).
    /// `ink`: the face is WS.ink (dark in light, light in dark).
    func liaHoverWash<S: Shape>(_ shape: S, enabled: Bool = true, ink: Bool = false) -> some View {
        modifier(LiaHoverWashModifier(shape: shape, outline: false, enabled: enabled, ink: ink))
    }

    /// A card or a tile: its outline goes a step stronger under the pointer (same width), with a faint wash, and the hand.
    func liaHoverOutline<S: Shape>(_ shape: S, enabled: Bool = true) -> some View {
        modifier(LiaHoverWashModifier(shape: shape, outline: true, enabled: enabled, ink: false))
    }
}

private struct LiaHoverWashModifier<S: Shape>: ViewModifier {
    let shape: S
    let outline: Bool
    let enabled: Bool
    let ink: Bool
    @State private var hover = false

    func body(content: Content) -> some View {
        content
            .overlay { face }
            .liaHover(enabled ? .pointer : .off, isHovered: $hover)
    }

    @ViewBuilder private var face: some View {
        let on = hover && enabled
        ZStack {
            shape.fill(on ? wash : Color.clear)
            if outline { shape.stroke(on ? LiaWash.line : Color.clear, lineWidth: 1) }
        }
        .allowsHitTesting(false)
    }

    private var wash: Color {
        if ink { return LiaWash.onInk }
        return outline ? LiaWash.color.opacity(0.5) : LiaWash.color
    }
}
