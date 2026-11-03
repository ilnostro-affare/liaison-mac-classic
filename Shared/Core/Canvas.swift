import Foundation

// The Canvas: a panel on the right of a conversation that shows what an agent made -
// Dev's site now; an HTML document, a design or an animation later. It takes the place of the agent's browser while
// it is open and belongs to the dialogue (open state, width, tab), as the agent browser does.

/// One thing the Canvas shows. `profile` is the workspace whose project it is (Dev's files are read under it).
/// One item is ONE artifact of Dev (a preview, a published site, its work, a pushed branch), with its own
/// record (`art`) and so its own Activity and changes; `activity` is Dev working now, before any artifact.
struct CanvasItem: Equatable, Identifiable {
    /// `activity`: Dev's steps of the turn (no page yet). `devWork`: files changed, no page. `devPush`: a branch pushed.
    /// `images` (item 8): Crea's pictures of one block on a board (pan, zoom), the clicked one selected.
    enum Kind: String, Equatable { case devPreview, activity, devWork, devPush, images }

    let kind: Kind
    let title: String
    let url: URL?
    let profile: String?
    /// The artifact's record (GET /agents/dev/art); nil: none was stored (or an older block).
    var art: String? = nil
    var changes: DevChanges? = nil
    /// A pushed branch (kind devPush).
    var push: DevPush? = nil
    /// The project's page for an item with no page of its own (work, a push, Dev working now): the
    /// block's `preview`, else the newest preview or live site of the dialogue (withPage). The Preview tab shows it.
    var page: URL? = nil
    /// Crea's pictures (kind images).
    var board: CreaBoard? = nil
    /// The dialogue's newest private preview, for an item that is a live site or has no preview of its
    /// own: its Preview side (CanvasLiveChoice). Not part of the id.
    var privatePage: URL? = nil

    /// Two turns' previews of the same address are two items (each with its own activity).
    var id: String {
        if let b = board { return kind.rawValue + "|" + b.id }
        return kind.rawValue + "|" + (url?.absoluteString ?? push.map { $0.repo + "|" + $0.branch } ?? title) + (art.map { "|" + $0 } ?? "")
    }

    init(kind: Kind, title: String, url: URL?, profile: String?, art: String? = nil, changes: DevChanges? = nil, push: DevPush? = nil) {
        self.kind = kind; self.title = title; self.url = url; self.profile = profile
        self.art = art; self.changes = changes; self.push = push
    }

    init(preview: DevPreview, profile: String?) {
        self.init(kind: .devPreview, title: preview.title, url: preview.url, profile: profile, art: preview.meta.art,
                  changes: preview.meta.changes)
    }

    init(work: DevWork, profile: String?) {
        self.init(kind: .devWork, title: work.title, url: nil, profile: profile, art: work.meta.art, changes: work.meta.changes)
        page = work.meta.preview
    }

    init(push p: DevPush, profile: String?) {
        self.init(kind: .devPush, title: p.title, url: nil, profile: profile, art: p.meta.art, changes: p.meta.changes, push: p)
        page = p.meta.preview
    }

    /// A block the Canvas can show (`dev_preview`, `dev_work`, `dev_push`); nil for every other block.
    init?(block: ChatBlock, profile: String?) {
        if let p = DevPreview(block) { self.init(preview: p, profile: profile); return }
        if let w = DevWork(block) { self.init(work: w, profile: profile); return }
        if let p = DevPush(block) { self.init(push: p, profile: profile); return }
        return nil
    }

    /// Crea's pictures of one block on the board, `selected` (a picture id) in the middle.
    static func images(_ board: CreaBoard) -> CanvasItem {
        var i = CanvasItem(kind: .images, title: board.title, url: nil, profile: nil)
        i.board = board
        return i
    }

    /// Dev's activity in a workspace (the Canvas opens on it when Dev starts working); `page`: the dialogue's newest
    /// preview, so the Preview tab stays while Dev works.
    static func activity(profile: String?, page: URL? = nil) -> CanvasItem {
        var i = CanvasItem(kind: .activity, title: "Dev working", url: nil, profile: profile)
        i.page = page
        return i
    }

    /// The item with `fallback` as its page when it has none of its own (a preview's own address always wins).
    func withPage(_ fallback: URL?) -> CanvasItem {
        guard kind != .images, previewURL == nil, let fallback else { return self }
        var i = self
        i.page = fallback
        return i
    }

    /// The item with the dialogue's newest private preview beside it (only a Dev item; only a private address).
    func withPrivatePage(_ u: URL?) -> CanvasItem {
        guard kind != .images, profile != nil, DevSites.isPrivatePreview(u) else { return self }
        var i = self
        i.privatePage = u
        return i
    }

