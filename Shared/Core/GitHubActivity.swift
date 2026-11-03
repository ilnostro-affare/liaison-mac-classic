import Foundation

// Home's brief shows the workspace's repositories like a GitHub profile's contributions.
// GET /agents/github/activity?profile=<id> -> { ok, repos: [...] }. The pure pieces: parsing, the squares' levels,
// the last commit's first line and age.

struct RepoActivity: Equatable, Identifiable {
    struct Commit: Equatable {
        var message: String
        var at: Date?
        var author: String?
    }

    let fullName: String
    var htmlURL: URL?
    var commits7d: Int
    var commits30d: Int
    /// Commits per week, oldest first, at most `maxWeeks`.
    var weeks: [Int]
    var lastCommit: Commit?
    var openPRs: Int
    var id: String { fullName.lowercased() }

    static let maxWeeks = 26

    /// "site" of "owner/site".
    var name: String { fullName.split(separator: "/").last.map(String.init) ?? fullName }
    var owner: String { fullName.split(separator: "/").first.map(String.init) ?? "" }

    /// nil: not an answer (ok false, unreadable). An empty list is an answer (GitHub not connected, no repositories).
    static func parseList(_ data: Data) -> [RepoActivity]? {
        guard let o = JSONRead.object(data), JSONRead.bool(o, "ok") else { return nil }
        var out: [RepoActivity] = []
        for r in JSONRead.objects(o, "repos") {
            guard let n = JSONRead.string(r, "full_name"), n.contains("/") else { continue }
            if out.contains(where: { $0.id == n.lowercased() }) { continue }
            let weeks = ((r["weeks"] as? [Any]) ?? []).map { v -> Int in
                if JSONRead.isBool(v) { return 0 }
                if let x = v as? NSNumber { return max(0, x.intValue) }
                return 0
            }
            var last: Commit? = nil
            if let c = r["last_commit"] as? JSONObject {
                let msg = firstLine(JSONRead.string(c, "message") ?? "")
                let at = JSONRead.double(c, "at").flatMap { $0 > 0 ? Date(timeIntervalSince1970: $0 / 1000) : nil }
                let author = JSONRead.string(c, "author").flatMap { $0.isEmpty ? nil : $0 }
                if !msg.isEmpty || at != nil { last = Commit(message: msg, at: at, author: author) }
            }
            out.append(RepoActivity(fullName: n, htmlURL: GitHubStatus.web(JSONRead.string(r, "html_url")),
                                    commits7d: max(0, JSONRead.int(r, "commits_7d") ?? 0),
                                    commits30d: max(0, JSONRead.int(r, "commits_30d") ?? 0),
                                    weeks: Array(weeks.suffix(maxWeeks)), lastCommit: last,
                                    openPRs: max(0, JSONRead.int(r, "open_prs") ?? 0)))
        }
        return out
    }

    /// The answer with its freshness: `stale` true when the server answered from its last copy while it refreshes
    /// behind it. nil: not an answer.
    static func parseAnswer(_ data: Data) -> (list: [RepoActivity], stale: Bool)? {
        guard let list = parseList(data) else { return nil }
        return (list, JSONRead.bool(JSONRead.object(data), "stale"))
    }

    /// The list in the server's own shape, so the copy kept on disk reads back through `parseList`.
    static func encodeList(_ list: [RepoActivity]) -> Data {
        let repos: [[String: Any]] = list.map { r in
            var o: [String: Any] = ["full_name": r.fullName, "commits_7d": r.commits7d, "commits_30d": r.commits30d,
                                    "weeks": r.weeks, "open_prs": r.openPRs]
            if let u = r.htmlURL { o["html_url"] = u.absoluteString }
            if let c = r.lastCommit {
                var lc: [String: Any] = ["message": c.message]
                if let at = c.at { lc["at"] = (at.timeIntervalSince1970 * 1000).rounded() }
                if let a = c.author { lc["author"] = a }
                o["last_commit"] = lc
            }
            return o
        }
        return (try? JSONSerialization.data(withJSONObject: ["ok": true, "repos": repos])) ?? Data()
    }

    /// A commit message's first line, trimmed and capped.
    static func firstLine(_ s: String, limit: Int = 120) -> String {
        let line = s.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
        let t = line.trimmingCharacters(in: .whitespaces)
        return t.count > limit ? String(t.prefix(limit - 1)) + "\u{2026}" : t
    }

    /// The last `n` weeks, padded with zeros at the start (oldest first), so every strip has the same length.
    func strip(_ n: Int) -> [Int] {
        let n = max(0, min(n, Self.maxWeeks))
        let tail = Array(weeks.suffix(n))
        return Array(repeating: 0, count: n - tail.count) + tail
    }

    /// The square's shade, as on GitHub: 0 (none) ... 4, relative to the busiest week shown.
    static func level(_ count: Int, max top: Int) -> Int {
        guard count > 0, top > 0 else { return 0 }
        let q = Double(count) / Double(top)
        if q <= 0.25 { return 1 }
        if q <= 0.5 { return 2 }
        if q <= 0.75 { return 3 }
        return 4
    }

    /// Most recently active first (no last commit: last), then by name.
    static func sorted(_ list: [RepoActivity]) -> [RepoActivity] {
        list.sorted { a, b in
            let x = a.lastCommit?.at ?? .distantPast, y = b.lastCommit?.at ?? .distantPast
            if x != y { return x > y }
            return a.fullName.lowercased() < b.fullName.lowercased()
        }
    }

    /// "3 commits this week" / "1 commit this week" / "No commits this week".
    var weekLine: String {
        commits7d == 0 ? "No commits this week" : commits7d == 1 ? "1 commit this week" : "\(commits7d) commits this week"
    }
}

/// Whether Home shows the quiet "Connect GitHub" line: only when the workspace keeps no repositories and GitHub is
/// known to be not connected (an unknown status shows nothing).
enum RepoActivityHint {
    static func showConnect(workspaceRepos: Int, connected: Bool?) -> Bool {
        workspaceRepos == 0 && connected == false
    }
}
