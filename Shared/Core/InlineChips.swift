import Foundation

/// Inline chips inside a line of Lia's answer, after mdInline + entifyHtml in ai.js:
/// A markdown link becomes a source chip (letter tile + title); "([x](url))" swallows its brackets,
/// a lone bracket stays; the utm the search tool appends is dropped
/// «name» (id N) with N in ents becomes that entity's chip (Lia named the object herself)
/// Any other «text» is a quote: a namesake chip when names in ents match it (it lists them, never picks one),
/// else a plain grey chip that opens nothing
/// "id 1234567890123" or a bare 13 to 18 digit id known in ents becomes that entity's chip
/// A citation marker (CiteMark) becomes the source chip of that group (ai.js citeSwap)
/// A bare url, and a bare domain, becomes a site chip (favicon, the address; a click opens it)
/// A branch with a known prefix (dev/, feat/, fix/, claude/, release/ ...) or named by the dialogue's blocks: a chip
/// A known repository ("owner/name", KnownRepos) and a commit sha in a commit's context (KnownRepos.commitRepo): a chip
/// A path of Dev's project (FileChips): a code span that is a whole path, or a bare "dir/file.ext"
enum InlineSegment: Equatable {
    case text(String)
    case link(label: String, url: String, host: String)
    /// A url_citation group by index into CiteMark's groups (ai.js citeChipHTML).
    case cite(Int)
    /// A url written bare in the text: tap copies it.
    case url(String)
    case entity(name: String, id: String?, kind: String?)
    /// A quote whose words name `count` objects in the account (ai.js `.lia-entchip--q.lia-entchip--many`).
    case namesake(name: String, count: Int, kind: String?)
    case quote(String)
    /// A GitHub pull request, branch or commit (a github.com link, or a Dev branch named in the text).
    case github(GitHubRef)
    /// A file or folder of Dev's project (a click opens it in the Canvas: Changes or Files).
    case file(FileRef)
    /// An agent named in the text ("@Dev", or Lia / Dev / Met / Crea as a word): the landing's pill,
    /// the name on the agent's own tint (no dot).
    case agent(id: String, name: String, color: UInt32)
}

/// Agents named in a text, as pills (InlineChips) and in the composer (the same ranges).
enum AgentChips {
    struct Hit: Equatable {
        let range: NSRange
        let id: String
        let name: String
        let color: UInt32
    }

    /// The team's agents a bare name (no "@") makes a pill for: their names are not ordinary words.
    static let bareIDs: Set<String> = ["lia", "dev", "met", "crea"]

    private static let rx = try! NSRegularExpression(pattern: #"(?<![\w@./\-])(@?)([A-Za-z]{2,12})(?![\w@/\-]|\.\w)"#)

    /// Every agent named in `text`: "@Name" for any known agent (any case), a bare name only for the team's four and
    /// written with its capital ("Dev", never "dev" or "DEV").
    static func hits(_ text: String, roster: [AgentInfo] = AgentInfo.fallback + AgentInfo.known) -> [Hit] {
        let ns = text as NSString
        var byName: [String: AgentInfo] = [:]
        for a in roster where !a.soon { byName[a.name.lowercased()] = a }
        var out: [Hit] = []
        for m in rx.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            let at = m.range(at: 1).length > 0
            let word = ns.substring(with: m.range(at: 2))
            guard let a = byName[word.lowercased()] else { continue }
            if !at && (word != a.name || !bareIDs.contains(a.id)) { continue }
            out.append(Hit(range: m.range, id: a.id, name: a.name, color: a.colorHex))
        }
        return out
    }

    /// Only the "@Name" mentions (the fields an agent is called from: the message box, Notes, the
    /// address bar, Home's prompt); a bare "Dev" typed there stays plain text.
    static func mentions(_ text: String, roster: [AgentInfo] = AgentInfo.fallback + AgentInfo.known) -> [Hit] {
        let ns = text as NSString
        return hits(text, roster: roster).filter { $0.range.length > 0 && ns.character(at: $0.range.location) == 0x40 }
    }
}

