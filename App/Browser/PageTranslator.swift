import SwiftUI
import AppKit
import WebKit
import NaturalLanguage
#if canImport(Translation)
import Translation
#endif

// Translation of pages and selections (0.2.11,: "like Arc, Chrome or Safari - without an LLM").
// Chrome and Arc send the page's text to Google Translate's servers; Firefox (Bergamot) and Apple's Translation
// framework translate on the device. We use Apple's: on device, free, and nothing of the page leaves the Mac, so it
// also works in private windows. The page is read and rewritten in BrowserModel.agentWorld only
// (PageTranslateScript); the pure part (languages, batches, restore, "Always translate") is Shared/Core/PageTranslate.
//
// TranslationSession comes only through SwiftUI's `.translationTask` (macOS 15): PageTranslateEngine, a 1 pt view in
// the tab's TranslateTabLayer, owns the session while `request` is set; clearing `request` ends it. The selection is
// translated the same way (SelectionTranslateEngine) into our own popover, so it uses the remembered language; on
// macOS 14.4 it is the system's `.translationPresentation`, which picks its own. On macOS 14 the page path says so.
// (the product's test): no floating "Translate" chip over a selection any more (the right-click menu has it);
// the page and the selection each keep their own last pick (the page asks before its first translation;
// a selection with no pick of its own uses the page's); the page's language prefers `<html lang>`
// and the recognizer only answers languages Apple translates; a page streams in batches, the screen first.

/// One translator per web view (a main-window tab or a private one).
@MainActor
final class PageTranslateCenter: ObservableObject {
    static let shared = PageTranslateCenter()
    /// The translator lives on its web view as an associated object, so it goes when the tab's web view goes
    /// (an NSMapTable weak-to-strong keeps the value until the table happens to resize: every closed tab's
    /// translator stayed). PageTranslator holds the web view weakly, so there is no cycle.
    private static var key: UInt8 = 0

    func model(for webView: WKWebView, isPrivate: Bool = false) -> PageTranslator {
        if let m = existing(webView) { return m }
        let m = PageTranslator(webView: webView, isPrivate: isPrivate)
        objc_setAssociatedObject(webView, &Self.key, m, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        return m
    }

    /// Only an existing one (the page menu, the View menu: no translator is made for a page never shown).
    func existing(_ webView: WKWebView?) -> PageTranslator? {
        guard let webView else { return nil }
        return objc_getAssociatedObject(webView, &Self.key) as? PageTranslator
    }

    // MARK: settings

    private static let alwaysKey = "lia_translate_always"
    /// The selection's target (the one value for pages and selections alike).
    private static let targetKey = "lia_translate_target"
    /// The page's own target, unset until the person picks one (the page asks first).
    private static let pageKey = "lia_translate_page_target"
    private static let recentKey = "lia_translate_recent"

    var always: AlwaysTranslate {
        get { AlwaysTranslate(UserDefaults.standard.dictionary(forKey: Self.alwaysKey) as? [String: [String]] ?? [:]) }
        set { UserDefaults.standard.set(newValue.hosts, forKey: Self.alwaysKey) }
    }

    var preferred: [String] { Locale.preferredLanguages }

    /// The language pages are translated into: nil until the person picks one, so the first
    /// translation of a page asks; then that pick for every tab and window ("once I pick Russian it must stay
    /// Russian"), read fresh each time. Kept apart from the selection's (`selectionTarget`).
    var pageTarget: String? {
        get { TranslateLang.base(UserDefaults.standard.string(forKey: Self.pageKey)) }
        set {
            guard let b = TranslateLang.base(newValue), b != UserDefaults.standard.string(forKey: Self.pageKey) else { return }
            objectWillChange.send()
            UserDefaults.standard.set(b, forKey: Self.pageKey)
            UserDefaults.standard.set(TranslateLang.remember(b, in: storedRecent), forKey: Self.recentKey)
        }
    }

    /// The selection's own last pick (nil: none yet).
    private var storedSelection: String? { TranslateLang.base(UserDefaults.standard.string(forKey: Self.targetKey)) }

    /// The language a selection goes into: its own last pick, else the page's, else the system's first language.
    var selectionTarget: String {
        get { TranslateLang.selectionTarget(stored: storedSelection, page: pageTarget, preferred: preferred) }
        set {
            guard let b = TranslateLang.base(newValue), b != UserDefaults.standard.string(forKey: Self.targetKey) else { return }
            objectWillChange.send()
            UserDefaults.standard.set(b, forKey: Self.targetKey)
            UserDefaults.standard.set(TranslateLang.remember(b, in: storedRecent), forKey: Self.recentKey)
        }
    }

    private var storedRecent: [String] { UserDefaults.standard.stringArray(forKey: Self.recentKey) ?? [] }

    /// Where a selected text in `source` goes without asking: its own target first, then the page's, then the recent
    /// picks, never the text's own language (nil: the person picks from the menu).
    func pick(for source: String?) -> String? {
        TranslateLang.pick(source: source, recent: TranslateLang.order(first: storedSelection, second: pageTarget, recent: storedRecent),
                           preferred: preferred, supported: supported)
    }

    /// The suggestion in the page's language chooser: the page's target first, then the recent picks.
    func pagePick(for source: String?) -> String? {
        TranslateLang.pick(source: source, recent: TranslateLang.order(first: pageTarget, second: nil, recent: storedRecent),
                           preferred: preferred, supported: supported)
    }

    /// Translations made this run, by (source, target, text): a site's next page, another tab (TranslateCache).
    var cache = TranslateCache()

    /// The languages Apple Translation offers on this Mac (base codes); the built-in list until the Mac answers.
    private(set) var supported: [String] = TranslateLang.appleSupported

    /// The targets Apple Translation offers on this Mac (codes like "en", "zh-Hant"), the person's own first.
    private(set) var targets: [String] = []

    func loadTargets() async {
        guard targets.isEmpty else { return }
        var codes: [String] = []
        #if canImport(Translation)
        if #available(macOS 15.0, *) {
            let langs = await LanguageAvailability().supportedLanguages
            codes = langs.compactMap { TranslateLang.base($0.maximalIdentifier) }
        }
        #endif
        if !codes.isEmpty { supported = Array(Set(codes)).sorted() }
        // The picker offers every language Apple translates; the built-in list until the Mac answers.
        if codes.isEmpty { codes = TranslateLang.appleSupported }
        var seen = Set<String>(), out: [String] = []
        for c in preferred.compactMap({ TranslateLang.base($0) }) + codes.sorted(by: { Self.name($0) < Self.name($1) }) where !seen.contains(c) {
            if !codes.isEmpty, !codes.contains(c) { continue }
            seen.insert(c); out.append(c)
        }
        targets = out
    }

