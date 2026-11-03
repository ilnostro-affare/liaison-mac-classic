import SwiftUI

/// "Forward\u{2026}" on a message: a small glass list of this workspace's dialogues (Team first, then each
/// agent). A pick opens that dialogue with the message waiting in its composer as a quoted chip (removable) and the
/// field empty for a comment; nothing is sent until the person presses Send.
struct ChatForwardPicker: View {
    @ObservedObject var ws: WorkspaceModel
    /// The dialogue the message is in (not offered).
    let from: String
    let item: TeamItem
    /// The text selected in the message when Forward was picked: only that part goes (nil: the message).
    var fragment: String? = nil
    let onDone: () -> Void

    private var targets: [String] { ws.dialogueIds.filter { $0 != from && ws.agent($0)?.soon != true } }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Forward to").font(LiaFont.ui(12, .semibold)).foregroundStyle(WS.text2)
                .padding(.horizontal, 8).padding(.top, 2)
                .accessibilityAddTraits(.isHeader)
            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(targets, id: \.self) { d in
                        ChatForwardRow(ws: ws, title: ws.dialogueTitle(d), agents: [d == "team" ? "lia" : d]) { forward(to: d) }
                    }
                }
            }
            .frame(maxHeight: 280)
            .scrollIndicators(.hidden)
        }
        .padding(6)
        .frame(width: 250)
        .wsGlass(16)
    }

    private var draft: ChatForwardDraft.Draft {
        var who = "You"
        if let id = item.agent { who = ws.agent(id)?.name ?? "an agent" }
        // The person's own words without a reply quote or attachment markers (an agent must not act on a forwarded
        // [attached_creative ...]); an agent's answer as plain text.
        let whole = item.agent == nil ? ChatAttach.split(ChatQuote.split(item.message.content).body).text : ChatSearch.text(of: item)
        let part = fragment?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let words = part.isEmpty ? whole : part
        return ChatForwardDraft.Draft(who: who, agent: item.agent, text: words)
    }

    private func forward(to dlg: String) {
        guard let c = ws.chat(for: dlg) else { return }
        ChatForwardDraft.shared.put(draft, in: c.key)
        onDone()
        ws.openDialogue(dlg)
    }
}

private struct ChatForwardRow: View {
    @ObservedObject var ws: WorkspaceModel
    let title: String
    let agents: [String]
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                HStack(spacing: -6) {
                    ForEach(Array(agents.prefix(3)), id: \.self) { id in
                        if let a = ws.agent(id) { AgentAvatar(agent: a, size: 22) }
                    }
                }
                .frame(width: 42, alignment: .leading)
                .accessibilityHidden(true)
                Text(title).font(LiaFont.ui(13)).foregroundStyle(WS.ink).lineLimit(1)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 8).frame(height: 34)
            .background(hover ? WS.blue.opacity(0.10) : Color.clear, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.liaPlain)
        .onHover { hover = $0 }
        .liaPointer()
        .accessibilityLabel(Text("Forward to \(title)"))
    }
}

/// The forwarded message waiting in a dialogue's composer, by its key, until it is sent or removed (kept for
/// the app's life: the sheet re-creates the thread column when it switches conversations).
@MainActor
final class ChatForwardDraft: ObservableObject {
    static let shared = ChatForwardDraft()
    /// What starts the quote line of a forwarded message.
    nonisolated static let prefix = "Forwarded from "

    struct Draft: Equatable {
        let who: String
        let agent: String?
        let text: String

        /// One line for the quote (the whole message, its line breaks as spaces).
        var line: String {
            text.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
                .trimmingCharacters(in: .whitespaces)
        }

        /// The message that goes: the quote line, then the person's comment (if any).
        func compose(_ comment: String) -> String {
            let quote = "> " + ChatForwardDraft.prefix + who + ": " + line
            let c = comment.trimmingCharacters(in: .whitespacesAndNewlines)
            return c.isEmpty ? quote : quote + "\n\n" + c
        }
    }

    @Published private(set) var drafts: [String: Draft] = [:]

    func put(_ d: Draft, in thread: String) { drafts[thread] = d }
    func draft(_ thread: String) -> Draft? { drafts[thread] }
    func clear(_ thread: String) { drafts[thread] = nil }
}

/// The forwarded message over the composer: who said it, its first line, \u{00d7} removes it.
struct ChatForwardChip: View {
    let draft: ChatForwardDraft.Draft
    let agent: AgentInfo?
    let onRemove: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "arrowshape.turn.up.right.fill").font(.system(size: 10, weight: .semibold))
                .foregroundStyle(agent.map { Color(hex: $0.colorHex) } ?? WS.blue)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                Text("Forwarded from \(draft.who)").font(LiaFont.ui(11.5, .semibold))
                    .foregroundStyle(agent.map { Color(hex: $0.colorHex) } ?? WS.text2)
                Text(draft.line).font(LiaFont.ui(12)).foregroundStyle(WS.text2).lineLimit(1).truncationMode(.tail)
            }
            Spacer(minLength: 6)
            Button(action: onRemove) {
                Image(systemName: "xmark").font(.system(size: 9, weight: .bold)).foregroundStyle(WS.text2)
                    .frame(width: 20, height: 20).background(WS.soft, in: Circle())
            }
            .buttonStyle(.liaPlain).liaPointer()
            .accessibilityLabel(Text("Remove forwarded message"))
        }
        .padding(.horizontal, 10).padding(.vertical, 6)
        .wsGlass(12)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text("Forwarding \(draft.who)'s message: \(draft.line). Add a comment and send."))
    }
}

/// Where a message the person sent from outside the conversation came from ("from notes"), small, under
/// their bubble.
struct ChatOriginChip: View {
    let label: String

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: "arrow.turn.down.right").font(.system(size: 8.5, weight: .semibold))
            Text(label)
        }
        .font(LiaFont.ui(10.5, .medium))
        .foregroundStyle(WS.text3)
        .padding(.horizontal, 7).frame(height: 18)
        .background(WS.soft, in: Capsule())
        .accessibilityLabel(Text("Sent \(label)"))
    }
}

// (item 11): a quick action outside the conversation (\u{2318}E, the page menu, notes, the brief, quick
// tasks, the address bar's @agent) never sends by itself. It opens the agent's conversation with the words in the
// Composer ('s draft) and, for a selection, the quoted chip; the person presses Send.
// Machine replies (a gate, an ask, a browser result) and the side panel's own field still send directly.
extension WorkspaceModel {
    /// Puts `text` (and `quote`) into the composer of `agent`'s conversation ("lia": Team) and opens it.
    func draft(_ text: String, toAgent agent: String, quote: ChatForwardDraft.Draft? = nil) {
        let dlg = DialogueSummary.dlg(forAgent: agent)
        guard let c = chat(for: dlg) else { return }
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let quote { ChatForwardDraft.shared.put(quote, in: c.key) }
        if sheet == dlg {
            // The composer is on screen: its own field takes the words (EntityPopup's signal).
            if !t.isEmpty { NotificationCenter.default.post(name: .liaPutText, object: nil, userInfo: ["text": t]) }
            return
        }
        // The composer reads its saved draft when it appears (ConversationSheet, `lia_ws_draft_` + key).
        if !t.isEmpty {
            let key = "lia_ws_draft_" + c.key
            let old = (UserDefaults.standard.string(forKey: key) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            UserDefaults.standard.set(old.isEmpty ? t : old + "\n" + t, forKey: key)
        }
        sheet = dlg
    }
}
