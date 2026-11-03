import Foundation

// The right side of the conversation sheet (the agent's browser or the Canvas) folds to a spine and
// unfolds by itself when something new appears there. The pure rules: what unfolds it, and what counts as a new place.
enum PaneFold {
    /// Seconds after the person folded it during which nothing unfolds it by itself.
    static let grace: Double = 2

    /// What happened on the right while it was folded.
    enum Trigger: Equatable {
        /// A preview, document or file arrived (`.liaCanvasArrived`).
        case canvasArrived
        /// The agent's browser opened a tab or brought another one to the front.
        case newTab
        /// The selected tab committed a page at another host or path.
        case navigated
        /// An approval card opened in this conversation.
        case gateOpened
        /// One of Dev's Activity steps: counted on the spine, never unfolds.
        case activity
    }

    /// Parameter sinceFold: seconds since the person folded it (nil: unknown, long ago).
    static func autoUnfolds(_ t: Trigger, folded: Bool, sinceFold: Double?) -> Bool {
        guard folded, t != .activity else { return false }
        if let s = sinceFold, s >= 0, s < grace { return false }
        return true
    }

    /// A page at another host or path. The same page again, a fragment or a query change is not a new place; nothing
    /// (nil) is never one.
    static func isNewPlace(from old: URL?, to new: URL?) -> Bool {
        guard let new, let nh = new.host?.lowercased(), !nh.isEmpty else { return false }
        guard let old, let oh = old.host?.lowercased() else { return true }
        if oh != nh { return true }
        return trimmed(old.path) != trimmed(new.path)
    }

    private static func trimmed(_ p: String) -> String {
        var s = p
        while s.hasSuffix("/") { s.removeLast() }
        return s
    }
}
