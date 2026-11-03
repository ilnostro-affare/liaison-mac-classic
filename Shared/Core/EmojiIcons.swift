import Foundation

// "Dev wrote a green check - just how the model wrote it. Replace emoji in the interface so all emoji
// and icons models write have one style." The common emoji a model puts in its text are drawn as our own symbols
// (SF Symbols, at text size, in the semantic colours) when an agent's message is rendered. Only at render time: the
// stored text, Copy and the clipboard keep the emoji as written. Never inside `code` or a url; an emoji with no entry
// here stays as it is. Pure (Foundation only), tested on Linux; the view (AnswerText) turns an icon into pixels.

/// The colour family an icon is drawn in.
enum EmojiTone: String, Equatable {
    /// Green: done, passed, up.
    case success
    /// Orange: caution, heat.
    case warning
    /// Red: failed, down, stop.
    case error
    /// Our blue: pointers to something, ideas in motion.
    case accent
    /// Yellow: stars, ideas.
    case highlight
    /// The text's secondary colour: everything descriptive (a calendar, a link, a wrench).
    case neutral
}

/// One symbol: an SF Symbol name and its tone.
struct EmojiIcon: Equatable {
    let symbol: String
    let tone: EmojiTone
}

enum EmojiIcons {
    enum Piece: Equatable {
        case text(String)
        /// `original` is the emoji exactly as written (variation selector and skin tone included), for copy.
        case icon(EmojiIcon, original: String)
    }

    private static let vs16: UInt32 = 0xFE0F
    private static let vs15: UInt32 = 0xFE0E

