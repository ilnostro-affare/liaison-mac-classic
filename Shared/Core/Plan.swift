import Foundation

// Lia 1.4 Plan, published from the Mac without our Ads Manager ("no editing").
// The web publishes a new tree through browser.js crPublish, which re-plans each part from its create
// screens: plan_create_campaign -> apply, plan_create_ad_set_panel -> apply, plan_create_ad_panel -> apply.
// The Mac re-plans the same parts from the arguments Lia's doors kept on the plan (the server),
// converted the way the doors convert them (the server). Rows and answers: the server.

struct PlanItem: Equatable, Identifiable {
    let id: String
    let tool: String
    let entity: String
    let title: String
    let planId: String?
    let error: String?
    var off: Bool
    let variant: String?
    let entityId: String?
    let entityType: String?
    let diff: [GateDiffRow]
    /// The door's arguments as JSON text (kept whole so the plan round-trips through chat-save).
    let argsJSON: String

    init?(json o: JSONObject) {
        guard let id = JSONRead.string(o, "id"), !id.isEmpty else { return nil }
        self.id = id
        tool = JSONRead.string(o, "tool") ?? ""
        entity = JSONRead.string(o, "entity") ?? ""
        title = JSONRead.string(o, "title") ?? ""
        planId = JSONRead.string(o, "plan_id").flatMap { $0.isEmpty ? nil : $0 }
        error = JSONRead.string(o, "error").flatMap { $0.isEmpty ? nil : $0 }
        off = JSONRead.bool(o, "off")
        variant = JSONRead.string(o, "variant").flatMap { $0.isEmpty ? nil : $0 }
        entityId = JSONRead.string(o, "entity_id").flatMap { $0.isEmpty ? nil : $0 }
        entityType = JSONRead.string(o, "entity_type").flatMap { $0.isEmpty ? nil : $0 }
        diff = JSONRead.objects(o, "diff").map {
            GateDiffRow(label: JSONRead.string($0, "label") ?? "", old: JSONRead.string($0, "old") ?? "", new: JSONRead.string($0, "new") ?? "")
        }
        let a = (o["args"] as? JSONObject) ?? [:]
        argsJSON = (try? JSONSerialization.data(withJSONObject: a)).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
    }

    var args: JSONObject { JSONRead.object(Data(argsJSON.utf8)) ?? [:] }

    /// campaign | adset | ad for a part of the new tree, nil for a change to something that exists.
    var createKind: String? { PlanLogic.createKinds[tool] }

    /// planKindWord
    var kindWord: String {
        if let k = createKind { return k == "adset" ? "Ad set" : k == "ad" ? "Ad" : "Campaign" }
        switch entityType ?? "" {
        case "campaign": return "Campaign"
        case "ad": return "Ad"
        case "ad_set", "adset": return "Ad set"
        default: return entity.isEmpty ? "Change" : entity.prefix(1).uppercased() + entity.dropFirst()
        }
    }

    /// planDiffLine: up to four rows, the audience size as a bare number.
    var diffLine: String {
        diff.filter { !$0.label.isEmpty && !$0.label.hasPrefix("New ") }.prefix(4).map { r in
            r.label == "Estimated audience" ? r.new : r.label + " " + (r.old.isEmpty ? "" : r.old + " \u{2192} ") + (r.new.isEmpty ? "\u{2014}" : r.new)
        }.joined(separator: " \u{00b7} ")
    }
}

/// One line of what publishing did (kept on the plan as `results`).
struct PlanResult: Equatable {
    var kind: String
    var k: String
    var title: String
    var what: String?
    var ok = false
    var on = false
    var createdId: String?
    var error: String?
    var off = false
    /// For the reply only.
    var entity: String = ""
    var planId: String?
    var entityId: String?
    var activateError: String?

    var json: JSONObject {
        var o: JSONObject = ["kind": kind, "k": k, "title": title, "ok": ok, "on": on, "off": off,
                             "created_id": createdId ?? NSNull(), "error": error ?? NSNull()]
        if let what { o["what"] = what }
        return o
    }

