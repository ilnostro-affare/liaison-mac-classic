import Foundation

// The address bar finds the workspace's campaigns, ad sets and ads by NAME. The names come from one read of
// find_entity with no query (the account's skeleton from the tree cache, no date window, so paused and old objects are
// there too), kept in memory per ad account and refreshed at most every ten minutes. Matching runs locally per
// keystroke. Read-only: nothing here plans or applies a write.

struct OmniEntity: Equatable, Sendable {
    enum Level: String, Sendable { case campaign, adSet, ad }

    let id: String
    let name: String
    let level: Level
    /// effective_status, else status ("ACTIVE", "CAMPAIGN_PAUSED"...); empty when Meta gave none.
    let status: String
    /// Where it sits: the campaign of an ad set, "campaign / ad set" of an ad; empty for a campaign.
    let path: String
    /// The name folded (case and diacritics): what a typed fragment is compared with.
    let key: String

    init(id: String, name: String, level: Level, status: String, path: String) {
        self.id = id; self.name = name; self.level = level; self.status = status; self.path = path
        key = OmniEntities.fold(name)
    }

    var levelLabel: String {
        switch level {
        case .campaign: return "Campaign"
        case .adSet: return "Ad set"
        case .ad: return "Ad"
        }
    }

    /// "ACTIVE" -> "Active", "CAMPAIGN_PAUSED" -> "Campaign paused", "ADSET_PAUSED" -> "Ad set paused".
    var statusLabel: String {
        let s = status.uppercased()
        if s.isEmpty { return "" }
        if s == "ADSET_PAUSED" { return "Ad set paused" }
        let words = s.split(separator: "_").map { $0.lowercased() }
        guard let first = words.first else { return "" }
        return ([first.prefix(1).uppercased() + first.dropFirst()] + words.dropFirst()).joined(separator: " ")
    }

    var isActive: Bool { status.uppercased() == "ACTIVE" }
}

enum OmniEntities {
    static let maxRows = 3
    static let minQuery = 2

