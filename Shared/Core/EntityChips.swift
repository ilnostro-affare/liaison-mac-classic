import Foundation

/// Where a chip in Lia's answer points (ai.js entChipHtml `data-entid`, the namesake chip's `data-entname`).
/// It travels as a link in the answer's text and the markdown view opens the popup for it instead of a page.
enum EntityLink: Equatable {
    /// An entity known by id: «name» (id N), "id N" or a bare id in the map.
    case entity(String)
    /// A quote whose words name one or more objects in the account (lowercased, trimmed).
    case namesake(String)

    static let scheme = "lia-ent"

    var url: URL? {
        var c = URLComponents()
        c.scheme = Self.scheme
        switch self {
        case .entity(let id): c.host = "id"; c.path = "/" + id
        case .namesake(let key): c.host = "name"; c.path = "/" + key
        }
        return c.url
    }

    init?(url: URL) {
        guard url.scheme == Self.scheme,
              let c = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        let value = String(c.path.dropFirst())
        guard !value.isEmpty else { return nil }
        switch c.host {
        case "id": self = .entity(value)
        case "name": self = .namesake(value)
        default: return nil
        }
    }
}

/// What the entity popups show and do (ai.js entPopup / entPopupMany, / / /). Read-only:
/// nothing here reaches Meta; "Use" only puts words into the composer.
enum EntityChips {
    struct Item: Equatable {
        let id: String
        let name: String
        let kind: String?
    }

    /// entPopup: the campaign above (the map carries one parent level), the entity, up to six children under it.
    struct Tree: Equatable {
        let parent: String?
        let name: String
        let kind: String?
        let kids: [Item]
    }

    /// entPopupMany: the entities sharing the quoted name, grouped by their campaign ("—" when none).
    struct Group: Equatable {
        let title: String
        let items: [Item]
    }

    static func key(_ name: String) -> String {
        name.lowercased().trimmingCharacters(in: .whitespaces)
    }

    /// ai.js kindNice.
    static func kindNice(_ k: String?) -> String {
        let raw = k ?? ""
        switch raw.lowercased() {
        case "campaign": return "Campaign"
        case "adset", "ad_set", "ad set": return "Ad set"
        case "ad": return "Ad"
        case "creative": return "Creative"
        default:
            guard !raw.isEmpty else { return "" }
            let spaced = raw.replacingOccurrences(of: #"[_\s]+"#, with: " ", options: .regularExpression)
            return spaced.prefix(1).uppercased() + spaced.dropFirst()
        }
    }

    /// The words "Use" puts into the composer: kind, the name in guillemets and the id, so the model gets a number
    /// rather than a name (ai.js /).
    static func useText(id: String, entity: ChatEntity?) -> String {
        let kw: String
        switch (entity?.kind ?? "").lowercased() {
        case "campaign": kw = "campaign"
        case "adset", "ad set": kw = "ad set"
        case "ad": kw = "ad"
        case "creative": kw = "creative"
        default: kw = ""
        }
        let name = (entity?.name).flatMap { $0.isEmpty ? nil : $0 } ?? id
        return (kw.isEmpty ? "" : kw + " ") + "\u{00AB}" + name + "\u{00BB} (id " + id + ")"
    }

    /// window.LiaPutText: appends, never replaces; what was typed survives, a space follows for the next word.
    static func putText(_ current: String, _ add: String) -> String {
        guard !current.isEmpty else { return add + " " }
        var trimmed = current
        while let last = trimmed.last, last.isWhitespace { trimmed.removeLast() }
        return trimmed + " " + add + " "
    }

    static func tree(id: String, ents: [String: ChatEntity]) -> Tree {
        let e = ents[id]
        let name = e?.name ?? ""
        var kids: [Item] = []
        if !name.isEmpty {
            kids = ents.filter { $0.value.parent == name }
                .sorted { $0.key < $1.key }
                .prefix(6)
                .map { Item(id: $0.key, name: $0.value.name, kind: $0.value.kind) }
        }
        let parent = (e?.parent).flatMap { $0.isEmpty ? nil : $0 }
        return Tree(parent: parent, name: name.isEmpty ? "unknown entity" : name, kind: e?.kind, kids: kids)
    }

    /// The namesakes of a quoted name, at most twelve, grouped by campaign in first-seen order.
    static func namesakes(_ nameKey: String, ents: [String: ChatEntity]) -> [Group] {
        let want = key(nameKey)
        let hits = ents.filter { key($0.value.name) == want }.sorted { $0.key < $1.key }.prefix(12)
        var order: [String] = []
        var groups: [String: [Item]] = [:]
        for (id, e) in hits {
            let g = (e.parent ?? "").trimmingCharacters(in: .whitespaces)
            let title = g.isEmpty ? "\u{2014}" : g
            if groups[title] == nil { order.append(title) }
            groups[title, default: []].append(Item(id: id, name: e.name, kind: e.kind))
        }
        return order.map { Group(title: $0, items: groups[$0] ?? []) }
    }
}
