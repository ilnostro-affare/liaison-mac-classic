import SwiftUI
import AppKit

/// Lia 2.0 drawn over the real page (AgentDirector): her cursor and its presses, the values she sets drawn over the
/// real controls, a new object's row in the real table, and while she works a shield with the status and Stop.
/// All of it is ours, on top of the web view: the page gets no event.
struct AgentOverlay: View {
    @ObservedObject var agent: AgentDirector
    let tabID: UUID
    /// The colour of the agent at the wheel (the glow, the cursor's tag).
    var tint: Color = AppConfig.accent
    /// Who is at work, for the shield's hint and the pill ("Met is working").
    var name: String = "Lia"
    /// The take-over path of the place hosting the page (the conversation's Stop); the director stops too.
    var onTakeOver: (() -> Void)? = nil
    /// The browser's web agent, for "Step N of 30" and Pause (nil: the plate shows status and Stop only).
    var web: WebAgent? = nil
    @State private var shieldHover = false
    /// ("almost unnoticeable"): a bigger cursor with the hero on it, travel that overshoots a little, a
    /// ripple on a press, a short trail, a pulsing frame. Reduce Motion: the earlier quiet cursor and press ring.
    @Environment(\.accessibilityReduceMotion) private var reduceMotionEnv
    private var calm: Bool { reduceMotionEnv || NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }
    @State private var ripples: [AgentRipple.Item] = []
    private var hero: AgentInfo? { AgentInfo.lookup(name.lowercased(), in: WorkspaceModel.current?.roster ?? []) }

    /// /04: the person takes the wheel: the run stops and the overlay clears.
    private func takeOver() {
        onTakeOver?()
        if agent.active { agent.stop() }
    }

    var body: some View {
        if agent.visible && agent.tabID == tabID {
            GeometryReader { g in
                ZStack(alignment: .topLeading) {
                    if let shot = agent.curtain {
                        Image(nsImage: shot).resizable().frame(width: g.size.width, height: g.size.height).transition(.opacity)
                    }
                    if agent.active {
                        // The shield: the page is the agent's while it works (browser.js agentGlow). a click
                        // here never reaches the page; it takes over.
                        Rectangle().fill(Color.black.opacity(0.001)).contentShape(Rectangle())
                            .onHover { h in withAnimation(.easeOut(duration: 0.2)) { shieldHover = h } }
                            .onTapGesture { takeOver() }
                            .accessibilityElement()
                            .accessibilityLabel(Text("\(name) is working"))
                            .accessibilityHint(Text("Click to take over"))
                            .accessibilityAddTraits(.isButton)
                            .accessibilityAction { takeOver() }
                        AgentGlow(tint: tint).allowsHitTesting(false)
                    }
                    ForEach(agent.marks) { m in MarkView(mark: m).allowsHitTesting(false) }
                    if agent.active, let f = AgentFocus.current(agent) {
                        // The control being worked on, framed and named ("Filling: Headline").
                        AgentFocusFrame(focus: f, tint: tint).allowsHitTesting(false)
                    }
                    if calm, let p = agent.press {
                        Circle().stroke(tint, lineWidth: 2).frame(width: 26, height: 26)
                            .offset(x: p.x - 13, y: p.y - 13).transition(.scale.combined(with: .opacity)).allowsHitTesting(false)
                    }
                    if !calm {
                        ForEach(ripples) { r in AgentRipple(item: r, tint: tint).allowsHitTesting(false) }
                        if let p = agent.cursor { AgentTrail(point: p, tint: tint).allowsHitTesting(false) }
                    }
                    if let p = agent.cursor {
                        // Near the right edge the tag goes to the left of the arrow, so it never leaves the page.
                        let flip = p.x > g.size.width - 240
                        let tipX: CGFloat = calm ? 4 : 6
                        AgentCursor(caption: agent.caption, flip: flip, tint: tint, hero: calm ? nil : hero, big: !calm,
                                    pressed: !calm && agent.press != nil)
                            .frame(width: 440, alignment: flip ? .topTrailing : .topLeading)
                            .offset(x: flip ? p.x - 440 + (calm ? 19 : 25) : p.x - tipX, y: p.y - (calm ? 2 : 3))   // the arrow's tip at the point (ai.js .br-ag-cur)
                            .modifier(OvershootTravel(on: !calm, value: p))
                            .allowsHitTesting(false)
                    }
                    // No status plate on the page while she works; the pane's Take over (AgentTakeOverButton)
                    // carries the step, the progress and Stop. The pill stays for a question and for the end.
                    if !(agent.active && agent.webAsk == nil) {
                        AgentPill(agent: agent, name: name)
                            .frame(maxWidth: .infinity, alignment: .center)
                            .padding(.top, 10)
                    }
                    if agent.active && shieldHover && agent.webAsk == nil {
                        // What a click on the page does now.
                        HStack(spacing: 6) {
                            Circle().fill(tint).frame(width: 7, height: 7)
                            Text("\(name) is working \u{00b7} Click to take over")
                                .font(LiaFont.ui(12.5, .medium)).foregroundStyle(AppConfig.ink).lineLimit(1)
                        }
                        .padding(.horizontal, 12).frame(height: 30)
                        .background(Capsule().fill(WS.pill))
        .background(.ultraThinMaterial, in: Capsule())
                        .overlay(Capsule().stroke(tint.opacity(0.35)))
                        .shadow(color: .black.opacity(0.10), radius: 8, y: 3)
                        .padding(.bottom, 14)
                        .frame(width: g.size.width, height: g.size.height, alignment: .bottom)
                        .allowsHitTesting(false)
                        .transition(.opacity)
                    }
                }
                .frame(width: g.size.width, height: g.size.height, alignment: .topLeading)
            }
            .onChange(of: agent.press) { _, p in
                guard let p, !calm else { return }
                let r = AgentRipple.Item(point: p)
                ripples.append(r)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { ripples.removeAll { $0.id == r.id } }
            }
        }
    }
}