    /// "it" -> "Italian", "zh-Hant" -> "Chinese, Traditional" (in English: the app's copy is English).
    static func name(_ code: String?) -> String {
        guard let code else { return "Unknown" }
        let en = Locale(identifier: "en")
        if code == "zh-Hant" { return "Chinese (Traditional)" }
        if code == "zh-Hans" { return "Chinese (Simplified)" }
        return en.localizedString(forIdentifier: code) ?? en.localizedString(forLanguageCode: code) ?? code
    }
}

@MainActor
final class PageTranslator: ObservableObject {
    /// What the engine translates now: nil, no session. `token` makes "translate again" a new request.
    struct Request: Equatable {
        var source: String?
        var target: String
        var token: Int
    }
    /// The selection, its rect in the web view (points, top-left origin) and whether it can be replaced.
    struct Selection: Equatable {
        var text: String
        var rect: CGRect
        var editable: Bool
    }
    /// The selection's own translation (macOS 15): what SelectionTranslateEngine translates now.
    struct SelectionRequest: Equatable {
        var text: String
        var source: String?
        var target: String
        var token: Int
    }
    /// What the selection's popover shows.
    enum SelectionState: Equatable {
        case working
        case done(String)
        case failed(String)
        /// The text is already in every language the app would pick: the person chooses (the menu is the answer).
        case choose(String)
    }

