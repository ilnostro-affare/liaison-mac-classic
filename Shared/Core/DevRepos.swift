import Foundation

// The Canvas's Code tab picks its source - Dev's local project, or one of the GitHub repositories
// cloned into it (/workspace/project/<name>, each with its own git) - and, for a repository, one of Dev's LOCAL
// branches. Contract: GET /agents/dev/repos, GET /agents/dev/git (op=ls | show | diff).

/// One local branch of a cloned repository.
struct DevBranch: Equatable, Identifiable, Hashable {
    let name: String
    /// Commits over the repository's default branch.
    let ahead: Int
    /// The checked-out one.
    let current: Bool
    var id: String { name }

    init(name: String, ahead: Int, current: Bool) { self.name = name; self.ahead = ahead; self.current = current }

    /// "+3" when ahead (nil: nothing over the default branch).
    var aheadText: String? { ahead > 0 ? "+\(ahead)" : nil }

    /// The branch menu's entry: "dev/hero +3 \u{00b7} checked out".
    var menuTitle: String {
        var t = name
        if let a = aheadText { t += "  " + a }
        if current { t += " \u{00b7} checked out" }
        return t
    }
}

/// A repository cloned into Dev's project.
struct DevRepo: Equatable, Identifiable, Hashable {
    /// Its folder under the project ("liaison-mac"), or "." when the project itself is the clone.
    let dir: String
    /// The checked-out branch.
    let branch: String
    let remote: String
    /// The default branch ("main").
    let base: String
    /// Uncommitted files of the checked-out branch.
    let dirty: Int
    let branches: [DevBranch]
    var id: String { dir }

    init(dir: String, branch: String, remote: String, base: String, dirty: Int, branches: [DevBranch]) {
        self.dir = dir; self.branch = branch; self.remote = remote; self.base = base; self.dirty = dirty; self.branches = branches
    }

    /// "owner/name" read from the remote (https, ssh "git@host:o/r.git"); nil when it has no two path parts.
    var slug: String? {
        var r = remote.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !r.isEmpty else { return nil }
        if let q = r.firstIndex(where: { $0 == "?" || $0 == "#" }) { r = String(r[..<q]) }
        while r.hasSuffix("/") { r.removeLast() }
        if r.lowercased().hasSuffix(".git") { r.removeLast(4) }
        // "git@github.com:o/r" -> "o/r"; "https://github.com/o/r" -> "github.com/o/r"
        if let s = r.range(of: "://") { r = String(r[s.upperBound...]) } else if let c = r.firstIndex(of: ":") { r = String(r[r.index(after: c)...]) }
        let parts = r.split(separator: "/").map(String.init).filter { !$0.isEmpty }
        guard parts.count >= 2 else { return nil }
        return parts[parts.count - 2] + "/" + parts[parts.count - 1]
    }

    /// The name shown: the folder, else (a clone at the project's root) the remote's repository name.
    var name: String {
        var d = dir.trimmingCharacters(in: .whitespaces)
        while d.hasPrefix("./") { d.removeFirst(2) }
        while d.hasSuffix("/") { d.removeLast() }
        if !d.isEmpty, d != "." { return d.split(separator: "/").last.map(String.init) ?? d }
        if let s = slug, let n = s.split(separator: "/").last { return String(n) }
        return "Repository"
    }

    /// The menu entry: "liaison-mac \u{00b7} dev/hero".
    var label: String { branch.isEmpty ? name : name + " \u{00b7} " + branch }

    /// "3 uncommitted" (nil: clean).
    var dirtyText: String? { dirty > 0 ? "\(dirty) uncommitted" : nil }

    /// What a repository scope of the Code tab shows.
    enum Scope: Equatable { case changes, work, files }

    /// The line beside the scopes: "dev/hero \u{2192} main", "Not committed on dev/hero", "dev/hero, read only".
    func scopeNote(branch b: String, scope: Scope) -> String {
        switch scope {
        case .changes: return base.isEmpty || base == b ? b : b + " \u{2192} " + base
        case .work: return "Not committed on " + b
        case .files: return b + ", read only"
        }
    }

    /// The local branch called `name`.
    func branch(_ name: String) -> DevBranch? { branches.first { $0.name == name } }

    /// The branch the source opens on: `wanted` when it is local, else the checked-out one, else the first.
    func pick(_ wanted: String?) -> String {
        if let w = wanted, !w.isEmpty, branch(w) != nil { return w }
        if !branch.isEmpty { return branch }
        return branches.first(where: { $0.current })?.name ?? branches.first?.name ?? ""
    }

