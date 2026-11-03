import SwiftUI
import AppKit

// Lia's answer drawn the way the browser draws `.ai__atext` (ai.js injectCSS, ai/index.html).
//
// One NSTextView (TextKit 1) per block, because three things the site does cannot be done with SwiftUI Text:
// CSS line boxes. `line-height: 1.72` centres every font's content box in a 27.52 px box and a line is as tall as
// its tallest box, so a line with Cyrillic (drawn in Georgia, whose content box is taller than Newsreader's) is a
// little taller than a Latin one. CSSLineBoxes sets each line fragment to exactly that.
// The fallback face. `'Newsreader', Georgia, serif`: Newsreader has no Cyrillic, so Russian words are Georgia while
// digits and Latin stay Newsreader. AnswerFonts assigns Georgia per character instead of leaving it to the system
// cascade, which picked the system sans.
// Chips. Every chip is an attachment cell drawing the site's box (radius, border, padding, colours for both themes):
// a whole that never splits across lines, sits on the baseline as the CSS aligns it, stays selectable with the text
// around it, and is clicked through the view itself. The previous TextRenderer route painted nothing once the text
// was selectable, and the macOS 14 fallback was a square tint.

// MARK: tokens as NSColor (AppConfig's values), resolved at draw time for the window's appearance

enum AnswerInk {
    static func dyn(_ dark: (UInt32, CGFloat), _ light: (UInt32, CGFloat)) -> NSColor {
        NSColor(name: nil) { ap in
            let isDark = ap.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            let (v, a) = isDark ? dark : light
            return NSColor(srgbRed: CGFloat((v >> 16) & 0xff) / 255, green: CGFloat((v >> 8) & 0xff) / 255,
                           blue: CGFloat(v & 0xff) / 255, alpha: a)
        }
    }
    static let text = dyn((0xffffff, 1), (0x11141a, 1))
    static let text2 = dyn((0xffffff, 0.70), (0x11141a, 0.72))
    static let text3 = dyn((0xffffff, 0.50), (0x11141a, 0.55))
    static let text4 = dyn((0xffffff, 0.35), (0x11141a, 0.42))
    static let line2 = dyn((0xffffff, 0.10), (0xdde4ec, 1))
    static let msgU = dyn((0x262625, 1), (0xefeeeb, 1))
    static let surface2 = dyn((0xffffff, 0.04), (0x11141a, 0.05))
    static let chipBg = dyn((0x232321, 1), (0xefeeeb, 1))
    static let chipLine = dyn((0x343432, 1), (0xdde4ec, 1))
    static let accent = NSColor(srgbRed: 0, green: 126 / 255, blue: 247 / 255, alpha: 1)
    static let accentLine = NSColor(srgbRed: 0, green: 126 / 255, blue: 247 / 255, alpha: 0.4)
    static func grey(_ a: CGFloat) -> NSColor { NSColor(srgbRed: 127 / 255, green: 127 / 255, blue: 127 / 255, alpha: a) }
    static func white(_ a: CGFloat) -> NSColor { NSColor(srgbRed: 1, green: 1, blue: 1, alpha: a) }
}

// MARK: faces

enum AnswerFonts {
    static func newsreader(_ size: CGFloat, _ w: Font.Weight, oblique: Bool = false, tabular: Bool = false) -> NSFont {
        if let f = LiaFont.answerFace(size, w, oblique: oblique, tabular: tabular) { return unsafeBitCast(f, to: NSFont.self) }
        return georgia(size, w, italic: oblique)
    }

    static func georgia(_ size: CGFloat, _ w: Font.Weight, italic: Bool) -> NSFont {
        NSFont(name: LiaFont.georgiaName(w, italic: italic), size: size) ?? NSFont(name: "Georgia", size: size) ?? .systemFont(ofSize: size)
    }

    static func inter(_ size: CGFloat, _ w: Font.Weight) -> NSFont {
        if let f = LiaFont.interFace(size, w) { return unsafeBitCast(f, to: NSFont.self) }
        return .systemFont(ofSize: size, weight: nsWeight(w))
    }

    static func nunito(_ size: CGFloat, _ w: Font.Weight) -> NSFont {
        if let f = LiaFont.nunitoFace(size, w) { return unsafeBitCast(f, to: NSFont.self) }
        return .systemFont(ofSize: size, weight: nsWeight(w))
    }

    static func nsWeight(_ w: Font.Weight) -> NSFont.Weight {
        switch w {
        case .ultraLight: return .ultraLight
        case .thin: return .thin
        case .light: return .light
        case .medium: return .medium
        case .semibold: return .semibold
        case .bold: return .bold
        case .heavy: return .heavy
        case .black: return .black
        default: return .regular
        }
    }

    /// What Newsreader can draw. Anything else goes to Georgia, the next family in the site's stack.
    private static let newsreaderSet: CharacterSet? = {
        guard let f = LiaFont.answerFace(16, .regular) else { return nil }
        return CTFontCopyCharacterSet(f) as CharacterSet
    }()

    static func newsreaderHas(_ u: Unicode.Scalar) -> Bool {
        guard let set = newsreaderSet else { return true }
        return set.contains(u)
    }

    /// Appends `s` in Newsreader, with the runs Newsreader cannot draw in Georgia. Spaces stay with the run they are in.
    static func appendAnswer(_ s: String, to out: NSMutableAttributedString, news: NSFont, georgia: NSFont, attrs: [NSAttributedString.Key: Any]) {
        var buf = ""
        var bufIsNews = true
        func flush() {
            guard !buf.isEmpty else { return }
            var a = attrs
            a[.font] = bufIsNews ? news : georgia
            out.append(NSAttributedString(string: buf, attributes: a))
            buf = ""
        }
        for u in s.unicodeScalars {
            let neutral: Bool = u.properties.isWhitespace
            let isNews: Bool = neutral ? bufIsNews : newsreaderHas(u)
            if isNews != bufIsNews && !buf.isEmpty { flush() }
            bufIsNews = isNews
            buf.unicodeScalars.append(u)
        }
        flush()
    }

    /// One inline box under `line-height: factor`: its content box (ascent + descent) centred in factor x size.
    static func box(_ f: NSFont, factor: CGFloat) -> (above: CGFloat, below: CGFloat) {
        let a: CGFloat = f.ascender
        let d: CGFloat = -f.descender
        let half: CGFloat = (factor * f.pointSize - (a + d)) / 2
        return (half + a, half + d)
    }
}

// MARK: the style of one block

struct AnswerStyle: Equatable {
    enum Face: Equatable { case answer, ui }
    enum Tone: Equatable { case text, text2, text3 }

    /// Answers in the interface face (Nunito), like the person's messages; no serif.
    var face: Face = .ui
    var size: CGFloat = 14
    var weight: Font.Weight = .regular
    var tone: Tone = .text
    /// `.tl__txt b{color:var(--text-2)}`
    var boldTone: Tone? = nil
    /// The unitless CSS line-height (the person's bubble reads at about 1.5).
    var factor: CGFloat = 1.5
    var tabular = false
    var uppercase = false
    /// letter-spacing in em.
    var tracking: CGFloat = 0
    var wraps = true
    /// A list item's marker ("•", "3."), drawn outside the text as the browser draws `list-style-position: outside`.
    var marker: String? = nil
    /// ul/ol padding-left.
    var indent: CGFloat = 0

    static func color(_ t: Tone) -> NSColor {
        switch t {
        case .text: return AnswerInk.text
        case .text2: return AnswerInk.text2
        case .text3: return AnswerInk.text3
        }
    }

    func font(bold: Bool = false, italic: Bool = false) -> NSFont {
        let w: Font.Weight = bold ? .bold : weight
        switch face {
        case .answer: return AnswerFonts.newsreader(size, w, oblique: italic, tabular: tabular)
        case .ui: return AnswerFonts.nunito(size, w)
        }
    }
}

// MARK: chips

/// What a click on a chip asks for. `.copy` is answered by the view itself (the url chip copies and flashes).
enum ChipAction: Equatable {
    case entity(String)
    case namesake(String)
    case cite(Int)
    case link(String)
    case copy(String)
    /// A pull request, branch or commit (MarkdownView opens its page or the branch's preview).
    case github(GitHubRef)
    /// A file or folder of Dev's project; answered by the view itself (CanvasFileOpen: the Canvas on
    /// the right, Changes or Files), so every text that draws it opens it the same way.
    case file(FileRef)
}

/// What a chip's hover card shows (ChipHoverHost), taken when the chip is built.
enum ChipHover: Equatable {
    case link(title: String, url: String, host: String)
    case cite([ChatCite])
    case github(GitHubRef)
    case entity(name: String, kind: String?, parent: String?, kids: Int)
    /// A path of Dev's project.
    case file(FileRef)
}

/// One chip's box, measured once, drawn by ChipCell. All sizes are the site's CSS px.
final class ChipSpec {
    /// `.path`: ("the chips look strange") - a file / folder / branch drawn as an inline code chip with
    /// its glyph directly in it (no inner tile), so it reads as part of the sentence.
    /// `.gh`: (Claude's chips as the reference) - a repository, branch, pull request or commit as a
    /// light blue pill, its glyph and name in blue, inline at the text's height.
    /// `.site`: (feedback: "the site chips weigh the message down") - a link or an address as a light
    /// inline pill in blue at the text's height, no letter tile, no favicon, no outline.
    /// `.agent`: - an agent named in the text as the landing draws it: the name on the agent's own tint
    /// (Lia on the ink's);: no dot before the name, as in the message box.
    enum Kind { case entity, namesake, quote, link, cite, url, code, path, gh, site, agent }

