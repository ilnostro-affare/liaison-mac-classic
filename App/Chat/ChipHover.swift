import SwiftUI
import AppKit

// ("like in Claude"): a chip in an answer shows a small card while the pointer rests on it - a source
// (site, title, favicon), a GitHub branch / pull request / commit (repository, state, base <- head, last commit,
// ahead / behind, preview), a Meta object (kind, name, campaign). The card ignores the mouse; a click on the chip
// still does what it did. GitHub facts come from the blocks the dialogue carried (GitHubRefCache) and Dev's cloned
// repositories (DevRepoStore); nothing is fetched for a hover.

/// The one hover card on screen: a borderless panel over the window that never takes the mouse.
@MainActor
final class ChipHoverHost {
    static let shared = ChipHoverHost()

    private var panel: NSPanel?
    private var hosting: NSHostingView<AnyView>?
    private weak var owner: NSView?
    private weak var window: NSWindow?
    private var current: ChipHover?
    private var anchor: NSRect = .zero
    private var wait: Task<Void, Never>?
    private var monitor: Any?

    /// The pointer came onto a chip: its card after a short rest (the same chip again keeps what shows).
    func hover(_ h: ChipHover, anchor: NSRect, in window: NSWindow?, owner: NSView) {
        if current == h, self.owner === owner, panel?.isVisible == true { return }
        hide()
        self.owner = owner
        self.window = window
        self.current = h
        self.anchor = anchor
        // A GitHub chip's facts are asked for at once; the card waits for them up to a second after its rest
        if case .github(let ref) = h { GitHubRefCache.shared.startFetch(ref) }
        wait = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 350_000_000)
            guard !Task.isCancelled else { return }
            if case .github(let ref) = h {
                let deadline = Date().addingTimeInterval(1.0)
                while Date() < deadline, !Task.isCancelled, GitHubRefCache.shared.isFetching(ref) {
                    try? await Task.sleep(nanoseconds: 50_000_000)
                }
            }
            guard !Task.isCancelled else { return }
            self?.showPending()
        }
    }

    /// The pointer left the chips of `owner`.
    func leave(_ owner: NSView) {
        guard self.owner == nil || self.owner === owner else { return }
        hide()
    }

    /// A click, a scroll, a key: the card goes.
    func dismiss() { hide() }

    private func hide() {
        wait?.cancel(); wait = nil
        current = nil
        owner = nil
        if let p = panel, p.isVisible {
            p.parent?.removeChildWindow(p)
            p.orderOut(nil)
        }
        if let m = monitor { NSEvent.removeMonitor(m); monitor = nil }
    }

    private func showPending() {
        guard let h = current, let w = window, w.isVisible, !DropdownHost.shared.isOpen else { return }
        let p = ensurePanel()
        p.appearance = w.effectiveAppearance
        hosting?.rootView = AnyView(ChipHoverCard(hover: h).padding(1))
        hosting?.layoutSubtreeIfNeeded()
        let size = hosting?.fittingSize ?? NSSize(width: 300, height: 80)
        var x = anchor.minX - 8
        var y = anchor.minY - 6 - size.height
        if let v = (w.screen ?? NSScreen.main)?.visibleFrame.insetBy(dx: 8, dy: 8) {
            x = min(max(x, v.minX), v.maxX - size.width)
            if y < v.minY { y = anchor.maxY + 6 }
        }
        p.setFrame(NSRect(x: x, y: y, width: size.width, height: size.height), display: true)
        if p.parent !== w { p.parent?.removeChildWindow(p); w.addChildWindow(p, ordered: .above) }
        p.orderFront(nil)
        if monitor == nil {
            monitor = NSEvent.addLocalMonitorForEvents(matching: [.scrollWheel, .leftMouseDown, .rightMouseDown, .keyDown]) { e in
                MainActor.assumeIsolated { ChipHoverHost.shared.dismiss() }
                return e
            }
        }
    }

    private func ensurePanel() -> NSPanel {
        if let p = panel { return p }
        let p = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 300, height: 80), styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered, defer: true)
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = false
        p.ignoresMouseEvents = true
        p.isReleasedWhenClosed = false
        p.hidesOnDeactivate = true
        let h = NSHostingView(rootView: AnyView(EmptyView()))
        p.contentView = h
        panel = p
        hosting = h
        return p
    }
}

