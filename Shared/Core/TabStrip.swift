import Foundation

// The browser's tab strip, the pure part. Order (pinned tabs, then pinned groups, then the rest, every
// group's tabs side by side), a group's one-word name from its first tab's site, the page's theme-color, and the
// server's name for a group of two or more tabs (POST /agents/suggest, kind "tab_name").

enum TabStrip {
    /// One tab as the order sees it: its group (nil: none) and whether it is pinned.
    struct Slot: Equatable {
        let group: String?
        let pinned: Bool
        init(group: String?, pinned: Bool) { self.group = group; self.pinned = pinned }
    }

    /// The order the strip must have, as indices into `slots`: pinned tabs first (they sit in the workspace's cell),
    /// then the pinned groups, then everything else. Every group's tabs are contiguous, gathered where the group's first
    /// tab is; nothing else keeps a place between them. Relative order is kept wherever the rules allow.
    static func order(_ slots: [Slot], pinnedGroups: Set<String>) -> [Int] {
        var pinned: [Int] = []
        var pinnedRuns: [Int] = []
        var rest: [Int] = []
        var members: [String: [Int]] = [:]
        var firstSeen: [String] = []
        for (i, s) in slots.enumerated() where !s.pinned {
            guard let g = s.group else { continue }
            if members[g] == nil { firstSeen.append(g) }
            members[g, default: []].append(i)
        }
        var placed = Set<String>()
        for (i, s) in slots.enumerated() {
            if s.pinned { pinned.append(i); continue }
            guard let g = s.group else { rest.append(i); continue }
            if placed.contains(g) || pinnedGroups.contains(g) { continue }
            placed.insert(g)
            rest.append(contentsOf: members[g] ?? [])
        }
        for g in firstSeen where pinnedGroups.contains(g) { pinnedRuns.append(contentsOf: members[g] ?? []) }
        return pinned + pinnedRuns + rest
    }

    /// True when `slots` already is in the strip's order.
    static func isOrdered(_ slots: [Slot], pinnedGroups: Set<String>) -> Bool {
        order(slots, pinnedGroups: pinnedGroups) == Array(slots.indices)
    }

    /// Every group's tabs side by side (the invariant the strip draws one container per group on).
    static func groupsContiguous(_ groups: [String?]) -> Bool {
        var closed = Set<String>()
        var current: String?
        for g in groups {
            if g != current {
                if let c = current { closed.insert(c) }
                if let g, closed.contains(g) { return false }
                current = g
            }
        }
        return true
    }

    /// A tab dropped at `index` of `groups` (the order after the move, the tab itself at `index`): the group it joins.
    /// Between two tabs of one group: that group. Otherwise the group of the tab it was dropped on (`target`), which
    /// makes it the edge of that run, never a stranger inside it.
    static func groupAfterDrop(_ groups: [String?], index: Int, target: String?) -> String? {
        let before = index > 0 ? groups[index - 1] : nil
        let after = index + 1 < groups.count ? groups[index + 1] : nil
        if let b = before, b == after { return b }
        return target
    }
}

/// A group's one-word name from its tab's site: "github.com" -> "GitHub", "app.hubspot.com" -> "Hubspot" (or the
/// title's own spelling, "HubSpot"), "mail.google.com" -> "Gmail" when the title says so, else "Google".
enum SiteName {
    static let maxLength = 18

    /// Brands whose spelling is not a capital and lower case.
    private static let spelled: [String: String] = [
        "github": "GitHub", "gitlab": "GitLab", "youtube": "YouTube", "linkedin": "LinkedIn", "tiktok": "TikTok",
        "paypal": "PayPal", "chatgpt": "ChatGPT", "openai": "OpenAI", "whatsapp": "WhatsApp", "liaisone": "Liaison",
        "icloud": "iCloud", "wordpress": "WordPress", "stackoverflow": "StackOverflow", "doubleclick": "DoubleClick",
    ]
    /// Second-level labels that are a public suffix's part ("co.uk", "com.au"): the name is the label before them.
    private static let suffixParts: Set<String> = ["co", "com", "net", "org", "gov", "edu", "ac", "ne", "or", "go"]

    static func word(host: String?, title: String?) -> String {
        guard var h = host?.lowercased().trimmingCharacters(in: .whitespaces), !h.isEmpty else { return "Tab" }
        if h.hasSuffix(".") { h.removeLast() }
        if h.hasPrefix("www.") { h.removeFirst(4) }
        let t = (title ?? "").lowercased()
        if h == "localhost" || h.allSatisfy({ $0.isNumber || $0 == "." || $0 == ":" }) { return clamp(h == "localhost" ? "Localhost" : h) }
        let parts = h.split(separator: ".").map(String.init)
        // Google's own services: Gmail is Gmail, the rest is Google (Docs, Drive and Ads all say Google).
        if parts.count >= 2, parts[parts.count - 2] == "google" { return t.contains("gmail") ? "Gmail" : "Google" }
        var label = parts.first ?? h
        if parts.count >= 2 {
            label = parts[parts.count - 2]
            if parts.count >= 3, parts[parts.count - 1].count == 2, suffixParts.contains(label) { label = parts[parts.count - 3] }
        }
        if let s = spelled[label] { return clamp(s) }
        // The title's own spelling when it names the site ("HubSpot | Contacts").
        if let title, let w = titleWord(title, matching: label) { return clamp(w) }
        return clamp(label.prefix(1).uppercased() + label.dropFirst())
    }

