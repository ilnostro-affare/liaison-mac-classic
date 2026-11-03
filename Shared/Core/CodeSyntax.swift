import Foundation

// ("like Claude's code viewer"): the Code tab colours code - keywords, strings, comments, numbers -
// with a small tokenizer per language family. Pure and line based (a block comment or a triple-quoted string carries
// into the next line through `State`), so the viewer colours a file off the main thread once and caches it.

enum CodeLang: String, Equatable, Sendable {
    case cLike, python, ruby, shell, css, html, json, yaml, sql, markdown, plain

    /// The family by the file's extension (or its name: Dockerfile, Makefile).
    static func of(path: String) -> CodeLang {
        let name = (path.split(separator: "/").last.map(String.init) ?? path).lowercased()
        if name == "dockerfile" || name == "makefile" || name.hasPrefix(".env") || name == ".gitignore" { return .shell }
        guard let dot = name.lastIndex(of: "."), dot != name.startIndex else { return .plain }
        switch String(name[name.index(after: dot)...]) {
        case "swift", "js", "mjs", "cjs", "jsx", "ts", "tsx", "go", "rs", "java", "kt", "kts", "c", "h", "cc", "cpp", "hpp",
             "m", "mm", "cs", "php", "dart", "scala", "groovy", "gradle", "proto", "zig":
            return .cLike
        case "py", "pyi": return .python
        case "rb", "rake", "gemspec": return .ruby
        case "sh", "bash", "zsh", "fish", "toml", "ini", "conf", "cfg", "properties": return .shell
        case "css", "scss", "sass", "less": return .css
        case "html", "htm", "xml", "svg", "vue", "svelte", "plist", "xib", "storyboard": return .html
        case "json", "jsonc", "webmanifest", "map": return .json
        case "yml", "yaml": return .yaml
        case "sql": return .sql
        case "md", "markdown", "mdx", "txt": return .markdown
        default: return .plain
        }
    }

    /// The fence word of a Markdown code block ("swift", "js", ...): the context Attach puts in the composer.
    static func fence(path: String) -> String {
        let name = (path.split(separator: "/").last.map(String.init) ?? path).lowercased()
        guard let dot = name.lastIndex(of: "."), dot != name.startIndex else { return "" }
        return String(name[name.index(after: dot)...])
    }
}

enum CodeTokenKind: Equatable, Sendable { case plain, keyword, string, comment, number, type, tag, attribute }

/// One coloured piece of a line, in order; the pieces of a line join back into the line.
struct CodePiece: Equatable, Sendable {
    let kind: CodeTokenKind
    let text: String
}

enum CodeSyntax {
    /// What carries over a line end.
    enum State: Equatable, Sendable {
        case none
        /// Inside /* */ (or <!-- --> in HTML).
        case blockComment
        /// Inside a string that spans lines: Python's """ / ''', a JS template literal, a Swift """.
        case string(String)
    }

