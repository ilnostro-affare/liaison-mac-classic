import SwiftUI

// The brief over the new tab: "Yesterday: €1,240 · 87 leads · CPL €14.2 (↓8%)" for the current workspace.
// The whole workspace, not its first ad account. ("the brief is Meta and GitHub
// numbers only - direct backend requests, no model; switch the period by tapping: yesterday, today, week, month -
// rolling, not calendar; several ad accounts: sum them"): the period is a tap on its label (BriefPeriod, remembered
// per workspace), every account is read for the period and the equal one before it (get_account_stats, one Graph
// insights read each) and summed per currency - one row per currency, never one sum across currencies - and the words
// are a template (BriefText). No model is called anywhere on this line. Kept per workspace, period and day in
// UserDefaults (Today for 15 minutes), so a new tab never refetches them. No ad account: no ad figures at all.

/// The period's numbers, one group per currency, as the brief shows them.
struct HomeBriefData: Codable, Equatable {
    var period: String
    var groups: [BriefGroup]
    var at: Date
}

extension TourStats {
    /// One account over a range of days (get_account_stats -> meta-auth /meta/stats -> Graph insights).
    @MainActor
    static func fetch(_ ws: WorkspaceModel, account: String, from: String, to: String) async -> TourStats? {
        let d = try? await LiaAPI(auth: ws.auth).mcpCall("get_account_stats", ["account": account, "from": from, "to": to])
        return parse(d)
    }
}

/// Loads and caches the brief for one workspace, period and day.
@MainActor
final class HomeBriefStore: ObservableObject {
    enum State: Equatable { case idle, loading, ready(HomeBriefData), failed }
    @Published private(set) var state: State = .idle
    private var key: String?
    /// Reads that failed today in this run: not retried on every new tab.
    private static var failed: Set<String> = []
    /// Today's numbers move: a copy older than this is read again (shown meanwhile).
    static let todayFresh: TimeInterval = 15 * 60

    /// The workspace's ad accounts, in its order (the first is `metaAccount`).
    static func accounts(_ ws: WorkspaceModel) -> [String] {
        BriefTotals.accounts(ws.profile?.metaAccounts.map(\.id) ?? [], first: ws.profile?.metaAccount)
    }

    /// What `.task(id:)` watches: the workspace and its accounts.
    static func watchKey(_ ws: WorkspaceModel) -> String {
        (ws.profile?.id ?? "") + "|" + accounts(ws).joined(separator: ",")
    }

    private static func cacheKey(_ profile: String, _ accounts: [String], _ period: BriefPeriod, _ day: String) -> String {
        "lia_home_brief_\(profile)_\(accounts.joined(separator: "-"))_\(period.rawValue)_\(day)"
    }

    /// Every account over every range, in parallel: `[range][account]` (nil: that read failed).
    static func fetch(_ ws: WorkspaceModel, accounts: [String], ranges: [(from: String, to: String)]) async -> [[TourStats?]] {
        var out: [[TourStats?]] = Array(repeating: Array(repeating: nil, count: accounts.count), count: ranges.count)
        await withTaskGroup(of: (Int, Int, TourStats?).self) { g in
            for (r, range) in ranges.enumerated() {
                for (a, acc) in accounts.enumerated() {
                    g.addTask { @MainActor in
                        let got = await TourStats.fetch(ws, account: acc, from: range.from, to: range.to)
                        return (r, a, got)
                    }
                }
            }
            for await (r, a, s) in g { out[r][a] = s }
        }
        return out
    }

    /// The period and the one before it over the whole workspace, per currency (the tour's "Yesterday" step reads it
    /// too). nil: no ad account, or no account answered.
    static func workspace(_ ws: WorkspaceModel, period: BriefPeriod) async -> [BriefGroup]? {
        let accs = accounts(ws)
        guard !accs.isEmpty else { return nil }
        var ranges = [period.range()]
        if let p = period.previousRange() { ranges.append(p) }
        let got = await fetch(ws, accounts: accs, ranges: ranges)
        let groups = BriefTotals.groups(current: got[0], previous: got.count > 1 ? got[1] : [])
        return groups.isEmpty ? nil : groups
    }

