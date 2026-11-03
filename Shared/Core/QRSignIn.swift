import Foundation

/// Sign in with a phone (or another browser) that is already signed in on liaisone.com.
/// The server side is meta-mcp `/auth/qr/{start,poll}`: start gives a code (drawn as a QR of
/// `https://liaisone.com/qr#<code>`), a 6-character short code for typing, and a poll secret that never leaves the Mac.
/// An approved poll carries the approver's Memberstack member token, which the app then signs in with exactly like
/// an email-code login (AuthStore.finish → /auth/session). Pure parts only: the view and the network live in App/Auth
/// and Shared/Auth.
enum QRSignIn {
    /// How often the Mac asks whether the phone answered.
    static let pollInterval: TimeInterval = 1.5
    static let siteHost = "liaisone.com"

    struct Ticket: Equatable {
        let code: String
        let poll: String
        let short: String
        let expiresIn: TimeInterval
        let startedAt: Date

        func expiresAt() -> Date { startedAt.addingTimeInterval(expiresIn) }
        func isExpired(now: Date) -> Bool { now >= expiresAt() }
        /// Whole seconds left, never negative (the countdown under the QR).
        func secondsLeft(now: Date) -> Int { max(0, Int((expiresAt().timeIntervalSince(now)).rounded(.up))) }
        /// What the QR encodes. The code is in the fragment, so it never reaches a server log.
        var payload: String { QRSignIn.payload(code: code) }
    }

    enum PollResult: Equatable {
        case pending
        case approved(memberToken: String, email: String)
        case denied
        /// Expired or already used: draw a new code.
        case expired
        case rateLimited
        /// A network hiccup or a server error: keep polling.
        case retry
    }

    static func isCodeLike(_ s: String) -> Bool {
        (40...64).contains(s.count) && s.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") }
    }

    static func payload(code: String) -> String { "https://\(siteHost)/qr#\(code)" }

    /// "ABC234" → "ABC 234" for reading aloud and typing; the site's field ignores the space.
    static func displayShort(_ short: String) -> String {
        let s = Array(short.uppercased())
        guard s.count == 6 else { return short.uppercased() }
        return String(s[0..<3]) + " " + String(s[3..<6])
    }

    static func manualHint(short: String) -> String {
        "Or open \(siteHost)/qr and enter \(displayShort(short))"
    }

    /// `POST /auth/qr/start` → a ticket, or nil when the answer is not one.
    static func ticket(status: Int, json: [String: Any], now: Date) -> Ticket? {
        guard status == 200, (json["ok"] as? Bool) == true,
              let code = json["code"] as? String, isCodeLike(code),
              let poll = json["poll"] as? String, isCodeLike(poll),
              let short = json["short"] as? String, short.count == 6 else { return nil }
        let raw = json["expires_in"]
        let ttl = (raw as? Int).map(Double.init) ?? (raw as? Double) ?? (raw as? NSNumber)?.doubleValue ?? 120
        return Ticket(code: code, poll: poll, short: short.uppercased(), expiresIn: max(10, min(ttl, 600)), startedAt: now)
    }

    /// `POST /auth/qr/poll`.
    static func pollResult(status: Int, json: [String: Any]) -> PollResult {
        let state = json["state"] as? String ?? ""
        if status == 429 { return .rateLimited }
        if status == 404 || status == 410 { return state == "denied" ? .denied : .expired }
        // 403: the poll secret did not match - this ticket is not ours to wait on any more.
        if status == 403 || status == 400 { return .expired }
        guard status == 200, (json["ok"] as? Bool) == true else { return .retry }
        switch state {
        case "pending": return .pending
        case "denied": return .denied
        case "approved":
            guard let t = json["member_token"] as? String, t.hasPrefix("ey"), !t.isEmpty else { return .expired }
            return .approved(memberToken: t, email: (json["email"] as? String) ?? "")
        default: return .retry
        }
    }
}
