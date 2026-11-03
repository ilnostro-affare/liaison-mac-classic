import SwiftUI
import AppKit

// / Mac 0.2.7: an agent's profile, Telegram-like: the figure, name and role, then what the dialogue holds
// (media, files, links, plans from /agents/items). A 340 pt column the conversation sheet hosts.
// (the product's ask 2): a Favourites tab: the dialogue's messages the person liked (\u{2764}\u{FE0F}), from /agents/marks.

@MainActor
struct AgentProfilePanel: View {
    let ws: WorkspaceModel
    let profile: String
    let dlg: String
    let onJump: (String) -> Void
    let onClose: () -> Void
    /// The conversation's "\u{2026}" menu (Export as Markdown / PDF) beside the close; nil: none.
    let onExport: ((Bool) -> Void)?
    /// A link row: the conversation opens it in the agent's browser on the right; nil: the workspace's browser, else
    /// the default browser.
    let onOpenLink: ((URL) -> Void)?
    /// (Dev's profile): a file of Dev's project opens in the conversation's Canvas, on Code, with it
    /// selected; nil: the rows do not open.
    let onOpenDevFile: ((String) -> Void)?
    /// Dev's preview or live site (Links) opens in the conversation's Canvas (address, title); nil: the agent's browser.
    let onOpenDevPreview: ((URL, String) -> Void)?

    @State private var tab: DlgItem.Kind = .media
    @State private var counts: [String: Int] = [:]
    @State private var items: [DlgItem.Kind: [DlgItem]] = [:]
    @State private var hasMore: [DlgItem.Kind: Bool] = [:]
    @State private var loading: Set<DlgItem.Kind> = []
    @State private var failed: Set<DlgItem.Kind> = []
    /// The Favourites tab is open (it is not a `DlgItem.Kind`: it reads the marks, not /agents/items).
    @State private var favTab = false
    /// The liked marks from the server; nil until the first read.
    @State private var favs: [DlgMark]?
    @State private var favFailed = false
    /// Dev's project files (Files tab of Dev's profile): nil until read; the read wakes Dev's box (slow).
    @State private var devRows: [DevFiles.Row]?
    @State private var devError: String?
    /// The conversation's marks on this Mac: a like given or taken back shows here at once.
    @ObservedObject private var local: ChatLocal

    init(ws: WorkspaceModel, profile: String, dlg: String, onJump: @escaping (String) -> Void, onClose: @escaping () -> Void,
         onExport: ((Bool) -> Void)? = nil, onOpenLink: ((URL) -> Void)? = nil,
         onOpenDevFile: ((String) -> Void)? = nil, onOpenDevPreview: ((URL, String) -> Void)? = nil) {
        self.ws = ws
        self.profile = profile
        self.dlg = dlg
        self.onJump = onJump
        self.onClose = onClose
        self.onExport = onExport
        self.onOpenLink = onOpenLink
        self.onOpenDevFile = onOpenDevFile
        self.onOpenDevPreview = onOpenDevPreview
        _local = ObservedObject(wrappedValue: ChatLocal.shared(profile + "|" + dlg))
    }

    /// Team's dialogue belongs to Lia.
    private var agentId: String { dlg == "team" ? "lia" : dlg }
    private var agent: AgentInfo? { AgentInfo.lookup(agentId, in: ws.roster) }
    /// Dev's profile: Code (its pushes) instead of Plans, and its project's files under Files.
    private var isDev: Bool { agentId == "dev" }
    private var kinds: [DlgItem.Kind] { DlgItem.Kind.profileTabs(agent: agentId) }

    var body: some View {
        VStack(spacing: 0) {
            topBar
            header
            tabs
            Divider().overlay(WS.line)
            content
        }
        .frame(width: 340)
        .frame(maxHeight: .infinity)
        .background(WS.surface)
        .onExitCommand(perform: onClose)
        .task(id: dlg) { await loadCounters() }
        .task(id: "\(dlg)|\(tab.rawValue)") { await loadFirst(tab) }
        .task(id: isDev && tab == .files && !favTab ? "\(dlg)|devfiles" : "") {
            if isDev && tab == .files && !favTab && devRows == nil { await loadDevFiles() }
        }
        .task(id: favTab ? "\(dlg)|\(likedHere)" : "") { if favTab { await loadFavs() } }
    }