enum InlineChips {
    private static let pattern = try! NSRegularExpression(pattern:
        #"(\(\s*)?\[([^\]]{1,120})\]\((https?://[^)\s]{1,400})\)(\s*\))?"#     // 1..4 link
        + #"|«([^«»]{2,60})»(?:\s*\(?\s*id[\s:]*([0-9]{13,18})\s*\)?)?"#         // 5,6 guillemets
        + #"|\(?\bid[\s:]*([0-9]{13,18})\)?"#                                   // 7 "id N"
        + #"|\b([0-9]{13,18})\b"#                                               // 8 bare id
        + #"|\x{E0C1}([0-9]{1,4})\x{E0C1}"#                                         // 9 citation marker
        + #"|(https?://[^\s<>"']+)"#                                            // 10 bare url
        // 11 a bare domain: "bakery.liaisone.app", "github.com/o/r" - lowercase, a known TLD (DomainChip)
        + #"|(?<![\w@./\-:])((?:[a-z0-9](?:[a-z0-9\-]{0,61}[a-z0-9])?\.)+[a-z]{2,6}(?::[0-9]{2,5})?(?:/[^\s<>"'`)\]]*)?)(?![\w\-@])"#
        // 12 a branch (dev/ only; any known prefix, or a branch the dialogue's blocks named)
        + #"|(?<![\w/.\-@:])([A-Za-z0-9][A-Za-z0-9_\-]{0,30}/[A-Za-z0-9](?:[A-Za-z0-9._/\-]{0,95}[A-Za-z0-9_])?)"#
        // 13 a commit sha: 7 to 40 hex; a chip only in a commit's context (KnownRepos.commitRepo)
        + #"|(?<![\w/.\-@:#])([0-9a-f]{7,40})(?![\w\-/@]|\.\w)"#,
        options: [.caseInsensitive])

    static func segments(_ text: String, ents: [String: ChatEntity]) -> [InlineSegment] {
        segments(text, ents: ents, repos: KnownRepos.shared.snapshot())
    }

