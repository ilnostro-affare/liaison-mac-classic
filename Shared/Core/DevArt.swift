import Foundation

// Dev's artifacts. Each thing Dev made in a turn (a preview, a published site, a pushed branch,
// or just work on the files) has its own record on the server: its activity (Dev's messages and steps), what it changed
// and the diff. The thread keeps only the first and the last of Dev's messages of a turn; the rest live in the
// artifact's Activity. Contract: lia-agents (GET /agents/dev/art).

// MARK: - the thread rule

/// Which of Dev's messages the thread shows. Among the messages of one turn (`run`) only the first (lowest `seg`) and
/// the last (the `fin` one; else, once the turn is over, the highest `seg`) are drawn; the others are in the
/// artifact's Activity. A message without `run` (older ones, the person's) is always drawn.
enum DevThread {
    struct Entry: Equatable {
        let id: String
        /// nil: the person's message.
        let agent: String?
        let run: String?
        let seg: Int?
        let fin: Bool

        init(id: String, agent: String?, run: String?, seg: Int?, fin: Bool) {
            self.id = id; self.agent = agent; self.run = run; self.seg = seg; self.fin = fin
        }
    }

    /// The ids the thread leaves out. `liveRun`: the turn streaming now ("never in the chat, not even
    /// for a moment"): of it only the first message and a `fin` one are drawn, every intermediate one is hidden at
    /// once (it reads in the live Activity). A finished turn shows its first and its `fin` message, else its highest
    /// `seg` (a turn that ended without a `fin`).
    static func hidden(_ entries: [Entry], liveRun: String? = nil) -> Set<String> {
        // run -> the indexes of its messages, in order
        var runs: [String: [Int]] = [:]
        for (i, e) in entries.enumerated() {
            guard e.agent != nil, let r = e.run, !r.isEmpty else { continue }
            runs[r, default: []].append(i)
        }
        var out = Set<String>()
        for (r, idx) in runs {
            let live = liveRun != nil && r == liveRun
            guard live || idx.count > 2 else { continue }
            // first: the lowest seg (the earliest one on a tie)
            let first = idx.min { a, b in
                let x = entries[a].seg ?? Int.max, y = entries[b].seg ?? Int.max
                return x != y ? x < y : a < b
            }!
            let fins = idx.filter { entries[$0].fin }
            // last: a `fin` message (the highest seg of those); else (not live) the highest seg (the latest on a tie)
            let pool = fins.isEmpty ? (live ? [] : idx) : fins
            let last = pool.max { a, b in
                let x = entries[a].seg ?? -1, y = entries[b].seg ?? -1
                return x != y ? x < y : a < b
            }
            for i in idx where i != first && i != last { out.insert(entries[i].id) }
        }
        return out
    }

    /// The entries left once the hidden ones are gone (same order).
    static func visible(_ entries: [Entry], liveRun: String? = nil) -> [Entry] {
        let h = hidden(entries, liveRun: liveRun)
        return h.isEmpty ? entries : entries.filter { !h.contains($0.id) }
    }
}

// MARK: - the blocks' summary fields

/// `changes` {files, add, del} of a block.
struct DevChanges: Equatable {
    var files: Int
    var add: Int
    var del: Int

    init(files: Int, add: Int, del: Int) { self.files = files; self.add = add; self.del = del }

    init?(json o: JSONObject?) {
        guard let o else { return nil }
        self.init(files: max(0, JSONRead.int(o, "files") ?? 0), add: max(0, JSONRead.int(o, "add") ?? 0),
                  del: max(0, JSONRead.int(o, "del") ?? 0))
    }

    var isEmpty: Bool { files <= 0 }
    /// "3 files", "1 file".
    var filesText: String { files == 1 ? "1 file" : "\(files) files" }
    /// "+40".
    var addText: String { "+\(add)" }
    /// "\u{2212}2" (a real minus sign).
    var delText: String { "\u{2212}\(del)" }
    /// "3 files \u{00b7} +40 \u{2212}2" (the UI draws + green and \u{2212} red).
    var line: String { filesText + " \u{00b7} " + addText + " " + delText }
}

