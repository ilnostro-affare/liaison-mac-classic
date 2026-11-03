import Foundation

// Home's background is a living sky for the person's local time and weather. The server locates
// the person roughly by IP (GET /agents/sky); without an answer the Mac's clock alone picks the phase. The pure
// pieces: the report, the phase of the day, and the look (gradient stops, text colour, motion) for a phase + weather.

enum SkyCondition: String, CaseIterable, Equatable {
    case clear, cloudy, rain, snow, fog, storm
}

enum SkyPhase: String, CaseIterable, Equatable {
    case night, dawn, morning, day, golden, dusk
}

/// GET /agents/sky.
struct SkyReport: Equatable {
    var city: String?
    var tempC: Double?
    var code: Int?
    var isDay: Bool?
    var condition: SkyCondition
    var sunrise: Date?
    var sunset: Date?
    var tz: String?

    /// nil: not an answer (ok false, unreadable).
    static func parse(_ data: Data) -> SkyReport? {
        guard let o = JSONRead.object(data), JSONRead.bool(o, "ok") else { return nil }
        let cond = JSONRead.string(o, "condition").flatMap { SkyCondition(rawValue: $0.lowercased()) } ?? .clear
        func ms(_ k: String) -> Date? {
            guard let v = JSONRead.double(o, k), v > 0 else { return nil }
            return Date(timeIntervalSince1970: v / 1000)
        }
        var isDay: Bool? = nil
        if let v = o["is_day"] {
            if JSONRead.isBool(v) { isDay = JSONRead.bool(o, "is_day") } else if let n = JSONRead.int(o, "is_day") { isDay = n != 0 }
        }
        let city = JSONRead.string(o, "city")?.trimmingCharacters(in: .whitespacesAndNewlines)
        return SkyReport(city: (city?.isEmpty ?? true) ? nil : city, tempC: JSONRead.double(o, "temp_c"),
                         code: JSONRead.int(o, "code"), isDay: isDay, condition: cond,
                         sunrise: ms("sunrise"), sunset: ms("sunset"), tz: JSONRead.string(o, "tz"))
    }
}

/// An sRGB colour, 0...1.
struct SkyRGB: Equatable {
    var r: Double, g: Double, b: Double

    init(r: Double, g: Double, b: Double) { self.r = r; self.g = g; self.b = b }
    init(_ hex: UInt32) {
        r = Double((hex >> 16) & 0xFF) / 255
        g = Double((hex >> 8) & 0xFF) / 255
        b = Double(hex & 0xFF) / 255
    }

    /// `t` of the way from self to `o`.
    func mix(_ o: SkyRGB, _ t: Double) -> SkyRGB {
        let t = min(max(t, 0), 1)
        return SkyRGB(r: r + (o.r - r) * t, g: g + (o.g - g) * t, b: b + (o.b - b) * t)
    }

    /// ("the sunset looks cheap"): `t` of the way to `o` in OKLab, a perceptual space. A blue to orange
    /// mix in plain RGB passes through a muddy grey band; in OKLab it stays clean (the sky's gradients, the weather's
    /// grey over a warm hour, the clouds' light).
    func okMix(_ o: SkyRGB, _ t: Double) -> SkyRGB {
        let t = min(max(t, 0), 1)
        let a = oklab, b = o.oklab
        return SkyRGB(oklab: (a.L + (b.L - a.L) * t, a.a + (b.a - a.a) * t, a.b + (b.b - a.b) * t))
    }

