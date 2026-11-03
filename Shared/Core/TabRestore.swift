import Foundation

// "We always keep the NEW link." A tab is saved and restored at the page it is on now, never at the
// one it was opened, pinned or grouped with (Arc's "Back to pinned URL" reset is not ours). Like Safari and Chrome:
// the latest address follows every committed and same-document navigation (pushState, replaceState, #hash), is
// written within a moment, and again at once when the app resigns, quits or the Mac goes to sleep. WebKit's
// `interactionState` (back/forward list, scroll, form fields) goes with it when it is still about that address.
// The pure rules of that; the web views and files are BrowserModel's and TabStateStore's.
enum TabRestore {
    /// A tab's interaction state above this is not kept (the address alone restores it).
    static let maxStateBytes = 2 * 1024 * 1024
    /// Seconds between two automatic saves while pages change (a page sets its address several times as it loads).
    static let saveDelay: Double = 1

    static func isWeb(_ u: URL?) -> Bool {
        guard let s = u?.scheme?.lowercased() else { return false }
        return s == "http" || s == "https"
    }

    /// The tab's latest address. A tab not loaded (restored or asleep) is at its pending address; a loaded one at
    /// what its web view shows now (read live: the published copy arrives a run-loop turn later); else the last
    /// address it knew. `about:blank` (what a sleeping tab holds) and other non-web addresses never win.
    static func latest(pending: URL?, live: URL?, known: URL?) -> URL? {
        for u in [pending, live, known] where isWeb(u) { return u }
        return nil
    }

    /// The address to save: `url`, with the current position of its YouTube video when the last sample is of this
    /// same video (its `t` aside). Anything else: `url` as it is.
    static func withMedia(_ url: URL, sample: (url: URL, seconds: Double)?) -> URL {
        guard let sample, sameIgnoringTime(url, sample.url), let u = MediaResume.url(url, at: sample.seconds) else { return url }
        return u
    }

    /// The same page, whatever its YouTube `t` says.
    static func sameIgnoringTime(_ a: URL, _ b: URL) -> Bool {
        if a == b { return true }
        guard MediaResume.applies(to: a), MediaResume.applies(to: b),
              let na = MediaResume.url(a, at: 0), let nb = MediaResume.url(b, at: 0) else { return false }
        return na == nb
    }

    enum Source: Equatable { case state, url }

    /// Restore from the interaction state only while it is about the address being restored: the state was taken at
    /// `stateURL`, and if the tab moved on after it (a navigation not captured yet, or a YouTube position written into
    /// the address), the newer address wins and the state is dropped.
    static func source(savedURL: String, stateURL: String?, stateBytes: Int?) -> Source {
        guard let stateURL, let n = stateBytes, n > 0, n <= maxStateBytes, stateURL == savedURL else { return .url }
        return .state
    }

    static func keeps(stateBytes n: Int) -> Bool { n > 0 && n <= maxStateBytes }

    /// A file-safe name for an id (a chat, an account, a tab): letters, digits, '-', '_', '.'; at most 80; nil when
    /// nothing is left or it would be '.' / '..'.
    static func fileName(_ id: String) -> String? {
        let s = String(id.prefix(80).map { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" || $0 == ".") ? $0 : "_" })
        guard !s.isEmpty, s != ".", s != ".." else { return nil }
        return s
    }

    /// State files no saved tab refers to any more (`files` are names without extension).
    static func orphans(files: [String], keep: Set<String>) -> [String] {
        files.filter { !keep.contains($0) }.sorted()
    }

    /// "Go to the Pinned Address" is offered only when a pinned tab is somewhere else now (an explicit menu item,
    /// never a reset: it is a navigation, Back returns to where the tab was).
    static func offersPinnedAddress(pinned: Bool, home: URL?, current: URL?) -> Bool {
        guard pinned, let home, isWeb(home) else { return false }
        guard let current else { return true }
        return normalized(home) != normalized(current)
    }

    private static func normalized(_ u: URL) -> String {
        var s = u.absoluteString
        if s.hasSuffix("/") { s.removeLast() }
        return s.lowercased()
    }

    // MARK: the state file: "LTS1", the address's length (UInt32, big-endian), the address (UTF-8), WebKit's bytes.

    private static let magic: [UInt8] = Array("LTS1".utf8)

    static func encode(url: String, state: Data) -> Data? {
        let u = Array(url.utf8)
        guard keeps(stateBytes: state.count), !u.isEmpty, u.count < 64 * 1024 else { return nil }
        var out = Data(magic)
        let n = UInt32(u.count)
        out.append(contentsOf: [UInt8(n >> 24 & 0xFF), UInt8(n >> 16 & 0xFF), UInt8(n >> 8 & 0xFF), UInt8(n & 0xFF)])
        out.append(contentsOf: u)
        out.append(state)
        return out
    }

    /// nil: not ours, cut short, empty or too big (the caller restores from the address).
    static func decode(_ data: Data) -> (url: String, state: Data)? {
        let b = [UInt8](data)
        guard b.count > 8, Array(b[0..<4]) == magic else { return nil }
        let n = Int(b[4]) << 24 | Int(b[5]) << 16 | Int(b[6]) << 8 | Int(b[7])
        guard n > 0, 8 + n < b.count, let url = String(bytes: b[8..<(8 + n)], encoding: .utf8) else { return nil }
        let state = Data(b[(8 + n)...])
        guard keeps(stateBytes: state.count) else { return nil }
        return (url, state)
    }
}

// MARK: \u{2318}W on a pinned tab

extension TabRestore {
    enum CloseAction: Equatable {
        /// An ordinary tab (or an unpinned close, a move): it goes.
        case close
        /// A pinned tab: it stays, unloaded (asleep) at the page it is on now, never back at its pinned address;
        /// `select`: the tab to bring to front instead (nil: it was not in front, the selection stays).
        case unload(select: Int?)
        /// A pinned tab with nothing else to show: left as it is.
        case keep
    }

    /// What closing the tab at `index` does. `hidden`: the strip's tabs a collapsed group hides (never brought to
    /// front); the neighbour on the right is preferred, then the one on the left.
    static func closeAction(pinned: Bool, force: Bool, index: Int, selected: Bool, hidden: [Bool]) -> CloseAction {
        guard pinned, !force else { return .close }
        let n = hidden.count
        guard n > 1, index >= 0, index < n else { return .keep }
        guard selected else { return .unload(select: nil) }
        let order = Array((index + 1)..<n) + Array((0..<index).reversed())
        guard let j = order.first(where: { !hidden[$0] }) else { return .keep }
        return .unload(select: j)
    }
}
