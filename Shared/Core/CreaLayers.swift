import Foundation

// Crea's creatives as movable layers (server; docs/CREA-LAYERS.md). The picture is made
// without any text; the block's `layers` are the words (brand, headline, sub-text, call to action) the Mac draws over
// it. Everything here is pure geometry in fractions of the picture: x / y of a layer's top-left corner over the
// picture's width / height, a scale over the kind's base size (font sizes are fractions of the picture's SHORTER
// side, so one layout fits 1:1, 4:5, 9:16 and 16:9). What a layer measures (its box) comes from the renderer
// (App/Workspace/CreaLayersArt.swift); `estimate` stands in where nothing can measure (Linux, tests).

/// The type a layer is set in (picked per layer; Crea names one too). The raw values are the
/// server's names (`font`); `read` takes a few other spellings.
enum CreaFont: String, Codable, CaseIterable, Equatable {
    case sans, serif, rounded, mono, condensed

    /// The name in the font menu.
    var title: String {
        switch self {
        case .sans: return "Sans"
        case .serif: return "Serif"
        case .rounded: return "Rounded"
        case .mono: return "Mono"
        case .condensed: return "Condensed"
        }
    }

    /// A block's `font`, read tolerantly ("sans-serif", "SF Mono", "Helvetica" ...); nil when it names none.
    static func read(_ v: String?) -> CreaFont? {
        let s = (v ?? "").lowercased().filter { $0.isLetter }
        guard !s.isEmpty else { return nil }
        if let f = CreaFont(rawValue: s) { return f }
        switch s {
        case "system", "sansserif", "default", "sf", "sfpro", "helvetica", "helveticaneue", "inter", "arial", "avenir", "avenirnext": return .sans
        case "newyork", "times", "timesnewroman", "garamond", "georgia", "didot", "playfair", "playfairdisplay": return .serif
        case "sfrounded", "round", "nunito": return .rounded
        case "monospace", "monospaced", "sfmono", "code", "menlo", "courier": return .mono
        case "narrow", "compressed", "sfcondensed", "impact", "oswald", "bebas", "bebasneue": return .condensed
        default: return allCases.first { s.hasPrefix($0.rawValue) }
        }
    }
}

/// How a layer's lines line up (`align`).
enum CreaAlign: String, Codable, CaseIterable, Equatable {
    case left, center, right

    static func read(_ v: String?) -> CreaAlign? {
        switch (v ?? "").trimmingCharacters(in: .whitespaces).lowercased() {
        case "left", "leading", "start": return .left
        case "center", "centre", "middle": return .center
        case "right", "trailing", "end": return .right
        default: return nil
        }
    }
}

/// One layer of a creative: words with their colour, an optional plate behind them (the CTA's button is its plate),
/// the type, and where Crea placed it (nil: the Mac places it).
struct CreaLayer: Equatable, Identifiable, Codable {
    enum Kind: String, Codable, CaseIterable { case brand, headline, sub, body, cta }

    let id: String
    let kind: Kind
    var text: String
    /// The words' colour, "#RRGGBB".
    var color: String
    /// The plate's colour (the CTA's button), "#RRGGBB"; nil: the colour that reads under the words.
    var bg: String?
    /// The plate is drawn (always on the CTA unless the block turns it off; the other kinds only when asked).
    var plate: Bool
    /// The plate's opacity 0...1.
    var plateOpacity: Double
    var font: CreaFont
    var align: CreaAlign
    /// Crea's placement: the top-left corner in fractions of the picture, the wrap width (a fraction of the width)
    /// and the size over the kind's base. Nil: the layout's own (or the defaults).
    var x: Double?
    var y: Double?
    var w: Double?
    var scale: Double?
    /// Crea set a style field of its own (font, align, plate, w): the person's older style gives way.
    var styledByCrea: Bool

