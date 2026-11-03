import XCTest
import Foundation
@testable import Liaison

/// QR sign-in (Shared/Core/QRSignIn.swift). The server's half is tested in the web repo.
final class QRSignInTests: XCTestCase {
    private let code = String(repeating: "a", count: 40) + "B-_"
    private let poll = String(repeating: "z", count: 43)

    func testPayloadPutsTheCodeInTheFragment() {
        XCTAssertEqual(QRSignIn.payload(code: code), "https://liaisone.com/qr#" + code)
    }

    func testShortCodeIsShownInTwoGroups() {
        XCTAssertEqual(QRSignIn.displayShort("abc234"), "ABC 234")
        XCTAssertEqual(QRSignIn.displayShort("ABCD"), "ABCD")
        XCTAssertEqual(QRSignIn.manualHint(short: "XYZ789"), "Or open liaisone.com/qr and enter XYZ 789")
    }

    func testCodeShape() {
        XCTAssertTrue(QRSignIn.isCodeLike(code))
        XCTAssertFalse(QRSignIn.isCodeLike("short"))
        XCTAssertFalse(QRSignIn.isCodeLike(String(repeating: "a", count: 42) + "#"))
        XCTAssertFalse(QRSignIn.isCodeLike(String(repeating: "a", count: 65)))
    }

    func testTicketFromStart() {
        let now = Date(timeIntervalSince1970: 1_000)
        let t = QRSignIn.ticket(status: 200, json: ["ok": true, "code": code, "poll": poll, "short": "abc234", "expires_in": 120], now: now)
        XCTAssertNotNil(t)
        XCTAssertEqual(t?.short, "ABC234")
        XCTAssertEqual(t?.payload, "https://liaisone.com/qr#" + code)
        XCTAssertEqual(t?.secondsLeft(now: now.addingTimeInterval(19.2)), 101)
        XCTAssertEqual(t?.isExpired(now: now.addingTimeInterval(119)), false)
        XCTAssertEqual(t?.isExpired(now: now.addingTimeInterval(120)), true)
        XCTAssertEqual(t?.secondsLeft(now: now.addingTimeInterval(500)), 0)
        XCTAssertNil(QRSignIn.ticket(status: 429, json: ["ok": false], now: now))
        XCTAssertNil(QRSignIn.ticket(status: 200, json: ["ok": true, "code": code, "short": "abc234"], now: now), "no poll secret, no ticket")
        XCTAssertNil(QRSignIn.ticket(status: 200, json: ["ok": true, "code": "x", "poll": poll, "short": "abc234"], now: now))
    }

    func testPollResults() {
        XCTAssertEqual(QRSignIn.pollResult(status: 200, json: ["ok": true, "state": "pending"]), .pending)
        XCTAssertEqual(QRSignIn.pollResult(status: 200, json: ["ok": true, "state": "approved", "member_token": "eyA.b.c", "email": "e@x.it"]),
                       .approved(memberToken: "eyA.b.c", email: "e@x.it"))
        XCTAssertEqual(QRSignIn.pollResult(status: 200, json: ["ok": true, "state": "approved"]), .expired, "approved without a token is not a sign-in")
        XCTAssertEqual(QRSignIn.pollResult(status: 200, json: ["ok": true, "state": "denied"]), .denied)
        XCTAssertEqual(QRSignIn.pollResult(status: 410, json: ["ok": false, "state": "consumed"]), .expired)
        XCTAssertEqual(QRSignIn.pollResult(status: 410, json: ["ok": false, "state": "expired"]), .expired)
        XCTAssertEqual(QRSignIn.pollResult(status: 403, json: ["ok": false]), .expired)
        XCTAssertEqual(QRSignIn.pollResult(status: 429, json: [:]), .rateLimited)
        XCTAssertEqual(QRSignIn.pollResult(status: 0, json: [:]), .retry)
        XCTAssertEqual(QRSignIn.pollResult(status: 502, json: [:]), .retry)
    }
}
