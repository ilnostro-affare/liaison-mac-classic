import SwiftUI
import AppKit
import Combine

/// The grabber at the top of the conversation sheet. Dragged down past 90 pt (or flicked) it closes the
/// sheet; short of that the sheet springs back. VoiceOver: a button that closes. With Esc, the only gesture that
/// closes the sheet (a scroll in the thread never does).
struct ChatGrabber: View {
    @Binding var pull: CGFloat
    let onClose: () -> Void
    @State private var hover = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        grip
            .onHover { hover = $0 }
            .gesture(drag)
            .liaPointer()
            .accessibilityElement()
            .accessibilityLabel(Text("Close conversation"))
            .accessibilityAddTraits(.isButton)
            .accessibilityAction { onClose() }
    }

    private var grip: some View {
        let tint: Color = hover || pull > 0 ? WS.text3 : WS.line2
        return Capsule()
            .fill(tint)
            .frame(width: 38, height: 5)
            .frame(width: 90, height: 18)
            .contentShape(Rectangle())
    }

    private var drag: some Gesture {
        DragGesture(minimumDistance: 3)
            .onChanged { v in pull = max(0, v.translation.height) }
            .onEnded { v in
                if v.translation.height > 90 || v.predictedEndTranslation.height > 260 {
                    onClose()
                } else if reduceMotion {
                    pull = 0
                } else {
                    withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) { pull = 0 }
                }
            }
    }
}

/// The two-finger swipe that closed the sheet at the top of the thread is gone - a swipe or a scroll
/// inside the thread never closes it (the grabber's drag above and Esc do). What is left watches the window's
/// scroll-wheel events (never consumes them) to tell the person's own scrolling from the thread moving by itself:
/// while the person scrolls, a streaming answer does not pull the thread back to the end, and older or newer pages
/// load only when the person scrolled to them (not from a layout pass while the thread opens). Not actor-bound (as
/// WSKeyMonitor): local monitors run on the main thread.
final class ChatScrollMonitor {
    /// The pointer is over the thread (kept by `ChatScrollHooks`).
    var inside = false
    /// The last scroll-wheel event over the thread (a trackpad's phases and momentum, a mouse wheel).
    private(set) var lastScroll = Date.distantPast
    private var monitor: Any?

    /// The person scrolled the thread within `seconds` (momentum included).
    func scrolled(within seconds: TimeInterval) -> Bool { Date().timeIntervalSince(lastScroll) < seconds }

    func start() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] e in
            if let self, self.inside, e.scrollingDeltaY != 0 || !e.phase.isEmpty || !e.momentumPhase.isEmpty {
                self.lastScroll = Date()
            }
            return e
        }
    }

    func stop() {
        if let m = monitor { NSEvent.removeMonitor(m) }
        monitor = nil
    }
}

/// Where the first message is in the thread's scroll view (its top marker's minY in "chatScroll").
struct ChatTopKey: PreferenceKey {
    static var defaultValue: CGFloat = -.greatestFiniteMagnitude
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

/// Wires the monitor to the thread: on while shown, the pointer over it.
struct ChatScrollHooks: ViewModifier {
    let monitor: ChatScrollMonitor

    func body(content: Content) -> some View {
        content
            .onHover { monitor.inside = $0 }
            .onAppear { monitor.start() }
            .onDisappear { monitor.stop() }
    }
}

// MARK: -: a dialogue opened again is the same view (its rows, text views and scroll position)

/// What the kept thread is told about its host: shown again (the sheet opened on it) or hidden (closed, or another
/// dialogue in front). The thread restores its end or keeps the person's place, and flushes its draft and deletions.
/// Not actor-bound (a default argument of ThreadColumn reads `none`); events are sent on the main queue.
final class ThreadLife {
    /// The thread outside the sheet (the side panel): never kept, never told.
    static let unkept = ThreadLife()
    /// true: shown again; false: hidden.
    let events = PassthroughSubject<Bool, Never>()
    /// Was the person at the end of the thread when it was hidden (it opens there again; else at the same place).
    var atEndWhenHidden = true
    func send(_ shown: Bool) {
        DispatchQueue.main.async { [events] in events.send(shown) }
    }
}

/// The view behind a kept thread: its own hosting view, so the SwiftUI graph (rows, NSTextViews, the scroll view)
/// survives the sheet that showed it.
final class ThreadHostBox: NSView {
    let host: NSHostingView<AnyView>
    let life: ThreadLife
    private var everShown = false

