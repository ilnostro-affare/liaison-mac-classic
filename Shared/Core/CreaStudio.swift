import Foundation

// Crea Studio: one board per creative project, and the project is ONE graph. Crea's first drafts
// block starts a studio (its id from the first draft's id, its name from the brief); the drafts are the roots (no brief
// node since the brief is the studio's name only), a final hangs off the draft it was made from (its `from`,
// else the draft of its number), and every later block of the dialogue joins the same studio, an edit off the picture
// it edited, an area
// edit made on this Mac off the picture the box was on (the box outlined on the new node), a text variant off the node
// its words were arranged on. Nothing is undone: every version is a node, and Download / Make an ad act on the selected
// one. (his own photo, placed on the canvas, joined the old drafts as "Final 1"): a photo Crea PLACED
// (crea_images action place: stage "place", picture id "up_...") opens a board of its own, a root of kind `.upload`
// ("Upload 1"), never linked to drafts; its edits and words hang off it there. (after 0.2.12 his
// photo placed was "Final 1" on the yoga drafts' board and its two Edit area branches were gone): a photo
// placed (stage "final", no "up_") is recognised too (`placedBefore`, or the server's `upload` mark), and
// opening the book moves it with everything made off it to an Upload board of its own (`promoteUpload`); a board is
// never merged into another one when it holds the person's own photo, and a version made on this Mac remembers the
// folder its PNG is in (`dir`) when its node changes boards. Nothing that was on a board is dropped: a node the book
// cannot read is skipped alone, never the whole book. This file is the pure part (the graph,
// how blocks become nodes, the names, the layout, the words sent with a target); the board is App/Workspace/CreaStudioView.swift, the store CreaStudioStore.swift.

/// A Crea picture as the studio keeps it (CreaImages.Picture, Codable).
struct CreaPicRef: Codable, Equatable {
    var id: String
    var n: Int
    var url: String
    var key: String
    var idea: String
    var w: Int?
    var h: Int?
    var fit: String?
    var from: String?
    var isDraft: Bool
    /// The person's own photo (CreaImages.Picture.upload). Optional: books saved before have no such key.
    var upload: Bool?

    init(_ p: CreaImages.Picture) {
        id = p.id; n = p.n; url = p.url; key = p.key; idea = p.idea; w = p.w; h = p.h; fit = p.fit; from = p.from
        isDraft = p.isDraft
        upload = p.upload ? true : nil
    }

    var picture: CreaImages.Picture {
        CreaImages.Picture(id: id, n: n, url: url, key: key, idea: idea, w: w, h: h, generating: url.isEmpty && !key.contains("/att/"),
                           fit: fit, from: from, isDraft: isDraft, upload: upload ?? false)
    }
}

struct CreaStudioNode: Codable, Equatable, Identifiable {
    /// `brief`: only in studios saved before that revision (dropped on reading, `CreaStudioBook.decoded`).
    enum Kind: String, Codable { case brief, draft, final, edit, photo, area, text, upload }

    let id: String
    var kind: Kind
    var parent: String?
    /// The server's picture (its pixels); for a text variant, the picture its words are arranged over.
    var pic: CreaPicRef?
    /// A version made on this Mac (an area edit): its PNG's file name in the studio's folder.
    var file: String?
    /// The studio whose folder holds `file` when the node moved to another board (a merge or an upload
    /// split); nil: the node's own studio. The store moves the file over and clears it.
    var dir: String?
    /// The words drawn over the picture (the block's layers; a variant's are its source's).
    var layers: [CreaLayer] = []
    /// An area edit: the box changed, in the new picture's pixels.
    var region: CreaArea?
    /// What was asked (an area edit's words), or the brief on the root.
    var note: String?
    /// Where the person dragged it (board units, top-left); nil: placed by the layout.
    var x: Double?
    var y: Double?
    /// Pixel size once known (the layout's ratio).
    var w: Int?
    var h: Int?
    /// When it was made (seconds since 1970): the order of the names.
    var at: Double
    /// The picture as a chat attachment once uploaded (an R2 /att/ key and its signed url): what Crea is sent when this
    /// node is the target.
    var attKey: String?
    var attURL: String?

    /// Width over height (4:5 until known).
    var aspect: Double {
        if let w, let h, w > 0, h > 0 { return Double(w) / Double(h) }
        if let p = pic, let w = p.w, let h = p.h, w > 0, h > 0 {
            if let f = p.fit, !layers.isEmpty, let r = CreaStudio.ratio(f) { return r }
            return Double(w) / Double(h)
        }
        if let f = pic?.fit, let r = CreaStudio.ratio(f) { return r }
        return 0.8
    }

