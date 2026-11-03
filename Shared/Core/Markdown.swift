import Foundation

/// Block level markdown for Lia's answers: what mdLite in ai.js renders (tables, lists, headings,
/// code). Inline markup (bold, italic, links, code) stays in the strings and is rendered by
/// AttributedString in the view, so no rule here can ever produce markup from what the model wrote.
enum MDBlock: Equatable {
    case heading(level: Int, text: String)
    case paragraph(String)
    case bullets([String])
    case numbered([String])
    case table(header: [String], rows: [[String]])
    case code(String)
    case rule
}

enum Markdown {
    static func blocks(_ source: String) -> [MDBlock] {
        let lines = clean(source).components(separatedBy: "\n")
        var out: [MDBlock] = []
        var para: [String] = []
        var i = 0

        func flushPara() {
            let t = para.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            if !t.isEmpty { out.append(.paragraph(t)) }
            para.removeAll()
        }

        while i < lines.count {
            let line = lines[i]
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            if trimmed.hasPrefix("```") {
                flushPara()
                var code: [String] = []
                i += 1
                while i < lines.count, !lines[i].trimmingCharacters(in: .whitespaces).hasPrefix("```") {
                    code.append(lines[i]); i += 1
                }
                out.append(.code(code.joined(separator: "\n")))
                i += 1
                continue
            }
            if isRow(line), i + 1 < lines.count, isSeparator(lines[i + 1]) {
                flushPara()
                let header = cells(line)
                var rows: [[String]] = []
                i += 2
                while i < lines.count, isRow(lines[i]) {
                    var r = cells(lines[i])
                    if r.count < header.count { r += Array(repeating: "", count: header.count - r.count) }
                    rows.append(Array(r.prefix(header.count)))
                    i += 1
                }
                out.append(.table(header: header, rows: rows))
                continue
            }
            if let h = heading(trimmed) {
                flushPara(); out.append(h); i += 1; continue
            }
            if isRule(trimmed) {
                flushPara(); out.append(.rule); i += 1; continue
            }
            if bulletText(line) != nil {
                flushPara()
                out.append(.bullets(listItems(lines, &i, bulletText)))
                continue
            }
            if numberedText(line) != nil {
                flushPara()
                out.append(.numbered(listItems(lines, &i, numberedText)))
                continue
            }
            if trimmed.isEmpty { flushPara(); i += 1; continue }
            // (0.2.11, "text comes oddly"): trailing spaces (a Markdown hard break) are not words.
            para.append(trailingTrimmed(line))
            i += 1
        }
        flushPara()
        return out
    }