/// The cursor's travel: a spring that passes the point a little and settles (Reduce Motion: the director's own curve).
private struct OvershootTravel: ViewModifier {
    let on: Bool
    let value: CGPoint
    func body(content: Content) -> some View {
        if on { content.animation(.spring(response: 0.55, dampingFraction: 0.64), value: value) } else { content }
    }
}

/// A press on the page: two rings that spread and fade from the point, and a dot that flashes.
private struct AgentRipple: View {
    struct Item: Identifiable, Equatable { let id = UUID(); let point: CGPoint }
    let item: Item
    let tint: Color
    @State private var go = false

    var body: some View {
        ZStack {
            Circle().fill(tint.opacity(go ? 0 : 0.35)).frame(width: 18, height: 18).scaleEffect(go ? 1.6 : 0.6)
            Circle().stroke(tint, lineWidth: 2.5).frame(width: 60, height: 60).scaleEffect(go ? 1 : 0.15).opacity(go ? 0 : 0.95)
            Circle().stroke(tint.opacity(0.7), lineWidth: 1.5).frame(width: 60, height: 60).scaleEffect(go ? 1.35 : 0.1).opacity(go ? 0 : 0.7)
                .animation(.easeOut(duration: 0.7).delay(0.08), value: go)
        }
        .frame(width: 90, height: 90)
        .offset(x: item.point.x - 45, y: item.point.y - 45)
        .animation(.easeOut(duration: 0.6), value: go)
        .onAppear { go = true }
    }
}

/// A short comet behind the cursor: each move leaves a streak from the old point to the new that runs and fades.
private struct AgentTrail: View {
    let point: CGPoint
    let tint: Color
    @State private var streaks: [Streak] = []
    @State private var last: CGPoint?

    struct Streak: Identifiable { let id = UUID(); let from: CGPoint; let to: CGPoint }