    func load(_ ws: WorkspaceModel, period: BriefPeriod) async {
        let accs = Self.accounts(ws)
        guard let p = ws.profile, !accs.isEmpty else { state = .idle; key = nil; return }
        let day = TourDay.today
        let k = Self.cacheKey(p.id, accs, period, day)
        var stale = false
        if key != k {
            key = k
            if let d = UserDefaults.standard.data(forKey: k), let data = try? JSONDecoder().decode(HomeBriefData.self, from: d) {
                state = .ready(data)
                stale = period == .today && Date().timeIntervalSince(data.at) > Self.todayFresh
                if !stale { return }
            } else if Self.failed.contains(k) {
                state = .failed
                return
            }
        } else if case let .ready(data) = state {
            stale = period == .today && Date().timeIntervalSince(data.at) > Self.todayFresh
            if !stale { return }
        } else if state != .idle {
            return
        }
        if !stale { state = .loading }
        let groups = await Self.workspace(ws, period: period)
        guard key == k, !Task.isCancelled else {
            // Cancelled half way (the period switched, the view went): the same read may start again later.
            if key == k, !stale { key = nil; state = .idle }
            return
        }
        guard let groups else {
            if !stale { Self.failed.insert(k); state = .failed }
            return
        }
        let data = HomeBriefData(period: period.rawValue, groups: groups, at: Date())
        if let d = try? JSONEncoder().encode(data) { UserDefaults.standard.set(d, forKey: k) }
        Self.prune(profile: p.id, day: day)
        state = .ready(data)
    }

    /// Other days of this workspace go (today's periods stay); the per-account keys of before and the
    /// one-day keys of before too.
    private static func prune(profile: String, day: String) {
        let prefix = "lia_home_brief_\(profile)_"
        for k in UserDefaults.standard.dictionaryRepresentation().keys where k.hasPrefix("lia_home_brief_") {
            if k.hasPrefix(prefix) ? !k.hasSuffix("_" + day) : k.dropFirst("lia_home_brief_".count).first?.isNumber == true {
                UserDefaults.standard.removeObject(forKey: k)
            }
        }
    }
}

/// The brief: the period's ad numbers and, merged with them, the workspace's repositories' activity on
/// GitHub (GET /agents/github/activity: GitHub's API, no model). Real glass over the sky (HomeGlass). Bars in place of
/// the figures while they load; nothing when there is neither (one "Connect GitHub…" capsule only when the workspace
/// has no repositories and GitHub is not connected).
struct HomeBriefLine: View {
    @ObservedObject var ws: WorkspaceModel
    /// Space above the line while it shows (none when it is hidden).
    var top: CGFloat = 14
    /// Opens a repository's page (Home's address handling); nil: the row is not a link.
    var open: ((URL) -> Void)? = nil
    @StateObject private var store = HomeBriefStore()
    @StateObject private var repos = HomeRepoStore()
    @ObservedObject private var github = GitHubLink.shared
    /// The period picked in this view; `periodFor` is the workspace it was picked for (another one reads its own).
    @State private var picked: BriefPeriod = .fallback
    @State private var periodFor: String?
    /// Home's tone (WorkspaceHome sets it from the sky): the text's colours (HomeInk).
    @Environment(\.colorScheme) private var scheme

    /// The workspace and its repositories: a change of either reloads the activity.
    private var repoKey: String {
        (ws.profile?.id ?? "") + "|" + (ws.profile?.githubRepos.map(\.id).joined(separator: ",") ?? "")
    }

    private var profileId: String { ws.profile?.id ?? "" }

