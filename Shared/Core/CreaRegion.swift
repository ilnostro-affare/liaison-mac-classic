import Foundation

// Edit area: the person clicks on a thing in a Crea picture (one person in a group photo) and asks
// for a change to only that. The Mac cuts the area out with a margin, sends the cut to the image-edit call, scales
// the answer back and blends it in with a soft edge over the margin, so every pixel outside the cut is the original's,
// whichever model made the picture. This file is the pure part: the box, the cut, the sizes, the mask, the request.
// The drawing and CoreImage are in App/Workspace/CreaRegionEdit.swift.

/// A box in the picture's pixels (x to the right, y down, from the top-left corner).
struct CreaArea: Equatable, Codable {
    var x: Double
    var y: Double
    var w: Double
    var h: Double

    var maxX: Double { x + w }
    var maxY: Double { y + h }
    var midX: Double { x + w / 2 }
    var midY: Double { y + h / 2 }

    func contains(_ px: Double, _ py: Double) -> Bool { px >= x && px <= maxX && py >= y && py <= maxY }
}

/// A box in whole pixels.
struct CreaPixelRect: Equatable {
    var x: Int
    var y: Int
    var w: Int
    var h: Int
}

enum CreaRegion {
    /// The box a click makes: this share of the picture's shorter side.
    static let clickFraction = 0.30
    /// The margin cut around the box on each side, as a share of the box's side.
    static let padding = 0.25
    /// The cut is sent at most this long on its long side.
    static let maxSend = 1024
    /// Below this a drag is a click (view points).
    static let clickSlop = 4.0

    /// The smallest box side: 4% of the shorter side, at least 12 pixels (never more than the picture).
    static func minSide(w: Double, h: Double) -> Double {
        min(min(w, h), max(12, 0.04 * min(w, h)))
    }

    /// The box at most the picture's size and moved inside it.
    static func clamp(_ b: CreaArea, w: Double, h: Double) -> CreaArea {
        let bw = min(max(0, b.w), w), bh = min(max(0, b.h), h)
        let x = min(max(0, b.x), w - bw), y = min(max(0, b.y), h - bh)
        return CreaArea(x: x, y: y, w: bw, h: bh)
    }

    /// A click: a square of `fraction` of the shorter side centred on the click, moved inside the picture.
    static func around(x px: Double, y py: Double, w: Double, h: Double, fraction: Double = clickFraction) -> CreaArea {
        let s = max(minSide(w: w, h: h), min(w, h) * fraction)
        return clamp(CreaArea(x: px - s / 2, y: py - s / 2, w: s, h: s), w: w, h: h)
    }

    /// A drag from one point to another: the box between them, cut to the picture; nil when it is too small to edit.
    static func drawn(from a: (x: Double, y: Double), to b: (x: Double, y: Double), w: Double, h: Double) -> CreaArea? {
        let x0 = max(0, min(a.x, b.x)), y0 = max(0, min(a.y, b.y))
        let x1 = min(w, max(a.x, b.x)), y1 = min(h, max(a.y, b.y))
        let m = minSide(w: w, h: h)
        guard x1 - x0 >= m, y1 - y0 >= m else { return nil }
        return CreaArea(x: x0, y: y0, w: x1 - x0, h: y1 - y0)
    }

    enum Corner: CaseIterable, Equatable { case topLeft, topRight, bottomLeft, bottomRight }

    static func point(_ c: Corner, of b: CreaArea) -> (x: Double, y: Double) {
        switch c {
        case .topLeft: return (b.x, b.y)
        case .topRight: return (b.maxX, b.y)
        case .bottomLeft: return (b.x, b.maxY)
        case .bottomRight: return (b.maxX, b.maxY)
        }
    }

    /// The corner within `radius` of a point (the nearest), if any.
    static func corner(near px: Double, _ py: Double, of b: CreaArea, radius: Double) -> Corner? {
        var best: (Corner, Double)? = nil
        for c in Corner.allCases {
            let p = point(c, of: b)
            let d = hypot(p.x - px, p.y - py)
            if d <= radius, d < (best?.1 ?? .infinity) { best = (c, d) }
        }
        return best?.0
    }

