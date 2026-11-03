import XCTest
import Foundation
@testable import Liaison

/// The person's default face (a stable palette colour) and the avatars' wire.
final class AvatarsTests: XCTestCase {
    func testHashIsFNV1a() {
        XCTAssertEqual(PersonAvatar.fnv1a(""), 0x811C9DC5)
        XCTAssertEqual(PersonAvatar.fnv1a("a"), 0xE40C292C)
        XCTAssertEqual(PersonAvatar.fnv1a("foobar"), 0xBF9CF968)
    }

    func testColourIsStableAndFromThePalette() {
        let a = PersonAvatar.colorHex(seed: "mem_example000000000000000")
        XCTAssertTrue(CompanyProfile.palette.contains(a))
        XCTAssertEqual(a, PersonAvatar.colorHex(seed: "mem_example000000000000000"))
        XCTAssertEqual(PersonAvatar.colorHex(seed: " Sam@Example.com "), PersonAvatar.colorHex(seed: "sam@example.com"))
        XCTAssertEqual(PersonAvatar.colorHex(seed: "a"), CompanyProfile.palette[Int(0xE40C292C as UInt32 % 7)])
    }

    func testNotEveryoneTheSameColour() {
        let colours = Set((0..<60).map { PersonAvatar.colorHex(seed: "mem_\($0)") })
        XCTAssertTrue(colours.count >= 5)
        XCTAssertFalse(colours.contains(0x1F2430))
    }

    func testCropIsTheCentredSquare() {
        let w = PersonAvatar.crop(width: 1600, height: 900)
        XCTAssertEqual(w.x, 350); XCTAssertEqual(w.y, 0); XCTAssertEqual(w.side, 900); XCTAssertEqual(w.out, 512)
        let t = PersonAvatar.crop(width: 300, height: 400)
        XCTAssertEqual(t.x, 0); XCTAssertEqual(t.y, 50); XCTAssertEqual(t.side, 300); XCTAssertEqual(t.out, 300)
    }

    func testFolder() {
        XCTAssertEqual(PersonAvatar.folder("mem_ABC-1"), "mem_abc-1")
        XCTAssertEqual(PersonAvatar.folder("a@b.c/../x"), "a_b_c____x")
        XCTAssertEqual(PersonAvatar.folder(""), "_none")
    }

    func testWhoAndBody() {
        XCTAssertEqual(AvatarWho.me.id, "me")
        XCTAssertEqual(AvatarWho.workspace("p1").id, "ws:p1")
        XCTAssertEqual(AvatarWho.workspace("p1").body(key: "k")["profile"] as? String, "p1")
        XCTAssertEqual(AvatarWho.me.body(key: "")["target"] as? String, "me")
    }

    func testParse() {
        let d = Data(#"{"ok":true,"me":{"key":"ai/m/att/1.jpg","url":"/intelligence/plot?key=1"},"workspaces":{"p1":{"key":"ai/m/att/2.jpg","url":"/x"},"p2":{"key":"nope","url":"/y"}}}"#.utf8)
        let s = AvatarSet.parse(d)
        XCTAssertEqual(s?.me?.key, "ai/m/att/1.jpg")
        XCTAssertEqual(s?.workspaces.count, 1)
        XCTAssertEqual(s?.byId["ws:p1"]?.url, "/x")
        XCTAssertNil(AvatarSet.parse(Data(#"{"ok":false}"#.utf8)))
        XCTAssertNil(AvatarSet.parse(Data(#"{"ok":true,"me":null,"workspaces":{}}"#.utf8))?.me)
    }
}
