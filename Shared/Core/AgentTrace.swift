import Foundation

// Lia 2.0's live trace (server) and what the browser shows from it.
// The server says what a tool does, field by field; `AgentRun` turns that into beats for the overlay:
// open the right Ads Manager page, point at the right place, type the fields into our own drawn panel, show
// Meta's check, and after the person's Yes go to the object that was made. Nothing here touches the page:
// the page is only loaded by address and scrolled (decisions of).

/// One trace event, as the stream sent it.
enum AgentEvent: Equatable {
    /// The model has started writing a call; its arguments follow.
    case intent(call: String, tool: String, label: String, door: Bool)
    /// One argument: a string grows (`done` false) and then closes; other values arrive whole.
    case arg(call: String, key: String, value: String, done: Bool)
    /// The call is complete: links `call` to the step id and carries every argument.
    case start(id: String, call: String?, tool: String, label: String, args: [String: String])
    /// What the server does with it: `guard` (refused before it ran, with a reason), `call`, `meta_check`.
    case step(id: String, step: String, account: String?, reason: String?)
    /// What came back.
    case done(id: String, sum: AgentSum)
    /// The person said Yes and the change reached Meta (or did not): from the app, not the stream.
    case applied(entityType: String, entityId: String?, createdId: String?, account: String?, error: String?)
    /// The turn is over (done, error or stop).
    case end
    /// Lia handed a task on the open web to the Mac (WebAgent): do it in the chat's browser, report back.
    case browserTask(task: String, goal: String, tab: String, url: String?)

    /// nil unless the line is one of the trace events (act_start / act_done included: they carry call, targs, sum).
    static func parse(line: String) -> AgentEvent? {
        guard line.hasPrefix("data:") else { return nil }
        let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
        guard let o = JSONRead.object(Data(payload.utf8)), let type = JSONRead.string(o, "type") else { return nil }
        switch type {
        case "act_intent":
            let tool = JSONRead.string(o, "tool") ?? ""
            return .intent(call: JSONRead.string(o, "call") ?? "", tool: tool, label: JSONRead.string(o, "label") ?? tool,
                           door: JSONRead.bool(o, "door"))
        case "act_arg":
            guard let key = JSONRead.string(o, "key") else { return nil }
            return .arg(call: JSONRead.string(o, "call") ?? "", key: key, value: AgentValue.text(o["value"]),
                        done: JSONRead.bool(o, "done"))
        case "act_start":
            // Only the 2.0 shape (it has targs); 1.4's act_start stays a ChatEvent alone.
            guard let targs = o["targs"] as? JSONObject else { return nil }
            var args: [String: String] = [:]
            for (k, v) in targs { args[k] = AgentValue.text(v) }
            let tool = JSONRead.string(o, "tool") ?? ""
            return .start(id: JSONRead.string(o, "id") ?? "", call: JSONRead.string(o, "call"), tool: tool,
                          label: JSONRead.string(o, "label") ?? DevToolPhrases.labels[tool] ?? tool, args: args)
        case "act_step":
            return .step(id: JSONRead.string(o, "id") ?? "", step: JSONRead.string(o, "step") ?? "",
                         account: JSONRead.string(o, "account"), reason: JSONRead.string(o, "reason"))
        case "applied":
            // A change of a task the person approved, applied by the server without stopping
            let ok = o["ok"] as? Bool ?? true
            return .applied(entityType: JSONRead.string(o, "entity_type") ?? JSONRead.string(o, "entity") ?? "",
                            entityId: JSONRead.string(o, "entity_id"), createdId: JSONRead.string(o, "created_id"),
                            account: nil, error: ok ? nil : (JSONRead.string(o, "error") ?? "Not applied"))
        case "browser_task":
            guard let goal = JSONRead.string(o, "goal"), !goal.isEmpty else { return nil }
            let url = JSONRead.string(o, "url")
            return .browserTask(task: JSONRead.string(o, "task") ?? JSONRead.string(o, "id") ?? "", goal: goal,
                                tab: JSONRead.string(o, "tab") ?? "new", url: (url?.isEmpty ?? true) ? nil : url)
        case "act_done":
            guard let s = o["sum"] as? JSONObject else { return nil }
            return .done(id: JSONRead.string(o, "id") ?? "", sum: AgentSum(json: s))
        default:
            return nil
        }
    }
}