    /// Its Preview | Live as its data decides, with the person's pick (`chosen`).
    func liveChoice(chosen: Bool?) -> CanvasLiveChoice {
        CanvasLiveChoice.resolve(own: previewURL, isDev: kind != .images && profile != nil, fallback: privatePage, chosen: chosen)
    }

    /// The page a block names: a Preview's or a Live site's address, or the `preview` of Changes / a push.
    static func page(of b: ChatBlock) -> URL? {
        if let p = DevPreview(b) { return p.url }
        if let w = DevWork(b) { return w.meta.preview }
        if let p = DevPush(b) { return p.meta.preview }
        return nil
    }

    /// Dev's project itself (its files, picked in the profile): no page and no record.
    static func project(profile: String) -> CanvasItem {
        CanvasItem(kind: .devWork, title: "Project files", url: nil, profile: profile)
    }

    /// Only Dev's projects have files to read.
    var hasCode: Bool { !(profile ?? "").isEmpty }

    /// Its changes can be shown (the artifact's record holds them).
    var hasChanges: Bool { art != nil && kind != .activity && kind != .images }

    /// The Code tab opens on the artifact's changes (a push always; else when it changed files).
    var prefersChanges: Bool {
        guard hasChanges else { return false }
        return kind == .devPush || !(changes?.isEmpty ?? true) || !hasCode
    }

    /// The page the Preview tab loads: a preview's own address; for the others, the project's page (`page`).
    var previewURL: URL? {
        switch kind {
        case .devPreview: return url ?? page
        case .images: return nil
        default: return page ?? privatePage
        }
    }

    /// The tab it opens on: Preview when there is a page, else Changes for a push, else Activity.
    var firstTab: CanvasState.Tab {
        if kind == .images { return .images }
        if previewURL != nil { return .preview }
        if kind == .devPush { return .code }
        return .activity
    }
}

/// The Canvas of one dialogue.
struct CanvasState: Equatable {
    enum Tab: String, Equatable { case preview, code, activity, images }

    var item: CanvasItem
    var tab: Tab = .preview
    /// The preview drawn 390 pt wide (a phone), centred.
    var mobile = false
    /// Bumped to reload the preview (Reload, or a new preview of the same page).
    var reloads = 0
    /// A project file picked in Dev's profile (Files): the Code tab shows "All files" with it
    /// selected. `focusSeq` is bumped on every pick, so picking the same file again selects it again.
    var focusPath: String? = nil
    var focusSeq = 0
    /// Live chosen (true) or Preview chosen (false) for this item; nil: what its data decides.
    var live: Bool? = nil

    init(item: CanvasItem, tab: Tab? = nil, mobile: Bool = false, reloads: Int = 0) {
        self.item = item; self.tab = tab ?? item.firstTab; self.mobile = mobile; self.reloads = reloads
    }

    /// What the Canvas becomes when `item` is opened over `current`: the same artifact keeps its tab and width and
    /// reloads (Dev changed the site since); another one starts on its first tab, keeping the width.
    static func opening(_ item: CanvasItem, over current: CanvasState?) -> CanvasState {
        guard var s = current else { return CanvasState(item: item) }
        if s.item.id == item.id {
            s.item = item
            s.reloads += 1
            s.focusPath = nil
            if !s.tabs.contains(s.tab) { s.tab = item.firstTab }
            return s
        }
        return CanvasState(item: item, tab: item.firstTab, mobile: s.mobile, reloads: s.reloads + 1)
    }

    /// An artifact arriving live: opened (or reloaded) and shown on its first tab, whatever tab was in front.
    static func arriving(_ item: CanvasItem, over current: CanvasState?) -> CanvasState {
        var s = opening(item, over: current)
        s.tab = item.firstTab
        return s
    }

    /// Dev started working in the dialogue in front: the Canvas shows Dev working now, on Activity (each
    /// artifact has its own activity, so the live one is its own item; the width stays). `page`: the dialogue's newest
    /// preview (the Preview tab stays while Dev works).
    static func activity(profile: String?, page: URL? = nil, over current: CanvasState?) -> CanvasState {
        let live = CanvasItem.activity(profile: profile, page: page)
        guard var s = current else { return CanvasState(item: live, tab: .activity) }
        if s.item.kind != .activity || s.item.profile != profile {
            s.item = live
        } else if let page, s.item.page != page {
            s.item.page = page
        }
        s.tab = .activity
        return s
    }

