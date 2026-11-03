import XCTest
import Foundation
@testable import Liaison

/// What notifies, bounces the dock figure and counts on its badge (Shared/Core/AgentAttention.swift),
/// the dock's double-click guard, and our own downloads (Shared/Core/OurHost.swift DownloadSource).
final class AgentAttentionTests: XCTestCase {
    typealias M = AgentAttention.Message

    func testFinalAnswerAndGateInOwnDialogue() {
        XCTAssertEqual(AgentAttention.kind(M(agent: "met", seq: 5), in: "met"), .message)
        XCTAssertEqual(AgentAttention.kind(M(agent: "met", seq: 5, hasGate: true), in: "met"), .approval)
        // Lia's dialogue is "team"
        XCTAssertEqual(AgentAttention.kind(M(agent: "lia", seq: 2), in: "team"), .message)
        // no agent on the message: the dialogue's own
        XCTAssertEqual(AgentAttention.kind(M(agent: "", seq: 2), in: "crea"), .message)
    }

    func testNotThePersonCardsOrAcknowledgements() {
        XCTAssertNil(AgentAttention.kind(M(agent: nil, seq: 3), in: "met"))
        XCTAssertNil(AgentAttention.kind(M(agent: "met", isTask: true), in: "met"))
        XCTAssertNil(AgentAttention.kind(M(agent: "met", handed: true), in: "met"))
        // Met's one-line acknowledgement in Lia's dialogue: the work is in Met's own
        XCTAssertNil(AgentAttention.kind(M(agent: "met", toDlg: "met"), in: "team"))
        XCTAssertNil(AgentAttention.kind(M(agent: "dev"), in: "team"))
    }

    func testDevTurnOnlyItsFinalMessage() {
        XCTAssertNil(AgentAttention.kind(M(agent: "dev", run: "r1", fin: false), in: "dev"))   // "on it" / activity
        XCTAssertEqual(AgentAttention.kind(M(agent: "dev", run: "r1", fin: true), in: "dev"), .message)
        // a question card in the middle of a turn still needs the person
        XCTAssertEqual(AgentAttention.kind(M(agent: "dev", hasGate: true, run: "r1"), in: "dev"), .approval)
    }

    func testCountAfterSeen() {
        let list = [M(agent: nil, seq: 10), M(agent: "dev", seq: 11, run: "r", fin: false),
                    M(agent: "dev", seq: 12, run: "r", fin: false), M(agent: "dev", seq: 13, run: "r", fin: true),
                    M(agent: "dev", seq: 14, hasGate: true)]
        XCTAssertEqual(AgentAttention.count(list, in: "dev", after: 9), 2)
        XCTAssertEqual(AgentAttention.count(list, in: "dev", after: 13), 1)
        XCTAssertEqual(AgentAttention.count(list, in: "dev", after: 14), 0)
    }

    func testFromStoredMessage() {
        let ack = DlgMessage(id: "a", seq: 4, role: .assistant, agent: "met", origin: DlgOrigin(surface: .handoff, toDlg: "met"), taskId: "t1")
        XCTAssertFalse(AgentAttention.needs(M(ack), in: "team"))
        let person = DlgMessage(id: "p", seq: 5, role: .user, text: "hi")
        XCTAssertFalse(AgentAttention.needs(M(person), in: "met"))
        let answer = DlgMessage(id: "b", seq: 6, role: .assistant, agent: "met", text: "Done.")
        XCTAssertTrue(AgentAttention.needs(M(answer), in: "met"))
        let card = DlgMessage(id: "c", seq: 7, role: .system, agent: "met", taskId: "t1")
        XCTAssertFalse(AgentAttention.needs(M(card), in: "met"))
    }

    func testDockToggleWaitsForTheSlide() {
        let t = Date(timeIntervalSince1970: 1000)
        XCTAssertTrue(DockToggle.closes(openedAt: nil, now: t))
        XCTAssertFalse(DockToggle.closes(openedAt: t, now: t.addingTimeInterval(0.2)))
        XCTAssertTrue(DockToggle.closes(openedAt: t, now: t.addingTimeInterval(DockToggle.settle)))
    }

    func testOurDownloads() {
        XCTAssertTrue(DownloadSource.isOurs(URL(string: "https://lia.liaisone.com/dl/mac")))
        XCTAssertTrue(DownloadSource.isOurs(URL(string: "https://liaisone.com/Liaison.dmg")))
        XCTAssertFalse(DownloadSource.isOurs(URL(string: "http://liaisone.com/Liaison.dmg")))
        XCTAssertFalse(DownloadSource.isOurs(URL(string: "https://evilliaisone.com/x.dmg")))
        XCTAssertFalse(DownloadSource.isOurs(URL(string: "https://example.com/x.dmg")))
        XCTAssertFalse(DownloadSource.isOurs(nil))
        // a Dev site (the person's own code) is not ours
        XCTAssertFalse(DownloadSource.isOurs(URL(string: "https://alex.liaisone.app/app.dmg")))
        XCTAssertFalse(DownloadSource.isOurs(URL(string: "https://pv-abcd1234.liaisone.com/app.dmg")))
    }

    func testAgentsOffForTheTurnBody() {
        let roster = [AgentInfo(id: "lia", name: "Lia", role: "", shape: .ring, colorHex: 0, lead: true),
                      AgentInfo(id: "met", name: "Met", role: "", shape: .ring, colorHex: 0),
                      AgentInfo(id: "dev", name: "Dev", role: "", shape: .ring, colorHex: 0),
                      AgentInfo(id: "crea", name: "Crea", role: "", shape: .ring, colorHex: 0),
                      AgentInfo(id: "soon", name: "Soon", role: "", shape: .ring, colorHex: 0, soon: true)]
        // nothing hidden, Meta connected: only the coming-soon one
        XCTAssertEqual(AgentVisibility.off(roster, isHidden: { _ in false }, isLocked: { _ in false }), ["soon"])
        // Met hidden in this workspace, Dev locked: both off, in roster order; Lia never, even if marked hidden
        XCTAssertEqual(AgentVisibility.off(roster, isHidden: { $0 == "met" || $0 == "lia" }, isLocked: { $0 == "dev" }),
                       ["met", "dev", "soon"])
    }
}