    var isImage: Bool { kind != .brief }
    var isLocal: Bool { file != nil }
}

struct CreaStudio: Codable, Equatable, Identifiable {
    let id: String
    var title: String
    var brief: String
    var profile: String
    var dlg: String
    var created: Double
    var updated: Double
    var nodes: [CreaStudioNode] = []
    var selected: String?

    var thread: String { profile + "|" + dlg }

    func node(_ id: String?) -> CreaStudioNode? {
        guard let id else { return nil }
        return nodes.first { $0.id == id }
    }

    func has(_ id: String) -> Bool { nodes.contains { $0.id == id } }

    func children(_ id: String) -> [CreaStudioNode] { nodes.filter { $0.parent == id } }

    /// A board opened by a placed photo: drafts never join it, and it never merges into an older board.
    var isUpload: Bool { nodes.contains { $0.kind == .upload } }

    /// The node and everything made off it (its descendants), the node first.
    func subtree(_ id: String) -> [String] {
        guard has(id) else { return [] }
        var out = [id]
        var inside: Set<String> = [id]
        var grew = true
        while grew {
            grew = false
            for n in nodes where !inside.contains(n.id) {
                if let p = n.parent, inside.contains(p) { inside.insert(n.id); out.append(n.id); grew = true }
            }
        }
        return out
    }

    /// The images, for the tab's count.
    var imageCount: Int { nodes.filter(\.isImage).count }

    /// The node's ancestors and itself, root first (the selected path).
    func path(to id: String?) -> [String] {
        var out: [String] = []
        var cur = id
        var seen = Set<String>()
        while let c = cur, let n = node(c), !seen.contains(c) {
            seen.insert(c)
            out.append(c)
            cur = n.parent
        }
        return out.reversed()
    }

    /// "4:5" -> 0.8.
    static func ratio(_ s: String) -> Double? {
        let p = s.split(separator: ":").compactMap { Double($0) }
        guard p.count == 2, p[0] > 0, p[1] > 0 else { return nil }
        return p[0] / p[1]
    }

    /// The studio's name from a brief: its first line, at most 40 characters on a word boundary.
    static func title(_ brief: String) -> String {
        let one = CreaImages.oneLine(brief.split(whereSeparator: { $0 == "\n" || $0 == "." }).first.map(String.init) ?? brief)
        guard !one.isEmpty else { return "Creative" }
        guard one.count > 40 else { return one }
        var cut = String(one.prefix(40))
        if let sp = cut.lastIndex(of: " "), cut.distance(from: cut.startIndex, to: sp) > 16 { cut = String(cut[..<sp]) }
        return cut + "\u{2026}"
    }

    // MARK: names

    /// Every node's name: "Draft 2", "Final 2", "Final 2 · edit 3", "Final 2 · text 1", "Photo 1". Drafts by
    /// their place among the drafts (as the chat shows them); a final by the draft it came from (else its order);
    /// edits, area edits and text variants numbered under the nearest draft / final / photo above them, oldest first.
    func labels() -> [String: String] {
        var out: [String: String] = [:]
        let order = nodes.enumerated().sorted { a, b in a.element.at != b.element.at ? a.element.at < b.element.at : a.offset < b.offset }.map(\.element)
        var draftNo: [String: Int] = [:]
        var k = 0
        for n in order where n.kind == .draft { k += 1; draftNo[n.id] = k; out[n.id] = "Draft \(k)" }
        var finals = 0, photos = 0, uploads = 0
        for n in order {
            switch n.kind {
            case .brief: out[n.id] = "Brief"
            case .final:
                finals += 1
                if let p = n.parent, let d = draftNo[p] { out[n.id] = "Final \(d)" } else { out[n.id] = "Final \(finals)" }
            case .photo:
                photos += 1
                out[n.id] = "Photo \(photos)"
            case .upload:
                uploads += 1
                out[n.id] = "Upload \(uploads)"
            default: break
            }
        }
        // Two finals from one draft: the second gets a letter.
        var seen: [String: Int] = [:]
        for n in order where n.kind == .final {
            let l = out[n.id] ?? "Final"
            let c = (seen[l] ?? 0) + 1
            seen[l] = c
            if c > 1 { out[n.id] = l + Self.letter(c) }
        }
        var edits: [String: Int] = [:], texts: [String: Int] = [:]
        for n in order where n.kind == .edit || n.kind == .area || n.kind == .text {
            let a = anchor(n.id)
            let base = a.flatMap { out[$0] } ?? "Image"
            if n.kind == .text {
                let c = (texts[a ?? ""] ?? 0) + 1; texts[a ?? ""] = c
                out[n.id] = base + " \u{00B7} text \(c)"
            } else {
                let c = (edits[a ?? ""] ?? 0) + 1; edits[a ?? ""] = c
                out[n.id] = base + " \u{00B7} edit \(c)"
            }
        }
        return out
    }

