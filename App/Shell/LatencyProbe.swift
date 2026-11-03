import SwiftUI
import AppKit
import IOKit.ps

// 0.2.11: "track button latency so we see in logs which buttons took more than 100-400 ms over a
// week, at least for the canary (only my account)". The recorder; the pure part is Shared/Core/Latency.swift, the
// server is lia-agents /agents/telemetry/latency (the site's docs/TELEMETRY.md).
//
// What is measured, per action id (a button's `.latencyID`, else its accessibility label):
// A click: from the mouse-up event's own timestamp (so the time it waited in the queue counts) to the main thread
// being free again after the click's work, which is when the next frame can be drawn. Every click on a button, a
// link, a `.clickable` view or a `.liaClicks` view in our windows; never a click inside a web page.
// An opening: from that click to the first appearance of what it opened (`.latencyAppear("Settings")` on a sheet,
// popup or panel), recorded as "open:<name>". `LatencyProbe.begin(id)` / `.end(id)` for anything else.
// Only for a member the server lists (GET answers on): for everyone else nothing is installed and every hook returns
// at its first line. The day is kept in memory and in Application Support/Liaison/Latency/<member>/<day>.json, and a
// finished day is sent once.: today's aggregate so far is sent too (the app going to the background,
// and every 30 min while it runs, when something new was recorded); the server replaces a day on a re-send, so the
// finished day's own send later carries the complete one (LatencyUpload.partialDue).
//
// (slow events): every action over 250 ms (LatencyEvent.thresholdMs) is also kept one by one, at most
// 200 a day, the slowest kept: its phases (a click: queue / handler / render; an agent open: sheet / first_frame /
// settled), the longest main-thread block inside it (`stall`, from a CFRunLoopObserver on the main run loop that exists
// only while the probe is on), the app's conditions at that moment (LatencyCtx: enumerated values and buckets only) and
// the factor LatencyCause blames. A click is now timed to the main thread going to sleep after the frame was committed
// (the observer's beforeWaiting, after Core Animation's commit), so its render counts; before, it ended at the first
// main-queue pass after the click.

@MainActor
final class LatencyProbe {
    static let shared = LatencyProbe()
    /// On only for a canary member. Read by every hook before anything else (main thread only; written there too).
    nonisolated(unsafe) private(set) static var enabled = false

    private var member: String?
    private var auth: AuthStore?
    private var monitor: Any?
    private var day = LatencyDay(day: LiaDay.key(Date()))
    private var dirty = false
    private var saveJob: Task<Void, Never>?
    private var terminateObserver: NSObjectProtocol?
    private var resignObserver: NSObjectProtocol?
    /// Today's partial sends: something recorded since the last one, when it went, the 30-minute clock.
    private var recordedSincePartial = false
    private var partialSentAt: TimeInterval?
    private var partialJob: Task<Void, Never>?
    private var partialSending = false
    /// The last click that may open something (systemUptime of its event), for `.latencyAppear`.
    private var lastClick: TimeInterval?
    /// Set by a button style or a tap hook while the current click is dispatched: the click hit a control of ours.
    private var tapMarked = false
    private var begun: [String: TimeInterval] = [:]
    /// The main run loop's observer (only while on), when the current pass woke, the long passes, the clicks waiting
    /// for the main thread to go to sleep after their frame.
    private var loopObserver: CFRunLoopObserver?
    private var wakeAt: TimeInterval = 0
    private var spans = LatencySpans()
    private var idleWaiters: [(TimeInterval) -> Void] = []
    /// Action ids (and agent) measured since launch, for `first_since_launch`.
    private var seen: Set<String> = []
    /// On battery, read at most once a minute (IOKit).
    private var batteryAt: TimeInterval = -1_000
    private var battery: Bool?

    private init() {}

    nonisolated private static var now: TimeInterval { ProcessInfo.processInfo.systemUptime }

    /// The hooks are called from view code; whatever isolation the SDK gives it, the work runs on the main actor.
    nonisolated private static func onMain(_ f: @escaping @MainActor () -> Void) {
        if Thread.isMainThread { MainActor.assumeIsolated(f) } else { DispatchQueue.main.async { f() } }
    }

