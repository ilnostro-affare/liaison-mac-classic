import XCTest
import Foundation
@testable import Liaison

/// When a downloaded update relaunches the app by itself and when it only tells the person.
final class UpdatePolicyTests: XCTestCase {
    private func ctx(_ m: UpdatePolicy.Moment, busy: UpdatePolicy.Busy = .none, launch: TimeInterval = 5000,
                     wake: TimeInterval? = nil, react: TimeInterval? = nil, idle: TimeInterval = 1, active: Bool = true) -> UpdatePolicy.Context {
        UpdatePolicy.Context(moment: m, busy: busy, sinceLaunch: launch, sinceWake: wake, sinceReactivation: react,
                             systemIdle: idle, appActive: active)
    }

    func testLaunchInstallsRightAway() {
        XCTAssertEqual(UpdatePolicy.decide(ctx(.launch, launch: 1, idle: 0)), .installNow)
        // Found a minute after launch, the person quiet: still the launch.
        XCTAssertEqual(UpdatePolicy.decide(ctx(.ready, launch: 60, idle: 30)), .installNow)
    }

    func testLaunchGraceEndsWhenThePersonIsTyping() {
        XCTAssertEqual(UpdatePolicy.decide(ctx(.ready, launch: 60, idle: 1)), .notify(system: false))
        XCTAssertEqual(UpdatePolicy.decide(ctx(.ready, launch: 500, idle: 30)), .notify(system: false))
    }

    func testWakeInstallsWhenNothingRuns() {
        XCTAssertEqual(UpdatePolicy.decide(ctx(.wake, wake: 0, idle: 0)), .installNow)
        XCTAssertEqual(UpdatePolicy.decide(ctx(.ready, wake: 90, idle: 10, active: false)), .installNow)
        XCTAssertEqual(UpdatePolicy.decide(ctx(.ready, wake: 400, idle: 10, active: false)), .notify(system: true))
    }

    func testComingBackAfterALongWhileInstalls() {
        XCTAssertTrue(UpdatePolicy.isReturn(backgroundFor: 45 * 60))
        XCTAssertFalse(UpdatePolicy.isReturn(backgroundFor: 60))
        XCTAssertEqual(UpdatePolicy.decide(ctx(.reactivated, react: 0, idle: 0)), .installNow)
        XCTAssertEqual(UpdatePolicy.decide(ctx(.timer, react: 200, idle: 1)), .notify(system: false))
    }

    func testAwayFromTheMacInstalls() {
        XCTAssertEqual(UpdatePolicy.decide(ctx(.timer, idle: 16 * 60, active: false)), .installNow)
        XCTAssertEqual(UpdatePolicy.decide(ctx(.timer, idle: 16 * 60, active: true)), .installNow)
        XCTAssertEqual(UpdatePolicy.decide(ctx(.timer, idle: 2 * 60, active: true)), .notify(system: false))
    }

    func testNeverInstallsOverWork() {
        let cases: [UpdatePolicy.Busy] = [
            .init(agentRuns: 1), .init(gatesPending: 1), .init(unsentDrafts: 1), .init(otherRuns: 1),
        ]
        for b in cases {
            XCTAssertEqual(UpdatePolicy.decide(ctx(.launch, busy: b, launch: 1, idle: 0)), .notify(system: false))
            XCTAssertEqual(UpdatePolicy.decide(ctx(.wake, busy: b, wake: 0, idle: 0, active: false)), .notify(system: true))
            XCTAssertEqual(UpdatePolicy.decide(ctx(.timer, busy: b, idle: 3600)), .notify(system: false))
            XCTAssertTrue(UpdatePolicy.needsConfirm(b))
        }
        XCTAssertFalse(UpdatePolicy.needsConfirm(.none))
    }

    func testConfirmText() {
        XCTAssertEqual(UpdatePolicy.confirmText(.none), "Restart Liaison now?")
        XCTAssertEqual(UpdatePolicy.confirmText(.init(agentRuns: 1)), "An agent is working. Restart anyway?")
        XCTAssertEqual(UpdatePolicy.confirmText(.init(agentRuns: 2, gatesPending: 1, unsentDrafts: 1)),
                       "2 agents are working, a change waits for your Yes and a message is not sent yet. Restart anyway?")
    }

    func testBannerLaterIsPerVersion() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        XCTAssertFalse(UpdatePolicy.bannerVisible(ready: nil, snoozedVersion: nil, snoozedUntil: nil, now: now))
        XCTAssertTrue(UpdatePolicy.bannerVisible(ready: "0.9.1", snoozedVersion: nil, snoozedUntil: nil, now: now))
        XCTAssertFalse(UpdatePolicy.bannerVisible(ready: "0.9.1", snoozedVersion: "0.9.1", snoozedUntil: now.addingTimeInterval(60), now: now))
        XCTAssertTrue(UpdatePolicy.bannerVisible(ready: "0.9.1", snoozedVersion: "0.9.1", snoozedUntil: now.addingTimeInterval(-1), now: now))
        // A newer release shows again even inside the snooze.
        XCTAssertTrue(UpdatePolicy.bannerVisible(ready: "0.9.2", snoozedVersion: "0.9.1", snoozedUntil: now.addingTimeInterval(60), now: now))
    }

    func testSystemNotificationOncePerVersionInTheBackground() {
        XCTAssertTrue(UpdatePolicy.shouldPostSystem(version: "1.0", alreadyPosted: nil, appActive: false))
        XCTAssertFalse(UpdatePolicy.shouldPostSystem(version: "1.0", alreadyPosted: "1.0", appActive: false))
        XCTAssertFalse(UpdatePolicy.shouldPostSystem(version: "1.0", alreadyPosted: nil, appActive: true))
        XCTAssertTrue(UpdatePolicy.shouldPostSystem(version: "1.1", alreadyPosted: "1.0", appActive: false))
    }
}