    let kind: Kind
    /// What Copy puts on the clipboard for this chip.
    let plain: String
    let action: ChipAction?
    /// The card shown while the pointer rests on the chip (nil: none).
    var hover: ChipHover?
    /// An SF Symbol drawn in the letter tile instead of a letter (a GitHub chip's PR / commit glyph), or `.path`'s glyph.
    var tileSymbol: String?
    private(set) var size: NSSize = .zero
    /// Above and below the baseline, margins included: what the line box has to hold.
    private(set) var ascent: CGFloat = 0
    private(set) var descent: CGFloat = 0
    var copiedUntil: Date?
    /// `.agent`: the agent's colour.
    var agentColor: NSColor?

    private let labelText: String
    private let labelFont: NSFont
    private let labelGeorgia: NSFont?
    private var labelWidth: CGFloat = 0
    private let badgeText: String?
    private let tileText: String?
    private var textColor: NSColor = AnswerInk.text
    // geometry, from the cell's top-left
    private var margin = NSSize(width: 0, height: 0)
    private var borderH: CGFloat = 0
    private var contentTop: CGFloat = 0
    private var contentH: CGFloat = 0
    private var labelX: CGFloat = 0
    private var baseline: CGFloat = 0
    private var badgeW: CGFloat = 0
    /// `.path`: the glyph's width and the gap after it.
    private var glyphW: CGFloat = 0

    private static let labelCap: CGFloat = 520

    private init(kind: Kind, label: String, plain: String, action: ChipAction?, font: NSFont, georgia: NSFont? = nil,
                 badge: String? = nil, tile: String? = nil) {
        self.kind = kind
        self.labelText = label
        self.plain = plain
        self.action = action
        self.labelFont = font
        self.labelGeorgia = georgia
        self.badgeText = badge
        self.tileText = tile
    }

    static func make(_ seg: InlineSegment, groups: [[ChatCite]], parent: NSFont, parentColor: NSColor, factor: CGFloat,
                     ents: [String: ChatEntity] = [:]) -> ChipSpec? {
        let spec: ChipSpec
        switch seg {
        case .text:
            return nil
        case let .entity(name, id, kind):
            // .lia-entchip: 500 12px Inter (the answer's --font-sans), --msg-u, 1 px --line-2, radius 7, padding 0 7.
            spec = ChipSpec(kind: .entity, label: name, plain: name, action: id.map { .entity($0) }, font: AnswerFonts.inter(12, .medium))
            if let id {
                let t = EntityChips.tree(id: id, ents: ents)
                spec.hover = .entity(name: name, kind: ents[id]?.kind ?? kind, parent: t.parent, kids: t.kids.count)
            }
        case let .namesake(name, count, _):
            spec = ChipSpec(kind: .namesake, label: name, plain: name, action: .namesake(EntityChips.key(name)),
                            font: AnswerFonts.inter(12, .medium), badge: count > 1 ? String(count) : nil)
        case .quote(let q):
            spec = ChipSpec(kind: .quote, label: q, plain: q, action: nil, font: AnswerFonts.inter(12, .medium))
        case let .link(label, url, host):
            // .md-a: the citation pill without the card. 12.5 px in the answer face, the letter tile of the host.
            spec = ChipSpec(kind: .site, label: label, plain: label, action: .link(url),
                            font: AnswerFonts.inter(parent.pointSize * 0.9, .regular))
            spec.hover = .link(title: label, url: url, host: host)
        case .cite(let gi):
            guard groups.indices.contains(gi), let first = groups[gi].first else { return nil }
            var dom = first.host
            if dom.hasPrefix("www.") { dom = String(dom.dropFirst(4)) }
            if dom.isEmpty { dom = "source" }
            let extra = groups[gi].count - 1
            spec = ChipSpec(kind: .cite, label: dom, plain: dom, action: .cite(gi),
                            font: AnswerFonts.nunito(12.5, .regular),
                            badge: extra > 0 ? "+" + String(extra) : nil, tile: String(dom.prefix(1)).uppercased())
            spec.hover = .cite(groups[gi])
        case .url(let u):
            // ("Dev's links are blue links"): a bare address or domain is a site chip like a source - the
            // host's letter tile, the address without its scheme, the site's card on hover; a click opens it (the
            // thread's route: Dev's sites in the Canvas, the rest in Peek / the in-app browser). Copy keeps the address.
            var host = URL(string: u)?.host ?? ""
            if host.hasPrefix("www.") { host = String(host.dropFirst(4)) }
            let label = DomainChip.label(u)
            spec = ChipSpec(kind: .site, label: label, plain: u, action: .link(u),
                            font: AnswerFonts.inter(parent.pointSize * 0.9, .regular))
            spec.hover = .link(title: label, url: u, host: host)
        case .github(let ref):
            // (Claude's PR chip as the reference): every GitHub ref - repository, branch, pull request,
            // commit - is the same light blue pill with its glyph; the card on hover says the rest.
            spec = ChipSpec(kind: .gh, label: ref.label, plain: ref.webURL?.absoluteString ?? ref.label, action: .github(ref),
                            font: AnswerFonts.inter(parent.pointSize * 0.9, .regular))
            spec.tileSymbol = ChipSpec.gitHubSymbol(ref.kind)
            spec.hover = .github(ref)
        case .file(let f):
            // Dev's path drawn as an inline code chip with its glyph in it (no tile, no outline).
            // ("just the file's name"): the last part only ("index.html", "site"), no card on hover; Copy keeps the
            // words as written, a click opens it as before.
            var shown = f.written
            while shown.count > 1, shown.hasSuffix("/") { shown.removeLast() }
            if let last = shown.split(separator: "/").last, !last.isEmpty { shown = String(last) }
            spec = ChipSpec(kind: .path, label: shown, plain: f.written, action: .file(f),
                            font: AnswerFonts.inter(parent.pointSize * 0.9, .regular))
            spec.tileSymbol = ChipSpec.fileSymbol(f)
        case let .agent(_, name, color):
            spec = ChipSpec(kind: .agent, label: name, plain: "@" + name, action: nil,
                            font: AnswerFonts.inter(parent.pointSize * 0.9, .semibold))
            spec.agentColor = ChipSpec.agentInk(color)
        }
        spec.measure(parent: parent, factor: factor)
        spec.textColor = parentColor
        return spec
    }

    /// The agent's colour for its pill; Lia's near-black ink becomes the text's own colour (it reads in Dark).
    static func agentInk(_ hex: UInt32) -> NSColor {
        let c = NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
                        blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
        let lum = 0.2126 * c.redComponent + 0.7152 * c.greenComponent + 0.0722 * c.blueComponent
        return lum < 0.2 ? AnswerInk.text : c
    }

    /// A GitHub chip's tile glyph by kind (also the hover card's and the popup's).
    static func gitHubSymbol(_ kind: GitHubRef.Kind) -> String {
        switch kind {
        case .pr: return "arrow.triangle.pull"
        case .branch: return "arrow.triangle.branch"
        case .commit: return "smallcircle.filled.circle"
        case .repo: return "book.closed"
        }
    }

    /// A path chip's tile glyph: a folder, a picture, a page.
    static func fileSymbol(_ f: FileRef) -> String {
        if f.isDir { return "folder" }
        if f.isImage { return "photo" }
        return "doc.text"
    }

    /// `.md-c`: Inter at .9em on rgba(127,127,127,.14), radius 4, padding 1 5. Short code only: a long span stays text so
    /// it can wrap, as the browser wraps an inline element.
    static func code(_ s: String, parent: NSFont, parentColor: NSColor, factor: CGFloat) -> ChipSpec {
        let spec = ChipSpec(kind: .code, label: s, plain: s, action: nil, font: AnswerFonts.inter(parent.pointSize * 0.9, .regular))
        spec.measure(parent: parent, factor: factor)
        spec.textColor = parentColor
        return spec
    }

    private func label(color: NSColor, maxWidth: CGFloat? = nil) -> NSAttributedString {
        let p = NSMutableParagraphStyle()
        p.lineBreakMode = .byTruncatingTail
        let attrs: [NSAttributedString.Key: Any] = [.foregroundColor: color, .paragraphStyle: p, .font: labelFont]
        if let g = labelGeorgia {
            let out = NSMutableAttributedString()
            AnswerFonts.appendAnswer(labelText, to: out, news: labelFont, georgia: g, attrs: attrs)
            return out
        }
        return NSAttributedString(string: labelText, attributes: attrs)
    }

    private static func width(_ s: String, _ f: NSFont) -> CGFloat {
        ceil((s as NSString).size(withAttributes: [.font: f]).width)
    }

