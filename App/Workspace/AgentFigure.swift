import SwiftUI
import AppKit

/// The workspace's own look.: a real dark theme. Every token is a light/dark pair that
/// follows the view's appearance (the app's Theme: System / Light / Dark, or a subtree's own colorScheme, e.g. Home
/// under a night sky). Light values are the original white design.
enum WS {
    static let ground = Color.dyn(0x111317, 0xECEEF1)
    static let groupBg = Color.dyn(0x15181C, 0xDFE2E7)
    static let surface = Color.dyn(0x1A1D22, 0xFFFFFF)
    /// A raised surface over `surface` (menus, popovers, a card on a card): one step lighter in dark.
    static let raised = Color.dyn(0x22262C, 0xFFFFFF)
    static let ink = Color.dyn(0xF2F3F5, 0x0E1014)
    /// Text and glyphs on an `ink` fill (the primary dark button in light theme, its light twin in dark).
    static let onInk = Color.dyn(0x111317, 0xFFFFFF)
    static let text2 = Color.dyn(0xB4BAC3, 0x4A505A)
    static let text3 = Color.dyn(0x7D838C, 0x8A8F98)
    static let line = Color.dyn(dark: (0xFFFFFF, 0.08), light: (0x0E1014, 0.08))
    static let line2 = Color.dyn(dark: (0xFFFFFF, 0.12), light: (0x0E1014, 0.12))
    static let soft = Color.dyn(0x23262C, 0xF3F4F6)
    /// A hover wash over a row (a faint darkening in light, a faint lightening in dark).
    static let hover = Color.dyn(dark: (0xFFFFFF, 0.06), light: (0x000000, 0.035))
    /// A translucent light chip over the window's ground (an unselected tab), and its hover.
    static let wash = Color.dyn(dark: (0xFFFFFF, 0.06), light: (0xFFFFFF, 0.35))
    static let washHover = Color.dyn(dark: (0xFFFFFF, 0.10), light: (0xFFFFFF, 0.55))
    /// An inset field on glass (a text editor, a log box): a light wash in light, a faint one in dark.
    static let field = Color.dyn(dark: (0xFFFFFF, 0.06), light: (0xFFFFFF, 0.7))
    /// A pill over a web page: nearly opaque surface (white / dark).
    static let pill = Color.dyn(dark: (0x1A1D22, 0.9), light: (0xFFFFFF, 0.9))
    /// The light band that sweeps over a loading skeleton.
    static let shimmer = Color.dyn(dark: (0xFFFFFF, 0.07), light: (0xFFFFFF, 0.7))
    /// The ring around an agent's avatar where it overlaps a neighbour (the surface it sits on).
    static let avatarRing = Color.dyn(0x1A1D22, 0xFBFAF9)
    static let amber = Color.dyn(0xF5A524, 0xF59E0B)
    static let amberInk = Color.dyn(0xF2B45A, 0x8A4B05)
    static let amberSoft = Color.dyn(dark: (0xF59E0B, 0.16), light: (0xFFF1DC, 1))
    /// The edge of an amber (waiting) card.
    static let amberLine = Color.dyn(dark: (0xF5A524, 0.45), light: (0xF3C98B, 1))
    static let blue = Color.dyn(0x5B78FF, 0x3B5BFD)
    static let green = Color.dyn(0x3DBE8B, 0x11865A)
    static let bad = Color.dyn(0xF08A4B, 0xB4500B)
    /// The unread dot / destructive red.
    static let red = Color.dyn(0xFF6369, 0xE5484D)
    static let radius: CGFloat = 22
}

/// What an agent is doing. The eyes show it; working also animates the whole figure.
enum AgentStatus: Equatable { case idle, working, waiting }

