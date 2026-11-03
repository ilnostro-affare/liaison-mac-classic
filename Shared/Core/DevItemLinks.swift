import Foundation

// One consistent Preview | Live per Dev item, and every Dev item that relates to a site or a branch
// linked to its preview / live site. Pure: the Canvas and the cards read these; the stores feed them.

/// What the Canvas's Preview tab shows for one Dev item, decided from the item's own data.
/// A private preview (pv-...) -> Preview is the default; Live sits beside it (the workspace's site, or Publish)
/// An item that IS a published site -> Live; with the dialogue's private preview known, both, Preview by default
/// Live is selected only when the person chose it for this item (`chosen`), or when there is nothing but Live
struct CanvasLiveChoice: Equatable {
    /// The private preview the Preview side loads (nil: none known).
    let preview: URL?
    /// The item's own live site (nil: the workspace's live site, read by the Live side from DevSites).
    let site: URL?
    /// The Live side exists.
    let offersLive: Bool
    /// Live is in front.
    let live: Bool

    /// Both sides exist: the Preview | Live switch is drawn.
    var showsSwitch: Bool { preview != nil && offersLive }

    /// `own`: the page the item names (its preview, its live site, the project's page); `isDev`: one of Dev's items
    /// (a workspace project); `fallback`: the dialogue's newest private preview; `chosen`: the person's pick.
    static func resolve(own: URL?, isDev: Bool, fallback: URL?, chosen: Bool?) -> CanvasLiveChoice {
        guard isDev else { return CanvasLiveChoice(preview: own, site: nil, offersLive: false, live: false) }
        let ownPrivate = DevSites.isPrivatePreview(own)
        let ownSite = !ownPrivate && DevSites.siteURL(own?.absoluteString) != nil
        let privateFallback = DevSites.isPrivatePreview(fallback) ? fallback : nil
        let preview: URL?
        if ownPrivate { preview = own } else if own == nil || ownSite { preview = privateFallback } else { preview = own }
        let site: URL? = ownSite ? own : nil
        let offersLive = ownSite || DevSites.isPrivatePreview(preview)
        let live: Bool
        if preview != nil && offersLive { live = chosen ?? false } else { live = preview == nil && offersLive }
        return CanvasLiveChoice(preview: preview, site: site, offersLive: offersLive, live: live)
    }

    /// The key the person's pick is kept under: one per project and item.
    static func key(profile: String?, item: String) -> String { (profile ?? "") + "|" + item }
}

/// The two links under a Dev work / push card (Preview, Live): resolved from the block itself, else the dialogue's
/// newest pages, else the workspace's live site (DevSites).
struct DevItemLinks: Equatable {
    let preview: URL?
    let live: URL?

    var isEmpty: Bool { preview == nil && live == nil }

    /// `own`: the block's `preview` (a preview or a live site); `dialoguePreview` / `dialoguePage`: the dialogue's newest
    /// private preview and newest page of any kind; `siteLive`: the workspace's live site from the registry.
    static func resolve(own: URL?, dialoguePreview: URL?, dialoguePage: URL?, siteLive: URL?) -> DevItemLinks {
        func priv(_ u: URL?) -> URL? { DevSites.isPrivatePreview(u) ? u : nil }
        func site(_ u: URL?) -> URL? { u.flatMap { DevSites.siteURL($0.absoluteString) } }
        let p = priv(own) ?? priv(dialoguePreview) ?? priv(dialoguePage)
        let l = site(own) ?? site(dialoguePage) ?? site(siteLive)
        return DevItemLinks(preview: p, live: l)
    }
}

// MARK: - the diff's rows, built once (off the main thread)

/// One row of a file's drawn diff: a hunk's separator or one line.
struct DevDiffRow: Equatable, Identifiable {
    enum Kind: Equatable { case hunk(String), line(DevDiff.Line) }
    let id: Int
    let kind: Kind
}

/// A file's diff as the Code tab draws it: the rows (capped at DevDiff.maxLines), the gutter's width in digits and
/// whether the file was cut.
struct DevDiffLayout: Equatable {
    let rows: [DevDiffRow]
    let digits: Int
    let tooLong: Bool

    static let empty = DevDiffLayout(rows: [], digits: 2, tooLong: false)

    static func make(_ file: DevDiff.File?) -> DevDiffLayout {
        guard let file else { return .empty }
        var out: [DevDiffRow] = []
        var n = 0
        var cut = false
        outer: for h in file.hunks {
            out.append(DevDiffRow(id: n, kind: .hunk(h.label))); n += 1
            for l in h.lines {
                if n >= DevDiff.maxLines { cut = true; break outer }
                out.append(DevDiffRow(id: n, kind: .line(l))); n += 1
            }
        }
        let mx = file.hunks.map { max($0.oldStart + $0.oldCount, $0.newStart + $0.newCount) }.max() ?? 1
        return DevDiffLayout(rows: out, digits: max(String(mx).count, 2), tooLong: cut)
    }
}

/// A file's text as numbered lines (the Code tab draws only the ones in view).
enum DevCodeLines {
    /// The lines (a trailing newline makes no extra line), the text first cut at DevFiles.maxChars with a line saying so.
    static func make(_ text: String) -> [String] {
        var s = text
        var cut = false
        if s.count > DevFiles.maxChars { s = String(s.prefix(DevFiles.maxChars)); cut = true }
        var lines = s.replacingOccurrences(of: "\r\n", with: "\n").split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        if lines.count > 1, lines.last == "" { lines.removeLast() }
        if cut { lines.append("\u{2026} (cut: the file is too long to show here)") }
        return lines
    }
}

// A bare work item ("Work \u{00B7} 1 step": steps, no file changed) draws no card in the thread; its
// Activity, Preview and Live stay in the Canvas and on Dev's other cards.
extension DevWork {
    /// Changed no files: no card for it in the thread.
    var isBare: Bool { meta.fileChanges == nil }
}
