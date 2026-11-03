import Foundation

enum AuthError: Error, Equatable {
    case invalidEmail
    case emailNotFound
    case invalidCode
    /// Email + password: Memberstack's `invalid-credentials` (a wrong password, or an account without a password).
    case wrongPassword
    case rateLimited
    case network
    case sessionExpired
    case server(String)

    // UI strings: English only.
    var message: String {
        switch self {
        case .invalidEmail: return "Enter a valid email address."
        case .emailNotFound: return "No Liaison account uses this email."
        case .invalidCode: return "That code is not right or has expired."
        case .wrongPassword: return "The email or password is not right. If this account signs in with Google, Apple or an email code, use that instead."
        case .rateLimited: return "Too many attempts. Wait a minute and try again."
        case .network: return "Could not reach Liaison. Check your connection."
        case .sessionExpired: return "Your session ended. Sign in again."
        case .server(let code):
            // A server hint is a sentence; a bare code gets a neutral wrapper, never "Sign in failed".
            return code.contains(" ") && !code.hasPrefix("HTTP") ? code : "Something went wrong (\(code))."
        }
    }
}

struct AuthAPI {
    var session: URLSession = .shared

    /// Memberstack emails a 6 digit code. Same call the website makes.
    func sendCode(email: String) async throws {
        let (status, json) = try await post(
            AppConfig.memberstackClient + "/auth/passwordless/login/send",
            body: ["email": email],
            headers: ["X-API-Key": AppConfig.memberstackPublicKey])
        let ok = ((json["data"] as? [String: Any])?["success"] as? Bool) == true
        if status == 200 && ok { return }
        throw Self.mapError(status: status, json: json)
    }

    /// The landing's first call for an email: Memberstack's SIGNUP code. An email that already has an account
    /// answers with an "already in use" error, and the landing then sends the login code (`sendCode`).
    func sendSignupCode(email: String) async throws -> MacSignIn.SignupSend {
        let (status, json) = try await post(
            AppConfig.memberstackClient + "/auth/passwordless/signup/send",
            body: ["email": email],
            headers: ["X-API-Key": AppConfig.memberstackPublicKey])
        let r = MacSignIn.signupSend(status: status, json: json)
        if r == .failed { throw Self.mapError(status: status, json: json) }
        return r
    }

    /// SignupMemberPasswordless, as the landing calls it: the emailed code, the Free plan and the
    /// "How did you hear about Liaison?" answer in `acquisition-source`. Returns the new member's token. An email that
    /// turned out to have an account meanwhile signs in with the same code, like the landing.
    func signup(email: String, code: String, source: String?) async throws -> String {
        let (status, json) = try await post(
            AppConfig.memberstackClient + "/auth/signup?isPasswordless=true",
            body: MacSignIn.signupBody(email: email, code: code, source: source),
            headers: ["X-API-Key": AppConfig.memberstackPublicKey])
        if status == 200, let token = MacSignIn.accessToken(json) { return token }
        if MacSignIn.isExistingEmail(status: status, json: json) { return try await login(email: email, code: code) }
        throw Self.mapError(status: status, json: json)
    }

    /// Returns the Memberstack member token (14 days).
    func login(email: String, code: String) async throws -> String {
        let (status, json) = try await post(
            AppConfig.memberstackClient + "/auth/passwordless/login",
            body: ["email": email, "passwordlessToken": code],
            headers: ["X-API-Key": AppConfig.memberstackPublicKey])
        let token = ((json["data"] as? [String: Any])?["tokens"] as? [String: Any])?["accessToken"] as? String
        if status == 200, let token, !token.isEmpty { return token }
        throw Self.mapError(status: status, json: json)
    }

    /// Email + password (Memberstack's own login), for accounts that have a password, such as the account Apple's
    /// reviewers use. Returns the member token like the code login.
    func login(email: String, password: String) async throws -> String {
        let (status, json) = try await post(
            AppConfig.memberstackClient + "/auth/login",
            body: ["email": email, "password": password],
            headers: ["X-API-Key": AppConfig.memberstackPublicKey])
        let token = ((json["data"] as? [String: Any])?["tokens"] as? [String: Any])?["accessToken"] as? String
        if status == 200, let token, !token.isEmpty { return token }
        // A wrong password read "Something went wrong (invalid-credentials)."
        switch MacSignIn.passwordFailure(status: status, json: json) {
        case .wrongPassword: throw AuthError.wrongPassword
        case .rateLimited: throw AuthError.rateLimited
        case .network: throw AuthError.network
        case .other(let m): throw AuthError.server(m)
        }
    }

    /// Exchanges the member token for a 15 minute lsess_ at the existing meta-mcp endpoint.
    func mintSession(memberToken: String) async throws -> String {
        let (status, json) = try await post(
            AppConfig.mcpBase + "/auth/session",
            body: nil,
            headers: ["Authorization": "Bearer \(memberToken)"])
        if status == 401 { throw AuthError.sessionExpired }
        if status == 200, (json["ok"] as? Bool) == true, let t = json["session_token"] as? String, t.hasPrefix("lsess_") {
            return t
        }
        throw Self.mapError(status: status, json: json)
    }

    /// QR sign-in (meta-mcp /auth/qr/*). No session on either call: the poll proves itself with the ticket's
    /// poll secret, which only this Mac holds. Raw (status, json); Shared/Core/QRSignIn.swift reads them.
    func qrStart(device: String) async throws -> (Int, [String: Any]) {
        try await post(AppConfig.mcpBase + "/auth/qr/start", body: ["client": "mac", "device": device], headers: [:])
    }

