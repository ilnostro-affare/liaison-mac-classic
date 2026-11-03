import Foundation

/// The signed-in member, read from Memberstack GET /member (same fields shell.js paints the sidebar from).
struct MemberProfile: Equatable {
    let id: String
    let email: String
    let fullName: String
    let firstName: String
    let company: String
    let planName: String
    /// auth.providers, lower-cased ("google"): settings.js renderGeneral reads `{provider}` objects or plain strings.
    var providers: [String] = []
    /// auth.hasPassword as Memberstack sends it; nil when the field is absent.
    var hasPasswordField: Bool? = nil

    /// settings.js: hasGoogle = providers includes "google".
    var hasGoogle: Bool { providers.contains("google") }
    /// settings.js: hasPw = (hasPassword !== false && no providers) ? true: !!hasPassword.
    var hasPassword: Bool {
        if hasPasswordField != false && providers.isEmpty { return true }
        return hasPasswordField ?? false
    }
    /// settings.js emailEditable: a Google member's email comes from Google unless they also have a password.
    var emailEditable: Bool { !hasGoogle || (hasPasswordField ?? false) }
    /// settings.js: Disconnect is disabled ("Add a password first") when Google is the only way in.
    var canDisconnectGoogle: Bool { !( !hasPassword && providers.count == 1) }

    /// First letter of the name, the avatar (shell.js: first, else full name, else "A").
    var letter: String {
        let source = firstName.isEmpty ? fullName : firstName
        return source.trimmingCharacters(in: .whitespaces).first.map { String($0).uppercased() } ?? "A"
    }

    static let canonPlans = ["pln_free-example1": "Free", "pln_lia-pro-example2": "Lia Pro", "pln_lia-max-example3": "Lia Max"]

    static func parse(_ data: Data) -> MemberProfile? {
        guard let root = JSONRead.object(data) else { return nil }
        let m = (root["data"] as? JSONObject) ?? root
        guard let id = JSONRead.string(m, "id") else { return nil }
        let cf = m["customFields"] as? JSONObject
        func field(_ keys: [String]) -> String {
            for k in keys { if let v = JSONRead.string(cf, k)?.trimmingCharacters(in: .whitespaces), !v.isEmpty { return v } }
            return ""
        }
        let first = field(["first-name", "firstName", "first_name"])
        let last = field(["last-name", "lastName", "last_name"])
        let email = JSONRead.string(m["auth"] as? JSONObject, "email") ?? ""
        let emailName = email.split(separator: "@").first.map(String.init) ?? ""
        let full = [first, last].filter { !$0.isEmpty }.joined(separator: " ")
        let fullName = !full.isEmpty ? full : (!emailName.isEmpty ? emailName : "Account")

        // The paid plan connection: never the free plan, never a canceled one (the server).
        let okStates = ["ACTIVE", "TRIALING", "PAST_DUE"]
        let paid = JSONRead.objects(m, "planConnections").first { pc in
            let planId = JSONRead.string(pc, "planId") ?? ""
            if planId == "pln_free-example1" { return false }
            if (JSONRead.string(pc, "type") ?? "").uppercased() == "FREE" { return false }
            let st = (JSONRead.string(pc, "status") ?? JSONRead.string(pc["payment"] as? JSONObject, "status") ?? "").uppercased()
            return okStates.contains(st)
        }
        var planName = "Free"
        if let paid {
            let st = (JSONRead.string(paid, "status") ?? JSONRead.string(paid["payment"] as? JSONObject, "status") ?? "").uppercased()
            let base = canonPlans[JSONRead.string(paid, "planId") ?? ""] ?? (st == "TRIALING" ? "Trial" : "Lia Pro")
            planName = base == "Trial" ? base : base + (st == "TRIALING" ? " · Trial" : "")
        }
        let authObj = m["auth"] as? JSONObject
        let provs: [String] = ((authObj?["providers"] as? [Any]) ?? []).compactMap { x -> String? in
            if let o = x as? JSONObject { return JSONRead.string(o, "provider")?.lowercased() }
            return (x as? String)?.lowercased()
        }.filter { !$0.isEmpty }
        var hasPw: Bool? = nil
        if let v = authObj?["hasPassword"], JSONRead.isBool(v) { hasPw = (v as? Bool) ?? false }
        return MemberProfile(id: id, email: email, fullName: fullName,
                             firstName: full.isEmpty ? fullName : (fullName.split(separator: " ").first.map(String.init) ?? fullName),
                             company: field(["company", "company-name"]), planName: planName,
                             providers: provs, hasPasswordField: hasPw)
    }
}