    init(id: String, kind: Kind, text: String, color: String, bg: String? = nil, plate: Bool? = nil, plateOpacity: Double = 1,
         font: CreaFont = .sans, align: CreaAlign = .left, x: Double? = nil, y: Double? = nil, w: Double? = nil,
         scale: Double? = nil, styledByCrea: Bool = false) {
        self.id = id
        self.kind = kind
        self.text = text
        self.color = color
        self.bg = bg
        self.plate = plate ?? (kind == .cta)
        self.plateOpacity = min(1, max(0, plateOpacity))
        self.font = font
        self.align = align
        self.x = x
        self.y = y
        self.w = w
        self.scale = scale
        self.styledByCrea = styledByCrea
    }

    /// Crea placed this layer (x / y / scale).
    var isPlaced: Bool { x != nil || y != nil || scale != nil }

    /// The plate's colour as drawn: its own, else dark under light words and light under dark ones.
    var plateColor: String { bg ?? (CreaColor.luminance(color) > 0.45 ? "#111111" : "#FFFFFF") }

    /// Everything the block says about this layer: a person's change made against another signature is stale (Crea
    /// changed the layer since, and Crea's word wins).
    var signature: String {
        func n(_ v: Double?) -> String { v.map { String(format: "%.4f", $0) } ?? "-" }
        return [text, color, bg ?? "-", plate ? "1" : "0", n(plateOpacity), font.rawValue, align.rawValue,
                n(x), n(y), n(w), n(scale)].joined(separator: "|")
    }

    /// A fraction 0...1, or a percentage 1...100 (as a model may write it); anything else nil.
    static func fraction(_ v: Double?) -> Double? {
        guard let v, v.isFinite, v >= 0 else { return nil }
        if v <= 1 { return v }
        return v <= 100 ? v / 100 : nil
    }

    /// A block's `layers` (server /), read tolerantly: an unknown kind, empty words or a repeated id are
    /// skipped; a colour that is not hex is white (the words) / dark (the button). The fields read: id, kind
    /// (brand / headline / sub / body / cta), text, color, x, y (top-left, fractions or percent), w (wrap width
    /// 0.05...1), scale (0.4...3), font (sans / serif / rounded / mono / condensed), align (left / center / right),
    /// plate ({on, color?, opacity?}, or a bare bool), bg (the CTA's button,; alias plate_color).
    static func list(_ d: JSONObject) -> [CreaLayer] {
        var seen = Set<String>()
        var out: [CreaLayer] = []
        for o in JSONRead.objects(d, "layers") {
            guard let kind = Kind(rawValue: (JSONRead.string(o, "kind") ?? "").lowercased()) else { continue }
            let text = CreaImages.oneLine(JSONRead.string(o, "text") ?? "")
            let rawId = (JSONRead.string(o, "id") ?? "").trimmingCharacters(in: .whitespaces)
            let id = rawId.isEmpty ? kind.rawValue : rawId
            guard !text.isEmpty, !seen.contains(id) else { continue }
            seen.insert(id)
            let po = o["plate"] as? JSONObject
            let plateOn = po.flatMap { Self.flag($0["on"]) } ?? (po != nil ? true : Self.flag(o["plate"]))
            let given = CreaColor.hex(po.flatMap { JSONRead.string($0, "color") })
                ?? CreaColor.hex(JSONRead.string(o, "bg")) ?? CreaColor.hex(JSONRead.string(o, "plate_color"))
            let bg = kind == .cta ? (given ?? "#111111") : given
            let opacity = po.flatMap { Self.number($0["opacity"]) }.map { min(1, max(0, $0)) } ?? 1
            let ground = (plateOn ?? (kind == .cta)) ? (bg ?? "#111111") : nil
            let color = CreaColor.hex(JSONRead.string(o, "color"))
                ?? (kind == .cta ? ground.map { CreaColor.luminance($0) > 0.45 ? "#111111" : "#FFFFFF" } : nil) ?? "#FFFFFF"
            let scale = Self.number(o["scale"]).map { min(CreaLayers.maxScale, max(CreaLayers.minScale, $0)) }
            let w = fraction(Self.number(o["w"])).map { min(1, max(0.05, $0)) }
            let font = CreaFont.read(JSONRead.string(o, "font"))
            let align = CreaAlign.read(JSONRead.string(o, "align"))
            out.append(CreaLayer(id: id, kind: kind, text: text, color: color, bg: bg, plate: plateOn, plateOpacity: opacity,
                                 font: font ?? .sans, align: align ?? .left,
                                 x: fraction(Self.number(o["x"])), y: fraction(Self.number(o["y"])), w: w, scale: scale,
                                 styledByCrea: font != nil || align != nil || po != nil || (kind != .cta && plateOn != nil) || w != nil))
        }
        return out
    }