    init(kind: String, k: String, title: String, what: String? = nil, ok: Bool = false, createdId: String? = nil,
         error: String? = nil, off: Bool = false, entity: String = "", planId: String? = nil, entityId: String? = nil) {
        self.kind = kind; self.k = k; self.title = title; self.what = what; self.ok = ok; self.createdId = createdId
        self.error = error; self.off = off; self.entity = entity; self.planId = planId; self.entityId = entityId
    }

    init(json o: JSONObject) {
        kind = JSONRead.string(o, "kind") ?? "change"
        k = JSONRead.string(o, "k") ?? ""
        title = JSONRead.string(o, "title") ?? ""
        what = JSONRead.string(o, "what")
        ok = JSONRead.bool(o, "ok"); on = JSONRead.bool(o, "on"); off = JSONRead.bool(o, "off")
        createdId = JSONRead.string(o, "created_id").flatMap { $0.isEmpty ? nil : $0 }
        error = JSONRead.string(o, "error").flatMap { $0.isEmpty ? nil : $0 }
    }
}

struct PlanState: Equatable {
    var items: [PlanItem]
    var pick: String?
    var done: Bool
    var answer: String?
    var publishing: Double?
    var results: [PlanResult]

    init?(json o: JSONObject?) {
        guard let o else { return nil }
        let its = JSONRead.objects(o, "items").compactMap(PlanItem.init(json:))
        guard !its.isEmpty else { return nil }
        items = its
        pick = JSONRead.string(o, "pick").flatMap { $0.isEmpty ? nil : $0 }
        done = JSONRead.bool(o, "done")
        answer = JSONRead.string(o, "answer")
        publishing = JSONRead.double(o, "publishing").flatMap { $0 > 0 ? $0 : nil }
        results = JSONRead.objects(o, "results").map(PlanResult.init(json:))
    }

    /// Writes this state over the stored plan, keeping every field the Mac does not read (stamp, args...).
    func merged(into stored: JSONObject) -> JSONObject {
        var o = stored
        o["done"] = done
        if let answer { o["answer"] = answer } else { o.removeValue(forKey: "answer") }
        if let pick { o["pick"] = pick }
        if let publishing { o["publishing"] = publishing } else { o.removeValue(forKey: "publishing") }
        if !results.isEmpty { o["results"] = results.prefix(20).map(\.json) }
        let offs = Dictionary(uniqueKeysWithValues: items.map { ($0.id, $0.off) })
        o["items"] = JSONRead.objects(stored, "items").map { it -> JSONObject in
            var x = it
            if let id = JSONRead.string(it, "id"), let off = offs[id] { if off { x["off"] = true } else { x.removeValue(forKey: "off") } }
            return x
        }
        return o
    }

    var creates: [PlanItem] { items.filter { $0.createKind != nil && $0.error == nil } }
    var variants: [PlanItem] { creates.filter { $0.tool == "create_ad_set" && $0.variant != nil } }
    var edits: [PlanItem] { items.filter { $0.createKind == nil && $0.planId != nil && $0.error == nil } }
    /// Refusals Lia did not fix later in the same turn (ai.js planPaint `bad`).
    var refused: [PlanItem] {
        items.enumerated().filter { i, x in x.error != nil && !items[(i + 1)...].contains { $0.tool == x.tool && $0.error == nil } }.map(\.1)
    }
    var parts: Int { items.filter { $0.error == nil && !$0.off }.count - max(0, variants.count - 1) }

    /// The audience variant that will be created: the one picked, else Lia's first.
    var chosenAdSet: PlanItem? {
        let v = variants
        if v.count > 1 { return v.first { $0.id == pick } ?? v.first }
        return creates.first { $0.tool == "create_ad_set" }
    }
    func create(_ kind: String) -> PlanItem? { kind == "adset" ? chosenAdSet : creates.first { $0.createKind == kind } }
}

enum PlanAnswer: String { case publish, publishOn = "publish_on", apply, no }

