import Foundation

/// The sign-in's hero area (App/Auth/SignInOrbit.swift), iCloud.com's way. Pure data, so the
/// web can copy it 1:1: points in pt from the centre of a fixed `width` x `height` frame, y down; angles in degrees,
/// clockwise from east (y down); times in seconds.
///
/// The stages run forever: the team (all four heroes side by side, no ring) -> Lia -> Dev -> Met -> Crea -> the team...
/// In a hero's stage that hero sits in the centre in its own tinted circle (`centreSize`) with its own set of service
/// bubbles round it: touching the circle or tucked a little under its edge (always below the circle). The ring turns
/// clockwise as one, at a constant speed (`ringTurn` seconds a turn); each bubble keeps its radius.
struct OrbitSpot: Equatable {
    let id: String
    /// Whose set: lia, dev, met or crea.
    let world: String
    /// Place in its set: the order it pops in (and out).
    let order: Int
    /// Where on the ring at rest (degrees, clockwise from east).
    let angle: Double
    let size: Double
    /// How far it sits under the centre circle's edge (pt; 0 = just touching).
    let tuck: Double
    /// The BrandMarks id drawn (Crea's OpenAI bubble, "openai.crea", draws OpenAI's mark).
    var mark: String? = nil
    var markId: String { mark ?? id }

    /// Distance of its centre from the orbit's centre.
    var radius: Double { OrbitLayout.centreSize / 2 + size / 2 - tuck }

    /// Its point with the ring turned `turn` degrees clockwise.
    func point(turn: Double) -> (x: Double, y: Double) {
        let a = (angle + turn) * Double.pi / 180
        return (radius * cos(a), radius * sin(a))
    }
}

enum OrbitLayout {
    static let width = 320.0
    static let height = 320.0
    /// The centre circle's diameter, and the hero inside it (a share of the circle).
    static let centreSize = 150.0
    static let heroShare = 0.6

    // MARK: stages

    static let heroes = ["lia", "dev", "met", "crea"]
    /// The all-together stage.
    static let team = "team"
    static let stages = [team] + heroes

    /// The stage after `s`: the team after Crea, forever (an unknown stage gives the team).
    static func nextStage(after s: String) -> String {
        guard let i = stages.firstIndex(of: s) else { return team }
        return stages[(i + 1) % stages.count]
    }

    /// How long a stage stays: the cloud 3 s, each hero 3 s.
    static let cloudHold = 3.0
    static let heroHold = 3.0
    static func duration(_ stage: String) -> Double { stage == team ? cloudHold : heroHold }

    // MARK: the cloud (iCloud's cloud)

    /// One filled cloud, the union of three circles and a wide flat-bottomed base with round ends: a big circle top
    /// centre-right, a smaller one top-left, one at the right end (x, y, r).
    static let cloudCircles: [(x: Double, y: Double, r: Double)] = [(22, 0, 76), (-62, 14, 50), (100, 36, 40)]
    static let cloudBase = (x0: -140.0, y0: 16.0, x1: 140.0, y1: 76.0, corner: 30.0)
    /// The heroes inside it, each in one bump: Lia the big top bump, Met the small top-left one, Dev the right end,
    /// Crea the lower-left base (x, y, figure scale: a share of the centre figure).
    static let cloudSpots: [String: (x: Double, y: Double, scale: Double)] = [
        "lia": (22, -6, 0.8),
        "met": (-62, 10, 0.6),
        "dev": (104, 40, 0.5),
        "crea": (-108, 48, 0.42),
    ]
    /// The cloud's gradient, left to right: each hero's tint where it sits.
    static let cloudStops = ["crea", "met", "lia", "dev"]

    /// The body's shape: the cloud (morph 0) melting into the centre circle (morph 1; every piece lerps to the circle,
    /// the base's corners to its radius), scaled about the centre.
    struct BodyShape: Equatable {
        var circles: [Disc]
        var base: Box
        struct Disc: Equatable { var x: Double, y: Double, r: Double }
        struct Box: Equatable { var x0: Double, y0: Double, x1: Double, y1: Double, corner: Double }
    }

    static func bodyShape(morph m: Double, scale s: Double) -> BodyShape {
        let R = centreSize / 2
        func l(_ a: Double, _ b: Double) -> Double { (a + (b - a) * m) * s }
        let circles = cloudCircles.map { BodyShape.Disc(x: l($0.x, 0), y: l($0.y, 0), r: l($0.r, R)) }
        let b = cloudBase
        let box = BodyShape.Box(x0: l(b.x0, -R), y0: l(b.y0, -R), x1: l(b.x1, R), y1: l(b.y1, R), corner: l(b.corner, R))
        return BodyShape(circles: circles, base: box)
    }

    // MARK: the director: which stage, since when

