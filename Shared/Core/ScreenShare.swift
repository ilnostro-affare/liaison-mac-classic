import Foundation

// Server (Lia said she cannot see the screen; "all agents must see what is on your screen right
// now, the way Met does when it drives the browser; only Lia and Met may control it"). With every turn the Mac sends
// a compact view of the workspace's main browser: the front tab's readable text, what the person selected on it, the
// other tabs by address and title only. A picture of the front tab only when an agent asks (look_at_screen): the
// turn stops on `screen_look`, the Mac takes a downsized JPEG, uploads it like an attachment and answers
// "[screen_result] {...}" to that agent. Private windows are never read (they are not a workspace browser). Pure, so it
// is tested on Linux; the reading itself is App/Workspace/ScreenShareMac.swift.

enum ScreenShare {
    /// The front tab's text the Mac sends (the server cuts at 8,000 too).
    static let frontText = 7000
    /// The controls listed with the front tab's text (their names, never a secret's value).
    static let frontControls = 40
    static let selectionCap = 2000
    static let maxTabs = 12
    /// The picture's longest side, in pixels, and its JPEG quality.
    static let shotMaxSide = 1280
    static let shotQuality = 0.6
    static let tag = "[screen_result]"

    struct Tab: Equatable {
        let id: String
        let title: String
        let url: String
        let active: Bool
        var text: String = ""
        var selection: String = ""
        /// A private window's tab: never sent, even when it is the one in front (0.2.11).
        var isPrivate: Bool = false
    }

    /// What one turn saw (the small line under the composer): the front tab's id (a tab's short id, or `peekID`) and
    /// address, so the line can bring that tab back in front.
    struct Seen: Equatable {
        let title: String
        let host: String
        var id: String = ""
        var url: String = ""
    }

    // MARK: the tab in front

    /// The Peek panel's page, when it is what the person is looking at (it is not a tab of the browser).
    static let peekID = "peek"

    /// (incident): every wrong "what is on my screen" answer came on a turn with no tab marked in
    /// front, and the model took the first listed one. The tab the person is looking at: Peek over the page wins;
    /// then the pane of a split / three-pane view that holds the keyboard focus in the window; then the browser's
    /// selected tab; then the first tab (what the stage shows when nothing is selected). nil only with no tabs.
    static func frontID(peek: Bool, focused: String?, panes: [String], selected: String?, tabs: [String]) -> String? {
        if peek { return peekID }
        if let f = focused, panes.contains(f) { return f }
        if let s = selected, tabs.contains(s) { return s }
        return tabs.first
    }

    /// The tabs as sent: private tabs out; the front tab FIRST and always kept (also with no address yet: a new tab
    /// page, a tab still restoring); then the others with an address, in their order, so at most `maxTabs` in all
    /// (the server reads 12). Only the first tab marked active is the front one.
    static func ordered(_ tabs: [Tab]) -> [Tab] {
        let visible = tabs.filter { !$0.isPrivate }
        let fi = visible.firstIndex { $0.active }
        let front = fi.map { visible[$0] }
        let others = visible.enumerated().filter { $0.offset != fi && !$0.element.url.isEmpty }.map { e in
            Tab(id: e.element.id, title: e.element.title, url: e.element.url, active: false)
        }
        let room = front == nil ? maxTabs : maxTabs - 1
        return (front.map { [$0] } ?? []) + Array(others.prefix(room))
    }

    // MARK: always on (0.2.11)

    /// 0.2.11: no switch. Agents look only when the person writes to them (the front tab goes with
    /// that message) or when one asks for a picture during that turn; nothing is watched between messages. Filled
    /// password and payment fields are never read or pictured, and private windows are never read. The old
    /// per-workspace key ("lia_screen_share_<profile>") is no longer read.
    static func isOn(profile: String) -> Bool { true }

    // MARK: the payload

    /// 0.2.11: the tabs the person stopped sharing with one conversation (the ✕ on "Lia sees this
    /// tab") left out - also the one in front, so nothing of it goes and no picture can be asked for.
    static func unshared(_ tabs: [Tab], hidden: Set<String>) -> [Tab] {
        hidden.isEmpty ? tabs : tabs.filter { !hidden.contains($0.id) }
    }

    /// The `browser` object of /agents/turn. `shared` false: no tabs at all, only that a browser is there (kept for
    /// the server's "hidden" shape; the Mac always shares since 0.2.11) (Lia and Met can still open a new tab for a task). `canLook`: the Mac can take a
    /// picture of the front tab now. Other tabs carry no text; the front tab's text and selection are cleaned and capped.
    static func payload(_ tabs: [Tab], shared: Bool, canLook: Bool) -> [String: Any] {
        guard shared else { return ["tabs": [Any](), "available": true, "hidden": true, "look": false] }
        let kept = ordered(tabs)
        var hasFront = false
        let list: [[String: Any]] = kept.map { t in
            var o: [String: Any] = ["id": t.id, "title": String(clean(t.title, cap: 160)), "url": String(t.url.prefix(400)), "active": t.active]
            if t.active {
                hasFront = true
                o["text"] = clean(t.text, cap: frontText)
                let sel = clean(t.selection, cap: selectionCap, oneLine: true)
                if !sel.isEmpty { o["selection"] = sel }
            } else {
                o["text"] = ""
            }
            return o
        }
        return ["tabs": list, "available": true, "look": canLook && hasFront]
    }

    /// The front tab the payload carries, for the indicator (nil: nothing of a page went with the turn).
    static func seen(_ payload: Any?) -> Seen? {
        guard let p = payload as? [String: Any], (p["hidden"] as? Bool) != true,
              let tabs = p["tabs"] as? [[String: Any]],
              let front = tabs.first(where: { ($0["active"] as? Bool) == true }) else { return nil }
        let url = front["url"] as? String ?? ""
        return Seen(title: front["title"] as? String ?? "", host: host(url), id: front["id"] as? String ?? "", url: url)
    }

