import XCTest
@testable import Liaison

/// A change waiting for its Yes / No is not "Not answered" because another turn of the same agent ended.
final class AgentWaitPolicyTests: XCTestCase {
    func testIncidentAnotherTaskEndingKeepsTheWait() {
        // Met's browser ("agent-met"), the copy waits, the metrics task's turn ends; the chat's probe is not wired
        let own = !AgentWaitPolicy.isAgentBrowser(chatID: "agent-met")
        XCTAssertFalse(own)
        XCTAssertEqual(AgentWaitPolicy.onEnd(waiting: true, gateOpen: nil, ownChat: own), .keep)
    }

    func testTheChatSaysTheCardIsStillOpen() {
        XCTAssertEqual(AgentWaitPolicy.onEnd(waiting: true, gateOpen: true, ownChat: false), .keep)
        XCTAssertEqual(AgentWaitPolicy.onEnd(waiting: true, gateOpen: true, ownChat: true), .keep)
    }

    func testTheCardIsGoneWithoutAnAnswer() {
        // the person typed instead of answering: the chat's card is no longer open
        XCTAssertEqual(AgentWaitPolicy.onEnd(waiting: true, gateOpen: false, ownChat: false), .expire)
        // a web chat's own browser: a later turn there follows the person's own message (the rule)
        XCTAssertEqual(AgentWaitPolicy.onEnd(waiting: true, gateOpen: nil, ownChat: true), .expire)
        XCTAssertTrue(!AgentWaitPolicy.isAgentBrowser(chatID: "c_123"))
        XCTAssertTrue(!AgentWaitPolicy.isAgentBrowser(chatID: nil))
    }

    func testNothingWaits() {
        XCTAssertEqual(AgentWaitPolicy.onEnd(waiting: false, gateOpen: nil, ownChat: false), .none)
        XCTAssertEqual(AgentWaitPolicy.onEnd(waiting: false, gateOpen: false, ownChat: true), .none)
    }

    func testANewChangeReplacesTheWaitingOne() {
        XCTAssertTrue(AgentWaitPolicy.supersedes(waiting: true, hasHistoryRow: true))
        XCTAssertFalse(AgentWaitPolicy.supersedes(waiting: true, hasHistoryRow: false))   // already answered No / ended
        XCTAssertFalse(AgentWaitPolicy.supersedes(waiting: false, hasHistoryRow: true))
    }
}