    var body: some View {
        ZStack(alignment: .topLeading) {
            ForEach(streaks) { s in StreakView(streak: s, tint: tint) }
        }
        .onAppear { last = point }
        .onChange(of: point) { _, p in
            defer { last = p }
            guard let from = last, hypot(p.x - from.x, p.y - from.y) > 24 else { return }
            let s = Streak(from: from, to: p)
            streaks.append(s)
            if streaks.count > 3 { streaks.removeFirst() }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) { streaks.removeAll { $0.id == s.id } }
        }
    }

    private struct StreakView: View {
        let streak: Streak
        let tint: Color
        @State private var head: CGFloat = 0
        @State private var fade = 1.0

        var body: some View {
            Path { p in p.move(to: streak.from); p.addLine(to: streak.to) }
                .trim(from: max(0, head - 0.5), to: head)
                .stroke(tint.opacity(0.5), style: StrokeStyle(lineWidth: 4, lineCap: .round))
                .opacity(fade)
                .onAppear {
                    withAnimation(.easeOut(duration: 0.5)) { head = 1 }
                    withAnimation(.easeIn(duration: 0.35).delay(0.4)) { fade = 0 }
                }
        }
    }
}

/// While the agent drives the page, its border glows in the agent's colour: a soft angular gradient turning
/// slowly (one turn in 6 s). Reduce Motion: the same gradient, still.
/// (lag): it was a TimelineView at 30 fps that rebuilt the gradient and blurred a shadow over the whole
/// page every frame, on the main thread, for the whole task. Now the gradient is drawn once and only turned (a
/// transform the render server animates), masked to the border; the soft edge is a second, still, wider stroke.
private struct AgentGlow: View {
    let tint: Color
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var turn = false

    var body: some View {
        GeometryReader { g in
            let side = hypot(g.size.width, g.size.height)
            ZStack {
                RoundedRectangle(cornerRadius: 4, style: .continuous).strokeBorder(tint.opacity(0.18), lineWidth: 7)
                Rectangle()
                    .fill(AngularGradient(gradient: Gradient(colors: [tint.opacity(0.95), tint.opacity(0.25), tint.opacity(0.7), tint.opacity(0.2), tint.opacity(0.95)]),
                                          center: .center))
                    .frame(width: side, height: side)
                    .rotationEffect(.degrees(turn ? 360 : 0))
                    .frame(width: g.size.width, height: g.size.height)
                    .mask(RoundedRectangle(cornerRadius: 4, style: .continuous).strokeBorder(lineWidth: 2.5))
            }
        }
        .onAppear {
            guard !reduceMotion else { return }
            withAnimation(.linear(duration: 6).repeatForever(autoreverses: false)) { turn = true }
        }
    }
}

/// CSS colours as the page computes them: rgb(…) / rgba(…).
extension CSSColor {
    static func color(_ s: String) -> Color? {
        let n = s.components(separatedBy: CharacterSet(charactersIn: "0123456789.").inverted).filter { !$0.isEmpty }.compactMap(Double.init)
        guard n.count >= 3 else { return nil }
        let a = n.count >= 4 ? n[3] : 1
        guard a > 0.05 else { return nil }
        return Color(.sRGB, red: n[0] / 255, green: n[1] / 255, blue: n[2] / 255, opacity: a)
    }
}

/// The arrow, its name tag, and what it is doing right now.
private struct AgentCursor: View {
    let caption: String?
    var flip = false
    var tint: Color = AppConfig.accent
    /// The hero at the wheel, drawn moving in the tag (nil: the plain tag, as with Reduce Motion).
    var hero: AgentInfo? = nil
    /// The larger cursor (Reduce Motion keeps the earlier 19 pt one).
    var big = false
    var pressed = false
    var body: some View {
        HStack(alignment: .top, spacing: 2) {
            if flip { tag }
            Image(systemName: "cursorarrow")
                .font(.system(size: big ? 26 : 19, weight: .regular))
                .foregroundStyle(.white)
                .shadow(color: .black.opacity(0.55), radius: 0.6)
                .shadow(color: .black.opacity(0.25), radius: 3, y: 1)
                .shadow(color: big ? tint.opacity(0.45) : .clear, radius: 6)
                .scaleEffect(pressed ? 0.84 : 1, anchor: .topLeading)
                .animation(.spring(response: 0.22, dampingFraction: 0.5), value: pressed)
            if !flip { tag }
        }
    }
    private var tag: some View {
        HStack(spacing: 5) {
            if let hero {
                AgentAvatar(agent: hero, size: 20, status: .working, nudges: false)
                    .background(Circle().fill(.white.opacity(0.92)).frame(width: 22, height: 22))
            }
            Text(caption ?? hero?.name ?? "Lia")
                .font(LiaFont.ui(big ? 12 : 11, .semibold)).foregroundStyle(.white).lineLimit(1)
        }
        .padding(.leading, hero == nil ? 7 : 3).padding(.trailing, big ? 9 : 7).padding(.vertical, hero == nil ? 3 : 2)
        .background(Capsule().fill(tint))
        .shadow(color: big ? .black.opacity(0.18) : .clear, radius: 4, y: 2)
        .padding(.top, big ? 19 : 14)
        .fixedSize()
        .animation(.easeOut(duration: 0.15), value: caption)
    }
}

