import SwiftUI
import os
import TipKit
import AppKit

/// The agents at the bottom of the window. Lia on the left opens the team chat (every agent, under her
/// lead); then each agent on its own (one endless dialogue each); the journal.
/// Drag an agent onto the page or drop text/links/files on one; right-click menu
/// ; the hand-off spark; what it is doing in the caption; eyes follow the pointer
/// ; the inbox.
struct AgentDock: View {
    @ObservedObject var ws: WorkspaceModel
    @EnvironmentObject private var app: AppModel
    /// The agent under the pointer (it and its neighbours grow, its caption shows).
    @State private var hovered: String?
    /// The pointer over the dock (its space), nil when it is elsewhere.
    @State private var pointer: CGPoint?
    @State private var frames: [String: CGRect] = [:]
    /// The agent something is being dragged over.
    @State private var dropTarget: String?
    /// The spark running now; with Reduce Motion the agent that lights up instead.
    @State private var spark: DockSpark?
    @State private var flash: String?
    /// "Drag an agent onto the page", until the first drag, a click on an agent or its \u{00d7}.
    private let dragTip = DockDragTip()
    /// 0.2.11: TipKit's popover over the dock ate the first click on an agent (a transient popover
    /// takes the click that closes it). The tip is now our own bubble above the dock, shown while TipKit says so.
    @State private var dragTipShown = false
    /// Small avatars without captions.
    @AppStorage("lia_dock_compact") private var compact = false
    /// Bumped after a reorder (the order itself lives in UserDefaults).
    @State private var orderTick = 0
    /// Agents hidden in this workspace (Settings > Team) leave the dock; redraws on a change.
    @ObservedObject private var shown = AgentShownStore.shared
    /// Each agent's bounce, bumped by a message of its that needs the person (AgentAttention).
    @State private var hops: [String: Int] = [:]
    /// ("I click again because I think the click did not register"): the agent just clicked, pressed
    /// down in the frame of the click, until its open settles (or 600 ms).
    @State private var pressed: String?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        bar
            .overlay(alignment: .top) {
                if dragTipShown {
                    DockTipBubble(tip: dragTip) { dragTip.invalidate(reason: .tipClosed) }
                        .alignmentGuide(.top) { d in d[.bottom] + 10 }
                        .transition(.opacity)
                }
            }
            .animation(WSMotion.micro, value: dragTipShown)
            .task { for await s in dragTip.shouldDisplayUpdates { dragTipShown = s } }
            .modifier(DockAutoHide())
            .contextMenu { dockMenu }
            // Scheduled messages go out from the window that shows the dock.
            .task { ChatScheduler.shared.start(ws) }
    }

    private var bar: some View {
        HStack(alignment: .bottom, spacing: 6) {
            if let lia = ws.roster.first(where: { $0.lead }) {
                agent(lia, label: "Lia", base: compact ? 22 : 44, open: ws.sheet == "team") {
                    toggle("team", figure: lia.id) { ws.openTeam() }
                }
                divider
            }
            ForEach(agents) { a in
                agent(a, label: a.name, base: compact ? 22 : 40, open: isOpen(a.id)) {
                    // No ad account in this workspace: its Ad accounts open (Settings > Meta without Meta).
                    if ws.isLocked(a.id) { unlock() } else { toggle(DialogueSummary.dlg(forAgent: a.id), figure: a.id) { ws.openAgent(a.id) } }
                }
            }
            divider
            // The Journal opens from the profile menu; the dock keeps only the Inbox.
            DockInbox(ws: ws)
        }
        .padding(.horizontal, 14)
        .padding(.top, 10)
        .padding(.bottom, 8)
        .wsGlass(28)
        .tourAnchor("dock")
        .shadow(color: Color.black.opacity(0.14), radius: 24, y: 12)
        .overlay { DockSparkLayer(spark: spark, from: liaFrame, to: spark.flatMap { frames[$0.agent] }) }
        .coordinateSpace(name: DockSpace.name)
        .onPreferenceChange(DockFrameKey.self) { f in if f != frames { frames = f } }
        .onContinuousHover(coordinateSpace: .named(DockSpace.name)) { phase in
            guard !reduceMotion else { if pointer != nil { pointer = nil }; return }
            switch phase {
            // 0.2.11: only a move of 2 pt or more redraws the dock (each redraw lays out every agent; under a moving
            // hand it kept the main thread busy at the moment of the click).
            case let .active(p): if LiaClicks.pointerMoved(from: pointer, to: p) { pointer = p }
            case .ended: pointer = nil
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .liaHandOff)) { n in handOff(n) }
        .onReceive(NotificationCenter.default.publisher(for: .liaAgentAttention)) { n in hop(n) }
    }

    /// One agent with its caption, menu, drag and drop.
    private func agent(_ a: AgentInfo, label: String, base: CGFloat, open: Bool, action: @escaping () -> Void) -> some View {
        DockAgent(agent: a, status: ws.status(of: a.id), label: label, compact: compact, unread: unreadCount(a), open: open,
                  locked: ws.isLocked(a.id), hop: hops[a.id] ?? 0, calm: reduceMotion, pressed: pressed == a.id,
                  scale: scale(a.id), base: base, gaze: DockGaze.toward(pointer, from: frames[a.id]),
                  highlight: dropTarget == a.id || flash == a.id,
                  caption: captionReader(a),
                  onHover: { hover(a.id, $0) }, action: {
                      // 0.2.11: a click on an agent is the tip's answer too: it goes, and the click still opens.
                      if dragTipShown { dragTip.invalidate(reason: .actionPerformed) }
                      action()
                  })
            .dockFrame(a.id)
            .tourAnchor("dock." + a.id)   // The morning tour's spotlight
            .zIndex(hovered == a.id ? 1 : 0)
            .contextMenu { menu(a) }
            .onDrag {
                dragTip.invalidate(reason: .actionPerformed)
                return DockDrop.provider(agent: a.id)
            }
            .onDrop(of: DockDrop.types, isTargeted: targeted(a.id)) { providers in
                // Another agent dropped here takes this place; anything else goes to the agent.
                DockOrder.drop(providers, on: a.id, ws: ws) { reordered() }
            }
            .accessibilityAction(named: Text(ws.isLocked(a.id) ? lockedLabel : "Open Conversation")) {
                if ws.isLocked(a.id) { unlock() } else { ws.openAgent(a.id) }
            }
            .accessibilityAction(named: Text("Agent Settings")) { app.openSettings("agents") }
            // For VoiceOver: reorder without dragging.
            .accessibilityAction(named: Text("Move Left")) { nudge(a, by: -1) }
            .accessibilityAction(named: Text("Move Right")) { nudge(a, by: 1) }
    }

    private var liaFrame: CGRect? { ws.roster.first(where: { $0.lead }).flatMap { frames[$0.id] } }

    private var divider: some View {
        Rectangle().fill(WS.line2).frame(width: 1, height: compact ? 22 : 38).padding(.horizontal, compact ? 4 : 6).padding(.bottom, compact ? 4 : 16)
    }

    /// The agents after Lia, in the person's order, without the ones hidden in this workspace.
    private var agents: [AgentInfo] {
        _ = orderTick
        _ = shown.rev
        return ws.shownAgents(DockOrder.sorted(ws.roster.filter { !$0.lead }))
    }

    /// Lia first, then the agents, in dock order (neighbours for the magnification).
    private var order: [String] { ws.roster.filter { $0.lead }.map(\.id) + agents.map(\.id) }

    private func nudge(_ a: AgentInfo, by step: Int) {
        let list = agents
        guard !a.lead, let i = list.firstIndex(where: { $0.id == a.id }), list.indices.contains(i + step) else { return }
        // The whole order (hidden agents keep their place), moved past the shown neighbour.
        DockOrder.move(a.id, onto: list[i + step].id, in: ws.roster.filter { !$0.lead })
        reordered()
    }

    private func reordered() {
        if reduceMotion { orderTick += 1 } else { withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) { orderTick += 1 } }
        ChatA11y.announce("Dock order changed")
    }

    /// The dock's own settings (also at the end of every agent's menu).
    @ViewBuilder private var dockMenu: some View {
        Toggle("Compact Dock", isOn: $compact)
        Button("Reset Order") {
            DockOrder.reset()
            reordered()
        }
        .disabled(!DockOrder.isCustom)
    }

    /// 1.25 under the pointer, 1.1 beside it.
    private func scale(_ id: String) -> CGFloat {
        guard let h = hovered, let hi = order.firstIndex(of: h), let i = order.firstIndex(of: id) else { return 1 }
        switch abs(hi - i) {
        case 0: return 1.25
        case 1: return 1.1
        default: return 1
        }
    }

    private func hover(_ id: String, _ on: Bool) {
        if on { prefetch(id) }
        let next: String? = on ? id : (hovered == id ? nil : hovered)
        guard next != hovered else { return }
        if reduceMotion { hovered = next } else { withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) { hovered = next } }
    }

    /// (feedback: "the first frame must show the end"): the pointer on a figure reads its dialogue's
    /// newest page, so the click opens on messages already here (they no longer arrive after the sheet is up and push
    /// the thread). At most once per dialogue per 10 s; a locked agent has no dialogue to read.
    private func prefetch(_ id: String) {
        guard !ws.isLocked(id) else { return }
        let dlg = DialogueSummary.dlg(forAgent: id)
        guard ws.sheet != dlg, let c = ws.chat(for: dlg), DockPrefetch.due(c.key) else { return }
        Task { @MainActor in
            if c.loaded { await c.refreshLatest() } else { await c.load() }
        }
    }

    private func targeted(_ id: String) -> Binding<Bool> {
        Binding(get: { dropTarget == id }, set: { on in
            let next: String? = on ? id : (dropTarget == id ? nil : dropTarget)
            if reduceMotion { dropTarget = next } else { withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) { dropTarget = next } }
        })
    }

    private func captionReader(_ a: AgentInfo) -> (() -> String)? {
        guard hovered == a.id else { return nil }
        return { caption(a) }
    }

    /// A locked agent: Meta connected, the workspace needs an ad account; otherwise Meta itself.
    private var lockedLabel: String { ws.metaConnected ? "Add an ad account" : "Connect Meta" }
    private func unlock() { if !ws.openLockedTarget() { app.openSettings("meta") } }

    /// The role on hover, never "Name \u{00b7} Role" (the name is already written under the
    /// figure): "Marketer", "Marketer \u{00b7} Building the report\u{2026}" while it works; Lia is "Assistant".
    private func caption(_ a: AgentInfo) -> String {
        let doing = activity(a.id)
        if a.lead { return a.shownRole + (doing.map { " \u{00b7} " + $0 } ?? "") }
        var s = a.shownRole
        if a.soon { s += " \u{00b7} coming soon" }
        if ws.isLocked(a.id) { s += " \u{00b7} " + lockedLabel }
        if let doing { s += " \u{00b7} " + doing }
        else if ws.status(of: a.id) == .waiting { s += " \u{00b7} waiting for your Yes" }
        return s
    }

    /// What the agent is doing now in any dialogue of this workspace.
    private func activity(_ id: String) -> String? {
        for d in ws.dialogueIds {
            if let c = ws.chatIfOpen(d), let s = c.activity(of: id) { return s }
        }
        return nil
    }

    /// How many messages of the agent's own dialogue need the person (Lia: Team), AgentAttention's rule.
    private func unreadCount(_ a: AgentInfo) -> Int { ws.attentionCount(agent: a.id) }

    private func isOpen(_ agent: String) -> Bool { ws.sheet == agent }

    /// The open conversation closes on a second click; anything else opens.: a click while it is still
    /// sliding in (a double click) is ignored; it closes only once fully open.
    /// Timed by the clicks themselves (DockOpenClock): a click made while the sheet slid in or before its
    /// thread was first fully drawn does nothing, even when the busy main thread handles it later.
    /// the figure is pressed in the click's own frame (no animation, so it is in the very
    /// next frame drawn) and lets go when the open settles; a second click within that window is ignored.
    private func toggle(_ id: String?, figure: String, open: () -> Void) {
        let click = DockOpenClock.clickTime()
        if let id, ws.sheet == id {
            guard DockOpenClock.shared.closes(id, click: click) else { return }
            DockOpenClock.shared.reset()
            ws.sheet = nil
        } else {
            press(figure)
            open()
            if let id, ws.sheet == id { DockOpenClock.shared.opened(id, at: click) }
        }
    }

    private func press(_ figure: String) {
        var t = Transaction()
        t.disablesAnimations = true
        withTransaction(t) { pressed = figure }
        DockOpenClock.shared.onSettled = { release(figure) }
        DispatchQueue.main.asyncAfter(deadline: .now() + DockOpenClock.window) { release(figure) }
    }

    private func release(_ figure: String) {
        guard pressed == figure else { return }
        if reduceMotion { pressed = nil } else { withAnimation(.spring(response: 0.25, dampingFraction: 0.7)) { pressed = nil } }
    }

    /// A message that needs the person: its agent's figure jumps (each message, every agent); the
    /// Inbox stays still and shows its total. Lia's dialogue ("team") bounces Lia.
    private func hop(_ n: Notification) {
        guard let id = n.userInfo?["agent"] as? String, (n.userInfo?["profile"] as? String) == ws.profile?.id,
              let a = ws.agent(id) else { return }
        hops[a.id, default: 0] += 1
    }

    // MARK:

    @ViewBuilder private func menu(_ a: AgentInfo) -> some View {
        if a.lead {
            Button("Open Lia Chat") { ws.openTeam() }
        } else if ws.isLocked(a.id) {
            Button(lockedLabel + "\u{2026}") { unlock() }
        } else {
            Button("Open Conversation") { ws.openAgent(a.id) }
        }
        Button("Pause All Tasks") { pauseAll(a) }
            .disabled(ws.status(of: a.id) != .working)
        Divider()
        Button("Agent Settings\u{2026}") { app.openSettings("agents") }
        Divider()
        dockMenu
    }

    /// Stops the agent's running answers and browser work in this workspace's open conversations (Lia: the team chat).
    private func pauseAll(_ a: AgentInfo) {
        for d in ws.dialogueIds where a.lead ? d == "team" : (d == "team" || d == a.id) {
            ws.chatIfOpen(d)?.stop(agent: a.id)
        }
        ws.show("\(a.name) paused", symbol: "pause.circle")
    }

    // MARK:

    private func handOff(_ n: Notification) {
        guard let id = n.userInfo?["agent"] as? String, let a = ws.agent(id), !a.lead,
              (n.userInfo?["profile"] as? String) == ws.profile?.id else { return }
        if reduceMotion {
            flash = id
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { if flash == id { flash = nil } }
        } else {
            let s = DockSpark(agent: id, colorHex: a.colorHex)
            spark = s
            DispatchQueue.main.asyncAfter(deadline: .now() + DockSpark.duration + 0.05) {
                if spark?.id == s.id { spark = nil }
                // the agent lights up as the spark lands
                flash = id
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { if flash == id { flash = nil } }
            }
        }
    }
}

