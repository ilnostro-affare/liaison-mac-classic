import SwiftUI
import AppKit
import WebKit

// the toolbar reflects the page, strongly, as one system with the window. On Home it is
// Home's sky top; on a web tab it is the colour at the top of the visible page (a few rows of the web view's own
// pixels, re-sampled while the page scrolls), so the bar follows the sections and gradients the page shows under it.
// The window's background around the page card is the same colour, fading softly downwards: the card sits in one
// continuous surface with no line or step at its edges. Pure parts: PageTint (Shared/Core/TabStrip.swift).

/// What the toolbar and the window reflect now.
@MainActor
final class ToolbarTint: ObservableObject {
    static let shared = ToolbarTint()

    struct State: Equatable {
        /// Home (or no page): the sky. Otherwise `field`.
        var home = true
        /// The page's top band as a grid of colours (gradients, not one averaged colour).
        var field = TintField.solid(0xF3F4F6)
        /// The band's average (one colour, for what still needs one).
        var top: UInt32 { field.average }
    }

    @Published private(set) var state = State()
    /// Bumped on every change of `state`: the grounds cross-fade on it (a gradient's stops do not animate).
    @Published private(set) var version = 0
    /// The window's content size and the page card's frame (the root space, top-left origin), for the ground's
    /// gradients, the per-region glyph contrast and the card's feathered edge.
    @Published private(set) var windowSize: CGSize = .zero
    @Published private(set) var cardFrame: CGRect = .zero

    private weak var tab: BrowserTab?
    private var monitors: [Any] = []
    private var lastSample: TimeInterval = 0
    private var sampling = false
    /// A sample was asked for while one was in flight: one more right after it (never dropped).
    private var again = false
    private var trailing: Task<Void, Never>?
    private var settling: Task<Void, Never>?
    /// Each tab's last field, applied the instant it comes to front (then refined).
    private var cache: [UUID: TintField] = [:]

    private init() {}

    func setWindowSize(_ s: CGSize) {
        if abs(s.width - windowSize.width) > 0.5 || abs(s.height - windowSize.height) > 0.5 { windowSize = s }
    }

    func setCardFrame(_ r: CGRect) {
        let d = abs(r.minX - cardFrame.minX) + abs(r.minY - cardFrame.minY) + abs(r.width - cardFrame.width) + abs(r.height - cardFrame.height)
        if d > 0.5 { cardFrame = r }
    }

    /// The tab in front changed (or loaded, navigated, woke): reflect it at once, then look again.
    func follow(_ tab: BrowserTab?) async {
        let switched = tab?.id != self.tab?.id
        self.tab = tab
        installMonitors()
        guard let tab, !tab.isStart else {
            settling?.cancel()
            set(State(home: true, field: state.field))
            return
        }
        // A tab switch: its last known colours instantly; a first visit: its theme-color, else what the bar shows
        // now (no flash to grey).
        if let f = cache[tab.id] {
            if switched || state.home { set(State(home: false, field: f)) }
        } else if state.home || switched {
            set(State(home: false, field: tab.themeColor.map { TintField.solid($0) } ?? state.field))
        }
        await sample()
        settle()
    }

    /// The navigation committed (BrowserTab.didCommit): the new page has painted ~150 ms later.
    func committed(_ tab: BrowserTab) {
        guard tab.id == self.tab?.id else { return }
        settle()
    }

