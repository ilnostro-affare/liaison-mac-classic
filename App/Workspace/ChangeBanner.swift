import SwiftUI
import Combine
import WebKit

// After an agent's write reaches Meta (the person's Yes), the person's own Ads Manager tabs still show the old
// state. Those tabs get a small banner ("Met changed 2 things · Reload"); when the tab reloads or moves inside
// Ads Manager, ChangeTour walks through where each change is. Nothing here touches the page: the page is only
// read (agentWorld) and, for the tour, scrolled to the row.

/// One write that was applied, as the conversation saw it.
struct AppliedChange: Identifiable {
    let id = UUID()
    let agent: String
    /// The company profile the conversation belongs to (resolves the browser and, when `accountId` is nil, the account).
    var profile: String?
    var accountId: String?
    var entityId: String?
    var entityType: String?
    let title: String
    let diff: [GateDiffRow]
    let at: Date
}

extension Notification.Name {
    /// Posted when a write to Meta was applied. userInfo: "change" (AppliedChange).
    static let liaWriteApplied = Notification.Name("lia.ws.writeApplied")
}

/// One stop of the tour: a change, and one of its rows (nil: the change has no rows).
struct ChangeTourStep: Identifiable {
    let id = UUID()
    let change: AppliedChange
    let row: GateDiffRow?
}

/// The tour that is showing.
struct ChangeTourRun {
    let tabID: UUID
    weak var tab: BrowserTab?
    let steps: [ChangeTourStep]
    var index = 0
    /// Where the current step is, in window coordinates (top-left origin); nil: not found (card centred).
    var rect: CGRect?
    var located = false
}

/// Pending changes per tab of the person's browser, the banner's state and the tour's.
@MainActor
final class ChangeCenter: ObservableObject {
    static let shared = ChangeCenter()

    /// Changes the tab does not show yet.
    @Published private(set) var pending: [UUID: [AppliedChange]] = [:]
    /// Tabs that moved while changes were pending: the banner is gone, the tour starts once the page settles.
    @Published private(set) var armed: Set<UUID> = []
    @Published private(set) var tour: ChangeTourRun?

    private weak var ws: WorkspaceModel?
    private var tabs: [UUID: WeakTab] = [:]
    private var subs: [UUID: [AnyCancellable]] = [:]
    private var observer: NSObjectProtocol?
    private var monitor: Any?
    private var locateTask: Task<Void, Never>?

    private struct WeakTab { weak var tab: BrowserTab? }

    private init() {
        observer = NotificationCenter.default.addObserver(forName: .liaWriteApplied, object: nil, queue: .main) { [weak self] n in
            guard let c = n.userInfo?["change"] as? AppliedChange else { return }
            MainActor.assumeIsolated { self?.receive(c) }
        }
    }

    func attach(_ ws: WorkspaceModel) { self.ws = ws }

    func showsBanner(_ id: UUID) -> Bool { !(pending[id] ?? []).isEmpty && !armed.contains(id) }

    static func isAdsManager(_ url: URL?) -> Bool {
        guard let url, let host = url.host?.lowercased(), host == "facebook.com" || host.hasSuffix(".facebook.com") else { return false }
        return host.hasPrefix("adsmanager.") || url.path.lowercased().hasPrefix("/adsmanager")
    }

    // MARK: - changes in

    private func receive(_ c: AppliedChange) {
        prune()
        guard let ws else { return }
        guard let pid = c.profile ?? ws.profileId, let browser = ws.openBrowsers[pid] else { return }
        let account = c.accountId ?? ws.profiles.first(where: { $0.id == pid })?.metaAccount
        let hits = browser.tabs.filter { t in
            guard Self.isAdsManager(t.url) else { return false }
            guard let a = account, let act = AdsManagerAccount.of(t.url) else { return true }
            return act == a
        }
        for t in hits {
            pending[t.id, default: []].append(c)
            tabs[t.id] = WeakTab(tab: t)
            if subs[t.id] == nil { watch(t) }
        }
    }

    private func watch(_ tab: BrowserTab) {
        let id = tab.id
        // @Published sends before the value is stored: read the tab on the next turn of the run loop.
        let u = tab.$url.removeDuplicates().dropFirst().receive(on: RunLoop.main).sink { [weak self, weak tab] _ in
            guard let self, let tab else { return }
            self.moved(tab)
        }
        let l = tab.$isLoading.removeDuplicates().dropFirst().receive(on: RunLoop.main).sink { [weak self, weak tab] loading in
            guard let self, let tab else { return }
            if loading { self.moved(tab) } else { self.settle(tab) }
        }
        subs[id] = [u, l]
    }

    /// The tab reloaded or navigated (the person's own move, or Reload on the banner).
    private func moved(_ tab: BrowserTab) {
        guard !(pending[tab.id] ?? []).isEmpty else { return }
        guard Self.isAdsManager(tab.url) else { clear(tab.id); return }
        armed.insert(tab.id)
        // A move inside Ads Manager (pushState) loads nothing: settle without waiting for isLoading.
        if !tab.isLoading { settle(tab) }
    }

    private func settle(_ tab: BrowserTab) {
        guard armed.contains(tab.id) else { return }
        let id = tab.id
        Task { @MainActor [weak self] in
            // Ads Manager draws its table after the load ends.
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            guard let self, let t = self.tabs[id]?.tab, !t.isLoading else { return }
            self.tryStart(t)
        }
    }

