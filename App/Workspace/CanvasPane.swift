import SwiftUI
import AppKit
import WebKit
import os

// The Canvas: what an agent made, on the right of the conversation, in the place of
// the agent's browser. Dev's site now (Preview | Code); other kinds (a document, a design, an animation) later.
// The preview is its own WKWebView with a non-persistent store: the Liaison session never enters it, and none of our
// scripts run in the page's world (design rule: our scripts never enter the page world); Select element (DevPickerLayer, 0.2.11) reads Dev's own pages
// from BrowserModel.agentWorld only.

/// Each dialogue's Canvas, kept for the app's life (as the agent browsers are): open or not, its tab and width.
@MainActor
final class CanvasStore: ObservableObject {
    static let shared = CanvasStore()

    @Published private(set) var states: [String: CanvasState] = [:]
    /// The width last chosen in a dialogue, kept when its Canvas closes.
    private var mobile: [String: Bool] = [:]
    /// Each dialogue's newest preview or live site (TeamChatModel.latestDevPage): the Preview tab of
    /// an item with no page of its own (Changes, a push, Dev working now).
    private var pages: [String: URL] = [:]
    /// Each dialogue's newest PRIVATE preview: the Preview side of a live site's item (CanvasLiveChoice).
    private var privatePages: [String: URL] = [:]
    /// The person's Preview / Live per item (CanvasLiveChoice.key) and per live site ("site|host"),
    /// kept across launches.
    private var choices: [String: Bool]
    private static let choicesKey = "lia_canvas_live_choices"

    init() {
        choices = (UserDefaults.standard.dictionary(forKey: Self.choicesKey) as? [String: Bool]) ?? [:]
    }

    func state(_ key: String) -> CanvasState? { states[key] }

    /// The dialogue's newest page, as its model knows it (nil changes nothing).
    func notePage(_ url: URL?, key: String) {
        guard let url else { return }
        pages[key] = url
        if DevSites.isPrivatePreview(url) { privatePages[key] = url }
    }

    /// The dialogue's newest page and newest private preview (the latter read from its messages once, then kept).
    func note(_ chat: TeamChatModel) {
        notePage(chat.latestDevPage, key: chat.key)
        _ = privatePreview(chat)
    }

    /// The dialogue's newest private preview (a Dev card's Preview link).
    func privatePreview(_ chat: TeamChatModel) -> URL? {
        if let u = privatePages[chat.key] { return u }
        let u = chat.latestDevPreview
        if let u { privatePages[chat.key] = u }
        return u
    }

    /// The page an item without one shows: the dialogue's newest, else the workspace's live site (DevSites).
    private func fallback(_ key: String, profile: String?) -> URL? {
        pages[key] ?? profile.flatMap { DevSitesStore.shared.sites[$0]?.live?.url }
    }

    private func prepared(_ item: CanvasItem, key: String) -> CanvasItem {
        item.withPage(fallback(key, profile: item.profile)).withPrivatePage(privatePages[key])
    }

    /// The person's pick for this item: by the item, else by its live site; `explicit`: the person opened a live
    /// site's own card (that is choosing Live).
    private func remembered(_ item: CanvasItem, explicit: Bool) -> Bool? {
        if let c = choices[CanvasLiveChoice.key(profile: item.profile, item: item.id)] { return c }
        let ch = item.liveChoice(chosen: nil)
        if let h = ch.site?.host?.lowercased() {
            if let c = choices["site|" + h] { return c }
            if explicit && ch.showsSwitch { return true }
        }
        return nil
    }

    /// The state with the item's own pick applied (another item than the one shown starts from its own).
    private func applyChoice(_ s: inout CanvasState, previous: CanvasState?, explicit: Bool) {
        if previous?.item.id == s.item.id, previous?.live != nil { return }
        s.live = remembered(s.item, explicit: explicit)
    }

    /// Opens `item` in the dialogue's Canvas, or reloads it when it already shows that page.
    func open(_ item: CanvasItem, key: String) {
        let item = prepared(item, key: key)
        var s = CanvasState.opening(item, over: states[key])
        if states[key] == nil, let m = mobile[key] { s.mobile = m }
        applyChoice(&s, previous: states[key], explicit: true)
        states[key] = s
    }

    /// A preview that arrived live: opened (or reloaded) and brought to the front on Preview.
    func arrive(_ item: CanvasItem, key: String) {
        if item.kind == .devPreview, let u = item.previewURL {
            pages[key] = u
            if DevSites.isPrivatePreview(u) { privatePages[key] = u }
        }
        let item = prepared(item, key: key)
        var s = CanvasState.arriving(item, over: states[key])
        if states[key] == nil, let m = mobile[key] { s.mobile = m }
        applyChoice(&s, previous: states[key], explicit: false)
        states[key] = s
    }

    /// Dev started working in this dialogue: the Canvas opens on its Activity (with the newest page as Preview).
    func showActivity(key: String, profile: String?) {
        var s = CanvasState.activity(profile: profile, page: pages[key], over: states[key])
        s.item = s.item.withPrivatePage(privatePages[key])
        if states[key] == nil, let m = mobile[key] { s.mobile = m }
        applyChoice(&s, previous: states[key], explicit: false)
        states[key] = s
    }

    /// A file of Dev's project picked in the profile: the Canvas shows it on Code, "All files".
    func focusFile(_ path: String, profile: String, key: String) {
        var s = CanvasState.focusing(path, profile: profile, over: states[key])
        if states[key] == nil, let m = mobile[key] { s.mobile = m }
        states[key] = s
    }

    /// Preview (false) or Live (true) picked in the Canvas: kept for the item and for the live site it shows.
    func setLive(_ on: Bool, key: String) {
        guard var s = states[key] else { return }
        s.live = on
        states[key] = s
        let ch = s.item.liveChoice(chosen: on)
        choose(on, item: s.item, site: ch.site ?? s.item.profile.flatMap { DevSitesStore.shared.sites[$0]?.live?.url })
    }

    /// The person's pick made before the item opens (a card's Preview / Live link).
    func choose(_ on: Bool, item: CanvasItem, site: URL? = nil) {
        choices[CanvasLiveChoice.key(profile: item.profile, item: item.id)] = on
        let own = item.liveChoice(chosen: on).site ?? site
        if let h = own?.host?.lowercased() { choices["site|" + h] = on }
        if choices.count > 400 { choices = Dictionary(uniqueKeysWithValues: choices.suffix(300).map { ($0.key, $0.value) }) }
        UserDefaults.standard.set(choices, forKey: Self.choicesKey)
    }

    /// Closes it: the right side shows what it showed before (the agent's browser).
    func close(_ key: String) {
        if let s = states[key] { mobile[key] = s.mobile }
        states[key] = nil
    }

    func update(_ key: String, _ change: (inout CanvasState) -> Void) {
        guard var s = states[key] else { return }
        change(&s)
        states[key] = s
    }
}

extension TeamChatModel {
    /// The newest private preview (pv-...) among the loaded messages (nil: none).
    var latestDevPreview: URL? {
        for it in items.reversed() {
            for b in it.message.blocks.reversed() {
                if let u = CanvasItem.page(of: b), DevSites.isPrivatePreview(u) { return u }
            }
        }
        return nil
    }
}

/// The panel: a header (title, Preview | Activity | Code, Reload, width, Open in browser, Close) over the preview, the
/// activity or the code.: what it shows is one of Dev's artifacts (each with its own activity and changes), or
/// Dev working now; a push has Changes | Activity and Open on GitHub.
struct CanvasPane: View {
    let state: CanvasState
    let auth: AuthStore
    let onTab: (CanvasState.Tab) -> Void
    let onMobile: (Bool) -> Void
    let onReload: () -> Void
    let onOpenInBrowser: (URL) -> Void
    let onClose: () -> Void
    /// Dev's steps (the Activity tab) and what it is doing now.
    var activity = DevActivity()
    var working = false
    /// "What did Dev do?" (nil: no button).
    var onHistory: (() -> Void)? = nil
    /// Preview (false) or Live (true) picked by the person; kept per item by the store.
    var onLive: (Bool) -> Void = { _ in }
    /// The item's title (a branch path) and Open on GitHub are in the sheet's top bar
    /// (CanvasHeaderCrumb), so the tabs here keep their room. false: drawn here, as before.
    var titleInSheet = false
    /// Folds the right side to a spine (the conversation sheet); nil: no button.
    var onFold: (() -> Void)? = nil
    @ObservedObject var siteStore = DevSitesStore.shared
    /// ("opening an agent must be instant"): the heavy panes (the web view, the diff, the file list)
    /// are built once the sheet's opening animation is over; until then a light placeholder stands in.
    @State var settled = false