    var oklab: (L: Double, a: Double, b: Double) {
        func lin(_ v: Double) -> Double { v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4) }
        let R = lin(r), G = lin(g), B = lin(b)
        let l = cbrt(0.4122214708 * R + 0.5363325363 * G + 0.0514459929 * B)
        let m = cbrt(0.2119034982 * R + 0.6806995451 * G + 0.1073969566 * B)
        let s = cbrt(0.0883024619 * R + 0.2817188376 * G + 0.6299787005 * B)
        return (0.2104542553 * l + 0.7936177850 * m - 0.0040720468 * s,
                1.9779984951 * l - 2.4285922050 * m + 0.4505937099 * s,
                0.0259040371 * l + 0.7827717662 * m - 0.8086757660 * s)
    }

    init(oklab o: (L: Double, a: Double, b: Double)) {
        let l = pow(o.L + 0.3963377774 * o.a + 0.2158037573 * o.b, 3)
        let m = pow(o.L - 0.1055613458 * o.a - 0.0638541728 * o.b, 3)
        let s = pow(o.L - 0.0894841775 * o.a - 1.2914855480 * o.b, 3)
        func enc(_ v: Double) -> Double {
            let c = v <= 0.0031308 ? 12.92 * v : 1.055 * pow(v, 1 / 2.4) - 0.055
            return min(max(c, 0), 1)
        }
        self.init(r: enc(4.0767416621 * l - 3.3077115913 * m + 0.2309699292 * s),
                  g: enc(-1.2684380046 * l + 2.6097574011 * m - 0.3413193965 * s),
                  b: enc(-0.0041960863 * l - 0.7034186147 * m + 1.7076147010 * s))
    }

    /// Relative luminance (WCAG).
    var luminance: Double {
        func lin(_ c: Double) -> Double { c <= 0.03928 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4) }
        return 0.2126 * lin(r) + 0.7152 * lin(g) + 0.0722 * lin(b)
    }

    var hex: UInt32 {
        func c(_ v: Double) -> UInt32 { UInt32((min(max(v, 0), 1) * 255).rounded()) }
        return c(r) << 16 | c(g) << 8 | c(b)
    }
}

struct SkyStop: Equatable {
    var color: SkyRGB
    var location: Double
}

/// What moves over the gradient (nothing with Reduce Motion).
enum SkyMotion: String, Equatable {
    case none, stars, clouds, rain, snow, fog, storm
}

/// A phase + weather as drawn: the gradient top to bottom, whether text over it is white, the sun/moon glow.
struct SkyLook: Equatable {
    var phase: SkyPhase
    var condition: SkyCondition
    /// Top to bottom.
    var stops: [SkyStop]
    /// The text over the sky's upper part is white (a dark sky).
    var lightText: Bool
    /// A soft glow (sun or moon) and where it sits (0...1 of the width, 0...1 of the sky's height); nil: none.
    var glow: SkyRGB?
    var glowX: Double
    var glowY: Double
    var motion: SkyMotion
    /// How strong the clouds are (0: none ... 1: overcast).
    var cloudCover: Double

    /// The colour at the top and in the middle of the sky (the reflection behind the tab strip).
    var top: SkyRGB { stops.first?.color ?? SkyRGB(0xFFFFFF) }
    var middle: SkyRGB { stops.count > 1 ? stops[stops.count / 2].color : top }
}

enum Sky {
    /// Without sunrise/sunset: 06:30 and 19:00 on the Mac's clock.
    static let defaultSunrise: TimeInterval = 6.5 * 3600
    static let defaultSunset: TimeInterval = 19 * 3600

    /// Seconds since local midnight of `d` in `tz`.
    static func secondsOfDay(_ d: Date, _ tz: TimeZone) -> TimeInterval {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = tz
        let c = cal.dateComponents([.hour, .minute, .second], from: d)
        let h: Int = c.hour ?? 0, m: Int = c.minute ?? 0, sec: Int = c.second ?? 0
        return TimeInterval(h * 3600 + m * 60 + sec)
    }

    /// The phase at `now`. Sunrise and sunset are compared by their time of day, so a report from yesterday still
    /// reads right; unusable ones (missing, sunset not after sunrise) fall back to the clock defaults.
    static func phase(now: Date, sunrise: Date?, sunset: Date?, timeZone: TimeZone = .current) -> SkyPhase {
        var rise = defaultSunrise, set = defaultSunset
        if let sunrise, let sunset {
            let r = secondsOfDay(sunrise, timeZone), s = secondsOfDay(sunset, timeZone)
            if s - r >= 3600 { rise = r; set = s }
        }
        let t = secondsOfDay(now, timeZone)
        let span = set - rise
        // Plain comparisons, not ranges: a short day would make a range's bounds cross (a trap).
        let morningEnd = rise + max(30 * 60, min(3 * 3600, span * 0.3))
        let goldenStart = max(morningEnd, set - min(90 * 60, span * 0.2))
        if t < rise - 45 * 60 { return .night }
        if t < rise + 30 * 60 { return .dawn }
        if t < morningEnd { return .morning }
        if t < goldenStart { return .day }
        if t < set + 10 * 60 { return .golden }
        if t < set + 55 * 60 { return .dusk }
        return .night
    }