    /// Looks at `early` and at `settle` from now (the page's first paint, then late headers and images).
    private func settle() {
        settling?.cancel()
        settling = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(TintTiming.early * 1_000_000_000))
            if Task.isCancelled { return }
            await self?.sample()
            try? await Task.sleep(nanoseconds: UInt64((TintTiming.settle - TintTiming.early) * 1_000_000_000))
            if Task.isCancelled { return }
            await self?.sample()
        }
    }

    private func set(_ s: State) {
        guard s.home != state.home || s.field.differs(from: state.field) else { return }
        state = s
        version &+= 1
    }

    /// The top band of the visible page as a grid (TintField.columns x rows).
    private func sample() async {
        guard let tab, !tab.isStart else { return }
        if sampling { again = true; return }
        if tab.crashed || tab.loadError != nil { set(State(home: false, field: .solid(0xFFFFFF))); return }
        guard !tab.asleep, let wv = tab.loadedWebView, let win = wv.window, wv.bounds.width > 40, wv.bounds.height > 30 else {
            if let c = tab.themeColor { set(State(home: false, field: .solid(c))) }
            return
        }
        sampling = true
        lastSample = ProcessInfo.processInfo.systemUptime
        let band: CGFloat = 24
        let cfg = WKSnapshotConfiguration()
        cfg.rect = CGRect(x: 0, y: wv.isFlipped ? 0 : wv.bounds.height - band, width: wv.bounds.width, height: band)
        // About 4 pixel rows: enough for two rows of cells, still tiny.
        cfg.snapshotWidth = NSNumber(value: Double(max(70, min(320, (4 * wv.bounds.width / band).rounded(.up)))))
        cfg.afterScreenUpdates = false
        // Where the page sits across the window (the field's gradient lines up with it).
        let inWindow = wv.convert(wv.bounds, to: nil)
        let W = max(1, win.contentView?.bounds.width ?? win.frame.width)
        let x0 = Double(inWindow.minX / W), x1 = Double(inWindow.maxX / W)
        let id = tab.id
        let shot: NSImage? = await withCheckedContinuation { k in wv.takeSnapshot(with: cfg) { img, _ in k.resume(returning: img) } }
        sampling = false
        if let img = shot, self.tab?.id == id, var f = Self.field(img) {
            f.x0 = min(max(min(x0, x1), 0), 1)
            f.x1 = min(max(max(x0, x1), 0), 1)
            cache[id] = f
            if cache.count > 120 { cache = [id: f] }
            set(State(home: false, field: f))
        }
        if again {
            again = false
            await sample()
        }
    }

    private static func field(_ img: NSImage) -> TintField? {
        guard let cg = img.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        let w = max(1, min(cg.width, 320)), h = max(1, min(cg.height, 8))
        var px = [UInt8](repeating: 0, count: w * h * 4)
        let ok: Bool = px.withUnsafeMutableBytes { buf -> Bool in
            guard let ctx = CGContext(data: buf.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        return ok ? PageTint.field(rgba: px, width: w, height: h) : nil
    }

    // MARK: scrolling

    /// Scroll-wheel (with its momentum) and keys (Space, arrows, Page Down) over the page: a sample at most every
    /// `scrollThrottle` while it moves, and one when it stops.
    private func installMonitors() {
        guard monitors.isEmpty else { return }
        if let m = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel, handler: { e in
            MainActor.assumeIsolated { ToolbarTint.shared.moved(e.window) }
            return e
        }) { monitors.append(m) }
        if let m = NSEvent.addLocalMonitorForEvents(matching: .keyDown, handler: { e in
            MainActor.assumeIsolated { ToolbarTint.shared.moved(e.window, key: true) }
            return e
        }) { monitors.append(m) }
    }

    private func moved(_ window: NSWindow?, key: Bool = false) {
        guard let tab, !tab.isStart, let wv = tab.loadedWebView, let win = wv.window, window === win else { return }
        if key {
            // Keys scroll only the page that has them.
            guard let r = win.firstResponder as? NSView, r === wv || r.isDescendant(of: wv) else { return }
        }
        if TintTiming.sampleWhileScrolling(now: ProcessInfo.processInfo.systemUptime, last: lastSample) {
            Task { @MainActor in await ToolbarTint.shared.sample() }
        }
        trailing?.cancel()
        let wait = key ? TintTiming.keyScrollEnd : TintTiming.scrollEnd
        trailing = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000))
            if Task.isCancelled { return }
            await self?.sample()
        }
    }
}

// MARK: - glyphs over the tint

private struct BarOnDarkKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    /// The toolbar's colour is dark: its glyphs and text turn light.
    var wsBarOnDark: Bool {
        get { self[BarOnDarkKey.self] }
        set { self[BarOnDarkKey.self] = newValue }
    }
}