    private static func letter(_ c: Int) -> String {
        let s = Array("abcdefghijklmnopqrstuvwxyz")
        return c - 1 < s.count ? String(s[c - 1]) : "\(c)"
    }

    /// The nearest draft / final / photo / upload strictly above a node.
    func anchor(_ id: String) -> String? {
        var cur = node(id)?.parent
        var seen = Set<String>()
        while let c = cur, let n = node(c), !seen.contains(c) {
            seen.insert(c)
            if n.kind == .draft || n.kind == .final || n.kind == .photo || n.kind == .upload { return c }
            cur = n.parent
        }
        return nil
    }
}

/// The studios of one workspace, newest first, at most `cap`.
struct CreaStudioBook: Codable, Equatable {
    static let cap = 40
    var studios: [CreaStudio] = []

    func index(of id: String) -> Int? { studios.firstIndex { $0.id == id } }
    func studio(_ id: String?) -> CreaStudio? { id.flatMap { i in studios.first { $0.id == i } } }

    /// The studio a node (a picture id or a node of this Mac's) is in.
    func studio(containing node: String) -> Int? { studios.firstIndex { $0.has(node) } }

    /// Newest first.
    var ordered: [CreaStudio] { studios.sorted { $0.created > $1.created } }

    struct Ingested: Equatable {
        let studio: String
        /// Nodes this block added (empty: it was known).
        let added: [String]
    }

    /// A Crea block into the graph (idempotent: a known picture only gets its fresh link). `thread`: the dialogue it
    /// is in ("profile|dlg"); `pending`: the node a request sent from this dialogue named as its target (the parent of
    /// an answer that does not say what it was made from). Nil when the block cannot be placed (no picture).
    mutating func ingest(_ b: CreaImages, profile: String, dlg: String, now: Double, pending: String? = nil) -> Ingested? {
        ingest(Block(stage: b.stage, brief: b.brief, images: b.images, layers: b.layers), profile: profile, dlg: dlg, now: now, pending: pending)
    }

    /// A picture Crea placed from the person's uploads (action place). The server marks it twice: the block's
    /// stage "place" (which CreaImages reads as a final) and the picture's id prefix "up_", which survives every
    /// layer that drops the stage (CreaImages, CreaBoard, a saved node).
    static func isUpload(_ p: CreaImages.Picture) -> Bool { p.upload || p.id.hasPrefix(uploadPrefix) }
    static let uploadPrefix = "up_"

    /// A photo Crea placed between and: the server answered it as an ordinary
    /// final (stage "final", no "up_"), so the Mac took it for Final 1 of the dialogue's drafts. What gives it away on
    /// the Mac: one picture, made from nothing (no `from`: a final made from a draft always names it) with no
    /// idea (a generated final carries its draft's idea), and an id minted inside the hours was live (the
    /// server's ids start with Date.now in base 36). A final made without any draft in those hours is the only thing
    /// it could be mistaken for; the server's `upload` mark (lia-agents agSignRows, from the picture's R2 metadata
    /// stage "place") settles it either way once it is deployed.
    static func placedBefore(id: String, idea: String, from: String?) -> Bool {
        guard !id.hasPrefix(uploadPrefix), (from ?? "").isEmpty, idea.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let ms = mintedAt(id) else { return false }
        return ms >= legacyPlaceWindow.lowerBound && ms <= legacyPlaceWindow.upperBound
    }

    /// Went live (14:03 UTC) and replaced it by 18:25 UTC: 13:30 to 19:00 UTC that day,
    /// in milliseconds since 1970.
    static let legacyPlaceWindow: ClosedRange<Double> = 1_792_675_800_000...1_792_695_600_000

    /// The milliseconds a server id (`Date.now.toString(36)` + 6 random characters) was minted at; nil for any other id.
    static func mintedAt(_ id: String) -> Double? {
        guard id.count == 14, id.allSatisfy({ $0.isASCII && ($0.isLowercase || $0.isNumber) }),
              let v = Int(id.prefix(8), radix: 36) else { return nil }
        return Double(v)
    }

