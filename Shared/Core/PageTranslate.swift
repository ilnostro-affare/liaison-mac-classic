import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
#endif

// Page and selection translation, on the Mac (0.2.11,: "like Arc / Chrome, without an LLM").
// The translating itself is Apple's Translation framework, on device (App/Browser/PageTranslator.swift); the page is
// read and its text nodes replaced by a script in BrowserModel.agentWorld (App/Browser/PageTranslateScript.swift).
// This file is the pure part: which language a page is in and whether to offer, how a text node's whitespace is kept,
// how the nodes go out in batches and come back by id, what to restore, the per-site "Always translate" list, and
// where the selection's button and popover go. Nothing here leaves the Mac, and no model is called.

/// Language codes as the page, NaturalLanguage and Locale give them, compared the way a person means them.
enum TranslateLang {
    /// "en-US" -> "en", "pt_BR" -> "pt", "zh-TW" / "zh-Hant-HK" -> "zh-Hant", "zh" / "zh-CN" -> "zh-Hans",
    /// "iw" -> "he", "in" -> "id", "ji" -> "yi", "no" -> "nb"; nil for empty, "und", "mul", "zxx" or garbage.
    static func base(_ raw: String?) -> String? {
        guard var s = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty else { return nil }
        s = s.replacingOccurrences(of: "_", with: "-")
        let parts = s.split(separator: "-").map { String($0) }
        guard let first = parts.first?.lowercased(), (2...3).contains(first.count),
              first.allSatisfy({ $0 >= "a" && $0 <= "z" }) else { return nil }
        if ["und", "mul", "zxx", "mis"].contains(first) { return nil }
        let legacy = ["iw": "he", "in": "id", "ji": "yi", "no": "nb", "tl": "fil"]
        let lang = legacy[first] ?? first
        if lang == "zh" {
            let rest = parts.dropFirst().map { $0.lowercased() }
            if rest.contains("hant") || rest.contains("tw") || rest.contains("hk") || rest.contains("mo") { return "zh-Hant" }
            return "zh-Hans"
        }
        return lang
    }

    static func same(_ a: String?, _ b: String?) -> Bool {
        guard let x = base(a), let y = base(b) else { return false }
        return x == y
    }

    /// The languages Apple Translation offers (macOS 15), as base codes: the recognizer is constrained to these when
    /// the Mac has not answered `LanguageAvailability.supportedLanguages` yet. A page "in Kazakh" is a page we
    /// could not translate anyway; a Russian page must never read as one.
    static let appleSupported: [String] = ["ar", "zh-Hans", "zh-Hant", "nl", "en", "fr", "de", "hi", "id", "it", "ja",
                                           "ko", "pl", "pt", "ru", "es", "th", "tr", "uk", "vi"]

    /// The script most of a text's letters are in (counted over the first 4,000 scalars).
    enum Script: String, Equatable { case latin, cyrillic, greek, arabic, hebrew, han, kana, hangul, thai, devanagari }

    static func dominantScript(_ text: String) -> Script? {
        var counts: [Script: Int] = [:]
        var seen = 0
        for u in text.unicodeScalars {
            if seen >= 4000 { break }
            let v = u.value
            let s: Script?
            switch v {
            case 0x41...0x5A, 0x61...0x7A, 0xC0...0x24F, 0x1E00...0x1EFF: s = .latin
            case 0x400...0x52F: s = .cyrillic
            case 0x370...0x3FF, 0x1F00...0x1FFF: s = .greek
            case 0x600...0x6FF, 0x750...0x77F, 0xFB50...0xFDFF, 0xFE70...0xFEFF: s = .arabic
            case 0x590...0x5FF: s = .hebrew
            case 0x3040...0x30FF: s = .kana
            case 0x4E00...0x9FFF, 0x3400...0x4DBF: s = .han
            case 0xAC00...0xD7AF, 0x1100...0x11FF: s = .hangul
            case 0xE00...0xE7F: s = .thai
            case 0x900...0x97F: s = .devanagari
            default: s = nil
            }
            guard let s else { continue }
            seen += 1
            counts[s, default: 0] += 1
        }
        guard seen >= 8 else { return nil }
        // Japanese mixes kana and kanji: any real share of kana makes it Japanese.
        if let k = counts[.kana], k * 10 >= seen { return .kana }
        guard let top = counts.max(by: { $0.value < $1.value }), top.value * 2 > seen else { return nil }
        return top.key
    }

