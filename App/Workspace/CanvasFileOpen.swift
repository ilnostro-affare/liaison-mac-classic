import SwiftUI
import AppKit

// ("file paths as chips, opened in our Changes - or Files - without closing the messenger, on the right
// as usual"): a click on a path chip (FileChips) opens the Canvas of the dialogue in front. A file the dialogue's diff
// holds opens in Changes with that file picked; any other file in Files ("All files") with it picked; a folder in
// Files with that folder marked.

/// A file picked from the chat for an item's Changes (CanvasChangesList selects it). Kept per item (`key`), with a
/// sequence so the same file picked again is picked again, and a time so a list built later still takes it once.
@MainActor
final class CanvasChangeFocus: ObservableObject {
    static let shared = CanvasChangeFocus()

    struct Focus: Equatable {
        let path: String
        let seq: Int
        let at: Date
    }

    @Published private(set) var focus: [String: Focus] = [:]
    private var seq = 0

    /// The item's key: its project and its id (as the Code tab keys its source pick).
    static func key(_ item: CanvasItem) -> String { (item.profile ?? "") + "|" + item.id }

    func set(_ path: String, item: CanvasItem) {
        seq &+= 1
        focus[Self.key(item)] = Focus(path: path, seq: seq, at: Date())
    }

    /// The item's focus when it was set a moment ago (a view built for it now takes it; an old one is left alone).
    func fresh(_ key: String?) -> Focus? {
        guard let key, let f = focus[key], Date().timeIntervalSince(f.at) < 6 else { return nil }
        return f
    }
}

@MainActor
enum CanvasFileOpen {
    /// Opens `file` in the Canvas of the conversation in front (the messenger stays open on the left).
    static func open(_ file: FileRef) {
        guard let ws = WorkspaceModel.current, let dlg = ws.sheet, let chat = ws.chat(for: dlg) else { return }
        let key = chat.key
        let store = CanvasStore.shared
        store.note(chat)
        if file.isDir {
            // a folder: Files, the folder marked ("/" alone: the project's top)
            animate { store.focusFile(file.path.isEmpty ? "/" : file.path + "/", profile: chat.profile, key: key) }
            return
        }
        Task { @MainActor in
            if let hit = await changesItem(for: file.path, chat: chat, current: store.state(key)?.item) {
                animate {
                    if store.state(key)?.item.id == hit.item.id {
                        store.update(key) { s in s.tab = .code; s.focusPath = nil }
                    } else {
                        store.open(hit.item, key: key)
                        store.update(key) { s in s.tab = .code }
                    }
                }
                CanvasChangeFocus.shared.set(hit.path, item: hit.item)
            } else {
                animate { store.focusFile(file.path, profile: chat.profile, key: key) }
            }
        }
    }

    private static func animate(_ f: () -> Void) {
        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion { f() } else { withAnimation(.easeOut(duration: 0.2)) { f() } }
    }

    /// The artifact whose changes hold `path`: the Canvas's own item first, then the dialogue's newest artifacts (a few),
    /// with the path as its changes list it. Each record is read once (DevArtStore keeps it).
    private static func changesItem(for path: String, chat: TeamChatModel,
                                    current: CanvasItem?) async -> (item: CanvasItem, path: String)? {
        var candidates: [CanvasItem] = []
        if let c = current, c.hasChanges, c.profile == chat.profile { candidates.append(c) }
        outer: for it in chat.items.reversed() {
            for b in it.message.blocks.reversed() {
                guard let item = CanvasItem(block: b, profile: chat.profile), item.hasChanges,
                      !(item.changes?.isEmpty ?? false), !candidates.contains(where: { $0.id == item.id }) else { continue }
                candidates.append(item)
                if candidates.count >= 4 { break outer }
            }
        }
        let arts = DevArtStore.shared
        for item in candidates {
            await arts.load(auth: chat.auth, item: item)
            // another view may be reading it: wait for that read a little
            var tries = 0
            while case .loading? = arts.load(for: item), tries < 30 {
                try? await Task.sleep(nanoseconds: 100_000_000)
                tries += 1
            }
            if case .loaded(let l)? = arts.load(for: item), let hit = FileChips.match(path, in: l.list.map(\.path)) {
                return (item, hit)
            }
        }
        return nil
    }
}