    /// `repos`: the repositories and commits known when the text is built (tests pass their own).
    static func segments(_ text: String, ents: [String: ChatEntity], repos: KnownRepos.Snapshot) -> [InlineSegment] {
        let ns = text as NSString
        var out: [InlineSegment] = []
        var cursor = 0
        var byName: [String: [(String, ChatEntity)]] = [:]
        for (id, e) in ents { byName[e.name.lowercased().trimmingCharacters(in: .whitespaces), default: []].append((id, e)) }

        func group(_ m: NSTextCheckingResult, _ i: Int) -> String? {
            let r = m.range(at: i)
            return r.location == NSNotFound ? nil : ns.substring(with: r)
        }
        func emitText(_ s: String) {
            guard !s.isEmpty else { return }
            if case .text(let prev)? = out.last { out[out.count - 1] = .text(prev + s) } else { out.append(.text(s)) }
        }

        // each chip's place in the text; `linkish`: an address written out (a file path inside it is part of it)
        var reps: [(range: NSRange, segs: [InlineSegment], linkish: Bool)] = []
        for m in pattern.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            var replacement: [InlineSegment]? = nil
            let linkish = group(m, 3) != nil || group(m, 10) != nil
            if let label = group(m, 2), let rawURL = group(m, 3) {
                let open = group(m, 1), close = group(m, 4)
                let wrapped = open != nil && close != nil
                let url = rawURL.replacingOccurrences(of: #"[?&]utm_source=openai\b"#, with: "", options: .regularExpression)
                var host = URL(string: url)?.host ?? ""
                if host.hasPrefix("www.") { host = String(host.dropFirst(4)) }
                replacement = []
                if !wrapped, let open { replacement!.append(.text(open)) }
                if let ref = GitHubRef.parse(url) ?? GitHubRef.parseRepo(url) {
                    replacement!.append(.github(ref))
                } else {
                    replacement!.append(.link(label: label, url: url, host: host.isEmpty ? label : host))
                }
                if !wrapped, let close { replacement!.append(.text(close)) }
            } else if let name = group(m, 5) {
                let hit = (byName[name.lowercased().trimmingCharacters(in: .whitespaces)] ?? []).sorted { $0.0 < $1.0 }
                if let qid = group(m, 6), let e = ents[qid] {
                    replacement = [.entity(name: name, id: qid, kind: e.kind)]
                } else if !hit.isEmpty {
                    replacement = [.namesake(name: name, count: hit.count, kind: hit[0].1.kind)]
                } else {
                    replacement = [.quote(name)]
                }
            } else if let id = group(m, 7) {
                if let e = ents[id] { replacement = [.entity(name: e.name, id: id, kind: e.kind)] }
            } else if let id = group(m, 8) {
                if let e = ents[id] { replacement = [.entity(name: e.name, id: id, kind: e.kind)] }
            } else if let gi = group(m, 9), let n = Int(gi) {
                replacement = [.cite(n)]
            } else if let u = group(m, 10) {
                // Internal asset endpoints are noise: dropped (the creative is shown in its block instead).
                if u.range(of: #"api\.liaisone\.(io|com)/meta/"#, options: [.regularExpression, .caseInsensitive]) != nil {
                    replacement = []
                } else if let ref = GitHubRef.parse(Self.trimURL(u)) ?? GitHubRef.parseRepo(Self.trimURL(u)) {
                    // a sentence's full stop or comma after the address is not part of it
                    let tail = String(u.dropFirst(Self.trimURL(u).count))
                    replacement = [.github(ref)] + (tail.isEmpty ? [] : [.text(tail)])
                } else {
                    replacement = [.url(u)]
                }
            } else if let d = group(m, 11) {
                let clean = Self.trimURL(d)
                if DomainChip.isDomain(clean) {
                    let tail = String(d.dropFirst(clean.count))
                    let url = "https://" + clean
                    if let ref = GitHubRef.parse(url) ?? GitHubRef.parseRepo(url) {
                        replacement = [.github(ref)] + (tail.isEmpty ? [] : [.text(tail)])
                    } else {
                        replacement = [.url(url)] + (tail.isEmpty ? [] : [.text(tail)])
                    }
                }
            } else if let b = group(m, 12) {
                // a repository the workspace or the dialogue named wins over a branch of the same shape
                if let full = repos.repo(named: b) {
                    replacement = [.github(.repo(full))]
                } else if GitHubRef.isBranchName(b) {
                    replacement = [.github(.branch(b))]
                }
            } else if let sha = group(m, 13), let repo = repos.commitRepo(sha: sha, in: ns, at: m.range) {
                replacement = [.github(.commit(sha, repo: repo))]
            }
            guard let rep = replacement else { continue }
            reps.append((m.range, rep, linkish))
        }
        // Dev's paths. A path inside an address stays the address; any other chip of the same words (a
        // bare domain, an unknown branch shape) gives way to the path. A branch or a known repository never is a path.
        let files = FileChips.hits(text, repos: repos).filter { h in
            !reps.contains { $0.linkish && NSIntersectionRange($0.range, h.range).length > 0 }
        }
        if !files.isEmpty {
            reps.removeAll { r in files.contains { NSIntersectionRange($0.range, r.range).length > 0 } }
            reps += files.map { ($0.range, [InlineSegment.file($0.ref)], false) }
            reps.sort { $0.range.location < $1.range.location }
        }
        // Agents named in the text are pills; inside any other chip (an address, a path) they stay its words.
        let agents = AgentChips.hits(text).filter { h in !reps.contains { NSIntersectionRange($0.range, h.range).length > 0 } }
        if !agents.isEmpty {
            reps += agents.map { ($0.range, [InlineSegment.agent(id: $0.id, name: $0.name, color: $0.color)], false) }
            reps.sort { $0.range.location < $1.range.location }
        }
        for r in reps where r.range.location >= cursor {
            emitText(ns.substring(with: NSRange(location: cursor, length: r.range.location - cursor)))
            for seg in r.segs { if case .text(let t) = seg { emitText(t) } else { out.append(seg) } }
            cursor = r.range.location + r.range.length
        }
        emitText(ns.substring(from: cursor))
        return stripBoldAroundChips(out)
    }