    static let cKeywords: Set<String> = Set([
        "func", "function", "let", "var", "const", "if", "else", "for", "while", "do", "return", "switch", "case", "default",
        "break", "continue", "class", "struct", "enum", "protocol", "extension", "interface", "import", "export", "from",
        "package", "public", "private", "protected", "internal", "fileprivate", "static", "final", "override", "init",
        "deinit", "self", "Self", "super", "this", "new", "delete", "try", "catch", "throw", "throws", "rethrows", "finally",
        "async", "await", "guard", "defer", "in", "is", "as", "where", "typeof", "instanceof", "void", "null", "nil",
        "undefined", "true", "false", "type", "typealias", "namespace", "using", "module", "require", "yield", "go", "chan",
        "fn", "impl", "trait", "mut", "pub", "use", "crate", "match", "loop", "mod", "ref", "move", "dyn", "where", "val",
        "fun", "object", "companion", "data", "sealed", "open", "abstract", "lazy", "weak", "unowned", "inout", "some", "any",
        "mutating", "nonmutating", "nonisolated", "actor", "get", "set", "willSet", "didSet", "operator", "extends",
        "implements", "of", "with", "goto", "sizeof", "int", "char", "float", "double", "long", "short", "unsigned", "signed",
        "bool", "boolean", "string", "number", "readonly", "declare", "keyof", "satisfies", "enum", "elif", "select",
        "range", "map", "struct", "defer", "fallthrough", "repeat", "associatedtype", "subscript", "convenience", "required",
        "optional", "indirect", "precedencegroup", "macro", "consume", "borrowing", "consuming",
    ])
    static let pyKeywords: Set<String> = Set([
        "def", "class", "return", "if", "elif", "else", "for", "while", "in", "not", "and", "or", "is", "import", "from",
        "as", "with", "try", "except", "finally", "raise", "pass", "break", "continue", "lambda", "yield", "global",
        "nonlocal", "assert", "del", "None", "True", "False", "async", "await", "self", "match", "case",
    ])
    static let rbKeywords: Set<String> = Set([
        "def", "class", "module", "end", "if", "elsif", "else", "unless", "while", "until", "for", "in", "do", "return",
        "yield", "begin", "rescue", "ensure", "raise", "nil", "true", "false", "self", "require", "require_relative",
        "attr_accessor", "attr_reader", "attr_writer", "then", "case", "when", "and", "or", "not", "super", "lambda", "proc",
    ])
    static let shKeywords: Set<String> = Set([
        "if", "then", "else", "elif", "fi", "for", "in", "do", "done", "while", "until", "case", "esac", "function", "return",
        "export", "local", "set", "unset", "echo", "exit", "source", "cd", "readonly", "declare", "true", "false", "FROM",
        "RUN", "CMD", "COPY", "ADD", "ENV", "WORKDIR", "EXPOSE", "ENTRYPOINT", "ARG",
    ])
    static let sqlKeywords: Set<String> = Set([
        "select", "from", "where", "insert", "into", "values", "update", "set", "delete", "create", "table", "drop", "alter",
        "index", "join", "left", "right", "inner", "outer", "on", "group", "by", "order", "having", "limit", "offset", "and",
        "or", "not", "null", "is", "as", "distinct", "union", "all", "primary", "key", "foreign", "references", "default",
        "begin", "commit", "rollback", "with", "case", "when", "then", "else", "end", "exists", "in", "like", "count",
    ])
    static let cssKeywords: Set<String> = Set(["important", "media", "import", "keyframes", "font-face", "supports", "root", "from", "to"])

    /// The pieces of every line (in order) of `lines`, the state carried from line to line.
    static func highlight(_ lines: [String], lang: CodeLang) -> [[CodePiece]] {
        var st: State = .none
        var out: [[CodePiece]] = []
        out.reserveCapacity(lines.count)
        for l in lines {
            let r = line(l, lang: lang, state: st)
            out.append(r.pieces)
            st = r.state
        }
        return out
    }

