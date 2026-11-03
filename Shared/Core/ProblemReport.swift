import Foundation

// "Report a problem" is our own form, not Mail. POST /agents/report (lia-agents):
// {text, context: {...}, logs: [...], screenshot_b64?} -> {ok, id}. The server keeps it in R2 under the member,
// caps every context value at 2,000 characters, the logs at 400 lines of 600, the screenshot (PNG) at 4,000,000
// base64 characters. These are the pure pieces: what is attached and the body.

struct ProblemReport: Equatable {
    var text: String
    /// What the app saw, in order (shown to the person before sending, sent as `context`).
    var context: [(key: String, value: String)]
    var logs: [String]
    var screenshotB64: String?

    static func == (a: ProblemReport, b: ProblemReport) -> Bool {
        a.text == b.text && a.context.map(\.key) == b.context.map(\.key) && a.context.map(\.value) == b.context.map(\.value)
            && a.logs == b.logs && a.screenshotB64 == b.screenshotB64
    }

    static let maxLogs = 200
    static let maxValue = 2000
    static let maxLine = 600
    static let maxScreenshot = 4_000_000

    /// Something to send: words, or at least the logs.
    var canSend: Bool { !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    /// The JSON body; empty context values are left out, everything capped as the server caps it.
    func body() -> [String: Any] {
        var ctx: [String: String] = [:]
        for (k, v) in context where !v.isEmpty { ctx[k] = ProblemReport.cap(v, Self.maxValue) }
        var b: [String: Any] = ["text": text.trimmingCharacters(in: .whitespacesAndNewlines), "context": ctx,
                                "logs": Self.tail(logs)]
        if let s = screenshotB64, !s.isEmpty, s.count <= Self.maxScreenshot { b["screenshot_b64"] = s }
        return b
    }

    /// The last `n` non-empty lines, each capped.
    static func tail(_ lines: [String], _ n: Int = maxLogs) -> [String] {
        let kept = lines.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        return kept.suffix(n).map { cap($0, maxLine) }
    }

    static func cap(_ s: String, _ n: Int) -> String {
        s.count > n ? String(s.prefix(n - 1)) + "\u{2026}" : s
    }

    /// "12:04:31 [WebKit] message" for one log line.
    static func line(at: Date, source: String, _ message: String) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "HH:mm:ss"
        let one = message.replacingOccurrences(of: "\n", with: " ")
        return f.string(from: at) + (source.isEmpty ? " " : " [\(source)] ") + one
    }

    /// The dialogue in front, newest last: "You: …" / "Met: …", each line capped, at most `n`.
    static func dialogue(_ lines: [(who: String, text: String)], _ n: Int = 12) -> String {
        lines.suffix(n).map { $0.who + ": " + cap($0.text.replacingOccurrences(of: "\n", with: " "), 300) }.joined(separator: "\n")
    }
}
