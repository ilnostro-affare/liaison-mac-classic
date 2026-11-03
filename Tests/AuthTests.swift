import XCTest
@testable import Liaison

// Mac only: AuthAPI depends on URLSession async APIs.
final class AuthErrorMappingTests: XCTestCase {
    func testMemberstackCodesMap() {
        XCTAssertEqual(AuthAPI.mapError(status: 404, json: ["code": "passwordless-email-not-found"]), .emailNotFound)
        XCTAssertEqual(AuthAPI.mapError(status: 400, json: ["code": "invalid-passwordless-login-code"]), .invalidCode)
        XCTAssertEqual(AuthAPI.mapError(status: 429, json: [:]), .rateLimited)
        XCTAssertEqual(AuthAPI.mapError(status: 502, json: [:]), .network)
        XCTAssertEqual(AuthAPI.mapError(status: 418, json: [:]), .server("HTTP 418"))
    }
}
