import SwiftUI

/// Which agents the dock and the side panel show, per Liaison account and workspace
/// (`AgentVisibility`, one UserDefaults key per agent). Settings > Team writes it; the strips read it and redraw on
/// `rev`. Display only: routing, @mentions, jobs and notifications never ask it.
@MainActor
final class AgentShownStore: ObservableObject {
    static let shared = AgentShownStore()
    @Published private(set) var rev = 0

    func isHidden(_ agent: String, account: String?, profile: String?) -> Bool {
        guard let p = profile else { return false }
        return UserDefaults.standard.bool(forKey: AgentVisibility.key(account: account, profile: p, agent: agent))
    }

    func set(_ agent: String, shown: Bool, account: String?, profile: String) {
        let k = AgentVisibility.key(account: account, profile: profile, agent: agent)
        if shown { UserDefaults.standard.removeObject(forKey: k) } else { UserDefaults.standard.set(true, forKey: k) }
        rev += 1
    }
}

extension WorkspaceModel {
    /// The agents usable in the workspace in front, in roster order: shown there (Settings > Team),
    /// not "coming soon", and not locked (Met / the Meta agents without an ad account in this workspace). Lia (the lead)
    /// is always in. For the server (who Lia may hand a task to); the dock and the messenger filter with `shownAgents`.
    var enabledAgentIds: [String] {
        shownAgents(roster).filter { $0.lead || (!$0.soon && !isLocked($0.id)) }.map(\.id)
    }

    /// The rest of the roster for workspace `p` (hidden, locked, coming soon; never Lia): the turn body's `agents_off`.
    func agentsOff(profile p: String) -> [String] {
        let store = AgentShownStore.shared, account = auth.activeId
        let noAccounts = profiles.first { $0.id == p }?.metaAccounts.isEmpty ?? false
        return AgentVisibility.off(roster, isHidden: { store.isHidden($0, account: account, profile: p) },
                                   isLocked: { noAccounts && Self.metaAgents.contains($0) })
    }

    /// `list` without the agents hidden in the current workspace (Settings > Team > Show in this workspace).
    func shownAgents(_ list: [AgentInfo]) -> [AgentInfo] {
        let store = AgentShownStore.shared, account = auth.activeId, profile = profileId
        return AgentVisibility.filter(list, roster: roster) { store.isHidden($0, account: account, profile: profile) }
    }
}
