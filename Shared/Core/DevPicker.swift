import Foundation

// Select element on Dev's own sites (server, liaison backend/workers/lia-dev-edits.js): the person points at one
// element of a page Dev built - the private Preview (pv-<token>.liaisone.app) or one of the workspace's live sites
// (<slug>.liaisone.app; .liaisone.com while server moves them) - and asks for a change to it: a comment, a new text, or a move. The pure parts live here
// (Linux tests): which pages are Dev's, the element's locator (a CSS selector built from what the page reports), caps,
// the drag read as a reorder or a shift, the request body, the tasks as the server lists them, the card's placement.
// The page is read by a script in BrowserModel.agentWorld only (App/Workspace/DevPickerScript.swift).

/// Which pages are Dev's: its private preview, or a live site on the sites domain (never Liaison's own hosts).
enum DevPickerHost {
    /// Server: sites and previews live on liaisone.app; liaisone.com is the
    /// old domain, still served (then 301ed) by lia-sites during the move, so a page open there is still Dev's.
    /// The first is the one addresses are shown on (the server builds them; nothing here rewrites one).
    static let domains = ["liaisone.app", "liaisone.com"]
    /// The sites domain (lia-sites' SITES_DOMAIN).
    static var primary: String { domains[0] }
    /// lia-sites' RESERVED: names that are Liaison's own hosts, never a site.
    static let reserved: Set<String> = ["www", "app", "api", "ai", "mcp", "map", "tiles", "lia", "lia-app", "admin", "browser", "updates", "route",
                                        "reply", "auth", "mail", "send", "notify", "support", "help", "status", "blog", "docs", "liamaps",
                                        "mcp-apps", "memberstack-client", "_domainconnect", "site", "sites", "dev", "preview"]

    enum Kind: Equatable {
        case preview
        case site(String)
    }

    static func kind(_ url: URL?) -> Kind? {
        guard let u = url, u.scheme?.lowercased() == "https" else { return nil }
        return kind(host: u.host)
    }

    /// The same, from a host alone (OurHost asks it: a Dev page is never one of Liaison's own hosts).
    static func kind(host: String?) -> Kind? {
        guard let host = host?.lowercased(), !host.isEmpty else { return nil }
        for d in domains where host.hasSuffix("." + d) {
            let sub = String(host.dropLast(d.count + 1))
            if sub.hasPrefix("pv-") {
                let rest = sub.dropFirst(3)
                return rest.count >= 4 && rest.count <= 80 && rest.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") }) ? .preview : nil
            }
            guard !sub.isEmpty, sub.count <= 63, !sub.contains("."), !reserved.contains(sub),
                  let f = sub.first, f.isASCII, f.isLetter || f.isNumber,
                  sub.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") }) else { return nil }
            return .site(sub)
        }
        return nil
    }

    static func isDevSite(_ url: URL?) -> Bool { kind(url) != nil }

    /// Where Select element is offered ("on the preview, and its own right-click menu there - and not
    /// on other sites"): Dev's private preview, and a live site only when it is one of THIS workspace's sites
    /// (`sites`, the slugs GET /agents/dev/sites listed; nil: not read yet, so not offered). Another workspace's or
    /// another person's site on our domain gets nothing - the server would refuse it anyway (403).
    static func allowed(_ url: URL?, sites: [String]?) -> Bool {
        switch kind(url) {
        case .preview?: return true
        case .site(let s)?: return sites?.contains(s) ?? false
        case nil: return false
        }
    }
}

/// What a right-click on one of Dev's pages starts: the card at the element under the pointer, ready for a comment,
/// for its text, or for a drag.
enum DevPickIntent: String, Equatable, CaseIterable {
    case comment, text, move
}

/// The right-click menu's own items on Dev's pages (only there; never on another site). Over the page they come first,
/// above WebKit's; while selecting, the page gets no right-click and these are the whole menu.
enum DevPickMenu {
    static let selectTitle = "Select Element"
    static let stopTitle = "Stop Selecting"

    static func title(_ i: DevPickIntent) -> String {
        switch i {
        case .comment: return "Comment on This Element\u{2026}"
        case .text: return "Edit This Text\u{2026}"
        case .move: return "Move This Element\u{2026}"
        }
    }

    enum Item: Equatable {
        case intent(DevPickIntent)
        case toggle(String)
        case separator
    }

    /// In order: the three intents, a separator, then Select Element (Stop Selecting while it is on).
    static func items(selecting: Bool) -> [Item] {
        DevPickIntent.allCases.map { Item.intent($0) } + [.separator, .toggle(selecting ? stopTitle : selectTitle)]
    }

