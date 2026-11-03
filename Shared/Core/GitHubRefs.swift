import Foundation

// Branches, commits and pull requests as chips, like in Claude. A GitHub link in an answer
// (github.com/<owner>/<repo>/pull/<n>, /tree/<branch>, /commit/<sha>, /compare/<base>...<head>), a Dev branch name
// written in the text (dev/landing-light-theme) and the structured blocks {kind:"dev_pr"} / {kind:"dev_branch"} become
// one chip each; its hover card shows what is known (GitHubRefInfo). Pure: parsing and merging only.

/// What a GitHub chip points at.
struct GitHubRef: Equatable, Hashable {
    enum Kind: String, Equatable { case pr, branch, commit, repo }

    let kind: Kind
    /// "owner/name" ("" when the text named a branch alone).
    let repo: String
    let number: Int?
    let branch: String?
    let sha: String?

    init(kind: Kind, repo: String, number: Int? = nil, branch: String? = nil, sha: String? = nil) {
        self.kind = kind; self.repo = repo; self.number = number; self.branch = branch; self.sha = sha
    }

    static func pr(_ repo: String, _ n: Int) -> GitHubRef { GitHubRef(kind: .pr, repo: repo, number: n) }
    static func branch(_ name: String, repo: String = "") -> GitHubRef { GitHubRef(kind: .branch, repo: repo, branch: name) }
    static func commit(_ sha: String, repo: String) -> GitHubRef { GitHubRef(kind: .commit, repo: repo, sha: sha.lowercased()) }
    /// A repository named in Dev's text ("owner/name") is a chip too.
    static func repo(_ fullName: String) -> GitHubRef { GitHubRef(kind: .repo, repo: fullName) }

    /// The cache key: the same branch of the same repository is one entry (a branch named without its repository is
    /// keyed by the name alone).
    var key: String {
        switch kind {
        case .pr: return "pr|" + repo.lowercased() + "|" + String(number ?? 0)
        case .branch: return "br|" + (branch ?? "")
        case .commit: return "c|" + String((sha ?? "").prefix(7))
        case .repo: return "r|" + repo.lowercased()
        }
    }

    /// "name" of "owner/name".
    var repoName: String { repo.split(separator: "/").last.map(String.init) ?? repo }

    /// The chip's words: "repo#12", the branch, the short sha.
    var label: String {
        switch kind {
        case .pr: return (repoName.isEmpty ? "" : repoName) + "#" + String(number ?? 0)
        case .branch: return branch ?? ""
        case .commit: return String((sha ?? "").prefix(7))
        case .repo: return repo
        }
    }

    /// The page on GitHub (nil without a repository).
    var webURL: URL? {
        guard repo.contains("/") else { return nil }
        let base = "https://github.com/" + repo
        switch kind {
        case .pr: return number.flatMap { URL(string: base + "/pull/" + String($0)) }
        case .branch:
            guard let b = branch, let e = b.addingPercentEncoding(withAllowedCharacters: Self.pathAllowed) else { return nil }
            return URL(string: base + "/tree/" + e)
        case .commit: return sha.flatMap { URL(string: base + "/commit/" + $0) }
        case .repo: return URL(string: base)
        }
    }

    private static let pathAllowed: CharacterSet = {
        var c = CharacterSet.urlPathAllowed
        c.remove(charactersIn: "?#")
        return c
    }()

    /// A GitHub page's address -> the ref it names (nil: not one of the four kinds, or not github.com).
    static func parse(_ raw: String) -> GitHubRef? {
        let t = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let u = URL(string: t), let s = u.scheme?.lowercased(), s == "https" || s == "http",
              let h = u.host?.lowercased(), h == "github.com" || h == "www.github.com" else { return nil }
        var parts = u.path.split(separator: "/", omittingEmptySubsequences: true).map { String($0).removingPercentEncoding ?? String($0) }
        guard parts.count >= 4 else { return nil }
        let repo = parts[0] + "/" + parts[1]
        guard validName(parts[0]), validName(parts[1]) else { return nil }
        let what = parts[2].lowercased()
        parts.removeFirst(3)
        switch what {
        case "pull", "pulls":
            guard let n = Int(parts[0]), n > 0 else { return nil }
            return .pr(repo, n)
        case "tree":
            let b = parts.joined(separator: "/")
            return b.isEmpty ? nil : .branch(b, repo: repo)
        case "commit", "commits":
            let sha = parts[0]
            guard sha.count >= 7, sha.count <= 40, sha.allSatisfy({ $0.isHexDigit }) else { return nil }
            return .commit(sha, repo: repo)
        case "compare":
            // base...head (or base..head): the head branch
            let spec = parts.joined(separator: "/")
            let head: String
            if let r = spec.range(of: "...") { head = String(spec[r.upperBound...]) }
            else if let r = spec.range(of: "..") { head = String(spec[r.upperBound...]) }
            else { head = spec }
            return head.isEmpty ? nil : .branch(head, repo: repo)
        default:
            return nil
        }
    }

