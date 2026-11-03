import Foundation

/// The agent's log ("logs everywhere, the animation too - on what principles the cursor works from
/// Decisions, how fast, what it costs"). Every beat, page load, lookup (with confidence), move, typing and miss, with
/// its time since the run began; sent in batches to /intelligence/agent-log, where the server adds each Decisions call
/// with its tokens and cost. Read back with GET /intelligence/agent-log?chat=<id>.
@MainActor
final class AgentLog {
    /// Set by the app: the chat and the call that posts a batch.
    var chatId: String?
    var send: @MainActor (String, [[String: Any]]) async -> Void = { _, _ in }

    private var buffer: [[String: Any]] = []

    /// The last steps of this browser's agent, kept in memory for "What did the agent do?" (newest last).
    struct Entry: Identifiable { let id = UUID(); let at: Date; let event: String; let text: String }
    private(set) var recent: [Entry] = []
    private static let readable: Set<String> = ["run_start", "web_action", "web_ask", "web_diff", "web_step_failed", "beat", "move", "type", "miss", "lookup", "run_end",
        "open", "fill", "draw", "walk", "ready", "result", "applied", "finish", "answer_yes", "answer_no", "stop_pressed"]
    private var started = Date()
    private var scheduled = false

    func begin(_ fields: [String: Any]) {
        started = Date()
        add("run_start", fields)
    }

    /// Milliseconds since the run began.
    var now: Int { Int(Date().timeIntervalSince(started) * 1000) }

    func add(_ event: String, _ fields: [String: Any] = [:]) {
        var e = fields
        e["ev"] = event
        e["t"] = now
        buffer.append(e)
        if Self.readable.contains(event) || event.hasPrefix("web_") {
            let text = (fields["actions"] as? String) ?? (fields["kind"] as? String) ?? (fields["diff"] as? String) ?? (fields["label"] as? String) ?? (fields["url"] as? String) ?? (fields["key"] as? String) ?? (fields["value"] as? String) ?? (fields["error"] as? String) ?? ""
            recent.append(Entry(at: Date(), event: event, text: String(text.prefix(240))))
            if recent.count > 80 { recent.removeFirst(recent.count - 80) }
        }
        if buffer.count >= 40 { flush() } else if !scheduled {
            scheduled = true
            Task { [weak self] in
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                self?.flush()
            }
        }
    }

    func flush() {
        scheduled = false
        guard let chat = chatId, !buffer.isEmpty else { return }
        let batch = buffer
        buffer = []
        let send = self.send
        Task { await send(chat, batch) }
    }
}