    /// A bare address without the punctuation that ends a sentence after it ("see https://x/pull/3.").
    static func trimURL(_ u: String) -> String {
        var s = u
        while let l = s.last, ".,;:!?)*_`".contains(l) { s.removeLast() }
        return s
    }

    /// The model often writes **«Name»**. The chip already carries the weight, and the two orphan
    /// asterisk pairs would otherwise print literally on each side of it.
    static func stripBoldAroundChips(_ segs: [InlineSegment]) -> [InlineSegment] {
        var out = segs
        var i = 0
        while i < out.count {
            let isChip: Bool
            switch out[i] { case .text: isChip = false; default: isChip = true }
            if isChip, i > 0, i + 1 < out.count,
               case .text(let before) = out[i - 1], case .text(let after) = out[i + 1],
               before.hasSuffix("**"), after.hasPrefix("**") {
                out[i - 1] = .text(String(before.dropLast(2)))
                out[i + 1] = .text(String(after.dropFirst(2)))
            }
            i += 1
        }
        return out.filter { if case .text(let t) = $0 { return !t.isEmpty } else { return true } }
    }
}

/// ("commits can be picked as entities, like repositories"): the GitHub repositories and commits the
/// app knows - the workspace's own repositories (Workspace Settings > Repositories), the repositories and pushed commits
/// Dev's blocks named. A repository written "owner/name" is a chip when it is one of these; a sha is a chip only when a
/// commit it names is known, or when it stands in a commit's context (a code span, or "commit" / "sha" close by) and its
/// repository is known (named in the same text, else the only one of the workspace, else the only one known).
final class KnownRepos: @unchecked Sendable {
    static let shared = KnownRepos()
    private let lock = NSLock()
    private var repos: [String] = []
    private var commits: [String: String] = [:]
    private var preferred: [String] = []

    struct Snapshot: Equatable {
        /// Full names, as first written.
        var repos: [String] = []
        /// Full sha (lowercased) -> its repository.
        var commits: [String: String] = [:]
        /// The repositories of the workspace in front.
        var preferred: [String] = []

        init(repos: [String] = [], commits: [String: String] = [:], preferred: [String] = []) {
            self.repos = repos; self.commits = commits; self.preferred = preferred
        }

        /// "Owner/Name" written in the text -> the known repository's full name (case aside).
        func repo(named s: String) -> String? {
            guard GitHubRef.isRepoName(s) else { return nil }
            let k = s.lowercased()
            return (preferred + repos).first { $0.lowercased() == k }
        }

        /// The repository a sha at `range` of `text` is a commit of, nil when it is not one (see the type's note).
        func commitRepo(sha raw: String, in text: NSString, at range: NSRange) -> String? {
            let sha = raw.lowercased()
            guard raw == sha, sha.count >= 7, sha.count <= 40,
                  sha.contains(where: { $0.isLetter }), sha.contains(where: { $0.isNumber }) else { return nil }
            if let hit = commits.first(where: { $0.key.hasPrefix(sha) || sha.hasPrefix($0.key) }) { return hit.value }
            guard Self.commitContext(text, range) else { return nil }
            // a repository named in the same text
            let lower = (text as String).lowercased()
            if let named = (preferred + repos).first(where: { lower.contains($0.lowercased()) }) { return named }
            if preferred.count == 1 { return preferred[0] }
            if preferred.isEmpty, repos.count == 1 { return repos[0] }
            return nil
        }