    private static func titleWord(_ title: String, matching label: String) -> String? {
        let words = title.split(whereSeparator: { !($0.isLetter || $0.isNumber) })
        for w in words where w.lowercased() == label { return String(w) }
        return nil
    }

    private static func clamp(_ s: String) -> String { String(s.prefix(maxLength)) }
}

/// A page's `<meta name="theme-color">`: "#abc", "#aabbcc", "#aabbccdd", "rgb(1, 2, 3)", "rgba(1,2,3,.5)", a few names.
enum CSSColor {
    private static let names: [String: UInt32] = ["white": 0xFFFFFF, "black": 0x000000, "red": 0xFF0000, "blue": 0x0000FF,
                                                   "green": 0x008000, "orange": 0xFFA500, "purple": 0x800080]

    static func parse(_ raw: String?) -> UInt32? {
        guard let s = raw?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(), !s.isEmpty else { return nil }
        if let n = names[s] { return n }
        if s.hasPrefix("#") {
            let hex = String(s.dropFirst())
            guard hex.allSatisfy({ $0.isHexDigit }) else { return nil }
            switch hex.count {
            case 3, 4:
                let c = Array(hex.prefix(3))
                return UInt32(String([c[0], c[0], c[1], c[1], c[2], c[2]]), radix: 16)
            case 6, 8:
                return UInt32(String(hex.prefix(6)), radix: 16)
            default:
                return nil
            }
        }
        if s.hasPrefix("rgb"), let open = s.firstIndex(of: "("), let close = s.lastIndex(of: ")"), open < close {
            let inner = s[s.index(after: open)..<close]
            let parts = inner.split(whereSeparator: { $0 == "," || $0 == " " || $0 == "/" }).map(String.init)
            guard parts.count >= 3 else { return nil }
            var rgb: [UInt32] = []
            for p in parts.prefix(3) {
                let v: Double?
                if p.hasSuffix("%") { v = Double(p.dropLast()).map { $0 * 2.55 } } else { v = Double(p) }
                guard let v else { return nil }
                rgb.append(UInt32(max(0, min(255, v.rounded()))))
            }
            return (rgb[0] << 16) | (rgb[1] << 8) | rgb[2]
        }
        return nil
    }

    /// Relative luminance 0...1.
    static func luminance(_ c: UInt32) -> Double {
        let r = Double((c >> 16) & 0xFF) / 255, g = Double((c >> 8) & 0xFF) / 255, b = Double(c & 0xFF) / 255
        return 0.2126 * r + 0.7152 * g + 0.0722 * b
    }

    /// A colour worth tinting the toolbar with: not (nearly) white, black or grey.
    static func isTint(_ c: UInt32) -> Bool {
        let r = Int((c >> 16) & 0xFF), g = Int((c >> 8) & 0xFF), b = Int(c & 0xFF)
        let spread = max(r, g, b) - min(r, g, b)
        let l = luminance(c)
        return spread >= 28 && l > 0.06 && l < 0.94
    }
}

/// The server's name for a group of two or more tabs, and its category (the header draws the category's
/// icon from the app's own set, never an emoji; `emoji` is read only so an old reply still names the group).
struct SuggestedTabName: Equatable {
    let name: String
    var emoji: String? = nil
    var cat: String? = nil
}

extension Suggest {
    /// {ok, name, cat, emoji?}: a name of at most 18 characters (else nil), a known category (else nil), one emoji (else nil).
    static func parseTabName(_ data: Data) -> SuggestedTabName? {
        guard let o = JSONRead.object(data), JSONRead.bool(o, "ok") else { return nil }
        let name = String((JSONRead.string(o, "name") ?? "").trimmingCharacters(in: .whitespacesAndNewlines).prefix(maxGroupName))
        guard !name.isEmpty else { return nil }
        return SuggestedTabName(name: name, emoji: oneEmoji(JSONRead.string(o, "emoji")), cat: TabGroupCat.normalize(JSONRead.string(o, "cat")))
    }