/// Each agent is one soft blot, like a fried egg: the same width and height for all, each
/// spilled its own way (a round centre plus four bulges, merged). No limbs, no mouth: the eyes carry the character
/// and the mood. The numbers are the ones of the sheet he picked (option 1), so the app draws exactly those.
enum AgentBlot {
    /// A bulge around the centre circle (radius 1): angle (radians, y down), its radius, its distance.
    struct Bulge { let a: Double; let r: Double; let d: Double }
    /// The merged outline's bounds in the same units, to stretch every agent to one box.
    struct Shape { let bulges: [Bulge]; let box: (x0: Double, y0: Double, x1: Double, y1: Double) }

    static func shape(_ id: String) -> Shape {
        func s(_ b: [(Double, Double, Double)], _ x0: Double, _ y0: Double, _ x1: Double, _ y1: Double) -> Shape {
            Shape(bulges: b.map { Bulge(a: $0.0, r: $0.1, d: $0.2) }, box: (x0, y0, x1, y1))
        }
        switch id {
        case "met":   return s([(3.5541, 0.6105, 0.6369), (5.0884, 0.549, 0.7484), (6.0688, 0.3865, 0.6653), (8.2122, 0.4406, 0.7005)], -1.1875, -1.2375, 1.025, 1.0825)
        case "giggs": return s([(2.7937, 0.4132, 0.81), (4.0343, 0.5007, 0.8195), (5.672, 0.513, 0.735), (7.2069, 0.471, 0.761)], -1.1575, -1.1275, 1.1025, 1.0675)
        case "rep":   return s([(3.122, 0.5399, 0.5928), (4.1109, 0.4699, 0.6322), (6.4012, 0.5457, 0.7304), (7.7451, 0.5387, 0.5936)], -1.125, -1.0025, 1.2625, 1.12)
        case "seara": return s([(4.2538, 0.6097, 0.6089), (5.2522, 0.5778, 0.6499), (7.0993, 0.5756, 0.605), (9.1537, 0.4979, 0.5714)], -1.04, -1.15, 1.0025, 1.015)
        case "crea":  return s([(4.2268, 0.4896, 0.7634), (5.8397, 0.5049, 0.7702), (7.2225, 0.586, 0.561), (8.2904, 0.6193, 0.774)], -1.0, -1.1525, 1.19, 1.315)
        case "dev":   return s([(-0.2717, 0.4743, 0.7552), (1.3227, 0.407, 0.6195), (3.4505, 0.4154, 0.7722), (4.9354, 0.4128, 0.7107)], -1.135, -1.09, 1.1875, 1.01)   // Lee's blot (Lee retired)
        default:      return s([(1.1252, 0.4751, 0.5965), (2.663, 0.4764, 0.8254), (4.8944, 0.5636, 0.6166), (6.2278, 0.4464, 0.6018)], -1.195, -1.1625, 1.035, 1.015)
        }
    }

    /// The eyes: oval by default, each agent its own cut (emotions in the eyes only; Rep's half-lidded, like glasses).
    struct Eyes {
        enum Cut { case oval, rounded, capsule }
        let rx: Double, ry: Double, gap: Double, cut: Cut, lid: Double, tilt: Double, rightScale: Double
    }

    static func eyes(_ id: String) -> Eyes {
        switch id {
        case "met":   return Eyes(rx: 0.050, ry: 0.062, gap: 0.101, cut: .rounded, lid: 0, tilt: 0, rightScale: 1)     // steady
        case "giggs": return Eyes(rx: 0.059, ry: 0.078, gap: 0.106, cut: .oval, lid: 0, tilt: 0, rightScale: 1)        // open
        case "rep":   return Eyes(rx: 0.064, ry: 0.064, gap: 0.106, cut: .oval, lid: 0.48, tilt: 0, rightScale: 1)     // reading
        case "seara": return Eyes(rx: 0.048, ry: 0.076, gap: 0.098, cut: .oval, lid: 0, tilt: 0, rightScale: 1.18)     // curious
        case "crea":  return Eyes(rx: 0.045, ry: 0.070, gap: 0.099, cut: .oval, lid: 0, tilt: 14, rightScale: 1)       // playful
        case "dev":   return Eyes(rx: 0.028, ry: 0.084, gap: 0.086, cut: .capsule, lid: 0, tilt: 0, rightScale: 1)     // quick (Lee's)
        default:      return Eyes(rx: 0.045, ry: 0.073, gap: 0.098, cut: .oval, lid: 0, tilt: 0, rightScale: 1)        // Lia
        }
    }

