import Foundation

// The site's Creatives and Leads screens (creatives.js, leads.js) as data: what the in-chat popups read,
// filter, sort and export. Pure, so the Linux harness proves it.

// MARK: formatting (api.js fmt)

enum SiteFmt {
    private static func grouped(_ v: Double, fraction: Int) -> String {
        let f = NumberFormatter()
        f.locale = Locale(identifier: "en_US")
        f.numberStyle = .decimal
        f.minimumFractionDigits = fraction
        f.maximumFractionDigits = fraction
        return f.string(from: NSNumber(value: v)) ?? String(format: "%.\(fraction)f", v)
    }

    /// fmt.eur: "€1,234.56", "—" for nothing.
    static func eur(_ v: Double?) -> String {
        guard let v, v.isFinite else { return "\u{2014}" }
        return "\u{20ac}" + grouped(v, fraction: 2)
    }

    /// fmt.int: "1,234".
    static func int(_ v: Double?) -> String {
        guard let v, v.isFinite else { return "\u{2014}" }
        return grouped(v.rounded(), fraction: 0)
    }

    static func int(_ v: Int?) -> String { int(v.map(Double.init)) }

    /// fmt.pct: "0.57%".
    static func pct(_ v: Double?) -> String {
        guard let v, v.isFinite else { return "\u{2014}" }
        return String(format: "%.2f%%", v)
    }

    /// The bar charts' compact money (creatives.js compactEur): €12k, €1.5k, €37.
    static func compactEur(_ v: Double) -> String {
        if v >= 10000 { return "\u{20ac}" + String(Int((v / 1000).rounded())) + "k" }
        if v >= 1000 { return "\u{20ac}" + String(format: "%.1f", v / 1000) + "k" }
        return "\u{20ac}" + String(Int(v.rounded()))
    }

    /// The row's share label (creatives.js rowHtml): one decimal under 10%.
    static func share(_ pct: Double) -> String {
        pct >= 10 ? String(format: "%.0f%%", pct) : String(format: "%.1f%%", pct)
    }

    /// components.js statusPill: "ADSET_PAUSED" -> "Adset paused"; active is the blue pill, the rest grey.
    static func status(_ s: String?) -> (label: String, active: Bool) {
        let low = (s ?? "").lowercased()
        guard !low.isEmpty else { return ("\u{2014}", false) }
        let spaced = low.replacingOccurrences(of: "_", with: " ")
        return (spaced.prefix(1).uppercased() + spaced.dropFirst(), low == "active")
    }

    /// api.js phonePretty, /(\+?\d{2})(\d{3})(\d{3})(\d+)/ -> "$1 $2 $3 $4": "+392000000001" -> "+39 200 000 0001".
    /// The regex is unanchored, so the first place it fits is rewritten and the rest kept as it was.
    static func phone(_ p: String) -> String {
        guard !p.isEmpty else { return "\u{2014}" }
        let c = Array(p)
        func isD(_ i: Int) -> Bool { i < c.count && c[i].isASCII && c[i].isNumber }
        for start in 0..<c.count {
            var i = start
            let plus = c[i] == "+"
            if plus { i += 1 }
            guard (i..<(i + 8)).allSatisfy(isD), isD(i + 8) else { continue }
            var j = i + 8
            while isD(j) { j += 1 }
            let s = { (a: Int, b: Int) in String(c[a..<b]) }
            return s(0, start) + (plus ? "+" : "") + s(i, i + 2) + " " + s(i + 2, i + 5) + " " + s(i + 5, i + 8) + " " + s(i + 8, j) + s(j, c.count)
        }
        return p
    }

    /// fmt.time in en-GB: "17/09/2026, 16:24".
    static func time(_ d: Date?, timeZone: TimeZone = .current) -> String {
        guard let d else { return "\u{2014}" }
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_GB")
        f.timeZone = timeZone
        f.dateFormat = "dd/MM/yyyy, HH:mm"
        return f.string(from: d)
    }
}

extension DateRange {
    /// The popup's period menu: the last n days, today included.
    static func lastDays(_ n: Int, now: Date, calendar: Calendar = Calendar(identifier: .gregorian)) -> DateRange {
        let today = calendar.startOfDay(for: now)
        let from = calendar.date(byAdding: .day, value: -(max(1, n) - 1), to: today) ?? today
        return DateRange(from: iso(from, calendar), to: iso(today, calendar))
    }