enum PlanLogic {
    static let createKinds = ["create_campaign": "campaign", "create_ad_set": "adset", "create_ad": "ad"]

    /// planButtons: Publish paused / Publish and turn on / No; Apply N / No; Close when nothing can be sent.
    static func buttons(_ p: PlanState) -> [(PlanAnswer, String)] {
        let n = p.edits.filter { !$0.off }.count
        if p.creates.isEmpty && n == 0 { return [(.no, "Close")] }
        return p.creates.isEmpty ? [(.apply, "Apply \(n)"), (.no, "No")] : [(.publish, "Publish paused"), (.publishOn, "Publish and turn on"), (.no, "No")]
    }

    /// planAudLine: places, age, sex, interests.
    static func audienceLine(_ a: JSONObject) -> String {
        let g = json(a["geo"]) as? JSONObject ?? [:]
        var placeList: [String] = []
        for c in JSONRead.objects(g, "cities") {
            let name: String = JSONRead.string(c, "name") ?? "a city"
            let radius: String = JSONRead.string(c, "radius_km").map { " +" + $0 + " km" } ?? ""
            placeList.append(name + radius)
        }
        for r in JSONRead.objects(g, "regions") { placeList.append(JSONRead.string(r, "name") ?? "a region") }
        for k in (g["countries"] as? [Any]) ?? [] { placeList.append("\(k)") }
        let places = placeList.prefix(3).joined(separator: ", ")
        let lo = JSONRead.string(a, "age_min"), hi = JSONRead.string(a, "age_max")
        let age = (lo != nil || hi != nil) ? "\(lo ?? "18")\u{2013}\(hi ?? "65")" : ""
        let gn = json(a["genders"]) as? [Any] ?? []
        let sex = gn.count == 1 ? ("\(gn[0])" == "1" ? "men" : "women") : ""
        let ints = ((json(a["interests"]) as? [Any]) ?? []).prefix(3).map { ($0 as? JSONObject).flatMap { JSONRead.string($0, "name") } ?? "\($0)" }.joined(separator: ", ")
        return [places, age, sex, ints].filter { !$0.isEmpty }.joined(separator: " \u{00b7} ")
    }

    // MARK: the gateway calls, built from the door's arguments

    /// plan_create_campaign (meta-mcp 1769): the door's keys; a bid strategy without a campaign budget is dropped.
    static func campaignParams(_ a: JSONObject) -> [String: Any] {
        var c = pick(a, ["name", "objective", "account", "daily_budget", "lifetime_budget", "spend_cap", "bid_strategy"])
        for k in ["special_ad_categories", "special_ad_category_country"] { if let v = jsonText(a[k]) { c[k] = v } }
        if c["bid_strategy"] != nil && c["daily_budget"] == nil && c["lifetime_budget"] == nil { c.removeValue(forKey: "bid_strategy") }
        return c
    }

    /// plan_create_ad_set_panel (meta-mcp 1781): into the campaign just made, or the one Lia named.
    static func adSetParams(_ a: JSONObject, campaignId: String?) -> [String: Any] {
        var c = pick(a, ["name", "account", "targeting_from", "conversion_location", "optimization_goal", "page_id", "pixel_id",
                         "custom_event_type", "daily_budget", "lifetime_budget", "start_time", "end_time", "bid_strategy", "bid_amount",
                         "attribution_window", "age_min", "age_max"])
        c["from_scratch"] = "true"
        let named = (JSONRead.string(a, "campaign_id") ?? "").filter(\.isNumber)
        if let campaignId { c["campaign_id"] = campaignId } else if !named.isEmpty { c["campaign_id"] = named }
        // genders: the door's [1] / [2]; the planner reads words (the server).
        if let g = json(a["genders"]) as? [Any], g.count == 1 { c["genders"] = "\(g[0])" == "1" ? "men" : "women" }
        else if let s = JSONRead.string(a, "genders"), ["men", "women", "all"].contains(s) { c["genders"] = s }
        // advantage_audience: on / off -> 1 / 0; an age the person asked for is a hard age.
        if let adv = JSONRead.string(a, "advantage_audience"), adv == "on" || adv == "off" { c["advantage_audience"] = adv == "on" ? "1" : "0" }
        else if c["age_min"] != nil || c["age_max"] != nil { c["advantage_audience"] = "0" }
        for k in ["geo", "interests", "schedule", "locales", "age_range", "device_platforms"] { if let v = jsonText(a[k]) { c[k] = v } }
        // placements: {"platforms":["instagram"],"instagram":["stream"]} is the list it means.
        if let p = json(a["placements"]) {
            if let o = p as? JSONObject, let pls = o["platforms"] as? [Any] {
                let list = pls.flatMap { pl in ((o["\(pl)"] as? [Any]) ?? []).map { "\(pl)_\($0)" } }
                if !list.isEmpty { c["placements"] = jsonText(list) }
            } else if let t = jsonText(p) { c["placements"] = t }
        }
        return c
    }

