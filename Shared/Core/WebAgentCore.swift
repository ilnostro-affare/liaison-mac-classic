import Foundation

// The open web (server): what WebAgent sends for each step and what comes back. Pure, so it is tested on Linux.

/// One action the browse-step model chose (the server).
enum WebAction: Equatable {
    case click(id: String)
    case type(id: String, text: String, enter: Bool)
    case select(id: String, option: String)
    case scroll(down: Bool)
    case navigate(URL)
    case back
    case wait(seconds: Double)
    /// `human`: a login, a captcha or a block the person handles; otherwise a step that pays, books or sends.
    case ask(human: Bool, question: String)
    case done(ok: Bool, summary: String)
    /// Composite actions: a field with suggestions (type, wait, choose, check) and a date (open, reach, choose).
    case pick(id: String, text: String, option: String)
    case setDate(id: String, year: Int, month: Int, day: Int)
    /// The page's whole text next step.
    case read
    case invalid(String)

    /// One action of a batch (`act`): `{type, id, text, option, date, enter, direction, url, seconds}`.
    static func from(batchItem o: JSONObject) -> WebAction {
        let type = JSONRead.string(o, "type") ?? ""
        switch type {
        case "pick":
            let id = (JSONRead.string(o, "id") ?? "").trimmingCharacters(in: .whitespaces)
            let text = JSONRead.string(o, "text") ?? "", option = JSONRead.string(o, "option") ?? ""
            guard !id.isEmpty else { return .invalid("pick without an id") }
            return .pick(id: id, text: text.isEmpty ? option : text, option: option.isEmpty ? text : option)
        case "set_date":
            let id = (JSONRead.string(o, "id") ?? "").trimmingCharacters(in: .whitespaces)
            let parts = (JSONRead.string(o, "date") ?? "").split(separator: "-").compactMap { Int($0) }
            guard !id.isEmpty else { return .invalid("set_date without an id") }
            guard parts.count == 3, (1...12).contains(parts[1]), (1...31).contains(parts[2]) else { return .invalid("set_date needs YYYY-MM-DD") }
            return .setDate(id: id, year: parts[0], month: parts[1], day: parts[2])
        case "read": return .read
        default: return from(name: type, args: o)
        }
    }

    static func from(name: String, args: JSONObject) -> WebAction {
        let id = (JSONRead.string(args, "id") ?? "").trimmingCharacters(in: .whitespaces)
        switch name {
        case "click": return id.isEmpty ? .invalid("click without an id") : .click(id: id)
        case "type":
            return id.isEmpty ? .invalid("type without an id")
                : .type(id: id, text: JSONRead.string(args, "text") ?? "", enter: JSONRead.bool(args, "enter"))
        case "select":
            return id.isEmpty ? .invalid("select without an id") : .select(id: id, option: JSONRead.string(args, "option") ?? "")
        case "scroll": return .scroll(down: (JSONRead.string(args, "direction") ?? "down") != "up")
        case "navigate":
            var raw = (JSONRead.string(args, "url") ?? "").trimmingCharacters(in: .whitespaces)
            // Another scheme (javascript:, file:, data:) is never opened; a bare host gets https.
            if raw.range(of: "^[A-Za-z][A-Za-z0-9+.-]*:", options: .regularExpression) != nil,
               !raw.lowercased().hasPrefix("http://"), !raw.lowercased().hasPrefix("https://") { return .invalid("not a web address: \(raw)") }
            if !raw.isEmpty, !raw.lowercased().hasPrefix("http") { raw = "https://" + raw }
            guard let u = URL(string: raw), let scheme = u.scheme?.lowercased(), scheme == "https" || scheme == "http", u.host != nil
            else { return .invalid("not a web address: \(raw)") }
            return .navigate(u)
        case "back": return .back
        case "wait": return .wait(seconds: min(5, max(0.5, JSONRead.double(args, "seconds") ?? 1)))
        case "ask":
            return .ask(human: (JSONRead.string(args, "kind") ?? "confirm") == "human", question: JSONRead.string(args, "question") ?? "")
        case "done": return .done(ok: (args["ok"] as? Bool) ?? true, summary: JSONRead.string(args, "summary") ?? "")
        default: return .invalid("unknown action \(name)")
        }
    }

