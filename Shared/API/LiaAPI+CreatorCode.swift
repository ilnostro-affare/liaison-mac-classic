import Foundation

// (creators program): the creator code. Routes on lia-agents (the site's
// backend/workers/lia-agents-creators.js); the rules are in Shared/Core/CreatorCode.swift.
extension LiaAPI {
    /// `POST|GET /agents/creator-code` with this account's session: the status and the JSON, any status. nil: no
    /// answer (offline, or the session could not be had: the caller retries later).
    private func creatorCodeCall(_ method: String, body: [String: Any]? = nil) async -> (Int, JSONObject?)? {
        guard let url = URL(string: AppConfig.agentsBase + "/agents/creator-code") else { return nil }
        for attempt in 0..<2 {
            guard let token = try? await token(forceRefresh: attempt == 1) else { return nil }
            var req = URLRequest(url: url, timeoutInterval: 15)
            LiaClient.stamp(&req)
            req.httpMethod = method
            req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            if let body {
                req.setValue("application/json", forHTTPHeaderField: "Content-Type")
                req.httpBody = try? JSONSerialization.data(withJSONObject: body)
            }
            guard let result = try? await session.data(for: req) else { return nil }
            let status = (result.1 as? HTTPURLResponse)?.statusCode ?? 0
            if status == 401 && attempt == 0 { continue }
            return (status, JSONRead.object(result.0))
        }
        return nil
    }

    /// The code saved on this account, none, or failed.
    func creatorCode() async -> CreatorCode.Saved {
        guard let r = await creatorCodeCall("GET") else { return .failed }
        return CreatorCode.saved(status: r.0, json: r.1)
    }

    /// Saves the code on this account (the first one wins on the server).
    func applyCreatorCode(_ code: String, via: CreatorCode.Via) async -> CreatorCode.SendOutcome {
        guard let r = await creatorCodeCall("POST", body: ["code": CreatorCode.normalize(code), "via": via.rawValue]) else { return .retry }
        return CreatorCode.sendOutcome(status: r.0, json: r.1)
    }
}

/// `GET /creators/code?code=X`: public, no session (the sign-up asks before the account exists).
enum CreatorCodeLookup {
    static func check(_ code: String) async -> CreatorCode.Check {
        if let local = CreatorCode.localCheck(code) { return local }
        guard var c = URLComponents(string: AppConfig.agentsBase + "/creators/code") else { return .unverified }
        c.queryItems = [URLQueryItem(name: "code", value: code)]
        guard let url = c.url else { return .unverified }
        var req = URLRequest(url: url, timeoutInterval: 8)
        LiaClient.stamp(&req)
        guard let r = try? await URLSession.shared.data(for: req) else { return .unverified }
        return CreatorCode.check(status: (r.1 as? HTTPURLResponse)?.statusCode ?? 0, json: JSONRead.object(r.0))
    }
}

/// The code a sign-up brought, delivered once the account's session is up; kept per member in UserDefaults until the
/// server saved or refused it, and tried again on the next launch (SignedInRoot) or when Settings opens.
@MainActor
enum CreatorCodeSync {
    private static var inFlight: Set<String> = []

    static func enqueue(_ code: String, via: CreatorCode.Via, member: String) {
        let n = CreatorCode.normalize(code)
        guard CreatorCode.isWellFormed(n), let d = CreatorCode.encode(CreatorCode.Pending(code: n, via: via, at: Date())) else { return }
        UserDefaults.standard.set(d, forKey: CreatorCode.pendingKey(member: member))
    }

    /// The active account's pending code, if any (Settings shows it while it waits).
    static func pending(auth: AuthStore) -> CreatorCode.Pending? {
        guard let m = auth.activeId else { return nil }
        return CreatorCode.decode(UserDefaults.standard.data(forKey: CreatorCode.pendingKey(member: m)))
    }

    /// Sends the active account's pending code, once at a time. The outcome, nil when nothing was sent.
    @discardableResult
    static func flush(auth: AuthStore) async -> CreatorCode.SendOutcome? {
        guard let member = auth.activeId, auth.phase == .signedIn, !auth.sessionExpired, !inFlight.contains(member) else { return nil }
        let key = CreatorCode.pendingKey(member: member)
        let defaults = UserDefaults.standard
        guard let raw = defaults.data(forKey: key) else { return nil }
        guard let p = CreatorCode.decode(raw), CreatorCode.keeps(p, now: Date()) else {
            defaults.removeObject(forKey: key)
            return nil
        }
        inFlight.insert(member)
        defer { inFlight.remove(member) }
        let outcome = await LiaAPI(auth: auth, account: member).applyCreatorCode(p.code, via: p.via)
        if !CreatorCode.keepsAfter(outcome) { defaults.removeObject(forKey: key) }
        return outcome
    }
}