    /// plan_create_ad_panel (meta-mcp 1791): into the ad set just made, or the one Lia named.
    static func adParams(_ a: JSONObject, adSetId: String?) -> [String: Any] {
        var c = pick(a, ["name", "r2_key", "image_hash", "video_id", "page_id", "instagram_user_id", "primary_text", "headline",
                         "description", "call_to_action", "lead_form_id", "link", "display_link", "url_tags", "multi_advertiser"])
        let named = (JSONRead.string(a, "ad_set_id") ?? "").filter(\.isNumber)
        if let adSetId { c["ad_set_id"] = adSetId } else if !named.isEmpty { c["ad_set_id"] = named }
        return c
    }

    /// `[plan_reply] {answer, items:[...]}` as planAnswer writes it.
    static func reply(_ answer: PlanAnswer, _ out: [PlanResult]) -> String {
        let items = out.map { x -> String in
            var pairs: [(String, Any)] = [("entity", x.entity), ("title", x.title)]
            if let w = x.what { pairs.append(("what", w)) }
            pairs.append(("on", x.on))
            if let e = x.activateError { pairs.append(("activate_error", e)) }
            if let p = x.planId { pairs.append(("plan_id", p)) }
            pairs.append(("created_id", x.createdId.map { $0 as Any } ?? NSNull()))
            pairs.append(("entity_id", x.entityId.map { $0 as Any } ?? NSNull()))
            pairs.append(("error", x.error.map { $0 as Any } ?? NSNull()))
            pairs.append(("off", x.off))
            return OrderedJSON.object(pairs)
        }
        return ModeReply.planTag + " {\"answer\":" + OrderedJSON.string(answer.rawValue) + ",\"items\":[" + items.joined(separator: ",") + "]}"
    }

    // MARK: helpers

    private static func pick(_ a: JSONObject, _ keys: [String]) -> [String: Any] {
        var c: [String: Any] = [:]
        for k in keys {
            guard let v = a[k], !(v is NSNull) else { continue }
            if let s = v as? String { if !s.trimmingCharacters(in: .whitespaces).isEmpty { c[k] = s } }
            else if let n = v as? NSNumber { c[k] = n.stringValue }
        }
        return c
    }

    /// A JSON parameter as the model may send it: the value, or its text.
    static func json(_ v: Any?) -> Any? {
        if let s = v as? String {
            let t = s.trimmingCharacters(in: .whitespaces)
            guard !t.isEmpty, let d = t.data(using: .utf8) else { return nil }
            return try? JSONSerialization.jsonObject(with: d, options: [.fragmentsAllowed])
        }
        if v is NSNull { return nil }
        return v
    }

    /// The gateway takes JSON parameters as text.
    static func jsonText(_ v: Any?) -> String? {
        guard let j = json(v), JSONSerialization.isValidJSONObject(j),
              let d = try? JSONSerialization.data(withJSONObject: j, options: [.sortedKeys]) else { return nil }
        return String(data: d, encoding: .utf8)
    }
}
