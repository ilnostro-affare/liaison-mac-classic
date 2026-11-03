import Foundation

/// 0.2.10 ("Dev doesn't appear right away"): the team as /agents/roster answered last, per Liaison
/// account, so a launch draws the dock from it at once (Dev included for a flagged member) and /agents/roster only
/// corrects it quietly. Dev is listed only by the server (never in `AgentInfo.fallback`), so without this the dock
/// drew Lia, Met, Crea and Dev jumped in a moment later. Stored in the `/agents/roster` shape so `parseRoster` reads it.
enum RosterCache {
    /// UserDefaults key per Liaison account (`lia_ws_` so Start over clears it with the rest).
    static func key(account: String?) -> String {
        let a = (account ?? "").trimmingCharacters(in: .whitespaces)
        return "lia_ws_roster_" + (a.isEmpty ? "_" : a)
    }

    /// The roster in the server's own shape: {"ok": true, "agents": [...]}.
    static func encode(_ roster: [AgentInfo]) -> Data? {
        guard !roster.isEmpty else { return nil }
        let agents: [[String: Any]] = roster.map { a in
            var o: [String: Any] = [
                "id": a.id, "name": a.name, "role": a.role, "shape": a.shape.rawValue,
                "color": String(format: "#%06X", a.colorHex),
            ]
            if a.write { o["write"] = true }
            if a.lead { o["lead"] = true }
            if a.onCall { o["on_call"] = true }
            if a.writesFirst { o["writes_first"] = true }
            if a.soon { o["soon"] = true }
            if !a.bio.isEmpty { o["bio"] = a.bio }
            return o
        }
        return try? JSONSerialization.data(withJSONObject: ["ok": true, "agents": agents], options: [.sortedKeys])
    }

    /// The cached roster, or nil (nothing stored, unreadable, empty): the caller keeps `AgentInfo.fallback`.
    static func decode(_ data: Data?) -> [AgentInfo]? {
        guard let d = data else { return nil }
        return AgentInfo.parseRoster(d)
    }
}