    /// A file of Dev's project picked in the profile: the Canvas shows it on Code, "All files". An open Canvas with
    /// this project's files keeps its artifact; otherwise it shows the project itself (no page, no record).
    static func focusing(_ path: String, profile: String, over current: CanvasState?) -> CanvasState {
        var s: CanvasState
        if let c = current, c.item.hasCode, c.item.profile == profile, c.item.kind != .devPush {
            s = c
        } else {
            s = CanvasState(item: CanvasItem.project(profile: profile), tab: .code, mobile: current?.mobile ?? false,
                            reloads: (current?.reloads ?? 0) + 1)
            s.focusSeq = current?.focusSeq ?? 0
        }
        s.tab = .code
        s.focusPath = path
        s.focusSeq += 1
        return s
    }

    /// The tabs the header offers, in order: Preview (a page), Activity, Code (Code last).:
    /// Changes and a push keep the project's Preview first too; a push's Code is its Changes.
    var tabs: [Tab] {
        if item.kind == .images { return [.images] }
        var t: [Tab] = []
        if item.previewURL != nil { t.append(.preview) }
        t.append(.activity)
        if item.kind == .devPush || item.hasCode || item.hasChanges { t.append(.code) }
        return t
    }
}

/// Dev's project files (GET /agents/dev/files, /agents/dev/file).
enum DevFiles {
    /// One line of the file list: indented by its depth; directories are drawn but not opened.
    struct Row: Equatable, Identifiable {
        let path: String
        let name: String
        let depth: Int
        let isDir: Bool
        var id: String { path }
    }

    /// `{ok, path, files:[...]}` -> the entries; an error's own words (or a plain one) otherwise.
    static func parseList(_ data: Data) -> Result<[String], DevFilesError> {
        guard let o = JSONRead.object(data) else { return .failure(DevFilesError("Could not read the files.")) }
        guard JSONRead.bool(o, "ok") else { return .failure(DevFilesError(JSONRead.string(o, "error") ?? "Could not read the files.")) }
        return .success((o["files"] as? [Any] ?? []).compactMap { $0 as? String })
    }

    /// `{ok, path, content}` -> the text.
    static func parseFile(_ data: Data) -> Result<String, DevFilesError> {
        guard let o = JSONRead.object(data) else { return .failure(DevFilesError("Could not read the file.")) }
        guard JSONRead.bool(o, "ok") else { return .failure(DevFilesError(JSONRead.string(o, "error") ?? "Could not read the file.")) }
        return .success(o["content"] as? String ?? "")
    }

    /// The entries as one flat list: "./" and trailing "/" dropped, duplicates gone, ordered by path components (a
    /// folder right above what it holds), indented by depth. A directory is an entry that ended in "/" or that is a
    /// prefix of another entry; a folder the server left out is drawn above its files.
    static func rows(_ entries: [String]) -> [Row] {
        var dirs = Set<String>()
        var paths = Set<String>()
        for raw in entries {
            var p = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            while p.hasPrefix("./") { p.removeFirst(2) }
            if p.hasSuffix("/") {
                while p.hasSuffix("/") { p.removeLast() }
                if !p.isEmpty { dirs.insert(p) }
            }
            if p.isEmpty || p == "." { continue }
            paths.insert(p)
        }
        for p in paths {
            var parts = p.split(separator: "/").map(String.init)
            parts.removeLast()
            var prefix = ""
            for c in parts {
                prefix = prefix.isEmpty ? c : prefix + "/" + c
                dirs.insert(prefix)
            }
        }
        paths.formUnion(dirs)
        let ordered = paths.sorted { a, b in
            let x = a.split(separator: "/"), y = b.split(separator: "/")
            for (l, r) in zip(x, y) where l != r { return l < r }
            return x.count < y.count
        }
        return ordered.map { p in
            let parts = p.split(separator: "/")
            return Row(path: p, name: String(parts.last ?? Substring(p)), depth: parts.count - 1, isDir: dirs.contains(p))
        }
    }

    /// The file opened first: index.html at the top, else the first file.
    static func firstFile(_ rows: [Row]) -> String? {
        rows.first { !$0.isDir && $0.path == "index.html" }?.path ?? rows.first { !$0.isDir }?.path
    }

    /// "1\n2\n...\nN" for a text of N lines (a trailing newline makes no extra line).
    static func lineNumbers(_ text: String) -> String {
        var n = text.reduce(1) { $1 == "\n" ? $0 + 1 : $0 }
        if text.hasSuffix("\n"), n > 1 { n -= 1 }
        return (1...n).map(String.init).joined(separator: "\n")
    }

    /// The longest text the Code view draws; the rest is cut with a line saying so.
    static let maxChars = 200_000
}

struct DevFilesError: Error, Equatable {
    let message: String
    init(_ message: String) { self.message = message }
}