    /// A corner dragged to a point: the opposite corner stays, the box keeps the minimum side and stays inside.
    static func resized(_ b: CreaArea, corner c: Corner, to px: Double, _ py: Double, w: Double, h: Double) -> CreaArea {
        let m = minSide(w: w, h: h)
        let qx = min(max(0, px), w), qy = min(max(0, py), h)
        var x0 = b.x, y0 = b.y, x1 = b.maxX, y1 = b.maxY
        switch c {
        case .topLeft: x0 = min(qx, x1 - m); y0 = min(qy, y1 - m)
        case .topRight: x1 = max(qx, x0 + m); y0 = min(qy, y1 - m)
        case .bottomLeft: x0 = min(qx, x1 - m); y1 = max(qy, y0 + m)
        case .bottomRight: x1 = max(qx, x0 + m); y1 = max(qy, y0 + m)
        }
        return clamp(CreaArea(x: x0, y: y0, w: x1 - x0, h: y1 - y0), w: w, h: h)
    }

    /// The box moved by a drag, kept inside the picture.
    static func moved(_ b: CreaArea, dx: Double, dy: Double, w: Double, h: Double) -> CreaArea {
        clamp(CreaArea(x: b.x + dx, y: b.y + dy, w: b.w, h: b.h), w: w, h: h)
    }

    /// The box in whole pixels: its edges rounded outwards, inside a `w` x `h` picture, at least 1 x 1.
    static func pixels(_ b: CreaArea, w: Int, h: Int) -> CreaPixelRect {
        let x0 = max(0, min(w - 1, Int(floor(b.x)))), y0 = max(0, min(h - 1, Int(floor(b.y))))
        let x1 = max(x0 + 1, min(w, Int(ceil(b.maxX)))), y1 = max(y0 + 1, min(h, Int(ceil(b.maxY))))
        return CreaPixelRect(x: x0, y: y0, w: x1 - x0, h: y1 - y0)
    }

    /// The cut sent to the model: the box with `pad` of its side added on every side, cut to the picture.
    static func crop(_ inner: CreaPixelRect, w: Int, h: Int, pad: Double = padding) -> CreaPixelRect {
        let px = Int((Double(inner.w) * pad).rounded()), py = Int((Double(inner.h) * pad).rounded())
        let x0 = max(0, inner.x - px), y0 = max(0, inner.y - py)
        let x1 = min(w, inner.x + inner.w + px), y1 = min(h, inner.y + inner.h + py)
        return CreaPixelRect(x: x0, y: y0, w: max(1, x1 - x0), h: max(1, y1 - y0))
    }

    // MARK: - the cut in the model's shape (the pasted area did not line up with the photo around it)
    //
    // The photo model draws at a fixed set of ratios. Sent a cut of another ratio with no aspect_ratio, it chose its own
    // frame (often re-framing or extending the scene), and the answer was then STRETCHED back to the cut: the content
    // slid inside the box (a table from outside the cut appeared at its left edge). Now the cut is widened (or, at the
    // picture's edge, narrowed - never into the box) to the nearest of the model's ratios, that ratio is sent, and an
    // answer that still comes back in another shape is centre-cropped to the cut's shape, never stretched.

    /// The ratios the server's photo model draws at (lia-crea.js CREA_REGION_ASPECTS).
    static let modelRatios: [(name: String, value: Double)] = [
        ("1:1", 1), ("2:3", 2.0 / 3), ("3:2", 1.5), ("3:4", 0.75), ("4:3", 4.0 / 3), ("4:5", 0.8), ("5:4", 1.25), ("9:16", 9.0 / 16), ("16:9", 16.0 / 9)
    ]

    /// The model ratio nearest to w x h (by the log of the ratio, so 2:1 and 1:2 are as far from 1:1).
    static func modelRatio(w: Int, h: Int) -> (name: String, value: Double) {
        guard w > 0, h > 0 else { return modelRatios[0] }
        let r = log(Double(w) / Double(h))
        return modelRatios.min { abs(log($0.value) - r) < abs(log($1.value) - r) } ?? modelRatios[0]
    }

