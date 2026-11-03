import SwiftUI
#if canImport(AppKit)
import AppKit
#endif

/// Hosts and design tokens. Tokens are the site's own (`shell.build2.css` :root and
/// Root[data-theme="light"], master e708917d), not DESIGN_TOKENS.md, which is stale
/// (Inter → Nunito, sidebar 272 → 292).
enum AppConfig {
    // .io is deleted. Only .com.
    static let memberstackClient = "https://client.memberstack.com"
    static let memberstackPublicKey = "pk_REPLACE_WITH_MEMBERSTACK_PUBLIC_KEY"   // public by design, same key the website ships
    static let mcpBase = "https://mcp.liaisone.com"
    static let aiBase = "https://ai.liaisone.com"
    /// The agent team (lia-agents worker): /agents/* and, through it, every Lia 2.0 route.
    static let agentsBase = "https://lia.liaisone.com"
    /// Lia 2.0's own calls (browser steps, locate, the agent log): the agents' host in the New Workspace, so its
    /// OpenAI spend is the lia-agents worker's key, apart from Lia 1.4's; the classic window keeps ai.liaisone.com.
    static var lia20Base: String { agentsBase }
    static let apiBase = "https://api.liaisone.com"
    static let siteBase = "https://liaisone.com"
    static let mcpServerURL = "https://mcp.liaisone.com/mcp"
    static let termsURL = URL(string: "https://liaisone.com/terms")!
    static let privacyURL = URL(string: "https://liaisone.com/privacy")!
    // SiteBillingURL and siteGeneralURL are gone - email change and Google run natively (meta-mcp /auth/email/*,
    // /auth/google/*); billing opens Stripe's own pages. Nothing in the app opens the web app any more.

    // MARK: layout (ai/index.html, shell.build2.css)
    static let sidebarWidth: CGFloat = 292
    /// The window's top row: traffic lights, the sidebar's logo and
    /// controls, the chat title, the account chip, the globe and the browser's tabs all sit centred on one line.
    static let barHeight: CGFloat = 52
    /// Room the traffic lights take at the left of that row (they end at 70; the first control starts after a gap).
    static let lightsInset: CGFloat = 80
    static let threadMaxWidth: CGFloat = 820
    static let composerMaxWidth: CGFloat = 830
    /// The browser panel never closes. It shrinks to this and grows to 80% of the window.
    static let browserMinWidth: CGFloat = 360
    static let browserMaxFraction: CGFloat = 0.8
    /// The browser opens at 75% of the space right of the sidebar.
    static let browserDefaultShare = 0.75
    /// Narrower than this the chat gives way and the browser takes the window.
    static let chatMinWidth: CGFloat = 420
    /// Pulled narrower than this, the chat stops being readable: the browser takes the window at once.
    static let chatSnapWidth: CGFloat = 330
    /// Below this the open sidebar steps aside while the browser's edge is dragged; it returns when there is room.
    static let chatCollapseAt: CGFloat = 560
    /// How far a drag may squeeze the chat before the release decides (full screen or not).
    static let chatSqueezeWidth: CGFloat = 420
    /// The site's default: clamp(520px, 46vw, 1120px).
    static func browserDefaultWidth(window: CGFloat) -> CGFloat { min(max(520, window * 0.46), 1120) }

    // MARK: colours. Dynamic: follow the window's appearance (Dark / Light / Auto).
    static let accent = Color(hex: 0x007EF7)
    static let accentSoft = accent.opacity(0.10)
    static let accentLine = Color.dyn(dark: (0x007EF7, 0.28), light: (0x007EF7, 0.32))
    static let onAccent = Color.white

