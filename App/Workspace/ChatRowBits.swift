import SwiftUI
import AppKit

// Pieces around a message in the workspace messenger: the marks under a bubble (reactions are in
// ChatReactions.swift; the message's other actions are its context menu), the time inside it, the pinned capsule, the delivery status, and the approval's diff list, its
// Inline editor and its collapsed row after the decision.

// MARK: - marks

/// What the person marked on a message, small under its bubble (a click takes it back).
struct ChatMarkChip: View {
    let symbol: String
    let label: String
    let onRemove: () -> Void
    var body: some View {
        Button(action: onRemove) {
            Image(systemName: symbol).font(.system(size: 9.5, weight: .semibold)).foregroundStyle(WS.blue)
                .frame(width: 22, height: 18)
                .background(WS.blue.opacity(0.10), in: Capsule())
        }
        .buttonStyle(.liaPlain).liaHoverWash(Capsule())
        .liaTip(label)
        .accessibilityLabel(Text(label))
        .accessibilityHint(Text("Removes it"))
        .transition(.scale.combined(with: .opacity))
    }
}

/// An agent's figure beside its messages (no name above them): the tip names the agent, a click opens
/// its profile.
struct ChatAgentFace: View {
    let agent: AgentInfo
    var size: CGFloat = 30
    var status: AgentStatus = .idle
    let onOpen: (String) -> Void

    var body: some View {
        Button { onOpen(agent.id) } label: {
            AgentAvatar(agent: agent, size: size, status: status).contentShape(Circle())
        }
        .buttonStyle(.liaPlain).liaHoverWash(Circle())
        .accessibilityLabel(Text(agent.name))
        .accessibilityHint(Text("Opens the profile"))
    }
}

/// A deleted message waits 10 s as one small line, "Message deleted \u{00B7} Undo (7)"; it is sent to
/// the server when the count ends (ChatPendingDeletes). Undo brings the message back, nothing is sent.
struct ChatDeletedLine: View {
    let until: Date
    let mine: Bool
    let onUndo: () -> Void

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { ctx in
            let left = max(0, Int(ceil(until.timeIntervalSince(ctx.date))))
            HStack(spacing: 6) {
                if mine { Spacer(minLength: 0) }
                Image(systemName: "trash").font(.system(size: 10, weight: .semibold)).accessibilityHidden(true)
                Text("Message deleted").font(LiaFont.ui(12))
                if left > 0 {
                    Text("\u{00B7}").font(LiaFont.ui(12)).accessibilityHidden(true)
                    Button(action: onUndo) {
                        Text("Undo (\(left))").font(LiaFont.ui(12, .semibold)).foregroundStyle(WS.blue).monospacedDigit()
                            .padding(.horizontal, 5).frame(height: 20)
                    }
                    .buttonStyle(.liaPlain).liaHover(.icon, radius: 6)
                    .padding(.horizontal, -5)
                    .accessibilityLabel(Text("Undo delete, \(left) seconds left"))
                }
                if !mine { Spacer(minLength: 0) }
            }
            .foregroundStyle(WS.text3)
            .frame(height: 24)
            .padding(.leading, mine ? 0 : 38)
        }
        .transition(.opacity)
    }
}

/// The time inside a bubble, bottom right (iMessage/Telegram): small, the full date in the tip.
struct ChatBubbleTime: View {
    let ts: Double?
    var onDark = false
    var pinned = false
    var status: String? = nil

    var body: some View {
        if let ts {
            let d = Date(timeIntervalSince1970: ts / 1000)
            HStack(spacing: 3) {
                if pinned { Image(systemName: "pin.fill").font(.system(size: 8)) }
                Text(d, format: .dateTime.hour().minute())
                if let status { Image(systemName: status == "Sent" ? "checkmark" : "checkmark.circle").font(.system(size: 8, weight: .bold)) }
            }
            .font(LiaFont.ui(10.5))
            .foregroundStyle(onDark ? Color.white.opacity(0.72) : WS.text3)
            .monospacedDigit()
            .liaTip(d.formatted(date: .abbreviated, time: .shortened))
            .accessibilityHidden(true)
        }
    }
}

// MARK: - @mention