    /// A node that is the person's own photo but not yet shown as one (a final, by the server's mark or the rule above).
    static func isPlacedPhoto(_ n: CreaStudioNode) -> Bool {
        guard n.kind == .final, n.file == nil, let p = n.pic else { return false }
        return p.upload == true || p.id.hasPrefix(uploadPrefix) || placedBefore(id: p.id, idea: p.idea, from: p.from)
    }

    /// The parts of a block the graph reads (a Canvas board carries them without the block).
    struct Block {
        let stage: CreaImages.Stage
        let brief: String
        let images: [CreaImages.Picture]
        let layers: [CreaLayer]

        /// Every picture of the block was placed from the uploads (or one photo placed).
        var isUpload: Bool {
            guard !images.isEmpty else { return false }
            if images.allSatisfy({ CreaStudioBook.isUpload($0) }) { return true }
            guard stage == .final, images.count == 1, let p = images.first else { return false }
            return CreaStudioBook.placedBefore(id: p.id, idea: p.idea, from: p.from)
        }
    }

    mutating func ingest(_ b: Block, profile: String, dlg: String, now: Double, pending: String? = nil) -> Ingested? {
        guard let first = b.images.first else { return nil }
        // Known already: refresh the links (every read of the dialogue signs them anew), place nothing.
        if var si = studio(containing: first.id) {
            // A photo the book took for a final (placed, or marked by the server only now)
            // moves to a board of its own with what was made off it.
            if b.isUpload, let n = studios[si].node(first.id), n.kind != .upload {
                if let to = promoteUpload(first.id), let i = index(of: to) { si = i }
            }
            var s = studios[si]
            var added: [String] = []
            for p in b.images {
                if let ni = s.nodes.firstIndex(where: { $0.id == p.id }) {
                    if !p.url.isEmpty, s.nodes[ni].pic?.url != p.url { s.nodes[ni].pic?.url = p.url }
                    // A placed photo usually arrives bare and gets its words with a later action text (same picture):
                    // the board's layers editor needs them on the node.
                    if s.nodes[ni].kind == .upload, s.nodes[ni].layers.isEmpty, !b.layers.isEmpty { s.nodes[ni].layers = b.layers }
                } else {
                    s.nodes.append(node(p, stage: b.stage, layers: b.layers, parent: parent(of: p, in: s, stage: b.stage, pending: pending), at: now))
                    added.append(p.id)
                }
            }
            if !added.isEmpty { s.updated = now }
            studios[si] = s
            return Ingested(studio: s.id, added: added)
        }
        let thread = profile + "|" + dlg
        var si: Int?
        let newest = newest(thread: thread, profile: profile, anyDialogue: dlg.isEmpty)
        if b.isUpload {
            // The person's own photo opens a new board, never the drafts' (si stays nil).
        } else if b.stage != .drafts {
            // The studio of what it was made from, of the target, else the newest of this dialogue: a final, an edit or
            // a photo never opens a board of its own while the dialogue has one.
            for p in b.images {
                if let f = p.from, let i = studio(containing: f) { si = i; break }
            }
            if si == nil, let t = pending { si = studio(containing: t) }
            if si == nil { si = newest }
        } else if let i = newest, !studios[i].isUpload, studios[i].nodes.allSatisfy({ $0.kind != .draft }) || b.brief.isEmpty
                    || CreaImages.oneLine(studios[i].brief) == CreaImages.oneLine(b.brief) {
            // Drafts again for the same brief (or a studio that has none yet): the same project.
            si = i
        }
        if si == nil {
            let id = "st-" + CreaImages.safeName(first.id)
            let s = CreaStudio(id: id, title: b.isUpload && b.brief.isEmpty ? "Upload" : CreaStudio.title(b.brief), brief: b.brief, profile: profile, dlg: dlg, created: now, updated: now)
            studios.append(s)
            si = studios.count - 1
            trim()
            si = index(of: id)
        }
        guard let i = si else { return nil }
        var s = studios[i]
        if s.brief.isEmpty, !b.brief.isEmpty { s.brief = b.brief; s.title = CreaStudio.title(b.brief) }
        var added: [String] = []
        for (k, p) in b.images.enumerated() where !s.has(p.id) {
            s.nodes.append(b.isUpload
                ? node(p, kind: .upload, layers: b.layers, parent: nil, at: now + Double(k) * 0.001)
                : node(p, stage: b.stage, layers: b.layers, parent: parent(of: p, in: s, stage: b.stage, pending: pending),
                       at: now + Double(k) * 0.001))
            added.append(p.id)
        }
        s.updated = now
        if let a = added.last, b.stage != .drafts || s.selected == nil { s.selected = a }
        studios[i] = s
        return Ingested(studio: s.id, added: added)
    }

