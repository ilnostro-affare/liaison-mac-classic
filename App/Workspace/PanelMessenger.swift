import SwiftUI
import WebKit

// MARK: - the agents' messenger in the side panel (its first, fixed page)

/// The side panel's "agents" page is our messenger in a narrow column: the agents' figures on top
/// (Team first, then the dock's order; an agent that needs Meta in a workspace without it is grey), then the picked
/// dialogue's thread and composer - the sheet's own `ThreadColumn` (formatting, reactions, the message menu, Forward,
/// attachments, drafts, Stop, approvals, typing, the huddle). Left out: the dialogue rail, search, the profile and the
/// agent's browser pane; while the picked agent works in its browser a strip on top opens the full conversation.
struct AgentsMiniMessenger: View {
    @ObservedObject var ws: WorkspaceModel
    /// The picked dialogue ("team" or an agent id), kept between launches.
    @AppStorage("lia_ws_panel_dlg") private var picked = "team"
    /// Agents hidden in this workspace (Settings > Team) leave the figures on top.
    @ObservedObject private var shown = AgentShownStore.shared

    /// Team (Lia's figure) first, then the agents in dock order; agents not connected yet are left out.
    private var rows: [PanelAgentRow] {
        var out: [PanelAgentRow] = []
        if let lia = ws.roster.first(where: { $0.lead }) { out.append(PanelAgentRow(dlg: "team", agent: lia)) }
        _ = shown.rev
        for a in ws.shownAgents(DockOrder.sorted(ws.roster.filter { !$0.lead && !$0.soon })) {
            out.append(PanelAgentRow(dlg: DialogueSummary.dlg(forAgent: a.id), agent: a))
        }
        return out
    }

    /// The picked dialogue, or Team when it is gone or locked here.
    private var dlg: String {
        guard picked != "team", let a = ws.agent(picked), !a.soon, !ws.isLocked(a.id), !ws.shownAgents([a]).isEmpty else { return "team" }
        return picked
    }

    var body: some View {
        VStack(spacing: 0) {
            PanelAgentPicker(ws: ws, rows: rows, current: dlg) { picked = $0 }
            Rectangle().fill(WS.line).frame(height: 1)
            if let c = ws.chat(for: dlg) {
                PanelThread(ws: ws, chat: c)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .id(c.key)
            } else {
                Text("Pick a workspace to write to the agents.")
                    .font(LiaFont.ui(12.5)).foregroundStyle(WS.text3).multilineTextAlignment(.center)
                    .padding(24).frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        // ("clicking Team shifts the messenger to the right"): the column is pinned to the panel's
        // leading edge at the panel's width, so a dialogue whose content is wider never re-centres it; any overflow
        // is clipped on the trailing side.
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .clipped()
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text("Agents"))
    }
}

private struct PanelAgentRow: Identifiable {
    let dlg: String
    let agent: AgentInfo
    var id: String { dlg }
}

/// The row of figures: a click picks the dialogue; a locked agent's opens Settings > Meta.
private struct PanelAgentPicker: View {
    @ObservedObject var ws: WorkspaceModel
    @EnvironmentObject private var app: AppModel
    let rows: [PanelAgentRow]
    let current: String
    let onPick: (String) -> Void

