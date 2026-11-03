import Foundation

/// Items 14-15: the very short line the menu bar item and the notch island show for an agent at work
/// ("Dev · pushing", "Crea · drawing 2/4", "Lia · reading the account"), made from the long status the conversation
/// already writes ("Reading the account…", "Working in the browser…"). Pure, so it is tested on Linux.
enum AgentActivity {
    /// Steps of a counted job (a copy of N ads, N drafts): "2/4".
    struct Steps: Equatable {
        let done: Int
        let total: Int
        init(done: Int, total: Int) { self.done = done; self.total = total }
        /// nil when there is nothing to count.
        var text: String? { total > 0 ? "\(max(0, min(done, total)))/\(total)" : nil }
    }

    static let dot = " \u{00b7} "
    private static let ellipsis: Set<Character> = ["\u{2026}", ".", ":", ";", "!", " "]
    /// Words a cut line must not end on ("reading the" -> "reading").
    private static let weak: Set<String> = ["the", "a", "an", "to", "of", "in", "on", "for", "and", "with", "at", "from", "by", "into", "your", "its", "is"]

    /// The step in a few lowercase words: "Reading the account…" -> "reading the account"; "Dev is pushing to main"
    /// > "pushing to main"; a long line is cut on a word and ends with "…". Empty -> "working".
    static func step(_ text: String, name: String = "", maxLength: Int = 24) -> String {
        var s = text.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespaces)
        // the first clause only: "Drawing · draft 2" / "Pushing - main" / "Reading (3 tabs)"
        for sep in [" \u{00b7} ", " - ", " \u{2014} ", " \u{2013} ", ": ", " (", ", "] {
            if let r = s.range(of: sep), r.lowerBound > s.startIndex { s = String(s[s.startIndex..<r.lowerBound]) }
        }
        while let last = s.last, ellipsis.contains(last) { s.removeLast() }
        if !name.isEmpty {
            for p in [name + " is ", name + " "] where s.lowercased().hasPrefix(p.lowercased()) && s.count > p.count {
                s = String(s.dropFirst(p.count)); break
            }
        }
        s = s.trimmingCharacters(in: .whitespaces)
        guard !s.isEmpty else { return "working" }
        var words = s.split(separator: " ").map(String.init)
        // "Reading" -> "reading"; "GitHub", "URL", "Meta" stay as they are (a name, not a verb)
        if let w = words.first, isPlainCapitalised(w) { words[0] = w.lowercased() }
        let full = words.joined(separator: " ")
        if full.count <= maxLength { return full }
        var out: [String] = []
        for w in words {
            let next = (out + [w]).joined(separator: " ")
            if next.count > maxLength - 1 { break }
            out.append(w)
        }
        while out.count > 1, let l = out.last, weak.contains(l.lowercased()) { out.removeLast() }
        if out.isEmpty { return String(full.prefix(max(1, maxLength - 1))) + "\u{2026}" }
        return out.joined(separator: " ") + "\u{2026}"
    }

    /// "Reading" yes; "GitHub", "URL", "I" (a single letter), "3D" no.
    private static func isPlainCapitalised(_ w: String) -> Bool {
        guard let f = w.first, f.isUppercase, w.count > 1 else { return false }
        return w.dropFirst().allSatisfy { $0.isLowercase || !$0.isLetter } && w.dropFirst().contains { $0.isLetter }
    }

    /// The menu bar's line: "Crea · drawing 2/4", "Met · working in the browser 40%", "Lia · reading the account".
    /// Steps win over a fraction; a fraction shows only between 1 and 99 %.
    static func label(name: String, text: String, progress: Double? = nil, steps: Steps? = nil, maxLength: Int = 24) -> String {
        var line = name + dot + step(text, name: name, maxLength: maxLength)
        if let s = steps?.text { line += " " + s }
        else if let p = progress, p > 0.005, p < 0.995 { line += " \(Int((p * 100).rounded()))%" }
        return line
    }

    /// How long a run has gone: "8s", "2m 05s", "14m", "1h 05m".
    static func elapsed(_ seconds: Double) -> String {
        let s = max(0, Int(seconds.rounded(.down)))
        if s < 60 { return "\(s)s" }
        let m = s / 60
        if m < 10 { return "\(m)m " + pad(s % 60) + "s" }
        if m < 60 { return "\(m)m" }
        return "\(m / 60)h " + pad(m % 60) + "m"
    }

    /// How long ago a run finished: "just now", "3m ago", "2h ago".
    static func ago(_ seconds: Double) -> String {
        let s = max(0, Int(seconds))
        if s < 45 { return "just now" }
        if s < 3600 { return "\(max(1, (s + 30) / 60))m ago" }
        return "\(s / 3600)h ago"
    }

    private static func pad(_ n: Int) -> String { n < 10 ? "0\(n)" : "\(n)" }

    /// Which of `count` running agents the menu bar shows at `now` (seconds): each one for `every` seconds in turn.
    static func pick(count: Int, now: Double, every: Double = 3) -> Int {
        guard count > 1, every > 0 else { return 0 }
        let n = Int((max(0, now) / every).rounded(.down))
        return n % count
    }

    /// The ids that were running and are not any more (a run that finished or was stopped), in their old order.
    static func finished(before: [String], after: [String]) -> [String] {
        let now = Set(after)
        return before.filter { !now.contains($0) }
    }

    /// The finished list, newest first, without repeats and at most `limit` long.
    static func remember<T>(_ new: [T], into list: [T], limit: Int = 4, id: (T) -> String) -> [T] {
        var seen = Set<String>(), out: [T] = []
        for x in new + list where !seen.contains(id(x)) {
            seen.insert(id(x)); out.append(x)
            if out.count == limit { break }
        }
        return out
    }
}