/// One agent in the @mention list: figure, full name, role; the highlighted one (keyboard) in our blue.
struct ChatMentionRow: View {
    let agent: AgentInfo
    let selected: Bool
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 9) {
                AgentAvatar(agent: agent, size: 26)
                VStack(alignment: .leading, spacing: 0) {
                    Text(agent.name).font(LiaFont.ui(13, .semibold)).foregroundStyle(WS.ink).lineLimit(1)
                    Text(agent.shownRole).font(LiaFont.ui(11.5)).foregroundStyle(WS.text2).lineLimit(1)
                }
                Spacer(minLength: 8)
                if agent.soon { Text("Soon").font(LiaFont.ui(11)).foregroundStyle(WS.text3) }
            }
            .padding(.horizontal, 8).frame(height: 40)
            .background(selected ? WS.blue.opacity(0.12) : (hover ? WS.hover : Color.clear),
                        in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.liaPlain)
        .onHover { hover = $0 }
        .liaPointer()
        .accessibilityLabel(Text("Mention \(agent.name), \(agent.shownRole)"))
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

// MARK: - pinned

/// The pinned message as one glass capsule floating at the top of the thread: pin, who, its first line. A click
/// scrolls to it; with several pins each click goes to the next older one (as in Telegram).
struct ChatPinnedStrip: View {
    let pinned: [TeamItem]
    let agentOf: (String?) -> AgentInfo?
    let onJump: (TeamItem) -> Void
    let onUnpin: (TeamItem) -> Void
    /// Index into `pinned` of the one shown (the newest first).
    @State private var shown: Int?
    /// The strip deepens under the pointer (it scrolls to the message).
    @State private var hoverJump = false

    private var index: Int { min(shown ?? pinned.count - 1, pinned.count - 1) }

