import Foundation

// 0.2.11 /: the canary's click latency on lia-agents (lia.liaisone.com/agents/telemetry/latency, the site's
// backend/workers/lia-telemetry.js). GET says whether this member is on the canary; POST sends one finished day's
// aggregate (LatencyDay.payload). Screen Time has no route: it never leaves the Mac. Contract: the site's docs/TELEMETRY.md.
extension LiaAPI {
    private func telemetryCall(_ method: String, body: [String: Any]? = nil) async throws -> (Int, Data) {
        guard let url = URL(string: AppConfig.agentsBase + "/agents/telemetry/latency") else { throw AuthError.network }
        for attempt in 0..<2 {
            let token = try await token(forceRefresh: attempt == 1)
            var req = URLRequest(url: url, timeoutInterval: 20)
            LiaClient.stamp(&req)
            req.httpMethod = method
            req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            if let body {
                req.setValue("application/json", forHTTPHeaderField: "Content-Type")
                req.httpBody = try JSONSerialization.data(withJSONObject: body)
            }
            let result: (Data, URLResponse)
            do { result = try await session.data(for: req) } catch { throw AuthError.network }
            let status = (result.1 as? HTTPURLResponse)?.statusCode ?? 0
            if status == 401 && attempt == 0 { continue }
            if status == 401 { throw AuthError.sessionExpired }   // a background call: never marks the session expired itself
            return (status, result.0)
        }
        throw AuthError.sessionExpired
    }

    /// Is this member on the latency canary? nil when the server could not be asked (the last answer then stands).
    func latencyCanary() async -> Bool? {
        guard let r = try? await telemetryCall("GET"), r.0 == 200 else { return nil }
        return LatencyUpload.isOn(r.1)
    }

    /// Sends one day. true when the server stored it (a 400 for a day it will never take also counts as done).
    func latencyUpload(_ payload: [String: Any]) async -> Bool {
        guard let r = try? await telemetryCall("POST", body: payload) else { return false }
        return r.0 == 200 || r.0 == 400
    }
}
