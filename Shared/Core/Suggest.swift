import Foundation

// POST /agents/suggest (lia-agents). The new tab's suggested tasks and the tab row's Tidy. The server clamps
// everything already; the client clamps again so a changed server can never put a long line or a stray tab id on
// screen. Decodable for the shape, read leniently (JSONRead) like every other answer from the runner.

/// A next task the team suggests, from the workspace's own recent messages.
struct SuggestedTask: Codable, Equatable {
    let text: String
    let agent: String
}

/// A group Tidy proposes: a short name, an SF Symbol from the server's allowlist, at least two tab ids, and
/// its category, drawn as the app's own icon (TabGroupCat); nil from an older server.
struct SuggestedGroup: Decodable, Equatable {
    let name: String
    let icon: String
    let tabIds: [String]
    var cat: String? = nil

    enum CodingKeys: String, CodingKey { case name, icon, tabIds = "tab_ids", cat }
}

enum Suggest {
    static let maxTasks = 3
    static let maxTaskChars = 60
    static let maxGroupName = 18
    static let maxRecent = 20
    static let maxRecentChars = 400
    static let maxTabs = 60

    /// The `recent` field: the last 20 messages (oldest first), each cut to 400 characters, empty ones dropped.
    static func recent(_ messages: [(agent: String?, text: String)]) -> [[String: Any]] {
        let kept = messages.compactMap { m -> (String?, String)? in
            let t = m.text.trimmingCharacters(in: .whitespacesAndNewlines)
            return t.isEmpty ? nil : (m.agent, String(t.prefix(maxRecentChars)))
        }
        return kept.suffix(maxRecent).map { a, t in
            var o: [String: Any] = ["text": t]
            if let a { o["agent"] = a }
            return o
        }
    }

    /// ("only when there is something new"): what the `recent` field would carry, as a stable
    /// FNV-1a hash (the same in every run, unlike Hasher). Home asks again only when this changed since the last
    /// answer; the server keeps its own cache on the same input (lia-agents agSuggestKey).
    static func fingerprint(_ messages: [(agent: String?, text: String)]) -> String {
        var h: UInt64 = 0xcbf29ce484222325
        func mix(_ s: String) {
            for b in s.utf8 { h ^= UInt64(b); h = h &* 0x100000001b3 }
            h ^= 0x1f; h = h &* 0x100000001b3   // a separator, so "ab"+"c" is not "a"+"bc"
        }
        for m in recent(messages) {
            mix(m["agent"] as? String ?? "")
            mix(m["text"] as? String ?? "")
        }
        return String(h, radix: 16)
    }

    /// ("quick tasks vanish"): what Home shows after an answer. The server often answers 0 or 1 task
    /// for the same workspace (gpt-6-luna, no error); an empty answer, or a failed call (nil), never wipes what is on
    /// screen - the last non-empty set stays until a non-empty answer replaces it.
    static func kept(shown: [SuggestedTask], answer: [SuggestedTask]?) -> [SuggestedTask] {
        guard let answer, !answer.isEmpty else { return shown }
        return answer
    }

    /// The last non-empty set, as kept on disk per workspace and member (JSON); nil for anything unreadable or empty.
    static func decodeKept(_ data: Data?) -> [SuggestedTask]? {
        guard let data, let l = try? JSONDecoder().decode([SuggestedTask].self, from: data), !l.isEmpty else { return nil }
        return Array(l.prefix(maxTasks))
    }

    /// Contains "<profile>|", so Reset this workspace clears it with the rest of `lia_ws_*`; the member keeps another
    /// person's suggestions from ever showing.
    static func keptKey(profile: String, member: String) -> String { "lia_ws_suggested_tasks_" + profile + "|" + member }

    /// {ok, tasks:[{text, agent}]}: at most 3, non-empty, 60 characters, no repeats.
    static func parseTasks(_ data: Data) -> [SuggestedTask] {
        guard let o = JSONRead.object(data), JSONRead.bool(o, "ok") else { return [] }
        var out: [SuggestedTask] = []
        for x in JSONRead.objects(o, "tasks") {
            let text = String((JSONRead.string(x, "text") ?? "").trimmingCharacters(in: .whitespacesAndNewlines).prefix(maxTaskChars))
            guard !text.isEmpty, !out.contains(where: { $0.text.lowercased() == text.lowercased() }) else { continue }
            let agent = JSONRead.string(x, "agent").flatMap { $0.isEmpty ? nil : $0.lowercased() } ?? "lia"
            out.append(SuggestedTask(text: text, agent: agent))
            if out.count == maxTasks { break }
        }
        return out
    }

    /// {ok, groups:[{name, icon, cat, tab_ids}]}: a name of at most 18 characters, an icon (else "folder"), a known
    /// category (else nil), at least two ids.
    static func parseGroups(_ data: Data) -> [SuggestedGroup] {
        guard let o = JSONRead.object(data), JSONRead.bool(o, "ok") else { return [] }
        return JSONRead.objects(o, "groups").compactMap { g in
            let name = String((JSONRead.string(g, "name") ?? "").trimmingCharacters(in: .whitespacesAndNewlines).prefix(maxGroupName))
            var ids: [String] = []
            for id in JSONRead.strings(g, "tab_ids") where !ids.contains(id) { ids.append(id) }
            guard !name.isEmpty, ids.count >= 2 else { return nil }
            let icon = JSONRead.string(g, "icon").flatMap { $0.isEmpty ? nil : $0 } ?? "folder"
            return SuggestedGroup(name: name, icon: icon, tabIds: ids, cat: TabGroupCat.normalize(JSONRead.string(g, "cat")))
        }
    }

    /// The groups that can still be applied: only tabs in `available` (ungrouped, not pinned, still open), each tab in
    /// one group, still at least two per group.
    static func applicable(_ groups: [SuggestedGroup], available: [String]) -> [SuggestedGroup] {
        let open = Set(available)
        var used = Set<String>()
        var out: [SuggestedGroup] = []
        for g in groups {
            let ids = g.tabIds.filter { open.contains($0) && !used.contains($0) }
            guard ids.count >= 2 else { continue }
            used.formUnion(ids)
            out.append(SuggestedGroup(name: g.name, icon: g.icon, tabIds: ids, cat: g.cat))
        }
        return out
    }
}
