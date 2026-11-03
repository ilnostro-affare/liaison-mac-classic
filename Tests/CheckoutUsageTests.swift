import XCTest
import Foundation
#if canImport(Liaison)
@testable import Liaison
#endif

final class UsageCatsTests: XCTestCase {
    func testSessTextNeverRoundsWorkToZero() {
        XCTAssertEqual(UsageCats.sessText(0), "0%")
        XCTAssertEqual(UsageCats.sessText(0.28), "<1%")
        XCTAssertEqual(UsageCats.sessText(4.6), "5%")
        XCTAssertEqual(UsageCats.sessText(221.2), "221%")
    }

    func testRowsListTheThreeEvenAtZeroAndTheRemainderOnlyWhenItExists() {
        let r = UsageCats.rows(["read": 3.2, "write": 0, "web": 1.6])
        XCTAssertEqual(r.map(\.name), ["Reading", "Changes", "Web search"])
        XCTAssertEqual(r.map(\.text), ["3%", "0%", "2%"])
        let withOther = UsageCats.rows(["read": 1, "other": 0.4])
        XCTAssertEqual(withOther.last, UsageCats.Row(key: "other", name: "Earlier this week", text: "<1%"))
        XCTAssertTrue(UsageCats.rows([:]).isEmpty)
    }

    func testSegmentsDrawOnlyWhatHasWidthAndClamp() {
        let s = UsageCats.segments(["read": 40, "write": 0, "web": 130])
        XCTAssertEqual(s, [UsageCats.Segment(key: "read", width: 40), UsageCats.Segment(key: "web", width: 100)])
        XCTAssertFalse(UsageCats.hasSplit(["read": 0, "write": 0]))
        XCTAssertTrue(UsageCats.hasSplit(["web": 0.1]))
    }

    func testTip() {
        XCTAssertEqual(UsageCats.tip(["read": 12.4, "write": 2, "web": 0]), "Reading  12%\nChanges  2%\nWeb search  0%")
        XCTAssertEqual(UsageCats.tip([:]), "")
    }

    func testChatSummaryFromTheUsageResponse() {
        let u = UsageInfo.parse(Data(#"{"ok":true,"session":{"pct":10},"weekly":{"pct":20},"chat":{"known":true,"pct":4.6,"split":{"read":3,"write":1.1,"web":0.5}}}"#.utf8))!
        XCTAssertEqual(u.chatSummary, "5% of a session")
        XCTAssertEqual(u.chatRows.map(\.text), ["3%", "1%", "<1%"])
        XCTAssertFalse(u.chatOverrun)
        let over = UsageInfo.parse(Data(#"{"ok":true,"chat":{"known":true,"pct":221}}"#.utf8))!
        XCTAssertTrue(over.chatOverrun)
        XCTAssertEqual(over.chatSummary, "221% of a session")
        let unknown = UsageInfo.parse(Data(#"{"ok":true,"chat":{"known":false,"pct":3,"split":{"read":3}}}"#.utf8))!
        XCTAssertEqual(unknown.chatSummary, "\u{2014}")
        XCTAssertTrue(unknown.chatRows.isEmpty)
    }
}

final class CheckoutTests: XCTestCase {
    func testCheckoutBodyIsTheSitesAndRefusesANonPrice() {
        let b = StripeCheckout.checkoutBody(priceId: "prc_lia-pro-abc")!
        XCTAssertEqual(b["priceId"] as? String, "prc_lia-pro-abc")
        XCTAssertEqual(b["success_url"] as? String, "https://liaisone.com/overview")
        XCTAssertEqual(b["cancel_url"] as? String, "https://liaisone.com/settings/billing")
        XCTAssertNil(StripeCheckout.checkoutBody(priceId: "pln_lia-pro-example2"))
        XCTAssertNil(StripeCheckout.checkoutBody(priceId: ""))
        XCTAssertNil(StripeCheckout.portalBody()["return_url"])
    }

    func testPriceIdFromGetPlans() {
        let d = Data(#"{"data":{"plans":[{"id":"pln_free-example1","prices":[]},{"id":"pln_lia-pro-example2","prices":[{"id":"prc_pro-1","amount":20}]},{"id":"pln_lia-max-example3","prices":[{"id":"prc_max-1","amount":100},{"id":"prc_max-2"}]}]}}"#.utf8)
        XCTAssertEqual(StripeCheckout.priceId(plans: d, planId: PlanCatalog.pro.id), "prc_pro-1")
        XCTAssertEqual(StripeCheckout.priceId(plans: d, planId: PlanCatalog.max.id), "prc_max-1")
        XCTAssertNil(StripeCheckout.priceId(plans: d, planId: PlanCatalog.free.id))
        XCTAssertNil(StripeCheckout.priceId(plans: Data("nope".utf8), planId: PlanCatalog.pro.id))
    }

    func testReply() {
        XCTAssertEqual(StripeCheckout.reply(Data(#"{"data":{"url":"https://checkout.stripe.com/c/pay/cs_1"}}"#.utf8)),
                       .url(URL(string: "https://checkout.stripe.com/c/pay/cs_1")!))
        XCTAssertEqual(StripeCheckout.reply(Data(#"{"error":{"code":"x","message":"No customer"}}"#.utf8)), .error("No customer"))
        XCTAssertEqual(StripeCheckout.reply(Data(#"{"data":{"url":"javascript:alert(1)"}}"#.utf8)), .error(""))
        XCTAssertEqual(StripeCheckout.reply(Data()), .error(""))
    }

    func testPlanByName() {
        XCTAssertEqual(StripeCheckout.planId(named: "Lia Max"), PlanCatalog.max.id)
        XCTAssertEqual(StripeCheckout.planId(named: "Lia Pro \u{00b7} Trial"), PlanCatalog.pro.id)
        XCTAssertNil(StripeCheckout.planId(named: "Your plan"))
    }
}
