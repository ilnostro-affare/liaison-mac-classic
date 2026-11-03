import Foundation
import Combine
import os

struct StoredAccount: Codable, Identifiable, Equatable {
    let id: String
    var email: String
    var token: String
}

@MainActor
final class AuthStore: ObservableObject {
    enum Phase: Equatable { case signedOut, signedIn }

    @Published private(set) var phase: Phase
    /// Every signed in Liaison account on this iPhone (Settings, account card), newest first.
    @Published private(set) var accounts: [StoredAccount] = []
    @Published private(set) var activeId: String?
    /// The server refused the active account's session twice in a row. The account stays in the saved list;
    /// the window asks for a new sign-in instead of dropping it.
    @Published private(set) var sessionExpired = false
    static let accountsKey = "memberstack.accounts"
    private let api: AuthAPI
    private var sessionToken: String?
    private var sessionMintedAt: Date?
    private var minting: Task<String, Error>?
    /// The member token the in-flight mint started with: a mint that finishes after a switch or a sign-out
    /// belongs to the previous account and is thrown away.
    private var mintingFor: String?
    static let memberTokenKey = "memberstack.accessToken"
    // The server keeps an lsess_ session for 15 minutes, sliding; it is re-minted after 10, as the web client does.
    static let sessionReuse: TimeInterval = 10 * 60

    init(api: AuthAPI = AuthAPI()) {
        self.api = api
        phase = Keychain.get(Self.memberTokenKey) == nil ? .signedOut : .signedIn
        if let raw = Keychain.get(Self.accountsKey), let list = try? JSONDecoder().decode([StoredAccount].self, from: Data(raw.utf8)) {
            accounts = list
        }
        if let token = Keychain.get(Self.memberTokenKey) {
            let id = MemberToken.memberId(from: token) ?? "current"
            if !accounts.contains(where: { $0.id == id }) { accounts.insert(StoredAccount(id: id, email: "", token: token), at: 0); persistAccounts() }
            activeId = id
        }
    }

    private func persistAccounts() {
        if let data = try? JSONEncoder().encode(accounts), let s = String(data: data, encoding: .utf8) {
            Keychain.set(s, for: Self.accountsKey)
        }
    }

    func rememberEmail(_ email: String) {
        guard let id = activeId, let i = accounts.firstIndex(where: { $0.id == id }), accounts[i].email != email else { return }
        accounts[i].email = email
        persistAccounts()
    }

    func switchTo(_ id: String) {
        guard let acc = accounts.first(where: { $0.id == id }), id != activeId else { return }
        Keychain.set(acc.token, for: Self.memberTokenKey)
        liveMemberToken = acc.token
        cancelMint()
        sessionToken = nil
        sessionMintedAt = nil
        sessionExpired = false
        activeId = id
        phase = .signedIn
    }

    /// The token this launch signed in with, kept in memory too: if the keychain refused to store it, the profile,
    /// the member id and everything that hangs on them still work until the app quits.
    private var liveMemberToken: String?

    /// The Memberstack member token, for the few endpoints that verify it themselves (/member, /billing/summary).
    var memberToken: String? { liveMemberToken ?? Keychain.get(Self.memberTokenKey) }

    /// Member id read from the stored Memberstack token (no network, nothing trusted from it).
    var memberId: String? { memberToken.flatMap(MemberToken.memberId(from:)) }

    func sendCode(email: String) async throws {
        try await api.sendCode(email: email)
    }

    func verify(email: String, code: String) async throws {
        try await finish(email: email, member: try await api.login(email: email, code: code))
    }

    /// The landing's email step. A new email gets Memberstack's signup code (true: ask the source next); an email
    /// that already has an account gets the login code (false: straight to the code).
    func sendCodeForSignupOrLogin(email: String) async throws -> Bool {
        switch try await api.sendSignupCode(email: email) {
        case .newMember: return true
        case .existing, .failed:
            try await api.sendCode(email: email)
            return false
        }
    }

