import SwiftUI

// Pieces of the agent dock: where each agent sits (for the spark and the gaze), the hand-off spark,
// Eyes that follow the pointer, the inbox.

/// The dock's coordinate space: agents report their frames in it; the pointer is read in it.
enum DockSpace { static let name = "agentDock" }

struct DockFrameKey: PreferenceKey {
    static var defaultValue: [String: CGRect] = [:]
    static func reduce(value: inout [String: CGRect], nextValue: () -> [String: CGRect]) {
        value.merge(nextValue(), uniquingKeysWith: { $1 })
    }
}

extension View {
    /// Reports this view's frame in the dock under `id`.
    func dockFrame(_ id: String) -> some View {
        background(GeometryReader { g in
            Color.clear.preference(key: DockFrameKey.self, value: [id: g.frame(in: .named(DockSpace.name))])
        })
    }
}

// MARK: - gaze

enum DockGaze {
    /// Where an avatar at `frame` looks for a pointer at `p` (both in the dock's space): -1...1, zero without a pointer.
    static func toward(_ p: CGPoint?, from frame: CGRect?) -> CGSize {
        guard let p, let r = frame else { return .zero }
        let dx = (p.x - r.midX) / 140, dy = (p.y - r.midY) / 60
        return CGSize(width: max(-1, min(1, dx)), height: max(-1, min(1, dy)))
    }
}

/// The agent's figure whose gaze animates (the figure itself draws one frame per value; this interpolates it).
struct DockGazeAvatar: View, Animatable {
    let agent: AgentInfo
    let size: CGFloat
    let status: AgentStatus
    var gaze: CGSize

    var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get { AnimatablePair(gaze.width, gaze.height) }
        set { gaze = CGSize(width: newValue.first, height: newValue.second) }
    }

    var body: some View {
        AgentAvatar(agent: agent, size: size, status: status, gaze: gaze)
    }
}

// MARK: - the hand-off spark

struct DockSpark: Equatable {
    let id = UUID()
    let agent: String
    let colorHex: UInt32
    let start = Date()
    static let duration: TimeInterval = 0.6
}

/// A dot in the agent's colour that runs from Lia to the agent along a short arc over the dock.
struct DockSparkLayer: View {
    let spark: DockSpark?
    let from: CGRect?
    let to: CGRect?

    var body: some View {
        if let s = spark, let a = from, let b = to {
            TimelineView(.animation) { tl in
                let raw = min(1, max(0, tl.date.timeIntervalSince(s.start) / DockSpark.duration))
                let t = raw < 0.5 ? 2 * raw * raw : 1 - pow(-2 * raw + 2, 2) / 2   // ease in-out
                let color = Color(hex: s.colorHex)
                Circle().fill(color)
                    .frame(width: 9, height: 9)
                    .overlay(Circle().stroke(Color.white, lineWidth: 1.5))
                    .shadow(color: color.opacity(0.8), radius: 6)
                    .scaleEffect(1 + 0.4 * sin(.pi * t))
                    .position(Self.point(t, a, b))
                    .opacity(raw >= 1 ? 0 : 1)
            }
            .allowsHitTesting(false)
            .accessibilityHidden(true)
        }
    }

    /// A quadratic arc from the top of one figure to the top of the other, rising over the dock.
    static func point(_ t: Double, _ a: CGRect, _ b: CGRect) -> CGPoint {
        let p0 = CGPoint(x: a.midX, y: a.minY + a.height * 0.3)
        let p2 = CGPoint(x: b.midX, y: b.minY + b.height * 0.3)
        let lift = min(70, 24 + abs(p2.x - p0.x) * 0.18)
        let c = CGPoint(x: (p0.x + p2.x) / 2, y: min(p0.y, p2.y) - lift)
        let u = 1 - t
        return CGPoint(x: u * u * p0.x + 2 * u * t * c.x + t * t * p2.x,
                       y: u * u * p0.y + 2 * u * t * c.y + t * t * p2.y)
    }
}

// MARK: - the inbox

/// A bell after Journal: the agents' latest messages in this workspace's conversations, newest first; a click opens one.
struct DockInbox: View {
    @ObservedObject var ws: WorkspaceModel
    @State private var open = false
    @State private var hover = false
    @ObservedObject private var updates = Updates.shared
    @Environment(\.accessibilityReduceMotion) private var reduce
    /// The dock sits on the theme's glass, not over the bar's tint: the bell's well follows the theme.
    @Environment(\.colorScheme) private var scheme

    private var unread: Int { ws.unreadCount + (updates.inboxUnseen ? 1 : 0) }

