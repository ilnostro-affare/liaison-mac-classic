import Foundation

/// The decisions behind a Relay feed row, ported from ai.js bodyJournal so they can be tested apart from
/// the view: whose side a row sits on, its avatar, its stamp, its diff and where its comment thread hangs.
enum RelayLook {
    /// ai.js: identity is the actor, not the source. A row is mine when it is our own write journal
    /// (source 'lia'), or its actor_id is a person project_people marks is_you, or its actor's name is.
    static func isMine(_ e: RelayEvent, people: AccountPeople?) -> Bool {
        if e.fromJournal { return true }
        let me = (people?.active ?? []).filter(\.isYou)
        if let a = e.actorId, !a.isEmpty, me.contains(where: { $0.actorId == a }) { return true }
        return me.contains { $0.name == e.actor }
    }

    /// ai.js jcAv: a comment is mine when its member id is the signed-in member's.
    static func isMine(_ c: RelayComment, memberId: String?) -> Bool {
        guard let m = c.memberId, let me = memberId, !m.isEmpty else { return false }
        return m == me
    }

    /// ai.js ini: the first letters of two words; a one-word name still gets two letters.
    static func initials(_ name: String) -> String {
        let t = name.trimmingCharacters(in: .whitespaces)
        let words = (t.isEmpty ? "?" : t).split(whereSeparator: { $0.isWhitespace })
        let firsts = String(words.compactMap(\.first).prefix(2))
        return (firsts.count > 1 ? firsts : String((words.first.map(String.init) ?? "?").prefix(2))).uppercased()
    }

    /// ai.js JAV_SELF: you see yourself in the lighter blue, everywhere.
    static let selfColor: UInt32 = 0x5a9bd6
    /// ai.js JAV_POOL.
    static let pool: [UInt32] = [0x8a5cd6, 0x2f8f6f, 0xb5603a, 0x4a7ec7, 0xa05aa0, 0xc7863d, 0x3d6fd6]

    /// ai.js jAvColor: inside a project people take distinct palette slots in the people list's order (you
    /// pinned to JAV_SELF); anyone not in the list falls back to a name hash over the pool.
    static func avatarColor(_ name: String, people: AccountPeople?) -> UInt32 {
        let nm = name.trimmingCharacters(in: .whitespaces).lowercased()
        if nm.isEmpty { return pool[0] }
        if let pp = people {
            var map: [String: UInt32] = [:]
            var slot = 0
            for p in pp.active + pp.access {
                let k = p.name.trimmingCharacters(in: .whitespaces).lowercased()
                if k.isEmpty || map[k] != nil { continue }
                if p.isYou { map[k] = selfColor } else { map[k] = pool[slot % pool.count]; slot += 1 }
            }
            if let c = map[nm] { return c }
        }
        var h: UInt32 = 0
        for u in nm.utf16 { h = h &* 31 &+ UInt32(u) }
        return pool[Int(h % UInt32(pool.count))]
    }

    /// The mark in a bubble's stamp (ai.js `stamp`): the Liaison "a", Meta's logo for Ads Manager, a plug
    /// for any other tool (titled with its real name), or nothing.
    enum Stamp: Equatable { case liaison, adsManager, other(String), none }

    static func stamp(_ e: RelayEvent) -> Stamp {
        guard let v = e.via, !v.isEmpty else { return .none }
        if v == "Liaison" { return .liaison }
        if v == "Ads Manager" { return .adsManager }
        return .other(e.viaReal ?? "external tool")
    }

    /// ai.js jDayLabel: TODAY, YESTERDAY, else "9 OCT".
    static func dayLabel(_ ms: Double, now: Date = Date(), calendar: Calendar = .current) -> String {
        let d = Date(timeIntervalSince1970: ms / 1000)
        if calendar.isDate(d, inSameDayAs: now) { return "TODAY" }
        if let y = calendar.date(byAdding: .day, value: -1, to: now), calendar.isDate(d, inSameDayAs: y) { return "YESTERDAY" }
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_GB")
        f.calendar = calendar
        f.timeZone = calendar.timeZone
        f.dateFormat = "d MMM"
        return f.string(from: d).uppercased()
    }

    /// ai.js tone: stopped is red, running is green, everything else neutral. "inactive" is checked first.
    enum Tone: Equatable { case off, on, neutral }

    static func tone(_ v: String?) -> Tone {
        let s = (v ?? "").lowercased()
        let off = ["inactive", "paused", "deleted", "disapproved", "payment", "blocked", "rejected"]
        if off.contains(where: { s.contains($0) }) { return .off }
        if ["active", "approved", "running", "live"].contains(where: { s.contains($0) }) { return .on }
        return .neutral
    }

    /// ai.js jSysDiff: from struck through and an arrow to the new value; a long JSON payload (an audience
    /// rule) is not printed - the line says "rules updated" and the entity name stays out of it.
    struct Diff: Equatable {
        var from: String?
        var to: String?
        var said: String?
        var hidesEntity = false
    }

    static func diff(_ e: RelayEvent) -> Diff? {
        let f = e.from ?? "", t = e.to ?? ""
        let first = (f.isEmpty ? t : f).trimmingCharacters(in: .whitespacesAndNewlines)
        if f.count + t.count > 160, first.hasPrefix("{") || first.hasPrefix("[") {
            return Diff(said: "rules updated", hidesEntity: true)
        }
        if !f.isEmpty, !t.isEmpty { return Diff(from: f, to: t) }
        if !t.isEmpty { return Diff(to: t) }
        return nil
    }

    /// ai.js row menu "Copy text": `actor action entity (from → to)`.
    static func copyText(_ e: RelayEvent) -> String {
        var s = "\(e.actor.isEmpty ? "You" : e.actor) \(e.action) \(e.entity)"
        if let f = e.from, let t = e.to, !f.isEmpty, !t.isEmpty { s += " (\(f) \u{2192} \(t))" }
        return s.trimmingCharacters(in: .whitespaces)
    }

    /// ai.js: one journal entry can paint several rows that share its eid; its single thread renders
    /// under the LAST of them. Returns the event ids (in the given order) that carry a thread.
    static func threadAnchors(_ ordered: [RelayEvent]) -> Set<String> {
        var last: [String: String] = [:]
        for e in ordered { if let eid = e.eid { last[eid] = e.id } }
        var out = Set(last.values)
        for e in ordered where e.eid == nil { out.insert(e.id) }
        return out
    }

    /// ai.js summary: up to three avatars of distinct authors for a collapsed thread.
    static func stackNames(_ comments: [RelayComment]) -> [String] {
        var seen = Set<String>(), out: [String] = []
        for c in comments where seen.insert(c.name).inserted { out.append(c.name) }
        return Array(out.prefix(3))
    }
}