/// The fields every artifact block may carry: its record id, its changes, how many steps and messages it took.
struct DevArtMeta: Equatable {
    var art: String?
    var changes: DevChanges?
    var steps: Int
    var msgs: Int
    /// The project's preview (or live site) when it has one (`preview` on dev_work / dev_push), so the
    /// Canvas keeps a Preview tab for Changes and a push.
    var preview: URL?

    init(art: String? = nil, changes: DevChanges? = nil, steps: Int = 0, msgs: Int = 0, preview: URL? = nil) {
        self.art = art; self.changes = changes; self.steps = steps; self.msgs = msgs; self.preview = preview
    }

    init(_ o: JSONObject?) {
        let a = JSONRead.string(o, "art")?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        self.init(art: a.isEmpty ? nil : a, changes: DevChanges(json: o?["changes"] as? JSONObject),
                  steps: max(0, JSONRead.int(o, "steps") ?? 0), msgs: max(0, JSONRead.int(o, "msgs") ?? 0),
                  preview: DevArtMeta.page(JSONRead.string(o, "preview")))
    }

    /// An http(s) address with a host (as a Preview card's); nil otherwise.
    static func page(_ raw: String?) -> URL? {
        guard let r = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !r.isEmpty, let u = URL(string: r),
              let scheme = u.scheme?.lowercased(), scheme == "https" || scheme == "http",
              let h = u.host, !h.isEmpty else { return nil }
        return u
    }

    /// The changes when there are any files in them.
    var fileChanges: DevChanges? { changes.flatMap { $0.isEmpty ? nil : $0 } }
}

/// A `dev_work` block: Dev worked (files or just steps) but made no preview and shipped nothing.
struct DevWork: Equatable {
    let title: String
    let meta: DevArtMeta

    init?(_ b: ChatBlock) {
        guard b.kind == "dev_work" || b.tool == "dev_work" else { return nil }
        let o = b.raw
        let t = JSONRead.string(o, "title")?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        title = t.isEmpty ? "Work" : t
        meta = DevArtMeta(o)
    }

    /// The card's line before the +/\u{2212} counts: "Edited 3 files", else "12 steps".
    var summary: String {
        if let c = meta.fileChanges { return "Edited " + c.filesText }
        if meta.steps > 0 { return meta.steps == 1 ? "1 step" : "\(meta.steps) steps" }
        return "No file changes"
    }
}

/// One commit of a push.
struct DevCommit: Equatable, Identifiable {
    let sha: String
    let msg: String
    var id: String { sha + "|" + msg }
    /// The first 7 characters.
    var short: String { String(sha.prefix(7)) }
    /// The message's first line.
    var title: String { msg.split(separator: "\n", omittingEmptySubsequences: false).first.map(String.init) ?? msg }

    init(sha: String, msg: String) { self.sha = sha; self.msg = msg }

    static func list(_ o: JSONObject?, _ key: String = "commits") -> [DevCommit] {
        JSONRead.objects(o, key).compactMap { c in
            let s = JSONRead.string(c, "sha") ?? "", m = JSONRead.string(c, "msg") ?? JSONRead.string(c, "message") ?? ""
            return s.isEmpty && m.isEmpty ? nil : DevCommit(sha: s, msg: m)
        }
    }
}

/// A `dev_push` block: a branch Dev pushed to the person's repository (drawn like an attached file).
struct DevPush: Equatable {
    let repo: String
    let branch: String
    let base: String
    /// GitHub's compare page (base...branch); nil when missing or not https.
    let url: URL?
    let commit: String
    let commits: [DevCommit]
    let meta: DevArtMeta

