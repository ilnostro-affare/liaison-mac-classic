import SwiftUI
import AppKit

/// (instead of Live Activities, which macOS has no API for): what the agents are doing right now, for the menu
/// bar item and the progress bar on the app's Dock icon. WorkspaceModel refreshes it once a second while anyone works.
@MainActor
final class MenuBarStatus: ObservableObject {
    static let shared = MenuBarStatus()

    struct Item: Identifiable, Equatable {
        let id: String          // dialogue key + agent
        let agent: String
        let name: String
        let color: UInt32
        let text: String
        let client: String
        /// "profile|dlg"
        let dialogue: String
        /// 0...1 when known (the agent's browser step out of its budget, a copy job), nil: just working.
        let progress: Double?
        /// Items 14-15: a counted job's steps ("2/4"), when the caller knows them (TeamChatModel.jobProgress).
        var steps: AgentActivity.Steps? = nil
    }

    /// A run that ended (finished or stopped), for the popover's recent list and the notch's short "done".
    struct Finished: Identifiable, Equatable {
        let id: String
        let agent: String
        let name: String
        let color: UInt32
        let text: String
        let client: String
        let dialogue: String
        let at: Date
        let took: TimeInterval
    }

    @Published private(set) var items: [Item] = []
    @Published private(set) var waiting = 0
    /// Newest first, at most four.
    @Published private(set) var recent: [Finished] = []
    /// The run that has just ended (the notch shows it with a check for ~3 s); set again on every new end.
    @Published private(set) var lastFinished: Finished?
    /// For a minute and a half after the last run ends the item stays, a still figure, so its recent list can be read.
    @Published private(set) var lingering = false
    /// When each running item was first seen (its elapsed time).
    private(set) var started: [String: Date] = [:]
    private var lingerToken = 0

    /// The menu bar item shows while something runs or waits, and shortly after (Settings › Notifications can turn it off).
    var visible: Bool { (!items.isEmpty || waiting > 0 || lingering) && Prefs.flag("lia_menubar_status") }

    func update(_ new: [Item], waiting w: Int) {
        let now = Date()
        let gone = AgentActivity.finished(before: items.map(\.id), after: new.map(\.id))
        if !gone.isEmpty {
            let ended: [Finished] = gone.compactMap { id in
                guard let it = items.first(where: { $0.id == id }) else { return nil }
                return Finished(id: id + "@" + String(Int(now.timeIntervalSince1970)), agent: it.agent, name: it.name, color: it.color,
                                text: it.text, client: it.client, dialogue: it.dialogue, at: now,
                                took: now.timeIntervalSince(started[id] ?? now))
            }
            recent = AgentActivity.remember(ended, into: recent, limit: 4) { $0.id }
            lastFinished = ended.first
            for id in gone { started[id] = nil }
            if new.isEmpty { linger() }
        }
        for it in new where started[it.id] == nil { started[it.id] = now }
        if new != items { items = new }
        if w != waiting { waiting = w }
        if !new.isEmpty, lingering { lingering = false }
        DockProgress.show(overall)
        MenuBarTicker.shared.running(!items.isEmpty)
    }

    private func linger() {
        lingerToken += 1
        let token = lingerToken
        lingering = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 90) { [weak self] in
            guard let self, self.lingerToken == token else { return }
            self.lingering = false
        }
    }

    func elapsed(_ item: Item, now: Date = Date()) -> TimeInterval { now.timeIntervalSince(started[item.id] ?? now) }

    /// Stop: the conversation's run, when this agent is the one at work in it.
    func stop(_ item: Item) {
        WorkspaceModel.current?.chat(key: item.dialogue)?.stop(agent: item.agent)
    }

    /// Open: the app in front, on that conversation.
    func open(dialogue: String?) {
        NSApp.activate(ignoringOtherApps: true)
        if let w = NSApp.windows.first(where: { $0.identifier?.rawValue.hasPrefix("main") == true && $0.isVisible }) ?? NSApp.windows.first(where: { $0.canBecomeMain && $0.isVisible }) {
            w.makeKeyAndOrderFront(nil)
        }
        if let dialogue { WorkspaceModel.current?.openDialogue(key: dialogue) }
    }

    /// The mean of the known progresses; nil when nothing runs; -1 when work runs with no measurable progress.
    var overall: Double? {
        guard !items.isEmpty else { return nil }
        let known = items.compactMap(\.progress)
        return known.isEmpty ? -1 : known.reduce(0, +) / Double(known.count)
    }

    /// Reduce Motion (the system's) or the app's calmer agents: figures stay still.
    /// Low Power Mode calms it too (the figure redrew the menu bar ten times a second while agents worked).
    static var calm: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion || Prefs.flag(Prefs.simpleBlobs, default: false) || EnergySaver.isLow }
}

/// The menu bar figure's clock: ten frames a second while an agent works (one a second with Reduce Motion, only to
/// turn between agents), nothing while all rest. Its own object, so only the label redraws, not the app's scene.
@MainActor
final class MenuBarTicker: ObservableObject {
    static let shared = MenuBarTicker()
    @Published private(set) var t: Double = 0
    private var timer: Timer?
    private var calm = false
    private let origin = Date()