    /// A number or a numeric string ("30%" is 30).
    static func number(_ v: Any?) -> Double? {
        if let n = v as? NSNumber { return n.doubleValue }
        if let s = v as? String { return Double(s.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "%", with: "")) }
        return nil
    }

    /// true / false, 1 / 0, "on" / "off", "yes" / "no"; anything else nil.
    static func flag(_ v: Any?) -> Bool? {
        if let b = v as? Bool { return b }
        if let n = v as? NSNumber { return n.intValue != 0 }
        switch (v as? String ?? "").trimmingCharacters(in: .whitespaces).lowercased() {
        case "true", "on", "yes", "1": return true
        case "false", "off", "no", "0", "none": return false
        default: return nil
        }
    }
}

/// Where a layer sits: its top-left corner in fractions of the picture, and its size over the kind's base.
struct CreaLayerFrame: Equatable, Codable {
    var x: Double
    var y: Double
    var scale: Double = 1
    /// The words as the person edited them in place (nil: the block's own).: a layer's text can be
    /// edited, not only moved; the edit lives in the layout, so Undo and Reset take it back like a move.
    var text: String? = nil
    /// The person's own words colour, plate colour, plate on / off and type (nil: the block's).
    var color: String? = nil
    var bg: String? = nil
    var plate: Bool? = nil
    var font: CreaFont? = nil
    var align: CreaAlign? = nil
    /// The layer's signature (CreaLayer.signature) when the person changed it: once Crea changes the layer, the
    /// person's words and style give way to Crea's, and so does the place when Crea placed it.
    var basis: String? = nil

    /// The person changed the words or the style.
    var hasStyle: Bool { text != nil || color != nil || bg != nil || plate != nil || font != nil || align != nil }
}

/// A layer's box in fractions of the picture (x / y top-left, w / h).
struct CreaBox: Equatable {
    var x: Double
    var y: Double
    var w: Double
    var h: Double
    var midX: Double { x + w / 2 }
    var midY: Double { y + h / 2 }
    var maxX: Double { x + w }
    var maxY: Double { y + h }
}

/// A guide line drawn while a layer snaps: vertical at `at` (a fraction of the width) or horizontal (of the height).
struct CreaGuide: Equatable, Hashable {
    enum Axis: String { case vertical, horizontal }
    let axis: Axis
    let at: Double
}

/// The layout of one picture: a frame per layer id.
struct CreaLayout: Equatable, Codable {
    var frames: [String: CreaLayerFrame] = [:]

    subscript(_ id: String) -> CreaLayerFrame? {
        get { frames[id] }
        set { frames[id] = newValue }
    }
}

enum CreaLayers {
    /// The safe margin (5% of each side), where snapping pulls an edge.
    static let margin = 0.05
    static let minScale = 0.4
    static let maxScale = 3.0
    /// A layer's words never wrap wider than this share of the picture.
    static let maxWrap = 0.9

    /// The kind's base: the width its words wrap at (a fraction of the picture's width) and its font size (a
    /// fraction of the picture's shorter side), both at scale 1.
    static func base(_ k: CreaLayer.Kind) -> (wrap: Double, font: Double) {
        switch k {
        case .brand: return (0.5, 0.045)
        case .headline: return (0.80, 0.085)
        case .sub: return (0.70, 0.042)
        case .body: return (0.75, 0.034)
        case .cta: return (0.80, 0.040)
        }
    }