/// One agent in the dock: its figure (the eyes show working / waiting), a red capsule with the number of unread
/// conversations, an amber "!" while it waits for an approval (a glyph and a shape, not colour only: A11Y-05).
private struct DockAgent: View {
    let agent: AgentInfo
    let status: AgentStatus
    let label: String
    /// No caption under the figure.
    var compact = false
    var unread = 0
    let open: Bool
    /// Needs Meta and the workspace has no ad account: greyed (no badge), a click opens Settings > Meta.
    var locked = false
    /// Bumped for each message that needs the person: the figure jumps once (Reduce Motion: none).
    var hop = 0
    var calm = false
    /// clicked and opening (DockOpenClock's window): pressed down and marked as open at once.
    var pressed = false
    var scale: CGFloat = 1
    var base: CGFloat = 40
    /// Where the eyes look.
    var gaze: CGSize = .zero
    /// Something dragged over it; the spark landed on it.
    var highlight = false
    /// Read every second while shown (the activity changes as the agent works).
    var caption: (() -> String)? = nil
    let onHover: (Bool) -> Void
    let action: () -> Void
    // In steps (figure, cell, caption): one expression for all of it was too much for the type checker.
    var body: some View {
        // A tap, not a Button: on macOS a Button with .onDrag (the dock's reorder) sometimes eats the first click
        // ("agents don't open"). The caption bubble never takes the click.
        // 0.2.11 (the marketer: "agents are hard to press"): the cell takes the click over its whole frame, and the
        // figure grown under the pointer takes it over its grown size too (its own hit shape scales with it, see
        // `figure`); before, the cell's resting rectangle was the only hit shape, so a click on the head of the grown
        // figure - the part that sticks out above the cell - went nowhere.
        cell
            .background(Color.clear.contentShape(Rectangle()))
            .onTapGesture(perform: action)
            .overlay(alignment: .top) { captionBubble.allowsHitTesting(false) }
            .onHover(perform: onHover)
            .liaPointer()
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(open ? [.isButton, .isSelected] : .isButton)
            .accessibilityAction { action() }
            .accessibilityLabel(Text(a11y))
            .accessibilityHint(Text(hint))
    }