/// A value over one real control: typed into a text field, picked from a drawn menu, ticked on an option.
private struct MarkView: View {
    let mark: AgentDirector.Mark
    var body: some View {
        let r = mark.rect
        let st = mark.style
        let radius = st?.radius ?? 6
        ZStack(alignment: .topLeading) {
            switch mark.kind {
            case "text", "select":
                // The control's own background over its old value, then ours in its own type size and colour.
                HStack(spacing: 0) {
                    Text(mark.typed)
                        .font(.system(size: max(11, st?.fontSize ?? 14), weight: (st?.fontWeight ?? 400) >= 600 ? .semibold : .regular))
                        .foregroundStyle(st.flatMap { CSSColor.color($0.color) } ?? AppConfig.ink)
                        .lineLimit(1)
                    if mark.kind == "text" && mark.typed.count < mark.value.count {
                        Rectangle().fill(AppConfig.accent).frame(width: 1.5, height: max(12, (st?.fontSize ?? 14) + 2))
                    }
                    Spacer(minLength: 0)
                }
                .padding(.leading, max(6, st?.paddingLeft ?? 8))
                .frame(width: max(0, r.width - 2), height: max(0, r.height - 2))
                .background(RoundedRectangle(cornerRadius: radius).fill(st.flatMap { CSSColor.color($0.background) } ?? AppConfig.composeBg))
                .overlay(RoundedRectangle(cornerRadius: radius).stroke(AppConfig.accent, lineWidth: 1.5))
                .offset(x: r.minX + 1, y: r.minY + 1)
                if mark.kind == "select" && mark.menu {
                    // A drawn open menu with the chosen option (browser.js agFakeOpen): Meta's own never opens.
                    HStack(spacing: 8) {
                        Image(systemName: "checkmark").font(.system(size: 11, weight: .semibold)).foregroundStyle(AppConfig.accent)
                        Text(mark.value).font(LiaFont.ui(13)).foregroundStyle(AppConfig.ink).lineLimit(1)
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 10).frame(width: max(160, r.width), height: 34)
                    .background(RoundedRectangle(cornerRadius: 8).fill(AppConfig.accentSoft))
                    .padding(6)
                    .background(RoundedRectangle(cornerRadius: 10).fill(AppConfig.composeBg))
                    .overlay(RoundedRectangle(cornerRadius: 10).stroke(AppConfig.line2))
                    .shadow(color: .black.opacity(0.14), radius: 12, y: 6)
                    .offset(x: r.minX, y: r.maxY + 4)
                    .transition(.opacity.combined(with: .move(edge: .top)))
                }
            case "toggle":
                RoundedRectangle(cornerRadius: 8).stroke(AppConfig.accent, lineWidth: 2)
                    .background(RoundedRectangle(cornerRadius: 8).fill(AppConfig.accent.opacity(0.08)))
                    .frame(width: r.width + 6, height: r.height + 6)
                    .offset(x: r.minX - 3, y: r.minY - 3)
                Image(systemName: "checkmark.circle.fill").font(.system(size: 16)).foregroundStyle(.white, AppConfig.accent)
                    .offset(x: r.maxX - 8, y: r.minY - 8)
            default:
                RoundedRectangle(cornerRadius: 6).stroke(AppConfig.accent, lineWidth: 1.5)
                    .background(RoundedRectangle(cornerRadius: 6).fill(AppConfig.accent.opacity(0.07)))
                    .frame(width: r.width + 6, height: r.height + 6)
                    .offset(x: r.minX - 3, y: r.minY - 3)
            }
        }
    }
}

