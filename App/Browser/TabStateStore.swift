import Foundation

/// Each tab's WebKit `interactionState` (back/forward list, scroll, form fields) on disk, one file per tab, out of
/// UserDefaults: Application Support/Liaison/TabState/<account>/<chat>/<tab>.lts (TabRestore's envelope, which also
/// records the address the state was taken at). Writes go to one serial queue; `flush` waits for them (quit, sleep).
/// A missing or broken file is no error: the tab restores from its latest address (BrowserMemory).
enum TabStateStore {
    private static let queue = DispatchQueue(label: "lia.browser.tabstate", qos: .utility)

    private static let root: URL? = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
        .appendingPathComponent("Liaison", isDirectory: true)
        .appendingPathComponent("TabState", isDirectory: true)

    static func dir(account: String?, chat: String) -> URL? {
        guard let a = TabRestore.fileName(account ?? "_none"), let c = TabRestore.fileName(chat) else { return nil }
        return root?.appendingPathComponent(a, isDirectory: true).appendingPathComponent(c, isDirectory: true)
    }

    private static func file(account: String?, chat: String, tab: String) -> URL? {
        guard let t = TabRestore.fileName(tab) else { return nil }
        return dir(account: account, chat: chat)?.appendingPathComponent(t + ".lts")
    }

    /// The state the tab had at `url`. Read on the caller's thread (a few hundred KB at most, once per tab restore).
    static func read(account: String?, chat: String, tab: String) -> (url: String, state: Data)? {
        guard let f = file(account: account, chat: chat, tab: tab), let d = try? Data(contentsOf: f) else { return nil }
        return TabRestore.decode(d)
    }

    static func write(_ state: Data, url: String, account: String?, chat: String, tab: String) {
        guard let f = file(account: account, chat: chat, tab: tab), let d = TabRestore.encode(url: url, state: state) else { return }
        queue.async {
            try? FileManager.default.createDirectory(at: f.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? d.write(to: f, options: .atomic)
        }
    }

    /// Files of tabs the chat no longer has.
    static func prune(account: String?, chat: String, keep: Set<String>) {
        guard let d = dir(account: account, chat: chat) else { return }
        let names = Set(keep.compactMap(TabRestore.fileName))
        queue.async {
            let files = (try? FileManager.default.contentsOfDirectory(atPath: d.path)) ?? []
            let ids = files.filter { $0.hasSuffix(".lts") }.map { String($0.dropLast(4)) }
            for id in TabRestore.orphans(files: ids, keep: names) {
                try? FileManager.default.removeItem(at: d.appendingPathComponent(id + ".lts"))
            }
        }
    }

    /// The chat is gone (deleted, or dropped from BrowserMemory): its states go too.
    static func forget(account: String?, chat: String) {
        guard let d = dir(account: account, chat: chat) else { return }
        queue.async { try? FileManager.default.removeItem(at: d) }
    }

    /// Waits for the writes queued so far (quit, system sleep).
    static func flush() { queue.sync {} }
}
