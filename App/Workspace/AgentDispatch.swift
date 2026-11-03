import Foundation

// A message for one agent sent from outside its conversation (the address bar, notes, the page, the side
// panel). It goes into that agent's dialogue without opening the conversation sheet, with `origin` set, so the
// server stores where it came from and the bubble shows a small chip ("from notes").
// DispatchOriginStore is only a fallback now, for messages sent before the server kept `origin`.

enum DispatchOrigin: String, Codable {
    case addressBar, notes, page, sidePanel

    /// The server's surface for this origin.
    var surface: DlgOrigin.Surface {
        switch self {
        case .addressBar: return .addressBar
        case .notes: return .notes
        case .page: return .page
        case .sidePanel: return .sidePanel
        }
    }

    var label: String {
        switch self {
        case .addressBar: return "from the address bar"
        case .notes: return "from notes"
        case .page: return "from the page"
        case .sidePanel: return "from the side panel"
        }
    }
}

/// Where each dispatched message came from, by thread and the exact text of the person's message.
/// UserDefaults-backed, newest 500 kept.
final class DispatchOriginStore: @unchecked Sendable {
    static let shared = DispatchOriginStore()
    private static let key = "lia_dispatch_origins"
    private static let cap = 500

    private struct Entry: Codable { let thread: String; let text: String; let origin: DispatchOrigin }
    private var entries: [Entry]
    private let lock = NSLock()

    private init() {
        if let d = UserDefaults.standard.data(forKey: Self.key), let e = try? JSONDecoder().decode([Entry].self, from: d) {
            entries = e
        } else {
            entries = []
        }
    }

    func record(thread: String, text: String, origin: DispatchOrigin) {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        lock.lock()
        entries.removeAll { $0.thread == thread && $0.text == t }
        entries.append(Entry(thread: thread, text: t, origin: origin))
        if entries.count > Self.cap { entries.removeFirst(entries.count - Self.cap) }
        let snapshot = entries
        lock.unlock()
        if let d = try? JSONEncoder().encode(snapshot) { UserDefaults.standard.set(d, forKey: Self.key) }
    }

    func origin(thread: String, text: String) -> DispatchOrigin? {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        lock.lock(); defer { lock.unlock() }
        return entries.last { $0.thread == thread && $0.text == t }?.origin
    }
}

extension WorkspaceModel {
    /// Sends `text` to `agent` ("lia": the team) in the current workspace, without opening the conversation. Only for
    /// a field that is itself a messenger (the side panel); quick actions use `draft` (ChatForward.swift), unsent.
    func dispatch(agent: String, text: String, origin: DispatchOrigin) {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty, let c = chat(for: DialogueSummary.dlg(forAgent: agent)) else { return }
        // Kept on this Mac as well, for a bubble drawn before the server's copy (with its origin) arrives.
        DispatchOriginStore.shared.record(thread: c.key, text: t, origin: origin)
        c.send(t, origin: origin.surface)
    }
}
