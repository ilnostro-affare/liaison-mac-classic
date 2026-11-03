import Foundation

// Crea (the team's creative agent) makes pictures on the server (lia-agents, OpenRouter image models) and answers
// with one block, `crea_images`:
// { stage: "drafts" | "final" | "edit" | "photo" | "place", brief, images: [{id, n, url, key, idea, w?, h?, upload?}], note? }
// ("place", the person's own photo put on the canvas, reads as a final with every picture `upload`.)
// `url` is a signed relative path (the chart blocks' kind: `/intelligence/plot?...&sig=...`), `key` the R2 key
// (ai/{member}/att/crea/{id}.png), which also travels as a message attachment. Drafts are rough pictures to choose
// from ("Use draft N" goes back to Crea); the other stages are the picture itself.

/// A `crea_images` block, read tolerantly: an unknown stage is drafts when there are several pictures, else final;
/// a picture without an id is skipped, and one without a url too unless it is still being made (`status` pending /
/// generating / queued / working) or has its R2 key (a link the server did not sign: it is asked for again);
/// a block without any picture is not one.
struct CreaImages: Equatable {
    enum Stage: String, Equatable { case drafts, final, edit, photo }

    struct Picture: Equatable, Identifiable {
        let id: String
        /// 1-based order, the number "Use draft N" names.
        let n: Int
        let url: String
        let key: String
        let idea: String
        let w: Int?
        let h: Int?

        /// Still being made (no url yet): a spinner, never Retry.
        var generating: Bool = false
        /// The ratio the server could not crop to ("4:5"): the client crops at display (and before compositing).
        var fit: String? = nil
        /// The draft this final was made from (its layout of the layers is where the final's starts).
        var from: String? = nil
        /// One of a drafts block (its words are off by default: CreaTextShown).
        var isDraft: Bool = false
        /// The person's own photo Crea placed (action place), never a generated picture: the block's stage
        /// "place", the picture's `upload: true` (the server's mark on a photo placed, read from
        /// its R2 metadata) or an "up_" id. The Studio shows it as "Upload N" on a board of its own.
        var upload: Bool = false

        /// No link to load yet: being made, or a key waiting for a signed link.
        var isPending: Bool { url.isEmpty }

        /// The file name the picture is saved and attached under.
        var fileName: String { "crea-" + CreaImages.safeName(id) + ".png" }

        /// Width over height when both are known and positive.
        var aspect: Double? {
            guard let w, let h, w > 0, h > 0 else { return nil }
            return Double(w) / Double(h)
        }

        /// The picture as a message attachment (an existing R2 key; nothing is uploaded again). Nil without a key
        /// the server would take as an attachment (it must hold "/att/").
        var attachment: ChatAttachment? {
            guard key.contains("/att/") else { return nil }
            return ChatAttachment(key: key, kind: "image", name: fileName, mime: "image/png", bytes: 0, url: url)
        }
    }

    static let tool = "crea_images"

    let stage: Stage
    let brief: String
    let images: [Picture]
    let note: String?
    /// The words drawn over the pictures as movable layers (CreaLayers.swift); empty for a flat picture (every
    /// block, a photo edit, an answer without layer words).
    let layers: [CreaLayer]

    var isDrafts: Bool { stage == .drafts }
    var isLayered: Bool { !layers.isEmpty }

    init?(_ b: ChatBlock) {
        guard b.tool == Self.tool || b.kind == Self.tool, let d = b.raw else { return nil }
        self.init(data: d)
    }

