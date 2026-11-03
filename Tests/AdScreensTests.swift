import XCTest
import Foundation
#if canImport(Liaison)
@testable import Liaison
#endif

// The in-chat Creatives / Ad / Leads popups: creatives.js and leads.js as data.
final class AdScreensTests: XCTestCase {
    private func data(_ s: String) -> Data { Data(s.utf8) }

    func testSiteFormatting() {
        XCTAssertEqual(SiteFmt.eur(1234.5), "\u{20ac}1,234.50")
        XCTAssertEqual(SiteFmt.eur(nil), "\u{2014}")
        XCTAssertEqual(SiteFmt.int(1234.6), "1,235")
        XCTAssertEqual(SiteFmt.pct(0.567), "0.57%")
        XCTAssertEqual(SiteFmt.compactEur(12_400), "\u{20ac}12k")
        XCTAssertEqual(SiteFmt.compactEur(1_540), "\u{20ac}1.5k")
        XCTAssertEqual(SiteFmt.compactEur(37.4), "\u{20ac}37")
        XCTAssertEqual(SiteFmt.share(12.4), "12%")
        XCTAssertEqual(SiteFmt.share(3.14), "3.1%")
        XCTAssertEqual(SiteFmt.status("ADSET_PAUSED").label, "Adset paused")
        XCTAssertTrue(SiteFmt.status("ACTIVE").active)
        XCTAssertFalse(SiteFmt.status("PAUSED").active)
        XCTAssertEqual(SiteFmt.phone("+392000000001"), "+39 200 000 0001")
        XCTAssertEqual(SiteFmt.phone("392000000001"), "39 200 000 0001")
        XCTAssertEqual(SiteFmt.phone("12345"), "12345")
        XCTAssertEqual(SiteFmt.phone(""), "\u{2014}")
        let d = ISO8601DateFormatter().date(from: "2026-09-17T16:24:00Z")
        XCTAssertEqual(SiteFmt.time(d, timeZone: TimeZone(identifier: "UTC")!), "17/09/2026, 16:24")
    }

    func testDateButtonAndPresets() {
        XCTAssertEqual(DateRange(from: "2026-10-01", to: "2026-10-08").buttonLabel, "Oct 1 - 8, 2026")
        XCTAssertEqual(DateRange(from: "2026-09-09", to: "2026-10-08").buttonLabel, "Sep 9 - Oct 8, 2026")
        XCTAssertEqual(DateRange(from: "2025-12-30", to: "2026-01-02").buttonLabel, "Dec 30, 2025 - Jan 2, 2026")
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        let now = Date(timeIntervalSince1970: 1_789_000_000)   // UTC
        XCTAssertEqual(DateRange.lastDays(30, now: now, calendar: cal), DateRange(from: "2026-08-12", to: "2026-09-10"))
        XCTAssertEqual(DateRange.lastDays(7, now: now, calendar: cal), DateRange(from: "2026-09-04", to: "2026-09-10"))
        XCTAssertEqual(DateRange.lastDays(14, now: now, calendar: cal).presetDays(now: now, calendar: cal), 14)
        XCTAssertNil(DateRange(from: "2026-01-01", to: "2026-01-31").presetDays(now: now, calendar: cal))
    }