    init?(_ b: ChatBlock) {
        guard b.kind == "dev_push" || b.tool == "dev_push" else { return nil }
        let o = b.raw
        func s(_ k: String) -> String { (JSONRead.string(o, k) ?? "").trimmingCharacters(in: .whitespacesAndNewlines) }
        repo = s("repo")
        branch = s("branch")
        guard !branch.isEmpty || !repo.isEmpty else { return nil }
        base = s("base")
        url = DevPush.web(JSONRead.string(o, "url") ?? b.url)
        commit = s("commit")
        commits = DevCommit.list(o)
        meta = DevArtMeta(o)
    }

    /// Only an https address with a host opens.
    static func web(_ raw: String?) -> URL? {
        guard let r = raw?.trimmingCharacters(in: .whitespacesAndNewlines), let u = URL(string: r),
              u.scheme?.lowercased() == "https", let h = u.host, !h.isEmpty else { return nil }
        return u
    }

    /// The card's title: the branch (the repository when there is no branch).
    var title: String { branch.isEmpty ? repo : branch }

    var commitCount: Int { commits.isEmpty ? (commit.isEmpty ? 0 : 1) : commits.count }

    /// "owner/repo \u{00b7} 2 commits" (the card adds the +/\u{2212} counts).
    var summary: String {
        var parts: [String] = []
        if !repo.isEmpty { parts.append(repo) }
        let n = commitCount
        if n > 0 { parts.append(n == 1 ? "1 commit" : "\(n) commits") }
        return parts.joined(separator: " \u{00b7} ")
    }

    /// "dev/x \u{2192} main".
    var route: String { base.isEmpty ? branch : branch + " \u{2192} " + base }
}

// MARK: - the artifact record (GET /agents/dev/art)

/// One changed file of an artifact. `add`/`del` are -1 for a binary file.
struct DevFileChange: Equatable, Identifiable {
    let path: String
    let add: Int
    let del: Int
    var id: String { path }
    var binary: Bool { add < 0 || del < 0 }

    init(path: String, add: Int, del: Int) { self.path = path; self.add = add; self.del = del }
}

/// One entry of an artifact's activity: Dev's message or one of its steps.
enum DevArtEntry: Equatable, Identifiable {
    /// `at`: when it was written (ms; 0: unknown).
    case msg(id: String, text: String, at: Double = 0)
    case step(DevStep)

    var id: String {
        switch self {
        case .msg(let id, _, _): return "m-" + id
        case .step(let s): return "s-" + s.id
        }
    }
}

struct DevArtRecord: Equatable {
    let id: String
    let kind: String
    let title: String
    let at: Double
    /// "local" | "git".
    let source: String
    let repo: String?
    let branch: String?
    let base: String?
    let url: URL?
    let activity: [DevArtEntry]
    let changes: [DevFileChange]
    let diff: String
    let cut: Bool
    let commits: [DevCommit]

    var isGit: Bool { source == "git" }

    /// `{ok:true, ...}` -> the record; `{ok:false, error}` (or anything unreadable) -> its words.
    static func parse(_ data: Data) -> Result<DevArtRecord, DevFilesError> {
        guard let o = JSONRead.object(data) else { return .failure(DevFilesError("Could not read the activity.")) }
        guard JSONRead.bool(o, "ok") else {
            return .failure(DevFilesError(JSONRead.string(o, "error") ?? "Could not read the activity."))
        }
        return .success(DevArtRecord(json: o))
    }

