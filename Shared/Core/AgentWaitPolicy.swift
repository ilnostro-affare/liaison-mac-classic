import Foundation

/// (incident): what the end of a turn does to a change the overlay holds for the person's Yes / No.
/// Met stopped on a copy's gate; one second later another task of Met's ran in the same dialogue and its end wrote
/// "Not answered" for the copy (the old rule: any later turn's end while the overlay waits expires it). In an agent's
/// dialogue a later turn is not always the person's: a task, a teammate's hand-over. The wait now ends only when the
/// card is really answered (Yes / No reach `answered`), replaced (a new change begins, or the chat says the card is no
/// longer open), or stopped.
enum AgentWaitPolicy {
    enum OnEnd: Equatable {
        /// nothing waits: the end is an ordinary turn end
        case none
        /// the change still waits for its answer: the overlay and its history row stay
        case keep
        /// the card is gone without an answer: "Not answered", the overlay clears
        case expire
    }

    /// Waiting: the overlay is idle with a change ready for the answer
    /// GateOpen: the chat's own answer to "is this agent's card still open?" (nil: not wired / not known)
    /// OwnChat: the overlay is one chat's own browser (a web chat: a later turn there always follows the person's
    /// own message, which replaces the card); false for an agent's browser ("agent-<id>"), shared by every turn of
    /// that agent's dialogue
    static func onEnd(waiting: Bool, gateOpen: Bool?, ownChat: Bool) -> OnEnd {
        guard waiting else { return .none }
        if let open = gateOpen { return open ? .keep : .expire }
        return ownChat ? .expire : .keep
    }

    /// A new change begins while the last one still waits for its answer (its run finished and its history row says
    /// "waiting"): that one was replaced, never answered.
    static func supersedes(waiting: Bool, hasHistoryRow: Bool) -> Bool { waiting && hasHistoryRow }

    /// The browser of an agent's dialogue (WorkspaceModel.agentBrowser: chat "agent-<id>").
    static func isAgentBrowser(chatID: String?) -> Bool { chatID?.hasPrefix("agent-") ?? false }
}