    /// ai.js canvasCreatives dLabel, the date button: "Oct 1 - 8, 2026", "Sep 9 - Oct 8, 2026", "Dec 30, 2025 - Jan 2, 2026".
    var buttonLabel: String {
        let a = from.prefix(10).split(separator: "-").compactMap { Int($0) }
        let b = to.prefix(10).split(separator: "-").compactMap { Int($0) }
        guard a.count == 3, b.count == 3, (1...12).contains(a[1]), (1...12).contains(b[1]) else { return "Select date" }
        let ma = Self.months[a[1] - 1], mb = Self.months[b[1] - 1]
        if a[0] == b[0] && a[1] == b[1] { return "\(ma) \(a[2]) - \(b[2]), \(a[0])" }
        if a[0] == b[0] { return "\(ma) \(a[2]) - \(mb) \(b[2]), \(a[0])" }
        return "\(ma) \(a[2]), \(a[0]) - \(mb) \(b[2]), \(b[0])"
    }

    /// Which of the menu's presets this range is, if any (days counted inclusively, ending today).
    func presetDays(now: Date, calendar: Calendar = Calendar(identifier: .gregorian)) -> Int? {
        for n in [7, 14, 30, 90] where Self.lastDays(n, now: now, calendar: calendar) == self { return n }
        return nil
    }
}

// MARK: creatives inventory (creatives.js flattenTree + the get_creatives preview pass)

struct AdRow: Equatable, Identifiable {
    let id: String               // ad_id
    let name: String
    let status: String
    let campaignId: String
    let campaignName: String
    let adsetId: String
    let adsetName: String
    let spend: Double
    let leads: Double
    let impressions: Double
    let clicks: Double
    let ctr: Double?
    let cpl: Double?
    var preview: CreativePreview?
    var previewLoaded = false

    /// rowHtml: the name, else "ad · " and the id's last six.
    var displayName: String { name.isEmpty ? "ad \u{00b7} " + String(id.suffix(6)) : name }
    var crumbs: String {
        let t = [campaignName, adsetName].filter { !$0.isEmpty }
        return t.isEmpty ? "\u{2014}" : t.joined(separator: " / ")
    }
}

enum AdsTree {
    /// get_ads_tree {tree: {campaign: {id, name, adsets: {adset: {id, name, ads: [...]}}}}}, flattened to one row per ad.
    /// Object order is not kept by JSON, so campaigns and ad sets are walked by id for a stable list.
    static func flatten(_ data: Data) -> [AdRow] {
        guard let tree = JSONRead.object(data)?["tree"] as? JSONObject else { return [] }
        var out: [AdRow] = []
        for cKey in tree.keys.sorted() {
            guard let c = tree[cKey] as? JSONObject else { continue }
            let adsets = (c["adsets"] as? JSONObject) ?? [:]
            for aKey in adsets.keys.sorted() {
                guard let s = adsets[aKey] as? JSONObject else { continue }
                for ad in JSONRead.objects(s, "ads") {
                    guard let id = JSONRead.string(ad, "ad_id"), !id.isEmpty else { continue }
                    out.append(AdRow(
                        id: id,
                        name: (JSONRead.string(ad, "name") ?? "").trimmingCharacters(in: .whitespacesAndNewlines),
                        status: JSONRead.string(ad, "status_ui") ?? JSONRead.string(ad, "effective_status") ?? JSONRead.string(ad, "status") ?? "UNKNOWN",
                        campaignId: JSONRead.string(c, "id") ?? cKey, campaignName: JSONRead.string(c, "name") ?? "",
                        adsetId: JSONRead.string(s, "id") ?? aKey, adsetName: JSONRead.string(s, "name") ?? "",
                        spend: JSONRead.double(ad, "spend") ?? 0, leads: JSONRead.double(ad, "leads") ?? 0,
                        impressions: JSONRead.double(ad, "impressions") ?? 0, clicks: JSONRead.double(ad, "clicks") ?? 0,
                        ctr: JSONRead.double(ad, "ctr"), cpl: JSONRead.double(ad, "cpl")))
                }
            }
        }
        return out
    }
}

/// One ad's preview from get_creatives (/meta/creatives): {creatives: {ad_id: {...}}} or an array of the same.
struct CreativePreview: Equatable {
    let preview: String?
    let previewHi: String?
    let videoSource: String?
    let videoPermalink: String?
    let videoPoster: String?
    let type: String?
    let name: String?

