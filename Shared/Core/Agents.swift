import Foundation

// The agent team of the new workspace. Liaison is a browser with a team of agents: tab
// groups per company profile on top, the agents in a dock at the bottom. These are the pure pieces (Foundation
// only, tested on Linux): the roster, the company profiles, the conversations, the team stream's own lines, and
// the Ads Manager account an address points at. The server is lia-agents (lia.liaisone.com, /agents/*).

/// The figure an agent is drawn as. Each agent has its own, and its own colour.
enum AgentShape: String, CaseIterable {
    case ring, square, half, triangle, hexagon, diamond, flower, code
}

struct AgentInfo: Identifiable, Equatable {
    let id: String
    var name: String
    var role: String
    var shape: AgentShape
    var colorHex: UInt32
    /// Writes to Meta (Met alone). Every agent drives the browser.
    var write: Bool
    var lead: Bool
    var onCall: Bool
    var writesFirst: Bool
    /// Not connected yet (Google Ads).
    var soon: Bool
    /// The one line under the name in the agent's profile (roster `bio`; empty from an old server).
    var bio: String = ""

    init(id: String, name: String, role: String, shape: AgentShape, colorHex: UInt32, write: Bool = false,
         lead: Bool = false, onCall: Bool = false, writesFirst: Bool = false, soon: Bool = false) {
        self.id = id; self.name = name; self.role = role; self.shape = shape; self.colorHex = colorHex
        self.write = write; self.lead = lead; self.onCall = onCall; self.writesFirst = writesFirst; self.soon = soon
    }

    init?(json o: JSONObject) {
        guard let id = JSONRead.string(o, "id"), !id.isEmpty, let name = JSONRead.string(o, "name") else { return nil }
        self.init(id: id, name: name, role: JSONRead.string(o, "role") ?? "",
                  shape: AgentShape(rawValue: JSONRead.string(o, "shape") ?? "") ?? .ring,
                  colorHex: AgentInfo.hex(JSONRead.string(o, "color")) ?? 0x0E1014,
                  write: JSONRead.bool(o, "write"), lead: JSONRead.bool(o, "lead"), onCall: JSONRead.bool(o, "on_call"),
                  writesFirst: JSONRead.bool(o, "writes_first"), soon: JSONRead.bool(o, "soon"))
        bio = JSONRead.string(o, "bio") ?? ""
    }

    /// "#3B5BFD" -> 0x3B5BFD.
    static func hex(_ s: String?) -> UInt32? {
        guard var t = s?.trimmingCharacters(in: .whitespaces), !t.isEmpty else { return nil }
        if t.hasPrefix("#") { t.removeFirst() }
        guard t.count == 6, let v = UInt32(t, radix: 16) else { return nil }
        return v
    }

    /// The first letter for the figure.
    var initial: String { String(name.prefix(1)).uppercased() }

    /// The role as the interface shows it. Lia (the lead) is "Assistant" whatever the roster says
    /// ("Lead"); every other agent its roster role ("Marketer", "Developer", "Creative").
    var shownRole: String { lead || id == "lia" ? "Assistant" : role }

    /// The team as the server ships it, so the dock draws before /agents/roster answers (and offline). Dev is not
    /// here on purpose: the server lists it only for flagged members, so it appears only when the roster says so.
    /// Lee is retired: Met does its work, Rep covers the metrics, Dev took its look.
    /// Seara (research), Rep (reports) and Giggs (Google) are retired too - Lia, the main one,
    /// does their work. The team: Lia, Dev, Met, Crea.
    static let fallback: [AgentInfo] = [
        AgentInfo(id: "lia", name: "Lia", role: "Lead", shape: .ring, colorHex: 0x1F2430, lead: true),
        AgentInfo(id: "met", name: "Met", role: "Marketer", shape: .square, colorHex: 0x0866FF, write: true),
        AgentInfo(id: "crea", name: "Crea", role: "Creative", shape: .flower, colorHex: 0xD6409F),
    ]