    /// The cut reshaped to `ratio`: the short side grown around the cut's centre; where the picture ends, the long side
    /// shortened instead. It stays inside the picture and always holds the box; when no such shape exists the cut is
    /// returned as it was.
    static func conform(_ crop: CreaPixelRect, inner: CreaPixelRect, ratio: Double, w: Int, h: Int) -> CreaPixelRect {
        guard ratio > 0, w > 0, h > 0, crop.w > 0, crop.h > 0 else { return crop }
        var cw = Double(crop.w), ch = Double(crop.h)
        if cw / ch < ratio {
            cw = ch * ratio
            if cw > Double(w) { cw = Double(w); ch = cw / ratio }
        } else {
            ch = cw / ratio
            if ch > Double(h) { ch = Double(h); cw = ch * ratio }
        }
        let iw = min(w, Int(cw.rounded())), ih = min(h, Int(ch.rounded()))
        guard iw >= inner.w, ih >= inner.h, iw > 0, ih > 0 else { return crop }
        func place(_ centre: Double, _ size: Int, _ total: Int, _ lo: Int, _ len: Int) -> Int {
            var a = Int((centre - Double(size) / 2).rounded())
            a = min(max(0, a), total - size)
            if a > lo { a = lo }
            if a + size < lo + len { a = lo + len - size }
            return min(max(0, a), total - size)
        }
        let x = place(Double(crop.x) + Double(crop.w) / 2, iw, w, inner.x, inner.w)
        let y = place(Double(crop.y) + Double(crop.h) / 2, ih, h, inner.y, inner.h)
        return CreaPixelRect(x: x, y: y, w: iw, h: ih)
    }

    /// How much the answer's shape may differ from the cut's before it is cropped rather than scaled: the model's
    /// sizes at 1K are its ratios only roughly (4:3 is 1184 x 864, 2.8% wide), and that much is scaled.
    static let shapeTolerance = 0.04

    /// The centred part of a `w` x `h` answer that has the cut's shape (`toW` x `toH`); nil when the shapes already
    /// agree within `tolerance` (then the whole answer is scaled to the cut).
    static func matchShape(w: Int, h: Int, toW: Int, toH: Int, tolerance: Double = shapeTolerance) -> CreaPixelRect? {
        guard w > 0, h > 0, toW > 0, toH > 0 else { return nil }
        let have = Double(w) / Double(h), want = Double(toW) / Double(toH)
        if abs(have - want) / want <= tolerance { return nil }
        if have > want {
            let cw = max(1, min(w, Int((Double(h) * want).rounded())))
            return CreaPixelRect(x: (w - cw) / 2, y: 0, w: cw, h: h)
        }
        let ch = max(1, min(h, Int((Double(w) / want).rounded())))
        return CreaPixelRect(x: 0, y: (h - ch) / 2, w: w, h: ch)
    }

    // MARK: - the box on screen and in the picture's pixels

    /// How the picture is drawn in its view: `fill` (aspect-fill, centred: the board's plain picture, which a node box of
    /// another shape crops) or stretched to the view (the layered picture). view = pixel * scale + offset.
    struct ViewMap: Equatable {
        var sx: Double
        var sy: Double
        var ox: Double
        var oy: Double

        init(view: (w: Double, h: Double), pixels: (w: Double, h: Double), fill: Bool) {
            guard view.w > 0, view.h > 0, pixels.w > 0, pixels.h > 0 else { sx = 1; sy = 1; ox = 0; oy = 0; return }
            if fill {
                let s = max(view.w / pixels.w, view.h / pixels.h)
                sx = s; sy = s
                ox = (view.w - pixels.w * s) / 2
                oy = (view.h - pixels.h * s) / 2
            } else {
                sx = view.w / pixels.w; sy = view.h / pixels.h; ox = 0; oy = 0
            }
        }

