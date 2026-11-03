import Foundation

enum ChatStreamError: Error {
    case http(Int, String?)

    var message: String {
        switch self {
        case let .http(status, msg):
            if let msg, !msg.isEmpty { return msg }
            return status == 429 ? "Usage limit reached. Try again later." : "Lia could not answer (HTTP \(status))."
        }
    }
}

@MainActor
struct LiaAPI {
    let auth: AuthStore
    var session: URLSession = .shared
    /// The account this API speaks for, fixed when it is made. After a switch or sign-out its calls stop instead of
    /// running with the next account's session (a plan publish or save started for A must never land in B).
    let account: String?

    init(auth: AuthStore, session: URLSession = .shared) {
        self.init(auth: auth, account: auth.activeId, session: session)
    }
    init(auth: AuthStore, account: String?, session: URLSession = .shared) {
        self.auth = auth
        self.account = account
        self.session = session
    }

    /// A session for `account` only; a switch while the mint ran is caught after it too.
    func token(forceRefresh: Bool = false) async throws -> String {
        guard auth.activeId == account else { throw CancellationError() }
        let t = try await auth.validSession(forceRefresh: forceRefresh)
        guard auth.activeId == account else { throw CancellationError() }
        return t
    }

    /// liaisone.com or one of its subdomains: the only hosts that get the session header.
    nonisolated static func isOurs(_ url: URL) -> Bool { OurHost.matches(url.host) }

    func state() async throws -> LiaState {
        let data = try await authorized("GET", AppConfig.aiBase + "/intelligence/state")
        return try JSONDecoder().decode(LiaState.self, from: data)
    }

    func chatDoc(id: String) async throws -> ChatDoc {
        let q = id.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? id
        // Long chats are megabytes of JSON: 20 s timed out on ordinary mobile links and showed
        // "Could not reach Liaison" on a working connection. One retry covers a dropped first try.
        var lastError: Error = AuthError.network
        for _ in 0..<2 {
            do {
                let data = try await authorized("GET", AppConfig.aiBase + "/intelligence/chat-doc?id=\(q)", timeout: 60)
                guard let doc = ChatDoc.parse(data, fallbackId: id) else { throw AuthError.server("chat-doc") }
                ChatDocCache.store(data, id: id)
                return doc
            } catch AuthError.network {
                lastError = AuthError.network
            }
        }
        throw lastError
    }

    /// Read lane upload (POST /intelligence/attach): the model reads the file, the ad account never sees it.
    func uploadAttachment(filename: String, mime: String, data: Data) async throws -> ChatAttachment {
        let body: [String: Any] = ["filename": filename, "mime": mime, "data": data.base64EncodedString()]
        let raw = try await authorized("POST", AppConfig.aiBase + "/intelligence/attach", body: body, timeout: 120, acceptErrors: true)
        switch ChatAttachment.parseUpload(raw) {
        case .success(let a): return a
        case .failure(let e): throw e
        }
    }

    /// Same list the web account chip uses (api.js call('list_ad_accounts')).
    func adAccounts() async throws -> [AdAccount] {
        let data = try await authorized("GET", AppConfig.mcpBase + "/call/list_ad_accounts")
        return AdAccount.parseList(data)
    }

    /// The member's main account (settings), the one a fresh chat starts on (shell.js loadMainAccount).
    /// /meta/* sits behind the session gate (the API worker), which also rewrites member_id.
    func defaultAccountId() async -> String? {
        guard let mid = auth.memberId,
              let data = try? await authorized("GET", AppConfig.apiBase + "/meta/default-account?member_id=" + mid) else { return nil }
        return JSONRead.string(JSONRead.object(data), "account")
    }

    /// Memberstack GET /member with the member token, the same call the website makes for the sidebar.
    func memberProfile() async -> MemberProfile? {
        guard let token = auth.memberToken, let url = URL(string: AppConfig.memberstackClient + "/member") else { return nil }
        var req = URLRequest(url: url, timeoutInterval: 20)
        LiaClient.stamp(&req)   // X-Lia-Client, our hosts only
        req.setValue(AppConfig.memberstackPublicKey, forHTTPHeaderField: "X-API-Key")
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        guard let result = try? await session.data(for: req) else { return nil }
        return MemberProfile.parse(result.0)
    }

    /// Stripe truth for the subscription row. The endpoint verifies the Memberstack token itself.
    func billingSummary() async -> BillingSummary? {
        guard let token = auth.memberToken, let url = URL(string: AppConfig.apiBase + "/billing/summary") else { return nil }
        var req = URLRequest(url: url, timeoutInterval: 20)
        LiaClient.stamp(&req)   // X-Lia-Client, our hosts only
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        guard let result = try? await session.data(for: req) else { return nil }
        return BillingSummary.parse(result.0)
    }

    func metaConnection() async -> MetaConnection? {
        guard let mid = auth.memberId,
              let data = try? await authorized("GET", AppConfig.apiBase + "/meta/status?member_id=" + mid, acceptErrors: true) else { return nil }
        return MetaConnection.parse(data)
    }

    /// Relay feed for one ad account (ai.js jFetch: get_write_journal through the MCP gateway).
    func relay(account: String?) async throws -> [RelayEvent] {
        let q = (account ?? "").filter { $0.isASCII && $0.isNumber }
        let data = try await authorized("GET", AppConfig.mcpBase + "/call/get_write_journal" + (q.isEmpty ? "" : "?account=" + q))
        return RelayFeed.parse(data)
    }

    // MARK: MCP gateway tools (api.js call: GET mcp/call/<tool>?params, objects as JSON)

    func mcpCall(_ tool: String, _ params: [String: Any] = [:], noCache: Bool = false, acceptErrors: Bool = false) async throws -> Data {
        var comps = URLComponents(string: AppConfig.mcpBase + "/call/" + tool)!
        comps.queryItems = params.compactMap { k, v in
            if let s = v as? String { return s.isEmpty ? nil : URLQueryItem(name: k, value: s) }
            if JSONSerialization.isValidJSONObject(v), let d = try? JSONSerialization.data(withJSONObject: v) {
                return URLQueryItem(name: k, value: String(data: d, encoding: .utf8))
            }
            return URLQueryItem(name: k, value: "\(v)")
        }
        if comps.queryItems?.isEmpty == true { comps.queryItems = nil }
        return try await authorized("GET", comps.url!.absoluteString, acceptErrors: acceptErrors)
    }

    /// api.js post: POST mcp/call/<tool> with a JSON body (creative_upload and its poster / board).
    func mcpPost(_ tool: String, _ body: [String: Any], timeout: TimeInterval = 120) async throws -> JSONObject {
        JSONRead.object(try await authorized("POST", AppConfig.mcpBase + "/call/" + tool, body: body, timeout: timeout, acceptErrors: true)) ?? [:]
    }

    /// A picture into the media library (ai.js composerUpload): {ok, r2_key, preview} or {ok:false, error}.
    func creativeUpload(filename: String, mime: String, data: Data, extra: [String: Any] = [:]) async throws -> JSONObject {
        var body: [String: Any] = ["filename": filename, "mime": mime, "data": data.base64EncodedString()]
        body.merge(extra) { _, n in n }
        return try await mcpPost("creative_upload", body)
    }

    /// A video streams raw: base64 would triple the memory for nothing.
    func creativeUploadStream(mime: String, data: Data) async throws -> JSONObject {
        let q = mime.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? mime
        guard let url = URL(string: AppConfig.mcpBase + "/call/creative_upload_stream?mime=" + q) else { throw AuthError.network }
        for attempt in 0..<2 {
            let token = try await token(forceRefresh: attempt == 1)
            var req = URLRequest(url: url, timeoutInterval: 600)
            LiaClient.stamp(&req)   // X-Lia-Client, our hosts only
            req.httpMethod = "POST"
            req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            req.setValue(mime, forHTTPHeaderField: "Content-Type")
            let result: (Data, URLResponse)
            do { result = try await session.upload(for: req, from: data) } catch { throw AuthError.network }
            if (result.1 as? HTTPURLResponse)?.statusCode == 401 && attempt == 0 { continue }
            return JSONRead.object(result.0) ?? [:]
        }
        throw AuthError.sessionExpired
    }