    private let tree = #"""
    {"ok":true,"tree":{"c1":{"id":"c1","name":"Lead Test","adsets":{"s1":{"id":"s1","name":"Cinisello","ads":[
      {"ad_id":"a1","name":" Barsa ","status":"ACTIVE","effective_status":"ADSET_PAUSED","status_ui":"ADSET_PAUSED","spend":159.39,"leads":18,"ctr":0.56,"cpl":8.85},
      {"ad_id":"a2","name":"Concerto","effective_status":"PAUSED","spend":2.51,"leads":0,"ctr":0.29,"cpl":null}]},
      "s2":{"id":"s2","name":"Wide","ads":[{"ad_id":"a3","name":"","status":"ACTIVE","spend":"297.81","leads":52,"ctr":0.57,"cpl":5.73},{"name":"no id"}]}}},
      "c0":{"id":"c0","name":"Brand","adsets":{"s9":{"id":"s9","name":"All","ads":[{"ad_id":"a4","name":"Zeta","status_ui":"ACTIVE","spend":10,"leads":1,"cpl":10}]}}}}}
    """#

    func testTreeFlattensAndQueriesLikeTheScreen() {
        let rows = AdsTree.flatten(data(tree))
        XCTAssertEqual(rows.map(\.id), ["a4", "a1", "a2", "a3"])
        XCTAssertEqual(rows[1].name, "Barsa")
        XCTAssertEqual(rows[1].status, "ADSET_PAUSED")
        XCTAssertEqual(rows[2].status, "PAUSED")
        XCTAssertEqual(rows[3].spend, 297.81)
        XCTAssertEqual(rows[3].displayName, "ad \u{00b7} a3")
        XCTAssertEqual(rows[1].crumbs, "Lead Test / Cinisello")
        XCTAssertNil(rows[2].cpl)

        var q = CreativeQuery()
        XCTAssertEqual(q.apply(rows).map(\.id), ["a3", "a1", "a4", "a2"])
        q.column = .cpl
        XCTAssertEqual(q.apply(rows).map(\.id), ["a4", "a1", "a3", "a2"], "no CPL goes last, descending")
        q.descending = false
        XCTAssertEqual(q.apply(rows).map(\.id), ["a3", "a1", "a4", "a2"], "and last ascending too")
        q = CreativeQuery(search: "WIDE")
        XCTAssertEqual(q.apply(rows).map(\.id), ["a3"])
        q = CreativeQuery(search: "a2")
        XCTAssertEqual(q.apply(rows).map(\.id), ["a2"], "a bare ad id finds the ad")
        q = CreativeQuery(status: "PAUSED")
        XCTAssertEqual(q.apply(rows).map(\.id), ["a2"])
        q = CreativeQuery(campaign: "c0")
        XCTAssertEqual(q.apply(rows).map(\.id), ["a4"])
        XCTAssertEqual(CreativeQuery.statuses(rows), ["ACTIVE", "ADSET_PAUSED", "PAUSED"])
        XCTAssertEqual(CreativeQuery.campaigns(rows).map(\.name), ["Brand", "Lead Test"])
        XCTAssertTrue(AdsTree.flatten(data(#"{"ok":true,"tree":{}}"#)).isEmpty)
    }

    func testPreviewsMapOrArray() {
        let m = CreativePreview.parseMap(data(#"{"creatives":{"a1":{"type":"video","preview":"p","video_source":"https://api.liaisone.com/meta/video?video_id=1","video_permalink":"/reel/1/"},"a2":{"preview":"q","preview_hi":"qh"}}}"#))
        XCTAssertTrue(m["a1"]?.isVideo == true)
        XCTAssertEqual(m["a1"]?.best, "p")
        XCTAssertEqual(m["a2"]?.best, "qh")
        let a = CreativePreview.parseMap(data(#"{"creatives":[{"ad_id":"x","thumbnail_url":"t"}]}"#))
        XCTAssertEqual(a["x"]?.preview, "t")
        XCTAssertTrue(CreativePreview.parseMap(data("{}")).isEmpty)
    }

    func testAdModalTabs() {
        let t = CreativeText.parse(data(#"{"ads":[{"ad_id":"a1","creative":{"title":null,"body":"Impara\nVieni","cta":"SIGN_UP","video_id":"17","type":"video","thumbnail_url":"th"}}]}"#))
        XCTAssertEqual(t?.body, "Impara\nVieni")
        XCTAssertNil(t?.title)
        XCTAssertTrue(t?.hasText == true)
        XCTAssertTrue(t?.isVideo == true)
        XCTAssertFalse(CreativeText.parse(data(#"{"ads":[{"creative":{"title":""}}]}"#))?.hasText ?? true)
        XCTAssertNil(CreativeText.parse(data(#"{"ads":[]}"#)))

        let demo = AdDemographics.parse(data(#"{"ads":[{"ad_id":"z"},{"ad_id":"a1","by_age":[{"age":"35-44","spend":10,"leads":2},{"age":"18-24","spend":5,"leads":0}],"by_gender":[{"gender":"female","spend":3,"leads":1},{"gender":"male","spend":4,"leads":0}]}]}"#), adId: "a1")
        XCTAssertEqual(demo?.age.map(\.label), ["18-24", "35-44"])
        XCTAssertEqual(demo?.gender.map(\.label), ["male", "female"])
        XCTAssertEqual(demo?.age.last?.sub, "2l \u{00b7} \u{20ac}5.00")
        XCTAssertEqual(demo?.age.first?.sub, "\u{2014}")
        XCTAssertNil(AdDemographics.parse(data(#"{"ads":[{"ad_id":"a1","by_age":[],"by_gender":[]}]}"#), adId: "a1"))

        let plat = AdPlatforms.parse(data(#"{"ads":[{"ad_id":"a1","platforms":[{"platform":"facebook","spend":27.5,"leads":1},{"platform":"instagram","spend":114.65,"leads":20}]}]}"#), adId: "a1")
        XCTAssertEqual(plat.map(\.label), ["facebook", "instagram"])
        XCTAssertTrue(AdPlatforms.parse(data(#"{"ads":[]}"#), adId: "a1").isEmpty)

        let daily = AdDaily.parse(data(#"{"ads":[{"ad_id":"a1","daily":[{"date":"2026-10-01","spend":10,"leads":2,"cpl":5},{"date":"2026-10-02","spend":6,"leads":0}],"fatigue":{"status":"fatiguing","change_pct":-34,"cpl_first_half":5,"cpl_second_half":9}}]}"#), adId: "a1")
        XCTAssertEqual(daily?.days.count, 2)
        XCTAssertEqual(daily?.totalSpend, 16)
        XCTAssertEqual(daily?.fatigue?.status, "fatiguing")
        XCTAssertNil(AdDaily.parse(data(#"{"ads":[{"ad_id":"a1","daily":[]}]}"#), adId: "a1"))
    }

    private let leadsJSON = #"""
    {"leads":[
      {"id":"l1","phone":"+392000000001","platform":"ig","ad_id":"a1","ad_name":"Barsa","adset_id":"s1","campaign_id":"c1","created_at":"2026-09-17T15:58:00Z"},
      {"id":"l2","phone":"392000000001","platform":"FB","ad_id":"a1","adset_id":"s1","campaign_id":"c1","created_at":"2026-09-17T16:24:00.000Z"},
      {"id":"l3","phone":"1111111","platform":"facebook","ad_id":"a2","adset_id":"s2","campaign_id":"c2","created_at":"2026-09-16T10:00:00Z"},
      {"id":"l4","phone":"+39 333 123, \"x\"","platform":"instagram","ad_id":"a3","ad_name":"Wide, big","adset_id":"s3","campaign_id":"c2","stored_at":"2026-09-18T09:00:00Z"}
    ],"has_more":true,"total":250}
    """#

    func testLeadRowsQualityAndPaging() {
        let page = LeadPage.parse(data(leadsJSON))
        XCTAssertTrue(page.hasMore)
        XCTAssertEqual(page.total, 250)
        let quality = LeadQualitySummary.parse(data(#"{"total":250,"duplicates":{"count":13,"pct":5.2,"phones":[{"phone":"+39 200 000 0001"}]},"invalid":{"count":4},"platforms":{"fb":{"count":60,"pct":24},"ig":{"count":190,"pct":76}}}"#))
        XCTAssertEqual(quality.duplicatePhones, ["392000000001"])
        let rows = LeadRow.parse(page.rows, duplicatePhones: quality.duplicatePhones)
        XCTAssertEqual(rows.map(\.quality), [.duplicate, .duplicate, .invalid, .clean])
        XCTAssertEqual(rows[1].platform, "fb")
        XCTAssertTrue(rows[1].isFacebook)
        XCTAssertNotNil(rows[1].createdAt, "fractional seconds parse")
        XCTAssertNotNil(rows[3].createdAt, "stored_at stands in")
        XCTAssertEqual(LeadRow.newestFirst(rows).map(\.id), ["l4", "l2", "l1", "l3"])

        let totals = LeadTotals(quality: quality, rows: rows)
        XCTAssertEqual(totals.total, 250)
        XCTAssertEqual(totals.dups, 13)
        XCTAssertEqual(totals.invalid, 4)
        XCTAssertTrue(abs(totals.invalidPct - 1.6) < 0.001)
        XCTAssertEqual(totals.igPct, 76)
        let local = LeadTotals(quality: LeadQualitySummary.parse(nil), rows: rows)
        XCTAssertEqual(local.total, 4)
        XCTAssertEqual(local.fb, 2)
        XCTAssertEqual(local.ig, 2)
        XCTAssertEqual(local.fbPct, 50)
        XCTAssertFalse(LeadRow.phoneValid("0123456789"))
        XCTAssertTrue(LeadRow.phoneValid("2000000001"))
    }

    func testLeadFiltersCascadeAndExport() {
        let rows = LeadRow.parse(LeadPage.parse(data(leadsJSON)).rows, duplicatePhones: [])
        var q = LeadQuery()
        q.platform = "ig"
        XCTAssertEqual(q.apply(rows).map(\.id), ["l1", "l4"])
        q = LeadQuery(quality: "invalid")
        XCTAssertEqual(q.apply(rows).map(\.id), ["l3"])
        q = LeadQuery(search: "333")
        XCTAssertEqual(q.apply(rows).map(\.id), ["l4"])
        q = LeadQuery()
        q.setCampaign("c2")
        XCTAssertEqual(LeadOptions.ads(rows, q).map(\.id), ["a2", "a3"])
        q.setAdset("s3"); q.ad = "a3"
        XCTAssertEqual(q.apply(rows).map(\.id), ["l4"])
        q.setCampaign("c1")
        XCTAssertEqual(q.adset, "")
        XCTAssertEqual(q.ad, "")
        let opts = LeadOptions(campaigns: LeadOptions.parseCampaigns(data(#"{"campaigns":[{"campaign_id":"c1","name":"One"}]}"#)),
                               adsets: LeadOptions.parseAdsets(data(#"{"data":[{"id":"s1","name":"S","campaign_id":"c1"},{"id":"s2","campaign_id":"c2"}]}"#)))
        XCTAssertEqual(opts.campaigns.first?.name, "One")
        XCTAssertEqual(opts.visibleAdsets(q).map(\.id), ["s1"])

        let csv = LeadsCSV.make([rows[3], rows[0]])
        let lines = csv.components(separatedBy: "\r\n")
        XCTAssertEqual(lines[0], "Created,Phone,Quality,Platform,Ad,Ad ID,Ad set,Ad set ID,Campaign ID")
        XCTAssertEqual(lines[1], #"2026-09-18T09:00:00Z,"+39 333 123, ""x""",clean,instagram,"Wide, big",a3,,s3,c2"#)
        XCTAssertEqual(lines[2], "2026-09-17T15:58:00Z,+392000000001,clean,ig,Barsa,a1,,s1,c1")
        XCTAssertEqual(LeadsCSV.fileName(account: "372555795343518", range: DateRange(from: "2026-09-01", to: "2026-09-30")),
                       "leads-372555795343518-2026-09-01-to-2026-09-30.csv")
    }
}
