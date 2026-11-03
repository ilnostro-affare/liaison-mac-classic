import Foundation

/// A page's alert/confirm budget (the browser panel): after `limit` dialogs within `window` seconds, the rest
/// of that page load gets none. Reset on every new main-frame commit.
struct DialogThrottle {
    var limit = 3
    var window: TimeInterval = 10
    private(set) var suppressed = false
    private var times: [Date] = []

    init(limit: Int = 3, window: TimeInterval = 10) { self.limit = limit; self.window = window }

    /// True: show this dialog. False: deny it silently (and every later one until `reset`).
    mutating func allow(now: Date = Date()) -> Bool {
        if suppressed { return false }
        times = times.filter { now.timeIntervalSince($0) < window }
        if times.count >= limit { suppressed = true; times = []; return false }
        times.append(now)
        return true
    }

    mutating func reset() { suppressed = false; times = [] }
}