    var isVideo: Bool { type == "video" || videoSource != nil }
    /// rowHtml: the upscaled preview first, the guaranteed one as the fallback.
    var best: String? { previewHi ?? preview ?? videoPoster }

    init(json c: JSONObject) {
        preview = JSONRead.string(c, "preview") ?? JSONRead.string(c, "preview_url") ?? JSONRead.string(c, "thumbnail_url")
        previewHi = JSONRead.string(c, "preview_hi")
        videoSource = JSONRead.string(c, "video_source")
        videoPermalink = JSONRead.string(c, "video_permalink")
        videoPoster = JSONRead.string(c, "video_poster")
        type = JSONRead.string(c, "type")
        name = JSONRead.string(c, "ad_name") ?? JSONRead.string(c, "name")
    }

    static func parseMap(_ data: Data) -> [String: CreativePreview] {
        guard let o = JSONRead.object(data) else { return [:] }
        let raw = o["creatives"] ?? o["data"]
        var out: [String: CreativePreview] = [:]
        if let map = raw as? JSONObject {
            for (k, v) in map { if let c = v as? JSONObject { out[k] = CreativePreview(json: c) } }
        } else if let list = raw as? [Any] {
            for case let c as JSONObject in list {
                if let id = JSONRead.string(c, "ad_id") ?? JSONRead.string(c, "id") { out[id] = CreativePreview(json: c) }
            }
        }
        return out
    }
}

/// The screen's search, two filters and sort (creatives.js applyFilters / applySort).
struct CreativeQuery: Equatable {
    enum Column: String, CaseIterable, Identifiable {
        case spend = "Spend", leads = "Leads", cpl = "CPL", ctr = "CTR", name = "Name", campaign = "Campaign"
        var id: String { rawValue }
    }
    var search = ""
    var status = ""
    var campaign = ""
    var column: Column = .spend
    var descending = true

    func apply(_ rows: [AdRow]) -> [AdRow] {
        let q = search.lowercased().trimmingCharacters(in: .whitespaces)
        let kept = rows.filter { a in
            if !status.isEmpty && a.status != status { return false }
            if !campaign.isEmpty && a.campaignId != campaign { return false }
            if !q.isEmpty {
                let hay = "\(a.name) \(a.adsetName) \(a.campaignName) \(a.id)".lowercased()
                if !hay.contains(q) { return false }
            }
            return true
        }
        let m: Double = descending ? -1 : 1
        // A stable sort: rows that compare equal keep the tree's order, as Array.prototype.sort does.
        return kept.enumerated().sorted { l, r in
            let c = compare(l.element, r.element, m)
            return c == 0 ? l.offset < r.offset : c < 0
        }.map(\.element)
    }

    /// <0 when a goes first. Missing numbers always go last, whatever the direction.
    private func compare(_ a: AdRow, _ b: AdRow, _ m: Double) -> Double {
        switch column {
        case .name: return Double(a.name.compare(b.name).rawValue) * m
        case .campaign: return Double(a.campaignName.compare(b.campaignName).rawValue) * m
        case .spend: return (a.spend - b.spend) * m
        case .leads: return (a.leads - b.leads) * m
        case .cpl, .ctr:
            let av = column == .cpl ? a.cpl : a.ctr, bv = column == .cpl ? b.cpl : b.ctr
            switch (av, bv) {
            case (nil, nil): return 0
            case (nil, _): return 1
            case (_, nil): return -1
            case let (x?, y?): return (x - y) * m
            }
        }
    }

    /// The status options: what the inventory holds, labelled the site's way.
    static func statuses(_ rows: [AdRow]) -> [String] { Array(Set(rows.map(\.status).filter { !$0.isEmpty })).sorted() }

    static func campaigns(_ rows: [AdRow]) -> [(id: String, name: String)] {
        var seen: [String: String] = [:]
        for r in rows where !r.campaignId.isEmpty && seen[r.campaignId] == nil { seen[r.campaignId] = r.campaignName }
        return seen.map { (id: $0.key, name: $0.value.isEmpty ? $0.key : $0.value) }.sorted { $0.name < $1.name }
    }
}

// MARK: the ad modal (creatives.js openAdModal's tabs)