        /// A view point in the picture's pixels.
        func pixel(_ x: Double, _ y: Double) -> (x: Double, y: Double) { ((x - ox) / sx, (y - oy) / sy) }
        /// A view distance (a drag) in pixels.
        func pixelDelta(_ dx: Double, _ dy: Double) -> (x: Double, y: Double) { (dx / sx, dy / sy) }
        /// A box in pixels on the view.
        func view(_ b: CreaArea) -> (x: Double, y: Double, w: Double, h: Double) { (b.x * sx + ox, b.y * sy + oy, b.w * sx, b.h * sy) }
        /// Pixels per view point (the larger of the two axes), for hit radii.
        var pixelsPerPoint: Double { 1 / max(1e-9, min(sx, sy)) }
    }

    /// The size the cut is sent at: its long side at most `maxSide` (never enlarged), and the factor applied.
    static func sendSize(w: Int, h: Int, maxSide: Int = maxSend) -> (w: Int, h: Int, scale: Double) {
        guard w > 0, h > 0 else { return (1, 1, 1) }
        let long = max(w, h)
        guard long > maxSide else { return (w, h, 1) }
        let s = Double(maxSide) / Double(long)
        return (max(1, Int((Double(w) * s).rounded())), max(1, Int((Double(h) * s).rounded())), s)
    }

    /// The soft edge: the box inside the cut, and the width of the margin on each side (0 where the cut met the
    /// picture's edge: there the box is replaced right to the edge, nothing lies beyond it).
    struct Feather: Equatable {
        let w: Int
        let h: Int
        let left: Int
        let top: Int
        let right: Int
        let bottom: Int
    }

    static func feather(inner: CreaPixelRect, crop: CreaPixelRect) -> Feather {
        let l = max(0, inner.x - crop.x), t = max(0, inner.y - crop.y)
        let r = max(0, (crop.x + crop.w) - (inner.x + inner.w)), b = max(0, (crop.y + crop.h) - (inner.y + inner.h))
        return Feather(w: crop.w, h: crop.h, left: l, top: t, right: r, bottom: b)
    }

    /// 0 at the cut's edge, 1 where the box starts: smoothstep over the margin.
    static func ramp(_ d: Double, band: Double) -> Double {
        guard band > 0 else { return 1 }
        let t = min(1, max(0, d / band))
        return t * t * (3 - 2 * t)
    }

    /// How much of the edited cut one column (`axis` x) or row takes: 1 in the box, falling to 0 over the margin.
    static func weight(_ i: Int, size: Int, lead: Int, trail: Int) -> Double {
        let c = Double(i) + 0.5
        if c < Double(lead) { return ramp(c, band: Double(lead)) }
        if c > Double(size - trail) { return ramp(Double(size) - c, band: Double(trail)) }
        return 1
    }

    /// The edited cut's share at one pixel of the cut (column weight x row weight).
    static func alpha(x: Int, y: Int, _ f: Feather) -> Double {
        weight(x, size: f.w, lead: f.left, trail: f.right) * weight(y, size: f.h, lead: f.top, trail: f.bottom)
    }

    /// The mask as 8-bit grey, row by row from the top, `f.w` x `f.h` (255: the edited cut, 0: the original).
    static func mask(_ f: Feather) -> [UInt8] {
        guard f.w > 0, f.h > 0 else { return [] }
        let cols = (0..<f.w).map { weight($0, size: f.w, lead: f.left, trail: f.right) }
        let rows = (0..<f.h).map { weight($0, size: f.h, lead: f.top, trail: f.bottom) }
        var out = [UInt8](repeating: 0, count: f.w * f.h)
        for y in 0..<f.h {
            let ry = rows[y], base = y * f.w
            for x in 0..<f.w { out[base + x] = UInt8(max(0, min(255, (cols[x] * ry * 255).rounded()))) }
        }
        return out
    }

    // MARK: the request

    /// The instruction the image model gets with the cut.
    static func prompt(_ instruction: String) -> String {
        let change = CreaImages.oneLine(instruction).prefix(800)
        return "This image is a cut-out part of a larger picture. Change only this: \(change). "
            + "Keep everything else exactly as it is: the framing, the composition, the scale, the lighting, the colours, "
            + "the faces and identities of the people, the background and every edge. Do not zoom, crop, add borders or "
            + "change the aspect ratio; return the whole cut-out at the same framing."
    }

