import SwiftUI
import AppKit

// Small pieces of the workspace messenger (ConversationSheet): day separators, the approval's risk
// , error cards (/03), queued messages, starter prompts
// And VoiceOver announcements (A11Y-06).

// MARK: - errors

/// What kind of failure an agent's error text describes, in plain words for the card.
enum ChatError: Equatable {
    case busy, signIn, network, other

    /// Reads the server's or the transport's text. Busy/limits retry by themselves.
    static func kind(of text: String) -> ChatError {
        let t = text.lowercased()
        if ["429", "503", "502", "overloaded", "rate limit", "too many requests", "usage limit", "temporarily unavailable", "capacity"]
            .contains(where: { t.contains($0) }) { return .busy }
        if ["session", "sign in", "sign-in", "signed out", "log in", "login", "logged out", "expired", "unauthorized", "401"]
            .contains(where: { t.contains($0) }) { return .signIn }
        if ["offline", "connection", "network", "timed out", "internet"].contains(where: { t.contains($0) }) { return .network }
        return .other
    }

    /// The card's headline: what failed, no jargon (the raw text goes under Details).
    static func headline(_ text: String, agent: String, retryIn: Int?) -> String {
        switch kind(of: text) {
        case .busy:
            if let s = retryIn { return "The agents are busy. Trying again in \(s) s" }
            return "The agents are busy right now."
        case .signIn: return "\(agent) could not get in: the sign-in has expired."
        case .network: return "\(agent) lost the connection."
        case .other: return "\(agent) could not finish this."
        }
    }
}

/// An agent's error as a card: what failed, Details with Copy, and what to do next.
struct ChatErrorCard: View {
    let text: String
    let agent: AgentInfo?
    var retryIn: Int? = nil
    var onRetry: (() -> Void)? = nil
    var onOpenBrowser: (() -> Void)? = nil
    @State private var details = false
    @State private var copied = false

    private var name: String { agent?.name ?? "The agent" }
    private var kind: ChatError { ChatError.kind(of: text) }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: kind == .busy ? "hourglass" : "exclamationmark.triangle.fill")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(kind == .busy ? WS.amberInk : WS.bad)
                    .frame(width: 18, height: 18)
                Text(ChatError.headline(text, agent: name, retryIn: retryIn))
                    .font(LiaFont.ui(13, .semibold)).foregroundStyle(WS.ink)
                    .fixedSize(horizontal: false, vertical: true)
                    .contentTransition(.numericText())
                Spacer(minLength: 0)
            }
            HStack(spacing: 8) {
                if let onRetry {
                    Button(retryIn == nil ? "Try Again" : "Try Now", action: onRetry).buttonStyle(ChatCapsuleButtonStyle()).liaHoverWash(Capsule())
                }
                if kind == .signIn, let onOpenBrowser {
                    Button("Open \(name)'s Browser", action: onOpenBrowser).buttonStyle(ChatCapsuleButtonStyle(primary: false)).liaHoverWash(Capsule())
                }
                Button {
                    withAnimation(.easeOut(duration: 0.2)) { details.toggle() }
                } label: {
                    HStack(spacing: 4) {
                        Text("Details")
                        Image(systemName: "chevron.down").font(.system(size: 9, weight: .bold)).rotationEffect(.degrees(details ? 180 : 0))
                    }
                    .font(LiaFont.ui(12.5))
                }
                .buttonStyle(.liaPlain).liaHover(.text, tint: WS.text2)
                Spacer(minLength: 0)
            }
            if details {
                HStack(alignment: .top, spacing: 8) {
                    Text(verbatim: text).font(LiaFont.mono(11.5)).foregroundStyle(WS.text2).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Button {
                        Clipboard.copy(text)
                        copied = true
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) { copied = false }
                    } label: {
                        Text(copied ? "Copied" : "Copy").font(LiaFont.ui(11.5, .medium)).foregroundStyle(WS.ink)
                            .padding(.horizontal, 8).frame(height: 22)
                            .background(WS.surface, in: Capsule()).overlay(Capsule().stroke(WS.line2, lineWidth: 1))
                    }
                    .buttonStyle(.liaPlain).liaHoverWash(Capsule())
                }
                .padding(10)
                .background(WS.soft, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .transition(.opacity)
            }
        }
        // The workspace's in-chat card (14, hairline, soft shadow); amber edge while busy.
        .chatCard()
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(kind == .busy ? WS.amberLine : Color.clear, lineWidth: 1))
        .padding(.leading, 38)
        .padding(.top, 6)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text("Error. " + ChatError.headline(text, agent: name, retryIn: retryIn)))
    }
}