    func running(_ on: Bool) {
        let c = MenuBarStatus.calm
        if on, timer != nil, c == calm { return }
        timer?.invalidate(); timer = nil
        calm = c
        guard on else { t = 0; return }
        timer = Timer.scheduledTimer(withTimeInterval: c ? 1 : 0.1, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.t = Date().timeIntervalSince(self.origin)
            }
        }
    }

    /// Where an agent's figure is in its cycle now (0 with Reduce Motion: still).
    func phase(_ agent: String) -> Double {
        if calm { return 0 }
        // each agent its own offset, so two at work do not move in step
        let off = Double(agent.unicodeScalars.reduce(0) { $0 + Int($1.value) } % 7) * 0.13
        return (t / AgentBlot.cycle + off).truncatingRemainder(dividingBy: 1)
    }

    /// Point 4: the agent's working move now (HeroMoves, the same as the big figure's), rest with Reduce Motion.
    /// Each agent with the same offset as `phase`, so two at work do not move in step; alone here, so no nudge.
    private var tracks: [String: HeroMoves.Sequence] = [:]
    func pose(_ agent: String) -> HeroPose {
        if calm { return .rest }
        let off = Double(agent.unicodeScalars.reduce(0) { $0 + Int($1.value) } % 7) * 0.13 * AgentBlot.cycle
        var seq = tracks[agent] ?? HeroMoves.Sequence(agent: agent, allowNudge: false)
        let p = seq.pose(elapsed: t + off)
        tracks[agent] = seq
        return p
    }
}

/// The app icon in the Dock with a thin progress bar under it while agents work (like a Finder copy).
@MainActor
enum DockProgress {
    private static var view: DockProgressView?
    private static var last: Double? = nil

    static func show(_ value: Double?) {
        if value == last { return }
        last = value
        let tile = NSApp.dockTile
        guard let value else {
            tile.contentView = nil
            tile.display()
            view = nil
            return
        }
        if view == nil {
            let v = DockProgressView(frame: NSRect(origin: .zero, size: tile.size))
            view = v
            tile.contentView = v
        }
        view?.value = value
        tile.display()
    }
}

final class DockProgressView: NSView {
    /// 0...1, or -1 for "working, no measure" (a short bar that sits in the middle).
    var value: Double = 0

    override func draw(_ dirtyRect: NSRect) {
        NSApp.applicationIconImage?.draw(in: bounds)
        let h = bounds.height * 0.085
        let track = NSRect(x: bounds.width * 0.14, y: bounds.height * 0.10, width: bounds.width * 0.72, height: h)
        NSColor.black.withAlphaComponent(0.55).setFill()
        NSBezierPath(roundedRect: track, xRadius: h / 2, yRadius: h / 2).fill()
        var fill = track.insetBy(dx: 1.5, dy: 1.5)
        if value >= 0 {
            fill.size.width = max(fill.height, fill.width * CGFloat(min(1, value)))
        } else {
            fill.origin.x += fill.width * 0.3
            fill.size.width *= 0.4
        }
        NSColor.white.setFill()
        NSBezierPath(roundedRect: fill, xRadius: fill.height / 2, yRadius: fill.height / 2).fill()
    }
}

/// The menu bar item's window (items 14-15): each agent at work with its figure, its step, how long it has gone, Stop
/// and Open; the changes waiting for a Yes; the runs that just ended, with a check; Open Liaison.
struct LiveStatusMenu: View {
    @ObservedObject var status = MenuBarStatus.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(status.items.isEmpty ? "Nothing running" : (status.items.count == 1 ? "Working now" : "\(status.items.count) agents working"))
                .font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary)
            ForEach(status.items) { it in LiveAgentRow(item: it) }
            if status.waiting > 0 {
                Divider()
                Button {
                    status.open(dialogue: nil)
                    WorkspaceModel.current?.showApprovals = true
                } label: {
                    Label(status.waiting == 1 ? "1 change waits for your Yes" : "\(status.waiting) changes wait for your Yes", systemImage: "exclamationmark.circle.fill")
                }
                .buttonStyle(.liaPlain)
                .foregroundStyle(WS.amberInk)
            }
            if !status.recent.isEmpty {
                Divider()
                Text("Recently finished").font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
                ForEach(status.recent) { f in LiveFinishedRow(item: f) }
            }
            Divider()
            Button("Open Liaison") { status.open(dialogue: nil) }.buttonStyle(.liaPlain)
        }
        .padding(14)
        .frame(width: 320)
    }
}

/// One agent at work: its moving figure, name and client, the step, the time it has gone, the progress, Stop / Open.
/// Used by the menu bar's window and by the notch island (`onDark`: white text on the island's black).
struct LiveAgentRow: View {
    let item: MenuBarStatus.Item
    var onDark = false
    @ObservedObject private var status = MenuBarStatus.shared