    /// The width a layer's words wrap at, as a fraction of the picture's width.
    static func wrap(_ k: CreaLayer.Kind, scale: Double) -> Double { min(maxWrap, base(k).wrap * scale) }

    /// A layer's wrap width: Crea's `w` when it gave one (it does not grow with the scale), else the kind's.
    static func wrap(_ l: CreaLayer, scale: Double) -> Double { l.w.map { min(1, max(0.05, $0)) } ?? wrap(l.kind, scale: scale) }

    /// The font size in the picture's units (pixels of a `w` x `h` picture, or points on screen).
    static func fontSize(_ k: CreaLayer.Kind, scale: Double, w: Double, h: Double) -> Double {
        base(k).font * scale * min(w, h)
    }

    /// A rough box (w, h fractions) where nothing can measure: average glyph 0.55 em, line 1.18 em, the CTA's pill
    /// padded 0.55 em top and bottom and 1.1 em on the sides, the brand's dot 1.2 em.
    static func estimate(_ l: CreaLayer, scale: Double, aspect: Double) -> (w: Double, h: Double) {
        let a = max(0.1, aspect)         // the picture is a x 1
        let font = fontSize(l.kind, scale: scale, w: a, h: 1)
        let glyph = 0.55 * font
        let textW = Double(l.text.count) * glyph
        switch l.kind {
        case .cta:
            return (min(1, (textW + 2.2 * font) / a), 1.18 * font + 1.1 * font)
        default:
            let extra = l.kind == .brand ? 1.2 * font : 0
            let wrapW = wrap(l, scale: scale) * a
            let lines = max(1, Int((textW / max(glyph, wrapW)).rounded(.up)))
            return (min(wrapW, textW + extra) / a, Double(lines) * 1.18 * font)
        }
    }

    // MARK: the default layout

    /// Where the layers start: the brand top-left, the headline under it, the sub-text under the headline, the CTA at
    /// the bottom, all on the left margin (the server asked the image model to keep the top third and the bottom fifth
    /// calm). `size` gives each layer's box at scale 1 (the renderer's measure, or `estimate`).
    static func defaults(_ layers: [CreaLayer], size: (CreaLayer) -> (w: Double, h: Double)) -> CreaLayout {
        var out = CreaLayout()
        let left = 0.07
        var y = 0.06
        for k in [CreaLayer.Kind.brand, .headline, .sub, .body] {
            for l in layers where l.kind == k {
                out[l.id] = CreaLayerFrame(x: left, y: y)
                y += size(l).h + (k == .brand ? 0.03 : 0.025)
            }
        }
        for l in layers where l.kind == .cta {
            let h = size(l).h
            out[l.id] = CreaLayerFrame(x: left, y: max(y, 1 - 0.07 - h))
        }
        return out
    }

    /// The layout to draw: what the person made (`own`), else the draft's this picture was made from (`seed`), else
    /// where Crea placed the layer (its x / y / scale), else `defaults`. A layer Crea placed after the person moved it
    /// goes where Crea put it. Frames of layers no longer there are dropped.
    static func resolved(_ layers: [CreaLayer], own: CreaLayout?, seed: CreaLayout?, size: (CreaLayer) -> (w: Double, h: Double)) -> CreaLayout {
        let d = defaults(layers, size: size)
        var out = CreaLayout()
        for l in layers {
            let base = d[l.id] ?? CreaLayerFrame(x: 0.07, y: 0.07)
            // Crea placed it: the person's frame stands only when it was made against this very layer.
            func usable(_ f: CreaLayerFrame?) -> CreaLayerFrame? {
                guard let f else { return nil }
                return l.isPlaced && f.basis != l.signature ? nil : f
            }
            let placed = l.isPlaced ? CreaLayerFrame(x: l.x ?? base.x, y: l.y ?? base.y, scale: l.scale ?? base.scale) : nil
            out[l.id] = usable(own?[l.id]) ?? usable(seed?[l.id]) ?? placed ?? base
        }
        return out
    }

    // MARK: moving and resizing