    private func measure(parent: NSFont, factor: CGFloat) {
        labelWidth = min(Self.labelCap, ceil(label(color: .black).size().width))
        let a: CGFloat = labelFont.ascender
        let d: CGFloat = -labelFont.descender
        switch kind {
        case .entity, .namesake, .quote:
            // line-height 1.55 at 12 px, a 1 px border, a 1 px margin all round; the text's baseline is the chip's.
            let lineH: CGFloat = 12 * 1.55
            margin = NSSize(width: 1, height: 1)
            borderH = lineH + 2
            contentTop = margin.height + 1
            contentH = lineH
            baseline = contentTop + (lineH - (a + d)) / 2 + a
            labelX = margin.width + 1 + 7
            if let b = badgeText {
                // .lia-entchip__n: margin-left 5, 700 10px, padding 0 4, line-height 1.5, radius 5.
                badgeW = Self.width(b, AnswerFonts.inter(10, .bold)) + 8
            }
            let w: CGFloat = labelX + labelWidth + (badgeText == nil ? 0 : 5 + badgeW) + 7 + 1 + margin.width
            size = NSSize(width: w, height: borderH + 2 * margin.height)
            ascent = baseline
            descent = size.height - baseline
        case .link, .cite:
            // .md-a / .ai__cite: line-height 1.7 at 12.5, padding 1 8 1 4, a 1 px border, margin 0 1, the 15 px tile and a
            // 5 px gap, vertical-align 1px. A Cyrillic label's Georgia box can make the line taller, as in the browser.
            var above: CGFloat = AnswerFonts.box(labelFont, factor: 1.7).above
            var below: CGFloat = AnswerFonts.box(labelFont, factor: 1.7).below
            if let g = labelGeorgia, labelText.unicodeScalars.contains(where: { !$0.properties.isWhitespace && !AnswerFonts.newsreaderHas($0) }) {
                let gb = AnswerFonts.box(g, factor: 1.7)
                above = max(above, gb.above); below = max(below, gb.below)
            }
            margin = NSSize(width: 1, height: 0)
            contentH = above + below
            borderH = contentH + 4
            contentTop = 2
            baseline = 2 + above
            labelX = margin.width + 1 + 4 + 15 + 5
            if let b = badgeText { badgeW = Self.width(b, AnswerFonts.inter(11.5, .regular)) }
            let w: CGFloat = labelX + labelWidth + (badgeText == nil ? 0 : 5 + badgeW) + 8 + 1 + margin.width
            size = NSSize(width: w, height: borderH)
            ascent = baseline + 1
            descent = size.height - ascent
        case .url:
            let maxLabel: CGFloat = 220 - 18
            labelWidth = min(labelWidth, maxLabel)
            margin = NSSize(width: 0, height: 0)
            borderH = 20
            contentTop = 1
            contentH = 18
            let lineTop: CGFloat = 1 + (18 - 11) / 2
            baseline = lineTop + (11 - (a + d)) / 2 + a
            labelX = 1 + 8
            size = NSSize(width: labelWidth + 18, height: 20)
            // vertical-align: middle - the chip's centre at half the parent's x-height above the baseline.
            let mid: CGFloat = parent.xHeight / 2
            ascent = 10 + mid
            descent = 10 - mid
        case .code, .path, .gh, .site, .agent:
            // a long address is cut with an ellipsis, as the old site chip was
            if kind == .site { labelWidth = min(labelWidth, 260) }
            // .md-c's box: the label's own line, so the chip sits on the text's baseline at the text's height.
            let half: CGFloat = (factor * labelFont.pointSize - (a + d)) / 2
            let room: CGFloat = kind == .gh || kind == .site || kind == .agent ? 2 : 1
            ascent = max(half + a, a + room)
            descent = max(half + d, d + room)
            if kind == .path || kind == .gh, let sym = tileSymbol, let img = Self.pathSymbol(sym, size: labelFont.pointSize) {
                glyphW = ceil(img.size.width) + (kind == .gh ? 4 : 3)
            }
            // .gh: a little more room on each side (6 px), as Claude's pill
            let pad: CGFloat = kind == .gh || kind == .site || kind == .agent ? 6 : 5
            size = NSSize(width: labelWidth + 2 * pad + glyphW, height: ascent + descent)
            baseline = ascent
            labelX = pad + glyphW
            contentTop = ascent - a - (kind == .gh || kind == .site || kind == .agent ? 2 : 1)
            borderH = a + d + (kind == .gh || kind == .site || kind == .agent ? 4 : 2)
        }
    }

    func draw(in f: NSRect, hover: Bool) {
        let copied = (copiedUntil ?? .distantPast) > Date()
        switch kind {
        case .entity, .namesake, .quote:
            let box = NSRect(x: f.minX + margin.width, y: f.minY + margin.height, width: f.width - 2 * margin.width, height: borderH)
            let path = NSBezierPath(roundedRect: box.insetBy(dx: 0.5, dy: 0.5), xRadius: 6.5, yRadius: 6.5)
            let fill: NSColor = hover ? AnswerInk.white(0.1) : (kind == .entity ? AnswerInk.msgU : AnswerInk.surface2)
            fill.setFill()
            path.fill()
            if kind != .quote {
                AnswerInk.line2.setStroke()
                path.lineWidth = 1
                if kind == .namesake { path.setLineDash([3, 2], count: 2, phase: 0) }
                path.stroke()
            }
            drawLabel(in: f, color: AnswerInk.text)
            if let b = badgeText {
                let bx: CGFloat = f.minX + labelX + labelWidth + 5
                let by: CGFloat = f.minY + contentTop + (contentH - 15) / 2
                let r = NSRect(x: bx, y: by, width: badgeW, height: 15)
                AnswerInk.white(0.07).setFill()
                NSBezierPath(roundedRect: r, xRadius: 5, yRadius: 5).fill()
                let bf = AnswerFonts.inter(10, .bold)
                let base: CGFloat = by + (15 - (bf.ascender - bf.descender)) / 2 + bf.ascender
                (b as NSString).draw(at: NSPoint(x: bx + 4, y: base - bf.ascender), withAttributes: [.font: bf, .foregroundColor: AnswerInk.text4])
            }
        case .link, .cite:
            let box = NSRect(x: f.minX + margin.width, y: f.minY, width: f.width - 2 * margin.width, height: borderH)
            let path = NSBezierPath(roundedRect: box.insetBy(dx: 0.5, dy: 0.5), xRadius: borderH / 2 - 0.5, yRadius: borderH / 2 - 0.5)
            AnswerInk.grey(hover ? 0.22 : 0.14).setFill()
            path.fill()
            // The hover darkens the fill and the outline; the box never moves (same path, same width).
            (hover ? AnswerInk.grey(0.42) : AnswerInk.line2).setStroke()
            path.lineWidth = 1
            path.stroke()
            // .ai__cite__f: 15 px, radius 4, rgba(127,127,127,.26), 600 8.5px Inter, --text-2.
            let tile = NSRect(x: box.minX + 1 + 4, y: f.minY + contentTop + (contentH - 15) / 2, width: 15, height: 15)
            AnswerInk.grey(0.26).setFill()
            NSBezierPath(roundedRect: tile, xRadius: 4, yRadius: 4).fill()
            if let sym = tileSymbol, let img = Self.symbol(sym) {
                let sz = img.size
                let r = NSRect(x: tile.midX - sz.width / 2, y: tile.midY - sz.height / 2, width: sz.width, height: sz.height)
                let tint = AnswerInk.text2
                let tinted = NSImage(size: sz, flipped: false) { b in
                    img.draw(in: b)
                    tint.set()
                    b.fill(using: .sourceAtop)
                    return true
                }
                tinted.draw(in: r, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
            } else if let t = tileText {
                let tf = AnswerFonts.inter(8.5, .semibold)
                let tw = (t as NSString).size(withAttributes: [.font: tf]).width
                let base: CGFloat = tile.minY + (15 - (tf.ascender - tf.descender)) / 2 + tf.ascender
                (t as NSString).draw(at: NSPoint(x: tile.midX - tw / 2, y: base - tf.ascender), withAttributes: [.font: tf, .foregroundColor: AnswerInk.text2])
            }
            drawLabel(in: f, color: hover ? AnswerInk.text : AnswerInk.text2)
            if let b = badgeText {
                // .ai__cite__p: 400 11.5px/1, --text-3.
                let bf = AnswerFonts.inter(11.5, .regular)
                let bx: CGFloat = f.minX + labelX + labelWidth + 5
                let base: CGFloat = f.minY + contentTop + (contentH - 11.5) / 2 + (11.5 - (bf.ascender - bf.descender)) / 2 + bf.ascender
                (b as NSString).draw(at: NSPoint(x: bx, y: base - bf.ascender), withAttributes: [.font: bf, .foregroundColor: AnswerInk.text3])
            }
        case .url:
            let box = NSRect(x: f.minX, y: f.minY, width: f.width, height: 20)
            let path = NSBezierPath(roundedRect: box.insetBy(dx: 0.5, dy: 0.5), xRadius: 9.5, yRadius: 9.5)
            (copied ? AnswerInk.accent : AnswerInk.chipBg).setFill()
            path.fill()
            (hover && !copied ? AnswerInk.accentLine : AnswerInk.chipLine).setStroke()
            path.lineWidth = 1
            path.stroke()
            drawLabel(in: f, color: copied ? .white : AnswerInk.accent)
        case .code:
            let r = NSRect(x: f.minX, y: f.minY + contentTop, width: f.width, height: borderH)
            AnswerInk.grey(0.14).setFill()
            NSBezierPath(roundedRect: r, xRadius: 4, yRadius: 4).fill()
            drawLabel(in: f, color: textColor)
        case .path:
            // The code chip's pill (a touch darker under the pointer: it opens something), the glyph straight in it,
            // centred on the label's cap height.
            let r = NSRect(x: f.minX, y: f.minY + contentTop, width: f.width, height: borderH)
            AnswerInk.grey(hover ? 0.22 : 0.14).setFill()
            NSBezierPath(roundedRect: r, xRadius: 4, yRadius: 4).fill()
            if let sym = tileSymbol, let img = Self.pathSymbol(sym, size: labelFont.pointSize) {
                let sz = img.size
                let midY: CGFloat = f.minY + baseline - labelFont.capHeight / 2
                let g = NSRect(x: f.minX + 5, y: midY - sz.height / 2, width: sz.width, height: sz.height)
                Self.tinted(img, AnswerInk.text2).draw(in: g, from: .zero, operation: .sourceOver, fraction: 1,
                                                       respectFlipped: true, hints: nil)
            }
            drawLabel(in: f, color: hover ? AnswerInk.text : textColor)
        case .site:
            let r = NSRect(x: f.minX, y: f.minY + contentTop, width: f.width, height: borderH)
            (copied ? AnswerInk.accent : AnswerInk.grey(hover ? 0.18 : 0.1)).setFill()
            NSBezierPath(roundedRect: r, xRadius: 6, yRadius: 6).fill()
            drawLabel(in: f, color: copied ? .white : AnswerInk.accent)
        case .agent:
            let r = NSRect(x: f.minX, y: f.minY + contentTop, width: f.width, height: borderH)
            let ink = agentColor ?? AnswerInk.text
            ink.withAlphaComponent(hover ? 0.2 : 0.13).setFill()
            NSBezierPath(roundedRect: r, xRadius: 6, yRadius: 6).fill()
            // Just the name in the agent's colour (the dot is gone)
            drawLabel(in: f, color: ink)
        case .gh:
            let r = NSRect(x: f.minX, y: f.minY + contentTop, width: f.width, height: borderH)
            let ink: NSColor = copied ? .white : AnswerInk.accent
            (copied ? AnswerInk.accent : AnswerInk.accent.withAlphaComponent(hover ? 0.2 : 0.12)).setFill()
            NSBezierPath(roundedRect: r, xRadius: 6, yRadius: 6).fill()
            if let sym = tileSymbol, let img = Self.pathSymbol(sym, size: labelFont.pointSize) {
                let sz = img.size
                let midY: CGFloat = f.minY + baseline - labelFont.capHeight / 2
                let g = NSRect(x: f.minX + 6, y: midY - sz.height / 2, width: sz.width, height: sz.height)
                Self.tinted(img, ink).draw(in: g, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
            }
            drawLabel(in: f, color: ink)
        }
    }

    /// `.path`'s glyph at the label's size, regular weight, kept per name and size.
    nonisolated(unsafe) private static var pathSymbols: [String: NSImage] = [:]
    private static func pathSymbol(_ name: String, size: CGFloat) -> NSImage? {
        let key = name + "@" + String(Double(size))
        if let i = pathSymbols[key] { return i }
        let cfg = NSImage.SymbolConfiguration(pointSize: size * 0.88, weight: .regular)
        guard let i = NSImage(systemSymbolName: name, accessibilityDescription: nil)?.withSymbolConfiguration(cfg) else { return nil }
        pathSymbols[key] = i
        return i
    }

    /// A template symbol filled with one colour.
    private static func tinted(_ img: NSImage, _ tint: NSColor) -> NSImage {
        NSImage(size: img.size, flipped: false) { b in
            img.draw(in: b)
            tint.set()
            b.fill(using: .sourceAtop)
            return true
        }
    }

    /// The tile's glyph, 8.5 pt semibold, kept per name.
    nonisolated(unsafe) private static var symbols: [String: NSImage] = [:]
    private static func symbol(_ name: String) -> NSImage? {
        if let i = symbols[name] { return i }
        let cfg = NSImage.SymbolConfiguration(pointSize: 8.5, weight: .semibold)
        guard let i = NSImage(systemSymbolName: name, accessibilityDescription: nil)?.withSymbolConfiguration(cfg) else { return nil }
        symbols[name] = i
        return i
    }

    private func drawLabel(in f: NSRect, color: NSColor) {
        let s = label(color: color)
        let top: CGFloat = f.minY + baseline - labelFont.ascender
        s.draw(with: NSRect(x: f.minX + labelX, y: top, width: labelWidth + 1, height: labelFont.ascender - labelFont.descender + 4),
               options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine], context: nil)
    }
}

final class ChipCell: NSTextAttachmentCell {
    let spec: ChipSpec