/// act_done's `sum` (the server).
struct AgentSum: Equatable {
    var ok = true
    var error: String?
    var door = false
    var planId: String?
    var entityType: String?
    var entityId: String?
    var title: String?
    var diff: [GateDiffRow] = []
    var rows: Int?
    var ids: [String] = []

    init() {}
    init(json o: JSONObject) {
        ok = JSONRead.bool(o, "ok")
        error = JSONRead.string(o, "error")
        door = JSONRead.bool(o, "door")
        planId = JSONRead.string(o, "plan_id")
        entityType = JSONRead.string(o, "entity_type")
        entityId = JSONRead.string(o, "entity_id")
        title = JSONRead.string(o, "title")
        diff = JSONRead.objects(o, "diff").map {
            GateDiffRow(label: JSONRead.string($0, "label") ?? "", old: AgentValue.text($0["old"]), new: AgentValue.text($0["new"]))
        }
        rows = JSONRead.int(o, "rows")
        ids = JSONRead.strings(o, "ids")
    }
}

/// Values as the overlay shows them.
enum AgentValue {
    static func text(_ v: Any?) -> String {
        switch v {
        case nil, is NSNull: return ""
        case let s as String: return s
        case let b as Bool: return b ? "Yes" : "No"
        case let n as NSNumber:
            let d = n.doubleValue
            return d == d.rounded() && abs(d) < 1e15 ? String(Int64(d)) : String(d)
        case let a as [Any]: return a.map { text($0) }.filter { !$0.isEmpty }.joined(separator: ", ")
        case let o as [String: Any]:
            if let name = o["name"] as? String { return name }
            return (try? JSONSerialization.data(withJSONObject: o, options: [.sortedKeys]))
                .flatMap { String(data: $0, encoding: .utf8) } ?? ""
        default: return "\(v!)"
        }
    }

    /// How a person reads a value (the cursor's tag showed code). OUTCOME_LEADS -> Leads,
    /// instant_forms -> Instant forms, a geo object -> "1 city · +17 km", a bare Meta id -> "" (the label says it).
    static func display(_ s: String) -> String {
        let t0 = s.trimmingCharacters(in: .whitespaces)
        if t0.hasPrefix("{") || t0.hasPrefix("["), let data = t0.data(using: .utf8),
           let json = try? JSONSerialization.jsonObject(with: data) {
            return describe(json)
        }
        if t0.count >= 8, t0.allSatisfy(\.isNumber) { return "" }
        var t = t0
        if t.hasPrefix("OUTCOME_") { t = String(t.dropFirst(8)) }
        guard t.count > 1, t.range(of: "^[A-Za-z0-9_]+$", options: .regularExpression) != nil,
              t == t.uppercased() || (t == t.lowercased() && t.rangeOfCharacter(from: .letters) != nil) else { return s }
        let words = t.lowercased().replacingOccurrences(of: "_", with: " ")
        return words.prefix(1).uppercased() + words.dropFirst()
    }

    /// A JSON value in words: names where it has them, else counts of what it holds.
    static func describe(_ v: Any) -> String {
        if let a = v as? [Any] {
            let parts = a.prefix(4).map(describe).filter { !$0.isEmpty }
            return parts.isEmpty ? (a.isEmpty ? "" : "\(a.count) items") : parts.joined(separator: ", ") + (a.count > 4 ? " +\(a.count - 4)" : "")
        }
        if let o = v as? [String: Any] {
            for k in ["name", "title", "label"] { if let n = o[k] as? String, !n.isEmpty { return n } }
            var out: [String] = []
            let groups: [(String, String, String)] = [("cities", "city", "cities"), ("regions", "region", "regions"),
                                                     ("countries", "country", "countries"), ("zips", "postcode", "postcodes"),
                                                     ("custom_locations", "place", "places"), ("interests", "interest", "interests")]
            for (k, one, many) in groups {
                guard let a = o[k] as? [Any], !a.isEmpty else { continue }
                let named = a.compactMap { ($0 as? [String: Any])?["name"] as? String }
                out.append(named.isEmpty ? "\(a.count) \(a.count == 1 ? one : many)" : named.prefix(3).joined(separator: ", "))
                if let r = a.compactMap({ ($0 as? [String: Any])?["radius_km"] ?? ($0 as? [String: Any])?["radius"] }).first {
                    out.append("+\(text(r)) km")
                }
            }
            return out.joined(separator: " \u{00b7} ")
        }
        if let s = v as? String { return display(s) }
        return text(v)
    }
}

