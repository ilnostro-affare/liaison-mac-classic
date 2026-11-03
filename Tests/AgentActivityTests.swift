import XCTest
import Foundation
@testable import Liaison

/// Items 14-15: the short step for the menu bar item and the notch island.
final class AgentActivityTests: XCTestCase {
    func testStepLowercasesAndDropsEllipsis() {
        XCTAssertEqual(AgentActivity.step("Reading the account\u{2026}"), "reading the account")
        XCTAssertEqual(AgentActivity.step("Thinking..."), "thinking")
        XCTAssertEqual(AgentActivity.step("  Pushing  "), "pushing")
    }

    func testStepKeepsNames() {
        XCTAssertEqual(AgentActivity.step("GitHub sync"), "GitHub sync")
        XCTAssertEqual(AgentActivity.step("URL check"), "URL check")
        XCTAssertEqual(AgentActivity.step("I am here"), "I am here")
    }

    func testStepDropsTheAgentsName() {
        XCTAssertEqual(AgentActivity.step("Dev is pushing to main", name: "Dev"), "pushing to main")
        XCTAssertEqual(AgentActivity.step("Crea drawing", name: "Crea"), "drawing")
        XCTAssertEqual(AgentActivity.step("Dev", name: "Dev"), "dev")   // a name alone is not dropped
    }

    func testStepFirstClause() {
        XCTAssertEqual(AgentActivity.step("Drawing \u{00b7} draft 2"), "drawing")
        XCTAssertEqual(AgentActivity.step("Opened Ryanair: picking dates"), "opened Ryanair")
        XCTAssertEqual(AgentActivity.step("Reading (3 tabs)"), "reading")
    }

    func testStepCutsOnAWord() {
        let s = AgentActivity.step("Comparing the creatives of the last thirty days", maxLength: 24)
        XCTAssertTrue(s.hasSuffix("\u{2026}"))
        XCTAssertTrue(s.count <= 24)
        XCTAssertEqual(s, "comparing the creatives\u{2026}")
        // never ends on a small word
        XCTAssertEqual(AgentActivity.step("Looking at the account of the client", maxLength: 16), "looking\u{2026}")
        // one long word is cut hard
        XCTAssertEqual(AgentActivity.step("Supercalifragilistic", maxLength: 8), "superca\u{2026}")
    }

    func testStepEmpty() {
        XCTAssertEqual(AgentActivity.step(""), "working")
        XCTAssertEqual(AgentActivity.step("\u{2026}"), "working")
    }

    func testLabel() {
        XCTAssertEqual(AgentActivity.label(name: "Dev", text: "Pushing\u{2026}"), "Dev \u{00b7} pushing")
        XCTAssertEqual(AgentActivity.label(name: "Crea", text: "Drawing", steps: .init(done: 2, total: 4)), "Crea \u{00b7} drawing 2/4")
        XCTAssertEqual(AgentActivity.label(name: "Met", text: "Working in the browser\u{2026}", progress: 0.4), "Met \u{00b7} working in the browser 40%")
        XCTAssertEqual(AgentActivity.label(name: "Lia", text: "Reading the account", progress: 0), "Lia \u{00b7} reading the account")
        XCTAssertEqual(AgentActivity.label(name: "Lia", text: "x", progress: 1), "Lia \u{00b7} x")
        // steps win over the fraction; zero steps count nothing
        XCTAssertEqual(AgentActivity.label(name: "Crea", text: "Drawing", progress: 0.5, steps: .init(done: 1, total: 4)), "Crea \u{00b7} drawing 1/4")
        XCTAssertEqual(AgentActivity.label(name: "Crea", text: "Drawing", steps: .init(done: 0, total: 0)), "Crea \u{00b7} drawing")
        XCTAssertEqual(AgentActivity.Steps(done: 7, total: 4).text, "4/4")
    }

    func testElapsed() {
        XCTAssertEqual(AgentActivity.elapsed(-3), "0s")
        XCTAssertEqual(AgentActivity.elapsed(8.9), "8s")
        XCTAssertEqual(AgentActivity.elapsed(125), "2m 05s")
        XCTAssertEqual(AgentActivity.elapsed(14 * 60 + 3), "14m")
        XCTAssertEqual(AgentActivity.elapsed(3600 + 5 * 60), "1h 05m")
    }

    func testAgo() {
        XCTAssertEqual(AgentActivity.ago(10), "just now")
        XCTAssertEqual(AgentActivity.ago(50), "1m ago")
        XCTAssertEqual(AgentActivity.ago(185), "3m ago")
        XCTAssertEqual(AgentActivity.ago(7300), "2h ago")
    }

    func testPickCycles() {
        XCTAssertEqual(AgentActivity.pick(count: 0, now: 100), 0)
        XCTAssertEqual(AgentActivity.pick(count: 1, now: 100), 0)
        XCTAssertEqual(AgentActivity.pick(count: 3, now: 0), 0)
        XCTAssertEqual(AgentActivity.pick(count: 3, now: 3.1), 1)
        XCTAssertEqual(AgentActivity.pick(count: 3, now: 6.5), 2)
        XCTAssertEqual(AgentActivity.pick(count: 3, now: 9.0), 0)
    }

    func testFinishedAndRemember() {
        XCTAssertEqual(AgentActivity.finished(before: ["a", "b", "c"], after: ["b"]), ["a", "c"])
        XCTAssertEqual(AgentActivity.finished(before: [], after: ["b"]), [])
        let list = AgentActivity.remember(["c", "a"], into: ["a", "x", "y", "z"], limit: 4) { $0 }
        XCTAssertEqual(list, ["c", "a", "x", "y"])
    }
}