    init(spec: ChipSpec) {
        self.spec = spec
        super.init(textCell: "")
    }

    required init(coder: NSCoder) { fatalError("not used") }

    override func cellSize() -> NSSize { spec.size }
    override func cellBaselineOffset() -> NSPoint { NSPoint(x: 0, y: -spec.descent) }
    override func wantsToTrackMouse() -> Bool { false }

    override func draw(withFrame cellFrame: NSRect, in controlView: NSView?) {
        spec.draw(in: cellFrame, hover: false)
    }

    override func draw(withFrame cellFrame: NSRect, in controlView: NSView?, characterIndex charIndex: Int, layoutManager: NSLayoutManager) {
        let hover = spec.action != nil && (controlView as? AnswerTextNSView)?.hoverIndex == charIndex
        spec.draw(in: cellFrame, hover: hover)
    }
}

/// An emoji drawn as an SF Symbol at the text's size, in its tone's colour (EmojiIcons). Copy gives `original` back.
final class EmojiIconCell: NSTextAttachmentCell {
    let original: String
    private let symbol: NSImage
    private let tint: NSColor
    private let glyph: NSSize
    private let pad: CGFloat
    private let capHeight: CGFloat

    init?(icon: EmojiIcon, original: String, font: NSFont, tint: NSColor) {
        let cfg = NSImage.SymbolConfiguration(pointSize: font.pointSize * 0.92, weight: .semibold)
        guard let img = NSImage(systemSymbolName: icon.symbol, accessibilityDescription: nil)?.withSymbolConfiguration(cfg),
              img.size.width > 0, img.size.height > 0 else { return nil }
        self.original = original
        self.symbol = img
        self.tint = tint
        self.glyph = img.size
        self.pad = max(1, (font.pointSize * 0.06).rounded())
        self.capHeight = font.capHeight
        super.init(textCell: "")
    }

    required init(coder: NSCoder) { fatalError("not used") }

    override func cellSize() -> NSSize { NSSize(width: glyph.width + pad * 2, height: glyph.height) }
    /// The symbol's middle on the middle of the capitals, as an emoji sits in the line.
    override func cellBaselineOffset() -> NSPoint { NSPoint(x: 0, y: -((glyph.height - capHeight) / 2).rounded()) }
    override func wantsToTrackMouse() -> Bool { false }

    override func draw(withFrame cellFrame: NSRect, in controlView: NSView?) {
        let r = NSRect(x: cellFrame.minX + pad, y: cellFrame.minY + (cellFrame.height - glyph.height) / 2,
                       width: glyph.width, height: glyph.height)
        // Tinted at draw time, so a dynamic colour follows the window's appearance.
        let symbol = self.symbol, tint = self.tint
        let tinted = NSImage(size: glyph, flipped: false) { b in
            symbol.draw(in: b)
            tint.set()
            b.fill(using: .sourceAtop)
            return true
        }
        tinted.draw(in: r, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
    }
}

extension AnswerInk {
    /// EmojiIcons' tones in the app's semantic colours (WS.green / amber / red / blue, both themes).
    static let success = dyn((0x3DBE8B, 1), (0x11865A, 1))
    static let warning = dyn((0xF5A524, 1), (0xE5850B, 1))
    static let error = dyn((0xFF6369, 1), (0xE5484D, 1))
    static let iconBlue = dyn((0x5B78FF, 1), (0x3B5BFD, 1))
    static let highlight = dyn((0xF5C542, 1), (0xD9A31A, 1))

    static func tone(_ t: EmojiTone) -> NSColor {
        switch t {
        case .success: return success
        case .warning: return warning
        case .error: return error
        case .accent: return iconBlue
        case .highlight: return highlight
        case .neutral: return text2
        }
    }
}

// MARK: building a block's text

enum AnswerAttr {
    static func make(_ text: String, style: AnswerStyle, ents: [String: ChatEntity], groups: [[ChatCite]]) -> NSAttributedString {
        let out = NSMutableAttributedString()
        let base: NSFont = style.font()
        let color: NSColor = AnswerStyle.color(style.tone)
        let para = NSMutableParagraphStyle()
        para.lineBreakMode = style.wraps ? .byWordWrapping : .byClipping
        if let m = style.marker {
            // The browser's outside marker: "• " / "3. " in the item's own face, ending where the text begins.
            let space: CGFloat = (" " as NSString).size(withAttributes: [.font: base]).width
            para.tabStops = [NSTextTab(textAlignment: .right, location: max(1, style.indent - space), options: [:]),
                             NSTextTab(textAlignment: .left, location: style.indent, options: [:])]
            para.headIndent = style.indent
            para.firstLineHeadIndent = 0
            out.append(NSAttributedString(string: "\t" + m + "\t", attributes: [.font: base, .foregroundColor: color]))
        }
        for piece in AnswerInline.pieces(text, ents: ents) {
            switch piece {
            case .text(let run):
                appendRun(run, style: style, base: base, color: color, to: out)
            case .chip(let seg):
                guard let spec = ChipSpec.make(seg, groups: groups, parent: base, parentColor: color, factor: style.factor, ents: ents) else { continue }
                appendChip(spec, base: base, to: out)
            }
        }
        out.addAttribute(.paragraphStyle, value: para, range: NSRange(location: 0, length: out.length))
        return out
    }

