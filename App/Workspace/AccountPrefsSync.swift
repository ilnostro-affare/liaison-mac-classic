import Foundation

/// The welcome's done flag and the role, per Liaison account (rules: Shared/Core/AccountPrefs.swift). The
/// Mac-wide `lia_onboarded` / `lia_role` mirror the account in front, so their @AppStorage readers need no change.
@MainActor
enum AccountPrefsSync {
    /// The account came in front (WorkspaceModel.init): its own values go into the Mac-wide mirror. Returns whether it
    /// has been through the welcome.
    @discardableResult
    static func activate(member: String?) -> Bool {
        let d = UserDefaults.standard
        guard let m = member else { return d.bool(forKey: AccountPrefs.globalOnboarded) }
        let r = AccountPrefs.resolve(member: m, owner: d.string(forKey: AccountPrefs.ownerKey),
                                     globalOnboarded: d.bool(forKey: AccountPrefs.globalOnboarded),
                                     globalRole: d.string(forKey: AccountPrefs.globalRole),
                                     memberOnboarded: d.object(forKey: AccountPrefs.onboardedKey(m)) == nil ? nil : d.bool(forKey: AccountPrefs.onboardedKey(m)),
                                     memberRole: d.string(forKey: AccountPrefs.roleKey(m)))
        if r.inherits { d.set(m, forKey: AccountPrefs.ownerKey) }
        d.set(r.onboarded, forKey: AccountPrefs.onboardedKey(m))
        d.set(r.role, forKey: AccountPrefs.roleKey(m))
        d.set(r.onboarded, forKey: AccountPrefs.globalOnboarded)
        if r.role.isEmpty { d.removeObject(forKey: AccountPrefs.globalRole) } else { d.set(r.role, forKey: AccountPrefs.globalRole) }
        return r.onboarded
    }

    static func markOnboarded(member: String?) {
        let d = UserDefaults.standard
        d.set(true, forKey: AccountPrefs.globalOnboarded)
        if let m = member { d.set(true, forKey: AccountPrefs.onboardedKey(m)) }
    }

    /// The role was picked (the welcome, Settings): kept for this account as well as in the mirror.
    static func setRole(_ raw: String, member: String?) {
        guard let m = member else { return }
        UserDefaults.standard.set(LiaRole.stored(raw)?.rawValue ?? "", forKey: AccountPrefs.roleKey(m))
    }

    /// The role of the account in front.
    static func role(member: String?) -> LiaRole? {
        guard let m = member else { return LiaRole.stored(UserDefaults.standard.string(forKey: AccountPrefs.globalRole)) }
        return LiaRole.stored(UserDefaults.standard.string(forKey: AccountPrefs.roleKey(m)))
    }

    /// Start over: this account's welcome and role go too (the mirror is cleared by clearWorkspaceDefaults).
    static func forget(member: String?) {
        guard let m = member else { return }
        UserDefaults.standard.removeObject(forKey: AccountPrefs.onboardedKey(m))
        UserDefaults.standard.set("", forKey: AccountPrefs.roleKey(m))
    }
}
