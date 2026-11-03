import Foundation

/// How a Markdown table in a chat message shares the message's width (a two-column table ran past
/// the bubble and its long column was cut off mid-word). Pure math, measured widths in, column widths out:
/// Everything fits at its natural (one-line) width: each column gets it, and the spare room is shared in
/// proportion to it (the browser's `table { width: 100% }`);
/// Otherwise short columns keep their natural width and the long ones share what is left equally (water filling),
/// their text wrapping, a word that cannot fit breaking where it must;
/// Only when that would leave a column narrower than `readable` (and narrower than it needs) the table is laid
/// out at readable widths in a horizontal scroll view instead. Content is never clipped.
/// Widths include the cells' own padding.
enum TableFit {
    struct Column: Equatable {
        /// CSS min-content: the widest piece that cannot break (a word, a chip).
        var min: CGFloat
        /// CSS max-content: the cell's text on one line.
        var natural: CGFloat
        init(min: CGFloat, natural: CGFloat) {
            self.min = Swift.max(0, min)
            self.natural = Swift.max(0, natural, min)
        }
    }

    struct Result: Equatable {
        var widths: [CGFloat]
        /// The table is wider than the room: it scrolls horizontally.
        var scrolls: Bool
        var total: CGFloat { widths.reduce(0, +) }
    }

    /// Under this a wrapped column reads a word or two per line.
    static let readable: CGFloat = 70
    /// A column in the scrolling table wraps at this width (or its longest word, up to `scrollMax`).
    static let scrollColumn: CGFloat = 200
    static let scrollMax: CGFloat = 360

    /// The narrowest room the table fits without scrolling: each column at its natural width or `readable`,
    /// whichever is smaller. Also the table's ideal width, so a parent measuring it can tell whether it fits.
    static func minimumWidth(_ cols: [Column], readable: CGFloat = readable) -> CGFloat {
        cols.reduce(0) { $0 + Swift.min($1.natural, readable) }
    }

    static func fit(_ cols: [Column], available: CGFloat, readable: CGFloat = readable) -> Result {
        guard !cols.isEmpty else { return Result(widths: [], scrolls: false) }
        let nat = cols.map(\.natural)
        guard available.isFinite, available > 0 else { return Result(widths: nat, scrolls: false) }
        if available + 0.5 < minimumWidth(cols, readable: readable) {
            return Result(widths: scrollWidths(cols), scrolls: true)
        }
        let total = nat.reduce(0, +)
        if total <= available {
            let extra = available - total
            guard total > 0 else { return Result(widths: nat.map { _ in available / CGFloat(nat.count) }, scrolls: false) }
            return Result(widths: nat.map { $0 + extra * $0 / total }, scrolls: false)
        }
        if let w = share(cols, available: available, keepWords: true, readable: readable) { return Result(widths: w, scrolls: false) }
        let w = share(cols, available: available, keepWords: false, readable: readable) ?? nat
        return Result(widths: w, scrolls: false)
    }

    /// Water filling: a column that needs less than an equal share takes what it needs; the rest split the remainder.
    /// With `keepWords` a long column also keeps its longest word whole when the others can still stay readable;
    /// nil when that is impossible.
    private static func share(_ cols: [Column], available: CGFloat, keepWords: Bool, readable: CGFloat) -> [CGFloat]? {
        var w = [CGFloat](repeating: 0, count: cols.count)
        var open = Array(cols.indices)
        var rem = available
        while !open.isEmpty {
            let s = rem / CGFloat(open.count)
            var fixed = open.filter { cols[$0].natural <= s }
            if fixed.isEmpty && keepWords {
                fixed = open.filter { Swift.min(cols[$0].min, cols[$0].natural) > s }
            }
            if fixed.isEmpty {
                for i in open { w[i] = s }
                break
            }
            for i in fixed {
                let need = cols[i].natural <= s ? cols[i].natural : Swift.min(cols[i].min, cols[i].natural)
                w[i] = need
                rem -= need
            }
            open.removeAll { fixed.contains($0) }
            if rem < 0 { return keepWords ? nil : w }
        }
        if keepWords {
            for (i, c) in cols.enumerated() where w[i] + 0.01 < Swift.min(c.natural, readable) { return nil }
        }
        // A column held at its longest word may leave room over once the others took their natural width: it gets it.
        var left = available - w.reduce(0, +)
        for i in cols.indices where left > 0.01 && w[i] < cols[i].natural {
            let add = Swift.min(left, cols[i].natural - w[i])
            w[i] += add
            left -= add
        }
        return w
    }

    /// The scrolling table: each column at its natural width up to `scrollColumn` (wider for a long unbreakable
    /// word, up to `scrollMax`), never under `readable` unless its content is narrower still.
    static func scrollWidths(_ cols: [Column]) -> [CGFloat] {
        cols.map { c in
            Swift.min(c.natural, Swift.max(scrollColumn, Swift.min(c.min, scrollMax)))
        }
    }
}