    /// The first character when it is an emoji ("🔎", "👩‍💻", "🇮🇹"); nil for text, digits or nothing.
    static func oneEmoji(_ s: String?) -> String? {
        guard let c = s?.trimmingCharacters(in: .whitespacesAndNewlines).first else { return nil }
        let scalars = c.unicodeScalars
        guard let first = scalars.first else { return nil }
        let p = first.properties
        let variation = scalars.contains { $0.value == 0xFE0F }
        let emoji = p.isEmojiPresentation || (p.isEmoji && first.value > 0x238C) || (p.isEmoji && variation && first.value > 0x7F)
        return emoji ? String(c) : nil
    }
}

// MARK: - the strip never scrolls

/// The widths the strip gives its tabs and group headers, Dia / Chrome style: every tab shares the room equally, up to
/// `maxTab`; as more open each gets narrower (the title truncates, then hides, leaving the favicon); the selected tab
/// never goes under `minSelected`, the others under `minTab`. Headers shrink with the tabs, never below `minHeader`.
/// Only when even the minimums do not fit do the last items leave the strip (they are in the "All tabs" menu).
enum TabFit {
    struct Limits: Equatable {
        var maxTab: CGFloat = 220
        var minSelected: CGFloat = 56
        var minTab: CGFloat = 36
        var minHeader: CGFloat = 30
        /// Between any two neighbours (tabs, headers, groups).
        var spacing: CGFloat = 2
        /// A group's container: its horizontal padding on both sides together.
        var groupPad: CGFloat = 4
        init() {}
    }

    struct Item: Equatable {
        enum Kind: Equatable { case tab, header }
        var kind: Kind
        var selected = false
        /// The group run it belongs to (nil: a loose tab). A header and its tabs share it.
        var group: Int?
        /// A header's own width (icon and name); for a `fixed` item, the width it keeps.
        var natural: CGFloat = 0
        /// Pinned groups keep their compact size: never shrunk, never sent to the menu.
        var fixed = false

        static func tab(selected: Bool = false, group: Int? = nil, fixed: Bool = false, width: CGFloat = 0) -> Item {
            Item(kind: .tab, selected: selected, group: group, natural: width, fixed: fixed)
        }
        static func header(_ natural: CGFloat, group: Int, fixed: Bool = false) -> Item {
            Item(kind: .header, selected: false, group: group, natural: natural, fixed: fixed)
        }
    }

    struct Result: Equatable {
        /// One width per item; 0 for an item that left the strip.
        var widths: [CGFloat]
        /// The items in the menu instead of the strip, in order.
        var hidden: [Int]
        /// The common width of an unselected tab.
        var share: CGFloat
        /// The strip's width with these widths.
        var used: CGFloat
    }

    static func width(_ it: Item, share: CGFloat, _ l: Limits) -> CGFloat {
        if it.fixed { return it.natural }
        switch it.kind {
        case .tab: return it.selected ? max(l.minSelected, share) : max(l.minTab, share)
        case .header: return max(l.minHeader, min(it.natural, share))
        }
    }

    static func total(_ items: [Item], visible: [Bool], share: CGFloat, _ l: Limits) -> CGFloat {
        var w: CGFloat = 0
        var n = 0
        var groups = Set<Int>()
        for (i, it) in items.enumerated() where visible[i] {
            w += width(it, share: share, l)
            n += 1
            if let g = it.group { groups.insert(g) }
        }
        return w + l.spacing * CGFloat(max(0, n - 1)) + l.groupPad * CGFloat(groups.count)
    }

    /// The widths for `available` points. `available` = .infinity gives the strip's ideal width (every tab at max).
    static func fit(_ items: [Item], available: CGFloat, limits l: Limits = Limits()) -> Result {
        var visible = Array(repeating: true, count: items.count)
        // Past the minimums: the last items go to the menu (never the selected tab, a fixed one, or a header whose
        // group still shows a tab).
        while total(items, visible: visible, share: 0, l) > available + 0.5 {
            var removed = false
            for i in items.indices.reversed() where visible[i] {
                let it = items[i]
                if it.selected || it.fixed { continue }
                if it.kind == .header, let g = it.group,
                   items.indices.contains(where: { visible[$0] && $0 != i && items[$0].group == g }) { continue }
                visible[i] = false
                removed = true
                break
            }
            if !removed { break }
        }
        var share = l.maxTab
        if total(items, visible: visible, share: l.maxTab, l) > available {
            var lo: CGFloat = 0, hi = l.maxTab
            for _ in 0..<40 {
                let mid = (lo + hi) / 2
                if total(items, visible: visible, share: mid, l) <= available { lo = mid } else { hi = mid }
            }
            share = (lo * 2).rounded(.down) / 2
        }
        let widths = items.indices.map { visible[$0] ? width(items[$0], share: share, l) : 0 }
        let hidden = items.indices.filter { !visible[$0] }
        return Result(widths: widths, hidden: hidden, share: share, used: total(items, visible: visible, share: share, l))
    }
}