    var body: some View {
        if pinned.indices.contains(index) {
            let p = pinned[index]
            HStack(spacing: 8) {
                Button { jump(p) } label: {
                    HStack(spacing: 7) {
                        Image(systemName: "pin.fill").font(.system(size: 10, weight: .semibold)).foregroundStyle(WS.blue)
                        Text(agentOf(p.agent)?.name ?? "You").font(LiaFont.ui(12, .semibold)).foregroundStyle(WS.blue)
                        Text(ChatQuote.firstLine(p, max: 90)).font(LiaFont.ui(12)).foregroundStyle(WS.ink).lineLimit(1)
                        if pinned.count > 1 {
                            Text("\(index + 1)/\(pinned.count)").font(LiaFont.ui(11)).foregroundStyle(WS.text3).monospacedDigit()
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.liaPlain).liaHover(.pointer, isHovered: $hoverJump)
                .accessibilityLabel(Text("Pinned. \(agentOf(p.agent)?.name ?? "You"): \(ChatQuote.firstLine(p))"))
                .accessibilityHint(Text("Scrolls to the message"))
                Button { onUnpin(p) } label: {
                    Image(systemName: "xmark").font(.system(size: 8.5, weight: .bold)).foregroundStyle(WS.text3)
                        .frame(width: 18, height: 18).contentShape(Rectangle())
                }
                .buttonStyle(.liaPlain).liaHover(.icon, radius: 9, tint: WS.text3)
                .accessibilityLabel(Text("Unpin"))
            }
            .padding(.leading, 12).padding(.trailing, 6).frame(height: 32)
            .background(WS.blue.opacity(hoverJump ? 0.13 : 0.07), in: Capsule())
            .wsGlass(16)
            .shadow(color: .black.opacity(0.08), radius: 10, y: 3)
            .frame(maxWidth: 400)
        }
    }

    private func jump(_ p: TeamItem) {
        onJump(p)
        guard pinned.count > 1 else { return }
        shown = index == 0 ? pinned.count - 1 : index - 1
    }
}

// MARK: - what the agent did

/// "What did <Agent> do?": the browser's own steps (AgentLog, this Mac, since launch) together with the tools the
/// agent used in this conversation (each answer's stored timeline), oldest first as the log sheet expects.
enum ChatAgentSteps {
    @MainActor
    static func entries(agent: String, items: [TeamItem], browser: [AgentLog.Entry]) -> [AgentLog.Entry] {
        var out = browser
        for it in items where it.agent == agent {
            guard let ts = it.message.ts, let tl = it.message.timeline else { continue }
            let at = Date(timeIntervalSince1970: ts / 1000)
            for ph in tl.phases {
                switch ph.kind {
                case .tools:
                    if ph.items.isEmpty {
                        out.append(AgentLog.Entry(at: at, event: "used_tools", text: ph.title))
                    } else {
                        for t in ph.items { out.append(AgentLog.Entry(at: at, event: "used_a_tool", text: t.label)) }
                    }
                case .web:
                    out.append(AgentLog.Entry(at: at, event: "searched_the_web", text: ph.query.isEmpty ? ph.title : ph.query))
                case .code:
                    out.append(AgentLog.Entry(at: at, event: "ran_code", text: ph.title))
                case .think:
                    continue
                }
            }
            if let g = it.message.gate {
                out.append(AgentLog.Entry(at: at, event: "prepared_a_change", text: g.title.isEmpty ? g.stepName : g.title))
            }
        }
        return out.sorted { $0.at < $1.at }.suffix(120).map { $0 }
    }
}

// MARK: - delivery status

enum ChatDelivery {
    /// Under the person's last message: "Sent", then "<Agent> is on it" while a run goes; nil once anyone answered.
    @MainActor
    static func status(_ chat: TeamChatModel, name: (String) -> String) -> String? {
        guard let last = chat.items.last, last.agent == nil, chat.errorText == nil else { return nil }
        if let a = chat.liveAgent { return "\(name(a)) is on it" }
        if let a = chat.webAgent { return "\(name(a)) is on it" }
        return "Sent"
    }
}

struct ChatDeliveryLabel: View {
    let text: String
    /// "<Agent> is on it" is just a checkmark (no circle, no words); the words stay for VoiceOver.
    var body: some View {
        HStack(spacing: 4) {
            Spacer()
            if text != "Sent" {
                Image(systemName: "checkmark").font(.system(size: 9, weight: .bold))
            } else {
                Text(text)
            }
        }
        .font(LiaFont.ui(10.5)).foregroundStyle(WS.text3)
        .padding(.trailing, 6).padding(.top, 1)
        .contentTransition(.opacity)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("Status: \(text)"))
    }
}

// MARK: - approvals

/// The rows of an approval's diff: label, old value struck through, the new one.
struct GateDiffList: View {
    let gate: Gate
    var limit = 6

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(gate.diff.prefix(limit).enumerated()), id: \.offset) { _, row in
                HStack(alignment: .firstTextBaseline) {
                    Text(row.label.isEmpty ? "Change" : row.label).font(LiaFont.ui(12.5)).foregroundStyle(WS.text2)
                    Spacer(minLength: 12)
                    if !row.old.isEmpty {
                        Text(row.old).font(LiaFont.mono(12)).foregroundStyle(WS.text3).strikethrough()
                        Text("\u{2192}").font(LiaFont.ui(12)).foregroundStyle(WS.text3)
                    }
                    Text(row.new).font(LiaFont.mono(12).weight(.semibold)).foregroundStyle(WS.ink)
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(Text(row.old.isEmpty ? "\(row.label): \(row.new)" : "\(row.label): from \(row.old) to \(row.new)"))
            }
            if gate.diff.count > limit {
                Text("+\(gate.diff.count - limit) more").font(LiaFont.ui(11.5)).foregroundStyle(WS.text3)
            }
        }
        .padding(10)
        .background(WS.soft, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

/// The new values of the diff as fields. "Send changes" writes to the agent what to change; the agent
/// makes a new plan (which asks again). Nothing edited here is ever applied by the app itself.
struct ChatGateEditor: View {
    let gate: Gate
    let who: String
    let onSend: (String) -> Void
    let onCancel: () -> Void
    @State private var values: [String] = []
    @FocusState private var focused: Int?

    /// "Change the plan: Daily budget: 40; Name: Autumn" from the rows whose value changed (nil: none changed).
    static func message(_ gate: Gate, values: [String]) -> String? {
        var parts: [String] = []
        for (i, row) in gate.diff.enumerated() where i < values.count {
            let v = values[i].trimmingCharacters(in: .whitespacesAndNewlines)
            if v != row.new.trimmingCharacters(in: .whitespacesAndNewlines) {
                parts.append("\(row.label.isEmpty ? "Change" : row.label): \(v.isEmpty ? "(empty)" : v)")
            }
        }
        return parts.isEmpty ? nil : "Change the plan: " + parts.joined(separator: "; ")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Edit the new values. \(who) makes a new plan and asks you again.")
                .font(LiaFont.ui(12)).foregroundStyle(WS.text2).fixedSize(horizontal: false, vertical: true)
            ForEach(Array(gate.diff.enumerated()), id: \.offset) { i, row in field(i, row) }
            HStack(spacing: 8) {
                Button("Send changes") { if let m = Self.message(gate, values: values) { onSend(m) } }
                    .buttonStyle(WSButtonStyle(primary: true, small: true))
                    .disabled(Self.message(gate, values: values) == nil)
                    .accessibilityHint(Text("Asks \(who) to change the plan"))
                Button("Cancel", action: onCancel).buttonStyle(WSButtonStyle(small: true))
                Spacer()
            }
        }
        .padding(10)
        .background(WS.soft, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .onAppear {
            if values.count != gate.diff.count { values = gate.diff.map(\.new) }
            focused = 0
        }
    }

    private func field(_ i: Int, _ row: GateDiffRow) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(row.label.isEmpty ? "Change" : row.label).font(LiaFont.ui(12.5)).foregroundStyle(WS.text2)
                .frame(width: 120, alignment: .leading).lineLimit(2)
            TextField(row.new, text: binding(i))
                .textFieldStyle(.plain)
                .font(LiaFont.mono(12))
                .focused($focused, equals: i)
                .padding(.horizontal, 8).frame(height: 26)
                .background(WS.surface, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).stroke(WS.line2, lineWidth: 1))
                .onExitCommand(perform: onCancel)
                .accessibilityLabel(Text("New \(row.label.isEmpty ? "value" : row.label)"))
                .accessibilityHint(Text(row.old.isEmpty ? "" : "Was \(row.old)"))
        }
    }

    private func binding(_ i: Int) -> Binding<String> {
        Binding(get: { i < values.count ? values[i] : (i < gate.diff.count ? gate.diff[i].new : "") },
                set: { v in
                    if values.count != gate.diff.count { values = gate.diff.map(\.new) }
                    if i < values.count { values[i] = v }
                })
    }
}