/// api /billing/summary (Stripe truth). Prices are deliberately not kept: the app never shows one.
struct BillingSummary: Equatable {
    let status: String
    let periodEnd: Date?
    let trialEnd: Date?
    let cancelAtPeriodEnd: Bool

    static func parse(_ data: Data) -> BillingSummary? {
        guard let o = JSONRead.object(data), let status = JSONRead.string(o, "status") else { return nil }
        func date(_ k: String) -> Date? { JSONRead.double(o, k).flatMap { $0 > 0 ? Date(timeIntervalSince1970: $0) : nil } }
        return BillingSummary(status: status.lowercased(), periodEnd: date("currentPeriodEnd"), trialEnd: date("trialEnd"),
                              cancelAtPeriodEnd: JSONRead.bool(o, "cancelAtPeriodEnd"))
    }

    /// One human line for the settings row.
    var statusLine: String {
        switch status {
        case "active": return cancelAtPeriodEnd ? "Active, ends at the end of the period" : "Active"
        case "trialing": return "Trial"
        case "past_due": return "Payment overdue"
        case "canceled", "cancelled": return "Canceled"
        case "none", "": return "No subscription"
        default: return status.replacingOccurrences(of: "_", with: " ").capitalized
        }
    }

    /// Which date matters: the trial end while trialing, otherwise the period end.
    var keyDate: (label: String, date: Date)? {
        if status == "trialing", let t = trialEnd { return ("Trial ends", t) }
        if let p = periodEnd, status != "none" { return (cancelAtPeriodEnd ? "Ends" : "Renews", p) }
        return nil
    }
}

/// api /meta/status: {connected, expired, fbUserId, fbName}.
struct MetaConnection: Equatable {
    let connected: Bool
    let expired: Bool
    let name: String

    static func parse(_ data: Data) -> MetaConnection? {
        guard let o = JSONRead.object(data), o["connected"] != nil || o["expired"] != nil else { return nil }
        let name = JSONRead.string(o, "fbName") ?? JSONRead.string(o, "fbUserId") ?? ""
        return MetaConnection(connected: JSONRead.bool(o, "connected"), expired: JSONRead.bool(o, "expired"), name: name)
    }
}

/// One line of Relay: who changed what. Two sources, merged like ai.js jFetch: our write journal
/// (changes made through Liaison) and Meta's own audit (meta_changes).
struct RelayComment: Equatable, Identifiable {
    let cid: String
    let name: String
    let text: String
    let ts: Double
    let replyName: String?
    let replyText: String?
    /// The author's Memberstack id (`m`): a comment is mine by identity, not by name (ai.js jcAv).
    var memberId: String? = nil
    var id: String { cid }

    init?(json c: JSONObject) {
        let t = JSONRead.double(c, "t") ?? 0
        // Rows minted before cid existed resolve by their time, as ai.js _jcid does.
        let cid = JSONRead.string(c, "cid") ?? String(Int(t), radix: 36)
        guard let x = JSONRead.string(c, "x") ?? JSONRead.string(c, "text"), !x.isEmpty else { return nil }
        self.cid = cid
        self.name = JSONRead.string(c, "n") ?? JSONRead.string(c, "name") ?? ""
        self.text = x
        self.ts = t
        let re = c["re"] as? JSONObject
        self.replyName = JSONRead.string(re, "n")
        self.replyText = JSONRead.string(re, "x")
        self.memberId = JSONRead.string(c, "m")
    }
}

