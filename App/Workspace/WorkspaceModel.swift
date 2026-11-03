import SwiftUI
import WebKit

/// The new workspace. A browser with a team of agents:
/// A company profile (one ad client) is a browser profile: its own tab group, its own cookies (one
/// WKWebsiteDataStore per profile, BrowserModel keyed by CompanyProfile.browserKey), its own agents and chats;
/// Ads Manager opens on the profile's account, and moving to another account in Ads Manager switches to the
/// profile that owns it, so two clients never meet in one browser;
/// Every agent has its own browser in the profile (same cookies, its own tabs) and can read the person's tabs;
/// Lia leads the team chat;: every agent has one endless dialogue per workspace (no threads, no groups).
@MainActor
final class WorkspaceModel: ObservableObject {
    let auth: AuthStore
    @Published var roster: [AgentInfo] = AgentInfo.fallback
    /// Agent id -> name, for reading "@Name" in a message (DlgMention).
    var agentNames: [String: String] { Dictionary(roster.map { ($0.id, $0.name) }, uniquingKeysWith: { a, _ in a }) }
    @Published private(set) var profiles: [CompanyProfile] = []
    @Published private(set) var profileId: String?
    /// The workspace's dialogues: Team first, then the roster (GET /agents/dialogues).
    @Published private(set) var dialogues: [DialogueSummary] = []
    /// The dialogue open over the browser ("team" or an agent id). Opening or closing one marks it read.
    @Published var sheet: String? {
        didSet {
            if let o = oldValue { markSeen(o) }
            if let n = sheet { markSeen(n) }
            // The open conversation comes back after a restart.
            if booted, let p = profileId { UserDefaults.standard.set(sheet, forKey: "lia_ws_sheet_" + p) }
        }
    }
    /// The profile being edited (nil: none), and the one asked to delete.
    @Published var editingProfile: CompanyProfile?
    @Published var confirmDelete: CompanyProfile?
    /// Bumped by \u{2318}L: the selected tab becomes the address field.
    @Published var addressFocus = 0
    @Published var showJournal = false
    @Published var showNewProfile = false
    @Published private(set) var booted = false
    @Published var errorText: String?
    @Published private(set) var adAccounts: [AdAccount] = []
    /// Agents busy right now (working in a run or in their browser), and the ones waiting for the person.
    @Published private(set) var working: Set<String> = []
    @Published private(set) var waiting: Set<String> = []

    private var browsers: [String: BrowserModel] = [:]
    private var chats: [String: TeamChatModel] = [:]

    // MARK: toasts, approvals, reconnect, menus

    /// The window in front, for the menu bar's commands (WorkspaceCommands).
    static weak var current: WorkspaceModel?