    /// A new member, as the landing creates one: the code, the Free plan, the answer to "How did you hear".
    /// `creatorCode` (already checked by the source step) waits for this member in UserDefaults before the
    /// session comes up, so the signed-in window (SignedInRoot) delivers it, or the next launch if that failed.
    func signUp(email: String, code: String, source: String?, creatorCode: String? = nil) async throws {
        let member = try await api.signup(email: email, code: code, source: source)
        if let c = creatorCode, let id = MemberToken.memberId(from: member) { CreatorCodeSync.enqueue(c, via: .signup, member: id) }
        try await finish(email: email, member: member)
    }

    /// Continue with Google came back from the browser: the one-time code -> the member token the browser's
    /// Memberstack sign-in holds, which signs in exactly like an email code.
    func signInWithHandoff(code: String, verifier: String) async throws -> MacSignIn.Collect {
        guard let r = try? await api.handoffCollect(code: code, verifier: verifier) else { throw AuthError.network }
        let result = MacSignIn.collect(status: r.0, json: r.1)
        if case .signedIn(let token, let email) = result {
            // The page finished an existing member's Google with this round's proof: link Google after it, quietly
            // (quiet link, so the next Continue with Google signs in directly)
            if let link = MacSignIn.handoffLink(status: r.0, json: r.1) {
                pendingLink = PendingLink(provider: .google, link: link, email: email, at: Date(), quiet: true)
            }
            try await finish(email: email, member: token)
        }
        return result
    }

    /// Email + password (accounts that have one; the review account).
    func verify(email: String, password: String) async throws {
        try await finish(email: email, member: try await api.login(email: email, password: password))
    }

    /// QR sign-in. A phone that is signed in approved this Mac and handed over its member token; it signs in
    /// exactly like an email code (the token is kept only after /auth/session accepts it).
    /// A new code to draw, or nil (rate limited, offline, a server error): `rateLimited` says which.
    func qrStart(device: String) async -> (ticket: QRSignIn.Ticket?, rateLimited: Bool) {
        guard let r = try? await api.qrStart(device: device) else { return (nil, false) }
        return (QRSignIn.ticket(status: r.0, json: r.1, now: Date()), r.0 == 429)
    }
    func qrPoll(_ ticket: QRSignIn.Ticket) async -> QRSignIn.PollResult {
        guard let r = try? await api.qrPoll(code: ticket.code, poll: ticket.poll) else { return .retry }
        return QRSignIn.pollResult(status: r.0, json: r.1)
    }
    func verify(approvedMemberToken token: String, email: String) async throws {
        try await finish(email: email, member: token)
    }

    /// Sign in with Apple (or Continue with Google) came back with an email that already has a Liaison
    /// account. Kept in memory until the next successful sign-in on this Mac, which connects that provider to the account
    /// (the server keeps it 30 minutes).
    enum LinkProvider: Equatable { case apple, google }
    /// `quiet` - Google's link, finished by the /signin/mac/ page right after (MacSignIn.LinkNext.page): the
    /// outcome goes to the log only; the person just signed in with Google and is told nothing either way.
    struct PendingLink: Equatable { let provider: LinkProvider; let link: String; let email: String; let at: Date; var quiet = false }
    private static let log = Logger(subsystem: "com.liaisone.mac", category: "signin")
    @Published private(set) var pendingLink: PendingLink?

    /// The one-time code from liaison://auth/apple -> the member token (signs in like an email code) or a pending
    /// link. The verifier is the one this Mac made for the round; nothing else can collect the code.
    func signInWithApple(code: String, verifier: String) async throws -> AppleSignIn.Collect {
        guard let r = try? await api.appleCollect(code: code, verifier: verifier) else { throw AuthError.network }
        return try await settle(AppleSignIn.collect(status: r.0, json: r.1), provider: .apple)
    }

    /// What a Google collect came to: Apple's three outcomes, or (a server, next=app) an existing
    /// account that finishes with Memberstack's emailed code in the app.
    enum GoogleCollect: Equatable {
        case collect(AppleSignIn.Collect)
        case code(MacSignIn.CodeRequired)
    }

