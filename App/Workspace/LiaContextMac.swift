import Foundation

// Server: with every turn to Lia, what the person has been doing (a Screen Time summary of
// about the last 24 hours) and what is open now (titles and hosts of the workspace's main browser), so she can offer
// concrete help. Off with Settings > Screen Time > "Lia uses Screen Time and open tabs to suggest tasks": then nothing
// is sent. The shaping and caps are Shared/Core/LiaContext.swift. Never to another agent (the server drops it too).

/// The Screen Time part (24 h, today, 7 days), computed off the main thread at most once per 5 minutes per Liaison account.
@MainActor
final class LiaContextCache {
    static let shared = LiaContextCache()
    private var cached: (account: String, at: Date, value: LiaContext.Rollup)?
    private init() {}

    func screenTime() async -> LiaContext.Rollup? {
        let tracker = ScreenTimeTracker.shared
        // Screen Time turned off: no summary (an old ledger is not "what the person has been doing").
        guard tracker.isOn else { return nil }
        let account = tracker.account ?? "_", now = Date()
        if let c = cached, c.account == account, LiaContext.fresh(at: c.at, now: now) { return c.value }
        let ledger = tracker.ledger   // a value copy; the shaping runs off the main thread
        let value = await Task.detached(priority: .utility) { LiaContext.rollup(ledger, now: now) }.value
        cached = (account, now, value)
        return value
    }

    func reset() { cached = nil }
}

extension WorkspaceModel {
    /// The `context` object of a turn to Lia, or nil when the person turned it off or the workspace is gone.
    /// `hidden`: the tabs the person stopped sharing with this conversation (ScreenUnshared): never listed.
    func liaContext(profile id: String, hidden: Set<String> = []) async -> JSONObject? {
        guard LiaContext.isOn() else { return nil }
        guard let p = profiles.first(where: { $0.id == id }) else { return nil }
        // The workspace's main browser only, as it is (never created for this); a private window is not one of its
        // tabs. The tab list is cheap, so it is read fresh each turn.
        let b = openBrowsers[p.id]
        let front = b?.selected?.id
        let tabs = (b?.tabs ?? []).filter { !hidden.contains($0.shortID) }.map { t in
            LiaContext.TabIn(title: t.displayTitle, url: t.isStart ? nil : (t.loadedWebView?.url ?? t.url), isStart: t.isStart,
                             front: t.id == front)
        }
        let shaped = LiaContext.tabs(tabs)
        let st = await LiaContextCache.shared.screenTime() ?? LiaContext.Rollup()
        return LiaContext.payload(screenTime: st, tabs: shaped, now: Date())
    }
}