    /// A mood the eyes take: a look (offset, scale), a lid, or one of the shaped moods.
    struct Mood {
        var dx = 0.0, dy = 0.0, scale = 1.0, lid = 0.0, open = 1.0
        var happy = false, worried = false, closed = false
        static let idle = Mood()
        static let listening = Mood(dy: -0.02, scale: 1.08)
        static let thinking = Mood(dx: 0.025, dy: -0.03, scale: 0.9)
        static let working = Mood(dy: 0.012, lid: 0.45)
        static let waiting = Mood(worried: true)
        static let offline = Mood(closed: true)

        static func mix(_ a: Mood, _ b: Mood, _ t: Double) -> Mood {
            func l(_ x: Double, _ y: Double) -> Double { x + (y - x) * t }
            return Mood(dx: l(a.dx, b.dx), dy: l(a.dy, b.dy), scale: l(a.scale, b.scale), lid: l(a.lid, b.lid), open: l(a.open, b.open))
        }
    }

    /// One working cycle (seconds). The figure flows and the eyes wander, and at the end of every cycle both are back
    /// exactly where they started; when the work stops, the figure finishes the cycle it is in and rests. Two move
    /// slots (`HeroMoves`), so the moves are at rest then too.
    static let cycle = HeroMoves.slot * 2

    /// The eyes over one cycle (u in 0..<1): look, think, read, listen, back; with two blinks.
    static func workingMood(_ u: Double, deepLid: Bool) -> Mood {
        let read = deepLid ? Mood(dy: 0.012, lid: 0.72) : Mood.working
        let keys: [(Double, Mood)] = [(0, .idle), (0.14, .idle), (0.24, .thinking), (0.40, .thinking), (0.50, read), (0.70, read), (0.80, .listening), (0.90, .idle), (1, .idle)]
        var m = Mood.idle
        for i in 0..<(keys.count - 1) where u >= keys[i].0 && u <= keys[i + 1].0 {
            let span = keys[i + 1].0 - keys[i].0
            let t = span > 0 ? (u - keys[i].0) / span : 0
            m = Mood.mix(keys[i].1, keys[i + 1].1, t * t * (3 - 2 * t))
            break
        }
        for b in [0.08, 0.62] {   // a blink lasts ~0.16 s
            let d = abs(u - b) / 0.014
            if d < 1 { m.open = min(m.open, 0.08 + 0.92 * d * d) }
        }
        return m
    }

    /// The bulges at a point of the cycle: they drift in angle, distance and size in waves, with an envelope that is
    /// zero (and still) at both ends, so every cycle starts and ends on the agent's own shape.
    static func flowing(_ s: Shape, _ u: Double) -> [Bulge] {
        guard u > 0 else { return s.bulges }
        let env = pow(sin(.pi * u), 2)
        return s.bulges.enumerated().map { i, b in
            let ph = Double(i) * 1.7
            let w = 2 * Double.pi * u
            // ("almost unnoticeable"): about half again as much flow as before.
            return Bulge(a: b.a + 0.38 * env * sin(w + ph),
                         r: b.r * (1 + 0.24 * env * sin(2 * w + ph + 0.8)),
                         d: b.d * (1 + 0.17 * env * sin(w + ph + 2.1)))
        }
    }
}

struct AgentAvatar: View {
    let agent: AgentInfo
    var size: CGFloat = 40
    var status: AgentStatus = .idle
    /// Where the eyes look, -1...1 on each axis (e.g. toward the pointer); zero: ahead.
    var gaze: CGSize = .zero
    /// Point 4: whether the hero may play the nudge (lean toward a neighbour, get knocked back). Off where it is
    /// shown alone (the notch, the cursor's tag).
    var nudges = true
    /// At rest it plays its own moves anyway (HeroMoves: dash, pancake, bounces, spin...), without the working
    /// look (the shape does not flow, the eyes stay idle), at this time (seconds) given by the parent's own timeline:
    /// no second timeline (the sign-in's orbit drives its heroes from its one). Still with Reduce Motion / calmer.
    var playTime: Double? = nil

