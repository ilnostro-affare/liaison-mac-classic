import Foundation

/// ai.js LIA_CATS / settings.js SX_CATS: where the money went, in the same words on every surface.
/// Pure: the colours live in AppConfig (catRead, catWrite, catWeb, line3) and are looked up by key.
enum UsageCats {
    struct Cat: Equatable { let key: String; let name: String; let quiet: Bool }

    static let all: [Cat] = [
        Cat(key: "read", name: "Reading", quiet: false),
        Cat(key: "write", name: "Changes", quiet: false),
        Cat(key: "web", name: "Web search", quiet: false),
        // Money spent before the breakdown shipped, which belongs to no category. Listed only while it exists.
        Cat(key: "other", name: "Earlier this week", quiet: true),
    ]

    struct Row: Equatable { let key: String; let name: String; let text: String }
    struct Segment: Equatable { let key: String; let width: Double }

    /// ai.js liaSessTxt: anything above zero and below one is "<1%", never a rounded-down zero.
    static func sessText(_ v: Double) -> String {
        if v > 0 && v < 1 { return "<1%" }
        return "\(Int(v.rounded()))%"
    }

    /// True when at least one category carries money (ai.js: a split with nothing in it is no split).
    static func hasSplit(_ split: [String: Double]) -> Bool {
        all.contains { (split[$0.key] ?? 0) > 0 }
    }

    /// ai.js liaCatRows: the three real categories always, even at zero; the remainder only above zero.
    /// No split on the record: no rows.
    static func rows(_ split: [String: Double]) -> [Row] {
        guard !split.isEmpty else { return [] }
        return all.filter { !$0.quiet || (split[$0.key] ?? 0) > 0 }
            .map { Row(key: $0.key, name: $0.name, text: sessText(split[$0.key] ?? 0)) }
    }

    /// ai.js liaCatBar: only what has width, each clamped to the track. Empty: draw one fill instead.
    static func segments(_ split: [String: Double]) -> [Segment] {
        all.compactMap { c in
            let v = split[c.key] ?? 0
            return v > 0 ? Segment(key: c.key, width: min(100, v)) : nil
        }
    }

    /// ai.js liaCatTip: "Reading 12%" per line, the remainder only while it exists.
    static func tip(_ split: [String: Double]) -> String {
        guard !split.isEmpty else { return "" }
        return all.filter { !$0.quiet || (split[$0.key] ?? 0) > 0 }
            .map { $0.name + "  " + "\(Int((split[$0.key] ?? 0).rounded()))%" }.joined(separator: "\n")
    }
}

extension UsageInfo {
    /// The figure beside "Usage" in the ring's panel (ai.js paintLimPanel data-cat-sum): a dash when not measured.
    var chatSummary: String { chatKnown ? UsageCats.sessText(chatPct) + " of a session" : "\u{2014}" }

    /// The panel's category rows: none for a chat that was not measured.
    var chatRows: [UsageCats.Row] { chatKnown ? UsageCats.rows(chatSplit) : [] }

    /// The tall bar under them: past a full session it is one full red bar.
    var chatOverrun: Bool { chatKnown && Int(chatPct.rounded()) >= 100 }
}