    private var info: AgentInfo {
        AgentInfo.lookup(item.agent, in: WorkspaceModel.current?.roster ?? [])
            ?? AgentInfo(id: item.agent, name: item.name, role: "", shape: .ring, colorHex: item.color)
    }
    private var primary: Color { onDark ? .white : .primary }
    private var secondary: Color { onDark ? .white.opacity(0.62) : .secondary }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            AgentAvatar(agent: info, size: 30, status: .working)
                .padding(.top, 1)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(item.name).font(.system(size: 13, weight: .semibold)).foregroundStyle(primary)
                    if !item.client.isEmpty { Text(item.client).font(.system(size: 11)).foregroundStyle(secondary).lineLimit(1) }
                    Spacer(minLength: 4)
                    TimelineView(.periodic(from: .now, by: 1)) { tl in
                        Text(AgentActivity.elapsed(status.elapsed(item, now: tl.date)))
                            .font(.system(size: 11).monospacedDigit()).foregroundStyle(secondary)
                    }
                }
                Text(item.text).font(.system(size: 12)).foregroundStyle(secondary).lineLimit(1)
                    .id(item.text)
                    .transition(.opacity)
                    .animation(.easeOut(duration: 0.2), value: item.text)
                HStack(spacing: 8) {
                    Group {
                        if let p = item.progress { ProgressView(value: p) } else { ProgressView().progressViewStyle(.linear) }
                    }
                    .controlSize(.small)
                    .tint(Color(hex: item.color == 0x1F2430 && onDark ? 0xDADDE3 : item.color))
                    if let s = item.steps?.text { Text(s).font(.system(size: 11).monospacedDigit()).foregroundStyle(secondary) }
                    else if let p = item.progress { Text("\(Int(p * 100))%").font(.system(size: 11).monospacedDigit()).foregroundStyle(secondary) }
                    Button { status.stop(item) } label: {
                        Image(systemName: "stop.fill").font(.system(size: 9, weight: .bold))
                            .frame(width: 22, height: 20)
                            .background(Capsule().fill(onDark ? Color.white.opacity(0.14) : Color.primary.opacity(0.08)))
                    }
                    .buttonStyle(.liaPlain).foregroundStyle(primary)
                    .accessibilityLabel(Text("Stop \(item.name)"))
                    // Dev's Open goes straight to his Activity (DevActivityJump).
                    Button { if item.agent == "dev" { DevActivityJump.open(key: item.dialogue) } else { status.open(dialogue: item.dialogue) } } label: {
                        Text("Open").font(.system(size: 11, weight: .semibold))
                            .padding(.horizontal, 8).frame(height: 20)
                            .background(Capsule().fill(onDark ? Color.white.opacity(0.14) : Color.primary.opacity(0.08)))
                    }
                    .buttonStyle(.liaPlain).foregroundStyle(primary)
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text("\(item.name), \(item.text)"))
    }
}

/// A run that ended: the figure at rest, a check, what it last did and when.
private struct LiveFinishedRow: View {
    let item: MenuBarStatus.Finished

    var body: some View {
        Button { MenuBarStatus.shared.open(dialogue: item.dialogue) } label: {
            HStack(spacing: 8) {
                Image(nsImage: AgentBlotImage.image(item.agent, color: item.color, u: 0, size: 18))
                Image(systemName: "checkmark.circle.fill").font(.system(size: 11)).foregroundStyle(.white, WS.green)
                Text(item.name).font(.system(size: 12, weight: .semibold))
                Text(AgentActivity.step(item.text, name: item.name, maxLength: 28)).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1)
                Spacer(minLength: 4)
                TimelineView(.periodic(from: .now, by: 30)) { tl in
                    Text(AgentActivity.ago(tl.date.timeIntervalSince(item.at))).font(.system(size: 11)).foregroundStyle(.secondary)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.liaPlain)
        .accessibilityLabel(Text("\(item.name) finished, \(item.text)"))
    }
}

/// The menu bar item's label (items 14-15): the working agent's figure moving, and a very short line
/// ("Dev · pushing", "Crea · drawing 2/4"), turning between agents every 3 s when several work. At rest: the last
/// agent's still figure, no text. Changes waiting with nothing running: the waiting sign and their count.
struct LiveStatusLabel: View {
    @ObservedObject var status = MenuBarStatus.shared
    @ObservedObject var tick = MenuBarTicker.shared

    var body: some View {
        if !status.items.isEmpty {
            let it = status.items[AgentActivity.pick(count: status.items.count, now: tick.t, every: 3) % status.items.count]
            Image(nsImage: AgentBlotImage.image(it.agent, color: it.color, u: tick.phase(it.agent), pose: tick.pose(it.agent)))
            Text(AgentActivity.label(name: it.name, text: it.text, progress: it.progress, steps: it.steps, maxLength: 22))
        } else if status.waiting > 0 {
            Image(systemName: "exclamationmark.circle")
            Text("\(status.waiting)")
        } else if let f = status.recent.first {
            Image(nsImage: AgentBlotImage.image(f.agent, color: f.color, u: 0))
        } else {
            Image(nsImage: AgentBlotImage.image("lia", color: 0x1F2430, u: 0))
        }
    }
}
