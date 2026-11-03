import SwiftUI
import AppKit

/// The person's GitHub connection (our GitHub App "liaisone"), one for the app: Settings > Integrations > GitHub and
/// each workspace's Repositories read the same state. Connect, Manage on GitHub and Choose more on GitHub open
/// GitHub in a small window of ours over the app (WebPopupWindow,: in the default browser - often
/// Liaison itself - the page landed under the workspace settings popup). Its web view uses the workspace browser's
/// data store (MetaConnect.storeKey), so a person signed in to GitHub in the browser is signed in there too. The
/// window closes itself once our callback page (lia.liaisone.com/agents/github/callback) has loaded, and the status
/// is read again at once; it is also read every 3 s for up to 3 minutes after Connect (GitHubPoll) and when the
/// window closes by hand.
@MainActor
final class GitHubLink: ObservableObject {
    static let shared = GitHubLink()

    /// nil: not read yet for this Liaison account.
    @Published private(set) var status: GitHubStatus?
    /// Connect was clicked and GitHub has not answered yet.
    @Published private(set) var pending = false
    @Published private(set) var busy = false
    @Published var error: String?
    /// The repositories the app can reach (nil: not read yet).
    @Published private(set) var repos: [GitHubRepo]?
    @Published private(set) var reposLoading = false
    @Published private(set) var reposError: String?

    /// The Liaison account the state above belongs to; another one starts from nothing.
    private var account: String?
    private var auth: AuthStore?
    private var poll: Task<Void, Never>?
    /// The GitHub window open now (connect or manage); one at a time.
    private var popup: WebPopupWindow?
    /// The window reached our callback page (GitHub answered), as against closed by hand.
    private var sawCallback = false
    private var observer: NSObjectProtocol?

    private init() {
        // A singleton, never released: no capture to weaken.
        observer = NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { _ in
            Task { @MainActor in await GitHubLink.shared.becameActive() }
        }
    }

    private func use(_ auth: AuthStore) {
        self.auth = auth
        guard auth.activeId != account else { return }
        account = auth.activeId
        cancel()
        status = nil
        repos = nil
        reposLoading = false
        reposError = nil
        error = nil
    }

    func refresh(_ auth: AuthStore) async {
        use(auth)
        let acct = account
        guard let s = await LiaAPI(auth: auth).githubStatus(), acct == account else { return }
        status = s
        if s.connected, pending { cancel() }
        if !s.connected { repos = nil }
    }

    /// Opens GitHub's install / sign-in page in a window over the app and waits for the answer.
    func connect(_ auth: AuthStore) async {
        use(auth)
        error = nil
        busy = true
        defer { busy = false }
        do {
            let url = try await LiaAPI(auth: auth).githubStartURL()
            openWindow(url, auth: auth, title: "Connect GitHub", connecting: true)
            pending = true
            startPolling(auth)
        } catch {
            self.error = userMessage(for: error)
        }
    }

    /// Our server's page after GitHub (installed, updated or refused): the window has done its job.
    static func isCallback(_ url: URL) -> Bool {
        guard let host = url.host?.lowercased(), host == URL(string: AppConfig.agentsBase)?.host?.lowercased() else { return false }
        return url.path.hasPrefix("/agents/github/callback")
    }

    /// GitHub in a window of ours (PopupPlacement: above the workspace settings popup, Settings and sheets).
    /// Closed by the callback or by hand, the status is read again; after Manage, the repositories too.
    private func openWindow(_ url: URL, auth: AuthStore, title: String, connecting: Bool) {
        if let old = popup { old.onClose = nil; old.close() }   // replaced: its close says nothing
        popup = nil
        sawCallback = false
        let key = MetaConnect.storeKey(auth: auth, ws: WorkspaceModel.current)
        let p = WebPopupWindow.show(url, configuration: BrowserModel.configuration(account: key), title: title)
        p.onLoaded = { u in
            guard GitHubLink.isCallback(u) else { return false }
            GitHubLink.shared.sawCallback = true
            // The callback stores nothing; this app finishes the connect with its own session
            if let f = GitHubFinish.params(u) { Task { @MainActor in await GitHubLink.shared.finish(auth, state: f.state, code: f.code) } }
            return true
        }
        p.onClose = { [weak p] in
            let link = GitHubLink.shared
            if let p, link.popup === p { link.popup = nil }
            Task { @MainActor in await link.returned(auth, connecting: connecting) }
        }
        popup = p
    }