    /// Agents the fallback leaves out but the app may still meet by id (a usage row, a download, a mark): named and
    /// drawn as the server ships them, so they never show as an empty slot.
    static let known: [AgentInfo] = [
        AgentInfo(id: "dev", name: "Dev", role: "Developer", shape: .triangle, colorHex: 0xF0533E),
        // Retired, met only in old dialogues and marks
        AgentInfo(id: "rep", name: "Rep", role: "Reports", shape: .hexagon, colorHex: 0x7B4DDB),
        AgentInfo(id: "seara", name: "Seara", role: "Research", shape: .diamond, colorHex: 0xE8A317),
        AgentInfo(id: "giggs", name: "Giggs", role: "Google Ads", shape: .half, colorHex: 0x1AA260, soon: true),
    ]

    /// An agent by id: the roster first, then the fallback, then `known`.
    static func lookup(_ id: String, in roster: [AgentInfo]) -> AgentInfo? {
        roster.first { $0.id == id } ?? fallback.first { $0.id == id } ?? known.first { $0.id == id }
    }

    /// GET /agents/roster -> the team; an unreadable answer keeps the fallback.
    static func parseRoster(_ data: Data) -> [AgentInfo]? {
        guard let o = JSONRead.object(data), JSONRead.bool(o, "ok") else { return nil }
        let list = JSONRead.objects(o, "agents").compactMap(AgentInfo.init(json:))
        return list.isEmpty ? nil : list
    }
}

/// One ad client: its own tab group, browser profile (cookies), agents and conversations.
struct CompanyProfile: Identifiable, Equatable {
    let id: String
    var name: String
    var colorHex: UInt32
    var metaAccount: String?
    var metaAccountName: String?
    var googleCustomer: String?
    /// Every ad account added to this workspace (the first is `metaAccount`, kept for older code). A workspace
    /// is the base and ad accounts are additions; the person picks which.
    var metaAccounts: [(id: String, name: String)] = []
    /// The GitHub repositories Dev works in for this workspace (`github_repos`, at most 20; missing: none).
    var githubRepos: [WorkspaceRepo] = []

    static func == (a: CompanyProfile, b: CompanyProfile) -> Bool {
        a.id == b.id && a.name == b.name && a.colorHex == b.colorHex && a.metaAccount == b.metaAccount
            && a.metaAccountName == b.metaAccountName && a.googleCustomer == b.googleCustomer
            && a.metaAccounts.map(\.id) == b.metaAccounts.map(\.id) && a.metaAccounts.map(\.name) == b.metaAccounts.map(\.name)
            && a.githubRepos == b.githubRepos
    }

    /// The body of a create/update for these accounts (server keeps meta_account = the first).
    static func accountsBody(_ list: [(id: String, name: String)]) -> [[String: String]] { list.map { ["id": $0.id, "name": $0.name] } }

    init(id: String, name: String, colorHex: UInt32 = 0xE8572A, metaAccount: String? = nil,
         metaAccountName: String? = nil, googleCustomer: String? = nil) {
        self.id = id; self.name = name; self.colorHex = colorHex; self.metaAccount = metaAccount
        self.metaAccountName = metaAccountName; self.googleCustomer = googleCustomer
    }

    init?(json o: JSONObject) {
        guard let id = JSONRead.string(o, "id"), !id.isEmpty else { return nil }
        self.init(id: id, name: JSONRead.string(o, "name") ?? "Untitled",
                  colorHex: AgentInfo.hex(JSONRead.string(o, "color")) ?? 0xE8572A,
                  metaAccount: CompanyProfile.digits(JSONRead.string(o, "meta_account")),
                  metaAccountName: JSONRead.string(o, "meta_account_name"),
                  googleCustomer: CompanyProfile.digits(JSONRead.string(o, "google_customer")))
        var list: [(id: String, name: String)] = JSONRead.objects(o, "meta_accounts").compactMap { a in
            guard let id = CompanyProfile.digits(JSONRead.string(a, "id")) else { return nil }
            return (id, JSONRead.string(a, "name") ?? "")
        }
        if list.isEmpty, let m = metaAccount { list = [(m, metaAccountName ?? "")] }   // an older server: one account
        metaAccounts = list
        githubRepos = WorkspaceRepo.parse(o)
    }

