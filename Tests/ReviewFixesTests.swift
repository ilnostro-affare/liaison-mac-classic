import XCTest
import Foundation
#if canImport(Liaison)
@testable import Liaison
#endif

// Pure logic behind the review fixes: our hosts, the browser's dialog budget, the server copy merge.
final class OurHostTests: XCTestCase {
    func testOnlyLiaisoneAndItsSubdomains() {
        XCTAssertTrue(OurHost.matches("liaisone.com"))
        XCTAssertTrue(OurHost.matches("mcp.liaisone.com"))
        XCTAssertTrue(OurHost.matches("API.Liaisone.com"))
        XCTAssertFalse(OurHost.matches("evilliaisone.com"))
        XCTAssertFalse(OurHost.matches("liaisone.com.evil.io"))
        XCTAssertFalse(OurHost.matches(nil))
        XCTAssertFalse(OurHost.matches(""))
    }

    /// Server: Dev's sites and previews are the person's code, never ours - no session header to them.
    func testDevSitesAreNotOurs() {
        for h in ["api.liaisone.com", "lia.liaisone.com", "ai.liaisone.com", "mcp.liaisone.com", "browser.liaisone.com",
                  "www.liaisone.com", "map.liaisone.com"] {
            XCTAssertTrue(OurHost.matches(h), h)
        }
        for h in ["pizza-roma.liaisone.app", "liaisone.app", "pv-abcd1234.liaisone.app", "pizza-roma.liaisone.com",
                  "pv-abcd1234.liaisone.com", "pv-a.liaisone.com", "support-site.liaisone.com"] {
            XCTAssertFalse(OurHost.matches(h), h)
        }
    }
}

final class DialogThrottleTests: XCTestCase {
    func testThreeInTenSecondsThenSilentUntilReset() {
        var t = DialogThrottle()
        let t0 = Date(timeIntervalSince1970: 1000)
        XCTAssertTrue(t.allow(now: t0))
        XCTAssertTrue(t.allow(now: t0.addingTimeInterval(1)))
        XCTAssertTrue(t.allow(now: t0.addingTimeInterval(2)))
        XCTAssertFalse(t.allow(now: t0.addingTimeInterval(3)))
        // Suppressed for the rest of the page load, even after the window passed.
        XCTAssertFalse(t.allow(now: t0.addingTimeInterval(60)))
        t.reset()
        XCTAssertTrue(t.allow(now: t0.addingTimeInterval(61)))
    }

    func testSpacedDialogsAreNotCounted() {
        var t = DialogThrottle()
        let t0 = Date(timeIntervalSince1970: 1000)
        for k in 0..<10 { XCTAssertTrue(t.allow(now: t0.addingTimeInterval(Double(k) * 6))) }
        XCTAssertFalse(t.suppressed)
    }
}

final class ChatMergeTests: XCTestCase {
    private func gate(_ done: Bool) -> String { #"{"plan_id":"p1","tool":"update_entity","done":\#(done)}"# }

    func testLocalAnswerWinsOverAnUnansweredServerCopy() {
        let local = [ChatMessage(id: "a", role: .user, content: "hi"),
                     ChatMessage(id: "b", role: .assistant, content: "Ready", gateJSON: gate(true))]
        let server = [ChatMessage(id: "m0", role: .user, content: "hi"),
                      ChatMessage(id: "m1", role: .assistant, content: "Ready", gateJSON: gate(false))]
        let out = ChatMerge.preferLocalAnswers(server: server, local: local)
        XCTAssertEqual(out[1].gate?.done, true)
        XCTAssertEqual(out[1].id, "m1")
    }

    func testServerWinsWhenItKnowsMoreOrTheMessageDiffers() {
        let local = [ChatMessage(id: "b", role: .assistant, content: "Ready", gateJSON: gate(false))]
        let server = [ChatMessage(id: "m0", role: .assistant, content: "Ready", gateJSON: gate(true))]
        XCTAssertEqual(ChatMerge.preferLocalAnswers(server: server, local: local)[0].gate?.done, true)
        let other = [ChatMessage(id: "m0", role: .assistant, content: "Something else", gateJSON: gate(false))]
        let l2 = [ChatMessage(id: "b", role: .assistant, content: "Ready", gateJSON: gate(true))]
        XCTAssertEqual(ChatMerge.preferLocalAnswers(server: other, local: l2)[0].gate?.done, false)
    }

    func testPlanDoneAndAskDoneAreKept() {
        let local = [ChatMessage(id: "b", role: .assistant, content: "Plan",
                                 askJSON: #"{"question":"Goal?","done":true,"answer":"Leads"}"#, planJSON: #"{"items":[],"done":true}"#)]
        let server = [ChatMessage(id: "m0", role: .assistant, content: "Plan",
                                  askJSON: #"{"question":"Goal?","done":false}"#, planJSON: #"{"items":[]}"#)]
        let out = ChatMerge.preferLocalAnswers(server: server, local: local)
        XCTAssertEqual(out[0].ask?.done, true)
        XCTAssertEqual(out[0].ask?.answer, "Leads")
        XCTAssertTrue(JSONRead.bool(out[0].plan, "done"))
    }
}