    /// The script a language is written in (the languages that matter here; anything else is taken as Latin).
    static func script(of code: String?) -> Script? {
        guard let c = base(code) else { return nil }
        switch c {
        case "ru", "uk", "be", "bg", "sr", "mk", "kk", "ky", "tg", "mn": return .cyrillic
        case "el": return .greek
        case "ar", "fa", "ur", "ps": return .arabic
        case "he", "yi": return .hebrew
        case "ja": return .kana
        case "zh-Hans", "zh-Hant": return .han
        case "ko": return .hangul
        case "th": return .thai
        case "hi", "mr", "ne": return .devanagari
        default: return .latin
        }
    }

    /// Can a text in script `s` be in language `code`? (Japanese text has Han too; Chinese has no kana.)
    static func fits(_ code: String?, script s: Script?) -> Bool {
        guard let s, let l = script(of: code) else { return true }
        if l == .kana { return s == .kana || s == .han }
        return l == s
    }

    /// The language a script alone points to (nil for Latin, which is too many).
    static func language(of s: Script?) -> String? {
        switch s {
        case .cyrillic: return "ru"
        case .greek: return "el"
        case .arabic: return "ar"
        case .hebrew: return "he"
        case .kana: return "ja"
        case .han: return "zh-Hans"
        case .hangul: return "ko"
        case .thai: return "th"
        case .devanagari: return "hi"
        case .latin, .none: return nil
        }
    }

    /// The recognizer's hints: every language it may answer gets an equal prior, the person's own languages twice
    /// that (a mild pull, so a page in the person's language is not "offered"; a clear other language still wins).
    /// Normalised to sum to 1. Codes as given (the app maps them to NLLanguage).
    static func hints(preferred: [String], supported: [String]) -> [String: Double] {
        let mine = Set(preferred.compactMap { base($0) })
        var raw: [String: Double] = [:]
        for c in supported.compactMap({ base($0) }) { raw[c] = mine.contains(c) ? 2 : 1 }
        let sum = raw.values.reduce(0, +)
        guard sum > 0 else { return [:] }
        return raw.mapValues { $0 / sum }
    }

    /// The page's language (a Russian page was "Kazakh"). Order:
    /// 1. `<html lang>` when it is there and its script is the text's: it wins, unless the recognizer (constrained to
    /// what Apple can translate) is very sure of another language over a long sample (a template's `lang="en"` left
    /// on an Italian page).
    /// 2. A declared language whose script is not the text's (`lang="en"` on Cyrillic text) is ignored.
    /// 3. The recognizer when it is confident and its answer fits the script and is one Apple translates.
    /// 4. The dominant script's language (Cyrillic -> Russian, kana -> Japanese, ...); nil for Latin: no idea.
    /// `confidence` is the recognizer's probability for `detected`; `sampleLength` the characters it read;
    /// `script` the sample's dominant script; `supported` the languages Apple Translation offers here.
    static func pageLanguage(htmlLang: String?, detected: String?, confidence: Double, sampleLength: Int,
                             script s: Script? = nil, supported: [String] = appleSupported) -> String? {
        let ok = Set(supported.compactMap { base($0) })
        var read = base(detected)
        if let r = read, (!ok.isEmpty && !ok.contains(r)) || !fits(r, script: s) { read = nil }
        if let declared = base(htmlLang), fits(declared, script: s) {
            if let r = read, r != declared, confidence >= 0.95, sampleLength >= 200 { return r }
            return declared
        }
        if let r = read, confidence >= 0.6, sampleLength >= 20 { return r }
        return language(of: s)
    }

