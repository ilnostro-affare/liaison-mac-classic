import Foundation

// ("file paths like html as chips I can select, opened in our Changes or Files without closing the
// messenger"): a path of Dev's project written in an answer - `frontend/landing/index.html` in a code span, a bare
// "src/app.js", a folder such as `/workspace/project/acme` - is a chip. A click opens the Canvas on the right:
// Changes when the dialogue's diff holds the file, else Files (CanvasFileOpen). Pure: the views draw and route it.

/// A file or folder of Dev's project named in the text.
struct FileRef: Equatable, Hashable, Sendable {
    /// Project-relative ("/workspace/project/acme/a.js" -> "acme/a.js"); "" is the project's top (a folder).
    let path: String
    let isDir: Bool
    /// As written (what the chip shows and what Copy gives back).
    let written: String

    /// The last part of the path ("index.html"; a folder's own name; "Project" for the top).
    var name: String {
        if path.isEmpty { return "Project" }
        return path.split(separator: "/").last.map(String.init) ?? path
    }

    /// An image the Canvas can draw (rather than text).
    var isImage: Bool { !isDir && FileChips.imageExtensions.contains(FileChips.ext(path)) }
}

enum FileChips {
    /// Extensions that make a word a file (lowercased, without the dot).
    static let extensions: Set<String> = [
        "html", "htm", "css", "scss", "sass", "less", "js", "mjs", "cjs", "ts", "tsx", "jsx", "vue", "svelte", "astro",
        "json", "jsonc", "md", "mdx", "txt", "csv", "tsv", "xml", "svg", "png", "jpg", "jpeg", "gif", "webp", "ico", "avif",
        "pdf", "py", "rb", "php", "swift", "go", "rs", "java", "kt", "c", "h", "cc", "cpp", "hpp", "m", "mm", "cs",
        "sh", "bash", "zsh", "yml", "yaml", "toml", "ini", "cfg", "conf", "env", "lock", "sql", "graphql", "gql",
        "xcconfig", "plist", "pbxproj", "entitlements", "strings", "webmanifest", "map", "wasm", "woff", "woff2", "ttf",
        "otf", "mp4", "webm", "mov", "mp3", "wav", "zip", "gz", "tar", "log", "patch", "diff",
    ]
    static let imageExtensions: Set<String> = ["png", "jpg", "jpeg", "gif", "webp", "ico", "avif", "svg"]
    /// Extensions that are also common member names in code (`console.log`, `arr.map`, `x.h`): a file only with a slash.
    static let ambiguousAlone: Set<String> = ["log", "map", "m", "h", "c", "cc", "cs", "mm", "go", "rs", "kt", "env",
                                               "lock", "conf", "cfg", "ini", "sql", "strings", "diff", "patch", "gz", "tar"]
    /// Files known by their whole name.
    static let names: Set<String> = [
        "dockerfile", "makefile", "procfile", "gemfile", "license", "readme", "changelog", ".gitignore", ".gitattributes",
        ".env", ".npmrc", ".nvmrc", ".prettierrc", ".eslintrc", ".editorconfig", "_redirects", "_headers", "cname",
    ]

    /// The extension of a path's last part, lowercased ("" when none).
    static func ext(_ path: String) -> String {
        let last = path.split(separator: "/").last.map(String.init) ?? path
        guard let dot = last.lastIndex(of: "."), dot != last.startIndex else { return "" }
        return String(last[last.index(after: dot)...]).lowercased()
    }

    /// The last part names a file: a known extension, or a known file name.
    static func namesFile(_ path: String) -> Bool {
        let last = (path.split(separator: "/").last.map(String.init) ?? path).lowercased()
        if names.contains(last) { return true }
        return extensions.contains(ext(path))
    }

    /// The project-relative path ("/workspace/project/x/a.js" -> "x/a.js", "./a.js" -> "a.js", a folder's "/" gone).
    static func normalize(_ raw: String) -> String {
        var d = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        for p in ["/workspace/project/", "/workspace/project", "/workspace/"] where d.hasPrefix(p) { d.removeFirst(p.count); break }
        while d.hasPrefix("./") { d.removeFirst(2) }
        while d.hasPrefix("/") { d.removeFirst() }
        while d.hasSuffix("/") { d.removeLast() }
        return d == "." ? "" : d
    }

    private static let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-/~@+[]")