    /// Whether a push to "owner/name" (or just "name") went from this clone.
    func matches(push repo: String) -> Bool {
        var r = repo.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if r.hasSuffix(".git") { r.removeLast(4) }
        guard !r.isEmpty else { return false }
        if let s = slug?.lowercased(), s == r { return true }
        let tail = r.split(separator: "/").last.map(String.init) ?? r
        if r.contains("/") {
            // owner/name: the remote's slug decides when there is one; else the folder's name
            return slug == nil && name.lowercased() == tail
        }
        return name.lowercased() == tail || (slug?.lowercased().split(separator: "/").last.map(String.init) == tail)
    }
}

enum DevRepos {
    /// `{ok, repos:[...]}` -> the repositories (an entry without a folder is left out).
    static func parse(_ data: Data) -> Result<[DevRepo], DevFilesError> {
        guard let o = JSONRead.object(data) else { return .failure(DevFilesError("Could not read the repositories.")) }
        guard JSONRead.bool(o, "ok") else {
            return .failure(DevFilesError(JSONRead.string(o, "error") ?? "Could not read the repositories."))
        }
        return .success(JSONRead.objects(o, "repos").compactMap { r in
            func s(_ k: String) -> String { (JSONRead.string(r, k) ?? "").trimmingCharacters(in: .whitespacesAndNewlines) }
            let dir = s("dir")
            guard !dir.isEmpty else { return nil }
            let checked = s("branch")
            var seen = Set<String>()
            let branches: [DevBranch] = JSONRead.objects(r, "branches").compactMap { b in
                let n = (JSONRead.string(b, "name") ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                guard !n.isEmpty, seen.insert(n).inserted else { return nil }
                return DevBranch(name: n, ahead: max(0, JSONRead.int(b, "ahead") ?? 0),
                                 current: JSONRead.bool(b, "current") || (!checked.isEmpty && n == checked))
            }
            return DevRepo(dir: dir, branch: checked, remote: s("remote"), base: s("base"),
                           dirty: max(0, JSONRead.int(r, "dirty") ?? 0), branches: branches)
        })
    }

    /// The repository and branch a push opens on: the clone it went from, on the pushed branch when it is local.
    static func preselect(_ repos: [DevRepo], push: DevPush?) -> (dir: String, branch: String)? {
        guard let p = push, !p.repo.isEmpty || !p.branch.isEmpty else { return nil }
        let match = repos.first { !p.repo.isEmpty && $0.matches(push: p.repo) }
            // no repo named (or none matched): the only clone holding the pushed branch
            ?? { let h = repos.filter { !p.branch.isEmpty && $0.branch(p.branch) != nil }; return h.count == 1 ? h[0] : nil }()
        guard let r = match else { return nil }
        return (r.dir, r.pick(p.branch))
    }
}

/// What the Code tab reads: the local project (as before), or a repository at one of its branches.
enum DevCodeSource: Equatable, Hashable {
    case project
    case repo(dir: String, branch: String)
    /// One folder of the project (a site's: the folder it is previewed or published from).
    case folder(String)