    /// Offer translation when the page's language is none of the person's languages (System Settings' list, as
    /// Safari does: a person who reads Italian and English is not offered either).
    static func shouldOffer(page: String?, preferred: [String]) -> Bool {
        guard let p = base(page) else { return false }
        return !preferred.contains { base($0) == p }
    }

    /// The target to use: the one the person picked last (kept by the app in UserDefaults:
    /// pick Russian it must stay Russian"), else their first language. Since the page and the selection keep
    /// one each (`selectionTarget`, `pageTarget`).
    static func target(stored: String?, preferred: [String]) -> String {
        base(stored) ?? defaultTarget(preferred: preferred)
    }

    /// The default target: the person's first language (base form), English when there is none.
    static func defaultTarget(preferred: [String]) -> String {
        preferred.lazy.compactMap { base($0) }.first ?? "en"
    }

    /// The targets picked, newest first (base codes, no repeats, at most `cap`): `code` goes to the front.
    static func remember(_ code: String, in recent: [String], cap: Int = 6) -> [String] {
        guard let b = base(code) else { return recent }
        var out = [b]
        for r in recent.compactMap({ base($0) }) where !out.contains(r) { out.append(r) }
        return Array(out.prefix(max(1, cap)))
    }

    /// The language a text in `source` goes into without asking (English text must translate into
    /// another language, never "already in English"): the newest pick that is not the source, else the person's next
    /// language (System Settings' list) that is not the source. nil: none of them differs from the source, so the
    /// person is offered the menu. `supported` (when not empty) drops languages Apple cannot translate into.
    /// An unknown source takes the newest pick, else the first language.
    static func pick(source: String?, recent: [String], preferred: [String], supported: [String] = []) -> String? {
        let ok = Set(supported.compactMap { base($0) })
        let all = (recent + preferred).compactMap { base($0) }.filter { ok.isEmpty || ok.contains($0) }
        guard let src = base(source) else { return all.first ?? defaultTarget(preferred: preferred) }
        return all.first { $0 != src }
    }

    /// The page's target when the person did not name one: the remembered page target unless the page is already in
    /// it; nil also when no page target was ever picked (the page asks before its first translation).
    /// nil: the person is offered the choice, with `pick` as the suggestion.
    static func pageTarget(source: String?, stored: String?) -> String? {
        guard let s = base(stored) else { return nil }
        return same(source, s) ? nil : s
    }

    /// The page and the selection remember their own targets. The selection's is its own last pick,
    /// else the page's, else the person's first language.
    static func selectionTarget(stored: String?, page: String?, preferred: [String]) -> String {
        base(stored) ?? base(page) ?? defaultTarget(preferred: preferred)
    }

    /// The picks in the order a text goes without asking: `first` (its own remembered target), then `second` (the
    /// other one), then the recent picks; base codes, no repeats.
    static func order(first: String?, second: String?, recent: [String]) -> [String] {
        var out: [String] = []
        for c in ([first, second] + recent.map { Optional($0) }).compactMap({ base($0) }) where !out.contains(c) { out.append(c) }
        return out
    }
}

/// A text node's value split into the whitespace around it and what gets translated, so " Prezzo\n" comes back as
/// " Price\n" and the layout's spaces between inline elements survive.
struct TextPiece: Equatable {
    var lead: String
    var core: String
    var trail: String