    static func digits(_ s: String?) -> String? {
        let d = (s ?? "").filter(\.isNumber)
        return d.isEmpty ? nil : d
    }

    /// The colours a new profile can take, in order.
    static let palette: [UInt32] = [0xE8572A, 0x13A3B0, 0x8F74F0, 0x2F9E5B, 0xD9A31A, 0xD0457A, 0x3B5BFD]

    /// GET /agents/profiles
    static func parseList(_ data: Data) -> [CompanyProfile]? {
        guard let o = JSONRead.object(data), JSONRead.bool(o, "ok") else { return nil }
        return JSONRead.objects(o, "profiles").compactMap(CompanyProfile.init(json:))
    }

    /// The browser-profile key: a Liaison account and one of its company profiles never share cookies with another.
    static func browserKey(account: String?, profile: String) -> String { (account ?? "_none") + "|p:" + profile }

    /// Ads Manager on this profile's account (nil: no account linked yet).
    var adsManagerURL: URL? { metaAccount.flatMap { AdsManagerLink(account: $0).url } }
}

/// A line of /agents/turn that belongs to the team run itself. Every other line is Lia 2.0's own event (ChatEvent /
/// AgentEvent parse it) with an "agent" field naming who said it.
enum TeamLine: Equatable {
    case agentStart(agent: String, from: String?)
    /// The run stopped for the person (an approval card, a browser task).
    case wait(agent: String)
    /// Hand-overs left when the run hit its turn cap.
    case cap([String])
    case done
    case error(agent: String?, message: String)

    static func parse(line: String) -> TeamLine? {
        guard let o = TeamLine.object(line), let type = JSONRead.string(o, "type") else { return nil }
        switch type {
        case "agent_start": return JSONRead.string(o, "agent").map { .agentStart(agent: $0, from: JSONRead.string(o, "from")) }
        case "team_wait": return .wait(agent: JSONRead.string(o, "agent") ?? "")
        case "team_cap": return .cap(JSONRead.strings(o, "left"))
        case "team_done": return .done
        case "error": return .error(agent: JSONRead.string(o, "agent"), message: JSONRead.string(o, "message") ?? "Something went wrong.")
        default: return nil
        }
    }

    /// Which agent an ordinary stream line belongs to.
    static func agent(line: String) -> String? { JSONRead.string(TeamLine.object(line), "agent") }

    static func object(_ line: String) -> JSONObject? {
        guard line.hasPrefix("data:") else { return nil }
        let body = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
        return JSONRead.object(Data(body.utf8))
    }
}

/// The agent a stored message came from (chat docs of agent threads carry "agent" on assistant messages).
enum AgentOf {
    static func message(_ m: ChatMessage) -> String? {
        guard m.role == .assistant, let raw = m.rawJSON, let o = JSONRead.object(Data(raw.utf8)) else { return nil }
        return JSONRead.string(o, "agent")
    }
    /// Machine replies (an approval answer, a browser report, a hand-over) are not shown as the person's words.
    static func isMachine(_ m: ChatMessage) -> Bool {
        m.role == .user && m.content.range(of: #"^\[(gate_reply|ask_reply|plan_reply|browser_result|screen_result|handoff|task_run)\]"#, options: .regularExpression) != nil
    }
}

/// The Ads Manager account an address points at: `act=123` or `/act_123`. Changing the account in Ads Manager
/// switches the browser profile to the company that owns it, so two clients never meet in one browser.
enum AdsManagerAccount {
    static func of(_ url: URL?) -> String? {
        guard let url, let host = url.host?.lowercased(), host.hasSuffix("facebook.com"),
              host.hasPrefix("adsmanager") || host.hasPrefix("business") || url.path.contains("/adsmanager") else { return nil }
        if let q = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems,
           let v = q.first(where: { $0.name == "act" || $0.name == "global_scope_id" })?.value {
            let d = v.filter(\.isNumber)
            if !d.isEmpty { return d }
        }
        if let r = url.path.range(of: #"act_([0-9]+)"#, options: .regularExpression) {
            return String(url.path[r].dropFirst(4))
        }
        return nil
    }

