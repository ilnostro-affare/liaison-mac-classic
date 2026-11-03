import XCTest
import Foundation
#if canImport(Liaison)
@testable import Liaison
#endif

final class EntityChipsTests: XCTestCase {
    private let ents: [String: ChatEntity] = [
        "120000000000001": ChatEntity(name: "Kids camp", kind: "campaign"),
        "120000000000002": ChatEntity(name: "Milan 25-45", kind: "adset", parent: "Kids camp"),
        "120000000000003": ChatEntity(name: "Prova gratis", kind: "ad", parent: "Kids camp"),
        "120000000000004": ChatEntity(name: "prova gratis ", kind: "ad", parent: "Spring"),
        "120000000000005": ChatEntity(name: "Rome", kind: "adset", parent: "Kids camp"),
    ]

    func testLinkRoundTrip() {
        for link in [EntityLink.entity("120000000000001"), .namesake("prova gratis"), .namesake("широкая 2 / test?#%"),
                     .namesake("«a» & b")] {
            guard let u = link.url else { return XCTFail("no url for \(link)") }
            XCTAssertEqual(u.scheme, "lia-ent")
            XCTAssertEqual(EntityLink(url: u), link)
        }
        XCTAssertNil(EntityLink(url: URL(string: "https://liaisone.com/id/1")!))
        XCTAssertNil(EntityLink(url: URL(string: "lia-ent://other/1")!))
        XCTAssertNil(EntityLink(url: URL(string: "lia-ent://id/")!))
    }

    func testQuoteWithIdIsEntityElseNamesakeElseQuote() {
        XCTAssertEqual(InlineChips.segments("«Kids camp» (id 120000000000001)", ents: ents),
                       [.entity(name: "Kids camp", id: "120000000000001", kind: "campaign")])
        // A quote never asserts which object, even with a single match.
        XCTAssertEqual(InlineChips.segments("Raise «kids camp» now", ents: ents),
                       [.text("Raise "), .namesake(name: "kids camp", count: 1, kind: "campaign"), .text(" now")])
        XCTAssertEqual(InlineChips.segments("«Prova gratis»", ents: ents), [.namesake(name: "Prova gratis", count: 2, kind: "ad")])
        XCTAssertEqual(InlineChips.segments("«Nothing here»", ents: ents), [.quote("Nothing here")])
        // An id the map does not know: the quote stays a quote, the id is swallowed as on the site.
        XCTAssertEqual(InlineChips.segments("«Nothing here» (id 999999999999999)", ents: ents), [.quote("Nothing here")])
    }

    func testTree() {
        let t = EntityChips.tree(id: "120000000000001", ents: ents)
        XCTAssertNil(t.parent)
        XCTAssertEqual(t.name, "Kids camp")
        XCTAssertEqual(t.kids.map(\.id), ["120000000000002", "120000000000003", "120000000000005"])
        let a = EntityChips.tree(id: "120000000000002", ents: ents)
        XCTAssertEqual(a.parent, "Kids camp")
        XCTAssertEqual(a.kids, [])
        XCTAssertEqual(EntityChips.tree(id: "1", ents: ents).name, "unknown entity")
    }

    func testNamesakesGroupedByCampaign() {
        let g = EntityChips.namesakes("PROVA gratis", ents: ents)
        XCTAssertEqual(g.map(\.title), ["Kids camp", "Spring"])
        XCTAssertEqual(g.flatMap(\.items).map(\.id), ["120000000000003", "120000000000004"])
        XCTAssertEqual(EntityChips.namesakes("x", ents: ents), [])
        let lone = EntityChips.namesakes("a", ents: ["9": ChatEntity(name: "A", kind: nil)])
        XCTAssertEqual(lone.map(\.title), ["\u{2014}"])
    }

    func testUseTextAndPutText() {
        XCTAssertEqual(EntityChips.useText(id: "120000000000002", entity: ents["120000000000002"]),
                       "ad set \u{00AB}Milan 25-45\u{00BB} (id 120000000000002)")
        XCTAssertEqual(EntityChips.useText(id: "7", entity: nil), "\u{00AB}7\u{00BB} (id 7)")
        XCTAssertEqual(EntityChips.putText("", "ad \u{00AB}X\u{00BB} (id 1)"), "ad \u{00AB}X\u{00BB} (id 1) ")
        XCTAssertEqual(EntityChips.putText("pause  \n", "ad X"), "pause ad X ")
    }

    func testKindNice() {
        XCTAssertEqual(EntityChips.kindNice("adset"), "Ad set")
        XCTAssertEqual(EntityChips.kindNice("AD"), "Ad")
        XCTAssertEqual(EntityChips.kindNice("lead_form"), "Lead form")
        XCTAssertEqual(EntityChips.kindNice(nil), "")
    }

    func testParentParsedFromMap() {
        let m = ChatEntity.map(["1": ["n": "A", "k": "ad", "p": "Camp"], "2": ["n": ""]])
        XCTAssertEqual(m, ["1": ChatEntity(name: "A", kind: "ad", parent: "Camp")])
    }
}