    private var hint: String {
        if locked { return "Opens Settings to connect Meta" }
        return (open ? "Closes the conversation" : "Opens the conversation")
            + ". Drop text, a link or a file to send it. More actions in the context menu."
    }

    private var cellWidth: CGFloat { compact ? 32 : 58 }
    /// Marked as open: the open conversation's agent, or the one just clicked (before the sheet's frame is drawn).
    private var lit: Bool { open || pressed }

    private var cell: some View {
        VStack(spacing: 4) {
            figure
            if !compact {
                // One line in the cell's width whatever the weight: a semibold name never wraps or widens the cell.
                Text(label).font(LiaFont.ui(11, open ? .semibold : .regular))
                    .foregroundStyle(open ? WS.ink : WS.text2)
                    .lineLimit(1)
                    .frame(width: cellWidth)
            }
            // The open conversation's agent: a dot under it, like a running app in the macOS Dock (the place is kept
            // when closed so nothing shifts).
            Circle().fill(Color(hex: agent.colorHex)).frame(width: 4, height: 4)
                .opacity(open ? 1 : 0)
                .padding(.top, -2)
                .accessibilityHidden(true)
        }
        // (feedback: "the names jitter left and right"): the cell's size never changes on hover. The
        // magnification used to be side padding (layout): the hovered cell and its neighbours widened, the centred dock
        // re-laid every agent out, every name slid sideways, and a pointer at a cell's edge fell out of the moved cell,
        // ended the hover, the cell shrank back under it, hovered again - the jitter (the Inbox, scaled only, never
        // did it). Now only the figure scales (a render effect); the slot (58 + 6) holds the grown figure and its
        // grown neighbours without touching (57.5 / 2 + 50.6 / 2 < 64).
        .frame(width: cellWidth)
        .opacity(agent.soon && !locked ? 0.6 : 1)
    }

