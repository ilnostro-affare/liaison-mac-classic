import XCTest
import Foundation
@testable import Liaison

/// The model's emoji drawn as our symbols (Shared/Core/EmojiIcons.swift), a paste into the message
/// box (ClipboardPaste.swift) and Lia's role in the interface (AgentInfo.shownRole).
final class EmojiIconsTests: XCTestCase {
    private func icons(_ p: [EmojiIcons.Piece]) -> [String] {
        p.compactMap { if case .icon(let i, _) = $0 { return i.symbol }; return nil }
    }

    private func joined(_ p: [EmojiIcons.Piece]) -> String {
        p.map { piece -> String in
            switch piece {
            case .text(let t): return t
            case .icon(_, let o): return o
            }
        }.joined()
    }

    func testCommonEmojiBecomeIconsAndTextStays() {
        let s = "Deployed \u{2705} and tests pass \u{1F680}. Next: \u{26A0}\u{FE0F} check budget"
        let p = EmojiIcons.pieces(s)
        XCTAssertEqual(icons(p), ["checkmark.circle.fill", "paperplane.fill", "exclamationmark.triangle.fill"])
        XCTAssertEqual(p.first, .text("Deployed "))
        // Copy and the stored text get exactly what the model wrote.
        XCTAssertEqual(joined(p), s)
        XCTAssertEqual(EmojiIcons.icon(for: "\u{2705}")?.tone, .success)
        XCTAssertEqual(EmojiIcons.icon(for: "\u{274C}")?.tone, .error)
        XCTAssertEqual(EmojiIcons.icon(for: "\u{26A0}\u{FE0F}")?.tone, .warning)
    }

    func testVariationSelectorsAndSkinTones() {
        // ✔️ with and without U+FE0F; 👍🏽 with a skin tone; U+FE0E asks for text and is left alone.
        XCTAssertEqual(EmojiIcons.icon(for: "\u{2714}\u{FE0F}")?.symbol, "checkmark")
        XCTAssertEqual(EmojiIcons.icon(for: "\u{2714}")?.symbol, "checkmark")
        XCTAssertEqual(EmojiIcons.icon(for: "\u{1F44D}\u{1F3FD}")?.symbol, "hand.thumbsup.fill")
        XCTAssertNil(EmojiIcons.icon(for: "\u{26A0}\u{FE0E}"))
        // An arrow is text unless written as the emoji.
        XCTAssertNil(EmojiIcons.icon(for: "\u{27A1}"))
        XCTAssertEqual(EmojiIcons.icon(for: "\u{27A1}\u{FE0F}")?.symbol, "arrow.right")
        let s = "Good \u{1F44D}\u{1F3FD}!"
        let p = EmojiIcons.pieces(s)
        XCTAssertEqual(p, [.text("Good "), .icon(EmojiIcon(symbol: "hand.thumbsup.fill", tone: .success), original: "\u{1F44D}\u{1F3FD}"), .text("!")])
        XCTAssertEqual(joined(p), s)
    }

    func testUnmappedAndSequencesStay() {
        // 🦄 has no entry; 👨‍💻 is a ZWJ sequence (one character), not 👨 + 💻; a keycap stays.
        for s in ["\u{1F984} unicorn", "\u{1F468}\u{200D}\u{1F4BB} coder", "1\u{FE0F}\u{20E3} first", "plain ascii", ""] {
            let p = EmojiIcons.pieces(s)
            XCTAssertTrue(icons(p).isEmpty, s)
            XCTAssertEqual(joined(p), s)
        }
        XCTAssertEqual(EmojiIcons.pieces(""), [])
    }

    func testCodeSpansAndUrlsUntouched() {
        let s = "Run `echo \u{2705}` then \u{2705} see https://x.com/\u{1F680}?a=\u{2705} and www.site.it/\u{1F525} done \u{1F525}"
        let p = EmojiIcons.pieces(s)
        XCTAssertEqual(icons(p), ["checkmark.circle.fill", "flame.fill"])
        XCTAssertEqual(joined(p), s)
        XCTAssertTrue(p.contains(.text("Run `echo \u{2705}` then ")))
        // A lone backtick does not swallow the rest; "show" is not a url start.
        let q = EmojiIcons.pieces("a ` b \u{2705} show\u{1F4C8}")
        XCTAssertEqual(icons(q), ["checkmark.circle.fill", "chart.line.uptrend.xyaxis"])
    }