/// While she works: what she is doing, with Stop. After: a small status (checked, done, refused) without the shield.
private struct AgentPill: View {
    @ObservedObject var agent: AgentDirector
    var name = "Lia"
    var body: some View {
        if let ask = agent.webAsk { askPill(ask) } else { statusPill }
    }

    /// The web agent waits for the person: what it needs, and the one button that lets it go on.
    private func askPill(_ ask: AgentDirector.WebAsk) -> some View {
        HStack(spacing: 10) {
            Image(systemName: ask.human ? "hand.raised.fill" : "questionmark.circle.fill").foregroundStyle(.white, AppConfig.accent)
            Text(ask.question).font(LiaFont.ui(12.5, .medium)).foregroundStyle(AppConfig.ink).lineLimit(2).frame(maxWidth: 380, alignment: .leading)
            Button { agent.webAnswered(true) } label: {
                Text(ask.human ? "Continue" : "Allow").font(LiaFont.ui(12, .semibold)).foregroundStyle(AppConfig.onAccent)
                    .padding(.horizontal, 10).padding(.vertical, 4).background(Capsule().fill(AppConfig.accent))
            }
            .buttonStyle(.liaPlain).liaHover(.solid)
            Button { agent.stop() } label: {
                Text("Stop").font(LiaFont.ui(12, .semibold)).foregroundStyle(AppConfig.ink)
                    .padding(.horizontal, 10).padding(.vertical, 4)
                    .background(Capsule().fill(AppConfig.surface)).overlay(Capsule().stroke(AppConfig.line2))
            }
            .buttonStyle(.liaPlain).liaPointer()
        }
        .padding(.leading, 12).padding(.trailing, 6).padding(.vertical, 6)
        .background(Capsule().fill(WS.pill))
        .background(.ultraThinMaterial, in: Capsule())
        .background(Capsule().fill(AppConfig.composeBg.opacity(0.35)))
        .overlay(Capsule().stroke(AppConfig.line2.opacity(0.7)))
        .shadow(color: .black.opacity(0.08), radius: 8, y: 3)
    }

    private var statusPill: some View {
        HStack(spacing: 10) {
            switch agent.status {
            case .working, .checking:
                ProgressView().controlSize(.small).scaleEffect(0.7).frame(width: 14, height: 14)
            case .ready, .applied:
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.white, AppConfig.accent)
            case .refused, .failed:
                Image(systemName: "exclamationmark.circle.fill").foregroundStyle(.white, AppConfig.bad)
            }
            Text(text).font(LiaFont.ui(12.5, .medium)).foregroundStyle(AppConfig.ink).lineLimit(1)
            if agent.active {
                Button { agent.stop() } label: {
                    Text("Stop").font(LiaFont.ui(12, .semibold)).foregroundStyle(AppConfig.ink)
                        .padding(.horizontal, 10).padding(.vertical, 4)
                        .background(Capsule().fill(AppConfig.surface))
                        .overlay(Capsule().stroke(AppConfig.line2))
                }
                .buttonStyle(.liaPlain)
            }
        }
        .padding(.leading, 12).padding(.trailing, agent.active ? 6 : 12).padding(.vertical, 6)
        // Glass, so the page shows through (the solid pill still covered Ads Manager).
        .background(Capsule().fill(WS.pill))
        .background(.ultraThinMaterial, in: Capsule())
        .background(Capsule().fill(AppConfig.composeBg.opacity(0.35)))
        .overlay(Capsule().stroke(AppConfig.line2.opacity(0.7)))
        .shadow(color: .black.opacity(0.08), radius: 8, y: 3)
    }

    private var text: String {
        switch agent.status {
        case .working: return "\(name) is working" + (agent.label.isEmpty ? "" : " \u{00b7} " + agent.label)
        case .checking: return "Meta is checking it\u{2026}"
        case .ready: return "Checked by Meta \u{00b7} answer in the chat"
        case .refused(let why): return why
        case .applied: return "Done"
        case .failed(let why): return why
        }
    }
}

/// The control the director is working on now: the last mark it drew, named by the cursor's tag
/// ("Headline \u{00b7} Summer sale" -> "Headline"). Nothing when there is no such mark (web tasks draw none).
struct AgentFocus: Equatable {
    let rect: CGRect
    let text: String