// MARK: - day separators

enum ChatDay {
    /// "Today", "Yesterday" or the date, when `ts` (ms) starts a new day after `prev` (ms); nil inside a day.
    static func label(_ ts: Double?, after prev: Double?, now: Date = Date()) -> String? {
        guard let ts else { return nil }
        let d = Date(timeIntervalSince1970: ts / 1000)
        let cal = Calendar.current
        if let prev, cal.isDate(Date(timeIntervalSince1970: prev / 1000), inSameDayAs: d) { return nil }
        if cal.isDateInToday(d) { return "Today" }
        if cal.isDateInYesterday(d) { return "Yesterday" }
        if cal.component(.year, from: d) == cal.component(.year, from: now) {
            return d.formatted(.dateTime.weekday(.wide).month(.wide).day())
        }
        return d.formatted(.dateTime.month(.wide).day().year())
    }
}

struct ChatDaySeparator: View {
    let label: String
    var body: some View {
        HStack(spacing: 10) {
            Rectangle().fill(WS.line).frame(height: 1)
            Text(label).font(LiaFont.ui(11.5, .medium)).foregroundStyle(WS.text3).fixedSize()
            Rectangle().fill(WS.line).frame(height: 1)
        }
        .padding(.vertical, 10)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(label))
        .accessibilityAddTraits(.isHeader)
    }
}

// MARK: - approvals

/// How much an approval can cost the person.
enum GateRisk: Equatable {
    /// Reads only.
    case read
    /// A draft or a change that spends nothing more (created paused, a name, a lower budget, an undo).
    case draft
    /// Spends money: turning on, publishing, activating, or raising a budget/bid. Shown red on the change; answered
    /// like any other, by a click on Yes (no hold).
    case spend

    /// The one place that maps a Gate to its risk, from its tool name, `final` (turns it on) and diff rows.
    /// Red: final, an activate/publish/boost tool, a status going to active, a budget or bid going up (or set on an
    /// existing object). Blue (read only): get_/list_/read_/find_ tools. Everything else: amber.
    static func of(_ g: Gate) -> GateRisk {
        let tool = g.tool.lowercased()
        if ["get_", "list_", "read_", "find_"].contains(where: { tool.hasPrefix($0) }) { return .read }
        if g.final { return .spend }
        if ["activate", "publish", "boost", "turn_on", "resume", "launch"].contains(where: { tool.contains($0) }) { return .spend }
        for row in g.diff {
            let label = row.label.lowercased()
            let new = row.new.lowercased().trimmingCharacters(in: .whitespaces)
            if label.contains("status") || label.contains("delivery") {
                if ["active", "on", "enabled", "published", "running", "live"].contains(new) { return .spend }
            }
            if ["budget", "bid", "spend cap", "cost cap"].contains(where: { label.contains($0) }) {
                if let n = number(row.new) {
                    if let o = number(row.old) { if n > o { return .spend } }
                    else if !(row.old.trimmingCharacters(in: .whitespaces).isEmpty && tool.hasPrefix("create_")) { return .spend }
                } else if !(row.old.trimmingCharacters(in: .whitespaces).isEmpty && tool.hasPrefix("create_")) {
                    // The new value is not a number ("No limit", "Unlimited", "\u{2014}", empty): a cap removed or unknown.
                    return .spend
                }
            }
        }
        return .draft
    }