    /// How the step is written back to the model (append-only, so the cached prefix holds).
    var described: String {
        switch self {
        case .click(let id): return "click \(id)"
        case let .type(id, text, enter): return "type \(id) «\(text.count > 80 ? String(text.prefix(80)) + "…" : text)»" + (enter ? " + Enter" : "")
        case let .select(id, option): return "select \(id) «\(option)»"
        case .scroll(let down): return "scroll " + (down ? "down" : "up")
        case .navigate(let u): return "navigate \(u.absoluteString)"
        case .back: return "back"
        case .wait(let s): return "wait \(s)s"
        case let .ask(human, q): return (human ? "hand over: " : "confirm: ") + q
        case let .done(ok, _): return ok ? "done" : "gave up"
        case let .pick(id, text, option): return "pick \(id) «\(text)»" + (option != text ? " → «\(option)»" : "")
        case let .setDate(id, y, m, d): return "set_date \(id) " + String(format: "%04d-%02d-%02d", y, m, d)
        case .read: return "read"
        case .invalid(let why): return "invalid (\(why))"
        }
    }

    /// The words on the cursor's tag while it does this (English UI, like the rest of the overlay).
    var caption: String {
        switch self {
        case .click: return "Click"
        case .type(_, let text, _): return text.count > 28 ? String(text.prefix(28)) + "…" : text
        case .select(_, let o): return o
        case .scroll: return "Scroll"
        case .navigate(let u): return u.host ?? "Open"
        case .back: return "Back"
        case .wait: return "Waiting"
        case .ask: return "Your turn"
        case .done: return "Done"
        case .pick(_, _, let o): return o
        case let .setDate(_, _, m, d): return "\(d).\(m)"
        case .read: return "Reading"
        case .invalid: return ""
        }
    }
}

/// What goes back to the chat when a browser task ends, as a machine reply Lia reads as one line (server
/// lia20BrowserLine) and the thread shows as a small quote.
enum BrowserResult {
    static let tag = "[browser_result]"

    /// `silent`: the person ended the task themselves (Stop): it is recorded in the dialogue so Lia knows, and a server
    /// that reads the flag stores it without asking her to answer (after a Stop she must not start it again).
    static func message(goal: String, ok: Bool, summary: String, why: String? = nil, url: String? = nil, steps: Int, silent: Bool = false) -> String {
        var pairs: [(String, Any)] = [("goal", String(goal.prefix(300))), ("ok", ok), ("summary", String(summary.prefix(3000)))]
        if let why, !why.isEmpty { pairs.append(("why", String(why.prefix(300)))) }
        if let url, !url.isEmpty { pairs.append(("url", String(url.prefix(300)))) }
        pairs.append(("steps", steps))
        if silent { pairs.append(("silent", true)) }
        return tag + " " + OrderedJSON.object(pairs)
    }
}

/// The chat's browser as Lia sees it with a message (server lia20Browser): each tab's id, title, address, and a text
/// snapshot - the front tab's whole page, the others a short head. Capped here as on the server.
enum BrowserContext {
    struct Tab { let id: String; let title: String; let url: String; let active: Bool; let text: String }

    /// Always says a browser is there (`available`): a chat with no tabs yet can still be asked to open a site
    /// (chat cd62ca5ys: "open Aviasales" in a new chat got "I cannot open it").
    static func payload(_ tabs: [Tab]) -> [String: Any] {
        let kept = tabs.filter { !$0.url.isEmpty }.prefix(12)
        var room = 30000
        let list: [[String: Any]] = kept.map { t in
            let cap = max(0, min(t.active ? 14000 : 2000, room))
            let text = String(t.text.prefix(cap))
            room -= text.count
            return ["id": t.id, "title": String(t.title.prefix(160)), "url": String(t.url.prefix(400)), "active": t.active, "text": text]
        }
        return ["tabs": list, "available": true]
    }
}

/// What an action changed on the page, from the snapshot before it and the one after (the model
/// only heard "ok" and could not tell a click that worked from one that did nothing, or which of two look-alike
/// fields it was typing into). Generic: values, chosen / focused / open state, controls that appeared or went.
enum PageDiff {
    static func controls(_ snapshot: String) -> [(id: String, line: String)] {
        guard let r = snapshot.range(of: "CONTROLS:\n") else { return [] }
        return snapshot[r.upperBound...].split(separator: "\n").compactMap { l in
            guard l.hasPrefix("["), let end = l.firstIndex(of: "]") else { return nil }
            return (String(l[l.index(after: l.startIndex)..<end]), String(l))
        }
    }