struct RelayEvent: Equatable, Identifiable {
    let id: String
    /// Stable identity the comment threads hang on (null for rows that cannot be commented).
    var eid: String? = nil
    let ts: Double
    let actor: String
    let action: String
    let entity: String
    let entityType: String
    let from: String?
    let to: String?
    let viaLiaison: Bool
    let system: Bool
    var comments: [RelayComment] = []
    /// Our journal rows only: the write it records (undo_write journal_id), whether Meta still allows
    /// undoing it, and the chat that made it.
    var journalId: String? = nil
    /// Whether the server takes comments on this line: our journal rows always, Meta rows only when their
    /// actor is a Liaison member (cm, frozen at ingestion). Otherwise the server answers not_commentable.
    var commentable = false
    var undoable = false
    var undone = false
    var chatId: String? = nil
    /// Meta's audit actor id: with project_people's is_you it decides which rows are mine (ai.js).
    var actorId: String? = nil
    /// The tool the change went through as Meta names it ("Liaison", "Ads Manager", another app), and the
    /// app's real name for the tooltip (ai.js stamp: via / via_real).
    var via: String? = nil
    var viaReal: String? = nil
    /// A row of our own write journal (ai.js source 'lia'): always mine.
    var fromJournal = false
    /// The actor is a Liaison member (cm) or the change came through Liaison: the avatar's small L badge.
    var liaisonActor = false
}

/// One ad account in Relay's list, a "dialog" with its unread counter (ai.js jProjects).
struct RelayProject: Equatable, Identifiable, Hashable {
    let id: String
    let name: String
    let unread: Int
    let lastChangeAt: Double?
    let lastText: String?

    /// Two letters for the avatar, the way the web rail draws them.
    var initials: String {
        let letters = name.split(whereSeparator: { $0.isWhitespace }).compactMap(\.first).prefix(2)
        return letters.isEmpty ? "#" : String(letters).uppercased()
    }
}

struct RelayFolder: Equatable, Identifiable, Hashable {
    var id: String
    var name: String
    var projects: [String]

    var json: JSONObject { ["id": id, "name": name, "projects": projects] }
}

enum RelayDirectory {
    /// mcp /call/projects -> {projects, folders}. Accounts the backend knows are empty are dropped
    /// (that verdict comes from the server, never from a slow feed). Newest change first.
    static func parse(_ data: Data) -> (projects: [RelayProject], folders: [RelayFolder]) {
        guard let o = JSONRead.object(data) else { return ([], []) }
        let projects = JSONRead.objects(o, "projects").compactMap { p -> RelayProject? in
            guard let id = JSONRead.string(p, "id"), !JSONRead.bool(p, "known_empty") else { return nil }
            return RelayProject(id: id, name: JSONRead.string(p, "name") ?? "act_\(id)",
                                unread: max(0, JSONRead.int(p, "unread") ?? 0),
                                lastChangeAt: JSONRead.double(p, "last_change_at"),
                                lastText: JSONRead.string(p, "last_text"))
        }.sorted { ($0.lastChangeAt ?? 0) > ($1.lastChangeAt ?? 0) }
        let folders = JSONRead.objects(o, "folders").compactMap { f -> RelayFolder? in
            guard let id = JSONRead.string(f, "id") else { return nil }
            return RelayFolder(id: id, name: JSONRead.string(f, "name") ?? "Folder", projects: JSONRead.strings(f, "projects"))
        }
        return (projects, folders)
    }

    /// Unread per tab: All, then each folder counting only its own accounts.
    static func unread(in folder: RelayFolder?, projects: [RelayProject]) -> Int {
        let list = folder.map { f in projects.filter { f.projects.contains($0.id) } } ?? projects
        return list.reduce(0) { $0 + $1.unread }
    }
}

/// ai /intelligence/usage: the limit bars (rolling 4h session, weekly cycle), their split by category,
/// and this chat's share of a session for the ring under the input (the server, ai.js paintCtxRing 6937).
struct UsageInfo: Equatable {
    struct Window: Equatable {
        let pct: Int
        let resetAt: Date?
        let active: Bool
        /// read / write / web / other, in percent of the window.
        var split: [String: Double] = [:]
    }
    let session: Window
    let weekly: Window
    var weeklyCost: Double = 0
    var weeklyBudget: Double = 0
    var buildCost: Double = 0
    var tier: String = ""
    /// This chat: measured or not, and its percent of a session.
    var chatKnown = false
    var chatPct: Double = 0
    var chatSplit: [String: Double] = [:]

