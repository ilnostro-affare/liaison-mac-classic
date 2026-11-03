import XCTest
import Foundation
@testable import Liaison

/// 0.2.11: page and selection translation's pure part (Shared/Core/PageTranslate.swift) - language codes and the
/// offer, whitespace kept around a node's text, dedup and batches, writes back by id, restore, "Always translate",
/// the page's language (declared, read, script), the remembered target, the sweep's plan and the cache.
final class PageTranslateTests: XCTestCase {
    func testBaseCodes() {
        XCTAssertEqual(TranslateLang.base("en-US"), "en")
        XCTAssertEqual(TranslateLang.base("pt_BR"), "pt")
        XCTAssertEqual(TranslateLang.base(" IT "), "it")
        XCTAssertEqual(TranslateLang.base("zh-TW"), "zh-Hant")
        XCTAssertEqual(TranslateLang.base("zh-Hant-HK"), "zh-Hant")
        XCTAssertEqual(TranslateLang.base("zh"), "zh-Hans")
        XCTAssertEqual(TranslateLang.base("zh-CN"), "zh-Hans")
        XCTAssertEqual(TranslateLang.base("iw"), "he")
        XCTAssertEqual(TranslateLang.base("no"), "nb")
        XCTAssertNil(TranslateLang.base(""))
        XCTAssertNil(TranslateLang.base("und"))
        XCTAssertNil(TranslateLang.base("x"))
        XCTAssertNil(TranslateLang.base("{{lang}}"))
        XCTAssertNil(TranslateLang.base(nil))
        XCTAssertTrue(TranslateLang.same("en-GB", "en_US"))
        XCTAssertFalse(TranslateLang.same("zh-TW", "zh-CN"))
    }

    func testPageLanguagePrefersConfidentText() {
        // a template's lang="en" on an Italian page
        XCTAssertEqual(TranslateLang.pageLanguage(htmlLang: "en", detected: "it", confidence: 0.95, sampleLength: 800), "it")
        // little text: the declared one
        XCTAssertEqual(TranslateLang.pageLanguage(htmlLang: "de", detected: "it", confidence: 0.95, sampleLength: 30), "de")
        XCTAssertEqual(TranslateLang.pageLanguage(htmlLang: "", detected: "fr", confidence: 0.6, sampleLength: 40), "fr")
        XCTAssertNil(TranslateLang.pageLanguage(htmlLang: nil, detected: "fr", confidence: 0.3, sampleLength: 400))
        XCTAssertNil(TranslateLang.pageLanguage(htmlLang: nil, detected: nil, confidence: 0, sampleLength: 0))
    }

    func testOffer() {
        XCTAssertTrue(TranslateLang.shouldOffer(page: "it", preferred: ["en-US"]))
        XCTAssertFalse(TranslateLang.shouldOffer(page: "it", preferred: ["en-US", "it-IT"]))
        XCTAssertFalse(TranslateLang.shouldOffer(page: "en", preferred: ["en-GB"]))
        XCTAssertFalse(TranslateLang.shouldOffer(page: nil, preferred: ["en"]))
        XCTAssertTrue(TranslateLang.shouldOffer(page: "zh-Hant", preferred: ["zh-Hans-CN"]))
        XCTAssertEqual(TranslateLang.defaultTarget(preferred: ["ru-RU", "en"]), "ru")
        XCTAssertEqual(TranslateLang.defaultTarget(preferred: []), "en")
    }

    func testLanguageDetectionPrefersDeclaredAndScript() {
        // A Russian page read as Kazakh. The declared language wins when its script is the text's.
        XCTAssertEqual(TranslateLang.pageLanguage(htmlLang: "ru", detected: "kk", confidence: 0.9, sampleLength: 900, script: .cyrillic), "ru")
        // Kazakh is not something Apple translates: never the answer, the script says Russian
        XCTAssertEqual(TranslateLang.pageLanguage(htmlLang: nil, detected: "kk", confidence: 0.9, sampleLength: 900, script: .cyrillic), "ru")
        // lang="en" left on a Cyrillic page: the declared one is ignored, the text is read
        XCTAssertEqual(TranslateLang.pageLanguage(htmlLang: "en", detected: "uk", confidence: 0.8, sampleLength: 900, script: .cyrillic), "uk")
        // an answer whose script is not the text's is not taken
        XCTAssertEqual(TranslateLang.pageLanguage(htmlLang: nil, detected: "en", confidence: 0.99, sampleLength: 900, script: .cyrillic), "ru")
        // not sure, Latin text, nothing declared: no idea
        XCTAssertNil(TranslateLang.pageLanguage(htmlLang: nil, detected: "it", confidence: 0.4, sampleLength: 900, script: .latin))
        // declared Italian, the recognizer only fairly sure of Spanish: Italian
        XCTAssertEqual(TranslateLang.pageLanguage(htmlLang: "it", detected: "es", confidence: 0.9, sampleLength: 900, script: .latin), "it")
        XCTAssertEqual(TranslateLang.pageLanguage(htmlLang: "ja", detected: nil, confidence: 0, sampleLength: 900, script: .han), "ja")
    }