    init?(data d: JSONObject) {
        var seen = Set<String>()
        var pics: [Picture] = []
        // Crea Studio: what a picture was made from - its own `from`, else `parent` / `source`,
        // else the block's (an edit block naming the image it edited once for all its pictures).
        let blockFrom = Self.firstString(d, ["from", "parent", "source", "edit_of"])
        let raw = (JSONRead.string(d, "stage") ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        for (i, o) in JSONRead.objects(d, "images").enumerated() {
            let id = (JSONRead.string(o, "id") ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let url = (JSONRead.string(o, "url") ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let key = (JSONRead.string(o, "key") ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let generating = url.isEmpty && Self.isGenerating(JSONRead.string(o, "status"))
            guard !id.isEmpty, !url.isEmpty || generating || key.contains("/att/"), !seen.contains(id) else { continue }
            seen.insert(id)
            let n = JSONRead.int(o, "n").flatMap { $0 > 0 ? $0 : nil } ?? (i + 1)
            let fit = (JSONRead.string(o, "fit") ?? "").trimmingCharacters(in: .whitespaces)
            let from = (Self.firstString(o, ["from", "parent", "source", "edit_of"]) ?? blockFrom ?? "").trimmingCharacters(in: .whitespaces)
            pics.append(Picture(id: id, n: n, url: url, key: key,
                                idea: Self.oneLine(JSONRead.string(o, "idea") ?? ""),
                                w: JSONRead.int(o, "w"), h: JSONRead.int(o, "h"), generating: generating,
                                fit: fit.isEmpty ? nil : fit, from: from.isEmpty || from == id ? nil : from,
                                upload: raw == "place" || JSONRead.bool(o, "upload") || id.hasPrefix("up_")))
        }
        guard !pics.isEmpty else { return nil }
        let st = Stage(rawValue: raw) ?? (pics.count > 1 ? .drafts : .final)
        stage = st
        // Stable by order: equal numbers keep the order they came in.
        images = pics.enumerated().sorted { a, b in a.element.n != b.element.n ? a.element.n < b.element.n : a.offset < b.offset }
            .map { e in var p = e.element; p.isDraft = st == .drafts; return p }
        brief = (JSONRead.string(d, "brief") ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let nt = (JSONRead.string(d, "note") ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        note = nt.isEmpty ? nil : nt
        layers = stage == .photo ? [] : CreaLayer.list(d)
    }

    // MARK: numbering (drafts "1" and "4" with the ones between missing)

    /// The number a picture is shown with: its place among the pictures shown (1...count), never the server's `n`,
    /// which keeps the numbers of drafts that failed or were blocked and so left gaps.
    func shownNumber(_ p: Picture) -> Int { CreaImages.shownNumber(p, in: images) }

    static func shownNumber(_ p: Picture, in pictures: [Picture]) -> Int {
        (pictures.firstIndex { $0.id == p.id } ?? 0) + 1
    }

    /// Drafts of this batch that did not come back (the gaps in the server's numbering).
    var missingDrafts: Int {
        guard isDrafts, let top = images.map(\.n).max() else { return 0 }
        return max(0, top - images.count)
    }

    /// One line in place of the gap, when the server's note does not already say what happened (it says
    /// "One draft failed — not charged." or that the safety filter blocked one). Nil: nothing missing, or said.
    var missingLine: String? {
        let k = missingDrafts
        guard k > 0 else { return nil }
        if let n = note?.lowercased(), n.contains("draft"), n.contains("fail") || n.contains("block") || n.contains("fit") { return nil }
        return k == 1 ? "1 draft could not be made." : "\(k) drafts could not be made."
    }

    // MARK: what the buttons send

    /// "Use draft N": the plain message back to Crea (no button sends it any more; the person picks by words).
    static func useDraft(_ n: Int) -> String { "Use draft \(n)" }

    /// "Use this" on the draft shown as `shown` whose number on the server is `server`: the plain "Use draft N" when
    /// they agree; otherwise the shown number with the server's in brackets, so Crea (which reads its own list) picks
    /// the right one and the person reads the number they saw.
    static func useDraft(shown: Int, server: Int) -> String {
        shown == server ? useDraft(server) : "Use draft \(shown) (number \(server) in the drafts list)"
    }
    /// Edit: put in the composer (EntityChips.putText adds the space after it); nothing is sent.
    static let editPrefix = "Change on the image:"
    /// "Make an ad": the draft in Met's composer, the picture attached.
    static let adDraft = "Make an ad with this image from Crea."

    // MARK: layout

    /// Columns of the drafts grid: one picture alone, three in a row, otherwise two (2 x 2 for four).
    static func columns(_ count: Int) -> Int {
        switch count {
        case ...1: return 1
        case 3: return 3
        default: return 2
        }
    }

    // MARK: addresses

    /// The host a signed path belongs to: `/intelligence/...` is the AI worker's, any other path the agents
    /// worker's (as the profile panel's media). An absolute address only on our own hosts; anything else is refused.
    static func absoluteURL(_ path: String, aiBase: String, agentsBase: String) -> URL? {
        let p = path.trimmingCharacters(in: .whitespacesAndNewlines)
        if p.hasPrefix("/") && !p.hasPrefix("//") {
            return URL(string: (p.hasPrefix("/intelligence/") ? aiBase : agentsBase) + p)
        }
        guard let u = URL(string: p), u.scheme?.lowercased() == "https", OurHost.matches(u.host) else { return nil }
        return u
    }

    /// The address that answers with an attachment (FileBlock's Download: `dl=1` and the file's name).
    static func downloadURL(_ pic: Picture, aiBase: String, agentsBase: String) -> URL? {
        guard let u = absoluteURL(pic.url, aiBase: aiBase, agentsBase: agentsBase),
              var c = URLComponents(url: u, resolvingAgainstBaseURL: false) else { return nil }
        var q = c.queryItems ?? []
        q.append(URLQueryItem(name: "dl", value: "1"))
        q.append(URLQueryItem(name: "name", value: pic.fileName))
        c.queryItems = q
        return c.url
    }

    // MARK: loading (item 8)

    /// A picture's `status` that means it is still being made.
    static func isGenerating(_ status: String?) -> Bool {
        ["pending", "generating", "queued", "working", "running"].contains((status ?? "").trimmingCharacters(in: .whitespaces).lowercased())
    }

    /// When a signed link stops working: its `exp` (milliseconds since 1970, the /intelligence/plot route's). Nil
    /// for an address without one.
    static func expiry(_ url: String) -> Date? {
        guard let c = URLComponents(string: url), let v = c.queryItems?.first(where: { $0.name == "exp" })?.value,
              let ms = Double(v), ms > 0 else { return nil }
        return Date(timeIntervalSince1970: ms / 1000)
    }

    /// The link has expired (or will within `margin`): ask for a fresh one before loading it.
    static func isStale(_ url: String, now: Date = Date(), margin: TimeInterval = 60) -> Bool {
        guard let e = expiry(url) else { return false }
        return e.timeIntervalSince(now) < margin
    }

    /// What a failed load does next.
    enum LoadVerdict: Equatable {
        /// Loaded.
        case ok
        /// The link was refused (expired, or signed wrong): ask the dialogue for freshly signed links.
        case relink
        /// The network or the server: one quiet retry after a short pause.
        case retry
        /// Nothing to retry silently (not found, a bad request): Retry for the person.
        case gone
    }

    static func verdict(status: Int) -> LoadVerdict {
        switch status {
        case 200..<300: return .ok
        case 401, 403, 410: return .relink
        case 0, 408, 425, 429, 500...599: return .retry
        default: return .gone
        }
    }

    /// The pause before the one silent retry.
    static let retryDelay: UInt64 = 800_000_000

    /// Every Crea picture in these blocks, id -> its signed link (the dialogue read again: each read signs anew).
    static func links(in blocks: [ChatBlock]) -> [String: String] {
        var out: [String: String] = [:]
        for b in blocks {
            guard let c = CreaImages(b) else { continue }
            for p in c.images where !p.url.isEmpty { out[p.id] = p.url }
        }
        return out
    }

    // MARK: helpers

    /// The first non-empty string among `keys`.
    static func firstString(_ o: JSONObject, _ keys: [String]) -> String? {
        for k in keys {
            if let v = JSONRead.string(o, k)?.trimmingCharacters(in: .whitespacesAndNewlines), !v.isEmpty { return v }
        }
        return nil
    }

    /// Line breaks and runs of spaces as one space.
    static func oneLine(_ s: String) -> String {
        s.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }

    /// An id fit for a file name: letters, digits, "-" and "_" only, at most 64 characters.
    static func safeName(_ id: String) -> String {
        let ok = id.unicodeScalars.map { s -> Character in
            let c = Character(s)
            return (s.isASCII && (c.isLetter || c.isNumber)) || c == "-" || c == "_" ? c : "-"
        }
        let s = String(String(ok).prefix(64))
        return s.isEmpty ? "image" : s
    }
}