    @MainActor init(root: AnyView, life: ThreadLife) {
        host = NSHostingView(rootView: root)
        self.life = life
        super.init(frame: NSRect(x: 0, y: 0, width: 460, height: 600))
        host.sizingOptions = []
        host.translatesAutoresizingMaskIntoConstraints = true
        host.autoresizingMask = [.width, .height]
        host.frame = bounds
        addSubview(host)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    /// a kept thread shown again is at its end in the FIRST frame. Messages that came in while
    /// it was hidden made its content taller with the offset unchanged, and the end was scrolled to only after the frame
    /// had shown (the scroller moved). Here, in the window but before anything is drawn, the hosting view is laid out
    /// and the thread's scroll view (the tallest one: the composer's is a few lines) is put at its maximum.
    @MainActor func pinToEnd() {
        // ("why 650 ms for a kept thread?"): this layout of every kept row is the suspect between the
        // sheet's appear (~50 ms) and the thread's first frame (~650 ms); its own time is reported as agent_open:pin
        let t0 = ProcessInfo.processInfo.systemUptime
        defer { LatencyProbe.record("agent_open:pin", ms: (ProcessInfo.processInfo.systemUptime - t0) * 1000) }
        host.frame = bounds
        host.layoutSubtreeIfNeeded()
        guard let sv = Self.threadScroll(in: host), let doc = sv.documentView else { return }
        let clip = sv.contentView
        let maxY: CGFloat = doc.isFlipped ? max(0, doc.frame.height - clip.bounds.height) : 0
        guard abs(clip.bounds.origin.y - maxY) > 0.5 else { return }
        clip.scroll(to: NSPoint(x: clip.bounds.origin.x, y: maxY))
        sv.reflectScrolledClipView(clip)
    }

    /// The tallest scroll view under `root`, web views left out (a chart's page scrolls on its own).
    @MainActor static func threadScroll(in root: NSView) -> NSScrollView? {
        var best: NSScrollView?
        var queue: [NSView] = [root]
        var seen = 0
        while !queue.isEmpty, seen < 4000 {
            let v = queue.removeFirst()
            seen += 1
            if String(describing: type(of: v)).hasPrefix("WK") { continue }
            if let sv = v as? NSScrollView, !(sv.documentView is NSTextView) {
                if best == nil || sv.frame.height > (best?.frame.height ?? 0) { best = sv }
                continue   // nothing of the thread's own sits inside another scroll view
            }
            queue.append(contentsOf: v.subviews)
        }
        return best
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        let w = window != nil
        MainActor.assumeIsolated {
            if w {
                if everShown {
                    if life.atEndWhenHidden { pinToEnd() }
                    life.send(true)
                }
                everShown = true
            } else if everShown {
                life.send(false)
            }
        }
    }
}

/// The kept threads, by dialogue (the newest `cap`; the oldest goes past it).
@MainActor
final class ThreadHostCache {
    static let shared = ThreadHostCache()
    /// UserDefaults switch: false builds the thread anew on every open (as before 0.2.11's round of).
    static let enabledKey = "lia_ws_keep_threads"
    /// The telemetry of his test (73 kept opens) had them no faster than a cold build
    /// (p50 650 ms either way) and up to 7.2 s at worst - the hosting view moved into the next sheet laid every row out
    /// again (`pinToEnd`, 47% of the main thread in the sample) - and their text views came back blank.
    static var enabled: Bool { UserDefaults.standard.object(forKey: enabledKey) as? Bool ?? false }
    private static let cap = 6