/// What the card says, by the chip's kind.
struct ChipHoverCard: View {
    let hover: ChipHover

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            switch hover {
            case let .link(title, url, host):
                ChipHoverSource(host: host, title: title, url: url, more: 0)
            case .cite(let group):
                if let c = group.first {
                    ChipHoverSource(host: c.host, title: c.title, url: c.url, more: group.count - 1)
                }
            case .github(let ref):
                ChipHoverGitHub(ref: GitHubRefCache.shared.resolved(ref), info: GitHubRefCache.shared.info(ref))
            case let .entity(name, kind, parent, kids):
                ChipHoverEntity(name: name, kind: kind, parent: parent, kids: kids)
            case .file(let f):
                ChipHoverFile(file: f)
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 10)
        .frame(width: 360, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(AppConfig.ddBg))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(AppConfig.line2, lineWidth: 1))
    }
}

/// A path of Dev's project - its name, its folder, where a click opens it.
private struct ChipHoverFile: View {
    let file: FileRef

    private var folder: String {
        let parts = file.path.split(separator: "/")
        return parts.count > 1 ? parts.dropLast().joined(separator: "/") : "Project"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 6) {
                Image(systemName: ChipSpec.fileSymbol(file)).font(.system(size: 10.5, weight: .semibold)).foregroundStyle(AppConfig.text2)
                Text(verbatim: file.isDir ? "Folder" : folder).font(LiaFont.ui(12)).foregroundStyle(AppConfig.text3)
                    .lineLimit(1).truncationMode(.middle)
            }
            Text(verbatim: file.name).font(LiaFont.ui(13.5, .medium)).foregroundStyle(AppConfig.ink)
                .lineLimit(2).truncationMode(.middle).fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// A web source: favicon and site, the page's title, its address.
private struct ChipHoverSource: View {
    let host: String
    let title: String
    let url: String
    let more: Int
    @State private var icon: NSImage?

    private var site: String {
        var h = host.isEmpty ? (URL(string: url)?.host ?? "") : host
        if h.hasPrefix("www.") { h = String(h.dropFirst(4)) }
        return h
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 7) {
                Group {
                    if let icon { Image(nsImage: icon).resizable().interpolation(.high) } else {
                        Text(verbatim: String(site.prefix(1)).uppercased()).font(LiaFont.inter(8.5, .semibold))
                            .foregroundStyle(AppConfig.text2)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .background(RoundedRectangle(cornerRadius: 4).fill(Color(white: 0.5).opacity(0.26)))
                    }
                }
                .frame(width: 15, height: 15)
                .clipShape(RoundedRectangle(cornerRadius: 4))
                Text(verbatim: site).font(LiaFont.ui(12.5)).foregroundStyle(AppConfig.text3).lineLimit(1)
                if more > 0 {
                    Text(verbatim: "+\(more)").font(LiaFont.ui(11.5)).foregroundStyle(AppConfig.text3)
                }
            }
            Text(verbatim: title.isEmpty ? site : title)
                .font(LiaFont.ui(13.5, .medium)).foregroundStyle(AppConfig.ink)
                .lineLimit(3).fixedSize(horizontal: false, vertical: true)
            Text(verbatim: url).font(LiaFont.ui(11)).foregroundStyle(AppConfig.text3).lineLimit(1).truncationMode(.middle)
        }
        .task(id: site) {
            guard !site.isEmpty else { return }
            if let c = Favicons.cached(site) { icon = c; return }
            let candidates = [URL(string: "https://" + site + "/favicon.ico")].compactMap { $0 }
            icon = await Favicons.icon(host: site, candidates: candidates)
        }
    }
}