    func testDominantScript() {
        XCTAssertEqual(TranslateLang.dominantScript("Привет, как дела? Это страница на русском языке."), .cyrillic)
        XCTAssertEqual(TranslateLang.dominantScript("Hello, this page is written in English."), .latin)
        XCTAssertEqual(TranslateLang.dominantScript("東京は日本の首都です。ひらがなもあります。"), .kana)
        XCTAssertEqual(TranslateLang.dominantScript("这是一个中文网页的例子文本内容"), .han)
        XCTAssertNil(TranslateLang.dominantScript("12 34"))
        XCTAssertTrue(TranslateLang.fits("ja", script: .han))
        XCTAssertFalse(TranslateLang.fits("zh-Hans", script: .kana))
        XCTAssertTrue(TranslateLang.fits("ru", script: nil))
    }

    func testHintsFavourThePersonsLanguages() {
        let h = TranslateLang.hints(preferred: ["ru-RU", "en"], supported: ["ru", "en", "uk", "de"])
        XCTAssertTrue(abs(h["ru"]! - 2.0 / 6) < 1e-9)
        XCTAssertTrue(abs(h["uk"]! - 1.0 / 6) < 1e-9)
        XCTAssertTrue(abs(h.values.reduce(0, +) - 1) < 1e-9)
        XCTAssertNil(h["kk"])
        XCTAssertTrue(TranslateLang.hints(preferred: ["en"], supported: []).isEmpty)
    }

    func testRememberedTarget() {
        XCTAssertEqual(TranslateLang.target(stored: "ru", preferred: ["es-ES"]), "ru")
        XCTAssertEqual(TranslateLang.target(stored: nil, preferred: ["ru-RU", "en"]), "ru")
        XCTAssertEqual(TranslateLang.target(stored: "", preferred: []), "en")
    }

    func testPageAndSelectionTargetsAreSeparate() {
        // No page target yet: the page asks (nil), whatever the selection picked.
        XCTAssertNil(TranslateLang.pageTarget(source: "it", stored: nil))
        XCTAssertNil(TranslateLang.pageTarget(source: "it", stored: ""))
        XCTAssertEqual(TranslateLang.pageTarget(source: "it", stored: "ru-RU"), "ru")
        // The selection: its own pick, else the page's, else the first language.
        XCTAssertEqual(TranslateLang.selectionTarget(stored: "de", page: "ru", preferred: ["en"]), "de")
        XCTAssertEqual(TranslateLang.selectionTarget(stored: nil, page: "ru", preferred: ["en"]), "ru")
        XCTAssertEqual(TranslateLang.selectionTarget(stored: nil, page: nil, preferred: ["it-IT"]), "it")
        XCTAssertEqual(TranslateLang.order(first: nil, second: "ru", recent: ["de", "ru"]), ["ru", "de"])
        XCTAssertEqual(TranslateLang.order(first: "en", second: "ru-RU", recent: ["ru", "it", "en"]), ["en", "ru", "it"])
        // A selection with no pick of its own goes into the page's target.
        XCTAssertEqual(TranslateLang.pick(source: "it", recent: TranslateLang.order(first: nil, second: "ru", recent: ["de"]),
                                          preferred: ["en"]), "ru")
    }

    func testPickNeverDeadEndsOnTheSourceLanguage() {
        // English text, remembered English: the newest other pick, else the next preferred language.
        XCTAssertEqual(TranslateLang.pick(source: "en", recent: ["en", "ru"], preferred: ["en-US"]), "ru")
        XCTAssertEqual(TranslateLang.pick(source: "en", recent: ["en"], preferred: ["en-US", "it-IT"]), "it")
        XCTAssertNil(TranslateLang.pick(source: "en", recent: ["en"], preferred: ["en-GB"]))
        XCTAssertEqual(TranslateLang.pick(source: "it", recent: ["en"], preferred: ["it"]), "en")
        XCTAssertEqual(TranslateLang.pick(source: nil, recent: [], preferred: ["de-DE"]), "de")
        XCTAssertEqual(TranslateLang.pick(source: "en", recent: ["kk", "en"], preferred: ["ru"], supported: ["en", "ru"]), "ru")
        XCTAssertNil(TranslateLang.pageTarget(source: "en-US", stored: "en"))
        XCTAssertEqual(TranslateLang.pageTarget(source: "ru", stored: "en"), "en")
        XCTAssertEqual(TranslateLang.pageTarget(source: nil, stored: "en"), "en")
        XCTAssertEqual(TranslateLang.remember("ru-RU", in: ["en", "ru", "it"]), ["ru", "en", "it"])
        XCTAssertEqual(TranslateLang.remember("de", in: ["a1", "en"], cap: 2), ["de", "en"])
    }