    /// One line's pieces and the state after it. Very long lines (minified code) stay plain past 4000 characters.
    static func line(_ s: String, lang: CodeLang, state: State = .none) -> (pieces: [CodePiece], state: State) {
        if lang == .plain || lang == .markdown || s.isEmpty { return (s.isEmpty ? [] : [CodePiece(kind: .plain, text: s)], state) }
        let cs = Array(s)
        let cut = min(cs.count, 4000)
        var t = Tokens()
        var st = state
        var i = 0

        // A line that starts inside a block comment or a multi-line string.
        switch st {
        case .blockComment:
            let close: [Character] = lang == .html ? ["-", "-", ">"] : ["*", "/"]
            if let e = find(close, in: cs, from: 0, to: cut) {
                t.add(.comment, cs, 0, e + close.count); i = e + close.count; st = .none
            } else {
                t.add(.comment, cs, 0, cut); i = cut
            }
        case .string(let q):
            let qc = Array(q)
            if let e = findUnescaped(qc, in: cs, from: 0, to: cut) {
                t.add(.string, cs, 0, e + qc.count); i = e + qc.count; st = .none
            } else {
                t.add(.string, cs, 0, cut); i = cut
            }
        case .none: break
        }

        if lang == .html {
            while i < cut, st == .none {
                if starts(["<", "!", "-", "-"], cs, i) {
                    if let e = find(["-", "-", ">"], in: cs, from: i + 4, to: cut) { t.add(.comment, cs, i, e + 3); i = e + 3 }
                    else { t.add(.comment, cs, i, cut); i = cut; st = .blockComment }
                    continue
                }
                if cs[i] == "<" {
                    var j = i + 1
                    if j < cut, cs[j] == "/" || cs[j] == "!" || cs[j] == "?" { j += 1 }
                    let ns = j
                    while j < cut, cs[j].isLetter || cs[j].isNumber || cs[j] == "-" || cs[j] == ":" || cs[j] == "_" || cs[j] == "." { j += 1 }
                    if j > ns {
                        t.add(.plain, cs, i, ns); t.add(.tag, cs, ns, j); i = j
                        // attributes up to ">"
                        while i < cut, cs[i] != ">" {
                            if cs[i] == "\"" || cs[i] == "'" {
                                let q = cs[i]
                                var k = i + 1
                                while k < cut, cs[k] != q { k += 1 }
                                k = min(k + 1, cut)
                                t.add(.string, cs, i, k); i = k
                            } else if cs[i].isLetter || cs[i] == "@" || cs[i] == ":" {
                                var k = i
                                while k < cut, !cs[k].isWhitespace, cs[k] != "=", cs[k] != ">", cs[k] != "/" { k += 1 }
                                t.add(.attribute, cs, i, k); i = k
                            } else {
                                t.add(.plain, cs, i, i + 1); i += 1
                            }
                        }
                        continue
                    }
                }
                t.add(.plain, cs, i, i + 1); i += 1
            }
            if cut < cs.count { t.add(.plain, cs, cut, cs.count) }
            return (t.pieces, st)
        }

        let keywords: Set<String>
        switch lang {
        case .cLike: keywords = cKeywords
        case .python: keywords = pyKeywords
        case .ruby: keywords = rbKeywords
        case .shell: keywords = shKeywords
        case .sql: keywords = sqlKeywords
        case .css: keywords = cssKeywords
        case .json, .yaml: keywords = ["true", "false", "null", "yes", "no", "on", "off"]
        default: keywords = []
        }
        let hashComment = lang == .python || lang == .ruby || lang == .shell || lang == .yaml
        let slashComment = lang == .cLike || lang == .json
        let blockComments = lang == .cLike || lang == .css || lang == .json

        while i < cut, st == .none {
            let c = cs[i]
            // comments
            if slashComment && starts(["/", "/"], cs, i) { t.add(.comment, cs, i, cut); i = cut; break }
            if hashComment && c == "#" && (i == 0 || cs[i - 1].isWhitespace || lang != .shell) {
                t.add(.comment, cs, i, cut); i = cut; break
            }
            if lang == .sql && starts(["-", "-"], cs, i) { t.add(.comment, cs, i, cut); i = cut; break }
            if blockComments && starts(["/", "*"], cs, i) {
                if let e = find(["*", "/"], in: cs, from: i + 2, to: cut) { t.add(.comment, cs, i, e + 2); i = e + 2 }
                else { t.add(.comment, cs, i, cut); i = cut; st = .blockComment }
                continue
            }
            // strings
            if c == "\"" || c == "'" || (c == "`" && lang == .cLike) {
                let triple: [Character] = [c, c, c]
                if (lang == .python || lang == .cLike) && c != "`" && starts(triple, cs, i) {
                    if let e = findUnescaped(triple, in: cs, from: i + 3, to: cut) { t.add(.string, cs, i, e + 3); i = e + 3 }
                    else { t.add(.string, cs, i, cut); i = cut; st = .string(String(triple)) }
                    continue
                }
                // an apostrophe inside a word ("don't" in a shell echo) is not a string in the C family's sense,
                // but a char literal there; keep it simple: a quote opens a string up to its unescaped twin
                if let e = findUnescaped([c], in: cs, from: i + 1, to: cut) {
                    let kind: CodeTokenKind = (lang == .json || lang == .yaml) && isKey(cs, after: e + 1, to: cut) ? .attribute : .string
                    t.add(kind, cs, i, e + 1); i = e + 1
                } else if c == "`" {
                    t.add(.string, cs, i, cut); i = cut; st = .string("`")
                } else {
                    t.add(.string, cs, i, cut); i = cut
                }
                continue
            }
            // numbers
            if c.isNumber && (i == 0 || !(cs[i - 1].isLetter || cs[i - 1] == "_" || cs[i - 1].isNumber)) {
                var j = i + 1
                while j < cut, cs[j].isNumber || cs[j].isLetter || cs[j] == "." || cs[j] == "_" { j += 1 }
                t.add(.number, cs, i, j); i = j
                continue
            }
            // words
            if c.isLetter || c == "_" || c == "$" || (c == "@" && lang != .css) || (c == "-" && lang == .css && i + 1 < cut && cs[i + 1].isLetter) {
                var j = i + 1
                while j < cut, cs[j].isLetter || cs[j].isNumber || cs[j] == "_" || cs[j] == "$" || (lang == .css && cs[j] == "-") { j += 1 }
                let w = String(cs[i..<j])
                let lw = lang == .sql ? w.lowercased() : w
                var kind: CodeTokenKind = .plain
                if keywords.contains(lw) || (c == "@" && lang == .cLike) { kind = .keyword }
                else if lang == .cLike, let f = w.first, f.isUppercase, w.count > 1 { kind = .type }
                else if lang == .css, j < cut, cs[j] == ":" { kind = .attribute }
                else if lang == .yaml, j < cut, cs[j] == ":", firstNonSpace(cs) == i { kind = .attribute }
                else if lang == .shell, j < cut, cs[j] == "=", firstNonSpace(cs) == i { kind = .attribute }
                t.add(kind, cs, i, j); i = j
                continue
            }
            if lang == .css && c == "#" {
                var j = i + 1
                while j < cut, cs[j].isLetter || cs[j].isNumber || cs[j] == "-" { j += 1 }
                t.add(.number, cs, i, j); i = j
                continue
            }
            t.add(.plain, cs, i, i + 1); i += 1
        }
        if i < cs.count { t.add(.plain, cs, max(i, cut), cs.count) }
        return (t.pieces, st)
    }