    /// The newest studio of a dialogue (`anyDialogue`: of the workspace, for a board that does not know its dialogue).
    private func newest(thread: String, profile: String, anyDialogue: Bool) -> Int? {
        studios.indices.filter { anyDialogue ? studios[$0].profile == profile : studios[$0].thread == thread }
            .max { studios[$0].created < studios[$1].created }
    }

    private func node(_ p: CreaImages.Picture, stage: CreaImages.Stage, layers: [CreaLayer], parent: String?, at: Double) -> CreaStudioNode {
        let kind: CreaStudioNode.Kind
        switch stage {
        case .drafts: kind = .draft
        case .final: kind = .final
        case .edit: kind = .edit
        case .photo: kind = .photo
        }
        return node(p, kind: kind, layers: layers, parent: parent, at: at)
    }

    private func node(_ p: CreaImages.Picture, kind: CreaStudioNode.Kind, layers: [CreaLayer], parent: String?, at: Double) -> CreaStudioNode {
        var ref = CreaPicRef(p)
        if kind == .upload { ref.upload = true }
        return CreaStudioNode(id: p.id, kind: kind, parent: parent, pic: ref, layers: layers, note: p.idea.isEmpty ? nil : p.idea,
                              w: p.w, h: p.h, at: at)
    }

    /// A picture's parent: drafts are roots; else what it was made from (`from`), else the target of the request, else
    /// (a final) the draft of its number, (an edit) the newest final or edit of the studio, else a root.
    private func parent(of p: CreaImages.Picture, in s: CreaStudio, stage: CreaImages.Stage, pending: String?) -> String? {
        if stage == .drafts { return nil }
        if let f = p.from, s.has(f) { return f }
        if let t = pending, s.has(t) { return t }
        if stage == .final, let d = s.nodes.last(where: { $0.kind == .draft && $0.pic?.n == p.n }) { return d.id }
        if stage == .edit, let last = s.nodes.filter({ $0.kind == .final || $0.kind == .edit || $0.kind == .upload }).max(by: { $0.at < $1.at }) { return last.id }
        return nil
    }

    private mutating func trim() {
        guard studios.count > Self.cap else { return }
        studios = Array(ordered.prefix(Self.cap))
    }

    // MARK: this Mac's nodes

    /// A new node under `parent` (an area edit or a text variant). Nil when the studio or the parent is unknown.
    mutating func add(_ n: CreaStudioNode, in studio: String) -> String? {
        guard let i = index(of: studio), studios[i].has(n.parent ?? "") else { return nil }
        studios[i].nodes.append(n)
        studios[i].updated = n.at
        studios[i].selected = n.id
        return n.id
    }

    mutating func update(_ studio: String, _ node: String, _ change: (inout CreaStudioNode) -> Void) {
        guard let i = index(of: studio), let j = studios[i].nodes.firstIndex(where: { $0.id == node }) else { return }
        change(&studios[i].nodes[j])
    }

    mutating func select(_ node: String?, in studio: String) {
        guard let i = index(of: studio) else { return }
        studios[i].selected = node
    }

    /// Removes a studio (its tab's close).
    mutating func remove(_ studio: String) { studios.removeAll { $0.id == studio } }

    func encoded() -> Data? {
        var b = self
        b.sanitize()
        return try? JSONEncoder().encode(b)
    }

    static func decoded(_ d: Data?) -> CreaStudioBook {
        d.flatMap { read($0) } ?? CreaStudioBook()
    }