    var body: some View {
        VStack(spacing: 10) {
            header
            stage
        }
        .padding(12)
        .background(Color.dyn(0x15181C, 0xF6F7F9))
        .overlay { ComposerFileOverlay(auth: auth) }   // A composer file opens over the preview and the web
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text("Canvas: \(state.item.title)"))
        .task {
            guard !settled else { return }
            try? await Task.sleep(nanoseconds: 280_000_000)
            settled = true
        }
    }

    private var item: CanvasItem { state.item }

    private var headerSymbol: String { Self.symbol(for: item) }

    /// The item's figure (the header's, the sheet's top bar's).
    static func symbol(for item: CanvasItem) -> String {
        switch item.kind {
        case .devPreview: return item.title.hasPrefix("Live site") ? "globe" : "macwindow"
        case .activity: return "list.bullet.rectangle"
        case .devWork: return "pencil.line"
        case .devPush: return "arrow.triangle.branch"
        case .images: return "photo.on.rectangle"
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            if !titleInSheet {
                Image(systemName: headerSymbol).font(.system(size: 13, weight: .medium))
                    .foregroundStyle(WS.text2)
                    .accessibilityHidden(true)
                Text(verbatim: item.title).font(LiaFont.ui(13, .semibold)).foregroundStyle(WS.ink).lineLimit(1).truncationMode(.tail)
            }
            if state.tabs.count > 1 {
                CanvasTabs(tab: state.tab, tabs: state.tabs, working: working && item.kind == .activity,
                           codeTitle: item.kind == .devPush ? "Changes" : "Code", onPick: onTab)
                    .padding(.leading, titleInSheet ? 0 : 4)
                    .fixedSize()
            }
            Spacer(minLength: 8)
            if !titleInSheet, item.kind == .devPush, let u = item.push?.url {
                // A push's compare page on GitHub (kept beside the project's Preview).
                Button("Open on GitHub") { onOpenInBrowser(u) }
                    .buttonStyle(ChatCapsuleButtonStyle(primary: false))
                    .liaHoverWash(Capsule())
            }
            if item.kind == .images {
                // Crea's actions live on the Studio's node toolbar (CreaStudioView); none duplicated here.
                EmptyView()
            } else if state.tab == .activity {
                if let onHistory { icon("clock.arrow.circlepath", label: "What did Dev do?", action: onHistory) }
            } else if state.tab == .preview {
                if choice.showsSwitch {
                    CanvasLiveSwitch(live: Binding(get: { choice.live }, set: { onLive($0) }))
                }
                icon("arrow.clockwise", label: "Reload", action: onReload)
                icon(state.mobile ? "iphone" : "desktopcomputer",
                     label: state.mobile ? "Mobile width. Switch to desktop" : "Desktop width. Switch to mobile",
                     active: state.mobile) { onMobile(!state.mobile) }
            } else if item.kind != .devPush {
                icon("arrow.clockwise", label: "Reload files", action: onReload)
            }
            if let u = openURL {
                icon("arrow.up.forward.app", label: "Open in browser") { onOpenInBrowser(u) }
            }
            icon("xmark", label: "Close", kbd: nil, action: onClose)
            if let onFold { icon("sidebar.right", label: "Hide the canvas", kbd: "\u{2318}\u{2325}B", action: onFold) }
        }
    }

    private func icon(_ symbol: String, label: String, kbd: String? = nil, active: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 12.5, weight: .medium)).foregroundStyle(active ? SettingsLook.accent : WS.text2)
                .frame(width: 28, height: 28)
                .background(active ? SettingsLook.accentSoft : WS.surface, in: Circle())
                .overlay(Circle().stroke(WS.line, lineWidth: active ? 0 : 1))
                .contentShape(Circle())
        }
        .buttonStyle(.liaPlain)
        .liaHoverWash(Circle())   // Reload, the width switch, Open in browser, Close
        .liaTip(["arrow.clockwise", "arrow.up.forward.app", "xmark"].contains(symbol) ? nil : label, kbd: kbd)
        .accessibilityLabel(Text(label))
    }

    private func boardContext(_ b: CreaBoard) -> CreaContext? {
        guard let p = b.chatProfile, let d = b.chatDlg else { return nil }
        return CreaContext(profile: p, dlg: d)
    }

    /// /: one Preview | Live per Dev item, decided from its data (CanvasLiveChoice): a private
    /// preview opens on Preview; a published site shows both when the dialogue's private preview is known (Live only
    /// when the person picked it); a site with no preview known shows Live alone. Every Dev item (a card, its work, its
    /// steps, a push, Dev working now) gets the same switch and the publish bar.
    private var choice: CanvasLiveChoice { item.liveChoice(chosen: state.live) }
    /// Open in browser: never our private preview address - the live site when Live shows one.
    private var openURL: URL? {
        let c = choice
        if c.live {
            if let s = c.site { return s }
            return item.profile.flatMap { siteStore.sites[$0]?.live?.url }
        }
        guard let u = c.preview else { return nil }
        return DevSites.isPrivatePreview(u) ? nil : u
    }

    private var stage: some View {
        let c = choice
        return ZStack {
            WS.surface
            if !settled && state.tab != .images {
                Color.clear
            } else {
                stageContent(c)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).stroke(WS.line, lineWidth: 1))
    }

    @ViewBuilder private func stageContent(_ c: CanvasLiveChoice) -> some View {
        if let u = c.preview {
            CanvasPreview(url: u, reloads: state.reloads, mobile: state.mobile, auth: auth, profile: item.profile)
                .opacity(state.tab == .preview && !c.live ? 1 : 0)
                .allowsHitTesting(state.tab == .preview && !c.live)
                .accessibilityHidden(state.tab != .preview || c.live)
        }
        if state.tab == .preview && c.live, let p = item.profile {
            CanvasLive(auth: auth, profile: p, reloads: state.reloads, mobile: state.mobile, own: c.site)
        }
        if state.tab == .images, let b = item.board {
            CanvasImageBoard(board: b, auth: auth, refits: state.reloads, ctx: boardContext(b)) { id in
                guard let p = b.chatProfile, let d = b.chatDlg else { return }
                CanvasStore.shared.update(p + "|" + d) { s in
                    if s.item.kind == .images, s.item.board?.id == b.id { s.item.board?.selected = id }
                }
            }
            .id(item.id)
        }
        if state.tab == .code {
            CanvasCodeTab(auth: auth, item: item, reloads: state.reloads, focusPath: state.focusPath, focusSeq: state.focusSeq,
                          onOpenOnGitHub: onOpenInBrowser).id(item.id)
        }
        if state.tab == .activity {
            VStack(spacing: 0) {
                DevEditsActivity(auth: auth, profile: item.profile)   // 0.2.11: Select element's tasks
                if item.kind == .activity {
                    CanvasActivity(activity: activity, working: working)
                } else {
                    CanvasArtActivity(auth: auth, item: item, reloads: state.reloads).id(item.id)
                }
            }
        }
    }
}

// MARK: - Live

/// The workspace's live sites per project, read when Live opens and again after a publish.
@MainActor
final class DevSitesStore: ObservableObject {
    static let shared = DevSitesStore()
    @Published private(set) var sites: [String: DevSites] = [:]
    @Published private(set) var errors: [String: String] = [:]
    @Published private(set) var publishing: Set<String> = []

    private var reading: Set<String> = []

    /// Reads the project's sites unless they are known or being read (a Dev card's Live link asks this).
    func loadOnce(auth: AuthStore, profile: String) async {
        guard sites[profile] == nil, !reading.contains(profile) else { return }
        reading.insert(profile)
        defer { reading.remove(profile) }
        await load(auth: auth, profile: profile)
    }

    func load(auth: AuthStore, profile: String) async {
        switch await LiaAPI(auth: auth).devSites(profile: profile) {
        case .success(let s): sites[profile] = s; errors[profile] = nil
        case .failure(let e): if sites[profile] == nil { errors[profile] = e.message }
        }
    }

    /// The person's click: asks first (the site is public), then publishes the previewed folder.
    func publish(auth: AuthStore, profile: String, to site: DevSite?, next: DevSite?) async {
        let target = site ?? next
        let a = NSAlert()
        a.messageText = site == nil ? "Publish this site?" : "Update the live site?"
        a.informativeText = "It goes live at \(target?.url.host ?? "the workspace\u{2019}s address"), for anyone who has the address."
        a.addButton(withTitle: site == nil ? "Publish" : "Update")
        a.addButton(withTitle: "Cancel")
        guard a.runModal() == .alertFirstButtonReturn else { return }
        errors[profile] = nil   // a failure from before does not stay under the new attempt
        publishing.insert(profile)
        defer { publishing.remove(profile) }
        switch await LiaAPI(auth: auth).devPublish(profile: profile, site: site?.slug, name: site == nil ? next?.slug : nil) {
        case .success: errors[profile] = nil; await load(auth: auth, profile: profile)
        case .failure(let e): errors[profile] = e.message
        }
    }
}

/// Preview | Live, the small switch beside Reload.
private struct CanvasLiveSwitch: View {
    @Binding var live: Bool
    var body: some View {
        HStack(spacing: 2) {
            seg("Preview", !live) { live = false }
            seg("Live", live) { live = true }
        }
        .padding(2)
        .background(WS.ink.opacity(0.06), in: Capsule())
        .accessibilityElement(children: .contain)
    }
    private func seg(_ t: String, _ on: Bool, _ act: @escaping () -> Void) -> some View {
        Button(action: act) {
            Text(t).font(LiaFont.ui(11.5, .medium)).foregroundStyle(on ? WS.ink : WS.text2)
                .padding(.horizontal, 9).frame(height: 22)
                .background(on ? WS.surface : Color.clear, in: Capsule())
                .contentShape(Capsule())
                .liaHoverWash(Capsule(), enabled: !on)   // the unselected side only
        }
        .buttonStyle(.liaPlain)
        .liaPointer()
        .accessibilityAddTraits(on ? .isSelected : [])
    }
}

/// Live: the site itself, or (not live yet) where it would go live and Publish.
private struct CanvasLive: View {
    let auth: AuthStore
    let profile: String
    let reloads: Int
    let mobile: Bool
    /// The item's own live site (a "Live site" card): shown as it is, whatever the registry says.
    var own: URL? = nil
    @ObservedObject private var store = DevSitesStore.shared

    var body: some View {
        Group {
            if let own {
                VStack(spacing: 0) {
                    CanvasPreview(url: own, reloads: reloads, mobile: mobile, auth: auth, profile: profile)
                    // the publish bar only for a site the registry knows (its slug is what Update names)
                    if let s = store.sites[profile], let site = s.sites.first(where: { $0.url.host?.lowercased() == own.host?.lowercased() }) {
                        bar(site: site, sites: s)
                    }
                }
            } else if let s = store.sites[profile] {
                if let site = s.live {
                    VStack(spacing: 0) {
                        CanvasPreview(url: site.url, reloads: reloads, mobile: mobile, auth: auth, profile: profile)
                        bar(site: site, sites: s)
                    }
                } else if s.canPublish {
                    note(title: "Not live yet",
                         text: "It goes live at \(s.next?.url.host ?? "the workspace\u{2019}s address"). Anyone with the address can open it.",
                         button: "Publish") { Task { await store.publish(auth: auth, profile: profile, to: nil, next: s.next) } }
                } else {
                    note(title: "Not live yet", text: "Ask Dev to build and publish this site.", button: nil, action: {})
                }
            } else if let e = store.errors[profile] {
                CanvasNote(words: e, bad: true) { Task { await store.load(auth: auth, profile: profile) } }
            } else {
                CanvasSpinner(words: "Reading the live site\u{2026}")
            }
        }
        .task(id: reloads) { await store.load(auth: auth, profile: profile) }
    }