/// The toolbar's text and glyph colours over the reflected tint. They follow the tint, not the app's theme (a white
/// page under the bar in Dark keeps dark glyphs), so the light branch is fixed, never a light/dark token.
enum BarInk {
    static func ink(_ dark: Bool) -> Color { dark ? Color.white : Color(hex: 0x0E1014) }
    static func text2(_ dark: Bool) -> Color { dark ? Color.white.opacity(0.8) : Color(hex: 0x4A505A) }
    static func text3(_ dark: Bool) -> Color { dark ? Color.white.opacity(0.62) : Color(hex: 0x8A8F98) }
    /// The faint containers (the pinned cell, a group).
    static func fill(_ dark: Bool) -> Color { dark ? Color.white.opacity(0.12) : Color(hex: 0x11141A, alpha: 0.045) }
    static func hairline(_ dark: Bool) -> Color { dark ? Color.white.opacity(0.18) : Color(hex: 0x11141A, alpha: 0.10) }
    /// Under the pointer (an unselected tab): a quiet step, never a white slab (was white 0.16 / 0.5).
    static func hover(_ dark: Bool) -> Color { dark ? Color.white.opacity(0.09) : Color(hex: 0x11141A, alpha: 0.055) }
}

/// Sets `wsBarOnDark` for the bar from the tint (Home: the sky's own text colour). The default for the whole bar;
/// `barInkRegion` refines it where a piece sits.
struct BarInkScope<Content: View>: View {
    @ObservedObject private var tint = ToolbarTint.shared
    @ObservedObject private var sky = SkyModel.shared
    @Environment(\.colorScheme) private var scheme
    let content: Content

    init(@ViewBuilder content: () -> Content) { self.content = content() }

    var body: some View {
        content.environment(\.wsBarOnDark, tint.state.home ? sky.look.homeDark(scheme) : PageTint.onDark(tint.state.top))
    }
}

/// Glyph contrast per region. The piece's own place across the window picks light or dark glyphs from the
/// gradient right behind it (a dark left half and a light right half each stay readable).
private struct BarInkRegion: ViewModifier {
    @ObservedObject private var tint = ToolbarTint.shared
    @ObservedObject private var sky = SkyModel.shared
    @Environment(\.colorScheme) private var scheme
    @State private var midX: CGFloat = -1

    func body(content: Content) -> some View {
        content
            .environment(\.wsBarOnDark, onDark)
            .background(GeometryReader { g in
                let x = g.frame(in: .named(WSSpace.root)).midX
                Color.clear
                    .onAppear { midX = x }
                    .onChange(of: x) { _, v in if abs(v - midX) > 2 { midX = v } }
            })
    }

    private var onDark: Bool {
        if tint.state.home { return sky.look.homeDark(scheme) }
        let w = tint.windowSize.width
        guard midX >= 0, w > 1 else { return PageTint.onDark(tint.state.top) }
        return tint.state.field.onDark(atX: Double(midX / w))
    }
}

extension View {
    /// The bar's glyphs here: light over a dark part of the gradient behind, dark over a light one.
    func barInkRegion() -> some View { modifier(BarInkRegion()) }

    /// The chrome's glass (a translucent material, a natural rim: WSGlassRim), over the bar's
    /// reflected colours. `strong`: the selected tab; otherwise containers and buttons.
    func chromeGlass<S: InsettableShape>(_ shape: S, strong: Bool = false, solid: Bool = false) -> some View {
        background { ChromeGlass(shape: shape, strong: strong, solid: solid) }
    }
}

