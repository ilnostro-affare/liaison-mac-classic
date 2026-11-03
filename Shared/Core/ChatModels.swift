import Foundation

/// A block attached to an assistant turn. MVP renders two kinds natively: `plot` (an HTML chart the
/// worker stored in R2, reached by a signed URL) and `file` (a generated document). Every other kind
/// (kpi, trend, write_plan...) is dead in production per and is kept only as data.
struct ChatBlock: Equatable, Identifiable {
    let tool: String?
    let kind: String?
    let url: String?
    let type: String?
    let filename: String?
    let bytes: Int?
    /// The block's `data` exactly as the worker wrote it, re-sent untouched by chat-save.
    var raw: JSONObject? { rawJSON.flatMap { JSONRead.object(Data($0.utf8)) } }
    let rawJSON: String?

    /// Several memory facts in one turn share tool and kind, so their text tells them apart.
    var id: String {
        if let url { return url }
        let memo = kind == "memory_saved" ? "|" + (raw.flatMap { JSONRead.string($0, "text") } ?? "")
            // Crea's blocks tell apart by their images (two in one message must not share an id)
            : tool == "crea_images" ? "|" + (raw.flatMap { JSONRead.objects($0, "images").compactMap { JSONRead.string($0, "id") }.joined(separator: ",") } ?? "")
            : ""
        return "\(tool ?? "")|\(kind ?? "")|\(filename ?? "")" + memo
    }

    init(tool: String?, kind: String?, url: String?, type: String?, filename: String?, bytes: Int?, rawJSON: String? = nil) {
        self.tool = tool; self.kind = kind; self.url = url; self.type = type; self.filename = filename; self.bytes = bytes
        self.rawJSON = rawJSON
    }

    /// From a stream event `{tool, data}` or a stored block `{tool, data}`.
    init(tool: String?, data: JSONObject?) {
        self.init(tool: tool,
                  kind: JSONRead.string(data, "kind"),
                  url: JSONRead.string(data, "url"),
                  type: JSONRead.string(data, "type"),
                  filename: JSONRead.string(data, "filename"),
                  bytes: JSONRead.int(data, "bytes"),
                  rawJSON: data.flatMap { try? JSONSerialization.data(withJSONObject: $0) }.flatMap { String(data: $0, encoding: .utf8) })
    }

    var isChart: Bool { kind == "plot" && url != nil }
    var isFile: Bool { kind == "file" && url != nil }
    var isViewable: Bool { isChart || isFile }
    /// Blocks the app draws as a widget rather than a file card: creatives and leads.
    var isWidget: Bool { tool == "get_creatives" || tool == "get_creative_analysis" || kind == "leads" }

    /// Worker URLs are relative (`/intelligence/plot?...`); anything else absolute is refused.
    func absoluteURL(base: String) -> URL? {
        guard let url else { return nil }
        if url.hasPrefix("/") { return URL(string: base + url) }
        return nil
    }

    var displayTitle: String {
        if let filename, !filename.isEmpty {
            if let dot = filename.lastIndex(of: "."), dot != filename.startIndex {
                return String(filename[..<dot])
            }
            return filename
        }
        return isChart ? "Chart" : "File"
    }

    /// Same labels as blkFile in ai.js.
    var kindLabel: String {
        if isChart { return "Chart" }
        let ext = (filename.flatMap { $0.split(separator: ".").last.map(String.init) } ?? "").lowercased()
        switch ext {
        case "docx", "pdf": return "Document"
        case "xlsx", "csv": return "Spreadsheet"
        case "pptx": return "Presentation"
        case "html": return "Chart"
        case "json": return "Data"
        case "txt", "md": return "Text"
        default: return "File"
        }
    }
}

struct ChatCite: Equatable, Identifiable {
    let url: String
    let title: String
    let host: String
    /// The url_citation's span in the answer's text (UTF-16 offsets, as ai.js citeMark slices them).
    var s: Int = 0
    var e: Int = 0
    var id: String { url }

    init?(json: JSONObject) {
        guard let url = JSONRead.string(json, "url"), url.hasPrefix("http") else { return nil }
        self.url = url
        self.title = JSONRead.string(json, "title") ?? ""
        let h = JSONRead.string(json, "host") ?? (URL(string: url)?.host ?? "")
        self.host = h.hasPrefix("www.") ? String(h.dropFirst(4)) : h
        self.s = JSONRead.int(json, "s") ?? 0
        self.e = JSONRead.int(json, "e") ?? 0
    }

    init(url: String, title: String, host: String, s: Int = 0, e: Int = 0) {
        self.url = url; self.title = title; self.host = host; self.s = s; self.e = e
    }
}

struct ChatEntity: Equatable {
    let name: String
    let kind: String?
    /// `p` in the runner's map: the campaign the entity sits under (ai.js entPopup's tree).
    var parent: String? = nil
}