/// A history row's second line: the page's host and path, shortened ("acme.app/admin/…/students"), so rows with
/// the same title read apart.
enum HistoryDetail {
    static let maxLength = 46

    static func line(_ url: URL?) -> String? {
        guard let url else { return nil }
        guard let raw = url.host?.lowercased(), !raw.isEmpty else {
            let s = url.absoluteString
            return s.isEmpty ? nil : clampEnd(s)
        }
        var host = raw
        if host.hasPrefix("www.") { host.removeFirst(4) }
        var path = url.path
        while path.count > 1 && path.hasSuffix("/") { path.removeLast() }
        if path == "/" { path = "" }
        var s = host + path
        if path.isEmpty, let q = url.query, !q.isEmpty { s += "?" + q }
        guard s.count > maxLength else { return s }
        // Too long: keep the host, the first and the last part of the path.
        let parts = path.split(separator: "/").map(String.init)
        if parts.count >= 3 {
            let short = host + "/" + parts[0] + "/\u{2026}/" + parts[parts.count - 1]
            if short.count <= maxLength { return short }
            return clampEnd(host + "/\u{2026}/" + parts[parts.count - 1])
        }
        return clampEnd(s)
    }

    private static func clampEnd(_ s: String) -> String {
        s.count <= maxLength ? s : String(s.prefix(maxLength - 1)) + "\u{2026}"
    }
}

/// The colour at the top of the visible page, reflected by the toolbar and the window around the page card.
enum PageTint {
    /// The average of an RGBA strip (premultiplied, 8 bits a channel); nil when it holds nothing opaque.
    static func average(rgba px: [UInt8], count: Int) -> UInt32? {
        var r = 0, g = 0, b = 0, n = 0
        let pixels = min(count, px.count / 4)
        for i in 0..<pixels {
            let a = Int(px[i * 4 + 3])
            guard a >= 128 else { continue }
            r += min(255, Int(px[i * 4]) * 255 / a)
            g += min(255, Int(px[i * 4 + 1]) * 255 / a)
            b += min(255, Int(px[i * 4 + 2]) * 255 / a)
            n += 1
        }
        guard n > 0, n * 4 >= pixels else { return nil }
        return UInt32(r / n) << 16 | UInt32(g / n) << 8 | UInt32(b / n)
    }

    /// Light glyphs over this colour.
    static func onDark(_ c: UInt32) -> Bool { CSSColor.luminance(c) < 0.56 }

    /// Two colours far enough apart to be worth a redraw (a step of a few units is noise while scrolling).
    static func differs(_ a: UInt32?, _ b: UInt32?) -> Bool {
        guard let a, let b else { return a != b }
        let d = [16, 8, 0].map { abs(Int((a >> $0) & 0xFF) - Int((b >> $0) & 0xFF)) }
        return (d.max() ?? 0) > 3
    }

    /// Where the window's colour around the card fades to: the tint, softened toward a light neutral.
    static func fade(_ c: UInt32) -> UInt32 { mix(c, 0xF1F2F4, 0.55) }

    static func mix(_ a: UInt32, _ b: UInt32, _ t: Double) -> UInt32 {
        let t = min(max(t, 0), 1)
        var out: UInt32 = 0
        for s in [16, 8, 0] {
            let x = Double((a >> UInt32(s)) & 0xFF), y = Double((b >> UInt32(s)) & 0xFF)
            out |= UInt32((x + (y - x) * t).rounded()) << UInt32(s)
        }
        return out
    }
}

// MARK: - the toolbar and the window continue the page as a gradient, on time

extension TabStrip {
    /// Where a tab the person opens goes: the end of the strip, after every tab and group, in no group. With `group`
    /// ("New Tab in Group"): right after that group's last tab (the end when the group has none).
    static func newTabIndex(_ slots: [Slot], group: String? = nil) -> Int {
        if let group, let last = slots.lastIndex(where: { $0.group == group && !$0.pinned }) { return last + 1 }
        return slots.count
    }

    /// One Home (the start page) at a time. The Home "+" / \u{2318}T reuses: the tab in front when it is
    /// a Home, else the last one; only a loose tab counts (pinned and grouped ones are the person's). nil: open one.
    static func homeTab(_ slots: [Slot], start: [Bool], selected: Int?) -> Int? {
        let homes = slots.indices.filter { $0 < start.count && start[$0] && !slots[$0].pinned && slots[$0].group == nil }
        if let s = selected, homes.contains(s) { return s }
        return homes.last
    }