    func relayDirectory() async throws -> (projects: [RelayProject], folders: [RelayFolder]) {
        RelayDirectory.parse(try await mcpCall("projects"))
    }

    func saveFolders(_ folders: [RelayFolder]) async throws -> [RelayFolder] {
        let data = try await mcpCall("folders_set", ["folders": folders.map(\.json)])
        let o = JSONRead.object(data)
        guard JSONRead.bool(o, "ok") else { throw AuthError.server("folders_set") }
        return RelayDirectory.parse(data).folders.isEmpty ? folders : RelayDirectory.parse(data).folders
    }

    func projectSeen(_ account: String) async {
        _ = try? await mcpCall("project_seen", ["account": account])
    }

    func comment(account: String, eid: String, text: String, replyTo: String?) async throws -> RelayComment? {
        var params: [String: Any] = ["account": account, "eid": eid, "text": String(text.prefix(500))]
        if let replyTo { params["re"] = replyTo }
        let o = JSONRead.object(try await mcpCall("journal_comment", params))
        guard JSONRead.bool(o, "ok") else { throw AuthError.server(JSONRead.string(o, "hint") ?? JSONRead.string(o, "error") ?? "comment") }
        return (o?["comment"] as? JSONObject).flatMap(RelayComment.init(json:))
    }

    func deleteComment(account: String, eid: String, cid: String) async throws {
        let o = JSONRead.object(try await mcpCall("journal_comment", ["account": account, "eid": eid, "del": cid]))
        guard JSONRead.bool(o, "ok") else { throw AuthError.server(JSONRead.string(o, "hint") ?? JSONRead.string(o, "error") ?? "delete") }
    }