    /// Under a live site: its address and Update (publishes the preview over it).
    private func bar(site: DevSite, sites: DevSites) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "globe").font(.system(size: 11)).foregroundStyle(WS.text3).accessibilityHidden(true)
            Text(verbatim: site.url.host ?? site.slug).font(LiaFont.ui(12)).foregroundStyle(WS.text2).lineLimit(1).textSelection(.enabled)
            if let e = store.errors[profile] { Text(verbatim: e).font(LiaFont.ui(11.5)).foregroundStyle(WS.bad).lineLimit(1) }
            Spacer(minLength: 4)
            DevLivePublishButtons(auth: auth, profile: profile, site: site, sites: sites)
        }
        .padding(.horizontal, 12).frame(height: 36)
        .background(WS.surface)
        .overlay(alignment: .top) { Rectangle().fill(WS.line).frame(height: 1) }
    }

    private func note(title: String, text: String, button: String?, action: @escaping () -> Void) -> some View {
        VStack(spacing: 10) {
            Image(systemName: "globe").font(.system(size: 22)).foregroundStyle(WS.text3).accessibilityHidden(true)
            Text(title).font(LiaFont.ui(14, .semibold)).foregroundStyle(WS.ink)
            Text(text).font(LiaFont.ui(12.5)).foregroundStyle(WS.text2).multilineTextAlignment(.center).frame(maxWidth: 320)
            if let e = store.errors[profile] { Text(verbatim: e).font(LiaFont.ui(12)).foregroundStyle(WS.bad).multilineTextAlignment(.center).frame(maxWidth: 320) }
            if let button {
                Button(store.publishing.contains(profile) ? "Publishing\u{2026}" : button, action: action)
                    .buttonStyle(ChatCapsuleButtonStyle())
                    .disabled(store.publishing.contains(profile))
                    .liaPointer()
                    .padding(.top, 4)
            }
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// The Canvas item's title in the conversation sheet's top bar beside search and the mode switch; a
/// push's is one chip, its branch, that opens the branch on GitHub. The title is cut in the middle; its tip is whole.
struct CanvasHeaderCrumb: View {
    let item: CanvasItem
    /// A push's branch chip: its GitHub page (the sheet shows it in a popup over the messenger).
    let onOpenInBrowser: (URL) -> Void

    var body: some View {
        if item.kind == .devPush, let u = item.push?.url {
            branchChip(u)
        } else {
            plainTitle
        }
    }

    private var plainTitle: some View {
        HStack(spacing: 6) {
            Image(systemName: CanvasPane.symbol(for: item)).font(.system(size: 12, weight: .medium))
                .foregroundStyle(WS.text2)
                .accessibilityHidden(true)
            Text(verbatim: item.title).font(LiaFont.ui(13, .semibold)).foregroundStyle(WS.ink)
                .lineLimit(1).truncationMode(.middle)
        }
        // Flush right in its frame, so the words sit beside search (leading left a gap before it)
        .frame(maxWidth: 280, alignment: .trailing)
        .liaTip(item.title)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text("Canvas: \(item.title)"))
    }

    /// the branch and "Open on GitHub" were two things far apart; now the branch itself is the
    /// one chip (branch icon + name) and a click opens its GitHub page.
    private func branchChip(_ u: URL) -> some View {
        Button { onOpenInBrowser(u) } label: {
            HStack(spacing: 5) {
                Image(systemName: "arrow.triangle.branch").font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(WS.text2)
                Text(verbatim: item.title).lineLimit(1).truncationMode(.middle)
            }
        }
        .buttonStyle(ChatCapsuleButtonStyle(primary: false))
        .liaHoverWash(Capsule())   // the chip reacts to the pointer, in its own capsule
        // Flush right in its frame, beside search (the 300 pt frame centred it, with a gap)
        .frame(maxWidth: 300, alignment: .trailing)
        .fixedSize(horizontal: false, vertical: true)
        .liaTip("Open \(item.push?.route ?? item.title) on GitHub")
        .latencyID("canvas.branch")
        .accessibilityLabel(Text("Branch \(item.title). Open on GitHub"))
    }
}

/// Site | Activity | Code, as a small segmented control in the app's look (a dot on Activity while Dev works).
private struct CanvasTabs: View {
    let tab: CanvasState.Tab
    var tabs: [CanvasState.Tab] = [.preview, .activity, .code]
    var working = false
    /// "Code", or "Changes" for a push.
    var codeTitle = "Code"
    let onPick: (CanvasState.Tab) -> Void

    var body: some View {
        HStack(spacing: 2) {
            ForEach(tabs, id: \.self) { t in seg(title(t), t) }
        }
        .padding(2)
        .background(WS.ink.opacity(0.06), in: Capsule())
        .accessibilityElement(children: .contain)
    }

    private func title(_ t: CanvasState.Tab) -> String {
        switch t {
        // "Site", not "Preview" - "Preview" is one side of the Preview | Live switch beside it.
        case .preview: return "Site"
        case .code: return codeTitle
        case .activity: return "Activity"
        case .images: return "Images"
        }
    }

    private func seg(_ title: String, _ t: CanvasState.Tab) -> some View {
        Button { onPick(t) } label: {
            HStack(spacing: 5) {
                if t == .activity && working {
                    Circle().fill(SettingsLook.accent).frame(width: 5, height: 5).accessibilityHidden(true)
                }
                Text(title).font(LiaFont.ui(12, .medium)).foregroundStyle(tab == t ? WS.ink : WS.text2)
            }
                .padding(.horizontal, 11).frame(height: 24)
                .background(tab == t ? WS.surface : Color.clear, in: Capsule())
                .shadow(color: tab == t ? Color.black.opacity(0.08) : .clear, radius: 2, y: 1)
                .contentShape(Capsule())
                .liaHoverWash(Capsule(), enabled: tab != t)   // the unselected tabs only
        }
        .buttonStyle(.liaPlain)
        .liaPointer()
        .accessibilityAddTraits(tab == t ? .isSelected : [])
    }
}

// MARK: - Preview

/// The page, full width or 390 pt (a phone) centred, with a thin progress line while it loads. Any http(s) address
/// loads as it is (Dev's previews have their own host, `https://pv-<token>.liaisone.com/`, and need no cookie). A
/// failed load shows why, with Try again.
private struct CanvasPreview: View {
    let url: URL
    let reloads: Int
    let mobile: Bool
    /// 0.2.11: Select element on Dev's own pages (the edit goes to this workspace's Dev).
    var auth: AuthStore? = nil
    var profile: String? = nil
    @State private var loading = false
    @State private var failed: String?
    /// Bumped by Try again: the address loads afresh.
    @State private var attempt = 0
    @StateObject private var picker = DevPickerModel()

    var body: some View {
        ZStack(alignment: .top) {
            (mobile ? WS.soft : WS.surface)
            CanvasWebView(url: url, reloads: reloads, attempt: attempt, loading: $loading, failed: $failed, picker: picker)
                .overlay { DevPickerLayer(model: picker, url: url, auth: auth, profile: profile, isLoading: loading) }
                .frame(maxWidth: mobile ? 390 : .infinity)
                .overlay(alignment: .leading) { if mobile { Rectangle().fill(WS.line).frame(width: 1) } }
                .overlay(alignment: .trailing) { if mobile { Rectangle().fill(WS.line).frame(width: 1) } }
            if loading {
                ProgressView().progressViewStyle(.linear).tint(SettingsLook.accent).frame(height: 2).padding(.horizontal, 0)
                    .accessibilityLabel(Text("Loading"))
            }
            if let f = failed {
                CanvasLoadError(detail: f) { failed = nil; attempt += 1 }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(WS.surface)
                    .transition(.opacity)
            }
        }
    }
}

/// The preview did not load: what happened (the system's words) and Try again.
private struct CanvasLoadError: View {
    let detail: String
    let onRetry: () -> Void

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle").font(.system(size: 22, weight: .regular)).foregroundStyle(WS.text3)
                .accessibilityHidden(true)
            Text("The preview didn\u{2019}t load").font(LiaFont.ui(14, .semibold)).foregroundStyle(WS.ink)
            Text(verbatim: detail).font(LiaFont.ui(12.5)).foregroundStyle(WS.text2)
                .multilineTextAlignment(.center).lineLimit(4).textSelection(.enabled)
                .frame(maxWidth: 320)
            Button("Try again", action: onRetry)
                .buttonStyle(ChatCapsuleButtonStyle())
                .liaPointer()
                .padding(.top, 4)
        }
        .padding(24)
        .accessibilityElement(children: .contain)
    }
}

/// The preview's web view: its own non-persistent store, no scripts of ours, links stay in it. A new address loads;
/// the same address with a new `reloads` reloads from the server (Dev changed the site); a new `attempt` (Try again)
/// loads the address afresh. A provisional failure is tried once more by itself after 1 s (the project's box may be
/// waking); every failure is logged with its domain, code and description.
private struct CanvasWebView: NSViewRepresentable {
    let url: URL
    let reloads: Int
    var attempt = 0
    @Binding var loading: Bool
    @Binding var failed: String?
    /// 0.2.11: Select element reads this web view (agent world only).
    var picker: DevPickerModel? = nil

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> WKWebView {
        let cfg = WKWebViewConfiguration()
        cfg.websiteDataStore = .nonPersistent()
        let v = DevPickerWebView(frame: .zero, configuration: cfg)
        picker?.webView = v
        v.navigationDelegate = context.coordinator
        v.uiDelegate = context.coordinator
        v.allowsBackForwardNavigationGestures = true
        context.coordinator.onLoading = { [loading = $loading, failed = $failed] on, error in
            DispatchQueue.main.async {
                loading.wrappedValue = on
                failed.wrappedValue = error
            }
        }
        return v
    }

    func updateNSView(_ v: WKWebView, context: Context) {
        let c = context.coordinator
        if c.url != url || c.attempt != attempt {
            c.url = url
            c.reloads = reloads
            c.attempt = attempt
            c.start(v, url)
        } else if c.reloads != reloads {
            c.reloads = reloads
            // A page that never loaded has nothing to reload: load the address again.
            if c.lastFailed || v.url == nil { c.start(v, url) } else { c.autoRetried = false; v.reloadFromOrigin() }
        }
    }

    final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate {
        var url: URL?
        var reloads = 0
        var attempt = 0
        var onLoading: ((Bool, String?) -> Void)?
        /// The one automatic retry of this load was used.
        var autoRetried = false
        /// The last navigation failed (Reload then loads the address, not the empty page).
        var lastFailed = false

        private static let log = Logger(subsystem: "com.liaisone.mac", category: "canvas")

        /// A fresh load of `u` (a new address, Try again, or Reload after a failure): one automatic retry again.
        func start(_ v: WKWebView, _ u: URL) {
            autoRetried = false
            lastFailed = false
            onLoading?(true, nil)
            v.load(URLRequest(url: u))
        }

        func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) { onLoading?(true, nil) }
        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            lastFailed = false
            onLoading?(false, nil)
        }
        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            done(webView, error, provisional: false)
        }
        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            done(webView, error, provisional: true)
        }

        private func done(_ webView: WKWebView, _ error: Error, provisional: Bool) {
            let e = error as NSError
            // A navigation replaced by another one is not a failure.
            if e.domain == NSURLErrorDomain && e.code == NSURLErrorCancelled { onLoading?(false, nil); return }
            // "Frame load interrupted" (WebKit 102): a download or a policy change, not a page that failed.
            if e.domain == "WebKitErrorDomain" && e.code == 102 { onLoading?(false, nil); return }
            let failing = (e.userInfo[NSURLErrorFailingURLErrorKey] as? URL) ?? webView.url ?? url
            let address = failing?.absoluteString ?? "-"
            let phase = provisional ? "provisional" : "committed"
            Self.log.error("Canvas preview \(phase, privacy: .public) load failed: \(e.domain, privacy: .public) \(e.code, privacy: .public) \(e.localizedDescription, privacy: .public) url=\(address, privacy: .public)")
            // The box may be waking: one more try after 1 s, the progress line still on.
            if provisional && !autoRetried, let u = url {
                autoRetried = true
                onLoading?(true, nil)
                DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self, weak webView] in
                    guard let self, let webView, self.url == u else { return }
                    Self.log.info("Canvas preview retrying once: \(u.absoluteString, privacy: .public)")
                    webView.load(URLRequest(url: u))
                }
                return
            }
            lastFailed = true
            onLoading?(false, Self.describe(e))
        }

        /// The error in words for the panel: the system's description and its code.
        static func describe(_ e: NSError) -> String {
            let text = e.localizedDescription.trimmingCharacters(in: .whitespacesAndNewlines)
            let base = text.isEmpty ? "The page could not be opened." : text
            return base + " (\(e.domain) \(e.code))"
        }

        /// target=_blank stays in the preview.
        func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                     for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
            if navigationAction.targetFrame == nil { webView.load(navigationAction.request) }
            return nil
        }
    }
}