    func qrPoll(code: String, poll: String) async throws -> (Int, [String: Any]) {
        try await post(AppConfig.mcpBase + "/auth/qr/poll", body: ["code": code, "poll": poll], headers: [:])
    }

    /// Sign in with Apple (meta-mcp /auth/apple/*). Collect proves itself with this Mac's verifier; link carries
    /// the member token of the sign-in that just finished. Raw (status, json); Shared/Core/AppleSignIn.swift reads them.
    func appleCollect(code: String, verifier: String) async throws -> (Int, [String: Any]) {
        try await post(AppConfig.mcpBase + "/auth/apple/collect", body: ["code": code, "verifier": verifier, "app": "mac"], headers: [:])
    }

    func appleLink(link: String, memberToken: String) async throws -> (Int, [String: Any]) {
        try await post(AppConfig.mcpBase + "/auth/apple/link", body: ["link": link], headers: ["Authorization": "Bearer \(memberToken)"])
    }

    /// Continue with Google (meta-mcp /auth/google/*), Apple's shape: collect proves itself with this Mac's verifier;
    /// link carries the member token of the sign-in that just finished. Raw (status, json); MacSignIn reads them.
    func googleCollect(code: String, verifier: String) async throws -> (Int, [String: Any]) {
        try await post(AppConfig.mcpBase + "/auth/google/collect", body: ["code": code, "verifier": verifier, "app": "mac"], headers: [:])
    }

    func googleLink(link: String, memberToken: String) async throws -> (Int, [String: Any]) {
        try await post(AppConfig.mcpBase + "/auth/google/link", body: ["link": link], headers: ["Authorization": "Bearer \(memberToken)"])
    }

    /// An existing account's Google round that answered code_required: Memberstack's emailed code finishes it
    /// (the server signs in, seals its password and maps Google, once); `googleResend` mails a new code.
    func googleFinish(link: String, code: String) async throws -> (Int, [String: Any]) {
        try await post(AppConfig.mcpBase + "/auth/google/finish", body: ["link": link, "code": code], headers: [:])
    }

    func googleResend(link: String) async throws -> (Int, [String: Any]) {
        try await post(AppConfig.mcpBase + "/auth/google/code", body: ["link": link], headers: [:])
    }

    /// Settings > Google: whether Google signs this account in, and Disconnect. The member token proves the account.
    func googleStatus(memberToken: String) async throws -> (Int, [String: Any]) {
        try await post(AppConfig.mcpBase + "/auth/google/status", body: [:], headers: ["Authorization": "Bearer \(memberToken)"])
    }

    func googleUnlink(memberToken: String) async throws -> (Int, [String: Any]) {
        try await post(AppConfig.mcpBase + "/auth/google/unlink", body: [:], headers: ["Authorization": "Bearer \(memberToken)"])
    }

    /// Settings > Email > Update (meta-mcp /auth/email/*): a code to the new address, then confirm; cancel puts the
    /// old address back. Raw (status, json); Shared/Core/AccountActions.swift reads them.
    func emailStart(memberToken: String, email: String) async throws -> (Int, [String: Any]) {
        try await post(AppConfig.mcpBase + "/auth/email/start", body: ["email": email], headers: ["Authorization": "Bearer \(memberToken)"])
    }

    func emailConfirm(memberToken: String, code: String) async throws -> (Int, [String: Any]) {
        try await post(AppConfig.mcpBase + "/auth/email/confirm", body: ["code": code], headers: ["Authorization": "Bearer \(memberToken)"])
    }

    func emailCancel(memberToken: String) async throws -> (Int, [String: Any]) {
        try await post(AppConfig.mcpBase + "/auth/email/cancel", body: [:], headers: ["Authorization": "Bearer \(memberToken)"])
    }

    /// (the fallback page): Continue with Google: the one-time code from liaison://auth/handoff, proved with this Mac's verifier.
    func handoffCollect(code: String, verifier: String) async throws -> (Int, [String: Any]) {
        try await post(AppConfig.mcpBase + "/auth/handoff/collect", body: ["code": code, "verifier": verifier], headers: [:])
    }

    static func mapError(status: Int, json: [String: Any]) -> AuthError {
        let code = MacSignIn.errorParts(json).code
        if code == "passwordless-email-not-found" { return .emailNotFound }
        if code.hasPrefix("invalid-passwordless") || code.contains("passwordless-token") { return .invalidCode }
        if status == 429 { return .rateLimited }
        if status == 0 || status >= 500 { return .network }
        return .server(code.isEmpty ? "HTTP \(status)" : code)
    }

    private func post(_ urlString: String, body: [String: Any]?, headers: [String: String]) async throws -> (Int, [String: Any]) {
        guard let url = URL(string: urlString) else { throw AuthError.network }
        var req = URLRequest(url: url, timeoutInterval: 20)
        LiaClient.stamp(&req)   // X-Lia-Client, our hosts only
        req.httpMethod = "POST"
        headers.forEach { req.setValue($0.value, forHTTPHeaderField: $0.key) }
        if let body {
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
        do {
            let (data, resp) = try await session.data(for: req)
            let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
            let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
            return (status, json)
        } catch {
            throw AuthError.network
        }
    }
}