    /// Keys are the emoji without variation selectors and skin tones.
    static let table: [String: EmojiIcon] = {
        func i(_ s: String, _ t: EmojiTone) -> EmojiIcon { EmojiIcon(symbol: s, tone: t) }
        return [
            // done / failed
            "\u{2705}": i("checkmark.circle.fill", .success),           // ✅
            "\u{2714}": i("checkmark", .success),                       // ✔️
            "\u{2611}": i("checkmark.square.fill", .success),           // ☑️
            "\u{274C}": i("xmark.circle.fill", .error),                 // ❌
            "\u{274E}": i("xmark.square.fill", .error),                 // ❎
            "\u{2716}": i("xmark", .error),                             // ✖️
            "\u{26A0}": i("exclamationmark.triangle.fill", .warning),   // ⚠️
            "\u{1F6D1}": i("xmark.octagon.fill", .error),               // 🛑
            "\u{1F6AB}": i("nosign", .error),                           // 🚫
            "\u{26D4}": i("minus.circle.fill", .error),                 // ⛔
            "\u{2753}": i("questionmark.circle.fill", .neutral),        // ❓
            "\u{2754}": i("questionmark.circle", .neutral),             // ❔
            "\u{2757}": i("exclamationmark.circle.fill", .error),       // ❗
            "\u{2755}": i("exclamationmark.circle", .neutral),          // ❕
            "\u{203C}": i("exclamationmark.2", .error),                 // ‼️
            "\u{2139}": i("info.circle.fill", .accent),                 // ℹ️
            // status dots
            "\u{1F7E2}": i("circle.fill", .success),                    // 🟢
            "\u{1F7E1}": i("circle.fill", .highlight),                  // 🟡
            "\u{1F7E0}": i("circle.fill", .warning),                    // 🟠
            "\u{1F534}": i("circle.fill", .error),                      // 🔴
            "\u{1F535}": i("circle.fill", .accent),                     // 🔵
            "\u{26AA}": i("circle", .neutral),                          // ⚪
            "\u{26AB}": i("circle.fill", .neutral),                     // ⚫
            // trends and money
            "\u{1F4C8}": i("chart.line.uptrend.xyaxis", .success),      // 📈
            "\u{1F4C9}": i("chart.line.downtrend.xyaxis", .error),      // 📉
            "\u{1F4CA}": i("chart.bar.fill", .accent),                  // 📊
            "\u{1F4B0}": i("dollarsign.circle.fill", .success),         // 💰
            "\u{1F4B5}": i("banknote.fill", .success),                  // 💵
            "\u{1F4B6}": i("eurosign.circle.fill", .success),           // 💶
            "\u{1F4B8}": i("banknote", .neutral),                       // 💸
            "\u{1F3C6}": i("trophy.fill", .highlight),                  // 🏆
            // ideas, energy, launch
            "\u{1F680}": i("paperplane.fill", .accent),                 // 🚀
            "\u{1F4A1}": i("lightbulb.fill", .highlight),               // 💡
            "\u{1F525}": i("flame.fill", .warning),                     // 🔥
            "\u{2B50}": i("star.fill", .highlight),                     // ⭐
            "\u{1F31F}": i("star.fill", .highlight),                    // 🌟
            "\u{2728}": i("sparkles", .accent),                         // ✨
            "\u{1F389}": i("party.popper.fill", .accent),               // 🎉
            "\u{1F38A}": i("party.popper.fill", .accent),               // 🎊
            "\u{26A1}": i("bolt.fill", .warning),                       // ⚡
            "\u{1F3AF}": i("target", .accent),                          // 🎯
            "\u{1F9E0}": i("brain", .neutral),                          // 🧠
            "\u{2764}": i("heart.fill", .error),                        // ❤️
            // pointers
            "\u{1F449}": i("hand.point.right.fill", .neutral),          // 👉
            "\u{1F448}": i("hand.point.left.fill", .neutral),           // 👈
            "\u{1F446}": i("hand.point.up.fill", .neutral),             // 👆
            "\u{1F447}": i("hand.point.down.fill", .neutral),           // 👇
            "\u{27A1}": i("arrow.right", .neutral),                     // ➡️
            "\u{2B05}": i("arrow.left", .neutral),                      // ⬅️
            "\u{2B06}": i("arrow.up", .neutral),                        // ⬆️
            "\u{2B07}": i("arrow.down", .neutral),                      // ⬇️
            "\u{2197}": i("arrow.up.right", .success),                  // ↗️
            "\u{2198}": i("arrow.down.right", .error),                  // ↘️
            "\u{1F504}": i("arrow.triangle.2.circlepath", .neutral),    // 🔄
            "\u{1F501}": i("repeat", .neutral),                         // 🔁
            "\u{2795}": i("plus", .neutral),                            // ➕
            "\u{2796}": i("minus", .neutral),                           // ➖
            // people and reactions
            "\u{1F44D}": i("hand.thumbsup.fill", .success),             // 👍
            "\u{1F44E}": i("hand.thumbsdown.fill", .error),             // 👎
            "\u{1F44B}": i("hand.wave.fill", .neutral),                 // 👋
            "\u{1F440}": i("eyes", .neutral),                           // 👀
            "\u{1F464}": i("person.fill", .neutral),                    // 👤
            "\u{1F465}": i("person.2.fill", .neutral),                  // 👥
            // things
            "\u{1F4CC}": i("pin.fill", .error),                         // 📌
            "\u{1F4CD}": i("mappin", .error),                           // 📍
            "\u{1F4DD}": i("square.and.pencil", .neutral),              // 📝
            "\u{270D}": i("pencil", .neutral),                          // ✍️
            "\u{270F}": i("pencil", .neutral),                          // ✏️
            "\u{1F6E0}": i("wrench.and.screwdriver.fill", .neutral),    // 🛠
            "\u{1F527}": i("wrench.fill", .neutral),                    // 🔧
            "\u{1F528}": i("hammer.fill", .neutral),                    // 🔨
            "\u{2699}": i("gearshape.fill", .neutral),                  // ⚙️
            "\u{1F9EA}": i("testtube.2", .neutral),                     // 🧪
            "\u{1F41B}": i("ladybug.fill", .error),                     // 🐛
            "\u{1F9E9}": i("puzzlepiece.fill", .neutral),               // 🧩
            "\u{1F4E6}": i("shippingbox.fill", .neutral),               // 📦
            "\u{23F1}": i("stopwatch.fill", .neutral),                  // ⏱
            "\u{23F0}": i("alarm.fill", .neutral),                      // ⏰
            "\u{23F3}": i("hourglass", .neutral),                       // ⏳
            "\u{231B}": i("hourglass", .neutral),                       // ⌛
            "\u{1F552}": i("clock", .neutral),                          // 🕒
            "\u{1F4C5}": i("calendar", .neutral),                       // 📅
            "\u{1F4C6}": i("calendar", .neutral),                       // 📆
            "\u{1F5D3}": i("calendar", .neutral),                       // 🗓
            "\u{1F517}": i("link", .neutral),                           // 🔗
            "\u{1F4CE}": i("paperclip", .neutral),                      // 📎
            "\u{1F50D}": i("magnifyingglass", .neutral),                // 🔍
            "\u{1F50E}": i("magnifyingglass", .neutral),                // 🔎
            "\u{1F4AC}": i("bubble.left.fill", .neutral),               // 💬
            "\u{1F4E7}": i("envelope.fill", .neutral),                  // 📧
            "\u{2709}": i("envelope.fill", .neutral),                   // ✉️
            "\u{1F4E3}": i("megaphone.fill", .neutral),                 // 📣
            "\u{1F4E2}": i("megaphone.fill", .neutral),                 // 📢
            "\u{1F514}": i("bell.fill", .neutral),                      // 🔔
            "\u{1F512}": i("lock.fill", .neutral),                      // 🔒
            "\u{1F513}": i("lock.open.fill", .neutral),                 // 🔓
            "\u{1F511}": i("key.fill", .neutral),                       // 🔑
            "\u{1F310}": i("globe", .neutral),                          // 🌐
            "\u{1F4F1}": i("iphone", .neutral),                         // 📱
            "\u{1F4BB}": i("laptopcomputer", .neutral),                 // 💻
            "\u{1F4C4}": i("doc.text", .neutral),                       // 📄
            "\u{1F4C1}": i("folder.fill", .neutral),                    // 📁
            "\u{1F4C2}": i("folder", .neutral),                         // 📂
            "\u{1F5C2}": i("folder", .neutral),                         // 🗂
            "\u{1F4CB}": i("doc.on.clipboard", .neutral),               // 📋
            "\u{1F3A8}": i("paintpalette.fill", .neutral),              // 🎨
            "\u{1F5BC}": i("photo", .neutral),                          // 🖼
            "\u{1F4F7}": i("camera.fill", .neutral),                    // 📷
            "\u{1F4F8}": i("camera.fill", .neutral),                    // 📸
            "\u{1F3AC}": i("film", .neutral),                           // 🎬
            "\u{1F3A5}": i("video.fill", .neutral),                     // 🎥
            "\u{1F4DE}": i("phone.fill", .neutral),                     // 📞
            "\u{1F6D2}": i("cart.fill", .neutral),                      // 🛒
            "\u{1F3C1}": i("flag.checkered", .neutral),                 // 🏁
            "\u{1F6A9}": i("flag.fill", .error),                        // 🚩
        ]
    }()