    /// The one-time code from liaison://auth/google (meta-mcp after Google's account chooser), the same way.
    func signInWithGoogle(code: String, verifier: String) async throws -> GoogleCollect {
        guard let r = try? await api.googleCollect(code: code, verifier: verifier) else { throw AuthError.network }
        if let c = MacSignIn.googleCodeRequired(status: r.0, json: r.1) { return .code(c) }
        // An older server's link_required: the email code in the app, then the quiet link (no page any more)
        return .collect(try await settle(MacSignIn.googleCollect(status: r.0, json: r.1), provider: .google, quiet: true))
    }

    /// The code Memberstack mailed for a code_required Google round -> signed in (and Google connected, once).
    func finishGoogle(link: String, code: String) async throws -> MacSignIn.GoogleFinish {
        guard let r = try? await api.googleFinish(link: link, code: code) else { throw AuthError.network }
        let result = MacSignIn.googleFinish(status: r.0, json: r.1)
        if case .signedIn(let token, let email, let linked) = result {
            try await finish(email: email, member: token)
            Self.log.notice("google code: signed in, \(linked ? "linked" : "not linked", privacy: .public)")
        }
        return result
    }

    /// A new code for the same round. nil when it was sent, else what to say.
    func resendGoogleCode(link: String) async -> String? {
        guard let r = try? await api.googleResend(link: link) else { return AuthError.network.message }
        if r.0 == 200, (r.1["ok"] as? Bool) == true { return nil }
        return (r.1["user_message"] as? String) ?? "The code could not be sent. Try again in a minute."
    }

    /// Settings changed the sign-in email: the account list shows the new address, and a fresh token for the same
    /// member (the server's answer) replaces the stored one.
    func adoptEmailChange(email: String, memberToken token: String?) {
        guard let id = activeId, let i = accounts.firstIndex(where: { $0.id == id }) else { return }
        accounts[i].email = email
        if AccountActions.adoptsToken(token, activeMember: memberId), let token {
            accounts[i].token = token
            Keychain.set(token, for: Self.memberTokenKey)
            liveMemberToken = token
        }
        persistAccounts()
    }

    private func settle(_ result: AppleSignIn.Collect, provider: LinkProvider, quiet: Bool = false) async throws -> AppleSignIn.Collect {
        switch result {
        case .signedIn(let token, let email):
            try await finish(email: email, member: token)
        case .linkRequired(let link, let email, _):
            pendingLink = PendingLink(provider: provider, link: link, email: email, at: Date(), quiet: quiet)
        case .failed:
            break
        }
        return result
    }

    func dropPendingLink() { pendingLink = nil }
    /// The page could not be opened, so the person signs in with the email after all: say how the link went.
    func announcePendingLink() { pendingLink?.quiet = false }

    /// After a sign-in with the email of a pending link: connect Apple or Google, then say how it went in the window.
    private func connectPendingLink(memberToken: String, email: String) {
        guard let p = pendingLink else { return }
        pendingLink = nil
        guard MacSignIn.linkApplies(pendingEmail: p.email, email: email, age: Date().timeIntervalSince(p.at)) else {
            if p.quiet { Self.log.notice("google link skipped: another account or too late") }
            return
        }
        if p.quiet {
            // Signed in through the page with Memberstack's Google: the server now seals its password and maps
            // google:sub, so the next Continue with Google signs in directly. A refusal (409 has_password: the member has
            // a password of their own) changes nothing for the person, who is signed in.
            Task { @MainActor [api] in
                let r = try? await api.googleLink(link: p.link, memberToken: memberToken)
                let outcome = r.map({ MacSignIn.linkOutcome(status: $0.0, json: $0.1) }) ?? .notLinked("network")
                if MacSignIn.remembersPageFirst(outcome) { UserDefaults.standard.set(true, forKey: MacSignIn.pageFirstKey) }
                switch outcome {
                case .linked:
                    UserDefaults.standard.removeObject(forKey: MacSignIn.pageFirstKey)
                    Self.log.notice("google link: linked")
                case .notLinked(let why): Self.log.notice("google link: not linked (\(why, privacy: .public))")
                }
            }
            return
        }
        Task { @MainActor [api] in
            switch p.provider {
            case .apple:
                let r = try? await api.appleLink(link: p.link, memberToken: memberToken)
                let msg = r.map { AppleSignIn.linkMessage(status: $0.0, json: $0.1) } ?? "Apple could not be connected. You are signed in."
                WorkspaceModel.current?.show(msg ?? "Apple is connected. Next time, Continue with Apple.", symbol: "apple.logo")
            case .google:
                let r = try? await api.googleLink(link: p.link, memberToken: memberToken)
                let msg = r.map { MacSignIn.googleLinkMessage(status: $0.0, json: $0.1) } ?? "Google could not be connected. You are signed in."
                WorkspaceModel.current?.show(msg ?? "Google is connected. Next time, Continue with Google.", symbol: "person.crop.circle.badge.checkmark")
            }
        }
    }