    /// A point in a view's own coordinates, top-left origin (WKWebView is flipped; a plain NSView is not).
    static func topLeft(_ p: CGPoint, height: CGFloat, flipped: Bool) -> CGPoint { flipped ? p : CGPoint(x: p.x, y: height - p.y) }
}

/// One element on the way from the picked one up to <body>, as the page script reports it.
struct DevPickNode: Equatable {
    let tag: String
    var id: String = ""
    /// The id is the only one of its kind on the page.
    var idUnique = false
    var classes: [String] = []
    /// 1-based position among its siblings of the same tag, and how many there are.
    var nth = 1
    var of = 1

    init(tag: String, id: String = "", idUnique: Bool = false, classes: [String] = [], nth: Int = 1, of: Int = 1) {
        self.tag = tag; self.id = id; self.idUnique = idUnique; self.classes = classes; self.nth = nth; self.of = of
    }

    init?(_ o: JSONObject) {
        guard let t = JSONRead.string(o, "tag")?.lowercased(), DevPickSelector.isTag(t) else { return nil }
        tag = t
        id = JSONRead.string(o, "id") ?? ""
        idUnique = JSONRead.bool(o, "idUnique")
        classes = JSONRead.strings(o, "classes")
        nth = max(1, JSONRead.int(o, "nth") ?? 1)
        of = max(nth, JSONRead.int(o, "of") ?? 1)
    }
}

/// The CSS selector of a picked element: a unique #id where there is one, else tag.class:nth-of-type(n) steps joined
/// with " > ". Only characters a selector of ours can hold (the server's editSelectorOk accepts exactly these).
enum DevPickSelector {
    static let maxSteps = 12
    static let maxLength = 600

    static func isTag(_ t: String) -> Bool {
        guard let f = t.first, f.isASCII, f.isLetter, t.count <= 30 else { return false }
        return t.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") }
    }
    /// An id or a class we can write without escaping: a letter or _ first, then letters, digits, - and _.
    static func isPlainName(_ s: String, max: Int = 64) -> Bool {
        guard let f = s.first, f.isASCII, f.isLetter || f == "_", s.count <= max else { return false }
        return s.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") }
    }
    /// A class that names the element rather than its state or a build hash: not "active", "is-open", "css-1x2y3z".
    static func stableClass(_ c: String) -> Bool {
        guard isPlainName(c, max: 40) else { return false }
        let l = c.lowercased()
        let state = ["active", "hover", "focus", "open", "opened", "show", "shown", "visible", "hidden", "selected", "current", "disabled",
                     "animated", "in-view", "inview", "loaded", "loading"]
        if state.contains(l) { return false }
        for p in ["is-", "has-", "js-", "css-", "sc-", "jsx-", "svelte-", "_", "ng-", "v-"] where l.hasPrefix(p) { return false }
        // a hash: three digits in a row, or a mix of 5+ letters and digits after a dash (".title-x7k2q9")
        var run = 0
        for ch in l { run = ch.isNumber ? run + 1 : 0; if run >= 3 { return false } }
        if let tail = l.split(separator: "-").last, tail.count >= 5, tail.contains(where: { $0.isNumber }), tail.contains(where: { $0.isLetter }) { return false }
        return true
    }
    static func segment(_ n: DevPickNode, classes: Bool) -> String {
        var s = n.tag
        if classes { for c in n.classes.filter(stableClass).prefix(2) { s += "." + c } }
        if n.of > 1 { s += ":nth-of-type(\(n.nth))" }
        return s
    }
    /// `chain` runs from the element up (the element first, <body> last). nil: nothing usable.
    static func build(_ chain: [DevPickNode], classes: Bool = true) -> String? {
        var steps: [String] = []
        for n in chain.prefix(maxSteps) {
            if n.idUnique, isPlainName(n.id) { steps.append("#" + n.id); break }
            if n.tag == "html" { break }
            steps.append(segment(n, classes: classes))
            if n.tag == "body" { break }
        }
        guard !steps.isEmpty else { return nil }
        let s = steps.reversed().joined(separator: " > ")
        return s.count <= maxLength ? s : nil
    }
}

/// Caps of what goes to the server (the same as lia-dev-edits EDIT_CAPS).
enum DevPickCaps {
    static let text = 300
    static let html = 2048
    static let comment = 2000
    static let newText = 2000
    static let label = 80
    /// Text-only elements longer than this are edited by a comment, not inline.
    static let inlineText = 600