/// get_creative_text {ads: [{ad_id, name, status, creative: {...}}]}.
struct CreativeText: Equatable {
    let title: String?
    let body: String?
    let description: String?
    let cta: String?
    let imageURL: String?
    let thumbnailURL: String?
    let videoId: String?
    let videoSource: String?
    let videoPermalink: String?
    let type: String?

    var hasText: Bool { [title, body, description, cta].contains { ($0 ?? "").isEmpty == false } }
    var isVideo: Bool { type == "video" || videoId != nil }

    static func parse(_ data: Data) -> CreativeText? {
        guard let ad = JSONRead.objects(JSONRead.object(data), "ads").first else { return nil }
        let c = ad["creative"] as? JSONObject ?? [:]
        func s(_ k: String) -> String? { JSONRead.string(c, k).flatMap { $0.isEmpty ? nil : $0 } }
        return CreativeText(title: s("title"), body: s("body"), description: s("description"), cta: s("cta"),
                            imageURL: s("image_url"), thumbnailURL: s("thumbnail_url"), videoId: s("video_id"),
                            videoSource: s("video_source"), videoPermalink: s("video_permalink"), type: s("type"))
    }
}

/// One bar of the audience / placement charts: spend is the bar, leads and CPL under it.
struct SpendBar: Equatable {
    let label: String
    let spend: Double
    let leads: Double
    var cpl: Double? { leads > 0 ? spend / leads : nil }
    /// "18l · €8.85" under the bar, or a dash.
    var sub: String { leads > 0 ? SiteFmt.int(leads) + "l \u{00b7} " + SiteFmt.eur(cpl) : "\u{2014}" }
}

/// get_ad_demographics {ads: [{ad_id, by_age, by_gender}]}: the backend returns every ad, the tab keeps one.
struct AdDemographics: Equatable {
    let age: [SpendBar]
    let gender: [SpendBar]

    static let ageOrder = ["13-17", "18-24", "25-34", "35-44", "45-54", "55-64", "65+"]
    static let genderOrder = ["male": 0, "female": 1, "unknown": 2]

    static func parse(_ data: Data, adId: String) -> AdDemographics? {
        guard let ad = JSONRead.objects(JSONRead.object(data), "ads").first(where: { JSONRead.string($0, "ad_id") == adId }) else { return nil }
        let age = JSONRead.objects(ad, "by_age").map { r in
            SpendBar(label: JSONRead.string(r, "age") ?? "\u{2014}", spend: JSONRead.double(r, "spend") ?? 0, leads: JSONRead.double(r, "leads") ?? 0)
        }.sorted { (ageOrder.firstIndex(of: $0.label) ?? 99) < (ageOrder.firstIndex(of: $1.label) ?? 99) }
        let gender = JSONRead.objects(ad, "by_gender").map { r in
            SpendBar(label: JSONRead.string(r, "gender") ?? "\u{2014}", spend: JSONRead.double(r, "spend") ?? 0, leads: JSONRead.double(r, "leads") ?? 0)
        }.sorted { (genderOrder[$0.label.lowercased()] ?? 9) < (genderOrder[$1.label.lowercased()] ?? 9) }
        guard !age.isEmpty || !gender.isEmpty else { return nil }
        return AdDemographics(age: age, gender: gender)
    }
}

/// get_platform_breakdown {ads: [{ad_id, platforms: [{platform, spend, leads, cpl}]}]}.
enum AdPlatforms {
    static func parse(_ data: Data, adId: String) -> [SpendBar] {
        guard let ad = JSONRead.objects(JSONRead.object(data), "ads").first(where: { JSONRead.string($0, "ad_id") == adId }) else { return [] }
        return JSONRead.objects(ad, "platforms").map { p in
            SpendBar(label: JSONRead.string(p, "platform") ?? "\u{2014}", spend: JSONRead.double(p, "spend") ?? 0, leads: JSONRead.double(p, "leads") ?? 0)
        }
    }
}

/// get_daily_breakdown for one ad: the days and the fatigue verdict.
struct AdDaily: Equatable {
    struct Day: Equatable { let date: String; let spend: Double; let leads: Double; let cpl: Double? }
    struct Fatigue: Equatable { let status: String; let changePct: Double; let firstHalf: Double?; let secondHalf: Double? }
    let days: [Day]
    let fatigue: Fatigue?

    var totalSpend: Double { days.reduce(0) { $0 + $1.spend } }
    var totalLeads: Double { days.reduce(0) { $0 + $1.leads } }