    weak var webView: WKWebView?
    let isPrivate: Bool
    @Published private(set) var phase: TranslatePhase = .off
    /// The page's language (base code), nil: unknown.
    @Published private(set) var pageLanguage: String?
    /// The page is in a language the person does not read: the tab shows the Translate button.
    @Published private(set) var offer = false
    @Published private(set) var request: Request?
    /// A message over the page for a moment (macOS 14, a refused download, a failure).
    @Published var notice: String?
    /// The selection's popover (nil: closed): ours on macOS 15, the system's on 14.4.
    @Published var presenting: Selection? {
        didSet { if presenting == nil { selectionRequest = nil } }
    }
    @Published private(set) var selectionRequest: SelectionRequest?
    @Published private(set) var selectionState: SelectionState = .working
    /// The selection's language and the language it goes into now (the popover's "English -> Russian").
    @Published private(set) var selectionFrom: String?
    @Published private(set) var selectionTarget: String?
    /// The person asked to translate the page and no language is settled for it: none picked yet (
    /// ask first) or the page is already in the remembered one (never "already in English" as a dead
    /// end). The layer offers the languages.
    @Published var choosing = false
    /// The page's translate bar ("Translated into <language ▾>", Show Original): on while the page translates and
    /// a few seconds after, until closed.
    @Published var bar = false

    /// The language this page goes into: the remembered page target (PageTranslateCenter.pageTarget), the person's
    /// first language only as a placeholder before one is picked (`translate` asks then).
    var target: String { PageTranslateCenter.shared.pageTarget ?? TranslateLang.defaultTarget(preferred: PageTranslateCenter.shared.preferred) }
    /// A page target has been picked.
    var targetChosen: Bool { PageTranslateCenter.shared.pageTarget != nil }

    private var memo = TranslationMemo()
    private var originals = TranslateOriginals()
    private var token = 0
    private var selectionToken = 0
    private var host: String?
    /// Chrome's habit: once a tab is translated, its next pages in the same language are too, until Show Original.
    private var sticky: String?
    private var noticeJob: Task<Void, Never>?
    private var barJob: Task<Void, Never>?

    init(webView: WKWebView, isPrivate: Bool) {
        self.webView = webView
        self.isPrivate = isPrivate
    }

    /// What an agent reading or looking at this page is told while it shows our translation (the text
    /// and the picture are the translated page as shown; without this the agent misreports the site's language). nil:
    /// the page shows its own text.
    var agentNote: String? { Self.agentNote(phase: phase, source: pageLanguage, target: request?.target ?? target) }

    static func agentNote(phase: TranslatePhase, source: String?, target: String) -> String? {
        let from = source.map { PageTranslateCenter.name($0) }
        let into = PageTranslateCenter.name(target)
        let what = from.map { "translated from \($0) into \(into) by Liaison" } ?? "translated into \(into) by Liaison"
        switch phase {
        case .on: return "[This page is shown " + what + "; the site itself is" + (from.map { " in " + $0 } ?? " in another language") + ".]"
        case .preparing, .translating: return "[This page is being " + what + ": part of it may still be in the original language.]"
        case .off, .failed: return nil
        }
    }

    static var pageSupported: Bool {
        #if canImport(Translation)
        if #available(macOS 15.0, *) { return true }
        #endif
        return false
    }

    static var selectionSupported: Bool {
        #if canImport(Translation)
        if #available(macOS 14.4, *) { return true }
        #endif
        return false
    }

    // MARK: the page script