    /// Clear-sky gradients, top to bottom.: the low-sun hours go through soft periwinkle, dusty rose and
    /// peach the way a real sky does, instead of jumping from blue to a flat orange band.
    static func clearStops(_ p: SkyPhase) -> [UInt32] {
        switch p {
        case .night: return [0x070B1C, 0x111A3D, 0x1D2756, 0x2C3668]
        case .dawn: return [0x24305F, 0x4F5590, 0x9479AB, 0xD995A0, 0xF4BE9F, 0xFADCC0]
        case .morning: return [0x4F8FE0, 0x7FB2EC, 0xB7D6F4, 0xE8F2FB]
        case .day: return [0x2F7BDB, 0x5C9FE8, 0x9CC7F2, 0xD3E8FA]
        case .golden: return [0x6C8CCB, 0x98A9D6, 0xC9B1C6, 0xEFBDA2, 0xF8D09A, 0xFCE6C2]
        case .dusk: return [0x121638, 0x262A5C, 0x4A3B78, 0x84507F, 0xC56E7C, 0xE89A84]
        }
    }

    /// How many stops the drawn gradient has: the hour's colours resampled in OKLab with a smoothstep between
    /// neighbours, so no stop reads as a band.
    static let gradientSamples = 16

    static func resampled(_ stops: [SkyStop], samples: Int = gradientSamples) -> [SkyStop] {
        guard stops.count > 1 else { return stops }
        let n = max(2, samples)
        return (0..<n).map { k in
            let u = Double(k) / Double(n - 1)
            var i = 0
            while i < stops.count - 2 && u > stops[i + 1].location { i += 1 }
            let a = stops[i], b = stops[i + 1]
            let f = min(max((u - a.location) / max(1e-6, b.location - a.location), 0), 1)
            return SkyStop(color: a.color.okMix(b.color, f * f * (3 - 2 * f)), location: u)
        }
    }

    /// What the weather pulls the clear sky toward, and how far (day / night tone of the same weather).
    static func weatherTint(_ c: SkyCondition, dark: Bool) -> (color: SkyRGB, amount: Double)? {
        switch c {
        case .clear: return nil
        case .cloudy: return (SkyRGB(dark ? 0x2A2F3A : 0xB3BAC6), dark ? 0.3 : 0.42)
        case .rain: return (SkyRGB(dark ? 0x1C232E : 0x66727F), dark ? 0.5 : 0.55)
        case .snow: return (SkyRGB(dark ? 0x3A4252 : 0xDCE2EA), dark ? 0.38 : 0.55)
        case .fog: return (SkyRGB(dark ? 0x3A3F47 : 0xCED2D7), dark ? 0.48 : 0.62)
        case .storm: return (SkyRGB(dark ? 0x10141B : 0x323947), dark ? 0.62 : 0.74)
        }
    }

    static func look(phase: SkyPhase, condition: SkyCondition) -> SkyLook {
        let dark = phase == .night || phase == .dusk
        let hexes = clearStops(phase)
        var stops = hexes.enumerated().map { i, h in
            SkyStop(color: SkyRGB(h), location: hexes.count > 1 ? Double(i) / Double(hexes.count - 1) : 0)
        }
        if let w = weatherTint(condition, dark: dark) {
            stops = stops.map { SkyStop(color: $0.color.okMix(w.color, w.amount), location: $0.location) }
        }
        // The text sits over the upper third: judge its colour by the first two stops.
        let upper = stops.count > 1 ? stops[0].color.mix(stops[1].color, 0.5) : (stops.first?.color ?? SkyRGB(0xFFFFFF))
        // 0.19: where white and our ink have the same contrast over the colour.
        let lightText = upper.luminance < 0.19
        stops = resampled(stops)

        var glow: SkyRGB? = nil
        var gx = 0.78, gy = 0.18
        let visible = condition == .clear || condition == .cloudy
        switch phase {
        case .night: glow = visible ? SkyRGB(0xDCE3FF) : nil; gx = 0.8; gy = 0.16
        case .dawn: glow = SkyRGB(0xFFD3A6); gx = 0.24; gy = 0.86
        case .morning: glow = visible ? SkyRGB(0xFFF3D6) : nil; gx = 0.2; gy = 0.28
        case .day: glow = visible ? SkyRGB(0xFFFBEA) : nil; gx = 0.72; gy = 0.06
        case .golden: glow = SkyRGB(0xFFD69A); gx = 0.8; gy = 0.78
        case .dusk: glow = SkyRGB(0xF4A88C); gx = 0.82; gy = 0.98
        }
        if condition == .storm || condition == .fog { glow = nil }

        let motion: SkyMotion
        switch condition {
        case .clear: motion = phase == .night ? .stars : .none
        case .cloudy: motion = .clouds
        case .rain: motion = .rain
        case .snow: motion = .snow
        case .fog: motion = .fog
        case .storm: motion = .storm
        }
        let cover: Double
        switch condition {
        case .clear: cover = phase == .night ? 0 : 0.15
        case .cloudy: cover = 0.7
        case .rain, .snow: cover = 0.8
        case .fog: cover = 0.5
        case .storm: cover = 0.95
        }
        return SkyLook(phase: phase, condition: condition, stops: stops, lightText: lightText, glow: glow,
                       glowX: gx, glowY: gy, motion: motion, cloudCover: cover)
    }