    static func parse(_ data: Data, adId: String) -> AdDaily? {
        let ads = JSONRead.objects(JSONRead.object(data), "ads")
        guard let ad = ads.first(where: { JSONRead.string($0, "ad_id") == adId }) ?? ads.first else { return nil }
        let days = JSONRead.objects(ad, "daily").map { d in
            Day(date: JSONRead.string(d, "date") ?? "", spend: JSONRead.double(d, "spend") ?? 0,
                leads: JSONRead.double(d, "leads") ?? 0, cpl: JSONRead.double(d, "cpl"))
        }
        guard !days.isEmpty else { return nil }
        let f = (ad["fatigue"] as? JSONObject).map { f in
            Fatigue(status: JSONRead.string(f, "status") ?? "warning", changePct: JSONRead.double(f, "change_pct") ?? 0,
                    firstHalf: JSONRead.double(f, "cpl_first_half"), secondHalf: JSONRead.double(f, "cpl_second_half"))
        }
        return AdDaily(days: days, fatigue: f)
    }
}

// MARK: leads (leads.js)

/// One page of get_leads plus the paging fields (first 100, then 400 at a time).
struct LeadPage {
    let rows: [JSONObject]
    let hasMore: Bool
    let total: Int

    static func parse(_ data: Data) -> LeadPage {
        let o = JSONRead.object(data)
        let rows = JSONRead.objects(o, "leads").isEmpty ? JSONRead.objects(o, "data") : JSONRead.objects(o, "leads")
        return LeadPage(rows: rows, hasMore: JSONRead.bool(o, "has_more"), total: JSONRead.int(o, "total") ?? rows.count)
    }
}

/// get_lead_quality {total, duplicates: {count, pct, phones: [{phone}]}, invalid: {count, pct}, platforms: {fb, ig}}.
struct LeadQualitySummary: Equatable {
    var total: Int?
    var duplicates: (count: Int, pct: Double?)?
    var invalid: (count: Int, pct: Double?)?
    var fb: (count: Int, pct: Double?)?
    var ig: (count: Int, pct: Double?)?
    var duplicatePhones: Set<String> = []

    static func == (a: LeadQualitySummary, b: LeadQualitySummary) -> Bool {
        a.total == b.total && a.duplicatePhones == b.duplicatePhones && a.duplicates?.count == b.duplicates?.count
            && a.invalid?.count == b.invalid?.count && a.fb?.count == b.fb?.count && a.ig?.count == b.ig?.count
    }

    static func parse(_ data: Data?) -> LeadQualitySummary {
        guard let data, let root = JSONRead.object(data) else { return LeadQualitySummary() }
        let q = (root["summary"] as? JSONObject) ?? (root["quality"] as? JSONObject) ?? root
        func pick(_ v: Any?) -> (count: Int, pct: Double?)? {
            if let o = v as? JSONObject, let n = JSONRead.int(o, "count") { return (count: n, pct: JSONRead.double(o, "pct")) }
            if let v, !JSONRead.isBool(v), let n = v as? NSNumber { return (count: n.intValue, pct: nil) }
            return nil
        }
        let plat = (q["platforms"] as? JSONObject) ?? (q["platform"] as? JSONObject)
        var dups: Set<String> = []
        for p in JSONRead.objects(q["duplicates"] as? JSONObject, "phones") {
            let norm = (JSONRead.string(p, "phone") ?? "").filter { $0.isASCII && $0.isNumber }
            if !norm.isEmpty { dups.insert(norm) }
        }
        return LeadQualitySummary(total: JSONRead.int(q, "total") ?? JSONRead.int(q, "total_leads"),
                                  duplicates: pick(q["duplicates"]), invalid: pick(q["invalid"]),
                                  fb: pick(plat?["fb"]), ig: pick(plat?["ig"]), duplicatePhones: dups)
    }
}

/// A lead as the leads table shows it (leads.js enrichLead + renderTable).
struct LeadRow: Equatable, Identifiable {
    enum Quality: String { case clean, duplicate, invalid }
    let id: String
    let phone: String
    let platform: String          // lowercased as stored: fb, ig, facebook, instagram
    let adId: String
    let adName: String?
    let adsetId: String
    let adsetName: String?
    let campaignId: String
    let campaignName: String?
    let preview: String?
    let createdAt: Date?
    let quality: Quality