    private func js(_ op: String, items: [[Any]] = [], text: String = "", max: Int = 0, within seconds: Double = 3) async -> Any? {
        guard let wv = webView else { return nil }
        let args: [String: Any] = ["op": op, "items": items, "text": text, "max": max]
        return await withCheckedContinuation { (k: CheckedContinuation<Any?, Never>) in
            let once = OnceResume(k)
            wv.callAsyncJavaScript(PageTranslateScript.js, arguments: args, in: nil, in: BrowserModel.agentWorld) { r in
                if case .success(let v) = r { once.resume(v) } else { once.resume(nil) }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { once.resume(nil) }
        }
    }

    private var zoom: CGFloat {
        guard let w = webView else { return 1 }
        let z = w.pageZoom * w.magnification
        return z > 0 ? z : 1
    }

    // MARK: language detection

    /// What a text reads as: NLLanguageRecognizer constrained to the languages Apple Translation offers on this Mac
    /// (Kazakh is never an answer for Russian text) and hinted towards the person's own languages.
    static func recognize(_ text: String) -> (lang: String?, confidence: Double) {
        let center = PageTranslateCenter.shared
        let r = NLLanguageRecognizer()
        let supported = center.supported
        r.languageConstraints = supported.map { NLLanguage(rawValue: $0) }
        var hints: [NLLanguage: Double] = [:]
        for (k, v) in TranslateLang.hints(preferred: center.preferred, supported: supported) { hints[NLLanguage(rawValue: k)] = v }
        r.languageHints = hints
        r.processString(text)
        guard let top = r.languageHypotheses(withMaximum: 1).first else { return (nil, 0) }
        return (top.key.rawValue, top.value)
    }

    // MARK: the page's language

    /// After each load: is this the same document still translated (a single-page app moved), or a new page?
    /// A new one is read for its language; the offer, "Always translate" and the tab's habit follow from it.
    func pageLoaded(_ url: URL?) async {
        guard let url, ["http", "https"].contains(url.scheme?.lowercased() ?? "") else {
            reset(); pageLanguage = nil; offer = false; return
        }
        if let s = await js("state") as? [String: Any], (s["on"] as? Bool) == true, request != nil { return }
        reset()
        host = url.host
        await PageTranslateCenter.shared.loadTargets()
        guard let d = await js("detect") as? [String: Any] else { return }
        let sample = d["sample"] as? String ?? ""
        let read = Self.recognize(sample)
        let lang = TranslateLang.pageLanguage(htmlLang: d["lang"] as? String, detected: read.lang, confidence: read.confidence,
                                              sampleLength: sample.count, script: TranslateLang.dominantScript(sample),
                                              supported: PageTranslateCenter.shared.supported)
        pageLanguage = lang
        offer = TranslateLang.shouldOffer(page: lang, preferred: PageTranslateCenter.shared.preferred)
        guard offer, let lang, Self.pageSupported else { return }
        let always = !isPrivate && PageTranslateCenter.shared.always.contains(host: host, language: lang)
        // Automatic only into another language: a page already in the target is never a question by itself. "Always"
        // with no page target yet asks (the bar's chooser).
        guard always || sticky == lang else { return }
        if !targetChosen { choosing = true } else if !TranslateLang.same(lang, target) { translate() }
    }

    /// The document is gone (or never was ours): forget its nodes; no session.
    private func reset() {
        request = nil
        memo.removeAll()
        originals.removeAll()
        phase = .off
        presenting = nil
        choosing = false
        hideBar()
    }

    // MARK: page translation

    func toggle() { phase.isActive ? showOriginal() : translate() }

    /// The language the page would go into without asking: the remembered page target unless the page is in it;
    /// nil: none picked yet, or the page is in it (the chooser asks).
    var suggestedTarget: String? {
        TranslateLang.pageTarget(source: pageLanguage, stored: PageTranslateCenter.shared.pageTarget)
    }

    /// The page into `newTarget` (the menus), or into the remembered target. A page already in the target is not
    /// refused: the layer offers the languages (`choosing`), the next one first.
    func translate(to newTarget: String? = nil) {
        guard Self.pageSupported else { say("Translation needs macOS 15. Selected text can still be translated from the page menu."); return }
        if let t = newTarget, TranslateLang.same(t, pageLanguage) {
            // The page's own language picked: not a translation, and not remembered; the choice stays open.
            if !phase.isActive { choosing = true }
            say("This page is in \(PageTranslateCenter.name(t)). Pick another language.")
            return
        }
        var switching = false
        if let t = newTarget, !TranslateLang.same(t, PageTranslateCenter.shared.pageTarget) {
            objectWillChange.send()
            PageTranslateCenter.shared.pageTarget = t
            switching = phase.isActive
        }
        // No language picked for pages yet (or the page is in it): ask, never the selection's.
        if newTarget == nil, TranslateLang.pageTarget(source: pageLanguage, stored: PageTranslateCenter.shared.pageTarget) == nil {
            choosing = true
            return
        }
        choosing = false
        if phase.isActive, !switching { return }
        request = nil                 // ends a running session first
        phase = .preparing
        sticky = pageLanguage
        showBar()
        token += 1
        let next = Request(source: pageLanguage, target: target, token: token)
        Task { @MainActor in
            // Another target: the page goes back to its own text first, then is translated again.
            if switching { await self.restoreOnly() }
            guard self.token == next.token else { return }
            self.request = next
        }
    }

    func showOriginal() {
        choosing = false
        hideBar()
        sticky = nil
        request = nil
        phase = .off
        token += 1
        Task { await restoreOnly() }
    }

    private func restoreOnly() async {
        let items = originals.restores().map { [$0.id, $0.text] as [Any] }
        _ = await js("restore", items: items)
        originals.removeAll()
        memo.removeAll()
    }

    /// "Always translate <language> on <host>" (not offered in a private window: it would remember the site).
    var alwaysOn: Bool { PageTranslateCenter.shared.always.contains(host: host, language: pageLanguage) }
    var siteName: String? { AlwaysTranslate.key(host) }

    func setAlways(_ on: Bool) {
        guard !isPrivate else { return }
        var a = PageTranslateCenter.shared.always
        a.set(host: host, language: pageLanguage, on: on)
        PageTranslateCenter.shared.always = a
        objectWillChange.send()
        if on, !phase.isActive { translate() }
    }

    private func showBar() {
        barJob?.cancel()
        barJob = nil
        bar = true
    }

    /// The bar stays a few seconds after the page is done (the toolbar's menu changes the language later).
    private func fadeBar(after seconds: Double = 6) {
        barJob?.cancel()
        barJob = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            guard !Task.isCancelled else { return }
            self?.bar = false
        }
    }