    private var figure: some View {
        DockGazeAvatar(agent: agent, size: base, status: status, gaze: gaze)
            .animation(.easeOut(duration: 0.25), value: gaze)
            .saturation(locked ? 0 : 1)
            .opacity(locked ? 0.45 : 1)
            // The figure stays in the dock while its conversation is open (it used to fly into the
            // header via matchedGeometryEffect and leave an empty place); the open one is marked instead.
            .frame(width: base, height: base)
            .overlay {
                if highlight {
                    Circle().stroke(Color(hex: agent.colorHex), lineWidth: 2.5)
                        .frame(width: base + 8, height: base + 8)
                        .transition(.opacity)
                }
            }
            .overlay(alignment: .topTrailing) {
                if unread > 0 {
                    Text(unread > 9 ? "9+" : "\(unread)")
                        .font(.system(size: 10, weight: .bold)).foregroundStyle(.white)
                        .padding(.horizontal, 4)
                        .frame(minWidth: 17, minHeight: 17)
                        .background(Capsule().fill(WS.red))
                        .overlay(Capsule().stroke(WS.surface, lineWidth: 1.5))
                        .fixedSize()
                        .offset(x: 6, y: -5)
                        .transition(.scale.combined(with: .opacity))
                }
            }
            .overlay(alignment: .bottomTrailing) {
                // A locked agent has no lock badge any more, only the grey figure (above).
                // Sits over the figure's own small amber dot: one waiting mark, with a glyph.
                if !locked && status == .waiting {
                    Image(systemName: "exclamationmark")
                        .font(.system(size: 9.5, weight: .heavy)).foregroundStyle(.white)
                        .frame(width: 17, height: 17)
                        .background(Circle().fill(WS.amber))
                        .overlay(Circle().stroke(WS.surface, lineWidth: 1.5))
                        .offset(x: 4, y: 4)
                        .transition(.scale.combined(with: .opacity))
                }
            }
            .padding(3)
            .background(lit ? Color(hex: agent.colorHex).opacity(0.16) : Color.clear, in: RoundedRectangle(cornerRadius: 15, style: .continuous))
            .overlay {
                if lit {
                    RoundedRectangle(cornerRadius: 15, style: .continuous)
                        .stroke(Color(hex: agent.colorHex).opacity(0.55), lineWidth: 1.5)
                }
            }
            .contentShape(Rectangle())   // scaled and offset with the figure below: the grown figure is clickable all over
            .scaleEffect(highlight && scale == 1 ? 1.12 : scale, anchor: .bottom)
            .scaleEffect(pressed ? 0.92 : 1, anchor: .bottom)
            .offset(y: open && scale == 1 ? -3 : 0)
            // the jump: up, a small squash on landing, still (an offset and a scale only: no layout per frame)
            .keyframeAnimator(initialValue: DockHop(), trigger: hop) { v, h in
                v.scaleEffect(x: calm ? 1 : h.squash, y: calm ? 1 : 2 - h.squash, anchor: .bottom).offset(y: calm ? 0 : h.y)
            } keyframes: { _ in
                KeyframeTrack(\.y) {
                    CubicKeyframe(-16, duration: 0.2)
                    CubicKeyframe(0, duration: 0.18)
                    CubicKeyframe(-5, duration: 0.12)
                    CubicKeyframe(0, duration: 0.12)
                }
                KeyframeTrack(\.squash) {
                    LinearKeyframe(1, duration: 0.38)
                    CubicKeyframe(1.08, duration: 0.07)
                    CubicKeyframe(1, duration: 0.17)
                }
            }
    }