/// An approval after the decision: one line ("\u{2713} Approved by you \u{00b7} 10:42"); a click shows what it was.
struct ChatDecidedRow: View {
    let gate: Gate
    let decision: ChatDecisions.Decision?
    @State private var expanded = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var line: String {
        guard let d = decision else { return "Not answered" }
        let t = d.at.formatted(date: .omitted, time: .shortened)
        return d.approved ? "Approved by you \u{00b7} \(t)" : "Declined \u{00b7} \(t)"
    }
    private var approved: Bool { decision?.approved ?? false }
    /// The chip's whole text for its tip (the title is cut to one line in the chip).
    private var fullLine: String {
        let what: String = gate.title.isEmpty ? gate.stepName : gate.title
        return what.isEmpty ? line : line + " \u{00b7} " + what
    }
    /// No decision recorded on this Mac: a neutral mark, never a green check.
    private var symbol: String {
        guard let d = decision else { return "circle" }
        return d.approved ? "checkmark.circle.fill" : "xmark.circle"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button {
                if reduceMotion { expanded.toggle() } else { withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) { expanded.toggle() } }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: symbol)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(approved ? WS.blue : WS.text3)
                    Text(line).font(LiaFont.ui(12, .medium)).foregroundStyle(WS.text2).lineLimit(1).fixedSize()
                    if !gate.title.isEmpty || !gate.stepName.isEmpty {
                        Text("\u{00b7} " + (gate.title.isEmpty ? gate.stepName : gate.title))
                            .font(LiaFont.ui(12)).foregroundStyle(WS.text3).lineLimit(1)
                    }
                    Image(systemName: "chevron.down").font(.system(size: 8.5, weight: .bold)).foregroundStyle(WS.text3)
                        .rotationEffect(.degrees(expanded ? 180 : 0))
                }
                .padding(.horizontal, 10).frame(height: 26)
                .background(WS.soft, in: Capsule())
                .contentShape(Capsule())
            }
            .buttonStyle(.liaPlain).liaHoverWash(Capsule())
            .frame(maxWidth: 420, alignment: .leading)
            .help(fullLine)
            .accessibilityLabel(Text(line + (gate.title.isEmpty ? "" : ", " + gate.title)))
            .accessibilityValue(Text(expanded ? "expanded" : "collapsed"))
            .accessibilityHint(Text("Shows the change"))
            if expanded && !gate.diff.isEmpty {
                GateDiffList(gate: gate, limit: 12).frame(maxWidth: 380, alignment: .leading)
                    .transition(.opacity)
            }
        }
        .padding(.leading, 38)
        .padding(.top, 4)
    }
}