    func hideBar() {
        barJob?.cancel()
        barJob = nil
        bar = false
    }

    func say(_ text: String, seconds: Double = 5) {
        notice = text
        noticeJob?.cancel()
        noticeJob = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            guard !Task.isCancelled else { return }
            self?.notice = nil
        }
    }

    private func fail(_ message: String) {
        request = nil
        hideBar()
        phase = .failed(message)
        say(message, seconds: 7)
        Task { await self.restoreOnly() }
    }

    #if canImport(Translation)
    /// The languages ready for a session: the system's own sheet offers to download them the first time. nil: ready;
    /// otherwise the message to show.
    @available(macOS 15.0, *)
    private func ready(_ session: TranslationSession, source: String?, target: String) async -> String? {
        let to = Locale.Language(identifier: target)
        if let src = source {
            let status = await LanguageAvailability().status(from: Locale.Language(identifier: src), to: to)
            switch status {
            case .unsupported:
                return "Apple Translation can't translate \(PageTranslateCenter.name(src)) into \(PageTranslateCenter.name(target)) on this Mac."
            case .supported:
                do { try await session.prepareTranslation() } catch {
                    return "The languages weren't downloaded. Try again, or add them in System Settings \u{203A} General \u{203A} Language & Region \u{203A} Translation Languages."
                }
            default: break
            }
        } else {
            do { try await session.prepareTranslation() } catch { return "Couldn't tell which language this is in." }
        }
        return nil
    }

    /// The engine's session at work (PageTranslateEngine's `.translationTask`): languages first, then the page in
    /// sweeps, then new content as it comes, until the request ends.
    @available(macOS 15.0, *)
    func run(_ session: TranslationSession, for req: Request) async {
        guard request == req else { return }
        phase = .preparing
        let problem = await ready(session, source: req.source, target: req.target)
        guard request == req, !Task.isCancelled else { return }
        if let problem { fail(problem); return }
        _ = await js("start")
        let ok = await pass(session, req)
        guard request == req, !Task.isCancelled else { return }
        if !ok { fail("Couldn't translate this page."); return }
        phase = .on
        if bar { fadeBar() }
        // New content while translation is on (an infinite list, a SPA's next view), checked about once a second.
        while request == req, !Task.isCancelled {
            try? await Task.sleep(nanoseconds: 900_000_000)
            guard request == req, !Task.isCancelled else { return }
            guard let o = await js("changed", within: 1.5) as? [String: Any] else { continue }
            let edits = (o["edits"] as? [[Any]]) ?? []
            for e in edits where e.count == 2 {
                if let i = (e[0] as? NSNumber)?.intValue, let t = e[1] as? String { originals.pageChanged(i, to: t) }
            }
            if (o["dirty"] as? Bool) == true || !edits.isEmpty { _ = await pass(session, req, quiet: true) }
        }
    }

    /// One sweep (a landing page took about a minute). The script hands over up to 1,500 text nodes
    /// at once, what is on screen first. Text this run already translated (this page, another tab, the site's other
    /// pages: PageTranslateCenter.cache) is written at once; the rest is deduplicated, what is on screen (the script's
    /// `vis`) goes first in small batches (16, then 40) and then the rest in batches of 200, each ONE
    /// `translate(batch:)` whose answers stream back and are written to the page as they come (the screen's every 3
    /// answers or 50 ms, later ones every 20 or 100 ms). Before each big batch the script says which of the waiting
    /// nodes are on screen now, and those go next (the person scrolled). Batches run one after another on the one
    /// session (Apple does not promise concurrent requests on a session; the model is one on-device engine anyway).
    /// false: nothing translated.
    @available(macOS 15.0, *)
    private func pass(_ session: TranslationSession, _ req: Request, quiet: Bool = false) async -> Bool {
        var done = 0, total = 0, failed = 0, batchesRun = 0, rounds = 0
        var more = true
        while more, rounds < 40, request == req, !Task.isCancelled {
            rounds += 1
            guard let o = await js("collect", max: 1500, within: 6) as? [String: Any] else { break }
            more = (o["more"] as? Bool) ?? false
            let visibleNodes = (o["vis"] as? NSNumber)?.intValue ?? 0
            let nodes: [TranslateNode] = ((o["nodes"] as? [[Any]]) ?? []).compactMap { a in
                guard a.count == 2, let i = (a[0] as? NSNumber)?.intValue, let t = a[1] as? String else { return nil }
                return TranslateNode(id: i, text: t)
            }
            if nodes.isEmpty { break }
            var todo: [TranslateBatcher.Unique] = []
            for u in TranslateBatcher.unique(nodes, skipping: memo.keys) {
                if let t = PageTranslateCenter.shared.cache.get(source: req.source, target: req.target, text: u.text) {
                    memo.add(u.text, t)
                } else {
                    todo.append(u)
                }
            }
            await write(nodes)   // known text: this page's, and the run's cache
            total += todo.count
            if !quiet, total > 0 { phase = .translating(done: done, total: total) }
            // The screen first, in small batches (the first lines are back at once), then the rest in big ones; between
            // the big ones, what the person scrolled to goes next (`onscreen`).
            let ordered = TranslateBatcher.screenFirst(todo, nodes: nodes, visibleNodes: visibleNodes)
            var queue = TranslateBatcher.plan(ordered.items, visible: ordered.visible)
            var screenLeft = ordered.visible
            var bi = 0
            while !queue.isEmpty {
                guard request == req, !Task.isCancelled else { return true }
                if screenLeft <= 0, bi > 0, queue.count > 1 {
                    let ids = queue.flatMap { $0.flatMap(\.ids) }.prefix(4000).map { [$0] as [Any] }
                    if let on = await js("onscreen", items: Array(ids), within: 1) as? [Any] {
                        let set = Set(on.compactMap { ($0 as? NSNumber)?.intValue })
                        queue = TranslateBatcher.reprioritised(queue, onScreen: set)
                    }
                    guard request == req, !Task.isCancelled else { return true }
                }
                let batch = queue.removeFirst()
                let onScreen = screenLeft > 0
                screenLeft -= batch.count
                defer { bi += 1 }
                let reqs = batch.enumerated().map { TranslationSession.Request(sourceText: $0.element.text, clientIdentifier: String($0.offset)) }
                batchesRun += 1
                let base = done
                var waiting = Set<Int>()   // node ids whose translation came back and is not on the page yet
                var waitingN = 0
                var flushed = Date()
                do {
                    for try await r in session.translate(batch: reqs) {
                        guard request == req, !Task.isCancelled else { return true }
                        if let c = r.clientIdentifier, let k = Int(c), k < batch.count {
                            memo.add(batch[k].text, r.targetText)
                            PageTranslateCenter.shared.cache.put(source: req.source, target: req.target, text: batch[k].text, r.targetText)
                            waiting.formUnion(batch[k].ids)
                            waitingN += 1
                            done += 1
                        }
                        // The screen's batches: on the page every 3 answers or 50 ms; later ones every 20 answers or 100 ms.
                        if TranslateBatcher.shouldFlush(pending: waitingN, sinceMs: Date().timeIntervalSince(flushed) * 1000,
                                                        every: onScreen ? 3 : 20, ms: onScreen ? 50 : 100) {
                            let ids = waiting
                            waiting = []; waitingN = 0; flushed = Date()
                            await write(nodes.filter { ids.contains($0.id) })
                            if !quiet { phase = .translating(done: done, total: total) }
                        }
                    }
                } catch {
                    failed += 1
                }
                guard request == req else { return true }
                if !waiting.isEmpty { await write(nodes.filter { waiting.contains($0.id) }) }
                done = base + batch.count
                if !quiet { phase = .translating(done: done, total: total) }
            }
        }
        return batchesRun == 0 || failed < batchesRun
    }

    /// The selection's own translation (SelectionTranslateEngine's `.translationTask`), into the remembered target.
    @available(macOS 15.0, *)
    func runSelection(_ session: TranslationSession, for req: SelectionRequest) async {
        guard selectionRequest == req else { return }
        selectionState = .working
        if let problem = await ready(session, source: req.source, target: req.target) {
            guard selectionRequest == req else { return }
            selectionState = .failed(problem)
            return
        }
        guard selectionRequest == req, !Task.isCancelled else { return }
        do {
            let r = try await session.translate(req.text)
            guard selectionRequest == req else { return }
            selectionState = .done(r.targetText)
        } catch {
            guard selectionRequest == req, !Task.isCancelled else { return }
            selectionState = .failed("Couldn't translate the selection.")
        }
    }
    #endif

    private func write(_ nodes: [TranslateNode]) async {
        let w = TranslateBatcher.writes(nodes, translated: memo.map)
        guard !w.isEmpty else { return }
        let before = await js("apply", items: w.map { [$0.id, $0.text] as [Any] })
        for e in (before as? [[Any]]) ?? [] where e.count == 2 {
            if let i = (e[0] as? NSNumber)?.intValue, let t = e[1] as? String { originals.record(i, original: t) }
        }
    }

    // MARK: selection

    /// The selection as the page has it now (nil: nothing selected).
    func readSelection() async -> Selection? {
        guard let o = await js("selection", within: 1) as? [String: Any], let text = o["text"] as? String,
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        func d(_ k: String) -> Double { (o[k] as? NSNumber)?.doubleValue ?? 0 }
        let r = TranslateGeometry.viewRect(x: d("x"), y: d("y"), w: d("w"), h: d("h"), zoom: zoom)
        let editable = !((o["editable"] as? String) ?? "").isEmpty
        return Selection(text: text, rect: r, editable: editable)
    }

    /// The selection's source: what it reads as when the recognizer is sure enough for its length, else the page's.
    private func selectionSource(_ text: String) -> String? {
        let r = Self.recognize(text)
        let sure = text.count < 12 ? 0.85 : 0.6
        let script = TranslateLang.dominantScript(text)
        if let l = TranslateLang.base(r.lang), r.confidence >= sure, TranslateLang.fits(l, script: script) { return l }
        if let p = pageLanguage, TranslateLang.fits(p, script: script) { return p }
        return TranslateLang.language(of: script)
    }

    /// "Translate" in the page's right-click menu (or the View menu): the popover at the selection. On macOS 15 ours,
    /// in the remembered language; on 14.4 the system's.
    func translateSelection() {
        guard Self.selectionSupported else { say("Translation needs macOS 15."); return }
        Task {
            guard let s = await readSelection() else { say("Select some text on the page first."); return }
            presenting = s
            if Self.pageSupported { startSelection(s.text) }
        }
    }

    /// The selection again into another language (the popover's menu); the pick is remembered for selections only
    /// (the page asks for its own), not when it is the text's own language.
    func translateSelection(to code: String) {
        guard let s = presenting else { return }
        if TranslateLang.same(code, selectionFrom) {
            selectionToken += 1
            selectionRequest = nil
            selectionState = .choose("This text is in \(PageTranslateCenter.name(code)). Pick another language.")
            return
        }
        objectWillChange.send()
        PageTranslateCenter.shared.selectionTarget = code   // the selection's own: the page keeps its target
        startSelection(s.text, into: code)
    }

    /// The selection into `explicit`, or (none) into the selection's target, else the page's, else the last language
    /// picked that is not the text's own, else the person's next language (English text translates
    /// too); none of them differs: the menu.
    private func startSelection(_ text: String, into explicit: String? = nil) {
        selectionToken += 1
        let src = selectionSource(text)
        selectionFrom = src
        guard let to = explicit ?? PageTranslateCenter.shared.pick(for: src) else {
            selectionRequest = nil
            selectionTarget = nil
            selectionState = .choose("This text is in \(PageTranslateCenter.name(src)). Pick a language to translate it into.")
            return
        }
        selectionTarget = TranslateLang.base(to) ?? to
        selectionState = .working
        selectionRequest = SelectionRequest(text: String(text.prefix(5000)), source: src, target: selectionTarget ?? to, token: selectionToken)
    }

    /// The popover's "Replace with Translation": only in a text field or an editable area of the page.
    func replaceSelection(with text: String) {
        Task { _ = await js("replace", text: text) }
    }
}