    private static func text(_ snapshot: String) -> Substring {
        guard let r = snapshot.range(of: "TEXT:\n") else { return "" }
        let rest = snapshot[r.upperBound...]
        return rest.range(of: "\n\nCONTROLS:\n").map { rest[..<$0.lowerBound] } ?? rest
    }

    private static func name(_ line: String) -> String {
        guard let a = line.range(of: "«"), let b = line.range(of: "»", range: a.upperBound..<line.endIndex) else { return "" }
        return String(line[a.upperBound..<b.lowerBound])
    }

    static func describe(before: String, after: String) -> String {
        let old = controls(before), new = controls(after)
        var oldBy: [String: String] = [:]; for c in old { oldBy[c.id] = c.line }
        let newIds = Set(new.map(\.id))
        var parts: [String] = []
        let changed = new.filter { c in oldBy[c.id].map { $0 != c.line } ?? false }
        if !changed.isEmpty {
            parts.append("changed: " + changed.prefix(6).map { $0.line.count > 140 ? String($0.line.prefix(140)) + "…" : $0.line }.joined(separator: "; ")
                         + (changed.count > 6 ? "; +\(changed.count - 6) more" : ""))
        }
        let appeared = new.filter { oldBy[$0.id] == nil }
        if !appeared.isEmpty {
            let names = appeared.map { name($0.line) }.filter { !$0.isEmpty }.prefix(6).map { "«\($0)»" }
            parts.append("appeared \(appeared.count)" + (names.isEmpty ? "" : " (" + names.joined(separator: ", ") + ")"))
        }
        let gone = old.filter { !newIds.contains($0.id) }.count
        if gone > 0 { parts.append("gone \(gone)") }
        if let f = new.first(where: { $0.line.contains(" focused") }) { parts.append("focus: " + (f.line.count > 100 ? String(f.line.prefix(100)) + "…" : f.line)) }
        if parts.isEmpty || (parts.count == 1 && parts[0].hasPrefix("focus:")) {
            parts.insert(text(before) == text(after) ? "nothing on the page changed" : "only the page text changed", at: 0)
        }
        let s = parts.joined(separator: " | ")
        return s.count > 900 ? String(s.prefix(900)) + "…" : s
    }
}

/// What one browse-step call answered (server): a batch to run, a picture to take, a question, or the end.
enum WebStep: Equatable {
    case act([WebAction])
    case look
    case ask(human: Bool, question: String)
    case done(ok: Bool, summary: String)

    static func from(kind: String, actions: [JSONObject], args: JSONObject, legacy: (name: String, args: JSONObject)?) -> WebStep {
        switch kind {
        case "act":
            let list = actions.prefix(5).map { WebAction.from(batchItem: $0) }
            return .act(list.isEmpty ? [.invalid("an empty batch")] : Array(list))
        case "look": return .look
        case "ask": return .ask(human: (JSONRead.string(args, "kind") ?? "confirm") == "human", question: JSONRead.string(args, "question") ?? "")
        case "done": return .done(ok: (args["ok"] as? Bool) ?? true, summary: JSONRead.string(args, "summary") ?? "")
        default:
            // a server from: one action
            guard let legacy else { return .act([.invalid("no action")]) }
            switch WebAction.from(name: legacy.name, args: legacy.args) {
            case let .ask(h, q): return .ask(human: h, question: q)
            case let .done(ok, s): return .done(ok: ok, summary: s)
            case let a: return .act([a])
            }
        }
    }
}

/// The suggestion that best matches what the model named (pick): the same words first, then one that starts
/// with them, then one that contains them, then the reverse, then one with its first word.
enum WebOptions {
    static func norm(_ s: String) -> String {
        s.lowercased().folding(options: .diacriticInsensitive, locale: nil).split(whereSeparator: { !$0.isLetter && !$0.isNumber }).joined(separator: " ")
    }

    static func best(_ opts: [(ref: Int, text: String)], for wanted: String) -> (ref: Int, text: String)? {
        bestScored(opts, for: wanted)?.option
    }

