import Foundation

/// Sign in with Apple through Apple's WEB flow (Services ID com.liaisone.signin; native Sign in with Apple is
/// not available to a Developer ID app). The server half is meta-mcp `/auth/apple/*` in the web repo.
///
/// The app makes a verifier (32 random bytes), opens
/// `https://mcp.liaisone.com/auth/apple/start?app=mac&cc=<b64url sha256(verifier)>` in a real browser that is not
/// Liaison (no ASWebAuthenticationSession, which reached Liaison itself when it is the default browser), and
/// gets back `liaison://auth/apple?code=<one-time>` (or `?error=`) through the sign-in screen's onOpenURL. It POSTs `/auth/apple/collect`
/// {code, verifier, app: "mac"} and receives the member's ordinary Memberstack token, which signs in exactly like an
/// email code (AuthStore.finish -> /auth/session). An email that already has a Liaison account answers with a pending
/// link instead: the person signs in once with an email code and the app POSTs `/auth/apple/link` with that token.
/// Pure parts only; the hashing (CryptoKit) and the session live in App/Auth, the network in Shared/Auth.
enum AppleSignIn {
    /// The app's own URL scheme: "liaison" for the release, "liaison-dev" for a local build (Info.plist LiaURLScheme,
    /// from the LIA_URL_SCHEME build setting), so a sign-in started in Liaison Dev comes back to Liaison Dev and not
    /// to the installed Liaison.
    static var callbackScheme: String {
        let s = (Bundle.main.object(forInfoDictionaryKey: "LiaURLScheme") as? String) ?? ""
        return s.isEmpty || s.hasPrefix("$(") ? "liaison" : s.lowercased()
    }

    enum Callback: Equatable {
        case code(String)
        case error(String)
        /// Not ours (another liaison:// address) or malformed.
        case unrelated
    }

    enum Collect: Equatable {
        case signedIn(memberToken: String, email: String)
        case linkRequired(link: String, email: String, message: String)
        case failed(String)
    }

    /// 43 characters of base64url: 32 random bytes, the shape of every secret in this flow.
    static func isTokenLike(_ s: String) -> Bool {
        s.count == 43 && s.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") }
    }

    static func base64url(_ data: Data) -> String {
        data.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    static func startURL(base: String, challenge: String) -> URL? {
        guard isTokenLike(challenge), var c = URLComponents(string: base + "/auth/apple/start") else { return nil }
        c.queryItems = [URLQueryItem(name: "app", value: "mac"), URLQueryItem(name: "cc", value: challenge)]
        if callbackScheme != "liaison" { c.queryItems?.append(URLQueryItem(name: "scheme", value: callbackScheme)) }
        return c.url
    }

    /// `liaison://auth/apple?code=...` / `?error=...`.
    static func callback(_ url: URL) -> Callback {
        guard url.scheme?.lowercased() == callbackScheme, url.host?.lowercased() == "auth", url.path == "/apple",
              let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems else { return .unrelated }
        if let code = items.first(where: { $0.name == "code" })?.value, isTokenLike(code) { return .code(code) }
        if let e = items.first(where: { $0.name == "error" })?.value, !e.isEmpty,
           e.count <= 64, e.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_" || $0 == "-") }) {
            return .error(e)
        }
        return .unrelated
    }

    /// What the sign-in screen says for an `error=` (nil: say nothing, the person cancelled). English only.
    static func message(forError e: String) -> String? {
        switch e {
        case "cancelled": return nil
        case "unavailable": return "Sign in with Apple is not available right now. Use your email."
        case "email_unverified": return "Apple did not confirm this email. Use your email."
        case "no_email": return "Apple did not share an email. Try again and keep the email shared."
        case "busy": return "Too many sign-ins right now. Try again in a minute."
        case "expired": return "This sign-in has expired. Try again."
        default: return "Sign in with Apple did not finish. Try again."
        }
    }

    /// `POST /auth/apple/collect`.
    static func collect(status: Int, json: [String: Any]) -> Collect {
        let msg = (json["user_message"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        if status == 429 { return .failed(msg ?? "Too many attempts. Wait a minute and try again.") }
        guard status == 200, (json["ok"] as? Bool) == true else {
            if status == 410 { return .failed(msg ?? "This sign-in has expired. Try again.") }
            return .failed(msg ?? "Sign in with Apple did not finish. Try again.")
        }
        let email = (json["email"] as? String) ?? ""
        switch json["state"] as? String {
        case "signed_in":
            if let t = json["member_token"] as? String, t.hasPrefix("ey"), t.split(separator: ".").count == 3 {
                return .signedIn(memberToken: t, email: email)
            }
        case "link_required":
            if let l = json["link"] as? String, isTokenLike(l) {
                return .linkRequired(link: l, email: email,
                                     message: msg ?? "This email already has a Liaison account. Sign in once with your email to connect Apple.")
            }
        default: break
        }
        return .failed("Sign in with Apple did not finish. Try again.")
    }

    /// `POST /auth/apple/link`: nil when Apple is now connected, else what to tell the person.
    static func linkMessage(status: Int, json: [String: Any]) -> String? {
        if status == 200, (json["ok"] as? Bool) == true, (json["state"] as? String) == "linked" { return nil }
        if let m = json["user_message"] as? String, !m.isEmpty { return m }
        return "Apple could not be connected. You are signed in."
    }
}