/// A branch, a pull request or a commit.
private struct ChipHoverGitHub: View {
    let ref: GitHubRef
    let info: GitHubRefInfo

    private var symbol: String { ChipSpec.gitHubSymbol(ref.kind) }

    /// (Claude's PR card as the reference, for the facts): the state with the kind's glyph in a
    /// pill, the repository and number, the age on the right; the title in bold; the author with their picture and the
    /// size (+added -removed, files) at the bottom; a branch's lead (ahead / behind) under it.
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 7) {
                pill
                Text(verbatim: repoLine).font(LiaFont.ui(12)).foregroundStyle(AppConfig.text3).lineLimit(1).truncationMode(.middle)
                Spacer(minLength: 4)
                if let at = info.lastAt {
                    Text(verbatim: Self.ago(at)).font(LiaFont.ui(11.5)).foregroundStyle(AppConfig.text3).lineLimit(1).fixedSize()
                }
            }
            Text(verbatim: heading).font(LiaFont.ui(14, .semibold)).foregroundStyle(AppConfig.ink)
                .lineLimit(3).fixedSize(horizontal: false, vertical: true)
            if let sub = subline {
                Text(verbatim: sub).font(LiaFont.ui(12)).foregroundStyle(AppConfig.text2).lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if info.author != nil || info.additions != nil || info.files != nil {
                HStack(spacing: 6) {
                    if let a = info.author {
                        AsyncImage(url: info.avatar) { img in img.resizable().interpolation(.high) } placeholder: {
                            Circle().fill(AppConfig.text3.opacity(0.2))
                        }
                        .frame(width: 18, height: 18).clipShape(Circle())
                        Text(verbatim: a).font(LiaFont.ui(12)).foregroundStyle(AppConfig.text3).lineLimit(1)
                    }
                    Spacer(minLength: 6)
                    if info.additions != nil || info.deletions != nil {
                        HStack(spacing: 4) {
                            Text(verbatim: "+" + Self.num(info.additions ?? 0)).foregroundStyle(Color(hex: 0x1A7F37))
                            Text(verbatim: "\u{2212}" + Self.num(info.deletions ?? 0)).foregroundStyle(Color(hex: 0xCF222E))
                        }
                        .font(LiaFont.ui(11.5, .medium))
                        .padding(.horizontal, 7).padding(.vertical, 2)
                        .background(RoundedRectangle(cornerRadius: 6).fill(AppConfig.text3.opacity(0.1)))
                    }
                    if let f = info.files {
                        Text(verbatim: f == 1 ? "1 file" : Self.num(f) + " files").font(LiaFont.ui(11.5)).foregroundStyle(AppConfig.text2)
                            .padding(.horizontal, 7).padding(.vertical, 2)
                            .background(RoundedRectangle(cornerRadius: 6).fill(AppConfig.text3.opacity(0.1)))
                    }
                }
            }
            ForEach(lines, id: \.self) { l in
                Text(verbatim: l).font(LiaFont.ui(11.5)).foregroundStyle(AppConfig.text3).lineLimit(1)
            }
        }
    }

    @ViewBuilder private var pill: some View {
        if let s = info.stateText {
            HStack(spacing: 4) {
                Image(systemName: ref.kind == .branch ? "arrow.triangle.pull" : symbol).font(.system(size: 10, weight: .semibold))
                Text(verbatim: s).font(LiaFont.ui(11.5, .medium))
            }
            .foregroundStyle(stateColor)
            .padding(.horizontal, 7).padding(.vertical, 2)
            .background(Capsule().fill(stateColor.opacity(0.14)))
        } else {
            // no state known (a branch without a pull request, a commit, a repository): the kind in a neutral pill
            HStack(spacing: 4) {
                Image(systemName: symbol).font(.system(size: 10, weight: .semibold))
                Text(verbatim: kindName).font(LiaFont.ui(11.5, .medium))
            }
            .foregroundStyle(AppConfig.text2)
            .padding(.horizontal, 7).padding(.vertical, 2)
            .background(Capsule().fill(AppConfig.text3.opacity(0.14)))
        }
    }

    private var heading: String {
        switch ref.kind {
        case .pr: return info.title ?? ("Pull request #" + String(ref.number ?? 0))
        case .branch: return ref.branch ?? ""
        case .commit: return info.lastMessage ?? ("Commit " + String((ref.sha ?? "").prefix(7)))
        case .repo: return ref.repo.isEmpty ? (info.repo ?? "") : ref.repo
        }
    }

    /// Under the title: a branch's pull request ("#12 Its title") or its last commit; a repository's description.
    private var subline: String? {
        switch ref.kind {
        case .branch:
            if let n = info.prNumber { return "#\(n) " + (info.title ?? "") }
            return info.lastMessage
        case .repo: return info.title
        default: return nil
        }
    }

    private var kindName: String {
        switch ref.kind {
        case .pr: return "Pull request"
        case .branch: return "Branch"
        case .commit: return "Commit"
        case .repo: return "Repository"
        }
    }

    private var repoLine: String {
        var p: [String] = []
        if !ref.repo.isEmpty { p.append(ref.repo) } else if let r = info.repo { p.append(r) }
        if ref.kind == .pr, let n = ref.number { p.append("#\(n)") }
        if ref.kind == .commit, let s = ref.sha { p.append(String(s.prefix(7))) }
        return p.isEmpty ? "GitHub" : p.joined(separator: " ")
    }

    private var lines: [String] {
        var out: [String] = []
        if ref.kind == .branch, let ab = info.aheadBehind { out.append(ab + (info.base.map { " " + $0 } ?? "")) }
        if let c = info.checks { out.append("Checks: " + c) }
        return out
    }

    private var stateColor: Color {
        switch (info.state ?? "").lowercased() {
        case "merged": return Color(hex: 0x8250DF)
        case "closed": return Color(hex: 0xCF222E)
        case "draft": return AppConfig.text3
        default: return Color(hex: 0x1A7F37)
        }
    }

    static func num(_ n: Int) -> String {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        f.locale = Locale(identifier: "en_US")
        return f.string(from: NSNumber(value: n)) ?? String(n)
    }

    static func ago(_ d: Date) -> String {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .short
        f.locale = Locale(identifier: "en_US")
        return f.localizedString(for: d, relativeTo: Date())
    }
}