    /// A repository's own page ("https://github.com/owner/name", nothing after it) -> a repo ref. Kept apart from
    /// `parse`, which names only the pages inside a repository.
    static func parseRepo(_ raw: String) -> GitHubRef? {
        let t = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let u = URL(string: t), let s = u.scheme?.lowercased(), s == "https" || s == "http",
              let h = u.host?.lowercased(), h == "github.com" || h == "www.github.com", u.query == nil, u.fragment == nil else { return nil }
        let parts = u.path.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        guard parts.count == 2, validName(parts[0]), validName(parts[1]) else { return nil }
        var name = parts[1]
        if name.lowercased().hasSuffix(".git") { name = String(name.dropLast(4)) }
        guard !name.isEmpty else { return nil }
        return .repo(parts[0] + "/" + name)
    }

    /// A repository's full name as written ("owner/name"): both parts GitHub-valid.
    static func isRepoName(_ s: String) -> Bool {
        let parts = s.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        return parts.count == 2 && validName(parts[0]) && validName(parts[1])
    }

    private static func validName(_ s: String) -> Bool {
        !s.isEmpty && s.count <= 100 && s.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" || $0 == ".") }
    }

    /// The prefixes a branch written in prose is recognised by ("feat/x, fix/x, claude/x, dev/x,
    /// release/x"); any other word with a slash is a branch only when the dialogue's blocks named it (KnownBranches).
    /// (Folder-like words - docs/, test/, build/ - are left out: "docs/RELEASE" in prose is a path.)
    static let branchPrefixes = ["dev", "feat", "feature", "fix", "bugfix", "hotfix", "claude", "release", "chore",
                                 "codex", "refactor", "exp", "wip"]

    /// A branch named in the text: a known prefix (not a file path: no "name.ext" at the end) or a known branch.
    static func isBranchName(_ s: String) -> Bool {
        guard s.count > 2, s.count <= 120, !s.hasSuffix("/"), !s.hasSuffix("."), !s.contains(".."), !s.contains("//"),
              s.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || "-_./".contains($0)) }) else { return false }
        if KnownBranches.shared.contains(s) { return true }
        guard let slash = s.firstIndex(of: "/") else { return false }
        let head = s[..<slash].lowercased()
        guard branchPrefixes.contains(head) else { return false }
        // "docs/readme.md", "test/app.spec.js": a file, not a branch
        let last = s.split(separator: "/").last.map(String.init) ?? s
        if let dot = last.lastIndex(of: "."), dot != last.startIndex {
            let ext = last[last.index(after: dot)...]
            if !ext.isEmpty, ext.count <= 5, ext.allSatisfy({ $0.isLetter }) { return false }
        }
        return true
    }

    /// A Dev branch written in the text ("dev/landing-light-theme"): Dev names its branches `dev/...`.
    static func isDevBranch(_ s: String) -> Bool {
        guard s.hasPrefix("dev/"), s.count > 4, s.count <= 100 else { return false }
        return s.dropFirst(4).allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || "-_./".contains($0)) }
            && !s.hasSuffix("/") && !s.hasSuffix(".") && !s.contains("..")
    }
}

/// What a chip's hover card can say. Every field is optional: the card shows what is known.
struct GitHubRefInfo: Equatable {
    var title: String?
    /// "open" | "closed" | "merged" | "draft".
    var state: String?
    var base: String?
    var head: String?
    /// "passing" | "failing" | "pending" (any word the server sends, shown as it is).
    var checks: String?
    var lastMessage: String?
    var lastAt: Date?
    var ahead: Int?
    var behind: Int?
    var commits: Int?
    /// The branch's preview or live site.
    var preview: URL?
    var url: URL?
    var repo: String?
    /// (GET /agents/github/ref): who made it, its size, a branch's pull request.
    var author: String?
    var avatar: URL?
    var additions: Int?
    var deletions: Int?
    var files: Int?
    var prNumber: Int?
    var prState: String?
    /// The server answered for this ref (its card does not ask again).
    var fetched = false

