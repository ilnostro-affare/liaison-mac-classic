import Foundation

/// A period a widget or a sheet is looking at. Same wording as bDates in ai.js.
struct DateRange: Equatable {
    var from: String   // YYYY-MM-DD
    var to: String

    static let months = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]

    var label: String {
        let f = from.split(separator: "-").compactMap { Int($0) }
        let t = to.split(separator: "-").compactMap { Int($0) }
        guard f.count == 3, t.count == 3, (1...12).contains(f[1]), (1...12).contains(t[1]) else { return "\(from) – \(to)" }
        if f[0] == t[0] && f[1] == t[1] { return "\(f[2])–\(t[2]) \(Self.months[f[1] - 1])" }
        if f[0] == t[0] { return "\(Self.months[f[1] - 1]) \(f[2]) – \(Self.months[t[1] - 1]) \(t[2])" }
        return "\(Self.months[f[1] - 1]) \(f[2]) '\(String(f[0]).suffix(2)) – \(Self.months[t[1] - 1]) \(t[2]) '\(String(t[0]).suffix(2))"
    }

    static func iso(_ d: Date, _ calendar: Calendar = Calendar(identifier: .gregorian)) -> String {
        let c = calendar.dateComponents([.year, .month, .day], from: d)
        return String(format: "%04d-%02d-%02d", c.year ?? 2026, c.month ?? 1, c.day ?? 1)
    }

    enum Preset: String, CaseIterable, Identifiable {
        case today = "Today", week = "Last 7 days", month = "Last 30 days", thisMonth = "This month", custom = "Custom range"
        var id: String { rawValue }
    }

    static func preset(_ p: Preset, now: Date, calendar: Calendar = Calendar(identifier: .gregorian)) -> DateRange? {
        let today = calendar.startOfDay(for: now)
        switch p {
        case .today: return DateRange(from: iso(today, calendar), to: iso(today, calendar))
        case .week: return DateRange(from: iso(calendar.date(byAdding: .day, value: -6, to: today) ?? today, calendar), to: iso(today, calendar))
        case .month: return DateRange(from: iso(calendar.date(byAdding: .day, value: -29, to: today) ?? today, calendar), to: iso(today, calendar))
        case .thisMonth:
            var c = calendar.dateComponents([.year, .month], from: today)
            c.day = 1
            return DateRange(from: iso(calendar.date(from: c) ?? today, calendar), to: iso(today, calendar))
        case .custom: return nil
        }
    }
}

/// get_creative_analysis: the "Creative performance" widget (best creative, the strip, four numbers).
struct CreativeStat: Equatable, Identifiable {
    let id: String
    let name: String
    let image: String?
    let cpl: Double?
    let leads: Int?
    let spend: Double?
    let ctr: Double?
    let campaign: String?
    let adset: String?
    let rank: Int?
    let isVideo: Bool

    init?(json c: JSONObject, index: Int) {
        guard let id = JSONRead.string(c, "id") ?? JSONRead.string(c, "ad_id") else { return nil }
        self.id = id
        name = JSONRead.string(c, "name") ?? JSONRead.string(c, "ad_name") ?? id
        image = JSONRead.string(c, "img") ?? JSONRead.string(c, "preview") ?? JSONRead.string(c, "thumbnail_url")
        cpl = JSONRead.double(c, "cpl")
        leads = JSONRead.int(c, "leads")
        spend = JSONRead.double(c, "spend")
        ctr = JSONRead.double(c, "ctr")
        campaign = JSONRead.string(c, "campaign")
        adset = JSONRead.string(c, "adset")
        rank = JSONRead.int(c, "rank") ?? (index + 1)
        isVideo = JSONRead.string(c, "video_id") != nil || JSONRead.string(c, "type") == "video"
    }

    var context: String? {
        let t = [campaign, adset].compactMap { $0 }.filter { !$0.isEmpty }
        return t.isEmpty ? nil : t.joined(separator: " · ")
    }
}

struct CreativePerformance: Equatable {
    let account: String?
    let accountName: String?
    let period: DateRange?
    let creatives: [CreativeStat]
    let bestId: String?
    let count: Int
    let avgCPL: Double?
    let leads: Int?
    let worstCPL: Double?
    let currency: String?

    static func parse(_ o: JSONObject?) -> CreativePerformance? {
        guard let o else { return nil }
        let list = JSONRead.objects(o, "creatives").enumerated().compactMap { CreativeStat(json: $0.element, index: $0.offset) }
        guard !list.isEmpty else { return nil }
        let kpi = o["kpi"] as? JSONObject
        let p = o["period"] as? JSONObject
        return CreativePerformance(
            account: JSONRead.string(o, "account"), accountName: JSONRead.string(o, "account_name"),
            period: (JSONRead.string(p, "from")).flatMap { f in JSONRead.string(p, "to").map { DateRange(from: f, to: $0) } },
            creatives: list, bestId: JSONRead.string(o, "best_id"),
            count: JSONRead.int(kpi, "count") ?? list.count,
            avgCPL: JSONRead.double(kpi, "avg_cpl"), leads: JSONRead.int(kpi, "leads"),
            worstCPL: JSONRead.double(kpi, "worst_cpl"), currency: JSONRead.string(o, "currency"))
    }

    var best: CreativeStat? { creatives.first { $0.id == bestId } ?? creatives.first }
}

