import XCTest
import Foundation
@testable import Liaison

final class WebAgentCoreTests: XCTestCase {
    func testTheStreamCarriesABrowserTask() {
        let line = #"data: {"type":"browser_task","id":"a1","task":"r:a1","goal":"Find flights Milan-Rome on Friday","tab":"3fa2c1","url":"https://www.google.com/travel/flights"}"#
        XCTAssertEqual(AgentEvent.parse(line: line), .browserTask(task: "r:a1", goal: "Find flights Milan-Rome on Friday", tab: "3fa2c1",
                                                                   url: "https://www.google.com/travel/flights"))
        XCTAssertNil(AgentEvent.parse(line: #"data: {"type":"browser_task","goal":""}"#))
    }

    func testABrowserTaskIsNoBeatForTheAdsOverlay() {
        var run = AgentRun()
        XCTAssertEqual(run.feed(.browserTask(task: "t", goal: "g", tab: "new", url: nil)), [])
    }

    func testActionsReadFromTheModel() {
        XCTAssertEqual(WebAction.from(name: "click", args: ["id": "k3f"]), .click(id: "k3f"))
        XCTAssertEqual(WebAction.from(name: "type", args: ["id": "q", "text": "Roma", "enter": true]), .type(id: "q", text: "Roma", enter: true))
        XCTAssertEqual(WebAction.from(name: "navigate", args: ["url": "booking.com"]), .navigate(URL(string: "https://booking.com")!))
        XCTAssertEqual(WebAction.from(name: "navigate", args: ["url": "javascript:alert(1)"]).described.hasPrefix("invalid"), true)
        XCTAssertEqual(WebAction.from(name: "wait", args: ["seconds": 30.0]), .wait(seconds: 5))
        XCTAssertEqual(WebAction.from(name: "ask", args: ["kind": "human", "question": "Solve the captcha"]), .ask(human: true, question: "Solve the captcha"))
        XCTAssertEqual(WebAction.from(name: "done", args: ["ok": false, "summary": "Sold out"]), .done(ok: false, summary: "Sold out"))
        XCTAssertEqual(WebAction.from(name: "click", args: [:]), .invalid("click without an id"))
        XCTAssertEqual(WebAction.from(name: "fly", args: [:]), .invalid("unknown action fly"))
    }

    func testTheResultIsAMachineReplyTheThreadQuotes() {
        let m = BrowserResult.message(goal: "Flights", ok: true, summary: "ITA 9:05, 39 €", url: "https://x.it", steps: 7)
        XCTAssertTrue(m.hasPrefix("[browser_result] {\"goal\":\"Flights\",\"ok\":true"))
        let q = ModeReply.quote(for: m)
        XCTAssertEqual(q?.question, "Browser \u{00b7} Flights")
        XCTAssertEqual(q?.answer, "Done")
    }

    func testTheContextIsCappedLikeTheServer() {
        let tabs = [BrowserContext.Tab(id: "a", title: "A", url: "https://a.it", active: true, text: String(repeating: "x", count: 50000)),
                    BrowserContext.Tab(id: "b", title: "B", url: "https://b.it", active: false, text: String(repeating: "y", count: 9000)),
                    BrowserContext.Tab(id: "c", title: "New tab", url: "", active: false, text: "")]
        let p = BrowserContext.payload(tabs)
        let list = p["tabs"] as? [[String: Any]] ?? []
        XCTAssertEqual(list.count, 2)
        XCTAssertEqual((list[0]["text"] as? String)?.count, 14000)
        XCTAssertEqual((list[1]["text"] as? String)?.count, 2000)
        XCTAssertEqual((BrowserContext.payload([])["tabs"] as? [[String: Any]])?.count, 0)
        XCTAssertEqual(BrowserContext.payload([])["available"] as? Bool, true)
    }
}

final class PageDiffTests: XCTestCase {
    private func page(_ text: String, _ lines: [String]) -> String { "TEXT:\n" + text + "\n\nCONTROLS:\n" + lines.joined(separator: "\n") }

    func testAChosenDayAndTheFocusThatMoved() {
        let a = page("Flights", ["[d1] text «Departure»", "[d2] text «Return»", "[x23] button «23» in «December»"])
        let b = page("Flights", ["[d1] text «Departure» value «Wed 23 Dec»", "[d2] text «Return» focused", "[x23] button «23» in «December» selected"])
        let s = PageDiff.describe(before: a, after: b)
        XCTAssertTrue(s.contains("changed: [d1] text «Departure» value «Wed 23 Dec»"))
        XCTAssertTrue(s.contains("[x23] button «23» in «December» selected"))
        XCTAssertTrue(s.contains("focus: [d2] text «Return» focused"))
    }

    func testWhatAppearedAndWent() {
        let a = page("x", ["[a] button «Open»", "[b] link «Old»"])
        let b = page("x", ["[a] button «Open» open", "[m1] button «December»", "[m2] button «24»"])
        let s = PageDiff.describe(before: a, after: b)
        XCTAssertTrue(s.contains("appeared 2 («December», «24»)"))
        XCTAssertTrue(s.contains("gone 1"))
    }

    func testAClickThatDidNothingSaysSo() {
        let a = page("Same", ["[a] button «Go»"])
        XCTAssertEqual(PageDiff.describe(before: a, after: a), "nothing on the page changed")
        XCTAssertEqual(PageDiff.describe(before: a, after: page("Other", ["[a] button «Go»"])), "only the page text changed")
    }
}

final class WebBatchTests: XCTestCase {
    func testABatchWithCompositeActions() {
        let step = WebStep.from(kind: "act", actions: [["type": "pick", "id": "d1", "text": "Barcelona", "option": "Barcelona, Spain"],
                                                       ["type": "set_date", "id": "dt", "date": "2026-12-23"],
                                                       ["type": "click", "id": "go"]], args: [:], legacy: nil)
        XCTAssertEqual(step, .act([.pick(id: "d1", text: "Barcelona", option: "Barcelona, Spain"), .setDate(id: "dt", year: 2026, month: 12, day: 23), .click(id: "go")]))
        XCTAssertEqual(WebAction.from(batchItem: ["type": "set_date", "id": "dt", "date": "23.12.2026"]), .invalid("set_date needs YYYY-MM-DD"))
        XCTAssertEqual(WebAction.setDate(id: "dt", year: 2026, month: 12, day: 3).described, "set_date dt 2026-12-03")
    }

    func testTheOtherKindsAndAnOldServer() {
        XCTAssertEqual(WebStep.from(kind: "look", actions: [], args: [:], legacy: nil), .look)
        XCTAssertEqual(WebStep.from(kind: "done", actions: [], args: ["ok": true, "summary": "39 €"], legacy: nil), .done(ok: true, summary: "39 €"))
        XCTAssertEqual(WebStep.from(kind: "", actions: [], args: [:], legacy: ("click", ["id": "a"])), .act([.click(id: "a")]))
        XCTAssertEqual(WebStep.from(kind: "", actions: [], args: [:], legacy: ("ask", ["kind": "human", "question": "Log in"])), .ask(human: true, question: "Log in"))
    }
}

final class WebOptionsTests: XCTestCase {
    func testTheMeantSuggestionWins() {
        let opts = [(ref: 1, text: "Barcelona BLA Venezuela"), (ref: 2, text: "Barcelona BCN Spain"), (ref: 3, text: "Reus REU Spain")]
        XCTAssertEqual(WebOptions.best(opts, for: "Barcelona, Spain")?.ref, 2)
        XCTAssertEqual(WebOptions.best(opts, for: "Barcelona BCN")?.ref, 2)
        XCTAssertEqual(WebOptions.best([(ref: 7, text: "Zürich HB")], for: "zurich")?.ref, 7)
        XCTAssertNil(WebOptions.best(opts, for: "Yerevan"))
    }
}

final class WebOptionsRecentTests: XCTestCase {
    func testARecentSearchDoesNotBeatThePlace() {
        let opts = [(ref: 1, text: "Milan — Barcelona , Dec 23–25"), (ref: 2, text: "Barcelona BCN Spain Spain Check ticket prices")]
        XCTAssertEqual(WebOptions.best(opts, for: "Barcelona, Spain (BCN)")?.ref, 2)
        XCTAssertTrue((WebOptions.bestScored([opts[0]], for: "Barcelona, Spain (BCN)")?.score ?? 0) >= 100)
    }
}

/// Incident (dlg:pncnhjyjam4:team): a search button and a Google result link were held as payments.
final class WebGateTests: XCTestCase {
    private func f(_ tag: String = "button", words: String, type: String = "", role: String = "", href: String = "", submit: Bool = false,
                   formRole: String = "", formAction: String = "", searchInput: Bool = false, card: Bool = false,
                   textarea: Bool = false, email: Bool = false, page: String = "https://example.com/") -> WebGate.Facts {
        var x = WebGate.Facts()
        x.tag = tag; x.words = words; x.type = type; x.role = role; x.href = href; x.hrefAbs = href; x.submit = submit
        x.inForm = submit || card || !formAction.isEmpty; x.formRole = formRole; x.formAction = formAction; x.searchInput = searchInput
        x.card = card; x.textarea = textarea; x.email = email; x.page = page
        return x
    }

    func testWhatNeverWaits() {
        let cases: [(String, WebGate.Facts)] = [
            ("incident: a travel site's search button", f(words: "готово готово. искать билеты туда и обратно с датой вылета 1", submit: true,
                                                          page: "https://www.tutu.ru/poezda/")),
            ("incident: a Google result link with «купить»", f("a", words: "купить билеты на поезд сочи — батуми яндекс путешествия http",
                                                                href: "https://travel.yandex.ru/trains/sochi--batumi/", page: "https://www.google.com/search?q=sochi+batumi")),
            ("a link with Buy now opens the product", f("a", words: "buy now", href: "https://shop.example.com/p/123", page: "https://www.google.com/search?q=x")),
            ("Search", f(words: "search", submit: true)),
            ("Найти", f(words: "найти", submit: true)),
            ("Cerca voli", f(words: "cerca voli", submit: true)),
            ("Show 120 results", f(words: "show 120 results")),
            ("Показать результаты", f(words: "показать результаты")),
            ("an icon button in a role=search form", f(words: "", submit: true, formRole: "search")),
            ("a long button in a form with a search box", f(words: String(repeating: "flights ", count: 12), submit: true, searchInput: true)),
            ("a form that goes to /search", f(words: "go", submit: true, formAction: "/search")),
            ("a filter", f(words: "apply filters")),
            ("next page", f(words: "next")),
            ("Далее", f(words: "далее")),
            ("a buy word in a product card off checkout", f(words: "купить")),
            ("Book on a hotel page", f(words: "book now", page: "https://hotel.example.com/rooms/12")),
            ("Prenota off checkout", f(words: "prenota", page: "https://www.trenitalia.com/it.html")),
            ("a checkbox «Pay at the property»", f("input", words: "pay at the property", type: "checkbox")),
            ("a label of a filter «Pay at the property»", f("label", words: "pay at the property")),
            ("Отправление (departure) is not «отправить»", f(words: "отправление 10:40")),
            ("a long submit without a card or message form", f(words: String(repeating: "word ", count: 20), submit: true)),
        ]
        for (name, x) in cases { XCTAssertEqual(WebGate.reason(x), "", name) }
    }

    func testWhatWaitsForAllow() {
        let cases: [(String, WebGate.Facts)] = [
            ("Pay", f(words: "pay 39,00 €", submit: true, card: true)),
            ("Place order", f(words: "place order", page: "https://shop.example.com/checkout")),
            ("Buy now button", f(words: "buy now")),
            ("Купить in the cart", f(words: "купить", page: "https://shop.example.ru/cart")),
            ("Купить in a card form", f(words: "купить", submit: true, card: true)),
            ("Оплатить", f(words: "оплатить 2 400 ₽")),
            ("Send", f(words: "send")),
            ("Отправить", f(words: "отправить сообщение")),
            ("Invia", f(words: "invia")),
            ("Delete", f(words: "delete")),
            ("Удалить", f(words: "удалить")),
            ("Elimina", f(words: "elimina account")),
            ("Publish", f(words: "publish")),
            ("Confirm booking", f(words: "confirm booking")),
            ("Conferma prenotazione", f(words: "conferma prenotazione")),
            ("Подтвердить on the order page", f(words: "подтвердить", page: "https://travel.example.ru/trains/order/?id=1")),
            ("Continue in a card form", f(words: "continue", submit: true, card: true)),
            ("an icon submit in a form going to /pay", f(words: "", submit: true, formAction: "https://psp.example.com/payment")),
            ("Place order drawn as a link on the cart", f("a", words: "place order", href: "https://shop.example.com/checkout/place", page: "https://shop.example.com/cart")),
            ("a link-button Pay (href #)", f("a", words: "pay", href: "#")),
            ("an icon submit of a message form", f(words: "", submit: true, textarea: true, email: true)),
            ("a search word does not hide a card form", f(words: "find", submit: true, card: true)),
        ]
        for (name, x) in cases { XCTAssertFalse(WebGate.reason(x).isEmpty, name) }
        XCTAssertEqual(WebGate.reason(f(words: "", submit: true, card: true)), "a button without words (in a payment form)")
    }

    func testEnterInAField() {
        let field = f("input", words: "", type: "text")
        XCTAssertEqual(WebGate.enterReason(field: field, submits: [f(words: "search", submit: true)]), "")
        XCTAssertEqual(WebGate.enterReason(field: field, submits: [f(words: "готово готово. искать билеты туда и обратно с датой вылета 1", submit: true)]), "")
        XCTAssertEqual(WebGate.enterReason(field: field, submits: [f(words: "send", submit: true)]), "send")
        var cardField = field; cardField.card = true
        XCTAssertEqual(WebGate.enterReason(field: cardField, submits: []), "Enter (it submits a payment form)")
        XCTAssertEqual(WebGate.enterReason(field: field, submits: []), "")
    }

    func testFactsFromThePage() {
        let x = WebGate.Facts(["tag": "A", "words": "Купить", "href": "https://x.ru/", "submit": false, "card": NSNumber(value: true), "page": "https://g.com/"])
        XCTAssertEqual(x.tag, "a"); XCTAssertEqual(x.words, "купить"); XCTAssertTrue(x.card); XCTAssertTrue(WebGate.navigates(x))
    }

    func testWhatWasFoundSoFar() {
        let snap = "TEXT:\nSochi — Batumi\n  12 Oct  4 500 ₽\n\nCONTROLS:\n[a] button «Buy»"
        XCTAssertEqual(BrowserSoFar.text(steps: 3, title: "Trains", url: "https://t.ru/x", snapshot: snap),
                       "after 3 steps, on «Trains» https://t.ru/x. The page shows: Sochi — Batumi 12 Oct 4 500 ₽")
        XCTAssertEqual(BrowserSoFar.text(steps: 1, title: "", url: "", snapshot: nil), "after 1 step")
    }

    func testAStoppedTaskIsToldToLia() {
        let m = BrowserResult.message(goal: "Tickets", ok: false, summary: "after 2 steps", why: "stopped by the person", steps: 2, silent: true)
        XCTAssertTrue(m.contains("\"why\":\"stopped by the person\""))
        XCTAssertTrue(m.contains("\"silent\":true"))
        XCTAssertFalse(BrowserResult.message(goal: "g", ok: true, summary: "s", steps: 1).contains("silent"))
    }
}

final class WebLimitTests: XCTestCase {
    func testA429IsTheServersWords() {
        let o = JSONRead.object(Data(#"{"ok":false,"error":"weekly_limit","message":"You have used this week's Lia budget. It refills on Monday."}"#.utf8))
        XCTAssertEqual(WebLimit.message(status: 429, json: o), "You have used this week's Lia budget. It refills on Monday.")
        XCTAssertEqual(WebLimit.message(status: 429, json: nil), "Usage limit reached. Try again later.")
        XCTAssertEqual(WebLimit.message(status: 429, json: JSONRead.object(Data(#"{"ok":false,"message":"  "}"#.utf8))), WebLimit.fallback)
        XCTAssertNil(WebLimit.message(status: 200, json: o))
        XCTAssertNil(WebLimit.message(status: 500, json: o))
    }

    func testWhoseCallItIs() {
        XCTAssertEqual(WebLimit.agent("agent-met"), "met")
        XCTAssertEqual(WebLimit.agent("met"), "met")
        XCTAssertEqual(WebLimit.agent("agent-lia"), "lia")
        XCTAssertEqual(WebLimit.agent("agent-dev"), "lia")
        XCTAssertEqual(WebLimit.agent(nil), "lia")
    }
}
