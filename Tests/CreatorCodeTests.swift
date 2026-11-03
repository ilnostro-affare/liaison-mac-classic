import XCTest
import Foundation
@testable import Liaison

/// The creator code at sign-up and in Settings (lia-agents /creators/code, /agents/creator-code).
final class CreatorCodeTests: XCTestCase {
    func testNormalize() {
        XCTAssertEqual(CreatorCode.normalize("jdoe20"), "JDOE20")
        XCTAssertEqual(CreatorCode.normalize(" ab-c d_1! "), "ABCD1")
        XCTAssertEqual(CreatorCode.normalize("çaféÉ9"), "AF9")
        XCTAssertEqual(CreatorCode.normalize("１２AB"), "AB")
        XCTAssertEqual(CreatorCode.normalize(String(repeating: "a", count: 30)).count, 20)
        XCTAssertEqual(CreatorCode.normalize(""), "")
    }

    func testWellFormed() {
        XCTAssertTrue(CreatorCode.isWellFormed("ABC"))
        XCTAssertTrue(CreatorCode.isWellFormed(String(repeating: "Z", count: 20)))
        XCTAssertFalse(CreatorCode.isWellFormed("AB"))
        XCTAssertFalse(CreatorCode.isWellFormed("abc"))
        XCTAssertFalse(CreatorCode.isWellFormed("AB-C"))
        XCTAssertFalse(CreatorCode.isWellFormed(String(repeating: "Z", count: 21)))
    }

    func testLocalCheck() {
        XCTAssertEqual(CreatorCode.localCheck(""), .empty)
        XCTAssertEqual(CreatorCode.localCheck("AB"), .unknown)
        XCTAssertNil(CreatorCode.localCheck("JDOE"))
    }

    func testCheckAnswer() {
        XCTAssertEqual(CreatorCode.check(status: 200, json: ["ok": true, "valid": true]), .found)
        XCTAssertEqual(CreatorCode.check(status: 200, json: ["ok": true, "valid": false]), .unknown)
        XCTAssertEqual(CreatorCode.check(status: 429, json: ["ok": false]), .unverified)
        XCTAssertEqual(CreatorCode.check(status: 500, json: nil), .unverified)
        XCTAssertEqual(CreatorCode.check(status: 0, json: nil), .unverified)
        XCTAssertEqual(CreatorCode.check(status: 200, json: ["ok": true]), .unverified)
    }

    func testLabels() {
        XCTAssertEqual(CreatorCode.label(.found), "Code found")
        XCTAssertEqual(CreatorCode.label(.unknown), "We don't know this code")
        XCTAssertNil(CreatorCode.label(.unverified))
        XCTAssertNil(CreatorCode.label(.checking))
        XCTAssertNil(CreatorCode.label(.empty))
    }

    func testToSend() {
        XCTAssertEqual(CreatorCode.toSend("jdoe", .found), "JDOE")
        XCTAssertEqual(CreatorCode.toSend("JDOE", .unverified), "JDOE")
        XCTAssertEqual(CreatorCode.toSend("JDOE", .checking), "JDOE")
        XCTAssertNil(CreatorCode.toSend("JDOE", .unknown))
        XCTAssertNil(CreatorCode.toSend("AB", .found))
        XCTAssertNil(CreatorCode.toSend("", .empty))
    }

    func testSendOutcome() {
        XCTAssertEqual(CreatorCode.sendOutcome(status: 200, json: ["ok": true, "code": "jdoe"]), .saved("JDOE"))
        XCTAssertEqual(CreatorCode.sendOutcome(status: 200, json: ["ok": true]), .saved(nil))
        XCTAssertEqual(CreatorCode.sendOutcome(status: 200, json: ["ok": false, "error": "unknown_code"]), .refused("unknown_code"))
        XCTAssertEqual(CreatorCode.sendOutcome(status: 409, json: ["ok": false, "error": "already_set"]), .refused("already_set"))
        XCTAssertEqual(CreatorCode.sendOutcome(status: 400, json: ["ok": false, "error": "bad_code"]), .refused("bad_code"))
        XCTAssertEqual(CreatorCode.sendOutcome(status: 0, json: nil), .retry)
        XCTAssertEqual(CreatorCode.sendOutcome(status: 401, json: nil), .retry)
        XCTAssertEqual(CreatorCode.sendOutcome(status: 404, json: nil), .retry)
        XCTAssertEqual(CreatorCode.sendOutcome(status: 429, json: ["ok": false, "error": "rate_limited"]), .retry)
        XCTAssertEqual(CreatorCode.sendOutcome(status: 502, json: nil), .retry)
        XCTAssertEqual(CreatorCode.sendOutcome(status: 403, json: ["ok": false, "error": "forbidden"]), .refused("http_403"))
        XCTAssertEqual(CreatorCode.sendOutcome(status: 200, json: ["ok": false, "error": "weird"]), .retry)
    }

    func testRetryDecision() {
        XCTAssertTrue(CreatorCode.keepsAfter(.retry))
        XCTAssertFalse(CreatorCode.keepsAfter(.saved("JDOE")))
        XCTAssertFalse(CreatorCode.keepsAfter(.refused("unknown_code")))
        XCTAssertFalse(CreatorCode.keepsAfter(.refused("already_set")))
    }

    func testApplyMessage() {
        XCTAssertNil(CreatorCode.applyMessage(.saved("JDOE")))
        XCTAssertEqual(CreatorCode.applyMessage(.refused("unknown_code")), "We don't know this code")
        XCTAssertNil(CreatorCode.applyMessage(.refused("already_set")))
        XCTAssertNotNil(CreatorCode.applyMessage(.retry))
        for m in [CreatorCode.applyMessage(.retry), CreatorCode.applyMessage(.refused("bad_code")), CreatorCode.applyMessage(.refused("http_403"))] {
            XCTAssertFalse(m!.contains("\u{2014}") || m!.contains("\u{2013}"))
        }
    }

    func testSaved() {
        XCTAssertEqual(CreatorCode.saved(status: 200, json: ["ok": true, "code": "JDOE"]), .code("JDOE"))
        XCTAssertEqual(CreatorCode.saved(status: 200, json: ["ok": true, "code": NSNull()]), .none)
        XCTAssertEqual(CreatorCode.saved(status: 200, json: ["ok": true]), .none)
        XCTAssertEqual(CreatorCode.saved(status: 500, json: nil), .failed)
        XCTAssertEqual(CreatorCode.saved(status: 200, json: ["ok": false]), .failed)
    }

    func testPendingRoundTripAndLifetime() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let p = CreatorCode.Pending(code: "JDOE", via: .signup, at: now)
        XCTAssertEqual(CreatorCode.decode(CreatorCode.encode(p)), p)
        XCTAssertNil(CreatorCode.decode(nil))
        XCTAssertNil(CreatorCode.decode(Data("{}".utf8)))
        let bad = CreatorCode.Pending(code: "ab", via: .signup, at: now)
        XCTAssertNil(CreatorCode.decode(CreatorCode.encode(bad)))
        XCTAssertTrue(CreatorCode.keeps(p, now: now.addingTimeInterval(3 * 86400)))
        XCTAssertFalse(CreatorCode.keeps(p, now: now.addingTimeInterval(61 * 86400)))
        XCTAssertEqual(CreatorCode.pendingKey(member: "mem_1"), "lia_creator_code_pending_mem_1")
    }
}