    var dir: String? { if case .repo(let d, _) = self { return d }; return nil }
    var branch: String? { if case .repo(_, let b) = self { return b }; return nil }
    var folder: String? { if case .folder(let f) = self { return f }; return nil }
}

/// "All files always shows the Meta-Api repository" - the project's listing held every repository cloned
/// into it (Meta-Api's 2,000 files sort first) and the first file was picked from there, whatever the item was. The Code
/// tab now opens on what the item belongs to: a push's repository, a site's own folder (DevSites), else the project
/// without its cloned repositories (each of those has its own entry in the source menu).
enum DevCodeScope {
    /// "/workspace/project/sites/a/" -> "sites/a"; "." and "" -> "".
    static func normalize(_ raw: String?) -> String {
        var d = (raw ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        for p in ["/workspace/project/", "/workspace/project", "/workspace/"] where d.hasPrefix(p) { d.removeFirst(p.count); break }
        while d.hasPrefix("./") { d.removeFirst(2) }
        while d.hasPrefix("/") { d.removeFirst() }
        while d.hasSuffix("/") { d.removeLast() }
        return d == "." ? "" : d
    }

    /// The project folder a page belongs to: a private preview shows the preview's folder; a published site the folder
    /// it was published from (matched by its address). Nil: unknown, or the project's top.
    static func siteDir(page: URL?, sites: DevSites?) -> String? {
        guard let page, let sites else { return nil }
        let dir: String?
        if DevSites.isPrivatePreview(page) {
            dir = sites.previewDir
        } else if let h = page.host?.lowercased() {
            dir = sites.sites.first { $0.url.host?.lowercased() == h }?.dir
        } else {
            dir = nil
        }
        let d = normalize(dir)
        return d.isEmpty ? nil : d
    }

    /// The source the Code tab opens on for an item: a push's clone, else its site's folder (the clone holding it at the
    /// checked-out branch when the folder is a clone), else the project.
    static func pick(push: DevPush?, page: URL?, repos: [DevRepo], sites: DevSites?) -> DevCodeSource {
        if let r = DevRepos.preselect(repos, push: push) { return .repo(dir: r.dir, branch: r.branch) }
        if let d = siteDir(page: page, sites: sites) {
            if let r = repos.first(where: { normalize($0.dir) == d && !d.isEmpty }) { return .repo(dir: r.dir, branch: r.pick(nil)) }
            return .folder(d)
        }
        return .project
    }

    /// The folders of the clones (not the project itself when it is one).
    static func repoDirs(_ repos: [DevRepo]) -> [String] {
        repos.map { normalize($0.dir) }.filter { !$0.isEmpty }
    }

    /// The project's entries without the cloned repositories' folders and what is under them.
    static func projectEntries(_ entries: [String], repos: [DevRepo]) -> [String] {
        let dirs = repoDirs(repos)
        guard !dirs.isEmpty else { return entries }
        return entries.filter { e in
            let p = normalize(e)
            return !dirs.contains { p == $0 || p.hasPrefix($0 + "/") }
        }
    }

    /// The entries under `dir`, relative to it ("sites/a/index.html" -> "index.html").
    static func folderEntries(_ entries: [String], dir: String) -> [String] {
        let d = normalize(dir)
        guard !d.isEmpty else { return entries }
        return entries.compactMap { e in
            let p = normalize(e)
            guard p.hasPrefix(d + "/") else { return nil }
            let rest = String(p.dropFirst(d.count + 1))
            return e.hasSuffix("/") ? rest + "/" : rest
        }
    }

    /// A path of a folder source as the project knows it ("index.html" in "sites/a" -> "sites/a/index.html").
    static func projectPath(_ path: String, in dir: String) -> String {
        let d = normalize(dir)
        return d.isEmpty ? path : d + "/" + path
    }

    /// The most entries one GET /agents/dev/files answers with (the box's `find ... | head -400`): a listing this long was
    /// cut, and what sorts after the cut (in a project holding a big clone: most of the project's own files) is missing.
    static let listCap = 400

    /// Whether a listing reached the cap (and so may miss entries).
    static func isCut(_ entries: [String]) -> Bool { entries.count >= listCap }

    /// ("All files shows nothing anywhere"): the project's listing stops at 400 entries and a cloned
    /// repository (Meta-Api, 2,000 files, sorting first) fills it, so the project without its clones came out empty. The
    /// folders to read on their own when that happens: the sites' folders and the top-level folders seen, never a clone
    /// (nor what is inside one), each once, the shortest first, a folder already under another left out.
    static func extraDirs(_ entries: [String], repos: [DevRepo], sites: [String]) -> [String] {
        let clones = repoDirs(repos)
        func inClone(_ d: String) -> Bool { clones.contains { d == $0 || d.hasPrefix($0 + "/") } }
        var top: [String] = []
        for e in entries {
            let p = normalize(e)
            guard let first = p.split(separator: "/").first.map(String.init), !first.isEmpty else { continue }
            // a top-level folder: something sits under it, or the server marked it with a trailing "/"
            if p.contains("/") || e.hasSuffix("/") { top.append(first) }
        }
        var out: [String] = []
        for d in (sites.map { normalize($0) } + top).sorted(by: { $0.count < $1.count })
        where !d.isEmpty && !inClone(d) && !out.contains(where: { d == $0 || d.hasPrefix($0 + "/") }) {
            out.append(d)
        }
        return out
    }

    /// `entries` of folder `dir` (relative to it) as the project's paths ("index.html" in "sites/a" -> "sites/a/index.html").
    static func prefixed(_ entries: [String], dir: String) -> [String] {
        entries.map { e in
            let p = normalize(e)
            let full = projectPath(p, in: dir)
            return e.hasSuffix("/") ? full + "/" : full
        }
    }

    /// Whether a changed file belongs to an item: under its site's folder when it has one, else anywhere in the project
    /// but inside a cloned repository.
    static func owns(_ path: String, folder: String?, repos: [DevRepo]) -> Bool {
        let p = normalize(path)
        if let f = folder.map({ normalize($0) }), !f.isEmpty { return p == f || p.hasPrefix(f + "/") }
        return !repoDirs(repos).contains { p == $0 || p.hasPrefix($0 + "/") }
    }

    /// The sites' folders the source menu offers (by the site's address), without the project's top and the clones.
    static func siteFolders(_ sites: DevSites?, repos: [DevRepo]) -> [DevSiteFolder] {
        guard let sites else { return [] }
        let clones = Set(repoDirs(repos))
        var seen = Set<String>()
        var out: [DevSiteFolder] = []
        var all = sites.sites.map { DevSiteFolder(dir: normalize($0.dir), label: $0.url.host ?? $0.slug) }
        let pv = normalize(sites.previewDir)
        if !pv.isEmpty, !all.contains(where: { $0.dir == pv }) { all.insert(DevSiteFolder(dir: pv, label: "Preview"), at: 0) }
        for s in all where !s.dir.isEmpty && !clones.contains(s.dir) && seen.insert(s.dir).inserted { out.append(s) }
        return out
    }
}

/// A site's folder in the Code tab's source menu.
struct DevSiteFolder: Equatable, Hashable, Identifiable {
    let dir: String
    let label: String
    var id: String { dir }
}

/// A repository's diff (GET /agents/dev/git op=diff): a branch over the default one, or the uncommitted work.
struct DevGitDiff: Equatable {
    let changes: [DevFileChange]
    let diff: String
    let cut: Bool
    let commits: [DevCommit]
    /// Uncommitted, untracked files (work only).
    let untracked: [String]
    let work: Bool
    let ref: String
    let base: String