    /// The look at `now` from a report, or from the clock alone (nil report).
    static func look(now: Date, report: SkyReport?, timeZone: TimeZone = .current) -> SkyLook {
        let tz = report?.tz.flatMap { TimeZone(identifier: $0) } ?? timeZone
        let p = phase(now: now, sunrise: report?.sunrise, sunset: report?.sunset, timeZone: tz)
        return look(phase: p, condition: report?.condition ?? .clear)
    }

    /// The SF Symbol for the weather.
    static func symbol(_ c: SkyCondition, day: Bool) -> String {
        switch c {
        case .clear: return day ? "sun.max" : "moon.stars"
        case .cloudy: return day ? "cloud.sun" : "cloud.moon"
        case .rain: return "cloud.rain"
        case .snow: return "cloud.snow"
        case .fog: return "cloud.fog"
        case .storm: return "cloud.bolt.rain"
        }
    }

    /// The spoken weather word.
    static func word(_ c: SkyCondition) -> String {
        switch c {
        case .clear: return "Clear"
        case .cloudy: return "Cloudy"
        case .rain: return "Rain"
        case .snow: return "Snow"
        case .fog: return "Fog"
        case .storm: return "Storm"
        }
    }

    /// "21°" (Celsius) or "70°" (Fahrenheit); nil without a temperature.
    static func temperature(_ c: Double?, fahrenheit: Bool) -> String? {
        guard let c, c.isFinite else { return nil }
        let v = fahrenheit ? c * 9 / 5 + 32 : c
        var n = Int(v.rounded())
        if n == 0 { n = 0 }   // no "-0°"
        return "\(n)\u{00b0}"
    }

    /// "21° Milan" / "21°" / "Milan"; nil when the report has neither.
    static func weatherText(_ r: SkyReport, fahrenheit: Bool) -> String? {
        let parts = [temperature(r.tempC, fahrenheit: fahrenheit), r.city].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: " ")
    }

    /// Whether the report says day (its own flag, else the phase).
    static func isDay(_ r: SkyReport?, phase: SkyPhase) -> Bool {
        if let d = r?.isDay { return d }
        return phase != .night && phase != .dusk
    }
}

/// Deterministic particle positions (stars, raindrops, flakes): the same sky every launch, no random state.
enum SkyNoise {
    /// 0..<1 from an index and a salt.
    static func unit(_ i: Int, _ salt: Int) -> Double {
        var x = UInt64(bitPattern: Int64(i &* 73_856_093 ^ salt &* 19_349_663))
        x ^= x >> 33
        x = x &* 0xff51afd7ed558ccd
        x ^= x >> 33
        x = x &* 0xc4ceb9fe1a85ec53
        x ^= x >> 33
        return Double(x % 1_000_000) / 1_000_000
    }
}

// The glow's size and strength by the hour (the moon a small halo, a low sun broad), its falloff a
// smooth bell sampled into stops (no ring where a three-stop gradient bent), the clouds' light by the hour, and a rare
// shooting star on a clear night.
extension Sky {
    /// The glow's radius as a share of max(width, sky height), and its peak opacity.
    static func glowShape(_ look: SkyLook) -> (radius: Double, alpha: Double) {
        switch look.phase {
        case .night: return (0.16, 0.42)
        case .dawn, .golden, .dusk: return (0.6, 0.62)
        case .morning, .day: return (0.45, 0.5)
        }
    }

