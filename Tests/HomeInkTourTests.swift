import XCTest
import Foundation
@testable import Liaison

/// Home's text over a dark sky reads (HomeInkTone), and the morning tour's GitHub step (TourGitHub).
final class HomeInkTourTests: XCTestCase {

    /// Every dark sky (lightText) with every weather: the secondary text is far above the old grey, and readable.
    func testSecondaryTextReadsOnEveryDarkSky() {
        var checked = 0
        for p in SkyPhase.allCases {
            for c in SkyCondition.allCases {
                let look = Sky.look(phase: p, condition: c)
                guard look.lightText else { continue }
                for stop in look.stops.prefix(2) {
                    let g = stop.color
                    let t2 = HomeInkTone.over(.text2, dark: true, ground: g)
                    let t3 = HomeInkTone.over(.text3, dark: true, ground: g)
                    let link = HomeInkTone.over(.link, dark: true, ground: g)
                    // The old dark greys (WS.text2 B4BAC3, WS.text3 7D838C, WS.blue 5B78FF) for comparison.
                    let old3 = HomeInkTone.contrast(SkyRGB(0x7D838C), g)
                    XCTAssertTrue(HomeInkTone.contrast(t3, g) > old3, "\(p) \(c)")
                    XCTAssertTrue(HomeInkTone.contrast(t2, g) >= 3.0, "\(p) \(c)")
                    XCTAssertTrue(HomeInkTone.contrast(t3, g) >= 2.4, "\(p) \(c)")
                    XCTAssertTrue(HomeInkTone.contrast(link, g) > HomeInkTone.contrast(SkyRGB(0x5B78FF), g), "\(p) \(c)")
                    checked += 1
                }
            }
        }
        XCTAssertTrue(checked > 4)
    }

    /// On a night sky secondary text meets WCAG AA (4.5:1).
    func testNightIsAA() {
        let g = Sky.look(phase: .night, condition: .clear).stops[1].color
        XCTAssertTrue(HomeInkTone.contrast(HomeInkTone.over(.text2, dark: true, ground: g), g) >= 4.5)
        XCTAssertTrue(HomeInkTone.contrast(HomeInkTone.over(.text3, dark: true, ground: g), g) >= 4.5)
    }

    /// "On the white Home keep as is": the light values are the app's light tokens.
    func testLightValuesUnchanged() {
        XCTAssertEqual(HomeInkTone.value(.ink, dark: false).hex, 0x0E1014)
        XCTAssertEqual(HomeInkTone.value(.text2, dark: false).hex, 0x4A505A)
        XCTAssertEqual(HomeInkTone.value(.text3, dark: false).hex, 0x8A8F98)
        XCTAssertEqual(HomeInkTone.value(.link, dark: false).hex, 0x3B5BFD)
        XCTAssertEqual(HomeInkTone.value(.warn, dark: false).hex, 0x8A4B05)
        for r in HomeInkTone.Role.allCases where r != .track {
            XCTAssertEqual(HomeInkTone.value(r, dark: false).alpha, 1)
        }
    }

    func testGitHubStepKind() {
        XCTAssertEqual(TourGitHub.kind(connected: false, repos: 0), .connect)
        XCTAssertEqual(TourGitHub.kind(connected: false, repos: 3), .connect)
        XCTAssertEqual(TourGitHub.kind(connected: true, repos: 2), .repos)
        XCTAssertEqual(TourGitHub.kind(connected: nil, repos: 1), .repos)
        XCTAssertEqual(TourGitHub.kind(connected: true, repos: 0), .pick)
        XCTAssertNil(TourGitHub.kind(connected: nil, repos: 0))
    }

    func testGitHubStepAnchorsAndActions() {
        XCTAssertEqual(TourGitHub.anchors(.repos).first, "repos")
        XCTAssertEqual(TourGitHub.anchors(.connect).first, "workspaces")
        XCTAssertEqual(TourGitHub.anchors(.pick).first, "workspaces")
        XCTAssertNil(TourGitHub.actionLabel(.repos))
        XCTAssertEqual(TourGitHub.actionLabel(.connect), "Connect")
        XCTAssertEqual(TourGitHub.actionLabel(.pick), "Open")
    }

    func testGitHubStepText() {
        XCTAssertEqual(TourGitHub.list([]), "your repositories")
        XCTAssertEqual(TourGitHub.list(["acme/site"]), "site")
        XCTAssertEqual(TourGitHub.list(["acme/site", "acme/api"]), "site and api")
        XCTAssertEqual(TourGitHub.list(["a/x", "a/y", "a/z", "b/w"]), "x, y and 2 more")
        let t = TourGitHub.text(.repos, names: ["acme/site"], dev: "Dev")
        XCTAssertTrue(t.contains("site"))
        XCTAssertTrue(t.contains("@Dev"))
        XCTAssertTrue(TourGitHub.text(.connect, names: [], dev: "Dev").hasPrefix("Connect GitHub"))
        for k in [TourGitHub.Kind.repos, .pick, .connect] {
            XCTAssertTrue(TourGitHub.text(k, names: ["acme/site", "acme/api"]).count < 140)
            XCTAssertFalse(TourGitHub.title(k).isEmpty)
        }
    }
}