    /// `s` cut to `bytes` UTF-8 bytes, never inside a character.
    static func cut(_ s: String, bytes: Int) -> String {
        guard s.utf8.count > bytes else { return s }
        var out = ""
        var n = 0
        for ch in s {
            let w = String(ch).utf8.count
            if n + w > bytes { break }
            out.append(ch); n += w
        }
        return out
    }
    static func squash(_ s: String, _ max: Int) -> String {
        let one = s.split(whereSeparator: { $0 == " " || $0 == "\n" || $0 == "\t" || $0 == "\r" }).joined(separator: " ")
        return String(one.prefix(max))
    }
}

/// A box in CSS px: of the page (scroll included) for the server, of the viewport for drawing.
struct DevPickBox: Equatable {
    var x: Double, y: Double, w: Double, h: Double
    init(x: Double, y: Double, w: Double, h: Double) { self.x = x; self.y = y; self.w = w; self.h = h }
    init?(_ o: JSONObject?) {
        guard let o, let x = JSONRead.double(o, "x"), let y = JSONRead.double(o, "y"), let w = JSONRead.double(o, "w"), let h = JSONRead.double(o, "h") else { return nil }
        self.init(x: x, y: y, w: w, h: h)
    }
    var rect: CGRect { CGRect(x: x, y: y, width: w, height: h) }
    var json: JSONObject { ["x": Int(x.rounded()), "y": Int(y.rounded()), "w": Int(w.rounded()), "h": Int(h.rounded())] }
}

/// What the overlay writes beside the outline: "h2 · Our lessons", "img", "a#book · Book now".
enum DevPickLabel {
    static func make(tag: String, id: String = "", classes: [String] = [], text: String = "") -> String {
        var head = tag
        if DevPickSelector.isPlainName(id) { head += "#" + id }
        else if let c = classes.first(where: DevPickSelector.stableClass) { head += "." + c }
        let t = DevPickCaps.squash(text, 400)
        guard !t.isEmpty else { return String(head.prefix(DevPickCaps.label)) }
        let short = t.count > 32 ? String(t.prefix(31)) + "\u{2026}" : t
        return String((head + " \u{00b7} " + short).prefix(DevPickCaps.label))
    }
}

/// The picked element, as it goes to the server.
struct DevPickLocator: Equatable {
    var selector: String
    var tag: String
    var id = ""
    var classes: [String] = []
    var text = ""
    var label = ""
    var html = ""
    /// In page coordinates (scroll included).
    var box: DevPickBox?
    var viewport: DevPickBox?
    /// It holds text only (no child elements): its text can be edited inline.
    var textOnly = false

    /// From the page script's "pick" answer and a selector checked to find exactly this element.
    static func make(_ o: JSONObject, selector: String) -> DevPickLocator? {
        guard let tag = JSONRead.string(o, "tag")?.lowercased(), DevPickSelector.isTag(tag), !selector.isEmpty,
              selector.count <= DevPickSelector.maxLength else { return nil }
        let id = JSONRead.string(o, "id") ?? ""
        let classes = JSONRead.strings(o, "classes").filter { DevPickSelector.isPlainName($0, max: 60) }
        let text = DevPickCaps.squash(JSONRead.string(o, "text") ?? "", DevPickCaps.text)
        var l = DevPickLocator(selector: selector, tag: tag)
        l.id = DevPickSelector.isPlainName(id) ? id : ""
        l.classes = Array(classes.prefix(8))
        l.text = text
        l.label = DevPickLabel.make(tag: tag, id: l.id, classes: l.classes, text: text)
        l.html = DevPickCaps.cut(JSONRead.string(o, "html") ?? "", bytes: DevPickCaps.html)
        l.box = DevPickBox(o["page"] as? JSONObject)
        l.viewport = DevPickBox(o["viewport"] as? JSONObject)
        let full = JSONRead.string(o, "fullText") ?? text
        l.textOnly = JSONRead.bool(o, "textOnly") && !full.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && full.count <= DevPickCaps.inlineText
        return l
    }

    var json: JSONObject {
        var o: JSONObject = ["selector": selector, "tag": tag, "classes": classes, "text": text, "label": label, "html": html]
        if !id.isEmpty { o["id"] = id }
        if let box { o["box"] = box.json }
        if let viewport { o["viewport"] = ["w": Int(viewport.w.rounded()), "h": Int(viewport.h.rounded())] }
        return o
    }
}