    /// "€1,200.50" -> 1200.5, "50,00 €" -> 50.0, "€1.200" -> 1200, "12.50" -> 12.5.
    static func number(_ s: String) -> Double? {
        var t = s.filter { $0.isNumber || $0 == "." || $0 == "," }
        if let c = t.lastIndex(of: ","), let d = t.lastIndex(of: ".") {
            // Both: the last one is the decimal mark ("1,200.50", "1.200,50").
            if c > d { t.removeAll { $0 == "." }; t = t.replacingOccurrences(of: ",", with: ".") } else { t.removeAll { $0 == "," } }
        } else if t.contains(",") {
            // "1,200" / "12,500,000": thousands; "50,00": a decimal comma.
            let groups = t.split(separator: ",", omittingEmptySubsequences: false)
            if groups.count > 2 || groups.last?.count == 3 { t.removeAll { $0 == "," } } else { t = t.replacingOccurrences(of: ",", with: ".") }
        } else if t.contains(".") {
            // "1.200" / "12.500.000": thousands (every group after the first has 3 digits); "1.5" / "12.50": decimal.
            let groups = t.split(separator: ".", omittingEmptySubsequences: false)
            let first = groups.first?.count ?? 0
            if groups.count > 1 && first >= 1 && first <= 3 && groups.first != "0" && groups.dropFirst().allSatisfy({ $0.count == 3 }) { t.removeAll { $0 == "." } }
        }
        return Double(t)
    }

    var color: Color {
        switch self {
        case .read: return WS.blue
        case .draft: return WS.amber
        case .spend: return WS.red
        }
    }
    var soft: Color {
        switch self {
        case .read: return Color.dyn(dark: (0x5B78FF, 0.16), light: (0xE8EDFF, 1))
        case .draft: return WS.amberSoft
        case .spend: return Color.dyn(dark: (0xFF6369, 0.16), light: (0xFDE8E8, 1))
        }
    }
    var ink: Color {
        switch self {
        case .read: return WS.blue
        case .draft: return WS.amberInk
        case .spend: return Color.dyn(0xFF8A8E, 0xB42318)
        }
    }
    var label: String {
        switch self {
        case .read: return "Read only"
        case .draft: return "No spend"
        case .spend: return "Spends money"
        }
    }
    var symbol: String {
        switch self {
        case .read: return "eye"
        case .draft: return "pencil"
        case .spend: return "creditcard"
        }
    }
}

// MARK: - queued messages

/// A message waiting for the running answer to finish: a click puts it back in the field, \u{00d7} drops it.
struct ChatQueuedBubble: View {
    let text: String
    let onEdit: () -> Void
    let onRemove: () -> Void
    @State private var hover = false

    var body: some View {
        HStack(alignment: .center, spacing: 6) {
            Spacer(minLength: 70)
            Text("Queued").font(LiaFont.ui(11, .medium)).foregroundStyle(WS.text3)
            HStack(alignment: .top, spacing: 8) {
                Text(text).font(LiaFont.ui(14)).foregroundStyle(WS.ink).lineLimit(4).multilineTextAlignment(.leading)
                Button(action: onRemove) {
                    Image(systemName: "xmark").font(.system(size: 9, weight: .bold)).foregroundStyle(WS.text2)
                        .frame(width: 18, height: 18).background(WS.soft, in: Circle())
                }
                .buttonStyle(.liaPlain).liaHoverWash(Circle())
                .accessibilityLabel(Text("Remove queued message"))
            }
            .padding(.leading, 14).padding(.trailing, 8).padding(.vertical, 8)
            .background(WS.surface, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).stroke(WS.line2, style: StrokeStyle(lineWidth: 1, dash: [4, 3])))
            .opacity(hover ? 1 : 0.85)
            .contentShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            .onTapGesture(perform: onEdit)
            .onHover { hover = $0 }
            .liaPointer()
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text("Queued: \(text)"))
        .accessibilityAction(named: Text("Edit"), onEdit)
    }
}