// MARK: - Code

/// The project's files on the left, the picked file's text on the right (read only, selectable, line numbers).
/// Both calls wake the project's box, so each shows a spinner and its own error line. `source`: the local project (as
/// before), or a cloned repository at one of its branches (op=ls / op=show, read only).
private struct CanvasCode: View {
    let auth: AuthStore
    let profile: String
    let reloads: Int
    var focusPath: String? = nil
    var focusSeq = 0
    var source: DevCodeSource = .project
    /// The project's clones (left out of the project's own list: each is a source of its own).
    var repos: [DevRepo] = []
    /// The breadcrumb's first part (the project, the repository, the site).
    var rootLabel = "Project"
    /// The sites' folders: read on their own when the project's listing was cut (DevCodeScope.extraDirs).
    var siteDirs: [String] = []
    @State private var rows: [DevFiles.Row]?
    @State private var listError: String?
    /// The listing reached the server's cap: said under the list (and instead of "No files yet").
    @State private var cutNote: String?
    @State private var selected: String?
    @State private var text: String?
    @State private var fileError: String?
    @State private var loadingFile = false
    /// The newest file load (loadFile), the one whose end clears `loadingFile`.
    @State private var fileLoad = UUID()
    /// A folder picked from the chat (a path chip): marked in the list and scrolled to.
    @State private var focusDir: String?
    /// The row the list scrolls to (a picked file or folder).
    @State private var scrollTarget: String?