    @State private var workStart: Date?
    @State private var restAt: Date?
    /// With Reduce Motion the figure does not flow; the eyes just show the mood.
    @Environment(\.accessibilityReduceMotion) private var reduceMotionSystem
    /// A11Y-07: the app's own "calmer agents" switch counts like Reduce Motion for the figures.
    @AppStorage(Prefs.simpleBlobs) private var simpleBlobs = false
    private var reduceMotion: Bool { reduceMotionSystem || simpleBlobs }
    /// At rest the figure is alive too: it breathes (a scale-only animation, no redraw) and
    /// blinks now and then (two redraws a blink). Reduce Motion / calmer agents: still, as before.
    @State private var blinking = false
    /// The breath's state: toggled every 1.9 s with no animation in the transaction; only the scale below animates it.
    @State private var breath = false
    /// The working moves, stepped from the timeline (a box, so stepping is not a view update).
    @State private var track = HeroTrack()
    /// Nothing ticks while no window of the app can be seen.
    @ObservedObject private var seen = HeroVisibility.shared
    private var idleAlive: Bool { !reduceMotion && !agent.soon && workStart == nil && status != .working && seen.visible }

    var body: some View {
        let color = agent.soon ? Color(hex: 0xB8BCC4) : Color(hex: agent.colorHex)
        Group {
            if workStart != nil {
                TimelineView(.animation(minimumInterval: EnergySaver.isLow ? 1.0 / 8 : 1.0 / 30, paused: !seen.visible)) { tl in   // Slower in Low Power Mode
                    figure(color, at: tl.date)
                }
            } else if let playTime, idleAlive {
                figure(color, at: nil, play: playTime)
            } else {
                figure(color, at: nil)
            }
        }
        .frame(width: size, height: size)
        // Bugs 2/3 (Feed figures and the messenger's avatars flew up into place): the breath was a
        // phaseAnimator, whose every phase change runs in an animated transaction; a figure appearing while its card
        // or the sheet was still being laid out had its position animated in that transaction, from where it was
        // first placed (below, or the corner) into place, for 1.9 s. Now the figure is one geometry unit placed by its
        // parent, and the breath's animation is scoped to the scale alone: nothing animates the figure's position.
        .geometryGroup()
        .animation(.easeInOut(duration: 1.9)) { v in
            v.scaleEffect(x: breath ? 0.982 : 1, y: breath ? 1.035 : 1, anchor: .bottom)
        }
        .task(id: idleAlive) {
            guard idleAlive else { breath = false; return }
            // start at rest, each figure at its own moment, then in and out
            try? await Task.sleep(nanoseconds: UInt64(Double.random(in: 0.4...1.8) * 1e9))
            while !Task.isCancelled {
                breath.toggle()
                try? await Task.sleep(nanoseconds: 1_900_000_000)
            }
        }
        .task(id: idleAlive) {
            guard idleAlive else { blinking = false; return }
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(Double.random(in: 2.6...5.8) * 1e9))
                if Task.isCancelled { break }
                blinking = true
                try? await Task.sleep(nanoseconds: 140_000_000)
                blinking = false
            }
        }
        .overlay(alignment: .bottomTrailing) {
            if status == .waiting {
                Circle().fill(WS.amber)
                    .frame(width: max(6, size * 0.22), height: max(6, size * 0.22))
                    .overlay(Circle().stroke(WS.surface, lineWidth: 1.5))
                    .offset(x: size * 0.02, y: size * 0.02)
            }
        }
        .onAppear { if status == .working && !reduceMotion { workStart = Date() } }
        .onChange(of: status) { _, s in
            if s == .working {
                if reduceMotion { return }
                restAt = nil
                if workStart == nil { workStart = Date() }
            } else if let start = workStart {
                // finish the cycle in progress, then rest on the agent's own shape
                let done = Date().timeIntervalSince(start)
                let left = AgentBlot.cycle - done.truncatingRemainder(dividingBy: AgentBlot.cycle)
                let at = Date().addingTimeInterval(left)
                restAt = at
                DispatchQueue.main.asyncAfter(deadline: .now() + left) {
                    if restAt == at, status != .working { workStart = nil; restAt = nil }
                }
            }
        }
        .accessibilityLabel(Text("\(agent.name), \(agent.shownRole)"))
    }

    /// The figure at a moment of the cycle (nil: at rest).
    private func figure(_ color: Color, at date: Date?, play: Double? = nil) -> some View {
        var u = 0.0
        var pose = HeroPose.rest
        if let play, workStart == nil {
            pose = track.pose(agent.id, nudge: false, elapsed: play)
        } else if let date, let start = workStart {
            var t = date.timeIntervalSince(start)
            if let restAt { t = min(t, restAt.timeIntervalSince(start)) }
            u = (t / AgentBlot.cycle).truncatingRemainder(dividingBy: 1)
            if let restAt, date >= restAt { u = 0 } else { pose = track.pose(agent.id, nudge: nudges, elapsed: t) }
        }
        let shape = AgentBlot.shape(agent.id)
        let eyes = AgentBlot.eyes(agent.id)
        let mood: AgentBlot.Mood
        if agent.soon { mood = .offline }
        else if date != nil, workStart != nil { mood = AgentBlot.workingMood(u, deepLid: eyes.lid > 0) }
        else if status == .waiting { mood = .waiting }
        else if status == .working { mood = .working }   // Reduce Motion: still, reading eyes
        else { mood = .idle }
        let bulges = AgentBlot.flowing(shape, u)
        var look = mood
        look.dx += Double(max(-1, min(1, gaze.width))) * 0.022 + pose.eyeDX
        look.dy += Double(max(-1, min(1, gaze.height))) * 0.016 + pose.eyeDY
        look.scale *= pose.eyeScale
        look.open = min(look.open, pose.eyeOpen)
        if blinking && date == nil { look.open = 0.08 }
        let seenLook = look   // a constant into the renderer closure, not a captured var
        let side = Double(size)
        // Transform only, inside the figure's fixed frame: the layout never changes while it moves.
        return Canvas { ctx, sz in
            Self.drawBlot(&ctx, sz, shape, bulges, color)
            Self.drawEyes(&ctx, sz, eyes, seenLook)
        }
        .scaleEffect(x: pose.sx, y: pose.sy, anchor: .bottom)
        .rotationEffect(.degrees(pose.tilt), anchor: UnitPoint(x: 0.5, y: 1 - pose.pivot))
        .offset(x: pose.dx * side, y: -pose.lift * side)
    }

    /// The blot: circles merged by blur + threshold (a metaball), stretched to the common box.
    private static func drawBlot(_ ctx: inout GraphicsContext, _ sz: CGSize, _ s: AgentBlot.Shape, _ bulges: [AgentBlot.Bulge], _ color: Color) {
        let side = min(sz.width, sz.height)
        let box = side * 0.80
        let bw = s.box.x1 - s.box.x0, bh = s.box.y1 - s.box.y0
        let kx = box / bw, ky = box / bh        // units -> points (one box for every agent)
        let ox = sz.width / 2 - (s.box.x0 + bw / 2) * kx
        let oy = sz.height / 2 - (s.box.y0 + bh / 2) * ky
        let sigma = 0.15 * (kx + ky) / 2
        ctx.drawLayer { layer in
            // soften the threshold's edge. (too blurry): half the old radius (max(0.35, side
            // * 0.006)), a medium edge, still not hard; every figure (dock, chats, Home, notch) draws through here
            layer.addFilter(.blur(radius: max(0.2, side * 0.003)))
            layer.addFilter(.alphaThreshold(min: 0.47, color: color))
            layer.addFilter(.blur(radius: sigma))
            layer.drawLayer { l in
                func disc(_ x: Double, _ y: Double, _ r: Double) {
                    l.fill(Path(ellipseIn: CGRect(x: ox + (x - r) * kx, y: oy + (y - r) * ky, width: 2 * r * kx, height: 2 * r * ky)), with: .color(.black))
                }
                disc(0, 0, 1)
                for b in bulges { disc(b.d * cos(b.a), b.d * sin(b.a), b.r) }
            }
        }
    }

    private static func drawEyes(_ ctx: inout GraphicsContext, _ sz: CGSize, _ e: AgentBlot.Eyes, _ m: AgentBlot.Mood) {
        let S = min(sz.width, sz.height)
        let cx = sz.width / 2 + m.dx * S, cy = sz.height / 2 - 0.03 * S + m.dy * S
        for side in [-1.0, 1.0] {
            var rx = e.rx * S * m.scale, ry = e.ry * S * m.scale
            if side > 0 { rx *= e.rightScale; ry *= e.rightScale }
            let x = cx + side * e.gap * S
            ctx.drawLayer { l in
                l.translateBy(x: x, y: cy)
                if e.tilt != 0 { l.rotate(by: .degrees(side * e.tilt)) }
                if m.closed {
                    var p = Path()
                    p.addArc(center: CGPoint(x: 0, y: -ry * 0.2), radius: rx * 1.1, startAngle: .degrees(25), endAngle: .degrees(155), clockwise: false)
                    l.stroke(p, with: .color(.white), style: StrokeStyle(lineWidth: max(1, S * 0.02), lineCap: .round))
                    return
                }
                let h = ry * max(0.08, m.open)
                let r = CGRect(x: -rx, y: -h, width: 2 * rx, height: 2 * h)
                let eye: Path
                switch e.cut {
                case .oval: eye = Path(ellipseIn: r)
                case .rounded: eye = Path(roundedRect: r, cornerRadius: min(rx, h) * 0.55, style: .continuous)
                case .capsule: eye = Path(roundedRect: r, cornerRadius: min(rx, h), style: .continuous)
                }
                l.fill(eye, with: .color(.white))
                l.blendMode = .destinationOut
                let lid = max(e.lid, m.lid)
                if m.happy {
                    l.fill(Path(ellipseIn: CGRect(x: -rx * 1.3, y: h * 0.05, width: rx * 2.6, height: h * 2.15)), with: .color(.black))
                } else if m.worried {
                    // the lid slopes down toward the outside, asking
                    let inner = -h + 2 * h * 0.15, outer = -h + 2 * h * 0.55
                    let xi = -side * rx * 1.5, xo = side * rx * 1.5
                    var p = Path()
                    p.move(to: CGPoint(x: xi, y: -h * 3)); p.addLine(to: CGPoint(x: xo, y: -h * 3))
                    p.addLine(to: CGPoint(x: xo, y: outer)); p.addLine(to: CGPoint(x: xi, y: inner)); p.closeSubpath()
                    l.fill(p, with: .color(.black))
                } else if lid > 0 {
                    l.fill(Path(CGRect(x: -rx * 2, y: -h * 3, width: rx * 4, height: h * 2 + 2 * h * lid)), with: .color(.black))
                }
            }
        }
    }
}

