import SwiftUI
import AppKit

// 0.2.11 ("inside the messenger 'Open creative' and the like are hard to press").
// They were not hard to press: they did nothing. When the conversation moved into the workspace's messenger (94bdfc7)
// its messages were drawn with the default WidgetActions, whose every action is empty, and with an empty
// onOpenBlock: "Open creatives", a creative's thumbnail, "Open leads", the retention block's ad, Connect Meta's
// Settings, a file card and a chart's "Open in panel" all clicked into nothing. This puts back what ChatScreen did
// (6bf093a): the creatives / ad / leads popups over the conversation's own column, and the document viewer for files.

/// What a widget or a block in one conversation opens. Held by its ThreadColumn; the rows find it through the
/// environment (a weak link), so the rows' equality slots (ThreadRowSlot) never see a new closure.
@MainActor
final class ChatWidgetRouter: ObservableObject {
    let popups = ChatPopupModel()
    /// A file or a chart page opened from a block (AttachmentDocSheet).
    @Published var doc: AttachmentDocSheet.Item?

    private weak var ws: WorkspaceModel?
    private weak var chat: TeamChatModel?
    private weak var library: LibraryStore?
    private var settings: (String) -> Void = { _ in }

    func bind(ws: WorkspaceModel, chat: TeamChatModel, library: LibraryStore, openSettings: @escaping (String) -> Void) {
        self.ws = ws
        self.chat = chat
        self.library = library
        self.settings = openSettings
    }

    /// The actions every widget of this conversation gets. Each one changes state at once (the popup's own orbit
    /// shows while it reads), nothing waits for the network before the click shows.
    var actions: WidgetActions {
        var w = WidgetActions()
        w.openSettings = { [weak self] tab in self?.settings(tab) }
        w.openCreatives = { [weak self] perf, range, account in
            guard let self else { return }
            popups.open(.creatives(scope(account ?? perf?.account, perf?.accountName, range ?? perf?.period)))
        }
        w.openCreative = { [weak self] stat, range, account in
            // ai.js openBlockAd (r71): the creatives list first, the ad stacked over it.
            guard let self else { return }
            let s = scope(account, nil, range)
            popups.open(.creatives(s))
            popups.push(.ad(AdSeed(adId: stat.id, name: stat.name, scope: s, row: nil)))
        }
        w.openLeads = { [weak self] leads in
            guard let self else { return }
            popups.open(.leads(scope(leads.account, leads.accountName, leads.period)))
        }
        w.openAd = { [weak self] adId, name, account in
            guard let self, !adId.isEmpty else { return }
            // The block's account, or the conversation's only one; never the first connected (rule 11)
            guard let s = strictScope(account) else { refuse(PopupAccountRule.unknownAccount); return }
            popups.open(.creatives(s))
            popups.push(.ad(AdSeed(adId: adId, name: name, scope: s, row: nil)))
        }
        return w
    }

    /// A file card or a chart's "Open in panel": the signed page in the window's document viewer.
    func openBlock(_ block: ChatBlock) {
        guard let u = block.absoluteURL(base: AppConfig.aiBase) else { return }
        let name = (block.filename?.isEmpty == false ? block.filename : nil) ?? (block.isChart ? "Chart" : "File")
        doc = AttachmentDocSheet.Item(name: name, url: u)
    }

    private func threadAccounts() -> [(id: String, name: String)] {
        let profile = ws.flatMap { w in w.profiles.first { $0.id == chat?.profile } ?? w.profile }
        var thread: [(id: String, name: String)] = profile?.metaAccounts ?? []
        if thread.isEmpty, let id = profile?.metaAccount {
            thread = [(id: id, name: profile?.metaAccountName ?? chat?.accountName ?? "")]
        }
        return thread
    }

    private func strictScope(_ account: String?) -> PopupScope? {
        let known = (library?.accounts ?? []).map { (id: $0.id, name: $0.name) }
        guard let r = PopupAccountRule.strict(given: account, givenName: nil, thread: threadAccounts(), known: known) else { return nil }
        return PopupScope(account: r.id, accountName: r.name, range: DateRange.lastDays(30, now: Date()))
    }

    private func refuse(_ text: String) {
        let a = NSAlert()
        a.messageText = "Can't open this ad"
        a.informativeText = text
        a.addButton(withTitle: "OK")
        if let w = NSApp.keyWindow { a.beginSheetModal(for: w) } else { a.runModal() }
    }

    /// The account and period a popup opens on (PopupAccountRule): the widget's, else this conversation's workspace
    /// account, else the first connected one; the last 30 days when the widget carried no period.
    private func scope(_ account: String?, _ name: String?, _ range: DateRange?) -> PopupScope {
        let profile = ws.flatMap { w in w.profiles.first { $0.id == chat?.profile } ?? w.profile }
        var thread: [(id: String, name: String)] = profile?.metaAccounts ?? []
        if thread.isEmpty, let id = profile?.metaAccount {
            thread = [(id: id, name: profile?.metaAccountName ?? chat?.accountName ?? "")]
        }
        let known = (library?.accounts ?? []).map { (id: $0.id, name: $0.name) }
        let r = PopupAccountRule.resolve(given: account, givenName: name, thread: thread, known: known)
        return PopupScope(account: r.id, accountName: r.name, range: range ?? DateRange.lastDays(30, now: Date()))
    }
}

/// The router of the conversation a row is drawn in (nil outside a ThreadColumn: the actions stay empty).
struct ChatWidgetLink: Equatable {
    weak var router: ChatWidgetRouter?

    /// The same router is the same link, so setting it on every redraw of the column redraws no row.
    static func == (a: ChatWidgetLink, b: ChatWidgetLink) -> Bool { a.router === b.router }
}

private struct ChatWidgetLinkKey: EnvironmentKey { static let defaultValue = ChatWidgetLink() }

extension EnvironmentValues {
    var chatWidgets: ChatWidgetLink {
        get { self[ChatWidgetLinkKey.self] }
        set { self[ChatWidgetLinkKey.self] = newValue }
    }
}