/// The glass itself. It reads `wsBarOnDark` where it is drawn: a dark material and a whiter edge over dark colours.
struct ChromeGlass<S: InsettableShape>: View {
    let shape: S
    var strong = false
    /// The address being typed: nearly opaque, so the field reads over any colour.
    var solid = false
    @Environment(\.wsBarOnDark) private var onDark
    @Environment(\.accessibilityReduceTransparency) private var opaque
    /// The app's theme: the field being typed in is the theme's surface (its text is the theme's ink).
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        if opaque && solid {
            shape.fill(WS.surface)
                .overlay(shape.strokeBorder(WS.line2, lineWidth: 1))
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        } else if opaque {
            // Reduce Transparency: a plain surface with a line (white on white would not show otherwise).
            shape.fill(onDark && !solid ? Color.white.opacity(0.22) : Color.white)
                .overlay(shape.strokeBorder(onDark && !solid ? Color.white.opacity(0.4) : Color(hex: 0x0E1014, alpha: 0.12), lineWidth: 1))
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        } else {
            glass
        }
    }

    /// ("lit at the top and bottom like a reflection; the tab can be invisible on a bright
    /// background"): no white band and no white border. The material, a light white tint (none of it a slab), the
    /// shared natural rim (WSGlassRim: a light catch at the top-leading corner, a faint shade edge), and for the
    /// selected piece a soft lift (a short shadow plus a contact shadow), so it reads on white and on dark alike.
    /// Before: tint 0.30 / 0.52 (light), 0.10 / 0.20 (dark); a white top fill 0.28 / 0.10 down to the middle; a 0.75 pt
    /// white edge 0.75 -> 0.18 (strong 0.95 -> 0.30) in light, 0.26 -> 0.08 (0.42) in dark; shadow 0.10 / 0.22, r 2.
    private var glass: some View {
        let tintAlpha: Double = solid ? 0.92 : (onDark ? (strong ? 0.13 : 0.05) : (strong ? 0.50 : 0.16))
        // Hotfix (the open tab could still vanish on a white page): light lift 0.10 r 3 y 1 -> 0.14 r 4 y 1.5,
        // contact 0.06 -> 0.10. Our own drawing on every macOS (Liquid Glass is never used for the strip).
        let lift: Double = strong ? (onDark ? 0.30 : 0.14) : 0
        let contact: Double = strong ? (onDark ? 0.20 : 0.10) : 0
        return ZStack {
            shape.fill(strong ? Material.regularMaterial : Material.ultraThinMaterial)
                .environment(\.colorScheme, solid ? scheme : (onDark ? .dark : .light))
            shape.fill(solid ? WS.surface.opacity(tintAlpha) : Color.white.opacity(tintAlpha))
            WSGlassRim(shape: shape, dark: solid ? scheme == .dark : onDark, strong: strong)
        }
        .shadow(color: Color.black.opacity(contact), radius: strong ? 0.5 : 0, y: strong ? 0.5 : 0)
        .shadow(color: Color.black.opacity(lift), radius: strong ? (onDark ? 3 : 4) : 0, y: strong ? (onDark ? 1 : 1.5) : 0)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

// MARK: - the surfaces

/// Behind the browser toolbar and tabs. The window's ground (WindowTintBackground) paints the bar's
/// gradients itself, so the bar and the ground are one surface by construction; this adds only the glass's light at
/// the very top edge. In compact mode the bar floats with its own material (WindowCompact.swift).
struct ToolbarGlassBackground: View {
    @ObservedObject private var tint = ToolbarTint.shared
    @ObservedObject private var sky = SkyModel.shared
    /// The compact bar floats over the page; it paints the ground's top itself (same pixels).
    @AppStorage(Prefs.compactMode) private var compact = false
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let dark = tint.state.home ? sky.look.homeDark(scheme) : PageTint.onDark(tint.state.top)
        ZStack(alignment: .topLeading) {
            if compact && tint.windowSize.width > 1 {
                TintGround(state: tint.state, look: sky.look, size: tint.windowSize, card: tint.cardFrame, compact: true)
                    .id(tint.version)
                    .transition(.opacity)
            }
            // A breath of light at the very top, not a band (was 0.14 / 0.06 down to the middle).
            LinearGradient(stops: [.init(color: Color.white.opacity(dark ? 0.03 : 0.06), location: 0),
                                   .init(color: Color.white.opacity(0), location: 0.35)],
                           startPoint: .top, endPoint: .bottom)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .clipped()
        .animation(.easeInOut(duration: TintTiming.transition), value: tint.version)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// The window's ground: the page's top band continued as horizontal gradients under the bar and around the page
/// card, fading softly downwards. On Home it is the sky laid out as Home's own backdrop is (HomeSky), with its glow
/// in the same place, so the glow carries on above the card into the bar.
struct WindowTintBackground: View {
    @ObservedObject private var tint = ToolbarTint.shared
    @ObservedObject private var sky = SkyModel.shared
    /// Compact mode: no bar, the card starts under the 6 pt hover strip.
    @AppStorage(Prefs.compactMode) private var compact = false

    var body: some View {
        GeometryReader { g in
            ZStack(alignment: .topLeading) {
                TintGround(state: tint.state, look: sky.look, size: g.size, card: tint.cardFrame, compact: compact)
                    .id(tint.version)
                    .transition(.opacity)
            }
            .frame(width: g.size.width, height: g.size.height, alignment: .topLeading)
            .animation(.easeInOut(duration: TintTiming.transition), value: tint.version)
            .onAppear { tint.setWindowSize(g.size) }
            .onChange(of: g.size) { _, s in tint.setWindowSize(s) }
        }
        .animation(.easeInOut(duration: 2.5), value: sky.look)
        .ignoresSafeArea()
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// The ground for one state, at the window's size. The card's feathered edge draws the same view, offset, so the
/// colours on both sides of the card's edge are the same pixels.
struct TintGround: View {
    let state: ToolbarTint.State
    let look: SkyLook
    let size: CGSize
    /// The page card in the window (zero before it has reported: the usual inset is assumed).
    let card: CGRect
    var compact = false
    /// The app's theme (Dark veils the sky and darkens the ground, as HomeSky does).
    @Environment(\.colorScheme) private var scheme

    private var cardTop: CGFloat { compact ? 6 : AppConfig.barHeight + 2 }
    private var cardRect: CGRect {
        if card.width > 1, card.height > 1 { return card }
        return CGRect(x: 10, y: cardTop, width: max(1, size.width - 20), height: max(1, size.height - cardTop - 10))
    }

    var body: some View {
        Group {
            if state.home { home } else { web }
        }
        .frame(width: size.width, height: size.height, alignment: .topLeading)
    }

    private static func gradient(_ stops: [TintStop]) -> LinearGradient {
        LinearGradient(stops: stops.map { Gradient.Stop(color: Color(hex: $0.color), location: CGFloat($0.location)) },
                       startPoint: .leading, endPoint: .trailing)
    }

    /// The bar: the page's top row underneath, its upward continuation at the window's top; then the top row held
    /// under the card's top, then fading to the band's lower row, softened.
    private var web: some View {
        let H = max(size.height, 1)
        let top = max(1, cardRect.minY)
        let hold = min(0.98, (top + 40) / H)
        let end = min(1, max(hold + 0.01, (top + 300) / H))
        let f = state.field
        return ZStack(alignment: .top) {
            Self.gradient(f.fadeStops)
            Self.gradient(f.barStops)
                .mask(LinearGradient(stops: [.init(color: .black, location: 0), .init(color: .black, location: hold),
                                             .init(color: .black.opacity(0), location: end)],
                                     startPoint: .top, endPoint: .bottom))
            Self.gradient(f.barTopStops())
                .frame(height: top)
                .mask(LinearGradient(colors: [.black, .black.opacity(0)], startPoint: .top, endPoint: .bottom))
        }
    }

    /// HomeSky's gradient at the same heights as inside the card and its glow at the same place, over the window's
    /// neutral in Home's tone; the band above the card is the sky's top, the glow running through it.
    /// The same long cosine fade and the same Dark veil as HomeSky, so both sides of the card match.
    private var home: some View {
        let c = cardRect
        let h = CGFloat(Sky.skyHeight(cardHeight: Double(c.height)))
        let fadeH = CGFloat(Sky.fadeHeight(cardHeight: Double(c.height)))
        let H = max(size.height, 1)
        let veil = look.veil(scheme)
        return ZStack(alignment: .topLeading) {
            HomeTone.window(dark: look.homeDark(scheme))
            ZStack(alignment: .topLeading) {
                VStack(spacing: 0) {
                    Rectangle().fill(look.top.color).frame(height: c.minY)
                    LinearGradient(gradient: look.gradient(scaledTo: Double(h / max(fadeH, 1))), startPoint: .top, endPoint: .bottom)
                        .frame(height: fadeH)
                    Spacer(minLength: 0)
                }
                if let gc = look.glow, let g = Sky.glow(look, card: c) {
                    RadialGradient(stops: Sky.glowStops(peak: Sky.glowShape(look).alpha).map { .init(color: gc.color.opacity($0.alpha), location: $0.location) },
                                   center: UnitPoint(x: g.center.x / max(size.width, 1), y: g.center.y / H),
                                   startRadius: 0, endRadius: CGFloat(g.radius))
                }
                if veil > 0 { HomeTone.veil.opacity(veil) }
            }
            .frame(width: size.width, height: size.height, alignment: .topLeading)
            .mask { HomeTone.fadeMask(from: c.minY, height: fadeH, total: H) }
        }
    }
}

/// (feedback: "a white rim around the card's corners and edges") the card's edge melts into the window. A
/// ring of the window's own ground, from just outside the card's edge to a few points inside it, feathered, over
/// the page; no white base shows at the rounded corners' anti-aliased pixels. Also reports the card's frame.
struct CardEdgeFeather: View {
    @ObservedObject private var tint = ToolbarTint.shared
    @ObservedObject private var sky = SkyModel.shared
    @AppStorage(Prefs.compactMode) private var compact = false
    var radius: CGFloat = WS.radius
    /// The main stage's card reports its frame (the ground lines its gradients and the Home glow up with it).
    var report = true

    var body: some View {
        GeometryReader { g in
            let f = g.frame(in: .named(WSSpace.root))
            let size = tint.windowSize
            ZStack(alignment: .topLeading) {
                if size.width > 1 {
                    TintGround(state: tint.state, look: sky.look, size: size, card: tint.cardFrame, compact: compact)
                        .id(tint.version)
                        .transition(.opacity)
                        .offset(x: -f.minX, y: -f.minY)
                }
            }
            .frame(width: g.size.width, height: g.size.height, alignment: .topLeading)
            .animation(.easeInOut(duration: TintTiming.transition), value: tint.version)
            .mask {
                RoundedRectangle(cornerRadius: radius + 1, style: .continuous)
                    .inset(by: -1)
                    .strokeBorder(Color.black, lineWidth: 3.5)
                    .blur(radius: 1.4)
            }
            .onAppear { if report { tint.setCardFrame(f) } }
            .onChange(of: f) { _, v in if report { tint.setCardFrame(v) } }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// Under the page inside the card: the page's own top colour instead of white, so nothing white shows where the
/// page has not painted or at the clipped corners. Home keeps the card's white.
struct CardBase: View {
    @ObservedObject private var tint = ToolbarTint.shared
    @ObservedObject private var sky = SkyModel.shared
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        Group {
            if tint.state.home { HomeTone.card(dark: sky.look.homeDark(scheme)) } else { Color(hex: tint.state.top) }
        }
        .animation(.easeInOut(duration: TintTiming.transition), value: tint.state.top)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// Keeps ToolbarTint on the tab in front: its page, its loads and navigations (scrolling is ToolbarTint's own).
struct ToolbarTintDriver: View {
    @ObservedObject var ws: WorkspaceModel

    var body: some View {
        Group {
            if let b = ws.currentBrowser { ForBrowser(browser: b) } else { Home() }
        }
        .frame(width: 0, height: 0)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private struct Home: View {
        var body: some View {
            Color.clear.task { await ToolbarTint.shared.follow(nil) }
        }
    }

    private struct ForBrowser: View {
        @ObservedObject var browser: BrowserModel
        var body: some View {
            if let t = browser.selected { ForTab(tab: t) } else { Home() }
        }
    }

    private struct ForTab: View {
        @ObservedObject var tab: BrowserTab
        private var key: String {
            let parts: [String] = [tab.id.uuidString, tab.isStart ? "s" : "p", tab.isLoading ? "l" : "d", tab.url?.absoluteString ?? "",
             tab.themeColor.map { String($0) } ?? "", tab.asleep ? "z" : "", tab.crashed ? "c" : "",
             tab.loadError == nil ? "" : "e"]
            return parts.joined(separator: "|")
        }
        var body: some View {
            Color.clear.task(id: key) { await ToolbarTint.shared.follow(tab) }
        }
    }
}