        /// A code span around the sha, or the word "commit" (commits, committed) / "sha" within a few words of it.
        static func commitContext(_ text: NSString, _ r: NSRange) -> Bool {
            let end = r.location + r.length
            if r.location > 0, end < text.length,
               text.substring(with: NSRange(location: r.location - 1, length: 1)) == "`",
               text.substring(with: NSRange(location: end, length: 1)) == "`" { return true }
            let from = max(0, r.location - 48), to = min(text.length, end + 24)
            let around = (text.substring(with: NSRange(location: from, length: r.location - from)) + " "
                          + text.substring(with: NSRange(location: end, length: to - end))).lowercased()
            if around.contains("commit") { return true }
            return around.range(of: #"\bsha\b"#, options: .regularExpression) != nil
        }
    }

    func snapshot() -> Snapshot {
        lock.lock(); defer { lock.unlock() }
        return Snapshot(repos: repos, commits: commits, preferred: preferred)
    }

    func add(_ fullName: String) {
        let n = fullName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard GitHubRef.isRepoName(n) else { return }
        lock.lock(); defer { lock.unlock() }
        if !repos.contains(where: { $0.lowercased() == n.lowercased() }) { repos.append(n) }
    }

    func addCommit(_ sha: String, repo: String) {
        let s = sha.lowercased()
        guard s.count >= 7, s.count <= 40, s.allSatisfy({ $0.isHexDigit }), GitHubRef.isRepoName(repo) else { return }
        add(repo)
        lock.lock(); defer { lock.unlock() }
        if commits.count < 2000 { commits[s] = repo }
    }

    /// The workspace in front's repositories (replaces the last set).
    func setPreferred(_ list: [String]) {
        let clean = list.filter { GitHubRef.isRepoName($0) }
        lock.lock(); defer { lock.unlock() }
        preferred = clean
    }
}

/// The text of a user message as the person wrote it: our own machine captions removed
/// (upSplitMarker in ai.js).
enum UserText {
    static let attachmentOnly = "[attachment_only]"

    static func display(_ content: String) -> String {
        content
            .replacingOccurrences(of: #"\n?\[attached_creative (r2_key|image_hash|video_id)=[^\]\s]+\]"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"^\[quick_action\]\s*"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"^\[attachment_only\]\s*"#, with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// What goes to the runner: a message with only files carries our caption, never an empty string.
    /// The keys of the creatives the person attached ([attached_creative r2_key= / image_hash= / video_id=…]).
    static func creativeKeys(_ content: String) -> [String] {
        guard let re = try? NSRegularExpression(pattern: #"\[attached_creative (?:r2_key|image_hash|video_id)=([^\]\s]+)\]"#) else { return [] }   // escape-ok
        let ns = content as NSString
        return re.matches(in: content, range: NSRange(location: 0, length: ns.length)).map { ns.substring(with: $0.range(at: 1)) }
    }

    static func outgoing(_ typed: String, hasAttachments: Bool) -> String {
        let t = typed.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty && hasAttachments ? attachmentOnly : t
    }
}

/// The Memberstack member token is a JWT whose payload names the member (`id: mem_...`).
/// Reading it saves a round trip; nothing is trusted from it, the server verifies the token itself.
enum MemberToken {
    static func memberId(from jwt: String) -> String? {
        let parts = jwt.split(separator: ".")
        guard parts.count == 3 else { return nil }
        var b64 = String(parts[1]).replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while b64.count % 4 != 0 { b64 += "=" }
        guard let data = Data(base64Encoded: b64), let o = JSONRead.object(data) else { return nil }
        let id = JSONRead.string(o, "id") ?? JSONRead.string(o, "sub") ?? JSONRead.string(o, "memberId")
        guard let id, id.range(of: #"^mem_[A-Za-z0-9]{8,40}$"#, options: .regularExpression) != nil else { return nil }
        return id
    }
}
