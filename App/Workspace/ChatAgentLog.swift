import SwiftUI

/// "What did <Agent> do?".: not a log. The agent's tasks in its own browser, each a card
/// (title, time, outcome) opening to a few short steps, by day (AgentHistoryStore, this Mac, 200 tasks); the running
/// task on top, live. The raw log ("Details") is gone; each card's Go to opens the dialogue at the task's result.
struct ChatAgentLogSheet: View {
    let name: String
    /// Kept for the callers; the sheet shows the task history only.
    let entries: [AgentLog.Entry]
    /// The agent's task history in this workspace.
    var history: AgentHistoryStore?
    /// Where Go to opens the dialogue (nil: the workspace in front).
    var ws: WorkspaceModel?
    /// Server: where the agent's work items are read (its dialogue); nil: the browser tasks alone.
    struct WorkSource { let auth: AuthStore; let profile: String; let dlg: String }
    var work: WorkSource?
    let onClose: () -> Void
    /// What the server says the agent did (searches, drafts, files, prepared changes), newest first.
    @State private var workItems: [DlgWork] = []

    init(name: String, entries: [AgentLog.Entry], history: AgentHistoryStore? = nil, ws: WorkspaceModel? = nil,
         work: WorkSource? = nil, onClose: @escaping () -> Void) {
        self.name = name
        self.entries = entries
        self.history = history
        self.ws = ws
        self.work = work
        self.onClose = onClose
    }

    private var noTasks: Bool { history?.log.tasks.isEmpty ?? true }
    private var empty: Bool { noTasks && workItems.isEmpty }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Rectangle().fill(WS.line).frame(height: 1)
            if !empty {
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        if !workItems.isEmpty { workList }
                        if let history, !noTasks { AgentHistoryList(store: history, onGoTo: goTo) }
                    }
                }
            } else {
                Text("\(name) has not done anything in this browser yet.")
                    .font(LiaFont.ui(13)).foregroundStyle(WS.text2)
                    .frame(maxWidth: .infinity, minHeight: 120)
            }
        }
        // The header at the top whatever the height (it sat mid-sheet over an empty area); an empty
        // log is a short card, a long one stops at 520.
        .frame(width: 520, height: empty ? 200 : 520, alignment: .top)
        .background(WS.surface)
        .task { await loadWork() }
    }

    private func loadWork() async {
        guard let w = work, let list = try? await LiaAPI(auth: w.auth).workItems(profile: w.profile, dlg: w.dlg) else { return }
        workItems = list
    }

    /// The server's work items, newest first: a click opens the dialogue at the message the work came from.
    private var workList: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("In the dialogue").font(LiaFont.ui(12, .semibold)).foregroundStyle(WS.text2)
                .padding(.horizontal, 18).padding(.top, 12).padding(.bottom, 4)
                .accessibilityAddTraits(.isHeader)
            ForEach(workItems) { it in
                ChatWorkRow(item: it) { openWork(it) }
            }
        }
        .padding(.bottom, 8)
    }

    private func openWork(_ it: DlgWork) {
        guard !it.msgId.isEmpty, let w = ws ?? WorkspaceModel.current else { return }
        onClose()
        w.openDialogue(it.dlg, jumpTo: it.msgId)
    }

    /// The sheet closes, the dialogue opens and scrolls to the agent's report of the task.
    private func goTo(_ t: AgentTaskRecord) {
        guard let w = ws ?? WorkspaceModel.current else { return }
        let store = history
        onClose()
        Task { @MainActor in await AgentTaskGoTo.go(t, store: store, ws: w) }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Text("What did \(name) do?").font(LiaFont.ui(16, .bold)).foregroundStyle(WS.ink)
                .accessibilityAddTraits(.isHeader)
            Spacer()
            Button(action: onClose) {
                Image(systemName: "xmark").font(.system(size: 11, weight: .semibold)).foregroundStyle(WS.text2)
                    .frame(width: 28, height: 28)
                    .background(WS.soft, in: Circle())
                    .contentShape(Circle())
            }
            .buttonStyle(.liaPlain)
            .keyboardShortcut(.cancelAction)
            .liaPointer()
            .accessibilityLabel(Text("Close"))
        }
        .padding(.horizontal, 18).padding(.vertical, 14)
    }
}

/// One work item: what was done, and when.
private struct ChatWorkRow: View {
    let item: DlgWork
    let onOpen: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: onOpen) {
            HStack(spacing: 10) {
                Image(systemName: "checkmark.circle").font(.system(size: 12, weight: .medium)).foregroundStyle(WS.text3)
                    .accessibilityHidden(true)
                Text(item.title).font(LiaFont.ui(13)).foregroundStyle(WS.ink).lineLimit(2)
                Spacer(minLength: 8)
                if let ts = item.ts {
                    Text(ts, format: .dateTime.month(.abbreviated).day().hour().minute())
                        .font(LiaFont.ui(11.5)).foregroundStyle(WS.text3)
                }
            }
            .padding(.horizontal, 12).padding(.vertical, 7)
            .background(hover ? WS.soft : Color.clear, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.liaPlain)
        .onHover { hover = $0 }
        .liaPointer()
        .padding(.horizontal, 6)
        .accessibilityLabel(Text(item.title))
    }
}
