import SwiftUI
import AppKit
import CoreGraphics

// 0.2.11: Screen Time, like the iPhone's, only in our browser. The person sees which sites, agents
// and parts of Liaison he spends his time in (Settings > Screen Time). LOCAL ONLY: the ledger is a file on this Mac
// per Liaison account (Application Support/Liaison/ScreenTime/<account>.json, 30 days); no log or upload ever
// carries it.: a rounded summary (top sites/features, minutes) goes with turns to Lia unless the person turned
// that off (LiaContext, App/Workspace/LiaContextMac.swift). The pure rules (domain, clock, ledger, summaries) are Shared/Core/ScreenTime.swift.
//
// Every 10 s: what is in front. Counted only while the app is active, a workspace (or Settings) window is key, the
// screen is not locked or asleep, and the person touched the mouse or keyboard within the last 60 s. A private
// window is never counted.
// Site: the registrable domain of the selected tab, while the page is what is in front (Browser or Notes beside it)
// Agent: the conversation open over the browser ("team" or the agent's id)
// Feature: Settings (its window key) > Notes (the panel open) > Chats (a conversation open) > Home (a new tab) >
// Browser
@MainActor
final class ScreenTimeTracker: ObservableObject {
    static let shared = ScreenTimeTracker()
    static let onKey = "lia_screentime_on"
    static let tickSeconds: TimeInterval = 10

    @Published private(set) var ledger = ScreenTimeLedger()
    @Published var isOn: Bool = UserDefaults.standard.object(forKey: ScreenTimeTracker.onKey) as? Bool ?? true {
        didSet {
            UserDefaults.standard.set(isOn, forKey: Self.onKey)
            if !isOn { pause() }
        }
    }
    private(set) var account: String?
    private var clock = ScreenTimeClock(maxGap: ScreenTimeTracker.tickSeconds * 3)
    private var timer: Timer?
    private var locked = false
    private var observers: [(NotificationCenter, NSObjectProtocol)] = []
    private var dirty = false
    private var lastSave = Date()

    private init() {}

    /// Starts (once) and follows the Liaison account in front: each account has its own ledger.
    func start(account: String?) {
        let a = account ?? "_"
        if a != self.account {
            _ = pause()
            save()
            self.account = a
            ledger = load(a)
            ledger.prune(now: Date())
        }
        guard timer == nil else { return }
        let t = Timer(timeInterval: Self.tickSeconds, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        t.tolerance = 2
        RunLoop.main.add(t, forMode: .common)
        timer = t
        let dnc = DistributedNotificationCenter.default()
        observe(dnc, "com.apple.screenIsLocked") { $0.locked = true; $0.pause() }
        observe(dnc, "com.apple.screenIsUnlocked") { $0.locked = false }
        let wnc = NSWorkspace.shared.notificationCenter
        observe(wnc, NSWorkspace.screensDidSleepNotification.rawValue) { $0.locked = true; $0.pause() }
        observe(wnc, NSWorkspace.screensDidWakeNotification.rawValue) { $0.locked = false }
        observe(wnc, NSWorkspace.willSleepNotification.rawValue) { $0.pause(); $0.save() }
        observe(wnc, NSWorkspace.sessionDidResignActiveNotification.rawValue) { $0.locked = true; $0.pause() }
        observe(wnc, NSWorkspace.sessionDidBecomeActiveNotification.rawValue) { $0.locked = false }
        let nc = NotificationCenter.default
        observe(nc, NSApplication.didResignActiveNotification.rawValue) { $0.pause() }
        observe(nc, NSApplication.willTerminateNotification.rawValue) { $0.pause(); $0.save() }
    }

    private func observe(_ center: NotificationCenter, _ name: String, _ f: @escaping @MainActor (ScreenTimeTracker) -> Void) {
        let o = center.addObserver(forName: Notification.Name(name), object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { if let self { f(self) } }
        }
        observers.append((center, o))
    }

    /// Forgets every day of this account (Settings > Screen Time > Clear).
    func clear() {
        _ = clock.pause(now: Date())
        ledger = ScreenTimeLedger()
        dirty = false
        if let a = account { try? FileManager.default.removeItem(at: file(a)) }
    }

    // MARK: counting

    private func tick() {
        let now = Date()
        guard isOn else { return }
        var idle = CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: CGEventType(rawValue: ~0)!)
        // Watching a video or a film (any site) is activity: no idle pause while the tab in front plays
        if WorkspaceModel.current?.currentBrowser?.selected?.playing == true { idle = 0 }
        if let r = clock.tick(now: now, sample: sample(), idle: idle) { add(r) }
        if dirty, now.timeIntervalSince(lastSave) >= 60 { save() }
    }

    @discardableResult
    private func pause() -> Bool {
        guard let r = clock.pause(now: Date()) else { return false }
        add(r)
        return true
    }

    private func add(_ r: (from: Date, to: Date, sample: ScreenTimeSample)) {
        guard isOn else { return }
        ledger.add(from: r.from, to: r.to, sample: r.sample)
        dirty = true
    }

    /// What is in front now.
    private func sample() -> ScreenTimeSample {
        guard NSApp.isActive, !locked, let key = NSApp.keyWindow else { return .inactive }
        let ident = key.identifier?.rawValue ?? ""
        if ident == "lia-settings" { return ScreenTimeSample(active: true, feature: .settings, site: nil, agent: nil) }
        if ident.hasPrefix("private") { return .inactive }
        guard let ws = WorkspaceModel.current else { return .inactive }
        let tab = ws.currentBrowser?.selected
        let agent = ws.sheet
        let feature: ScreenTimeFeature
        if WSExtras.shared.notesOpen { feature = .notes }
        else if agent != nil { feature = .chats }
        else if tab == nil || tab?.isStart == true { feature = .home }
        else { feature = .browser }
        let site = (feature == .browser || feature == .notes) && tab?.isStart == false ? ScreenTimeDomain.registrable(tab?.url) : nil
        return ScreenTimeSample(active: true, feature: feature, site: site, agent: agent)
    }

    // MARK: the file

    private static var folder: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("Liaison/ScreenTime", isDirectory: true)
    }

    private func file(_ account: String) -> URL {
        let safe = account.filter { $0.isLetter || $0.isNumber || $0 == "_" || $0 == "-" }
        return Self.folder.appendingPathComponent((safe.isEmpty ? "_" : safe) + ".json")
    }

    private func load(_ account: String) -> ScreenTimeLedger {
        guard let d = try? Data(contentsOf: file(account)), let l = try? JSONDecoder().decode(ScreenTimeLedger.self, from: d) else { return ScreenTimeLedger() }
        return l
    }

    func save() {
        lastSave = Date()
        guard dirty, let a = account else { return }
        dirty = false
        ledger.prune(now: Date())
        try? FileManager.default.createDirectory(at: Self.folder, withIntermediateDirectories: true)
        if let d = try? JSONEncoder().encode(ledger) { try? d.write(to: file(a), options: .atomic) }
    }
}