    @MainActor
    static func current(_ agent: AgentDirector) -> AgentFocus? {
        guard let m = agent.marks.last, let cap = agent.caption, !cap.isEmpty else { return nil }
        let label = cap.components(separatedBy: " \u{00b7} ").first ?? cap
        guard !label.isEmpty else { return nil }
        let verb: String
        switch m.kind {
        case "text": verb = m.typed.count < m.value.count ? "Filling" : "Filled"
        case "select": verb = "Choosing"
        case "toggle": verb = "Setting"
        default: return nil
        }
        return AgentFocus(rect: m.rect, text: verb + ": " + label)
    }
}

private struct AgentFocusFrame: View {
    let focus: AgentFocus
    let tint: Color
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let r = focus.rect.insetBy(dx: -5, dy: -5)
        // The tag goes above the frame, or under it when the control is at the top of the page.
        let above = r.minY > 26
        ZStack(alignment: .topLeading) {
            if !reduceMotion {
                // the pulse: a soft wash and a ring that breathes out from the frame (Reduce Motion: the frame alone)
                RoundedRectangle(cornerRadius: 8, style: .continuous).fill(tint.opacity(0.07))
                    .frame(width: r.width, height: r.height)
                    .offset(x: r.minX, y: r.minY)
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(tint, lineWidth: 2)
                    .frame(width: r.width, height: r.height)
                    .phaseAnimator([0.0, 1.0]) { v, ph in
                        v.scaleEffect(x: 1 + 10 / max(40, r.width) * ph, y: 1 + 10 / max(20, r.height) * ph).opacity(0.75 * (1 - ph))
                    } animation: { ph in ph == 1 ? .easeOut(duration: 1.1) : .linear(duration: 0.01) }
                    .offset(x: r.minX, y: r.minY)
            }
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(tint, style: StrokeStyle(lineWidth: 2, dash: [5, 3]))
                .frame(width: r.width, height: r.height)
                .offset(x: r.minX, y: r.minY)
            Text(focus.text)
                .font(LiaFont.ui(11, .semibold)).foregroundStyle(.white).lineLimit(1)
                .padding(.horizontal, 7).padding(.vertical, 3)
                .background(RoundedRectangle(cornerRadius: 5, style: .continuous).fill(tint))
                .fixedSize()
                .offset(x: r.minX, y: above ? r.minY - 22 : r.maxY + 4)
        }
        .animation(reduceMotion ? nil : .spring(response: 0.3, dampingFraction: 0.85), value: focus)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(focus.text))
    }
}

/// The one control over an agent's browser. While the agent works: a Stop icon in a progress ring
/// (steps so far of the task's most on the open web; a turning ring when the total is not known), "Take over" and the
/// current step in a person's words, changing with a small slide. When it has finished: "Open in main window" for the
/// agent's page (a tab of the workspace's main browser, brought forward by the host). Nothing while there is neither.
struct AgentTakeOverButton: View {
    @ObservedObject var browser: BrowserModel
    let name: String
    var tint: Color = AppConfig.accent
    /// The host's idea of "at work" (the conversation also counts the seconds between two tasks of one job).
    let running: Bool
    var onTakeOver: () -> Void = {}
    /// nil: no Open in main window.
    var onOpenInMain: ((URL) -> Void)? = nil

    var body: some View {
        if running {
            AgentTakeOverWorking(agent: browser.agent, web: browser.web, history: AgentHistoryStore.shared(for: browser),
                                 name: name, tint: tint, onTakeOver: onTakeOver)
        } else if let onOpenInMain, let t = browser.selected {
            AgentOpenInMainControl(tab: t, action: onOpenInMain)
        }
    }
}

private struct AgentTakeOverWorking: View {
    @ObservedObject var agent: AgentDirector
    @ObservedObject var web: WebAgent
    let history: AgentHistoryStore?
    let name: String
    let tint: Color
    let onTakeOver: () -> Void

    /// Steps done of the most (the open web's calls); nil: not known (the director's runs).
    private var fraction: Double? {
        guard let n = web.step else { return nil }
        return min(1, max(0.04, Double(n) / Double(max(1, WebAgent.maxCalls))))
    }

    private func takeOver() {
        onTakeOver()
        if agent.active { agent.stop() }
    }

