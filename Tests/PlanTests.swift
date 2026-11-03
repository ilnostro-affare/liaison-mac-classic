import XCTest
import Foundation
#if canImport(Liaison)
@testable import Liaison
#endif

// Plan on the Mac: the parts, the buttons, and the gateway parameters re-planned from the doors' arguments.
final class PlanTests: XCTestCase {
    private func plan(_ s: String) -> PlanState { PlanState(json: JSONRead.object(Data(s.utf8)))! }

    private let tree = #"""
    {"items":[
     {"id":"1","tool":"create_campaign","entity":"campaign","title":"Spring","plan_id":"p1","args":{"name":"Spring","objective":"OUTCOME_LEADS","account":"123","bid_strategy":"COST_CAP"}},
     {"id":"2","tool":"create_ad_set","entity":"ad set","title":"Milan","variant":"Broad","args":{"name":"Milan","campaign_id":"plan","genders":"[2]","age_min":"25","geo":"{\"cities\":[{\"key\":\"2\",\"name\":\"Milan\",\"radius_km\":17}]}","placements":{"platforms":["instagram"],"instagram":["stream","story"]}},"diff":[{"label":"Estimated audience","new":"1.2M people"}]},
     {"id":"3","tool":"create_ad_set","entity":"ad set","title":"Milan","variant":"Mats","args":{"name":"Milan","campaign_id":"plan","advantage_audience":"on","interests":[{"id":"6","name":"Mats"}]}},
     {"id":"4","tool":"create_ad","entity":"ad","title":"Video","deferred":true,"args":{"name":"Video","ad_set_id":"plan","video_id":"99","page_id":"7"}},
     {"id":"5","tool":"update_entity","entity":"campaign change","title":"Old","plan_id":"p5","entity_type":"campaign","diff":[{"label":"Budget","old":"€10","new":"€20"}],"args":{}},
     {"id":"6","tool":"create_ad_set","entity":"ad set","title":"X","error":"Meta said no","args":{}}
    ]}
    """#

    func testPartsVariantsAndButtons() {
        var p = plan(tree)
        XCTAssertEqual(p.creates.map(\.id), ["1", "2", "3", "4"])
        XCTAssertEqual(p.variants.map(\.id), ["2", "3"])
        XCTAssertEqual(p.edits.map(\.id), ["5"])
        XCTAssertEqual(p.refused.map(\.id), ["6"])
        XCTAssertEqual(p.parts, 4)   // 5 good rows, two variants count as one
        XCTAssertEqual(p.chosenAdSet?.id, "2")
        p.pick = "3"
        XCTAssertEqual(p.create("adset")?.id, "3")
        XCTAssertEqual(PlanLogic.buttons(p).map(\.1), ["Publish paused", "Publish and turn on", "No"])
        let edits = plan(#"{"items":[{"id":"5","tool":"update_entity","plan_id":"p5","args":{}},{"id":"7","tool":"update_ad","plan_id":"p7","off":true,"args":{}}]}"#)
        XCTAssertEqual(PlanLogic.buttons(edits).map(\.1), ["Apply 1", "No"])
        XCTAssertEqual(plan(#"{"items":[{"id":"8","tool":"update_ad","args":{}}]}"#).edits.count, 0)   // nothing Meta checked, nothing to apply
        let refusals = plan(#"{"items":[{"id":"6","tool":"create_ad","error":"no","args":{}}]}"#)
        XCTAssertEqual(PlanLogic.buttons(refusals).map(\.1), ["Close"])
    }

    func testCampaignParams() {
        let c = PlanLogic.campaignParams(plan(tree).create("campaign")!.args)
        XCTAssertEqual(c["objective"] as? String, "OUTCOME_LEADS")
        XCTAssertNil(c["bid_strategy"])   // no campaign budget: the bid belongs to the ad sets
    }

    func testAdSetParamsConvertLikeTheDoor() {
        let p = plan(tree)
        let c = PlanLogic.adSetParams(p.create("adset")!.args, campaignId: "555")
        XCTAssertEqual(c["campaign_id"] as? String, "555")
        XCTAssertEqual(c["from_scratch"] as? String, "true")
        XCTAssertEqual(c["genders"] as? String, "women")
        XCTAssertEqual(c["advantage_audience"] as? String, "0")   // an age asked for
        XCTAssertEqual(c["placements"] as? String, #"["instagram_stream","instagram_story"]"#)
        XCTAssertTrue((c["geo"] as? String)?.contains("\"radius_km\":17") == true)
        let v = PlanLogic.adSetParams(p.variants[1].args, campaignId: nil)
        XCTAssertNil(v["campaign_id"])   // "plan" is not an id
        XCTAssertEqual(v["advantage_audience"] as? String, "1")
        XCTAssertEqual(v["interests"] as? String, #"[{"id":"6","name":"Mats"}]"#)
        let named = PlanLogic.adSetParams(["campaign_id": "120", "genders": "[1]"], campaignId: nil)
        XCTAssertEqual(named["campaign_id"] as? String, "120")
        XCTAssertEqual(named["genders"] as? String, "men")
    }

    func testAdParams() {
        let a = PlanLogic.adParams(plan(tree).create("ad")!.args, adSetId: "777")
        XCTAssertEqual(a["ad_set_id"] as? String, "777")
        XCTAssertEqual(a["video_id"] as? String, "99")
        XCTAssertEqual(PlanLogic.adParams(["ad_set_id": "plan"], adSetId: nil)["ad_set_id"] as? String, nil)
    }

    func testLinesAndReply() {
        let p = plan(tree)
        XCTAssertEqual(p.items[4].diffLine, "Budget €10 → €20")
        XCTAssertEqual(p.items[1].diffLine, "1.2M people")
        XCTAssertEqual(PlanLogic.audienceLine(p.items[1].args), "Milan +17 km · 25–65 · women")
        var r = PlanResult(kind: "campaign", k: "Campaign", title: "Spring", ok: true, createdId: "9", entity: "campaign", planId: "p1")
        r.on = true
        XCTAssertEqual(PlanLogic.reply(.publishOn, [r]),
                       #"[plan_reply] {"answer":"publish_on","items":[{"entity":"campaign","title":"Spring","on":true,"plan_id":"p1","created_id":"9","entity_id":null,"error":null,"off":false}]}"#)
        XCTAssertEqual(ModeReply.quote(for: PlanLogic.reply(.publishOn, [r]))?.answer, "Publish and turn on")
    }

    func testStateMergesBackKeepingUnknownFields() {
        let stored = JSONRead.object(Data(tree.utf8))!
        var p = PlanState(json: stored)!
        p.items[4].off = true
        p.done = true; p.answer = "apply"
        p.results = [PlanResult(kind: "change", k: "Campaign", title: "Old", ok: true)]
        let out = p.merged(into: stored)
        XCTAssertEqual(out["answer"] as? String, "apply")
        XCTAssertEqual(JSONRead.objects(out, "items")[4]["off"] as? Bool, true)
        XCTAssertNotNil(JSONRead.objects(out, "items")[0]["args"])
        XCTAssertEqual(PlanState(json: out)?.results.first?.ok, true)
    }
}
