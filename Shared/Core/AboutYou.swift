import Foundation

/// How a member heard about Liaison (`acquisition-source`) and what describes them
/// (`type-of-market`, from the welcome's role, LiaRole) in their Memberstack record. The welcome asks both for every
/// account that goes through it (now per account, AccountPrefs): the role step, then "How did you hear about Liaison?"
/// with the optional creator code (skipped when the email sign-up already saved the source). The "About you" sheet is
/// the fallback for members already past the welcome on this Mac whose record still lacks a field: it asks only what is
/// missing (a role this Mac already knows is sent without asking), "Not now" hides it for 7 days.
/// The answers go to Memberstack's own client API with the member's token (`POST client.memberstack.com/member
/// {customFields}`, what @memberstack/dom updateMember sends; the Mac already saves the name this way). An answer that
/// could not be delivered waits per member in UserDefaults and is sent again on the next launch, like the creator code.
enum AboutYou {
    static let sourceField = MacSignIn.sourceField   // "acquisition-source"
    static let marketField = "type-of-market"
    static let fields = [sourceField, marketField]

    /// The values set for `type-of-market`: agency, studio, freelancer, business (in-house team), other.
    static let marketValues = ["agency", "studio", "freelancer", "business", "other"]

    /// The welcome's role as `type-of-market`: Agency or studio -> agency, Founder or freelancer -> freelancer,
    /// Marketer -> business (the in-house team), Developer -> other. nil: no role.
    static func marketValue(_ role: LiaRole?) -> String? {
        switch role {
        case .agency: return "agency"
        case .owner: return "freelancer"
        case .marketer: return "business"
        case .developer: return "other"
        case nil: return nil
        }
    }

    /// The value to save for a picked source; nil for nothing picked or an unknown id.
    static func sourceValue(_ picked: String?) -> String? {
        guard let p = picked, MacSignIn.sources.contains(where: { $0.id == p }) else { return nil }
        return p
    }

    // MARK: what the member's record lacks (Memberstack GET /member)

    /// The member's custom fields in a GET /member answer (`data.customFields`, or a bare member object); nil when the
    /// answer is not a member at all (then nothing is asked: a failed read is not "missing").
    static func customFields(_ json: JSONObject?) -> JSONObject? {
        guard let root = json else { return nil }
        let m = (root["data"] as? JSONObject) ?? root
        guard JSONRead.string(m, "id") != nil else { return nil }
        return (m["customFields"] as? JSONObject) ?? [:]
    }

