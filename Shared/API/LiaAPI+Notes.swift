import Foundation

// Notes sync on lia-agents (lia.liaisone.com/agents/notes/*, the backend). Only
// envelopes travel: the caller encrypts before `notesPut` and decrypts after `notesList`. Contract: the shared notes format.
extension LiaAPI {
    /// One call with the status kept (a 409 / 410 is an answer here, not a failure); one retry with a fresh session on 401.
    private func notesCall(_ method: String, _ path: String, query: [URLQueryItem] = [], body: JSONObject? = nil) async throws -> (Int, Data) {
        var comps = URLComponents(string: AppConfig.agentsBase + path)
        if !query.isEmpty { comps?.queryItems = query }
        guard let url = comps?.url else { throw AuthError.network }
        for attempt in 0..<2 {
            let token = try await token(forceRefresh: attempt == 1)
            var req = URLRequest(url: url, timeoutInterval: 30)
            LiaClient.stamp(&req)   // X-Lia-Client, our hosts only
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
            if status >= 500 || status == 0 { throw AuthError.server("HTTP \(status)") }
            return (status, result.0)
        }
        throw AuthError.sessionExpired
    }

    /// GET /agents/notes/list: the notes changed after the stored position, up to 20 pages (a longer backlog
    /// continues from the returned position on the next sync, instead of being dropped).
    struct NotesListResult {
        var notes: [NoteRemote] = []
        var since: Int
        var after: String?
        var cursor: Int?
        var purgedAt: Int?
        var now: Int?
    }

    func notesList(ws: String, since: Int, after: String?, cursor: Int?) async throws -> NotesListResult {
        var res = NotesListResult(since: since, after: after, cursor: cursor)
        for _ in 0..<20 {
            let q = NotesWire.listQuery(ws: ws, since: res.since, after: res.after, cursor: res.cursor).map { URLQueryItem(name: $0.0, value: $0.1) }
            let (_, d) = try await notesCall("GET", "/agents/notes/list", query: q)
            guard let page = NotesWire.listPage(d) else { throw AuthError.server(JSONRead.string(JSONRead.object(d), "error") ?? "notes") }
            res.notes += page.notes
            res.since = page.nextSince
            res.after = page.more ? page.nextAfter : nil
            res.cursor = page.nextCursor
            if let p = page.purgedAt { res.purgedAt = p }
            if let n = page.now { res.now = n }
            if !page.more { break }
        }
        return res
    }

    func notesPut(ws: String, id: String, env: NoteEnvelope, u: Int, base: Int?) async throws -> NotesPutResult {
        let (st, d) = try await notesCall("POST", "/agents/notes/put", body: NotesWire.putBody(ws: ws, id: id, env: env, u: u, base: base))
        return NotesWire.write(status: st, d)
    }

    func notesDelete(ws: String, id: String, u: Int, base: Int?) async throws -> NotesPutResult {
        let (st, d) = try await notesCall("POST", "/agents/notes/delete", body: NotesWire.deleteBody(ws: ws, id: id, u: u, base: base))
        return NotesWire.write(status: st, d)
    }

    /// POST /agents/notes/purge: every synced note of the workspace becomes a tombstone (the person's own click).
    func notesPurge(ws: String) async throws -> Bool {
        let (st, d) = try await notesCall("POST", "/agents/notes/purge", body: ["ws": ws, "confirm": "delete"])
        return st == 200 && JSONRead.bool(JSONRead.object(d), "ok")
    }

    /// GET /agents/notes/key: the member's key fingerprint, nil when no device made one yet.
    func notesKid() async throws -> String? {
        let (_, d) = try await notesCall("GET", "/agents/notes/key")
        return NotesWire.kid(d)
    }

    /// POST /agents/notes/key: claims the fingerprint. -> the fingerprint the server keeps (another one: a device won the race).
    func notesClaimKid(_ kid: String) async throws -> String? {
        let (_, d) = try await notesCall("POST", "/agents/notes/key", body: ["kid": kid])
        return NotesWire.kid(d)
    }
}