    init(_ s: String) {
        let scalars = Array(s.unicodeScalars)
        var i = 0, j = scalars.count
        while i < j, CharacterSet.whitespacesAndNewlines.contains(scalars[i]) { i += 1 }
        while j > i, CharacterSet.whitespacesAndNewlines.contains(scalars[j - 1]) { j -= 1 }
        var l = String.UnicodeScalarView(), c = String.UnicodeScalarView(), t = String.UnicodeScalarView()
        l.append(contentsOf: scalars[0..<i]); c.append(contentsOf: scalars[i..<j]); t.append(contentsOf: scalars[j...])
        lead = String(l); core = String(c); trail = String(t)
    }

    /// The node's new value: the translation inside the original whitespace (the translation's own trimmed).
    func joined(_ translated: String) -> String {
        lead + translated.trimmingCharacters(in: .whitespacesAndNewlines) + trail
    }

    /// Worth sending: it has a letter, and is not an address, an e-mail, a number or a lone symbol.
    var isTranslatable: Bool {
        let c = core
        guard !c.isEmpty, c.count <= 5000 else { return false }
        guard c.unicodeScalars.contains(where: { CharacterSet.letters.contains($0) }) else { return false }
        let lower = c.lowercased()
        if !c.contains(" ") {
            if lower.hasPrefix("http://") || lower.hasPrefix("https://") || lower.hasPrefix("www.") { return false }
            if c.contains("@"), c.contains(".") { return false }
            // a lone Latin letter ("x", "A") stays; one CJK character is a word
            if c.count == 1, c.unicodeScalars.allSatisfy({ $0.isASCII }) { return false }
        }
        return true
    }
}

/// One text node of the page, as the script gives it: its id there and its whole value.
struct TranslateNode: Equatable {
    var id: Int
    var text: String
}

/// What the page sends and what comes back.
enum TranslateBatcher {
    /// The nodes worth translating, deduplicated: each distinct core text once (a menu's "Accedi" ten times is one
    /// request), with the ids that share it. Order: the first occurrence's (the script sends what is on screen first).
    struct Unique: Equatable {
        var text: String
        var ids: [Int]
    }

    static func unique(_ nodes: [TranslateNode], skipping known: Set<String> = []) -> [Unique] {
        var out: [Unique] = []
        var at: [String: Int] = [:]
        for n in nodes {
            let p = TextPiece(n.text)
            guard p.isTranslatable, !known.contains(p.core) else { continue }
            if let i = at[p.core] { out[i].ids.append(n.id) } else { at[p.core] = out.count; out.append(Unique(text: p.core, ids: [n.id])) }
        }
        return out
    }

    /// Batches of at most `maxItems` requests and about `maxChars` characters (one longer text goes alone).
    /// 0.2.11 (a landing page took about a minute): 200 / 12,000 by default, was 48 / 3,000; each
    /// batch goes as one `translate(batch:)` whose answers stream back, so a bigger batch costs no waiting.
    static func batches(_ items: [Unique], maxItems: Int = 200, maxChars: Int = 12000) -> [[Unique]] {
        var out: [[Unique]] = []
        var cur: [Unique] = []
        var chars = 0
        for u in items {
            let n = u.text.count
            if !cur.isEmpty, cur.count >= maxItems || chars + n > maxChars {
                out.append(cur); cur = []; chars = 0
            }
            cur.append(u); chars += n
        }
        if !cur.isEmpty { out.append(cur) }
        return out
    }

    /// The batches of one sweep: the first `first` texts (what is on screen: the script sends the viewport first) as a
    /// small batch of their own, so the screen is translated in a moment, then the rest in big batches.
    static func plan(_ items: [Unique], first: Int = 40, maxItems: Int = 200, maxChars: Int = 12000) -> [[Unique]] {
        guard items.count > first, first > 0 else { return batches(items, maxItems: maxItems, maxChars: maxChars) }
        return batches(Array(items.prefix(first)), maxItems: first, maxChars: maxChars)
            + batches(Array(items.dropFirst(first)), maxItems: maxItems, maxChars: maxChars)
    }