    /// where a tab a page opens goes (target=_blank, window.open without a size,
    /// \u{2318}-click, middle-click, "Open Link in New Tab"): right after the tab it was opened from, after the tabs that
    /// tab already opened next to it (they keep their opening order, as Chrome does). ("it does not
    /// open where the page was"): a loose opener keeps it right after itself. (a link from a grouped
    /// tab went into the group, he collapsed it and it looked like nothing opened): an opener in a GROUP, like a pinned
    /// one, sends the new tab to the end of the strip, loose, outside every group (`newTabIndex`). `openedBy[i]`:
    /// slot `i` was opened from the same opener. No opener (or a stale one): the end, no group. `group` stays in the
    /// result for the callers; it is always nil now.
    static func linkTabPlace(_ slots: [Slot], opener: Int?, openedBy: [Bool]) -> (index: Int, group: String?) {
        guard let o = opener, slots.indices.contains(o) else { return (newTabIndex(slots), nil) }
        let from = slots[o]
        if from.pinned || from.group != nil { return (newTabIndex(slots), nil) }
        var i = o + 1
        while i < slots.count, i < openedBy.count, openedBy[i], !slots[i].pinned, slots[i].group == from.group { i += 1 }
        return (i, from.group)
    }

    static func linkTabIndex(_ slots: [Slot], opener: Int?, openedBy: [Bool]) -> Int {
        linkTabPlace(slots, opener: opener, openedBy: openedBy).index
    }

    /// The mouse on a link that asks for a new tab: \u{2318}-click, or the middle button (WKNavigationAction.buttonNumber
    /// on the Mac is a mask: 1 left, 2 right, 4 middle).
    static func linkWantsNewTab(command: Bool, button: Int) -> Bool { command || button == 4 }
}

/// Every reaction of the tint in 100...400 ms, never more (the product's rule for the whole app).
enum TintTiming {
    /// The first look after a navigation commits or a tab comes to front (the page has painted by then).
    static let early: TimeInterval = 0.15
    /// The last look after a commit, a load or a switch: late headers and hero images.
    static let settle: TimeInterval = 0.4
    /// While scrolling: at most one sample this often.
    static let scrollThrottle: TimeInterval = 0.12
    /// After the last scroll event (wheel, momentum): the sample at the scroll's end.
    static let scrollEnd: TimeInterval = 0.15
    /// After a scrolling key (Space, arrows, Page Down): its smooth scroll is longer than a wheel's step.
    static let keyScrollEnd: TimeInterval = 0.3
    /// The colour's own transition.
    static let transition: Double = 0.25
    /// The allowed range of any reaction.
    static let reaction: ClosedRange<Double> = 0.1...0.4

    /// A scroll event at `now`: sample now (throttled) when the last sample is old enough.
    static func sampleWhileScrolling(now: TimeInterval, last: TimeInterval) -> Bool { now - last >= scrollThrottle }
}

/// One colour of a horizontal gradient, at a place across the window (0: left edge, 1: right edge).
struct TintStop: Equatable {
    var color: UInt32
    var location: Double
    init(color: UInt32, location: Double) { self.color = color; self.location = location }
}

/// The page's top band as a grid of colours (columns across, rows down; top row first), and where the page sits
/// across the window (x0...x1, 0...1). The toolbar and the window's ground paint it as horizontal gradients, so a
/// glow, a split header or a gradient carries on across the page's edge instead of stopping at it.
struct TintField: Equatable {
    static let columns = 7
    static let rows = 2

    let columns: Int
    let rows: Int
    /// Row-major, top row first, 0xRRGGBB.
    let colors: [UInt32]
    var x0: Double
    var x1: Double

    init(columns: Int, rows: Int, colors: [UInt32], x0: Double = 0, x1: Double = 1) {
        let c = max(1, columns), r = max(1, rows)
        var list = Array(colors.prefix(c * r))
        while list.count < c * r { list.append(list.last ?? 0xFFFFFF) }
        self.columns = c
        self.rows = r
        self.colors = list
        self.x0 = min(max(min(x0, x1), 0), 1)
        self.x1 = min(max(max(x0, x1), 0), 1)
    }

    /// One colour everywhere (a theme-color, an error page, white until the first sample).
    static func solid(_ c: UInt32) -> TintField { TintField(columns: 1, rows: 1, colors: [c]) }

    func at(_ col: Int, _ row: Int) -> UInt32 {
        colors[min(max(row, 0), rows - 1) * columns + min(max(col, 0), columns - 1)]
    }

    func row(_ r: Int) -> [UInt32] { (0..<columns).map { at($0, r) } }

    /// The whole band's colour (what one colour would have been).
    var average: UInt32 { PageTint.mean(colors) }

    /// The top row with its neighbours mixed in (1-2-1): a hard edge in the page becomes a soft one across the bar.
    func diffused(_ r: Int) -> [UInt32] {
        let line = row(r)
        guard line.count > 2 else { return line }
        return line.indices.map { i in
            let a = line[max(0, i - 1)], b = line[i], c = line[min(line.count - 1, i + 1)]
            return PageTint.mix(PageTint.mix(a, c, 0.5), b, 0.5)
        }
    }