// MARK: - starter prompts

enum ChatStarters {
    struct Starter: Hashable { let text: String; var disabled = false }

    /// 3-4 prompts that fit the dialogue's agent (the team's for Team).
    static func list(for dlg: String) -> [Starter] {
        switch dlg {
        case "met": return ["Write 5 headlines for our best ad", "Why did CPL rise yesterday?", "Which campaigns spend the most this week?", "Which ads should we pause?"].map { Starter(text: $0) }
        case "rep": return ["Yesterday's report", "Weekly summary for the client", "Compare this month with last month"].map { Starter(text: $0) }
        case "seara": return ["What are competitors running?", "Research this audience", "Trends in our niche this month"].map { Starter(text: $0) }
        case "crea": return ["Ideas for 3 new creatives", "Rewrite this ad for Instagram", "What makes our best creative work?"].map { Starter(text: $0) }
        case "dev": return ["Make a landing page for my business", "Add a contact form to the site", "Show me the site"].map { Starter(text: $0) }
        case "giggs": return [Starter(text: "Google Ads is coming soon", disabled: true)]
        default: return team
        }
    }

    /// Lia does research and reports herself now (Seara and Rep are retired).
    private static let team: [Starter] = [
        "How did we do this week?",
        "Yesterday's report",
        "What are competitors running?",
        "@Crea ideas for 3 new creatives",
    ].map { Starter(text: $0) }
}

struct ChatStarterButton: View {
    let starter: ChatStarters.Starter
    let action: () -> Void
    @State private var hover = false
    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Text(starter.text).font(LiaFont.ui(13)).foregroundStyle(starter.disabled ? WS.text3 : WS.ink).multilineTextAlignment(.leading)
                Spacer(minLength: 6)
                if !starter.disabled {
                    Image(systemName: "arrow.up").font(.system(size: 10, weight: .bold)).foregroundStyle(WS.text2).opacity(hover ? 1 : 0.5)
                }
            }
            .padding(.horizontal, 12).padding(.vertical, 9)
            .background(hover && !starter.disabled ? WS.soft : WS.surface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(WS.line2, lineWidth: 1))
            .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(.liaPlain)
        .disabled(starter.disabled)
        .onHover { h in withAnimation(.easeOut(duration: 0.2)) { hover = h } }
        .liaPointer()
        .accessibilityHint(Text(starter.disabled ? "Not available yet" : "Sends this message"))
    }
}

// MARK: - VoiceOver (A11Y-06)

@MainActor
enum ChatA11y {
    private static var said: Set<String> = []

    /// Says `text` now, over whatever VoiceOver was reading (an approval waiting, a new message). With `once`, a
    /// key (an approval's plan id) is said only the first time, however often its card reappears while scrolling.
    static func announce(_ text: String, once key: String? = nil) {
        if let key { guard said.insert(key).inserted else { return } }
        let element: Any
        if let w = NSApp.mainWindow { element = w } else { element = NSApp as Any }
        NSAccessibility.post(element: element, notification: .announcementRequested,
                             userInfo: [.announcement: text, .priority: NSAccessibilityPriorityLevel.high.rawValue])
    }
}

/// Where the bottom of the thread is inside the scroll view (no view there: scrolled far away).
struct ChatBottomKey: PreferenceKey {
    static var defaultValue: CGFloat = .greatestFiniteMagnitude
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = min(value, nextValue()) }
}

// MARK: - task cards and forgetting facts

/// A hand-over in the dialogue that started it: "Seara took this · working · Open". Open goes to the owner's
/// dialogue at the task's first message.
struct ChatTaskCard: View {
    let item: TeamItem
    let task: AgentTask?
    let agent: AgentInfo?
    let onOpen: (AgentTask) -> Void