    /// The stage under way, from `from` to `to` since `changeAt` (orbit clock, seconds). Stepped once a frame.
    struct Director: Equatable {
        var from = OrbitLayout.team
        var to = OrbitLayout.team
        var changeAt = 0.0

        /// The next stage when this one has had its time; `holdLia`: go to Lia (now) and stay.
        mutating func step(_ t: Double, holdLia: Bool) {
            if holdLia {
                if to != "lia" { from = to; to = "lia"; changeAt = t }
                return
            }
            if t - changeAt >= OrbitLayout.duration(to) {
                from = to
                to = OrbitLayout.nextStage(after: to)
                changeAt = t
            }
        }
    }

    // MARK: timing

    /// A change: the old ring is pulled in under the hero and the circle contracts (`squeeze`) for `swapDelay`; then
    /// the heroes move and the body springs out. From the cloud nothing is pulled in: the heroes move at once.
    static let swapDelay = 0.28
    static let squeeze = 0.87
    static func moveAt(from: String) -> Double { from == team ? 0 : swapDelay }
    /// When the new ring is spat out: once the circle has formed (from the cloud), or right after the swap.
    static func spitAt(from: String) -> Double { from == team ? 0.34 : swapDelay + 0.08 }
    /// Bubble after bubble: in `inStagger`, out `outStagger`.
    static let inStagger = 0.05
    static let outStagger = 0.02
    /// One clockwise turn of the ring. It never stops: the angle is the clock's, across every change.
    static let ringTurn = 75.0

    static func ringAngle(_ t: Double) -> Double {
        (t * 360 / ringTurn).truncatingRemainder(dividingBy: 360)
    }

    /// Pulled in: over `pullDuration` a bubble slides to `pullRadius` of its radius (under the centre circle), shrinks
    /// to `pullScale` and fades.
    static let pullDuration = 0.3
    static let pullRadius = 0.35
    static let pullScale = 0.55

    /// Spat out (the jelly): from under the centre (`spitFrom` of its radius, `spitScale`) it shoots a few pt past its
    /// place and bounces back three times, each smaller and slower. Keyframes: (radial offset from its place in pt,
    /// scale, seconds); the first is the shot (eased out), the rest cosine swings.
    static let spitFrom = 0.35
    static let spitScale = 0.55
    static let spitFade = 0.1
    static let jellyKeys: [(dr: Double, scale: Double, time: Double)] = [
        (5, 1.06, 0.34),
        (-2.5, 0.97, 0.18),
        (1.2, 1.015, 0.22),
        (-0.5, 0.995, 0.26),
        (0, 1, 0.30),
    ]
    static var jellyTotal: Double { jellyKeys.reduce(0) { $0 + $1.time } }

    /// Keyframes from `start`: the first segment eased out, the others cosine swings (smooth turns at both ends).
    static func track(_ keys: [(value: Double, time: Double)], from start: Double, _ tau: Double) -> Double {
        if tau <= 0 { return start }
        var from = start, t = tau
        for (i, k) in keys.enumerated() {
            if t < k.time {
                let u = t / k.time
                let e = i == 0 ? 1 - pow(1 - u, 3) : 0.5 - 0.5 * cos(Double.pi * u)
                return from + (k.value - from) * e
            }
            t -= k.time
            from = k.value
        }
        return keys.last?.value ?? start
    }

    /// A bubble `tau` seconds into its spit (negative: not yet out): its radial offset in pt from its place (rest
    /// radius `r`), its scale and opacity.
    static func spit(_ tau: Double, radius r: Double) -> (dr: Double, scale: Double, opacity: Double) {
        let dr = track(jellyKeys.map { ($0.dr, $0.time) }, from: -(1 - spitFrom) * r, tau)
        let sc = track(jellyKeys.map { ($0.scale, $0.time) }, from: spitScale, tau)
        return (dr, sc, max(0, min(1, tau / spitFade)))
    }

    /// A bubble `tau` seconds into being pulled in: its radius factor, scale and opacity.
    static func pull(_ tau: Double) -> (k: Double, scale: Double, opacity: Double) {
        let u = max(0, min(1, tau / pullDuration))
        let e = u * u
        let fade = max(0, min(1, (e - 0.4) / 0.6))
        return (1 - (1 - pullRadius) * e, 1 - (1 - pullScale) * e, 1 - fade)
    }

    /// The body springing out (scale) and the heroes arriving (progress 0 -> 1): past the mark, back, settled.
    static let springKeys: [(value: Double, time: Double)] = [(1.06, 0.22), (0.98, 0.16), (1.012, 0.16), (1, 0.18)]
    static let arriveKeys: [(value: Double, time: Double)] = [(1.04, 0.34), (0.99, 0.16), (1, 0.18)]
    /// A hop (lift in pt of the centre figure): up, down, a little one.
    static let hopKeys: [(value: Double, time: Double)] = [(16, 0.17), (0, 0.15), (3, 0.1), (0, 0.1)]
    /// The first show: the whole orbit pops from `popFrom`.
    static let popFrom = 0.6
    static func pop(_ t: Double) -> (scale: Double, opacity: Double) {
        (track(springKeys, from: popFrom, t), max(0, min(1, t / 0.25)))
    }

