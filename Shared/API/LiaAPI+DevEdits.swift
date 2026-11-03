import Foundation

// Select element (server, lia-agents backend/workers/lia-dev-edits.js): a change to one element of Dev's site,
// sent as a Dev task. POST /agents/dev/edit and /agents/dev/edit/run answer with Dev's stream (its first line the task)
// or, when Dev is busy or the request is refused, with JSON; GET /agents/dev/edits lists the workspace's tasks.
extension LiaAPI {
    enum DevEditStart {
        /// Dev took it: the lines of its turn ("data:..."), the task first.
        case stream(AsyncThrowingStream<String, Error>)
        /// Not started: queued (Dev busy) or refused, in the server's words.
        case reply(DevEditReply)
    }

    /// POST /agents/dev/edit (`body` from DevEditDraft.body) or /agents/dev/edit/run ({profile, site, id}).
    func devEditStart(path: String, body: JSONObject) async -> DevEditStart {
        guard let url = URL(string: AppConfig.agentsBase + path), let data = try? JSONSerialization.data(withJSONObject: body) else {
            return .reply(DevEditReply(ok: false, queued: false, task: nil, message: "Could not reach Dev."))
        }
        for attempt in 0..<2 {
            guard let token = try? await token(forceRefresh: attempt == 1) else { break }
            var req = URLRequest(url: url, timeoutInterval: 300)
            LiaClient.stamp(&req)   // X-Lia-Client, our hosts only
            req.httpMethod = "POST"
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            req.httpBody = data
            guard let (bytes, resp) = try? await session.bytes(for: req) else { break }
            let http = resp as? HTTPURLResponse
            let status = http?.statusCode ?? 0
            if status == 401 && attempt == 0 { continue }
            if status == 401 { auth.markSessionExpired(); break }
            if (http?.value(forHTTPHeaderField: "Content-Type") ?? "").contains("event-stream") && (200..<300).contains(status) {
                let stream = AsyncThrowingStream<String, Error> { continuation in
                    let task = Task {
                        do {
                            for try await line in bytes.lines {
                                if Task.isCancelled { break }
                                if line.hasPrefix("data:") { continuation.yield(line) }
                            }
                            continuation.finish()
                        } catch { continuation.finish(throwing: error) }
                    }
                    continuation.onTermination = { _ in task.cancel() }
                }
                return .stream(stream)
            }
            var raw = Data()
            do { for try await b in bytes { raw.append(b); if raw.count > 64000 { break } } } catch {}
            return .reply(DevEditReply.parse(raw))
        }
        return .reply(DevEditReply(ok: false, queued: false, task: nil, message: "Could not reach Dev."))
    }

    /// GET /agents/dev/edits?profile - the workspace's edit tasks, newest first.
    func devEdits(profile: String) async -> [DevEditTask]? {
        var c = URLComponents(string: AppConfig.agentsBase + "/agents/dev/edits")
        c?.queryItems = [URLQueryItem(name: "profile", value: profile)]
        guard let u = c?.url, let token = try? await token(forceRefresh: false) else { return nil }
        var req = URLRequest(url: u, timeoutInterval: 30)
        LiaClient.stamp(&req)
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        guard let (d, r) = try? await session.data(for: req), (r as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return DevEditTask.parseList(d)
    }

    /// POST /agents/dev/edit/delete.
    func devEditDelete(profile: String, site: String, id: String) async -> Bool {
        guard let u = URL(string: AppConfig.agentsBase + "/agents/dev/edit/delete"), let token = try? await token(forceRefresh: false),
              let body = try? JSONSerialization.data(withJSONObject: ["profile": profile, "site": site, "id": id]) else { return false }
        var req = URLRequest(url: u, timeoutInterval: 30)
        LiaClient.stamp(&req)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.httpBody = body
        guard let (d, r) = try? await session.data(for: req), (r as? HTTPURLResponse)?.statusCode == 200 else { return false }
        return JSONRead.bool(JSONRead.object(d), "ok")
    }

    /// (server lia-dev.js devSitesApi, `fresh`): "Publish to a new address" - the static preview goes live as a
    /// new site at `name` (the `next` address GET /agents/dev/sites showed; the server takes another free one if it was
    /// taken since), and every existing site stays as it is. The person's click is the yes.
    func devPublishNew(profile: String, name: String?) async -> Result<DevSite, DevFilesError> {
        var body: JSONObject = ["profile": profile, "fresh": true]
        if let name, !name.isEmpty { body["name"] = name }
        guard let u = URL(string: AppConfig.agentsBase + "/agents/dev/publish"),
              let data = try? JSONSerialization.data(withJSONObject: body) else { return .failure(DevFilesError("Could not reach the server.")) }
        for attempt in 0..<2 {
            guard let token = try? await token(forceRefresh: attempt == 1) else { break }
            var req = URLRequest(url: u, timeoutInterval: 120)
            LiaClient.stamp(&req)
            req.httpMethod = "POST"
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            req.httpBody = data
            guard let (d, r) = try? await session.data(for: req) else { break }
            let status = (r as? HTTPURLResponse)?.statusCode ?? 0
            if status == 401 && attempt == 0 { continue }
            if status == 401 { auth.markSessionExpired(); break }
            return DevSites.parsePublished(d)
        }
        return .failure(DevFilesError("Could not reach the server."))
    }
}
