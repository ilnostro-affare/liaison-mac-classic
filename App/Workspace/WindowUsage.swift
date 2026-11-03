import SwiftUI

// (docs/UX-BACKLOG.md): the AI usage of the current period in the account popover. The same single GET
// Settings' Usage tab makes (/intelligence/usage), kept for 10 minutes so opening the popover costs nothing.

@MainActor
enum WSUsageCache {
    private static var value: UsageInfo?
    private static var at: Date?
    /// The signed-in account the figures belong to (another account never sees them).
    private static var owner: String?
    static let ttl: TimeInterval = 600

    static func cached(_ auth: AuthStore) -> UsageInfo? { owner == auth.activeId ? value : nil }

    /// The cached figures while fresh, else one read; a failed read keeps the old figures.
    static func load(_ auth: AuthStore) async -> UsageInfo? {
        let who = auth.activeId
        if owner != who { value = nil; at = nil; owner = who }
        if let v = value, let t = at, Date().timeIntervalSince(t) < ttl { return v }
        if let u = await LiaAPI(auth: auth).usage(), owner == who { value = u; at = Date() }
        return value
    }
}

/// One compact bar: this week's share used (the plan's period), the session under it; a click opens Settings' Usage.
struct AccountUsageBar: View {
    let app: AppModel
    let close: () -> Void
    @State private var usage: UsageInfo?
    @State private var loaded = false

    var body: some View {
        Button {
            close()
            app.openSettings("usage")
        } label: { face }
        .buttonStyle(.liaPlain)
        .liaHover(.fill, radius: 8)
        .task {
            if let c = WSUsageCache.cached(app.auth) { usage = c; loaded = true }
            usage = await WSUsageCache.load(app.auth)
            loaded = true
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(a11y))
        .accessibilityAddTraits(.isButton)
        .accessibilityHint(Text("Opens usage in Settings"))
    }

    private var face: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text("AI usage this week").font(LiaFont.ui(12, .medium)).foregroundStyle(WS.ink)
                Spacer()
                Text(usage.map { "\($0.weekly.pct)%" } ?? (loaded ? "Unavailable" : "\u{2026}"))
                    .font(LiaFont.ui(12, .semibold)).foregroundStyle(WS.text2).monospacedDigit()
            }
            track(usage?.weekly.pct ?? 0)
            if let u = usage {
                Text(detail(u)).font(LiaFont.ui(11)).foregroundStyle(WS.text3).lineLimit(1)
            }
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 6)
        .contentShape(Rectangle())
    }

    private func track(_ pct: Int) -> some View {
        GeometryReader { g in
            ZStack(alignment: .leading) {
                Capsule().fill(WS.soft)
                Capsule().fill(color(pct)).frame(width: g.size.width * CGFloat(min(100, max(0, pct))) / 100)
            }
        }
        .frame(height: 5)
        .animation(WSMotion.micro, value: pct)
    }

    private func color(_ pct: Int) -> Color { pct >= 90 ? WS.bad : (pct >= 75 ? WS.amber : WS.blue) }

    private func detail(_ u: UsageInfo) -> String {
        var parts = ["Session \(u.session.pct)%"]
        if u.weekly.active, let r = u.weekly.resetAt {
            let f = DateFormatter()
            f.dateFormat = "EEE h:mm a"
            f.locale = Locale(identifier: "en_US")
            parts.append("resets " + f.string(from: r))
        }
        return parts.joined(separator: " \u{00B7} ")
    }

    private var a11y: String {
        guard let u = usage else { return loaded ? "AI usage unavailable" : "AI usage loading" }
        return "AI usage this week \(u.weekly.pct) percent, session \(u.session.pct) percent"
    }
}