    var isFacebook: Bool { platform == "fb" || platform == "facebook" }
    var isInstagram: Bool { platform == "ig" || platform == "instagram" }

    /// api.js phoneCountry's validity half: 7-15 digits, not one digit repeated, not a test sequence.
    static func phoneValid(_ phone: String) -> Bool {
        let d = phone.filter { $0.isASCII && $0.isNumber }
        guard (7...15).contains(d.count) else { return false }
        if Set(d).count == 1 { return false }
        return !["1234567890", "0123456789", "0987654321"].contains(d)
    }

    static func parse(_ rows: [JSONObject], duplicatePhones: Set<String>, offset: Int = 0) -> [LeadRow] {
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let iso2 = ISO8601DateFormatter()
        return rows.enumerated().map { i, l in
            let phone = JSONRead.string(l, "phone") ?? ""
            let created = JSONRead.string(l, "created_at") ?? JSONRead.string(l, "stored_at") ?? ""
            let given = JSONRead.string(l, "quality").flatMap(Quality.init(rawValue:))
            let norm = phone.filter { $0.isASCII && $0.isNumber }
            // Order matters: invalid wins over duplicate (leads.js enrichLead).
            let q: Quality = given ?? (!phoneValid(phone) ? .invalid : (duplicatePhones.contains(norm) ? .duplicate : .clean))
            return LeadRow(
                id: JSONRead.string(l, "lead_id") ?? JSONRead.string(l, "id") ?? "l\(offset + i)-\(created)",
                phone: phone, platform: (JSONRead.string(l, "platform") ?? "").lowercased(),
                adId: JSONRead.string(l, "ad_id") ?? "", adName: JSONRead.string(l, "ad_name"),
                adsetId: JSONRead.string(l, "adset_id") ?? "", adsetName: JSONRead.string(l, "adset_name"),
                campaignId: JSONRead.string(l, "campaign_id") ?? "", campaignName: JSONRead.string(l, "campaign_name"),
                preview: JSONRead.string(l, "preview_url") ?? JSONRead.string(l, "thumbnail_url"),
                createdAt: iso.date(from: created) ?? iso2.date(from: created), quality: q)
        }
    }

    /// renderTable: newest first.
    static func newestFirst(_ rows: [LeadRow]) -> [LeadRow] {
        rows.enumerated().sorted { l, r in
            let a = l.element.createdAt ?? .distantPast, b = r.element.createdAt ?? .distantPast
            return a == b ? l.offset < r.offset : a > b
        }.map(\.element)
    }
}

/// The summary cards (leads.js renderSummary): the quality tool's numbers, the loaded rows when it has none.
struct LeadTotals: Equatable {
    let total: Int
    let dups: Int, dupsPct: Double
    let invalid: Int, invalidPct: Double
    let fb: Int, fbPct: Double
    let ig: Int, igPct: Double

    init(quality q: LeadQualitySummary, rows: [LeadRow]) {
        let total = q.total ?? rows.count
        func pct(_ v: (count: Int, pct: Double?)?, _ count: Int) -> Double {
            if let p = v?.pct { return p }
            return total > 0 ? Double(count) / Double(total) * 100 : 0
        }
        self.total = total
        dups = q.duplicates?.count ?? rows.filter { $0.quality == .duplicate }.count
        dupsPct = pct(q.duplicates, dups)
        invalid = q.invalid?.count ?? rows.filter { $0.quality == .invalid }.count
        invalidPct = pct(q.invalid, invalid)
        fb = q.fb?.count ?? rows.filter(\.isFacebook).count
        fbPct = pct(q.fb, fb)
        ig = q.ig?.count ?? rows.filter(\.isInstagram).count
        igPct = pct(q.ig, ig)
    }
}

/// The filter bar (leads.js visibleLeads): cascading campaign -> ad set -> ad, platform, quality, phone search.
struct LeadQuery: Equatable {
    var campaign = ""
    var adset = ""
    var ad = ""
    var platform = ""    // "", fb, ig
    var quality = ""     // "", clean, duplicate, invalid
    var search = ""