    var body: some View {
        HStack(spacing: 0) {
            list.frame(width: 210)
            Divider().overlay(WS.line)
            file.frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .task(id: reloads) { await loadList() }
        .task(id: FileKey(path: selected, reloads: reloads)) { await loadFile() }
        .onChange(of: focusSeq) { _, _ in if let f = focusPath { applyFocus(f, rows: rows) } }
    }

    private struct FileKey: Equatable { let path: String?; let reloads: Int }

    /// A path picked from the chat. "dir/" marks that folder; a file is picked by its path, or by the one
    /// listed path that ends with it (Dev often names "index.html" alone). Before the list is read, the path as given.
    private func applyFocus(_ f: String, rows: [DevFiles.Row]?) {
        if f.hasSuffix("/") {
            let d = DevCodeScope.normalize(f)
            focusDir = d.isEmpty ? nil : d
            scrollTarget = focusDir
            return
        }
        focusDir = nil
        guard let rows else { selected = f; return }
        let files = rows.filter { !$0.isDir }.map(\.path)
        if let hit = FileChips.match(f, in: files) {
            selected = hit
            scrollTarget = hit
        }
    }

    @ViewBuilder private var list: some View {
        if let rows {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 1) {
                        if rows.isEmpty {
                            Text(verbatim: cutNote ?? emptyWords).font(LiaFont.ui(12.5))
                                .foregroundStyle(cutNote == nil ? WS.text3 : WS.bad).padding(10)
                        }
                        ForEach(rows) { r in row(r).id(r.path) }
                        if let cutNote, !rows.isEmpty {
                            Text(verbatim: cutNote).font(LiaFont.ui(11.5)).foregroundStyle(WS.text3).padding(10)
                        }
                    }
                    .padding(6)
                }
                .onChange(of: scrollTarget) { _, t in
                    guard let t else { return }
                    withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo(t, anchor: .center) }
                }
                .onAppear {
                    guard let t = scrollTarget else { return }
                    DispatchQueue.main.async { proxy.scrollTo(t, anchor: .center) }
                }
            }
            .background(Color.dyn(0x15181C, 0xFAFBFC))
        } else if let listError {
            message(listError, bad: true)
        } else {
            spinner(source.dir == nil ? "Opening the project\u{2026}" : "Reading the branch\u{2026}")
        }
    }

    /// An empty list says what was read (never a bare blank).
    private var emptyWords: String {
        switch source {
        case .project: return "The project has no files yet."
        case .folder(let d): return "No files in " + d + "."
        case .repo(_, let b): return "No files on " + b + "."
        }
    }

    private func row(_ r: DevFiles.Row) -> some View {
        let on = r.isDir ? r.path == focusDir : r.path == selected
        return Button { if !r.isDir { selected = r.path } } label: {
            HStack(spacing: 6) {
                Image(systemName: r.isDir ? "folder" : "doc.text").font(.system(size: 11))
                    .foregroundStyle(on ? SettingsLook.accent : WS.text3).frame(width: 14)
                Text(r.name).font(LiaFont.ui(12.5, on ? .medium : .regular)).foregroundStyle(r.isDir ? WS.text2 : WS.ink)
                    .lineLimit(1).truncationMode(.middle)
                Spacer(minLength: 0)
            }
            .padding(.leading, 6 + CGFloat(min(r.depth, 8)) * 14).padding(.trailing, 6)
            .frame(height: 26)
            .background(on ? SettingsLook.accentSoft : Color.clear, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.liaPlain)
        .disabled(r.isDir)
        .liaPointer()
        .help(r.path)
        .accessibilityLabel(Text(r.isDir ? "Folder \(r.path)" : r.path))
        .accessibilityAddTraits(on ? .isSelected : [])
    }

    @ViewBuilder private var file: some View {
        if let fileError {
            message(fileError, bad: true)
        } else if loadingFile {
            spinner("Reading the file\u{2026}")
        } else if let path = selected, FileRef(path: path, isDir: false, written: path).isImage, FileChips.ext(path) != "svg" {
            // Dev's files are read as text: a picture's bytes would print as noise
            message("Pictures are not shown here yet: \(path) is an image.", bad: false)
        } else if let text, let path = selected {
            CodeFileViewer(path: path, root: rootLabel, text: text, onClose: { selected = nil; self.text = nil })
                .id(path)
        } else if rows != nil {
            message("Pick a file", bad: false)
        } else {
            Color.clear
        }
    }

    private func spinner(_ words: String) -> some View {
        VStack(spacing: 8) {
            ProgressView().controlSize(.small)
            Text(words).font(LiaFont.ui(12)).foregroundStyle(WS.text3)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func message(_ words: String, bad: Bool) -> some View {
        Text(words).font(LiaFont.ui(12.5)).foregroundStyle(bad ? WS.bad : WS.text3)
            .multilineTextAlignment(.center).padding(14)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func loadList() async {
        listError = nil
        let api = LiaAPI(auth: auth)
        let got: Result<[String], DevFilesError>
        switch source {
        case .project: got = await api.devFiles(profile: profile)
        // ("All files shows nothing"): a site's folder is listed on its own. Cut out of the project's
        // listing it was empty: that listing stops at 400 entries and a big clone fills them.
        case .folder(let d): got = await api.devFiles(profile: profile, path: d)
        case .repo(let dir, let branch): got = await api.devGitFiles(profile: profile, dir: dir, ref: branch)
        }
        if Task.isCancelled { return }
        switch got {
        case .success(let all):
            var entries = all
            var note: String? = nil
            switch source {
            case .project:
                var own = DevCodeScope.projectEntries(all, repos: repos)
                if DevCodeScope.isCut(all) {
                    // the listing was cut: read the sites' and the top-level folders on their own
                    for d in DevCodeScope.extraDirs(all, repos: repos, sites: siteDirs) {
                        if case .success(let e) = await api.devFiles(profile: profile, path: d) {
                            own += [d + "/"] + DevCodeScope.prefixed(e, dir: d)
                        }
                        if Task.isCancelled { return }
                    }
                    note = own.isEmpty && !repos.isEmpty
                        ? "The project\u{2019}s list stops at \(DevCodeScope.listCap) entries and its cloned repositories fill it. Pick a site or a repository in the menu above."
                        : "The project\u{2019}s list stops at \(DevCodeScope.listCap) entries: some files may be missing. Its sites and repositories are in the menu above."
                }
                // a file picked in the profile that sits in a clone still shows
                if let f = focusPath, !DevCodeScope.normalize(f).isEmpty, FileChips.match(f, in: own) == nil { entries = all } else { entries = own }
            case .folder:
                if DevCodeScope.isCut(all) { note = "This folder\u{2019}s list stops at \(DevCodeScope.listCap) entries: some files may be missing." }
            case .repo: break
            }
            cutNote = note
            let r = DevFiles.rows(entries)
            rows = r
            if let f = focusPath, selected == nil || selected == f { applyFocus(f, rows: r) }
            if selected == nil || !r.contains(where: { $0.path == selected && !$0.isDir }) {
                selected = DevFiles.firstFile(r)
            }
        case .failure(let e):
            if rows == nil { listError = e.message.isEmpty ? "Could not read the files." : e.message }
        }
    }

    private func loadFile() async {
        let token = UUID()
        fileLoad = token
        guard let path = selected else { text = nil; loadingFile = false; return }
        fileError = nil
        loadingFile = true
        let r: Result<String, DevFilesError>
        switch source {
        case .project: r = await LiaAPI(auth: auth).devFile(profile: profile, path: path)
        case .folder(let d): r = await LiaAPI(auth: auth).devFile(profile: profile, path: DevCodeScope.projectPath(path, in: d))
        case .repo(let dir, let branch): r = await LiaAPI(auth: auth).devGitFile(profile: profile, dir: dir, ref: branch, path: path)
        }
        // 0.2.11: the newest load owns the spinner; a cancelled one that is still the newest clears it (before, a load
        // cancelled without a newer one left "loading" up for good).
        guard !Task.isCancelled, path == selected else {
            if fileLoad == token { loadingFile = false }
            return
        }
        loadingFile = false
        switch r {
        case .success(let s): text = s
        case .failure(let e): text = nil; fileError = e.message
        }
    }
}

// MARK: - Artifact records

/// The artifacts' records (GET /agents/dev/art), read once per artifact for the app's life and shared by its Activity
/// and Changes; the diff is parsed once when it arrives.
@MainActor
final class DevArtStore: ObservableObject {
    static let shared = DevArtStore()

    struct Loaded: Equatable {
        let record: DevArtRecord
        let files: [DevDiff.File]
        /// The changed files as listed (the record's, else the parsed diff's), built once with the parse.
        var list: [DevFileChange] = []
    }
    enum Load: Equatable { case loading, loaded(Loaded), failed(String) }

    @Published private(set) var loads: [String: Load] = [:]

    static func key(profile: String, id: String) -> String { profile + "|" + id }

    func load(for item: CanvasItem) -> Load? {
        guard let a = item.art, let p = item.profile else { return nil }
        return loads[Self.key(profile: p, id: a)]
    }

    /// Reads the record unless it is read or being read (a failure is read again).
    func load(auth: AuthStore, item: CanvasItem) async {
        guard let id = item.art, let profile = item.profile, !profile.isEmpty else { return }
        let k = Self.key(profile: profile, id: id)
        switch loads[k] {
        case .some(.loaded), .some(.loading): return
        default: break
        }
        loads[k] = .loading
        let r = await LiaAPI(auth: auth).devArt(profile: profile, id: id)
        // A view that went away mid-read: the next one reads it again.
        if Task.isCancelled { loads[k] = nil; return }
        switch r {
        case .success(let rec):
            // A diff of many files is parsed off the main thread (it held the sheet's opening)
            let diff = rec.diff, changes = rec.changes
            let parsed = await Task.detached(priority: .userInitiated) { () -> ([DevDiff.File], [DevFileChange]) in
                let f = DevDiff.parse(diff)
                return (f, DevGitDiff.fileList(changes, f))
            }.value
            loads[k] = .loaded(Loaded(record: rec, files: parsed.0, list: parsed.1))
        case .failure(let e): loads[k] = .failed(e.message)
        }
    }
}

/// A spinner with words, centred.
private struct CanvasSpinner: View {
    let words: String
    var body: some View {
        VStack(spacing: 8) {
            ProgressView().controlSize(.small)
            Text(words).font(LiaFont.ui(12)).foregroundStyle(WS.text3)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// A line of text centred in the stage (an error in the warning colour, with Try again when it can be retried).
private struct CanvasNote: View {
    let words: String
    var bad = false
    var onRetry: (() -> Void)? = nil
    var body: some View {
        VStack(spacing: 10) {
            Text(words).font(LiaFont.ui(12.5)).foregroundStyle(bad ? WS.bad : WS.text3)
                .multilineTextAlignment(.center)
            if let onRetry {
                Button("Try again", action: onRetry).buttonStyle(ChatCapsuleButtonStyle(primary: false)).liaPointer()
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Activity (in plain words)

/// Dev working now (the live item): its messages and, between them, each run of steps in one plain sentence that
/// opens to the steps; the status line at the bottom while it works.
private struct CanvasActivity: View {
    let activity: DevActivity
    let working: Bool

    var body: some View {
        CanvasActivityList(groups: DevActivityGroups.make(activity.entries), working: working, status: activity.status,
                           empty: working ? "Dev is starting\u{2026}" : "Nothing yet. Dev's steps show here while it works.")
    }
}

/// One artifact's own activity, read from its record.
private struct CanvasArtActivity: View {
    let auth: AuthStore
    let item: CanvasItem
    let reloads: Int
    @ObservedObject private var store = DevArtStore.shared

    var body: some View {
        Group {
            if item.art == nil || (item.profile ?? "").isEmpty {
                CanvasNote(words: "No activity was saved for this one.")
            } else {
                switch store.load(for: item) {
                case .loaded(let l)?:
                    CanvasActivityList(groups: DevActivityGroups.make(l.record.activity), working: false, status: nil,
                                       empty: "No activity was saved for this one.")
                case .failed(let e)?:
                    CanvasNote(words: e, bad: true) { Task { await store.load(auth: auth, item: item) } }
                default:
                    CanvasSpinner(words: "Loading the activity\u{2026}")
                }
            }
        }
        .task(id: reloads) { await store.load(auth: auth, item: item) }
    }
}

/// The groups as a list: messages as paragraphs, step runs as a line with a chevron (open: the steps).
private struct CanvasActivityList: View {
    let groups: [DevActivityGroup]
    let working: Bool
    let status: String?
    let empty: String
    @State private var open: Set<String> = []

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 4) {
                    if groups.isEmpty {
                        Text(empty)
                            .font(LiaFont.ui(12.5)).foregroundStyle(WS.text3)
                            .frame(maxWidth: .infinity, alignment: .center).padding(.top, 40)
                    }
                    ForEach(groups) { g in
                        if g.kind == .message {
                            CanvasActivityMessage(text: g.text, at: g.at, streaming: g.streaming).id(g.id)
                        } else {
                            stepGroup(g).id(g.id)
                        }
                    }
                    if working {
                        HStack(spacing: 8) {
                            ProgressView().controlSize(.mini).frame(width: 18)
                            Text(status ?? "Working").font(LiaFont.ui(12.5, .medium)).foregroundStyle(WS.text2).wsShimmer()
                        }
                        .padding(.horizontal, 10).frame(height: 28)
                        .id("now")
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel(Text(status ?? "Working"))
                    }
                    Color.clear.frame(height: 1).id("end")
                }
                .padding(10)
            }
            .onChange(of: groups.count) { _, _ in withAnimation(.easeOut(duration: 0.15)) { proxy.scrollTo("end", anchor: .bottom) } }
            .onChange(of: groups.last?.steps.count ?? 0) { _, _ in
                guard working else { return }
                withAnimation(.easeOut(duration: 0.15)) { proxy.scrollTo("end", anchor: .bottom) }
            }
            // Dev's words streaming in the Activity follow down as they grow.
            .onChange(of: groups.last(where: { $0.streaming })?.text.count ?? 0) { _, _ in
                guard working else { return }
                proxy.scrollTo("end", anchor: .bottom)
            }
            .onAppear { if working { proxy.scrollTo("end", anchor: .bottom) } }
        }
    }

    @ViewBuilder private func stepGroup(_ g: DevActivityGroup) -> some View {
        let on = open.contains(g.id)
        VStack(alignment: .leading, spacing: 2) {
            Button {
                if on { open.remove(g.id) } else { open.insert(g.id) }
            } label: {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Image(systemName: "chevron.right").font(.system(size: 9.5, weight: .semibold))
                        .foregroundStyle(WS.text3)
                        .rotationEffect(.degrees(on ? 90 : 0))
                        .frame(width: 18)
                        .accessibilityHidden(true)
                    (Text(verbatim: g.text).foregroundColor(WS.text2)
                        + Text(verbatim: g.failures.map { " \u{00b7} " + $0 } ?? "").foregroundColor(WS.bad))
                        .font(LiaFont.ui(12.5))
                        .lineLimit(on ? nil : 2)
                        .multilineTextAlignment(.leading)
                    Spacer(minLength: 6)
                    if g.running { ProgressView().controlSize(.mini) }
                }
                .padding(.horizontal, 10).padding(.vertical, 6)
                .contentShape(Rectangle())
            }
            .buttonStyle(.liaPlain)
            .liaPointer()
            .accessibilityLabel(Text(g.text + (g.failures.map { ", " + $0 } ?? "")))
            .accessibilityHint(Text(on ? "Hides the steps" : "Shows the steps"))
            if on {
                VStack(alignment: .leading, spacing: 1) {
                    ForEach(g.steps) { s in CanvasActivityRow(step: s) }
                }
                .padding(.leading, 18)
                .transition(.opacity)
            }
        }
    }
}

/// One of Dev's messages in the Activity, drawn as in the chat ("as his messages, in cells"): Dev's
/// small figure, its name, the bubble with light Markdown (bold, italics, code, links) and the time.
private struct CanvasActivityMessage: View {
    let text: String
    /// ms; 0: unknown (no time drawn).
    var at: Double = 0
    /// Still being written (the live turn).
    var streaming = false

    @MainActor private var dev: AgentInfo? { WorkspaceModel.current?.agent("dev") }

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Group {
                if let a = dev {
                    AgentAvatar(agent: a, size: 24, status: streaming ? .working : .idle)
                } else {
                    Circle().fill(WS.soft).overlay(Circle().stroke(WS.line, lineWidth: 1))
                }
            }
            .frame(width: 24, height: 24)
            .padding(.top, 1)
            .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(verbatim: dev?.name ?? "Dev").font(LiaFont.ui(11.5, .semibold)).foregroundStyle(WS.text2)
                VStack(alignment: .trailing, spacing: 2) {
                    // As in the thread - addresses, domains and branches are chips, not blue links
                    MarkdownView(text: text)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    if streaming {
                        Text("writing\u{2026}").font(LiaFont.ui(10.5)).foregroundStyle(WS.text3).wsShimmer()
                            .accessibilityHidden(true)
                    } else if at > 0 {
                        ChatBubbleTime(ts: at)
                    }
                }
                .padding(.horizontal, 12).padding(.top, 8).padding(.bottom, 5)
                .background(WS.soft, in: UnevenRoundedRectangle(topLeadingRadius: 6, bottomLeadingRadius: 14,
                                                               bottomTrailingRadius: 14, topTrailingRadius: 14, style: .continuous))
            }
            Spacer(minLength: 24)
        }
        .padding(.horizontal, 6).padding(.vertical, 6)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text("\(dev?.name ?? "Dev") said: " + text))
    }
}

private struct CanvasActivityRow: View {
    let step: DevStep

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: step.symbol).font(.system(size: 11, weight: .medium))
                .foregroundStyle(step.failed ? WS.bad : WS.text2).frame(width: 18)
                .accessibilityHidden(true)
            Text(verbatim: step.text)
                .font(step.code ? Font.system(size: 11.5, design: .monospaced) : LiaFont.ui(12.5))
                .foregroundStyle(WS.ink).lineLimit(2).truncationMode(.middle)
                .textSelection(.enabled)
            Spacer(minLength: 6)
            if step.running {
                ProgressView().controlSize(.mini)
            } else if let r = step.result {
                Text(r).font(LiaFont.ui(11.5)).foregroundStyle(step.failed ? WS.bad : WS.text3).lineLimit(1)
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 6)
        .background(step.failed ? WS.bad.opacity(0.06) : Color.clear, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Code: Changes | All files, and its source

/// The repositories cloned into each project and the diffs read from them, kept for the app's life (each read wakes
/// Dev's box) and read again when the Canvas reloads; and the source each Canvas item was switched to by hand.
@MainActor
final class DevRepoStore: ObservableObject {
    static let shared = DevRepoStore()

    enum Load<T: Equatable>: Equatable { case loading, loaded(T), failed(String) }
    struct Diff: Equatable {
        let diff: DevGitDiff
        let files: [DevDiff.File]
        var list: [DevFileChange] = []
    }

    @Published private(set) var repos: [String: Load<[DevRepo]>] = [:]
    @Published private(set) var diffs: [String: Load<Diff>] = [:]
    /// The source picked by hand, per Canvas item (CanvasItem.id).
    @Published var picks: [String: DevCodeSource] = [:]
    /// The `reloads` each key was last read for.
    private var seen: [String: Int] = [:]
    /// The source bar's Reload, per project: kept here (a view's own counter starts at 0 again when the view is made
    /// again, and its sum with the Canvas's reloads could repeat one already read - the Reload was skipped).
    @Published private(set) var manual: [String: Int] = [:]
    func bumpManual(_ profile: String) { manual[profile, default: 0] &+= 1 }

    static func diffKey(profile: String, dir: String, ref: String, work: Bool) -> String {
        "d|" + profile + "|" + dir + "|" + (work ? "~work" : ref)
    }

    /// The project's repositories once read ([] before, on a failure, or when it has none).
    func repoList(_ profile: String) -> [DevRepo] {
        if case .loaded(let r)? = repos[profile] { return r }
        return []
    }

    func diff(profile: String, dir: String, ref: String, work: Bool) -> Load<Diff>? {
        diffs[Self.diffKey(profile: profile, dir: dir, ref: ref, work: work)]
    }

    /// Reads the repositories unless they are being read or were read for these `reloads` (a list already read stays
    /// on screen while it is read again; a failure then keeps it).
    func loadRepos(auth: AuthStore, profile: String, reloads: Int) async {
        let k = "r|" + profile
        var wasLoaded = false
        switch repos[profile] {
        case .loading?: return
        case .loaded?: if seen[k] == reloads { return }; wasLoaded = true
        default: break
        }
        seen[k] = reloads
        if !wasLoaded { repos[profile] = .loading }
        let r = await LiaAPI(auth: auth).devRepos(profile: profile)
        if Task.isCancelled {
            if !wasLoaded { repos[profile] = nil; seen[k] = nil }
            return
        }
        switch r {
        case .success(let list): repos[profile] = .loaded(list)
        case .failure(let e): if !wasLoaded { repos[profile] = .failed(e.message) }
        }
    }

    /// Reads a diff (a branch over the default one, or the uncommitted work) the same way.
    func loadDiff(auth: AuthStore, profile: String, dir: String, ref: String, work: Bool, reloads: Int) async {
        let k = Self.diffKey(profile: profile, dir: dir, ref: ref, work: work)
        let had = diffs[k]
        var wasLoaded = false
        switch had {
        case .loading?: return
        case .loaded?: if seen[k] == reloads { return }; wasLoaded = true
        default: break
        }
        seen[k] = reloads
        if !wasLoaded { diffs[k] = .loading }
        let r = await LiaAPI(auth: auth).devGitDiff(profile: profile, dir: dir, ref: ref, work: work)
        if Task.isCancelled {
            if !wasLoaded { diffs[k] = nil; seen[k] = nil }
            return
        }
        switch r {
        case .success(let d):
            let text = d.diff, changes = d.changes
            let parsed = await Task.detached(priority: .userInitiated) { () -> ([DevDiff.File], [DevFileChange]) in
                let f = DevDiff.parse(text)
                return (f, DevGitDiff.fileList(changes, f))
            }.value
            diffs[k] = .loaded(Diff(diff: d, files: parsed.0, list: parsed.1))
        case .failure(let e): if !wasLoaded { diffs[k] = .failed(e.message) }
        }
    }
}

/// The Code tab: the artifact's changes (for a push, what went to git) or the whole local project, picked by a small
/// segmented control when both exist.: when the project holds cloned repositories, a source menu on
/// top picks the Project (all of the above, unchanged) or a repository, then one of Dev's local branches: its Changes
/// over the default branch, its Uncommitted work (the checked-out branch) or All files at that branch.
private struct CanvasCodeTab: View {
    let auth: AuthStore
    let item: CanvasItem
    let reloads: Int
    /// A file picked in Dev's profile: "All files" with it selected (bumped `focusSeq` on every pick).
    let focusPath: String?
    let focusSeq: Int
    let onOpenOnGitHub: (URL) -> Void
    enum Scope: Hashable { case changes, all }
    @State private var scope: Scope
    /// A repository's scope: the branch over the default one, the uncommitted work, or its files.
    enum RepoScope: Hashable { case changes, work, all }
    @State private var repoScope: RepoScope = .changes
    @ObservedObject private var repoStore = DevRepoStore.shared
    /// The workspace's sites (their folders: what a preview or a live site's Code shows).
    @ObservedObject private var siteStore = DevSitesStore.shared
    /// A changed file picked from the chat (a path chip): the Changes are shown with it picked.
    @ObservedObject private var changeFocus = CanvasChangeFocus.shared
    private var focusKey: String { CanvasChangeFocus.key(item) }

    init(auth: AuthStore, item: CanvasItem, reloads: Int, focusPath: String? = nil, focusSeq: Int = 0,
         onOpenOnGitHub: @escaping (URL) -> Void) {
        self.auth = auth; self.item = item; self.reloads = reloads; self.onOpenOnGitHub = onOpenOnGitHub
        self.focusPath = focusPath; self.focusSeq = focusSeq
        let focused = focusPath != nil && item.hasCode
        _scope = State(initialValue: !focused && (item.prefersChanges || !item.hasCode) ? .changes : .all)
    }

    private var both: Bool { item.hasChanges && item.hasCode }
    private var shown: Scope { both ? scope : (item.hasChanges ? .changes : .all) }

    /// The Canvas's reloads and the source bar's Reload (the store's, per project): both only grow, so the sum changes
    /// whenever either does, and never comes back to a value already read.
    private var ticks: Int { reloads &+ (profile.map { repoStore.manual[$0] ?? 0 } ?? 0) }
    private var profile: String? { item.hasCode ? item.profile : nil }
    private var repos: [DevRepo] { profile.map { repoStore.repoList($0) } ?? [] }

    /// The source shown: the one picked by hand, else (a push) the repository and branch it went from, else the
    /// project. A repository that is gone falls back to the project; a branch that is gone to the checked-out one.
    /// ("All files always shows Meta-Api, whatever the item"): the pick is kept per workspace and item
    /// (the project's own items - "Project files", "Dev working" - have the same id in every workspace and dialogue,
    /// so one pick of a clone there stuck everywhere), and with no pick the item's own source decides
    /// (DevCodeScope.pick: a push's clone, its site's folder, else the project without the clones).
    private var pickKey: String { (item.profile ?? "") + "|" + item.id }
    private var sites: DevSites? { profile.flatMap { siteStore.sites[$0] } }
    private var folders: [DevSiteFolder] { DevCodeScope.siteFolders(sites, repos: repos) }

    private var source: DevCodeSource {
        let rs = repos
        let auto = DevCodeScope.pick(push: item.push, page: item.previewURL, repos: rs, sites: sites)
        switch repoStore.picks[pickKey] ?? auto {
        case .project: return .project
        case .folder(let d): return .folder(d)
        case .repo(let dir, let branch):
            guard let r = rs.first(where: { $0.dir == dir }) else { return .project }
            return .repo(dir: dir, branch: r.pick(branch))
        }
    }

    /// (a "Live site" card's Changes listed Meta-Api's files): the folder a preview or a live site card's
    /// changes are kept to (its site's); nil for the others (they leave out only the cloned repositories).
    private var changesFolder: String? {
        guard item.kind == .devPreview, let u = item.url else { return nil }
        return DevCodeScope.siteDir(page: u, sites: sites)
    }

    /// The breadcrumb's root for the project or a folder.
    private var rootLabel: String {
        if let d = source.folder { return folders.first { $0.dir == d }?.label ?? d }
        return "Project"
    }

    private var repo: DevRepo? { source.dir.flatMap { d in repos.first { $0.dir == d } } }

    /// Uncommitted work is offered for the checked-out branch of a dirty clone.
    private var canWork: Bool {
        guard let r = repo, let b = source.branch else { return false }
        return r.dirty > 0 && b == r.branch
    }

    private var shownRepoScope: RepoScope { repoScope == .work && !canWork ? .changes : repoScope }

    private var noteScope: DevRepo.Scope {
        switch shownRepoScope {
        case .changes: return .changes
        case .work: return .work
        case .all: return .files
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            if !repos.isEmpty || !folders.isEmpty {
                sourceBar
                Divider().overlay(WS.line)
            }
            if let p = profile, let r = repo, let branch = source.branch {
                repoBar(r, branch: branch)
                Divider().overlay(WS.line)
                switch shownRepoScope {
                case .changes:
                    CanvasRepoChanges(auth: auth, profile: p, repo: r, branch: branch, work: false, reloads: ticks, focusKey: focusKey)
                        .id("c|" + r.dir + "|" + branch)
                case .work:
                    CanvasRepoChanges(auth: auth, profile: p, repo: r, branch: branch, work: true, reloads: ticks)
                        .id("w|" + r.dir + "|" + branch)
                case .all:
                    CanvasCode(auth: auth, profile: p, reloads: ticks, source: source, rootLabel: r.name).id(source)
                }
            } else {
                if both || item.push != nil {
                    bar
                    Divider().overlay(WS.line)
                }
                if shown == .changes {
                    CanvasChanges(auth: auth, item: item, reloads: reloads, folder: changesFolder, repos: repos, focusKey: focusKey)
                } else if let p = item.profile, item.previewURL != nil, sites == nil, siteStore.errors[p] == nil {
                    // the item's site decides which folder opens: its list first (no flash of the whole project)
                    CanvasSpinner(words: "Opening the project\u{2026}")
                } else if let p = item.profile {
                    CanvasCode(auth: auth, profile: p, reloads: ticks, focusPath: focusPath, focusSeq: focusSeq, source: source,
                               repos: repos, rootLabel: rootLabel, siteDirs: folders.map(\.dir))
                        // read again when the clones are known (they leave the project's list)
                        .id(Self.tag(source) + "|" + repos.map(\.dir).joined(separator: ",") + "|" + folders.map(\.dir).joined(separator: ","))
                } else {
                    CanvasNote(words: "No file changes.")
                }
            }
        }
        .task(id: ticks) {
            guard let p = profile else { return }
            await siteStore.loadOnce(auth: auth, profile: p)
            await repoStore.loadRepos(auth: auth, profile: p, reloads: ticks)
        }
        .onChange(of: changeFocus.focus[focusKey]?.seq) { _, s in
            guard s != nil else { return }
            scope = .changes
            repoScope = .changes
        }
        .onAppear {
            guard changeFocus.fresh(focusKey) != nil else { return }
            scope = .changes
            repoScope = .changes
        }
        .onChange(of: focusSeq) { _, _ in
            guard focusPath != nil, item.hasCode else { return }
            scope = .all
            // a file of the local project was picked: show the project
            if source != .project { repoStore.picks[pickKey] = .project }
        }
    }

    // MARK: the source

    private func pick(_ s: DevCodeSource) { repoStore.picks[pickKey] = s }

    private var sourceBar: some View {
        HStack(spacing: 8) {
            sourceMenu
            if let r = repo, let b = source.branch {
                branchMenu(r, branch: b)
                if let d = r.dirtyText {
                    Button {
                        pick(.repo(dir: r.dir, branch: r.pick(nil)))
                        repoScope = .work
                    } label: {
                        Text(verbatim: "\u{2022} " + d).font(LiaFont.ui(11.5)).foregroundStyle(WS.text3).lineLimit(1)
                    }
                    .buttonStyle(.liaPlain)
                    .liaPointer()
                    .accessibilityLabel(Text("\(d) on \(r.branch). Show them"))
                }
            }
            Spacer(minLength: 0)
            if source != .project {
                Button { if let p = profile { repoStore.bumpManual(p) } } label: {
                    Image(systemName: "arrow.clockwise").font(.system(size: 11, weight: .medium)).foregroundStyle(WS.text2)
                        .frame(width: 24, height: 24).contentShape(Rectangle())
                }
                .buttonStyle(.liaPlain)
                .liaPointer()
                .accessibilityLabel(Text("Reload the repository"))
            }
        }
        .padding(.horizontal, 10).frame(height: 38)
        .background(Color.dyn(0x15181C, 0xFAFBFC))
    }

    private var sourceMenu: some View {
        let current = source
        return Menu {
            Picker("Source", selection: Binding(get: { Self.tag(current) }, set: { t in
                if t.hasPrefix("dir:") { pick(.folder(String(t.dropFirst(4)))) }
                else if t.hasPrefix("repo:"), let r = repos.first(where: { $0.dir == String(t.dropFirst(5)) }) {
                    pick(.repo(dir: r.dir, branch: r.pick(nil)))
                } else { pick(.project) }
            })) {
                Text("Project").tag("")
                if !folders.isEmpty {
                    Section("Sites") {
                        ForEach(folders) { f in Text(verbatim: f.label).tag("dir:" + f.dir) }
                    }
                }
                if !repos.isEmpty {
                    Section("Repositories") {
                        ForEach(repos) { r in Text(verbatim: r.label).tag("repo:" + r.dir) }
                    }
                }
            }
            .pickerStyle(.inline)
            .labelsHidden()
        } label: {
            CanvasMenuPill(icon: current.folder != nil ? "globe" : current == .project ? "folder" : "book.closed",
                           text: repo?.name ?? rootLabel)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .liaPointer()
        .accessibilityLabel(Text("Source: " + (repo?.label ?? rootLabel)))
    }

    private static func tag(_ s: DevCodeSource) -> String {
        switch s {
        case .project: return ""
        case .folder(let d): return "dir:" + d
        case .repo(let d, _): return "repo:" + d
        }
    }

    @ViewBuilder private func branchMenu(_ r: DevRepo, branch: String) -> some View {
        let b = r.branch(branch)
        if r.branches.isEmpty {
            CanvasMenuPill(icon: "arrow.triangle.branch", text: branch, chevron: false)
        } else {
            Menu {
                Picker("Branch", selection: Binding(get: { branch }, set: { pick(.repo(dir: r.dir, branch: $0)) })) {
                    ForEach(r.branches) { x in Text(verbatim: x.menuTitle).tag(x.name) }
                }
                .pickerStyle(.inline)
                .labelsHidden()
            } label: {
                CanvasMenuPill(icon: "arrow.triangle.branch", text: branch, extra: b?.aheadText)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .liaPointer()
            .accessibilityLabel(Text("Branch: " + (b?.menuTitle ?? branch)))
        }
    }

    private func repoBar(_ r: DevRepo, branch: String) -> some View {
        HStack(spacing: 10) {
            HStack(spacing: 2) {
                repoSeg("Changes", .changes)
                if canWork { repoSeg("Uncommitted", .work) }
                repoSeg("All files", .all)
            }
            .padding(2)
            .background(WS.ink.opacity(0.06), in: Capsule())
            Text(verbatim: r.scopeNote(branch: branch, scope: noteScope))
                .font(LiaFont.ui(11.5)).foregroundStyle(WS.text3)
                .lineLimit(1).truncationMode(.middle)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10).frame(height: 36)
        .background(Color.dyn(0x15181C, 0xFAFBFC))
    }

    private func repoSeg(_ title: String, _ s: RepoScope) -> some View {
        let on = shownRepoScope == s
        return Button { repoScope = s } label: {
            Text(title).font(LiaFont.ui(11.5, .medium)).foregroundStyle(on ? WS.ink : WS.text2)
                .padding(.horizontal, 10).frame(height: 22)
                .background(on ? WS.surface : Color.clear, in: Capsule())
                .shadow(color: on ? Color.black.opacity(0.08) : .clear, radius: 2, y: 1)
                .contentShape(Capsule())
        }
        .buttonStyle(.liaPlain)
        .liaPointer()
        .accessibilityAddTraits(on ? .isSelected : [])
    }

    // MARK: the project (as before)

    private var bar: some View {
        HStack(spacing: 10) {
            if both {
                HStack(spacing: 2) {
                    seg(item.kind == .devPush ? "Pushed" : "Changes", .changes)
                    seg("All files", .all)
                }
                .padding(2)
                .background(WS.ink.opacity(0.06), in: Capsule())
            }
            if let p = item.push, shown == .changes {
                Image(systemName: "arrow.triangle.branch").font(.system(size: 11)).foregroundStyle(WS.text3).accessibilityHidden(true)
                Text(verbatim: p.route).font(.system(size: 11.5, design: .monospaced)).foregroundStyle(WS.text2)
                    .lineLimit(1).truncationMode(.middle)
                    .help(p.repo.isEmpty ? p.route : p.repo + ": " + p.route)
                if let u = p.url {
                    Button("GitHub") { onOpenOnGitHub(u) }
                        .buttonStyle(.liaPlain)
                        .font(LiaFont.ui(11.5, .medium)).foregroundStyle(SettingsLook.accent)
                        .liaPointer()
                        .accessibilityLabel(Text("Open on GitHub"))
                }
            } else if shown == .all {
                Text(verbatim: source.folder.map { "\($0) on Dev\u{2019}s computer" } ?? "The project on Dev\u{2019}s computer")
                    .font(LiaFont.ui(11.5)).foregroundStyle(WS.text3).lineLimit(1).truncationMode(.middle)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10).frame(height: 36)
        .background(Color.dyn(0x15181C, 0xFAFBFC))
    }

    private func seg(_ title: String, _ s: Scope) -> some View {
        Button { scope = s } label: {
            Text(title).font(LiaFont.ui(11.5, .medium)).foregroundStyle(shown == s ? WS.ink : WS.text2)
                .padding(.horizontal, 10).frame(height: 22)
                .background(shown == s ? WS.surface : Color.clear, in: Capsule())
                .shadow(color: shown == s ? Color.black.opacity(0.08) : .clear, radius: 2, y: 1)
                .contentShape(Capsule())
        }
        .buttonStyle(.liaPlain)
        .liaPointer()
        .accessibilityAddTraits(shown == s ? .isSelected : [])
    }
}

/// A compact glass capsule naming what a menu picks (an icon, the name, "+N" in green, a chevron).
private struct CanvasMenuPill: View {
    let icon: String
    let text: String
    var extra: String? = nil
    var chevron = true

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: icon).font(.system(size: 10.5, weight: .medium)).foregroundStyle(WS.text2)
                .accessibilityHidden(true)
            Text(verbatim: text).font(LiaFont.ui(12, .medium)).foregroundStyle(WS.ink)
                .lineLimit(1).truncationMode(.middle)
                .frame(maxWidth: 170, alignment: .leading)
                .fixedSize(horizontal: true, vertical: false)
            if let extra {
                Text(verbatim: extra).font(.system(size: 11, weight: .medium, design: .monospaced)).foregroundStyle(DevDiffLook.add)
            }
            if chevron {
                Image(systemName: "chevron.down").font(.system(size: 8.5, weight: .semibold)).foregroundStyle(WS.text3)
                    .accessibilityHidden(true)
            }
        }
        .padding(.horizontal, 10).frame(height: 24)
        .wsGlass(12)
        .contentShape(Capsule())
    }
}

/// A repository's diff: the branch over the default one (its commits above the files), or the checked-out branch's
/// uncommitted work (with the untracked files named).
private struct CanvasRepoChanges: View {
    let auth: AuthStore
    let profile: String
    let repo: DevRepo
    let branch: String
    let work: Bool
    let reloads: Int
    /// The item's key for a file picked from the chat (CanvasChangeFocus).
    var focusKey: String? = nil
    @ObservedObject private var store = DevRepoStore.shared

    /// The default branch itself holds nothing over the default branch: said at once, nothing read (an old server
    /// answered with the whole repository as added files).
    private var isBase: Bool { !work && !repo.base.isEmpty && branch == repo.base }

    var body: some View {
        Group {
            if isBase {
                CanvasNote(words: branch + " is the default branch: nothing to compare.")
            } else {
                switch store.diff(profile: profile, dir: repo.dir, ref: branch, work: work) {
                case .loaded(let d)?:
                    CanvasChangesList(changes: d.list, files: d.files,
                                      commits: work ? [] : d.diff.commits, cut: d.diff.cut, untracked: d.diff.untracked,
                                      empty: d.diff.emptyText(branch: branch, base: repo.base), loadNew: newSide,
                                      focusKey: focusKey)
                case .failed(let e)?:
                    CanvasNote(words: e, bad: true) { Task { await load() } }
                default:
                    CanvasSpinner(words: work ? "Reading the uncommitted changes\u{2026}" : "Reading the branch\u{2026}")
                }
            }
        }
        .task(id: reloads) { await load() }
    }

    /// The file after the change (the lines between hunks): the branch's copy, or the working tree for uncommitted work.
    private var newSide: @MainActor (String) async -> String? {
        let auth = auth, profile = profile, dir = repo.dir, branch = branch, work = work
        return { path in
            let api = LiaAPI(auth: auth)
            let r = work ? await api.devFile(profile: profile, path: DevCodeScope.projectPath(path, in: dir))
                : await api.devGitFile(profile: profile, dir: dir, ref: branch, path: path)
            if case .success(let t) = r { return t }
            return nil
        }
    }

    private func load() async {
        if isBase { return }
        await store.loadDiff(auth: auth, profile: profile, dir: repo.dir, ref: branch, work: work, reloads: reloads)
    }
}

/// The artifact's changed files on the left (+N green, \u{2212}M red), the picked file's diff on the right; a push
/// lists its commits above the files.
private struct CanvasChanges: View {
    let auth: AuthStore
    let item: CanvasItem
    let reloads: Int
    /// The item's site folder: only the changes under it are its own (nil: the whole project).
    var folder: String? = nil
    /// The project's clones: a local record's changes inside them are not the item's (a clone made in the same turn
    /// came in as thousands of added files).
    var repos: [DevRepo] = []
    /// The item's key for a file picked from the chat (CanvasChangeFocus).
    var focusKey: String? = nil
    @ObservedObject private var store = DevArtStore.shared

    /// The record's changes that are the item's own, and what was left out (a git record is a push: all of it).
    private func scoped(_ l: DevArtStore.Loaded) -> (list: [DevFileChange], files: [DevDiff.File], note: String?) {
        if l.record.isGit { return (l.list, l.files, nil) }
        let f = folder, rs = repos
        let list = l.list.filter { DevCodeScope.owns($0.path, folder: f, repos: rs) }
        let files = l.files.filter { DevCodeScope.owns($0.path, folder: f, repos: rs) }
        let left = l.list.count - list.count
        guard left > 0 else { return (list, files, nil) }
        let n = left == 1 ? "1 changed file" : "\(left) changed files"
        let note = f.map { "\(n) outside \($0) left out." } ?? "\(n) in cloned repositories left out."
        return (list, files, note)
    }

    var body: some View {
        Group {
            if item.art == nil || (item.profile ?? "").isEmpty {
                CanvasNote(words: "No changes were saved for this one.")
            } else {
                switch store.load(for: item) {
                case .loaded(let l)?:
                    loaded(l)
                case .failed(let e)?:
                    CanvasNote(words: e, bad: true) { Task { await store.load(auth: auth, item: item) } }
                default:
                    CanvasSpinner(words: "Loading the changes\u{2026}")
                }
            }
        }
        .task(id: reloads) { await store.load(auth: auth, item: item) }
    }

    private func loaded(_ l: DevArtStore.Loaded) -> CanvasChangesList {
        let s = scoped(l)
        let empty = s.note.map { "No changes of its own. " + $0 } ?? "No file changes."
        return CanvasChangesList(changes: s.list, files: s.files, commits: l.record.commits, cut: l.record.cut,
                                 empty: empty, loadNew: newSide(l), note: s.note, focusKey: focusKey)
    }

    /// A git record has no working copy to read from; a work record reads the project's file as it is now.
    private func newSide(_ l: DevArtStore.Loaded) -> (@MainActor (String) async -> String?)? {
        if l.record.isGit { return nil }
        return projectFile
    }

    /// The project's file as it is now: used for the lines between hunks only when it still matches the diff.
    private var projectFile: (@MainActor (String) async -> String?)? {
        guard let p = item.profile, !p.isEmpty else { return nil }
        let auth = auth
        return { path in
            if case .success(let t) = await LiaAPI(auth: auth).devFile(profile: p, path: path) { return t }
            return nil
        }
    }
}

/// Changed files on the left (commits above them, untracked names below), the picked file's diff on the right.
private struct CanvasChangesList: View {
    let changes: [DevFileChange]
    let files: [DevDiff.File]
    let commits: [DevCommit]
    let cut: Bool
    var untracked: [String] = []
    /// Said when there is nothing at all.
    let empty: String
    /// Reads a changed file as it is after the change (CodeDiffViewer's "Show N unchanged lines").
    var loadNew: (@MainActor (String) async -> String?)? = nil
    /// What was left out of the list (said above it).
    var note: String? = nil
    /// The item's key for a file picked from the chat (CanvasChangeFocus): picked and scrolled to.
    var focusKey: String? = nil
    @State private var selected: String?
    @State private var scrollTarget: String?
    @ObservedObject private var changeFocus = CanvasChangeFocus.shared

    var body: some View {
        content
            .onChange(of: focusKey.flatMap { changeFocus.focus[$0]?.seq }, initial: true) { _, _ in takeFocus() }
    }

    /// A file picked from the chat a moment ago: picked here when the list holds it.
    private func takeFocus() {
        guard let f = changeFocus.fresh(focusKey), let hit = FileChips.match(f.path, in: changes.map(\.path)) else { return }
        selected = hit
        scrollTarget = hit
    }

    @ViewBuilder private var content: some View {
        let list = changes
        if list.isEmpty && commits.isEmpty && untracked.isEmpty {
            CanvasNote(words: cut ? "The rest of the changes is too long to show here." : empty)
        } else {
            let pick = list.first(where: { $0.path == selected }) ?? list.first
            HStack(spacing: 0) {
                fileList(list, picked: pick?.path).frame(width: 230)
                Divider().overlay(WS.line)
                Group {
                    if let c = pick {
                        CodeDiffViewer(change: c, file: DevDiff.file(c.path, in: files), cut: cut,
                                       last: files.last.map { $0.path == c.path } ?? false, loadNew: loadNew)
                            .id(c.path)
                    } else if !untracked.isEmpty {
                        CanvasNote(words: "Untracked files are not in git yet: there is no diff to show.")
                    } else {
                        CanvasNote(words: "No file changes.")
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    private func fileList(_ list: [DevFileChange], picked: String?) -> some View {
        ScrollViewReader { proxy in
            fileScroll(list, picked: picked)
                .onChange(of: scrollTarget) { _, t in
                    guard let t else { return }
                    withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo(t, anchor: .center) }
                }
                .onAppear {
                    guard let t = scrollTarget else { return }
                    DispatchQueue.main.async { proxy.scrollTo(t, anchor: .center) }
                }
        }
    }

    private func fileScroll(_ list: [DevFileChange], picked: String?) -> some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 1) {
                if let note {
                    Text(verbatim: note).font(LiaFont.ui(11.5)).foregroundStyle(WS.text3)
                        .fixedSize(horizontal: false, vertical: true).padding(.horizontal, 8).padding(.vertical, 4)
                }
                if !commits.isEmpty {
                    sectionTitle(commits.count == 1 ? "1 commit" : "\(commits.count) commits")
                    ForEach(commits) { c in
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            Text(verbatim: c.short).font(.system(size: 11, design: .monospaced)).foregroundStyle(WS.text3)
                            Text(verbatim: c.title).font(LiaFont.ui(12)).foregroundStyle(WS.ink).lineLimit(2)
                            Spacer(minLength: 0)
                        }
                        .padding(.horizontal, 8).padding(.vertical, 4)
                        .help(c.sha + "\n" + c.msg)
                        .textSelection(.enabled)
                    }
                }
                if !commits.isEmpty || !untracked.isEmpty {
                    sectionTitle(list.count == 1 ? "1 file" : "\(list.count) files").padding(.top, commits.isEmpty ? 0 : 6)
                }
                if list.isEmpty {
                    Text("No file changes.").font(LiaFont.ui(12)).foregroundStyle(WS.text3).padding(8)
                }
                ForEach(list) { c in fileRow(c, on: c.path == picked).id(c.path) }
                if !untracked.isEmpty {
                    sectionTitle("Untracked").padding(.top, 6)
                    ForEach(untracked, id: \.self) { u in untrackedRow(u) }
                }
            }
            .padding(6)
        }
        .background(Color.dyn(0x15181C, 0xFAFBFC))
    }

    private func sectionTitle(_ t: String) -> some View {
        Text(t).font(LiaFont.ui(11, .semibold)).foregroundStyle(WS.text3)
            .padding(.horizontal, 8).padding(.top, 4).padding(.bottom, 2)
            .accessibilityAddTraits(.isHeader)
    }

    private func untrackedRow(_ path: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "doc.badge.plus").font(.system(size: 11)).foregroundStyle(WS.text3).frame(width: 14)
                .accessibilityHidden(true)
            Text(verbatim: path).font(LiaFont.ui(12.5)).foregroundStyle(WS.text2).lineLimit(1).truncationMode(.middle)
            Spacer(minLength: 4)
            Text("new").font(LiaFont.ui(11, .medium)).foregroundStyle(DevDiffLook.add)
        }
        .padding(.horizontal, 6).padding(.vertical, 4)
        .frame(minHeight: 24)
        .help(path)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text("\(path), untracked"))
    }

    private func fileRow(_ c: DevFileChange, on: Bool) -> some View {
        let parts = c.path.split(separator: "/")
        let name = parts.last.map(String.init) ?? c.path
        let dir = parts.count > 1 ? parts.dropLast().joined(separator: "/") : ""
        return Button { selected = c.path } label: {
            HStack(spacing: 6) {
                Image(systemName: "doc.text").font(.system(size: 11))
                    .foregroundStyle(on ? SettingsLook.accent : WS.text3).frame(width: 14)
                VStack(alignment: .leading, spacing: 0) {
                    Text(verbatim: name).font(LiaFont.ui(12.5, on ? .medium : .regular)).foregroundStyle(WS.ink)
                        .lineLimit(1).truncationMode(.middle)
                    if !dir.isEmpty {
                        Text(verbatim: dir).font(LiaFont.ui(10.5)).foregroundStyle(WS.text3).lineLimit(1).truncationMode(.head)
                    }
                }
                Spacer(minLength: 4)
                CanvasCounts(add: c.add, del: c.del, binary: c.binary)
            }
            .padding(.horizontal, 6).padding(.vertical, 4)
            .frame(minHeight: 26)
            .background(on ? SettingsLook.accentSoft : Color.clear, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.liaPlain)
        .liaPointer()
        .help(c.path)
        .accessibilityLabel(Text(c.binary ? "\(c.path), binary" : "\(c.path), \(c.add) added, \(c.del) removed"))
        .accessibilityAddTraits(on ? .isSelected : [])
    }
}

/// "+40 \u{2212}2" (+ green, \u{2212} red) or "binary".
private struct CanvasCounts: View {
    let add: Int
    let del: Int
    let binary: Bool
    var size: CGFloat = 11

    var body: some View {
        if binary {
            Text("binary").font(LiaFont.ui(size)).foregroundStyle(WS.text3)
        } else {
            (Text(verbatim: "+\(add)").foregroundColor(DevDiffLook.add)
                + Text(verbatim: " \u{2212}\(del)").foregroundColor(DevDiffLook.del))
                .font(.system(size: size, weight: .medium, design: .monospaced))
                .lineLimit(1)
                .fixedSize()
        }
    }
}