    private static func appendRun(_ run: StyledRun, style: AnswerStyle, base: NSFont, color: NSColor, to out: NSMutableAttributedString) {
        let text: String = style.uppercase ? run.text.uppercased() : run.text
        if run.code {
            if text.count <= 40 && !text.contains("\n") {
                appendChip(ChipSpec.code(text, parent: base, parentColor: color, factor: style.factor), base: base, to: out)
            } else {
                out.append(NSAttributedString(string: text, attributes: [.font: AnswerFonts.inter(style.size * 0.9, .regular),
                                                                         .foregroundColor: color,
                                                                         .backgroundColor: AnswerInk.grey(0.14)]))
            }
            return
        }
        var attrs: [NSAttributedString.Key: Any] = [:]
        attrs[.foregroundColor] = run.bold ? style.boldTone.map(AnswerStyle.color) ?? color : color
        if style.tracking != 0 { attrs[.kern] = style.size * style.tracking }
        let font: NSFont = style.font(bold: run.bold, italic: run.italic)
        func appendText(_ text: String) {
            switch style.face {
            case .answer:
                let w: Font.Weight = run.bold ? .bold : style.weight
                AnswerFonts.appendAnswer(text, to: out, news: font, georgia: AnswerFonts.georgia(style.size, w, italic: run.italic), attrs: attrs)
            case .ui:
                var a = attrs
                a[.font] = font
                // Nunito ships no italic: *emphasis* is slanted, as the browser synthesizes it.
                if run.italic { a[.obliqueness] = 0.16 }
                out.append(NSAttributedString(string: text, attributes: a))
            }
        }
        // The emoji a model writes are drawn as our symbols (EmojiIcons); copy keeps the emoji.
        for piece in EmojiIcons.pieces(text) {
            switch piece {
            case .text(let t):
                appendText(t)
            case .icon(let icon, let original):
                guard let cell = EmojiIconCell(icon: icon, original: original, font: font, tint: AnswerInk.tone(icon.tone)) else {
                    appendText(original); continue
                }
                let att = NSTextAttachment()
                att.attachmentCell = cell
                let a = NSMutableAttributedString(attributedString: NSAttributedString(attachment: att))
                a.addAttributes([.font: font], range: NSRange(location: 0, length: a.length))
                out.append(a)
            }
        }
    }

    private static func appendChip(_ spec: ChipSpec, base: NSFont, to out: NSMutableAttributedString) {
        let att = NSTextAttachment()
        att.attachmentCell = ChipCell(spec: spec)
        let a = NSMutableAttributedString(attributedString: NSAttributedString(attachment: att))
        var attrs: [NSAttributedString.Key: Any] = [.font: base]
        if spec.action != nil { attrs[.cursor] = NSCursor.pointingHand }
        a.addAttributes(attrs, range: NSRange(location: 0, length: a.length))
        out.append(a)
    }
}

/// ("opening an agent is slow"): every agent message's text was built again (chips measured, emoji
/// drawn, fonts looked up) each time a dialogue opened - the sheet is made anew on each open. Built once per input and
/// kept (at most `cap` texts; the oldest half goes past it).
@MainActor
final class AnswerAttrCache {
    static let shared = AnswerAttrCache()
    private var byText: [String: [(input: AnswerText.Input, out: NSAttributedString, tick: Int)]] = [:]
    private var count = 0
    private var tick = 0
    private static let cap = 1500

    func text(_ input: AnswerText.Input) -> NSAttributedString {
        // the workspace in front's repositories: an "owner/name" or a commit sha of theirs in the text is a GitHub chip
        KnownRepos.shared.setPreferred(WorkspaceModel.current?.profile?.githubRepos.map(\.fullName) ?? [])
        tick &+= 1
        if var list = byText[input.text], let i = list.firstIndex(where: { $0.input == input }) {
            list[i].tick = tick
            byText[input.text] = list
            return list[i].out
        }
        let out = AnswerAttr.make(input.text, style: input.style, ents: input.ents, groups: input.groups)
        byText[input.text, default: []].append((input, out, tick))
        count += 1
        if count > Self.cap { trim() }
        return out
    }

    private func trim() {
        let all = byText.values.flatMap { $0.map(\.tick) }.sorted()
        guard all.count > Self.cap / 2 else { return }
        let keepFrom = all[all.count - Self.cap / 2]
        var n = 0
        for (k, list) in byText {
            let kept = list.filter { $0.tick >= keepFrom }
            byText[k] = kept.isEmpty ? nil : kept
            n += kept.count
        }
        count = n
    }
}

extension NSAttributedString.Key {
    /// AnswerFlow: the space above a block (CSS px), on the block's first character; CSSLineBoxes adds it to the
    /// block's first line box.
    static let liaBlockGap = NSAttributedString.Key("liaBlockGap")
    /// AnswerFlow: the line end between two blocks. True: copied as a blank line (two paragraphs); false: one line end
    /// (two items of a list).
    static let liaBlockBreak = NSAttributedString.Key("liaBlockBreak")
}

// MARK: CSS line boxes

/// Every line fragment as tall as the CSS line box: the block's strut (its own face at its size), every font on the line
/// centred in factor x its size, every chip on its baseline; the tallest above and below the baseline win.
final class CSSLineBoxes: NSObject, NSLayoutManagerDelegate {
    var factor: CGFloat = 1.72
    var strut: NSFont = .systemFont(ofSize: 16)
    /// The clear space a chip keeps above and below it inside its line box.
    static let chipPad: CGFloat = 2.5

    func layoutManager(_ layoutManager: NSLayoutManager,
                       shouldSetLineFragmentRect lineFragmentRect: UnsafeMutablePointer<NSRect>,
                       lineFragmentUsedRect: UnsafeMutablePointer<NSRect>,
                       baselineOffset: UnsafeMutablePointer<CGFloat>,
                       in textContainer: NSTextContainer,
                       forGlyphRange glyphRange: NSRange) -> Bool {
        guard let ts = layoutManager.textStorage else { return false }
        let chars: NSRange = layoutManager.characterRange(forGlyphRange: glyphRange, actualGlyphRange: nil)
        let s = AnswerFonts.box(strut, factor: factor)
        var above: CGFloat = s.above
        var below: CGFloat = s.below
        let f = factor
        let pad: CGFloat = Self.chipPad
        ts.enumerateAttributes(in: chars, options: []) { attrs, _, _ in
            // (chips on consecutive lines collided): a line holding a chip keeps `chipPad` clear above
            // and below it, so two chips on two lines never touch and each stays inside its own line box.
            if let att = attrs[.attachment] as? NSTextAttachment, let cell = att.attachmentCell as? ChipCell {
                above = max(above, cell.spec.ascent + pad)
                below = max(below, cell.spec.descent + pad)
                return
            }
            // Any other inline cell (an emoji drawn as a symbol) holds its own box too.
            if let att = attrs[.attachment] as? NSTextAttachment, let cell = att.attachmentCell {
                let sz: NSSize = cell.cellSize()
                let off: CGFloat = cell.cellBaselineOffset().y
                above = max(above, sz.height + off)
                below = max(below, -off)
            }
            if let font = attrs[.font] as? NSFont {
                let b = AnswerFonts.box(font, factor: f)
                above = max(above, b.above)
                below = max(below, b.below)
            }
        }
        // AnswerFlow: the space above a block goes on its first line box (one text view holds several blocks).
        var gap: CGFloat = 0
        if chars.length > 0, chars.location < ts.length,
           let g = ts.attribute(.liaBlockGap, at: chars.location, effectiveRange: nil) as? NSNumber {
            gap = CGFloat(g.doubleValue)
        }
        let h: CGFloat = above + below + gap
        lineFragmentRect.pointee.size.height = h
        lineFragmentUsedRect.pointee.size.height = h
        baselineOffset.pointee = above + gap
        return true
    }
}

// MARK: the view

final class AnswerTextNSView: NSTextView {
    /// A text view placed in the thread scrolled the whole thread to its insertion point when it appeared - opening a
    /// thought in "Worked" threw the reader up the page. Only a drag-selection may scroll.
    override func scrollRangeToVisible(_ range: NSRange) {
        if NSApp.currentEvent?.type == .leftMouseDragged { super.scrollRangeToVisible(range) }
    }
    override func scrollToVisible(_ rect: NSRect) -> Bool {
        NSApp.currentEvent?.type == .leftMouseDragged ? super.scrollToVisible(rect) : false
    }
    let boxes = CSSLineBoxes()
    var storageRef: NSTextStorage?
    var wraps = true
    var onChip: ((ChipAction, NSRect) -> Void)?
    /// Set in the messenger (the row's menu and selection); nil elsewhere keeps AppKit's own behaviour.
    weak var hooks: AnswerTextHooks? {
        didSet { if hooks !== oldValue { hooks?.register(self) } }
    }
    /// The selection last reported to `hooks` (reported only when it changes).
    private var reportedSelection = ""
    var hoverIndex: Int? {
        didSet {
            guard oldValue != hoverIndex else { return }
            needsDisplay = true
            // The chip's card after a short rest of the pointer (ChipHoverHost)
            if let ci = hoverIndex, let c = cell(at: ci), let h = c.spec.hover {
                ChipHoverHost.shared.hover(h, anchor: screenRect(ofChar: ci), in: window, owner: self)
            } else {
                ChipHoverHost.shared.leave(self)
            }
        }
    }
    private var hoverArea: NSTrackingArea?
    private var minContent: CGFloat?