    var body: some View {
        HStack(spacing: 2) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 2) {
                    ForEach(rows) { r in cell(r.dlg, r.agent) }
                }
                .padding(.horizontal, 6)
            }
            .defaultScrollAnchor(.leading)   // the figures start at the leading edge, whichever one is picked
            .frame(maxWidth: .infinity, alignment: .leading)
            Button { ws.openDialogue(current) } label: {
                Image(systemName: "arrow.up.left.and.arrow.down.right").font(.system(size: 10.5, weight: .semibold)).foregroundStyle(WS.text2)
                    .frame(width: 26, height: 26).contentShape(Rectangle())
            }
            .buttonStyle(.liaPlain)
            .liaHover(.icon, radius: 8)
            .accessibilityLabel(Text("Open the full conversation"))
            .padding(.trailing, 6)
        }
        .frame(height: 56)
    }

    private func cell(_ dlg: String, _ a: AgentInfo) -> some View {
        let name = dlg == "team" ? "Lia" : a.name   // The team entry is "Lia"
        let locked = dlg != "team" && ws.isLocked(a.id)
        let selected = dlg == current
        let unread = ws.unread(dlg: dlg)
        return Button {
            if locked { app.openSettings("meta") } else { onPick(dlg) }
        } label: {
            VStack(spacing: 2) {
                AgentAvatar(agent: a, size: 28, status: ws.status(of: a.id))
                    .saturation(locked ? 0 : 1)
                    .opacity(locked ? 0.45 : 1)
                    .overlay(alignment: .topTrailing) {
                        if unread && !selected {
                            Circle().fill(WS.red).frame(width: 8, height: 8)
                                .overlay(Circle().stroke(WS.surface, lineWidth: 1.5))
                                .offset(x: 2, y: -2)
                        }
                    }
                Text(name).font(LiaFont.ui(10, selected ? .semibold : .regular))
                    .foregroundStyle(locked ? WS.text3 : (selected ? WS.ink : WS.text2))
                    .lineLimit(1)
            }
            .frame(width: 44, height: 48)
            .background(selected ? Color(hex: a.colorHex).opacity(0.14) : Color.clear,
                        in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.liaPlain)
        .liaPointer()
        // The name is under the figure; hover tells the role (Lia: "Assistant").
        .liaTip(locked ? "Connect Meta" : nil)
        .accessibilityLabel(Text([name, locked ? "locked, connect Meta" : nil, unread ? "unread" : nil].compactMap { $0 }.joined(separator: ", ")))
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
    }
}

/// The picked dialogue: the working strip, then the messenger's thread and composer in compact form.
private struct PanelThread: View {
    @ObservedObject var ws: WorkspaceModel
    @ObservedObject var chat: TeamChatModel
    @ObservedObject private var local: ChatLocal
    @ObservedObject private var recent = AgentBrowserRecent.shared
    /// Never opened here (no search panel); the thread only reads it.
    @StateObject private var search = ChatSearch()

    init(ws: WorkspaceModel, chat: TeamChatModel) {
        _ws = ObservedObject(wrappedValue: ws)
        _chat = ObservedObject(wrappedValue: chat)
        _local = ObservedObject(wrappedValue: ChatLocal.shared(chat.key))
    }

    /// Who works in a browser for this dialogue now: its own agent only (each agent's dialogue
    /// shows only its own browser - a teammate's browser work is in the teammate's dialogue, and Team's agent strip no
    /// longer stands in for an agent's own).
    private var working: (agent: AgentInfo, dlg: String)? {
        let own = AgentPaneChoice.shown(dlg: chat.dlg)
        guard chat.webAgent == own || recent.isBusy(chat.key, own), let a = AgentInfo.lookup(own, in: ws.roster) else { return nil }
        return (a, chat.dlg)
    }

    var body: some View {
        VStack(spacing: 0) {
            if let w = working, let p = ws.profiles.first(where: { $0.id == chat.profile }) {
                PanelWorkingStrip(agent: w.agent, browser: ws.agentBrowser(w.agent.id, in: p)) { ws.openDialogue(w.dlg) }
                    .padding(.horizontal, 8).padding(.top, 8)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
            ThreadColumn(ws: ws, chat: chat, search: search, local: local,
                         onOpenBrowser: { _ in ws.openDialogue(chat.dlg) },
                         compact: true, origin: .sidePanel)
        }
        // Dev's Preview card: the panel has no right side, so Open opens the full conversation with its Canvas.
        .environment(\.devPreviewOpen, DevPreviewOpenAction(run: { [ws, chat] preview in
            CanvasStore.shared.note(chat)
            CanvasStore.shared.open(CanvasItem(preview: preview, profile: chat.profile), key: chat.key)
            ws.openDialogue(key: chat.key)
        }, block: { [ws, chat] b in
            guard let item = CanvasItem(block: b, profile: chat.profile) else { return }
            CanvasStore.shared.note(chat)
            CanvasStore.shared.open(item, key: chat.key)
            ws.openDialogue(key: chat.key)
        }))
        .animation(.easeOut(duration: 0.2), value: working?.agent.id)
        .task(id: chat.key) { if chat.loaded { await chat.refreshLatest() } else { await chat.load() } }
        // Dev keeps working on the server while the app is away: coming back shows its steps.
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            Task { await chat.refreshLatest() }
        }
        .task(id: chat.key) { await ChatLocal.shared(chat.key).load(auth: chat.auth) }
        // A dialogue read in the panel is read: its unread dot goes, as when the sheet shows it.
        .onChange(of: chat.items.count, initial: true) { _, _ in ws.markSeen(chat.dlg) }
        // Links in answers open in Peek, as in the sheet (\u{2318}-click: a new tab of the workspace's browser).
        .environment(\.openURL, OpenURLAction { url in route(url) })
    }