    init(title: String? = nil, state: String? = nil, base: String? = nil, head: String? = nil, checks: String? = nil,
         lastMessage: String? = nil, lastAt: Date? = nil, ahead: Int? = nil, behind: Int? = nil, commits: Int? = nil,
         preview: URL? = nil, url: URL? = nil, repo: String? = nil) {
        self.title = title; self.state = state; self.base = base; self.head = head; self.checks = checks
        self.lastMessage = lastMessage; self.lastAt = lastAt; self.ahead = ahead; self.behind = behind; self.commits = commits
        self.preview = preview; self.url = url; self.repo = repo
    }

    /// GET /agents/github/ref's answer -> what the card shows (nil: not ok). A PR's title is its title; a branch's
    /// or commit's is its last commit's message; a repository's its description.
    static func fromServer(_ data: Data) -> GitHubRefInfo? {
        guard let o = JSONRead.object(data), JSONRead.bool(o, "ok"), let r = o["ref"] as? JSONObject else { return nil }
        func s(_ k: String) -> String? {
            let v = (JSONRead.string(r, k) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            return v.isEmpty ? nil : v
        }
        let kind = s("kind") ?? ""
        var i = GitHubRefInfo()
        i.repo = s("repo")
        i.url = s("url").flatMap { URL(string: $0) }
        i.lastAt = JSONRead.double(r, "at").flatMap { $0 > 0 ? Date(timeIntervalSince1970: $0 / 1000) : nil }
        if kind == "pr" { i.title = s("title"); i.state = s("state") } else { i.lastMessage = s("title") }
        if kind == "repo" { i.title = s("title") }
        i.base = s("base"); i.head = s("head")
        i.ahead = JSONRead.int(r, "ahead"); i.behind = JSONRead.int(r, "behind"); i.commits = JSONRead.int(r, "commits")
        i.additions = JSONRead.int(r, "additions"); i.deletions = JSONRead.int(r, "deletions"); i.files = JSONRead.int(r, "files")
        if let a = r["author"] as? JSONObject {
            i.author = JSONRead.string(a, "login").flatMap { $0.isEmpty ? nil : $0 }
            i.avatar = JSONRead.string(a, "avatar").flatMap { URL(string: $0) }
        }
        if let p = r["pr"] as? JSONObject, let n = JSONRead.int(p, "number"), n > 0 {
            i.prNumber = n
            i.prState = JSONRead.string(p, "state")
            if let t = JSONRead.string(p, "title"), !t.isEmpty { i.title = t }
            if i.state == nil { i.state = i.prState }
        }
        i.fetched = true
        return i
    }

    /// `newer`'s known fields over these.
    func merged(_ newer: GitHubRefInfo) -> GitHubRefInfo {
        var o = self
        o.title = newer.title ?? title; o.state = newer.state ?? state; o.base = newer.base ?? base; o.head = newer.head ?? head
        o.checks = newer.checks ?? checks; o.lastMessage = newer.lastMessage ?? lastMessage; o.lastAt = newer.lastAt ?? lastAt
        o.ahead = newer.ahead ?? ahead; o.behind = newer.behind ?? behind; o.commits = newer.commits ?? commits
        o.preview = newer.preview ?? preview; o.url = newer.url ?? url; o.repo = newer.repo ?? repo
        o.author = newer.author ?? author; o.avatar = newer.avatar ?? avatar; o.additions = newer.additions ?? additions
        o.deletions = newer.deletions ?? deletions; o.files = newer.files ?? files; o.prNumber = newer.prNumber ?? prNumber
        o.prState = newer.prState ?? prState; o.fetched = newer.fetched || fetched
        return o
    }

    /// "base \u{2190} head" (a PR) when both are known.
    var route: String? {
        guard let b = base, !b.isEmpty, let h = head, !h.isEmpty else { return nil }
        return b + " \u{2190} " + h
    }

    /// "+3 \u{00b7} \u{2212}1" ahead / behind; nil when neither is known.
    var aheadBehind: String? {
        var p: [String] = []
        if let a = ahead { p.append("\(a) ahead") }
        if let b = behind { p.append("\(b) behind") }
        return p.isEmpty ? nil : p.joined(separator: " \u{00b7} ")
    }

    /// "Open", "Merged" ... (nil: unknown).
    var stateText: String? {
        guard let s = state?.trimmingCharacters(in: .whitespaces), !s.isEmpty else { return nil }
        return s.prefix(1).uppercased() + s.dropFirst().lowercased()
    }
}

/// The structured blocks the server sends for GitHub work: `{kind:"dev_pr", repo, number, title, url, state, branch, base,
/// checks?}`, `{kind:"dev_branch", repo, branch, url, commit, preview?, ahead?, behind?}`; a `dev_push` names its branch too.
enum GitHubRefBlock {
    static func parse(_ b: ChatBlock) -> (ref: GitHubRef, info: GitHubRefInfo)? {
        let o = b.raw
        func s(_ k: String) -> String? {
            let v = (JSONRead.string(o, k) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            return v.isEmpty ? nil : v
        }
        let url = DevPush.web(s("url") ?? b.url)
        switch b.kind ?? b.tool ?? "" {
        case "dev_pr":
            let fromURL = url.flatMap { GitHubRef.parse($0.absoluteString) }
            let repo = s("repo") ?? fromURL?.repo ?? ""
            guard let n = JSONRead.int(o, "number") ?? fromURL?.number, n > 0 else { return nil }
            let info = GitHubRefInfo(title: s("title"), state: s("state"), base: s("base"), head: s("branch") ?? s("head"),
                                     checks: s("checks"), url: url ?? GitHubRef.pr(repo, n).webURL, repo: repo.isEmpty ? nil : repo)
            return (.pr(repo, n), info)
        case "dev_branch":
            let fromURL = url.flatMap { GitHubRef.parse($0.absoluteString) }
            guard let br = s("branch") ?? fromURL?.branch else { return nil }
            let repo = s("repo") ?? fromURL?.repo ?? ""
            let ref = GitHubRef.branch(br, repo: repo)
            var info = GitHubRefInfo(base: s("base"), ahead: JSONRead.int(o, "ahead"), behind: JSONRead.int(o, "behind"),
                                     preview: DevArtMeta.page(s("preview")), url: url ?? ref.webURL, repo: repo.isEmpty ? nil : repo)
            if let c = o?["commit"] as? JSONObject {
                info.lastMessage = JSONRead.string(c, "msg") ?? JSONRead.string(c, "message")
                info.lastAt = JSONRead.double(c, "at").flatMap { $0 > 0 ? Date(timeIntervalSince1970: $0 > 1e11 ? $0 / 1000 : $0) : nil }
            } else if let m = s("message") {
                info.lastMessage = m
            }
            info.lastMessage = info.lastMessage.map { RepoActivity.firstLine($0) }
            return (ref, info)
        default:
            guard let p = DevPush(b), !p.branch.isEmpty else { return nil }
            let ref = GitHubRef.branch(p.branch, repo: p.repo)
            let last = p.commits.first?.title
            let info = GitHubRefInfo(base: p.base.isEmpty ? nil : p.base, lastMessage: last.map { RepoActivity.firstLine($0) },
                                     commits: p.commitCount > 0 ? p.commitCount : nil, preview: p.meta.preview,
                                     url: p.url ?? ref.webURL, repo: p.repo.isEmpty ? nil : p.repo)
            return (ref, info)
        }
    }
}

/// The branches the open dialogues' blocks named (dev_push, dev_branch, dev_pr heads), so a branch with any name written
/// in the text becomes a chip once a block has named it. Read from any thread (the chips are built where the text is).
final class KnownBranches: @unchecked Sendable {
    static let shared = KnownBranches()
    private let lock = NSLock()
    private var names: Set<String> = []