    @ViewBuilder private var captionBubble: some View {
        if let caption {
            TimelineView(.periodic(from: .now, by: 1)) { _ in Text(caption()) }
                .font(LiaFont.ui(12, .medium)).foregroundStyle(WS.ink)
                .padding(.horizontal, 10).frame(height: 26)
                .background(WS.surface, in: Capsule())
                .overlay(Capsule().stroke(WS.line2, lineWidth: 1))
                .shadow(color: .black.opacity(0.12), radius: 8, y: 3)
                .fixedSize()
                .offset(y: -(base * (scale - 1)) - 36)
                .allowsHitTesting(false)
                .transition(.opacity)
        }
    }

    /// A11Y-01: "Met, Meta Ads, working, 2 unread".
    private var a11y: String {
        var parts = [agent.name, agent.shownRole]
        if agent.soon { parts.append("not connected yet") }
        if locked { parts.append("locked, connect Meta") }
        switch status {
        case .working: parts.append("working")
        case .waiting: parts.append("waiting for your approval")
        case .idle: break
        }
        if unread > 0 { parts.append("\(unread) unread") }
        if open { parts.append("open") }
        return parts.joined(separator: ", ")
    }
}

private struct DockButton: View {
    let symbol: String
    let label: String
    var compact = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 4) {
                Image(systemName: symbol).font(.system(size: compact ? 12 : 16, weight: .medium)).foregroundStyle(WS.text2)
                    .frame(width: compact ? 28 : 46, height: compact ? 28 : 46)
                    .background(WS.soft, in: RoundedRectangle(cornerRadius: compact ? 9 : 15, style: .continuous))
                if !compact { Text(label).font(LiaFont.ui(11)).foregroundStyle(WS.text2) }
            }
            .frame(width: compact ? 32 : 56)
        }
        .buttonStyle(.liaPlain)
        .liaPointer()
        .accessibilityLabel(Text(label))
    }
}