    static let canvasBg = Color.dyn(0x1a1a19, 0xfcfcfb)
    /// Sidebar and settings rail.
    static let ink0 = Color.dyn(0x181817, 0xfbfbf9)
    /// Modals, panels.
    static let ink2 = Color.dyn(0x181817, 0xffffff)
    static let surface = Color.dyn(dark: (0xffffff, 0.025), light: (0x11141a, 0.03))
    static let surface2 = Color.dyn(dark: (0xffffff, 0.04), light: (0x11141a, 0.05))
    static let surface3 = Color.dyn(0x2c2c2a, 0xefeeeb)
    static let ddBg = Color.dyn(0x383835, 0xffffff)
    static let navSel = Color.dyn(0x30302f, 0xefeeeb)
    static let navSelText = Color.dyn(0xffffff, 0x111111)
    static let ctl = Color.dyn(0x232323, 0xefeeeb)
    static let segOn = Color.dyn(0x515151, 0xffffff)
    static let composeBg = Color.dyn(0x2c2c2a, 0xffffff)
    /// browser.js .br-new__srch: surface-3 in dark, white in light.
    static let startSearch = Color.dyn(0x2c2c2a, 0xffffff)
    /// The input box's edge: none in dark, line-2 in light (measured on production).
    static let composeLine = Color.dyn(dark: (0xffffff, 0), light: (0xdde4ec, 1))
    static let userBubble = Color.dyn(0x262625, 0xefeeeb)
    static let chipBg = Color.dyn(0x232321, 0xefeeeb)
    /// The Relay rail's Search pill (ai.js .jrail__srch: surface-3, #e6e4dd in light).
    static let railSearch = Color.dyn(0x2c2c2a, 0xe6e4dd)
    static let chipLine = Color.dyn(0x343432, 0xdde4ec)
    static let line = Color.dyn(dark: (0xffffff, 0.06), light: (0xe6ebf1, 1))
    static let line2 = Color.dyn(dark: (0xffffff, 0.10), light: (0xdde4ec, 1))
    static let line3 = Color.dyn(dark: (0xffffff, 0.16), light: (0x11141a, 0.20))
    /// Text and its steps.
    static let ink = Color.dyn(0xffffff, 0x11141a)
    static let text2 = Color.dyn(dark: (0xffffff, 0.70), light: (0x11141a, 0.72))
    static let text3 = Color.dyn(dark: (0xffffff, 0.50), light: (0x11141a, 0.55))
    static let text4 = Color.dyn(dark: (0xffffff, 0.35), light: (0x11141a, 0.42))
    static let bad = Color.dyn(0xff6b6b, 0xd83a3a)
    static let warn = Color.dyn(0xd8b54a, 0xa8841f)
    /// Usage bar steps (settings.js).
    static let usageWarm = Color(hex: 0xE0A122)
    static let usageHot = Color(hex: 0xC25454)
    static let destructive = Color(hex: 0xC25454)
    static let catRead = Color.dyn(0x6b8fb5, 0x8fb4dc)
    static let catWrite = accent
    static let catWeb = Color.dyn(0xd8b54a, 0xe8b93c)
    static let tipBg = Color.dyn(0x383835, 0xffffff)
    static let avatarBg = Color.dyn(0x30302f, 0xe2e2e1)
    static let facebookBlue = Color(hex: 0x1877f2)
    static let scrim = Color(red: 8 / 255, green: 10 / 255, blue: 18 / 255).opacity(0.5)

    // iOS names kept so code copied from liappstore compiles unchanged.
    static var canvas: Color { canvasBg }
    static var sidebar: Color { ink0 }
    static var bubble: Color { userBubble }
}

extension Color {
    init(hex: UInt32, alpha: Double = 1) {
        self.init(.sRGB, red: Double((hex >> 16) & 0xff) / 255, green: Double((hex >> 8) & 0xff) / 255,
                  blue: Double(hex & 0xff) / 255, opacity: alpha)
    }

    static func dyn(_ dark: UInt32, _ light: UInt32) -> Color {
        dyn(dark: (dark, 1), light: (light, 1))
    }

    static func dyn(dark: (UInt32, Double), light: (UInt32, Double)) -> Color {
        #if canImport(AppKit)
        return Color(nsColor: NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            let (v, a) = isDark ? dark : light
            return NSColor(srgbRed: CGFloat((v >> 16) & 0xff) / 255, green: CGFloat((v >> 8) & 0xff) / 255,
                           blue: CGFloat(v & 0xff) / 255, alpha: CGFloat(a))
        })
        #else
        return Color(hex: dark.0, alpha: dark.1)
        #endif
    }
}
