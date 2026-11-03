import Foundation
import Security
import LocalAuthentication
import AppKit

/// One saved sign-in of the in-app browser (its password stays in the Keychain until it is asked for).
struct PasswordItem: Identifiable, Hashable, Sendable {
    /// The workspace's browser key (CompanyProfile.browserKey): every workspace is a different client.
    let workspace: String
    /// "https" or "http".
    let scheme: String
    let host: String
    let user: String
    let modified: Date?
    var id: String { workspace + "|" + scheme + "://" + host + "|" + user }
    /// The host as the lists show it.
    var site: String { PasswordMatch.bareHost(host) }
}

/// The in-app browser's passwords, in the Mac's login Keychain ("they are not saved, not offered").
///
/// Internet-password items (server, account, protocol, HTML-form authentication), label "Liaison", their security
/// domain "liaison:<workspace browser key>": one workspace never sees another's (two clients, two logins for the same
/// site). Not synchronized, never in iCloud.
/// The login keychain, as Shared/Auth/Keychain.swift explains: the app has no keychain-access-groups entitlement,
/// so the data-protection keychain (and with it a SecAccessControl `.userPresence` on the item) is not available.
/// The items' ACL is the app's own; reading a password to FILL, REVEAL or COPY it is gated here by LocalAuthentication
/// (Touch ID or the Mac's password, `.deviceOwnerAuthentication`). Saving asks nothing.
/// The list (sites and user names) is read without a password and cached per workspace.
@MainActor
final class PasswordStore: ObservableObject {
    static let shared = PasswordStore()

    static let label = "Liaison"
    /// "Offer to save passwords", on by default.
    static let offerKey = "lia_pw_offer_save"
    /// [workspace browser key: [host]]: the sites the person said Never for.
    static let neverKey = "lia_pw_never"
    static var offerEnabled: Bool { Prefs.flag(offerKey, default: true) }

    /// Bumped on every change, so lists and the address bar's key redraw.
    @Published private(set) var revision = 0
    private var cache: [String: [PasswordItem]] = [:]
    private var authedAt: Date?
    /// One Touch ID covers what the person does right after it (reveal, then copy), never longer.
    static let authGrace: TimeInterval = 30

    static func domain(_ workspace: String) -> String { "liaison:" + workspace }

    private static func proto(_ scheme: String) -> CFString { scheme.lowercased() == "http" ? kSecAttrProtocolHTTP : kSecAttrProtocolHTTPS }

    private static func scheme(of attr: Any?) -> String {
        if let s = attr as? String, s == (kSecAttrProtocolHTTP as String) { return "http" }
        return "https"
    }

    private static func base(_ workspace: String, scheme: String, host: String, user: String) -> [String: Any] {
        [kSecClass as String: kSecClassInternetPassword,
         kSecAttrSecurityDomain as String: domain(workspace),
         kSecAttrServer as String: PasswordMatch.normalizedHost(host),
         kSecAttrAccount as String: user,
         kSecAttrProtocol as String: proto(scheme),
         kSecAttrAuthenticationType as String: kSecAttrAuthenticationTypeHTMLForm]
    }

    private static func base(_ i: PasswordItem) -> [String: Any] { base(i.workspace, scheme: i.scheme, host: i.host, user: i.user) }

    // MARK: - reading the list

    /// The workspace's saved sign-ins, by site then user. No password is read.
    func items(_ workspace: String) -> [PasswordItem] {
        if let c = cache[workspace] { return c }
        let list = Self.load(workspace)
        cache[workspace] = list
        return list
    }

    private static func load(_ workspace: String) -> [PasswordItem] {
        let q: [String: Any] = [kSecClass as String: kSecClassInternetPassword,
                                kSecAttrSecurityDomain as String: domain(workspace),
                                kSecReturnAttributes as String: true,
                                kSecMatchLimit as String: kSecMatchLimitAll]
        var out: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let rows = out as? [[String: Any]] else { return [] }
        let list: [PasswordItem] = rows.compactMap { r in
            guard let host = r[kSecAttrServer as String] as? String, !host.isEmpty else { return nil }
            return PasswordItem(workspace: workspace, scheme: scheme(of: r[kSecAttrProtocol as String]), host: host,
                                user: r[kSecAttrAccount as String] as? String ?? "",
                                modified: r[kSecAttrModificationDate as String] as? Date)
        }
        return list.sorted { a, b in a.site == b.site ? a.user.localizedCaseInsensitiveCompare(b.user) == .orderedAscending : a.site < b.site }
    }

    private func changed(_ workspace: String) {
        cache[workspace] = nil
        revision += 1
    }

    // MARK: - writing

    enum SaveResult { case added, updated, unchanged, failed }

    /// Adds the sign-in or replaces its password. Asks nothing.
    @discardableResult
    func save(workspace: String, scheme: String, host: String, user: String, password: String) -> SaveResult {
        guard !password.isEmpty, !host.isEmpty else { return .failed }
        let q = Self.base(workspace, scheme: scheme, host: host, user: user)
        let data = Data(password.utf8)
        if let old = Self.read(q) {
            if old == password { return .unchanged }
            let st = SecItemUpdate(q as CFDictionary, [kSecValueData as String: data] as CFDictionary)
            changed(workspace)
            return st == errSecSuccess ? .updated : .failed
        }
        var add = q
        add[kSecValueData as String] = data
        add[kSecAttrLabel as String] = Self.label
        add[kSecAttrDescription as String] = "Liaison web password"
        add[kSecAttrComment as String] = "Saved by Liaison\u{2019}s browser for one workspace."
        let st = SecItemAdd(add as CFDictionary, nil)
        changed(workspace)
        return st == errSecSuccess ? .added : .failed
    }