    static func fold(_ s: String) -> String {
        s.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil).lowercased()
    }

    /// find_entity with no query: {ok, structure: {campaignId: {id, name, status, effective_status,
    /// adsets: {adsetId: {id, name, status, effective_status, ads: [{id, name, status, effective_status}]}}}}}.
    /// nil: not that answer (an error, a failed tree read), so the caller can retry later rather than cache nothing.
    static func parse(_ data: Data) -> [OmniEntity]? {
        guard let o = JSONRead.object(data), let tree = o["structure"] as? JSONObject else { return nil }
        var out: [OmniEntity] = []
        var seen: Set<String> = []
        func status(_ x: JSONObject) -> String { JSONRead.string(x, "effective_status") ?? JSONRead.string(x, "status") ?? "" }
        func name(_ x: JSONObject) -> String { (JSONRead.string(x, "name") ?? "").trimmingCharacters(in: .whitespacesAndNewlines) }
        func add(_ id: String?, _ n: String, _ l: OmniEntity.Level, _ st: String, _ p: String) {
            guard let id, !id.isEmpty, !n.isEmpty, st.uppercased() != "DELETED", seen.insert(id).inserted else { return }
            out.append(OmniEntity(id: id, name: n, level: l, status: st, path: p))
        }
        func children(_ v: Any?) -> [JSONObject] {
            if let m = v as? JSONObject { return m.keys.sorted().compactMap { m[$0] as? JSONObject } }
            return (v as? [Any])?.compactMap { $0 as? JSONObject } ?? []
        }
        for cKey in tree.keys.sorted() {
            guard let c = tree[cKey] as? JSONObject else { continue }
            let cName = name(c)
            add(JSONRead.string(c, "id") ?? cKey, cName, .campaign, status(c), "")
            for s in children(c["adsets"]) {
                let sName = name(s)
                add(JSONRead.string(s, "id"), sName, .adSet, status(s), cName)
                let adPath = [cName, sName].filter { !$0.isEmpty }.joined(separator: " / ")
                for ad in children(s["ads"]) { add(JSONRead.string(ad, "id"), name(ad), .ad, status(ad), adPath) }
            }
        }
        return out
    }

    /// The name starting with the fragment first, then a word in it starting with it, then the name containing it
    /// anywhere; within each, delivering before not, campaigns before ad sets before ads, the shorter name first.
    static func matches(_ typed: String, in items: [OmniEntity], limit: Int = maxRows) -> [OmniEntity] {
        let q = fold(typed.trimmingCharacters(in: .whitespacesAndNewlines))
        guard q.count >= minQuery, limit > 0 else { return [] }
        var scored: [(e: OmniEntity, w: Int)] = []
        for e in items {
            guard let r = e.key.range(of: q) else { continue }
            var w = 1
            if r.lowerBound == e.key.startIndex { w = 3 }
            else if wordStart(e.key, at: r.lowerBound) { w = 2 }
            else if let more = laterWordStart(e.key, q, after: r.lowerBound) { w = more ? 2 : 1 }
            scored.append((e, w))
        }
        func rank(_ l: OmniEntity.Level) -> Int { l == .campaign ? 0 : (l == .adSet ? 1 : 2) }
        scored.sort { a, b in
            if a.w != b.w { return a.w > b.w }
            if a.e.isActive != b.e.isActive { return a.e.isActive }
            if a.e.level != b.e.level { return rank(a.e.level) < rank(b.e.level) }
            if a.e.name.count != b.e.name.count { return a.e.name.count < b.e.name.count }
            return a.e.id < b.e.id
        }
        return scored.prefix(limit).map(\.e)
    }

    private static func wordStart(_ s: String, at i: String.Index) -> Bool {
        guard i > s.startIndex else { return true }
        let prev = s[s.index(before: i)]
        return !(prev.isLetter || prev.isNumber)
    }

    /// The first occurrence was mid-word: does a later one start a word? nil when there is no later one.
    private static func laterWordStart(_ s: String, _ q: String, after i: String.Index) -> Bool? {
        var from = s.index(after: i)
        var any = false
        while from < s.endIndex, let r = s.range(of: q, range: from..<s.endIndex) {
            any = true
            if wordStart(s, at: r.lowerBound) { return true }
            from = s.index(after: r.lowerBound)
        }
        return any ? false : nil
    }

    /// The entity selected in Ads Manager on the workspace's account (the same address 's ID rows use, at
    /// the entity's own level).
    static func adsManagerURL(_ e: OmniEntity, account: String?) -> URL? {
        let page: String, param: String
        switch e.level {
        case .campaign: page = "campaigns"; param = "selected_campaign_ids"
        case .adSet: page = "adsets"; param = "selected_adset_ids"
        case .ad: page = "ads"; param = "selected_ad_ids"
        }
        var c = URLComponents(string: "https://adsmanager.facebook.com/adsmanager/manage/" + page)
        var items: [URLQueryItem] = []
        if let a = account?.trimmingCharacters(in: .whitespaces), !a.isEmpty {
            items.append(URLQueryItem(name: "act", value: a.hasPrefix("act_") ? String(a.dropFirst(4)) : a))
        }
        items.append(URLQueryItem(name: param, value: e.id))
        c?.queryItems = items
        return c?.url
    }

    /// "Ad set · Paused · Spring sale": level, status, where it sits.
    static func detail(_ e: OmniEntity) -> String {
        [e.levelLabel, e.statusLabel, e.path].filter { !$0.isEmpty }.joined(separator: " \u{00B7} ")
    }

    static func askMet(_ e: OmniEntity) -> String {
        "Find the \(e.levelLabel.lowercased()) \u{201C}\(e.name)\u{201D} (ID \(e.id)) in this ad account and tell me how it's doing."
    }
}

/// One ad account's names in memory: when they were read, when a read was last tried.
struct OmniEntityBook: Sendable {
    static let refresh: Double = 600
    static let retry: Double = 60

    var items: [OmniEntity] = []
    var loadedAt: Double?
    var triedAt: Double?

    /// A read is due when nothing was read or the last read is ten minutes old, and no read started in the last
    /// minute (one in flight, or one that failed: a failing account is not asked again per keystroke or focus).
    func due(now: Double) -> Bool {
        if let l = loadedAt, now - l < Self.refresh { return false }
        if let t = triedAt, now - t < Self.retry { return false }
        return true
    }
}
