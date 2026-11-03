import Foundation

// What of an agent's work is worth the person's attention. One rule for the macOS notification, the
// dock figure's bounce and its red count, and the Inbox's total: a message in the agent's MAIN dialogue (its own; Lia's
// is "team") that is the end of a piece of work or needs the person (an approval card, a question, a final answer).
// Not: the person's own words, task cards, a task's first row (the hand-over), an agent's one-line acknowledgement in
// another agent's dialogue ("took it, working on it in my chat"), and Dev's intermediate messages of a running turn
// (its "on it" first message and the activity lines between).

enum AgentAttention {
    /// What the rule reads of one message (a DlgMessage or the app's TeamItem).
    struct Message: Equatable {
        /// nil: the person.
        var agent: String?
        var seq: Int = 0
        var hasGate = false
        /// A task card (role system with a task id) or a task's hand-over row.
        var isTask = false
        var handed = false
        /// An acknowledgement of a task worked in another dialogue (`origin.to_dlg`).
        var toDlg: String?
        /// A turn's messages carry its run; only the turn's final one (`fin`) ends the work.
        var run: String?
        var fin = false

        init(agent: String?, seq: Int = 0, hasGate: Bool = false, isTask: Bool = false, handed: Bool = false,
             toDlg: String? = nil, run: String? = nil, fin: Bool = false) {
            self.agent = agent; self.seq = seq; self.hasGate = hasGate; self.isTask = isTask; self.handed = handed
            self.toDlg = toDlg; self.run = run; self.fin = fin
        }

        init(_ m: DlgMessage) {
            let agent: String? = m.role == .user ? nil : (m.agent ?? "")
            self.init(agent: agent, seq: m.seq, hasGate: m.gateJSON != nil, isTask: m.isTaskCard || m.isHandedTask,
                      handed: m.isHandedTask, toDlg: m.origin?.toDlg, run: m.run, fin: m.fin)
        }
    }

    enum Kind: Equatable {
        /// An approval card: "needs your Yes".
        case approval
        /// A final answer or a question: the work is done, or the agent waits for the person's words.
        case message
    }

    /// Whether `m`, stored in dialogue `dlg`, is worth the person's attention, and why (nil: it is not).
    static func kind(_ m: Message, in dlg: String) -> Kind? {
        guard let agent = m.agent, !m.isTask, !m.handed else { return nil }
        // An agent with no name on the message: the dialogue's own.
        let who = agent.isEmpty ? DialogueSummary.agent(forDlg: dlg) : agent
        // Only the agent's own (main) dialogue; an acknowledgement elsewhere is not the work.
        guard DialogueSummary.dlg(forAgent: who) == dlg, m.toDlg == nil || m.toDlg == dlg else { return nil }
        if m.hasGate { return .approval }
        // A turn's first and intermediate messages ("on it", the activity) are not the end of the work.
        if m.run != nil && !m.fin { return nil }
        return .message
    }

    static func needs(_ m: Message, in dlg: String) -> Bool { kind(m, in: dlg) != nil }

    /// How many of `list` came after `seen` (the last seq the person saw) and are worth attention.
    static func count(_ list: [Message], in dlg: String, after seen: Int) -> Int {
        list.reduce(0) { $0 + ($1.seq > seen && needs($1, in: dlg) ? 1 : 0) }
    }
}

/// A click on an agent opens its messenger; a second click while it is still sliding in (a double click,
/// an impatient tap) used to close it mid-animation. A close by the same toggle waits until the open has settled.
enum DockToggle {
    /// The sheet's slide-in (WorkspaceWindow's spring, response 0.42) with a little margin.
    static let settle: TimeInterval = 0.5

    /// Whether a toggle on the open conversation's agent closes it now (false: still opening, the click is ignored).
    static func closes(openedAt: Date?, now: Date = Date(), settle: TimeInterval = DockToggle.settle) -> Bool {
        guard let t = openedAt else { return true }
        return now.timeIntervalSince(t) >= settle
    }

    /// The 0.5 s was not enough - while the thread was laid out the main thread was busy, the second
    /// click waited in the queue and was handled after the half second, so it closed the sheet. Times here are the
    /// clicks' own (NSEvent.timestamp, system uptime), not when they were handled: a click made before the opening
    /// slide is over, or before the first full frame of the thread (`settledAt`), does nothing. A sheet that never
    /// reports its frame closes again after `giveUp`.
    static let giveUp: TimeInterval = 4

    static func closes(click: TimeInterval, openedAt: TimeInterval?, settledAt: TimeInterval?, now: TimeInterval,
                       settle: TimeInterval = DockToggle.settle) -> Bool {
        guard let o = openedAt else { return true }
        if click < o + settle { return false }
        if let s = settledAt { return click >= s }
        return now - o >= giveUp
    }
}