    // MARK: helpers

    private struct Tokens {
        var pieces: [CodePiece] = []
        mutating func add(_ k: CodeTokenKind, _ cs: [Character], _ a: Int, _ b: Int) {
            guard b > a else { return }
            let s = String(cs[a..<b])
            if let last = pieces.last, last.kind == k {
                pieces[pieces.count - 1] = CodePiece(kind: k, text: last.text + s)
            } else {
                pieces.append(CodePiece(kind: k, text: s))
            }
        }
    }

    private static func starts(_ p: [Character], _ cs: [Character], _ i: Int) -> Bool {
        guard i + p.count <= cs.count else { return false }
        for k in 0..<p.count where cs[i + k] != p[k] { return false }
        return true
    }

    private static func find(_ p: [Character], in cs: [Character], from: Int, to: Int) -> Int? {
        var i = from
        while i + p.count <= to {
            if starts(p, cs, i) { return i }
            i += 1
        }
        return nil
    }

    /// The next `p` not escaped by a backslash.
    private static func findUnescaped(_ p: [Character], in cs: [Character], from: Int, to: Int) -> Int? {
        var i = from
        while i + p.count <= to {
            if cs[i] == "\\" { i += 2; continue }
            if starts(p, cs, i) { return i }
            i += 1
        }
        return nil
    }

    /// A JSON / YAML string followed by ":" is a key.
    private static func isKey(_ cs: [Character], after i: Int, to: Int) -> Bool {
        var j = i
        while j < to, cs[j] == " " || cs[j] == "\t" { j += 1 }
        return j < to && cs[j] == ":"
    }

    private static func firstNonSpace(_ cs: [Character]) -> Int {
        var i = 0
        while i < cs.count, cs[i] == " " || cs[i] == "\t" || cs[i] == "-" { i += 1 }
        return i
    }
}