    /// Studios saved by the brief node goes (its children become roots), and a studio with no drafts that a
    /// final or edit opened apart from its drafts joins the dialogue's studio made before it (one project, one graph).
    /// First, the person's own photo that the book took for a final goes to an Upload board of its own with
    /// everything made off it; a board holding such a photo never merges; a node of this Mac's that changes boards
    /// keeps the folder its PNG is in (`dir`).
    mutating func migrate() {
        for i in studios.indices {
            let briefs = Set(studios[i].nodes.filter { $0.kind == .brief }.map(\.id))
            guard !briefs.isEmpty else { continue }
            studios[i].nodes.removeAll { briefs.contains($0.id) }
            for j in studios[i].nodes.indices where briefs.contains(studios[i].nodes[j].parent ?? "") { studios[i].nodes[j].parent = nil }
            if let sel = studios[i].selected, briefs.contains(sel) { studios[i].selected = nil }
        }
        for id in studios.flatMap({ $0.nodes.filter(Self.isPlacedPhoto).map(\.id) }) { _ = promoteUpload(id) }
        let byAge = studios.sorted { $0.created < $1.created }.map(\.id)
        for id in byAge {
            // A placed photo's board stands alone (it has no drafts by design).
            guard let i = index(of: id), studios[i].nodes.allSatisfy({ $0.kind != .draft }), !studios[i].isUpload else { continue }
            let s = studios[i]
            guard let host = studios.indices.filter({ studios[$0].thread == s.thread && studios[$0].created < s.created && $0 != i && !studios[$0].isUpload })
                .max(by: { studios[$0].created < studios[$1].created }) else { continue }
            let known = Set(studios[host].nodes.map(\.id))
            for var n in s.nodes where !known.contains(n.id) {
                if n.parent == nil, n.kind == .final,
                   let d = studios[host].nodes.last(where: { $0.kind == .draft && $0.pic?.n == n.pic?.n }) { n.parent = d.id }
                if n.file != nil, n.dir == nil { n.dir = s.id }
                studios[host].nodes.append(n)
            }
            studios[host].updated = max(studios[host].updated, s.updated)
            if let sel = s.selected { studios[host].selected = sel }
            studios.removeAll { $0.id == s.id }
        }
    }

    /// The person's own photo `id` becomes an Upload: a root of kind `.upload` on a board of its own, with every node
    /// made off it (edits, area edits, text variants) still hanging off it. When its board holds nothing else it is
    /// turned in place; otherwise the photo and its subtree move to a new board (their dragged places dropped: they
    /// were places on the other board) and the rest stays. Nothing is removed. Returns the photo's board.
    @discardableResult
    mutating func promoteUpload(_ id: String) -> String? {
        guard let si = studio(containing: id) else { return nil }
        let s = studios[si]
        let moved = s.subtree(id)
        let inside = Set(moved)
        if s.nodes.allSatisfy({ inside.contains($0.id) }) {
            for j in studios[si].nodes.indices where studios[si].nodes[j].id == id {
                studios[si].nodes[j].kind = .upload
                studios[si].nodes[j].parent = nil
                studios[si].nodes[j].pic?.upload = true
            }
            if studios[si].brief.isEmpty || studios[si].title == "Creative" { studios[si].title = "Upload" }
            return s.id
        }
        var nid = "st-" + CreaImages.safeName(id)
        var k = 1
        while index(of: nid) != nil { k += 1; nid = "st-" + CreaImages.safeName(id) + "-\(k)" }
        var nodes: [CreaStudioNode] = []
        for n in s.nodes where inside.contains(n.id) {
            var m = n
            m.x = nil; m.y = nil
            if m.file != nil, m.dir == nil { m.dir = s.id }
            if m.id == id { m.kind = .upload; m.parent = nil; m.pic?.upload = true }
            nodes.append(m)
        }
        let at = nodes.first?.at ?? s.created
        var up = CreaStudio(id: nid, title: "Upload", brief: "", profile: s.profile, dlg: s.dlg, created: at,
                            updated: max(at, nodes.map(\.at).max() ?? at))
        up.nodes = nodes
        up.selected = s.selected.flatMap { inside.contains($0) ? $0 : nil } ?? id
        studios[si].nodes.removeAll { inside.contains($0.id) }
        if let sel = studios[si].selected, inside.contains(sel) { studios[si].selected = nil }
        studios.append(up)
        return nid
    }

    // MARK: saving

    /// Values JSON cannot hold (a NaN or an infinity from a drag or a box) made the whole book unsavable, so every
    /// change after one was lost on the next launch: such a place or box is dropped instead.
    mutating func sanitize() {
        for i in studios.indices {
            for j in studios[i].nodes.indices {
                var n = studios[i].nodes[j]
                if let x = n.x, !x.isFinite { n.x = nil }
                if let y = n.y, !y.isFinite { n.y = nil }
                if n.x == nil || n.y == nil { n.x = nil; n.y = nil }
                if let r = n.region, ![r.x, r.y, r.w, r.h].allSatisfy(\.isFinite) { n.region = nil }
                if !n.at.isFinite { n.at = 0 }
                if n != studios[i].nodes[j] { studios[i].nodes[j] = n }
            }
            if !studios[i].created.isFinite { studios[i].created = 0 }
            if !studios[i].updated.isFinite { studios[i].updated = studios[i].created }
        }
    }
}