    /// The best suggestion and how good the match is: below 100 the option starts with or contains what was meant;
    /// 100 and above only shares words with it (a recent search "Milan — Barcelona, Dec 23" for "Barcelona, Spain") -
    /// worth taking only when nothing better appears.
    static func bestScored(_ opts: [(ref: Int, text: String)], for wanted: String) -> (option: (ref: Int, text: String), score: Int)? {
        let w = norm(wanted)
        guard !w.isEmpty else { return opts.first.map { ($0, 0) } }
        let scored = opts.compactMap { o -> (Int, (ref: Int, text: String))? in
            let t = norm(o.text)
            if t == w { return (0, o) }
            if t.hasPrefix(w) { return (1, o) }
            if t.contains(w) { return (2, o) }
            if !t.isEmpty && w.contains(t) { return (3, o) }
            // the most of the wanted words, the first one among them ("Barcelona, Spain" -> "Barcelona BCN Spain")
            let words = w.split(separator: " ").map(String.init), tw = t.split(separator: " ").map(String.init), have = Set(tw)
            guard let first = words.first, have.contains(first) else { return nil }
            // an option that starts with the place meant beats one where it sits in the middle ("Milan — Barcelona")
            return ((tw.first == first ? 100 : 110) + words.count - words.filter { have.contains($0) }.count, o)
        }
        return scored.min { $0.0 < $1.0 }.map { ($0.1, $0.0) }
    }
}

/// Which press waits for the person's Allow (incident, chat dlg:pncnhjyjam4:team: a travel site's search
/// button «search round-trip tickets» and a Google result link «buy train tickets …» (both in Russian) were held as payments,
/// the task sat 5.6 minutes and was stopped). A gate only for a press that COMMITS something: pays, places or confirms
/// an order or a booking, sends a message or a form to someone, deletes, publishes, signs. Never for a link that
/// navigates, a search, a filter, a page of results, or "buy" in the words of a link. The page gives the facts
/// (AgentBridge factsOf); the decision is here, pure, so it is tested on Linux.
enum WebGate {
    /// What the page says about the control about to be pressed and its form.
    struct Facts: Equatable {
        /// button, a, input, or another tag (a div with role=button).
        var tag = "button"
        var role = ""
        /// The type attribute (submit, button, image, search...).
        var type = ""
        /// A text field or a select: focusing one presses nothing (Enter is checked on its own).
        var field = false
        /// The control's own words, lowercased (text, value, aria-label, title, alt).
        var words = ""
        /// An <a>'s href as written, and resolved.
        var href = ""
        var hrefAbs = ""
        /// A submit button of a form (a <button> without type, type=submit, input submit/image).
        var submit = false
        var inForm = false
        var formRole = ""
        var formAction = ""
        /// Under an element with role=search.
        var inSearch = false
        /// The form has a search box (type=search, or a field named q / query / search).
        var searchInput = false
        /// The form has a card, CVC or IBAN field, or a payment provider's frame.
        var card = false
        var password = false
        /// The form has a textarea or an email field (a message to someone).
        var textarea = false
        var email = false
        /// The page's address.
        var page = ""

        init() {}

        init(_ o: [String: Any]) {
            func s(_ k: String) -> String { (o[k] as? String) ?? "" }
            func b(_ k: String) -> Bool { (o[k] as? Bool) ?? ((o[k] as? NSNumber)?.boolValue ?? false) }
            tag = s("tag").lowercased(); role = s("role").lowercased(); type = s("type").lowercased(); field = b("field")
            words = s("words").lowercased(); href = s("href"); hrefAbs = s("hrefAbs"); submit = b("submit"); inForm = b("inForm")
            formRole = s("formRole").lowercased(); formAction = s("formAction"); inSearch = b("inSearch"); searchInput = b("searchInput")
            card = b("card"); password = b("pw"); textarea = b("textarea"); email = b("email"); page = s("page")
        }
    }

    // MARK: words (en, ru, it; the common es / de / fr ones too)