    private func route(_ url: URL) -> OpenURLAction.Result {
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else { return .systemAction }
        if NSEvent.modifierFlags.contains(.command), let b = ws.currentBrowser {
            b.open(url)
            ws.show("Opened in a new tab", symbol: "plus.square.on.square")
        } else {
            ws.peek = url
        }
        return .handled
    }
}

/// "<Name> is working. Click to watch.": a small live picture of the agent's page (every 2 s; the favicon when the
/// page cannot be drawn) and its title. A click opens the full conversation with the agent's browser.
private struct PanelWorkingStrip: View {
    let agent: AgentInfo
    @ObservedObject var browser: BrowserModel
    let onOpen: () -> Void

    var body: some View {
        if let t = browser.selected {
            PanelWorkingStripRow(agent: agent, tab: t, onOpen: onOpen).id(t.id)
        } else {
            PanelWorkingStripRow(agent: agent, tab: nil, onOpen: onOpen)
        }
    }
}

private struct PanelWorkingStripRow: View {
    let agent: AgentInfo
    let tab: BrowserTab?
    let onOpen: () -> Void
    @State private var shot: NSImage?

    var body: some View {
        Button(action: onOpen) {
            HStack(spacing: 10) {
                thumb
                VStack(alignment: .leading, spacing: 1) {
                    Text("\(agent.name) is working. Click to watch.")
                        .font(LiaFont.ui(12, .semibold)).foregroundStyle(WS.ink).lineLimit(1)
                    if let tab { PanelTabTitle(tab: tab) }
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right").font(.system(size: 10, weight: .bold)).foregroundStyle(WS.text3)
            }
            .padding(6).padding(.trailing, 4)
            .background(Color(hex: agent.colorHex).opacity(0.08), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(Color(hex: agent.colorHex).opacity(0.35), lineWidth: 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(.liaPlain)
        .liaPointer()
        .accessibilityLabel(Text("\(agent.name) is working in the browser. Open to watch"))
        .task { await refresh() }
    }

    private var thumb: some View {
        ZStack {
            WS.surface
            if let shot {
                Image(nsImage: shot).resizable().aspectRatio(contentMode: .fill)
            } else if let tab {
                PanelTabIcon(tab: tab)
            } else {
                AgentAvatar(agent: agent, size: 18, status: .working)
            }
        }
        .frame(width: 64, height: 40)
        .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).stroke(WS.line2, lineWidth: 1))
        .accessibilityHidden(true)
    }

    /// A small picture of the page every 2 s while the strip is on screen (the task ends with the view). Only a page
    /// that is already made and loaded is drawn; never one created for this.
    private func refresh() async {
        while !Task.isCancelled {
            if let tab, !tab.isStart, !tab.asleep, let w = tab.loadedWebView, w.url != nil {
                let config = WKSnapshotConfiguration()
                config.snapshotWidth = NSNumber(value: 192)
                let img: NSImage? = await withCheckedContinuation { k in w.takeSnapshot(with: config) { image, _ in k.resume(returning: image) } }
                if let img { shot = img }
            }
            try? await Task.sleep(nanoseconds: 2_000_000_000)
        }
    }
}

private struct PanelTabTitle: View {
    @ObservedObject var tab: BrowserTab
    var body: some View {
        Text(tab.isStart ? "Opening a page\u{2026}" : tab.displayTitle)
            .font(LiaFont.ui(11)).foregroundStyle(WS.text3).lineLimit(1)
    }
}

private struct PanelTabIcon: View {
    @ObservedObject var tab: BrowserTab
    var body: some View {
        if let f = tab.favicon {
            Image(nsImage: f).resizable().frame(width: 16, height: 16)
        } else {
            Image(systemName: "globe").font(.system(size: 14)).foregroundStyle(WS.text3)
        }
    }
}
