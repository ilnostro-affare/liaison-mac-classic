import XCTest
import Foundation
@testable import Liaison

/// Crea's `crea_images` block (lia-agents): drafts to choose from, or the final picture.
final class CreaTests: XCTestCase {
    private func block(_ json: String, tool: String = "crea_images") -> ChatBlock {
        ChatBlock(tool: tool, data: JSONRead.object(Data(json.utf8)))
    }

    private let draftsJSON = """
    {"stage":"drafts","brief":"Summer yoga camp","note":"Rough drafts",
     "images":[
       {"id":"b2","n":2,"url":"/intelligence/plot?member_id=m&key=k2&exp=1&sig=s","key":"ai/m/att/crea/b2.png","idea":"Kids on\\n stage   at sunset","w":512,"h":512},
       {"id":"a1","n":1,"url":"/intelligence/plot?key=k1","key":"ai/m/att/crea/a1.png","idea":"Close-up of sticks"},
       {"id":"","n":3,"url":"/x"},
       {"id":"c3","n":3},
       {"id":"a1","n":4,"url":"/dup"},
       {"id":"d4","url":"/agents/crea/img?k=4","key":"","idea":""}
     ]}
    """

    func testParseDrafts() {
        guard let c = CreaImages(block(draftsJSON)) else { return XCTFail("drafts block not read") }
        XCTAssertEqual(c.stage, .drafts)
        XCTAssertTrue(c.isDrafts)
        XCTAssertEqual(c.brief, "Summer yoga camp")
        XCTAssertEqual(c.note, "Rough drafts")
        // no id, no url and a repeated id are skipped; sorted by n; a missing n is the position
        XCTAssertEqual(c.images.map(\.id), ["a1", "b2", "d4"])
        XCTAssertEqual(c.images.map(\.n), [1, 2, 6])
        XCTAssertEqual(c.images[1].idea, "Kids on stage at sunset")
        XCTAssertEqual(c.images[1].aspect, 1)
        XCTAssertNil(c.images[0].aspect)
        XCTAssertEqual(c.images[0].fileName, "crea-a1.png")
    }