    func add(_ name: String) {
        let n = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard n.contains("/"), n.count <= 120 else { return }
        lock.lock(); names.insert(n); lock.unlock()
    }

    func contains(_ name: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return names.contains(name)
    }
}

/// A domain written bare in the text ("bakery.liaisone.app"): lowercase, a TLD people write sites with (not a file name:
/// "deploy.sh", "Liaison.app", "index.md" stay text).
enum DomainChip {
    static let tlds: Set<String> = ["com", "net", "org", "io", "app", "dev", "ai", "co", "it", "si", "de", "fr", "uk", "eu",
                                    "us", "es", "nl", "ch", "at", "be", "pl", "se", "no", "fi", "dk", "pt", "cz", "sk", "ie",
                                    "xyz", "site", "online", "store", "shop", "tech", "page", "link", "info", "biz", "ru",
                                    "ua", "ca", "au", "in", "jp", "br", "mx", "tv", "studio", "agency", "design", "blog"]

    static func isDomain(_ raw: String) -> Bool {
        let hostPart = raw.split(separator: "/", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? raw
        let host = hostPart.split(separator: ":").first.map(String.init) ?? hostPart
        guard host == host.lowercased(), host.contains("."), host.count <= 253 else { return false }
        let labels = host.split(separator: ".", omittingEmptySubsequences: false)
        guard labels.count >= 2, labels.allSatisfy({ !$0.isEmpty }), let tld = labels.last else { return false }
        return tlds.contains(String(tld))
    }

    /// The words a site chip shows: host and path, no scheme, no "www.", no trailing slash, at most 60 characters.
    static func label(_ url: String) -> String {
        var s = url
        for p in ["https://", "http://"] where s.lowercased().hasPrefix(p) { s.removeFirst(p.count); break }
        if s.hasPrefix("www.") { s.removeFirst(4) }
        while s.hasSuffix("/") { s.removeLast() }
        if s.count > 60 { s = String(s.prefix(57)) + "\u{2026}" }
        return s
    }
}

/// ("a Dev branch chip says 'No preview or repository known yet'"): what a dialogue's own messages tell
/// about its branches - every dev_push / dev_branch / dev_pr block (with its repository), and for a branch with no
/// preview of its own the dialogue's Dev preview of the same turn (else the newest one before it, else the next one).
enum GitHubDialogue {
    struct Entry {
        let run: String?
        let blocks: [ChatBlock]
        let text: String
        init(run: String?, blocks: [ChatBlock], text: String) { self.run = run; self.blocks = blocks; self.text = text }
    }