    private var name: String { agent?.name ?? (item.agent.map { DlgOrigin.displayName($0) } ?? "An agent") }
    private var title: String {
        let t = task?.title ?? ""
        return t.isEmpty ? FeedText.plain(item.message.content) : t
    }
    private var status: String {
        switch task?.status {
        case .waiting: return "waiting for you"
        case .done: return "done"
        case .failed: return "stopped"
        case .working, .none: return "working"
        }
    }
    private var statusColor: Color {
        switch task?.status {
        case .waiting: return WS.amberInk
        case .failed: return WS.red
        case .done: return WS.text3
        case .working, .none: return WS.blue
        }
    }
    /// The task to open: the server's, else one made from the card (its owner and id are enough to find it).
    private var openTask: AgentTask? {
        if let task { return task }
        guard let id = item.taskId, let owner = item.agent else { return nil }
        return AgentTask(id: id, owner: owner, title: title)
    }

    var body: some View {
        HStack(spacing: 10) {
            if let agent { AgentAvatar(agent: agent, size: 24, status: task?.status == .working ? .working : .idle) }
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 5) {
                    Text("\(name) took this").font(LiaFont.ui(12.5, .semibold)).foregroundStyle(WS.ink)
                    Text("\u{00b7}").foregroundStyle(WS.text3)
                    Text(status).font(LiaFont.ui(12)).foregroundStyle(statusColor)
                }
                if !title.isEmpty {
                    Text(title).font(LiaFont.ui(12)).foregroundStyle(WS.text2).lineLimit(1)
                }
            }
            Spacer(minLength: 6)
            if let t = openTask {
                Button("Open") { onOpen(t) }
                    .buttonStyle(WSButtonStyle(small: true))
                    .liaHoverWash(RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 9)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(WS.line, lineWidth: 1))
        .frame(maxWidth: 380, alignment: .leading)
        .frame(maxWidth: .infinity, alignment: .center)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text("\(name) took this task: \(title). \(status)"))
    }
}

/// Facts Lia saved from a deleted message (the server keeps them until the person decides).
struct ChatForgetFacts: Identifiable {
    struct Fact: Identifiable { let id: String; let text: String }
    let id = UUID()
    let facts: [Fact]
}

/// "Also forget what Lia learned from it?" with the facts listed: Forget deletes them from memory, Keep leaves them.
struct ChatForgetFactsSheet: View {
    let facts: ChatForgetFacts
    let auth: AuthStore
    /// How many were forgotten (0: kept).
    let onDone: (Int) -> Void
    @State private var busy = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Also forget what Lia learned from it?").font(LiaFont.ui(16, .semibold)).foregroundStyle(WS.ink)
            VStack(alignment: .leading, spacing: 6) {
                ForEach(facts.facts) { f in
                    HStack(alignment: .top, spacing: 8) {
                        Circle().fill(WS.text3).frame(width: 4, height: 4).padding(.top, 7)
                        Text(f.text).font(LiaFont.ui(13)).foregroundStyle(WS.text2).fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            HStack(spacing: 8) {
                Spacer()
                Button("Keep") { onDone(0) }.buttonStyle(WSButtonStyle()).disabled(busy)
                Button("Forget") { forget() }.buttonStyle(WSButtonStyle(primary: true)).disabled(busy)
            }
        }
        .padding(22)
        .frame(width: 400)
    }

    private func forget() {
        busy = true
        let api = LiaAPI(auth: auth)
        let ids = facts.facts.map(\.id)
        Task { @MainActor in
            var n = 0
            for id in ids {
                if let r = try? await api.memoryOp(["op": "delete", "id": id]), r["ok"] as? Bool == true { n += 1 }
            }
            busy = false
            onDone(n)
        }
    }
}
