import Foundation

/// The sign-in screen's pure rules - the website's email signup (new vs existing email, the "how did you hear"
/// sources, the Free plan) and Continue with Google through the default browser. The site's half is
/// the web repo app.liaisone.io/index.html (the landing's email flow) and, for Google, meta-mcp
/// /auth/google/{start,callback,collect,link} (Google's own OAuth, the account chooser at once). The
/// route - app.liaisone.io/signin/mac/ (the Google page) and meta-mcp /auth/handoff/{deposit,collect} - is kept as the
/// fallback (`googleFlow = .page`), not the default.
enum MacSignIn {
    // MARK: email: the landing's order of calls

    /// The plan the landing's own signup attaches (`plans: [{planId}]` in signupMemberPasswordless).
    static let freePlan = "pln_free-example1"
    /// The Memberstack custom field the landing saves the answer in.
    static let sourceField = "acquisition-source"

    struct Source: Equatable, Identifiable {
        let id: String
        let label: String
    }

    /// The landing's chips, in its order, with its values (`data-source`). "Referral" is saved as `direct`, like the web.
    static let sources: [Source] = [
        Source(id: "google", label: "Google"),
        Source(id: "instagram", label: "Instagram"),
        Source(id: "chatgpt", label: "ChatGPT"),
        Source(id: "claude", label: "Claude"),
        Source(id: "direct", label: "Referral"),
        Source(id: "other", label: "Other"),
    ]

    /// What the signup call sends: an unknown or empty answer is saved as `other`, like the web's `src||'other'`.
    static func sourceValue(_ picked: String?) -> String {
        guard let p = picked, sources.contains(where: { $0.id == p }) else { return "other" }
        return p
    }

    /// Memberstack's error, wherever it sits: top level `{code, message}` or `{error: {code, message}}`.
    static func errorParts(_ json: [String: Any]) -> (code: String, message: String) {
        let e = json["error"] as? [String: Any]
        let code = (json["code"] as? String) ?? (e?["code"] as? String) ?? ""
        let message = (json["message"] as? String) ?? (e?["message"] as? String) ?? (json["error"] as? String) ?? ""
        return (code, message)
    }

    /// The landing's test for "this email already has an account": the error says `already` or `exists`
    /// (Memberstack's code for it is `email-already-in-use`).
    static func isExistingEmail(status: Int, json: [String: Any]) -> Bool {
        let p = errorParts(json)
        if p.code == "email-already-in-use" { return true }
        let m = (p.code + " " + p.message).lowercased()
        return m.contains("already") || m.contains("exists")
    }

    enum SignupSend: Equatable {
        /// A new email: the signup code is on its way; ask the source, then the code.
        case newMember
        /// The email has an account: send the login code instead (the landing skips the question for them).
        case existing
        case failed
    }

    /// `POST /auth/passwordless/signup/send`.
    static func signupSend(status: Int, json: [String: Any]) -> SignupSend {
        if status == 200, (json["data"] as? [String: Any]) != nil, errorParts(json).code.isEmpty, json["error"] == nil { return .newMember }
        if isExistingEmail(status: status, json: json) { return .existing }
        return .failed
    }

    /// The body of `POST /auth/signup?isPasswordless=true`, as signupMemberPasswordless sends it from the landing.
    static func signupBody(email: String, code: String, source: String?) -> [String: Any] {
        [
            "email": email,
            "passwordlessToken": code,
            "plans": [["planId": freePlan]],
            "customFields": [sourceField: sourceValue(source)],
            "origin_domain": "https://liaisone.com",
        ]
    }

    /// The member token in a Memberstack auth answer (`data.tokens.accessToken`).
    static func accessToken(_ json: [String: Any]) -> String? {
        let t = ((json["data"] as? [String: Any])?["tokens"] as? [String: Any])?["accessToken"] as? String
        guard let t, t.hasPrefix("ey"), t.split(separator: ".").count == 3 else { return nil }
        return t
    }

    // MARK: Google through the default browser

    static var callbackScheme: String { AppleSignIn.callbackScheme }
    /// A started browser round is kept this long in memory; a later link is ignored.
    static let pendingLifetime: TimeInterval = 10 * 60

