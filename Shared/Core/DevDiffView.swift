import Foundation

// Changes as a proper diff view - unified with old / new line numbers, red / green line grounds, the
// changed words of a modified line marked, long unchanged runs folded behind "Show N lines", and Side by side (before |
// after). Pure: built once per file off the main thread (DevDiffView.make), the view only filters folds and draws.

/// The changed part of a modified line, in Characters of the line.
struct DiffSpan: Equatable, Sendable {
    let start: Int
    let length: Int
    var end: Int { start + length }
}

enum DiffWords {
    /// Words, runs of spaces and single other characters.
    static func tokens(_ s: String) -> [String] {
        var out: [String] = []
        var cur = ""
        var curKind = -1
        for c in s {
            let k = c.isLetter || c.isNumber || c == "_" ? 0 : c.isWhitespace ? 1 : 2
            if k == curKind && k != 2 { cur.append(c) } else {
                if !cur.isEmpty { out.append(cur) }
                cur = String(c); curKind = k
            }
        }
        if !cur.isEmpty { out.append(cur) }
        return out
    }

    /// The part of `old` and of `new` between their common leading and trailing words. Nil for a side that only
    /// gained or lost words at the ends (its span is empty), and nil for both when the lines share almost nothing (the
    /// whole line is the change then, its ground says so already).
    static func changed(_ old: String, _ new: String) -> (old: DiffSpan?, new: DiffSpan?) {
        guard old != new else { return (nil, nil) }
        let a = tokens(old), b = tokens(new)
        var p = 0
        while p < a.count, p < b.count, a[p] == b[p] { p += 1 }
        var s = 0
        while s < a.count - p, s < b.count - p, a[a.count - 1 - s] == b[b.count - 1 - s] { s += 1 }
        func span(_ t: [String]) -> DiffSpan? {
            let start = t[..<p].reduce(0) { $0 + $1.count }
            let len = t[p..<(t.count - s)].reduce(0) { $0 + $1.count }
            return len > 0 ? DiffSpan(start: start, length: len) : nil
        }
        let shared = a[..<p].reduce(0) { $0 + $1.count } + a[(a.count - s)...].reduce(0) { $0 + $1.count }
        let longest = max(old.count, new.count)
        // fewer than a quarter of the characters in common (and not a pure insertion): the whole line changed
        if longest > 0, Double(shared) / Double(longest) < 0.25 { return (nil, nil) }
        return (span(a), span(b))
    }
}

/// One side of a drawn diff line.
struct DiffSide: Equatable, Sendable {
    let kind: DevDiff.Line.Kind
    let number: Int
    let pieces: [CodePiece]
    let changed: DiffSpan?
    var text: String { pieces.map(\.text).joined() }
}

/// One row of the unified view.
struct DiffUnifiedRow: Equatable, Identifiable, Sendable {
    enum Kind: Equatable, Sendable {
        /// A hunk's header ("Lines 10-24").
        case hunk(String)
        case line
        /// `count` unchanged lines folded as group `group` (shown once the group is opened).
        case fold(group: Int, count: Int)
        /// `count` unchanged lines between hunks that the diff does not carry (`gap`: their index, to be read).
        case gap(gap: Int, count: Int)
    }
    let id: Int
    let kind: Kind
    /// A line: old and new numbers (nil on the side it is missing from), its pieces, its changed words.
    var old: Int? = nil
    var new: Int? = nil
    var lineKind: DevDiff.Line.Kind = .context
    var pieces: [CodePiece] = []
    var changed: DiffSpan? = nil
    /// The fold group this row belongs to (hidden until opened); nil: always shown.
    var group: Int? = nil

    var text: String { pieces.map(\.text).joined() }
}

/// One row of the side by side view: before on the left, after on the right.
struct DiffSplitRow: Equatable, Identifiable, Sendable {
    enum Kind: Equatable, Sendable { case hunk(String), pair, fold(group: Int, count: Int), gap(gap: Int, count: Int) }
    let id: Int
    let kind: Kind
    var left: DiffSide? = nil
    var right: DiffSide? = nil
    var group: Int? = nil
}

struct DevDiffView: Equatable, Sendable {
    let unified: [DiffUnifiedRow]
    let split: [DiffSplitRow]
    /// The gutter's width in digits.
    let digits: Int
    /// The longest line in characters (the content width of a horizontal scroll).
    let longest: Int
    let tooLong: Bool
    /// Gaps between hunks the diff does not carry, by index: where they start in the new file and how long they are.
    let gaps: [Int: (newStart: Int, count: Int)]

    static func == (a: DevDiffView, b: DevDiffView) -> Bool {
        a.unified == b.unified && a.split == b.split && a.digits == b.digits && a.longest == b.longest && a.tooLong == b.tooLong
            && a.gaps.keys.sorted() == b.gaps.keys.sorted()
    }

    static let empty = DevDiffView(unified: [], split: [], digits: 2, longest: 0, tooLong: false, gaps: [:])

    /// Unchanged runs longer than this inside a hunk fold, keeping `context` lines at each end.
    static let foldOver = 8
    static let context = 3