/// A campaign, ad set or ad: its kind, name and where it sits.
private struct ChipHoverEntity: View {
    let name: String
    let kind: String?
    let parent: String?
    let kids: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            let k = EntityChips.kindNice(kind)
            if !k.isEmpty { Text(verbatim: k).font(LiaFont.ui(11.5, .medium)).foregroundStyle(AppConfig.text3) }
            Text(verbatim: name).font(LiaFont.ui(13.5, .medium)).foregroundStyle(AppConfig.ink)
                .lineLimit(3).fixedSize(horizontal: false, vertical: true)
            if let p = parent { Text(verbatim: "In " + p).font(LiaFont.ui(11.5)).foregroundStyle(AppConfig.text2).lineLimit(2) }
            if kids > 0 {
                Text(verbatim: kids == 1 ? "1 item under it" : "\(kids) items under it").font(LiaFont.ui(11.5)).foregroundStyle(AppConfig.text2)
            }
            Text("Click for details").font(LiaFont.ui(11)).foregroundStyle(AppConfig.text3)
        }
    }
}

// MARK: - what is known about branches and pull requests

/// The GitHub facts the dialogue carried (dev_pr, dev_branch, dev_push blocks), for the app's life; plus Dev's cloned
/// repositories' local branches (ahead counts). Not observed: a hover card reads it when it shows.
@MainActor
final class GitHubRefCache {
    static let shared = GitHubRefCache()
    private var infos: [String: GitHubRefInfo] = [:]
    /// A branch's repository, by the branch's name (a branch named in the text alone finds its repository).
    private var branchRepo: [String: String] = [:]