    /// The tab's page card is on screen (StageTab): an armed tour can start now.
    func shown(_ tab: BrowserTab) {
        guard armed.contains(tab.id), !tab.isLoading else { return }
        tryStart(tab)
    }

    private func tryStart(_ tab: BrowserTab) {
        guard armed.contains(tab.id), tour == nil, let ws, !ws.touring else { return }
        guard Self.isAdsManager(tab.url) else { clear(tab.id); return }
        // Only over the tab the person is looking at; a background tab waits until it is shown.
        guard ws.currentBrowser?.selected?.id == tab.id else { return }
        let changes = pending[tab.id] ?? []
        clear(tab.id)
        let steps = changes.flatMap { c -> [ChangeTourStep] in
            let rows = c.diff.filter { !$0.label.isEmpty && $0.label != "Estimated audience" }
            return rows.isEmpty ? [ChangeTourStep(change: c, row: nil)] : rows.map { ChangeTourStep(change: c, row: $0) }
        }
        guard !steps.isEmpty else { return }
        tour = ChangeTourRun(tabID: tab.id, tab: tab, steps: steps)
        install()
        locateCurrent()
    }

    /// The banner's Reload: the person asked to see the new state, so no tour follows.
    func reload(_ tab: BrowserTab) {
        clear(tab.id)
        tab.reload()
    }

    private func clear(_ id: UUID) {
        pending[id] = nil
        armed.remove(id)
        subs[id] = nil
        tabs[id] = nil
    }

    private func prune() {
        for (id, w) in tabs where w.tab == nil { clear(id) }
    }

    // MARK: - the tour

    func go(_ delta: Int) {
        guard var run = tour else { return }
        let next = run.index + delta
        guard run.steps.indices.contains(next) else { return }
        run.index = next
        run.rect = nil
        run.located = false
        tour = run
        locateCurrent()
    }

    func close() {
        locateTask?.cancel()
        locateTask = nil
        tour = nil
        if let m = monitor { NSEvent.removeMonitor(m) }
        monitor = nil
    }

    private func locateCurrent() {
        locateTask?.cancel()
        guard let run = tour, let web = run.tab?.loadedWebView, run.steps.indices.contains(run.index) else {
            tour?.located = true
            return
        }
        let step = run.steps[run.index], index = run.index
        locateTask = Task { @MainActor [weak self] in
            let css = await ChangeLocate.find(name: step.change.title, id: step.change.entityId, label: step.row?.label, in: web)
            guard let self, !Task.isCancelled, self.tour?.index == index else { return }
            self.tour?.rect = css.flatMap { ChangeLocate.windowRect($0, in: web) }
            self.tour?.located = true
        }
    }

    /// Esc closes, the arrow keys step; everything else goes on to the window.
    private func install() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] e in
            let used = MainActor.assumeIsolated { self?.key(e) ?? false }
            return used ? nil : e
        }
    }

    private func key(_ e: NSEvent) -> Bool {
        guard tour != nil, e.window?.isKeyWindow == true else { return false }
        switch e.keyCode {
        case 53: close(); return true
        case 123: go(-1); return true
        case 124: go(1); return true
        default: return false
        }
    }
}

// MARK: - banner

/// The small glass banner at the top of an Ads Manager tab that does not show an agent's change yet.
struct ChangeBanner: View {
    @ObservedObject var tab: BrowserTab
    @ObservedObject var ws: WorkspaceModel
    @ObservedObject private var center = ChangeCenter.shared
    @Environment(\.accessibilityReduceMotion) private var reduce

    var body: some View {
        ZStack(alignment: .top) {
            if center.showsBanner(tab.id) {
                banner(center.pending[tab.id] ?? [])
                    .padding(.top, 10)
                    .transition(reduce ? AnyTransition.opacity : AnyTransition.move(edge: .top).combined(with: .opacity))
            }
        }
        .animation(reduce ? nil : WSMotion.navigation(false), value: center.showsBanner(tab.id))
        .onAppear { center.shown(tab) }
    }

    private func banner(_ changes: [AppliedChange]) -> some View {
        let ids = changes.reduce(into: [String]()) { r, c in if !r.contains(c.agent) { r.append(c.agent) } }
        let names = ids.map { ws.agent($0)?.name ?? $0.capitalized }
        let count = changes.reduce(0) { n, c in n + max(1, c.diff.filter { !$0.label.isEmpty && $0.label != "Estimated audience" }.count) }
        let who = names.count > 1 ? names.dropLast().joined(separator: ", ") + " and " + (names.last ?? "") : (names.first ?? "An agent")
        let text = who + " changed \(count) thing" + (count == 1 ? "" : "s")
        return HStack(spacing: 8) {
            if let a = ws.agent(ids.first) { AgentAvatar(agent: a, size: 20) }
            Text(text)
                .font(LiaFont.ui(12.5, .medium))
                .foregroundStyle(WS.ink)
                .lineLimit(1)
            Text("\u{00b7}").font(LiaFont.ui(12.5)).foregroundStyle(WS.text3)
            Button("Reload") { center.reload(tab) }
                .buttonStyle(.liaPlain)
                .font(LiaFont.ui(12.5, .semibold))
                .foregroundStyle(WS.blue)
        }
        .padding(.horizontal, 12)
        .frame(height: 34)
        .wsGlass(17)
        .shadow(color: Color.black.opacity(0.10), radius: 10, y: 4)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(text + ". Reload")
    }
}