    func testEveryEntryRoundTrips() {
        for (k, icon) in EmojiIcons.table {
            let written = EmojiIcons.needsEmojiSelector.contains(k) ? k + "\u{FE0F}" : k
            XCTAssertEqual(EmojiIcons.icon(for: Character(written)), icon, k)
            XCTAssertFalse(icon.symbol.isEmpty)
        }
        XCTAssertTrue(EmojiIcons.needsEmojiSelector.isSubset(of: Set(EmojiIcons.table.keys)))
    }

    // MARK: paste

    func testPasteKinds() {
        // Finder: a file url (with its name as text and its icon as TIFF) is the file.
        XCTAssertEqual(ClipboardPaste.kind(types: ["public.file-url", "public.utf8-plain-text", "public.tiff"]), .files)
        // A screenshot (⌘⌃⇧4): the PNG.
        XCTAssertEqual(ClipboardPaste.kind(types: ["public.png", "public.tiff"]), .image("public.png"))
        XCTAssertEqual(ClipboardPaste.kind(types: ["public.tiff"]), .image("public.tiff"))
        XCTAssertEqual(ClipboardPaste.kind(types: ["public.heic"]), .image("public.heic"))
        // Text with formatting and a picture of it (Excel, Word): the words.
        XCTAssertEqual(ClipboardPaste.kind(types: ["public.utf8-plain-text", "public.html", "public.rtf", "public.tiff"]), .text)
        XCTAssertEqual(ClipboardPaste.kind(types: ["public.utf8-plain-text"]), .text)
        XCTAssertEqual(ClipboardPaste.kind(types: ["public.html"]), .richText)
        XCTAssertEqual(ClipboardPaste.kind(types: ["com.apple.flat-rtfd"]), .richText)
        XCTAssertEqual(ClipboardPaste.kind(types: ["dyn.ah62d4rv4gu8y"]), .none)
        XCTAssertFalse(ClipboardPaste.canPaste(types: []))
        XCTAssertTrue(ClipboardPaste.canPaste(types: ["public.png"]))
    }

    func testPastedImageName() {
        var c = DateComponents()
        c.year = 2026; c.month = 10; c.day = 19; c.hour = 14; c.minute = 5; c.second = 9
        let d = Calendar.current.date(from: c)!
        XCTAssertEqual(ClipboardPaste.imageName(type: "public.png", at: d), "Pasted image 2026-10-19 at 14.05.09.png")
        XCTAssertEqual(ClipboardPaste.imageName(type: "public.jpeg", at: d), "Pasted image 2026-10-19 at 14.05.09.jpg")
        XCTAssertEqual(ClipboardPaste.imageName(type: "public.tiff", at: d), "Pasted image 2026-10-19 at 14.05.09.png")
        XCTAssertEqual(ClipboardPaste.imageName(type: "public.heic", at: d), "Pasted image 2026-10-19 at 14.05.09.png")
    }

    // MARK: roles

    func testShownRole() {
        let lia = AgentInfo.lookup("lia", in: [])!
        XCTAssertEqual(lia.role, "Lead")
        XCTAssertEqual(lia.shownRole, "Assistant")
        XCTAssertEqual(AgentInfo.lookup("met", in: [])?.shownRole, "Marketer")
        XCTAssertEqual(AgentInfo.lookup("dev", in: [])?.shownRole, "Developer")
        XCTAssertEqual(AgentInfo.lookup("crea", in: [])?.shownRole, "Creative")
        // A roster that ships Lia as "Leads the team" still reads "Assistant".
        let fromServer = AgentInfo(id: "lia", name: "Lia", role: "Leads the team", shape: .ring, colorHex: 0, lead: true)
        XCTAssertEqual(fromServer.shownRole, "Assistant")
    }
}