struct ChatAccount: Equatable {
    let id: String
    let name: String
}

/// A file the person attached, stored by POST /intelligence/attach (read lane: the model reads it,
/// the ad account never sees it). Only metadata travels with the message; bytes stay in R2.
struct ChatAttachment: Equatable, Identifiable {
    let key: String
    let kind: String
    let name: String
    let mime: String
    let bytes: Int
    /// Signed read URL; chat-doc re-signs it on every read. Relative (`/intelligence/plot?...`) or absolute.
    var url: String?
    /// Bytes of an image the person just attached, so the bubble shows it before any URL exists.
    var preview: Data?
    var id: String { key }
    var isImage: Bool { kind == "image" }

    init(key: String, kind: String, name: String, mime: String, bytes: Int, url: String? = nil, preview: Data? = nil) {
        self.key = key; self.kind = kind; self.name = name; self.mime = mime; self.bytes = bytes
        self.url = url; self.preview = preview
    }

    init?(json o: JSONObject) {
        guard let key = JSONRead.string(o, "key"), key.contains("/att/") else { return nil }
        self.init(key: key,
                  kind: JSONRead.string(o, "kind") == "image" ? "image" : "file",
                  name: JSONRead.string(o, "name") ?? "file",
                  mime: JSONRead.string(o, "mime") ?? "",
                  bytes: JSONRead.int(o, "bytes") ?? 0,
                  url: JSONRead.string(o, "url"))
    }

    func absoluteURL(base: String) -> URL? {
        guard let url, !url.isEmpty else { return nil }
        return url.hasPrefix("http") ? URL(string: url) : URL(string: base + url)
    }

    /// The badge in the corner of a file tile (ai.js attChip): extension, upper case, six letters at most.
    var badge: String {
        let parts = name.split(separator: ".")
        let ext = parts.count > 1 ? String(parts.last!) : (mime.split(separator: "/").last.map(String.init) ?? "file")
        return String(ext.uppercased().prefix(6))
    }

    var sizeLabel: String? {
        guard bytes > 0 else { return nil }
        return "\(max(1, Int((Double(bytes) / 1024).rounded()))) KB"
    }

    /// Response of /intelligence/attach: {ok, key, kind, name, mime, bytes, url} or {ok:false, error}.
    static func parseUpload(_ data: Data) -> Result<ChatAttachment, UploadError> {
        guard let o = JSONRead.object(data) else { return .failure(UploadError(message: "Could not attach that file.")) }
        if JSONRead.bool(o, "ok"), let a = ChatAttachment(json: o) { return .success(a) }
        return .failure(UploadError(message: JSONRead.string(o, "error") ?? "Could not attach that file."))
    }

    var meta: JSONObject { ["key": key, "kind": kind, "name": name, "mime": mime, "bytes": bytes] }
}

struct UploadError: Error, Equatable { let message: String }

struct ChatMessage: Equatable, Identifiable {
    enum Role: String { case user, assistant }
    let id: String
    let role: Role
    var content: String
    var reasoning: String?
    var blocks: [ChatBlock]
    var cites: [ChatCite]
    var timeline: Timeline?
    var attachments: [ChatAttachment]
    var stopped: Bool
    var ts: Double?
    /// The person's verdict on an answer: "up", "down" or nil. Saved by chat-save (whitelist).
    var feedback: String?
    /// Lia 1.4: the change, the setting or the plan this turn stopped on, as stored. `done` is
    /// flipped here when the person answers and written back by chat-save.
    var gateJSON: String?
    var askJSON: String?
    var planJSON: String?
    /// The message exactly as chat-doc returned it. chat-save sends this back untouched, so fields
    /// the app does not know (actsHTML, fb, ms...) survive a save made from the phone.
    /// `var` only so a quick answer can set `answered` in it (Quiz.swift markQuizAnswered).
    var rawJSON: String?

    init(id: String = UUID().uuidString, role: Role, content: String, reasoning: String? = nil,
         blocks: [ChatBlock] = [], cites: [ChatCite] = [], timeline: Timeline? = nil,
         attachments: [ChatAttachment] = [], stopped: Bool = false, ts: Double? = nil, feedback: String? = nil,
         gateJSON: String? = nil, askJSON: String? = nil, planJSON: String? = nil, rawJSON: String? = nil) {
        self.id = id; self.role = role; self.content = content; self.reasoning = reasoning
        self.blocks = blocks; self.cites = cites; self.timeline = timeline; self.attachments = attachments
        self.stopped = stopped; self.ts = ts; self.feedback = feedback; self.rawJSON = rawJSON
        self.gateJSON = gateJSON; self.askJSON = askJSON; self.planJSON = planJSON
    }