/// A drag of the picked element: dropped onto a sibling it is a reorder (before / after it), else a shift by Δx, Δy.
struct DevPickMove: Equatable {
    enum Where: String { case before, after }
    var dx: Int
    var dy: Int
    var place: Where? = nil
    var target: DevPickLocator? = nil

    var isEmpty: Bool { place == nil && dx == 0 && dy == 0 }

    /// The card's line: "Move after «section · Prices»", "Move 24 px right, 10 px down".
    var words: String {
        if let p = place, let t = target { return "Move \(p.rawValue) \u{00ab}\(t.label.isEmpty ? t.tag : t.label)\u{00bb}" }
        var parts: [String] = []
        if dx != 0 { parts.append("\(abs(dx)) px \(dx > 0 ? "right" : "left")") }
        if dy != 0 { parts.append("\(abs(dy)) px \(dy > 0 ? "down" : "up")") }
        return parts.isEmpty ? "No move" : "Move " + parts.joined(separator: ", ")
    }

    var json: JSONObject {
        var o: JSONObject = ["dx": dx, "dy": dy]
        if let p = place, let t = target {
            o["where"] = p.rawValue
            o["target"] = ["selector": t.selector, "tag": t.tag, "label": t.label, "text": t.text]
        }
        return o
    }
}

/// Where a drop lands among the element's siblings. Boxes in viewport CSS px; `own` is the dragged element's box and
/// index among its parent's element children; nil when the drop is on no sibling, or would leave the order as it is.
enum DevPickReorder {
    struct Sibling: Equatable { let index: Int; let box: DevPickBox }

    /// The siblings run left to right (a row) rather than top to bottom.
    static func horizontal(_ boxes: [DevPickBox]) -> Bool {
        guard boxes.count >= 2 else { return false }
        let xs = boxes.map { $0.x + $0.w / 2 }, ys = boxes.map { $0.y + $0.h / 2 }
        let spread = { (v: [Double]) in (v.max() ?? 0) - (v.min() ?? 0) }
        return spread(xs) > spread(ys)
    }

    static func decide(drop: CGPoint, own: Sibling, siblings: [Sibling]) -> (index: Int, place: DevPickMove.Where)? {
        let others = siblings.filter { $0.index != own.index }
        guard !others.isEmpty else { return nil }
        let row = horizontal(others.map(\.box) + [own.box])
        guard let hit = others.first(where: { $0.box.rect.insetBy(dx: -4, dy: -4).contains(drop) }) else { return nil }
        let mid = row ? hit.box.x + hit.box.w / 2 : hit.box.y + hit.box.h / 2
        let p = Double(row ? drop.x : drop.y)
        let place: DevPickMove.Where = p < mid ? .before : .after
        // dropping just before the next sibling or just after the previous one changes nothing
        if place == .before && hit.index == own.index + 1 { return nil }
        if place == .after && hit.index == own.index - 1 { return nil }
        return (hit.index, place)
    }
}

/// What the card sends: a comment, a new text, a move - one or more.
struct DevEditDraft: Equatable {
    var url: URL
    var locator: DevPickLocator
    var comment = ""
    /// The element's own text, and what the person typed instead (inline edit).
    var textFrom = ""
    var textTo: String? = nil
    var move: DevPickMove? = nil

    var textChanged: Bool { (textTo.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) } ?? "").isEmpty == false && textTo != textFrom }
    var canSend: Bool {
        !comment.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || textChanged || !(move?.isEmpty ?? true)
    }

    func body(profile: String) -> JSONObject {
        var o: JSONObject = ["profile": profile, "url": url.absoluteString, "locator": locator.json]
        let c = comment.trimmingCharacters(in: .whitespacesAndNewlines)
        if !c.isEmpty { o["comment"] = String(c.prefix(DevPickCaps.comment)) }
        if textChanged, let t = textTo { o["text"] = ["from": String(textFrom.prefix(DevPickCaps.newText)), "to": String(t.prefix(DevPickCaps.newText))] }
        if let m = move, !m.isEmpty { o["move"] = m.json }
        return o
    }
}

/// One task as the server lists it (GET /agents/dev/edits) or streams it first (`dev_edit`).
struct DevEditTask: Equatable, Identifiable {
    enum Status: String { case queued, running, done, failed }
    let id: String
    let site: String
    var status: Status
    var summary: String
    var label: String
    var url: URL?
    var at: Double
    var selector = ""
    var result = ""
    var error = ""
    var liveURL: URL?

    /// Run is offered for a task that waits (Dev was busy) or did not work.
    var canRun: Bool { status == .queued || status == .failed }
    var statusWords: String {
        switch status {
        case .queued: return "Waiting"
        case .running: return "Dev is on it"
        case .done: return "Done"
        case .failed: return "Didn\u{2019}t work"
        }
    }