    /// The glow's opacity at 0...1 of its radius: a bell that reaches 0 exactly at the rim.
    static func glowStops(peak: Double, samples: Int = 10) -> [(location: Double, alpha: Double)] {
        let n = max(2, samples)
        return (0...n).map { k in
            let u = Double(k) / Double(n)
            return (u, peak * exp(-u * u * 4.2) * (1 - u))
        }
    }

    /// A puff's colour: at a low sun (dawn, golden hour, dusk) the tops are a cool lilac and the bases warm, lit from
    /// below; rain greys them. Otherwise white over a grey base (dim at night), as before.
    static func cloudColor(_ look: SkyLook, shade: Double) -> SkyRGB {
        let warm: (top: UInt32, base: UInt32)?
        switch look.phase {
        case .golden: warm = (0xF3E6E6, 0xFFC79A)
        case .dawn: warm = (0xEADFEA, 0xFFC3A8)
        case .dusk: warm = (0x7B7398, 0xF09A8C)
        default: warm = nil
        }
        if let w = warm, look.condition != .storm {
            let c = SkyRGB(w.top).okMix(SkyRGB(w.base), shade)
            return look.condition == .rain ? c.okMix(SkyRGB(0x8A93A3), 0.45) : c
        }
        let night = look.lightText
        return SkyRGB(night ? 0xC3C8D2 : 0xFFFFFF).okMix(SkyRGB(night ? 0x707788 : 0xB8C2D0), shade * 0.45)
    }

    /// A shooting star about every 34 s for 0.9 s on a clear night: its head, the tail's end and its opacity at `t`
    /// in a sky `size`; nil between them.
    static let meteorPeriod: Double = 34
    static func meteor(t: Double, width: Double, skyHeight: Double) -> (head: CGPoint, tail: CGPoint, alpha: Double)? {
        guard width > 0, skyHeight > 0, t >= 0 else { return nil }
        let k = Int(t / meteorPeriod)
        let f = (t - Double(k) * meteorPeriod) / 0.9
        guard f >= 0, f <= 1 else { return nil }
        let x0 = width * (0.25 + SkyNoise.unit(k, 51) * 0.6), y0 = skyHeight * (0.06 + SkyNoise.unit(k, 52) * 0.25)
        let x = x0 - f * 220, y = y0 + f * 90
        return (CGPoint(x: x, y: y), CGPoint(x: x + 140, y: y - 140 * 0.41), sin(Double.pi * f) * 0.8)
    }
}

// the glow carries on past the card into the window's ground and the toolbar.
extension Sky {
    /// The sky's height inside the card (HomeSky: 68 % of the card, never under 460 pt).
    static func skyHeight(cardHeight: Double) -> Double { max(460, cardHeight * 0.68) }

    /// Home's sun / moon glow as HomeSky draws it inside the card, in the window's coordinates: its centre and
    /// radius. The window's ground draws the same glow, so it carries on above the card into the toolbar.
    static func glow(_ look: SkyLook, card: CGRect) -> (center: CGPoint, radius: Double)? {
        guard look.glow != nil, card.width > 0, card.height > 0 else { return nil }
        let h = skyHeight(cardHeight: Double(card.height))
        let cx = Double(card.minX) + look.glowX * Double(card.width)
        let cy = Double(card.minY) + look.glowY * h
        return (CGPoint(x: cx, y: cy), max(Double(card.width), h) * glowShape(look).radius)
    }
}

// "when it's cloudy and the side messenger opens, the clouds quickly rearrange; make them
// softer, they are too geometric". The clouds were sized and wrapped by the view's width (`x = (seed * span + t * v)
// mod span`, span = width + 2 cloud widths), so any width change moved every cloud to an unrelated place in one frame.
// Now they live on a fixed track in points: the view is a window onto it, a narrower view only crops the right side,
// and nothing about which clouds exist, their size or their position depends on the width.

/// One soft puff of a cloud, in the cloud's own points (origin: the cloud box's top-left; puffs may spill out of it).
struct SkyPuff: Equatable {
    var dx: Double
    var dy: Double
    /// Horizontal and vertical radius.
    var rx: Double
    var ry: Double
    /// 0...1, multiplied into the cloud's opacity.
    var alpha: Double
    /// 0 (the top, lit) ... 1 (the base, a touch greyer).
    var shade: Double
}