    /// Characters whose plain form is ordinary text (an arrow, "i", "!!"): drawn as an icon only when the writer asked
    /// for the emoji form with U+FE0F.
    static let needsEmojiSelector: Set<String> = ["\u{27A1}", "\u{2B05}", "\u{2B06}", "\u{2B07}", "\u{2197}", "\u{2198}",
                                                   "\u{2139}", "\u{203C}", "\u{2709}", "\u{270F}", "\u{2764}"]

    /// The icon for one written character (a grapheme: base + U+FE0F / skin tone), nil when it stays as written.
    /// U+FE0E (text presentation) is the writer asking for text: never replaced.
    static func icon(for c: Character) -> EmojiIcon? {
        var key = String.UnicodeScalarView()
        var hasVS16 = false
        for u in c.unicodeScalars {
            switch u.value {
            case vs15: return nil
            case vs16: hasVS16 = true
            case 0x1F3FB...0x1F3FF: continue   // skin tones
            default: key.append(u)
            }
        }
        let k = String(key)
        guard let icon = table[k] else { return nil }
        if needsEmojiSelector.contains(k) && !hasVS16 { return nil }
        return icon
    }

    /// The text as text and icons. `code` spans (between backticks) and urls (http(s)://..., www....) pass untouched.
    static func pieces(_ s: String) -> [Piece] {
        // Fast path: nothing at or above U+2000 can be an entry.
        guard s.unicodeScalars.contains(where: { $0.value >= 0x2000 }) else { return s.isEmpty ? [] : [.text(s)] }
        var out: [Piece] = []
        var buf = ""
        func flush() { if !buf.isEmpty { out.append(.text(buf)); buf = "" } }
        let chars = Array(s)
        var i = 0
        while i < chars.count {
            let c = chars[i]
            // `code`: up to the closing backtick (a lone backtick is just a character).
            if c == "`", let close = chars[(i + 1)...].firstIndex(of: "`") {
                buf.append(contentsOf: String(chars[i...close]))
                i = close + 1
                continue
            }
            if let end = urlEnd(chars, at: i) {
                buf.append(contentsOf: String(chars[i..<end]))
                i = end
                continue
            }
            if let icon = icon(for: c) {
                flush()
                out.append(.icon(icon, original: String(c)))
            } else {
                buf.append(c)
            }
            i += 1
        }
        flush()
        return out
    }

    /// Where a url starting at `i` ends (exclusive), nil when none starts there. A url starts after a non-letter and
    /// runs to whitespace or `<>"'`.
    private static func urlEnd(_ chars: [Character], at i: Int) -> Int? {
        let c = chars[i]
        guard c == "h" || c == "H" || c == "w" || c == "W" else { return nil }
        if i > 0, chars[i - 1].isLetter || chars[i - 1].isNumber { return nil }
        func has(_ p: String) -> Bool {
            let p = Array(p)
            guard i + p.count <= chars.count else { return false }
            for k in 0..<p.count where chars[i + k].lowercased() != String(p[k]) { return false }
            return true
        }
        guard has("https://") || has("http://") || has("www.") else { return nil }
        var j = i
        while j < chars.count {
            let d = chars[j]
            if d.isWhitespace || d == "<" || d == ">" || d == "\"" || d == "'" { break }
            j += 1
        }
        return j
    }
}