    static func parse(_ data: Data) -> Result<DevGitDiff, DevFilesError> {
        guard let o = JSONRead.object(data) else { return .failure(DevFilesError("Could not read the changes.")) }
        guard JSONRead.bool(o, "ok") else {
            return .failure(DevFilesError(JSONRead.string(o, "error") ?? "Could not read the changes."))
        }
        let changes: [DevFileChange] = JSONRead.objects(o, "changes").compactMap { c in
            guard let p = JSONRead.string(c, "path"), !p.isEmpty else { return nil }
            return DevFileChange(path: p, add: JSONRead.int(c, "add") ?? 0, del: JSONRead.int(c, "del") ?? 0)
        }
        let untracked = JSONRead.strings(o, "untracked").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        return .success(DevGitDiff(changes: changes, diff: JSONRead.string(o, "diff") ?? "", cut: JSONRead.bool(o, "cut"),
                                   commits: DevCommit.list(o), untracked: untracked, work: JSONRead.bool(o, "work"),
                                   ref: JSONRead.string(o, "ref") ?? "", base: branchName(JSONRead.string(o, "base"))))
    }

    /// The default branch's name; a commit id (servers sent the merge-base there) is no name.
    static func branchName(_ s: String?) -> String {
        let v = (s ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let isSha = v.count >= 7 && v.count <= 40 && v.allSatisfy { $0.isHexDigit && !$0.isUppercase }
        return isSha ? "" : v
    }

    /// Said when the diff holds nothing: "No uncommitted changes."; "dev/x holds nothing over main."
    func emptyText(branch: String, base fallback: String) -> String {
        if work { return "No uncommitted changes." }
        let r = ref.isEmpty ? branch : ref
        let b = base.isEmpty ? fallback : base
        if b.isEmpty || b == r { return r.isEmpty ? "No changes." : r + " is the default branch: nothing to compare." }
        return r + " holds nothing over " + b + "."
    }

    /// The changed files: the server's list, else the parsed diff's own (a binary file is -1/-1).
    static func fileList(_ changes: [DevFileChange], _ files: [DevDiff.File]) -> [DevFileChange] {
        if !changes.isEmpty { return changes }
        return files.map { DevFileChange(path: $0.path, add: $0.binary ? -1 : $0.add, del: $0.binary ? -1 : $0.del) }
    }
}