    private var lives: [String: ThreadLife] = [:]
    private var boxes: [String: ThreadHostBox] = [:]
    private var order: [String] = []

    /// The thread's identity: the dialogue's key and its model (another account's model with the same key is another).
    static func key(_ chat: TeamChatModel) -> String { chat.key + "#" + String(UInt(bitPattern: ObjectIdentifier(chat).hashValue)) }

    func life(_ key: String) -> ThreadLife {
        if let l = lives[key] { return l }
        let l = ThreadLife()
        lives[key] = l
        return l
    }

    func box(_ key: String, root: AnyView) -> ThreadHostBox {
        order.removeAll { $0 == key }
        order.append(key)
        if let b = boxes[key] { return b }
        let b = ThreadHostBox(root: root, life: life(key))
        boxes[key] = b
        while order.count > Self.cap {
            let old = order.removeFirst()
            // one on screen stays (it is only forgotten here)
            if boxes[old]?.window == nil { boxes[old] = nil; lives[old] = nil }
        }
        return b
    }

    /// Whether `key`'s thread was built already (its open shows the kept view; a cold one is built a frame later).
    func has(_ key: String) -> Bool { boxes[key] != nil }

    /// Drops every kept thread (signing out, switching accounts).
    func clear() { boxes = [:]; lives = [:]; order = [] }
}

/// The sheet's thread column, kept: the same hosting view every time this dialogue opens; each redraw of the sheet
/// hands it the current closures and objects.
struct KeptThread: NSViewRepresentable {
    let key: String
    let root: AnyView

    func makeNSView(context: Context) -> ThreadHostBox {
        let b = ThreadHostCache.shared.box(key, root: root)
        b.host.rootView = root
        return b
    }

    func updateNSView(_ v: ThreadHostBox, context: Context) {
        v.host.rootView = root
    }

    /// Nothing here: the box may already be in the next sheet's column (it is only moved, never torn down).
    static func dismantleNSView(_ v: ThreadHostBox, coordinator: Coordinator) {}

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: ThreadHostBox, context: Context) -> CGSize? {
        proposal.replacingUnspecifiedDimensions(by: CGSize(width: 460, height: 600))
    }
}

// MARK: - selection mode's pieces

/// The round check beside a message in selection mode.
struct ChatSelectCheck: View {
    let on: Bool

    var body: some View {
        ZStack {
            Circle().stroke(on ? WS.blue : WS.text3, lineWidth: 1.5)
            if on {
                Circle().fill(WS.blue)
                Image(systemName: "checkmark").font(.system(size: 10, weight: .bold)).foregroundStyle(.white)
            }
        }
        .frame(width: 20, height: 20)
        .accessibilityHidden(true)
    }
}

/// The bar over the thread in selection mode: "N selected", Copy, Forward, Delete, Cancel (Esc).
struct ChatSelectionBar: View {
    let count: Int
    let onCopy: () -> Void
    let onForward: () -> Void
    let onDelete: () -> Void
    let onCancel: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            Button(action: onCancel) {
                Image(systemName: "xmark").font(.system(size: 10, weight: .bold)).foregroundStyle(WS.text2)
                    .frame(width: 26, height: 26).background(WS.soft, in: Circle())
            }
            .buttonStyle(.liaPlain).liaPointer()
            .keyboardShortcut(.cancelAction)
            .accessibilityLabel(Text("Cancel selection"))
            Text(count == 1 ? "1 selected" : "\(count) selected")
                .font(LiaFont.ui(13, .semibold)).foregroundStyle(WS.ink)
                .padding(.leading, 2)
            Spacer(minLength: 8)
            barButton("Copy", symbol: "doc.on.doc", action: onCopy)
            barButton("Forward", symbol: "arrowshape.turn.up.right", action: onForward)
            barButton("Delete", symbol: "trash", destructive: true, action: onDelete)
        }
        .padding(.horizontal, 8).frame(height: 38)
        .wsGlass(14)
        .shadow(color: .black.opacity(0.08), radius: 10, y: 3)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text("\(count) messages selected"))
    }

    private func barButton(_ title: String, symbol: String, destructive: Bool = false, action: @escaping () -> Void) -> some View {
        let tint: Color = destructive ? WS.red : WS.ink
        return Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: symbol).font(.system(size: 11, weight: .semibold))
                Text(title).font(LiaFont.ui(12.5, .semibold))
            }
            .foregroundStyle(tint)
            .padding(.horizontal, 9).frame(height: 28)
            .background(WS.soft, in: Capsule())
            .contentShape(Capsule())
        }
        .buttonStyle(.liaPlain).liaPointer()
        .disabled(count == 0)
        .accessibilityLabel(Text(title))
    }
}