    func note(_ b: ChatBlock) {
        guard let g = GitHubRefBlock.parse(b) else { return }
        note(g.ref, g.info)
    }

    func note(_ r: GitHubRef, _ i: GitHubRefInfo) {
        infos[r.key] = (infos[r.key] ?? GitHubRefInfo()).merged(i)
        if r.kind == .branch, let b = r.branch, !r.repo.isEmpty { branchRepo[b] = r.repo }
        if r.kind == .branch, let b = r.branch { KnownBranches.shared.add(b) }
        // a PR names its head branch: the branch learns its repository too
        if r.kind == .pr, let h = i.head, !r.repo.isEmpty, branchRepo[h] == nil { branchRepo[h] = r.repo }
        if r.kind == .pr, let h = i.head { KnownBranches.shared.add(h) }
        // The repositories the blocks named make "owner/name" and its commits chips in the text
        if !r.repo.isEmpty { KnownRepos.shared.add(r.repo) }
        if let rp = i.repo { KnownRepos.shared.add(rp) }
    }

    /// A push's commits: a sha of theirs written in the text is a commit chip of that repository.
    private func noteCommits(_ b: ChatBlock) {
        guard let p = DevPush(b), !p.repo.isEmpty else { return }
        for c in p.commits where !c.sha.isEmpty { KnownRepos.shared.addCommit(c.sha, repo: p.repo) }
        if !p.commit.isEmpty { KnownRepos.shared.addCommit(p.commit, repo: p.repo) }
    }

    /// The workspace each branch was last seen in (its repositories are the fallback for a branch named alone).
    private var branchProfile: [String: String] = [:]

    /// Everything a dialogue's messages say about its branches (GitHubDialogue), read when it opens and
    /// as messages come in. A fact the text-only scan found never overrides what a block said.
    func learn(_ entries: [GitHubDialogue.Entry], profile: String) {
        if let ws = WorkspaceModel.current, let p = ws.profiles.first(where: { $0.id == profile }) {
            for r in p.githubRepos { KnownRepos.shared.add(r.fullName) }
        }
        for e in entries { for b in e.blocks { noteCommits(b) } }
        for (ref, info) in GitHubDialogue.links(entries) {
            if let b = ref.branch { branchProfile[b] = profile }
            if ref.repo.isEmpty, ref.kind == .branch, let known = infos[ref.key] {
                // a branch only written in the text: its turn's preview fills what nothing else said
                if known.preview == nil, let p = info.preview { infos[ref.key]?.preview = p }
                continue
            }
            note(ref, info)
        }
    }

    /// The ref with its repository filled in when only the branch was named: a block of the dialogue, a clone holding
    /// the branch, else the workspace's only repository (Workspace Settings > Repositories).
    /// What GitHub itself says about the ref (GET /agents/github/ref, the workspace's GitHub app), merged in once;
    /// one request at a time per ref, a failure not asked again for 2 minutes. A branch learns its repository from it.
    private var inflight: [String: Task<Void, Never>] = [:]
    private var failedAt: [String: Date] = [:]
    /// When GitHub last answered for a ref: asked again after 5 minutes (a pull request gets merged).
    private var fetchedAt: [String: Date] = [:]

    /// `fetch` without waiting for it.
    func startFetch(_ ref: GitHubRef) { Task { @MainActor in await self.fetch(ref) } }

    func fetch(_ ref: GitHubRef) async {
        let r = resolved(ref)
        let k = ref.key
        if let at = fetchedAt[k], Date().timeIntervalSince(at) < 300 { return }
        if let at = failedAt[k], Date().timeIntervalSince(at) < 120 { return }
        if let t = inflight[k] { await t.value; return }
        guard let ws = WorkspaceModel.current, let pid = ws.profile?.id else { return }
        let api = LiaAPI(auth: ws.auth)
        let t = Task { @MainActor [weak self] in
            guard let self else { return }
            if let got = await api.githubRef(profile: pid, r) {
                self.fetchedAt[k] = Date()
                self.note(ref, got)
                if r.key != ref.key { self.note(r, got) }
                if ref.kind == .branch, let b = ref.branch, let repo = got.repo { self.branchRepo[b] = repo }
            } else {
                self.failedAt[k] = Date()
            }
            self.inflight[k] = nil
        }
        inflight[k] = t
        await t.value
    }