    /// The profile that owns this account, when it is not the current one.
    static func owner(of url: URL?, current: String?, profiles: [CompanyProfile]) -> CompanyProfile? {
        guard let act = of(url) else { return nil }
        guard let p = profiles.first(where: { $0.metaAccount == act }), p.id != current else { return nil }
        return p
    }
}

/// "@Name" at the cursor, for the composer's suggestions.
enum AgentMention {
    /// ("an agent cannot be picked in the middle of the text", "deleting back to the @ shows nothing"):
    /// the "@..." right before the caret, wherever the caret is: the letters typed after the "@" and the range of the
    /// "@" and those letters (UTF-16, as NSTextView counts). nil: the caret is not in a mention.
    struct Spot: Equatable {
        let query: String
        let range: NSRange
    }

    static func spot(_ text: String, caret: Int) -> Spot? {
        let ns = text as NSString
        guard caret >= 0, caret <= ns.length else { return nil }
        var i = caret
        var letters = 0
        while i > 0 {
            let c = ns.character(at: i - 1)
            if c == 0x40 { break }   // "@"
            guard let u = UnicodeScalar(c), CharacterSet.letters.contains(u), letters < 12 else { return nil }
            letters += 1
            i -= 1
        }
        guard i > 0, ns.character(at: i - 1) == 0x40 else { return nil }
        let at = i - 1
        if at > 0, let u = UnicodeScalar(ns.character(at: at - 1)), !CharacterSet.whitespacesAndNewlines.contains(u),
           !"([{\"'«".unicodeScalars.contains(u) { return nil }
        return Spot(query: ns.substring(with: NSRange(location: i, length: caret - i)), range: NSRange(location: at, length: caret - at))
    }

    /// The text with the mention at `spot` replaced by "@Name " (a space only when none follows), and the caret after it.
    static func complete(_ text: String, at spot: Spot, with a: AgentInfo) -> (text: String, caret: Int) {
        let ns = text as NSString
        let end = spot.range.location + spot.range.length
        let nextIsSpace = end < ns.length && (UnicodeScalar(ns.character(at: end)).map { CharacterSet.whitespacesAndNewlines.contains($0) } ?? false)
        let ins = "@" + a.name + (nextIsSpace ? "" : " ")
        let out = ns.replacingCharacters(in: spot.range, with: ins)
        return (out, spot.range.location + (ins as NSString).length + (nextIsSpace ? 1 : 0))
    }

