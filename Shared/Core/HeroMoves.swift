import Foundation

/// (point 4): a hero at work no longer just rocks along an arc. It plays short "moves" one after
/// another, each starting and ending on the rest pose so they chain seamlessly: it dashes about, jumps and lands flat
/// as a pancake, spins, shakes thinking hard, floats, sinks and pops up, wobbles like jelly, gets dizzy, or leans
/// toward a neighbour and is knocked back. Which move comes next is a pure, deterministic pick per hero (its
/// personality weights, never the same move twice in a row), so it is tested on Linux. The figure (SwiftUI), the
/// menu bar's NSImage and the notch island all draw the same pose.

/// A pose of the figure, applied as a transform only (never layout): `dx` sideways and `lift` up in units of the
/// figure's size, `tilt` in degrees (about the bottom centre), `sx`/`sy` a squash or stretch anchored at the bottom.
/// The eyes: an extra look (units of size), a scale and how open they are (1: as the mood has them).
struct HeroPose: Equatable {
    var dx = 0.0, lift = 0.0, tilt = 0.0, sx = 1.0, sy = 1.0
    /// Where the tilt turns, in units of size above the bottom centre: 0 rocks on the ground, 0.5 turns about the middle.
    var pivot = 0.0
    var eyeDX = 0.0, eyeDY = 0.0, eyeScale = 1.0, eyeOpen = 1.0

    static let rest = HeroPose()

    /// Within `eps` of the rest pose on every channel.
    func isRest(_ eps: Double = 1e-6) -> Bool {
        abs(dx) < eps && abs(lift) < eps && abs(tilt) < eps && abs(sx - 1) < eps && abs(sy - 1) < eps
            && abs(eyeDX) < eps && abs(eyeDY) < eps && abs(eyeScale - 1) < eps && abs(eyeOpen - 1) < eps
    }

    /// The largest difference from another pose on any channel (tilt in hundreds of degrees, the short way round).
    func distance(to o: HeroPose) -> Double {
        max(abs(dx - o.dx), abs(lift - o.lift), abs(HeroMoves.normalizedDegrees(tilt - o.tilt)) / 100, abs(sx - o.sx), abs(sy - o.sy),
            abs(eyeDX - o.eyeDX), abs(eyeDY - o.eyeDY), abs(eyeScale - o.eyeScale), abs(eyeOpen - o.eyeOpen))
    }
}

enum HeroMove: String, CaseIterable, Equatable {
    /// Zips left and right, stretched along the motion, leaning into it.
    case dash
    /// Jumps and bounces like a ball: brief squashes on impact that rebound into lower hops (no lying flat).
    case pancake
    /// Three hops, each lower, a squash on every landing.
    case bounces
    /// Leans back, leaps into a full turn, lands and wobbles.
    case spin
    /// Shakes fast in place, hunched (thinking hard), then an "aha" pop.
    case jitter
    /// Rises slowly, tall, sways while it hovers, settles with a soft squash.
    case float
    /// Sinks low into the ground, looks left and right, pops up tall.
    case peek
    /// A poke, then the whole body wobbles like jelly and calms.
    case jelly
    /// Sways in circles, the eyes roll round, then shakes it off.
    case dizzy
    /// Leans toward a neighbour, gets knocked back, wobbles to rest.
    case nudge

    /// Seconds. Every move fits a slot (`HeroMoves.slot`); the rest of the slot is a short pause at rest.
    var duration: Double {
        switch self {
        case .dash: return 2.2
        case .pancake: return 2.6
        case .bounces: return 2.4
        case .spin: return 2.0
        case .jitter: return 1.8
        case .float: return 2.9
        case .peek: return 2.5
        case .jelly: return 2.2
        case .dizzy: return 2.6
        case .nudge: return 2.3
        }
    }
}

enum HeroMoves {
    /// One move per slot; two slots make the figure's flow cycle (`AgentBlot.cycle`), so a run that stops finishes
    /// on a slot boundary, at rest.
    static let slot = 3.0
    /// Spelled once, so the pose arithmetic type-checks fast (no `.pi` literal inference).
    static let pi = Double.pi

    // MARK: the picker