    private func finish(email: String, member: String) async throws {
        // The token is saved only after the server accepted it: otherwise the Keychain would hold
        // a token the app cannot make a single request with.
        let session = try await api.mintSession(memberToken: member)
        Keychain.set(member, for: Self.memberTokenKey)
        liveMemberToken = member
        let id = MemberToken.memberId(from: member) ?? "current"
        accounts.removeAll { $0.id == id }
        accounts.insert(StoredAccount(id: id, email: email, token: member), at: 0)
        persistAccounts()
        cancelMint()
        activeId = id
        sessionToken = session
        sessionMintedAt = Date()
        sessionExpired = false
        phase = .signedIn
        connectPendingLink(memberToken: member, email: email)
    }

    /// A usable lsess_. One mint at a time: parallel callers share the same task.
    func validSession(forceRefresh: Bool = false) async throws -> String {
        if !forceRefresh, let t = sessionToken, let at = sessionMintedAt, Date().timeIntervalSince(at) < Self.sessionReuse {
            return t
        }
        // `memberToken`: the in-memory token first, so a keychain that refused to store it is covered.
        guard let member = memberToken else {
            signOut()
            throw AuthError.sessionExpired
        }
        if let minting, mintingFor == member {
            let t = try await minting.value
            guard memberToken == member else { throw AuthError.sessionExpired }
            return t
        }
        let task = Task { [api] in try await api.mintSession(memberToken: member) }
        minting = task
        mintingFor = member
        defer {
            if mintingFor == member { minting = nil; mintingFor = nil }
        }
        do {
            let t = try await task.value
            // Switched or signed out while the mint ran: this session belongs to the previous account.
            guard memberToken == member, !task.isCancelled else { throw AuthError.sessionExpired }
            sessionToken = t
            sessionMintedAt = Date()
            return t
        } catch AuthError.sessionExpired {
            // The Memberstack token expired (14 days) or was revoked: only a new sign-in helps.
            if memberToken == member { markSessionExpired() }
            throw AuthError.sessionExpired
        }
    }

    /// The server refused the session even after a fresh mint: ask for a new sign-in, keep the saved account.
    func markSessionExpired() {
        cancelMint()
        sessionToken = nil
        sessionMintedAt = nil
        sessionExpired = true
    }

    /// The email last used with the active account (prefills the new sign-in after an expiry).
    var activeEmail: String? {
        guard let id = activeId, let e = accounts.first(where: { $0.id == id })?.email, !e.isEmpty else { return nil }
        return e
    }

    private func cancelMint() {
        minting?.cancel()
        minting = nil
        mintingFor = nil
    }

    /// Signs out the active account; another signed in account takes over if there is one.
    func signOut() {
        if let id = activeId { accounts.removeAll { $0.id == id } }
        persistAccounts()
        cancelMint()
        sessionToken = nil
        sessionMintedAt = nil
        sessionExpired = false
        if let next = accounts.first {
            Keychain.set(next.token, for: Self.memberTokenKey)
            liveMemberToken = next.token
            activeId = next.id
            phase = .signedIn
        } else {
            Keychain.delete(Self.memberTokenKey)
            liveMemberToken = nil
            activeId = nil
            phase = .signedOut
        }
        ChatDocCache.clear()
    }
}
