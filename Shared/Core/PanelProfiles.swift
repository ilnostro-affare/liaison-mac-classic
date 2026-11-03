import Foundation

// How each site is shown in the narrow side panel. Web apps behave badly at
// 380 pt, so a site gets the agent and the width that work for it there.
// FROM MEMORY, NOT MEASURED: which UI each service serves to which agent and width is what we remember of these sites;
// every row must be checked on the product's Mac before it is trusted.
// Telegram Web, Slack desktop agent, panel width as is (their layouts are responsive)
// Gmail iPhone Safari agent (Gmail's touch web UI fits a narrow column)
// WhatsApp Web desktop agent at a virtual 1000 px, fitted to the panel's width (380 pt: zoom 0.38) - it has
// no narrow layout.: the old 0.7 floor laid the page out 700 pt wide
// and scrolled it sideways, so the login QR code was off screen; now it always fits, vertical
// scroll only, and the person zooms with + / - in the panel's menu (remembered per site).
// Slack left at the panel's width: its client is responsive down to a phone-sized column (from
// memory). If the Mac shows Slack's "too narrow" / "use the app" page instead, give it a
// virtualWidth (about 800) like WhatsApp - MUST BE CHECKED ON THE MAC.
// anything else desktop agent, as is

enum PanelAgent: String, Equatable { case desktop, mobile }

struct PanelProfile: Equatable {
    /// The service's name, nil for a site the table does not know.
    let service: String?
    let agent: PanelAgent
    /// CSS pixels the page is laid out at; nil: the panel's own width.
    let virtualWidth: Double?
    /// The smallest zoom fitting may go to (a sanity floor, not a readability one: the page always fits the panel).
    let minZoom: Double

    static let plain = PanelProfile(service: nil, agent: .desktop, virtualWidth: nil, minZoom: 1)
}

/// The zoom and the web view's width for a panel of a given width.
struct PanelLayout: Equatable {
    let zoom: Double
    /// The web view's width in points: always the panel's (never sideways scroll).
    let documentWidth: Double
}

enum PanelProfiles {
    /// iPhone Safari (iOS 26 freezes the OS part at 18_6, as Safari does).
    static let mobileAgent = "Mozilla/5.0 (iPhone; CPU iPhone OS 18_6 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/26.0 Mobile/15E148 Safari/604.1"

    /// The panel's two widths (points): as it opens, and after "Wider".
    static let narrowWidth: Double = 380
    static let wideWidth: Double = 640

    static func width(wide: Bool) -> Double { wide ? wideWidth : narrowWidth }

    static func profile(for url: URL?) -> PanelProfile { profile(host: url?.host) }

    static func profile(host: String?) -> PanelProfile {
        guard let h = host?.lowercased(), !h.isEmpty else { return .plain }
        func on(_ d: String) -> Bool { h == d || h.hasSuffix("." + d) }
        if on("whatsapp.com") {
            return PanelProfile(service: "WhatsApp", agent: .desktop, virtualWidth: 1000, minZoom: 0.3)
        }
        if h == "mail.google.com" {
            return PanelProfile(service: "Gmail", agent: .mobile, virtualWidth: nil, minZoom: 1)
        }
        if on("telegram.org") {
            return PanelProfile(service: "Telegram", agent: .desktop, virtualWidth: nil, minZoom: 1)
        }
        if on("slack.com") {
            return PanelProfile(service: "Slack", agent: .desktop, virtualWidth: nil, minZoom: 1)
        }
        return .plain
    }

    /// The agent string for a profile; `desktop` is the app's own (the installed Safari's).
    static func userAgent(_ p: PanelProfile, desktop: String) -> String {
        p.agent == .mobile ? mobileAgent : desktop
    }

    /// The page's zoom for a panel width. `userZoom` is the person's own (+ / - in the panel's menu), nil: Fit (the
    /// profile's virtual width fitted into the panel, or 1 for a site laid out at the panel's own width). The web
    /// view is always exactly as wide as the panel: the page scrolls vertically only.
    static func layout(_ p: PanelProfile, panelWidth: Double, userZoom: Double? = nil) -> PanelLayout {
        let w = max(panelWidth, 0)
        if let u = userZoom { return PanelLayout(zoom: clampZoom(u), documentWidth: w) }
        return PanelLayout(zoom: fitZoom(p, panelWidth: w), documentWidth: w)
    }

    /// Fit: panel width / virtual width, never above 1 and never below the profile's floor.
    static func fitZoom(_ p: PanelProfile, panelWidth: Double) -> Double {
        guard panelWidth > 0, let vw = p.virtualWidth, vw > panelWidth else { return 1 }
        let floor = min(max(p.minZoom, minUserZoom), 1)
        return max(floor, panelWidth / vw)
    }

    // MARK: the person's zoom

    static let minUserZoom: Double = 0.3
    static let maxUserZoom: Double = 2
    /// The steps + and - walk through (Safari's, extended down for pages fitted into a narrow column).
    static let zoomSteps: [Double] = [0.3, 0.4, 0.5, 0.6, 0.7, 0.8, 0.9, 1, 1.1, 1.25, 1.5, 1.75, 2]

    static func clampZoom(_ z: Double) -> Double { min(max(z, minUserZoom), maxUserZoom) }

    /// The next step above (`up`) or below the current zoom; the current zoom itself if there is none.
    static func step(_ current: Double, up: Bool) -> Double {
        let c = clampZoom(current)
        if up { return zoomSteps.first { $0 > c + 0.001 } ?? c }
        return zoomSteps.last { $0 < c - 0.001 } ?? c
    }

    /// "38%".
    static func percent(_ z: Double) -> String { "\(Int((z * 100).rounded()))%" }

    /// Where the person's zoom is remembered: one per service (WhatsApp, every whatsapp.com host), else per host
    /// without "www.". nil: no host.
    static func zoomKey(_ url: URL?) -> String? {
        guard let h = url?.host?.lowercased(), !h.isEmpty else { return nil }
        if let s = profile(host: h).service { return s.lowercased() }
        return h.hasPrefix("www.") ? String(h.dropFirst(4)) : h
    }
}