    func apply(_ rows: [LeadRow]) -> [LeadRow] {
        let q = search.lowercased().trimmingCharacters(in: .whitespaces)
        return rows.filter { l in
            if !campaign.isEmpty && l.campaignId != campaign { return false }
            if !adset.isEmpty && l.adsetId != adset { return false }
            if !ad.isEmpty && l.adId != ad { return false }
            if platform == "fb" && !l.isFacebook { return false }
            if platform == "ig" && !l.isInstagram { return false }
            if !quality.isEmpty && l.quality.rawValue != quality { return false }
            if !q.isEmpty && !l.phone.lowercased().contains(q) { return false }
            return true
        }
    }

    /// A parent change clears its children (onChange in renderFilters).
    mutating func setCampaign(_ id: String) { campaign = id; adset = ""; ad = "" }
    mutating func setAdset(_ id: String) { adset = id; ad = "" }
}

/// Names for the filter menus, from get_campaigns / get_adsets and the loaded leads themselves.
struct LeadOptions: Equatable {
    struct Item: Equatable, Identifiable { let id: String; let name: String; var parent: String = "" }
    var campaigns: [Item] = []
    var adsets: [Item] = []

    static func parseCampaigns(_ data: Data?) -> [Item] {
        guard let data, let o = JSONRead.object(data) else { return [] }
        let rows = JSONRead.objects(o, "campaigns").isEmpty ? JSONRead.objects(o, "data") : JSONRead.objects(o, "campaigns")
        return rows.compactMap { c in
            guard let id = JSONRead.string(c, "campaign_id") ?? JSONRead.string(c, "id") else { return nil }
            return Item(id: id, name: JSONRead.string(c, "name") ?? id)
        }
    }

    static func parseAdsets(_ data: Data?) -> [Item] {
        guard let data, let o = JSONRead.object(data) else { return [] }
        let rows = JSONRead.objects(o, "adsets").isEmpty ? JSONRead.objects(o, "data") : JSONRead.objects(o, "adsets")
        return rows.compactMap { s in
            guard let id = JSONRead.string(s, "adset_id") ?? JSONRead.string(s, "id") else { return nil }
            return Item(id: id, name: JSONRead.string(s, "name") ?? id, parent: JSONRead.string(s, "campaign_id") ?? "")
        }
    }

    func visibleAdsets(_ q: LeadQuery) -> [Item] { q.campaign.isEmpty ? adsets : adsets.filter { $0.parent == q.campaign } }

    /// The ad menu lists the ads that brought leads, narrowed by the chosen campaign / ad set.
    static func ads(_ rows: [LeadRow], _ q: LeadQuery) -> [Item] {
        var seen = Set<String>()
        var out: [Item] = []
        for l in rows where !l.adId.isEmpty && !seen.contains(l.adId) {
            if !q.adset.isEmpty && l.adsetId != q.adset { continue }
            if q.adset.isEmpty && !q.campaign.isEmpty && l.campaignId != q.campaign { continue }
            seen.insert(l.adId)
            out.append(Item(id: l.adId, name: l.adName ?? l.adId))
        }
        return out.sorted { $0.name.lowercased() < $1.name.lowercased() }
    }
}

/// Export CSV, written here from the loaded rows (the site downloads export_leads' file; the popup saves what it shows).
enum LeadsCSV {
    static let header = ["Created", "Phone", "Quality", "Platform", "Ad", "Ad ID", "Ad set", "Ad set ID", "Campaign ID"]

    static func field(_ s: String) -> String {
        let needs = s.contains(",") || s.contains("\"") || s.contains("\n") || s.contains("\r")
        return needs ? "\"" + s.replacingOccurrences(of: "\"", with: "\"\"") + "\"" : s
    }

    static func make(_ rows: [LeadRow], adName: (LeadRow) -> String = { $0.adName ?? "" },
                     adsetName: (LeadRow) -> String = { $0.adsetName ?? "" }) -> String {
        let iso = ISO8601DateFormatter()
        var lines = [header.joined(separator: ",")]
        for l in rows {
            let cells = [l.createdAt.map { iso.string(from: $0) } ?? "", l.phone, l.quality.rawValue, l.platform,
                         adName(l), l.adId, adsetName(l), l.adsetId, l.campaignId]
            lines.append(cells.map(field).joined(separator: ","))
        }
        return lines.joined(separator: "\r\n") + "\r\n"
    }

    /// leads.js runExport: leads-{account}-{from}-to-{to}.csv
    static func fileName(account: String, range: DateRange) -> String {
        "leads" + (account.isEmpty ? "" : "-" + account) + "-\(range.from)-to-\(range.to).csv"
    }
}