    static func host(_ url: String) -> String {
        guard let h = URL(string: url)?.host else { return "" }
        return h.hasPrefix("www.") ? String(h.dropFirst(4)) : h
    }

    /// Control characters out (newlines and tabs kept, or folded to spaces with `oneLine`), runs of blank lines and
    /// spaces folded, anything that reads as a card number masked, cut at `cap` characters.
    static func clean(_ s: String, cap: Int, oneLine: Bool = false) -> String {
        var out = ""
        out.reserveCapacity(min(s.count, cap + 64))
        var spaces = 0, newlines = 0, n = 0
        for ch in s {
            if ch == "\n" || ch == "\r" || ch == "\r\n" {
                if oneLine { if spaces == 0 && n > 0 { out.append(" "); n += 1; spaces = 1 }; continue }
                newlines += 1; spaces = 0
                if newlines <= 2 && n > 0 { out.append("\n"); n += 1 }
                continue
            }
            if ch == " " || ch == "\t" || ch == "\u{00A0}" {
                if spaces == 0 && newlines == 0 && n > 0 { out.append(" "); n += 1 }
                spaces += 1
                continue
            }
            if ch.unicodeScalars.allSatisfy({ CharacterSet.controlCharacters.contains($0) || $0.properties.generalCategory == .format }) { continue }
            spaces = 0; newlines = 0
            out.append(ch)
            n += 1
            if n >= cap + 64 { break }
        }
        let masked = maskCards(out.trimmingCharacters(in: .whitespacesAndNewlines))
        return masked.count > cap ? String(masked.prefix(cap)) : masked
    }

    /// 13-19 digits (spaces or dashes between groups allowed) that pass the Luhn check read as a card number: masked.
    static func maskCards(_ s: String) -> String {
        guard s.contains(where: { $0.isNumber }) else { return s }
        let chars = Array(s)
        var out = ""
        var i = 0
        while i < chars.count {
            let c = chars[i]
            // a run starts at a digit not glued to a letter or another digit before it
            if c.isASCII, c.isNumber, i == 0 || !(chars[i - 1].isLetter || chars[i - 1].isNumber) {
                var j = i, digits: [Int] = [], lastDigit = i
                while j < chars.count {
                    let d = chars[j]
                    if d.isASCII, d.isNumber { digits.append(Int(String(d))!); lastDigit = j; j += 1; continue }
                    if (d == " " || d == "-"), j + 1 < chars.count, chars[j + 1].isASCII, chars[j + 1].isNumber, !digits.isEmpty { j += 1; continue }
                    break
                }
                let end = lastDigit + 1
                let glued = end < chars.count && (chars[end].isLetter || chars[end].isNumber)
                if (13...19).contains(digits.count), !glued, luhn(digits) {
                    out += "[card number hidden]"
                    i = end
                    continue
                }
                out += String(chars[i..<end])
                i = end
                continue
            }
            out.append(c)
            i += 1
        }
        return out
    }

    static func luhn(_ digits: [Int]) -> Bool {
        var sum = 0
        for (k, d) in digits.reversed().enumerated() {
            if k % 2 == 1 { let x = d * 2; sum += x > 9 ? x - 9 : x } else { sum += d }
        }
        return sum % 10 == 0
    }

    // MARK: the picture

    /// The picture's size in pixels: the longest side at most `shotMaxSide`, never upscaled, never 0.
    static func shotSize(width: Double, height: Double, maxSide: Int = shotMaxSide) -> (width: Int, height: Int) {
        guard width > 0, height > 0 else { return (1, 1) }
        let m = Double(maxSide)
        let scale = min(1, m / max(width, height))
        return (max(1, Int((width * scale).rounded())), max(1, Int((height * scale).rounded())))
    }

    /// The Mac's answer to `screen_look`: `[screen_result] {"ok", "look", "title", "url", "why"}`.
    static func result(ok: Bool, look: String, title: String = "", url: String = "", why: String? = nil) -> String {
        var o: [String: Any] = ["ok": ok, "look": String(look.prefix(80))]
        if ok {
            if !title.isEmpty { o["title"] = String(title.prefix(160)) }
            if !url.isEmpty { o["url"] = String(url.prefix(400)) }
        } else if let why, !why.isEmpty {
            o["why"] = String(why.prefix(200))
        }
        let data = (try? JSONSerialization.data(withJSONObject: o, options: [.sortedKeys])) ?? Data("{}".utf8)
        return tag + " " + (String(data: data, encoding: .utf8) ?? "{}")
    }
}

/// A `screen_look` line of /agents/turn: an agent asked for a picture of the front tab (server). The turn has
/// stopped; the Mac answers with ScreenShare.result to that agent.
struct ScreenLook: Equatable {
    let id: String
    let look: String
    let tab: String?
    let agent: String?

    static func parse(line: String) -> ScreenLook? {
        let o: JSONObject?
        if line.hasPrefix("data:") { o = TeamLine.object(line) } else { o = JSONRead.object(Data(line.utf8)) }
        guard let o, JSONRead.string(o, "type") == "screen_look" else { return nil }
        let id = JSONRead.string(o, "id") ?? ""
        let look = JSONRead.string(o, "look") ?? id
        guard !look.isEmpty || !id.isEmpty else { return nil }
        return ScreenLook(id: id, look: look, tab: JSONRead.string(o, "tab"), agent: JSONRead.string(o, "agent"))
    }
}