    /// A press that commits whatever page it is on (a button, not a link).
    private static let commitWords = [
        "pay", "pay now", "place order", "place your order", "buy now", "complete purchase", "complete order", "complete booking",
        "complete payment", "confirm booking", "confirm reservation", "confirm order", "confirm purchase", "confirm payment",
        "confirm and pay", "book and pay", "send", "send message", "submit", "delete", "publish", "post", "sign contract",
        "sign agreement", "sign and submit", "transfer money", "send money", "donate", "subscribe",
        "оплатить", "заплатить", "отправить", "отправь", "удалить", "удали", "опубликовать", "оформить заказ", "подтвердить заказ",
        "подтвердить бронирование", "подтвердить оплату", "купить сейчас", "подписать", "подписаться", "пожертвовать", "перевести деньги",
        "paga", "paga ora", "pagare", "invia", "elimina", "pubblica", "conferma ordine", "conferma l'ordine", "conferma prenotazione",
        "conferma la prenotazione", "conferma pagamento", "conferma e paga", "acquista ora", "compra ora", "completa l'acquisto",
        "completa acquisto", "firma", "iscriviti", "dona",
        "pagar", "enviar", "eliminar", "bezahlen", "jetzt kaufen", "zahlungspflichtig bestellen", "senden", "löschen", "payer",
        "envoyer", "supprimer", "acheter maintenant",
    ]
    /// A press that commits only where money is taken: a checkout, a cart, a payment form.
    private static let checkoutWords = [
        "buy", "purchase", "order", "order now", "book", "book now", "reserve", "confirm", "checkout", "check out", "continue to payment",
        "купить", "заказать", "забронировать", "бронировать", "подтвердить", "оформить", "acquista", "compra", "ordina", "prenota",
        "conferma", "reservar", "comprar", "buchen", "bestellen", "kaufen", "réserver", "acheter", "commander",
    ]
    /// A press that looks something up or moves between pages of results: never a gate (unless a card form holds it).
    private static let searchWords = [
        "search", "find", "look up", "show results", "show", "see results", "filter", "filters", "apply filters", "sort", "next",
        "previous", "more results", "load more", "show more", "view", "details",
        "искать", "найти", "поиск", "показать", "найдите", "ищите", "фильтр", "фильтры", "применить", "сортировать", "далее", "ещё", "еще",
        "подробнее", "смотреть",
        "cerca", "ricerca", "trova", "mostra", "filtra", "filtri", "ordina per", "avanti", "altri risultati", "dettagli",
        "buscar", "suchen", "finden", "rechercher", "chercher",
    ]

    private static func pattern(_ words: [String]) -> String {
        let alts = words.sorted { $0.count > $1.count }.map { NSRegularExpression.escapedPattern(for: $0) }.joined(separator: "|")
        return "(?<![\\p{L}\\p{N}])(" + alts + ")(?![\\p{L}\\p{N}])"
    }
    private static let commitRx = pattern(commitWords)
    private static let checkoutRx = pattern(checkoutWords)
    private static let searchRx = pattern(searchWords)

    private static func has(_ rx: String, _ s: String) -> Bool { !s.isEmpty && s.range(of: rx, options: .regularExpression) != nil }

    /// Where money is taken: an address (host + path, not the query) or a form action with these in it.
    static func checkoutPlace(_ address: String) -> Bool {
        guard !address.isEmpty else { return false }
        var s = address.lowercased()
        if let u = URL(string: address), let h = u.host?.lowercased() { s = h + u.path.lowercased() }
        return s.range(of: #"(checkout|/cart|basket|/pay(/|$|ment)|^pay\.|payment|billing|purchase|/order|place-?order|booking/confirm|/confirm|корзин|оформлени|оплат|carrello|pagamento|cassa)"#,
                       options: .regularExpression) != nil
    }

    /// A real link: it goes to another address (not "#", not javascript:, not a button dressed as a link).
    static func navigates(_ f: Facts) -> Bool {
        guard f.tag == "a", f.role != "button" else { return false }
        let h = f.href.trimmingCharacters(in: .whitespaces).lowercased()
        if h.isEmpty || h.hasPrefix("#") || h.hasPrefix("javascript:") { return false }
        return true
    }

    /// Ticking a box, choosing a tab or an option commits nothing.
    static func choosing(_ f: Facts) -> Bool {
        if f.field { return true }
        if f.tag == "input", ["checkbox", "radio", "search", "text", "range"].contains(f.type) { return true }
        return ["checkbox", "radio", "switch", "option", "tab", "menuitemcheckbox", "menuitemradio", "combobox", "listbox", "textbox", "searchbox"].contains(f.role)
    }