    func isFetching(_ ref: GitHubRef) -> Bool { inflight[ref.key] != nil }

    func resolved(_ r: GitHubRef) -> GitHubRef {
        guard r.kind == .branch, r.repo.isEmpty, let b = r.branch else { return r }
        if let repo = branchRepo[b] ?? infos[r.key]?.repo ?? localRepo(of: b)?.slug ?? soleWorkspaceRepo(of: b) {
            return .branch(b, repo: repo)
        }
        return r
    }

    /// The only GitHub repository of the workspace the branch was seen in (or of the one in front).
    private func soleWorkspaceRepo(of branch: String) -> String? {
        guard let ws = WorkspaceModel.current else { return nil }
        let pid = branchProfile[branch] ?? ws.profile?.id
        let repos = ws.profiles.first { $0.id == pid }?.githubRepos ?? []
        return repos.count == 1 ? repos[0].fullName : nil
    }

    func info(_ r: GitHubRef) -> GitHubRefInfo {
        var i = infos[r.key] ?? GitHubRefInfo()
        if r.kind == .branch, let b = r.branch, i.ahead == nil, let local = localRepo(of: b),
           let br = local.branches.first(where: { $0.name == b }) {
            i.ahead = br.ahead
            if i.base == nil, !local.base.isEmpty { i.base = local.base }
        }
        return i
    }

    /// A repository cloned into one of Dev's projects that has this local branch.
    private func localRepo(of branch: String) -> DevRepo? {
        for (_, load) in DevRepoStore.shared.repos {
            guard case .loaded(let list) = load else { continue }
            if let r = list.first(where: { $0.branches.contains { $0.name == branch } || $0.branch == branch }) { return r }
        }
        return nil
    }
}

/// A click on a GitHub chip ("a branch is a GitHub entity, not ours"): its page on GitHub - in the
/// messenger's GitHub popup with the workspace's sign-ins when a messenger is open (SheetGitHubRoute), else the thread's
/// link route (`open`: Peek). ("the blue chips open the site again"): never the site - a
/// block's `url` counts only when it is a github.com page, and a branch whose repository is not known for sure opens
/// the branch search of the likeliest repository (the workspace's, or the ones the dialogue named) on GitHub. Only
/// with no repository known at all does it fall back to the preview.
@MainActor
enum ChipGitHub {
    /// Branch chips whose click waits for their repository (a second click meanwhile is dropped).
    private static var opening: Set<String> = []
    static func open(_ ref: GitHubRef, open: OpenURLAction, devOpen: DevPreviewOpenAction) {
        // A branch whose repository is not known yet asks GitHub first (the hover usually did already)
        // (review: at most 1.5 s of waiting, then the branch search; a second click meanwhile does nothing)
        if ref.kind == .branch, GitHubRefCache.shared.resolved(ref).repo.isEmpty, !GitHubRefCache.shared.info(ref).fetched {
            guard !opening.contains(ref.key) else { return }
            opening.insert(ref.key)
            Task { @MainActor in GitHubRefCache.shared.startFetch(ref) }
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 60_000_000)
                let deadline = Date().addingTimeInterval(1.5)
                while Date() < deadline, GitHubRefCache.shared.isFetching(ref) {
                    try? await Task.sleep(nanoseconds: 50_000_000)
                }
                opening.remove(ref.key)
                openNow(ref, open: open, devOpen: devOpen)
            }
            return
        }
        openNow(ref, open: open, devOpen: devOpen)
    }

    private static func openNow(_ ref: GitHubRef, open: OpenURLAction, devOpen: DevPreviewOpenAction) {
        let r = GitHubRefCache.shared.resolved(ref)
        let info = GitHubRefCache.shared.info(ref)
        let blockURL: URL? = info.url.flatMap { u in
            let h = (u.host ?? "").lowercased()
            return h == "github.com" || h.hasSuffix(".github.com") ? u : nil
        }
        if let u = r.webURL ?? blockURL ?? branchSearch(r) {
            if SheetGitHubRoute.shared.open(u) { return }
            open(u)
            return
        }
        if r.kind == .branch, let p = info.preview {
            // no repository known anywhere: the branch's own preview is all there is
            if DevSites.isPrivatePreview(p) {
                if let run = devOpen.run,
                   let pv = DevPreview(ChatBlock(tool: "dev_preview", data: ["kind": "dev_preview", "url": p.absoluteString,
                                                                            "title": r.branch ?? "Preview"])) {
                    run(pv)
                    return
                }
            } else {
                open(p)
                return
            }
        }
    }
}

