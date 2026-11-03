import Foundation

/// (creators program): the creator code a new member brings. The site's half is the web repo
/// backend/workers/lia-agents-creators.js: `GET /creators/code?code=X` (public: is it a code) -> {ok, valid},
/// `POST /agents/creator-code {code, via}` -> {ok, code} | {ok:false, error: unknown_code|already_set|bad_code},
/// `GET /agents/creator-code` -> {ok, code|null}. The first code a member sends wins (the server's record is
/// write-once); the app only asks once it knows the account and keeps a code it could not deliver until it is.
enum CreatorCode {
    static let maxLength = 20
    static let minLength = 3

    /// Uppercase as typed; only A-Z and 0-9 (ASCII), at most 20.
    static func normalize(_ raw: String) -> String {
        String(raw.uppercased().filter { $0.isASCII && ($0.isLetter || $0.isNumber) }.prefix(maxLength))
    }

    /// The server's shape for a code: 3 to 20 of A-Z 0-9.
    static func isWellFormed(_ code: String) -> Bool {
        (minLength...maxLength).contains(code.count) && normalize(code) == code
    }

    // MARK: the inline check

    enum Check: Equatable {
        /// nothing typed
        case empty
        /// the lookup is pending (debounce or network)
        case checking
        case found
        /// the server does not know it, or it cannot be a code (too short): not sent, sign-up goes on
        case unknown
        /// the lookup failed (offline, rate limited, a server error): the code is kept and sent; the server decides
        case unverified
    }

    /// What needs no network: nil means ask the server.
    static func localCheck(_ code: String) -> Check? {
        if code.isEmpty { return .empty }
        if !isWellFormed(code) { return .unknown }
        return nil
    }

    /// `GET /creators/code?code=X`.
    static func check(status: Int, json: JSONObject?) -> Check {
        guard status == 200, JSONRead.bool(json, "ok"), let valid = json?["valid"] as? Bool else { return .unverified }
        return valid ? .found : .unknown
    }

    /// The inline line under the field (nil: say nothing).
    static func label(_ c: Check) -> String? {
        switch c {
        case .found: return "Code found"
        case .unknown: return "We don't know this code"
        case .empty, .checking, .unverified: return nil
        }
    }

    /// The code to deliver after the sign-up, or nil: an unknown or malformed code is not sent; a code still being
    /// checked or one the lookup could not reach is (the server decides).
    static func toSend(_ code: String, _ c: Check) -> String? {
        let n = normalize(code)
        guard isWellFormed(n) else { return nil }
        switch c {
        case .unknown, .empty: return nil
        case .found, .checking, .unverified: return n
        }
    }

    // MARK: delivering it (POST /agents/creator-code)

    enum Via: String, Codable, Equatable { case signup, settings }

    enum SendOutcome: Equatable {
        /// saved on the account (the server's code, uppercase)
        case saved(String?)
        /// the server said no for good: unknown_code, already_set, bad_code (or another 4xx, as http_N)
        case refused(String)
        /// try again later (offline, the session, 404 while the route is not live, 429, 5xx)
        case retry
    }

    static let refusals: Set<String> = ["unknown_code", "already_set", "bad_code"]

    /// status 0 / json nil: no answer.
    static func sendOutcome(status: Int, json: JSONObject?) -> SendOutcome {
        if let e = JSONRead.string(json, "error"), refusals.contains(e), !JSONRead.bool(json, "ok") { return .refused(e) }
        if status == 200, JSONRead.bool(json, "ok") {
            let c = JSONRead.string(json, "code").map(normalize).flatMap { $0.isEmpty ? nil : $0 }
            return .saved(c)
        }
        if status == 0 || status == 401 || status == 404 || status == 408 || status == 429 || status >= 500 { return .retry }
        if (400..<500).contains(status) { return .refused("http_\(status)") }
        return .retry
    }

    /// Settings' line after Apply (nil: saved, nothing to say). `already_set` shows the saved code instead.
    static func applyMessage(_ o: SendOutcome) -> String? {
        switch o {
        case .saved: return nil
        case .refused("unknown_code"): return "We don't know this code"
        case .refused("bad_code"): return "A code is 3 to 20 letters and digits."
        case .refused("already_set"): return nil
        case .refused: return "This code could not be saved."
        case .retry: return "Could not save the code. Try again."
        }
    }

    enum Saved: Equatable {
        case code(String)
        case none
        case failed
    }

    /// `GET /agents/creator-code`.
    static func saved(status: Int, json: JSONObject?) -> Saved {
        guard status == 200, JSONRead.bool(json, "ok") else { return .failed }
        guard let c = JSONRead.string(json, "code").map(normalize), !c.isEmpty else {
            return json?["code"] == nil || json?["code"] is NSNull ? .none : .failed
        }
        return .code(c)
    }

    // MARK: the pending code (UserDefaults, one per member)

    struct Pending: Codable, Equatable {
        let code: String
        let via: Via
        let at: Date
    }

    static func pendingKey(member: String) -> String { "lia_creator_code_pending_" + member }

    /// A code waits this long for its account; then it is dropped (the person can still enter it in Settings).
    static let pendingLifetime: TimeInterval = 60 * 24 * 3600

    static func encode(_ p: Pending) -> Data? { try? JSONEncoder().encode(p) }

    static func decode(_ d: Data?) -> Pending? {
        guard let d, let p = try? JSONDecoder().decode(Pending.self, from: d), isWellFormed(p.code) else { return nil }
        return p
    }

    /// Whether to send a pending code now (else drop it).
    static func keeps(_ p: Pending, now: Date) -> Bool {
        let age = now.timeIntervalSince(p.at)
        return age > -3600 && age < pendingLifetime
    }

    /// After a send: keep the pending code only when the answer says try again.
    static func keepsAfter(_ o: SendOutcome) -> Bool { o == .retry }
}