/// 0.2.11: the dock's one-time tip ("Drag an agent onto the page") as a small bubble above the dock. Not a popover:
/// nothing is modal, the agents under it take the first click; only the bubble itself takes the pointer (\u{00d7}).
private struct DockTipBubble: View {
    let tip: DockDragTip
    let close: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "hand.draw").font(.system(size: 13, weight: .semibold)).foregroundStyle(WS.text2)
                .padding(.top, 1)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                tip.title.font(.system(size: 12.5, weight: .semibold)).foregroundStyle(WS.ink)
                if let m = tip.message { m.font(.system(size: 12)).foregroundStyle(WS.text2) }
            }
            .fixedSize(horizontal: true, vertical: false)
            Button(action: close) {
                Image(systemName: "xmark").font(.system(size: 9, weight: .bold)).foregroundStyle(WS.text3)
                    .frame(width: 18, height: 18).contentShape(Rectangle())
            }
            .buttonStyle(.liaPlain)
            .accessibilityLabel(Text("Dismiss tip"))
        }
        .padding(.horizontal, 12).padding(.vertical, 9)
        .background(TourLook.cardGround, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(WS.line2, lineWidth: 1).allowsHitTesting(false))
        .shadow(color: Color.black.opacity(0.16), radius: 14, y: 6)
        .accessibilityElement(children: .contain)
    }
}

