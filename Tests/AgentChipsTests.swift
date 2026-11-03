import XCTest
import Foundation
@testable import Liaison

// Agents named in a text are pills; "@" works anywhere in the box, not only at its end.
final class AgentChipsTests: XCTestCase {
    func testHits() {
        let t = "Dev a waitlist page, @crea the images, Met a test. dev.liaisone.app and Devon stay text; @Lia too."
        let h = AgentChips.hits(t)
        XCTAssertEqual(h.map(\.id), ["dev", "crea", "met", "lia"])
        XCTAssertEqual(h[1].name, "Crea")
        XCTAssertEqual((t as NSString).substring(with: h[1].range), "@crea")
        // a bare name only with its capital, and only the team's four
        XCTAssertTrue(AgentChips.hits("the dev server, a MET gala").isEmpty)
        XCTAssertEqual(AgentChips.hits("ask @Seara").map(\.id), ["seara"])
        XCTAssertTrue(AgentChips.hits("Seara said").isEmpty)
    }

    // The fields an agent is called from paint only "@Name"
    func testMentions() {
        let t = "Dev, ask @met and @Crea; mail@lia.com stays"
        let m = AgentChips.mentions(t)
        XCTAssertEqual(m.map(\.id), ["met", "crea"])
        XCTAssertEqual((t as NSString).substring(with: m[0].range), "@met")
        XCTAssertTrue(AgentChips.mentions("Dev and Lia").isEmpty)
    }

    func testSegments() {
        let s = InlineChips.segments("Dev builds it at https://x.liaisone.app/Dev today", ents: [:])
        XCTAssertEqual(s.first, .agent(id: "dev", name: "Dev", color: 0xF0533E))
        // inside an address the name stays the address
        XCTAssertFalse(s.dropFirst().contains { if case .agent = $0 { return true } else { return false } })
    }

    func testSpotAnywhere() {
        let t = "hello @Cr and more"
        XCTAssertEqual(AgentMention.spot(t, caret: 9), AgentMention.Spot(query: "Cr", range: NSRange(location: 6, length: 3)))
        XCTAssertNil(AgentMention.spot(t, caret: 14))
        // deleting back to a lone "@" lists everyone
        XCTAssertEqual(AgentMention.spot("hello @", caret: 7)?.query, "")
        XCTAssertNil(AgentMention.spot("mail@x", caret: 6))
        let crea = AgentInfo.fallback.first { $0.id == "crea" }!
        let r = AgentMention.complete(t, at: AgentMention.spot(t, caret: 9)!, with: crea)
        XCTAssertEqual(r.text, "hello @Crea and more")
        XCTAssertEqual(r.caret, 12)
        let e = AgentMention.complete("hi @D", at: AgentMention.spot("hi @D", caret: 5)!, with: crea)
        XCTAssertEqual(e.text, "hi @Crea ")
        XCTAssertEqual(e.caret, 9)
    }
}