    /// Inside the picture: the whole box when it fits, else its left / top edge at 0.
    static func clamp(_ f: CreaLayerFrame, w: Double, h: Double) -> CreaLayerFrame {
        var r = f
        r.x = min(max(0, r.x), max(0, 1 - w))
        r.y = min(max(0, r.y), max(0, 1 - h))
        r.scale = min(maxScale, max(minScale, r.scale))
        return r
    }

    /// One axis: the offset (edge, centre, far edge) whose target is nearest within `threshold` -> the new start and
    /// the guide's position.
    private static func snap1(_ start: Double, len: Double, targets: [[Double]], threshold: Double) -> (Double, Double)? {
        var best: (d: Double, start: Double, at: Double)? = nil
        for (i, off) in [0, len / 2, len].enumerated() {
            for t in targets[i] {
                let d = abs(start + off - t)
                if d <= threshold, d < (best?.d ?? .infinity) { best = (d, t - off, t) }
            }
        }
        return best.map { ($0.start, $0.at) }
    }

    /// A layer moved from `start` by (dx, dy) (fractions of the picture), its box `w` x `h`: snapped to the safe
    /// margins, the centre and the other layers' edges and centres within `threshold`, then kept inside. The guides
    /// are what it snapped to. `snapping: false` (Option held) only clamps.
    static func moved(_ start: CreaLayerFrame, dx: Double, dy: Double, w: Double, h: Double, others: [CreaBox],
                      threshold: Double = 0.015, snapping: Bool = true) -> (frame: CreaLayerFrame, guides: [CreaGuide]) {
        var f = start
        f.x += dx
        f.y += dy
        var guides: [CreaGuide] = []
        if snapping {
            let xs = [[margin] + others.map(\.x), [0.5] + others.map(\.midX), [1 - margin] + others.map(\.maxX)]
            let ys = [[margin] + others.map(\.y), [0.5] + others.map(\.midY), [1 - margin] + others.map(\.maxY)]
            if let s = snap1(f.x, len: w, targets: xs, threshold: threshold) { f.x = s.0; guides.append(CreaGuide(axis: .vertical, at: s.1)) }
            if let s = snap1(f.y, len: h, targets: ys, threshold: threshold) { f.y = s.0; guides.append(CreaGuide(axis: .horizontal, at: s.1)) }
        }
        let c = clamp(f, w: w, h: h)
        // a guide whose snap the clamp undid is not true any more
        if c.x != f.x { guides.removeAll { $0.axis == .vertical } }
        if c.y != f.y { guides.removeAll { $0.axis == .horizontal } }
        return (c, guides)
    }

    /// The corner handle dragged by `dx` (a fraction of the picture's width) on a box `w0` wide at `start`: the
    /// scale follows the width, the top-left corner stays.
    static func resized(_ start: CreaLayerFrame, w0: Double, dx: Double) -> CreaLayerFrame {
        guard w0 > 0 else { return start }
        var f = start
        f.scale = min(maxScale, max(minScale, start.scale * max(0.02, w0 + dx) / w0))
        return f
    }

    /// An arrow key: 0.5% of the picture, 2.5% with Shift; kept inside.
    static func nudged(_ f: CreaLayerFrame, dx: Int, dy: Int, big: Bool, w: Double, h: Double) -> CreaLayerFrame {
        let step = big ? 0.025 : 0.005
        var r = f
        r.x += Double(dx) * step
        r.y += Double(dy) * step
        return clamp(r, w: w, h: h)
    }

    // MARK: edited words

    /// The layer as drawn: the words and style its frame in `lay` carries over the block's own, unless Crea changed the
    /// layer since the person did (the frame's basis is another signature).
    static func edited(_ l: CreaLayer, in lay: CreaLayout) -> CreaLayer {
        // A frame stamped against this very layer applies; an old unstamped one (words only, before) unless
        // Crea has styled the layer itself.
        guard let f = lay[l.id], f.hasStyle, f.basis == l.signature || (f.basis == nil && !l.styledByCrea) else { return l }
        var r = l
        if let t = f.text, !t.isEmpty { r.text = t }
        if let c = CreaColor.hex(f.color) { r.color = c }
        if let b = CreaColor.hex(f.bg) { r.bg = b }
        if let p = f.plate { r.plate = p }
        if let fo = f.font { r.font = fo }
        if let al = f.align { r.align = al }
        return r
    }