    // MARK: switching on

    /// Asks the server once per launch and account; the last answer is used at once so the first clicks count.
    static func configure(auth: AuthStore) {
        let p = shared
        guard let m = auth.activeId, m != p.member || p.auth !== auth else { return }
        p.stop()
        p.member = m
        p.auth = auth
        let cacheKey = "lia_latency_on_" + m
        if UserDefaults.standard.bool(forKey: cacheKey) { p.start() }
        Task { @MainActor in
            guard let on = await LiaAPI(auth: auth).latencyCanary(), p.member == m else { return }
            UserDefaults.standard.set(on, forKey: cacheKey)
            if on { p.start(); await p.uploadDue() } else { p.stop() }
        }
    }

    private func start() {
        guard !Self.enabled, let m = member else { return }
        Self.enabled = true
        day = load(m, LiaDay.key(Date())) ?? LatencyDay(day: LiaDay.key(Date()))
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseUp]) { [weak self] e in
            MainActor.assumeIsolated { self?.mouseUp(e) }
            return e
        }
        terminateObserver = NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.save() }
        }
        // The app going to the background (another app in front, hidden): today so far goes now.
        resignObserver = NotificationCenter.default.addObserver(forName: NSApplication.didResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.sendToday(leaving: true) }
        }
        installLoopObserver()
        partialJob = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(LatencyUpload.partialEvery * 1_000_000_000))
                guard !Task.isCancelled else { return }
                self?.sendToday(leaving: false)
            }
        }
    }

    private func stop() {
        if Self.enabled { save() }
        Self.enabled = false
        if let m = monitor { NSEvent.removeMonitor(m) }
        monitor = nil
        if let o = terminateObserver { NotificationCenter.default.removeObserver(o) }
        terminateObserver = nil
        if let o = resignObserver { NotificationCenter.default.removeObserver(o) }
        resignObserver = nil
        partialJob?.cancel(); partialJob = nil
        saveJob?.cancel(); saveJob = nil
        begun = [:]; lastClick = nil
        removeLoopObserver()
    }

    // MARK: the main run loop

    /// Each pass of the main run loop from waking (afterWaiting) to going to sleep (beforeWaiting) is one block of the
    /// main thread; the passes of 16 ms or more are kept (LatencySpans). The highest order, so beforeWaiting comes
    /// after Core Animation's commit: that is when a click's frame is done. Only while the probe is on.
    private func installLoopObserver() {
        guard loopObserver == nil else { return }
        wakeAt = Self.now
        let acts = CFRunLoopActivity.afterWaiting.rawValue | CFRunLoopActivity.beforeWaiting.rawValue
        guard let o = CFRunLoopObserverCreateWithHandler(kCFAllocatorDefault, acts, true, CFIndex.max, { [weak self] _, activity in
            MainActor.assumeIsolated { self?.loopActivity(activity) }
        }) else { return }
        CFRunLoopAddObserver(CFRunLoopGetMain(), o, .commonModes)
        loopObserver = o
    }

    private func removeLoopObserver() {
        if let o = loopObserver {
            CFRunLoopRemoveObserver(CFRunLoopGetMain(), o, .commonModes)
            CFRunLoopObserverInvalidate(o)
        }
        loopObserver = nil
        let w = idleWaiters
        idleWaiters = []
        let t = Self.now
        for f in w { f(t) }
        spans = LatencySpans()
    }

    private func loopActivity(_ a: CFRunLoopActivity) {
        let t = Self.now
        if a.contains(.afterWaiting) { wakeAt = t; return }
        guard a.contains(.beforeWaiting) else { return }
        spans.add(start: wakeAt, end: t)
        wakeAt = t
        guard !idleWaiters.isEmpty else { return }
        let w = idleWaiters
        idleWaiters = []
        for f in w { f(t) }
    }

    /// Runs `f` with the time the main thread next goes to sleep (now, without the observer).
    private func whenIdle(_ f: @escaping (TimeInterval) -> Void) {
        guard loopObserver != nil else { f(Self.now); return }
        if idleWaiters.count >= 16 { idleWaiters.removeFirst() }
        idleWaiters.append(f)
    }

    // MARK: the API

    /// Starts a measurement of `id` now (for an action that is not a click, or whose result shows later).
    nonisolated static func begin(_ id: String) {
        guard enabled else { return }
        let t = now
        onMain { shared.begun[id] = t }
    }

    /// Ends `id`'s measurement: recorded when it began less than 10 s ago.
    nonisolated static func end(_ id: String) {
        guard enabled else { return }
        let t = now
        onMain {
            guard let t0 = shared.begun.removeValue(forKey: id) else { return }
            let ms = (t - t0) * 1000
            if ms >= 0, ms < 10_000, let c = LatencyID.clean(id) { shared.record(c, ms: ms, window: (t0, t)) }
        }
    }

    /// A measurement taken elsewhere (the dock's agent opens time themselves from the click event: AgentOpenTrace).
    /// An `agent_open:*` id only counts here; its slow event comes from `agentOpen` with the phases.
    nonisolated static func record(_ id: String, ms: Double) {
        guard enabled else { return }
        onMain {
            guard ms >= 0, ms < 10_000, let c = LatencyID.clean(id) else { return }
            shared.record(c, ms: ms, event: !c.hasPrefix("agent_open:"))
        }
    }

    /// An agent open that settled (AgentOpenTrace): its slow event, when over the threshold, with the phases as
    /// segments (click -> sheet, sheet -> first frame, first frame -> settled) and the thread's conditions. The
    /// histogram already has the number (`record`).
    static func agentOpen(dlg: String, kept: Bool, rows: Int, click: TimeInterval, sheet: TimeInterval?, first: TimeInterval?,
                          settled: TimeInterval) {
        guard enabled else { return }
        let ms = (settled - click) * 1000
        guard ms >= 0, ms < 10_000 else { return }
        let id = kept ? "agent_open:kept:settled" : "agent_open:cold:settled"
        var phases: [String: Double] = [:]
        if let s = sheet { phases["sheet"] = max(0, s - click) * 1000 }
        if let f = first {
            phases["first_frame"] = max(0, f - (sheet ?? click)) * 1000
            phases["settled"] = max(0, settled - f) * 1000
        }
        shared.slowEvent(id, ms: ms, phases: phases, window: (click, settled), agent: LatencyBucket.agent(dlg),
                         thread: kept ? "kept" : "cold", rows: rows)
    }

    /// A control of ours took the click being dispatched (the button styles, `.clickable`, `.liaClicks`).
    nonisolated static func markTap() {
        guard enabled else { return }
        onMain { shared.tapMarked = true }
    }

    /// Something a click opens appeared: "open:<name>", from that click, once.
    nonisolated static func appeared(_ name: String) {
        guard enabled else { return }
        let t = now
        onMain {
            guard let t0 = shared.lastClick else { return }
            shared.lastClick = nil
            let ms = (t - t0) * 1000
            guard ms >= 0, ms < 5_000, let id = LatencyID.clean("open:" + name) else { return }
            shared.record(id, ms: ms, window: (t0, t))
        }
    }

    // MARK: clicks

    private func mouseUp(_ e: NSEvent) {
        guard Self.enabled, let win = e.window else { return }
        // Inside a web page: not our button (and the accessibility tree there is another process).
        if let v = win.contentView?.hitTest(e.locationInWindow), Self.inWebView(v) { return }
        let t0 = e.timestamp
        // our handler starts here: the time since the event's own timestamp is the queue (the main thread was busy)
        let hStart = Self.now
        // Review 0.2.11: the accessibility hit test is the probe's own work, not the click's. It must run here, before
        // the click is dispatched (after it, a sheet or a replaced button would be what is under the pointer and the
        // id would be wrong), so its own time is taken off the measurement instead of being counted as the button's.
        let h0 = Self.now
        let found = Self.actionId(in: win, at: win.convertPoint(toScreen: e.locationInWindow))
        let probeCost = Self.now - h0
        tapMarked = false
        lastClick = t0 + probeCost
        DispatchQueue.main.async { [weak self] in
            let t1 = Self.now
            guard let self, Self.enabled else { return }
            let confirmed = self.tapMarked || found?.control == true
            self.tapMarked = false
            guard confirmed, let id = found?.id else { return }
            // the frame: until the main thread goes to sleep after Core Animation's commit (the run-loop observer)
            self.whenIdle { [weak self] tFree in
                guard let self, Self.enabled else { return }
                let queue = max(0, hStart - t0), handler = max(0, t1 - hStart - probeCost), render = max(0, tFree - t1)
                let ms = (queue + handler + render) * 1000
                guard ms < 10_000 else { return }
                self.record(id, ms: ms, phases: ["queue": queue * 1000, "handler": handler * 1000, "render": render * 1000],
                            window: (t0, tFree))
            }
        }
    }

    private static func inWebView(_ v: NSView) -> Bool {
        var cur: NSView? = v
        var n = 0
        while let c = cur, n < 40 {
            if String(describing: type(of: c)).contains("WKWebView") || String(describing: type(of: c)).hasPrefix("WK") { return true }
            cur = c.superview; n += 1
        }
        return false
    }

    private static let controlRoles: Set<String> = ["AXButton", "AXLink", "AXCheckBox", "AXRadioButton", "AXMenuItem",
                                                    "AXMenuButton", "AXPopUpButton", "AXDisclosureTriangle", "AXTab", "AXSwitch", "AXToggle"]

    /// The clicked element's id: an explicit `.latencyID` up the chain wins; else the label of the first control
    /// (button, link, ...) up the chain (`control` true); else the deepest label (counted only if a tap hook fires).
    private static func actionId(in win: NSWindow, at point: NSPoint) -> (id: String, control: Bool)? {
        guard let hit = win.accessibilityHitTest(point) else { return nil }
        var el = hit as AnyObject
        var deepest: String?
        for _ in 0..<10 {
            if let ident = ax(el, "accessibilityIdentifier"), ident.hasPrefix(latencyPrefix),
               let id = LatencyID.clean(String(ident.dropFirst(latencyPrefix.count))) { return (id, true) }
            let label = ax(el, "accessibilityLabel") ?? ax(el, "accessibilityTitle")
            if deepest == nil, let l = label, let c = LatencyID.clean(l) { deepest = c }
            if deepest == nil, let v = ax(el, "accessibilityValue"), let c = LatencyID.clean(v) { deepest = c }
            if let role = ax(el, "accessibilityRole"), controlRoles.contains(role) {
                if let l = label, let c = LatencyID.clean(l) { return (c, true) }
                if let d = deepest { return (d, true) }
            }
            guard let parent = axObject(el, "accessibilityParent"), !(parent is NSWindow) else { break }
            el = parent
        }
        // Not a control: a `.clickable` / `.liaClicks` view, counted only when its tap hook fires. Its label may be
        // content (a message, a title, a name). Since the upload is on for every member none of it goes into
        // the id: such a view is "tap" unless it sets `.latencyID`.
        return deepest.map { _ in ("tap", false) }
    }

    nonisolated static let latencyPrefix = "lat:"

    private static func ax(_ o: AnyObject, _ sel: String) -> String? {
        guard let obj = o as? NSObject else { return nil }
        let s = NSSelectorFromString(sel)
        guard obj.responds(to: s), let r = obj.perform(s)?.takeUnretainedValue() else { return nil }
        return (r as? String).flatMap { $0.isEmpty ? nil : $0 }
    }

    private static func axObject(_ o: AnyObject, _ sel: String) -> AnyObject? {
        guard let obj = o as? NSObject else { return nil }
        let s = NSSelectorFromString(sel)
        guard obj.responds(to: s), let r = obj.perform(s)?.takeUnretainedValue() else { return nil }
        return r as AnyObject
    }

    // MARK: the day

    /// One measurement into the day's histogram, and its slow event when over the threshold (`event`).
    private func record(_ id: String, ms: Double, phases: [String: Double] = [:], window: (TimeInterval, TimeInterval)? = nil,
                        event: Bool = true) {
        rollDay()
        day.add(id, ms: ms)
        let first = seen.insert(id).inserted
        if event { slowEvent(id, ms: ms, phases: phases, window: window, first: first) }
        changed()
    }

    private func rollDay() {
        let today = LiaDay.key(Date())
        guard today != day.day else { return }
        save()
        day = LatencyDay(day: today)
        Task { @MainActor in await self.uploadDue() }
    }

    /// Keeps the action as an event when it was slow: phases, the longest block in its window, conditions, cause.
    private func slowEvent(_ id: String, ms: Double, phases: [String: Double], window: (TimeInterval, TimeInterval)?,
                           agent: String? = nil, thread: String? = nil, rows: Int? = nil, first: Bool? = nil) {
        guard LatencyEvent.isSlow(id, ms: ms) else {
            if let a = agent { seen.insert(id + "|" + a) }
            return
        }
        rollDay()
        var ph = phases
        if let w = window, loopObserver != nil { ph["stall"] = spans.longest(from: w.0, to: w.1, open: wakeAt) }
        let isFirst = first ?? seen.insert(id + "|" + (agent ?? "")).inserted
        let ctx = context(agent: agent, thread: thread, rows: rows, first: isFirst)
        day.addEvent(LatencyEvent.make(id: id, ms: ms, at: Date(), phases: ph, ctx: ctx))
        changed()
    }

    /// The app's conditions now: cheap reads only, enumerated values and buckets (never a title, URL or name).
    private func context(agent: String?, thread: String?, rows: Int?, first: Bool) -> LatencyCtx {
        var c = LatencyCtx()
        c.agent = agent
        c.thread = thread
        c.rows = rows.map { LatencyBucket.rows($0) }
        c.firstSinceLaunch = first
        c.uptime = LatencyBucket.uptime(Self.appUptime)
        if let ws = WorkspaceModel.current {
            c.busy = !ws.working.isEmpty
            var tabs = 0, loading = 0
            for b in ws.openBrowsers.values {
                for t in b.tabs {
                    tabs += 1
                    if t.isLoading { loading += 1 }
                }
            }
            c.tabs = LatencyBucket.count(tabs)
            c.loading = loading
        }
        c.windows = NSApp.windows.filter { $0.isVisible }.count
        let pi = ProcessInfo.processInfo
        c.lowPower = pi.isLowPowerModeEnabled
        c.thermal = Self.thermalName(pi.thermalState)
        c.memMb = Self.footprint().map { LatencyBucket.memory(bytes: $0) }
        let now = Self.now
        if now - batteryAt > 60 { battery = Self.onBattery(); batteryAt = now }
        c.onBattery = battery
        return c
    }

    private static var appUptime: TimeInterval {
        NSRunningApplication.current.launchDate.map { Date().timeIntervalSince($0) } ?? ProcessInfo.processInfo.systemUptime
    }

    private static func thermalName(_ s: ProcessInfo.ThermalState) -> String {
        switch s {
        case .nominal: return "nominal"
        case .fair: return "fair"
        case .serious: return "serious"
        case .critical: return "critical"
        @unknown default: return "other"
        }
    }

    /// The app's own phys_footprint (what Activity Monitor calls Memory), from task_info TASK_VM_INFO.
    private static func footprint() -> UInt64? {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let kr = withUnsafeMutablePointer(to: &info) { p in
            p.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count) }
        }
        return kr == KERN_SUCCESS ? info.phys_footprint : nil
    }

    /// The Mac runs on its battery now (IOKit power sources); nil when it cannot be read.
    private static func onBattery() -> Bool? {
        guard let snap = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let type = IOPSGetProvidingPowerSourceType(snap)?.takeUnretainedValue() else { return nil }
        return (type as String) == "Battery Power"
    }

    private func changed() {
        dirty = true
        recordedSincePartial = true
        if saveJob == nil {
            saveJob = Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: 60_000_000_000)
                self?.saveJob = nil
                self?.save()
            }
        }
    }

    private static var folder: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("Liaison/Latency", isDirectory: true)
    }

    private func dir(_ m: String) -> URL { Self.folder.appendingPathComponent(m.filter { $0.isLetter || $0.isNumber || $0 == "_" || $0 == "-" }, isDirectory: true) }

    private func load(_ m: String, _ key: String) -> LatencyDay? {
        guard let d = try? Data(contentsOf: dir(m).appendingPathComponent(key + ".json")) else { return nil }
        return try? JSONDecoder().decode(LatencyDay.self, from: d)
    }

    private func save() {
        guard dirty, let m = member else { return }
        dirty = false
        let d = dir(m)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(day) { try? data.write(to: d.appendingPathComponent(day.day + ".json"), options: .atomic) }
        prune(d)
    }

    /// Files older than 30 days go.
    private func prune(_ d: URL) {
        let cut = LiaDay.key(daysBefore: 30, Date())
        for f in (try? FileManager.default.contentsOfDirectory(atPath: d.path)) ?? [] where f.hasSuffix(".json") && String(f.dropLast(5)) < cut {
            try? FileManager.default.removeItem(at: d.appendingPathComponent(f))
        }
    }

    /// Today's aggregate so far (LatencyUpload.partialDue). Saved first, so the file and the server agree; the day is
    /// not marked sent (its complete version goes once it is over).
    private func sendToday(leaving: Bool) {
        guard Self.enabled, !partialSending, let auth else { return }
        let now = Self.now
        guard LatencyUpload.partialDue(recordedSince: recordedSincePartial, leaving: leaving, lastSent: partialSentAt, now: now),
              !day.actions.isEmpty else { return }
        save()
        let snapshot = day
        recordedSincePartial = false
        partialSending = true
        Task { @MainActor [weak self] in
            let ok = await LiaAPI(auth: auth).latencyUpload(snapshot.payload(client: LiaClient.current))
            guard let self else { return }
            self.partialSending = false
            if ok { self.partialSentAt = Self.now } else { self.recordedSincePartial = true }
        }
    }

    /// Sends each finished day not sent yet (one POST per day), and remembers what went.
    private func uploadDue() async {
        guard Self.enabled, let m = member, let auth else { return }
        let sentKey = "lia_latency_sent_" + m
        var sent = Set(UserDefaults.standard.stringArray(forKey: sentKey) ?? [])
        let stored = ((try? FileManager.default.contentsOfDirectory(atPath: dir(m).path)) ?? [])
            .filter { $0.hasSuffix(".json") }.map { String($0.dropLast(5)) }
        let today = LiaDay.key(Date())
        for key in LatencyUpload.due(stored: stored, uploaded: sent, today: today) {
            guard let d = load(m, key), !d.actions.isEmpty else { sent.insert(key); continue }
            guard await LiaAPI(auth: auth).latencyUpload(d.payload(client: LiaClient.current)) else { break }
            sent.insert(key)
        }
        let cut = LiaDay.key(daysBefore: 31, Date())
        UserDefaults.standard.set(sent.filter { $0 >= cut }.sorted(), forKey: sentKey)
    }
}

// MARK: - hooks for views

extension View {
    /// The latency action id of this control (instead of its accessibility label). Sets the accessibility identifier
    /// "lat:<id>"; use it where the label changes with the content (a count, a name) or is empty (an icon).
    func latencyID(_ id: String) -> some View {
        accessibilityIdentifier(LatencyProbe.latencyPrefix + id)
    }

    /// A sheet, popup or panel a click opens: its first appearance ends that click's "open:<name>" measurement.
    func latencyAppear(_ name: String) -> some View {
        onAppear { LatencyProbe.appeared(name) }
    }
}

/// The button styles' hook: a release of a pressed button marks the click as one of ours (canary only).
struct LatencyPressMark: ViewModifier {
    let isPressed: Bool
    func body(content: Content) -> some View {
        content.onChange(of: isPressed) { _, pressed in
            if !pressed { LatencyProbe.markTap() }
        }
    }
}