    static func make() -> AnswerTextNSView {
        let storage = NSTextStorage()
        let lm = NSLayoutManager()
        lm.usesFontLeading = false
        storage.addLayoutManager(lm)
        let tc = NSTextContainer(size: NSSize(width: 100, height: CGFloat.greatestFiniteMagnitude))
        tc.lineFragmentPadding = 0
        tc.widthTracksTextView = false
        tc.heightTracksTextView = false
        lm.addTextContainer(tc)
        let v = AnswerTextNSView(frame: NSRect(x: 0, y: 0, width: 100, height: 20), textContainer: tc)
        v.storageRef = storage
        lm.delegate = v.boxes
        v.isEditable = false
        v.isSelectable = true
        v.drawsBackground = false
        v.importsGraphics = false
        v.textContainerInset = .zero
        v.isVerticallyResizable = false
        v.isHorizontallyResizable = false
        v.focusRingType = .none
        v.usesFontPanel = false
        v.allowsUndo = false
        v.isAutomaticLinkDetectionEnabled = false
        return v
    }

    func load(_ text: NSAttributedString, style: AnswerStyle) {
        boxes.factor = style.factor
        boxes.strut = style.font()
        wraps = style.wraps
        minContent = nil
        hoverIndex = nil
        textStorage?.setAttributedString(text)
        syncContainer(width: bounds.width)
        layoutManager?.invalidateLayout(forCharacterRange: NSRange(location: 0, length: textStorage?.length ?? 0), actualCharacterRange: nil)
        invalidateIntrinsicContentSize()
        needsDisplay = true
    }

    private func syncContainer(width: CGFloat) {
        guard let tc = textContainer else { return }
        let w: CGFloat = wraps ? max(1, width) : 1e7
        if abs(tc.size.width - w) > 0.25 { tc.size = NSSize(width: w, height: CGFloat.greatestFiniteMagnitude) }
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        syncContainer(width: newSize.width)
    }

    /// (messages drawn as empty bubbles): a text view put into a window again draws itself again; with
    /// nothing else may invalidate it, and the layer it had can be empty.
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil { needsDisplay = true }
    }

    /// The height at a width (nil: one line per paragraph, the natural width). The container goes back to the
    /// view's own width afterwards, so a measurement never leaves the drawn layout at another width.
    /// measured every time again. The per-width cache of dcf82d7 (for the kept threads,
    /// now off) came with messages taller than their text - a bubble with empty space under its last line.
    func measure(width: CGFloat?) -> NSSize {
        guard let lm = layoutManager, let tc = textContainer else { return .zero }
        let saved: NSSize = tc.size
        let w: CGFloat = wraps ? max(1, width ?? 1e7) : 1e7
        if abs(tc.size.width - w) > 0.25 { tc.size = NSSize(width: w, height: CGFloat.greatestFiniteMagnitude) }
        lm.ensureLayout(for: tc)
        let used: NSRect = lm.usedRect(for: tc)
        if abs(saved.width - tc.size.width) > 0.25 { tc.size = saved }
        return NSSize(width: ceil(used.width), height: ceil(used.height))
    }

    /// CSS min-content: the widest piece that cannot break (a word, a chip), plus a list's indent.
    func minContentWidth() -> CGFloat {
        if let m = minContent { return m }
        guard let ts = textStorage else { return 0 }
        if !wraps { let m = measure(width: nil).width; minContent = m; return m }
        let str = ts.string as NSString
        var best: CGFloat = 0
        var start = 0
        let n = str.length
        var i = 0
        while i <= n {
            let c: unichar = i == n ? 0x20 : str.character(at: i)
            let isAttachment = c == 0xFFFC
            if c == 0x20 || c == 0x0A || c == 0x09 || isAttachment {
                if i > start {
                    best = max(best, ceil(ts.attributedSubstring(from: NSRange(location: start, length: i - start)).size().width))
                }
                if isAttachment, let att = ts.attribute(.attachment, at: i, effectiveRange: nil) as? NSTextAttachment,
                   let cell = att.attachmentCell as? ChipCell {
                    best = max(best, ceil(cell.spec.size.width))
                }
                start = i + 1
            }
            i += 1
        }
        if let p = ts.length > 0 ? ts.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle : nil {
            best += p.headIndent
        }
        minContent = best
        return best
    }

    // MARK: chips under the pointer

    private func chipIndex(at p: NSPoint) -> Int? {
        guard let lm = layoutManager, let tc = textContainer, let ts = textStorage, ts.length > 0 else { return nil }
        let o = textContainerOrigin
        let pt = NSPoint(x: p.x - o.x, y: p.y - o.y)
        var frac: CGFloat = 0
        let g: Int = lm.glyphIndex(for: pt, in: tc, fractionOfDistanceThroughGlyph: &frac)
        guard g < lm.numberOfGlyphs else { return nil }
        let r: NSRect = lm.boundingRect(forGlyphRange: NSRange(location: g, length: 1), in: tc)
        guard r.contains(pt) else { return nil }
        let ci: Int = lm.characterIndexForGlyph(at: g)
        guard ci < ts.length, cell(at: ci) != nil else { return nil }
        return ci
    }

    private func cell(at ci: Int) -> ChipCell? {
        guard let ts = textStorage, ci < ts.length,
              let att = ts.attribute(.attachment, at: ci, effectiveRange: nil) as? NSTextAttachment else { return nil }
        return att.attachmentCell as? ChipCell
    }

    private func screenRect(ofChar ci: Int) -> NSRect {
        guard let lm = layoutManager, let tc = textContainer, let w = window else { return .zero }
        let g: Int = lm.glyphIndexForCharacter(at: ci)
        var r: NSRect = lm.boundingRect(forGlyphRange: NSRange(location: g, length: 1), in: tc)
        r.origin.x += textContainerOrigin.x
        r.origin.y += textContainerOrigin.y
        return w.convertToScreen(convert(r, to: nil))
    }

    /// The chip the last press acted on (LiaClicks.chipFires: the second press of a double click on it does nothing).
    private var lastChip: Int?

    /// 0.2.11: a chip acts on the click that brings the window forward too (it used to only activate the window,
    /// and the marketer clicked "again").
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        if let e = event, chipIndex(at: convert(e.locationInWindow, from: nil)) != nil { return true }
        return super.acceptsFirstMouse(for: event)
    }