    // MARK: - header

    private var topBar: some View {
        HStack(spacing: 6) {
            Spacer()
            if let onExport { moreMenu(onExport) }
            Button(action: onClose) {
                Image(systemName: "xmark").font(.system(size: 11, weight: .bold)).foregroundStyle(WS.text2)
                    .frame(width: 26, height: 26)
                    .background(WS.soft, in: Circle())
            }
            .buttonStyle(.liaPlain)
            .accessibilityLabel(Text("Close"))
        }
        .padding(.horizontal, 14)
        .padding(.top, 12)
    }

    private func moreMenu(_ export: @escaping (Bool) -> Void) -> some View {
        Menu {
            Menu("Export") {
                Button("Markdown\u{2026}") { export(false) }
                Button("PDF\u{2026}") { export(true) }
            }
        } label: {
            Image(systemName: "ellipsis").font(.system(size: 11, weight: .bold)).foregroundStyle(WS.text2)
                .frame(width: 26, height: 26)
                .background(WS.soft, in: Circle())
                .contentShape(Circle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .liaPointer()
        .accessibilityLabel(Text("More actions"))
    }

    private var header: some View {
        VStack(spacing: 6) {
            if let agent {
                AgentAvatar(agent: agent, size: 84)
            }
            Text(agent?.name ?? DlgOrigin.displayName(agentId))
                .font(LiaFont.ui(18, .bold)).foregroundStyle(WS.ink)
            if let role = agent?.shownRole, !role.isEmpty {
                Text(role).font(LiaFont.ui(12, .semibold)).foregroundStyle(WS.blue)
            }
            Text(character).font(LiaFont.ui(12)).foregroundStyle(WS.text2)
                .multilineTextAlignment(.center).lineLimit(2)
                .padding(.horizontal, 24)
        }
        .padding(.bottom, 14)
    }

    /// One line of character: the roster's `bio`; these lines only when an old server sends none.
    private var character: String {
        if let bio = agent?.bio.trimmingCharacters(in: .whitespacesAndNewlines), !bio.isEmpty { return bio }
        switch agentId {
        case "lia": return "Your main partner: talk anything through, research, reports, any errand."
        case "met": return "Reads and changes your Meta ads, always with your Yes."
        case "giggs": return "Google Ads. Not connected yet."
        case "rep": return "Turns numbers into reports you can send."
        case "seara": return "Looks things up on the web for you."
        case "crea": return "Writes and shapes your creatives."
        case "dev": return "Builds your site and shows it to you."
        default: return agent?.shownRole ?? ""
        }
    }

    // MARK: - tabs

    /// A carousel that scrolls sideways when the tabs do not fit (counts reach 1000+), each tab as wide
    /// as its title and count, inset from the capsule's edge.: when they fit, they share the capsule's
    /// width, so the space after the last tab equals the 3 pt before the first.
    private var tabs: some View {
        ScrollViewReader { proxy in
            ViewThatFits(in: .horizontal) {
                segments(fill: true)
                    .background(WS.soft, in: Capsule())
                ScrollView(.horizontal, showsIndicators: false) {
                    segments(fill: false)
                }
                .scrollIndicators(.hidden)
                .background(WS.soft, in: Capsule())
                .clipShape(Capsule())
            }
            .onChange(of: favTab ? "fav" : tab.rawValue) { _, id in
                withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo(id, anchor: .center) }
            }
        }
        .frame(height: 32)
        .padding(.horizontal, 14)
        .padding(.bottom, 10)
    }

    /// The tabs in a row, 3 pt from the capsule's edge; `fill`: each grows to share the width.
    private func segments(fill: Bool) -> some View {
        HStack(spacing: 2) {
            ForEach(kinds, id: \.rawValue) { k in segment(k, fill: fill).id(k.rawValue) }
            favSegment(fill: fill).id("fav")
        }
        .padding(3)
    }

    private func segment(_ k: DlgItem.Kind, fill: Bool) -> some View {
        let on = !favTab && tab == k
        return Button { tab = k; favTab = false } label: {
            segmentLabel(APTab.title(k), count: count(k), on: on, fill: fill)
        }
        .buttonStyle(.liaPlain)
    }

    /// The server's count; Links once fully read counts only the links shown (ours and machines' are hidden).
    private func count(_ k: DlgItem.Kind) -> Int? {
        if k == .links, let l = items[.links], hasMore[.links] != true { return AgentLinks.visible(l).count }
        // Dev's Files: the project's files (once read) and the attachments.
        if isDev, k == .files, let devRows { return devRows.filter { !$0.isDir }.count + (counts[k.rawValue] ?? 0) }
        return counts[k.rawValue]
    }

    private func favSegment(fill: Bool) -> some View {
        Button { favTab = true } label: {
            segmentLabel("Favourites", count: favs.map { favList($0).count }, on: favTab, fill: fill)
        }
        .buttonStyle(.liaPlain)
    }

    private func segmentLabel(_ title: String, count: Int?, on: Bool, fill: Bool) -> some View {
        HStack(spacing: 4) {
            Text(title).font(LiaFont.ui(12, on ? .semibold : .regular)).lineLimit(1)
            if let n = count, n > 0 {
                Text(APTab.compact(n)).font(LiaFont.ui(10.5)).foregroundStyle(WS.text3).monospacedDigit().lineLimit(1)
            }
        }
        .fixedSize()
        .foregroundStyle(on ? WS.ink : WS.text2)
        .padding(.horizontal, 11)
        .frame(maxWidth: fill ? CGFloat.infinity : nil)
        .frame(height: 26)
        .background(on ? WS.surface : Color.clear, in: Capsule())
        .shadow(color: on ? Color.black.opacity(0.08) : .clear, radius: 2, y: 1)
        .contentShape(Capsule())
    }

    // MARK: - content

    @ViewBuilder private var content: some View {
        if favTab { favContent } else { itemsContent }
    }

    @ViewBuilder private var itemsContent: some View {
        if isDev && tab == .files { devFilesContent } else { kindContent }
    }

    @ViewBuilder private var kindContent: some View {
        // Links: only addresses a person would open (never ours, never a machine's); the server filters too.
        let list = tab == .links ? AgentLinks.visible(items[tab] ?? []) : (items[tab] ?? [])
        if list.isEmpty && loading.contains(tab) {
            LiaLoadingOrbit(size: 72, label: "Loading").frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if list.isEmpty && failed.contains(tab) {
            VStack(spacing: 10) {
                Text("Could not load.").font(LiaFont.ui(12)).foregroundStyle(WS.text2)
                Button("Try again") { Task { await loadFirst(tab, force: true) } }.buttonStyle(.bordered)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if list.isEmpty {
            Text(APTab.empty(tab)).font(LiaFont.ui(12)).foregroundStyle(WS.text3)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView {
                if tab == .media { mediaGrid(list) } else { rows(list) }
                if hasMore[tab] == true { moreFooter }
            }
        }
    }

    private func mediaGrid(_ list: [DlgItem]) -> some View {
        let cols = Array(repeating: GridItem(.flexible(), spacing: 3), count: 3)
        return LazyVGrid(columns: cols, spacing: 3) {
            ForEach(list) { it in
                APMediaTile(item: it, url: pictureURL(it), auth: ws.auth) { onJump(it.msgId) }
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
    }

    private func rows(_ list: [DlgItem]) -> some View {
        LazyVStack(alignment: .leading, spacing: 2) {
            ForEach(list) { it in row(it) }
        }
        .padding(.vertical, 6)
    }

    @ViewBuilder private func row(_ it: DlgItem) -> some View {
        switch it.kind {
        case .links:
            if AgentLinks.isDev(it), let u = AgentLinks.link(it) {
                let live = AgentLinks.isLiveSite(it)
                let title = (it.title?.isEmpty == false ? it.title : nil) ?? (live ? "Live site" : "Preview")
                APRow(icon: live ? "globe" : "macwindow", title: title, subtitle: AgentLinks.host(u), date: it.ts,
                      action: { openDevPreview(u, title) }, jump: { onJump(it.msgId) })
                    .liaPointer()
                    .help(u.absoluteString)
                    .contextMenu {
                        Button("Open") { openDevPreview(u, title) }
                        Button("Open in Default Browser") { NSWorkspace.shared.open(u) }
                        Button("Copy Link") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(u.absoluteString, forType: .string)
                        }
                        Button("Show in Chat") { onJump(it.msgId) }
                    }
            } else if let u = AgentLinks.address(it.url) {
                APRow(icon: "link", title: AgentLinks.title(u, served: it.title), subtitle: AgentLinks.host(u), date: it.ts,
                      action: { openLink(u) }, jump: { onJump(it.msgId) })
                    .liaPointer()
                    .help(u.absoluteString)
                    .contextMenu {
                        Button("Open") { openLink(u) }
                        Button("Open in Default Browser") { NSWorkspace.shared.open(u) }
                        Button("Copy Link") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(u.absoluteString, forType: .string)
                        }
                        Button("Show in Chat") { onJump(it.msgId) }
                    }
            }
        case .files:
            APRow(icon: "doc", title: it.name ?? "File", subtitle: APTab.size(it.bytes), date: it.ts,
                  action: { onJump(it.msgId) }, jump: nil)
        case .plans:
            APRow(icon: "list.bullet.rectangle", title: it.title ?? it.name ?? "Plan", subtitle: "", date: it.ts,
                  action: { onJump(it.msgId) }, jump: nil)
        case .media:
            APRow(icon: "photo", title: it.name ?? "Media", subtitle: "", date: it.ts,
                  action: { onJump(it.msgId) }, jump: nil)
        case .code:
            // Dev's push: its compare page on GitHub in the agent's browser; without one, the message.
            let u = AgentLinks.address(it.url)
            APRow(icon: "arrow.triangle.branch", title: it.title ?? "Push", subtitle: it.codeSubtitle, date: it.ts,
                  action: { if let u { openLink(u) } else { onJump(it.msgId) } }, jump: { onJump(it.msgId) })
                .liaPointer()
                .help(u?.absoluteString ?? "")
                .contextMenu {
                    if let u {
                        Button("Open on GitHub") { openLink(u) }
                        Button("Open in Default Browser") { NSWorkspace.shared.open(u) }
                        Button("Copy Link") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(u.absoluteString, forType: .string)
                        }
                    }
                    Button("Show in Chat") { onJump(it.msgId) }
                }
        }
    }

    // MARK: - Dev's files

    /// Dev's project files (flat: name, folder under it), then the dialogue's attachments under their own header.
    @ViewBuilder private var devFilesContent: some View {
        let att = items[.files] ?? []
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 2) {
                if let devRows {
                    let files = devRows.filter { !$0.isDir }
                    if files.isEmpty {
                        Text("Dev's project has no files yet.").font(LiaFont.ui(12)).foregroundStyle(WS.text3)
                            .frame(maxWidth: .infinity).padding(.vertical, 24)
                    }
                    ForEach(files) { r in
                        APRow(icon: APTab.fileIcon(r.name), title: r.name, subtitle: APTab.folder(r.path), date: nil,
                              action: { if let f = onOpenDevFile { f(r.path) } }, jump: nil)
                            .liaPointer()
                            .help(r.path)
                    }
                } else if let devError {
                    VStack(spacing: 10) {
                        Text(devError).font(LiaFont.ui(12)).foregroundStyle(WS.text2).multilineTextAlignment(.center)
                        Button("Try again") { Task { await loadDevFiles() } }.buttonStyle(.bordered)
                    }
                    .frame(maxWidth: .infinity).padding(.vertical, 24).padding(.horizontal, 16)
                } else {
                    VStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("Opening Dev's project\u{2026}").font(LiaFont.ui(12)).foregroundStyle(WS.text3)
                    }
                    .frame(maxWidth: .infinity).padding(.vertical, 24)
                }
                if !att.isEmpty {
                    Text("Attachments").font(LiaFont.ui(11, .semibold)).foregroundStyle(WS.text3)
                        .padding(.horizontal, 14).padding(.top, 12).padding(.bottom, 2)
                    ForEach(att) { it in row(it) }
                }
            }
            .padding(.vertical, 6)
            if hasMore[.files] == true { moreFooter }
        }
    }

