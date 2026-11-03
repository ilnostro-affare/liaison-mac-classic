import SwiftUI
import AppKit
import Sparkle

/// Sparkle, started only when the build carries a feed and a public key (release builds). A dev or CI build
/// has neither and never checks, so it cannot show an update error to someone running it.
///
/// A new release downloads quietly in the background.
/// Checks run at launch, on wake from sleep, when the app comes back to the front, every
/// hour (Sparkle) and on our own 15-minute timer. When the download is done, UpdatePolicy decides: at a moment the
/// person is not working (just launched, just woke the Mac, came back after 30+ minutes, or away from the Mac 15+
/// minutes) and nothing would be lost (AppBusy: no agent run, no change waiting for a Yes, no unsent text, no other
/// run) the app installs and relaunches by itself. Otherwise the update waits and says so: a banner in the window
/// (Restart / Later), a row in the inbox, a Home card, and a system notification while the app is in the
/// background. Quitting the app installs it too (Sparkle's install on quit). Restart while something runs asks first.
@MainActor
final class Updates: NSObject, ObservableObject, SPUUpdaterDelegate {
    static let shared = Updates()
    private var controller: SPUStandardUpdaterController?
    @Published private(set) var canCheck = false
    /// The version downloaded and waiting, shown on the card; nil when there is nothing to install.
    @Published private(set) var readyVersion: String?
    @Published private(set) var installing = false
    /// The window's banner (hidden by Later for `UpdatePolicy.laterSnooze`, per version).
    @Published private(set) var bannerShown = false
    /// The inbox's row has not been seen yet (the bell's badge counts it).
    @Published private(set) var inboxUnseen = false
    private var installNow: (() -> Void)?
    private var observers: [NSObjectProtocol] = []
    private var timer: Timer?
    private var lastBackgroundCheck = Date.distantPast
    private let launchedAt = Date()
    private var wokeAt: Date?
    private var returnedAt: Date?
    private var resignedAt: Date?

    private static let snoozeVersionKey = "lia_update_later_version"
    private static let snoozeUntilKey = "lia_update_later_until"
    private static let notifiedKey = "lia_update_notified_version"

    var configured: Bool {
        let feed = Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") as? String ?? ""
        let key = Bundle.main.object(forInfoDictionaryKey: "SUPublicEDKey") as? String ?? ""
        return feed.hasPrefix("https://") && !key.isEmpty
    }