    /// The GitHub window closed: read the status now; a connect that did not land stops waiting.
    private func returned(_ auth: AuthStore, connecting: Bool) async {
        let answered = sawCallback
        sawCallback = false
        await refresh(auth)
        let connected = status?.connected == true
        if connecting {
            cancel()
            // Closed by hand is not a failure; GitHub's answer without a connection is.
            if answered, status != nil, !connected, error == nil { error = "GitHub did not connect. Try again." }
        } else if connected, repos != nil {
            await loadRepos(auth, force: true)
        }
    }

    /// GitHub's answer, finished with this Liaison session. Another GitHub account than the connected one is
    /// replaced only after the person says yes.
    func finish(_ auth: AuthStore, state: String, code: String) async {
        use(auth)
        error = nil
        busy = true
        defer { busy = false }
        await apply(await LiaAPI(auth: auth).githubFinish(state: state, code: code), auth: auth)
    }

    /// liaison://github/connect?state=&code= - the callback page was opened in another browser.
    func finishLink(_ url: URL, auth: AuthStore) async {
        guard let f = GitHubFinish.params(url) else { return }
        await finish(auth, state: f.state, code: f.code)
    }

    private func apply(_ answer: GitHubFinish, auth: AuthStore) async {
        switch answer {
        case .connected(let s):
            status = s
            cancel()
            if repos != nil { await loadRepos(auth, force: true) }
        case .confirm(let login, let current):
            let a = NSAlert()
            a.messageText = "Replace the GitHub account?"
            a.informativeText = "Liaison is connected to GitHub as \(current ?? "another account"). Connect \(login) instead? Dev then works with \(login)'s repositories."
            a.addButton(withTitle: "Replace")
            a.addButton(withTitle: "Cancel")
            if a.runModal() == .alertFirstButtonReturn {
                await apply(await LiaAPI(auth: auth).githubFinishConfirm(), auth: auth)
            } else {
                cancel()
                await refresh(auth)
            }
        case .failed(let message):
            error = message
            cancel()
        }
    }

    /// Stops waiting (the Cancel link, a switch of account, connected).
    func cancel() {
        poll?.cancel()
        poll = nil
        pending = false
    }

    private func startPolling(_ auth: AuthStore) {
        poll?.cancel()
        let started = Date()
        poll = Task {
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(GitHubPoll.interval * 1_000_000_000))
                if Task.isCancelled { return }
                await self.refresh(auth)
                if Task.isCancelled { return }
                if !GitHubPoll.shouldContinue(started: started, now: Date(), connected: self.status?.connected == true) {
                    self.poll = nil
                    self.pending = false
                    return
                }
            }
        }
    }

    private func becameActive() async {
        guard let auth else { return }
        if pending { await refresh(auth) }
    }

    /// Forgets the connection on our side; the app itself is removed on GitHub (Manage on GitHub).
    func disconnect(_ auth: AuthStore) async {
        use(auth)
        error = nil
        busy = true
        defer { busy = false }
        do {
            let manage = try await LiaAPI(auth: auth).githubDisconnect()
            status = GitHubStatus(connected: false, login: nil, avatar: nil, installations: [], manageURL: manage ?? status?.manageURL)
            repos = nil
            await refresh(auth)
        } catch {
            self.error = userMessage(for: error)
        }
    }

    func loadRepos(_ auth: AuthStore, force: Bool = false) async {
        use(auth)
        if reposLoading || (repos != nil && !force) { return }
        reposLoading = true
        reposError = nil
        let acct = account
        defer { if acct == account { reposLoading = false } }
        do {
            let list = try await LiaAPI(auth: auth).githubRepos()
            guard acct == account else { return }
            repos = list
        } catch {
            guard acct == account else { return }
            reposError = userMessage(for: error)
        }
    }

    /// The app's settings on GitHub (which accounts and repositories it can reach), in a window over the app.
    func openManage() {
        guard let u = status?.manageURL, let auth else { return }
        openWindow(u, auth: auth, title: "GitHub", connecting: false)
    }
}
