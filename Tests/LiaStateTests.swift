import XCTest
import Foundation
#if canImport(Liaison)
@testable import Liaison
#endif

// Fixtures repeat the SHAPE of the /intelligence/state response as the server writes it.
final class LiaStateTests: XCTestCase {
    private func decode(_ s: String) throws -> LiaState {
        try JSONDecoder().decode(LiaState.self, from: Data(s.utf8))
    }

    func testDecodesChatsAndProjects() throws {
        let st = try decode(#"{"ok":true,"chats":[{"id":"c1","title":"Budget","project":"p1","starred":true,"updated":1789570000000}],"projects":[{"id":"p1","name":"Yoga studio","account":"123"}],"crm":null}"#)
        XCTAssertEqual(st.chats.count, 1)
        XCTAssertEqual(st.chats.first?.title, "Budget")
        XCTAssertEqual(st.chats.first?.starred, true)
        XCTAssertEqual(st.projects.first?.name, "Yoga studio")
    }

    func testOneBrokenChatDoesNotDropTheList() throws {
        let st = try decode(#"{"ok":true,"chats":[{"title":"no id"},{"id":"c2","title":"Kept"}],"projects":[]}"#)
        XCTAssertEqual(st.chats.map(\.id), ["c2"])
    }

    func testMissingOptionalFieldsAndStringUpdated() throws {
        let st = try decode(#"{"ok":true,"chats":[{"id":"c3","updated":"1789570000001"},{"id":"c4","starred":null}],"projects":[{"id":"p9"}]}"#)
        XCTAssertEqual(st.chats.first(where: { $0.id == "c3" })?.updated, 1789570000001)
        XCTAssertEqual(st.chats.first(where: { $0.id == "c3" })?.displayTitle, "Untitled chat")
        XCTAssertEqual(st.chats.first(where: { $0.id == "c4" })?.starred, false)
        XCTAssertEqual(st.projects.first?.name, "Project")
    }

    func testNotOkThrows() {
        XCTAssertThrowsError(try decode(#"{"ok":false,"error":"unauthorized"}"#))
    }

    func testPinnedFirstThenNewest() throws {
        let st = try decode(#"{"ok":true,"chats":[{"id":"old","updated":1},{"id":"new","updated":3},{"id":"pin","starred":true,"updated":2}],"projects":[]}"#)
        XCTAssertEqual(st.sortedChats.map(\.id), ["pin", "new", "old"])
    }
}