/// Forward's picker in selection mode: the workspace's other dialogues (Team first, then each agent).
struct ChatSelectForwardPicker: View {
    @ObservedObject var ws: WorkspaceModel
    let from: String
    let onPick: (String) -> Void

    private var targets: [String] { ws.dialogueIds.filter { $0 != from && ws.agent($0)?.soon != true } }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Forward to").font(LiaFont.ui(12, .semibold)).foregroundStyle(WS.text2)
                .padding(.horizontal, 8).padding(.top, 2)
                .accessibilityAddTraits(.isHeader)
            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(targets, id: \.self) { d in
                        ChatSelectForwardRow(agent: ws.agent(d == "team" ? "lia" : d), title: ws.dialogueTitle(d)) { onPick(d) }
                    }
                }
            }
            .frame(maxHeight: 280)
            .scrollIndicators(.hidden)
        }
        .padding(6)
        .frame(width: 250)
        .wsGlass(16)
    }
}

private struct ChatSelectForwardRow: View {
    let agent: AgentInfo?
    let title: String
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                if let agent { AgentAvatar(agent: agent, size: 22).accessibilityHidden(true) }
                Text(title).font(LiaFont.ui(13)).foregroundStyle(WS.ink).lineLimit(1)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 8).frame(height: 34)
            .background(hover ? WS.blue.opacity(0.10) : Color.clear, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.liaPlain)
        .onHover { hover = $0 }
        .liaPointer()
        .accessibilityLabel(Text("Forward to \(title)"))
    }
}

/// Deleting several messages: the server's answers come one by one; the facts Lia saved from them are asked about
/// once - when every message has answered, or after the countdown if one was taken back (Undo answers nothing).
final class ChatDeleteTally {
    private var left: Int
    private var finished = false
    private(set) var facts: [ChatForgetFacts.Fact] = []
    private(set) var failed = false

    init(count: Int) { left = count }

    /// One message's answer (nil: it failed); true when this one closes the tally.
    func done(_ f: [(id: String, text: String)]?) -> Bool {
        if let f { facts += f.map { ChatForgetFacts.Fact(id: $0.id, text: $0.text) } } else { failed = true }
        left -= 1
        return left <= 0 ? finish() : false
    }

    /// Closes the tally once (later calls answer false).
    func finish() -> Bool {
        guard !finished else { return false }
        finished = true
        return true
    }
}

/// while a thread opens, its scroll view keeps the bottom where it is as the content grows
/// or measures itself (macOS 15's `.sizeChanges` anchor). On macOS 14 nothing is added: the bottom default anchor places
/// the first layout and the end is held by `toEnd` without animation.
struct ChatEndPin: ViewModifier {
    let on: Bool

    @ViewBuilder func body(content: Content) -> some View {
        if #available(macOS 15.0, *) {
            content.defaultScrollAnchor(on ? UnitPoint.bottom : nil, for: .sizeChanges)
        } else {
            content
        }
    }
}