    func testVisibleFirstPlanAndReprioritise() {
        let items = (0..<300).map { TranslateBatcher.Unique(text: "t\($0)", ids: [$0]) }
        XCTAssertEqual(TranslateBatcher.plan(items, visible: 100).map(\.count), [16, 40, 40, 4, 200])
        XCTAssertEqual(TranslateBatcher.plan(items, visible: 0).map(\.count), [40, 200, 60])
        XCTAssertEqual(TranslateBatcher.plan(Array(items.prefix(10)), visible: 50).map(\.count), [10])
        let nodes = (0..<6).map { TranslateNode(id: $0, text: "n\($0)") }
        let u = [TranslateBatcher.Unique(text: "a", ids: [4]), TranslateBatcher.Unique(text: "b", ids: [0, 5]),
                 TranslateBatcher.Unique(text: "c", ids: [3])]
        let sf = TranslateBatcher.screenFirst(u, nodes: nodes, visibleNodes: 2)
        XCTAssertEqual(sf.items.map(\.text), ["b", "a", "c"])
        XCTAssertEqual(sf.visible, 1)
        let rest = TranslateBatcher.batches(items, maxItems: 200)
        let re = TranslateBatcher.reprioritised(rest, onScreen: [250, 251])
        XCTAssertEqual(re.first?.map(\.text), ["t250", "t251"])
        XCTAssertEqual(re.flatMap { $0 }.count, 300)
        XCTAssertEqual(TranslateBatcher.reprioritised(rest, onScreen: []).map(\.count), [200, 100])
    }

    func testPlanSendsTheScreenFirstAndCaches() {
        let items = (0..<300).map { TranslateBatcher.Unique(text: "t\($0)", ids: [$0]) }
        XCTAssertEqual(TranslateBatcher.plan(items).map(\.count), [40, 200, 60])
        XCTAssertEqual(TranslateBatcher.plan(Array(items.prefix(30))).map(\.count), [30])
        XCTAssertTrue(TranslateBatcher.shouldFlush(pending: 40, sinceMs: 0))
        XCTAssertTrue(TranslateBatcher.shouldFlush(pending: 1, sinceMs: 200))
        XCTAssertFalse(TranslateBatcher.shouldFlush(pending: 5, sinceMs: 10))
        XCTAssertFalse(TranslateBatcher.shouldFlush(pending: 0, sinceMs: 999))
        var c = TranslateCache(cap: 2)
        c.put(source: "it-IT", target: "en", text: "Ciao", "Hi")
        XCTAssertEqual(c.get(source: "it", target: "en-US", text: "Ciao"), "Hi")
        XCTAssertNil(c.get(source: "it", target: "ru", text: "Ciao"))
        c.put(source: "it", target: "en", text: "A", "a")
        c.put(source: "it", target: "en", text: "B", "b")
        XCTAssertNil(c.get(source: "it", target: "en", text: "Ciao"))
        XCTAssertEqual(c.count, 2)
    }

    func testWhitespaceKept() {
        let p = TextPiece("  Prezzo\n")
        XCTAssertEqual(p.lead, "  ")
        XCTAssertEqual(p.core, "Prezzo")
        XCTAssertEqual(p.trail, "\n")
        XCTAssertEqual(p.joined(" Price "), "  Price\n")
        XCTAssertEqual(TextPiece("\u{00A0}Ciao").core, "Ciao")
        XCTAssertEqual(TextPiece("   ").core, "")
        XCTAssertEqual(TextPiece("Ciao").joined("Hi"), "Hi")
    }

    func testTranslatable() {
        XCTAssertTrue(TextPiece("Accedi").isTranslatable)
        XCTAssertTrue(TextPiece("中").isTranslatable)
        XCTAssertFalse(TextPiece("  ").isTranslatable)
        XCTAssertFalse(TextPiece("12,50 €").isTranslatable)
        XCTAssertFalse(TextPiece("·").isTranslatable)
        XCTAssertFalse(TextPiece("x").isTranslatable)
        XCTAssertFalse(TextPiece("https://example.com/a").isTranslatable)
        XCTAssertFalse(TextPiece("info@example.it").isTranslatable)
        XCTAssertTrue(TextPiece("Scrivi a info@example.it oggi").isTranslatable)
    }