    /// This workspace's period: the one just picked, else the one saved for it, else Yesterday.
    private var period: BriefPeriod {
        if periodFor == profileId { return picked }
        return BriefPeriod.stored(UserDefaults.standard.string(forKey: BriefPeriod.key(profile: profileId)))
    }

    private func switchPeriod() {
        let n = period.next
        picked = n
        periodFor = profileId
        UserDefaults.standard.set(n.rawValue, forKey: BriefPeriod.key(profile: profileId))
    }

    var body: some View {
        content
            .task(id: HomeBriefStore.watchKey(ws) + "#" + period.rawValue) { await store.load(ws, period: period) }
            .task(id: repoKey) { await repos.load(ws) }
            .task { if github.status == nil { await github.refresh(ws.auth) } }
            .animation(.easeOut(duration: 0.25), value: repos.list?.count)
    }

    private var activity: [RepoActivity] { repos.list ?? [] }
    private var showConnect: Bool {
        RepoActivityHint.showConnect(workspaceRepos: ws.profile?.githubRepos.count ?? 0, connected: github.status?.connected)
    }

    @ViewBuilder private var content: some View {
        if activity.isEmpty {
            // The brief, as before, in glass capsules.
            if !hasFigures && !showConnect {
                hidden
            } else {
                VStack(spacing: 8) {
                    figuresRow
                    if showConnect { connectButton }
                }
                .padding(.top, top)
            }
        } else {
            VStack(alignment: .leading, spacing: 10) {
                if hasFigures { figuresRow.frame(maxWidth: .infinity) }
                HomeRepoSection(repos: activity, open: open)
            }
            .tourAnchor("repos")
            .padding(12)
            .frame(maxWidth: 760)
            .homeGlass(RoundedRectangle(cornerRadius: 18, style: .continuous))
            .padding(.top, top)
            .transition(.opacity)
        }
    }

    /// The numbers show, or are loading; a failed read shows only when another period than the default was picked
    /// (so the switch stays reachable), never for a workspace whose default read fails.
    private var hasFigures: Bool {
        switch store.state {
        case .loading, .ready: return true
        case .failed: return period != .fallback
        case .idle: return false
        }
    }

    private var hidden: some View { Color.clear.frame(width: 1, height: 0).accessibilityHidden(true) }

    @ViewBuilder private var figuresRow: some View {
        switch store.state {
        case .loading: HomeBriefFigures(period: period, groups: nil, failed: false, switchPeriod: switchPeriod, ask: ask)
        case let .ready(d): HomeBriefFigures(period: period, groups: d.groups, failed: false, switchPeriod: switchPeriod, ask: ask)
        case .failed: HomeBriefFigures(period: period, groups: nil, failed: true, switchPeriod: switchPeriod, ask: ask)
        case .idle: EmptyView()
        }
    }

    private func ask(_ metric: String) { ws.askTeam("Explain the \(metric) \(period.askSuffix)") }

    /// Connects GitHub as Settings > GitHub does (GitHubLink), in a glass capsule.
    private var connectButton: some View {
        Button { Task { await github.connect(ws.auth) } } label: {
            HStack(spacing: 6) {
                if github.busy || github.pending { ProgressView().controlSize(.mini) }
                else { Image(systemName: "chevron.left.forwardslash.chevron.right").font(.system(size: 10.5, weight: .semibold)) }
                Text(github.pending ? "Waiting for GitHub\u{2026}" : "Connect GitHub\u{2026}").font(LiaFont.ui(12.5, .medium))
            }
            .foregroundStyle(HomeInk(scheme).ink)
            .shadow(color: HomeInk(scheme).shadow, radius: 3, y: 0.5)
            .padding(.horizontal, 12).frame(height: 28)
            .homeGlass(Capsule())
            .contentShape(Capsule())
        }
        .buttonStyle(.liaPlain)
        .disabled(github.busy || github.pending)
        .liaPointer()
        .accessibilityHint(Text("Shows your repositories here"))
    }
}