    func testStageFallbacks() {
        let one = block(#"{"stage":"weird","images":[{"id":"x","url":"/a"}]}"#)
        XCTAssertEqual(CreaImages(one)?.stage, .final)
        let two = block(#"{"images":[{"id":"x","url":"/a"},{"id":"y","url":"/b"}]}"#)
        XCTAssertEqual(CreaImages(two)?.stage, .drafts)
        XCTAssertEqual(CreaImages(block(#"{"stage":"EDIT","images":[{"id":"x","url":"/a"}]}"#))?.stage, .edit)
        XCTAssertEqual(CreaImages(block(#"{"stage":"photo","images":[{"id":"x","url":"/a"},{"id":"y","url":"/b"}]}"#))?.stage, .photo)
        XCTAssertFalse(CreaImages(block(#"{"stage":"final","images":[{"id":"x","url":"/a"}]}"#))?.isDrafts ?? true)
        // nothing to draw, another tool, no data
        XCTAssertNil(CreaImages(block(#"{"stage":"final","images":[{"id":"x"}]}"#)))
        XCTAssertNil(CreaImages(block(#"{"stage":"final"}"#)))
        XCTAssertNil(CreaImages(block(#"{"images":[{"id":"x","url":"/a"}]}"#, tool: "plot")))
        XCTAssertNil(CreaImages(ChatBlock(tool: "crea_images", data: nil)))
        XCTAssertNil(CreaImages(block(#"{"images":[{"id":"x","url":"/a"}]}"#))?.note)
    }

    func testAttachment() {
        let c = CreaImages(block(draftsJSON))
        let a = c?.images.first?.attachment
        XCTAssertEqual(a?.key, "ai/m/att/crea/a1.png")
        XCTAssertEqual(a?.kind, "image")
        XCTAssertEqual(a?.mime, "image/png")
        XCTAssertEqual(a?.name, "crea-a1.png")
        XCTAssertEqual(a?.url, "/intelligence/plot?key=k1")
        // a picture without an attachment key cannot be attached
        XCTAssertNil(c?.images.last?.attachment)
    }

    func testAddresses() {
        let ai = "https://ai.liaisone.com", ag = "https://lia.liaisone.com"
        XCTAssertEqual(CreaImages.absoluteURL("/intelligence/plot?key=k", aiBase: ai, agentsBase: ag)?.absoluteString,
                       "https://ai.liaisone.com/intelligence/plot?key=k")
        XCTAssertEqual(CreaImages.absoluteURL("/agents/crea/img?k=1", aiBase: ai, agentsBase: ag)?.absoluteString,
                       "https://lia.liaisone.com/agents/crea/img?k=1")
        XCTAssertEqual(CreaImages.absoluteURL("https://ai.liaisone.com/x", aiBase: ai, agentsBase: ag)?.absoluteString,
                       "https://ai.liaisone.com/x")
        XCTAssertNil(CreaImages.absoluteURL("https://evil.com/x", aiBase: ai, agentsBase: ag))
        XCTAssertNil(CreaImages.absoluteURL("//evil.com/x", aiBase: ai, agentsBase: ag))
        XCTAssertNil(CreaImages.absoluteURL("http://ai.liaisone.com/x", aiBase: ai, agentsBase: ag))
        let pic = CreaImages(block(draftsJSON))!.images[0]
        XCTAssertEqual(CreaImages.downloadURL(pic, aiBase: ai, agentsBase: ag)?.absoluteString,
                       "https://ai.liaisone.com/intelligence/plot?key=k1&dl=1&name=crea-a1.png")
    }

    func testTextsAndLayout() {
        XCTAssertEqual(CreaImages.useDraft(3), "Use draft 3")
        XCTAssertEqual(CreaImages.editPrefix, "Change on the image:")
        XCTAssertEqual(CreaImages.adDraft, "Make an ad with this image from Crea.")
        XCTAssertEqual([1, 2, 3, 4, 5].map(CreaImages.columns), [1, 2, 3, 2, 2])
        XCTAssertEqual(CreaImages.safeName("a/b c.png"), "a-b-c-png")
        XCTAssertEqual(CreaImages.safeName(""), "image")
    }

    // Pictures still being made, stale links, what a failed load does next, fresh links from a dialogue read.

    func testPendingPictures() {
        let c = CreaImages(block(#"{"stage":"drafts","images":[{"id":"a","url":"/intelligence/plot?key=a"},{"id":"b","status":"generating"},{"id":"c","key":"ai/m/att/crea/c.png"},{"id":"d","status":"done"}]}"#))
        XCTAssertEqual(c?.images.map(\.id), ["a", "b", "c"])
        XCTAssertEqual(c?.images.map(\.generating), [false, true, false])
        XCTAssertEqual(c?.images.map(\.isPending), [false, true, true])
        XCTAssertTrue(CreaImages.isGenerating(" Pending "))
        XCTAssertFalse(CreaImages.isGenerating(nil))
        // a url wins over a status
        XCTAssertEqual(CreaImages(block(#"{"images":[{"id":"x","url":"/a","status":"pending"}]}"#))?.images.first?.generating, false)
    }

    func testExpiry() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let fresh = "/intelligence/plot?member_id=m&key=k&exp=\(Int(now.timeIntervalSince1970 * 1000) + 3_600_000)&sig=s"
        let old = "/intelligence/plot?member_id=m&key=k&exp=\(Int(now.timeIntervalSince1970 * 1000) - 1)&sig=s"
        let soon = "/intelligence/plot?key=k&exp=\(Int(now.timeIntervalSince1970 * 1000) + 30_000)"
        XCTAssertTrue(abs((CreaImages.expiry(fresh)?.timeIntervalSince(now) ?? 0) - 3600) < 0.01)
        XCTAssertFalse(CreaImages.isStale(fresh, now: now))
        XCTAssertTrue(CreaImages.isStale(old, now: now))
        XCTAssertTrue(CreaImages.isStale(soon, now: now))
        XCTAssertFalse(CreaImages.isStale("/agents/crea/img?k=1", now: now))
        XCTAssertNil(CreaImages.expiry("/intelligence/plot?exp=abc"))
    }

    func testVerdicts() {
        XCTAssertEqual(CreaImages.verdict(status: 200), .ok)
        XCTAssertEqual(CreaImages.verdict(status: 403), .relink)
        XCTAssertEqual(CreaImages.verdict(status: 401), .relink)
        XCTAssertEqual(CreaImages.verdict(status: 410), .relink)
        XCTAssertEqual(CreaImages.verdict(status: 0), .retry)
        XCTAssertEqual(CreaImages.verdict(status: 503), .retry)
        XCTAssertEqual(CreaImages.verdict(status: 429), .retry)
        XCTAssertEqual(CreaImages.verdict(status: 404), .gone)
        XCTAssertEqual(CreaImages.verdict(status: 400), .gone)
    }

    func testLinksFromBlocks() {
        let blocks = [block(draftsJSON), block(#"{"images":[{"id":"z","url":"/intelligence/plot?key=z"}]}"#, tool: "plot"),
                      block(#"{"images":[{"id":"q","status":"pending"}]}"#)]
        let l = CreaImages.links(in: blocks)
        XCTAssertEqual(l["a1"], "/intelligence/plot?key=k1")
        XCTAssertEqual(l["b2"], "/intelligence/plot?member_id=m&key=k2&exp=1&sig=s")
        XCTAssertNil(l["z"])   // another tool
        XCTAssertNil(l["q"])   // no link yet
    }

    func testSignedPathGoesToAIHost() {
        // The agents worker signs with the /intelligence/plot route: that route is the AI worker's, never lia.
        let u = CreaImages.absoluteURL("/intelligence/plot?member_id=m&key=ai%2Fm%2Fatt%2Fcrea%2Fx.png&exp=1&sig=s",
                                       aiBase: "https://ai.liaisone.com", agentsBase: "https://lia.liaisone.com")
        XCTAssertEqual(u?.host, "ai.liaisone.com")
        XCTAssertEqual(u?.path, "/intelligence/plot")
    }

    // A batch shown as "1" and "4". The shown numbers are 1...count; "Use this" names both numbers
    // when they differ; the gap is one line.
    func testDraftsNumberedConsecutively() {
        guard let c = CreaImages(block(draftsJSON)) else { return XCTFail("drafts block not read") }
        XCTAssertEqual(c.images.map { c.shownNumber($0) }, [1, 2, 3])
        XCTAssertEqual(c.missingDrafts, 3)        // the server numbered up to 6 and three came back
        XCTAssertEqual(c.missingLine, "3 drafts could not be made.")
        XCTAssertEqual(CreaImages.useDraft(shown: 2, server: 2), "Use draft 2")
        XCTAssertEqual(CreaImages.useDraft(shown: 2, server: 4), "Use draft 2 (number 4 in the drafts list)")
        let gap = block(#"{"stage":"drafts","note":"One draft failed — not charged.","images":[{"id":"a","n":1,"url":"/a"},{"id":"d","n":4,"url":"/d"},{"id":"c","n":3,"url":"/c"}]}"#)
        guard let g = CreaImages(gap) else { return XCTFail("gap block not read") }
        XCTAssertEqual(g.images.map(\.n), [1, 3, 4])
        XCTAssertEqual(g.images.map { g.shownNumber($0) }, [1, 2, 3])
        XCTAssertEqual(g.missingDrafts, 1)
        XCTAssertNil(g.missingLine)               // the server's note says it already
        let whole = block(#"{"stage":"drafts","images":[{"id":"a","n":1,"url":"/a"},{"id":"b","n":2,"url":"/b"}]}"#)
        XCTAssertEqual(CreaImages(whole)?.missingDrafts, 0)
        XCTAssertNil(CreaImages(whole)?.missingLine)
        let final = block(#"{"stage":"final","images":[{"id":"f","n":3,"url":"/f"}]}"#)
        XCTAssertEqual(CreaImages(final)?.missingDrafts, 0)
    }
}