    /// The words to show the person when this press waits for their Allow; "" when it goes ahead.
    static func reason(_ f: Facts) -> String {
        if choosing(f) { return "" }
        let words = f.words.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        let shown = String(words.prefix(60))
        let cardForm = f.card || checkoutPlace(f.formAction)
        let moneyPlace = cardForm || checkoutPlace(f.page)
        // a link opens a page: only a commit in a checkout ("Place order" drawn as a link on the cart) is asked about
        if navigates(f) {
            return has(commitRx, words) && (moneyPlace || checkoutPlace(f.hrefAbs.isEmpty ? f.href : f.hrefAbs)) ? shown : ""
        }
        // a search form: never, unless it also takes a card
        let searchForm = f.inSearch || f.formRole == "search" || f.searchInput || f.type == "search"
            || f.formAction.lowercased().range(of: "(search|query|find|/s\\?|suche|cerca|ricerca|poisk|поиск)", options: .regularExpression) != nil
        if searchForm && !cardForm { return "" }
        // a press (a button, a link that is only a button, a div a site made clickable); the words of a label (a
        // filter's «Pay at the property») commit nothing off a checkout
        if has(commitRx, words) && (f.tag != "label" || moneyPlace) { return shown }
        // search, filters, pages of results
        if has(searchRx, words) && !cardForm { return "" }
        if moneyPlace && has(checkoutRx, words) { return shown }
        let unclear = words.isEmpty || words.count > 60 || words.range(of: "[\\p{L}\\p{N}]", options: .regularExpression) == nil
        let label = words.isEmpty ? "a button without words" : shown
        if f.submit && cardForm { return label + " (in a payment form)" }
        // a form that writes to someone (a message box and an email), sent by a button with no clear words
        if f.submit && unclear && f.textarea && f.email { return label + " (it sends a message)" }
        return ""
    }

    /// Enter in a field submits its form: the reason of the first submit button that has one, or of the form itself
    /// when it has no button but takes a card or goes to a checkout.
    static func enterReason(field: Facts, submits: [Facts]) -> String {
        if submits.isEmpty { return (field.card || checkoutPlace(field.formAction)) ? "Enter (it submits a payment form)" : "" }
        for s in submits { let r = reason(s); if !r.isEmpty { return r } }
        return ""
    }
}

/// What the person and Lia are told when a browser task ends before its goal: the page it reached and the head of
/// its text, which is all the agent has found so far.
enum BrowserSoFar {
    static func text(steps: Int, title: String, url: String, snapshot: String?, head: Int = 1500) -> String {
        var body = snapshot ?? ""
        if let r = body.range(of: "TEXT:\n") { body = String(body[r.upperBound...]) }
        if let r = body.range(of: "\n\nCONTROLS:\n") { body = String(body[..<r.lowerBound]) }
        body = body.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        let place = title.isEmpty ? url : "«\(title)» " + url
        var s = "after \(steps) step" + (steps == 1 ? "" : "s")
        if !place.trimmingCharacters(in: .whitespaces).isEmpty { s += ", on " + place }
        if !body.isEmpty { s += ". The page shows: " + (body.count > head ? String(body.prefix(head)) + "…" : body) }
        return s
    }
}

/// Browse-step and locate refuse past the person's cap before any model runs: HTTP 429
/// `{ok:false, error, message}`. A refusal is not a failure to retry: the task stops at once and the person reads the
/// server's own words (the same fallback as a chat turn's 429, ChatStreamError).
enum WebLimit {
    static let fallback = "Usage limit reached. Try again later."

    /// The words to show for a refused call, nil when the call was not refused for the limit.
    static func message(status: Int, json: JSONObject?) -> String? {
        guard status == 429 else { return nil }
        let m = (JSONRead.string(json, "message") ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return m.isEmpty ? fallback : m
    }

    /// Whose money a call is (the server: "lia" or "met"): Met's chat and his Ads Manager overlay are
    /// Met's, everything else Lia's. `chatID` is the browser's chat ("agent-met") or an agent's name.
    static func agent(_ chatID: String?) -> String {
        guard var a = chatID?.lowercased() else { return "lia" }
        if a.hasPrefix("agent-") { a.removeFirst("agent-".count) }
        return a == "met" ? "met" : "lia"
    }
}