    /// Builds both views of `file`. `newText`: the file after the change, when it was read - the unchanged lines between
    /// hunks then come in folded (else they are a gap that can be read).
    static func make(_ file: DevDiff.File?, path: String, newText: [String]? = nil) -> DevDiffView {
        guard let file, !file.hunks.isEmpty else { return .empty }
        // a file read now may be newer than the diff: used only when every line the diff has on the new side matches
        let newText = newText.flatMap { fits(file, newText: $0) ? $0 : nil }
        let lang = CodeLang.of(path: path)
        var uni: [DiffUnifiedRow] = []
        var spl: [DiffSplitRow] = []
        var uid = 0, sid = 0
        var group = 0
        var gapIndex = 0
        var gaps: [Int: (newStart: Int, count: Int)] = [:]
        var longest = 0
        var count = 0
        var cut = false

        func same(_ text: String, old: Int, new: Int, group g: Int?) {
            let p = CodeSyntax.line(text, lang: lang).pieces
            longest = max(longest, text.count)
            uni.append(DiffUnifiedRow(id: uid, kind: .line, old: old, new: new, lineKind: .context, pieces: p, group: g)); uid += 1
            let side = DiffSide(kind: .context, number: old, pieces: p, changed: nil)
            spl.append(DiffSplitRow(id: sid, kind: .pair, left: side, right: DiffSide(kind: .context, number: new, pieces: p, changed: nil), group: g))
            sid += 1
        }
        /// Unchanged lines the diff does not carry, from new line `from` (old `oldFrom`), `n` of them.
        func between(from: Int, oldFrom: Int, n: Int) {
            guard n > 0 else { return }
            if let t = newText, from - 1 + n <= t.count, from >= 1 {
                uni.append(DiffUnifiedRow(id: uid, kind: .fold(group: group, count: n))); uid += 1
                spl.append(DiffSplitRow(id: sid, kind: .fold(group: group, count: n))); sid += 1
                for k in 0..<n { same(t[from - 1 + k], old: oldFrom + k, new: from + k, group: group) }
                group += 1
            } else {
                gaps[gapIndex] = (from, n)
                uni.append(DiffUnifiedRow(id: uid, kind: .gap(gap: gapIndex, count: n))); uid += 1
                spl.append(DiffSplitRow(id: sid, kind: .gap(gap: gapIndex, count: n))); sid += 1
                gapIndex += 1
            }
        }

        var prevNewEnd = 1, prevOldEnd = 1
        outer: for (hi, h) in file.hunks.enumerated() {
            // what lies between the previous hunk (or the top) and this one
            let newStart = max(h.newStart, h.newCount == 0 ? h.newStart + 1 : h.newStart)
            let n = newStart - prevNewEnd
            if hi > 0 || h.newStart > 1 { between(from: prevNewEnd, oldFrom: prevOldEnd, n: max(0, n)) }
            uni.append(DiffUnifiedRow(id: uid, kind: .hunk(h.label))); uid += 1
            spl.append(DiffSplitRow(id: sid, kind: .hunk(h.label))); sid += 1

            // runs: context, or a block of deletions then additions
            var i = 0
            let lines = h.lines
            while i < lines.count {
                if count >= DevDiff.maxLines { cut = true; break outer }
                if lines[i].kind == .context {
                    var j = i
                    while j < lines.count, lines[j].kind == .context { j += 1 }
                    let run = Array(lines[i..<j])
                    let fold = run.count > foldOver + 2 * Self.context
                    for (k, l) in run.enumerated() {
                        let inner = fold && k >= Self.context && k < run.count - Self.context
                        if fold && k == Self.context {
                            let n = run.count - 2 * Self.context
                            uni.append(DiffUnifiedRow(id: uid, kind: .fold(group: group, count: n))); uid += 1
                            spl.append(DiffSplitRow(id: sid, kind: .fold(group: group, count: n))); sid += 1
                        }
                        same(l.text, old: l.old ?? 0, new: l.new ?? 0, group: inner ? group : nil)
                        count += 1
                    }
                    if fold { group += 1 }
                    i = j
                    continue
                }
                var dels: [DevDiff.Line] = [], adds: [DevDiff.Line] = []
                while i < lines.count, lines[i].kind == .del { dels.append(lines[i]); i += 1 }
                while i < lines.count, lines[i].kind == .add { adds.append(lines[i]); i += 1 }
                let oldPieces = CodeSyntax.highlight(dels.map(\.text), lang: lang)
                let newPieces = CodeSyntax.highlight(adds.map(\.text), lang: lang)
                var spans: [(DiffSpan?, DiffSpan?)] = []
                for k in 0..<max(dels.count, adds.count) {
                    if k < dels.count, k < adds.count { spans.append(DiffWords.changed(dels[k].text, adds[k].text)) } else { spans.append((nil, nil)) }
                }
                var leftSides: [DiffSide] = [], rightSides: [DiffSide] = []
                for (k, l) in dels.enumerated() {
                    longest = max(longest, l.text.count)
                    let sp = spans[k].0
                    uni.append(DiffUnifiedRow(id: uid, kind: .line, old: l.old, new: nil, lineKind: .del, pieces: oldPieces[k], changed: sp)); uid += 1
                    leftSides.append(DiffSide(kind: .del, number: l.old ?? 0, pieces: oldPieces[k], changed: sp))
                    count += 1
                }
                for (k, l) in adds.enumerated() {
                    longest = max(longest, l.text.count)
                    let sp = spans[k].1
                    uni.append(DiffUnifiedRow(id: uid, kind: .line, old: nil, new: l.new, lineKind: .add, pieces: newPieces[k], changed: sp)); uid += 1
                    rightSides.append(DiffSide(kind: .add, number: l.new ?? 0, pieces: newPieces[k], changed: sp))
                    count += 1
                }
                for k in 0..<max(leftSides.count, rightSides.count) {
                    spl.append(DiffSplitRow(id: sid, kind: .pair, left: k < leftSides.count ? leftSides[k] : nil,
                                            right: k < rightSides.count ? rightSides[k] : nil)); sid += 1
                }
            }
            prevNewEnd = h.newStart + h.newCount
            prevOldEnd = h.oldStart + h.oldCount
            if h.newCount == 0 { prevNewEnd = h.newStart + 1 }
            if h.oldCount == 0 { prevOldEnd = h.oldStart + 1 }
        }
        // the rest of the file after the last hunk, when it is known
        if !cut, let t = newText, prevNewEnd <= t.count {
            between(from: prevNewEnd, oldFrom: prevOldEnd, n: t.count - prevNewEnd + 1)
        }
        let mx = file.hunks.map { max($0.oldStart + $0.oldCount, $0.newStart + $0.newCount) }.max() ?? 1
        return DevDiffView(unified: uni, split: spl, digits: max(String(max(mx, newText?.count ?? 0)).count, 2),
                           longest: longest, tooLong: cut, gaps: gaps)
    }