    static func links(_ entries: [Entry]) -> [(ref: GitHubRef, info: GitHubRefInfo)] {
        // the pages each turn made, and in order
        var runPage: [String: URL] = [:]
        var pages: [(index: Int, url: URL)] = []
        for (i, e) in entries.enumerated() {
            for b in e.blocks {
                guard let u = CanvasItem.page(of: b) else { continue }
                pages.append((i, u))
                if let r = e.run, runPage[r] == nil || DevSites.isPrivatePreview(u) { runPage[r] = u }
            }
        }
        func page(near i: Int, run: String?) -> URL? {
            if let r = run, let u = runPage[r] { return u }
            if let before = pages.last(where: { $0.index <= i }) { return before.url }
            return pages.first(where: { $0.index > i && $0.index <= i + 4 })?.url
        }
        var out: [(ref: GitHubRef, info: GitHubRefInfo)] = []
        var named = Set<String>()
        for (i, e) in entries.enumerated() {
            for b in e.blocks {
                guard var g = GitHubRefBlock.parse(b) else { continue }
                if g.ref.kind == .branch, g.info.preview == nil { g.info.preview = page(near: i, run: e.run) }
                if let br = g.ref.branch { named.insert(br) }
                if g.ref.kind == .pr, let h = g.info.head { named.insert(h) }
                out.append(g)
            }
        }
        // branches only written in a turn's words: that turn's page
        for (i, e) in entries.enumerated() where e.run != nil && !e.text.isEmpty {
            for name in branchNames(in: e.text) where !named.contains(name) {
                guard let u = page(near: i, run: e.run) else { continue }
                named.insert(name)
                out.append((.branch(name), GitHubRefInfo(preview: u)))
            }
        }
        return out
    }

    private static let branchRe = try? NSRegularExpression(pattern: #"(?<![\w/.\-@:])([A-Za-z0-9][A-Za-z0-9_\-]{0,30}/[A-Za-z0-9](?:[A-Za-z0-9._/\-]{0,95}[A-Za-z0-9_])?)"#)

    /// The branch names with a known prefix written in `text`.
    static func branchNames(in text: String) -> [String] {
        guard let re = branchRe else { return [] }
        let ns = text as NSString
        var out: [String] = []
        for m in re.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            let s = ns.substring(with: m.range(at: 1))
            if GitHubRef.isBranchName(s), !out.contains(s) { out.append(s) }
        }
        return out
    }
}