/// Point 4: one figure's working moves, stepped forward as its timeline asks for them. A plain box held in @State:
/// stepping it inside the timeline's closure is not a state change, so it costs no extra view update.
final class HeroTrack {
    private var seq: HeroMoves.Sequence?

    func pose(_ agent: String, nudge: Bool, elapsed: Double) -> HeroPose {
        if seq == nil || seq?.agent != agent || seq?.allowNudge != nudge {
            seq = HeroMoves.Sequence(agent: agent, allowNudge: nudge)
        }
        return seq?.pose(elapsed: elapsed) ?? .rest
    }
}

/// Point 4 (keep the Mac cool): whether any window of the app can be seen. The figures' timelines pause and the
/// breath and blinks stop while it cannot (every window hidden, minimised or covered).
@MainActor
final class HeroVisibility: ObservableObject {
    static let shared = HeroVisibility()
    @Published private(set) var visible = true
    private var observers: [NSObjectProtocol] = []
    private var poll: Timer?

    /// (after Continue with Apple the sign-in's Lia froze for good): the app's occlusion
    /// notification alone can be missed or arrive before the state settles (a system sheet over the window). Now
    /// activation, a window becoming key and a window's own occlusion re-check too, each once more a moment later,
    /// and while nothing is visible a slow poll re-checks, so the figures never stay paused once a window shows.
    private init() {
        let names: [Notification.Name] = [
            NSApplication.didChangeOcclusionStateNotification,
            NSApplication.didBecomeActiveNotification,
            NSApplication.didUnhideNotification,
            NSWindow.didBecomeKeyNotification,
            NSWindow.didChangeOcclusionStateNotification,
            NSWindow.didDeminiaturizeNotification,
        ]
        observers = names.map { name in
            NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { _ in
                Task { @MainActor in HeroVisibility.shared.refreshSoon() }
            }
        }
    }

