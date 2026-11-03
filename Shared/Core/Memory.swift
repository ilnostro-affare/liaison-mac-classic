import Foundation

// Lia's memory (-i): the "Saved to memory" line in a turn (ai.js memLineHTML 3145) and
// Settings > Memory (settings.js renderMemory 215). In a chat memory is only shown; Settings edits it.

enum MemorySection {
    /// ai.js MEM_SEC / settings.js MEM_LBL.
    static let labels: [String: String] = [
        "business": "Business", "customers": "Customers", "offer": "Offer", "goals": "Goals",
        "rules": "Rules", "history": "History", "experience": "Experience", "preferences": "Preferences",
    ]
    static let you = ["experience", "preferences"]
    static let account = ["business", "customers", "offer", "goals", "rules", "history"]
    static func label(_ s: String?) -> String { labels[s ?? ""] ?? "Memory" }
}

/// One fact as a `memory_saved` block carries it: {kind, text, scope, section, account, account_name, replaced}.
struct MemorySaved: Equatable {
    let text: String
    let scope: String
    let section: String?
    let account: String?
    let accountName: String?
    let replaced: Bool

    init?(_ block: ChatBlock) {
        guard block.kind == "memory_saved", let d = block.raw, let t = JSONRead.string(d, "text"), !t.isEmpty else { return nil }
        text = t
        scope = JSONRead.string(d, "scope") ?? "account"
        section = JSONRead.string(d, "section")
        account = JSONRead.string(d, "account")
        accountName = JSONRead.string(d, "account_name")
        replaced = !(JSONRead.string(d, "replaced") ?? "").isEmpty
    }

    /// "You · Experience", "Acme · Goals", "Ad account 123 · Offer", + " · updated".
    var whereLine: String {
        let who: String
        if scope == "you" { who = "You" }
        else if let n = accountName, !n.isEmpty { who = n }
        else { who = "Ad account " + (account ?? "") }
        return who + " \u{00b7} " + MemorySection.label(section) + (replaced ? " \u{00b7} updated" : "")
    }

    /// The facts of one turn, in the order they were saved. The site keeps the first 12 in the node's data.
    static func items(_ blocks: [ChatBlock]) -> [MemorySaved] { blocks.compactMap(MemorySaved.init) }

    /// "Saved to memory" with the count only when more than one fact was saved.
    static func count(_ n: Int) -> String? { n > 1 ? String(n) : nil }
}

/// Settings > Memory: GET /intelligence/memory.
struct MemoryItem: Equatable, Identifiable {
    let id: String
    var section: String
    var text: String
    var by: String
    let created: Double
    var updated: Double

    init?(_ o: JSONObject) {
        guard let id = JSONRead.string(o, "id"), let text = JSONRead.string(o, "text") else { return nil }
        self.id = id; self.text = text
        section = JSONRead.string(o, "section") ?? ""
        by = JSONRead.string(o, "by") ?? "lia"
        created = JSONRead.double(o, "created") ?? 0
        updated = JSONRead.double(o, "updated") ?? created
    }

    /// "Edited by you · Oct 9" / "Saved by Lia from a chat · Oct 9".
    var subLine: String {
        let who = by == "you" ? "Edited by you" : "Saved by Lia from a chat"
        let t = updated > 0 ? updated : created
        return t > 0 ? who + " \u{00b7} " + MemoryBook.short(t) : who
    }
}

struct MemoryScope: Equatable, Identifiable {
    /// nil for You, the account's digits otherwise.
    let account: String?
    var accountName: String?
    var updated: Double?
    var items: [MemoryItem]

    var id: String { account ?? "you" }
    var isYou: Bool { account == nil }
    var scope: String { isYou ? "you" : "account" }
    var sections: [String] { isYou ? MemorySection.you : MemorySection.account }

    func name(fallback: String? = nil) -> String {
        if isYou { return "About you" }
        if let n = accountName, !n.isEmpty { return n }
        if let f = fallback, !f.isEmpty { return f }
        return "Ad account " + (account ?? "")
    }

    /// The row's grey line: every fact joined, or "Nothing saved yet".
    var summary: String { items.isEmpty ? "Nothing saved yet" : items.map(\.text).joined(separator: " \u{00b7} ") }

    func items(in section: String) -> [MemoryItem] { items.filter { $0.section == section } }

    /// settings.js memPaintOne "Used".
    func usedLine(name: String) -> String {
        isYou ? "Read in every chat, before the ad account"
              : "Read in every chat that works in \(name) \u{00b7} account \(account ?? "")"
    }
}

struct MemoryBook: Equatable {
    var available: Bool
    var enabled: Bool
    var you: MemoryScope
    var accounts: [MemoryScope]

    static func parse(_ data: Data) -> MemoryBook? {
        guard let o = JSONRead.object(data), o["ok"] as? Bool != false else { return nil }
        let y = o["you"] as? JSONObject
        return MemoryBook(
            available: o["available"] == nil || JSONRead.bool(o, "available"),
            enabled: o["enabled"] == nil || JSONRead.bool(o, "enabled"),
            you: MemoryScope(account: nil, accountName: nil, updated: JSONRead.double(y, "updated"),
                             items: JSONRead.objects(y, "items").compactMap(MemoryItem.init)),
            accounts: JSONRead.objects(o, "accounts").compactMap { a in
                guard let id = JSONRead.string(a, "account") else { return nil }
                return MemoryScope(account: id, accountName: JSONRead.string(a, "account_name"),
                                   updated: JSONRead.double(a, "updated"),
                                   items: JSONRead.objects(a, "items").compactMap(MemoryItem.init))
            })
    }

    /// Accounts with memory first (server order: most recently updated), then every other connected one, empty.
    func rows(connected: [(id: String, name: String)]) -> [MemoryScope] {
        var out = accounts.filter { !$0.items.isEmpty }
        let have = Set(out.map(\.id))
        for a in accounts where a.items.isEmpty && !have.contains(a.id) { out.append(a) }
        let seen = Set(out.map(\.id))
        for c in connected where !seen.contains(c.id) {
            out.append(MemoryScope(account: c.id, accountName: c.name, updated: nil, items: []))
        }
        return out
    }

    mutating func update(_ scope: MemoryScope) {
        if scope.isYou { you = scope; return }
        if let i = accounts.firstIndex(where: { $0.id == scope.id }) { accounts[i] = scope } else { accounts.insert(scope, at: 0) }
    }

    func scope(_ id: String) -> MemoryScope? { id == "you" ? you : accounts.first { $0.id == id } }

    private static func fmt(_ f: String, _ ms: Double) -> String {
        let d = DateFormatter()
        d.locale = Locale(identifier: "en_US")
        d.dateFormat = f
        return d.string(from: Date(timeIntervalSince1970: ms / 1000))
    }
    /// "Oct 9" (toLocaleDateString en-US {month:'short', day:'numeric'}); times are milliseconds.
    static func short(_ ms: Double) -> String { fmt("MMM d", ms) }
    /// "Oct 9, 2026".
    static func long(_ ms: Double) -> String { fmt("MMM d, yyyy", ms) }

    static let maxLength = 280
}
