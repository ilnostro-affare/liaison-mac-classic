import Foundation

/// The welcome (onboarding) and the role asked in it belong to the Liaison account, not to the Mac.
/// Before, `lia_onboarded` and `lia_role` were Mac-wide: a new Google account signed up on a Mac that had been through
/// the welcome saw none of it (no role, no "How did you hear about Liaison?").
/// Now each member has `lia_onboarded_<member>` and `lia_role_<member>`; the old Mac-wide keys stay as the MIRROR of
/// the account in front (every reader of them, @AppStorage included, keeps working) and are rewritten whenever an
/// account becomes active. Migration: the first member active when this version runs inherits the Mac-wide values
/// (`lia_prefs_owner` records who); any other account that has no keys of its own starts with the welcome.
enum AccountPrefs {
    static let globalOnboarded = "lia_onboarded"
    static let globalRole = "lia_role"
    static let ownerKey = "lia_prefs_owner"

    static func onboardedKey(_ member: String) -> String { globalOnboarded + "_" + member }
    static func roleKey(_ member: String) -> String { globalRole + "_" + member }

    struct Resolved: Equatable {
        let onboarded: Bool
        let role: String
        /// this member takes the Mac-wide values (the migration): record it as the owner
        let inherits: Bool
    }

    /// The account's values when it becomes active. `memberOnboarded` / `memberRole`: its own keys (nil: absent).
    static func resolve(member: String, owner: String?, globalOnboarded: Bool, globalRole: String?,
                        memberOnboarded: Bool?, memberRole: String?) -> Resolved {
        if memberOnboarded != nil || memberRole != nil {
            return Resolved(onboarded: memberOnboarded ?? false, role: LiaRole.stored(memberRole)?.rawValue ?? "", inherits: false)
        }
        if owner == nil || owner == member {
            return Resolved(onboarded: globalOnboarded, role: LiaRole.stored(globalRole)?.rawValue ?? "", inherits: owner == nil)
        }
        return Resolved(onboarded: false, role: "", inherits: false)
    }
}