    init(json o: JSONObject) {
        func s(_ k: String) -> String? {
            let v = (JSONRead.string(o, k) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            return v.isEmpty ? nil : v
        }
        id = s("id") ?? ""
        kind = s("kind") ?? ""
        title = s("title") ?? ""
        at = JSONRead.double(o, "at") ?? 0
        source = s("source") ?? "local"
        repo = s("repo"); branch = s("branch"); base = s("base")
        url = DevPush.web(JSONRead.string(o, "url"))
        var entries: [DevArtEntry] = []
        for (i, e) in JSONRead.objects(o, "activity").enumerated() {
            let t = JSONRead.string(e, "t") ?? ""
            let when = JSONRead.double(e, "at") ?? 0
            if t == "msg" {
                let text = (JSONRead.string(e, "text") ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                if !text.isEmpty { entries.append(.msg(id: "a\(i)", text: text, at: when)) }
            } else if t == "step" {
                let tool = JSONRead.string(e, "tool") ?? ""
                var args: [String: String] = [:]
                for (k, v) in (e["targs"] as? JSONObject) ?? [:] { args[k] = AgentValue.text(v) }
                var step = DevStep.start(id: "a\(i)", tool: tool, args: args, at: when)
                let sum = (JSONRead.string(e, "sum") ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                let failed = JSONRead.bool(e, "failed")
                step.result = sum.isEmpty ? (failed ? "Failed" : "Done") : sum
                step.failed = failed
                entries.append(.step(step))
            }
        }
        activity = entries
        changes = JSONRead.objects(o, "changes").compactMap { c in
            guard let p = JSONRead.string(c, "path"), !p.isEmpty else { return nil }
            return DevFileChange(path: p, add: JSONRead.int(c, "add") ?? 0, del: JSONRead.int(c, "del") ?? 0)
        }
        diff = JSONRead.string(o, "diff") ?? ""
        cut = JSONRead.bool(o, "cut")
        commits = DevCommit.list(o)
    }
}

// MARK: - the Activity, in plain words

/// One line of the Activity: Dev's message, or a run of consecutive steps told in one sentence (opens to the steps).
struct DevActivityGroup: Equatable, Identifiable {
    enum Kind: Equatable { case message, steps }
    let id: String
    let kind: Kind
    /// The message, or the steps' sentence ("Edited index.html and styles.css, checked the page").
    let text: String
    let steps: [DevStep]
    /// "1 command failed" (nil: nothing failed).
    let failures: String?
    /// A message's time (ms; 0: unknown).
    var at: Double = 0
    /// A message still being written (the live turn's words after its first message, DevActivity.draft).
    var streaming = false
    /// A step of the run is still going.
    var running: Bool { steps.contains { $0.running } }
}

enum DevActivityGroups {
    /// Messages as they are; each run of steps between them as one group.
    static func make(_ entries: [DevArtEntry]) -> [DevActivityGroup] {
        var out: [DevActivityGroup] = []
        var run: [DevStep] = []
        func flush() {
            guard let f = run.first else { return }
            out.append(DevActivityGroup(id: "g-" + f.id, kind: .steps, text: sentence(run), steps: run, failures: failures(run)))
            run = []
        }
        for e in entries {
            switch e {
            case .msg(let id, let text, let at):
                flush()
                out.append(DevActivityGroup(id: "m-" + id, kind: .message, text: text, steps: [], failures: nil, at: at,
                                            streaming: id == DevActivity.draftId))
            case .step(let s):
                run.append(s)
            }
        }
        flush()
        return out
    }

    /// The live turn: Dev's steps and the messages it wrote between them (each note after the steps that came first).
    static func entries(steps: [DevStep], notes: [DevNote]) -> [DevArtEntry] {
        var out: [DevArtEntry] = []
        var n = 0
        let sorted = notes.enumerated().sorted { l, r in
            l.element.afterSteps != r.element.afterSteps ? l.element.afterSteps < r.element.afterSteps : l.offset < r.offset
        }.map(\.element)
        for (i, s) in steps.enumerated() {
            while n < sorted.count, sorted[n].afterSteps <= i { out.append(sorted[n].entry); n += 1 }
            out.append(.step(s))
        }
        while n < sorted.count { out.append(sorted[n].entry); n += 1 }
        return out
    }

    /// A short name for a path in a sentence: its last component ("src/app.js" -> "app.js").
    private static func name(_ p: String) -> String {
        let parts = p.split(separator: "/")
        return parts.last.map(String.init) ?? p
    }

    /// "a", "a and b", "a, b and c".
    static func list(_ xs: [String]) -> String {
        switch xs.count {
        case 0: return ""
        case 1: return xs[0]
        default: return xs.dropLast().joined(separator: ", ") + " and " + xs[xs.count - 1]
        }
    }

    /// The steps in one plain sentence, by kind in the order they first came: "Edited index.html and styles.css,
    /// checked the page"; "Ran 3 commands, edited 4 files".
    static func sentence(_ steps: [DevStep]) -> String {
        var order: [DevStep.Kind] = []
        var byKind: [DevStep.Kind: [DevStep]] = [:]
        for s in steps {
            if byKind[s.kind] == nil { order.append(s.kind) }
            byKind[s.kind, default: []].append(s)
        }
        func subjects(_ ss: [DevStep]) -> [String] {
            var seen = Set<String>(), out: [String] = []
            for s in ss { if let x = s.subject, !x.isEmpty, seen.insert(x).inserted { out.append(name(x)) } }
            return out
        }
        func files(_ ss: [DevStep], _ verb: String, _ fallbackOne: String) -> String {
            let names = subjects(ss)
            if names.isEmpty { return ss.count == 1 ? fallbackOne : verb + " \(ss.count) files" }
            if names.count <= 2 { return verb + " " + list(names) }
            return verb + " \(names.count) files"
        }
        var parts: [String] = []
        for k in order {
            let ss = byKind[k] ?? []
            let n = ss.count
            switch k {
            case .edit: parts.append(files(ss, "edited", "edited a file"))
            case .read: parts.append(files(ss, "read", "read a file"))
            case .list: parts.append("looked at the files")
            case .command: parts.append(n == 1 ? "ran a command" : "ran \(n) commands")
            case .preview: parts.append(n == 1 ? "started the preview" : "started the preview \(n) times")
            case .check: parts.append(n == 1 ? "checked the page" : "checked the page \(n) times")
            case .clone:
                let repos = Array(Set(ss.compactMap { $0.subject }.filter { !$0.isEmpty }))
                parts.append(repos.count == 1 ? "cloned " + repos[0] : n == 1 ? "cloned a repository" : "cloned \(n) repositories")
            case .push: parts.append(n == 1 ? "pushed the code" : "pushed the code \(n) times")
            case .github: parts.append(n == 1 ? "made a GitHub call" : "made \(n) GitHub calls")
            case .publish: parts.append(n == 1 ? "published the site" : "published the site \(n) times")
            case .request:
                // "called api.stripe.com", "called api.stripe.com 3 times", "called 2 APIs"
                var hosts: [String] = []
                for s in ss { if let h = s.subject, !h.isEmpty, !hosts.contains(h) { hosts.append(h) } }
                if hosts.count > 1 { parts.append("called \(hosts.count) APIs") }
                else if let h = hosts.first { parts.append(n == 1 ? "called " + h : "called " + h + " \(n) times") }
                else { parts.append(n == 1 ? "called an API" : "made \(n) API calls") }
            case .task: parts.append(n == 1 ? "took a task" : "took \(n) tasks")
            case .other: parts.append(n == 1 ? "took one more step" : "took \(n) more steps")
            }
        }
        let s = parts.joined(separator: ", ")
        return s.prefix(1).uppercased() + s.dropFirst()
    }

    /// "1 command failed", "2 steps failed" (nil: none failed).
    static func failures(_ steps: [DevStep]) -> String? {
        let bad = steps.filter { $0.failed }
        guard !bad.isEmpty else { return nil }
        if bad.allSatisfy({ $0.kind == .command }) { return bad.count == 1 ? "1 command failed" : "\(bad.count) commands failed" }
        if bad.allSatisfy({ $0.kind == .request }) { return bad.count == 1 ? "1 request failed" : "\(bad.count) requests failed" }
        return bad.count == 1 ? "1 step failed" : "\(bad.count) steps failed"
    }
}

/// One of Dev's messages written while the live turn works (the live Activity shows it between the steps).
struct DevNote: Equatable, Identifiable {
    let id: String
    var text: String
    let run: String?
    /// How many steps had come before it.
    var afterSteps: Int
    /// When it was written (ms; 0: unknown).
    var at: Double = 0

    var entry: DevArtEntry { .msg(id: id, text: text, at: at) }
}

// MARK: - the unified diff

enum DevDiff {
    struct Line: Equatable {
        enum Kind: Equatable { case add, del, context }
        let kind: Kind
        let text: String
        /// The line's number in the old file (nil for an added line).
        let old: Int?
        /// The line's number in the new file (nil for a deleted line).
        let new: Int?
    }

    struct Hunk: Equatable {
        let oldStart: Int
        let oldCount: Int
        let newStart: Int
        let newCount: Int
        var lines: [Line]

        /// "Lines 10\u{2013}24" (the new side; the old one for a hunk that only deletes).
        var label: String {
            let (s, n) = newCount > 0 ? (newStart, newCount) : (oldStart, oldCount)
            return n <= 1 ? "Line \(max(s, 1))" : "Lines \(s)\u{2013}\(s + n - 1)"
        }
    }

    struct File: Equatable, Identifiable {
        var path: String
        var oldPath: String?
        var binary = false
        var hunks: [Hunk] = []
        var id: String { path }
        var add: Int { hunks.reduce(0) { $0 + $1.lines.filter { $0.kind == .add }.count } }
        var del: Int { hunks.reduce(0) { $0 + $1.lines.filter { $0.kind == .del }.count } }
    }

    /// The most lines a file's diff draws.
    static let maxLines = 5000

    /// "a/x" -> "x"; "/dev/null" -> nil; quotes and a trailing tab (with a time) dropped.
    static func path(_ raw: String) -> String? {
        var s = raw
        if let t = s.firstIndex(of: "\t") { s = String(s[..<t]) }
        s = s.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("\""), s.hasSuffix("\""), s.count >= 2 { s = String(s.dropFirst().dropLast()) }
        if s == "/dev/null" || s.isEmpty { return nil }
        if s.hasPrefix("a/") || s.hasPrefix("b/") { s = String(s.dropFirst(2)) }
        return s
    }

    /// "@@ -10,7 +10,8 @@ ..." -> (10, 7, 10, 8). A missing count is 1.
    static func hunkHeader(_ line: String) -> (Int, Int, Int, Int)? {
        guard line.hasPrefix("@@") else { return nil }
        let body = line.dropFirst(2)
        guard let end = body.range(of: "@@") else { return nil }
        let parts = body[..<end.lowerBound].split(separator: " ")
        guard parts.count >= 2, parts[0].hasPrefix("-"), parts[1].hasPrefix("+") else { return nil }
        func range(_ p: Substring) -> (Int, Int)? {
            let x = p.dropFirst().split(separator: ",", omittingEmptySubsequences: false)
            guard let s = Int(x[0]) else { return nil }
            if x.count > 1 { guard let n = Int(x[1]) else { return nil }; return (s, n) }
            return (s, 1)
        }
        guard let o = range(parts[0]), let n = range(parts[1]) else { return nil }
        return (o.0, o.1, n.0, n.1)
    }

    /// Splits a `git diff` into files, each with its hunks and numbered lines. "\\ No newline" lines are left out;
    /// a binary file is marked and has no hunks.
    static func parse(_ text: String) -> [File] {
        var files: [File] = []
        var cur: File?
        var hunk: Hunk?
        var oldLeft = 0, newLeft = 0, oldNo = 0, newNo = 0

        func closeHunk() {
            if let h = hunk { cur?.hunks.append(h) }
            hunk = nil
            oldLeft = 0; newLeft = 0
        }
        func closeFile() {
            closeHunk()
            if let f = cur { files.append(f) }
            cur = nil
        }

        // "\r\n" is one Character in Swift: Windows line ends become "\n" before the split.
        let lines = text.replacingOccurrences(of: "\r\n", with: "\n").split(separator: "\n", omittingEmptySubsequences: false)
        var i = 0
        while i < lines.count {
            let l = String(lines[i])
            i += 1
            // inside a hunk: its lines, counted, so "--- x" deleted text is not mistaken for a header
            if hunk != nil, oldLeft > 0 || newLeft > 0 {
                if l.hasPrefix("\\") { continue }
                let c = l.first
                let body = l.isEmpty ? "" : String(l.dropFirst())
                if c == "+" {
                    hunk?.lines.append(Line(kind: .add, text: body, old: nil, new: newNo)); newNo += 1; newLeft -= 1
                    continue
                }
                if c == "-" {
                    hunk?.lines.append(Line(kind: .del, text: body, old: oldNo, new: nil)); oldNo += 1; oldLeft -= 1
                    continue
                }
                if c == " " || l.isEmpty {
                    hunk?.lines.append(Line(kind: .context, text: body, old: oldNo, new: newNo))
                    oldNo += 1; newNo += 1; oldLeft -= 1; newLeft -= 1
                    continue
                }
                // anything else ends the hunk early (a malformed count); read it as a header below
                closeHunk()
            }
            if l.hasPrefix("\\") { continue }
            if l.hasPrefix("diff --git ") {
                closeFile()
                let rest = String(l.dropFirst("diff --git ".count))
                var newP = rest
                var oldP: String? = nil
                if let r = rest.range(of: " b/", options: .backwards) {
                    newP = String(rest[r.upperBound...])
                    let left = String(rest[..<r.lowerBound])
                    oldP = left.hasPrefix("a/") ? String(left.dropFirst(2)) : left
                } else if let r = rest.range(of: " ", options: .backwards) {
                    newP = path(String(rest[r.upperBound...])) ?? rest
                }
                newP = newP.replacingOccurrences(of: "\"", with: "")
                cur = File(path: newP, oldPath: oldP == newP ? nil : oldP)
                continue
            }
            if l.hasPrefix("--- ") {
                // a plain unified diff (no "diff --git" line): each "---" after hunks starts a new file
                if cur == nil || !(cur?.hunks.isEmpty ?? true) || hunk != nil {
                    closeFile()
                    cur = File(path: "")
                }
                closeHunk()
                let old = path(String(l.dropFirst(4)))
                if cur?.path.isEmpty ?? true { cur?.path = old ?? "" }
                if let o = old, o != cur?.path { cur?.oldPath = o }
                continue
            }
            if l.hasPrefix("+++ ") {
                if cur == nil { cur = File(path: "") }
                if let n = path(String(l.dropFirst(4))) {
                    if let p = cur?.path, !p.isEmpty, p != n, cur?.oldPath == nil { cur?.oldPath = p }
                    cur?.path = n
                    if cur?.oldPath == n { cur?.oldPath = nil }
                }
                continue
            }
            if l.hasPrefix("Binary files ") || l.hasPrefix("GIT binary patch") {
                if cur == nil {
                    // "Binary files a/x and b/x differ" with no header
                    var p = ""
                    if let r = l.range(of: " and ") {
                        p = path(String(l[r.upperBound...]).replacingOccurrences(of: " differ", with: "")) ?? ""
                    }
                    cur = File(path: p)
                }
                cur?.binary = true
                continue
            }
            if let h = hunkHeader(l) {
                if cur == nil { cur = File(path: "") }
                closeHunk()
                hunk = Hunk(oldStart: h.0, oldCount: h.1, newStart: h.2, newCount: h.3, lines: [])
                oldNo = h.0; newNo = h.2
                oldLeft = h.1; newLeft = h.3
                continue
            }
            // index, mode, rename and similarity lines: headers, nothing to draw
        }
        closeFile()
        return files.filter { !$0.path.isEmpty }
    }

    /// The parsed file for a changed path (a rename matches its old path too).
    static func file(_ path: String, in files: [File]) -> File? {
        files.first { $0.path == path } ?? files.first { $0.oldPath == path }
    }
}