    /// Where column `i`'s colour sits across the window.
    func location(_ i: Int) -> Double {
        x0 + (Double(i) + 0.5) / Double(columns) * (x1 - x0)
    }

    /// A row's colours as stops over the window's whole width (its edge colours held out to 0 and 1).
    func stops(_ line: [UInt32]) -> [TintStop] {
        guard let first = line.first, let last = line.last else { return [TintStop(color: 0xFFFFFF, location: 0)] }
        if line.count == 1 || x1 - x0 < 0.001 {
            let c = line.count == 1 ? first : PageTint.mean(line)
            return [TintStop(color: c, location: 0), TintStop(color: c, location: 1)]
        }
        var out: [TintStop] = []
        if location(0) > 0 { out.append(TintStop(color: first, location: 0)) }
        for (i, c) in line.enumerated() { out.append(TintStop(color: c, location: location(i))) }
        if location(line.count - 1) < 1 { out.append(TintStop(color: last, location: 1)) }
        return out
    }

    /// The bar's lower edge: the page's top row, diffused (what the page shows right under the bar).
    var barStops: [TintStop] { stops(diffused(0)) }

    /// The bar's upper edge: the page's vertical change continued a little upward (`lift` of the step between the
    /// two rows), so a gradient that darkens downward is lighter still at the top of the window.
    func barTopStops(lift: Double = 0.3) -> [TintStop] {
        let top = diffused(0), next = diffused(rows - 1)
        return stops(top.indices.map { PageTint.extend(top[$0], away: next[$0], lift) })
    }

    /// Where the window's ground fades to around the lower part of the card: the band's lower row, softened.
    var fadeStops: [TintStop] { stops(diffused(rows - 1).map(PageTint.fade)) }

    /// The bar's colour at `x` (0...1 of the window): its lower edge's gradient read there.
    func color(atX x: Double) -> UInt32 {
        let s = barStops
        guard let first = s.first, let last = s.last else { return 0xFFFFFF }
        if x <= first.location { return first.color }
        if x >= last.location { return last.color }
        for k in 1..<s.count where x <= s[k].location {
            let a = s[k - 1], b = s[k]
            let span = b.location - a.location
            return span <= 0 ? b.color : PageTint.mix(a.color, b.color, (x - a.location) / span)
        }
        return last.color
    }

    /// Light glyphs at `x` (per region: a dark left half and a light right half each keep their contrast).
    func onDark(atX x: Double) -> Bool { PageTint.onDark(color(atX: x)) }

    /// Far enough apart to be worth a redraw (a few units of noise while scrolling are not).
    func differs(from o: TintField) -> Bool {
        if columns != o.columns || rows != o.rows { return true }
        if abs(x0 - o.x0) > 0.01 || abs(x1 - o.x1) > 0.01 { return true }
        return colors.indices.contains { PageTint.differs(colors[$0], o.colors[$0]) }
    }
}

extension PageTint {
    /// The page's top band as a grid: `width` x `height` RGBA pixels (premultiplied, 8 bits a channel, top row first)
    /// cut into `columns` x `rows` cells, each averaged. A cell with nothing opaque takes its neighbour's colour; nil
    /// when less than a quarter of the band is opaque.
    static func field(rgba px: [UInt8], width: Int, height: Int, columns: Int = TintField.columns,
                      rows: Int = TintField.rows) -> TintField? {
        guard width > 0, height > 0, px.count >= width * height * 4 else { return nil }
        let cols = max(1, min(columns, width)), rws = max(1, min(rows, height))
        var cells: [UInt32?] = []
        var opaque = 0
        for r in 0..<rws {
            let y0 = r * height / rws, y1 = max(y0 + 1, (r + 1) * height / rws)
            for c in 0..<cols {
                let xa = c * width / cols, xb = max(xa + 1, (c + 1) * width / cols)
                var sr = 0, sg = 0, sb = 0, n = 0
                for y in y0..<min(y1, height) {
                    for x in xa..<min(xb, width) {
                        let i = (y * width + x) * 4
                        let a = Int(px[i + 3])
                        guard a >= 128 else { continue }
                        sr += min(255, Int(px[i]) * 255 / a)
                        sg += min(255, Int(px[i + 1]) * 255 / a)
                        sb += min(255, Int(px[i + 2]) * 255 / a)
                        n += 1
                    }
                }
                opaque += n
                cells.append(n > 0 ? (UInt32(sr / n) << 16 | UInt32(sg / n) << 8 | UInt32(sb / n)) : nil)
            }
        }
        guard opaque * 4 >= width * height, cells.contains(where: { $0 != nil }) else { return nil }
        // Holes: the nearest filled cell in the same row, else the same column of another row, else any.
        let any = cells.compactMap { $0 }.first ?? 0xFFFFFF
        var filled: [UInt32] = []
        for r in 0..<rws {
            for c in 0..<cols {
                if let v = cells[r * cols + c] { filled.append(v); continue }
                var found: UInt32?
                for d in 1..<max(2, cols) where found == nil {
                    if c - d >= 0, let v = cells[r * cols + c - d] { found = v } else if c + d < cols, let v = cells[r * cols + c + d] { found = v }
                }
                if found == nil { for o in 0..<rws where o != r { if let v = cells[o * cols + c] { found = v; break } } }
                filled.append(found ?? any)
            }
        }
        return TintField(columns: cols, rows: rws, colors: filled)
    }