extension View {
    /// Home's glass over the sky. ("clean glass, no extra colour"): the system glass and nothing on
    /// top of it - Liquid Glass (`.clear`) on macOS 26, the thinnest material elsewhere - with a faint hairline. No
    /// white wash: the material takes Home's tone (light over a light sky, dark over a dark one). Reduce Transparency:
    /// a solid surface.
    func homeGlass<S: InsettableShape>(_ shape: S) -> some View {
        modifier(HomeGlass(shape: shape))
    }
}

private struct HomeGlass<S: InsettableShape>: ViewModifier {
    let shape: S
    @Environment(\.accessibilityReduceTransparency) private var solid
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.colorScheme) private var scheme

    func body(content: Content) -> some View {
        if solid || contrast == .increased {
            content
                .background { shape.fill(WS.surface) }
                .overlay(shape.strokeBorder(WS.line2, lineWidth: 1).allowsHitTesting(false))
        } else {
            glass(content)
                .shadow(color: .black.opacity(0.05), radius: 10, y: 3)
        }
    }

    /// ("lit at the top and bottom, like a reflection"): Liquid Glass draws its own rim, so nothing
    /// is laid over it any more (a 0.5 pt white hairline, 0.5 light / 0.14 dark, doubled the system's light along
    /// every edge). The material elsewhere takes the shared natural rim (WSGlassRim). Shadow 0.06 r 12 y 4 -> 0.05 r 10 y 3.
    @ViewBuilder private func glass(_ content: Content) -> some View {
        #if compiler(>=6.2)
        if #available(macOS 26.0, *) {
            content.glassEffect(.clear, in: shape)
        } else {
            material(content)
        }
        #else
        material(content)
        #endif
    }

    private func material(_ content: Content) -> some View {
        content.background(.ultraThinMaterial, in: shape).overlay(WSGlassRim(shape: shape, dark: scheme == .dark))
    }
}

/// The workspace's repositories' activity (GET /agents/github/activity). Instant: the last copy on
/// disk (per workspace) shows at once and the server is asked behind it; the server answers from its own copy too,
/// with `stale: true` while it refreshes, so a stale answer is asked once more 20 s later. Kept ten minutes in
/// memory so a new tab does not refetch.
@MainActor
final class HomeRepoStore: ObservableObject {
    @Published private(set) var list: [RepoActivity]?
    private var shownFor: String?
    private static var memory: [String: Date] = [:]
    private static let fresh: TimeInterval = 10 * 60

    private static func diskKey(_ profile: String) -> String { "lia_home_repos_" + profile }

    func load(_ ws: WorkspaceModel) async {
        guard let p = ws.profile, !p.githubRepos.isEmpty else { list = []; return }
        if shownFor != p.id { shownFor = p.id; list = nil }   // another workspace: never its neighbour's rows
        let wanted = Set(p.githubRepos.map(\.id))
        let key = p.id + "|" + p.githubRepos.map(\.id).joined(separator: ",")
        // The copy on disk, at once (only the repositories the workspace still keeps).
        if let d = UserDefaults.standard.data(forKey: Self.diskKey(p.id)), let kept = RepoActivity.parseList(d) {
            let shown = kept.filter { wanted.contains($0.id) }
            if !shown.isEmpty || list == nil { list = shown.isEmpty ? nil : RepoActivity.sorted(shown) }
        }
        if let at = Self.memory[key], Date().timeIntervalSince(at) < Self.fresh, list != nil { return }
        if await fetch(ws, profile: p.id, key: key) {
            try? await Task.sleep(nanoseconds: 20_000_000_000)
            if Task.isCancelled { return }
            _ = await fetch(ws, profile: p.id, key: key)
        }
    }