    static func parse(_ data: Data) -> UsageInfo? {
        guard let o = JSONRead.object(data), JSONRead.bool(o, "ok") else { return nil }
        func split(_ w: JSONObject?) -> [String: Double] {
            var out: [String: Double] = [:]
            for (k, v) in (w?["split"] as? JSONObject) ?? [:] { if let n = v as? NSNumber, !JSONRead.isBool(v) { out[k] = n.doubleValue } }
            return out
        }
        func win(_ k: String) -> Window {
            let w = o[k] as? JSONObject
            let r = JSONRead.double(w, "reset_at").flatMap { $0 > 0 ? Date(timeIntervalSince1970: $0 > 1e11 ? $0 / 1000 : $0) : nil }
            return Window(pct: min(100, max(0, JSONRead.int(w, "pct") ?? 0)), resetAt: r, active: JSONRead.bool(w, "active"), split: split(w))
        }
        let wk = o["weekly"] as? JSONObject, chat = o["chat"] as? JSONObject
        return UsageInfo(session: win("session"), weekly: win("weekly"),
                         weeklyCost: JSONRead.double(wk, "cost_usd") ?? 0, weeklyBudget: JSONRead.double(wk, "budget_usd") ?? 0,
                         buildCost: JSONRead.double(o["build"] as? JSONObject, "cost_usd") ?? 0, tier: JSONRead.string(o, "tier") ?? "",
                         chatKnown: JSONRead.bool(chat, "known"), chatPct: JSONRead.double(chat, "pct") ?? 0, chatSplit: split(chat))
    }

    /// "Lia 1.4" bar: the week's spend without the retired Build, against the weekly budget (settings.js).
    var lia14Pct: Int {
        guard weeklyBudget > 0 else { return 0 }
        return min(100, max(0, Int(((weeklyCost - buildCost) / weeklyBudget * 100).rounded())))
    }

    /// The strip above the box from 75% (ai.js paintLim): the higher of session and week.
    var limitStrip: (text: String, pct: Int, full: Bool)? {
        let useSession = session.pct >= weekly.pct
        let pct = max(session.pct, weekly.pct)
        guard pct >= 75 else { return nil }
        if pct >= 100 { return (tier == "free" ? "Free limit reached" : "Limit reached", 100, true) }
        return (useSession ? "\(pct)% of this session" : "\(pct)% of this week's usage", pct, false)
    }

    /// The ring's tooltip (ai.js paintCtxRing).
    var chatTip: String {
        if !chatKnown { return "This chat has not been measured" }
        if chatPct >= 100 { return "\(Int(chatPct.rounded()))% of a session \u{00b7} a new chat would be cheaper" }
        return chatPct < 1 ? "<1% of a session" : "\(Int(chatPct.rounded()))% of a session"
    }
}

/// meta /notifications/prefs, same four categories and cadence cohorts as settings.js.
struct NotificationPrefs: Equatable {
    struct Category: Equatable { let key: String; let label: String; let detail: String; let cadences: [String] }
    static let categories: [Category] = [
        .init(key: "leads", label: "Leads", detail: "New leads attributed from Meta, delivered on each sync.", cadences: ["realtime", "3h", "6h", "12h", "daily", "weekly", "monthly"]),
        .init(key: "metrics", label: "Metrics", detail: "CPL, CTR, spend spikes and lead volume shifts by account.", cadences: ["6h", "12h", "daily", "3day", "weekly"]),
        .init(key: "storage", label: "Storage", detail: "A periodic digest of what Liaison keeps in Storage.", cadences: ["daily", "3day", "weekly", "monthly"]),
        .init(key: "system", label: "System and connection", detail: "Meta connection, token expiry and account access.", cadences: ["realtime", "daily"]),
    ]
    static let defaults: [String: (Bool, String)] = ["leads": (true, "realtime"), "metrics": (true, "daily"), "storage": (true, "weekly"), "system": (true, "realtime")]

    var values: [String: (enabled: Bool, cadence: String)]

    static func == (a: NotificationPrefs, b: NotificationPrefs) -> Bool {
        a.values.keys.sorted() == b.values.keys.sorted() && a.values.allSatisfy { k, v in b.values[k]?.enabled == v.enabled && b.values[k]?.cadence == v.cadence }
    }

    static func label(_ cadence: String, category: String) -> String {
        if category == "leads" && cadence == "realtime" { return "Realtime (1 min window)" }
        return ["realtime": "Realtime", "1h": "Every hour", "3h": "Every 3 hours", "6h": "Every 6 hours", "12h": "Every 12 hours",
                "daily": "Daily", "3day": "Every 3 days", "weekly": "Weekly", "monthly": "Monthly"][cadence] ?? cadence
    }

