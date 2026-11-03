import SwiftUI
import WebKit

// "Agent Beside Me" (Opera Neon, Dia): the person's page on the left, an agent's own browser on the
// right, read-only: the agent's selected tab with its live overlay (cursor, highlight). The person cannot click into
// it (the agent's page is the agent's); Take over stops the agent, and after the task "Open in main window" copies the
// address into the person's browser.
// A web view lives in one place at a time: while a conversation sheet is open (it may show the same agent browser),
// the pane shows a placeholder instead of taking the view away from it.

struct AgentBesidePane: View {
    @ObservedObject var ws: WorkspaceModel
    let agentID: String
    let profile: CompanyProfile

    var body: some View {
        AgentBesideContent(ws: ws, agent: ws.agent(agentID), browser: ws.agentBrowser(agentID, in: profile))
    }
}

private struct AgentBesideContent: View {
    @ObservedObject var ws: WorkspaceModel
    let agent: AgentInfo?
    @ObservedObject var browser: BrowserModel
    /// The agent's tasks (history) from here too, not only from the conversation.
    @State private var showLog = false

    private var name: String { agent?.name ?? "Agent" }
    private var tint: Color { Color(hex: agent?.colorHex ?? 0x3B5BFD) }

    var body: some View {
        VStack(spacing: 0) {
            header
            stage
        }
        .background(WS.surface)
        .clipShape(RoundedRectangle(cornerRadius: WS.radius - 4, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: WS.radius - 4, style: .continuous).stroke(tint.opacity(0.6), lineWidth: 1.5))
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text("\(name)\u{2019}s browser, read only"))
        .liaModal(isPresented: $showLog) {
            ChatAgentLogSheet(name: name, entries: browser.agent.log.recent, history: AgentHistoryStore.shared(for: browser)) { showLog = false }
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            if let a = agent { AgentAvatar(agent: a, size: 20) }
            VStack(alignment: .leading, spacing: 0) {
                Text("\(name)\u{2019}s browser").font(LiaFont.ui(12.5, .semibold)).foregroundStyle(WS.ink).lineLimit(1)
                Text(browser.selected?.url?.host ?? "Nothing open").font(LiaFont.ui(11)).foregroundStyle(WS.text3).lineLimit(1)
            }
            Spacer(minLength: 6)
            Button { showLog = true } label: { Image(systemName: "list.bullet.rectangle") }
                .buttonStyle(WSButtonStyle(small: true))
                .liaPointer()
                .liaTip("What did \(name) do?")
                .accessibilityLabel(Text("What did \(name) do?"))
            // One control. Take over (step, progress, Stop) while the agent works; Open in main window after.
            AgentTakeOverButton(browser: browser, name: name, tint: tint, running: browser.agent.active,
                                onOpenInMain: { openAsTab($0) })
            Button { WSExtras.shared.agentBeside = nil } label: {
                Image(systemName: "xmark").font(.system(size: 9, weight: .bold)).foregroundStyle(WS.text2)
                    .frame(width: 22, height: 22)
            }
            .buttonStyle(.liaPlain)
            .liaHover(.icon, radius: 7)
            .accessibilityLabel(Text("Close \(name)\u{2019}s browser"))
        }
        .padding(.horizontal, 10)
        .frame(height: 50)
        .background(tint.opacity(0.06))
    }

    @ViewBuilder private var stage: some View {
        if ws.sheet != nil {
            placeholder("Shown in the conversation")
        } else if let t = browser.selected, !t.isStart {
            AgentBesideTab(tab: t, browser: browser, tint: tint, name: name)
                .id(t.id)
        } else {
            placeholder("\(name) has no page open yet")
        }
    }

    private func placeholder(_ s: String) -> some View {
        Text(s).font(LiaFont.ui(13)).foregroundStyle(WS.text3)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func openAsTab(_ u: URL) {
        ws.currentBrowser?.open(u)
    }
}

private struct AgentBesideTab: View {
    @ObservedObject var tab: BrowserTab
    let browser: BrowserModel
    let tint: Color
    let name: String

    var body: some View {
        ZStack {
            WebViewHost(webView: tab.webView)
                .allowsHitTesting(false)
            AgentOverlay(agent: browser.agent, tabID: tab.id, tint: tint, name: name, web: browser.web)
            // Read-only: clicks and scrolls stop here, never reach the agent's page.
            Color.white.opacity(0.001)
                .contentShape(Rectangle())
                .accessibilityHidden(true)
        }
        .onAppear { tab.loadIfPending() }
    }
}