    /// The fields of ours that are absent, empty or blank, in `fields` order.
    static func missing(_ customFields: JSONObject) -> [String] {
        fields.filter { f in
            guard let v = customFields[f] else { return true }
            if let s = v as? String { return s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            return v is NSNull
        }
    }

    /// When the member was created (`data.createdAt`: an ISO 8601 string, or epoch seconds / milliseconds).
    static func createdAt(_ json: JSONObject?) -> Date? {
        guard let root = json else { return nil }
        let m = (root["data"] as? JSONObject) ?? root
        if let s = m["createdAt"] as? String, Double(s) == nil {
            let f = ISO8601DateFormatter()
            f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let d = f.date(from: s) { return d }
            f.formatOptions = [.withInternetDateTime]
            return f.date(from: s)
        }
        if let n = JSONRead.double(m, "createdAt"), n > 0 { return Date(timeIntervalSince1970: n > 1e11 ? n / 1000 : n) }
        return nil
    }

    /// A member made this recently is a sign-up: its creator code goes with via "signup", any other with "settings".
    static let newAccountWindow: TimeInterval = 3 * 24 * 3600

    static func creatorVia(createdAt: Date?, now: Date) -> CreatorCode.Via {
        guard let c = createdAt else { return .settings }
        let age = now.timeIntervalSince(c)
        return age > -3600 && age < newAccountWindow ? .signup : .settings
    }

    // MARK: this Mac's record per member (UserDefaults)

    struct Local: Codable, Equatable {
        /// "Not now": nothing is asked before this.
        var snoozedUntil: Date?
        /// Fields answered from this Mac: never asked again here, whatever Memberstack says.
        var answered: [String] = []
        /// Answers not delivered yet (field -> value) and since when.
        var pending: [String: String] = [:]
        var pendingAt: Date?
    }

    static func key(member: String) -> String { "lia_about_you_" + member }
    static let snooze: TimeInterval = 7 * 24 * 3600
    /// An undelivered answer is tried this long, then dropped.
    static let pendingLifetime: TimeInterval = 60 * 24 * 3600

    static func encode(_ l: Local) -> Data? { try? JSONEncoder().encode(l) }
    static func decode(_ d: Data?) -> Local {
        guard let d, let l = try? JSONDecoder().decode(Local.self, from: d) else { return Local() }
        return l
    }

    static func isSnoozed(_ l: Local, now: Date) -> Bool {
        guard let u = l.snoozedUntil else { return false }
        return now < u
    }

    /// "Not now": hidden for 7 days.
    static func snoozing(_ l: Local, now: Date) -> Local {
        var n = l
        n.snoozedUntil = now.addingTimeInterval(snooze)
        return n
    }

    /// The questions to show: what Memberstack lacks, less what this Mac already answered or still holds; none while
    /// snoozed. Empty: no sheet.
    static func toAsk(missing: [String], local: Local, now: Date) -> [String] {
        if isSnoozed(local, now: now) { return [] }
        return missing.filter { fields.contains($0) && !local.answered.contains($0) && local.pending[$0] == nil }
    }

    /// The customFields to save for the picked answers (only valid ones, only fields that were asked).
    static func answers(asked: [String], source: String?, role: LiaRole?) -> [String: String] {
        var out: [String: String] = [:]
        if asked.contains(sourceField), let s = sourceValue(source) { out[sourceField] = s }
        if asked.contains(marketField), let m = marketValue(role) { out[marketField] = m }
        return out
    }

    /// Save is possible once every asked question has an answer.
    static func canSave(asked: [String], source: String?, role: LiaRole?) -> Bool {
        !asked.isEmpty && answers(asked: asked, source: source, role: role).count == asked.filter(fields.contains).count
    }

    /// What the record lacks that this Mac can fill without asking: `type-of-market` from a role already known here.
    static func silent(toAsk: [String], role: LiaRole?) -> [String: String] {
        guard toAsk.contains(marketField), let m = marketValue(role) else { return [:] }
        return [marketField: m]
    }

    /// The welcome's source step: shown unless the record has a source already (the email sign-up saved it) or this
    /// Mac answered it. `customFields` nil (not read): shown.
    static func welcomeAsksSource(customFields: JSONObject?, local: Local) -> Bool {
        if local.answered.contains(sourceField) || local.pending[sourceField] != nil { return false }
        guard let cf = customFields else { return true }
        return missing(cf).contains(sourceField)
    }

    /// The record after Save: the answers are answered (never asked again) and wait to be delivered.
    static func answering(_ l: Local, _ fields: [String: String], now: Date) -> Local {
        var n = l
        for (k, v) in fields {
            if !n.answered.contains(k) { n.answered.append(k) }
            n.pending[k] = v
        }
        if !fields.isEmpty { n.pendingAt = now }
        n.snoozedUntil = nil
        return n
    }

    /// What to send now: the pending answers, or nil (none, or too old: `local` drops them then).
    static func toSend(_ l: Local, now: Date) -> [String: String]? {
        guard !l.pending.isEmpty, let at = l.pendingAt else { return nil }
        let age = now.timeIntervalSince(at)
        guard age > -3600, age < pendingLifetime else { return nil }
        return l.pending
    }

    /// The record after a send (or after `toSend` said they are too old: pass `.refused`).
    static func after(_ l: Local, sent: [String: String], outcome: SaveOutcome) -> Local {
        guard outcome != .retry else { return l }
        var n = l
        for k in sent.keys where n.pending[k] == sent[k] { n.pending[k] = nil }
        if n.pending.isEmpty { n.pendingAt = nil }
        return n
    }

    // MARK: Memberstack POST /member {customFields}

    enum SaveOutcome: Equatable {
        case saved
        /// for good (a 4xx Memberstack will not take, e.g. a field the member may not write): logged, not retried
        case refused(String)
        /// offline, the token, 408, 429, 5xx: next launch
        case retry
    }

    /// status 0 / json nil: no answer.
    static func saveOutcome(status: Int, json: JSONObject?) -> SaveOutcome {
        if (200..<300).contains(status), json?["data"] is JSONObject { return .saved }
        if status == 0 || status == 401 || status == 408 || status == 429 || status >= 500 { return .retry }
        if (400..<500).contains(status) {
            let code = JSONRead.string(json, "code") ?? JSONRead.string(json?["error"] as? JSONObject, "code") ?? "http_\(status)"
            return .refused(code)
        }
        return .retry   // 2xx without a member: say nothing, try again
    }

    /// The request body.
    static func body(_ fields: [String: String]) -> [String: Any] { ["customFields": fields] }
}