    static func smooth(_ x: Double) -> Double {
        let c = max(0, min(1, x))
        return c * c * (3 - 2 * c)
    }

    // MARK: the scene, a pure function of the clock

    /// The body: its shape (cloud 0 ... circle 1), scale, and two paints mixed (a hero's tint, or "team": the cloud's
    /// gradient).
    struct Body: Equatable {
        var morph = 0.0
        var scale = 1.0
        var paintA = OrbitLayout.team
        var paintB = OrbitLayout.team
        var mix = 0.0
    }

    static func body(from: String, to: String, tau: Double) -> Body {
        let rest = Body(morph: to == team ? 0 : 1, scale: 1, paintA: to, paintB: to, mix: 0)
        if from == to { return rest }
        let d = moveAt(from: from)
        if tau < d {   // contracting
            let k = smooth(tau / d)
            return Body(morph: from == team ? 0 : 1, scale: 1 - (1 - squeeze) * k, paintA: from, paintB: to, mix: 0)
        }
        let u = tau - d
        var morph = 1.0
        if from == team { morph = smooth(u / 0.45) }
        if to == team { morph = 1 - smooth(u / 0.5) }
        let s0 = from == team ? 1.0 : squeeze
        return Body(morph: morph, scale: track(springKeys, from: s0, u), paintA: from, paintB: to, mix: smooth(u / 0.22))
    }

    /// A hero figure: where (pt), how big (a share of the centre figure), how clear, and how high it hops (pt).
    struct Figure: Equatable {
        var x = 0.0
        var y = 0.0
        var scale = 1.0
        var opacity = 1.0
        var lift = 0.0
    }

    /// Where a hero stands in a stage: the centre (its stage), its bump of the cloud, or merged into the centre.
    static func figureAt(_ hero: String, in stage: String) -> Figure {
        if stage == team {
            let c = cloudSpots[hero] ?? (x: 0, y: 0, scale: 0.5)
            return Figure(x: c.x, y: c.y, scale: c.scale, opacity: 1)
        }
        return stage == hero ? Figure() : Figure(x: 0, y: 0, scale: 0.7, opacity: 0)
    }

    static func figure(_ hero: String, from: String, to: String, tau: Double) -> Figure {
        let b = figureAt(hero, in: to)
        if from == to { return b }
        let a = figureAt(hero, in: from)
        let d = moveAt(from: from)
        if tau < d {   // the centre hero contracts with its circle
            var f = a
            f.scale *= 1 - (1 - squeeze) * smooth(tau / d)
            return f
        }
        let u = tau - d
        let p = track(arriveKeys, from: 0, u)
        let a0 = from == team ? 1.0 : squeeze   // everyone contracted with the circle
        var f = Figure()
        f.x = a.x + (b.x - a.x) * p
        f.y = a.y + (b.y - a.y) * p
        f.scale = a.scale * a0 + (b.scale - a.scale * a0) * p
        let fade = b.opacity < a.opacity ? 0.18 : 0.22
        f.opacity = a.opacity + (b.opacity - a.opacity) * smooth(u / fade)
        if to == hero { f.lift = track(hopKeys, from: 0, u - 0.25) }
        return f
    }

    /// A bubble: its point (pt), scale and opacity. The ring turns with the clock `t`; spat out or pulled in by `tau`.
    static func bubble(_ spot: OrbitSpot, from: String, to: String, tau: Double, t: Double) -> (x: Double, y: Double, scale: Double, opacity: Double) {
        let a = (spot.angle + ringAngle(t)) * Double.pi / 180
        var r = spot.radius, s = 1.0, o = 0.0
        if spot.world == to {
            if from == to {
                o = 1
            } else {
                let j = spit(tau - spitAt(from: from) - Double(spot.order) * inStagger, radius: spot.radius)
                r += j.dr; s = j.scale; o = j.opacity
            }
        } else if spot.world == from {
            let q = pull(tau - Double(spot.order) * outStagger)
            r *= q.k; s = q.scale; o = q.opacity
        }
        return (r * cos(a), r * sin(a), s, o)
    }

    // MARK: sets