    override func mouseDown(with event: NSEvent) {
        ChipHoverHost.shared.dismiss()
        let p = convert(event.locationInWindow, from: nil)
        if let ci = chipIndex(at: p), let c = cell(at: ci), let action = c.spec.action {
            // 0.2.11: any press on a chip acts, except the second press of a double click on the same chip (before,
            // every press with a click count of 2 fell through to the text and did nothing).
            guard LiaClicks.chipFires(clickCount: event.clickCount, chip: ci, lastFired: lastChip) else { return }
            lastChip = ci
            if case .file(let f) = action {
                CanvasFileOpen.open(f)
                return
            }
            if case .copy(let s) = action {
                Clipboard.copy(s)
                c.spec.copiedUntil = Date().addingTimeInterval(1.4)
                needsDisplay = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.45) { [weak self] in self?.needsDisplay = true }
                return
            }
            onChip?(action, screenRect(ofChar: ci))
            return
        }
        lastChip = nil
        // In the messenger text is selected by press-and-drag only; a double or triple click selects
        // nothing (it used to select a word, then a right-click showed AppKit's text menu instead of ours).
        if hooks != nil && event.clickCount >= 2 { return }
        super.mouseDown(with: event)
    }

    // MARK: the messenger's menu

    /// A right-click shows the row's menu (Telegram-like), never AppKit's text menu; AppKit's own right-click would
    /// also select the word under the pointer first.
    override func rightMouseDown(with event: NSEvent) {
        if hooks != nil, let m = menu(for: event) {
            NSMenu.popUpContextMenu(m, with: event, for: self)
            return
        }
        super.rightMouseDown(with: event)
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        if let h = hooks, let make = h.menu, let m = make(plainSelection(), self) { return m }
        return super.menu(for: event)
    }

    override func setSelectedRanges(_ ranges: [NSValue], affinity: NSSelectionAffinity, stillSelecting: Bool) {
        super.setSelectedRanges(ranges, affinity: affinity, stillSelecting: stillSelecting)
        guard hooks != nil, !stillSelecting else { return }
        let now = plainSelection()
        guard now != reportedSelection else { return }
        reportedSelection = now
        // Off the current pass: a selection reset inside a SwiftUI update must not write the row's state there.
        DispatchQueue.main.async { [weak self] in self?.hooks?.onSelection?(now) }
    }

    /// The menu's Select: all the text of this block, as a selection the person then copies, quotes or forwards.
    func selectAllText() {
        window?.makeFirstResponder(self)
        selectAll(nil)
    }

    /// One tracking area for the view's life (`.inVisibleRect` follows the visible part by itself). It used to be made
    /// again on every layout pass, and each new one sent exit / enter / cursor updates of its own (the flicker).
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        guard hoverArea == nil else { return }
        let t = NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
                               owner: self, userInfo: nil)
        addTrackingArea(t)
        hoverArea = t
    }

    // MARK: the cursor: AppKit's own
    // The system I-beam and, on a chip, the hand (its `.cursor` attribute), both as NSTextView's cursor rects - nothing
    // is set on a move. Under a modal, a popup or the media library drawn over the thread (SwiftUI in the same window,
    // ) the rects are taken back, so what is on top shows its own cursor (LiaTextCursorRects).
    private var cursorRects = LiaTextCursorRects()

    override func resetCursorRects() {
        guard !cursorRects.covered else { return }
        super.resetCursorRects()
    }

    override func mouseEntered(with event: NSEvent) {
        super.mouseEntered(with: event)
        _ = cursorRects.update(self, event)
    }

    override func mouseMoved(with event: NSEvent) {
        _ = cursorRects.update(self, event)
        guard !cursorRects.covered else {
            hoverIndex = nil
            return
        }
        super.mouseMoved(with: event)
        let ci = chipIndex(at: convert(event.locationInWindow, from: nil))
        if ci != hoverIndex { hoverIndex = ci }
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        hoverIndex = nil
    }

    /// Like text in a page: a selection goes when the reader clicks elsewhere.
    override func resignFirstResponder() -> Bool {
        let ok = super.resignFirstResponder()
        if ok { setSelectedRange(NSRange(location: 0, length: 0)) }
        return ok
    }

    // MARK: copy: chips as their words

    override var writablePasteboardTypes: [NSPasteboard.PasteboardType] { [.string] }

    override func writeSelection(to pboard: NSPasteboard, type: NSPasteboard.PasteboardType) -> Bool {
        guard type == .string else { return super.writeSelection(to: pboard, type: type) }
        pboard.setString(plainSelection(), forType: .string)
        return true
    }

    func plainSelection() -> String {
        guard let ts = textStorage else { return "" }
        var out = ""
        for v in selectedRanges {
            let r = v.rangeValue
            guard r.length > 0, r.location + r.length <= ts.length else { continue }
            ts.enumerateAttributes(in: r, options: []) { attrs, sub, _ in
                if let att = attrs[.attachment] as? NSTextAttachment, let c = att.attachmentCell as? ChipCell {
                    out += c.spec.plain
                } else if let att = attrs[.attachment] as? NSTextAttachment, let c = att.attachmentCell as? EmojiIconCell {
                    out += c.original
                } else if let blank = attrs[.liaBlockBreak] as? Bool {
                    out += blank ? "\n\n" : "\n"   // AnswerFlow: paragraphs part by a blank line, list items by a line end
                } else {
                    out += (ts.string as NSString).substring(with: sub)
                }
            }
        }
        return Self.plainLines(out)
    }

    /// Copied text as words: a line break inside a block is a line end, and a list marker's tabs ("\t•\t") are
    /// layout - "• item".
    static func plainLines(_ s: String) -> String {
        let lines = s.replacingOccurrences(of: "\u{2028}", with: "\n").components(separatedBy: "\n").map { l -> String in
            guard l.hasPrefix("\t") else { return l.replacingOccurrences(of: "\t", with: " ") }
            return String(l.drop(while: { $0 == "\t" })).replacingOccurrences(of: "\t", with: " ")
        }
        return lines.joined(separator: "\n").trimmingCharacters(in: .whitespaces)
    }
}

/// One block of an answer: its text, chips and line boxes. Fills the proposed width; nil gives the natural width
/// (one line per paragraph) and zero the CSS min-content width, which the table layout asks for.
struct AnswerText: NSViewRepresentable {
    let text: String
    var style = AnswerStyle()
    var ents: [String: ChatEntity] = [:]
    var groups: [[ChatCite]] = []
    var onChip: (ChipAction, NSRect) -> Void = { _, _ in }

    struct Input: Equatable {
        let text: String
        let style: AnswerStyle
        let ents: [String: ChatEntity]
        let groups: [[ChatCite]]
    }

    final class Coordinator {
        var input: Input?
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> AnswerTextNSView {
        let v = AnswerTextNSView.make()
        v.hooks = context.environment.answerTextHooks
        apply(v, context.coordinator)
        return v
    }

    func updateNSView(_ nsView: AnswerTextNSView, context: Context) {
        nsView.hooks = context.environment.answerTextHooks
        apply(nsView, context.coordinator)
    }

    private func apply(_ v: AnswerTextNSView, _ c: Coordinator) {
        v.onChip = onChip
        let input = Input(text: text, style: style, ents: ents, groups: groups)
        guard c.input != input else { return }
        c.input = input
        v.load(AnswerAttrCache.shared.text(input), style: style)
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: AnswerTextNSView, context: Context) -> CGSize? {
        Self.fit(proposal, nsView)
    }

    /// The proposed width filled (nil: the natural width, zero: CSS min-content), as tall as the text there.
    static func fit(_ proposal: ProposedViewSize, _ nsView: AnswerTextNSView) -> CGSize {
        if let w = proposal.width, w <= 0.5 {
            let m: CGFloat = nsView.minContentWidth()
            return CGSize(width: m, height: nsView.measure(width: m).height)
        }
        if let w = proposal.width, w.isFinite {
            let s: NSSize = nsView.measure(width: w)
            return CGSize(width: nsView.wraps ? w : s.width, height: s.height)
        }
        let s: NSSize = nsView.measure(width: nil)
        return CGSize(width: s.width, height: s.height)
    }
}

/// (0.2.11: a message could only be selected a paragraph at a time): a run of an answer's text blocks
/// Paragraphs, headings, list items - in ONE text view, so a selection goes across them, ⌘A selects the run and a
/// copy keeps the paragraphs. Each block keeps its own style (a list item its marker and indent); the site's margins
/// between blocks are on each block's first line box (`.liaBlockGap`, CSSLineBoxes); a line break inside a block is a
/// line separator (the site's <br>), not a new paragraph. Chips are the same attachment cells, clicked as before.
struct AnswerFlow: NSViewRepresentable {
    struct Item: Equatable {
        var text: String
        var style: AnswerStyle
        /// The space above this block (0 for the first).
        var gap: CGFloat = 0
        /// The break before it is between paragraphs (copied as a blank line); false between two list items.
        var blank = true
    }

    let items: [Item]
    /// The run's base style: its line-height factor and the strut every line box has at least.
    var strut = AnswerStyle()
    var ents: [String: ChatEntity] = [:]
    var groups: [[ChatCite]] = []
    var onChip: (ChipAction, NSRect) -> Void = { _, _ in }

    struct Input: Equatable {
        let items: [Item]
        let strut: AnswerStyle
        let ents: [String: ChatEntity]
        let groups: [[ChatCite]]
    }

    final class Coordinator {
        var input: Input?
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> AnswerTextNSView {
        let v = AnswerTextNSView.make()
        v.hooks = context.environment.answerTextHooks
        apply(v, context.coordinator)
        return v
    }

    func updateNSView(_ nsView: AnswerTextNSView, context: Context) {
        nsView.hooks = context.environment.answerTextHooks
        apply(nsView, context.coordinator)
    }

    private func apply(_ v: AnswerTextNSView, _ c: Coordinator) {
        v.onChip = onChip
        let input = Input(items: items, strut: strut, ents: ents, groups: groups)
        guard c.input != input else { return }
        c.input = input
        v.load(AnswerFlowCache.shared.text(input), style: strut)
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: AnswerTextNSView, context: Context) -> CGSize? {
        AnswerText.fit(proposal, nsView)
    }

    /// The run as one attributed string (each block from AnswerAttrCache).
    @MainActor static func make(_ input: Input) -> NSAttributedString {
        let out = NSMutableAttributedString()
        for it in input.items {
            let piece = AnswerAttrCache.shared.text(AnswerText.Input(text: it.text, style: it.style, ents: input.ents, groups: input.groups))
            guard piece.length > 0 else { continue }
            if out.length > 0 {
                // The paragraph end belongs to the block before: its face, colour and paragraph style.
                let last = out.attributes(at: out.length - 1, effectiveRange: nil)
                var a: [NSAttributedString.Key: Any] = [.liaBlockBreak: it.blank]
                for k in [NSAttributedString.Key.font, .paragraphStyle, .foregroundColor] { if let v = last[k] { a[k] = v } }
                out.append(NSAttributedString(string: "\n", attributes: a))
            }
            let start = out.length
            out.append(piece)
            _ = out.mutableString.replaceOccurrences(of: "\n", with: "\u{2028}", options: [], range: NSRange(location: start, length: piece.length))
            if start > 0, it.gap > 0 { out.addAttribute(.liaBlockGap, value: NSNumber(value: Double(it.gap)), range: NSRange(location: start, length: 1)) }
        }
        return out
    }
}

/// AnswerFlow's strings, built once per run (as AnswerAttrCache keeps the blocks): at most `cap`, cleared past it.
@MainActor
final class AnswerFlowCache {
    static let shared = AnswerFlowCache()
    private var byKey: [String: [(input: AnswerFlow.Input, out: NSAttributedString)]] = [:]
    private var count = 0
    private static let cap = 600