    var body: some View {
        Button { open.toggle() } label: {
            VStack(spacing: 4) {
                Image(systemName: unread > 0 ? "bell.badge" : "bell").font(.system(size: 16, weight: .medium)).foregroundStyle(WS.text2)
                    .frame(width: 46, height: 46)
                    // ("the backing under the bell is white and stands out"): the bell sits in the dock's
                    // own glass, a faint well of it with the shared rim, no material and no white of its own. It was the
                    // opaque WS.soft, then (110431f) the chrome's glass, whose ultra-thin material plus a white tint still
                    // read as a lighter tile on the dock's glass. Open: the well a step deeper and the rim firmer.
                    .background { DockWell(shape: RoundedRectangle(cornerRadius: 15, style: .continuous), dark: scheme == .dark, open: open) }
                    .overlay(alignment: .topTrailing) {
                        if unread > 0 {
                            Text(unread > 9 ? "9+" : "\(unread)")
                                .font(.system(size: 10, weight: .bold)).foregroundStyle(.white)
                                .padding(.horizontal, 4)
                                .frame(minWidth: 17, minHeight: 17)
                                .background(Capsule().fill(WS.red))
                                .overlay(Capsule().stroke(WS.surface, lineWidth: 1.5))
                                .fixedSize()
                                .offset(x: 5, y: -5)
                        }
                    }
                Text("Inbox").font(LiaFont.ui(11)).foregroundStyle(WS.text2)
            }
            .frame(width: 56)
            .scaleEffect(hover && !reduce ? 1.12 : 1, anchor: .bottom)   // grows on hover like the agents
            .animation(.spring(response: 0.28, dampingFraction: 0.7), value: hover)
        }
        .buttonStyle(.liaPlain)
        .onHover { hover = $0 }
        .liaPointer()
        .accessibilityLabel(Text(unread > 0 ? "Inbox, \(unread) new" : "Inbox"))
        .popover(isPresented: $open, arrowEdge: .top) {
            DockInboxFeed(ws: ws) { id in open = false; ws.openDialogue(id) }
        }
        .onChange(of: open) { _, o in if o { Task { await ws.warmFeed() } } }
    }
}

/// A control's backing inside the dock: the dock's glass itself, deepened a touch (ink in light, white in dark),
/// with the natural rim (WSGlassRim). The same on every macOS (the dock is our material there too).
private struct DockWell<S: InsettableShape>: View {
    let shape: S
    let dark: Bool
    let open: Bool

    var body: some View {
        let ink = dark ? Color.white : Color(hex: 0x11141A)
        ZStack {
            shape.fill(ink.opacity(dark ? (open ? 0.12 : 0.07) : (open ? 0.08 : 0.04)))
            WSGlassRim(shape: shape, dark: dark, strong: open)
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

private struct DockInboxFeed: View {
    @ObservedObject var ws: WorkspaceModel
    let onOpen: (String) -> Void

    private var items: [WorkspaceModel.FeedItem] {
        Array(ws.feed.sorted { ($0.ts ?? 0) > ($1.ts ?? 0) }.prefix(20))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Inbox").font(LiaFont.ui(14, .semibold)).foregroundStyle(WS.ink)
                .padding(.horizontal, 8).padding(.bottom, 4)
                .accessibilityAddTraits(.isHeader)
            UpdateInboxRow()
            if items.isEmpty && Updates.shared.readyVersion == nil {
                VStack(spacing: 6) {
                    Image(systemName: "tray").font(.system(size: 20)).foregroundStyle(WS.text3)
                    Text("Nothing from your agents yet").font(LiaFont.ui(13)).foregroundStyle(WS.text2)
                }
                .frame(maxWidth: .infinity).padding(.vertical, 18)
            } else {
                ScrollView {
                    VStack(spacing: 2) {
                        ForEach(items) { item in row(item) }
                    }
                }
                .frame(maxHeight: 420)
            }
        }
        .padding(10)
        .frame(width: 360)
    }

    private func row(_ item: WorkspaceModel.FeedItem) -> some View {
        let a = ws.agent(item.agent)
        let unread = ws.unread(dlg: item.id)
        return Button { onOpen(item.id) } label: {
            HStack(alignment: .top, spacing: 10) {
                if let a { AgentAvatar(agent: a, size: 28, status: item.gate ? .waiting : .idle) }
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(a?.name ?? item.agent.capitalized).font(LiaFont.ui(12, .semibold)).foregroundStyle(a.map { Color(hex: $0.colorHex) } ?? WS.ink)
                        if item.gate { Text("needs your Yes").font(LiaFont.ui(11.5, .semibold)).foregroundStyle(WS.amberInk) }
                        Spacer(minLength: 0)
                        if let ts = item.ts {
                            Text(MessageTime.label(Date(timeIntervalSince1970: ts / 1000), now: Date()))
                                .font(LiaFont.ui(11)).foregroundStyle(WS.text3)
                        }
                    }
                    Text(item.title).font(LiaFont.ui(13, unread ? .semibold : .regular)).foregroundStyle(WS.ink).lineLimit(2)
                        .multilineTextAlignment(.leading)
                    if !item.body.isEmpty {
                        Text(item.body).font(LiaFont.ui(12)).foregroundStyle(WS.text2).lineLimit(2).multilineTextAlignment(.leading)
                    }
                }
                if unread { Circle().fill(WS.red).frame(width: 7, height: 7).padding(.top, 5) }
            }
            .padding(8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.liaPlain)
        .liaHover(.fill, radius: 10)
        .accessibilityLabel(Text([a?.name ?? item.agent, item.gate ? "needs your approval" : nil, item.title, unread ? "unread" : nil]
            .compactMap { $0 }.joined(separator: ", ")))
    }
}