    /// The batches of one sweep when the script says how many of the nodes are on screen (`visible`: the first
    /// `visible` uniques): the screen goes first in small batches (`firstItems`, then `screenItems`), so its first
    /// lines are back in a moment and the rest of the screen streams in; then the rest in big batches.
    static func plan(_ items: [Unique], visible: Int, firstItems: Int = 16, screenItems: Int = 40,
                     maxItems: Int = 200, maxChars: Int = 12000) -> [[Unique]] {
        let v = min(max(0, visible), items.count)
        guard v > 0 else { return plan(items, maxItems: maxItems, maxChars: maxChars) }
        let screen = Array(items.prefix(v))
        let head = Array(screen.prefix(firstItems))
        var out = batches(head, maxItems: max(1, firstItems), maxChars: maxChars)
        out += batches(Array(screen.dropFirst(firstItems)), maxItems: max(1, screenItems), maxChars: maxChars)
        out += batches(Array(items.dropFirst(v)), maxItems: maxItems, maxChars: maxChars)
        return out
    }

    /// How many of `uniques` (in order) are on screen: those whose first id is one of the first `visibleNodes` node
    /// ids the script sent (it sends what is on screen first). The on-screen ones are moved to the front.
    static func screenFirst(_ uniques: [Unique], nodes: [TranslateNode], visibleNodes: Int) -> (items: [Unique], visible: Int) {
        let shown = Set(nodes.prefix(max(0, visibleNodes)).map(\.id))
        guard !shown.isEmpty else { return (uniques, 0) }
        let on = uniques.filter { $0.ids.contains(where: shown.contains) }
        let off = uniques.filter { !$0.ids.contains(where: shown.contains) }
        return (on + off, on.count)
    }

    /// The person scrolled while a long page was translated: the batches not sent yet are reordered so the ones
    /// with a node now on screen (`onScreen`) go next, the rest keeping their order. Flattened and planned again.
    static func reprioritised(_ rest: [[Unique]], onScreen: Set<Int>, screenItems: Int = 40, maxItems: Int = 200,
                              maxChars: Int = 12000) -> [[Unique]] {
        let flat = rest.flatMap { $0 }
        guard !onScreen.isEmpty, !flat.isEmpty else { return rest }
        let on = flat.filter { $0.ids.contains(where: onScreen.contains) }
        guard !on.isEmpty else { return rest }
        let off = flat.filter { !$0.ids.contains(where: onScreen.contains) }
        return batches(on, maxItems: screenItems, maxChars: maxChars) + batches(off, maxItems: maxItems, maxChars: maxChars)
    }

    /// When the answers that came back are written to the page: every `every` answers, or when `ms` passed since the
    /// last write, or at the end of a batch.
    static func shouldFlush(pending: Int, sinceMs: Double, every: Int = 40, ms: Double = 150) -> Bool {
        pending > 0 && (pending >= every || sinceMs >= ms)
    }

    /// The writes for the page: each node id with its new value (original whitespace kept). `translated` maps a
    /// core text to its translation; nodes whose text has none are left alone.
    static func writes(_ nodes: [TranslateNode], translated: [String: String]) -> [(id: Int, text: String)] {
        var out: [(id: Int, text: String)] = []
        for n in nodes {
            let p = TextPiece(n.text)
            guard let t = translated[p.core], !t.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
            let v = p.joined(t)
            if v != n.text { out.append((n.id, v)) }
        }
        return out
    }
}

/// Translations already made on this page (core text -> translation), so text that comes back (a carousel, an
/// infinite list) is not sent again. Bounded; the oldest go first.
struct TranslationMemo {
    private(set) var map: [String: String] = [:]
    private var order: [String] = []
    let cap: Int

    init(cap: Int = 4000) { self.cap = cap }

    subscript(_ core: String) -> String? { map[core] }
    var keys: Set<String> { Set(map.keys) }
    var count: Int { map.count }

    mutating func add(_ core: String, _ translated: String) {
        if map[core] == nil { order.append(core) }
        map[core] = translated
        while order.count > cap { map[order.removeFirst()] = nil }
    }

