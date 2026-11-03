import Foundation
import os

// The one-time "About you" step (Shared/Core/AboutYou.swift has the rules). Memberstack's client API with
// the member's own token: GET /member reads the custom fields, POST /member {customFields} saves the answers (what
// @memberstack/dom updateMember sends; LiaAPI.updateName saves the name the same way).
extension LiaAPI {
    /// Memberstack `GET|POST /member` for this API's account: the status and the JSON. nil: no answer, or the account
    /// changed meanwhile.
    private func memberstackMember(_ method: String, body: [String: Any]? = nil) async -> (Int, JSONObject?)? {
        guard auth.activeId == account, let token = auth.memberToken,
              let url = URL(string: AppConfig.memberstackClient + "/member") else { return nil }
        var req = URLRequest(url: url, timeoutInterval: 20)
        LiaClient.stamp(&req)
        req.httpMethod = method
        req.setValue(AppConfig.memberstackPublicKey, forHTTPHeaderField: "X-API-Key")
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        if let body {
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = try? JSONSerialization.data(withJSONObject: body)
        }
        guard let r = try? await session.data(for: req), auth.activeId == account else { return nil }
        return ((r.1 as? HTTPURLResponse)?.statusCode ?? 0, JSONRead.object(r.0))
    }

    /// The member as Memberstack has it (nil: not read).
    func memberRecord() async -> JSONObject? {
        guard let r = await memberstackMember("GET"), r.0 == 200, AboutYou.customFields(r.1) != nil else { return nil }
        return r.1
    }

    /// Saves the answers in the member's custom fields.
    func saveMemberFields(_ fields: [String: String]) async -> AboutYou.SaveOutcome {
        guard !fields.isEmpty else { return .saved }
        guard let r = await memberstackMember("POST", body: AboutYou.body(fields)) else { return .retry }
        return AboutYou.saveOutcome(status: r.0, json: r.1)
    }
}

/// This Mac's record per member (UserDefaults) and the delivery of answers that are waiting.
@MainActor
enum AboutYouSync {
    private static let log = Logger(subsystem: "com.liaisone.mac", category: "about-you")
    private static var inFlight: Set<String> = []

    static func local(member: String) -> AboutYou.Local {
        AboutYou.decode(UserDefaults.standard.data(forKey: AboutYou.key(member: member)))
    }

    static func store(_ l: AboutYou.Local, member: String) {
        if let d = AboutYou.encode(l) { UserDefaults.standard.set(d, forKey: AboutYou.key(member: member)) }
    }

    /// "Not now": hidden for 7 days on this Mac.
    static func snooze(member: String) {
        store(AboutYou.snoozing(local(member: member), now: Date()), member: member)
    }

    /// Save: the answers are kept first (never asked again here), then delivered; the creator code goes through its own
    /// queue (POST /agents/creator-code).
    static func answer(_ fields: [String: String], creatorCode: String?, via: CreatorCode.Via, auth: AuthStore) async {
        guard let member = auth.activeId else { return }
        store(AboutYou.answering(local(member: member), fields, now: Date()), member: member)
        if let c = creatorCode { CreatorCodeSync.enqueue(c, via: via, member: member) }
        await flush(auth: auth)
        if creatorCode != nil { await CreatorCodeSync.flush(auth: auth) }
    }

    /// Sends the active member's waiting answers, once at a time.
    @discardableResult
    static func flush(auth: AuthStore) async -> AboutYou.SaveOutcome? {
        guard let member = auth.activeId, auth.phase == .signedIn, !auth.sessionExpired, !inFlight.contains(member) else { return nil }
        let l = local(member: member)
        guard let fields = AboutYou.toSend(l, now: Date()) else {
            if !l.pending.isEmpty { store(AboutYou.after(l, sent: l.pending, outcome: .refused("expired")), member: member) }
            return nil
        }
        inFlight.insert(member)
        defer { inFlight.remove(member) }
        let outcome = await LiaAPI(auth: auth, account: member).saveMemberFields(fields)
        // re-read: a Save in the meantime may have added answers
        store(AboutYou.after(local(member: member), sent: fields, outcome: outcome), member: member)
        switch outcome {
        case .saved: log.notice("about you: saved \(fields.keys.sorted().joined(separator: ","), privacy: .public)")
        case .refused(let why): log.notice("about you: refused (\(why, privacy: .public))")
        case .retry: log.notice("about you: will retry")
        }
        return outcome
    }

    /// The welcome's source step: whether to show it, and the creator code field in it.
    struct WelcomeNeeds: Equatable {
        let source: Bool
        let creator: Bool
        let via: CreatorCode.Via
    }

    static func welcomeNeeds(auth: AuthStore) async -> WelcomeNeeds {
        guard let member = auth.activeId else { return WelcomeNeeds(source: true, creator: false, via: .signup) }
        let api = LiaAPI(auth: auth, account: member)
        let rec = await api.memberRecord()
        let source = AboutYou.welcomeAsksSource(customFields: AboutYou.customFields(rec), local: local(member: member))
        var creator = CreatorCodeSync.pending(auth: auth) == nil
        if creator, case .code = await api.creatorCode() { creator = false }
        // the record unread: an account in the welcome is most likely new
        let via = rec == nil ? CreatorCode.Via.signup : AboutYou.creatorVia(createdAt: AboutYou.createdAt(rec), now: Date())
        return WelcomeNeeds(source: source, creator: creator, via: via)
    }

    struct Ask: Equatable {
        let fields: [String]
        /// show the creator code field (no code on the account, none waiting)
        let creator: Bool
        let via: CreatorCode.Via
    }

    /// What to ask the active member now, or nil: nothing missing, snoozed, or Memberstack not read.
    static func check(auth: AuthStore) async -> Ask? {
        guard let member = auth.activeId, auth.phase == .signedIn, !auth.sessionExpired else { return nil }
        await flush(auth: auth)
        if AboutYou.isSnoozed(local(member: member), now: Date()) { return nil }
        let api = LiaAPI(auth: auth, account: member)
        guard let rec = await api.memberRecord(), let cf = AboutYou.customFields(rec) else { return nil }
        var ask = AboutYou.toAsk(missing: AboutYou.missing(cf), local: local(member: member), now: Date())
        guard auth.activeId == member else { return nil }
        // a role this Mac already knows fills type-of-market without a question
        let silent = AboutYou.silent(toAsk: ask, role: AccountPrefsSync.role(member: member))
        if !silent.isEmpty {
            ask.removeAll { silent[$0] != nil }
            await answer(silent, creatorCode: nil, via: .settings, auth: auth)
        }
        guard !ask.isEmpty, auth.activeId == member else { return nil }
        var creator = CreatorCodeSync.pending(auth: auth) == nil
        if creator, case .code = await api.creatorCode() { creator = false }
        return Ask(fields: ask, creator: creator, via: AboutYou.creatorVia(createdAt: AboutYou.createdAt(rec), now: Date()))
    }
}