    static func parse(_ data: Data?) -> NotificationPrefs {
        let prefs = data.flatMap(JSONRead.object).flatMap { $0["prefs"] as? JSONObject }
        var v: [String: (enabled: Bool, cadence: String)] = [:]
        for c in categories {
            let row = prefs?[c.key] as? JSONObject
            let d = defaults[c.key]!
            let cad = JSONRead.string(row, "cadence").flatMap { c.cadences.contains($0) ? $0 : nil } ?? d.1
            v[c.key] = (row?["enabled"] as? Bool ?? d.0, cad)
        }
        return NotificationPrefs(values: v)
    }

    var json: JSONObject {
        var o: JSONObject = [:]
        for (k, val) in values { o[k] = ["enabled": val.enabled, "cadence": val.cadence] }
        return o
    }
}

enum RelayFeed {
    private static let actionNames: [String: String] = [
        "campaign status updated": "Changed a campaign status", "ad set status updated": "Changed an ad set status",
        "campaign created": "Created a campaign", "ad set created": "Created an ad set",
        "ad set targeting updated": "Changed targeting", "ad set optimisation goal updated": "Changed the optimisation goal",
        "ad set bid strategy updated": "Changed the bid strategy", "account billed": "Billed the account",
        "account status updated": "Changed the account status",
    ]
    private static let ourActions = ["paused": "Paused", "resumed": "Resumed", "activated": "Resumed",
                                     "budget": "Changed a budget", "renamed": "Renamed", "created": "Created"]

    /// Newest first, the way a phone reads a feed.
    static func parse(_ data: Data) -> [RelayEvent] {
        guard let o = JSONRead.object(data) else { return [] }
        var ours: [RelayEvent] = []
        for r in JSONRead.objects(o, "journal") {
            let ts = JSONRead.double(r, "ts") ?? 0
            let name = JSONRead.string(r, "entity_name") ?? JSONRead.string(r, "entity_id") ?? ""
            let type = (JSONRead.string(r, "entity_type") ?? "").replacingOccurrences(of: "_", with: " ")
            let diffs = JSONRead.objects(r, "diff")
            for (i, d) in (diffs.isEmpty ? [[:]] : diffs).enumerated() {
                let kind = JSONRead.string(d, "kind") ?? ""
                let isBudget = kind == "budget"
                let jid = JSONRead.string(r, "id")
                // The server stamps the eid its comment threads are keyed by; derive it only if absent.
                let eid = JSONRead.string(r, "eid") ?? jid.map { "j" + String($0.prefix(24)) }
                ours.append(RelayEvent(
                    id: "j\(jid ?? String(Int(ts)))-\(i)", eid: eid, ts: ts, actor: "You",
                    action: ourActions[kind] ?? "Changed", entity: name, entityType: type,
                    from: isBudget ? JSONRead.string(d, "old") : nil, to: isBudget ? JSONRead.string(d, "new") : nil,
                    viaLiaison: true, system: false,
                    journalId: jid, commentable: eid != nil, undoable: (r["undo_ok"] as? Bool) == true,
                    undone: JSONRead.string(r, "undo_block") == "undone", chatId: JSONRead.string(r, "session"),
                    via: "Liaison", viaReal: "Liaison", fromJournal: true, liaisonActor: true))
            }
        }
        var seen = Set<String>()
        ours = ours.filter { seen.insert("\($0.action)|\($0.entity)|\(Int($0.ts / 60000))").inserted }

        let meta: [RelayEvent] = JSONRead.objects(o, "meta_changes").enumerated().compactMap { i, m in
            let ts = JSONRead.double(m, "at") ?? 0
            let actor = JSONRead.string(m, "actor") ?? "Meta"
            let raw = JSONRead.string(m, "action") ?? "Changed something"
            let action = actionNames[raw.lowercased()] ?? (raw.prefix(1).uppercased() + raw.dropFirst())
            let via = JSONRead.string(m, "via")
            var ev = RelayEvent(id: JSONRead.string(m, "eid") ?? "m\(i)-\(Int(ts))", eid: JSONRead.string(m, "eid"), ts: ts, actor: actor, action: action,
                                entity: JSONRead.string(m, "entity_name") ?? JSONRead.string(m, "entity_id") ?? "",
                                entityType: JSONRead.string(m, "entity_type") ?? "",
                                from: JSONRead.string(m, "from"), to: JSONRead.string(m, "to"),
                                viaLiaison: via == "Liaison", system: actor == "Meta")
            let cm = JSONRead.bool(m, "cm") || JSONRead.int(m, "cm") == 1
            ev.commentable = ev.eid != nil && cm
            ev.actorId = JSONRead.string(m, "actor_id")
            ev.via = via
            ev.viaReal = JSONRead.string(m, "via_real")
            ev.liaisonActor = cm || via == "Liaison"
            // Meta also audits changes Liaison made: keep ours, drop Meta's echo within 90 s.
            if ev.viaLiaison && ours.contains(where: { abs($0.ts - ts) < 90_000 }) { return nil }
            return ev
        }
        let threads = o["comments"] as? JSONObject
        return (ours + meta).map { e -> RelayEvent in
            var e = e
            if let eid = e.eid, let list = threads?[eid] as? [Any] {
                e.comments = list.compactMap { ($0 as? JSONObject).flatMap(RelayComment.init(json:)) }.sorted { $0.ts < $1.ts }
            }
            return e
        }.sorted { $0.ts > $1.ts }
    }
}