    /// A frame the person just changed, stamped with the layer it was changed against; a stale edit (made against
    /// what Crea has changed since) is dropped first, so it never comes back.
    static func stamped(_ f: CreaLayerFrame, for l: CreaLayer) -> CreaLayerFrame {
        var r = f
        if let b = r.basis, b != l.signature {
            r.text = nil; r.color = nil; r.bg = nil; r.plate = nil; r.font = nil; r.align = nil
        } else if r.basis == nil, l.styledByCrea {
            r.text = nil; r.color = nil; r.bg = nil; r.plate = nil; r.font = nil; r.align = nil
        }
        r.basis = l.signature
        return r
    }

    /// The frame with a style change: nil leaves a field as it is; a value equal to the block's clears the override.
    static func styled(_ f: CreaLayerFrame, for l: CreaLayer, color: String? = nil, bg: String? = nil, plate: Bool? = nil,
                       font: CreaFont? = nil, align: CreaAlign? = nil) -> CreaLayerFrame {
        var r = stamped(f, for: l)
        if let c = CreaColor.hex(color) { r.color = c == l.color ? nil : c }
        if let b = CreaColor.hex(bg) { r.bg = b == l.bg ? nil : b }
        if let p = plate { r.plate = p == l.plate ? nil : p }
        if let fo = font { r.font = fo == l.font ? nil : fo }
        if let al = align { r.align = al == l.align ? nil : al }
        return r
    }

    /// The colours the style bar offers (and any hex the person picks).
    static let swatches = ["#FFFFFF", "#111111", "#F5E6C8", "#E63946", "#F4A261", "#FFD166", "#2A9D8F", "#3A86FF", "#8338EC", "#FF5DA2"]

    /// The frame with `typed` as its words: trimmed to one line; empty or the block's own words clear the edit.
    static func withText(_ f: CreaLayerFrame, typed: String, original: String) -> CreaLayerFrame {
        var r = f
        let t = CreaImages.oneLine(typed)
        r.text = (t.isEmpty || t == original) ? nil : t
        return r
    }

    /// The frame with `typed` as its words, stamped against the layer.
    static func withText(_ f: CreaLayerFrame, typed: String, layer l: CreaLayer) -> CreaLayerFrame {
        withText(stamped(f, for: l), typed: typed, original: l.text)
    }

    // MARK: the picture's own ratio

    /// The centred box of `ratio` ("4:5") inside a `w` x `h` picture, in pixels; nil when it already has that ratio
    /// (within 1%) or the ratio is unknown. The server's creaCropBox: a picture it could not crop carries
    /// `fit` and is cropped here, before it is shown with layers and composited.
    static func cropBox(w: Int, h: Int, ratio: String?) -> (x: Int, y: Int, w: Int, h: Int)? {
        let parts = (ratio ?? "").split(separator: ":").compactMap { Double($0) }
        guard parts.count == 2, parts[0] > 0, parts[1] > 0, w > 0, h > 0 else { return nil }
        let want = parts[0] / parts[1], have = Double(w) / Double(h)
        if abs(have - want) / want < 0.01 { return nil }
        if have > want {
            let cw = max(1, Int((Double(h) * want).rounded()))
            return ((w - cw) / 2, 0, cw, h)
        }
        let ch = max(1, Int((Double(w) / want).rounded()))
        return (0, (h - ch) / 2, w, ch)
    }
}

/// Undo for one picture's layout: the layouts before each change, newest last, at most 50.
struct CreaLayerHistory: Equatable {
    static let cap = 50
    private(set) var past: [CreaLayout] = []

    var canUndo: Bool { !past.isEmpty }