    private func refreshSoon() {
        refresh()
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 400_000_000)
            HeroVisibility.shared.refresh()
        }
    }

    private func refresh() {
        let v = NSApp.occlusionState.contains(.visible) || NSApp.windows.contains { $0.isVisible && $0.occlusionState.contains(.visible) }
        if v != visible { visible = v }
        if v {
            poll?.invalidate()
            poll = nil
        } else if poll == nil {
            poll = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { _ in
                Task { @MainActor in HeroVisibility.shared.refresh() }
            }
        }
    }
}

/// Items 14-15: the same figure as a small NSImage, for the menu bar item (whose label takes only Image and Text).
/// Drawn with Core Graphics as merged discs (at 18 pt a metaball and a union of discs look the same), with the
/// agent's flow, pose and eyes at a point `u` of its cycle; u = 0 is the agent at rest.
enum AgentBlotImage {
    static func image(_ id: String, color hex: UInt32, u: Double, pose: HeroPose = .rest, size: CGFloat = 18, blink: Bool = false, dim: Bool = false) -> NSImage {
        let img = NSImage(size: NSSize(width: size, height: size), flipped: true) { rect in
            guard let cg = NSGraphicsContext.current?.cgContext else { return false }
            let dark = NSAppearance.currentDrawing().bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            var c = NSColor(srgbHex: hex)
            // Lia's near-black would vanish on a dark menu bar: lift a dark colour there.
            if dark, c.brightnessComponentSafe < 0.35 { c = NSColor(white: 0.86, alpha: 1) }
            if dim { c = c.withAlphaComponent(0.55) }
            let S = Double(min(rect.width, rect.height))
            cg.saveGState()
            // the move's pose (HeroMoves), the same order as the big figure's: squash about the bottom centre, tilt
            // about the pivot, then the shift; a little smaller here, so it stays inside the menu bar's 18 pt
            let bottom = rect.maxY - 1
            let pivotY = bottom - CGFloat(pose.pivot * S)
            cg.translateBy(x: CGFloat(pose.dx * S * 0.6), y: -CGFloat(pose.lift * S * 0.6))
            cg.translateBy(x: rect.midX, y: pivotY)
            cg.rotate(by: CGFloat(pose.tilt * Double.pi / 180))
            cg.translateBy(x: 0, y: bottom - pivotY)
            cg.scaleBy(x: CGFloat(1 + (pose.sx - 1) * 0.8), y: CGFloat(1 + (pose.sy - 1) * 0.8))
            cg.translateBy(x: -rect.midX, y: -bottom)
            let shape = AgentBlot.shape(id)
            let bulges = AgentBlot.flowing(shape, u)
            let box = S * 0.86
            let bw = shape.box.x1 - shape.box.x0, bh = shape.box.y1 - shape.box.y0
            let kx = box / bw, ky = box / bh
            let ox = Double(rect.midX) - (shape.box.x0 + bw / 2) * kx
            let oy = Double(rect.midY) - (shape.box.y0 + bh / 2) * ky
            cg.setFillColor(c.cgColor)
            func disc(_ x: Double, _ y: Double, _ r: Double) {
                cg.fillEllipse(in: CGRect(x: ox + (x - r) * kx, y: oy + (y - r) * ky, width: 2 * r * kx, height: 2 * r * ky))
            }
            disc(0, 0, 1)
            for b in bulges { disc(b.d * cos(b.a), b.d * sin(b.a), b.r) }
            // the eyes, a little larger than in the big figure so they read at this size
            let e = AgentBlot.eyes(id)
            var m = u > 0 ? AgentBlot.workingMood(u, deepLid: e.lid > 0) : AgentBlot.Mood.idle
            m.dx += pose.eyeDX; m.dy += pose.eyeDY; m.scale *= pose.eyeScale
            m.open = min(m.open, pose.eyeOpen)
            if blink { m.open = 0.08 }
            let k = 1.45
            let cx = Double(rect.midX) + m.dx * S, cy = Double(rect.midY) - 0.03 * S + m.dy * S
            cg.setFillColor(NSColor.white.cgColor)
            for side in [-1.0, 1.0] {
                var rx = e.rx * S * k, ry = e.ry * S * k
                if side > 0 { rx *= e.rightScale; ry *= e.rightScale }
                let h = ry * max(0.12, m.open) * (1 - 0.5 * max(e.lid, m.lid))
                cg.fillEllipse(in: CGRect(x: cx + side * e.gap * S * 1.1 - rx, y: cy - h, width: 2 * rx, height: 2 * h))
            }
            cg.restoreGState()
            return true
        }
        img.isTemplate = false
        return img
    }
}