/// A cloud as drawn this frame: the box's top-left in the view (points), its size, opacity and blur.
struct SkyCloud: Equatable {
    /// Which cloud (stable across frames and widths).
    var index: Int
    var x: Double
    var y: Double
    var width: Double
    var height: Double
    var alpha: Double
    var blur: Double
    var puffs: [SkyPuff]
}

enum SkyClouds {
    /// The track the clouds drift along (points). The view shows [0, width) of it, repeated past this length.
    static let track: Double = 2600
    /// How far a cloud's soft edge (puffs past the box, blur) can reach outside its box.
    static let spill: Double = 48

    /// How many clouds live on the track for a cover (0: none ... 1: overcast). Independent of the view.
    static func count(cover: Double) -> Int { cover <= 0 ? 0 : Int(3 + min(cover, 1) * 9) }

    /// The cloud box's width in points (200...460).
    static func width(_ i: Int) -> Double { 200 + SkyNoise.unit(i, 11) * 260 }

    static func height(_ i: Int) -> Double { width(i) * (0.26 + SkyNoise.unit(i, 12) * 0.08) }

    /// Drift, points per second.
    static func speed(_ i: Int) -> Double { 3 + SkyNoise.unit(i, 13) * 6 }

    /// The box's left edge on the track at `t`, in [-width, track - width).
    static func trackX(_ i: Int, t: Double) -> Double {
        let p = (SkyNoise.unit(i, 14) * track + t * speed(i)).truncatingRemainder(dividingBy: track)
        return (p < 0 ? p + track : p) - width(i)
    }

    /// The box's top as a fraction of the sky's height.
    static func topFraction(_ i: Int) -> Double { 0.04 + SkyNoise.unit(i, 15) * 0.40 }

    /// Blur radius: 6 for the smallest cloud ... 14 for the largest.
    static func blur(_ i: Int) -> Double { 6 + (width(i) - 200) / 260 * 8 }

    /// The cloud's opacity (each cloud a little different; dim at night).
    static func alpha(_ i: Int, cover: Double, night: Bool) -> Double {
        (night ? 0.16 : 0.55) * (0.4 + min(max(cover, 0), 1) * 0.6) * (0.75 + SkyNoise.unit(i, 16) * 0.25)
    }

    /// The puffs: a flat, slightly grey base of two wide ellipses, and 5...8 round puffs of varied size along it,
    /// taller in the middle, each nudged so no two clouds are alike and none is symmetric.
    static func puffs(_ i: Int) -> [SkyPuff] {
        let w = width(i), h = height(i)
        var out: [SkyPuff] = [
            SkyPuff(dx: w * (0.36 + SkyNoise.unit(i, 17) * 0.06), dy: h * 0.78, rx: w * 0.34, ry: h * 0.24, alpha: 0.85, shade: 1),
            SkyPuff(dx: w * (0.6 + SkyNoise.unit(i, 18) * 0.06), dy: h * 0.8, rx: w * 0.31, ry: h * 0.22, alpha: 0.8, shade: 1),
        ]
        let m = 5 + Int(SkyNoise.unit(i, 19) * 4)
        for j in 0..<m {
            let s = i &* 16 &+ j
            let fx = (Double(j) + 0.5) / Double(m) + (SkyNoise.unit(s, 20) - 0.5) * 0.5 / Double(m)
            let bump = sin(Double.pi * min(max(fx, 0), 1))
            let r = w * (0.07 + 0.10 * bump + SkyNoise.unit(s, 21) * 0.04)
            let cy = h * 0.72 - r * (0.35 + 0.4 * bump) - SkyNoise.unit(s, 22) * h * 0.08
            out.append(SkyPuff(dx: w * (0.1 + 0.8 * fx), dy: cy, rx: r, ry: r * (0.8 + SkyNoise.unit(s, 23) * 0.25),
                               alpha: 0.75 + SkyNoise.unit(s, 24) * 0.25, shade: min(max(cy / h, 0), 1)))
        }
        return out
    }

