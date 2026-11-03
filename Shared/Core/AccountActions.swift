import Foundation

/// ("we remove the web from public today; the web must have nothing to do with it"): Settings >
/// Profile's Email Update and Google Connect / Disconnect, native. They opened liaisone.com/new#settings/general, where
/// only the site's Memberstack SDK could do them. The server's half is the web repo meta-mcp
/// /auth/email/{start,confirm,cancel} and /auth/google/{status,unlink} (+ the Google round with intent=link and
/// /auth/google/link). Pure rules only: what to send, how to read each answer.
enum AccountActions {
    // MARK: email change

    static func normalized(_ email: String) -> String { email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }

    static func looksValid(_ email: String) -> Bool {
        normalized(email).range(of: #"^[^\s@<>]{1,64}@[^\s@<>]{1,190}\.[^\s@<>.]{2,}$"#, options: .regularExpression) != nil
    }

    /// Whether Update may send: a valid address that is not the current one.
    static func canSend(new: String, current: String) -> Bool { looksValid(new) && normalized(new) != normalized(current) }

    /// The code field keeps digits only, at most six; six digits confirm by themselves.
    static func codeDigits(_ s: String) -> String { String(s.filter { $0.isASCII && $0.isNumber }.prefix(6)) }

    enum Start: Equatable {
        /// Memberstack mailed its code to the new address (the change stands once the code is entered, 10 minutes)
        case codeSent(email: String)
        case failed(String)
    }

    /// `POST /auth/email/start {email}`.
    static func start(status: Int, json: [String: Any]) -> Start {
        if status == 200, (json["ok"] as? Bool) == true, (json["state"] as? String) == "code_sent", let e = json["email"] as? String, !e.isEmpty {
            return .codeSent(email: e.lowercased())
        }
        return .failed(message(json, status: status, fallback: "The email could not be changed. Try again."))
    }

    enum Confirm: Equatable {
        /// changed; `memberToken`: a fresh token for the same member, when the server sent one
        case changed(email: String, memberToken: String?)
        /// a wrong code: type it again
        case retry(String)
        /// over (expired, five wrong codes): the old email is back; start again
        case restart(String)
        case failed(String)
    }

    /// `POST /auth/email/confirm {code}`.
    static func confirm(status: Int, json: [String: Any]) -> Confirm {
        if status == 200, (json["ok"] as? Bool) == true, (json["state"] as? String) == "changed", let e = json["email"] as? String, !e.isEmpty {
            let t = (json["member_token"] as? String).flatMap { $0.hasPrefix("ey") && $0.split(separator: ".").count == 3 ? $0 : nil }
            return .changed(email: e.lowercased(), memberToken: t)
        }
        if status == 400 || status == 429 { return .retry(message(json, status: status, fallback: "That code is not right or has expired.")) }
        if status == 410 { return .restart(message(json, status: status, fallback: "This change has expired. Your email was not changed.")) }
        return .failed(message(json, status: status, fallback: "The email could not be changed. Try again."))
    }

    /// A token handed back after a change replaces the stored one only when it is the same member's.
    static func adoptsToken(_ token: String?, activeMember: String?) -> Bool {
        guard let token, let activeMember, let id = MemberToken.memberId(from: token) else { return false }
        return id == activeMember
    }

    // MARK: Google in Settings

    struct GoogleState: Equatable {
        let connected: Bool
        let email: String
    }

    /// `POST /auth/google/status`: nil when the server did not say (the row falls back to Memberstack's providers).
    static func googleStatus(status: Int, json: [String: Any]) -> GoogleState? {
        guard status == 200, (json["ok"] as? Bool) == true, let c = json["connected"] as? Bool else { return nil }
        return GoogleState(connected: c, email: c ? ((json["google_email"] as? String) ?? "").lowercased() : "")
    }

    /// `POST /auth/google/unlink`: nil when Google no longer signs this account in, else what to say.
    static func unlinkMessage(status: Int, json: [String: Any]) -> String? {
        if status == 200, (json["ok"] as? Bool) == true, ["unlinked", "not_connected"].contains(json["state"] as? String ?? "") { return nil }
        return message(json, status: status, fallback: "Google could not be disconnected. Try again.")
    }

    /// `POST /auth/google/link` after Settings' Connect round: nil when connected, else the server's sentence (an email
    /// that is not the account's: "This Google account uses ..., not ...").
    static func connectMessage(status: Int, json: [String: Any]) -> String? {
        if status == 200, (json["ok"] as? Bool) == true, (json["state"] as? String) == "linked" { return nil }
        return message(json, status: status, fallback: "Google could not be connected. Try again.")
    }

    /// What Settings says when the Connect round's browser answered with an error word (nil: cancelled, say nothing).
    static func connectError(_ word: String) -> String? {
        switch word {
        case "cancelled": return nil
        case "email_unverified": return "Google did not confirm that account's email, so it cannot be connected."
        case "no_email": return "Google did not share an email. Try again."
        case "busy": return "Too many attempts right now. Try again in a minute."
        case "expired": return "This took too long. Choose Connect again."
        case "unavailable": return "Connecting Google is not available right now."
        default: return "Google could not be connected. Try again."
        }
    }

    private static func message(_ json: [String: Any], status: Int, fallback: String) -> String {
        if let m = json["user_message"] as? String, !m.isEmpty { return m }
        if status == 429 { return "Too many attempts. Wait a minute and try again." }
        if status == 401 { return "Your session ended. Sign in again." }
        if status == 0 { return "Could not reach Liaison. Check your connection." }
        return fallback
    }
}
