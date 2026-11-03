import XCTest
import Foundation
@testable import Liaison

/// The address bar's campaign / ad set / ad search by name (Shared/Core/OmniEntities.swift).
final class OmniEntitiesTests: XCTestCase {
    private let json = #"""
    {"ok":true,"structure":{
      "111":{"id":"111","name":"Spring Sale","status":"ACTIVE","effective_status":"ACTIVE","adsets":{
        "211":{"id":"211","name":"Milano women","status":"PAUSED","effective_status":"PAUSED","ads":[
          {"id":"311","name":"Café video","status":"ACTIVE","effective_status":"ADSET_PAUSED"},
          {"id":"312","name":"","status":"ACTIVE","effective_status":"ACTIVE"}]}}},
      "112":{"id":"112","name":"Копия Барса","status":"PAUSED","effective_status":"PAUSED","adsets":{}},
      "113":{"id":"113","name":"Old","status":"DELETED","adsets":{}},
      "114":{"id":"","name":"","status":null,"adsets":{
        "214":{"id":"214","name":"Orphan set","effective_status":"ACTIVE","ads":[]}}}
    },"_liaison":{}}
    """#

    private var items: [OmniEntity] { OmniEntities.parse(Data(json.utf8)) ?? [] }

    func testParseWalksTheStructure() {
        let e = items
        XCTAssertEqual(Set(e.map(\.id)), ["111", "211", "311", "112", "214"])
        let ad = e.first { $0.id == "311" }
        XCTAssertEqual(ad?.level, .ad)
        XCTAssertEqual(ad?.status, "ADSET_PAUSED")
        XCTAssertEqual(ad?.path, "Spring Sale / Milano women")
        XCTAssertEqual(e.first { $0.id == "211" }?.path, "Spring Sale")
        XCTAssertEqual(e.first { $0.id == "214" }?.path, "")
    }

    func testParseRejectsErrors() {
        XCTAssertNil(OmniEntities.parse(Data(#"{"ok":false,"error":"Graph read failed"}"#.utf8)))
        XCTAssertNil(OmniEntities.parse(Data("nope".utf8)))
        XCTAssertEqual(OmniEntities.parse(Data(#"{"ok":true,"structure":{}}"#.utf8))?.count, 0)
    }

    func testFoldedMatching() {
        XCTAssertEqual(OmniEntities.matches("CAFE", in: items).map(\.id), ["311"])
        XCTAssertEqual(OmniEntities.matches("барс", in: items).map(\.id), ["112"])
        XCTAssertEqual(OmniEntities.matches("s", in: items), [])
        XCTAssertEqual(OmniEntities.matches("  ", in: items), [])
        XCTAssertEqual(OmniEntities.matches("zzz", in: items), [])
    }

    func testWordPrefixBeatsSubstring() {
        let list = [
            OmniEntity(id: "1", name: "Promo winter", level: .campaign, status: "ACTIVE", path: ""),
            OmniEntity(id: "2", name: "Interior", level: .campaign, status: "ACTIVE", path: ""),
            OmniEntity(id: "3", name: "Winter 2", level: .ad, status: "PAUSED", path: ""),
            OmniEntity(id: "4", name: "Wintertime", level: .adSet, status: "PAUSED", path: ""),
        ]
        // "Winter 2" and "Wintertime" start with it, "Promo winter" has a word starting with it, "Interior" only contains "int".
        XCTAssertEqual(OmniEntities.matches("win", in: list, limit: 5).map(\.id), ["4", "3", "1"])
        XCTAssertEqual(OmniEntities.matches("int", in: list, limit: 5).map(\.id), ["2", "1", "4", "3"])
        XCTAssertEqual(OmniEntities.matches("ter", in: list, limit: 5).count, 4)
        XCTAssertEqual(OmniEntities.matches("win", in: list).count, 3)
    }

    func testActiveAndLevelBreakTies() {
        let list = [
            OmniEntity(id: "a", name: "Brand ad", level: .ad, status: "ACTIVE", path: ""),
            OmniEntity(id: "b", name: "Brand set", level: .adSet, status: "PAUSED", path: ""),
            OmniEntity(id: "c", name: "Brand camp", level: .campaign, status: "PAUSED", path: ""),
        ]
        XCTAssertEqual(OmniEntities.matches("brand", in: list).map(\.id), ["a", "c", "b"])
    }

    func testAdsManagerURL() {
        let e = items
        let c = OmniEntities.adsManagerURL(e.first { $0.id == "111" }!, account: "act_123")!.absoluteString
        XCTAssertEqual(c, "https://adsmanager.facebook.com/adsmanager/manage/campaigns?act=123&selected_campaign_ids=111")
        let s = OmniEntities.adsManagerURL(e.first { $0.id == "211" }!, account: "123")!.absoluteString
        XCTAssertEqual(s, "https://adsmanager.facebook.com/adsmanager/manage/adsets?act=123&selected_adset_ids=211")
        let a = OmniEntities.adsManagerURL(e.first { $0.id == "311" }!, account: nil)!.absoluteString
        XCTAssertEqual(a, "https://adsmanager.facebook.com/adsmanager/manage/ads?selected_ad_ids=311")
    }

    func testLabels() {
        let ad = items.first { $0.id == "311" }!
        XCTAssertEqual(ad.statusLabel, "Ad set paused")
        XCTAssertEqual(OmniEntities.detail(ad), "Ad \u{00B7} Ad set paused \u{00B7} Spring Sale / Milano women")
        XCTAssertEqual(OmniEntity(id: "1", name: "x", level: .campaign, status: "CAMPAIGN_PAUSED", path: "").statusLabel, "Campaign paused")
        XCTAssertEqual(OmniEntity(id: "1", name: "x", level: .campaign, status: "", path: "").statusLabel, "")
        XCTAssertTrue(OmniEntities.askMet(ad).contains("ID 311"))
    }

    func testBookTiming() {
        var b = OmniEntityBook()
        XCTAssertTrue(b.due(now: 1000))
        b.triedAt = 1000
        XCTAssertFalse(b.due(now: 1030))       // in flight or just failed
        XCTAssertTrue(b.due(now: 1061))        // a failed read is retried after a minute
        b.loadedAt = 1061; b.triedAt = 1061
        XCTAssertFalse(b.due(now: 1061 + 599))
        XCTAssertTrue(b.due(now: 1061 + 600))
    }
}