/// One Crea block's pictures as the Canvas shows them ("like on the canvas, like in Claude
/// Design": moved and zoomed). `chatProfile` / `chatDlg` name the dialogue the block is in (Use draft answers there,
/// expired links are signed again from it).
struct CreaBoard: Equatable {
    let stage: CreaImages.Stage
    let brief: String
    let pictures: [CreaImages.Picture]
    var selected: String
    var chatProfile: String? = nil
    var chatDlg: String? = nil
    /// A layered block's words (CreaLayers.swift): the board draws them over the pictures with the same
    /// editor as the chat block, on the same layouts (CreaLayersStore). Empty: flat pictures.
    var layers: [CreaLayer] = []

    init(images: CreaImages, selected: String?, chatProfile: String? = nil, chatDlg: String? = nil) {
        stage = images.stage
        brief = images.brief
        pictures = images.images
        layers = images.layers
        self.selected = selected.flatMap { s in images.images.contains { $0.id == s } ? s : nil } ?? images.images.first?.id ?? ""
        self.chatProfile = chatProfile
        self.chatDlg = chatDlg
    }

    /// One block, one board (its pictures' ids).
    var id: String { pictures.map(\.id).joined(separator: ",") }

    var isDrafts: Bool { stage == .drafts }

    var title: String {
        switch stage {
        case .drafts: return pictures.count == 1 ? "Draft" : "Drafts"
        case .final: return pictures.count == 1 ? "Image" : "Images"
        case .edit: return "Edited image"
        case .photo: return "Photo"
        }
    }

    var selectedPicture: CreaImages.Picture? { pictures.first { $0.id == selected } ?? pictures.first }
    var selectedIndex: Int { pictures.firstIndex { $0.id == selected } ?? 0 }

    /// "Use draft N" from the board: drafts only, in a known dialogue.
    var canUseDraft: Bool { isDrafts && chatDlg != nil }

    var isLayered: Bool { !layers.isEmpty }

    /// The number a picture is shown with (1...count, as in the chat block).
    func shownNumber(_ p: CreaImages.Picture) -> Int { CreaImages.shownNumber(p, in: pictures) }

    /// What "Use draft" on the board sends for a picture.
    func useDraftText(_ p: CreaImages.Picture) -> String { CreaImages.useDraft(shown: shownNumber(p), server: p.n) }
}

/// The board's geometry (item 8): every picture drawn at one height in a row with gaps, the selected one at the
/// origin; zoom about a point; fit. Units are board points (a picture is `unit` high at 100%).
enum CanvasBoardMath {
    static let unit: Double = 1024
    static let gap: Double = 64
    static let minScale: Double = 0.05
    static let maxScale: Double = 8
    /// The zoom steps of +/- and of \u{2318}+ / \u{2318}-.
    static let steps: [Double] = [0.05, 0.1, 0.15, 0.25, 0.33, 0.5, 0.67, 0.75, 1, 1.25, 1.5, 2, 3, 4, 6, 8]

    /// Each picture's centre x and width (board units), the selected one centred at 0. `aspects`: width / height.
    static func layout(aspects: [Double], selected: Int) -> [(x: Double, w: Double)] {
        guard !aspects.isEmpty else { return [] }
        let widths = aspects.map { unit * max(0.2, min(5, $0 > 0 ? $0 : 1)) }
        var xs: [Double] = []
        var left = 0.0
        for w in widths { xs.append(left + w / 2); left += w + gap }
        let i = max(0, min(selected, widths.count - 1))
        let shift = xs[i]
        return zip(xs, widths).map { pair in (x: pair.0 - shift, w: pair.1) }
    }

    static func clamp(_ s: Double) -> Double { max(minScale, min(maxScale, s)) }

    /// The scale that fits a picture `w` x `h` in a view `vw` x `vh` with `pad` around it (at most 200%).
    static func fit(w: Double, h: Double, vw: Double, vh: Double, pad: Double = 32) -> Double {
        guard w > 0, h > 0, vw > 0, vh > 0 else { return 1 }
        return clamp(min(2, min(max(1, vw - 2 * pad) / w, max(1, vh - 2 * pad) / h)))
    }

    /// The next step up or down from `s`.
    static func step(_ s: Double, up: Bool) -> Double {
        if up { return steps.first { $0 > s + 0.001 } ?? maxScale }
        return steps.last { $0 < s - 0.001 } ?? minScale
    }

    /// The offset that keeps the board point under `p` (view point relative to the view's centre) in place when the
    /// scale goes from `from` to `to`.
    static func zoom(offset: (x: Double, y: Double), about p: (x: Double, y: Double), from: Double, to: Double) -> (x: Double, y: Double) {
        guard from > 0 else { return offset }
        let k = to / from
        return (x: p.x - (p.x - offset.x) * k, y: p.y - (p.y - offset.y) * k)
    }

    /// "100%".
    static func percent(_ s: Double) -> String { "\(Int((s * 100).rounded()))%" }
}