    /// POST /agents/crea/edit.
    static let route = "/agents/crea/edit"

    static func body(profile: String, png: Data, instruction: String, aspect: String? = nil) -> JSONObject {
        var b: JSONObject = ["profile": profile, "image": png.base64EncodedString(), "prompt": prompt(instruction), "mode": "region"]
        if let aspect, modelRatios.contains(where: { $0.name == aspect }) { b["aspect"] = aspect }   // The cut's shape
        return b
    }

    /// The answer: the edited cut as a link or as base64, what it cost, or the server's words when it failed.
    struct Reply: Equatable {
        var imageURL: String?
        var imageB64: String?
        var cost: Double?
        var error: String?

        var ok: Bool { error == nil && (imageURL != nil || imageB64 != nil) }

        /// The bytes of a base64 answer (a `data:` prefix is dropped).
        var imageData: Data? {
            guard var s = imageB64 else { return nil }
            if s.hasPrefix("data:"), let comma = s.firstIndex(of: ",") { s = String(s[s.index(after: comma)...]) }
            return Data(base64Encoded: s, options: .ignoreUnknownCharacters)
        }

        init(imageURL: String? = nil, imageB64: String? = nil, cost: Double? = nil, error: String? = nil) {
            self.imageURL = imageURL; self.imageB64 = imageB64; self.cost = cost; self.error = error
        }

        static func parse(_ o: JSONObject, status: Int = 200) -> Reply {
            let url = (JSONRead.string(o, "image_url") ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let b64 = (JSONRead.string(o, "image_b64") ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let cost = (o["cost"] as? NSNumber)?.doubleValue ?? (o["cost"] as? String).flatMap(Double.init)
            let words = (JSONRead.string(o, "error") ?? JSONRead.string(o, "message") ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let okFlag = (o["ok"] as? Bool) ?? true
            if !(200..<300).contains(status) || !okFlag || (url.isEmpty && b64.isEmpty) {
                if !words.isEmpty { return Reply(cost: cost, error: words) }
                if status == 404 || status == 405 { return Reply(cost: cost, error: "Editing an area is not available on the server yet.") }
                return Reply(cost: cost, error: "The area could not be changed.")
            }
            return Reply(imageURL: url.isEmpty ? nil : url, imageB64: b64.isEmpty ? nil : b64, cost: cost)
        }
    }
}

/// The versions of one picture made by area edits, oldest first (the picture itself is version 0 and not listed).
struct CreaVersions: Equatable {
    static let cap = 20
    private(set) var names: [String] = []

    var canUndo: Bool { !names.isEmpty }
    var current: String? { names.last }

    /// The next version's file name ("v1.png", "v2.png", ...: one more than the highest kept).
    var nextName: String {
        let top = names.compactMap { n -> Int? in
            guard n.hasPrefix("v"), n.hasSuffix(".png") else { return nil }
            return Int(n.dropFirst().dropLast(4))
        }.max() ?? 0
        return "v\(top + 1).png"
    }

    /// Versions found on disk, in their order (v1, v2, ... v10).
    init(files: [String] = []) {
        names = files.compactMap { n -> (Int, String)? in
            guard n.hasPrefix("v"), n.hasSuffix(".png"), let k = Int(n.dropFirst().dropLast(4)), k > 0 else { return nil }
            return (k, n)
        }.sorted { $0.0 < $1.0 }.map(\.1)
    }

    /// A new version; the oldest beyond the cap is returned so its file can go.
    @discardableResult
    mutating func push(_ name: String) -> [String] {
        names.append(name)
        guard names.count > Self.cap else { return [] }
        let gone = Array(names.prefix(names.count - Self.cap))
        names.removeFirst(gone.count)
        return gone
    }

    /// Undo: the newest version goes (its file too); nil when only the picture itself is left.
    mutating func undo() -> String? { names.popLast() }
}