    var gate: Gate? { Gate(json: gateJSON.flatMap { JSONRead.object(Data($0.utf8)) }) }
    var ask: AskQuestion? { AskQuestion(json: askJSON.flatMap { JSONRead.object(Data($0.utf8)) }) }
    var plan: JSONObject? { planJSON.flatMap { JSONRead.object(Data($0.utf8)) } }

    /// Marks the stored gate answered (ai.js gateAnswer: done before the apply starts).
    mutating func markGateDone() { gateJSON = Self.patch(gateJSON) { $0["done"] = true } }

    /// Marks Manual's question answered with the person's words.
    mutating func markAskDone(answer: String) { askJSON = Self.patch(askJSON) { $0["done"] = true; $0["answer"] = answer } }

    private static func patch(_ json: String?, _ f: (inout JSONObject) -> Void) -> String? {
        guard let json, var o = JSONRead.object(Data(json.utf8)) else { return json }
        f(&o)
        return LiveTurn.encode(o)
    }

    init?(json: JSONObject, index: Int) {
        guard let r = JSONRead.string(json, "role") else { return nil }
        let reasoning = JSONRead.string(json, "reasoning")
        self.init(id: "m\(index)",
                  role: r == "assistant" ? .assistant : .user,
                  content: JSONRead.string(json, "content") ?? "",
                  reasoning: reasoning,
                  blocks: JSONRead.objects(json, "blocks").map { ChatBlock(tool: JSONRead.string($0, "tool"), data: $0["data"] as? JSONObject) },
                  cites: JSONRead.objects(json, "cites").compactMap(ChatCite.init(json:)),
                  timeline: Timeline(json: json["timeline"] as? JSONObject) ?? reasoning.flatMap(Timeline.fromReasoning),
                  attachments: JSONRead.objects(json, "att").compactMap(ChatAttachment.init(json:)),
                  stopped: JSONRead.bool(json, "stopped"),
                  ts: JSONRead.double(json, "ts"),
                  feedback: ["up", "down"].contains(JSONRead.string(json, "fb") ?? "") ? JSONRead.string(json, "fb") : nil,
                  gateJSON: (json["gate"] as? JSONObject).flatMap(LiveTurn.encode),
                  askJSON: (json["ask"] as? JSONObject).flatMap(LiveTurn.encode),
                  planJSON: (json["plan"] as? JSONObject).flatMap(LiveTurn.encode),
                  rawJSON: (try? JSONSerialization.data(withJSONObject: json)).flatMap { String(data: $0, encoding: .utf8) })
    }

    /// Body of this message inside chat-save. A stored message goes back as it came; a message written
    /// by the app is built from the same fields the web client pushes (ai.js), named on both sides.
    func saveJSON() -> JSONObject {
        if let rawJSON, var raw = JSONRead.object(Data(rawJSON.utf8)) {
            if stopped { raw["stopped"] = true }
            if let feedback { raw["fb"] = feedback } else { raw.removeValue(forKey: "fb") }
            putModeFields(&raw)
            return raw
        }
        var o: JSONObject = ["role": role.rawValue, "content": content]
        if let ts { o["ts"] = ts }
        if let reasoning, !reasoning.isEmpty { o["reasoning"] = reasoning }
        if let t = timeline?.saved() { o["timeline"] = t }
        let bs = blocks.compactMap { b -> JSONObject? in
            guard let data = b.raw else { return nil }
            return ["tool": b.tool ?? "", "data": data]
        }
        if !bs.isEmpty { o["blocks"] = bs }
        if !cites.isEmpty { o["cites"] = cites.map { ["url": $0.url, "title": $0.title, "host": $0.host, "s": $0.s, "e": $0.e] as JSONObject } }
        if !attachments.isEmpty { o["att"] = attachments.map(\.meta) }
        if stopped { o["stopped"] = true }
        if let feedback { o["fb"] = feedback }
        putModeFields(&o)
        return o
    }

    private func putModeFields(_ o: inout JSONObject) {
        for (json, key) in [(gateJSON, "gate"), (askJSON, "ask"), (planJSON, "plan")] {
            if let json, let v = JSONRead.object(Data(json.utf8)) { o[key] = v }
        }
    }

    /// What /intelligence/chat receives for this message in `messages`.
    func requestJSON() -> JSONObject {
        var o: JSONObject = ["role": role.rawValue, "content": content]
        if !attachments.isEmpty { o["att"] = attachments.map(\.meta) }
        return o
    }
}

/// GET /intelligence/chat-doc -> { ok, chat: {...} }. Plot URLs arrive re-signed by the worker.
struct ChatDoc: Equatable {
    let id: String
    var title: String
    var project: String?
    var starred: Bool
    var accounts: [ChatAccount]
    /// The model picker's choice for this chat (chat-save whitelist: lia13 | lia14, auto | plan | manual).
    var model: String?
    var rmode: String?
    var ents: [String: ChatEntity]
    var messages: [ChatMessage]
    /// Stored `ents` as written, echoed back as `_ents` by chat-save (its whitelist reads that name).
    var rawEntsJSON: String?