    /// Our own worker URLs (upload previews, plots) sit behind the session gate, so AsyncImage cannot
    /// fetch them: it sends no Authorization header and gets a 401 back. This one does.
    func authorizedData(_ urlString: String) async -> Data? {
        guard let url = URL(string: urlString) else { return nil }
        let ours = LiaAPI.isOurs(url)
        guard let token = try? await token() else { return nil }
        var req = URLRequest(url: url, timeoutInterval: 30)
        LiaClient.stamp(&req)   // X-Lia-Client, our hosts only
        if ours { req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        guard let result = try? await session.data(for: req),
              ((result.1 as? HTTPURLResponse)?.statusCode ?? 0) < 400 else { return nil }
        return result.0
    }

    /// Where a Meta video can be watched: its Facebook permalink (video_source).
    func videoPermalink(videoId: String) async -> URL? {
        guard let data = try? await mcpCall("video_source", ["video_id": videoId]) else { return nil }
        let o = JSONRead.object(data)
        return (JSONRead.string(o, "permalink") ?? JSONRead.string(o, "source")).flatMap(URL.init(string:))
    }

    /// Where a Meta video can be played in the app: our /meta/video proxy (video_source's `source`), which streams
    /// the file with the session header. Never the Facebook permalink.
    func videoSource(videoId: String) async -> String? {
        guard let data = try? await mcpCall("video_source", ["video_id": videoId]) else { return nil }
        return JSONRead.string(JSONRead.object(data), "source").flatMap { $0.isEmpty ? nil : $0 }
    }

    /// The creatives sheet reloads through the same tool the answer used.
    func creativePerformance(account: String?, range: DateRange) async throws -> CreativePerformance? {
        var p: [String: Any] = ["from": range.from, "to": range.to]
        if let account, !account.isEmpty { p["account"] = account }
        return CreativePerformance.parse(JSONRead.object(try await mcpCall("get_creative_analysis", p)))
    }

    func leads(account: String?, range: DateRange) async throws -> [Lead] {
        var p: [String: Any] = ["from": range.from, "to": range.to]
        if let account, !account.isEmpty { p["account"] = account }
        return Lead.parseList(try await mcpCall("get_leads", p))
    }

    func mediaLibrary(account: String?) async throws -> (uploads: [MediaItem], images: [MediaItem], videos: [MediaItem]) {
        let data = try await mcpCall("media_library", account.map { ["account": $0] } ?? [:])
        guard let lib = MediaItem.parseLibrary(data) else {
            throw AuthError.server(JSONRead.string(JSONRead.object(data), "error") ?? "Library failed to load")
        }
        return lib
    }

    /// ai.js jUndoRun: plan the reverse write, then apply it with a double confirmation mode.
    func undoWrite(journalId: String, accountName: String) async throws {
        let plan = JSONRead.object(try await mcpCall("undo_write", ["journal_id": journalId]))
        guard JSONRead.bool(plan, "ok"), let planId = JSONRead.string(plan, "plan_id") else {
            throw AuthError.server(JSONRead.string(plan, "error") ?? "undo failed")
        }
        let done = JSONRead.object(try await mcpCall("apply_write_plan", ["plan_id": planId, "mode": "double", "account_name": accountName]))
        guard JSONRead.bool(done, "ok") else { throw AuthError.server(JSONRead.string(done, "error") ?? "apply failed") }
    }

    // MARK: Lia 1.4 writes. The client applies a plan the person said Yes to (ai.js gateAnswer);
    // the runner never applies on its own.

    /// mcp `apply_write_plan` {plan_id, mode: single | double, session_id, account_name}.
    func applyWritePlan(planId: String, mode: String, sessionId: String?, accountName: String?) async throws -> JSONObject {
        var p: [String: Any] = ["plan_id": planId, "mode": mode]
        if let sessionId { p["session_id"] = sessionId }
        if let accountName, !accountName.isEmpty { p["account_name"] = accountName }
        return JSONRead.object(try await mcpCall("apply_write_plan", p, noCache: true, acceptErrors: true)) ?? [:]
    }

    /// mcp `undo_write` {journal_id} -> {ok, plan_id, applied_directly}.
    func undoPlan(journalId: String) async throws -> JSONObject {
        JSONRead.object(try await mcpCall("undo_write", ["journal_id": journalId], noCache: true, acceptErrors: true)) ?? [:]
    }

    /// mcp `copy_status` {job} -> {ok, status, done, total, created_id, error, error_class}.
    func copyStatus(job: String) async -> JSONObject? {
        guard let d = try? await mcpCall("copy_status", ["job": job], noCache: true) else { return nil }
        return JSONRead.object(d)
    }

    /// POST /intelligence/title {member_id, chat_id, text} -> {ok, title}. The first message names the chat.
    func title(chatId: String, text: String) async -> String? {
        var body: [String: Any] = ["chat_id": chatId, "text": String(text.prefix(2000))]
        if let mid = auth.memberId { body["member_id"] = mid }
        guard let d = try? await authorized("POST", AppConfig.aiBase + "/intelligence/title", body: body, acceptErrors: true) else { return nil }
        let t = JSONRead.string(JSONRead.object(d), "title")?.trimmingCharacters(in: .whitespacesAndNewlines)
        return (t?.isEmpty == false) ? String(t!.prefix(60)) : nil
    }

    /// Lia 2.0's agent: which element of a page each question means, by the Decisions API on our server.
    /// Answers by question name: the chosen value and the model's confidence. Empty on any failure.
    func locate(input: String, questions: [[String: Any]], chatId: String? = nil, agent: String = "met") async -> [String: (choice: String, confidence: Double)] {
        await locateReply(input: input, questions: questions, chatId: chatId, agent: agent).answers
    }

    /// As `locate`, and the server's words when it refused for the person's limit (429). `agent`: whose money
    /// the call is ("met": the Ads Manager overlay is Met's).
    func locateReply(input: String, questions: [[String: Any]], chatId: String? = nil, agent: String = "met")
        async -> (answers: [String: (choice: String, confidence: Double)], limit: String?) {
        var body: [String: Any] = ["input": input, "questions": questions, "agent": WebLimit.agent(agent)]
        if let chatId { body["chat_id"] = chatId }   // the server adds the call (time, tokens, cost) to the chat's agent log
        if let mid = auth.memberId { body["member_id"] = mid }
        guard let r = try? await authorizedStatus("POST", AppConfig.lia20Base + "/intelligence/locate", body: body, timeout: 15, acceptErrors: true)
        else { return ([:], nil) }
        let o = JSONRead.object(r.data)
        if let limit = WebLimit.message(status: r.status, json: o) { return ([:], limit) }
        guard let o, JSONRead.bool(o, "ok") else { return ([:], nil) }
        var out: [String: (choice: String, confidence: Double)] = [:]
        for a in JSONRead.objects(o, "answers") {
            guard let n = JSONRead.string(a, "name"), let c = JSONRead.string(a, "choice") else { continue }
            out[n] = (c, JSONRead.double(a, "confidence") ?? 0)
        }
        return (out, nil)
    }

    /// One step of a task on the open web - the goal, the steps so far with their results, the page now
    /// (and a picture of it after look, and notes on this site from earlier tasks) in; a batch, a look, a question or
    /// the end out, with what it cost. `.failed` when the call failed (worth a retry); `.limit` with the server's words
    /// when the person's limit is reached (429,: no retry). `agent`: whose task it is ("lia" or "met").
    struct BrowseUsage { var tokensIn = 0, cached = 0, out = 0; var usd = 0.0 }
    enum BrowseReply {
        case step(WebStep, ms: Int, usage: BrowseUsage)
        case limit(String)
        case failed
    }
    func browseStep(taskId: String, goal: String, steps: [(action: String, result: String)], url: String, title: String,
                    text: String, blocked: String, image: String? = nil, siteNotes: String? = nil, chatId: String?,
                    agent: String = "lia") async -> BrowseReply {
        var body: [String: Any] = ["task_id": taskId, "goal": goal, "agent": WebLimit.agent(agent),
                                   "steps": steps.map { ["action": $0.action, "result": $0.result] },
                                   "page": ["url": url, "title": title, "text": text, "blocked": blocked]]
        if let image { body["image"] = image }
        if let siteNotes, !siteNotes.isEmpty { body["site_notes"] = siteNotes }
        if let chatId { body["chat_id"] = chatId }
        if let mid = auth.memberId { body["member_id"] = mid }
        guard let r = try? await authorizedStatus("POST", AppConfig.lia20Base + "/intelligence/browse-step", body: body, timeout: 60, acceptErrors: true) else { return .failed }
        let parsed = JSONRead.object(r.data)
        if let limit = WebLimit.message(status: r.status, json: parsed) { return .limit(limit) }
        guard let o = parsed, JSONRead.bool(o, "ok") else { return .failed }
        let legacy: (name: String, args: JSONObject)? = (o["action"] as? JSONObject).flatMap { a in JSONRead.string(a, "name").map { ($0, a["args"] as? JSONObject ?? [:]) } }
        let step = WebStep.from(kind: JSONRead.string(o, "kind") ?? "", actions: JSONRead.objects(o, "actions"),
                                args: o["args"] as? JSONObject ?? [:], legacy: legacy)
        let u = o["usage"] as? JSONObject
        let usage = BrowseUsage(tokensIn: Int(JSONRead.double(u, "in") ?? 0), cached: Int(JSONRead.double(u, "cached") ?? 0),
                                out: Int(JSONRead.double(u, "out") ?? 0), usd: JSONRead.double(u, "usd") ?? 0)
        return .step(step, ms: Int(JSONRead.double(o, "ms") ?? 0), usage: usage)
    }

    /// Lia 2.0's agent log: what the overlay did, beat by beat, for /intelligence/agent-log?chat=.
    func agentLog(chatId: String, events: [[String: Any]]) async {
        var body: [String: Any] = ["chat_id": chatId, "events": events]
        if let mid = auth.memberId { body["member_id"] = mid }
        _ = try? await authorized("POST", AppConfig.lia20Base + "/intelligence/agent-log", body: body, timeout: 15, acceptErrors: true)
    }

    /// The whole Stripe summary for Settings, Billing (prices, card, invoices).
    func billingDetail() async -> BillingDetail? {
        guard let token = auth.memberToken, let url = URL(string: AppConfig.apiBase + "/billing/summary") else { return nil }
        var req = URLRequest(url: url, timeoutInterval: 20)
        LiaClient.stamp(&req)   // X-Lia-Client, our hosts only
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        guard let result = try? await session.data(for: req) else { return nil }
        return BillingDetail.parse(result.0)
    }

    /// How long a prepared change can be confirmed: 900 / 1800 / 3600 s (api /meta/plan-ttl).
    func planTTL() async -> Int? {
        guard let mid = auth.memberId, let d = try? await authorized("GET", AppConfig.apiBase + "/meta/plan-ttl?member_id=" + mid) else { return nil }
        return JSONRead.int(JSONRead.object(d), "ttl")
    }

    func setPlanTTL(_ ttl: Int) async throws {
        guard let mid = auth.memberId else { throw AuthError.sessionExpired }
        _ = try await authorized("POST", AppConfig.apiBase + "/meta/plan-ttl?member_id=" + mid, body: ["ttl": ttl])
    }

    /// Settings, Account, Meta connection: Disconnect.
    func metaDisconnect() async throws {
        guard let mid = auth.memberId else { throw AuthError.sessionExpired }
        _ = try await authorized("POST", AppConfig.apiBase + "/meta/disconnect?member_id=" + mid)
    }

    /// Usage with this chat's share for the ring under the input.
    func usage(chat: String) async -> UsageInfo? {
        // The session names the member too; without a member id from the token the server still answers by session.
        let who = auth.memberId.map { "member_id=" + $0 + "&" } ?? ""
        guard let data = try? await authorized("GET", AppConfig.aiBase + "/intelligence/usage?" + who + "chat=" + chat) else { return nil }
        return UsageInfo.parse(data)
    }

    /// Settings > Memory: everything Lia remembers, You and per ad account.
    func memory() async throws -> MemoryBook? {
        var u = AppConfig.aiBase + "/intelligence/memory"
        if let mid = auth.memberId { u += "?member_id=" + mid }
        return MemoryBook.parse(try await authorized("GET", u, acceptErrors: true))
    }

    /// POST /intelligence/memory-op: toggle, edit, delete, add, delete_scope. Returns the reply, ok or not.
    func memoryOp(_ body: [String: Any]) async throws -> JSONObject {
        var b = body
        if let mid = auth.memberId { b["member_id"] = mid }
        return JSONRead.object(try await authorized("POST", AppConfig.aiBase + "/intelligence/memory-op", body: b, acceptErrors: true)) ?? [:]
    }

    func usage() async -> UsageInfo? {
        guard let mid = auth.memberId,
              let data = try? await authorized("GET", AppConfig.aiBase + "/intelligence/usage?member_id=" + mid) else { return nil }
        return UsageInfo.parse(data)
    }

    func notificationPrefs() async -> NotificationPrefs {
        guard let mid = auth.memberId else { return NotificationPrefs.parse(nil) }
        return NotificationPrefs.parse(try? await authorized("GET", AppConfig.apiBase + "/meta/notifications/prefs?member_id=" + mid))
    }

    func saveNotificationPrefs(_ p: NotificationPrefs) async throws {
        guard let mid = auth.memberId else { throw AuthError.sessionExpired }
        _ = try await authorized("POST", AppConfig.apiBase + "/meta/notifications/prefs", body: ["member_id": mid, "prefs": p.json])
    }

    func setDefaultAccount(_ id: String?) async throws {
        guard let mid = auth.memberId else { throw AuthError.sessionExpired }
        _ = try await authorized("POST", AppConfig.apiBase + "/meta/default-account?member_id=" + mid, body: ["account": id ?? ""])
    }

    /// Memberstack POST /member with custom fields, as updateMember in @memberstack/dom.
    func updateName(first: String, last: String) async throws -> MemberProfile? {
        try await memberstack("POST", "/member", body: ["customFields": ["first-name": first, "last-name": last]]).flatMap(MemberProfile.parse)
    }

    /// Memberstack DELETE /member: the in-app account deletion the App Store requires.
    func deleteMember() async throws {
        _ = try await memberstack("DELETE", "/member", body: nil)
    }

    // MARK: Stripe through Memberstack (settings.js startCheckout / openPortal; @memberstack/dom
    // purchasePlansWithCheckout and launchStripeCustomerPortal make these same calls and redirect to the URL).

    /// getPlans: the price id of a plan (settings.js planPrice), read live like the site.
    func planPriceId(_ planId: String) async -> String? {
        guard let url = URL(string: AppConfig.memberstackClient + StripeCheckout.plansPath) else { return nil }
        var req = URLRequest(url: url, timeoutInterval: 20)
        LiaClient.stamp(&req)   // X-Lia-Client, our hosts only
        req.setValue(AppConfig.memberstackPublicKey, forHTTPHeaderField: "X-API-Key")
        if let token = auth.memberToken { req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        guard let result = try? await session.data(for: req) else { return nil }
        return StripeCheckout.priceId(plans: result.0, planId: planId)
    }

    /// The Stripe Checkout URL for a plan. Throws with the message the site would show in its modal.
    func checkoutURL(planId: String) async throws -> URL {
        guard let price = await planPriceId(planId), let body = StripeCheckout.checkoutBody(priceId: price) else {
            throw AuthError.server("The price for this plan did not load, so nothing was opened. Try again.")
        }
        // settings.js: one retry after 700 ms, a second checkout right after the first is sometimes refused.
        do { return try await stripeRedirect(StripeCheckout.checkoutPath, body) }
        catch AuthError.sessionExpired { throw AuthError.sessionExpired }
        catch {
            try? await Task.sleep(nanoseconds: 700_000_000)
            return try await stripeRedirect(StripeCheckout.checkoutPath, body)
        }
    }

    /// The Stripe customer portal: cancel, resume, card, and Pro to Max (settings.js).
    func portalURL() async throws -> URL {
        try await stripeRedirect(StripeCheckout.portalPath, StripeCheckout.portalBody())
    }

    private func stripeRedirect(_ path: String, _ body: [String: Any]) async throws -> URL {
        guard let token = auth.memberToken, let url = URL(string: AppConfig.memberstackClient + path) else { throw AuthError.sessionExpired }
        var req = URLRequest(url: url, timeoutInterval: 30)
        LiaClient.stamp(&req)   // X-Lia-Client, our hosts only
        req.httpMethod = "POST"
        req.setValue(AppConfig.memberstackPublicKey, forHTTPHeaderField: "X-API-Key")
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        let result: (Data, URLResponse)
        do { result = try await session.data(for: req) } catch { throw AuthError.network }
        switch StripeCheckout.reply(result.0) {
        case .url(let u): return u
        case .error(let m):
            let status = (result.1 as? HTTPURLResponse)?.statusCode ?? 0
            throw AuthError.server(m.isEmpty ? "Stripe did not open (HTTP \(status)). Try again in a moment." : m)
        }
    }

    private func memberstack(_ method: String, _ path: String, body: [String: Any]?) async throws -> Data? {
        guard let token = auth.memberToken, let url = URL(string: AppConfig.memberstackClient + path) else { throw AuthError.sessionExpired }
        var req = URLRequest(url: url, timeoutInterval: 20)
        LiaClient.stamp(&req)   // X-Lia-Client, our hosts only
        req.httpMethod = method
        req.setValue(AppConfig.memberstackPublicKey, forHTTPHeaderField: "X-API-Key")
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        if let body {
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
        let result: (Data, URLResponse)
        do { result = try await session.data(for: req) } catch { throw AuthError.network }
        let status = (result.1 as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else { throw AuthError.server(JSONRead.string(JSONRead.object(result.0), "code") ?? "HTTP \(status)") }
        return result.0
    }

    /// Where "Connect with Facebook" goes on the website (settings.js META_OAUTH_START).
    /// shell.js cxMaybePrompt: {ok, state: connected|missing|expired|..., should_prompt}. `stage` only leaves a trace.
    func metaConnectionState(stage: String? = nil) async -> (state: String, prompt: Bool)? {
        guard let mid = auth.memberId else { return nil }
        var u = AppConfig.apiBase + "/meta/connection-state?member_id=" + mid
        if let stage { u += "&stage=" + stage }
        guard let url = URL(string: u) else { return nil }
        var req = URLRequest(url: url)
        LiaClient.stamp(&req)   // X-Lia-Client, our hosts only
        guard let res = try? await session.data(for: req),
              let o = JSONRead.object(res.0), JSONRead.bool(o, "ok") else { return nil }
        return (JSONRead.string(o, "state") ?? "", JSONRead.bool(o, "should_prompt"))
    }

    /// shell.js bxMaybePrompt: {ok, should_prompt, state: past_due|..., plan_name}.
    func billingState() async -> (prompt: Bool, state: String, plan: String?)? {
        guard let mid = auth.memberId, let url = URL(string: AppConfig.apiBase + "/meta/billing-state?member_id=" + mid) else { return nil }
        var req = URLRequest(url: url)
        LiaClient.stamp(&req)   // X-Lia-Client, our hosts only
        guard let res = try? await session.data(for: req), let o = JSONRead.object(res.0), JSONRead.bool(o, "ok") else { return nil }
        return (JSONRead.bool(o, "should_prompt"), JSONRead.string(o, "state") ?? "", JSONRead.string(o, "plan_name"))
    }

    func billingNudgeDismiss() async {
        guard let mid = auth.memberId, let url = URL(string: AppConfig.apiBase + "/meta/billing-state/dismiss") else { return }
        var req = URLRequest(url: url)
        LiaClient.stamp(&req)   // X-Lia-Client, our hosts only
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: ["member_id": mid])
        _ = try? await session.data(for: req)
    }

    /// "Not now": the server snoozes the prompt for a day.
    func metaNudgeDismiss() async {
        guard let mid = auth.memberId, let url = URL(string: AppConfig.apiBase + "/meta/connection-state/dismiss") else { return }
        var req = URLRequest(url: url)
        LiaClient.stamp(&req)   // X-Lia-Client, our hosts only
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: ["member_id": mid])
        _ = try? await session.data(for: req)
    }

    var metaConnectURL: URL? {
        guard let mid = auth.memberId else { return nil }
        return URL(string: AppConfig.apiBase + "/meta/oauth/start?member_id=" + mid)
    }

    /// A verdict on one answer (the server /intelligence/feedback). Fire and forget, like the web thumb.
    func feedback(chatId: String, index: Int, verdict: String, text: String, topic: String? = nil, note: String? = nil) async {
        var body: [String: Any] = ["chat_id": chatId, "idx": index, "verdict": verdict,
                                   "text": String(text.prefix(4000)), "model": LiaModel.name]
        if let topic { body["topic"] = topic }
        if let note, !note.isEmpty { body["note"] = String(note.prefix(1000)) }
        _ = try? await authorized("POST", AppConfig.aiBase + "/intelligence/feedback", body: body, acceptErrors: true)
    }

    /// POST /intelligence/chat-save. The web client makes the same call after every turn; without it a
    /// turn written from the phone would lose its ledger and account chip on reload.
    func chatSave(_ body: JSONObject) async throws {
        let data = try await authorized("POST", AppConfig.aiBase + "/intelligence/chat-save", body: body)
        guard JSONRead.bool(JSONRead.object(data), "ok") else { throw AuthError.server("chat-save") }
    }

    func createProject(name: String, account: String? = nil) async throws {
        var body: [String: Any] = ["op": "create", "name": String(name.prefix(80))]
        if let account { body["account"] = account }
        let data = try await authorized("POST", AppConfig.aiBase + "/intelligence/project-op", body: body)
        guard JSONRead.bool(JSONRead.object(data), "ok") else { throw AuthError.server("project-op") }
    }

    /// star | unstar | rename (value: title) | set_project (value: project id or nil) | delete
    func chatOp(_ op: String, id: String, value: String? = nil) async throws {
        var body: [String: Any] = ["op": op, "id": id]
        body["value"] = value ?? NSNull()
        let data = try await authorized("POST", AppConfig.aiBase + "/intelligence/chat-op", body: body)
        guard JSONRead.bool(JSONRead.object(data), "ok") else { throw AuthError.server("chat-op") }
    }

    /// POST /intelligence/chat as a stream of parsed events. Cancelling the consuming task closes the
    /// connection; the runner keeps going and saves the turn on its own (background save, r24).
    func streamChat(_ payload: [String: Any]) -> AsyncThrowingStream<ChatEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let bytes = try await openStream(payload)
                    for try await line in bytes.lines {
                        if Task.isCancelled { break }
                        if let ev = ChatEvent.parse(line: line) { continuation.yield(ev) }
                        if let a = AgentEvent.parse(line: line) { continuation.yield(.agent(a)) }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private func openStream(_ payload: [String: Any], at address: String = AppConfig.aiBase + "/intelligence/chat") async throws -> URLSession.AsyncBytes {
        guard let url = URL(string: address) else { throw AuthError.network }
        let body = try JSONSerialization.data(withJSONObject: payload)
        for attempt in 0..<2 {
            let token = try await token(forceRefresh: attempt == 1)
            // A long think with no bytes for over a minute would cut the request at the default timeout.
            var req = URLRequest(url: url, timeoutInterval: 300)
            LiaClient.stamp(&req)   // X-Lia-Client, our hosts only
            req.httpMethod = "POST"
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            req.httpBody = body
            let result: (URLSession.AsyncBytes, URLResponse)
            do { result = try await session.bytes(for: req) } catch { throw AuthError.network }
            let (bytes, resp) = result
            let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
            if status == 401 && attempt == 0 { continue }
            if status == 401 { auth.markSessionExpired(); throw AuthError.sessionExpired }
            guard (200..<300).contains(status) else {
                var raw = Data()
                for try await b in bytes { raw.append(b); if raw.count > 8000 { break } }
                let o = JSONRead.object(raw)
                throw ChatStreamError.http(status, JSONRead.string(o, "message") ?? JSONRead.string(o, "error"))
            }
            return bytes
        }
        throw AuthError.sessionExpired
    }

    // MARK: -: the agent team (lia-agents, AppConfig.agentsBase)

    func agentsRoster() async -> [AgentInfo]? {
        guard let d = try? await authorized("GET", AppConfig.agentsBase + "/agents/roster") else { return nil }
        return AgentInfo.parseRoster(d)
    }
    func agentProfiles() async throws -> [CompanyProfile] {
        let d = try await authorized("GET", AppConfig.agentsBase + "/agents/profiles")
        guard let list = CompanyProfile.parseList(d) else { throw AuthError.server("profiles") }
        return list
    }
    /// create | update | delete. The answer as the server sent it (ok, profile, team_thread, error).
    func agentProfileOp(_ body: [String: Any]) async throws -> JSONObject {
        let d = try await authorized("POST", AppConfig.agentsBase + "/agents/profiles", body: body, acceptErrors: true)
        return JSONRead.object(d) ?? [:]
    }
    /// Dev's turn running now in this workspace, if any (GET /agents/dev/live): its run id, so a dialogue
    /// opened mid-turn hides that turn's intermediate messages (they read in the Activity).
    func devLiveRun(profile: String) async -> String? {
        let q = profile.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? profile
        guard let d = try? await authorized("GET", AppConfig.agentsBase + "/agents/dev/live?profile=\(q)"),
              let o = JSONRead.object(d), JSONRead.bool(o, "running") else { return nil }
        return JSONRead.string(o, "run")
    }
    func agentJournal(profile: String) async -> [JSONObject] {
        let q = profile.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? profile
        guard let d = try? await authorized("GET", AppConfig.agentsBase + "/agents/journal?profile=\(q)") else { return [] }
        return JSONRead.objects(JSONRead.object(d), "journal")
    }
    /// Up to three next tasks from this workspace's recent messages (POST /agents/suggest, kind "tasks").
    /// The server answers an empty list on any failure of its own; a network error throws.
    func agentSuggestTasks(profile: String, recent: [(agent: String?, text: String)]) async throws -> [SuggestedTask] {
        let body: [String: Any] = ["kind": "tasks", "profile": profile, "recent": Suggest.recent(recent)]
        let d = try await authorized("POST", AppConfig.agentsBase + "/agents/suggest", body: body, timeout: 15)
        return Suggest.parseTasks(d)
    }
    /// Tidy - groups of related tabs, each with a name and an SF Symbol (kind "tab_groups").
    func agentSuggestGroups(profile: String, tabs: [(id: String, title: String, host: String)]) async throws -> [SuggestedGroup] {
        let list: [[String: Any]] = tabs.prefix(Suggest.maxTabs).map { ["id": $0.id, "title": String($0.title.prefix(120)), "host": $0.host] }
        let body: [String: Any] = ["kind": "tab_groups", "profile": profile, "tabs": list]
        let d = try await authorized("POST", AppConfig.agentsBase + "/agents/suggest", body: body, timeout: 15)
        return Suggest.parseGroups(d)
    }
    /// A name and an emoji for a group of two or more tabs (POST /agents/suggest, kind "tab_name");
    /// nil: no usable answer. English always, at most 18 characters.
    func agentSuggestTabName(profile: String, tabs: [(id: String, title: String, host: String)]) async throws -> SuggestedTabName? {
        let list: [[String: Any]] = tabs.prefix(Suggest.maxTabs).map { ["id": $0.id, "title": String($0.title.prefix(120)), "host": $0.host] }
        let body: [String: Any] = ["kind": "tab_name", "profile": profile, "tabs": list]
        let d = try await authorized("POST", AppConfig.agentsBase + "/agents/suggest", body: body, timeout: 15)
        return Suggest.parseTabName(d)
    }
    /// Meta's own rendering of an ad in a placement (the API worker /meta/ad-preview): {ok, body: iframe HTML} or
    /// {ok, unsupported}. Format e.g. MOBILE_FEED_STANDARD, INSTAGRAM_STANDARD.
    func adPreview(ad: String, format: String = "MOBILE_FEED_STANDARD") async -> String? {
        guard let mid = auth.memberId else { return nil }
        var c = URLComponents(string: AppConfig.apiBase + "/meta/ad-preview")!
        c.queryItems = [URLQueryItem(name: "ad", value: ad), URLQueryItem(name: "format", value: format), URLQueryItem(name: "member_id", value: mid)]
        guard let u = c.url?.absoluteString, let data = try? await authorized("GET", u, acceptErrors: true),
              let o = JSONRead.object(data), JSONRead.bool(o, "ok") else { return nil }
        return JSONRead.string(o, "body")
    }

    /// POST /agents/turn: the raw stream lines (each one is a team line or a Lia 2.0 event with its agent).
    func streamTeam(_ payload: [String: Any]) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let bytes = try await openStream(payload, at: AppConfig.agentsBase + "/agents/turn")
                    for try await line in bytes.lines {
                        if Task.isCancelled { break }
                        if line.hasPrefix("data:") { continuation.yield(line) }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    // MARK: -: dialogues (docs/DIALOGUES-API.md). One endless dialogue per agent per profile, plus Team.

    private func agentsURL(_ path: String, _ items: [URLQueryItem]) throws -> String {
        guard var c = URLComponents(string: AppConfig.agentsBase + path) else { throw AuthError.network }
        c.queryItems = items
        // URLComponents leaves "+" alone, which a server reads as a space.
        c.percentEncodedQuery = c.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
        guard let s = c.url?.absoluteString else { throw AuthError.network }
        return s
    }
    private func qi(_ name: String, _ value: String?) -> URLQueryItem? { value.map { URLQueryItem(name: name, value: $0) } }

    /// GET /agents/dialogues: Team first, then the roster. The first call for a profile imports its old threads.
    func dialogues(profile: String) async throws -> [DialogueSummary] {
        let d = try await authorized("GET", try agentsURL("/agents/dialogues", [URLQueryItem(name: "profile", value: profile)]), timeout: 30)
        guard let list = DialogueSummary.parseList(d) else { throw AuthError.server("dialogues") }
        return list
    }
    /// GET /agents/dlg: a page oldest -> newest; `before` is a seq (nil: the newest page).
    func dialogPage(profile: String, dlg: String, before: Int? = nil, limit: Int = 50) async throws -> (messages: [DlgMessage], hasMore: Bool) {
        let items = [qi("profile", profile), qi("dlg", dlg), qi("before", before.map(String.init)), qi("limit", String(min(100, max(1, limit))))].compactMap { $0 }
        let d = try await authorized("GET", try agentsURL("/agents/dlg", items))
        guard let p = DlgParse.page(d) else { throw AuthError.server("dlg") }
        return p
    }
    /// GET /agents/dlg/around: the window around one message (a search hit, a task card).
    func dialogAround(profile: String, dlg: String, id: String, span: Int = 30) async throws -> (messages: [DlgMessage], hasMoreBefore: Bool, hasMoreAfter: Bool) {
        let items = [URLQueryItem(name: "profile", value: profile), URLQueryItem(name: "dlg", value: dlg),
                     URLQueryItem(name: "id", value: id), URLQueryItem(name: "span", value: String(span))]
        let d = try await authorized("GET", try agentsURL("/agents/dlg/around", items))
        guard let p = DlgParse.around(d) else { throw AuthError.server("dlg/around") }
        return p
    }
    /// GET /agents/dlg/at: the seq of the first message on/after `ts` (date jump); nil when there is none.
    func dialogAt(profile: String, dlg: String, ts: Date) async throws -> Int? {
        let items = [URLQueryItem(name: "profile", value: profile), URLQueryItem(name: "dlg", value: dlg),
                     URLQueryItem(name: "ts", value: String(DlgTime.ms(ts)))]
        let d = try await authorized("GET", try agentsURL("/agents/dlg/at", items))
        return DlgParse.at(d)
    }
    /// POST /agents/dlg/delete. `facts` were saved from those messages and are NOT deleted: the Mac asks.
    func dialogDelete(profile: String, dlg: String, ids: [String]) async throws -> (deleted: [String], facts: [(id: String, text: String)]) {
        let d = try await authorized("POST", AppConfig.agentsBase + "/agents/dlg/delete",
                                     body: ["profile": profile, "dlg": dlg, "ids": ids], acceptErrors: true)
        guard let r = DlgParse.deleted(d) else {
            throw AuthError.server(JSONRead.string(JSONRead.object(d), "error") ?? "dlg/delete")
        }
        return r
    }
    /// GET /agents/search (≤30 hits per page; page with `q.offset`).
    func search(profile: String, _ q: SearchQuery) async throws -> (hits: [SearchHit], count: Int, capped: Bool) {
        let d = try await authorized("GET", try agentsURL("/agents/search", [URLQueryItem(name: "profile", value: profile)] + q.items))
        guard let r = DlgParse.search(d) else { throw AuthError.server("search") }
        return r
    }
    /// GET /agents/search/counters: {all, media, files, links, plans}.
    func searchCounters(profile: String, dlg: String? = nil) async throws -> [String: Int] {
        let d = try await authorized("GET", try agentsURL("/agents/search/counters", [qi("profile", profile), qi("dlg", dlg)].compactMap { $0 }))
        guard let r = DlgParse.counters(d) else { throw AuthError.server("search/counters") }
        return r
    }
    /// GET /agents/items: an agent's profile tab; `before` is a timestamp.
    func items(profile: String, dlg: String, kind: DlgItem.Kind, before: Date? = nil, limit: Int = 50) async throws -> (items: [DlgItem], hasMore: Bool) {
        let items = [qi("profile", profile), qi("dlg", dlg), qi("kind", kind.rawValue),
                     qi("before", before.map { String(DlgTime.ms($0)) }), qi("limit", String(limit))].compactMap { $0 }
        let d = try await authorized("GET", try agentsURL("/agents/items", items))
        guard let r = DlgParse.items(d) else { throw AuthError.server("items") }
        return r
    }
    /// Server: what an agent did (GET /agents/items?kind=work), newest first - "What did <Agent> do?".
    func workItems(profile: String, dlg: String, limit: Int = 50) async throws -> [DlgWork] {
        let items = [qi("profile", profile), qi("dlg", dlg), qi("kind", "work"), qi("limit", String(limit))].compactMap { $0 }
        let d = try await authorized("GET", try agentsURL("/agents/items", items))
        guard let r = DlgWork.parse(d) else { throw AuthError.server("items/work") }
        return r
    }
    /// GET /agents/tasks: open tasks and the last 20 closed.
    func agentTasks(profile: String, dlg: String? = nil) async throws -> [AgentTask] {
        let d = try await authorized("GET", try agentsURL("/agents/tasks", [qi("profile", profile), qi("dlg", dlg)].compactMap { $0 }))
        guard let r = AgentTask.parseList(d) else { throw AuthError.server("tasks") }
        return r
    }
    /// The Canvas's Code tab: GET /agents/dev/files - the entries of Dev's project (it wakes the project's box: slow).
    func devFiles(profile: String, path: String = ".") async -> Result<[String], DevFilesError> {
        guard let u = try? agentsURL("/agents/dev/files", [URLQueryItem(name: "profile", value: profile), URLQueryItem(name: "path", value: path)]),
              let d = try? await authorized("GET", u, timeout: 60, acceptErrors: true) else {
            return .failure(DevFilesError("Could not reach the project."))
        }
        return DevFiles.parseList(d)
    }
    /// GET /agents/dev/file - one file's text.
    func devFile(profile: String, path: String) async -> Result<String, DevFilesError> {
        guard let u = try? agentsURL("/agents/dev/file", [URLQueryItem(name: "profile", value: profile), URLQueryItem(name: "path", value: path)]),
              let d = try? await authorized("GET", u, timeout: 60, acceptErrors: true) else {
            return .failure(DevFilesError("Could not reach the project."))
        }
        return DevFiles.parseFile(d)
    }
    /// GET /agents/dev/repos - the repositories cloned into Dev's project, with their local branches
    /// (wakes the box). A project with no clone answers [].
    func devRepos(profile: String) async -> Result<[DevRepo], DevFilesError> {
        guard let u = try? agentsURL("/agents/dev/repos", [URLQueryItem(name: "profile", value: profile)]),
              let d = try? await authorized("GET", u, timeout: 60, acceptErrors: true) else {
            return .failure(DevFilesError("Could not reach the repositories."))
        }
        return DevRepos.parse(d)
    }
    /// GET /agents/dev/sites - the workspace's live sites, the next address, what the preview shows.
    func devSites(profile: String) async -> Result<DevSites, DevFilesError> {
        guard let u = try? agentsURL("/agents/dev/sites", [URLQueryItem(name: "profile", value: profile)]),
              let d = try? await authorized("GET", u, timeout: 60, acceptErrors: true) else {
            return .failure(DevFilesError("Could not reach the sites."))
        }
        return DevSites.parse(d)
    }
    /// POST /agents/dev/publish - the static preview goes live (the person's click is the yes).
    func devPublish(profile: String, site: String?, name: String?) async -> Result<DevSite, DevFilesError> {
        var body: [String: Any] = ["profile": profile]
        if let site { body["site"] = site }
        if let name { body["name"] = name }
        guard let d = try? await authorized("POST", AppConfig.agentsBase + "/agents/dev/publish", body: body, timeout: 120, acceptErrors: true) else {
            return .failure(DevFilesError("Could not reach the server."))
        }
        return DevSites.parsePublished(d)
    }
    /// GET /agents/dev/git - one read of a cloned repository (`op`: ls | show | diff); the raw answer.
    func devGit(profile: String, op: String, dir: String, ref: String? = nil, path: String? = nil,
                work: Bool = false) async -> Result<Data, DevFilesError> {
        var items = [URLQueryItem(name: "profile", value: profile), URLQueryItem(name: "op", value: op),
                     URLQueryItem(name: "dir", value: dir)]
        if let ref, !ref.isEmpty { items.append(URLQueryItem(name: "ref", value: ref)) }
        if let path { items.append(URLQueryItem(name: "path", value: path)) }
        if work { items.append(URLQueryItem(name: "work", value: "1")) }
        guard let u = try? agentsURL("/agents/dev/git", items),
              let d = try? await authorized("GET", u, timeout: 60, acceptErrors: true) else {
            return .failure(DevFilesError("Could not reach the repository."))
        }
        return .success(d)
    }
    /// op=ls: the repository's files at `ref`.
    func devGitFiles(profile: String, dir: String, ref: String) async -> Result<[String], DevFilesError> {
        await devGit(profile: profile, op: "ls", dir: dir, ref: ref).flatMap(DevFiles.parseList)
    }
    /// op=show: one file's text at `ref`.
    func devGitFile(profile: String, dir: String, ref: String, path: String) async -> Result<String, DevFilesError> {
        await devGit(profile: profile, op: "show", dir: dir, ref: ref, path: path).flatMap(DevFiles.parseFile)
    }
    /// op=diff: what `ref` holds over the default branch; `work`: the checked-out branch's uncommitted changes.
    func devGitDiff(profile: String, dir: String, ref: String?, work: Bool) async -> Result<DevGitDiff, DevFilesError> {
        await devGit(profile: profile, op: "diff", dir: dir, ref: work ? nil : ref, work: work).flatMap(DevGitDiff.parse)
    }
    /// GET /agents/dev/art - one artifact's record (its activity, changes and diff).
    func devArt(profile: String, id: String) async -> Result<DevArtRecord, DevFilesError> {
        guard let u = try? agentsURL("/agents/dev/art", [URLQueryItem(name: "profile", value: profile), URLQueryItem(name: "id", value: id)]),
              let d = try? await authorized("GET", u, timeout: 60, acceptErrors: true) else {
            return .failure(DevFilesError("Could not reach the activity."))
        }
        return DevArtRecord.parse(d)
    }
    /// GET /agents/dev/cloud - Dev's one cloud (internet, keys without values, sites, env, setup).
    func devCloud(profile: String) async -> Result<DevCloud, DevFilesError> {
        guard let u = try? agentsURL("/agents/dev/cloud", [URLQueryItem(name: "profile", value: profile)]),
              let d = try? await authorized("GET", u, timeout: 30, acceptErrors: true) else {
            return .failure(DevFilesError("Could not reach Dev's cloud."))
        }
        return DevCloud.parse(d)
    }
    /// POST /agents/dev/cloud: only the fields passed change. -> the whole cloud, or the server's sentence.
    func saveDevCloud(profile: String, internet: Bool? = nil, sites: [String]? = nil, env: [String: String]? = nil,
                      setup: String? = nil) async -> Result<DevCloud, DevFilesError> {
        await devCloudPost("/agents/dev/cloud", DevCloudBody.cloud(profile: profile, internet: internet, sites: sites, env: env, setup: setup))
    }
    /// POST /agents/dev/cloud/secret: a new key (`id` nil, `value` required) or an edit (an empty `value` keeps it).
    func saveDevSecret(profile: String, id: String?, name: String, value: String, hosts: [String], paths: [String],
                       header: String, prefix: String) async -> Result<DevCloud, DevFilesError> {
        await devCloudPost("/agents/dev/cloud/secret", DevCloudBody.secret(profile: profile, id: id, name: name, value: value,
                                                                           hosts: hosts, paths: paths, header: header, prefix: prefix))
    }
    /// POST /agents/dev/cloud/secret/delete.
    func deleteDevSecret(profile: String, id: String) async -> Result<DevCloud, DevFilesError> {
        await devCloudPost("/agents/dev/cloud/secret/delete", DevCloudBody.deleteSecret(profile: profile, id: id))
    }
    /// POST /agents/dev/stop - Stop ends Dev's background turn on the server, not only this Mac's stream.
    func devStop(profile: String) async {
        _ = try? await authorized("POST", AppConfig.agentsBase + "/agents/dev/stop", body: ["profile": profile], timeout: 15, acceptErrors: true)
    }
    private func devCloudPost(_ path: String, _ body: JSONObject) async -> Result<DevCloud, DevFilesError> {
        guard let d = try? await authorized("POST", AppConfig.agentsBase + path, body: body, timeout: 30, acceptErrors: true) else {
            return .failure(DevFilesError("Could not reach Dev's cloud."))
        }
        return DevCloud.parse(d)
    }
    // MARK: GitHub (our GitHub App "liaisone"): Dev works in the person's repositories.

    /// GET /agents/github/status; nil: unreachable or unreadable.
    func githubStatus() async -> GitHubStatus? {
        guard let d = try? await authorized("GET", AppConfig.agentsBase + "/agents/github/status", acceptErrors: true) else { return nil }
        return GitHubStatus.parse(d)
    }
    /// GET /agents/github/start -> the address to open in the person's default browser.
    func githubStartURL() async throws -> URL {
        let d = try await authorized("GET", AppConfig.agentsBase + "/agents/github/start", acceptErrors: true)
        let o = JSONRead.object(d)
        guard JSONRead.bool(o, "ok"), let u = GitHubStatus.web(JSONRead.string(o, "url")) else {
            throw AuthError.server(JSONRead.string(o, "error") ?? "Could not start connecting GitHub.")
        }
        return u
    }
    /// POST /agents/github/finish: the code GitHub gave this app's window, finished with this session.
    func githubFinish(state: String, code: String) async -> GitHubFinish {
        guard let d = try? await authorized("POST", AppConfig.agentsBase + "/agents/github/finish", body: ["state": state, "code": code], timeout: 30, acceptErrors: true) else {
            return .failed("Liaison could not reach the server. Try again.")
        }
        return GitHubFinish.parse(d)
    }
    /// POST /agents/github/finish {confirm: true}: yes to replacing the connected GitHub account.
    func githubFinishConfirm() async -> GitHubFinish {
        guard let d = try? await authorized("POST", AppConfig.agentsBase + "/agents/github/finish", body: ["confirm": true], timeout: 30, acceptErrors: true) else {
            return .failed("Liaison could not reach the server. Try again.")
        }
        return GitHubFinish.parse(d)
    }
    /// GET /agents/github/repos (slow: it asks GitHub for every installation).
    func githubRepos() async throws -> [GitHubRepo] {
        let d = try await authorized("GET", AppConfig.agentsBase + "/agents/github/repos", timeout: 45, acceptErrors: true)
        guard let list = GitHubRepo.parseList(d) else {
            throw AuthError.server(JSONRead.string(JSONRead.object(d), "error") ?? "Could not read your repositories.")
        }
        return list
    }
    /// POST /agents/github/disconnect -> where the app is removed on GitHub itself.
    func githubDisconnect() async throws -> URL? {
        let d = try await authorized("POST", AppConfig.agentsBase + "/agents/github/disconnect", body: [:], acceptErrors: true)
        let o = JSONRead.object(d)
        guard JSONRead.bool(o, "ok") else { throw AuthError.server(JSONRead.string(o, "error") ?? "Could not disconnect GitHub.") }
        return GitHubStatus.web(JSONRead.string(o, "manage_url"))
    }
    /// GET /agents/github/activity: the workspace's repositories for Home's brief; nil: unreachable or unreadable.
    func githubActivity(profile: String) async -> [RepoActivity]? {
        guard let u = try? agentsURL("/agents/github/activity", [URLQueryItem(name: "profile", value: profile)]),
              let d = try? await authorized("GET", u, timeout: 30, acceptErrors: true) else { return nil }
        return RepoActivity.parseList(d)
    }
    /// GET /agents/github/ref - one pull request, branch, commit or repository of the workspace (nil: no answer).
    func githubRef(profile: String, _ ref: GitHubRef) async -> GitHubRefInfo? {
        var q = [URLQueryItem(name: "profile", value: profile)]
        switch ref.kind {
        case .pr: q += [.init(name: "kind", value: "pr"), .init(name: "number", value: String(ref.number ?? 0))]
        case .branch: q += [.init(name: "kind", value: "branch"), .init(name: "branch", value: ref.branch ?? "")]
        case .commit: q += [.init(name: "kind", value: "commit"), .init(name: "sha", value: ref.sha ?? "")]
        case .repo: q += [.init(name: "kind", value: "repo")]
        }
        if !ref.repo.isEmpty { q.append(.init(name: "repo", value: ref.repo)) }
        guard let u = try? agentsURL("/agents/github/ref", q),
              let d = try? await authorized("GET", u, timeout: 20, acceptErrors: true) else { return nil }
        return GitHubRefInfo.fromServer(d)
    }
    /// GET /agents/sky: the weather and sun times where the person is (located by IP); nil: no answer.
    func sky() async -> SkyReport? {
        guard let d = try? await authorized("GET", AppConfig.agentsBase + "/agents/sky", timeout: 15, acceptErrors: true) else { return nil }
        return SkyReport.parse(d)
    }
    /// GET /agents/usage - the session and week bars and each agent's share of them.
    func agentUsage() async throws -> AgentUsage {
        let d = try await authorized("GET", AppConfig.agentsBase + "/agents/usage")
        guard let u = AgentUsage.parse(d) else { throw AuthError.server("usage") }
        return u
    }
    /// POST /agents/feedback. Pass only what changes: verdict "up" | "down" | "none", fav, pin.
    /// > the message's marks now (nil: it has none left). Throws when the server refused.
    /// `reaction` "" removes it; the server sets the verdict from it.
    func dialogMark(profile: String, dlg: String, id: String, verdict: String? = nil, reaction: String? = nil, fav: Bool? = nil, pin: Bool? = nil) async throws -> DlgMark? {
        var body: [String: Any] = ["profile": profile, "dlg": dlg, "id": id]
        if let reaction { body["reaction"] = reaction }
        if let verdict { body["verdict"] = verdict }
        if let fav { body["fav"] = fav }
        if let pin { body["pin"] = pin }
        let d = try await authorized("POST", AppConfig.agentsBase + "/agents/feedback", body: body, acceptErrors: true)
        guard let r = DlgParse.mark(d) else {
            throw AuthError.server(JSONRead.string(JSONRead.object(d), "error") ?? "feedback")
        }
        return r
    }
    /// GET /agents/marks - every mark of one dialogue, pins first in pin order.
    func dialogMarks(profile: String, dlg: String) async throws -> [DlgMark] {
        let d = try await authorized("GET", try agentsURL("/agents/marks", [URLQueryItem(name: "profile", value: profile), URLQueryItem(name: "dlg", value: dlg)]))
        guard let r = DlgParse.marks(d) else { throw AuthError.server("marks") }
        return r
    }
    /// POST /agents/reset - this workspace's dialogues, tasks, summaries and marks are deleted on the server for
    /// good (old threads never come back). Memory facts are not touched. -> how many messages went.
    func agentsReset(profile: String) async throws -> Int {
        let d = try await authorized("POST", AppConfig.agentsBase + "/agents/reset", body: ["profile": profile, "confirm": "reset"], acceptErrors: true)
        guard let o = JSONRead.object(d), JSONRead.bool(o, "ok") else {
            throw AuthError.server(JSONRead.string(JSONRead.object(d), "error") ?? "reset")
        }
        return JSONRead.int(o, "wiped") ?? 0
    }
    /// POST /agents/turn for a dialogue: the raw stream lines, as streamTeam. Parse each with DlgStreamEvent.parse
    /// (msg / task / task_update), TeamLine.parse and the Lia 2.0 parsers. `extra` carries attachments, agent,
    /// task_yes, browser, context, tz, web_search exactly as before; thread_id is never sent.
    func streamDialogue(profile: String, dlg: String, text: String, origin: DlgOrigin.Surface? = nil,
                        extra: JSONObject = [:]) -> AsyncThrowingStream<String, Error> {
        streamTeam(DlgTurn.body(profile: profile, dlg: dlg, text: text, origin: origin, extra: extra))
    }

    /// One retry with a freshly minted session on 401, the same contract api.js follows.
    private func authorized(_ method: String, _ urlString: String, body: [String: Any]? = nil,
                            timeout: TimeInterval = 20, acceptErrors: Bool = false) async throws -> Data {
        try await authorizedStatus(method, urlString, body: body, timeout: timeout, acceptErrors: acceptErrors).data
    }

    /// As `authorized`, with the HTTP status (browse-step and locate tell a 429 limit from a failure).
    private func authorizedStatus(_ method: String, _ urlString: String, body: [String: Any]? = nil,
                                  timeout: TimeInterval = 20, acceptErrors: Bool = false) async throws -> (data: Data, status: Int) {
        guard let url = URL(string: urlString) else { throw AuthError.network }
        for attempt in 0..<2 {
            let token = try await token(forceRefresh: attempt == 1)
            var req = URLRequest(url: url, timeoutInterval: timeout)
            LiaClient.stamp(&req)   // X-Lia-Client, our hosts only
            req.httpMethod = method
            req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            if let body {
                req.setValue("application/json", forHTTPHeaderField: "Content-Type")
                req.httpBody = try JSONSerialization.data(withJSONObject: body)
            }
            let result: (Data, URLResponse)
            do { result = try await session.data(for: req) } catch { throw AuthError.network }
            let (data, resp) = result
            let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
            if status == 401 && attempt == 0 { continue }
            if status == 401 { auth.markSessionExpired(); throw AuthError.sessionExpired }
            if !(200..<300).contains(status) && !(acceptErrors && status < 500) { throw AuthError.server("HTTP \(status)") }
            return (data, status)
        }
        throw AuthError.sessionExpired
    }
}

func userMessage(for error: Error) -> String {
    if let e = error as? AuthError { return e.message }
    if let e = error as? ChatStreamError { return e.message }
    if let e = error as? UploadError { return e.message }
    return "Something went wrong. Try again."
}

/// The last chat-doc per chat on disk, so a chat opens at once and the network only refreshes it.
enum ChatDocCache {
    private static var dir: URL {
        let d = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("chatdocs", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }
    private static func file(_ id: String) -> URL { dir.appendingPathComponent(id.filter { $0.isLetter || $0.isNumber || $0 == "_" || $0 == "-" } + ".json") }

    static func store(_ data: Data, id: String) { try? data.write(to: file(id), options: .atomic) }
    static func load(id: String) -> ChatDoc? {
        guard let data = try? Data(contentsOf: file(id)) else { return nil }
        return ChatDoc.parse(data, fallbackId: id)
    }
    static func clear() { try? FileManager.default.removeItem(at: dir) }
}