    /// The clouds that touch a view `viewWidth` wide over a sky `skyHeight` tall at `t`. A cloud's place depends on
    /// its index and `t` only: changing the width adds or drops clouds at the right edge and moves none.
    static func layout(cover: Double, t: Double, viewWidth: Double, skyHeight: Double, night: Bool) -> [SkyCloud] {
        let n = count(cover: cover)
        guard n > 0, viewWidth > 0, skyHeight > 0 else { return [] }
        var out: [SkyCloud] = []
        for i in 0..<n {
            let w = width(i)
            var x = trackX(i, t: t)
            let y = skyHeight * topFraction(i)
            let ps = puffs(i)
            // The same cloud again every `track` points, so a view wider than the track is covered and the wrap
            // (x jumping back by `track`) happens where the next copy already stands.
            while x - spill < viewWidth {
                if x + w + spill > 0 {
                    out.append(SkyCloud(index: i, x: x, y: y, width: w, height: height(i),
                                        alpha: alpha(i, cover: cover, night: night), blur: blur(i), puffs: ps))
                }
                x += track
            }
        }
        return out
    }
}

// "the sky's lower edge is too abrupt". The gradient now keeps its last colour past the
// sky's own height and fades out over a much longer run, on a smooth (cosine) curve sampled finely: the slope is zero
// where the fade starts and where it ends, so neither end reads as a band.
extension Sky {
    /// How far down the sky's fade reaches, from the card's top: 1.6 x the sky's height.
    static let fadeReach: Double = 1.6

    static func fadeHeight(cardHeight: Double) -> Double { skyHeight(cardHeight: cardHeight) * fadeReach }

    /// Where the fade starts, as a fraction of `fadeHeight` (0.55 of the sky's height, as before).
    static let fadeHold: Double = 0.55 / fadeReach

    /// The fade's opacity over 0...1 of `fadeHeight`: 1 down to `hold`, then a cosine ease to 0 at 1, in `samples`
    /// steps. Locations rise, opacities never rise.
    static func fadeStops(hold: Double = fadeHold, samples: Int = 14) -> [(location: Double, alpha: Double)] {
        let h = min(max(hold, 0), 0.98)
        let n = max(2, samples)
        var out: [(location: Double, alpha: Double)] = [(0, 1)]
        for i in 0...n {
            let u = Double(i) / Double(n)
            out.append((h + (1 - h) * u, 0.5 * (1 + cos(Double.pi * u))))
        }
        return out
    }
}

extension SkyLook {
    /// The gradient's stops squeezed into the top `fraction` of a taller frame (the last colour then holds below).
    func scaledStops(_ fraction: Double) -> [SkyStop] {
        let k = min(max(fraction, 0), 1)
        return stops.map { SkyStop(color: $0.color, location: $0.location * k) }
    }
}

// (item 6): "on dark weather the CPL, the commits and 'Show more' are practically invisible; make
// them white too; on the white Home keep as is". Text drawn over the sky on Home takes these fixed pairs, picked by
// Home's own tone (SkyLook.homeDark), never by the app's theme: on a dark sky every line is white, the secondary ones
// a little less (never a mid grey, which disappears into a dusk or storm sky). The light values are the old ones.
enum HomeInkTone {
    enum Role: CaseIterable { case ink, text2, text3, link, warn, track }

    /// The colour and its opacity for a role on a dark (`dark`) or light Home.
    static func value(_ r: Role, dark: Bool) -> (hex: UInt32, alpha: Double) {
        switch r {
        case .ink: return dark ? (0xFFFFFF, 1) : (0x0E1014, 1)
        case .text2: return dark ? (0xFFFFFF, 0.88) : (0x4A505A, 1)
        case .text3: return dark ? (0xFFFFFF, 0.74) : (0x8A8F98, 1)
        // Our blue, lightened for a dark sky (the plain one sinks into a blue night).
        case .link: return dark ? (0xC3CEFF, 1) : (0x3B5BFD, 1)
        case .warn: return dark ? (0xFFD08A, 1) : (0x8A4B05, 1)
        // An empty week in the contributions strip.
        case .track: return dark ? (0xFFFFFF, 0.18) : (0x0E1014, 0.08)
        }
    }

    /// The colour as seen over `ground` (its opacity blended in).
    static func over(_ r: Role, dark: Bool, ground: SkyRGB) -> SkyRGB {
        let v = value(r, dark: dark)
        return ground.mix(SkyRGB(v.hex), v.alpha)
    }

    /// WCAG contrast ratio of two colours.
    static func contrast(_ a: SkyRGB, _ b: SkyRGB) -> Double {
        let la = a.luminance, lb = b.luminance
        return (max(la, lb) + 0.05) / (min(la, lb) + 0.05)
    }
}