/// Field names as Ads Manager's editors name them. Ids and plumbing are not fields: they decide the page.
enum AgentFields {
    static let labels: [String: String] = [
        "name": "Name", "objective": "Objective", "daily_budget": "Daily budget", "lifetime_budget": "Lifetime budget",
        "bid_strategy": "Bid strategy", "bid_amount": "Bid", "spend_cap": "Spending limit", "special_ad_categories": "Special ad categories",
        "status": "Status", "budget_mode": "Budget", "optimization_goal": "Performance goal", "billing_event": "Charged for",
        "start_time": "Start", "end_time": "End", "geo": "Locations", "locations": "Locations", "cities": "Locations",
        "countries": "Locations", "age_min": "Age from", "age_max": "Age to", "genders": "Gender", "interests": "Detailed targeting",
        "locales": "Languages", "placements": "Placements", "publisher_platforms": "Placements",
        "page_id": "Facebook Page", "instagram_user_id": "Instagram account", "lead_form_id": "Instant form",
        "primary_text": "Primary text", "headline": "Headline", "description": "Description", "call_to_action": "Call to action",
        "link": "Website URL", "display_link": "Display link", "url_tags": "URL parameters", "image_hash": "Image",
        "video_id": "Video", "r2_key": "Media", "creative_id": "Creative", "template": "Rule", "cpl_above": "Cost per lead above",
        "spend_above": "Spend above", "variable": "Variable", "metric": "Winner decided by",
    ]
    /// Arguments that choose the page, not a field on it.
    static let routing: Set<String> = ["account", "campaign_id", "ad_set_id", "adset_id", "ad_id", "entity_id", "entity_type",
                                       "source_ad_id", "scope_id", "scope_type", "ids", "journal_id", "after_campaign_plan_id",
                                       "after_adset_plan_id", "variant", "from_scratch"]

    static func label(_ key: String) -> String {
        if let l = labels[key] { return l }
        let w = key.replacingOccurrences(of: "_", with: " ")
        return w.prefix(1).uppercased() + w.dropFirst()
    }

    /// Shown in the panel: not routing, not empty.
    static func shows(_ key: String, _ value: String) -> Bool {
        !routing.contains(key) && !key.hasPrefix("__") && !value.isEmpty && value != "[]" && value != "{}"
    }
}

/// The Ads Manager level a page shows.
enum AdsLevel: String { case campaigns, adsets, ads }

/// adsmanager.facebook.com addresses. A list (ai.js adsManagerUrl) or Meta's own editor of one object, which opens
/// by address (`…/{level}/edit/standalone?act&selected_campaign_ids&selected_adset_ids&selected_ad_ids`,
/// ) - the real editor with no click.
struct AdsManagerLink: Equatable {
    var account: String
    var level: AdsLevel = .campaigns
    var campaign: String?
    var adSet: String?
    var ad: String?
    var editor = false

    var url: URL? {
        var c = URLComponents(string: "https://adsmanager.facebook.com/adsmanager/manage/" + level.rawValue + (editor ? "/edit/standalone" : ""))
        var q = [URLQueryItem(name: "act", value: account)]
        if editor {
            if let campaign { q.append(URLQueryItem(name: "selected_campaign_ids", value: campaign)) }
            if let adSet { q.append(URLQueryItem(name: "selected_adset_ids", value: adSet)) }
            if let ad { q.append(URLQueryItem(name: "selected_ad_ids", value: ad)) }
        } else {
            if let campaign, level != .ads { q.append(URLQueryItem(name: "selected_campaign_ids", value: campaign)) }
            if let adSet, level == .ads { q.append(URLQueryItem(name: "selected_adset_ids", value: adSet)) }
        }
        c?.queryItems = q
        return c?.url
    }
}

/// What the cursor aims at. The app finds it on the page through the Decisions API (no word lists of ours).
enum AgentTarget: Equatable {
    /// Whatever starts creating a new object of this level on the list.
    case create(AdsLevel)
    /// A table row: by id in the row's links first, else asked by name.
    case row(id: String?, name: String?)
}

