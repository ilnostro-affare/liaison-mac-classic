import XCTest
import Foundation
#if canImport(Liaison)
@testable import Liaison
#endif

// Lia 2.0's live trace (server): the stream lines as the server sent them, and the beats the
// browser overlay plays from them.
final class AgentTraceTests: XCTestCase {
    private func ev(_ json: String) -> AgentEvent? { AgentEvent.parse(line: "data:" + json) }

    func testParsesTheTraceEventsAsTheServerSendsThem() {
        XCTAssertEqual(ev(#"{"type":"act_intent","call":"c1","tool":"create_campaign","label":"Preparing the campaign","door":true}"#),
                       .intent(call: "c1", tool: "create_campaign", label: "Preparing the campaign", door: true))
        XCTAssertEqual(ev(#"{"type":"act_arg","call":"c1","key":"daily_budget","value":5,"done":true}"#),
                       .arg(call: "c1", key: "daily_budget", value: "5", done: true))
        XCTAssertEqual(ev(#"{"type":"act_arg","call":"c1","key":"name","value":"Курс","done":false}"#),
                       .arg(call: "c1", key: "name", value: "Курс", done: false))
        XCTAssertEqual(ev(#"{"type":"act_step","id":"a1","step":"meta_check","account":"372555795343518"}"#),
                       .step(id: "a1", step: "meta_check", account: "372555795343518", reason: nil))
        guard case let .done(id, sum)? = ev(#"{"type":"act_done","id":"a1","sum":{"ok":true,"door":true,"plan_id":"p1","title":"T","diff":[{"label":"Budget","old":"—","new":"5 EUR/day"}]}}"#) else {
            return XCTFail("act_done with sum")
        }
        XCTAssertEqual(id, "a1")
        XCTAssertEqual(sum.planId, "p1")
        XCTAssertEqual(sum.diff, [GateDiffRow(label: "Budget", old: "—", new: "5 EUR/day")])
    }

    func testLia14LinesAreNotTrace() {
        // 1.4's act_start has no targs and its act_done no sum: they stay ordinary ChatEvents.
        XCTAssertNil(ev(#"{"type":"act_start","id":"a1","tool":"get_account_stats","label":"Reading"}"#))
        XCTAssertNil(ev(#"{"type":"act_done","id":"a1"}"#))
        XCTAssertNil(ev(#"{"type":"delta","text":"hi"}"#))
    }

    func testValuesReadAsAdsManagerShowsThem() {
        XCTAssertEqual(AgentValue.display("OUTCOME_LEADS"), "Leads")
        XCTAssertEqual(AgentValue.display("LOWEST_COST_WITHOUT_CAP"), "Lowest cost without cap")
        XCTAssertEqual(AgentValue.display("Курс йоги"), "Курс йоги")
        XCTAssertEqual(AgentValue.text(["Milan", "Rome"]), "Milan, Rome")
        XCTAssertEqual(AgentValue.text(NSNumber(value: 150)), "150")
        XCTAssertEqual(AgentValue.display("instant_forms"), "Instant forms")
        XCTAssertEqual(AgentValue.display("off"), "Off")
        XCTAssertEqual(AgentValue.display(#"{"cities":[{"key":"1184376","radius_km":17}]}"#), "1 city \u{00b7} +17 km")
        XCTAssertEqual(AgentValue.display("159013140636607"), "")
    }

    func testANewCampaignOpensTheListAimsAtCreateAndFillsAGhostRow() {
        var run = AgentRun()
        XCTAssertEqual(run.feed(.intent(call: "c1", tool: "create_campaign", label: "Preparing the campaign", door: true)), [])
        XCTAssertEqual(run.feed(.arg(call: "c1", key: "account", value: "372555795343518", done: true)),
                       [.open(URL(string: "https://adsmanager.facebook.com/adsmanager/manage/campaigns?act=372555795343518")!), .point(.create(.campaigns))])
        XCTAssertEqual(run.feed(.arg(call: "c1", key: "name", value: "Lia 2.0 trace test", done: true)),
                       [.ghostRow(title: "New campaign"), .field(key: "name", label: "Name", value: "Lia 2.0 trace test", done: true)])
        XCTAssertEqual(run.feed(.arg(call: "c1", key: "objective", value: "OUTCOME_LEADS", done: true)),
                       [.field(key: "objective", label: "Objective", value: "Leads", done: true)])
        XCTAssertEqual(run.feed(.arg(call: "c1", key: "spend_cap", value: "", done: true)), [])
        let start = run.feed(.start(id: "a1", call: "c1", tool: "create_campaign", label: "",
                                    args: ["account": "372555795343518", "name": "Lia 2.0 trace test", "objective": "OUTCOME_LEADS", "daily_budget": "5"]))
        XCTAssertEqual(start, [.field(key: "daily_budget", label: "Daily budget", value: "5", done: true)])
        XCTAssertEqual(run.feed(.step(id: "a1", step: "meta_check", account: nil, reason: nil)), [.checking])
        var s = AgentSum(); s.diff = [GateDiffRow(label: "Budget", old: "—", new: "5 EUR/day")]
        XCTAssertEqual(run.feed(.done(id: "a1", sum: s)), [.result(ok: true, error: nil, diff: s.diff)])
        // after Yes: Meta's own editor of the new campaign, and the cursor walks its fields
        XCTAssertEqual(run.feed(.applied(entityType: "campaign", entityId: nil, createdId: "120249", account: nil, error: nil)),
                       [.applied(URL(string: "https://adsmanager.facebook.com/adsmanager/manage/campaigns/edit/standalone?act=372555795343518&selected_campaign_ids=120249")!, ok: true, error: nil, walk: true), .finish])
    }

    func testANewAdSetWaitsForItsCampaignThenOpensItsAdSets() {
        var run = AgentRun(defaultAccount: "1")
        _ = run.feed(.intent(call: "c", tool: "create_ad_set", label: "", door: true))
        XCTAssertEqual(run.feed(.arg(call: "c", key: "name", value: "Milano 25-45", done: true)), [])
        XCTAssertEqual(run.feed(.arg(call: "c", key: "campaign_id", value: "777", done: true)),
                       [.open(URL(string: "https://adsmanager.facebook.com/adsmanager/manage/adsets?act=1&selected_campaign_ids=777")!), .point(.create(.adsets))])
        let applied = run.feed(.applied(entityType: "ad_set", entityId: nil, createdId: "888", account: nil, error: nil))
        XCTAssertEqual(applied.first, .applied(URL(string: "https://adsmanager.facebook.com/adsmanager/manage/adsets/edit/standalone?act=1&selected_campaign_ids=777&selected_adset_ids=888")!, ok: true, error: nil, walk: true))
    }

    func testAChangeOpensMetasOwnEditorOfThatObject() {
        var run = AgentRun(defaultAccount: "1", kindOf: { $0 == "55" ? "adset" : nil }, parentOf: { $0 == "55" ? "9" : nil })
        _ = run.feed(.intent(call: "c", tool: "update_entity", label: "", door: true))
        XCTAssertEqual(run.feed(.arg(call: "c", key: "daily_budget", value: "20", done: true)), [])   // which object: not yet
        XCTAssertEqual(run.feed(.arg(call: "c", key: "entity_id", value: "55", done: true)),
                       [.open(URL(string: "https://adsmanager.facebook.com/adsmanager/manage/adsets/edit/standalone?act=1&selected_campaign_ids=9&selected_adset_ids=55")!)])
        XCTAssertEqual(run.feed(.arg(call: "c", key: "status", value: "PAUSED", done: true)),
                       [.field(key: "status", label: "Status", value: "Paused", done: true)])
        // act_start brings the field that streamed before the page was known
        _ = run.feed(.start(id: "a", call: "c", tool: "update_entity", label: "", args: ["entity_id": "55", "daily_budget": "20", "status": "PAUSED"]))
        XCTAssertEqual(run.feed(.applied(entityType: "ad_set", entityId: "55", createdId: nil, account: nil, error: nil)).first,
                       .applied(URL(string: "https://adsmanager.facebook.com/adsmanager/manage/adsets/edit/standalone?act=1&selected_campaign_ids=9&selected_adset_ids=55")!, ok: true, error: nil, walk: false))
    }

    func testAChangeTakesItsLevelFromEntityType() {
        var run = AgentRun(defaultAccount: "1")
        _ = run.feed(.intent(call: "c", tool: "update_entity", label: "", door: true))
        _ = run.feed(.arg(call: "c", key: "entity_id", value: "120249776943360685", done: true))
        // chat cxhowmx5k: the id alone opened a campaign editor for an ad, and Meta sent it back to the list
        var run2 = AgentRun(defaultAccount: "1")
        _ = run2.feed(.intent(call: "c", tool: "update_entity", label: "", door: true))
        _ = run2.feed(.arg(call: "c", key: "entity_type", value: "ad", done: true))
        XCTAssertEqual(run2.feed(.arg(call: "c", key: "entity_id", value: "777", done: true)),
                       [.open(URL(string: "https://adsmanager.facebook.com/adsmanager/manage/ads/edit/standalone?act=1&selected_ad_ids=777")!)])
        XCTAssertEqual(AgentEvent.parse(line: #"data:{"type":"applied","id":"a3","entity_type":"campaign","created_id":"55","ok":true}"#),
                       .applied(entityType: "campaign", entityId: nil, createdId: "55", account: nil, error: nil))
    }

    func testReadsAndRefusalsDoNotDrive() {
        var run = AgentRun(defaultAccount: "1")
        XCTAssertEqual(run.feed(.intent(call: "r", tool: "get_account_stats", label: "", door: false)), [])
        XCTAssertEqual(run.feed(.arg(call: "r", key: "account", value: "1", done: true)), [])
        _ = run.feed(.intent(call: "c", tool: "create_ad", label: "", door: true))
        _ = run.feed(.start(id: "a2", call: "c", tool: "create_ad", label: "", args: [:]))
        XCTAssertEqual(run.feed(.step(id: "a2", step: "guard", account: nil, reason: "Manual mode: ask first")),
                       [.result(ok: false, error: "Manual mode: ask first", diff: [])])
        XCTAssertEqual(run.feed(.end), [.finish])
        XCTAssertEqual(run.feed(.end), [])
    }

    func testStopgapChatTitleLikeTheSite() {
        XCTAssertEqual(ChatTitle.from("покажи мне расходы за вчера по кампаниям!"), "Расходы вчера кампаниям")
        XCTAssertEqual(ChatTitle.from("What is my CPL this week?"), "CPL this week")
        XCTAssertEqual(ChatTitle.from("   "), "")
    }
}