    /// One read; true when the server said its answer is stale.
    private func fetch(_ ws: WorkspaceModel, profile: String, key: String) async -> Bool {
        guard let got = await LiaAPI(auth: ws.auth).githubActivityAnswer(profile: profile), !Task.isCancelled else { return false }
        let sorted = RepoActivity.sorted(got.list)
        if !got.stale { Self.memory[key] = Date() }
        UserDefaults.standard.set(RepoActivity.encodeList(sorted), forKey: Self.diskKey(profile))
        if sorted != list { list = sorted }
        return got.stale
    }
}

extension LiaAPI {
    /// GET /agents/github/activity with its freshness (`stale`). nil: no answer.
    func githubActivityAnswer(profile: String) async -> (list: [RepoActivity], stale: Bool)? {
        var c = URLComponents(string: AppConfig.agentsBase + "/agents/github/activity")
        c?.queryItems = [URLQueryItem(name: "profile", value: profile)]
        guard let url = c?.url else { return nil }
        for attempt in 0..<2 {
            guard let t = try? await token(forceRefresh: attempt == 1) else { return nil }
            var req = URLRequest(url: url, timeoutInterval: 30)
            LiaClient.stamp(&req)   // X-Lia-Client, our hosts only
            req.setValue("Bearer \(t)", forHTTPHeaderField: "Authorization")
            guard let got = try? await session.data(for: req) else { return nil }
            let (data, resp) = got
            let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
            if status == 401 && attempt == 0 { continue }
            guard status < 500 else { return nil }
            return RepoActivity.parseAnswer(data)
        }
        return nil
    }
}

/// The repositories, one row at a time: the list scrolls row by row and snaps (a picker's paging);
/// "Show more" shows up to three rows (still snapping beyond), "Show less" one again. Every row has the same
/// geometry: name and last commit on the left (one line each, cut with an ellipsis), then a fixed slot for open PRs
/// (empty at 0), the weeks as squares, and the 7d · 30d counts right-aligned in a fixed column.
private struct HomeRepoSection: View {
    let repos: [RepoActivity]
    let open: ((URL) -> Void)?
    @State private var more = false
    @State private var width: CGFloat = 700
    @Environment(\.colorScheme) private var scheme
    static let rowHeight: CGFloat = 50

    private var visible: Int { more ? min(3, repos.count) : 1 }
    /// The same number of weeks for every row, from the panel's width.
    private var weeks: Int { width >= 640 ? 26 : width >= 470 ? 12 : 0 }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            header
            ScrollView(.vertical) {
                LazyVStack(spacing: 0) {
                    ForEach(repos) { r in
                        HomeRepoRow(repo: r, weeks: weeks, open: open)
                            .frame(height: Self.rowHeight)
                    }
                }
                .scrollTargetLayout()
            }
            .scrollTargetBehavior(.viewAligned)
            .scrollIndicators(.never)
            .frame(height: Self.rowHeight * CGFloat(visible))
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .animation(.easeOut(duration: 0.2), value: visible)
        }
        .background(GeometryReader { g in
            Color.clear.onAppear { width = g.size.width }.onChange(of: g.size.width) { _, w in width = w }
        })
    }

    private var header: some View {
        HStack(spacing: 6) {
            Image(systemName: "chevron.left.forwardslash.chevron.right").font(.system(size: 10.5, weight: .semibold))
                .accessibilityHidden(true)
            Text("Repositories").font(LiaFont.ui(12, .semibold)).accessibilityAddTraits(.isHeader)
            Spacer()
            if repos.count > 1 {
                Button(more ? "Show less" : "Show more") {
                    withAnimation(.easeOut(duration: 0.2)) { more.toggle() }
                }
                .buttonStyle(.liaPlain)
                .font(LiaFont.ui(12, .semibold)).foregroundStyle(HomeInk(scheme).link)
                .liaPointer()
            }
        }
        .foregroundStyle(HomeInk(scheme).text2)
        .shadow(color: HomeInk(scheme).shadow, radius: 3, y: 0.5)
        .padding(.horizontal, 6)
    }
}