/// What the overlay does next.
enum AgentBeat: Equatable {
    case open(URL)
    case point(AgentTarget)
    /// A new object: a drawn row in the real table, in its geometry, filled as the fields come.
    case ghostRow(title: String)
    /// One field: located on the page and drawn over its control, or shown by the cursor as a caption.
    case field(key: String, label: String, value: String, done: Bool)
    case checking
    case result(ok: Bool, error: String?, diff: [GateDiffRow])
    /// After Yes: Meta's editor of the object that was made or changed. `walk`: the cursor then passes over the
    /// fields Lia set (a new object, browser.js agentShow); for a change the real values simply replace ours.
    case applied(URL?, ok: Bool, error: String?, walk: Bool)
    case finish
}

/// Turns the trace into beats. Pure: the app feeds events and plays the beats.
struct AgentRun {
    /// The chat's account when a call names none.
    var defaultAccount: String?
    /// Kind of an id the chat knows ("campaign", "adset", "ad"), from the stream's ents.
    var kindOf: (String) -> String? = { _ in nil }
    /// The campaign an id sits under, from the stream's ents.
    var parentOf: (String) -> String? = { _ in nil }

    private(set) var tool = ""
    private(set) var account: String?
    private(set) var opened: URL?
    private var link: AdsManagerLink?
    private var shown: [String: String] = [:]
    private var closed: Set<String> = []
    private var calls: Set<String> = []
    private var stepIds: Set<String> = []
    private var ids: [String: String] = [:]      // routing args seen: campaign_id, ad_set_id, ad_id, entity_id …
    private var pointed = false
    private var ghost = false

    init(defaultAccount: String? = nil, kindOf: @escaping (String) -> String? = { _ in nil },
         parentOf: @escaping (String) -> String? = { _ in nil }) {
        self.defaultAccount = defaultAccount
        self.kindOf = kindOf
        self.parentOf = parentOf
    }

    static func isDoor(_ tool: String) -> Bool { RunSteps.doors.contains(tool) }

    var creating: Bool { tool.hasPrefix("create_") }

    var level: AdsLevel {
        if let l = link, l.editor { return l.level }   // a change: the level of the editor that opened
        switch tool {
        case "create_ad_set": return .adsets
        case "create_ad", "create_ad_from_creative", "update_ad": return .ads
        default: return .campaigns
        }
    }

    mutating func feed(_ e: AgentEvent) -> [AgentBeat] {
        switch e {
        case let .intent(call, t, _, isDoor):
            guard isDoor || Self.isDoor(t) else { return [] }
            tool = t; account = nil; shown = [:]; closed = []; ids = [:]; pointed = false; ghost = false; link = nil
            calls.insert(call)
            return []
        case let .arg(call, key, value, done):
            guard calls.contains(call) else { return [] }
            return take(key: key, value: value, done: done)
        case let .start(id, call, t, _, args):
            guard (call.map { calls.contains($0) } ?? false) || (Self.isDoor(t) && tool.isEmpty) else { return [] }
            if tool.isEmpty { tool = t }
            stepIds.insert(id)
            var out: [AgentBeat] = []
            if let a = args["account"] { out += take(key: "account", value: a, done: true) }
            for (k, v) in args.sorted(by: { $0.key < $1.key }) where AgentFields.routing.contains(k) && k != "account" {
                out += take(key: k, value: v, done: true)
            }
            for (k, v) in args.sorted(by: { $0.key < $1.key }) where !AgentFields.routing.contains(k) {
                out += take(key: k, value: v, done: true)
            }
            return out
        case let .step(id, step, _, reason):
            guard stepIds.contains(id) else { return [] }
            if step == "guard" { return [.result(ok: false, error: reason, diff: [])] }
            return step == "meta_check" ? [.checking] : []
        case let .done(id, sum):
            guard stepIds.contains(id) else { return [] }
            return [.result(ok: sum.ok, error: sum.error, diff: sum.diff)]
        case let .applied(entityType, entityId, createdId, acc, error):
            let a = acc.map(digits) ?? account ?? defaultAccount
            guard error == nil, let a, !a.isEmpty else { return [.applied(nil, ok: error == nil, error: error, walk: false), .finish] }
            var l = AdsManagerLink(account: a, editor: true)
            let made = (createdId ?? entityId).map(digits)
            switch entityType.replacingOccurrences(of: "_", with: "").lowercased() {
            case "campaign":
                l.level = .campaigns; l.campaign = made
            case "adset":
                l.level = .adsets; l.adSet = made; l.campaign = ids["campaign_id"] ?? made.flatMap(parentOf)
            case "ad":
                l.level = .ads; l.ad = made; l.adSet = ids["ad_set_id"] ?? ids["adset_id"]; l.campaign = made.flatMap(parentOf)
            default:
                return [.applied(link?.url, ok: true, error: nil, walk: false), .finish]
            }
            return [.applied(l.url, ok: true, error: nil, walk: createdId != nil), .finish]
        case .browserTask:
            return []   // the open web is WebAgent's, not the Ads Manager overlay's
        case .end:
            let had = !calls.isEmpty
            calls = []; stepIds = []
            return had ? [.finish] : []
        }
    }