    init?(_ o: JSONObject?) {
        guard let o, let id = JSONRead.string(o, "id"), !id.isEmpty, let site = JSONRead.string(o, "site"), !site.isEmpty else { return nil }
        self.id = id; self.site = site
        status = Status(rawValue: JSONRead.string(o, "status") ?? "") ?? .queued
        summary = JSONRead.string(o, "summary") ?? ""
        label = JSONRead.string(o, "label") ?? ""
        url = JSONRead.string(o, "url").flatMap(URL.init(string:)).flatMap { DevPickerHost.isDevSite($0) ? $0 : nil }
        at = JSONRead.double(o, "at") ?? 0
        selector = JSONRead.string(o, "selector") ?? ""
        result = JSONRead.string(o, "result") ?? ""
        error = JSONRead.string(o, "error") ?? ""
        liveURL = JSONRead.string(o, "live_url").flatMap(URL.init(string:)).flatMap { DevPickerHost.isDevSite($0) ? $0 : nil }
    }

    static func parseList(_ data: Data) -> [DevEditTask]? {
        guard let o = JSONRead.object(data), JSONRead.bool(o, "ok") else { return nil }
        return JSONRead.objects(o, "tasks").compactMap { DevEditTask($0) }
    }
}

/// POST /agents/dev/edit's answer when it is not a stream: queued (Dev busy), or refused.
struct DevEditReply: Equatable {
    let ok: Bool
    let queued: Bool
    let task: DevEditTask?
    let message: String

    static func parse(_ data: Data) -> DevEditReply {
        guard let o = JSONRead.object(data) else { return DevEditReply(ok: false, queued: false, task: nil, message: "Could not reach Dev.") }
        let ok = JSONRead.bool(o, "ok")
        let msg = JSONRead.string(o, "message") ?? JSONRead.string(o, "error") ?? (ok ? "" : "Dev could not take this.")
        return DevEditReply(ok: ok, queued: JSONRead.bool(o, "queued"), task: DevEditTask(o["task"] as? JSONObject), message: msg)
    }
}

/// The edit's stream: its own first line, Dev's turn after it.
enum DevEditStream {
    enum Line: Equatable {
        case task(DevEditTask)
        case dev(DevLine)
        case message(id: String, text: String)
        case done
        case error(String)
    }

    static func parse(_ line: String) -> Line? {
        guard line.hasPrefix("data:") else { return nil }
        let body = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
        guard let o = JSONRead.object(Data(body.utf8)), let type = JSONRead.string(o, "type") else { return nil }
        switch type {
        case "dev_edit": return DevEditTask(o["task"] as? JSONObject).map { .task($0) }
        case "done": return .done
        case "error": return .error(JSONRead.string(o, "message") ?? "Dev stopped.")
        case "msg":
            guard let m = o["message"] as? JSONObject, let id = JSONRead.string(m, "id"), let t = JSONRead.string(m, "text") else { return nil }
            return .message(id: id, text: t)
        default: return DevLine.parse(line: line).map { .dev($0) }
        }
    }
}

/// Where the card goes: under the element when it fits, else above it, else inside the view at the top; always
/// inside `bounds` with an 8 pt margin.
enum DevPickGeometry {
    static func cardOrigin(element r: CGRect, card: CGSize, in bounds: CGSize, gap: CGFloat = 8) -> CGPoint {
        let m: CGFloat = 8
        var x = r.minX
        x = min(x, bounds.width - card.width - m)
        x = max(m, x)
        let below = r.maxY + gap, above = r.minY - gap - card.height
        let y: CGFloat
        if below + card.height <= bounds.height - m { y = below }
        else if above >= m { y = above }
        else { y = max(m, min(bounds.height - card.height - m, r.minY + m)) }
        return CGPoint(x: x, y: y)
    }

    /// A point in the view (points) as CSS px of the page.
    static func css(_ p: CGPoint, zoom: CGFloat) -> CGPoint {
        let z = zoom > 0 ? zoom : 1
        return CGPoint(x: p.x / z, y: p.y / z)
    }
    /// A viewport box (CSS px) as a rect in the view.
    static func rect(_ b: DevPickBox, zoom: CGFloat) -> CGRect {
        let z = zoom > 0 ? zoom : 1
        return CGRect(x: b.x * Double(z), y: b.y * Double(z), width: b.w * Double(z), height: b.h * Double(z))
    }
}