/// mcp /call/project_people: who works in an ad account. `active` changed something in the last 14 days,
/// `access` can but did not (ai.js Relay header and people panel).
struct AccountPerson: Equatable, Identifiable {
    let name: String
    let changes: Int
    let lastAt: Double?
    let apps: [String]
    let isYou: Bool
    let system: Bool
    /// Meta's actor id for this person (project_people `id`), matched against a row's actor_id.
    var actorId: String? = nil
    var id: String { name }

    var initials: String {
        let letters = name.split(whereSeparator: { $0.isWhitespace }).compactMap(\.first).prefix(2)
        return letters.isEmpty ? "?" : String(letters).uppercased()
    }

    /// "Power Editor" is what Meta calls Ads Manager in its audit log.
    var appsLabel: String {
        apps.map { $0 == "Power Editor" ? "Ads Manager" : $0 }.joined(separator: ", ")
    }
}

struct AccountPeople: Equatable {
    let active: [AccountPerson]
    let access: [AccountPerson]

    static func parse(_ data: Data) -> AccountPeople? {
        guard let o = JSONRead.object(data), JSONRead.bool(o, "ok") else { return nil }
        func list(_ k: String) -> [AccountPerson] {
            JSONRead.objects(o, k).compactMap { p in
                guard let n = JSONRead.string(p, "name"), !n.isEmpty else { return nil }
                return AccountPerson(name: n, changes: JSONRead.int(p, "changes") ?? 0, lastAt: JSONRead.double(p, "last_at"),
                                     apps: JSONRead.strings(p, "apps"), isYou: JSONRead.bool(p, "is_you"), system: JSONRead.bool(p, "system"),
                                     actorId: JSONRead.string(p, "id"))
            }
        }
        return AccountPeople(active: list("active").sorted { ($0.lastAt ?? 0) > ($1.lastAt ?? 0) }, access: list("access"))
    }

    var count: Int { active.count + access.count }
}

extension RelayFeed {
    /// A comment the server just stored, added to its row without waiting for the next feed read
    /// (ai.js jcSend pushes r.comment the same way; the feed catches up later).
    static func removing(cid: String, eid: String, from events: [RelayEvent]) -> [RelayEvent] {
        events.map { e in
            guard e.eid == eid else { return e }
            var e = e
            e.comments.removeAll { $0.cid == cid }
            return e
        }
    }

    static func appending(_ c: RelayComment, eid: String, to events: [RelayEvent]) -> [RelayEvent] {
        events.map { e in
            guard e.eid == eid, !e.comments.contains(where: { $0.cid == c.cid }) else { return e }
            var e = e
            e.comments.append(c)
            return e
        }
    }

    /// Changes in the last `days` days, the number in the Relay header.
    static func recentCount(_ events: [RelayEvent], now: Double, days: Double = 14) -> Int {
        events.filter { !$0.system && $0.ts >= now - days * 86_400_000 }.count
    }

    /// Meta's own lines (billing, account status, anything without a person) are service messages,
    /// drawn centred like Telegram's, not as bubbles.
    static func isServiceLine(_ e: RelayEvent) -> Bool {
        e.system || e.actor.isEmpty || e.actor == "Meta"
    }
}