    /// A new user name and/or password for a saved sign-in. false: the Keychain refused (another item has that name).
    @discardableResult
    func update(_ item: PasswordItem, user: String, password: String?) -> Bool {
        var attrs: [String: Any] = [:]
        if user != item.user { attrs[kSecAttrAccount as String] = user }
        if let p = password, !p.isEmpty { attrs[kSecValueData as String] = Data(p.utf8) }
        guard !attrs.isEmpty else { return true }
        let st = SecItemUpdate(Self.base(item) as CFDictionary, attrs as CFDictionary)
        changed(item.workspace)
        return st == errSecSuccess
    }

    func delete(_ item: PasswordItem) {
        SecItemDelete(Self.base(item) as CFDictionary)
        changed(item.workspace)
    }

    /// Every sign-in of a workspace (the workspace is being reset by the person).
    func deleteAll(_ workspace: String) {
        let q: [String: Any] = [kSecClass as String: kSecClassInternetPassword, kSecAttrSecurityDomain as String: Self.domain(workspace)]
        SecItemDelete(q as CFDictionary)
        changed(workspace)
    }

    // MARK: - the password itself

    private static func read(_ q: [String: Any]) -> String? {
        var query = q
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &out) == errSecSuccess, let d = out as? Data else { return nil }
        return String(data: d, encoding: .utf8)
    }

    /// The password, for a caller that has just passed `authenticate` (fill, reveal, copy). Never handed to an agent.
    func secret(_ item: PasswordItem) -> String? { Self.read(Self.base(item)) }

    /// The accounts saved for exactly this site, with their passwords, for the save/update offer only (compared in
    /// memory, never shown): nothing is revealed, so this asks nothing.
    func known(workspace: String, host: String) -> [PasswordOffer.Known] {
        items(workspace).filter { PasswordMatch.sameHost($0.host, host) }.map { PasswordOffer.Known(user: $0.user, password: secret($0)) }
    }

    /// Touch ID or the Mac's password. `reason` completes macOS's "Liaison is trying to …".
    func authenticate(_ reason: String) async -> Bool {
        if let t = authedAt, Date().timeIntervalSince(t) < Self.authGrace { return true }
        let ctx = LAContext()
        var err: NSError?
        guard ctx.canEvaluatePolicy(.deviceOwnerAuthentication, error: &err) else { return false }
        let ok = (try? await ctx.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason)) ?? false
        if ok { authedAt = Date() }
        return ok
    }

    // MARK: - Never for this site

    func isNever(workspace: String, host: String) -> Bool {
        let all = UserDefaults.standard.dictionary(forKey: Self.neverKey) as? [String: [String]] ?? [:]
        return (all[workspace] ?? []).contains { PasswordMatch.sameHost($0, host) }
    }

    func setNever(workspace: String, host: String, _ on: Bool) {
        var all = UserDefaults.standard.dictionary(forKey: Self.neverKey) as? [String: [String]] ?? [:]
        var list = (all[workspace] ?? []).filter { !PasswordMatch.sameHost($0, host) }
        if on { list.append(PasswordMatch.bareHost(host)) }
        all[workspace] = list.isEmpty ? nil : list.sorted()
        UserDefaults.standard.set(all, forKey: Self.neverKey)
        revision += 1
    }

    func neverList(_ workspace: String) -> [String] {
        let all = UserDefaults.standard.dictionary(forKey: Self.neverKey) as? [String: [String]] ?? [:]
        return all[workspace] ?? []
    }

    // MARK: - clipboard

    /// Copies a password marked concealed (clipboard managers that honour nspasteboard.org skip it) and clears it
    /// after 90 s if nothing else was copied meanwhile.
    static func copy(_ password: String) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(password, forType: .string)
        pb.setString("", forType: NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType"))
        let count = pb.changeCount
        DispatchQueue.main.asyncAfter(deadline: .now() + 90) {
            if NSPasteboard.general.changeCount == count { NSPasteboard.general.clearContents() }
        }
    }
}

/// The passwords Liaison filled or saw submitted this session, kept in memory (30 minutes, never on disk) only so
/// that everything the agents get from a page is scrubbed of them (SecretMask.scrub), even where a page shows one.
@MainActor
enum PasswordSecrets {
    private static var list: [(value: String, at: Date)] = []
    static let lifetime: TimeInterval = 30 * 60

    static func remember(_ s: String) {
        guard s.count >= 4 else { return }
        prune()
        list.removeAll { $0.value == s }
        list.append((s, Date()))
        if list.count > 20 { list.removeFirst(list.count - 20) }
    }

    private static func prune() {
        let now = Date()
        list.removeAll { now.timeIntervalSince($0.at) > lifetime }
    }

    static func scrub(_ text: String) -> String {
        prune()
        return list.isEmpty ? text : SecretMask.scrub(text, secrets: list.map { $0.value })
    }
}