    /// The mean of several colours.
    static func mean(_ list: [UInt32]) -> UInt32 {
        guard !list.isEmpty else { return 0xFFFFFF }
        var r = 0, g = 0, b = 0
        for c in list { r += Int((c >> 16) & 0xFF); g += Int((c >> 8) & 0xFF); b += Int(c & 0xFF) }
        let n = list.count
        return UInt32((r + n / 2) / n) << 16 | UInt32((g + n / 2) / n) << 8 | UInt32((b + n / 2) / n)
    }

    /// `c` moved `t` of the way AWAY from `from` (a gradient continued past its end), each channel clamped.
    static func extend(_ c: UInt32, away from: UInt32, _ t: Double) -> UInt32 {
        var out: UInt32 = 0
        for s in [16, 8, 0] {
            let x = Double((c >> UInt32(s)) & 0xFF), y = Double((from >> UInt32(s)) & 0xFF)
            out |= UInt32(min(255, max(0, (x + (x - y) * t).rounded()))) << UInt32(s)
        }
        return out
    }
}

// MARK: - group icons by category, the tab's own buttons

/// The category /agents/suggest gives a group (kinds "tab_name" and "tab_groups"), drawn as an icon of the app's own
/// set (LiaIconData) in the group's header. No emoji anywhere in the strip.
enum TabGroupCat {
    /// The server's categories and the LiaIcon each draws as (the closest the set has).
    static let icons: [String: String] = [
        "code": "code",
        "design": "palette",
        "ads": "megaphone",
        "analytics": "chart-line",
        "money": "coins",
        "shop": "billing",
        "mail": "paper-plane",
        "chat": "chat-circle",
        "social": "cat-social",
        "docs": "note",
        "calendar": "calendar-blank",
        "travel": "plane",
        "learn": "lightning",
        "video": "play-circle",
        "music": "speaker-high",
        "news": "globe-hemisphere-west",
        "cloud": "cloud",
        "people": "users-three",
        "search": "magnifying-glass",
        "health": "shield-check",
        "home": "house",
        "work": "cat-employment",
        "folder": "folder-simple",
    ]
    static let fallback = "folder-simple"

    /// A category the client knows (trimmed, lowercased); nil for anything else.
    static func normalize(_ s: String?) -> String? {
        guard let c = s?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(), icons[c] != nil else { return nil }
        return c
    }

    /// The icon for a category; an unknown or missing one (an old group that has only an emoji) is the folder.
    static func icon(_ cat: String?) -> String {
        guard let c = normalize(cat) else { return fallback }
        return icons[c] ?? fallback
    }
}

/// Which small buttons a tab in the strip shows besides its \u{00D7}. The selected tab shows only the \u{00D7} (it is
/// small and they overlapped it); another tab keeps its speaker (a click mutes it) and shows Reader only when wide
/// enough for nothing to overlap. Both stay in the right-click menus.
enum TabButtons {
    struct Shown: Equatable {
        var speaker: Bool
        var reader: Bool
    }

    /// A tab narrower than this shows no Reader button.
    static let readerMinWidth: CGFloat = 180

    /// `width` nil: outside the shared row (its natural size, wide enough).
    static func shown(selected: Bool, width: CGFloat?, sound: Bool, article: Bool) -> Shown {
        if selected { return Shown(speaker: false, reader: false) }
        let wide = (width ?? .infinity) >= readerMinWidth
        return Shown(speaker: sound, reader: article && wide)
    }

    /// The passwords key (only ever on the selected tab) needs this much width beside the title and the \u{00D7}
    /// (on many narrow tabs it lay over the \u{00D7}). Narrower: no key in the tab; the suggestions
    /// at the page's sign-in field and Command-Backslash still fill.
    static let keyMinWidth: CGFloat = 120

    /// `width` nil: outside the shared row (its natural size, wide enough).
    static func showsKey(selected: Bool, width: CGFloat?) -> Bool {
        selected && (width ?? .infinity) >= keyMinWidth
    }
}

// MARK: -: collapsed groups hide every tab, the tab bar's own menu