extension ChipGitHub {
    /// A branch of a repository not known for sure: GitHub's branch search in the workspace's first repository (or the
    /// first one the dialogues named).
    static func branchSearch(_ r: GitHubRef) -> URL? {
        guard r.kind == .branch, let b = r.branch, !b.isEmpty else { return nil }
        let snap = KnownRepos.shared.snapshot()
        let ws = WorkspaceModel.current?.profile?.githubRepos.map(\.fullName) ?? []
        guard let repo = (ws + snap.preferred + snap.repos).first(where: { GitHubRef.isRepoName($0) }) else { return nil }
        var c = URLComponents(string: "https://github.com/" + repo + "/branches/all")
        c?.queryItems = [URLQueryItem(name: "query", value: b)]
        return c?.url
    }
}

// MARK: - the Meta objects a dialogue named

/// Entity chips in the workspace's stored messages. A stored dialogue message carries no `ents` map
/// (the live turn's `ents` event has it), so «name» (id N) fell back to a grey quote once the turn was stored. The map
/// is kept per dialogue as the turns stream (and on disk, bounded), and a message's own `ents` win when the server
/// sends them.
@MainActor
final class DialogueEnts {
    static let shared = DialogueEnts()
    private var maps: [String: [String: ChatEntity]] = [:]
    private static let cap = 600

    func merge(_ m: [String: ChatEntity], key: String) {
        guard !m.isEmpty else { return }
        var cur = map(key)
        for (k, v) in m { cur[k] = v }
        if cur.count > Self.cap { cur = Dictionary(uniqueKeysWithValues: cur.suffix(Self.cap).map { ($0.key, $0.value) }) }
        maps[key] = cur
        save(key, cur)
    }

    func map(_ key: String?) -> [String: ChatEntity] {
        guard let key else { return [:] }
        if let m = maps[key] { return m }
        let m = load(key)
        maps[key] = m
        return m
    }

    /// What a stored message's chips resolve against: the dialogue's map under the message's own.
    func ents(for message: ChatMessage, key: String?) -> [String: ChatEntity] {
        var out = map(key)
        if let r = message.rawJSON, r.contains("\"ents\""),
           let o = JSONRead.object(Data(r.utf8))?["ents"] as? JSONObject {
            for (k, v) in ChatEntity.map(o) { out[k] = v }
        }
        return out
    }

    private static func defaultsKey(_ key: String) -> String { "lia_dlg_ents_" + key }

    private func save(_ key: String, _ m: [String: ChatEntity]) {
        var o: [String: [String: String]] = [:]
        for (k, e) in m {
            var x = ["n": e.name]
            if let kd = e.kind { x["k"] = kd }
            if let p = e.parent { x["p"] = p }
            o[k] = x
        }
        UserDefaults.standard.set(o, forKey: Self.defaultsKey(key))
    }

    private func load(_ key: String) -> [String: ChatEntity] {
        guard let o = UserDefaults.standard.dictionary(forKey: Self.defaultsKey(key)) else { return [:] }
        return ChatEntity.map(o)
    }
}