private struct HomeRepoRow: View {
    let repo: RepoActivity
    let weeks: Int
    let open: ((URL) -> Void)?
    @State private var hover = false
    @Environment(\.colorScheme) private var scheme
    private var ink: HomeInk { HomeInk(scheme) }

    static let prSlot: CGFloat = 46
    static let countSlot: CGFloat = 70

    var body: some View {
        Button {
            if let u = repo.htmlURL { open?(u) }
        } label: {
            HStack(alignment: .center, spacing: 12) {
                left
                    .frame(maxWidth: .infinity, alignment: .leading)
                prBadge.frame(width: Self.prSlot, alignment: .center)
                if weeks > 0 { HomeContribStrip(weeks: repo.strip(weeks)).fixedSize() }
                counts.frame(width: Self.countSlot, alignment: .trailing)
            }
            .padding(.horizontal, 8)
            .frame(maxHeight: .infinity)
            .background(hover ? WS.hover : Color.clear, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.liaPlain)
        .disabled(repo.htmlURL == nil || open == nil)
        .onHover { hover = $0 && repo.htmlURL != nil }
        .liaPointer()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(spoken))
        .accessibilityHint(Text(repo.htmlURL == nil ? "" : "Opens the repository"))
    }

    private var left: some View {
        VStack(alignment: .leading, spacing: 2) {
            (Text(repo.owner + "/").foregroundColor(ink.text3) + Text(repo.name).foregroundColor(ink.ink).fontWeight(.semibold))
                .font(LiaFont.ui(13))
                .lineLimit(1).truncationMode(.tail)
            Text(RepoRowText.commitLine(repo))
                .font(LiaFont.ui(12)).foregroundStyle(repo.lastCommit == nil ? ink.text3 : ink.text2)
                .lineLimit(1).truncationMode(.tail)
                .help(timeLine)
        }
        .shadow(color: ink.shadow, radius: 3, y: 0.5)
    }

    @ViewBuilder private var prBadge: some View {
        if let t = RepoRowText.prBadge(repo.openPRs) {
            HStack(spacing: 3) {
                Image(systemName: "arrow.triangle.pull").font(.system(size: 10, weight: .semibold))
                Text(t).monospacedDigit()
            }
            .font(LiaFont.ui(12, .semibold)).foregroundStyle(ink.link)
            .padding(.horizontal, 7).frame(height: 22)
            .background(ink.link.opacity(ink.dark ? 0.18 : 0.10), in: Capsule())
            .lineLimit(1)
            .fixedSize()
        } else {
            Color.clear.frame(height: 22)
        }
    }

    private var counts: some View {
        VStack(alignment: .trailing, spacing: 2) {
            Text(RepoRowText.counts(repo))
                .font(LiaFont.ui(12.5, .semibold)).foregroundStyle(ink.ink).monospacedDigit().lineLimit(1)
            Text("7d \u{00b7} 30d").font(LiaFont.ui(10.5)).foregroundStyle(ink.text3).lineLimit(1)
        }
        .shadow(color: ink.shadow, radius: 3, y: 0.5)
    }

    /// "2 hours ago" for the commit line's tooltip.
    private var timeLine: String {
        guard let at = repo.lastCommit?.at else { return "" }
        return min(at, Date()).formatted(.relative(presentation: .named))
    }

    private var spoken: String {
        var s = "\(repo.fullName). \(repo.weekLine), \(repo.commits30d) in 30 days."
        if repo.openPRs > 0 { s += repo.openPRs == 1 ? " 1 open pull request." : " \(repo.openPRs) open pull requests." }
        if let c = repo.lastCommit {
            s += " Last commit: " + RepoRowText.commitLine(repo)
            if !timeLine.isEmpty { s += ", " + timeLine }
            if let a = c.author { s += " by \(a)" }
        }
        return s
    }
}