/// A book decoded node by node: a studio or a node this build cannot read (a kind from a newer build, a damaged
/// field) is skipped alone; before one such value made the whole file unreadable, the Mac started an empty
/// book and the next save wrote it over everything (every version made on this Mac lost).
private struct CreaLossy<T: Decodable>: Decodable {
    let value: T?
    init(from decoder: Decoder) throws { value = try? T(from: decoder) }
}

extension CreaStudioBook {
    enum CodingKeys: String, CodingKey { case studios }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        studios = (try c.decodeIfPresent([CreaLossy<CreaStudio>].self, forKey: .studios) ?? []).compactMap(\.value)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(studios, forKey: .studios)
    }

    /// The book, or nil when the data is not a book at all (the store then keeps the file aside instead of writing over it).
    static func read(_ d: Data) -> CreaStudioBook? {
        guard var b = try? JSONDecoder().decode(CreaStudioBook.self, from: d) else { return nil }
        b.migrate()
        return b
    }
}

extension CreaStudio {
    enum CodingKeys: String, CodingKey { case id, title, brief, profile, dlg, created, updated, nodes, selected }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        title = try c.decodeIfPresent(String.self, forKey: .title) ?? "Creative"
        brief = try c.decodeIfPresent(String.self, forKey: .brief) ?? ""
        profile = try c.decodeIfPresent(String.self, forKey: .profile) ?? ""
        dlg = try c.decodeIfPresent(String.self, forKey: .dlg) ?? ""
        created = try c.decodeIfPresent(Double.self, forKey: .created) ?? 0
        updated = try c.decodeIfPresent(Double.self, forKey: .updated) ?? created
        nodes = (try c.decodeIfPresent([CreaLossy<CreaStudioNode>].self, forKey: .nodes) ?? []).compactMap(\.value)
        selected = try c.decodeIfPresent(String.self, forKey: .selected)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(title, forKey: .title)
        try c.encode(brief, forKey: .brief)
        try c.encode(profile, forKey: .profile)
        try c.encode(dlg, forKey: .dlg)
        try c.encode(created, forKey: .created)
        try c.encode(updated, forKey: .updated)
        try c.encode(nodes, forKey: .nodes)
        try c.encodeIfPresent(selected, forKey: .selected)
    }
}

/// Where the nodes stand (board units, top-left corners), columns by depth: the drafts, the finals, the edits, each subtree's parent centred on its children; a node the person dragged stays where it was put, and its
/// descendants move with it.
enum CreaStudioLayout {
    static let header = 26.0
    static let colGap = 110.0
    static let rowGap = 44.0

    /// The picture's height on the board: one size for every picture (drafts are full images, not thumbnails).
    static let pictureH = 300.0
    static func imageHeight(_ k: CreaStudioNode.Kind) -> Double { pictureH }

    /// The node's box size (its name strip on top of the picture).
    static func size(_ n: CreaStudioNode) -> (w: Double, h: Double) {
        let ih = imageHeight(n.kind)
        let w = min(420, max(130, ih * max(0.2, min(5, n.aspect))))
        return (w, ih + header)
    }

    struct Frame: Equatable {
        var x: Double
        var y: Double
        var w: Double
        var h: Double
        var midY: Double { y + h / 2 }
        var maxX: Double { x + w }
        var maxY: Double { y + h }
    }