extension NSColor {
    convenience init(srgbHex h: UInt32) {
        self.init(srgbRed: CGFloat((h >> 16) & 0xFF) / 255, green: CGFloat((h >> 8) & 0xFF) / 255, blue: CGFloat(h & 0xFF) / 255, alpha: 1)
    }
    /// Brightness in HSB, 1 when the colour cannot be converted.
    var brightnessComponentSafe: CGFloat { usingColorSpace(.sRGB)?.brightnessComponent ?? 1 }
}

extension View {
    /// The workspace's glass (panels and toolbars in glass, as macOS gives it): Liquid Glass on
    /// MacOS 26 when built with its SDK, a translucent material otherwise; opaque with Reduce Transparency.
    func wsGlass(_ radius: CGFloat, interactive: Bool = false) -> some View {
        modifier(WSGlass(radius: radius, interactive: interactive))
    }
}

private struct WSGlass: ViewModifier {
    let radius: CGFloat
    let interactive: Bool
    @Environment(\.accessibilityReduceTransparency) private var opaque
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.colorScheme) private var scheme

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        if opaque || contrast == .increased {
            content.background(WS.surface, in: shape).overlay(shape.stroke(WS.line2, lineWidth: 1))
        } else {
            glass(content, shape)
        }
    }

    @ViewBuilder private func glass(_ content: Content, _ shape: RoundedRectangle) -> some View {
        #if compiler(>=6.2)
        if #available(macOS 26.0, *) {
            content.glassEffect(interactive ? .regular.interactive() : .regular, in: shape)
        } else {
            material(content, shape)
        }
        #else
        material(content, shape)
        #endif
    }

    /// Before macOS 26: the material with the shared natural rim (was a 1 pt white edge, 0.6 light /
    /// 0.14 dark, all round).
    private func material(_ content: Content, _ shape: RoundedRectangle) -> some View {
        content.background(.regularMaterial, in: shape).overlay(WSGlassRim(shape: shape, dark: scheme == .dark))
    }
}