/// The dock figure's jump (DockAgent's keyframes): its height and the landing's squash (1: none).
struct DockHop {
    var y: CGFloat = 0
    var squash: CGFloat = 1
}

/// ("I think the click failed, click again, and the second click closes it"): when the dock opened which
/// conversation and when its thread was first fully drawn (ThreadColumn reports it), in NSEvent time (system uptime).
@MainActor
final class DockOpenClock {
    static let shared = DockOpenClock()
    private var id: String?
    private var openedAt: TimeInterval?
    private var settledAt: TimeInterval?
    /// a second click within this of the opening click never closes (a click the person made
    /// because the first seemed lost), even when the thread settled sooner.
    static let window: TimeInterval = 0.6
    /// The dock's pressed figure lets go when the open settles (one shot).
    var onSettled: (() -> Void)?

    /// The time of the click being handled (when it was made, not when the main thread got to it).
    static func clickTime() -> TimeInterval {
        if let e = NSApp.currentEvent, e.type == .leftMouseUp || e.type == .leftMouseDown || e.type == .keyDown { return e.timestamp }
        return ProcessInfo.processInfo.systemUptime
    }

    func opened(_ id: String, at t: TimeInterval) {
        self.id = id
        openedAt = t
        settledAt = nil
        AgentOpenTrace.shared.click(id, at: t)
    }

    /// The thread of `dlg` has its first full frame on screen.
    func settled(_ dlg: String) {
        AgentOpenTrace.shared.settled(dlg)
        guard dlg == id, settledAt == nil else { return }
        settledAt = ProcessInfo.processInfo.systemUptime
        let f = onSettled
        onSettled = nil
        f?()
    }

    func reset() { id = nil; openedAt = nil; settledAt = nil; onSettled = nil }

    func closes(_ id: String, click: TimeInterval) -> Bool {
        guard id == self.id else { return true }
        return DockToggle.closes(click: click, openedAt: openedAt, settledAt: settledAt, now: ProcessInfo.processInfo.systemUptime,
                                 settle: Self.window)
    }
}

/// The dock's hover prefetch, throttled per dialogue.
@MainActor
enum DockPrefetch {
    private static var last: [String: TimeInterval] = [:]
    static func due(_ key: String, every: TimeInterval = 10) -> Bool {
        let now = ProcessInfo.processInfo.systemUptime
        if let t = last[key], now - t < every { return false }
        last[key] = now
        return true
    }
}

/// how long opening an agent really takes, per dialogue. os_log subsystem
/// com.liaisone.mac, category "open" (Console: `subsystem:com.liaisone.mac category:open`), one signpost interval
/// "agent_open" per open with events "sheet_visible" and "first_frame" (Instruments: os_signpost). Lines:
/// agent_open.click dlg=<d>
/// agent_open.sheet dlg=<d> ms=<click to the sheet's first appearance>
/// agent_open.first_frame dlg=<d> kept=<0|1> rows=<n> ms=<click to the first frame with the thread's rows>
/// agent_open.settled dlg=<d> kept=<0|1> rows=<n> sheet_ms= first_ms= ms=<click to settled>
/// "kept": the thread's view was kept from an earlier open (ThreadHostCache), else built now ("cold"). The canary's
/// latency telemetry (LatencyProbe) gets the same phases as actions agent_open:sheet, agent_open:<kept|cold>:first and
/// agent_open:<kept|cold>:settled (its p50/p95/max and the counts over 100 / 400 ms per day), and an open slower than
/// 250 ms as one slow event with the sheet / first_frame / settled segments (LatencyProbe.agentOpen, LatencyEvent).
@MainActor
final class AgentOpenTrace {
    static let shared = AgentOpenTrace()
    static let log = Logger(subsystem: "com.liaisone.mac", category: "open")
    static let signposter = OSSignposter(subsystem: "com.liaisone.mac", category: "open")

