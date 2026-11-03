import Foundation

// The person's photo and the workspaces' pictures (lia-agents /agents/avatar, the site's
// backend/workers/lia-agents-avatars.js). The bytes go up as an input file (uploadFileStream, src "avatar"); the
// route keeps only the key, one per avatar.
extension LiaAPI {
    private func avatarCall(_ method: String, body: [String: Any]? = nil) async throws -> Data {
        guard let url = URL(string: AppConfig.agentsBase + "/agents/avatar") else { throw AuthError.network }
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
            if status == 401 { auth.markSessionExpired(); throw AuthError.sessionExpired }
            if status >= 500 || status == 0 || status == 404 { throw AuthError.server("HTTP \(status)") }
            return result.0
        }
        throw AuthError.sessionExpired
    }

    /// Every picture of this member: the person's and the workspaces'.
    func avatars() async throws -> AvatarSet {
        guard let s = AvatarSet.parse(try await avatarCall("GET")) else { throw AuthError.server("avatars") }
        return s
    }

    /// Saves (or, with an empty key, clears) one picture. The stored entry, nil when cleared.
    func setAvatar(_ who: AvatarWho, key: String) async throws -> AvatarEntry? {
        let o = JSONRead.object(try await avatarCall("POST", body: who.body(key: key)))
        guard JSONRead.bool(o, "ok") else { throw AuthError.server(JSONRead.string(o, "error") ?? "Could not save the picture.") }
        return AvatarSet.entry(o?["avatar"] as? JSONObject)
    }
}
