import XCTest
import Foundation
@testable import Liaison

/// Pictures in a conversation and the profile's Media tab (an address rebuilt from a library
/// upload's key), and the Links tab (never our own hosts or a machine's addresses).
final class AgentItemsTests: XCTestCase {
    func testUploadKeyRebuildsTheAssetAddress() {
        let k = "mem_abc/uploads/1760000000-photo one.png"
        XCTAssertNil(MediaKeys.uploadAssetURL(k))   // a space never makes an address
        let ok = "mem_abc/uploads/1760000000-photo.png"
        XCTAssertEqual(MediaKeys.uploadAssetURL(ok),
                       "https://api.liaisone.com/meta/upload-asset?member_id=mem_abc&key=mem_abc%2Fuploads%2F1760000000-photo.png")
        XCTAssertEqual(MediaKeys.uploadAssetURL("mem_abc/uploads/v.MP4"),
                       "https://api.liaisone.com/meta/upload-asset?member_id=mem_abc&key=mem_abc%2Fuploads%2Fv.MP4.poster.jpg")
        XCTAssertNil(MediaKeys.uploadAssetURL("ai/mem_abc/att/x.png"))
        XCTAssertNil(MediaKeys.uploadAssetURL("/uploads/x.png"))
        XCTAssertNil(MediaKeys.uploadAssetURL("1234abcd"))   // an image hash
        XCTAssertNil(MediaKeys.uploadAssetURL(nil))
        XCTAssertTrue(MediaKeys.isSignedAttachment("ai/mem_abc/att/x.png"))
        XCTAssertFalse(MediaKeys.isSignedAttachment(ok))
    }

    func testPictureURLPrefersTheServersAddress() {
        let base = "https://lia.liaisone.com"
        XCTAssertEqual(MediaKeys.pictureURL(url: "https://x.example.com/a.png", key: nil, base: base), "https://x.example.com/a.png")
        XCTAssertEqual(MediaKeys.pictureURL(url: "/agents/file?k=1", key: nil, base: base), base + "/agents/file?k=1")
        XCTAssertEqual(MediaKeys.pictureURL(url: nil, key: "m1/uploads/a.jpg", base: base),
                       "https://api.liaisone.com/meta/upload-asset?member_id=m1&key=m1%2Fuploads%2Fa.jpg")
        XCTAssertNil(MediaKeys.pictureURL(url: "", key: "ai/m1/att/a.jpg", base: base))   // only the server can sign it
    }

    func testOurHostsAndMachineAddressesAreHidden() {
        for h in ["liaisone.com", "api.liaisone.com", "abc.dev.liaisone.com", "liaisone.io", "api.example.workers.dev",
                  "pub-1.r2.dev", "localhost", "127.0.0.1", "192.168.1.4", "", "LIAISONE.COM."] {
            XCTAssertTrue(AgentLinks.isInternal(h), h)
        }
        for h in ["example.com", "www.facebook.com", "notliaisone.com", "liaisone.com.evil.org"] {
            XCTAssertFalse(AgentLinks.isInternal(h), h)
        }
        XCTAssertNil(AgentLinks.address("javascript:alert(1)"))
        XCTAssertNil(AgentLinks.address("https://intranet/x"))
        XCTAssertNil(AgentLinks.address("https://mcp.liaisone.com/call/plan"))
        XCTAssertEqual(AgentLinks.address(" https://www.example.com/a ")?.absoluteString, "https://www.example.com/a")
    }

    func testVisibleLinksAndTheirTitles() {
        let items = [
            DlgItem(msgId: "1", kind: .links, url: "https://api.liaisone.com/meta/write/plan?x=1", title: "api.liaisone.com"),
            DlgItem(msgId: "2", kind: .links, url: "https://www.example.com/blog/spring-sale-ideas", title: "www.example.com"),
            DlgItem(msgId: "3", kind: .links, url: "https://www.example.com/blog/spring-sale-ideas", title: nil),
            DlgItem(msgId: "4", kind: .links, url: "https://shop.example.org/", title: "Shop - Spring"),
            DlgItem(msgId: "5", kind: .media, url: "https://www.example.com/a.png"),
            DlgItem(msgId: "6", kind: .links, url: "x.workers.dev", title: nil),
        ]
        let v = AgentLinks.visible(items)
        XCTAssertEqual(v.map(\.msgId), ["2", "4"])
        let u = AgentLinks.address(v[0].url)!
        XCTAssertEqual(AgentLinks.host(u), "example.com")
        XCTAssertEqual(AgentLinks.title(u, served: v[0].title), "Spring sale ideas")
        let s = AgentLinks.address(v[1].url)!
        XCTAssertEqual(AgentLinks.title(s, served: v[1].title), "Shop - Spring")
        XCTAssertEqual(AgentLinks.title(URL(string: "https://example.com/")!, served: nil), "example.com")
    }

    func testDevLinksPassTheFilter() {
        let items = [
            DlgItem(msgId: "1", kind: .links, name: "dev", url: "https://p-abc.liaisone.com/", title: "Preview"),
            DlgItem(msgId: "2", kind: .links, name: "dev", url: "https://shop.sites.liaisone.com/", title: "Live site \u{00B7} shop"),
            DlgItem(msgId: "3", kind: .links, name: "x", url: "https://api.liaisone.com/a", title: nil),
            DlgItem(msgId: "4", kind: .links, name: "dev", url: "javascript:alert(1)", title: "Preview"),
            DlgItem(msgId: "5", kind: .links, name: "dev", url: "https://p-abc.liaisone.com/", title: "Preview"),
        ]
        let v = AgentLinks.visible(items)
        XCTAssertEqual(v.map(\.msgId), ["1", "2"])
        XCTAssertFalse(AgentLinks.isLiveSite(v[0]))
        XCTAssertTrue(AgentLinks.isLiveSite(v[1]))
        XCTAssertEqual(AgentLinks.link(v[1])?.host, "shop.sites.liaisone.com")
        XCTAssertNil(AgentLinks.link(items[2]))
    }

    func testCodeItemsAndDevTabs() {
        XCTAssertEqual(DlgItem.Kind.profileTabs(agent: "dev"), [.media, .files, .links, .code])
        XCTAssertEqual(DlgItem.Kind.profileTabs(agent: "lia"), [.media, .files, .links, .plans])
        let o: JSONObject = ["msg_id": "m1", "dlg": "dev", "kind": "code", "ts": 1_760_000_000_000.0, "title": "feat/hero",
                             "name": "acme/site", "key": "abc1234", "url": "https://github.com/acme/site/compare/main...feat/hero",
                             "bytes": 2]
        let it = DlgItem(json: o)
        XCTAssertEqual(it?.kind, .code)
        XCTAssertEqual(it?.codeSubtitle, "acme/site \u{00B7} abc1234 \u{00B7} 2 commits")
        XCTAssertEqual(DlgItem(msgId: "m", kind: .code, name: "a/b", bytes: 1).codeSubtitle, "a/b \u{00B7} 1 commit")
        XCTAssertEqual(DlgItem(msgId: "m", kind: .code).codeSubtitle, "")
    }
}