    private func loadDevFiles() async {
        devError = nil
        switch await LiaAPI(auth: ws.auth).devFiles(profile: profile) {
        case .success(let entries):
            guard !Task.isCancelled else { return }
            devRows = DevFiles.rows(entries)
        case .failure(let e):
            if !Task.isCancelled { devError = e.message }
        }
    }

    // MARK: - favourites

    @ViewBuilder private var favContent: some View {
        if let favs {
            let list = favList(favs)
            if list.isEmpty && favFailed {
                VStack(spacing: 10) {
                    Text("Could not load.").font(LiaFont.ui(12)).foregroundStyle(WS.text2)
                    Button("Try again") { Task { await loadFavs() } }.buttonStyle(.bordered)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if list.isEmpty {
                Text("Messages you \u{2764}\u{FE0F} show here.").font(LiaFont.ui(12)).foregroundStyle(WS.text3)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        ForEach(list, id: \.id) { m in
                            APRow(icon: "heart.fill", title: Self.favTitle(m), subtitle: "", date: m.messageTs,
                                  action: { onJump(m.id) }, jump: nil)
                        }
                    }
                    .padding(.vertical, 6)
                }
            }
        } else if favFailed {
            VStack(spacing: 10) {
                Text("Could not load.").font(LiaFont.ui(12)).foregroundStyle(WS.text2)
                Button("Try again") { Task { await loadFavs() } }.buttonStyle(.bordered)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            LiaLoadingOrbit(size: 72, label: "Loading").frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    /// The liked messages here: the server's list, corrected by what this Mac changed since (a like taken back is
    /// gone at once, a new one shows before the server's list has it), newest first.
    private func favList(_ server: [DlgMark]) -> [DlgMark] {
        let mine = local.marks
        var out = server.filter { m in mine.isEmpty ? true : (mine[m.id].map(ChatLocal.liked) ?? false) }
        let known = Set(out.map(\.id))
        for m in mine.values where ChatLocal.liked(m) && !known.contains(m.id) { out.append(m) }
        return out.sorted { ($0.messageTs ?? .distantPast) > ($1.messageTs ?? .distantPast) }
    }

    /// The ids liked on this Mac now: the list is read again (a moment later) when they change.
    private var likedHere: String {
        local.marks.values.filter(ChatLocal.liked).map(\.id).sorted().joined(separator: ",")
    }

    /// The message's first line, without Markdown marks.
    nonisolated static func favTitle(_ m: DlgMark) -> String {
        let plain = FeedText.plain(m.text)
        let line = plain.split(whereSeparator: \.isNewline).lazy
            .map { $0.trimmingCharacters(in: .whitespaces) }.first { !$0.isEmpty } ?? ""
        return line.isEmpty ? "Message" : line
    }

    private func loadFavs() async {
        // A like just given or taken back: let its write reach the server first.
        if favs != nil { try? await Task.sleep(nanoseconds: 800_000_000) }
        guard !Task.isCancelled else { return }
        do {
            let all = try await LiaAPI(auth: ws.auth).dialogMarks(profile: profile, dlg: dlg)
            guard !Task.isCancelled else { return }
            favs = all.filter(ChatLocal.liked)
            favFailed = false
        } catch {
            if !Task.isCancelled { favFailed = true }
        }
    }

    private var moreFooter: some View {
        HStack { Spacer(); ProgressView().controlSize(.small); Spacer() }
            .frame(height: 36)
            .onAppear { Task { await loadMore(tab) } }
    }

    // MARK: - links

    /// The agent's browser in the conversation (the sheet's own), else a new tab of the workspace's browser, else the
    /// default browser.
    private func openLink(_ u: URL) {
        if let onOpenLink { onOpenLink(u); return }
        if let b = ws.currentBrowser { b.open(u) } else { NSWorkspace.shared.open(u) }
    }

    /// Dev's preview or live site: the conversation's Canvas, else as any other link.
    private func openDevPreview(_ u: URL, _ title: String) {
        if let onOpenDevPreview { onOpenDevPreview(u, title) } else { openLink(u) }
    }

    /// A media item's picture: the server's address (a signed /intelligence/ path is the AI host's, any other path
    /// the agents worker's), else one rebuilt from a library upload's key. A conversation attachment without a
    /// signed address has none (the server must sign it).
    private func pictureURL(_ it: DlgItem) -> String? {
        let base = (it.url ?? "").hasPrefix("/intelligence/") ? AppConfig.aiBase : AppConfig.agentsBase
        return MediaKeys.pictureURL(url: it.url, key: it.key, base: base)
    }


    // MARK: - loading

    private func loadCounters() async {
        counts = (try? await LiaAPI(auth: ws.auth).searchCounters(profile: profile, dlg: dlg)) ?? [:]
    }

    private func loadFirst(_ k: DlgItem.Kind, force: Bool = false) async {
        if !force, items[k] != nil { return }
        loading.insert(k)
        failed.remove(k)
        defer { loading.remove(k) }
        do {
            let r = try await LiaAPI(auth: ws.auth).items(profile: profile, dlg: dlg, kind: k)
            items[k] = r.items
            hasMore[k] = r.hasMore && !r.items.isEmpty
        } catch {
            if !Task.isCancelled { failed.insert(k) }
        }
    }

    /// The next older page: `before` is the oldest timestamp loaded.
    private func loadMore(_ k: DlgItem.Kind) async {
        guard !loading.contains(k), hasMore[k] == true else { return }
        let loaded = items[k] ?? []
        guard let oldest = loaded.compactMap(\.ts).min() else { hasMore[k] = false; return }
        loading.insert(k)
        defer { loading.remove(k) }
        guard let r = try? await LiaAPI(auth: ws.auth).items(profile: profile, dlg: dlg, kind: k, before: oldest) else {
            hasMore[k] = false
            return
        }
        let known = Set(loaded.map(\.id))
        let fresh = r.items.filter { !known.contains($0.id) }
        items[k] = loaded + fresh
        hasMore[k] = r.hasMore && !fresh.isEmpty
    }
}

/// Tab titles, empty lines, sizes.
enum APTab {
    static func title(_ k: DlgItem.Kind) -> String {
        switch k {
        case .media: return "Media"
        case .files: return "Files"
        case .links: return "Links"
        case .plans: return "Plans"
        case .code: return "Code"
        }
    }
    static func empty(_ k: DlgItem.Kind) -> String {
        switch k {
        case .media: return "No media yet."
        case .files: return "No files yet."
        case .links: return "No links yet."
        case .plans: return "No plans yet."
        case .code: return "Dev's pushes to GitHub show here."
        }
    }
    /// A project file's icon by its type.
    static func fileIcon(_ name: String) -> String {
        switch (name as NSString).pathExtension.lowercased() {
        case "html", "htm": return "chevron.left.forwardslash.chevron.right"
        case "css", "scss": return "paintbrush"
        case "js", "mjs", "ts", "jsx", "tsx", "json": return "curlybraces"
        case "png", "jpg", "jpeg", "gif", "webp", "svg", "ico", "avif": return "photo"
        case "md", "txt": return "doc.text"
        default: return "doc"
        }
    }
    /// The folder a project file is in ("" at the top).
    static func folder(_ path: String) -> String {
        let d = (path as NSString).deletingLastPathComponent
        return d == "." ? "" : d
    }
    /// A tab's count, short: 999, 1.2k, 12k, 1.2M.
    static func compact(_ n: Int) -> String {
        func short(_ v: Double, _ unit: String) -> String {
            let s = v < 10 ? String(format: "%.1f", (v * 10).rounded(.down) / 10) : String(Int(v))
            return (s.hasSuffix(".0") ? String(s.dropLast(2)) : s) + unit
        }
        if n < 1000 { return String(n) }
        if n < 1_000_000 { return short(Double(n) / 1000, "k") }
        return short(Double(n) / 1_000_000, "M")
    }

    static func size(_ bytes: Int?) -> String {
        guard let bytes, bytes > 0 else { return "" }
        return ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
    }
}

/// A square thumbnail through the authorized loader; a video gets a play mark.
@MainActor
private struct APMediaTile: View {
    let item: DlgItem
    let url: String?
    let auth: AuthStore
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            Color.clear
                .aspectRatio(1, contentMode: .fit)
                .overlay { picture }
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay {
                    if item.isVideo {
                        Image(systemName: "play.fill").font(.system(size: 14)).foregroundStyle(Color.white)
                            .shadow(color: .black.opacity(0.4), radius: 3)
                    }
                }
                .opacity(hover ? 0.85 : 1)
                .contentShape(Rectangle())
        }
        .buttonStyle(.liaPlain)
        .onHover { hover = $0 }
        .help(item.name ?? "")
    }

    @ViewBuilder private var picture: some View {
        if let url, !item.isVideo {
            AuthedImage(url: url, auth: auth)
        } else {
            ZStack {
                WS.soft
                Image(systemName: item.isVideo ? "play.rectangle" : "photo").font(.system(size: 18)).foregroundStyle(WS.text3)
            }
        }
    }
}

/// A file, link, plan or push row: icon, title, subtitle, date. `jump` adds a "Show in chat" button (links open on click).
@MainActor
private struct APRow: View {
    let icon: String
    let title: String
    let subtitle: String
    let date: Date?
    let action: () -> Void
    let jump: (() -> Void)?
    @State private var hover = false