    private mutating func take(key: String, value: String, done: Bool) -> [AgentBeat] {
        var out: [AgentBeat] = []
        if key == "account" {
            guard done else { return [] }
            account = digits(value)
            out += page()
        } else if AgentFields.routing.contains(key) {
            guard done else { return [] }
            // Ids are digits; entity_type is a word ("ad", "ad_set") and says which editor a change opens.
            let d = key == "entity_type" ? value.lowercased() : digits(value)
            if !d.isEmpty { ids[key] = d }
            out += page()
        } else if AgentFields.shows(key, value) {
            out += page()
            guard opened != nil else { return out }   // nowhere to draw yet; act_start brings it again
            if creating && !ghost { ghost = true; out.append(.ghostRow(title: AgentRun.newTitle(tool))) }
            // New text, or the same text now closed; a closed field is never repeated.
            if shown[key] != value || (done && !closed.contains(key)) {
                guard !closed.contains(key) || shown[key] != value else { return out }
                shown[key] = value
                if done { closed.insert(key) }
                out.append(.field(key: key, label: AgentFields.label(key), value: AgentValue.display(value), done: done))
            }
        }
        return out
    }

    static func newTitle(_ tool: String) -> String {
        switch tool {
        case "create_campaign": return "New campaign"
        case "create_ad_set": return "New ad set"
        case "create_ad", "create_ad_from_creative": return "New ad"
        case "create_ab_test": return "New A/B test"
        case "create_ad_rule": return "New rule"
        default: return "New"
        }
    }

    /// The page: a list with Create for a new object, Meta's editor of the object for a change. Opened once.
    private mutating func page() -> [AgentBeat] {
        guard let acc = account ?? defaultAccount, !acc.isEmpty else { return [] }
        var l = AdsManagerLink(account: acc)
        var target: AgentTarget?
        if creating {
            switch tool {
            case "create_ad_set":
                guard let c = ids["campaign_id"] else { return [] }   // its campaign's ad sets, once the id is written
                l.level = .adsets; l.campaign = c
            case "create_ad", "create_ad_from_creative":
                guard let s = ids["ad_set_id"] ?? ids["adset_id"] else { return [] }
                l.level = .ads; l.adSet = s
            default: break
            }
            target = .create(level)
        } else {
            // A change: Meta's own editor of that object.
            l.editor = true
            if let c = ids["campaign_id"] { l.level = .campaigns; l.campaign = c }
            else if let s = ids["ad_set_id"] ?? ids["adset_id"] { l.level = .adsets; l.adSet = s; l.campaign = parentOf(s) }
            else if let a = ids["ad_id"] { l.level = .ads; l.ad = a; l.campaign = parentOf(a) }
            else if let e = ids["entity_id"] ?? ids["source_ad_id"] {
                switch ids["entity_type"] ?? kindOf(e) {
                case "adset", "ad_set": l.level = .adsets; l.adSet = e; l.campaign = parentOf(e)
                case "ad": l.level = .ads; l.ad = e; l.campaign = parentOf(e)
                default: l.level = .campaigns; l.campaign = e
                }
            } else {
                return []   // which object is not known yet: wait for its id
            }
        }
        var out: [AgentBeat] = []
        if let u = l.url, u != opened {
            opened = u; link = l; pointed = false
            out.append(.open(u))
        }
        if creating, !pointed, let target { pointed = true; out.append(.point(target)) }
        return out
    }

    private func digits(_ s: String) -> String { s.filter(\.isNumber) }
}