    func testUniqueDedupsAndSkipsKnown() {
        let nodes = [TranslateNode(id: 1, text: " Accedi "), TranslateNode(id: 2, text: "Carrello"),
                     TranslateNode(id: 3, text: "Accedi"), TranslateNode(id: 4, text: "42"), TranslateNode(id: 5, text: "Esci")]
        let u = TranslateBatcher.unique(nodes, skipping: ["Esci"])
        XCTAssertEqual(u, [.init(text: "Accedi", ids: [1, 3]), .init(text: "Carrello", ids: [2])])
    }

    func testBatches() {
        let items = (0..<10).map { TranslateBatcher.Unique(text: String(repeating: "a", count: 10), ids: [$0]) }
        XCTAssertEqual(TranslateBatcher.batches(items, maxItems: 4, maxChars: 1000).map(\.count), [4, 4, 2])
        XCTAssertEqual(TranslateBatcher.batches(items, maxItems: 100, maxChars: 25).map(\.count), [2, 2, 2, 2, 2])
        let long = [TranslateBatcher.Unique(text: String(repeating: "b", count: 50), ids: [0])] + items.prefix(1)
        XCTAssertEqual(TranslateBatcher.batches(Array(long), maxItems: 10, maxChars: 20).map(\.count), [1, 1])
        XCTAssertTrue(TranslateBatcher.batches([]).isEmpty)
    }

    func testWritesKeepWhitespaceAndSkipMissing() {
        let nodes = [TranslateNode(id: 1, text: " Accedi\n"), TranslateNode(id: 2, text: "Carrello"), TranslateNode(id: 3, text: "Same")]
        let w = TranslateBatcher.writes(nodes, translated: ["Accedi": "Sign in", "Same": "Same", "Carrello": "  "])
        XCTAssertEqual(w.map(\.id), [1])
        XCTAssertEqual(w.first?.text, " Sign in\n")
    }

    func testMemoIsBounded() {
        var m = TranslationMemo(cap: 2)
        m.add("a", "A"); m.add("b", "B"); m.add("a", "AA"); m.add("c", "C")
        XCTAssertNil(m["a"])
        XCTAssertEqual(m["b"], "B")
        XCTAssertEqual(m["c"], "C")
        XCTAssertEqual(m.keys, ["b", "c"])
        m.removeAll()
        XCTAssertEqual(m.count, 0)
    }

    func testOriginalsFirstWinsUnlessPageChanged() {
        var o = TranslateOriginals()
        o.record(2, original: "Ciao")
        o.record(1, original: "Uno")
        o.record(2, original: "Hello")          // our own translation, seen again: not an original
        XCTAssertEqual(o.restores().map(\.id), [1, 2])
        XCTAssertEqual(o.restores().last?.text, "Ciao")
        o.pageChanged(2, to: "Salve")
        XCTAssertEqual(o.restores().last?.text, "Salve")
        o.removeAll()
        XCTAssertTrue(o.isEmpty)
    }

    func testAlwaysTranslate() {
        var a = AlwaysTranslate()
        a.set(host: "www.Corriere.it", language: "it-IT", on: true)
        XCTAssertTrue(a.contains(host: "corriere.it", language: "it"))
        XCTAssertFalse(a.contains(host: "corriere.it", language: "fr"))
        XCTAssertFalse(a.contains(host: "repubblica.it", language: "it"))
        a.set(host: "corriere.it", language: "it", on: true)
        XCTAssertEqual(a.hosts["corriere.it"], ["it"])
        a.set(host: "corriere.it", language: "it", on: false)
        XCTAssertTrue(a.hosts.isEmpty)
        XCTAssertEqual(AlwaysTranslate(["x.it": ["it"]]).contains(host: "www.x.it", language: "it"), true)
    }

    func testPhase() {
        XCTAssertTrue(TranslatePhase.on.isActive)
        XCTAssertTrue(TranslatePhase.translating(done: 1, total: 3).isActive)
        XCTAssertFalse(TranslatePhase.off.isActive)
        XCTAssertFalse(TranslatePhase.failed("x").isActive)
    }

    func testGeometry() {
        let r = TranslateGeometry.viewRect(x: 10, y: 20, w: 100, h: 0, zoom: 0.75)
        XCTAssertEqual(r, CGRect(x: 7.5, y: 15, width: 75, height: 1))
        let b = CGSize(width: 800, height: 600)
        XCTAssertFalse(TranslateGeometry.visible(CGRect(x: 0, y: -50, width: 10, height: 20), in: b))
        XCTAssertTrue(TranslateGeometry.visible(CGRect(x: 0, y: 5, width: 10, height: 20), in: b))
    }
}