/// The weeks as squares, oldest first, shaded like GitHub's contributions in our blue (never green).
private struct HomeContribStrip: View {
    let weeks: [Int]
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let top = weeks.max() ?? 0
        HStack(spacing: 2) {
            ForEach(Array(weeks.enumerated()), id: \.offset) { _, n in
                RoundedRectangle(cornerRadius: 2, style: .continuous)
                    .fill(Self.shade(RepoActivity.level(n, max: top), ink: HomeInk(scheme)))
                    .frame(width: 9, height: 9)
            }
        }
        .accessibilityHidden(true)
    }

    static func shade(_ level: Int, ink: HomeInk) -> Color {
        // On a dark sky the lighter blue, so the squares read like the text beside them.
        let blue = ink.dark ? ink.link : WS.blue
        switch level {
        case 0: return ink.track
        case 1: return blue.opacity(0.28)
        case 2: return blue.opacity(0.5)
        case 3: return blue.opacity(0.75)
        default: return blue
        }
    }
}

/// The period's figures: one glass capsule per currency (never one sum across currencies). The first starts with the
/// period, a tap switches it (Today, Yesterday, Last 7 days, Last 30 days, rolling); each figure asks the team to
/// explain it. Spend and cost per lead carry their change against the equal period before, named at the end.
private struct HomeBriefFigures: View {
    let period: BriefPeriod
    /// nil: loading (bars in place of the figures) or failed.
    let groups: [BriefGroup]?
    let failed: Bool
    let switchPeriod: () -> Void
    let ask: (String) -> Void
    @Environment(\.colorScheme) private var scheme
    private var ink: HomeInk { HomeInk(scheme) }

    var body: some View {
        VStack(spacing: 6) {
            if let groups, !groups.isEmpty {
                ForEach(Array(groups.enumerated()), id: \.offset) { i, g in
                    capsule {
                        if i == 0 { periodButton } else {
                            Text(g.currency.map { "In \($0.uppercased()):" } ?? "Other:").foregroundStyle(ink.text2)
                        }
                        HomeBriefGroupFigures(group: g, period: period, ask: ask)
                    }
                    .accessibilityElement(children: .contain)
                    .accessibilityLabel(Text(spoken(g)))
                }
            } else {
                capsule {
                    periodButton
                    if failed {
                        Text("No numbers for this period").foregroundStyle(ink.text3)
                    } else {
                        HomeBriefBars()
                    }
                }
            }
        }
        .transition(.opacity)
    }

    private func capsule<C: View>(@ViewBuilder _ c: () -> C) -> some View {
        HStack(spacing: 6) { c() }
            .font(LiaFont.ui(13))
            .shadow(color: ink.shadow, radius: 3, y: 0.5)
            .padding(.horizontal, 12).frame(height: 30)
            .homeGlass(Capsule())
    }

    /// The period's name and a small up-down mark: a tap moves to the next period.
    private var periodButton: some View {
        HomeBriefPeriodButton(period: period, action: switchPeriod)
    }

    private func spoken(_ g: BriefGroup) -> String {
        var s = BriefText.sentence(g, period: period)
        if let c = BriefText.change(g, period: period) { s += " " + c }
        return s
    }
}

private struct HomeBriefPeriodButton: View {
    let period: BriefPeriod
    let action: () -> Void
    @State private var hover = false
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        Button(action: action) {
            HStack(spacing: 3) {
                Text(period.title + ":")
                Image(systemName: "chevron.up.chevron.down").font(.system(size: 8.5, weight: .semibold))
                    .accessibilityHidden(true)
            }
            .foregroundStyle(HomeInk(scheme).text2)
            .underline(hover, color: HomeInk(scheme).text3)
            .contentShape(Rectangle())
        }
        .buttonStyle(.liaPlain)
        .onHover { hover = $0 }
        .liaPointer()
        .accessibilityLabel(Text("Period: \(period.title)"))
        .accessibilityHint(Text("Switches to \(period.next.title)"))
    }
}