    /// Which address Continue with Google opens. `.direct` (the default): meta-mcp's /auth/google/start, which
    /// sends the browser straight to Google's account chooser. `.page`: liaisone.com/signin/mac/ page and its
    /// Memberstack Google sign-in (the fallback; its answer is liaison://auth/handoff).
    enum GoogleFlow: Equatable { case direct, page }
    static let googleFlow: GoogleFlow = .direct

    /// Set on this Mac once the quiet link is refused with has_password (a member with a password of
    /// their own can never be signed in directly), so the next Continue with Google goes to the page at once: one
    /// account chooser instead of Google's, then the page's.
    static let pageFirstKey = "lia_google_page_first"
    /// ("the web must have nothing to do with it"): never the page any more; a member with a
    /// password of its own finishes with an emailed code in the app (`googleCodeRequired`). The key stays readable.
    static func flow(pageFirst: Bool) -> GoogleFlow { googleFlow }
    static func remembersPageFirst(_ outcome: LinkOutcome) -> Bool { outcome == .notLinked("has_password") }

    /// Https://mcp.liaisone.com/auth/google/start?cc=<b64url sha256(verifier)>&scheme=liaison|liaison-dev
    /// `&next=page` - an email that already has an account (link_required) is no longer sent
    /// back to this app (which came forward and showed "loading" while the browser waited); meta-mcp sends the browser
    /// on to the /signin/mac/ page with a one-time proof of this round's Google choice (`gf`), which hands over without
    /// a "Continue as" click when the browser's Liaison session is that very account. The app hears only the hand-over
    /// (liaison://auth/handoff, success) or an error. A server older than ignores `next` (way).
    /// (the web leaves the public): `&next=app` - no liaisone.com page at all. An email that
    /// already has an account this server holds no password for comes back as `code_required`: Memberstack has mailed
    /// its login code to the Google-verified address and the app asks for it (`googleCodeRequired`, /auth/google/finish).
    /// A server older than ignores `next=app` and answers link_required (the email code, then the quiet link).
    /// (no code - Memberstack's own Google login, its token straight into the app): `&next=ms`.
    /// An existing account the server holds no password for is sent by meta-mcp, in the browser, to its own standalone
    /// page (mcp.liaisone.com/auth/google/page, not liaisone.com): Memberstack's Google sign-in there, the member token
    /// deposited and handed over as liaison://auth/handoff (with the pending link: AuthStore links Google quietly, so the
    /// next Continue with Google signs in directly). The page's "Email me a code instead" comes back as
    /// liaison://auth/google -> `code_required`, code in the app. A server older than ignores `next=ms`
    /// and answers link_required (the email code, then the quiet link), as for next=app on an older server.
    static func googleStartURL(base: String, challenge: String, scheme: String = MacSignIn.callbackScheme) -> URL? {
        guard AppleSignIn.isTokenLike(challenge), var c = URLComponents(string: base + "/auth/google/start") else { return nil }
        c.queryItems = [URLQueryItem(name: "cc", value: challenge),
                        URLQueryItem(name: "scheme", value: scheme == "liaison-dev" ? "liaison-dev" : "liaison"),
                        URLQueryItem(name: "next", value: "ms")]
        return c.url
    }

    /// Settings > Profile > Google > Connect: the same Google round with `intent=link` - nothing is created and
    /// nobody signed in; collect answers `link_ready` and /auth/google/link (the member's token) connects it only when
    /// Google's verified email is the account's email.
    static func googleConnectURL(base: String, challenge: String, scheme: String = MacSignIn.callbackScheme) -> URL? {
        guard AppleSignIn.isTokenLike(challenge), var c = URLComponents(string: base + "/auth/google/start") else { return nil }
        c.queryItems = [URLQueryItem(name: "cc", value: challenge),
                        URLQueryItem(name: "scheme", value: scheme == "liaison-dev" ? "liaison-dev" : "liaison"),
                        URLQueryItem(name: "intent", value: "link")]
        return c.url
    }

    // MARK: an existing account's Google, finished in the app with Memberstack's emailed code

    struct CodeRequired: Equatable {
        let link: String
        let email: String
        /// false: Memberstack did not send it; the app offers Send code
        let sent: Bool
        let message: String
    }