    private struct Run {
        let dlg: String
        let click: TimeInterval
        let state: OSSignpostIntervalState
        var sheet: TimeInterval?
        var first: TimeInterval?
        var kept: Bool?
        var rows = 0
    }
    private var run: Run?

    private static var now: TimeInterval { ProcessInfo.processInfo.systemUptime }
    private static func ms(_ a: TimeInterval, _ b: TimeInterval?) -> Int { b.map { Int((($0 - a) * 1000).rounded()) } ?? -1 }

    /// The click that opens `dlg` (its event's own time). A run still open for another dialogue is dropped.
    func click(_ dlg: String, at t: TimeInterval) {
        if let r = run { Self.signposter.endInterval("agent_open", r.state, "abandoned") }
        let state = Self.signposter.beginInterval("agent_open", id: Self.signposter.makeSignpostID(), "\(dlg, privacy: .public)")
        run = Run(dlg: dlg, click: t, state: state)
        Self.log.notice("agent_open.click dlg=\(dlg, privacy: .public)")
    }

    /// The canary's latency (LatencyProbe), timed from the click event itself (its wait in the queue counts), the same
    /// number as the os_log line.
    private static func probe(_ id: String, _ ms: Int) {
        if ms >= 0 { LatencyProbe.record(id, ms: Double(ms)) }
    }

    /// The sheet is on screen with `dlg` (its first appearance, or a switch to it in the open sheet). An open the dock
    /// did not start (a notification, the menu, the keyboard) starts here, from the event being handled.
    func sheetVisible(_ dlg: String) {
        if run?.dlg != dlg || run?.sheet != nil { click(dlg, at: DockOpenClock.clickTime()) }
        guard var r = run, r.sheet == nil else { return }
        let t = Self.now
        r.sheet = t
        run = r
        Self.signposter.emitEvent("sheet_visible", id: Self.signposter.makeSignpostID(), "\(dlg, privacy: .public)")
        let ms = Self.ms(r.click, t)
        Self.log.notice("agent_open.sheet dlg=\(dlg, privacy: .public) ms=\(ms)")
        Self.probe("agent_open:sheet", ms)
    }

    /// The first frame with the thread's rows; `kept`: the thread's view was kept from an earlier open.
    func firstFrame(_ dlg: String, kept: Bool, rows: Int) {
        guard var r = run, r.dlg == dlg, r.first == nil else { return }
        let t = Self.now
        r.first = t
        r.kept = kept
        r.rows = rows
        run = r
        let k = kept ? 1 : 0
        let ms = Self.ms(r.click, t)
        Self.signposter.emitEvent("first_frame", id: Self.signposter.makeSignpostID(), "\(dlg, privacy: .public) kept=\(k) rows=\(rows)")
        Self.log.notice("agent_open.first_frame dlg=\(dlg, privacy: .public) kept=\(k) rows=\(rows) ms=\(ms)")
        Self.probe(kept ? "agent_open:kept:first" : "agent_open:cold:first", ms)
    }

    /// The open is over: the end checked once more after the rows measured themselves (the run closes).
    func settled(_ dlg: String) {
        guard let r = run, r.dlg == dlg, r.first != nil else { return }
        run = nil
        let t = Self.now
        let kept = r.kept == true
        let k = kept ? 1 : 0, rows = r.rows
        let sheetMs = Self.ms(r.click, r.sheet), firstMs = Self.ms(r.click, r.first), ms = Self.ms(r.click, t)
        Self.signposter.endInterval("agent_open", r.state, "kept=\(k) rows=\(rows)")
        Self.log.notice("agent_open.settled dlg=\(dlg, privacy: .public) kept=\(k) rows=\(rows) sheet_ms=\(sheetMs) first_ms=\(firstMs) ms=\(ms)")
        Self.probe(kept ? "agent_open:kept:settled" : "agent_open:cold:settled", ms)
        // the slow event (over 250 ms): the same open with its phases and conditions (no dialogue id leaves the Mac,
        // only its agent: lia / dev / crea / met / other)
        LatencyProbe.agentOpen(dlg: dlg, kept: kept, rows: rows, click: r.click, sheet: r.sheet, first: r.first, settled: t)
    }
}