/// One currency's figures: spend (and its change), leads or results, cost per lead (and its change), "vs ...".
private struct HomeBriefGroupFigures: View {
    let group: BriefGroup
    let period: BriefPeriod
    let ask: (String) -> Void
    @Environment(\.colorScheme) private var scheme
    private var ink: HomeInk { HomeInk(scheme) }

    private var s: TourStats { group.stats }
    private var isLeads: Bool { s.leads > 0 }
    private var count: Int { Int(s.outcome.rounded()) }
    private var unit: String { isLeads ? (count == 1 ? "lead" : "leads") : (count == 1 ? "result" : "results") }
    private var spendArrow: String? { BriefText.arrow(group.spendChange) }
    private var costArrow: String? { BriefText.arrow(group.costChange) }

    var body: some View {
        spendFigure
        dot
        HomeBriefFigure(text: "\(count) \(unit)") { ask(isLeads ? "leads" : "results") }
            .accessibilityLabel(Text("\(count) \(unit)"))
        if let c = s.costPer { dot; costFigure(c) }
        // No visible "vs the day before": the arrows carry the change, the period button says which.
    }

    private var dot: some View {
        Text("\u{00b7}").foregroundStyle(ink.text3).accessibilityHidden(true)
    }

    private var spendFigure: some View {
        var text = s.money(s.spend)
        if let a = spendArrow { text += " (\(a))" }
        // Spend going up or down is neither good nor bad news: no tint.
        return HomeBriefFigure(text: text) { ask("spend") }
            .accessibilityLabel(Text("Spend \(s.money(s.spend))" + (group.spendChange.map { ", \(BriefText.pct($0)) \(period.comparison ?? "")" } ?? "")))
    }

    private func costFigure(_ c: Double) -> some View {
        let label = isLeads ? "CPL" : "Cost/result"
        var text = "\(label) \(s.money(c))"
        var tint: Color? = nil
        if let a = costArrow, let p = group.costChange {
            text += " (\(a))"
            tint = p < 0 ? ink.link : ink.warn   // our blue for good news, never green
        }
        let metric = isLeads ? "cost per lead" : "cost per result"
        let spoken = (isLeads ? "Cost per lead " : "Cost per result ") + s.money(c)
            + (group.costChange.map { ", \(BriefText.pct($0)) \(period.comparison ?? "")" } ?? "")
        return HomeBriefFigure(text: text, tint: tint) { ask(metric) }
            .accessibilityLabel(Text(spoken))
            .accessibilityHint(Text("Asks Lia to explain the \(metric) \(period.askSuffix)"))
    }
}

private struct HomeBriefFigure: View {
    let text: String
    var tint: Color?
    let action: () -> Void
    @State private var hover = false
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        Button(action: action) {
            Text(text).font(LiaFont.ui(13, .semibold))
                .foregroundStyle(tint ?? HomeInk(scheme).ink)
                .underline(hover, color: HomeInk(scheme).text3)
                .lineLimit(1)
                .contentShape(Rectangle())
        }
        .buttonStyle(.liaPlain)
        .onHover { hover = $0 }
        .liaPointer()
        .liaTip("Ask Lia to explain")
    }
}

/// Grey bars of the figures' shape while the numbers load (the period button stays beside them).
private struct HomeBriefBars: View {
    @State private var pulse = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: 8) {
            ForEach([64, 58, 96], id: \.self) { w in
                RoundedRectangle(cornerRadius: 4, style: .continuous).fill(WS.line2).frame(width: CGFloat(w), height: 10)
            }
        }
        .opacity(pulse ? 0.55 : 1)
        .onAppear {
            guard !reduceMotion else { return }
            withAnimation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true)) { pulse = true }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("Loading the numbers"))
    }
}
