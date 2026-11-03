import Foundation

/// The chat's name before the model's arrives (ai.js chatTitleFrom + _STOP): the first message's words without
/// filler, six at most, capitalised. The model's title (/intelligence/title) replaces it a moment later.
enum ChatTitle {
    static let stop: Set<String> = Set(("a an the of to in on for with and or my your me you please can could "
        + "what which who how why when where show tell give me about is are was were do does did "
        + "что какой какая какие как почему когда где кто покажи скажи дай мне про о об по за и или "
        + "мой моя мои моего лучший самый мне ты вы пожалуйста был была были это эта этот").split(separator: " ").map(String.init))

    static func from(_ text: String) -> String {
        let raw = text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        guard !raw.isEmpty else { return "" }
        let words = raw.split(separator: " ").map(String.init)
        let keep = words.filter { w in
            let bare = w.lowercased().unicodeScalars.filter { CharacterSet.letters.contains($0) || CharacterSet.decimalDigits.contains($0) }
            let s = String(String.UnicodeScalarView(bare))
            return s.count > 1 && !stop.contains(s)
        }
        var picked = (keep.isEmpty ? words : keep).prefix(6).joined(separator: " ")
        while let last = picked.last, ".,;:!?".contains(last) { picked.removeLast() }
        picked = picked.trimmingCharacters(in: .whitespaces)
        if picked.isEmpty { picked = String(raw.prefix(40)) }
        return picked.prefix(1).uppercased() + picked.dropFirst()
    }
}