    /// Whether `t` (the new file's lines) is the file this diff ends in: every context and added line is where it says.
    static func fits(_ file: DevDiff.File, newText t: [String]) -> Bool {
        for h in file.hunks {
            for l in h.lines where l.kind != .del {
                guard let n = l.new, n >= 1, n <= t.count, t[n - 1] == l.text else { return false }
            }
        }
        return true
    }

    /// A file's text as lines for the diff (a trailing newline makes no extra line; nothing is cut).
    static func lines(_ text: String) -> [String] {
        var l = text.replacingOccurrences(of: "\r\n", with: "\n").split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        if l.count > 1, l.last == "" { l.removeLast() }
        return l
    }

    /// The fold group whose first hidden line is new line `n` (the gap a click asked for, once the file is read).
    static func group(startingAt n: Int, in rows: [DiffUnifiedRow]) -> Int? {
        rows.first { $0.group != nil && $0.new == n }?.group
    }

    /// The rows shown with the fold groups in `open` opened (a fold's own row goes once it is open).
    static func visible(_ rows: [DiffUnifiedRow], open: Set<Int>) -> [DiffUnifiedRow] {
        rows.filter { r in
            if case .fold(let g, _) = r.kind { return !open.contains(g) }
            return r.group.map { open.contains($0) } ?? true
        }
    }

    static func visible(_ rows: [DiffSplitRow], open: Set<Int>) -> [DiffSplitRow] {
        rows.filter { r in
            if case .fold(let g, _) = r.kind { return !open.contains(g) }
            return r.group.map { open.contains($0) } ?? true
        }
    }
}

// MARK: - the code view's selection and its context for the composer

enum CodeLines {
    /// "path:12" or "path:12-30" and the lines in a fenced block: what Attach as context puts in the composer.
    static func context(path: String, lines: [String], from: Int, to: Int) -> String {
        guard !lines.isEmpty else { return path }
        let a = max(1, min(from, to)), b = min(lines.count, max(from, to))
        guard a <= b else { return path }
        let where_ = a == b ? "\(path):\(a)" : "\(path):\(a)-\(b)"
        let body = lines[(a - 1)...(b - 1)].joined(separator: "\n")
        return where_ + "\n```" + CodeLang.fence(path: path) + "\n" + body + "\n```"
    }

    /// The lines from..to joined (Copy).
    static func text(_ lines: [String], from: Int, to: Int) -> String {
        guard !lines.isEmpty else { return "" }
        let a = max(1, min(from, to)), b = min(lines.count, max(from, to))
        guard a <= b else { return "" }
        return lines[(a - 1)...(b - 1)].joined(separator: "\n")
    }

    /// The 1-based numbers of the lines holding `query` (case-insensitive), in order.
    static func matches(_ lines: [String], query: String) -> [Int] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return [] }
        var out: [Int] = []
        for (i, l) in lines.enumerated() where l.range(of: q, options: [.caseInsensitive]) != nil { out.append(i + 1) }
        return out
    }

    /// "Canvas / src / app.js" -> the breadcrumb's parts.
    static func crumbs(_ path: String) -> [String] {
        path.split(separator: "/").map(String.init).filter { !$0.isEmpty && $0 != "." }
    }
}