/// get_creatives: the plain gallery (previews and names, no numbers).
struct CreativeGallery: Equatable {
    let items: [CreativeStat]

    static func parse(_ o: JSONObject?) -> CreativeGallery? {
        guard let o else { return nil }
        let raw = (o["items"] as? [Any]) ?? (o["creatives"] as? [Any]) ?? []
        let items = raw.compactMap { $0 as? JSONObject }.enumerated().compactMap { CreativeStat(json: $0.element, index: $0.offset) }
        return items.isEmpty ? nil : CreativeGallery(items: items)
    }
}

/// The leads widget (blkLeads) and the rows behind it (/meta/vali/leads).
struct LeadsSummary: Equatable {
    let account: String?
    let accountName: String?
    let period: DateRange?
    let total: Int
    let withPhone: Int
    let instagram: Int
    let facebook: Int
    let creatives: Int
    let adsets: Int
    let topCreatives: [(name: String, id: String, count: Int, image: String?)]

    static func == (a: LeadsSummary, b: LeadsSummary) -> Bool {
        a.total == b.total && a.withPhone == b.withPhone && a.account == b.account && a.period == b.period
            && a.topCreatives.map(\.id) == b.topCreatives.map(\.id)
    }

    var phonePercent: Int { total > 0 ? Int((Double(withPhone) / Double(total) * 100).rounded()) : 0 }

    static func parse(_ o: JSONObject?) -> LeadsSummary? {
        guard let o, let total = JSONRead.int(o, "total") else { return nil }
        let plat = o["by_platform"] as? JSONObject
        let p = o["period"] as? JSONObject
        let tops = JSONRead.objects(o, "by_creative").prefix(5).compactMap { c -> (String, String, Int, String?)? in
            let id = JSONRead.string(c, "ad_id") ?? JSONRead.string(c, "id") ?? ""
            let n = JSONRead.string(c, "name") ?? JSONRead.string(c, "ad_name") ?? id
            guard !n.isEmpty else { return nil }
            return (n, id, JSONRead.int(c, "leads") ?? JSONRead.int(c, "count") ?? 0, JSONRead.string(c, "img") ?? JSONRead.string(c, "preview"))
        }
        return LeadsSummary(
            account: JSONRead.string(o, "account"), accountName: JSONRead.string(o, "account_name"),
            period: (JSONRead.string(p, "from")).flatMap { f in JSONRead.string(p, "to").map { DateRange(from: f, to: $0) } },
            total: total, withPhone: JSONRead.int(o, "with_phone") ?? 0,
            instagram: JSONRead.int(plat, "instagram") ?? JSONRead.int(plat, "ig") ?? 0,
            facebook: JSONRead.int(plat, "facebook") ?? JSONRead.int(plat, "fb") ?? 0,
            creatives: JSONRead.int(o, "creatives_count") ?? JSONRead.objects(o, "by_creative").count,
            adsets: JSONRead.int(o, "adsets_count") ?? JSONRead.objects(o, "by_adset").count,
            topCreatives: tops.map { (name: $0.0, id: $0.1, count: $0.2, image: $0.3) })
    }
}

struct Lead: Equatable, Identifiable {
    enum Quality: String { case clean, duplicate, invalid }
    let id: String
    let phone: String
    let platform: String
    let adId: String?
    let adName: String?
    let createdAt: Date?
    var quality: Quality = .clean

    /// Digits in groups, the way the web prints a phone: +39 200 000 00 01.
    var prettyPhone: String {
        let digits = phone.filter(\.isNumber)
        guard digits.count >= 9 else { return phone }
        let cc = String(digits.prefix(digits.count > 10 ? 2 : 1))
        let rest = Array(digits.dropFirst(cc.count))
        var parts: [String] = []
        var i = 0
        for size in [3, 3, 2, 2, 3, 3] where i < rest.count {
            parts.append(String(rest[i..<min(i + size, rest.count)]))
            i += size
        }
        return "+" + cc + " " + parts.joined(separator: " ")
    }

    /// Quality is not stored: duplicates and unusable numbers are decided here, as the leads screen does.
    static func parseList(_ data: Data) -> [Lead] {
        guard let o = JSONRead.object(data) else { return [] }
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let iso2 = ISO8601DateFormatter()
        var seen: [String: Int] = [:]
        var out: [Lead] = []
        for (i, l) in JSONRead.objects(o, "leads").enumerated() {
            let phone = JSONRead.string(l, "phone") ?? ""
            let created = JSONRead.string(l, "created_at") ?? JSONRead.string(l, "stored_at") ?? ""
            var lead = Lead(id: JSONRead.string(l, "id") ?? "l\(i)-\(created)", phone: phone,
                            platform: (JSONRead.string(l, "platform") ?? "unknown").lowercased(),
                            adId: JSONRead.string(l, "ad_id"), adName: JSONRead.string(l, "ad_name"),
                            createdAt: iso.date(from: created) ?? iso2.date(from: created))
            let digits = phone.filter(\.isNumber)
            if digits.count < 7 || Set(digits).count == 1 {
                lead.quality = .invalid
            } else if seen[digits] != nil {
                lead.quality = .duplicate
            }
            seen[digits, default: 0] += 1
            out.append(lead)
        }
        return out.sorted { ($0.createdAt ?? .distantPast) > ($1.createdAt ?? .distantPast) }
    }
}