// MARK: - the message's menu

/// One right-click menu on a message wherever it is clicked - on its text too, where AppKit's text menu
/// used to show - Telegram-like: icons, Quote & Reply / Reply, Pin, Forward, Copy, the reactions, Save, Select,
/// Delete. With text selected in the message the first item is "Quote & Reply" and Reply, Forward and Copy take
/// only the selection. Drawn as SwiftUI menu content (`.contextMenu`) or as an NSMenu (a right-click on the text).
struct ChatMsgMenu {
    struct Entry {
        let title: String
        let symbol: String
        var destructive = false
        var children: [Entry] = []
        var action: () -> Void = {}
    }

    /// Groups, a separator between them.
    var sections: [[Entry]]

    /// The AppKit menu (the text views' right-click). Each item keeps its own target alive.
    func nsMenu() -> NSMenu {
        let m = NSMenu()
        m.autoenablesItems = false
        for (n, section) in sections.enumerated() where !section.isEmpty {
            if n > 0 && !m.items.isEmpty { m.addItem(.separator()) }
            for e in section { m.addItem(Self.item(e)) }
        }
        return m
    }

    private static func item(_ e: Entry) -> NSMenuItem {
        let it = NSMenuItem(title: e.title, action: nil, keyEquivalent: "")
        it.image = NSImage(systemSymbolName: e.symbol, accessibilityDescription: nil)
        it.isEnabled = true
        if e.children.isEmpty {
            let t = ChatMenuTarget(e.action)
            it.target = t
            it.action = #selector(ChatMenuTarget.fire)
            it.representedObject = t
        } else {
            let sub = NSMenu()
            sub.autoenablesItems = false
            for c in e.children { sub.addItem(item(c)) }
            it.submenu = sub
        }
        return it
    }
}

/// An NSMenuItem's closure.
final class ChatMenuTarget: NSObject {
    let run: () -> Void
    init(_ run: @escaping () -> Void) { self.run = run }
    @objc func fire() { run() }
}

/// The same menu as SwiftUI content, for `.contextMenu` (a right-click on the bubble around the text).
struct ChatMsgMenuContent: View {
    let menu: ChatMsgMenu

    var body: some View {
        ForEach(Array(menu.sections.enumerated()), id: \.offset) { n, section in
            if n > 0 && !section.isEmpty { Divider() }
            ForEach(Array(section.enumerated()), id: \.offset) { _, e in entry(e) }
        }
    }

    @ViewBuilder private func entry(_ e: ChatMsgMenu.Entry) -> some View {
        if e.children.isEmpty {
            Button(role: e.destructive ? ButtonRole.destructive : nil, action: e.action) {
                Label(e.title, systemImage: e.symbol).labelStyle(.titleAndIcon)
            }
        } else {
            Menu {
                ForEach(Array(e.children.enumerated()), id: \.offset) { _, c in
                    Button(action: c.action) { Label(c.title, systemImage: c.symbol).labelStyle(.titleAndIcon) }
                }
            } label: {
                Label(e.title, systemImage: e.symbol).labelStyle(.titleAndIcon)
            }
        }
    }
}

// MARK: - a task waiting its turn

/// ("if the mentioned agent is already working, the message goes into a queue and the person sees it
/// queued"): a task given this agent in another dialogue while it works. Read-only: the words are the asker's, and the
/// task starts by itself when the run in front of it ends.
struct ChatQueuedTaskRow: View {
    let task: AgentTask
    /// The dialogue it was asked in (its agent's name), nil when not known.
    let from: String?

    private var caption: String { from.map { "Queued \u{00B7} from \($0)'s dialogue" } ?? "Queued" }

    var body: some View {
        HStack(alignment: .center, spacing: 6) {
            Spacer(minLength: 70)
            Text(caption).font(LiaFont.ui(11, .medium)).foregroundStyle(WS.text3)
            Text(task.title).font(LiaFont.ui(14)).foregroundStyle(WS.ink).lineLimit(3).multilineTextAlignment(.leading)
                .padding(.horizontal, 14).padding(.vertical, 8)
                .background(WS.surface, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).stroke(WS.line2, style: StrokeStyle(lineWidth: 1, dash: [4, 3])))
                .opacity(0.85)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text(caption + ": " + task.title))
    }
}