/// mcp /call/media_library: the creatives shelf (uploads in our storage, images and videos in Meta).
struct MediaItem: Equatable, Identifiable {
    /// `file` is a file put in an agent's input (Storage > Uploads' index, R2 ai/{m}/att/...): any type; it
    /// travels as an attachment the model reads, never as an ad creative marker.
    enum Source: String { case upload, metaImage, metaVideo, file }
    let id: String
    let source: Source
    let name: String
    let preview: String?
    let seconds: Double?
    /// What the Uploads index knows (nil / 0 for a Meta shelf row or an older library row).
    var mime: String? = nil
    var bytes: Int = 0
    /// The file's own address (signed for an input file, /meta/upload-asset for a library file).
    var url: String? = nil
    /// A chat holds it: a delete from Uploads keeps the bytes.
    var chat: Bool = false

    var isVideo: Bool { source == .metaVideo }
    var isFile: Bool { source == .file }
    /// What the icon says (image, pdf, sheet, code, ...).
    var fileKind: String { UploadKind.of(name: name.isEmpty ? id : name, mime: mime ?? "") }

    /// An input file from Uploads as the attachment a message carries (the model reads it again; nothing is
    /// uploaded twice). A picture is "image" only when the model opens it as one.
    var attachment: ChatAttachment? {
        guard source == .file, id.contains("/att/") else { return nil }
        let m = (mime ?? "").lowercased()
        let image = ["image/png", "image/jpeg", "image/gif", "image/webp"].contains(m) && bytes <= ComposerLane.readLimit
        return ChatAttachment(key: id, kind: image ? "image" : "file", name: name.isEmpty ? "file" : name, mime: m, bytes: bytes, url: url)
    }

    /// The marker the web composer appends so the runner can resolve the creative (ai.js).
    var marker: String {
        switch source {
        case .upload: return "[attached_creative r2_key=\(id)]"
        case .metaImage: return "[attached_creative image_hash=\(id)]"
        case .metaVideo: return "[attached_creative video_id=\(id)]"
        case .file: return "[attached: \(name.isEmpty ? "file" : name), \(max(1, bytes / 1024)) KB]"
        }
    }

    static func parseLibrary(_ data: Data) -> (uploads: [MediaItem], images: [MediaItem], videos: [MediaItem])? {
        guard let o = JSONRead.object(data), JSONRead.bool(o, "ok") else { return nil }
        func rows(_ key: String, _ src: Source, _ idKey: String) -> [MediaItem] {
            JSONRead.objects(o, key).compactMap { r in
                guard let id = JSONRead.string(r, idKey), !id.isEmpty else { return nil }
                return MediaItem(id: id, source: src, name: JSONRead.string(r, "name") ?? JSONRead.string(r, "filename") ?? "",
                                 preview: JSONRead.string(r, "preview"), seconds: JSONRead.double(r, "length"))
            }
        }
        return (rows("uploads", .upload, "r2_key"), rows("meta_images", .metaImage, "image_hash"), rows("meta_videos", .metaVideo, "video_id"))
    }

    var durationLabel: String? {
        guard let s = seconds, s > 0 else { return nil }
        return "\(Int(s) / 60):" + String(format: "%02d", Int(s.rounded()) % 60)
    }
}

/// The empty chat greeting: time of day first, then a couple of plain openers.
enum Greeting {
    static func line(hour: Int, name: String?, seed: Int) -> String {
        let who = name.map { $0.trimmingCharacters(in: .whitespaces) }.flatMap { $0.isEmpty ? nil : $0 }
        let timed: String
        switch hour {
        case 5..<12: timed = who.map { "Good morning, \($0)" } ?? "Good morning"
        case 12..<18: timed = who.map { "Good afternoon, \($0)" } ?? "Good afternoon"
        case 18..<23: timed = who.map { "Good evening, \($0)" } ?? "Good evening"
        default: timed = who.map { "Up late, \($0)?" } ?? "Up late?"
        }
        let open = [timed, who.map { "Welcome back, \($0)" } ?? "Welcome back", who.map { "Where do we start, \($0)?" } ?? "Where do we start?"]
        return open[abs(seed) % open.count]
    }
}