    /// Personality: how often each hero plays each move (relative weights, in `HeroMove.allCases` order).
    static func weights(_ agent: String) -> [HeroMove: Double] {
        switch agent {
        case "dev":   // the quick one: hops and pancakes
            return [.dash: 2, .pancake: 5, .bounces: 4, .spin: 1, .jitter: 2, .float: 0.5, .peek: 1, .jelly: 1, .dizzy: 1, .nudge: 2]
        case "met":   // the careful one: precise dashes, focused shakes
            return [.dash: 5, .pancake: 1, .bounces: 1, .spin: 0.5, .jitter: 3, .float: 1, .peek: 2, .jelly: 0.5, .dizzy: 0.5, .nudge: 2]
        case "crea":  // the playful one: jelly and spins
            return [.dash: 1, .pancake: 1, .bounces: 2, .spin: 4, .jitter: 1, .float: 1, .peek: 1, .jelly: 5, .dizzy: 2, .nudge: 2]
        case "lia":   // the lead: floats and peeks
            return [.dash: 1, .pancake: 0.5, .bounces: 1, .spin: 1, .jitter: 1, .float: 5, .peek: 4, .jelly: 1, .dizzy: 0.5, .nudge: 2]
        default:
            return Dictionary(uniqueKeysWithValues: HeroMove.allCases.map { ($0, 1.0) })
        }
    }

    /// The move for `cycle` (a slot index): weighted by the hero, never `previous`, without `nudge` when the hero is
    /// shown alone. Pure: the same arguments always give the same move.
    static func next(agent: String, cycle: Int, previous: HeroMove?, allowNudge: Bool = true) -> HeroMove {
        let w = weights(agent)
        let pool = HeroMove.allCases.filter { m in
            m != previous && (allowNudge || m != .nudge) && (w[m] ?? 0) > 0
        }
        guard !pool.isEmpty else { return previous == .dash ? .jelly : .dash }
        let total = pool.reduce(0) { $0 + (w[$1] ?? 0) }
        var r = unit(agent, cycle, salt: 0x9E37) * total
        for m in pool {
            r -= w[m] ?? 0
            if r < 0 { return m }
        }
        return pool[pool.count - 1]
    }

    /// Which side a move leans to in `cycle` (+1 right, -1 left): the nudge's neighbour, the dash's first zip.
    static func direction(agent: String, cycle: Int) -> Double {
        unit(agent, cycle, salt: 0x51ED) < 0.5 ? -1 : 1
    }

    /// A stable number in 0..<1 from the hero and the cycle (FNV-1a, then a splitmix64 finish).
    static func unit(_ agent: String, _ cycle: Int, salt: UInt64) -> Double {
        var h: UInt64 = 0xcbf29ce484222325
        for b in agent.utf8 { h = (h ^ UInt64(b)) &* 0x100000001b3 }
        var z = h ^ (UInt64(bitPattern: Int64(cycle)) &* 0x9E3779B97F4A7C15) ^ (salt &* 0xBF58476D1CE4E5B9)
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        z = z ^ (z >> 31)
        return Double(z >> 11) / Double(UInt64(1) << 53)
    }

    /// The moves of one hero in order, stepped forward incrementally (a view keeps one and asks for the slot it is in;
    /// asking for an earlier slot starts over).
    struct Sequence {
        let agent: String
        let allowNudge: Bool
        private(set) var cycle = -1
        private(set) var move: HeroMove?

        init(agent: String, allowNudge: Bool = true) { self.agent = agent; self.allowNudge = allowNudge }

        mutating func at(_ c: Int) -> HeroMove {
            let target = max(0, c)
            if target < cycle { cycle = -1; move = nil }
            while cycle < target {
                cycle += 1
                move = HeroMoves.next(agent: agent, cycle: cycle, previous: move, allowNudge: allowNudge)
            }
            return move ?? .dash
        }

        /// The pose `elapsed` seconds into the work (slot by slot: the move, then rest until the slot ends).
        mutating func pose(elapsed: Double) -> HeroPose {
            guard elapsed > 0 else { return .rest }
            let c = Int((elapsed / HeroMoves.slot).rounded(.down))
            let local = elapsed - Double(c) * HeroMoves.slot
            let m = at(c)
            guard local < m.duration else { return .rest }
            return HeroMoves.pose(m, local / m.duration, dir: HeroMoves.direction(agent: agent, cycle: c))
        }
    }

    // MARK: the poses

