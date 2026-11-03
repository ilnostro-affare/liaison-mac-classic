import Foundation

// Lia's answer, inline, as ai.js draws it: withCites = citeMark (sources placed by their offsets) -> mdLite (mdInline:
// code, links, **bold**, *italic*) -> chipIds -> entifyHtml -> citeSwap. Pure: the views turn the pieces into pixels.

/// ai.js citeMark (/ /): each url_citation becomes a marker in the raw text at its offsets, before any
/// markdown is read, applied from the end backwards so earlier offsets stay valid. A citation whose span IS the model's
/// own markdown link replaces that link; any other is inserted after its span, pushed out of a link or url it fell into.
/// Offsets that do not fit the text put the whole set in one group at the end.
enum CiteMark {
    static let mark = "\u{E0C1}"

    struct Result: Equatable {
        let text: String
        let groups: [[ChatCite]]
    }

    private static let safeRx = try! NSRegularExpression(pattern: #"\[[^\]]*\]\([^)\s]*\)|https?://[^\s)<>"']+"#)
    private static let linkSpanRx = try! NSRegularExpression(pattern: #"^\(?\[[^\]]*\]\([^)\s]*\)\)?$"#)

    /// citeSafeAt: an offset inside a markdown link or a bare url moves to just past it.
    static func safeAt(_ t: NSString, _ pos: Int) -> Int {
        for m in safeRx.matches(in: t as String, range: NSRange(location: 0, length: t.length)) {
            let a = m.range.location, b = m.range.location + m.range.length
            if pos > a && pos < b { return b }
            if a > pos { break }
        }
        return pos
    }

    static func apply(_ text: String, cites: [ChatCite]) -> Result {
        let list = cites.filter { !$0.url.isEmpty }
        guard !list.isEmpty else { return Result(text: text, groups: []) }
        let t = text as NSString
        let len = t.length
        guard list.allSatisfy({ $0.e > 0 && $0.e <= len }) else {
            return Result(text: text + mark + "0" + mark, groups: [list])
        }
        struct Edit { let a: Int; let b: Int; var g: [ChatCite] }
        var edits: [Edit] = []
        var byEnd: [Int: Int] = [:]      // insertion offset -> index in edits
        var bySpan: [String: Int] = [:]  // "a:b" -> index in edits
        for c in list {
            let a = max(0, min(len, c.s)), b = max(0, min(len, c.e))
            let span = t.substring(with: NSRange(location: a, length: max(0, b - a))).trimmingCharacters(in: .whitespacesAndNewlines)
            let isLink = b > a && linkSpanRx.firstMatch(in: span, range: NSRange(location: 0, length: (span as NSString).length)) != nil
            if isLink {
                let k = "\(a):\(b)"
                if let i = bySpan[k] { edits[i].g.append(c) } else { bySpan[k] = edits.count; edits.append(Edit(a: a, b: b, g: [c])) }
                continue
            }
            let k = safeAt(t, b)
            if let i = byEnd[k] { edits[i].g.append(c) } else { byEnd[k] = edits.count; edits.append(Edit(a: k, b: k, g: [c])) }
        }
        // From the end backwards; JS sort is stable, so equal starts keep the order they were made in.
        let sorted = edits.enumerated().sorted { l, r in l.element.a != r.element.a ? l.element.a > r.element.a : l.offset < r.offset }.map(\.element)
        var out = t as String
        var groups: [[ChatCite]] = []
        for ed in sorted {
            let gi = groups.count
            groups.append(ed.g)
            let o = out as NSString
            out = o.substring(to: ed.a) + mark + String(gi) + mark + o.substring(from: ed.b)
        }
        return Result(text: out, groups: groups)
    }
}

/// mdInline's inline styles, the site's own three rules and nothing more (no escapes, no underscores):
/// `code` first, then **bold**, then *italic* where a space or "(" opens it and a space or punctuation closes it.
struct StyledRun: Equatable {
    var text: String
    var bold = false
    var italic = false
    var code = false
}

enum InlineStyle {
    private static let codeRx = try! NSRegularExpression(pattern: #"`([^`]+)`"#)
    private static let boldRx = try! NSRegularExpression(pattern: #"\*\*([^*]+)\*\*"#)
    private static let italicRx = try! NSRegularExpression(pattern: #"(^|[\s(])\*([^*\n]+)\*(?=[\s.,;:)!?]|$)"#)

    static func runs(_ s: String) -> [StyledRun] {
        var out: [StyledRun] = []
        func push(_ r: StyledRun) {
            guard !r.text.isEmpty else { return }
            if let last = out.last, last.bold == r.bold, last.italic == r.italic, last.code == r.code {
                out[out.count - 1].text += r.text
            } else {
                out.append(r)
            }
        }
        split(s, codeRx) { piece, isCode in
            if isCode { push(StyledRun(text: piece, code: true)); return }
            split(piece, boldRx) { p2, isBold in
                italics(p2) { p3, isItalic in push(StyledRun(text: p3, bold: isBold, italic: isItalic)) }
            }
        }
        return out
    }

    /// Calls `f` with the text between matches (false) and each match's first group (true), in order.
    private static func split(_ s: String, _ rx: NSRegularExpression, _ f: (String, Bool) -> Void) {
        let ns = s as NSString
        var cursor = 0
        for m in rx.matches(in: s, range: NSRange(location: 0, length: ns.length)) {
            if m.range.location > cursor { f(ns.substring(with: NSRange(location: cursor, length: m.range.location - cursor)), false) }
            f(ns.substring(with: m.range(at: 1)), true)
            cursor = m.range.location + m.range.length
        }
        if cursor < ns.length { f(ns.substring(from: cursor), false) }
    }

    private static func italics(_ s: String, _ f: (String, Bool) -> Void) {
        let ns = s as NSString
        var cursor = 0
        for m in italicRx.matches(in: s, range: NSRange(location: 0, length: ns.length)) {
            let lead = m.range(at: 1)
            let leadEnd = lead.location == NSNotFound ? m.range.location : lead.location + lead.length
            if leadEnd > cursor { f(ns.substring(with: NSRange(location: cursor, length: leadEnd - cursor)), false) }
            f(ns.substring(with: m.range(at: 2)), true)
            cursor = m.range.location + m.range.length
        }
        if cursor < ns.length { f(ns.substring(from: cursor), false) }
    }
}

/// One line of an answer as the view draws it: styled text and chips, in order. Chips are cut out first and stand in
/// the text as single placeholder characters while the styles are read, so **bold around «a chip»** still pairs up
/// (on the site the bold is applied before the chips exist).
enum AnswerInline {
    enum Piece: Equatable {
        case text(StyledRun)
        case chip(InlineSegment)
    }

    private static let base: UInt32 = 0xE100
    private static let limit: UInt32 = 0xE100 + 3000

    static func pieces(_ s: String, ents: [String: ChatEntity]) -> [Piece] {
        let segs = InlineChips.segments(s, ents: ents)
        var chips: [InlineSegment] = []
        var joined = ""
        for seg in segs {
            if case .text(let t) = seg { joined += t; continue }
            guard chips.count < Int(limit - base), let u = Unicode.Scalar(base + UInt32(chips.count)) else { continue }
            chips.append(seg)
            joined.unicodeScalars.append(u)
        }
        var out: [Piece] = []
        for run in InlineStyle.runs(joined) {
            var buf = ""
            func flush() {
                if !buf.isEmpty { var r = run; r.text = buf; out.append(.text(r)); buf = "" }
            }
            for u in run.text.unicodeScalars {
                if u.value >= base && u.value < base + UInt32(chips.count) {
                    flush()
                    out.append(.chip(chips[Int(u.value - base)]))
                } else {
                    buf.unicodeScalars.append(u)
                }
            }
            flush()
        }
        return out
    }
}