    /// Links into a finished code container (sandbox:/mnt/data/...) point nowhere; mdLite strips them.
    /// (0.2.11): Windows and old-Mac line ends become "\n" first - a line ending in "\r" was never
    /// blank, so a blank line between two paragraphs did not part them.
    static func clean(_ s: String) -> String {
        let lf = s.utf8.contains(13) ? s.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n") : s
        return lf.replacingOccurrences(of: #"\[([^\]]*)\]\(sandbox:[^)]*\)"#, with: "$1", options: .regularExpression)
    }

    /// The items of one list from line `i` on (`item` reads an item line of this list's kind), `i` left after it.
    /// (0.2.11): blank lines between items keep one list (CommonMark's loose list) - "1. a", "", "2. b"
    /// was two lists, both numbered from 1. An indented line right under an item that starts no block of its own goes
    /// on in that item (a wrapped item used to fall out of the list as a paragraph).
    static func listItems(_ lines: [String], _ i: inout Int, _ item: (String) -> String?) -> [String] {
        var items: [String] = []
        while i < lines.count {
            if let t = item(lines[i]) { items.append(trailingTrimmed(t)); i += 1; continue }
            let l = lines[i]
            let t = l.trimmingCharacters(in: .whitespaces)
            if t.isEmpty {
                var j = i
                while j < lines.count, lines[j].trimmingCharacters(in: .whitespaces).isEmpty { j += 1 }
                if j < lines.count, item(lines[j]) != nil { i = j; continue }
                break
            }
            if !items.isEmpty, l.first == " " || l.first == "\t", startsBlock(t) == false {
                items[items.count - 1] += "\n" + trailingTrimmed(t)
                i += 1
                continue
            }
            break
        }
        return items
    }

    /// The line starts a block of its own (so it cannot go on in a list item).
    private static func startsBlock(_ t: String) -> Bool {
        t.hasPrefix("```") || t.hasPrefix("|") || heading(t) != nil || isRule(t) || bulletText(t) != nil || numberedText(t) != nil
    }

    static func trailingTrimmed(_ s: String) -> String {
        var t = Substring(s)
        while let last = t.last, last == " " || last == "\t" { t = t.dropLast() }
        return String(t)
    }

    static func isRow(_ l: String) -> Bool {
        let t = l.trimmingCharacters(in: .whitespaces)
        return t.count >= 2 && t.hasPrefix("|") && t.hasSuffix("|")
    }

    static func isSeparator(_ l: String) -> Bool {
        let t = l.trimmingCharacters(in: .whitespaces)
        guard isRow(t), t.contains("-") else { return false }
        return t.allSatisfy { "|-: ".contains($0) }
    }

    static func cells(_ l: String) -> [String] {
        var t = l.trimmingCharacters(in: .whitespaces)
        if t.hasPrefix("|") { t.removeFirst() }
        if t.hasSuffix("|") { t.removeLast() }
        return t.components(separatedBy: "|").map { $0.trimmingCharacters(in: .whitespaces) }
    }

    static func heading(_ t: String) -> MDBlock? {
        var level = 0
        for ch in t { if ch == "#" { level += 1 } else { break } }
        guard (1...6).contains(level) else { return nil }
        let rest = t.dropFirst(level)
        guard rest.first == " " else { return nil }
        return .heading(level: level, text: rest.trimmingCharacters(in: .whitespaces))
    }

    static func isRule(_ t: String) -> Bool {
        t.count >= 3 && (t.allSatisfy { $0 == "-" } || t.allSatisfy { $0 == "*" } || t.allSatisfy { $0 == "_" })
    }

    static func bulletText(_ l: String) -> String? {
        let t = l.trimmingCharacters(in: .whitespaces)
        // mdLite: ^\s*[-*\u2022]\s+(.*) - any run of spaces or tabs after the marker.
        guard let first = t.first, "-*\u{2022}".contains(first) else { return nil }
        let rest = t.dropFirst()
        guard let gap = rest.first, gap == " " || gap == "\t" else { return nil }
        return String(rest.drop(while: { $0 == " " || $0 == "\t" }))
    }

    static func numberedText(_ l: String) -> String? {
        let t = l.trimmingCharacters(in: .whitespaces)
        var digits = 0
        for ch in t { if ch.isASCII && ch.isNumber { digits += 1 } else { break } }
        guard digits > 0, digits <= 3 else { return nil }
        let rest = t.dropFirst(digits)
        guard let sep = rest.first, sep == "." || sep == ")", let gap = rest.dropFirst().first, gap == " " || gap == "\t" else { return nil }
        return String(rest.dropFirst().drop(while: { $0 == " " || $0 == "\t" }))
    }
}

/// «Name» is how the runner marks an ad entity in text; ai.js turns known names into chips.
enum EntityText {
    struct Mark: Equatable { let name: String; let known: Bool }

    static func marks(in text: String, ents: [String: ChatEntity]) -> [Mark] {
        let names = Set(ents.values.map { $0.name.lowercased().trimmingCharacters(in: .whitespaces) })
        var out: [Mark] = []
        var rest = Substring(text)
        while let open = rest.firstIndex(of: "«"), let close = rest[open...].firstIndex(of: "»") {
            let name = String(rest[rest.index(after: open)..<close])
            if (2...60).contains(name.count) {
                out.append(Mark(name: name, known: names.contains(name.lowercased().trimmingCharacters(in: .whitespaces))))
            }
            rest = rest[rest.index(after: close)...]
        }
        return out
    }

    /// Known entities become bold (the native stand-in for ai.js chips); unknown «text» stays as written,
    /// exactly as entifyHtml leaves a name it cannot resolve.
    static func inlineMarkdown(_ text: String, ents: [String: ChatEntity]) -> String {
        let names = Set(ents.values.map { $0.name.lowercased().trimmingCharacters(in: .whitespaces) })
        guard !names.isEmpty, text.contains("«") else { return text }
        var out = ""
        var rest = Substring(text)
        while let open = rest.firstIndex(of: "«"), let close = rest[open...].firstIndex(of: "»") {
            out += rest[..<open]
            let name = String(rest[rest.index(after: open)..<close])
            if (2...60).contains(name.count), names.contains(name.lowercased().trimmingCharacters(in: .whitespaces)) {
                out += "**\(name)**"
            } else {
                out += rest[open...close]
            }
            rest = rest[rest.index(after: close)...]
        }
        return out + rest
    }
}
