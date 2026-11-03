import Foundation

// One small diagnostic event to lia-agents, `POST {agentsBase}/agents/log` with {kind, ...fields}
// (kinds: "load_fail" and "cookie_change", Shared/Core/LoadFailLog.swift). Fire-and-forget: one try, a short timeout, every failure
// ignored, never marks the session expired. Contract (server agent): Bearer auth, body {kind, host, code,
// phase, showing, retries, ms, client} (or {events: [...]}, up to 10); a 429 means stop, never retry.
extension LiaAPI {
    /// The HTTP status, nil when nothing was answered. The caller stops sending on 429.
    @discardableResult
    func logEvent(kind: String, fields: [String: Any]) async -> Int? {
        guard let url = URL(string: AppConfig.agentsBase + "/agents/log"),
              let token = try? await token() else { return nil }
        var body = fields
        body["kind"] = kind
        guard JSONSerialization.isValidJSONObject(body), let data = try? JSONSerialization.data(withJSONObject: body) else { return nil }
        var req = URLRequest(url: url, timeoutInterval: 10)
        LiaClient.stamp(&req)
        req.httpMethod = "POST"
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = data
        guard let r = try? await session.data(for: req) else { return nil }
        return (r.1 as? HTTPURLResponse)?.statusCode
    }
}
