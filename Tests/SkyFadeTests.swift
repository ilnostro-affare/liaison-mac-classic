import XCTest
import Foundation
@testable import Liaison

/// The sky's long, smooth fade into the page.
final class SkyFadeTests: XCTestCase {
    func testFadeStopsRunFromSolidToNothing() {
        let s = Sky.fadeStops()
        XCTAssertEqual(s.first?.location, 0)
        XCTAssertEqual(s.first?.alpha, 1)
        XCTAssertTrue(abs((s.last?.location ?? 0) - 1) < 1e-9)
        XCTAssertTrue((s.last?.alpha ?? 1) < 1e-9)
        for i in 1..<s.count {
            XCTAssertTrue(s[i].location >= s[i - 1].location)
            XCTAssertTrue(s[i].alpha <= s[i - 1].alpha + 1e-12)
        }
    }

    func testFadeStartsWhereTheOldOneDidAndReachesFurther() {
        let card = 800.0
        let h = Sky.skyHeight(cardHeight: card)
        let H = Sky.fadeHeight(cardHeight: card)
        XCTAssertTrue(H > h)
        XCTAssertTrue(abs(Sky.fadeHold * H - 0.55 * h) < 1e-6)
        // The ease is gentle at both ends: the first step below the hold loses only a little.
        let s = Sky.fadeStops()
        guard let i = s.firstIndex(where: { $0.alpha < 1 }) else { return XCTFail("no fade") }
        XCTAssertTrue(s[i].alpha > 0.95)
    }

    func testScaledStopsSqueezeTheGradient() {
        let look = Sky.look(phase: .day, condition: .clear)
        let sc = look.scaledStops(0.5)
        XCTAssertEqual(sc.count, look.stops.count)
        XCTAssertTrue(abs((sc.last?.location ?? 0) - 0.5) < 1e-9)
        XCTAssertEqual(sc.first?.color, look.stops.first?.color)
    }
}
