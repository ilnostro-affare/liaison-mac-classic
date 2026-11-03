import Foundation

// The person's GitHub, connected through our GitHub App "liaisone" so Dev can work in their repositories
// (lia-agents /agents/github/*). The pure pieces: the connection's status, the repositories the app can reach, and
// the repositories a workspace keeps (CompanyProfile.githubRepos).

/// GET /agents/github/status.
struct GitHubStatus: Equatable {
    struct Installation: Equatable, Identifiable {
        let id: Int
        let account: String
        /// "User" | "Organization".
        let type: String
    }

    var connected: Bool
    var login: String?
    var avatar: URL?
    var installations: [Installation]
    var manageURL: URL?

    static let none = GitHubStatus(connected: false, login: nil, avatar: nil, installations: [], manageURL: nil)

    /// nil: not an answer (ok false, unreadable).
    static func parse(_ data: Data) -> GitHubStatus? {
        guard let o = JSONRead.object(data), JSONRead.bool(o, "ok") else { return nil }
        let inst: [Installation] = JSONRead.objects(o, "installations").compactMap { i in
            guard let id = JSONRead.int(i, "id") else { return nil }
            return Installation(id: id, account: JSONRead.string(i, "account") ?? "", type: JSONRead.string(i, "type") ?? "User")
        }
        let login = JSONRead.string(o, "login").flatMap { $0.isEmpty ? nil : $0 }
        return GitHubStatus(connected: JSONRead.bool(o, "connected"), login: login,
                            avatar: GitHubStatus.web(JSONRead.string(o, "avatar")), installations: inst,
                            manageURL: GitHubStatus.web(JSONRead.string(o, "manage_url")))
    }

    /// "Installed on: jdoe, acme-org" (nil: on no account yet).
    var installedOnLine: String? {
        let names = installations.map(\.account).filter { !$0.isEmpty }
        var seen: [String] = []
        for n in names where !seen.contains(n) { seen.append(n) }
        return seen.isEmpty ? nil : "Installed on: " + seen.joined(separator: ", ")
    }

    /// Only http(s) addresses are opened.
    static func web(_ s: String?) -> URL? {
        guard let s, let u = URL(string: s), let scheme = u.scheme?.lowercased(), scheme == "https" || scheme == "http", u.host != nil else { return nil }
        return u
    }
}

/// The connect is finished by this app with its own session. GitHub sends its window to our callback page
/// (lia.liaisone.com/agents/github/callback?code=&state=), which stores nothing; the app reads both values from that
/// address (or from liaison://github/connect?... when another browser had the page) and POSTs /agents/github/finish.
enum GitHubFinish: Equatable {
    case connected(GitHubStatus)
    /// Another GitHub account than the connected one: replaced only after the person's yes.
    case confirm(login: String, current: String?)
    case failed(String)

    /// The callback (or liaison://github/connect) address -> its state and code; nil: nothing to finish.
    static func params(_ url: URL) -> (state: String, code: String)? {
        guard let c = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        let q = Dictionary((c.queryItems ?? []).map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { a, _ in a })
        guard let state = q["state"], let code = q["code"],
              state.count == 40, state.allSatisfy({ $0.isHexDigit && !$0.isUppercase }),
              !code.isEmpty, code.count <= 100,
              code.unicodeScalars.allSatisfy({ CharacterSet.alphanumerics.contains($0) || $0 == "_" || $0 == "-" }) else { return nil }
        return (state, code)
    }

    /// liaison://github/connect?state=&code= (a browser other than the app's own window had the callback page).
    static func isLink(_ url: URL) -> Bool {
        ["liaison", "liaison-dev"].contains(url.scheme?.lowercased() ?? "") && url.host?.lowercased() == "github" && url.path == "/connect"
    }

    static func parse(_ data: Data) -> GitHubFinish {
        guard let o = JSONRead.object(data) else { return .failed("GitHub did not connect. Try again.") }
        if JSONRead.bool(o, "ok"), let s = GitHubStatus.parse(data) { return .connected(s) }
        if JSONRead.bool(o, "confirm"), let login = JSONRead.string(o, "login"), !login.isEmpty {
            return .confirm(login: login, current: JSONRead.string(o, "current"))
        }
        return .failed(JSONRead.string(o, "error") ?? "GitHub did not connect. Try again.")
    }
}

/// One repository from GET /agents/github/repos.
struct GitHubRepo: Equatable, Identifiable {
    let fullName: String
    let isPrivate: Bool
    let defaultBranch: String
    let installationId: Int
    let htmlURL: URL?
    var id: String { fullName }

    static func parseList(_ data: Data) -> [GitHubRepo]? {
        guard let o = JSONRead.object(data), JSONRead.bool(o, "ok") else { return nil }
        return JSONRead.objects(o, "repos").compactMap { r in
            guard let name = JSONRead.string(r, "full_name"), name.contains("/"), let inst = JSONRead.int(r, "installation_id") else { return nil }
            return GitHubRepo(fullName: name, isPrivate: JSONRead.bool(r, "private"), defaultBranch: JSONRead.string(r, "default_branch") ?? "",
                              installationId: inst, htmlURL: GitHubStatus.web(JSONRead.string(r, "html_url")))
        }
    }

    /// The picker's search: owner or name, any case.
    static func filter(_ list: [GitHubRepo], _ query: String) -> [GitHubRepo] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return q.isEmpty ? list : list.filter { $0.fullName.lowercased().contains(q) }
    }
}

/// A repository a workspace keeps (profile `github_repos`). The server validates it when Dev uses it.
struct WorkspaceRepo: Equatable, Identifiable {
    let fullName: String
    let installationId: Int
    var id: String { fullName.lowercased() }

    /// At most this many per workspace.
    static let limit = 20

    init(fullName: String, installationId: Int) { self.fullName = fullName; self.installationId = installationId }
    init(_ r: GitHubRepo) { self.init(fullName: r.fullName, installationId: r.installationId) }

    /// A profile's `github_repos`; missing or unreadable rows read as none.
    static func parse(_ o: JSONObject) -> [WorkspaceRepo] {
        var out: [WorkspaceRepo] = []
        for r in JSONRead.objects(o, "github_repos") {
            guard let n = JSONRead.string(r, "full_name"), n.contains("/"), let i = JSONRead.int(r, "installation_id") else { continue }
            let w = WorkspaceRepo(fullName: n, installationId: i)
            if !out.contains(where: { $0.id == w.id }) { out.append(w) }
        }
        return Array(out.prefix(limit))
    }

    /// The body of a profile update: the full list, as given.
    static func body(_ list: [WorkspaceRepo]) -> [[String: Any]] {
        list.prefix(limit).map { ["full_name": $0.fullName, "installation_id": $0.installationId] }
    }

    /// `list` with `add` appended (already there: skipped; at most `limit`).
    static func adding(_ add: [WorkspaceRepo], to list: [WorkspaceRepo]) -> [WorkspaceRepo] {
        var out = list
        for r in add where out.count < limit && !out.contains(where: { $0.id == r.id }) { out.append(r) }
        return out
    }
}

/// After Connect: the status is read every `interval` seconds until it says connected or `limit` has passed.
enum GitHubPoll {
    static let interval: TimeInterval = 3
    static let limit: TimeInterval = 180

    static func shouldContinue(started: Date, now: Date, connected: Bool) -> Bool {
        !connected && now.timeIntervalSince(started) < limit
    }
}
