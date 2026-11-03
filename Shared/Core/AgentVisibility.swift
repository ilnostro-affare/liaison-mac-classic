import Foundation

// "Show in this workspace" per agent (Settings > Team). Someone does not need Met in one of their
// workspaces: they turn it off there and the dock and the side panel keep only the agents they use. Display only:
// a hidden agent still answers an @mention, runs its jobs and sends its notifications.
// Pure pieces (Foundation only, tested on Linux): the key, which agents are shown, the last-one rule.

enum AgentVisibility {
    static let prefix = "lia_agent_hidden_"

    /// One key per agent, per Liaison account and workspace: "lia_agent_hidden_<account>|p:<profile>|a:<agent>".
    /// Stored only while the agent is hidden (true); shown is the absence of the key.
    static func key(account: String?, profile: String, agent: String) -> String {
        prefix + CompanyProfile.browserKey(account: account, profile: profile) + "|a:" + agent
    }

    /// The lead (Lia) opens the team chat and always stays in the dock: it cannot be hidden.
    static func pinned(_ a: AgentInfo) -> Bool { a.lead }

    /// The ids shown out of `roster`. Never none: if every agent reads as hidden (a roster that changed under old
    /// keys), all of them are shown.
    static func shownIds(_ roster: [AgentInfo], isHidden: (String) -> Bool) -> Set<String> {
        let shown = roster.filter { pinned($0) || !isHidden($0.id) }.map(\.id)
        return Set(shown.isEmpty ? roster.map(\.id) : shown)
    }

    /// `list` (any part of the roster) without the hidden agents, in its own order.
    static func filter(_ list: [AgentInfo], roster: [AgentInfo], isHidden: (String) -> Bool) -> [AgentInfo] {
        let ids = shownIds(roster, isHidden: isHidden)
        return list.filter { ids.contains($0.id) }
    }

    /// Whether the toggle of `id` is enabled: never for the lead, not for the last shown agent (it may not be turned
    /// off); a hidden agent's toggle always is (it only turns it back on).
    static func canToggle(_ id: String, roster: [AgentInfo], isHidden: (String) -> Bool) -> Bool {
        guard let a = roster.first(where: { $0.id == id }), !pinned(a) else { return false }
        let ids = shownIds(roster, isHidden: isHidden)
        guard ids.contains(id) else { return true }
        return ids.count > 1
    }

    /// Server (`agents_off` on every POST /agents/turn): the roster's agents not usable in a workspace - hidden
    /// there, locked (a Meta agent without an ad account) or "coming soon" - in roster order, never Lia (the lead).
    /// The server then never says it hands a task to one of them.
    static func off(_ roster: [AgentInfo], isHidden: (String) -> Bool, isLocked: (String) -> Bool) -> [String] {
        let shown = shownIds(roster, isHidden: isHidden)
        var out: [String] = []
        for a in roster where !pinned(a) && a.id != "lia" && !out.contains(a.id) {
            if !shown.contains(a.id) || a.soon || isLocked(a.id) { out.append(a.id) }
        }
        return out
    }
}