    static let sets: [String: [OrbitSpot]] = [
        // Lia: everyday and general
        "lia": [
            OrbitSpot(id: "gmail", world: "lia", order: 0, angle: 198, size: 88, tuck: 12),
            OrbitSpot(id: "googlecalendar", world: "lia", order: 1, angle: 140, size: 60, tuck: 8),
            OrbitSpot(id: "stripe", world: "lia", order: 2, angle: 96, size: 46, tuck: 6),
            OrbitSpot(id: "slack", world: "lia", order: 3, angle: 32, size: 76, tuck: 12),
            OrbitSpot(id: "googledrive", world: "lia", order: 4, angle: 328, size: 64, tuck: 10),
            OrbitSpot(id: "notion", world: "lia", order: 5, angle: 268, size: 52, tuck: 6),
            OrbitSpot(id: "shopify", world: "lia", order: 6, angle: 232, size: 44, tuck: 4),
        ],
        // Dev: code (Claude and Claude Code's crab, OpenAI and Codex)
        "dev": [
            OrbitSpot(id: "github", world: "dev", order: 0, angle: 205, size: 86, tuck: 12),
            OrbitSpot(id: "claude", world: "dev", order: 1, angle: 148, size: 56, tuck: 8),
            OrbitSpot(id: "claudecode", world: "dev", order: 2, angle: 96, size: 70, tuck: 10),
            OrbitSpot(id: "codex", world: "dev", order: 3, angle: 40, size: 60, tuck: 8),
            OrbitSpot(id: "openai", world: "dev", order: 4, angle: 345, size: 54, tuck: 8),
            OrbitSpot(id: "vercel", world: "dev", order: 5, angle: 295, size: 44, tuck: 5),
            OrbitSpot(id: "cloudflare", world: "dev", order: 6, angle: 252, size: 52, tuck: 6),
        ],
        // Met: marketing (plain Meta: no Ads Manager mark)
        "met": [
            OrbitSpot(id: "meta", world: "met", order: 0, angle: 335, size: 88, tuck: 12),
            OrbitSpot(id: "instagram", world: "met", order: 1, angle: 195, size: 74, tuck: 10),
            OrbitSpot(id: "whatsapp", world: "met", order: 2, angle: 128, size: 58, tuck: 8),
            OrbitSpot(id: "facebook", world: "met", order: 3, angle: 52, size: 62, tuck: 8),
            OrbitSpot(id: "googleads", world: "met", order: 4, angle: 262, size: 50, tuck: 6),
        ],
        // Crea: creative (OpenAI again: ChatGPT is the same logo)
        "crea": [
            OrbitSpot(id: "openai.crea", world: "crea", order: 0, angle: 20, size: 84, tuck: 12, mark: "openai"),
            OrbitSpot(id: "figma", world: "crea", order: 1, angle: 205, size: 70, tuck: 10),
            OrbitSpot(id: "canva", world: "crea", order: 2, angle: 135, size: 60, tuck: 8),
            OrbitSpot(id: "higgsfield", world: "crea", order: 3, angle: 295, size: 54, tuck: 6),
            OrbitSpot(id: "midjourney", world: "crea", order: 4, angle: 82, size: 58, tuck: 8),
        ],
    ]

    /// Every bubble of every set, in hero order (the view keeps them all and shows one set).
    static var allSpots: [OrbitSpot] { heroes.flatMap { sets[$0] ?? [] } }

    /// Which bubbles answer a hover over Continue with Google.
    static let googleIds: Set<String> = ["googleads", "gmail", "googledrive", "googlecalendar"]

    // MARK: look

    /// A hero's circle, a shade of its own colour: (light top, light bottom, dark top, dark bottom). Lia is black, so
    /// hers is a cool graphite light enough for the black figure to read; soft in light, deeper in dark.
    static func tint(_ hero: String) -> (UInt32, UInt32, UInt32, UInt32) {
        switch hero {
        case "dev": return (0xFFD9D1, 0xFFC3B6, 0x6A2E26, 0x55241E)
        case "met": return (0xD8E7FF, 0xC2D8FF, 0x23417A, 0x1B3462)
        case "crea": return (0xFBD7EC, 0xF6C0DF, 0x6B2752, 0x561E42)
        default: return (0xCDD0E2, 0xB3B7CF, 0x5A5F80, 0x494D6B)
        }
    }

    /// A tiny breath (scale only, no translation): about 1%, 6...14 s, its own phase.
    static func breath(_ i: Int, t: Double) -> Double {
        let period = 6 + 8 * seed(i, 5)
        return 1 + 0.01 * sin(2 * Double.pi * (t / period + seed(i, 6)))
    }

    /// The same pseudo-random value for (i, k) on every run.
    static func seed(_ i: Int, _ k: Int) -> Double {
        let v = sin(Double(i) * 12.9898 + Double(k) * 78.233) * 43758.5453
        return v - floor(v)
    }

    /// How far a bubble follows the pointer (bigger is nearer, follows more): 1.5...4 pt; the centre 2.
    static func depth(size: Double) -> Double {
        1.5 + 2.5 * max(0, min(1, (size - 40) / 48))
    }
    static let centreDepth = 2.0
    static let maxDepth = 4.0
}