    mutating func removeAll() { map = [:]; order = [] }
}

/// Translations kept across pages and tabs for this run of the app, by (source, target, text): the header, the menu
/// and the footer of a site's next page come back at once. Bounded (the oldest go first); never written to disk.
struct TranslateCache {
    private var memo: TranslationMemo

    init(cap: Int = 20000) { memo = TranslationMemo(cap: cap) }

    static func key(source: String?, target: String, text: String) -> String {
        (TranslateLang.base(source) ?? "") + ">" + (TranslateLang.base(target) ?? target) + "\u{1}" + text
    }

    func get(source: String?, target: String, text: String) -> String? { memo[Self.key(source: source, target: target, text: text)] }

    mutating func put(source: String?, target: String, text: String, _ translated: String) {
        memo.add(Self.key(source: source, target: target, text: text), translated)
    }

    var count: Int { memo.count }
}

/// The originals of the nodes replaced, to put back on "Show Original". The first original wins: a node translated
/// twice (the page changed it and it was translated again) is restored to the page's latest own text, which the
/// script reports with `pageChanged`.
struct TranslateOriginals {
    private(set) var byID: [Int: String] = [:]

    mutating func record(_ id: Int, original: String) { if byID[id] == nil { byID[id] = original } }
    /// The page wrote its own text into a node we had translated: that is now the original.
    mutating func pageChanged(_ id: Int, to text: String) { byID[id] = text }
    func restores() -> [(id: Int, text: String)] { byID.keys.sorted().map { ($0, byID[$0]!) } }
    mutating func removeAll() { byID = [:] }
    var isEmpty: Bool { byID.isEmpty }
}

/// "Always translate <language> on this site", per host (without "www."). Kept in UserDefaults by the app; never
/// written from a private window.
struct AlwaysTranslate: Equatable {
    private(set) var hosts: [String: [String]] = [:]

    init(_ stored: [String: [String]] = [:]) { hosts = stored }

    static func key(_ host: String?) -> String? {
        guard var h = host?.lowercased().trimmingCharacters(in: .whitespaces), !h.isEmpty else { return nil }
        if h.hasPrefix("www.") { h.removeFirst(4) }
        return h
    }

    func contains(host: String?, language: String?) -> Bool {
        guard let k = Self.key(host), let l = TranslateLang.base(language) else { return false }
        return hosts[k]?.contains(l) ?? false
    }

    mutating func set(host: String?, language: String?, on: Bool) {
        guard let k = Self.key(host), let l = TranslateLang.base(language) else { return }
        var list = hosts[k] ?? []
        list.removeAll { $0 == l }
        if on { list.append(l) }
        hosts[k] = list.isEmpty ? nil : list
    }
}

/// Where the translation is at, for the tab's button and the status over the page.
enum TranslatePhase: Equatable {
    case off
    case preparing                      // checking or downloading the languages
    case translating(done: Int, total: Int)
    case on                             // the page shows the translation (and new content follows)
    case failed(String)

    var isActive: Bool {
        switch self { case .preparing, .translating, .on: return true; default: return false }
    }
}

/// The selection popover's anchor, in the web view's own points (top-left origin).
enum TranslateGeometry {
    /// A viewport rect (CSS px) in the view: times the page zoom (and magnification).
    static func viewRect(x: Double, y: Double, w: Double, h: Double, zoom: CGFloat) -> CGRect {
        let z = Double(zoom > 0 ? zoom : 1)
        return CGRect(x: x * z, y: y * z, width: max(1, w * z), height: max(1, h * z))
    }

    /// The selection is on screen at all (scrolled away: no button).
    static func visible(_ r: CGRect, in bounds: CGSize) -> Bool {
        r.maxY > 0 && r.minY < bounds.height && r.maxX > 0 && r.minX < bounds.width
    }
}