    /// A short glass pill at the top for events that need no action: 3 s, a click hides it.
    struct Toast: Identifiable, Equatable { let id = UUID(); let text: String; var symbol: String? = nil }
    @Published var toast: Toast?
    func show(_ text: String, symbol: String? = nil) {
        let t = Toast(text: text, symbol: symbol)
        toast = t
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 3_200_000_000)
            if self?.toast?.id == t.id { self?.toast = nil }
        }
    }

    /// Workspaces made by the app this launch: their pill appears with a short highlight.
    @Published private(set) var freshProfiles: Set<String> = []
    /// Meta stopped answering for this member (token expired or revoked): the banner asks to reconnect.
    @Published var metaNeedsReconnect = false
    /// GET /meta/status as read last (the account menu, the app coming back, a disconnect in Settings); nil: not read.
    @Published private(set) var meta: MetaConnection?
    /// Meta is connected and its token is good (nil: not read yet).
    var metaLive: Bool? { meta.map { $0.connected && !$0.expired } }
    /// Reads Meta's state again. Expired asks to reconnect; connected again after it was not makes the workspaces.
    func refreshMeta() async {
        guard let m = await LiaAPI(auth: auth).metaConnection() else { return }
        let was = metaLive
        meta = m
        if m.expired { metaNeedsReconnect = true }
        if was == false, metaLive == true {
            metaNeedsReconnect = false
            await reloadAccounts()
        }
    }
    private var activeObserver: NSObjectProtocol?

    /// The person said "I don't use Meta" in the welcome: one workspace without an ad account is made when there is
    /// none. Kept under lia_ws_ so Start over clears it. Per Liaison account (an added account inherited
    /// the first one's answer and got a workspace without Meta it never asked for); the old app-wide key is read for
    /// the account that was signed in when it was written, the first time only.
    @Published var worksWithoutMeta = false {
        didSet {
            if worksWithoutMeta { UserDefaults.standard.set(true, forKey: withoutMetaKey) }
            else { UserDefaults.standard.removeObject(forKey: withoutMetaKey) }
        }
    }
    private var withoutMetaKey: String { "lia_ws_without_meta_" + (auth.activeId ?? "_") }
    private static let legacyWithoutMetaKey = "lia_ws_without_meta"
    /// The welcome's "I don't use Meta": a workspace without Meta is made if there is none.
    func continueWithoutMeta() async {
        worksWithoutMeta = true
        if booted { await reloadAccounts() }
    }

    /// Agents that need a Meta ad account: locked in a workspace without one (the server answers needs_meta).
    /// Seara, Crea and Dev (sites, its own sandbox) work without one and are never listed here.
    static let metaAgents: Set<String> = ["met", "rep", "giggs"]   // rep and giggs are retired; kept for old dialogues
    /// 12: locked only while the workspace in front has no ad account added.
    func isLocked(_ agentId: String) -> Bool {
        guard let p = profile, p.metaAccounts.isEmpty else { return false }
        return Self.metaAgents.contains(agentId)
    }
    /// Meta connected (or its ad accounts read): a locked agent leads to the workspace's Ad accounts, not to Settings.
    var metaConnected: Bool { metaLive == true || !adAccounts.isEmpty }
    /// A locked agent's click: Meta connected opens the workspace settings on Ad accounts (true); false means the
    /// caller opens Settings \u{203a} Meta.
    func openLockedTarget() -> Bool {
        guard metaConnected, let p = profile else { return false }
        settingsFocus = "accounts"
        editingProfile = p
        return true
    }
    /// The section the workspace settings open on ("accounts": the ad account picker opens); read once by the sheet.
    @Published var settingsFocus: String?
    /// The member's main ad account (Settings), read at boot: preselected where accounts are picked.
    @Published private(set) var mainAccount: String?
    /// The find bar over the page and the downloads popover.
    @Published var findOpen = false
    /// \u{2318}G / \u{2318}\u{21E7}G from the menu: bumped, the find bar steps to the next (or previous) match.
    @Published var findAgain = 0
    var findAgainBackwards = false
    func findStep(backwards: Bool) { findAgainBackwards = backwards; if findOpen { findAgain += 1 } else { findOpen = true } }
    /// \u{2318}F: opens the find bar, or (already open) gives it the keys back with its text selected.
    @Published var findFocus = 0
    func openFind() { if findOpen { findFocus += 1 } else { findOpen = true } }
    @Published var showDownloads = false
    /// The approvals popover in the top bar.
    @Published var showApprovals = false
    /// \u{2318}K command palette and \u{2318}\u{21E7}A tab search across workspaces: one palette, two modes.
    enum PaletteMode { case commands, tabs }
    @Published var palette: PaletteMode?
    /// \u{2303}Tab cycles tabs in the order they were last used while \u{2303} is held; the index into
    /// `currentBrowser.recentTabs` (nil: the switcher is closed). Releasing \u{2303} picks it (the window's monitor).
    @Published var switcher: Int?
    func mruStep(_ forward: Bool) {
        let n = currentBrowser?.recentTabs.count ?? 0
        guard n > 1 else { return }
        let cur = switcher ?? 0
        switcher = (cur + (forward ? 1 : n - 1)) % n
    }
    func mruCommit() {
        if let i = switcher, let b = currentBrowser, b.recentTabs.indices.contains(i) { b.selectedID = b.recentTabs[i].id }
        switcher = nil
    }
    /// File > Import from Another Browser (again, any time).
    @Published var showImport = false
    /// \u{2318}Y the history window.
    @Published var showHistory = false
    /// The morning tour: on while it runs.
    @Published var touring = false

    /// \u{2318}/ the keyboard shortcuts sheet.
    @Published var showShortcuts = false
    /// A link opened in Peek over the page: \u{21E7}-click, or "Open in Peek".
    @Published var peek: URL?
    /// \u{2318}F while a conversation is open searches the conversation: bumped, the sheet opens its search.
    @Published var chatFind = 0
    /// First launch: the welcome shows until the person starts.
    /// Per account (AccountPrefs): set in init from the account in front.
    @Published var onboarding = false
    func finishOnboarding() { AccountPrefsSync.markOnboarded(member: auth.activeId); onboarding = false }

    /// Every change waiting for a Yes, in every workspace.
    struct PendingApproval: Identifiable { let id: String; let profileId: String?; let profileName: String; let agent: String; let title: String }
    var approvals: [PendingApproval] {
        chats.values.compactMap { c -> PendingApproval? in
            guard let g = c.openGate else { return nil }
            let p = profiles.first { $0.id == c.profile }
            let (title, _) = FeedText.split(g.item.message.content)
            return PendingApproval(id: c.key, profileId: c.profile, profileName: p?.name ?? "", agent: g.item.agent ?? "met",
                                   title: title.isEmpty ? "A change to approve" : title)
        }
    }

    /// Opens a waiting approval, switching to its workspace first.
    func openApproval(_ a: PendingApproval) {
        showApprovals = false
        openDialogue(key: a.id)
    }

    /// A tab moves to another workspace (its page opens there, with that client's sign-ins).
    func moveTab(_ tab: BrowserTab, from b: BrowserModel, to pid: String) {
        guard let u = tab.savedURL, let p = profiles.first(where: { $0.id == pid }) else { return }
        b.remove(tab)
        select(pid)
        browser(for: p).open(u)
        show("Moved to \(p.name)", symbol: "arrow.right.square")
    }

    /// \u{2318}E / the page menu: the team's conversation opens with the page's address in the
    /// composer and the selected text as a quoted chip; nothing goes until the person presses Send.
    func askAboutSelection() {
        guard let t = currentBrowser?.selected else { return }
        Task { @MainActor in
            let sel = await t.selectedText().trimmingCharacters(in: .whitespacesAndNewlines)
            let where_ = t.url?.absoluteString ?? ""
            if sel.isEmpty {
                draft("Look at this page: \(where_)", toAgent: "lia")
            } else {
                let host = t.url?.host ?? "the page"
                draft("About this, from \(where_):", toAgent: "lia", quote: ChatForwardDraft.Draft(who: host, agent: nil, text: sel))
            }
        }
    }

    /// A dialogue from anywhere (a notification, the menu bar), in its own workspace. `key` is "profile|dlg" (a
    /// chat's `key`) or a bare dlg of the workspace in front.
    func openDialogue(key: String) {
        let parts = key.split(separator: "|", maxSplits: 1).map(String.init)
        guard parts.count == 2 else { openDialogue(key); return }
        if parts[0] != profileId, profiles.contains(where: { $0.id == parts[0] }) { select(parts[0]) }
        guard parts[0] == profileId else { return }
        sheet = parts[1]
    }

    /// \u{2303}\u{2325}\u{2192} / \u{2303}\u{2325}\u{2190}: the next or previous workspace.
    func selectNextProfile(_ forward: Bool) {
        guard let cur = profileId, let i = profiles.firstIndex(where: { $0.id == cur }), profiles.count > 1 else { return }
        select(profiles[(i + (forward ? 1 : profiles.count - 1)) % profiles.count].id)
    }

    /// The direction of the last switch, for the slide: true = to the right.
    @Published private(set) var switchForward = true

    init(auth: AuthStore) {
        self.auth = auth
        // The welcome and the role are this account's (a new or added account gets the welcome)
        onboarding = !AccountPrefsSync.activate(member: auth.activeId)
        profileId = UserDefaults.standard.string(forKey: profileKey)
        let d = UserDefaults.standard
        if d.object(forKey: Self.legacyWithoutMetaKey) != nil {
            // the app-wide answer belongs to the account in front when this version first runs
            if d.bool(forKey: Self.legacyWithoutMetaKey) { d.set(true, forKey: "lia_ws_without_meta_" + (auth.activeId ?? "_")) }
            d.removeObject(forKey: Self.legacyWithoutMetaKey)
        }
        worksWithoutMeta = d.bool(forKey: withoutMetaKey)
        // 0.2.10: the team as the server listed it last for this account (Dev for a flagged member), so the dock's
        // first frame is the real one; boot refreshes it quietly.
        if let r = RosterCache.decode(d.data(forKey: RosterCache.key(account: auth.activeId))) { roster = r }
        Self.current = self
        Notifier.setUp()
        ScreenTimeTracker.shared.start(account: auth.activeId)   // 0.2.11: Screen Time, local only, per account
        LatencyProbe.configure(auth: auth)                        // 0.2.11: click latency, canary members only (server flag)
        // Back in the app (from Meta's sign-in in the browser, or after a while): Meta's state is read again.
        activeObserver = NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in await self?.refreshMeta() }
        }
    }

    deinit { if let o = activeObserver { NotificationCenter.default.removeObserver(o) } }

    private var profileKey: String { "lia_ws_profile_" + (auth.activeId ?? "_") }
    var profile: CompanyProfile? { profiles.first { $0.id == profileId } }
    func agent(_ id: String?) -> AgentInfo? { roster.first { $0.id == id } }
    func dialogue(_ dlg: String) -> DialogueSummary? { dialogues.first { $0.dlg == dlg } }
    /// Every dialogue of the workspace, Team first: the server's list, then any roster agent it did not list yet.
    var dialogueIds: [String] {
        var out = ["team"]
        for d in dialogues where !out.contains(d.dlg) { out.append(d.dlg) }
        for a in roster where !a.lead && !out.contains(a.id) { out.append(a.id) }
        return out
    }
    /// The display name of a dialogue: "Lia" (the team chat, Lia leads) or the agent's name.
    func dialogueTitle(_ dlg: String) -> String {
        dlg == "team" ? "Lia" : (agent(dlg)?.name ?? DlgOrigin.displayName(dlg))
    }

    func status(of agent: String) -> AgentStatus {
        if waiting.contains(agent) { return .waiting }
        return working.contains(agent) ? .working : .idle
    }

    // MARK: - boot and profiles

    /// Meta was connected after the launch (the welcome's Meta step): boot again so its ad accounts are read now.
    func reloadAccounts() async {
        guard booted, !reloading else { return }
        reloading = true
        defer { reloading = false }
        booted = false
        await boot()
    }
    private var reloading = false

    func boot() async {
        guard !booted else { return }
        let api = LiaAPI(auth: auth)
        if let r = await api.agentsRoster() {
            if r != roster { roster = r }   // unchanged: no republish, no dock relayout
            if let data = RosterCache.encode(r) { UserDefaults.standard.set(data, forKey: RosterCache.key(account: auth.activeId)) }
        }
        var all: [CompanyProfile] = []
        var loadedProfiles = false
        do { all = try await api.agentProfiles(); loadedProfiles = true } catch { errorText = userMessage(for: error) }
        do {
            adAccounts = try await api.adAccounts().filter { !$0.blocked }
        } catch {
            // A Meta token that expired or was revoked shows as a banner, not as missing workspaces.
            let t = String(describing: error).lowercased()
            metaNeedsReconnect = ["token", "expired", "oauth", "reconnect", "permission"].contains { t.contains($0) }
        }
        let main = CompanyProfile.digits(await api.defaultAccountId())
        mainAccount = main
        // 12: the workspace is the base and ad accounts are added to it by the person. No workspace per
        // ad account any more; one "Main" when there is none, and the welcome adds every account the person picks to
        // it (meta_accounts, up to 20). Only after a real list: a failed load is not "no workspaces". (Builds before
        // Made one empty workspace per ad account; the server archives those, .)
        if loadedProfiles, all.isEmpty {
            var o: [String: Any] = ["name": "Main", "color": String(format: "#%06X", CompanyProfile.palette[0])]
            // Past the welcome (Start over aside): the main account goes in, so the agents are not locked.
            if !onboarding, let m = main, let a = adAccounts.first(where: { CompanyProfile.digits($0.id) == m }) {
                o["meta_accounts"] = CompanyProfile.accountsBody([(m, a.name)])
                o["meta_account"] = m; o["meta_account_name"] = a.name
            }
            if let r = try? await api.agentProfileOp(["op": "create", "profile": o]),
               let j = r["profile"] as? JSONObject, let p = CompanyProfile(json: j) { all.append(p) }
        }
        // Every workspace shows, whatever ad accounts Meta lists now. The one with the main account first.
        func hasMain(_ p: CompanyProfile) -> Bool { main.map { m in p.metaAccounts.contains(where: { $0.id == m }) } ?? false }
        var shown = all
        shown.sort { a, b in
            if hasMain(a) != hasMain(b) { return hasMain(a) }
            return a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
        }
        profiles = shown
        // Every launch opens the main account's workspace (Settings), not the one used last.
        if let mp = profiles.first(where: hasMain) {
            profileId = mp.id
            UserDefaults.standard.set(mp.id, forKey: profileKey)
        } else if profileId == nil || !profiles.contains(where: { $0.id == profileId }) {
            profileId = profiles.first?.id
        }
        booted = true
        if let p = profile { _ = browser(for: p) }
        await loadDialogues()
        if let p = profileId, let id = UserDefaults.standard.string(forKey: "lia_ws_sheet_" + p), dialogueIds.contains(id), !onboarding { sheet = id }
        if CrashNotice.previousRunCrashed {
            CrashNotice.previousRunCrashed = false
            show("Liaison closed unexpectedly. Your tabs and conversations are back.", symbol: "arrow.counterclockwise")
        }
        startRefresh()
    }

    /// Dialogues refresh every 45 s while the window lives: an agent that wrote first (Rep's reports) shows up.
    private var refresh: Task<Void, Never>?
    private func startRefresh() {
        refresh?.cancel()
        refresh = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 45_000_000_000)
                guard let self, !Task.isCancelled else { return }
                if self.working.isEmpty { await self.loadDialogues() }
            }
        }
    }

    // MARK: - read / unread

    /// The last seq the person saw per "profile|dlg" (on this Mac).
    private var seenKey: String { "lia_ws_seenseq_" + (auth.activeId ?? "_") }
    private lazy var seen: [String: Int] = (UserDefaults.standard.dictionary(forKey: seenKey) as? [String: Int]) ?? [:]
    private func seenId(_ dlg: String, _ p: String? = nil) -> String { (p ?? profileId ?? "_") + "|" + dlg }
    /// Also called by the side panel's messenger, which shows a dialogue without the sheet.
    func markSeen(_ dlg: String) {
        let last = max(dialogue(dlg)?.lastSeq ?? 0, chatIfOpen(dlg)?.latestSeq ?? 0)
        let k = seenId(dlg)
        guard last > (seen[k] ?? -1) else { return }
        seen[k] = last
        UserDefaults.standard.set(seen, forKey: seenKey)
        objectWillChange.send()
    }
    /// How many messages since the person last looked need them (AgentAttention: a final answer, a
    /// question, an approval card in the agent's own dialogue; never activity lines or an acknowledgement), 0 while
    /// it is open. The dock's red count; summed, the Inbox's total. The loaded messages when the dialogue's model is
    /// in memory, else the summary's newest message.
    func attentionCount(dlg: String) -> Int {
        guard dlg != sheet, let d = dialogue(dlg) else { return 0 }
        let c = chatIfOpen(dlg)
        let seenSeq = seen[seenId(dlg)] ?? d.lastSeq
        guard max(d.lastSeq, c?.latestSeq ?? 0) > seenSeq else { return 0 }
        var n = c?.attentionCount(after: seenSeq) ?? 0
        if let last = d.last, last.seq > seenSeq, last.seq > (c?.latestSeq ?? 0),
           AgentAttention.needs(AgentAttention.Message(last), in: dlg) { n += 1 }
        return n
    }
    /// Something new that needs the person since they last looked (and it is not open now).
    func unread(dlg: String) -> Bool { attentionCount(dlg: dlg) > 0 }
    func unread(agent id: String) -> Bool { unread(dlg: DialogueSummary.dlg(forAgent: id)) }
    func attentionCount(agent id: String) -> Int { attentionCount(dlg: DialogueSummary.dlg(forAgent: id)) }
    /// The Inbox's total: every message that needs the person, over the workspace's dialogues.
    var unreadCount: Int { dialogues.reduce(0) { $0 + attentionCount(dlg: $1.dlg) } }

    /// A dialogue's newest seq moved (its stream or a page): the summary follows, and an open one stays read.
    private func seqMoved(profile p: String, dlg: String, seq: Int) {
        guard p == profileId else { return }
        if let i = dialogues.firstIndex(where: { $0.dlg == dlg }) {
            if dialogues[i].lastSeq < seq { dialogues[i].lastSeq = seq }
        } else {
            dialogues.append(DialogueSummary(dlg: dlg, lastSeq: seq))
        }
        if sheet == dlg { markSeen(dlg) }
    }

    func select(_ id: String) {
        guard id != profileId, profiles.contains(where: { $0.id == id }) else { return }
        if let a = profiles.firstIndex(where: { $0.id == profileId }), let b = profiles.firstIndex(where: { $0.id == id }) { switchForward = b > a }
        // Closed while the old workspace is still in front: it is marked read there, not in the new one.
        sheet = nil
        profileId = id
        UserDefaults.standard.set(id, forKey: profileKey)
        dialogues = []
        if let p = profile { _ = browser(for: p) }
        Task { await loadDialogues() }
    }

    /// Rename it, recolour it, or set its ad accounts or GitHub repositories (nil: the ones it has stay).
    func updateProfile(_ p: CompanyProfile, name: String, accounts: [(id: String, name: String)]? = nil, color: UInt32? = nil,
                       repos: [WorkspaceRepo]? = nil) async -> String? {
        var o: [String: Any] = ["name": name]
        if let color { o["color"] = String(format: "#%06X", color) }
        let list = accounts ?? p.metaAccounts
        o["meta_accounts"] = CompanyProfile.accountsBody(list)
        // An older server reads only these; mirrors the first itself.
        o["meta_account"] = list.first?.id ?? ""
        o["meta_account_name"] = list.first?.name ?? ""
        // The full list every time, so a rename never drops them; the server keeps it as given.
        o["github_repos"] = WorkspaceRepo.body(repos ?? (profiles.first(where: { $0.id == p.id }) ?? p).githubRepos)
        do {
            let r = try await LiaAPI(auth: auth).agentProfileOp(["op": "update", "id": p.id, "profile": o])
            guard JSONRead.bool(r, "ok"), let j = r["profile"] as? JSONObject, let made = CompanyProfile(json: j) else {
                return JSONRead.string(r, "error") ?? "Could not save the workspace."
            }
            if let i = profiles.firstIndex(where: { $0.id == made.id }) { profiles[i] = made }
            return nil
        } catch { return userMessage(for: error) }
    }

    /// Adds these ad accounts to a workspace (already there: skipped; at most 20).
    func addAccounts(_ add: [AdAccount], to p: CompanyProfile) async -> String? {
        var list = p.metaAccounts
        for a in add {
            guard let d = CompanyProfile.digits(a.id), !list.contains(where: { $0.id == d }) else { continue }
            list.append((d, a.name))
        }
        return await updateProfile(p, name: p.name, accounts: Array(list.prefix(20)))
    }

    /// The switcher's "New workspace": an empty one, selected, its settings open on Ad accounts.
    func newWorkspace() async {
        if let e = await createProfile(name: "New workspace", accounts: []) { errorText = e; return }
        if let p = profile { settingsFocus = "accounts"; editingProfile = p }
    }

    /// The profile, its conversations and its browsers go.
    func deleteProfile(_ p: CompanyProfile) async {
        do {
            let r = try await LiaAPI(auth: auth).agentProfileOp(["op": "delete", "id": p.id])
            guard JSONRead.bool(r, "ok") else { errorText = JSONRead.string(r, "error") ?? "Could not delete the profile."; return }
        } catch { errorText = userMessage(for: error); return }
        for (k, b) in browsers where k == p.id || k.hasPrefix(p.id + "|") {
            if let key = b.account { PasswordStore.shared.deleteAll(key) }   // a deleted client's saved sign-ins go too
            b.shutDown(); browsers[k] = nil
        }
        profiles.removeAll { $0.id == p.id }
        if profileId == p.id {
            profileId = nil
            if let next = profiles.first { select(next.id) } else { dialogues = []; sheet = nil; showNewProfile = true }
        }
    }

    /// \u{2318}1-9: the nth client.
    func selectIndex(_ n: Int) { if n >= 0, n < profiles.count { select(profiles[n].id) } }

    func loadDialogues() async {
        guard let p = profile else { dialogues = []; return }
        // a failed refresh keeps what we have: an empty list would close the open conversation
        guard let list = try? await LiaAPI(auth: auth).dialogues(profile: p.id) else { return }
        guard profile?.id == p.id else { return }
        // A dialogue seen for the first time on this Mac counts as read: no wall of dots on the first launch.
        var changed = false
        for d in list where seen[seenId(d.dlg, p.id)] == nil { seen[seenId(d.dlg, p.id)] = d.lastSeq; changed = true }
        if changed { UserDefaults.standard.set(seen, forKey: seenKey) }
        dialogues = list
        // Loaded dialogues behind the server (an agent wrote first, another device) catch up.
        for d in list {
            if let c = chats[seenId(d.dlg, p.id)], c.loaded, d.lastSeq > c.latestSeq { await c.refreshLatest() }
        }
        if let s = sheet { markSeen(s) }
    }

    /// A new workspace with these ad accounts (none is fine): its team chat is born with it.
    func createProfile(name: String, accounts: [(id: String, name: String)] = [], repos: [WorkspaceRepo] = []) async -> String? {
        let color = CompanyProfile.palette[profiles.count % CompanyProfile.palette.count]
        var p: [String: Any] = ["name": name, "color": String(format: "#%06X", color)]
        if !accounts.isEmpty {
            p["meta_accounts"] = CompanyProfile.accountsBody(Array(accounts.prefix(20)))
            p["meta_account"] = accounts[0].id; p["meta_account_name"] = accounts[0].name
        }
        if !repos.isEmpty { p["github_repos"] = WorkspaceRepo.body(repos) }
        do {
            let r = try await LiaAPI(auth: auth).agentProfileOp(["op": "create", "profile": p])
            guard JSONRead.bool(r, "ok"), let o = r["profile"] as? JSONObject, let made = CompanyProfile(json: o) else {
                return JSONRead.string(r, "error") ?? "Could not create the profile."
            }
            profiles.append(made)
            select(made.id)
            return nil
        } catch {
            return userMessage(for: error)
        }
    }

    // MARK: - browsers

    /// The person's browser of a profile. Ads Manager opens on the profile's account when nothing else is open.
    func browser(for p: CompanyProfile) -> BrowserModel {
        if let b = browsers[p.id] { return b }
        let b = BrowserModel(account: storeKey(for: p), chat: "ws")
        StoreLog.pane("workspace browser", browser: b, workspace: b.account)
        b.clientName = p.name
        if b.tabs.allSatisfy({ $0.isStart }), let u = p.adsManagerURL, let t = b.tabs.first { t.load(u) }
        browsers[p.id] = b
        return b
    }
    var currentBrowser: BrowserModel? { profile.map { browser(for: $0) } }
    /// Every browser opened this launch, keyed "profile" or "profile|agent" (diagnostics).
    var openBrowsers: [String: BrowserModel] { browsers }

    /// An agent's own browser in a profile: the profile's sign-ins, its own tabs.
    /// The agent's browser if it exists already (never creates one; safe to call while drawing a view).
    func existingAgentBrowser(_ agent: String, profile: String) -> BrowserModel? { browsers[profile + "|" + agent] }

    /// The data-store key of a workspace: its browser and every agent pane of it are on this one persistent store
    /// (BrowserModel.dataStore), so the person's sign-ins are the agents' too.
    func storeKey(for p: CompanyProfile) -> String { CompanyProfile.browserKey(account: auth.activeId, profile: p.id) }

    func agentBrowser(_ agent: String, in p: CompanyProfile) -> BrowserModel {
        let key = p.id + "|" + agent
        // Exactly the workspace browser's store: the key of the
        // workspace browser if it is open, else the workspace's own. An agent browser made on any other key (before
        // the Liaison account was known, under another one) is let go and made again on this one (Met opens Ads
        // Manager there again).
        let want = browsers[p.id]?.account ?? storeKey(for: p)
        if let b = browsers[key] {
            if b.account == want { return b }
            StoreLog.replaced(agent: agent)
            b.shutDown(); browsers[key] = nil
        }
        let b = BrowserModel(account: want, chat: "agent-" + agent)
        StoreLog.pane("agent pane " + agent, browser: b, workspace: storeKey(for: p))
        if agent == "met", b.tabs.allSatisfy({ $0.isStart }), let u = p.adsManagerURL, let t = b.tabs.first { t.load(u) }
        browsers[key] = b
        return b
    }

    /// A page of the person's browser changed. Another client's ad account in Ads Manager: that client's profile
    /// takes it over (opened there), and this browser goes back to its own account.
    func pageChanged(_ url: URL?) {
        guard let owner = AdsManagerAccount.owner(of: url, current: profileId, profiles: profiles), let url else { return }
        if let p = profile, let own = p.adsManagerURL { currentBrowser?.selected?.load(own) }
        select(owner.id)
        browser(for: owner).open(url)
    }

    /// What the agents see of the browsers with a message: the person's tabs (the front one read in full).
    /// A page shown in our translation is read as shown (the translated text, rewritten in place), with a
    /// note saying so (PageTranslator.agentNote), so the agent does not misreport the site's language.
    func browserContext(profile id: String? = nil) async -> [String: Any]? {
        let found: CompanyProfile?
        if let id {
            // A profile asked for by id and gone: nothing, never the front profile's tabs.
            found = profiles.first { $0.id == id }
        } else {
            found = profile
        }
        guard let p = found else { return BrowserContext.payload([]) }
        // Every agent sees the screen - the front tab read in full (compact), the others by name only; nothing
        // of a page when the person turned "Agents can see the current tab" off. Private windows are not a workspace
        // browser and are never read.
        guard ScreenShare.isOn(profile: p.id) else { return ScreenShare.payload([], shared: false, canLook: false) }
        let b = screenBrowser(p)
        // (incident): the tab the person is LOOKING at (Peek over the page, the focused pane of a
        // split / three-pane view, else the selected tab) always goes, first and marked front - also a new tab page
        // or a tab still restoring (no text then, no picture); ScreenShare.ordered keeps it ahead of the 12-tab cap.
        let seen = lookedAt(p)
        var tabs: [ScreenShare.Tab] = []
        var canLook = false
        if let w = seen.peek {
            var tab = ScreenShare.Tab(id: ScreenShare.peekID, title: w.title ?? "", url: w.url?.absoluteString ?? peek?.absoluteString ?? "", active: true)
            if w.url != nil {
                let read = await AgentBridge.snapshot(w, maxText: ScreenShare.frontText, maxControls: ScreenShare.frontControls, store: false).text
                tab.text = Self.translated(w, read)
                tab.selection = await Self.screenSelectedText(w)
                canLook = true
            }
            tabs.append(tab)
        }
        for t in b.tabs where !t.isStart || t.id == seen.tab?.id {
            let front = t.id == seen.tab?.id
            var tab = ScreenShare.Tab(id: t.shortID, title: t.isStart ? "New Tab" : t.displayTitle,
                                      url: t.isStart ? "" : (t.loadedWebView?.url ?? t.pendingURL ?? t.url)?.absoluteString ?? "", active: front)
            if front, !t.isStart, t.pendingURL == nil, let w = t.loadedWebView, w.url != nil {
                let read = await AgentBridge.snapshot(w, maxText: ScreenShare.frontText, maxControls: ScreenShare.frontControls, store: false).text
                tab.text = Self.translated(w, read)
                tab.selection = await t.selectedText()
                canLook = true
            }
            tabs.append(tab)
        }
        return ScreenShare.payload(tabs, shared: true, canLook: canLook)
    }

    /// A page's text as an agent gets it: when our translator shows the page, its note first (the text read is the
    /// translated page as shown).
    static func translated(_ w: WKWebView, _ text: String) -> String {
        guard let note = PageTranslateCenter.shared.existing(w)?.agentNote else { return text }
        return text.isEmpty ? note : note + "\n" + text
    }

    // MARK: - conversations

    /// The dialogue's model in the workspace in front (or `profile`), kept per profile and dlg for the app's life.
    func chat(for dlg: String, profile pid: String? = nil) -> TeamChatModel? {
        guard let p = pid ?? profileId, profiles.contains(where: { $0.id == p }) else { return nil }
        let key = p + "|" + dlg
        if let c = chats[key] { return c }
        // The dialogue's own client, not whichever profile is in front when it runs.
        let c = TeamChatModel(auth: auth, profile: p, dlg: dlg, accountName: profiles.first { $0.id == p }?.metaAccountName)
        // Read at apply time: an account changed in the profile after the chat opened is the one applied.
        c.currentAccountName = { [weak self] in self?.profiles.first { $0.id == p }?.metaAccountName }
        c.browserContext = { [weak self] in await self?.browserContext(profile: p) }
        c.liaContext = { [weak self] in await self?.liaContext(profile: p) }
        // Browser work lives in the dialogue of the agent that asked for it (its pane, status and
        // report), never in the dialogue whose stream carried it - Met's task after an @Met in Lia's is Met's dialogue's.
        c.onScreenLook = { [weak self, weak c] agent, look in   // A picture of the front tab, asked by an agent
            guard let self, let c else { return }
            self.lookAtScreen(chat: self.browserOwner(agent, of: c), agent: agent, look: look)
        }
        c.onBrowserTask = { [weak self, weak c] agent, task, goal, tab, url in
            guard let self, let c else { return }
            self.runBrowserTask(chat: self.browserOwner(agent, of: c), agent: agent, task: task, goal: goal, tab: tab, url: url)
        }
        c.onActivity = { [weak self] working, waiting in self?.merge(dialogue: key, working: working, waiting: waiting) }
        c.onSeq = { [weak self] seq in self?.seqMoved(profile: p, dlg: dlg, seq: seq) }
        // Notifications, the dock's bounce and its count follow AgentAttention only.
        c.onAttention = { [weak self] m, kind in self?.attention(key: key, profile: p, dlg: dlg, message: m, kind: kind) }
        // A task this dialogue's turn gave another agent runs in that agent's own dialogue (same client).
        c.onTaskRun = { [weak self] toDlg, task in self?.chat(for: toDlg, profile: p)?.startTask(task) }
        let session = c.sessionId
        // The write agent's work is drawn over its own Ads Manager (the cursor, the fields), as in the chat.
        c.onTrace = { [weak self, weak c] agent, e in
            guard let self, let c, let prof = self.profiles.first(where: { $0.id == p }), self.agent(agent)?.write == true else { return }
            let b = self.agentBrowser(agent, in: prof)
            let auth = self.auth
            b.agent.onStop = { [weak c] in c?.stop() }
            b.agent.gateOpen = { [weak self, weak c] in   // A card the person ignored by typing ends the wait
                guard let self, let c else { return false }
                return self.browserOwner(agent, of: c).openGate?.item.agent == agent
            }
            b.agent.locator.ask = { input, questions in await LiaAPI(auth: auth).locateReply(input: input, questions: questions, chatId: session, agent: agent) }
            b.agent.log.chatId = session
            b.agent.log.send = { cid, events in await LiaAPI(auth: auth).agentLog(chatId: cid, events: events) }
            let ents = c.live?.ents ?? [:]
            b.agent.feed(e, defaultAccount: prof.metaAccount, kindOf: { ents[$0]?.kind }, parentOf: { ents[$0]?.parent })
            // the agent's own dialogue shows it at work in its browser (AgentBrowserRecent;: not the
            // dialogue whose stream carried the trace)
            let owner = self.browserOwner(agent, of: c).key
            if case let .intent(_, tool, _, door) = e, door || AgentRun.isDoor(tool) { AgentBrowserRecent.shared.began(agent, chat: owner) } else if case .end = e { AgentBrowserRecent.shared.ended(agent, chat: owner) }
        }
        c.onTraceAnswer = { [weak self] agent, e in
            guard let self, let prof = self.profiles.first(where: { $0.id == p }), self.agent(agent)?.write == true else { return }
            self.agentBrowser(agent, in: prof).agent.answered(e, defaultAccount: prof.metaAccount)
        }
        chats[key] = c
        return c
    }

    /// A "profile|dlg" key (a chat's `key`) as its model.
    func chat(key: String) -> TeamChatModel? {
        let parts = key.split(separator: "|", maxSplits: 1).map(String.init)
        guard parts.count == 2 else { return nil }
        return chat(for: parts[1], profile: parts[0])
    }

    private var activity: [String: (Set<String>, Set<String>)] = [:]
    private func merge(dialogue key: String, working w: Set<String>, waiting q: Set<String>) {
        // An agent newly waiting for a Yes (an approval card, the browser agent asking on a page) notifies
        // once.: "finished" no longer comes from here (the working set changed with every turn and step,
        // acknowledgements included); a stored final answer or question posts it (`attention`, AgentAttention).
        let before = activity[key] ?? ([], [])
        let client = chats[key].flatMap { c in profiles.first { $0.id == c.profile }?.name }
        for a in q.subtracting(before.1) {
            Notifier.post(.approval, agent: agent(a)?.name ?? a.capitalized, agentId: a, client: client, dialogue: key)
        }
        activity[key] = (w, q)
        refreshLive()
        // The app icon in the Dock shows how many changes wait for a Yes.
        DispatchQueue.main.async { [weak self] in
            let n = self?.approvals.count ?? 0
            NSApp.dockTile.badgeLabel = n > 0 ? String(n) : nil
        }
        working = activity.values.reduce(into: Set<String>()) { $0.formUnion($1.0) }
        waiting = activity.values.reduce(into: Set<String>()) { $0.formUnion($1.1) }

    }

    /// A stored message that needs the person (AgentAttention) arrived in dialogue `key`: the agent's figure bounces in
    /// the dock (which peeks when hidden), and a macOS notification goes out while the app is in the background.
    private func attention(key: String, profile p: String, dlg: String, message m: DlgMessage, kind: AgentAttention.Kind) {
        let id = (m.agent ?? "").isEmpty ? DialogueSummary.agent(forDlg: dlg) : (m.agent ?? "")
        let client = profiles.first { $0.id == p }?.name
        // Not for the dialogue the person is reading right now.
        let reading = NSApp.isActive && p == profileId && sheet == dlg
        if !reading {
            NotificationCenter.default.post(name: .liaAgentAttention, object: nil, userInfo: ["agent": id, "profile": p])
        }
        // An approval notifies through the waiting set (merge), once per card; here the answers and questions.
        if kind == .message {
            Notifier.post(.done, agent: agent(id)?.name ?? id.capitalized, agentId: id, client: client, dialogue: key, text: m.text)
        }
        // The count reads the chat's items, which take the message right after this call.
        DispatchQueue.main.async { [weak self] in self?.objectWillChange.send() }
    }

    // MARK: live status (menu bar item, Dock progress)

    private var liveTimer: Timer?
    /// What every agent at work is doing, for MenuBarStatus; ticks once a second while anyone works.
    private func refreshLive() {
        var items: [MenuBarStatus.Item] = []
        for (key, act) in activity {
            guard let c = chats[key] else { continue }
            let client = profiles.first { $0.id == c.profile }?.name ?? ""
            for a in act.0.sorted() {
                let info = agent(a)
                var progress: Double?
                if let b = openBrowsers[c.profile + "|" + a], let step = b.web.step {
                    progress = min(1, Double(step) / Double(WebAgent.maxCalls))
                } else if let jp = c.jobProgress, jp.total > 0 {
                    progress = Double(jp.done) / Double(jp.total)
                }
                items.append(MenuBarStatus.Item(id: key + "|" + a, agent: a, name: info?.name ?? a.capitalized, color: info?.colorHex ?? 0x0E1014,
                                             text: c.activity(of: a) ?? "Working\u{2026}", client: client, dialogue: key, progress: progress,
                                             steps: c.jobProgress.flatMap { $0.total > 0 ? AgentActivity.Steps(done: $0.done, total: $0.total) : nil }))
            }
        }
        MenuBarStatus.shared.update(items, waiting: approvals.count)
        if items.isEmpty {
            liveTimer?.invalidate(); liveTimer = nil
        } else if liveTimer == nil {
            liveTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] t in
                // The model went away (sign-out / account switch rebuilds the window): the run loop must not keep it.
                guard self != nil else { t.invalidate(); Task { @MainActor in MenuBarStatus.shared.update([], waiting: 0) }; return }
                Task { @MainActor in self?.refreshLive() }
            }
        }
    }

    /// The dialogue's model if one was made already (the workspace in front), without making it.
    func chatIfOpen(_ dlg: String) -> TeamChatModel? { profileId.flatMap { chats[$0 + "|" + dlg] } }

    // MARK: - the new tab's feed

    struct FeedItem: Identifiable {
        let id: String          // the dialogue ("team" or an agent id) in the workspace in front
        let agent: String
        let title: String
        let body: String
        let ts: Double?
        let gate: Bool
    }

    /// The newest word of each agent in this client's dialogues, newest first (an approval first).
    var feed: [FeedItem] {
        dialogues.compactMap { d -> FeedItem? in
            let c = chatIfOpen(d.dlg)
            let open = c?.openGate != nil
            // A loaded dialogue knows its newest message best; else the summary's last one.
            var agent: String?, content = "", ts: Double?
            if let c, let last = c.items.last(where: { $0.agent != nil && !$0.isTask }) {
                agent = last.agent; content = last.message.content; ts = last.message.ts
            } else if let last = d.last, last.role != .user, !last.isTaskCard {
                agent = last.agent ?? (d.isTeam ? "lia" : d.dlg); content = last.text; ts = last.ts.map { $0.timeIntervalSince1970 * 1000 }
            }
            guard let a = agent else { return nil }
            let gate = open || (c == nil && (d.last?.gate.map { !$0.done } ?? false))
            let (title, body) = FeedText.split(content)
            guard !title.isEmpty || gate else { return nil }
            return FeedItem(id: d.dlg, agent: a, title: title.isEmpty ? "Prepared a change" : title, body: body, ts: ts, gate: gate)
        }
        .sorted { ($0.gate ? 1 : 0, $0.ts ?? 0) > ($1.gate ? 1 : 0, $1.ts ?? 0) }
    }

    /// Loads the newest dialogues' messages (once each; their models stay for the sheet).
    func warmFeed() async {
        await loadDialogues()
        let recent = dialogues.filter { $0.count > 0 }.sorted { ($0.last?.ts ?? .distantPast) > ($1.last?.ts ?? .distantPast) }.prefix(8)
        for d in recent { await chat(for: d.dlg)?.load() }
        objectWillChange.send()
    }

    /// A message for the team (Lia hands it on) from a quick action: it waits in Team's composer until Send.
    func askTeam(_ text: String) {
        draft(text, toAgent: "lia")
    }

    func openTeam() { openDialogue("team") }

    /// The dialogue with one agent ("lia": Team).
    func openAgent(_ id: String) { openDialogue(DialogueSummary.dlg(forAgent: id)) }

    /// Opens a dialogue of the workspace in front over the browser.
    func openDialogue(_ dlg: String) {
        guard profile != nil, dialogueIds.contains(dlg) else { return }
        sheet = dlg
    }

    /// Opens a dialogue and brings one of its messages into view (a search hit, a task card, the profile panel).
    func openDialogue(_ dlg: String, jumpTo messageId: String) {
        openDialogue(dlg)
        chat(for: dlg)?.jump(to: messageId)
    }

    /// A task card's Open: the owner's dialogue at the task's first message.
    func openTask(_ task: AgentTask) {
        let dlg = DialogueSummary.dlg(forAgent: task.owner)
        openDialogue(dlg)
        guard let c = chat(for: dlg) else { return }
        Task { await c.jumpToTask(task.id) }
    }

    /// The person's message to one agent ("lia": Team) from a quick action (a drop, Undo in the journal, Reader,
    /// Downloads): the dialogue opens with it in the composer; nothing goes until Send. `open` is kept for callers.
    func send(_ text: String, toAgent id: String, open: Bool = true) {
        draft(text, toAgent: id)
    }

    /// The dialogue an agent's browser work belongs to - its own (Team for Lia) in the same client,
    /// loaded so the report it gets later lands in a read thread. `c` itself when the agent is its own, or the client
    /// is gone.
    private func browserOwner(_ agent: String, of c: TeamChatModel) -> TeamChatModel {
        let d = AgentPaneChoice.owner(agent: agent)
        guard d != c.dlg, let o = chat(for: d, profile: c.profile) else { return c }
        if !o.loaded { Task { await o.load() } }
        return o
    }

    /// A browser task an agent gave: it runs in that agent's own browser, shown in that agent's own dialogue; the
    /// report goes back to that agent there.
    private func runBrowserTask(chat: TeamChatModel, agent: String, task: String, goal: String, tab: String, url: String?) {
        // The dialogue's client: a task never runs in another client's browser after a profile switch.
        guard let p = profiles.first(where: { $0.id == chat.profile }) else { return }
        let b = agentBrowser(agent, in: p)
        let auth = self.auth
        b.agent.log.chatId = chat.sessionId
        b.agent.log.send = { c, events in await LiaAPI(auth: auth).agentLog(chatId: c, events: events) }
        chat.webAgent = agent
        AgentBrowserRecent.shared.began(agent, chat: chat.key)
        b.agent.onWebLabel = { [weak chat] s in chat?.webStatus = s }
        chat.onStopWeb = { [weak b] in b?.agent.stop() }
        let chatKey = chat.key
        b.web.onEnd = { [weak chat, weak b] in
            chat?.webAgent = nil; chat?.webStatus = ""; b?.agent.onWebLabel = nil
            AgentBrowserRecent.shared.ended(agent, chat: chatKey)
        }
        b.web.run(task: task, goal: goal, tab: tab, url: url, api: LiaAPI(auth: auth), chatId: chat.sessionId) { [weak chat] message in
            chat?.sendMachine(message, agent: agent)
        }
    }

    // MARK: - reset and start over (Settings > Advanced)

    /// On while a reset or Start over runs (Settings shows it busy).
    @Published private(set) var resetting = false

    /// This workspace's dialogues, tasks and summaries go on the server (POST /agents/reset), then its conversation
    /// state on this Mac; the dock reloads empty. Memory, notes, tabs and sign-ins stay. Returns the error, or nil.
    func resetWorkspace() async -> String? {
        guard !resetting else { return nil }
        guard let p = profile else { return "No workspace is open." }
        resetting = true
        defer { resetting = false }
        do { _ = try await LiaAPI(auth: auth).agentsReset(profile: p.id) } catch { return userMessage(for: error) }
        // Server done: only now the local state goes.
        let pfx = p.id + "|"
        sheet = nil
        dropChats { $0.hasPrefix(pfx) }
        for s in ChatScheduler.shared.items where s.thread.hasPrefix(pfx) { ChatScheduler.shared.cancel(s) }
        let d = UserDefaults.standard
        for k in d.dictionaryRepresentation().keys where k.hasPrefix("lia_ws_") && (k.contains(pfx) || k == "lia_ws_sheet_" + p.id) {
            d.removeObject(forKey: k)
        }
        seen = seen.filter { !$0.key.hasPrefix(pfx) }
        d.set(seen, forKey: seenKey)
        ChatLocal.resetAll()
        dialogues = []
        await loadDialogues()
        show("Workspace reset", symbol: "arrow.counterclockwise")
        return nil
    }

    /// Every workspace goes on the server (deleting a profile wipes its dialogues), then the app's workspace state on
    /// this Mac; the welcome shows again and one workspace ("Main") is made anew, the picked ad accounts added to it. Login, memory,
    /// browser data and preferences stay. A failed server step leaves the local state as it was. Returns the error.
    func startOver() async -> String? {
        guard !resetting else { return nil }
        resetting = true
        defer { resetting = false }
        let api = LiaAPI(auth: auth)
        // The server's full list: a workspace hidden here (its ad account gone) goes too.
        let all: [CompanyProfile]
        do { all = try await api.agentProfiles() } catch { return userMessage(for: error) }
        var gone: [String] = []
        var failure: String?
        for p in all {
            do {
                let r = try await api.agentProfileOp(["op": "delete", "id": p.id])
                guard JSONRead.bool(r, "ok") else { failure = JSONRead.string(r, "error") ?? "Could not delete \(p.name)."; break }
                gone.append(p.id)
            } catch { failure = userMessage(for: error); break }
        }
        if let failure {
            // Part of it went: those workspaces leave the window as after Delete; nothing else local is touched.
            for id in gone {
                for (k, b) in browsers where k == id || k.hasPrefix(id + "|") { b.shutDown(); browsers[k] = nil }
                dropChats { $0.hasPrefix(id + "|") }
                profiles.removeAll { $0.id == id }
            }
            if let cur = profileId, gone.contains(cur) {
                profileId = nil
                sheet = nil
                if let next = profiles.first { select(next.id) } else { dialogues = [] }
            }
            return failure
        }
        refresh?.cancel(); refresh = nil
        sheet = nil; peek = nil; palette = nil; switcher = nil
        touring = false; showJournal = false; showApprovals = false; showNewProfile = false
        editingProfile = nil; confirmDelete = nil
        dropChats { _ in true }
        for (_, b) in browsers { b.shutDown() }
        browsers = [:]
        for s in ChatScheduler.shared.items { ChatScheduler.shared.cancel(s) }
        profiles = []; profileId = nil; dialogues = []; journal = []; freshProfiles = []
        Self.clearWorkspaceDefaults()
        AccountPrefsSync.forget(member: auth.activeId)
        worksWithoutMeta = false
        meta = nil
        seen = [:]
        ChatLocal.resetAll()
        DockOrder.reset()
        LiaTips.requestReset()
        errorText = nil
        onboarding = true
        booted = false
        await boot()
        return nil
    }

    /// The keys Start over removes: everything per workspace or conversation (`lia_ws_*`), the welcome, the role
    /// asked there, the morning tour's day, the new tab's tips and the home brief cache. Login (memberstack.*),
    /// updates (Sparkle), preferences and browser data (tabs, history, permissions, zoom, sign-ins) stay. Saved quick
    /// tasks are per workspace (`lia_ws_saved_prompts_`) and go with the rest.
    static func clearWorkspaceDefaults() {
        let d = UserDefaults.standard
        let exact: Set<String> = ["lia_onboarded", Prefs.role, TourDay.dayKey, TourDay.stepKey,
                                  "lia_ntp_tips_dismissed", "lia_ntp_tip_hidden_week"]
        for k in d.dictionaryRepresentation().keys where k.hasPrefix("lia_ws_") || k.hasPrefix("lia_home_brief_") || exact.contains(k) {
            d.removeObject(forKey: k)
        }
    }

    /// Conversations whose "profile|dlg" key matches go (their runs stop) with their activity.
    private func dropChats(_ match: (String) -> Bool) {
        for (k, c) in chats where match(k) {
            c.onActivity = nil
            c.onSeq = nil
            c.stop()
            chats[k] = nil
        }
        for k in Array(activity.keys) where match(k) { activity[k] = nil }
        working = activity.values.reduce(into: Set<String>()) { $0.formUnion($1.0) }
        waiting = activity.values.reduce(into: Set<String>()) { $0.formUnion($1.1) }
        refreshLive()
        let n = approvals.count
        NSApp.dockTile.badgeLabel = n > 0 ? String(n) : nil
    }

    // MARK: - journal

    @Published private(set) var journal: [JSONObject] = []
    func loadJournal() async {
        guard let p = profile else { journal = []; return }
        let rows = await LiaAPI(auth: auth).agentJournal(profile: p.id)
        // The person switched client while it loaded: that journal is not this one.
        guard profileId == p.id else { return }
        journal = rows
    }
}