    func start() {
        guard controller == nil, configured else { return }
        let c = SPUStandardUpdaterController(startingUpdater: false, updaterDelegate: self, userDriverDelegate: nil)
        controller = c
        let u = c.updater
        u.automaticallyChecksForUpdates = true
        u.automaticallyDownloadsUpdates = true
        u.updateCheckInterval = UpdatePolicy.checkInterval
        // The appcast request says which build asks, like every request to our hosts. updates.example.com is a
        // public R2 bucket with no worker, so nothing reads it yet; Sparkle's own User-Agent already carries the version.
        u.httpHeaders = [LiaClient.header: LiaClient.current]
        c.startUpdater()
        canCheck = u.canCheckForUpdates
        // At launch: an update downloaded in an earlier run comes back through willInstallUpdateOnQuit at once and
        // installs inside the launch grace; a new one downloads now.
        u.checkForUpdatesInBackground()
        lastBackgroundCheck = Date()

        let nc = NotificationCenter.default
        observers.append(nc.addObserver(forName: NSApplication.didResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.resignedAt = Date() }
        })
        observers.append(nc.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.becameActive() }
        })
        observers.append(NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.woke() }
        })
        timer = Timer.scheduledTimer(withTimeInterval: UpdatePolicy.recheckInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        timer?.tolerance = 60
    }

    /// The menu's "Check for Updates\u{2026}": Sparkle's own window, as macOS users expect from that item.
    func check() { controller?.checkForUpdates(nil) }

    /// Restart (banner, Home card, inbox row, Settings): install what was downloaded and relaunch, after a
    /// confirmation when an agent runs, a change waits for a Yes or a message is not sent.
    func installAndRelaunch() {
        guard installNow != nil, !installing else { return }
        let busy = AppBusy.shared.snapshot
        guard UpdatePolicy.needsConfirm(busy) else { install(); return }
        let a = NSAlert()
        a.messageText = "Restart to update Liaison?"
        a.informativeText = UpdatePolicy.confirmText(busy)
        a.addButton(withTitle: "Restart")
        a.addButton(withTitle: "Cancel")
        if let w = NSApp.keyWindow ?? NSApp.mainWindow {
            a.beginSheetModal(for: w) { r in
                if r == .alertFirstButtonReturn { Task { @MainActor in self.install() } }
            }
        } else if a.runModal() == .alertFirstButtonReturn {
            install()
        }
    }

    /// The banner's Later: hides it for a few hours for this version (the Home card and the inbox row stay).
    func later() {
        guard let v = readyVersion else { return }
        let d = UserDefaults.standard
        d.set(v, forKey: Self.snoozeVersionKey)
        d.set(Date().addingTimeInterval(UpdatePolicy.laterSnooze).timeIntervalSince1970, forKey: Self.snoozeUntilKey)
        withAnimation(.easeOut(duration: 0.2)) { bannerShown = false }
    }

    /// The inbox was opened.
    func markInboxSeen() { if inboxUnseen { inboxUnseen = false } }

    private func install() {
        guard let installNow, !installing else { return }
        installing = true
        installNow()
    }

    // MARK: moments

    private func becameActive() {
        let away = resignedAt.map { Date().timeIntervalSince($0) } ?? 0
        if UpdatePolicy.isReturn(backgroundFor: away) {
            returnedAt = Date()
            evaluate(.reactivated)
        } else {
            refreshBanner()
        }
        checkQuietly(minGap: UpdatePolicy.activeCheckGap)
    }

    private func woke() {
        wokeAt = Date()
        evaluate(.wake)
        // The network comes back a few seconds after the lid opens.
        DispatchQueue.main.asyncAfter(deadline: .now() + 20) { [weak self] in self?.checkQuietly(minGap: 0) }
    }

    private func tick() {
        if readyVersion != nil { evaluate(.timer) }
        // Sparkle's own hourly schedule can slip after a sleep; this keeps a release within the hour.
        checkQuietly(minGap: UpdatePolicy.checkInterval)
    }

    private func checkQuietly(minGap: TimeInterval) {
        guard let u = controller?.updater, readyVersion == nil, !u.sessionInProgress,
              Date().timeIntervalSince(lastBackgroundCheck) >= minGap else { return }
        lastBackgroundCheck = Date()
        u.checkForUpdatesInBackground()
    }

    /// Ask the policy whether to relaunch now; otherwise tell the person.
    private func evaluate(_ moment: UpdatePolicy.Moment) {
        guard let v = readyVersion, installNow != nil, !installing else { return }
        let now = Date()
        let ctx = UpdatePolicy.Context(moment: moment, busy: AppBusy.shared.snapshot,
                                       sinceLaunch: now.timeIntervalSince(launchedAt),
                                       sinceWake: wokeAt.map { now.timeIntervalSince($0) },
                                       sinceReactivation: returnedAt.map { now.timeIntervalSince($0) },
                                       systemIdle: AppBusy.systemIdle, appActive: NSApp.isActive)
        switch UpdatePolicy.decide(ctx) {
        case .installNow:
            install()
        case .notify(let system):
            refreshBanner()
            let d = UserDefaults.standard
            if system, UpdatePolicy.shouldPostSystem(version: v, alreadyPosted: d.string(forKey: Self.notifiedKey), appActive: NSApp.isActive) {
                d.set(v, forKey: Self.notifiedKey)
                Notifier.postUpdate(version: v)
            }
        }
    }

    private func refreshBanner() {
        let d = UserDefaults.standard
        let until = d.object(forKey: Self.snoozeUntilKey) as? Double
        let show = UpdatePolicy.bannerVisible(ready: readyVersion, snoozedVersion: d.string(forKey: Self.snoozeVersionKey),
                                              snoozedUntil: until.map { Date(timeIntervalSince1970: $0) }, now: Date())
        if show != bannerShown { withAnimation(.easeOut(duration: 0.2)) { bannerShown = show } }
    }

    // MARK: SPUUpdaterDelegate

    /// The update is downloaded and would install when the app quits; we keep the handle that installs it now.
    nonisolated func updater(_ updater: SPUUpdater, willInstallUpdateOnQuit item: SUAppcastItem,
                             immediateInstallationBlock immediateInstallHandler: @escaping () -> Void) -> Bool {
        let version = item.displayVersionString
        Task { @MainActor in
            self.installNow = immediateInstallHandler
            let fresh = self.readyVersion != version
            withAnimation(.easeOut(duration: 0.2)) { self.readyVersion = version }
            if fresh { self.inboxUnseen = true }
            self.evaluate(.ready)
        }
        return true
    }

    /// An install that did not go through: the card's Restart works again.
    nonisolated func updater(_ updater: SPUUpdater, didAbortWithError error: Error) {
        Task { @MainActor in self.installing = false }
    }
}

/// The banner at the top of the window while an update waits: "Liaison 1.2 is ready" Restart / Later.
/// Non-modal; shows in WorkspaceWindow's notice layer.
struct UpdateBanner: View {
    @ObservedObject var updates = Updates.shared