    /// Before a change: what the layout was. A change that changed nothing is not a step.
    mutating func record(_ before: CreaLayout, after: CreaLayout) {
        guard before != after else { return }
        past.append(before)
        if past.count > Self.cap { past.removeFirst(past.count - Self.cap) }
    }

    mutating func undo() -> CreaLayout? { past.popLast() }
}

/// The layouts the person made, by picture id, newest last, the newest `cap` kept (what UserDefaults holds).
struct CreaLayoutBook: Equatable, Codable {
    /// 60 -> 300 (every text variant in Crea Studio keeps a layout of its own).
    static let cap = 300
    var layouts: [String: CreaLayout] = [:]
    var order: [String] = []

    mutating func put(_ l: CreaLayout, for id: String) {
        layouts[id] = l
        order.removeAll { $0 == id }
        order.append(id)
        while order.count > Self.cap, let oldest = order.first {
            order.removeFirst()
            layouts[oldest] = nil
        }
    }

    mutating func remove(_ id: String) {
        layouts[id] = nil
        order.removeAll { $0 == id }
    }

    func encoded() -> Data? { try? JSONEncoder().encode(self) }

    static func decoded(_ d: Data?) -> CreaLayoutBook {
        guard let d, let b = try? JSONDecoder().decode(CreaLayoutBook.self, from: d) else { return CreaLayoutBook() }
        return b
    }
}

/// Hex colours.
enum CreaColor {
    /// "#abc" / "AABBCC" -> "#AABBCC"; anything else nil.
    static func hex(_ v: String?) -> String? {
        var s = (v ?? "").trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("#") { s.removeFirst() }
        guard s.allSatisfy({ $0.isHexDigit }) else { return nil }
        if s.count == 3 { s = s.map { "\($0)\($0)" }.joined() }
        guard s.count == 6 else { return nil }
        return "#" + s.uppercased()
    }

    /// 0...1 components of a hex colour (white when it is not one).
    static func rgb(_ v: String) -> (r: Double, g: Double, b: Double) {
        guard let h = hex(v), let n = Int(h.dropFirst(), radix: 16) else { return (1, 1, 1) }
        return (Double((n >> 16) & 0xFF) / 255, Double((n >> 8) & 0xFF) / 255, Double(n & 0xFF) / 255)
    }

    /// Relative luminance 0...1.
    static func luminance(_ v: String) -> Double {
        let c = rgb(v)
        func lin(_ x: Double) -> Double { x <= 0.03928 ? x / 12.92 : pow((x + 0.055) / 1.055, 2.4) }
        return 0.2126 * lin(c.r) + 0.7152 * lin(c.g) + 0.0722 * lin(c.b)
    }
}

/// Text on / off per picture (on drafts the words merge with the picture, and a draft is picked for
/// the picture; the words are worked on the final): off by default on a draft, on on a final; the person's choice
/// kept by picture id, the newest `cap`.
struct CreaTextShown: Equatable, Codable {
    static let cap = 200
    var on: [String: Bool] = [:]
    var order: [String] = []

    func isOn(_ p: CreaImages.Picture) -> Bool { on[p.id] ?? !p.isDraft }

    mutating func set(_ v: Bool, for p: CreaImages.Picture) {
        if v == !p.isDraft { on[p.id] = nil; order.removeAll { $0 == p.id }; return }
        on[p.id] = v
        order.removeAll { $0 == p.id }
        order.append(p.id)
        while order.count > Self.cap, let oldest = order.first {
            order.removeFirst()
            on[oldest] = nil
        }
    }

    /// The layers drawn on `p`: all of them with text on, none with it off.
    func layers(_ layers: [CreaLayer], for p: CreaImages.Picture) -> [CreaLayer] { isOn(p) ? layers : [] }

    func encoded() -> Data? { try? JSONEncoder().encode(self) }

    static func decoded(_ d: Data?) -> CreaTextShown {
        guard let d, let v = try? JSONDecoder().decode(CreaTextShown.self, from: d) else { return CreaTextShown() }
        return v
    }
}