    /// The pose of `move` at `t` in 0...1 (rest at both ends). `dir` mirrors the sideways moves.
    static func pose(_ move: HeroMove, _ t: Double, dir: Double = 1) -> HeroPose {
        guard t > 0, t < 1 else { return .rest }
        var p = HeroPose()
        let d = dir < 0 ? -1.0 : 1.0
        switch move {
        case .dash:
            // there and back twice, faster in the middle; stretch along the speed, lean into it
            let x = { (u: Double) -> Double in 0.13 * d * sin(4 * pi * u) * sin(pi * u) }
            let h = 0.004
            let v = (x(min(1, t + h)) - x(max(0, t - h))) / (2 * h)   // size units per move
            let speed = min(1, abs(v) / 1.6)
            p.dx = x(t)
            p.sx = 1 + 0.20 * speed
            p.sy = 1 - 0.12 * speed
            p.tilt = -9 * clamp(v / 1.6)
            p.lift = 0.02 * speed
            p.eyeDX = 0.03 * clamp(x(t) / 0.13)
        case .pancake:
            // (too stiff, lay flat too long): a bouncy ball. A jump, a brief squash on impact
            // (about 100 ms) that rebounds straight into a lower hop, a shorter squash, a little hop, a last tiny
            // squash, a damped wobble to rest. Never sits flat.
            if t < 0.06 {   // crouch
                let b = bump(t, 0, 0.06)
                p.sy = 1 - 0.12 * b; p.sx = 1 + 0.09 * b
            } else if t < 0.40 {   // the jump, stretched in the air
                let s = (t - 0.06) / 0.34
                p.lift = 0.24 * sin(pi * s)
                p.sy = 1 + 0.08 * sin(pi * s)
                p.sx = 1 - 0.06 * sin(pi * s)
                p.eyeDY = -0.02 * sin(pi * s)
                p.eyeScale = 1 + 0.12 * sin(pi * s)
            } else if t < 0.44 {   // impact: a brief splat that springs right back
                let b = bump(t, 0.40, 0.44)
                p.sy = 1 - 0.40 * b; p.sx = 1 + 0.36 * b
                p.eyeOpen = 1 - 0.55 * b
            } else if t < 0.64 {   // the rebound hop
                let s = (t - 0.44) / 0.20
                p.lift = 0.11 * sin(pi * s)
                p.sy = 1 + 0.05 * sin(pi * s); p.sx = 1 - 0.04 * sin(pi * s)
                p.eyeScale = 1 + 0.06 * sin(pi * s)
            } else if t < 0.675 {   // a shorter squash
                let b = bump(t, 0.64, 0.675)
                p.sy = 1 - 0.22 * b; p.sx = 1 + 0.20 * b
                p.eyeOpen = 1 - 0.3 * b
            } else if t < 0.80 {   // a little hop
                let s = (t - 0.675) / 0.125
                p.lift = 0.045 * sin(pi * s)
                p.sy = 1 + 0.025 * sin(pi * s); p.sx = 1 - 0.02 * sin(pi * s)
            } else if t < 0.83 {   // the last tiny squash
                let b = bump(t, 0.80, 0.83)
                p.sy = 1 - 0.11 * b; p.sx = 1 + 0.10 * b
            } else {   // a damped wobble, exactly to rest
                let s = (t - 0.83) / 0.17
                let w = 0.04 * sin(2 * pi * s) * (1 - s) * (1 - s)
                p.sy = 1 + w; p.sx = 1 - w * 0.9
            }
        case .bounces:
            // a crouch, three hops each lower; every landing a brief elastic squash (~85 ms) that pushes straight off
            let hops: [(Double, Double, Double)] = [(0.06, 0.36, 0.17), (0.36, 0.60, 0.11), (0.60, 0.78, 0.06)]
            if t < 0.06 {
                let b = bump(t, 0, 0.06)
                p.sy = 1 - 0.10 * b; p.sx = 1 + 0.07 * b
            } else if t < 0.78 {
                for (a, b, hh) in hops where t >= a && t < b {
                    let s = (t - a) / (b - a)
                    p.lift = hh * sin(pi * s)
                    p.sy = 1 + 0.06 * (hh / 0.17) * sin(pi * s)
                }
                let land = bump(t, 0.345, 0.38) + 0.7 * bump(t, 0.585, 0.62)
                p.sy -= 0.20 * land
                p.sx = 1 - (p.sy - 1) * 0.8
                let u = (t - 0.06) / 0.72
                p.tilt = 4 * d * sin(6 * pi * u) * sin(pi * u)
                p.eyeDY = -0.012 * p.lift / 0.17
            } else {
                let s = (t - 0.78) / 0.22
                let squash = 0.14 * bump(t, 0.78, 0.815)
                let w = 0.035 * sin(2 * pi * s) * (1 - s) * (1 - s)
                p.sy = 1 - squash + (t > 0.815 ? w : 0)
                p.sx = 1 - (p.sy - 1) * 0.8
            }
        case .spin:
            if t < 0.18 {   // lean back, gathering
                let b = smooth(t / 0.18)
                p.tilt = -14 * d * b
                p.sy = 1 - 0.08 * b; p.sx = 1 + 0.08 * b
            } else if t < 0.76 {   // the turn, in the air
                let s = (t - 0.18) / 0.58
                let e = smooth(s)
                p.tilt = d * (-14 + 394 * e)
                p.pivot = 0.5 * sin(pi * s)   // a whole turn goes about the middle, not over the ground
                p.lift = 0.15 * sin(pi * s)
                p.sy = 0.92 + 0.08 * smooth(min(1, s * 4)) + 0.05 * sin(pi * s)
                p.sx = 2 - p.sy
                p.eyeOpen = 1 - 0.4 * sin(pi * s)
            } else {   // land past the turn, wobble back
                let s = (t - 0.76) / 0.24
                let k = (1 - s) * (1 - s)
                p.tilt = d * (360 + 20 * k * cos(2.5 * pi * s))
                p.sy = 1 - 0.12 * k * sin(2.5 * pi * s); p.sx = 2 - p.sy
            }
            p.tilt = normalizedDegrees(p.tilt)
        case .jitter:
            let env = pow(sin(pi * min(1, t / 0.82)), 2) * (t < 0.82 ? 1 : 0)
            p.dx = 0.022 * sin(2 * pi * 15 * t) * env
            p.tilt = 3.5 * sin(2 * pi * 11 * t + 1) * env
            p.sy = 1 - 0.05 * env; p.sx = 1 + 0.03 * env
            p.eyeOpen = 1 - 0.45 * env   // squinting, thinking hard
            p.eyeDY = 0.01 * env
            // the "aha": eyes wide and a little hop
            let aha = bump(t, 0.80, 1.0)
            p.lift = 0.07 * aha
            p.eyeScale = 1 + 0.28 * aha
            p.sy += 0.06 * aha; p.sx -= 0.04 * aha
        case .float:
            let up = t < 0.28 ? smooth(t / 0.28) : (t < 0.78 ? 1 : 1 - smooth((t - 0.78) / 0.14))
            let hover = t < 0.92 ? up : 0
            p.lift = 0.13 * hover + 0.015 * sin(2 * pi * 3 * t) * hover
            p.sy = 1 + 0.07 * hover; p.sx = 1 - 0.045 * hover
            p.tilt = 7 * d * sin(2 * pi * 2 * t) * pow(sin(pi * min(1, t / 0.92)), 2) * (t < 0.92 ? 1 : 0)
            p.eyeDY = -0.03 * hover
            p.eyeScale = 1 + 0.06 * hover
            let land = bump(t, 0.88, 1.0)
            p.sy -= 0.10 * land; p.sx += 0.07 * land
        case .peek:
            if t < 0.22 {   // sink
                let s = smooth(t / 0.22)
                p.sy = 1 - 0.68 * s; p.sx = 1 + 0.16 * s
                p.eyeOpen = 1 - 0.3 * s
                p.eyeDY = -0.02 * s
            } else if t < 0.60 {   // low, looking left and right
                let s = (t - 0.22) / 0.38
                p.sy = 0.32; p.sx = 1.16
                p.eyeOpen = 0.7
                p.eyeDX = 0.04 * d * sin(2 * pi * s) * sin(pi * s) * 1.6
                p.eyeDY = -0.02
            } else if t < 0.74 {   // pop up, tall
                let s = smooth((t - 0.60) / 0.14)
                p.sy = 0.32 + 0.98 * s; p.sx = 1.16 - 0.32 * s
                p.lift = 0.11 * s
                p.eyeOpen = 0.7 + 0.3 * s
                p.eyeScale = 1 + 0.2 * s
                p.eyeDY = -0.02 * (1 - s)
            } else {   // come down, springy
                let s = (t - 0.74) / 0.26
                let k = (1 - s) * (1 - s)
                let c = cos(2.5 * pi * s)
                p.sy = 1 + 0.30 * k * c; p.sx = 1 - 0.16 * k * c
                p.lift = 0.11 * k * max(0, cos(pi / 2 * s * 1.6))
                p.eyeScale = 1 + 0.2 * k
            }
        case .jelly:
            let poke = smooth(min(1, t / 0.08))
            let k = pow(1 - t, 2) * poke
            let w = sin(2 * pi * 5 * t)
            p.sx = 1 + 0.17 * k * w
            p.sy = 1 - 0.17 * k * w
            p.tilt = 6 * d * k * sin(2 * pi * 3 * t)
            p.dx = 0.02 * d * k * sin(2 * pi * 3 * t)
            p.eyeDY = 0.02 * k * w
            p.eyeScale = 1 + 0.1 * k
        case .dizzy:
            let body = t < 0.80 ? pow(sin(pi * t / 0.80), 2) : 0
            let th = 2 * pi * 3 * t
            p.dx = 0.045 * d * sin(th) * body
            p.tilt = 8 * d * (cos(th) - 1) * body   // starts and ends upright
            p.lift = 0.02 * (1 - cos(th)) / 2 * body
            p.eyeDX = 0.03 * d * sin(2 * pi * 4 * t) * body
            p.eyeDY = 0.03 * (1 - cos(2 * pi * 4 * t)) / 2 * body - 0.015 * body
            p.eyeScale = 1 - 0.15 * body
            // shake it off
            if t >= 0.80 {
                let s = (t - 0.80) / 0.20
                p.tilt = 6 * d * sin(2 * pi * 3 * s) * sin(pi * s)
            }
        case .nudge:
            if t < 0.30 {   // lean toward the neighbour
                let s = smooth(t / 0.30)
                p.tilt = 14 * d * s; p.dx = 0.07 * d * s
                p.eyeDX = 0.035 * d * s
            } else if t < 0.40 {   // closer, curious
                let s = smooth((t - 0.30) / 0.10)
                p.tilt = 14 * d + 4 * d * s; p.dx = 0.07 * d + 0.02 * d * s
                p.eyeDX = 0.035 * d
                p.eyeScale = 1 + 0.1 * s
            } else if t < 0.48 {   // knocked back
                let s = smooth((t - 0.40) / 0.08)
                p.tilt = 18 * d - 40 * d * s; p.dx = 0.09 * d - 0.22 * d * s
                p.lift = 0.05 * sin(pi * s)
                let hit = sin(pi * s)
                p.sx = 1 - 0.18 * hit; p.sy = 1 + 0.08 * hit
                p.eyeOpen = 1 - 0.7 * hit
                p.eyeScale = 1.1 - 0.1 * s
                p.eyeDX = 0.035 * d * (1 - s)
            } else {   // wobble back to rest
                let s = (t - 0.48) / 0.52
                let k = (1 - s) * (1 - s)
                let c = cos(2.5 * pi * s)
                p.tilt = -22 * d * k * c
                p.dx = -0.13 * d * k * c
                p.sx = 1 - 0.06 * k * sin(5 * pi * s); p.sy = 2 - p.sx
                p.eyeOpen = 1 - 0.4 * sin(pi * s) * (1 - s)   // dazed
            }
        }
        return p
    }

    // MARK: helpers

    /// 0 at a and b, 1 halfway (a sin² bump); 0 outside.
    static func bump(_ t: Double, _ a: Double, _ b: Double) -> Double {
        guard t > a, t < b, b > a else { return 0 }
        let s = sin(pi * (t - a) / (b - a))
        return s * s
    }

    static func clamp(_ x: Double) -> Double { min(1, max(-1, x)) }

    static func smooth(_ x: Double) -> Double {
        let c = min(1, max(0, x))
        return c * c * (3 - 2 * c)
    }

    /// An angle in (-180, 180].
    static func normalizedDegrees(_ a: Double) -> Double {
        var r = a.truncatingRemainder(dividingBy: 360)
        if r > 180 { r -= 360 }
        if r <= -180 { r += 360 }
        return r
    }
}

