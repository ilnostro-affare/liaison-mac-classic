import XCTest
import Foundation
@testable import Liaison

/// The side panel's per-service table (Shared/Core/PanelProfiles.swift).
final class PanelProfilesTests: XCTestCase {
    func testTable() {
        XCTAssertEqual(PanelProfiles.profile(for: URL(string: "https://web.whatsapp.com/")).service, "WhatsApp")
        XCTAssertEqual(PanelProfiles.profile(host: "web.whatsapp.com").virtualWidth, 1000)
        XCTAssertEqual(PanelProfiles.profile(host: "mail.google.com").agent, .mobile)
        XCTAssertEqual(PanelProfiles.profile(host: "MAIL.google.com").service, "Gmail")
        XCTAssertEqual(PanelProfiles.profile(host: "calendar.google.com"), .plain)
        XCTAssertEqual(PanelProfiles.profile(host: "web.telegram.org").agent, .desktop)
        XCTAssertNil(PanelProfiles.profile(host: "web.telegram.org").virtualWidth)
        XCTAssertEqual(PanelProfiles.profile(host: "app.slack.com").service, "Slack")
        XCTAssertEqual(PanelProfiles.profile(host: "notslack.com"), .plain)
        XCTAssertEqual(PanelProfiles.profile(host: "whatsapp.com.evil.io"), .plain)
        XCTAssertEqual(PanelProfiles.profile(host: nil), .plain)
        XCTAssertEqual(PanelProfiles.profile(for: nil), .plain)
    }

    func testAgent() {
        let g = PanelProfiles.profile(host: "mail.google.com")
        XCTAssertTrue(PanelProfiles.userAgent(g, desktop: "D").contains("iPhone"))
        XCTAssertEqual(PanelProfiles.userAgent(.plain, desktop: "D"), "D")
    }

    func testLayout() {
        let w = PanelProfiles.profile(host: "web.whatsapp.com")
        // Always fits the panel, no sideways scroll (380 / 1000 = 0.38; the old 0.7 floor hid the QR code).
        let n = PanelProfiles.layout(w, panelWidth: 380)
        XCTAssertTrue(abs(n.zoom - 0.38) < 0.0001)
        XCTAssertEqual(n.documentWidth, 380)
        let m = PanelProfiles.layout(w, panelWidth: 640)
        XCTAssertTrue(abs(m.zoom - 0.64) < 0.0001)
        XCTAssertEqual(m.documentWidth, 640)
        XCTAssertEqual(PanelProfiles.layout(w, panelWidth: 1200), PanelLayout(zoom: 1, documentWidth: 1200))
        // The sanity floor only: a very narrow panel stops at 0.3.
        XCTAssertEqual(PanelProfiles.layout(w, panelWidth: 200).zoom, 0.3)
        XCTAssertEqual(PanelProfiles.layout(.plain, panelWidth: 380), PanelLayout(zoom: 1, documentWidth: 380))
        XCTAssertEqual(PanelProfiles.layout(w, panelWidth: 0), PanelLayout(zoom: 1, documentWidth: 0))
        // The person's zoom wins over Fit, the web view stays the panel's width.
        XCTAssertEqual(PanelProfiles.layout(w, panelWidth: 380, userZoom: 0.6), PanelLayout(zoom: 0.6, documentWidth: 380))
        XCTAssertEqual(PanelProfiles.layout(.plain, panelWidth: 380, userZoom: 9), PanelLayout(zoom: 2, documentWidth: 380))
        XCTAssertEqual(PanelProfiles.layout(.plain, panelWidth: 380, userZoom: 0.01).zoom, 0.3)
    }

    func testZoomSteps() {
        XCTAssertEqual(PanelProfiles.step(0.38, up: true), 0.4)
        XCTAssertEqual(PanelProfiles.step(0.38, up: false), 0.3)
        XCTAssertEqual(PanelProfiles.step(1, up: true), 1.1)
        XCTAssertEqual(PanelProfiles.step(1, up: false), 0.9)
        XCTAssertEqual(PanelProfiles.step(2, up: true), 2)
        XCTAssertEqual(PanelProfiles.step(0.3, up: false), 0.3)
        XCTAssertEqual(PanelProfiles.percent(0.38), "38%")
        XCTAssertEqual(PanelProfiles.percent(1.25), "125%")
    }

    func testZoomKey() {
        XCTAssertEqual(PanelProfiles.zoomKey(URL(string: "https://web.whatsapp.com/")), "whatsapp")
        XCTAssertEqual(PanelProfiles.zoomKey(URL(string: "https://www.Notion.so/x")), "notion.so")
        XCTAssertEqual(PanelProfiles.zoomKey(URL(string: "https://calendar.google.com/")), "calendar.google.com")
        XCTAssertNil(PanelProfiles.zoomKey(nil))
    }

    func testWidths() {
        XCTAssertEqual(PanelProfiles.width(wide: false), 380)
        XCTAssertTrue(PanelProfiles.width(wide: true) > PanelProfiles.width(wide: false))
    }
}
