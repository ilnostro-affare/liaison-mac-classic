import XCTest
import Foundation
#if canImport(Liaison)
@testable import Liaison
#endif

final class BillingTests: XCTestCase {
    private func bill(_ s: String) -> BillingDetail { BillingDetail.parse(Data(s.utf8))! }

    func testActiveLinesAndPrice() {
        let b = bill(#"{"status":"active","price":{"amount":2000,"currency":"usd","interval":"month"},"currentPeriodEnd":1790000000,"card":{"brand":"visa","last4":"4242"},"invoices":[{"date":1780000000,"total":2000,"currency":"usd","status":"paid","url":"https://x"}]}"#)
        XCTAssertTrue(b.hasSubscription)
        XCTAssertEqual(b.priceText, "$20.00 per month")
        XCTAssertTrue(b.subLine.hasPrefix("Renews automatically on "))
        XCTAssertEqual(b.pill(planTitle: "Lia Pro"), "Lia Pro")
        XCTAssertEqual(b.cardLast4, "4242")
        XCTAssertEqual(b.invoices.first?.status, "paid")
    }

    func testTrialCancelPastDue() {
        XCTAssertEqual(bill(#"{"status":"trialing"}"#).subLine, "Your free trial is active. Your plan begins when it ends.")
        XCTAssertEqual(bill(#"{"status":"trialing","price":{"amount":2000,"currency":"usd","interval":"month"},"trialEnd":1790000000}"#).subLine.hasSuffix(", then $20.00/mo begins automatically."), true)
        XCTAssertFalse(bill(#"{"status":"trialing"}"#).subLine.contains("7-day"))
        XCTAssertEqual(bill(#"{"status":"trialing","cancelAtPeriodEnd":true}"#).subLine, "Canceled — your free trial will not renew. You won’t be charged.")
        XCTAssertEqual(bill(#"{"status":"trialing"}"#).pill(planTitle: ""), "Free Trial")
        XCTAssertEqual(bill(#"{"status":"active","cancelAtPeriodEnd":true}"#).subLine, "Canceled — your plan will not renew at the end of the current period.")
        let pd = bill(#"{"status":"past_due","price":{"amount":10000,"currency":"usd"}}"#)
        XCTAssertEqual(pd.pill(planTitle: "Lia Max"), "Payment issue")
        XCTAssertEqual(pd.heldPlan(), "Lia Max")
        XCTAssertEqual(bill(#"{"status":"past_due","price":{"amount":20}}"#).heldPlan(), "Lia Pro")
        XCTAssertFalse(bill(#"{"status":"incomplete_expired"}"#).hasSubscription)
        XCTAssertEqual(bill(#"{"status":"none"}"#).priceText, "$20.00 per month")
        XCTAssertTrue(PlanCatalog.free.feats.contains("No card required"))
    }
}

final class UsageTests: XCTestCase {
    func testOneIsANumberNotTrue() {
        let o = JSONRead.object(Data(#"{"n":1,"z":0,"t":true,"f":false}"#.utf8))!
        XCTAssertEqual(JSONRead.int(o, "n"), 1)
        XCTAssertEqual(JSONRead.double(o, "z"), 0)
        XCTAssertEqual(JSONRead.string(o, "n"), "1")
        XCTAssertTrue(JSONRead.bool(o, "t"))
        XCTAssertFalse(JSONRead.bool(o, "f"))
        XCTAssertFalse(JSONRead.bool(o, "n"))
        XCTAssertNil(JSONRead.int(o, "t"))
    }

    func testUsageBarsStripAndRing() {
        let u = UsageInfo.parse(Data(#"{"ok":true,"tier":"free","session":{"pct":80,"active":true,"split":{"read":30,"write":50}},"weekly":{"pct":40,"cost_usd":3,"budget_usd":10},"build":{"cost_usd":1},"chat":{"known":true,"pct":0.4}}"#.utf8))!
        XCTAssertEqual(u.lia14Pct, 20)
        XCTAssertEqual(u.session.split["write"], 50)
        XCTAssertEqual(u.limitStrip?.text, "80% of this session")
        XCTAssertEqual(u.chatTip, "<1% of a session")
        let full = UsageInfo.parse(Data(#"{"ok":true,"tier":"free","session":{"pct":30},"weekly":{"pct":100}}"#.utf8))!
        XCTAssertEqual(full.limitStrip?.text, "Free limit reached")
        XCTAssertNil(UsageInfo.parse(Data(#"{"ok":true,"session":{"pct":10},"weekly":{"pct":70}}"#.utf8))!.limitStrip)
    }
}