    var body: some View {
        if updates.bannerShown, let v = updates.readyVersion {
            HStack(spacing: 10) {
                Image(systemName: "arrow.down.circle.fill").font(.system(size: 15, weight: .medium)).foregroundStyle(WS.blue)
                Text("Liaison \(v) is ready").font(LiaFont.ui(13, .medium)).foregroundStyle(WS.ink).lineLimit(1)
                Button(updates.installing ? "Updating\u{2026}" : "Restart") { updates.installAndRelaunch() }
                    .buttonStyle(WSButtonStyle(primary: true, small: true))
                    .disabled(updates.installing)
                Button("Later") { updates.later() }
                    .buttonStyle(WSButtonStyle(small: true))
                    .disabled(updates.installing)
            }
            .padding(.leading, 14).padding(.trailing, 8).frame(height: 44)
            .background(WS.surface, in: Capsule())
            .overlay(Capsule().stroke(WS.line2, lineWidth: 1))
            .shadow(color: Color.black.opacity(0.10), radius: 14, y: 6)
            .transition(.move(edge: .top).combined(with: .opacity))
            .accessibilityElement(children: .contain)
            .accessibilityLabel(Text("Liaison \(v) is ready to install"))
        }
    }
}

/// Home's card while an update waits (WorkspaceHome, under the brief line).
struct UpdateHomeCard: View {
    @ObservedObject var updates = Updates.shared

    var body: some View {
        if let v = updates.readyVersion {
            HStack(alignment: .center, spacing: 12) {
                Image(systemName: "arrow.down.circle.fill").font(.system(size: 22, weight: .medium)).foregroundStyle(WS.blue)
                VStack(alignment: .leading, spacing: 2) {
                    Text("A new update is out: Liaison \(v)").font(LiaFont.ui(14, .semibold)).foregroundStyle(WS.ink)
                    Text("Restart to use it. Your conversations and tabs come back as they were.")
                        .font(LiaFont.ui(12.5)).foregroundStyle(WS.text2).lineLimit(2)
                }
                Spacer(minLength: 8)
                Button(updates.installing ? "Updating\u{2026}" : "Restart") { updates.installAndRelaunch() }
                    .buttonStyle(WSButtonStyle(primary: true, small: true))
                    .disabled(updates.installing)
            }
            .padding(14)
            .frame(maxWidth: 640)
            .homeGlass(RoundedRectangle(cornerRadius: 16, style: .continuous))
            .transition(.opacity)
        }
    }
}

/// The inbox's first row while an update waits (DockInboxFeed). `unseen` badges the bell.
struct UpdateInboxRow: View {
    @ObservedObject var updates = Updates.shared

    var body: some View {
        if let v = updates.readyVersion {
            Button { updates.installAndRelaunch() } label: {
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: "arrow.down.circle.fill").font(.system(size: 22, weight: .medium)).foregroundStyle(WS.blue)
                        .frame(width: 28, height: 28)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Liaison").font(LiaFont.ui(12, .semibold)).foregroundStyle(WS.ink)
                        Text("Restart, a new update is out").font(LiaFont.ui(13, .semibold)).foregroundStyle(WS.ink)
                        Text(updates.installing ? "Updating\u{2026}" : "Version \(v) is downloaded. Click to restart.")
                            .font(LiaFont.ui(12)).foregroundStyle(WS.text2).lineLimit(2)
                    }
                    Spacer(minLength: 0)
                }
                .padding(8)
                .contentShape(Rectangle())
            }
            .buttonStyle(.liaPlain)
            .liaHover(.fill, radius: 10)
            .disabled(updates.installing)
            .accessibilityLabel(Text("Liaison \(v) is ready, restart to update"))
            .onAppear { updates.markInboxSeen() }
        }
    }
}

/// The row in the sidebar's footer when a downloaded update is waiting.
struct UpdateReadyCard: View {
    @ObservedObject var updates = Updates.shared
    @State private var hover = false

    /// One row in the footer, over the account: the whole row
    /// installs and relaunches; the version is its tooltip.
    var body: some View {
        if let v = updates.readyVersion {
            Button { updates.installAndRelaunch() } label: {
                HStack(spacing: 8) {
                    Text(updates.installing ? "Updating\u{2026}" : "Relaunch to update")
                        .font(LiaFont.ui(13, .medium)).foregroundStyle(AppConfig.ink).lineLimit(1)
                    Spacer(minLength: 6)
                    if updates.installing { ProgressView().controlSize(.small).scaleEffect(0.7).frame(width: 14, height: 14) }
                    else { LiaIcon("arrow-right", size: 14).foregroundStyle(AppConfig.text3) }
                }
                .padding(.horizontal, 10).frame(height: 34)
                .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(hover ? AppConfig.surface3 : AppConfig.surface2))
                .contentShape(Rectangle())
            }
            .buttonStyle(.liaPlain)
            .liaHover(.pointer, isHovered: $hover)
            .disabled(updates.installing)
            .liaTip("Liaison \(v) is ready")
            .padding(.bottom, 4)
            .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }
}