    func text(_ input: AnswerFlow.Input) -> NSAttributedString {
        let key = input.items.map(\.text).joined(separator: "\u{1}")
        if let hit = byKey[key]?.first(where: { $0.input == input }) { return hit.out }
        let out = AnswerFlow.make(input)
        if count >= Self.cap { byKey.removeAll(keepingCapacity: true); count = 0 }
        byKey[key, default: []].append((input, out))
        count += 1
        return out
    }
}

// MARK: the messenger's hooks

/// How one messenger row reaches the text views of its message (AnswerText and ChatPlainText read it from the
/// environment): its right-click menu (built for the text selected in that view, "" for none), the selection as it
/// changes, and the views themselves for the menu's Select. Outside the messenger it is nil and nothing changes.
final class AnswerTextHooks {
    var menu: ((String, AnswerTextNSView) -> NSMenu?)?
    var onSelection: ((String) -> Void)?
    private let views = NSHashTable<AnswerTextNSView>.weakObjects()

    @MainActor func register(_ v: AnswerTextNSView) { views.add(v) }

    /// Select from the bubble (not over its text): all the text of the message's first text block.
    @MainActor func selectFirst() {
        views.allObjects.first { $0.window != nil }?.selectAllText()
    }
}

private struct AnswerTextHooksKey: EnvironmentKey { static let defaultValue: AnswerTextHooks? = nil }

extension EnvironmentValues {
    var answerTextHooks: AnswerTextHooks? {
        get { self[AnswerTextHooksKey.self] }
        set { self[AnswerTextHooksKey.self] = newValue }
    }
}

/// The person's own words in the messenger bubble as a text view, so they select like an agent's (press and
/// drag, no double-click word) and a right-click on them shows the row's menu. Hugs its text: as wide as its widest
/// line, at most the proposed width.
/// Fix (the bubble collapsed to a one-character column): the size is measured on a text system of
/// its own (`ChatPlainText.size`), never on the view's, whose container follows whatever frame SwiftUI last gave the
/// view (a zero-width first frame left a one-point container). A width probe (0 or none) answers the natural width,
/// like Text; a proposal narrower than one character is not honoured either.
struct ChatPlainText: NSViewRepresentable {
    let text: String
    var size: CGFloat = 14
    var color: NSColor = .white
    /// The selection's background over the colour of the bubble.
    var selection: NSColor = NSColor.white.withAlphaComponent(0.32)
    var factor: CGFloat = 1.4

    final class Coordinator {
        var key: String?
        /// Sizes measured for the current text, by width (-1: the natural width).
        var sizes: [CGFloat: CGSize] = [:]
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> AnswerTextNSView {
        let v = AnswerTextNSView.make()
        v.hooks = context.environment.answerTextHooks
        apply(v, context.coordinator)
        return v
    }

    func updateNSView(_ nsView: AnswerTextNSView, context: Context) {
        nsView.hooks = context.environment.answerTextHooks
        apply(nsView, context.coordinator)
    }

    private var style: AnswerStyle { AnswerStyle(face: .ui, size: size, factor: factor) }

    private var attributed: NSAttributedString {
        NSAttributedString(string: text, attributes: [.font: style.font(), .foregroundColor: color])
    }

    private func apply(_ v: AnswerTextNSView, _ c: Coordinator) {
        v.selectedTextAttributes = [.backgroundColor: selection, .foregroundColor: color]
        let key = "\(size)|\(factor)|" + text
        guard c.key != key else { return }
        c.key = key
        c.sizes = [:]
        v.load(attributed, style: style)
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: AnswerTextNSView, context: Context) -> CGSize? {
        let c = context.coordinator
        let natural: CGSize = measured(nil, c)
        guard let w = proposal.width, w.isFinite, w > 0.5, w < natural.width else { return natural }
        // Never narrower than about two characters: a stray tiny proposal must not build a one-letter column.
        let floor: CGFloat = ceil(size * 1.6)
        return measured(max(w, min(floor, natural.width)), c)
    }

    private func measured(_ width: CGFloat?, _ c: Coordinator) -> CGSize {
        let k: CGFloat = width.map { ($0 * 2).rounded(.down) / 2 } ?? -1
        if let s = c.sizes[k] { return s }
        let s = Self.size(attributed, style: style, width: width)
        if c.sizes.count > 24 { c.sizes = [:] }
        c.sizes[k] = s
        return s
    }

    /// The text's used size at a width (nil: one line per paragraph) on a fresh text system with the view's line
    /// boxes (CSSLineBoxes), so it matches what the view draws at that width.
    static func size(_ attr: NSAttributedString, style: AnswerStyle, width: CGFloat?) -> CGSize {
        let storage = NSTextStorage(attributedString: attr)
        let lm = NSLayoutManager()
        lm.usesFontLeading = false
        let boxes = CSSLineBoxes()
        boxes.factor = style.factor
        boxes.strut = style.font()
        lm.delegate = boxes
        storage.addLayoutManager(lm)
        let tc = NSTextContainer(size: NSSize(width: max(1, width ?? 1e7), height: CGFloat.greatestFiniteMagnitude))
        tc.lineFragmentPadding = 0
        lm.addTextContainer(tc)
        let used: NSRect = withExtendedLifetime(boxes) {
            lm.ensureLayout(for: tc)
            return lm.usedRect(for: tc)
        }
        return CGSize(width: ceil(used.width), height: ceil(used.height))
    }
}

// MARK: the source card (ai.js citeChipHTML's .ai__cite__c)

@MainActor
enum CiteCard {
    /// Under the chip, its left edge 8 px left of the chip's, 7 px below it (.ai__cite__c left:-8px, padding-top 7).
    static func show(_ group: [ChatCite], anchor: NSRect, open: @escaping (URL) -> Void) {
        guard !group.isEmpty else { return }
        let window: NSWindow? = NSApp.mainWindow ?? NSApp.keyWindow
        let a = NSRect(x: anchor.minX - 8, y: anchor.minY, width: anchor.width, height: anchor.height)
        DropdownHost.shared.toggle("cite:" + group[0].url, anchor: a, in: window, edge: .below, align: .leading, gap: 7) {
            CiteCardView(group: group, open: open)
        }
    }
}

/// dd-bg, 1 px line-2, radius 13, 392 wide; up to four rows, each the letter tile and the domain over the page title.
/// It fades in and settles 4 px, as the site's card does (opacity and transform over .11 s).
struct CiteCardView: View {
    let group: [ChatCite]
    let open: (URL) -> Void
    @State private var shown = false

    var body: some View {
        DropdownPanelView(width: 392, padding: 0, radius: 13) {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(group.prefix(4).enumerated()), id: \.offset) { i, c in
                    CiteCardRow(cite: c, divider: i > 0, open: open)
                }
            }
            .padding(.vertical, 6)
        }
        .opacity(shown ? 1 : 0)
        .offset(y: shown ? 0 : -4)
        .onAppear { withAnimation(.easeOut(duration: 0.11)) { shown = true } }
    }
}

/// .ai__cite__i: margin 0 6, padding 10 11, radius 9, hover rgba(127,127,127,.12), a 1 px --line rule between rows;
/// .ai__cite__top (tile + domain 12.5 --text-3, gap 7, 5 below), .ai__cite__t 14 / 1.35 --text. In the answer face.
private struct CiteCardRow: View {
    let cite: ChatCite
    let divider: Bool
    let open: (URL) -> Void
    @State private var hover = false

    private var dom: String { cite.host.hasPrefix("www.") ? String(cite.host.dropFirst(4)) : cite.host }

    var body: some View {
        Button {
            DropdownHost.shared.close()
            if let u = URL(string: cite.url) { open(u) }
        } label: {
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 7) {
                    Text(verbatim: String(dom.prefix(1)).uppercased())
                        .font(LiaFont.inter(8.5, .semibold))
                        .foregroundStyle(AppConfig.text2)
                        .frame(width: 15, height: 15)
                        .background(RoundedRectangle(cornerRadius: 4).fill(Color(white: 0.5).opacity(0.26)))
                    Text(verbatim: dom).font(LiaFont.ui(12.5)).foregroundStyle(AppConfig.text3).lineLimit(1)
                }
                Text(verbatim: cite.title.isEmpty ? dom : cite.title)
                    .font(LiaFont.ui(14)).lineSpacing(3.5).foregroundStyle(AppConfig.ink)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 11).padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 9).fill(hover ? Color(white: 0.5).opacity(0.12) : Color.clear))
            .overlay(alignment: .top) {
                if divider { Rectangle().fill(AppConfig.line).frame(height: 1) }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.liaPlain)
        .padding(.horizontal, 6)
        .onHover { hover = $0 }
        .liaPointer()
        .accessibilityLabel(cite.title.isEmpty ? dom : cite.title)
    }
}