extension TabStrip {
    /// Which slots a collapsed group hides: every unpinned tab of a collapsed group, the selected one too (Chrome;
    /// "the whole group collapses except that tab" was the bug). Nothing else is ever hidden.
    /// `kept`: the tab that was in front when its group collapsed: it stays by the closed folder,
    /// even after another tab comes to front, until the group is opened again.
    static func hidden(_ slots: [Slot], collapsed: Set<String>, kept: Set<Int> = []) -> [Bool] {
        slots.indices.map { i in !kept.contains(i) && !slots[i].pinned && slots[i].group.map { collapsed.contains($0) } == true }
    }

    /// A click on a group's folder. Open: it collapses. Collapsed with a kept tab you have LEFT (another
    /// tab is in front): the kept tab hides as well and the group stays collapsed ("collapse once more"); the next click
    /// opens it. Collapsed while you are on the kept tab, or with nothing kept: it opens.
    enum FolderClick: Equatable { case collapse, expand, hideKept }
    static func folderClick(collapsed: Bool, kept: String?, selected: String?) -> FolderClick {
        guard collapsed else { return .collapse }
        if let k = kept, k != selected { return .hideKept }
        return .expand
    }

    /// The group to expand so the selected tab shows (it came to front through \u{2318}1...9, the tab list, a link, the
    /// agent): its own group when that group is collapsed; nil otherwise.
    /// A kept tab (it shows by the closed folder) comes to front without opening its group.
    static func groupToExpand(_ slots: [Slot], selected: Int?, collapsed: Set<String>, kept: Set<Int> = []) -> String? {
        guard let i = selected, slots.indices.contains(i), !kept.contains(i), !slots[i].pinned, let g = slots[i].group, collapsed.contains(g) else { return nil }
        return g
    }

    /// The tab in front after its group collapsed (`collapsed` already holds that group): the nearest tab that still
    /// shows, the first one to the right first, else the nearest to the left (Chromium's next expanded tab). nil: no
    /// tab shows at all; the caller opens a new tab (Chrome does the same), so the group never keeps a lone tab out.
    static func selectionAfterCollapse(_ slots: [Slot], selected: Int, collapsed: Set<String>, kept: Set<Int> = []) -> Int? {
        let hide = hidden(slots, collapsed: collapsed, kept: kept)
        guard slots.indices.contains(selected) else { return slots.indices.first { !hide[$0] } }
        if !hide[selected] { return selected }
        // Pinned tabs show in the workspace's cell, but a loose or expanded tab in the row is the nearer choice.
        let row = slots.indices.filter { !hide[$0] && !slots[$0].pinned }
        if let r = row.first(where: { $0 > selected }) { return r }
        if let l = row.last(where: { $0 < selected }) { return l }
        return slots.indices.last { !hide[$0] }
    }

    /// \u{2303}Tab / \u{2318}\u{2325}\u{2192}: the next (or previous) tab that shows, wrapping; tabs of collapsed groups are passed over
    /// (Chromium's SelectRelativeTab). nil: no other tab shows.
    static func relativeTab(_ slots: [Slot], from: Int, forward: Bool, collapsed: Set<String>, kept: Set<Int> = []) -> Int? {
        let n = slots.count
        guard n > 1, slots.indices.contains(from) else { return nil }
        let hide = hidden(slots, collapsed: collapsed, kept: kept)
        var i = from
        for _ in 1..<n {
            i = (i + (forward ? 1 : n - 1)) % n
            if !hide[i] { return i }
        }
        return nil
    }

    /// Safari's "Arrange Tabs By": the loose tabs (unpinned, in no group) sorted by `keys` (case- and
    /// diacritic-insensitive, ties kept in their order), each taking the next loose place, so pinned tabs and every
    /// group stay exactly where they are. Returns the new order as indices into `slots`.
    static func arranged(_ slots: [Slot], keys: [String]) -> [Int] {
        let loose = slots.indices.filter { !slots[$0].pinned && slots[$0].group == nil }
        func key(_ i: Int) -> String {
            (i < keys.count ? keys[i] : "").folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
        }
        let sorted = loose.enumerated().sorted { a, b in
            let ka = key(a.element), kb = key(b.element)
            return ka == kb ? a.offset < b.offset : ka < kb
        }.map(\.element)
        var out = Array(slots.indices)
        for (place, i) in zip(loose, sorted) { out[place] = i }
        return out
    }

    /// The key "Arrange Tabs By Website" sorts on: the host without "www.", then the title (so one site's pages sit
    /// together, in title order). An empty tab (no address) sorts last.
    static func siteKey(host: String?, title: String) -> String {
        var h = (host ?? "").lowercased()
        if h.hasPrefix("www.") { h.removeFirst(4) }
        return (h.isEmpty ? "\u{FFFF}" : h) + "\u{1}" + title
    }
}