    var body: some View {
        Button(action: takeOver) {
            HStack(spacing: 9) {
                AgentProgressRing(fraction: fraction, tint: tint)
                VStack(alignment: .leading, spacing: 0) {
                    Text("Take over").font(LiaFont.ui(13, .semibold)).foregroundStyle(WS.ink).lineLimit(1)
                    if let history { AgentStepNow(store: history, agent: agent, web: web) } else { AgentStepNowLabel(text: Self.fallback(agent, web)) }
                }
            }
            .padding(.leading, 6).padding(.trailing, 14)
            .frame(height: 38)
            .background(Capsule().fill(WS.surface))
            .overlay(Capsule().stroke(tint.opacity(0.55), lineWidth: 1.5))
            .shadow(color: tint.opacity(0.18), radius: 6, y: 2)
            .contentShape(Capsule())
        }
        .buttonStyle(.liaPlain)
        .liaPointer()
        .liaTip("Stop \(name) and take the wheel", kbd: "esc")
        .accessibilityLabel(Text("Take over from \(name)"))
        .accessibilityValue(Text(fraction.map { "\(Int(($0 * 100).rounded())) percent" } ?? "Working"))
        .accessibilityHint(Text("Stops the task and gives you the page"))
    }

    static func fallback(_ agent: AgentDirector, _ web: WebAgent) -> String {
        if web.paused { return "Paused" }
        if case .checking = agent.status { return "Meta is checking it\u{2026}" }
        return agent.label.isEmpty ? "Working\u{2026}" : agent.label
    }
}

/// The current step as the history writes it ("Opened Ryanair", "Picked dates"), else the director's label.
private struct AgentStepNow: View {
    @ObservedObject var store: AgentHistoryStore
    @ObservedObject var agent: AgentDirector
    @ObservedObject var web: WebAgent

    var body: some View {
        let step = store.running?.steps.last?.text
        AgentStepNowLabel(text: web.paused ? "Paused" : (step ?? AgentTakeOverWorking.fallback(agent, web)))
    }
}

private struct AgentStepNowLabel: View {
    let text: String
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack(alignment: .leading) {
            Text(text).font(LiaFont.ui(11)).foregroundStyle(WS.text2).lineLimit(1)
                .id(text)
                .transition(reduceMotion ? .opacity : .push(from: .bottom))
        }
        .frame(maxWidth: 200, alignment: .leading)
        .clipped()
        .animation(.easeOut(duration: 0.25), value: text)
        .accessibilityHidden(true)
    }
}

/// A Stop square inside a ring: the ring fills with the steps done, or turns when their total is not known.
private struct AgentProgressRing: View {
    let fraction: Double?
    let tint: Color
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var turn = false

    var body: some View {
        ZStack {
            Circle().stroke(tint.opacity(0.18), lineWidth: 2.5)
            if let f = fraction {
                Circle().trim(from: 0, to: f)
                    .stroke(tint, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .animation(.easeOut(duration: 0.3), value: f)
            } else {
                Circle().trim(from: 0, to: 0.28)
                    .stroke(tint, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                    .rotationEffect(.degrees(turn ? 360 : 0))
                    .onAppear {
                        guard !reduceMotion else { return }
                        withAnimation(.linear(duration: 1).repeatForever(autoreverses: false)) { turn = true }
                    }
            }
            RoundedRectangle(cornerRadius: 2, style: .continuous).fill(tint).frame(width: 9, height: 9)
        }
        .frame(width: 26, height: 26)
        .accessibilityHidden(true)
    }
}

/// After the task: the agent's page as a tab of the main window (hidden while nothing is open).
private struct AgentOpenInMainControl: View {
    @ObservedObject var tab: BrowserTab
    let action: (URL) -> Void

    var body: some View {
        if let url = tab.savedURL {
            Button { action(url) } label: {
                Label("Open in main window", systemImage: "arrow.up.forward.app")
                    .font(LiaFont.ui(12.5, .semibold))
            }
            .buttonStyle(WSButtonStyle(small: true))
            .liaPointer()
            .accessibilityHint(Text("Opens \(url.host ?? "this page") in a new tab of the main window"))
        }
    }
}