    var body: some View {
        HStack(spacing: 10) {
            RoundedRectangle(cornerRadius: 9, style: .continuous).fill(WS.blue.opacity(0.1))
                .frame(width: 34, height: 34)
                .overlay(Image(systemName: icon).font(.system(size: 14, weight: .semibold)).foregroundStyle(WS.blue))
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(LiaFont.ui(12, .semibold)).foregroundStyle(WS.ink).lineLimit(1)
                HStack(spacing: 6) {
                    if !subtitle.isEmpty {
                        Text(subtitle).font(LiaFont.ui(11)).foregroundStyle(WS.text3).lineLimit(1).truncationMode(.middle)
                    }
                    if let date {
                        Text(DSDate.short(date)).font(LiaFont.ui(11)).foregroundStyle(WS.text3).fixedSize()
                    }
                }
            }
            Spacer(minLength: 0)
            if let jump, hover {
                Button(action: jump) {
                    Image(systemName: "arrow.uturn.left").font(.system(size: 11, weight: .semibold)).foregroundStyle(WS.text2)
                        .frame(width: 24, height: 24)
                        .background(WS.surface, in: Circle())
                }
                .buttonStyle(.liaPlain)
                .help("Show in chat")
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(hover ? WS.soft : Color.clear, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .clickable()   // 0.2.11: the hand over the row, like every other clickable row
        .onTapGesture(perform: action)
        .onHover { hover = $0 }
        .padding(.horizontal, 4)
    }
}