    static func frames(_ s: CreaStudio) -> [String: Frame] {
        let ids = Set(s.nodes.map(\.id))
        let byParent = Dictionary(grouping: s.nodes) { n -> String in
            if let p = n.parent, ids.contains(p), p != n.id { return p }
            return ""
        }
        func kids(_ id: String) -> [CreaStudioNode] { (byParent[id] ?? []).sorted { $0.at < $1.at } }
        // Depths (roots: no parent or a parent not in the studio).
        var depth: [String: Int] = [:]
        var stack: [(String, Int)] = kids("").map { ($0.id, 0) }
        while let (id, d) = stack.popLast() {
            guard depth[id] == nil else { continue }
            depth[id] = d
            for c in kids(id) { stack.append((c.id, d + 1)) }
        }
        let sizes = Dictionary(uniqueKeysWithValues: s.nodes.map { ($0.id, size($0)) })
        let maxDepth = depth.values.max() ?? 0
        var colX: [Double] = []
        var x = 0.0
        for d in 0...maxDepth {
            colX.append(x)
            let w = s.nodes.filter { depth[$0.id] == d }.map { sizes[$0.id]?.w ?? 200 }.max() ?? 200
            x += w + colGap
        }
        // Tidy rows: leaves stacked, a parent centred on its children.
        var auto: [String: Frame] = [:]
        var cursor = 0.0
        func place(_ id: String) -> (top: Double, bottom: Double) {
            let sz = sizes[id] ?? (200, 200)
            let d = depth[id] ?? 0
            let cs = kids(id).filter { depth[$0.id] != nil }
            var y: Double
            if cs.isEmpty {
                y = cursor
                cursor += sz.h + rowGap
            } else {
                var top = Double.infinity, bottom = -Double.infinity
                for c in cs {
                    let r = place(c.id)
                    top = min(top, r.top); bottom = max(bottom, r.bottom)
                }
                y = (top + bottom) / 2 - sz.h / 2
                if y + sz.h + rowGap > cursor { cursor = y + sz.h + rowGap }
            }
            auto[id] = Frame(x: colX[min(d, colX.count - 1)], y: y, w: sz.w, h: sz.h)
            let f = auto[id]!
            return (f.y, f.maxY)
        }
        for r in kids("") { _ = place(r.id) }
        // The person's moves: a dragged node where it was put, its subtree shifted with it.
        var out: [String: Frame] = [:]
        func settle(_ id: String, shift: (Double, Double)) {
            guard var f = auto[id], let n = s.node(id) else { return }
            var sh = shift
            if let px = n.x, let py = n.y {
                sh = (px - f.x, py - f.y)
            }
            f.x += sh.0; f.y += sh.1
            out[id] = f
            for c in kids(id) { settle(c.id, shift: sh) }
        }
        for r in kids("") { settle(r.id, shift: (0, 0)) }
        return out
    }

    /// The box around every frame.
    static func bounds(_ frames: [String: Frame]) -> Frame {
        guard let f = frames.values.first else { return Frame(x: 0, y: 0, w: 1, h: 1) }
        var minX = f.x, minY = f.y, maxX = f.maxX, maxY = f.maxY
        for g in frames.values {
            minX = min(minX, g.x); minY = min(minY, g.y); maxX = max(maxX, g.maxX); maxY = max(maxY, g.maxY)
        }
        return Frame(x: minX, y: minY, w: max(1, maxX - minX), h: max(1, maxY - minY))
    }

    /// A connector from the parent's right edge to the child's left edge: start, the two control points, end.
    static func wire(from p: Frame, to c: Frame) -> [(x: Double, y: Double)] {
        let x1 = p.maxX, y1 = p.midY, x2 = c.x, y2 = c.midY
        let dx = max(40, (x2 - x1) * 0.5)
        return [(x1, y1), (x1 + dx, y1), (x2 - dx, y2), (x2, y2)]
    }
}

/// What a request with a node attached says to Crea.
enum CreaStudioTargetText {
    /// "Editing: Final 2 · edit 3", the composer's chip.
    static func chip(_ label: String) -> String { "Editing: " + label }

    /// The message: the person's words after a line naming the image (attached) they are about. In Team it goes to
    /// Crea, not the router.
    static func message(_ text: String, label: String, imageId: String?, attached: Bool, team: Bool) -> String {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        var head = "Edit " + (attached ? "the attached image" : "the image") + " \u{201C}" + label + "\u{201D}"
        if let id = imageId, !id.isEmpty { head += " (id \(id))" }
        head += " and make a new version of it."
        let body = t.isEmpty ? head : head + " " + t
        let mention = "@Crea"
        return team && !t.lowercased().contains(mention.lowercased()) ? mention + " " + body : body
    }
}

/// (dragging a card moved the board): where a drag may pan the board.
enum CreaStudioPan {
    /// A drag pans only when it starts on the empty board: not inside any of `rects` (the nodes, the toolbar; x, y,
    /// width, height in the board view's points). An empty rectangle covers nothing.
    static func mayPan(from p: (x: Double, y: Double), over rects: [(x: Double, y: Double, w: Double, h: Double)]) -> Bool {
        !rects.contains { r in r.w > 0 && r.h > 0 && p.x >= r.x && p.x <= r.x + r.w && p.y >= r.y && p.y <= r.y + r.h }
    }
}