    init(id: String, title: String = "", project: String? = nil, starred: Bool = false,
         accounts: [ChatAccount] = [], model: String? = nil, rmode: String? = nil,
         ents: [String: ChatEntity] = [:], messages: [ChatMessage] = [], rawEntsJSON: String? = nil) {
        self.id = id; self.title = title; self.project = project; self.starred = starred
        self.model = model; self.rmode = rmode
        self.accounts = accounts; self.ents = ents; self.messages = messages; self.rawEntsJSON = rawEntsJSON
    }

    /// POST /intelligence/chat-save body. The worker trims to 80 messages and whitelists every field.
    func saveBody(messages: [ChatMessage]) -> JSONObject {
        var chat: JSONObject = [
            "id": id,
            "title": title,
            "project": project ?? NSNull(),
            "starred": starred,
            "accounts": accounts.map { ["id": $0.id, "name": $0.name] },
            "messages": messages.suffix(80).map { $0.saveJSON() },
        ]
        if let model { chat["model"] = model }
        if let rmode { chat["rmode"] = rmode }
        if let rawEntsJSON, let e = JSONRead.object(Data(rawEntsJSON.utf8)) { chat["_ents"] = e }
        return ["chat": chat]
    }

    static func parse(_ data: Data, fallbackId: String) -> ChatDoc? {
        guard let root = JSONRead.object(data), JSONRead.bool(root, "ok") else { return nil }
        guard let chat = root["chat"] as? JSONObject else {
            // ok:true with chat:null is a chat that has no document yet (new, nothing saved).
            return ChatDoc(id: fallbackId)
        }
        let msgs = JSONRead.objects(chat, "messages").enumerated().compactMap { ChatMessage(json: $0.element, index: $0.offset) }
        return ChatDoc(
            id: JSONRead.string(chat, "id") ?? fallbackId,
            title: JSONRead.string(chat, "title") ?? "",
            project: JSONRead.string(chat, "project"),
            starred: JSONRead.bool(chat, "starred"),
            accounts: JSONRead.objects(chat, "accounts").compactMap { a in
                guard let id = JSONRead.string(a, "id") else { return nil }
                return ChatAccount(id: id, name: JSONRead.string(a, "name") ?? "")
            },
            model: JSONRead.string(chat, "model"),
            rmode: JSONRead.string(chat, "rmode"),
            ents: ChatEntity.map(chat["ents"] as? JSONObject),
            messages: msgs,
            rawEntsJSON: (chat["ents"] as? JSONObject).flatMap { try? JSONSerialization.data(withJSONObject: $0) }.flatMap { String(data: $0, encoding: .utf8) })
    }
}

extension ChatEntity {
    static func map(_ o: JSONObject?) -> [String: ChatEntity] {
        var out: [String: ChatEntity] = [:]
        for (k, v) in o ?? [:] {
            guard let e = v as? JSONObject, let n = JSONRead.string(e, "n"), !n.isEmpty else { continue }
            out[k] = ChatEntity(name: n, kind: JSONRead.string(e, "k"), parent: JSONRead.string(e, "p"))
        }
        return out
    }
}

enum ChatID {
    /// Same shape as ai.js uid: 'c' + 8 base36 chars. The worker accepts [A-Za-z0-9_-]{1,32}.
    static func make() -> String {
        let alphabet = Array("abcdefghijklmnopqrstuvwxyz0123456789")
        return "c" + String((0..<8).map { _ in alphabet[Int.random(in: 0..<alphabet.count)] })
    }
}

/// GET mcp.liaisone.com/call/list_ad_accounts -> {accounts|data: [{id|account_id, name, blocked}]}.
struct AdAccount: Equatable, Identifiable, Hashable {
    let id: String
    let name: String
    let blocked: Bool

    static func parseList(_ data: Data) -> [AdAccount] {
        guard let o = JSONRead.object(data) else { return [] }
        let rows = JSONRead.objects(o, "accounts").isEmpty ? JSONRead.objects(o, "data") : JSONRead.objects(o, "accounts")
        return rows.compactMap { r in
            let raw = JSONRead.string(r, "id") ?? JSONRead.string(r, "account_id") ?? ""
            let id = raw.filter { $0.isASCII && $0.isNumber }
            guard !id.isEmpty else { return nil }
            let name = JSONRead.string(r, "name") ?? id
            return AdAccount(id: id, name: name.isEmpty ? id : name, blocked: r["blocked"] != nil && !(r["blocked"] is NSNull))
        }
    }
}