    /// `POST /auth/google/collect` answering `code_required` (a server, the round started with next=app).
    static func googleCodeRequired(status: Int, json: [String: Any]) -> CodeRequired? {
        guard status == 200, (json["ok"] as? Bool) == true, (json["state"] as? String) == "code_required",
              let l = json["link"] as? String, AppleSignIn.isTokenLike(l) else { return nil }
        let email = ((json["email"] as? String) ?? "").lowercased()
        let msg = (json["user_message"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            ?? "This email already has a Liaison account. Enter the code we sent to finish signing in."
        return CodeRequired(link: l, email: email, sent: (json["sent"] as? Bool) ?? true, message: msg)
    }

    enum GoogleFinish: Equatable {
        case signedIn(memberToken: String, email: String, linked: Bool)
        /// a wrong code: type it again
        case retry(String)
        /// the round is over (expired, too many codes): start Continue with Google again
        case restart(String)
        case failed(String)
    }

    /// `POST /auth/google/finish {link, code}`.
    static func googleFinish(status: Int, json: [String: Any]) -> GoogleFinish {
        let msg = (json["user_message"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        if status == 200, (json["ok"] as? Bool) == true, (json["state"] as? String) == "signed_in",
           let t = json["member_token"] as? String, t.hasPrefix("ey"), t.split(separator: ".").count == 3 {
            return .signedIn(memberToken: t, email: ((json["email"] as? String) ?? "").lowercased(), linked: (json["linked"] as? Bool) == true)
        }
        if status == 400 { return .retry(msg ?? "That code is not right or has expired.") }
        if status == 410 || status == 403 { return .restart(msg ?? "This sign-in has expired. Choose Continue with Google again.") }
        if status == 429 { return .retry(msg ?? "Too many attempts. Wait a minute and try again.") }
        return .failed(msg ?? "Google sign-in did not finish. Try again.")
    }

    /// `POST /auth/google/collect` answering `link_ready` (Settings' Connect round): the link to hand /auth/google/link.
    static func googleConnectReady(status: Int, json: [String: Any]) -> (link: String, email: String)? {
        guard status == 200, (json["ok"] as? Bool) == true, (json["state"] as? String) == "link_ready",
              let l = json["link"] as? String, AppleSignIn.isTokenLike(l) else { return nil }
        return (l, ((json["email"] as? String) ?? "").lowercased())
    }

    /// Fallback: https://liaisone.com/signin/mac/?provider=google&cc=<b64url sha256(verifier)>
    /// `auto` (an existing member's Google, see `linkNext`) adds `auto=google` - the page starts Memberstack's
    /// Google sign-in by itself and says "Finishing Google sign-in..." - and `hint` adds `eh=` (`emailHintInput`, hashed),
    /// with which a browser already signed in to liaisone.com as that very email hands over without a click.
    /// A page older than ignores both and shows its Continue with Google button (one click); a page older than
    /// Ignores `scheme` too and always answers liaison:// (fine for the release, not for Liaison Dev).
    static func googleURL(site: String, challenge: String, scheme: String = MacSignIn.callbackScheme,
                          auto: Bool = false, hint: String? = nil) -> URL? {
        guard AppleSignIn.isTokenLike(challenge), var c = URLComponents(string: site + "/signin/mac/") else { return nil }
        c.queryItems = [URLQueryItem(name: "provider", value: "google"), URLQueryItem(name: "cc", value: challenge)]
        if scheme == "liaison-dev" { c.queryItems?.append(URLQueryItem(name: "scheme", value: "liaison-dev")) }
        if auto {
            c.queryItems?.append(URLQueryItem(name: "auto", value: "google"))
            if let h = hint, AppleSignIn.isTokenLike(h) { c.queryItems?.append(URLQueryItem(name: "eh", value: h)) }
        }
        return c.url
    }

    // MARK: an existing member's Google - the page finishes it, no email step

    /// What the sign-in does when the direct Google collect answers link_required (the email already has a Liaison
    /// account this server holds no password for: on liaisone.com it was made with Memberstack's own Google login).
    enum LinkNext: Equatable {
        /// Google: straight on to the /signin/mac/ page with `auto` (Memberstack's Google sign-in, usually one
        /// account-chooser click), then /auth/google/link with the new member token. Nothing to say.
        case page
        /// Apple (no Memberstack equivalent), or no page could be opened: way, sign in once with the email.
        case ask
    }

    static func linkNext(google: Bool, pageOpened: Bool) -> LinkNext { google && pageOpened ? .page : .ask }

    /// The text whose sha256 (b64url, as a PKCE challenge) is the page's `eh`: the round's challenge, a colon, the
    /// email (trimmed, lowercased). Bound to the round, so the hash means nothing outside it. nil: no email to hint.
    static func emailHintInput(challenge: String, email: String) -> String? {
        let e = email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard AppleSignIn.isTokenLike(challenge), !e.isEmpty, e.contains("@") else { return nil }
        return challenge + ":" + e
    }

    /// Whether a pending link (made `age` seconds ago for `pendingEmail`) belongs to the sign-in that just finished as
    /// `email`: within the server's 30 minutes (29, to be safe), and the same email when one is known.
    static func linkApplies(pendingEmail: String, email: String, age: TimeInterval) -> Bool {
        guard age >= -5, age < 29 * 60 else { return false }
        return pendingEmail.isEmpty || pendingEmail.lowercased() == email.lowercased()
    }

    enum LinkOutcome: Equatable {
        case linked
        /// Not connected; the word is for the log only (has_password, email_mismatch, expired, http_502...). The
        /// person is signed in either way and is told nothing.
        case notLinked(String)
    }

    /// `POST /auth/google/link` after the page's sign-in (the quiet link): linked, or why not, for the log.
    static func linkOutcome(status: Int, json: [String: Any]) -> LinkOutcome {
        if status == 200, (json["ok"] as? Bool) == true, (json["state"] as? String) == "linked" { return .linked }
        if let e = json["error"] as? String, !e.isEmpty, e.count <= 40,
           e.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_") }) { return .notLinked(e) }
        return .notLinked(status == 0 ? "network" : "http_\(status)")
    }

    enum Callback: Equatable {
        case code(String)
        case error(String)
        case unrelated
    }

    /// `liaison://auth/handoff?code=...` (or `?error=...`): page's answer.
    static func callback(_ url: URL) -> Callback { answer(url, path: "/handoff") }

    /// `liaison://auth/google?code=...` (or `?error=...`): meta-mcp's answer after Google.
    static func googleCallback(_ url: URL) -> Callback { answer(url, path: "/google") }

    private static func answer(_ url: URL, path: String) -> Callback {
        guard url.scheme?.lowercased() == callbackScheme, url.host?.lowercased() == "auth", url.path == path,
              let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems else { return .unrelated }
        if let code = items.first(where: { $0.name == "code" })?.value, AppleSignIn.isTokenLike(code) { return .code(code) }
        if let e = items.first(where: { $0.name == "error" })?.value, !e.isEmpty, e.count <= 64,
           e.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_" || $0 == "-") }) {
            return .error(e)
        }
        return .unrelated
    }

    /// Whether a browser round started at `startedAt` may still be finished at `now`.
    static func pendingValid(startedAt: Date, now: Date) -> Bool {
        let age = now.timeIntervalSince(startedAt)
        return age >= -5 && age < pendingLifetime
    }

    enum Collect: Equatable {
        case signedIn(memberToken: String, email: String)
        case failed(String)
    }

    /// `POST /auth/google/collect`: the member token, or a pending link (the email already has a Liaison account
    /// this server holds no password for: it signs in once with its email code and Google is connected), or what to say.
    /// The same three outcomes as Apple's collect, so the same type.
    static func googleCollect(status: Int, json: [String: Any]) -> AppleSignIn.Collect {
        let msg = (json["user_message"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        let failed = "Google sign-in did not finish. Try again."
        if status == 429 { return .failed(msg ?? "Too many attempts. Wait a minute and try again.") }
        guard status == 200, (json["ok"] as? Bool) == true else {
            if status == 410 { return .failed(msg ?? "This sign-in has expired. Choose Continue with Google again.") }
            return .failed(msg ?? failed)
        }
        let email = ((json["email"] as? String) ?? "").lowercased()
        switch json["state"] as? String {
        case "signed_in":
            if let t = json["member_token"] as? String, t.hasPrefix("ey"), t.split(separator: ".").count == 3 {
                return .signedIn(memberToken: t, email: email)
            }
        case "link_required":
            if let l = json["link"] as? String, AppleSignIn.isTokenLike(l) {
                return .linkRequired(link: l, email: email,
                                     message: msg ?? "This email already has a Liaison account. Sign in once with your email to connect Google.")
            }
        default: break
        }
        return .failed(failed)
    }

    /// What the sign-in screen says for `liaison://auth/google?error=` (nil: say nothing, the person cancelled).
    static func googleMessage(forError e: String) -> String? {
        switch e {
        case "cancelled": return nil
        case "unavailable": return "Continue with Google is not available right now. Use your email."
        case "email_unverified": return "Google did not confirm this email. Use your email."
        case "no_email": return "Google did not share an email. Try again."
        case "busy": return "Too many sign-ins right now. Try again in a minute."
        // Settings > Google > Disconnect was used for this account
        case "google_disconnected": return "Google is disconnected from this account. Sign in with your email, then connect Google in Settings."
        case "expired": return "This sign-in has expired. Try again."
        default: return "Google sign-in did not finish. Try again."
        }
    }

    /// `POST /auth/google/link`: nil when Google is now connected, else what to tell the person.
    static func googleLinkMessage(status: Int, json: [String: Any]) -> String? {
        if status == 200, (json["ok"] as? Bool) == true, (json["state"] as? String) == "linked" { return nil }
        if let m = json["user_message"] as? String, !m.isEmpty { return m }
        return "Google could not be connected. You are signed in."
    }

    /// The pending Google link a hand-over carries (the page finished an existing member's Google with this round's
    /// `gf`): AuthStore links Google with it after the sign-in, quietly. nil: none, or not token-shaped.
    static func handoffLink(status: Int, json: [String: Any]) -> String? {
        guard status == 200, (json["ok"] as? Bool) == true, let l = json["link"] as? String, AppleSignIn.isTokenLike(l) else { return nil }
        return l
    }

    /// `POST /auth/handoff/collect` (fallback).
    static func collect(status: Int, json: [String: Any]) -> Collect {
        let msg = (json["user_message"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        if status == 429 { return .failed(msg ?? "Too many attempts. Wait a minute and try again.") }
        if status == 410 { return .failed(msg ?? "This sign-in has expired. Choose Continue with Google again.") }
        if status == 200, (json["ok"] as? Bool) == true, (json["state"] as? String) == "signed_in",
           let t = json["member_token"] as? String, t.hasPrefix("ey"), t.split(separator: ".").count == 3 {
            return .signedIn(memberToken: t, email: ((json["email"] as? String) ?? "").lowercased())
        }
        return .failed(msg ?? "Google sign-in did not finish. Try again.")
    }

    // MARK: which browser opens the Google page

    /// Browsers in the order we prefer when the default one is Liaison itself: opening the page in Liaison while
    /// signed out shows this same sign-in screen, never a browser with Google in it.
    /// UserDefaults: the default browser's bundle id just before Liaison was made the default (Settings).
    static let previousBrowserKey = "lia_previous_default_browser"

    static let browserPreference = ["com.google.Chrome", "company.thebrowser.Browser", "com.brave.Browser",
                                    "com.microsoft.edgemac", "org.mozilla.firefox", "com.operasoftware.Opera",
                                    "com.apple.Safari"]

    /// The browser to open the Google page in, by bundle id: the default unless it is Liaison; then the browser that
    /// was the default before Liaison (if still installed), then the first installed of `browserPreference`, then any
    /// other installed browser. nil: open with the default (it is not us, or nothing else is installed).
    static func googleBrowser(defaultId: String?, ownIds: Set<String>, previousId: String?, installed: [String]) -> String? {
        guard let d = defaultId, ownIds.contains(d) else { return nil }
        let others = installed.filter { !ownIds.contains($0) }
        if let p = previousId, others.contains(p) { return p }
        if let pick = browserPreference.first(where: { others.contains($0) }) { return pick }
        return others.first
    }

    // MARK: links the signed-out window receives (Liaison is his default browser)

    enum Incoming: Equatable {
        /// liaison://auth/google (Continue with Google's answer) or liaison://auth/handoff (fallback's)
        case google
        /// liaison://auth/apple (Continue with Apple's answer)
        case apple
        /// an ordinary web page: a link clicked in another app while Liaison is the default browser. Never an auth
        /// answer; the sign-in screen opens it in another browser and says nothing.
        case web
        case other
    }

    static func incoming(_ url: URL) -> Incoming {
        if googleCallback(url) != .unrelated || callback(url) != .unrelated { return .google }
        if AppleSignIn.callback(url) != .unrelated { return .apple }
        if ["http", "https"].contains(url.scheme?.lowercased() ?? "") { return .web }
        return .other
    }

    // MARK: signing in from inside the app (Settings > Account > Add Account)

    /// Signed in already: another account is being added (Settings > Account > Add Account). (
    /// "a popup opens, but Google isn't signed in there"): Google and Apple now go to the person's own browser exactly
    /// like the first sign-in - the browser that holds their Google session - instead of our pop-up window with a
    /// fresh data store. Only the routing differs: the answer reaches the workspace window's onOpenURL (Settings is
    /// not a scene), which hands it to the round (`workspaceDelivers`).
    static func addsAccount(signedIn: Bool, sessionExpired: Bool) -> Bool { signedIn && !sessionExpired }

    /// Whether the workspace window gives an incoming link to a sign-in round: an auth answer of the round's
    /// provider, the round open and started while signed in (adding an account). The first window's sign-in screen
    /// takes its own links; anything else stays the workspace's.
    static func workspaceDelivers(_ incoming: Incoming, google: Bool, waiting: Bool, adding: Bool) -> Bool {
        guard waiting, adding else { return false }
        switch incoming {
        case .google: return google
        case .apple: return !google
        case .web, .other: return false
        }
    }

    /// ("don't bring the app forward until it is confirmed"): how a browser round ended for
    /// the app. Only a sign-in, or something the person must read, brings the app to the front; a round that goes on
    /// in the browser (an older server's link_required reopening the page) or ends with nothing to say leaves it where
    /// it is (the waiting card stays, with Cancel).
    enum RoundEnd: Equatable { case signedIn, tell, inBrowser, quiet }
    static func comesForward(_ end: RoundEnd) -> Bool { end == .signedIn || end == .tell }

    /// ("coming back, the browser does not bring me to the app; I press Open again"): the
    /// browser's answer to a round this app is waiting for brings the app forward the moment it arrives, before the
    /// collect's network call - macOS honours an activation best while the browser's hand-over is fresh (cooperative
    /// activation, macOS 14), and 2 s later it may refuse. Only liaison://auth/handoff (sent by the page on success
    /// only) and liaison://auth/google|apple (the server's final answer: signed in, the code card, or an error to read)
    /// reach here, so nothing that goes on in the browser brings the app forward. Not ours, or no round: nothing.
    static func comesForwardOnArrival(_ incoming: Incoming, googleWaiting: Bool, appleWaiting: Bool) -> Bool {
        switch incoming {
        case .google: return googleWaiting
        case .apple: return appleWaiting
        case .web, .other: return false
        }
    }

    /// Activation can be refused while another app is mid-gesture; it is asked again after these delays
    /// (seconds) for as long as the app is not active. Short and few: the person is waiting for the window.
    static let frontRetries: [Double] = [0.3, 1.0]

    /// The legal line's pages.
    static let termsURL = URL(string: "https://liaisone.com/terms/")!
    static let privacyURL = URL(string: "https://liaisone.com/privacy/")!

    // MARK: email + password (accounts that have one, e.g. Apple's reviewer)

    /// What a failed `POST client.memberstack.com/auth/login` means.
    enum PasswordFailure: Equatable {
        /// `invalid-credentials` (also what an account without a password of its own answers).
        case wrongPassword
        case rateLimited
        case network
        /// Memberstack's own sentence, or its code when there is no sentence.
        case other(String)
    }

    static func passwordFailure(status: Int, json: [String: Any]) -> PasswordFailure {
        let p = errorParts(json)
        let code = p.code.lowercased()
        if code.contains("invalid-credentials") || code.contains("invalid-password") || code.contains("invalid-email-or-password") {
            return .wrongPassword
        }
        if status == 429 { return .rateLimited }
        if status == 0 || status >= 500 { return .network }
        let m = p.message.trimmingCharacters(in: .whitespacesAndNewlines)
        if m.contains(" "), m.count <= 200 { return .other(m) }
        return .other(code.isEmpty ? "HTTP \(status)" : code)
    }
}