    /// What `raw` is when it stands alone (a code span's whole content: `inCode`) or bare in a sentence: a file, a
    /// folder, or nothing. A branch or a known repository of the same shape stays what it is (nil here).
    static func classify(_ raw: String, inCode: Bool, repos: KnownRepos.Snapshot = KnownRepos.Snapshot()) -> FileRef? {
        var s = raw.trimmingCharacters(in: .whitespaces)
        // "src/app.ts:42" - a line after the path
        if inCode, let r = s.range(of: #":[0-9]{1,6}(:[0-9]{1,4})?$"#, options: .regularExpression) { s = String(s[..<r.lowerBound]) }
        guard !s.isEmpty, s.count <= 240, !s.contains("://"), !s.contains("//"), !s.contains("..."),
              s.unicodeScalars.allSatisfy({ allowed.contains($0) }) else { return nil }
        guard let first = s.first, first != "-", first != "@", first != "+", first != "~",
              s.contains(where: { $0.isLetter }) else { return nil }
        // a word that is a branch or a known repository is that chip, never a folder
        if GitHubRef.isBranchName(s) || repos.repo(named: s) != nil { return nil }
        // "github.com/o/r", "bakery.liaisone.app/menu": a site
        if DomainChip.isDomain(s) { return nil }
        let slash = s.contains("/")
        let file = namesFile(s) && !s.hasSuffix("/")
        let underBox = s.hasPrefix("/workspace/")
        if inCode {
            if file {
                // `console.log`, `items.map`: code, not a file - a name alone needs an extension no code member shares
                guard slash || names.contains(s.lowercased()) || !ambiguousAlone.contains(ext(s)) else { return nil }
            } else {
                guard slash, folderShaped(s) else { return nil }
            }
        } else {
            guard slash, file || underBox else { return nil }
            if !file && !folderShaped(s) { return nil }
        }
        let path = normalize(s)
        if !file, !underBox, path.isEmpty { return nil }
        return FileRef(path: path, isDir: !file, written: raw.trimmingCharacters(in: .whitespaces))
    }

    /// A folder written on its own: the box's own path, "./x", "~/x", "x/" or a relative "a/b" of plain names. An absolute
    /// path anywhere else ("/agents/dev/files", a route) is not one of Dev's folders.
    static func folderShaped(_ s: String) -> Bool {
        if s.hasPrefix("/workspace/") || s == "/workspace" { return true }
        if s.hasPrefix("/") { return false }
        if s.hasPrefix("~/") { return false }
        let parts = s.split(separator: "/", omittingEmptySubsequences: true)
        guard !parts.isEmpty else { return false }
        // "1/2", "a/b", "and/or": words, not folders ("src/lib" is one)
        if parts.count == 2, parts.allSatisfy({ $0.count <= 2 }) { return false }
        if wordPairs.contains(s.lowercased()) { return false }
        return parts.allSatisfy { p in !p.isEmpty && p != "." && p.contains(where: { $0.isLetter || $0.isNumber }) }
    }

    private static let wordPairs: Set<String> = ["and/or", "yes/no", "on/off", "true/false", "read/write", "input/output",
                                                 "w/o", "n/a", "i/o", "either/or", "his/her", "he/she", "before/after"]

    private static let codeRx = try! NSRegularExpression(pattern: #"`([^`\n]{1,240})`"#)
    // a bare path: at least one slash and a file's name, or the box's own folder; not inside a word, a url or a domain
    private static let bareRx = try! NSRegularExpression(pattern:
        #"(?<![\w/.\-@:~`])((?:\./|/)?(?:[A-Za-z0-9_.\-@+\[\]]+/)+[A-Za-z0-9_.\-@+\[\]]*[A-Za-z0-9_\]])(?![\w\-/`]|\.\w)"#)

    struct Hit: Equatable {
        let range: NSRange
        let ref: FileRef
        /// Inside a code span (wins over a bare domain or a branch candidate of the same words).
        let inCode: Bool
    }

    /// The paths of the text, in order: each code span that is a whole path (the span's inside), and each bare path.
    static func hits(_ text: String, repos: KnownRepos.Snapshot = KnownRepos.Snapshot()) -> [Hit] {
        let ns = text as NSString
        var out: [Hit] = []
        var taken: [NSRange] = []
        for m in codeRx.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            taken.append(m.range)
            let inner = m.range(at: 1)
            let raw = ns.substring(with: inner)
            // the span's words exactly, its spaces aside
            let lead = raw.prefix(while: { $0 == " " }).utf16.count
            let trail = String(raw.reversed()).prefix(while: { $0 == " " }).utf16.count
            guard inner.length - lead - trail > 0 else { continue }
            let r = NSRange(location: inner.location + lead, length: inner.length - lead - trail)
            if let ref = classify(ns.substring(with: r), inCode: true, repos: repos) {
                out.append(Hit(range: r, ref: ref, inCode: true))
            }
        }
        for m in bareRx.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            let r = m.range(at: 1)
            if taken.contains(where: { NSIntersectionRange($0, r).length > 0 }) { continue }
            // a sentence's full stop after it is not part of it
            var raw = ns.substring(with: r)
            while let l = raw.last, ".,;:!?)".contains(l) { raw.removeLast() }
            guard let ref = classify(raw, inCode: false, repos: repos) else { continue }
            out.append(Hit(range: NSRange(location: r.location, length: (raw as NSString).length), ref: ref, inCode: false))
        }
        return out.sorted { $0.range.location < $1.range.location }
    }

    /// The listed path a chip's path names: the same path, else the one path that ends with it ("index.html" or
    /// "landing/index.html" -> "frontend/landing/index.html"), else the one the list's path ends inside it
    /// ("acme/frontend/a.js" for a list made under "acme"). Nil when none or when it is ambiguous.
    static func match(_ path: String, in paths: [String]) -> String? {
        let p = normalize(path)
        guard !p.isEmpty else { return nil }
        let norm = paths.map { (raw: $0, n: normalize($0)) }
        if let hit = norm.first(where: { $0.n == p }) { return hit.raw }
        let tails = norm.filter { $0.n.hasSuffix("/" + p) }
        if tails.count == 1 { return tails[0].raw }
        if tails.isEmpty {
            let heads = norm.filter { !$0.n.isEmpty && p.hasSuffix("/" + $0.n) }
            if heads.count == 1 { return heads[0].raw }
        }
        return nil
    }
}