    /// The partial name after the last "@" if the text ends inside a mention ("ask @Le" -> "Le").
    static func partial(_ text: String) -> String? {
        guard let at = text.lastIndex(of: "@") else { return nil }
        if at > text.startIndex, let p = text[..<at].last, !p.isWhitespace { return nil }
        let tail = text[text.index(after: at)...]
        guard tail.allSatisfy({ $0.isLetter }), tail.count <= 12 else { return nil }
        return String(tail)
    }
    static func suggestions(_ text: String, roster: [AgentInfo]) -> [AgentInfo] {
        guard let p = partial(text)?.lowercased() else { return [] }
        return roster.filter { $0.name.lowercased().hasPrefix(p) }
    }
    /// The text with the partial mention completed.
    static func complete(_ text: String, with a: AgentInfo) -> String {
        guard let at = text.lastIndex(of: "@") else { return text + "@" + a.name + " " }
        return String(text[..<at]) + "@" + a.name + " "
    }
}

/// The new tab's feed card from an agent's message: a bold first line and a short rest, markdown stripped.
enum FeedText {
    static func plain(_ s: String) -> String {
        var t = s.replacingOccurrences(of: #"\*\*|__|`|^#+\s*|^\s*[-*]\s+"#, with: "", options: .regularExpression)
        t = t.replacingOccurrences(of: #"\[([^\]]+)\]\([^)]+\)"#, with: "$1", options: .regularExpression)
        t = t.replacingOccurrences(of: #"(?m)^\s*@\w+\s*[:,—–-].*$"#, with: "", options: .regularExpression)   // hand-over lines
        return t.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// (title, body): the first sentence or line (at most `titleMax`), then the rest (at most `bodyMax`).
    static func split(_ s: String, titleMax: Int = 80, bodyMax: Int = 150) -> (String, String) {
        let t = plain(s)
        guard !t.isEmpty else { return ("", "") }
        var cut = t.endIndex
        if let nl = t.firstIndex(of: "\n") { cut = nl }
        if let r = t.range(of: #"[.!?](\s|$)"#, options: .regularExpression), r.lowerBound < cut { cut = t.index(after: r.lowerBound) }
        var title = String(t[..<cut]).trimmingCharacters(in: .whitespaces)
        var rest = String(t[cut...]).trimmingCharacters(in: .whitespacesAndNewlines)
        if title.count > titleMax {
            let head = String(title.prefix(titleMax))
            let at = head.lastIndex(of: " ") ?? head.endIndex
            rest = String(title[at...]).trimmingCharacters(in: .whitespaces) + (rest.isEmpty ? "" : " " + rest)
            title = String(head[..<at]) + "\u{2026}"
        }
        rest = rest.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
        if rest.count > bodyMax { rest = String(rest.prefix(bodyMax - 1)).trimmingCharacters(in: .whitespaces) + "\u{2026}" }
        return (title, rest)
    }

    /// What the omnibox does with the text: an address or a search opens in the tab; anything else goes to the team.
    enum Route: Equatable { case open, team }
    static func route(_ typed: String) -> Route {
        let t = typed.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.hasPrefix("http://") || t.hasPrefix("https://") { return .open }
        if !t.contains(" "), t.contains("."), t.count > 3 { return .open }
        return .team
    }
}

// MARK: -: usage per agent (GET /agents/usage)

/// The session and week windows as the person's plan counts them, and each agent's share of the same allowance.
struct AgentUsage: Equatable {
    /// A row the roster does not name: a retired agent that still has money in the window (Rep, Seara...), or
    /// `other` - what no agent was booked for (the web's Lia). The server names it, so the rows add up to the bar.
    struct RowLabel: Equatable {
        var name: String
        var role: String
        var retired: Bool
        var other: Bool
    }

    struct Window: Equatable {
        /// The tier's whole budget (every agent).
        var pct: Double
        var resets: Date?
        /// agent id -> percent of the same allowance (Giggs never listed)
        var agents: [(id: String, pct: Double)]
        /// Marketing (Lia, Met) against its own cap - the limit that stops them; nil from servers.
        var mktPct: Double? = nil
        /// False when the window has no cap of its own (Free's session and week): its figure is a share of the
        /// month's limit and its roll frees nothing, so no reset line is drawn. True from servers.
        var capped: Bool = true
        /// Names for rows the roster does not hold (`retired` / `other` rows), by id.
        var labels: [String: RowLabel] = [:]
        static func == (a: Window, b: Window) -> Bool {
            a.pct == b.pct && a.resets == b.resets && a.mktPct == b.mktPct && a.capped == b.capped && a.labels == b.labels
                && a.agents.map(\.id) == b.agents.map(\.id) && a.agents.map(\.pct) == b.agents.map(\.pct)
        }

        /// The line under the bar: the reset, or (no cap of its own) that it counts toward the month.
        func note(session: Bool, reset: (Date?, Bool) -> String) -> String {
            capped ? reset(resets, session) : AgentUsage.monthNote
        }
    }
    var session: Window
    var week: Window
    /// The calendar month (Free's Dev budget is a month sum); nil from servers.
    var month: Window? = nil

    /// The "Other" row's colour: Apple's system gray (#8E8E93), the same in light and dark and legible on both.
    static let otherGray: UInt32 = 0x8E8E93

    /// Under a window with no cap of its own (Free): it frees nothing when it rolls.
    static let monthNote = "Counts toward this month\u{2019}s limit"

    /// The footer under the week's agents.
    static func weekFooter(_ w: Window) -> String {
        w.capped ? "Each agent\u{2019}s share counts toward the same weekly limit."
            : "Each agent\u{2019}s share counts toward this month\u{2019}s limit. The rows add up to the bar."
    }

    /// The rows Settings › Usage draws: every agent the server lists, in its order, named and coloured from the
    /// roster (else the fallback, else `AgentInfo.known`, else its id). Only a "soon" agent (Giggs) is left out -
    /// unless the server sends it as a retired row with money (every row the bar is made of is drawn).
    static func rows(_ w: Window, roster: [AgentInfo]) -> [(agent: AgentInfo, pct: Double)] {
        var seen = Set<String>()
        return w.agents.compactMap { a in
            guard !a.id.isEmpty, seen.insert(a.id).inserted else { return nil }
            let label = w.labels[a.id]
            if let l = label, l.other {
                // "Other" is drawn in Seara's shape (retired agents' and unattributed spend), but in
                // a neutral gray, not her yellow (it is nobody's colour; reads the same in light and dark).
                let look = AgentInfo.lookup("seara", in: roster)
                return (AgentInfo(id: a.id, name: l.name.isEmpty ? "Other" : l.name, role: l.role,
                                  shape: look?.shape ?? .diamond, colorHex: AgentUsage.otherGray), a.pct)
            }
            let info = AgentInfo.lookup(a.id, in: roster)
                ?? AgentInfo(id: a.id, name: (label?.name).flatMap { $0.isEmpty ? nil : $0 } ?? DlgOrigin.displayName(a.id),
                             role: label?.role ?? "", shape: .ring, colorHex: 0x8A8F98)
            if label?.retired == true { return (info, a.pct) }
            return info.soon ? nil : (info, a.pct)
        }
    }

    static func parse(_ data: Data) -> AgentUsage? {
        guard let o = JSONRead.object(data), JSONRead.bool(o, "ok") else { return nil }
        func win(_ k: String) -> Window {
            let w = o[k] as? JSONObject
            let agents: [(id: String, pct: Double)] = JSONRead.objects(w, "agents").compactMap { a in
                guard let id = JSONRead.string(a, "id") else { return nil }
                return (id, JSONRead.double(a, "pct") ?? 0)
            }
            var labels: [String: RowLabel] = [:]
            for a in JSONRead.objects(w, "agents") {
                guard let id = JSONRead.string(a, "id"), JSONRead.bool(a, "retired") || JSONRead.bool(a, "other") else { continue }
                labels[id] = RowLabel(name: JSONRead.string(a, "name") ?? "", role: JSONRead.string(a, "role") ?? "",
                                      retired: JSONRead.bool(a, "retired"), other: JSONRead.bool(a, "other"))
            }
            return Window(pct: JSONRead.double(w, "pct") ?? 0,
                          resets: JSONRead.double(w, "resets").map { Date(timeIntervalSince1970: $0 / 1000) }, agents: agents,
                          mktPct: JSONRead.double(w, "mkt_pct"), capped: w?["capped"] == nil ? true : JSONRead.bool(w, "capped"), labels: labels)
        }
        return AgentUsage(session: win("session"), week: win("week"), month: (o["month"] as? JSONObject) == nil ? nil : win("month"))
    }
}
