import SwiftUI

// The top bar's glass pieces in one container (neighbours merge on macOS 26), and a hover
// highlight for glass buttons.

/// On macOS 26 (built with its SDK) the content's glass shapes share one `GlassEffectContainer`, so pieces closer
/// than `spacing` blend into each other; elsewhere the content as it is.
struct WSGlassGroup<Content: View>: View {
    var spacing: CGFloat = 8
    @ViewBuilder var content: Content

    var body: some View {
        #if compiler(>=6.2)
        if #available(macOS 26.0, *) {
            GlassEffectContainer(spacing: spacing) { content }
        } else {
            content
        }
        #else
        content
        #endif
    }
}

extension View {
    /// Under the pointer a glass button lifts a little: a faint wash and the rim a touch stronger.
    func wsGlassHover(_ radius: CGFloat) -> some View {
        modifier(WSGlassHover(radius: radius))
    }
}

private struct WSGlassHover: ViewModifier {
    let radius: CGFloat
    @State private var hover = false
    @Environment(\.accessibilityReduceTransparency) private var opaque
    @Environment(\.colorScheme) private var scheme

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        return content
            .overlay { shape.fill(wash).allowsHitTesting(false) }
            .overlay { WSGlassRim(shape: shape, dark: scheme == .dark, strong: true).opacity(hover && !opaque ? 1 : 0).allowsHitTesting(false) }
            .onHover { h in withAnimation(WSMotion.micro) { hover = h } }
    }

    /// A quiet wash, never a white glow (was white 0.16 light / 0.08 dark, with a white 0.8 rim).
    private static let glassWash = Color.dyn(dark: (0xFFFFFF, 0.05), light: (0x11141A, 0.04))

    /// Opaque surfaces (Reduce Transparency) get a grey wash: white on white would not show.
    private var wash: Color {
        guard hover else { return Color.clear }
        return opaque ? WS.ink.opacity(0.05) : Self.glassWash
    }
}

/// The glass's edge, shared by every glass we draw ourselves (the chrome's, Home's and the workspace's before
/// macOS 26). ("lit at the top and bottom, like a reflection; it must be natural"): no white
/// border and no bright band. Two hairlines (0.5 pt):
/// The light: a white catch at the top-leading corner fading out by the middle, added onto the glass's own colour
/// (`plusLighter`), so it takes the hue of what is behind and vanishes over white instead of glowing;
/// The shade: a faint ink edge, a little firmer at the bottom, so glass still has an outline on a white page
/// (white on white would not show).
/// Home and the dock use it on macOS 26 too (hotfix: no Liquid Glass there, its lens lit the edges).
struct WSGlassRim<S: InsettableShape>: View {
    let shape: S
    /// Dark glass (the material in Dark, or over a dark tint).
    let dark: Bool
    /// The selected piece (a tab, a segment): a little more definition.
    var strong = false

    var body: some View {
        let lit: Double = dark ? (strong ? 0.24 : 0.16) : (strong ? 0.55 : 0.40)
        let ink = dark ? Color.white : Color(hex: 0x11141A)
        // Hotfix: the selected piece's shade in light a touch firmer (0.04 / 0.10 -> 0.06 / 0.13), so a
        // selected tab keeps an outline on a white page.
        let shadeTop: Double = dark ? (strong ? 0.10 : 0.06) : (strong ? 0.06 : 0.025)
        let shadeBottom: Double = dark ? (strong ? 0.06 : 0.035) : (strong ? 0.13 : 0.06)
        ZStack {
            shape.strokeBorder(LinearGradient(colors: [ink.opacity(shadeTop), ink.opacity(shadeBottom)],
                                              startPoint: .top, endPoint: .bottom), lineWidth: 0.5)
            shape.strokeBorder(LinearGradient(stops: [.init(color: Color.white.opacity(lit), location: 0),
                                                      .init(color: Color.white.opacity(0), location: 0.5)],
                                              startPoint: .topLeading, endPoint: .bottomTrailing), lineWidth: 0.5)
                .blendMode(.plusLighter)
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}
