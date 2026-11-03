import SwiftUI
import AppKit
import Combine
import UniformTypeIdentifiers

/// The message box. An NSTextView underneath, because the box needs what a SwiftUI TextField cannot
/// give on the Mac: Return sends and Shift+Return breaks the line, a paste of a picture, a Finder file
/// or a long text becomes an attachment, and 1-3 answer Lia's question while the box is empty (the server).
struct ComposerTextView: NSViewRepresentable {
    @Binding var text: String
    @Binding var height: CGFloat
    var placeholder: String
    var focusTick: Int
    var onSubmit: () -> Void
    var onEscape: () -> Void
    /// A digit pressed in an empty box. Returns true when it answered something.
    var onDigit: (Int) -> Bool
    /// Unused (a pasted picture comes through `onPasteFiles` as bytes in memory); kept for callers.
    var onPasteImage: (Data, String) -> Void
    var onPasteLongText: (String) -> Void
    /// Files copied in Finder and pasted with ⌘V: attached like a drop.
    var onPasteFiles: ([URL]) -> Void = { _ in }
    /// Arrows, Return, Tab and Esc while the slash palette is open. Returns true when it took the key.
    enum Nav { case up, down, pick, close }
    var onNav: (Nav) -> Bool = { _ in false }
    /// The box's font size and its tallest height (it scrolls inside beyond that).
    var fontSize: CGFloat = 15
    var maxHeight: CGFloat = 200
    /// (0.2.11, the box lagged while typing): how long the typed words wait before they reach `text`
    /// (0: every keystroke). The owner's whole view is drawn again on each change of `text`; with a delay it is drawn
    /// when the typing pauses. They go at once when the box goes from empty to not (Send's state), while an @mention
    /// is typed, and before Return, a key the owner handles (`onNav`), Esc, or `flush.now` (the owner's Send button).
    var publishDelay: TimeInterval = 0
    var flush: ComposerFlush? = nil
    /// The last characters that are dictation's draft, not the server's words yet - drawn in a light
    /// shell (lighter words on a faint grey) until they are replaced; 0: none.
    var draftTail: Int = 0
    /// The "@..." at the caret (anywhere in the text), told whenever it changes (nil: none).
    var onMention: ((AgentMention.Spot?) -> Void)? = nil

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSTextView.scrollableTextView()
        scroll.drawsBackground = false
        // A long message scrolls inside the box (an overlay scroller, shown while scrolling).
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.scrollerStyle = .overlay
        // No inset of the window's own (a titlebar's) ever moves the line inside the box.
        scroll.automaticallyAdjustsContentInsets = false
        scroll.contentInsets = NSEdgeInsetsZero
        // (the box did not grow on a paste, stayed tall after a delete): TextKit 1 from the start, so
        // the layout manager the height is measured with is the one that lays the text out (a TextKit 2 view swapped
        // to TextKit 1 on the first `layoutManager` read, mid-life).
        let tv = BoxTextView(usingTextLayoutManager: false)
        tv.coordinator = context.coordinator
        tv.delegate = context.coordinator
        tv.isRichText = false
        tv.importsGraphics = false
        tv.allowsUndo = true
        tv.drawsBackground = false
        tv.font = NSFont(name: "Nunito", size: fontSize) ?? .systemFont(ofSize: fontSize)
        tv.textColor = NSColor(AppConfig.ink)   // Text, not the system label grey
        tv.textContainer?.lineFragmentPadding = 0
        tv.minSize = NSSize(width: 0, height: Coordinator.lineBox)
        tv.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        tv.isVerticallyResizable = true
        tv.isHorizontallyResizable = false
        tv.autoresizingMask = [.width]
        tv.textContainer?.widthTracksTextView = true
        // The container is as tall as the text needs: never the view's height (a container sized to the box cut the
        // layout at the box's edge, so a long paste measured no taller than the box already was).
        tv.textContainer?.heightTracksTextView = false
        tv.textContainer?.containerSize = NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude)
        tv.isAutomaticQuoteSubstitutionEnabled = false
        tv.isAutomaticDashSubstitutionEnabled = false
        scroll.documentView = tv
        context.coordinator.textView = tv
        context.coordinator.centreLine()
        DispatchQueue.main.async { tv.window?.makeFirstResponder(tv) }
        return scroll
    }

    static func dismantleNSView(_ scroll: NSScrollView, coordinator: Coordinator) {
        if coordinator.pending { coordinator.publishNow() }
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        let c = context.coordinator
        c.parent = self
        flush?.coordinator = c
        guard let tv = c.textView else { return }
        if tv.font?.pointSize != fontSize {
            tv.font = NSFont(name: "Nunito", size: fontSize) ?? .systemFont(ofSize: fontSize)
            c.centreLine()
            c.measure(fromUpdate: true)
        }
        // While typed words wait to be published, `text` is the older value, not text put in from outside.
        if tv.string != text, !(c.pending && text == c.published) {
            c.pending = false
            c.published = text
            tv.string = text
            // Text put in from outside (a draft, ↑, dictation, "Use"): the caret at its end, in view.
            tv.setSelectedRange(NSRange(location: (text as NSString).length, length: 0))
            tv.syncPlaceholder()
            c.measure(fromUpdate: true)
        }
        if c.draftTail != draftTail || c.draftPainted != tv.string {
            c.draftTail = draftTail
            c.draftPainted = tv.string
            Self.paintDraft(tv, tail: draftTail)
        }
        // (feedback: "it lags a lot"): the box is drawn again only when the placeholder's words change
        // (BoxTextView.placeholder); it used to be marked dirty on every SwiftUI update of the sheet.
        if tv.placeholder != placeholder { tv.placeholder = placeholder }
        // Whatever changed the words or the width, the box's height follows the layout (checked after this update;
        // nothing moves when it already matches).
        c.measure(fromUpdate: true, reveal: false)
        if context.coordinator.lastFocus != focusTick {
            context.coordinator.lastFocus = focusTick
            DispatchQueue.main.async { tv.window?.makeFirstResponder(tv) }
        }
    }

    /// The draft's shell: temporary attributes (never part of the text, gone on the next paint).
    static func paintDraft(_ tv: NSTextView, tail: Int) {
        guard let lm = tv.layoutManager else { return }
        let s = tv.string
        lm.removeTemporaryAttribute(.backgroundColor, forCharacterRange: NSRange(location: 0, length: (s as NSString).length))
        lm.removeTemporaryAttribute(.foregroundColor, forCharacterRange: NSRange(location: 0, length: (s as NSString).length))
        paintMentions(tv)
        guard tail > 0, tail <= s.count else { return }
        let r = NSRange(s.index(s.endIndex, offsetBy: -tail)..<s.endIndex, in: s)
        lm.addTemporaryAttributes([.backgroundColor: NSColor.labelColor.withAlphaComponent(0.07),
                                   .foregroundColor: NSColor.secondaryLabelColor], forCharacterRange: r)
    }

    /// Every "@Agent" in the box is the landing's pill - the name in the agent's colour on a rounded
    /// tint of it (drawn by BoxTextView under the text). Lia's near-black is the text's own colour.
    static func paintMentions(_ tv: NSTextView) {
        guard let lm = tv.layoutManager else { return }
        let hits = AgentChips.hits(tv.string).filter { $0.range.length > 0 && (tv.string as NSString).character(at: $0.range.location) == 0x40 }
        var pills: [(NSRange, NSColor)] = []
        for h in hits {
            let c = ChipSpec.agentInk(h.color)
            lm.addTemporaryAttribute(.foregroundColor, value: c, forCharacterRange: h.range)
            pills.append((h.range, c))
        }
        (tv as? BoxTextView)?.pills = pills
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        /// The draft shell last painted: its length and the words it was painted on.
        var draftTail = 0
        var draftPainted = ""
        var parent: ComposerTextView
        weak var textView: BoxTextView?
        var lastFocus = 0
        /// The value last handed to `text` (or put in from outside), and whether typed words wait to be handed over.
        var published = ""
        var pending = false
        private var publishGen = 0
        init(_ p: ComposerTextView) { parent = p; lastFocus = p.focusTick; published = p.text }

        /// The one-line box's height (ai.js autosize, desktop): the line is centred in it.
        static let lineBox: CGFloat = 28

        /// (the placeholder and the words sat off the box's middle): the top and bottom inset
        /// are half of what the box has beyond one line, so the line's centre is the 28 pt box's centre. The line's
        /// height is the one TextKit lays out with this font (ascender + descender + leading, as the typesetter rounds
        /// it), not a guess; halves are rounded down to 0.5 pt so one line never measures 29.
        func centreLine() {
            guard let tv = textView else { return }
            let line = Self.lineHeight(tv)
            let inset = max(0, ((Self.lineBox - line) / 2 * 2).rounded(.down) / 2)
            if abs(tv.textContainerInset.height - inset) > 0.01 {
                tv.textContainerInset = NSSize(width: 0, height: inset)
                tv.needsDisplay = true
            }
        }

        /// The height of one laid-out line in the box's font.
        static func lineHeight(_ tv: NSTextView) -> CGFloat {
            let font = tv.font ?? NSFont.systemFont(ofSize: 15)
            guard let lm = tv.layoutManager, let tc = tv.textContainer else { return ceil(font.ascender - font.descender + font.leading) }
            lm.ensureLayout(for: tc)
            if lm.numberOfGlyphs > 0 {
                let h = lm.lineFragmentRect(forGlyphAt: 0, effectiveRange: nil).height
                if h > 0 { return h }
            }
            let extra = lm.extraLineFragmentRect.height
            return extra > 0 ? extra : lm.defaultLineHeight(for: font)
        }

        func textDidChange(_ notification: Notification) {
            guard let tv = textView else { return }
            let now = tv.string
            // Measured here, in the text view, on this key: the box takes its new height in the same pass as the line.
            measure(fromUpdate: false)
            let spot = mentionSpot()
            if let tv = textView {
                // the pills follow every key (the draft shell, if any, is repainted with the next update)
                tv.layoutManager?.removeTemporaryAttribute(.foregroundColor, forCharacterRange: NSRange(location: 0, length: (tv.string as NSString).length))
                ComposerTextView.paintMentions(tv)
                if draftTail > 0 { ComposerTextView.paintDraft(tv, tail: draftTail) }
            }
            if parent.publishDelay <= 0 || now.isEmpty != published.isEmpty || spot != nil || lastSpot != nil
                || Self.mentioning(now) || Self.mentioning(published) {
                publishNow()
                reportMention(spot)
                return
            }
            reportMention(spot)
            pending = true
            publishGen &+= 1
            let gen = publishGen
            DispatchQueue.main.asyncAfter(deadline: .now() + parent.publishDelay) { [weak self] in
                guard let self, self.publishGen == gen else { return }
                self.publishNow()
            }
        }

        func textDidEndEditing(_ notification: Notification) { publishNow() }

        func textViewDidChangeSelection(_ notification: Notification) { reportMention(mentionSpot()) }

        /// The mention at the caret (no selection), as the owner's list needs it.
        func mentionSpot() -> AgentMention.Spot? {
            guard let tv = textView, tv.selectedRange().length == 0 else { return nil }
            return AgentMention.spot(tv.string, caret: tv.selectedRange().location)
        }

        var lastSpot: AgentMention.Spot?
        func reportMention(_ s: AgentMention.Spot?) {
            guard s != lastSpot else { return }
            lastSpot = s
            guard let f = parent.onMention else { return }
            // never while SwiftUI updates the view (a selection change can come from updateNSView)
            DispatchQueue.main.async { f(s) }
        }

        /// The owner picked an agent: "@Name " replaces the mention in the box itself (undo works, the caret after it).
        func complete(_ spot: AgentMention.Spot, name: String) {
            guard let tv = textView else { return }
            let ns = tv.string as NSString
            let end = NSMaxRange(spot.range)
            guard end <= ns.length else { return }
            let spaceNext = end < ns.length && (UnicodeScalar(ns.character(at: end)).map { CharacterSet.whitespacesAndNewlines.contains($0) } ?? false)
            tv.insertText("@" + name + (spaceNext ? "" : " "), replacementRange: spot.range)
            // a space already after it: the caret goes past it, ready for the next word
            if spaceNext { tv.setSelectedRange(NSRange(location: tv.selectedRange().location + 1, length: 0)) }
            publishNow()
            reportMention(mentionSpot())
        }

        /// The words typed so far go to `text` now.
        func publishNow() {
            publishGen &+= 1
            guard let tv = textView else { pending = false; return }
            let now = tv.string
            pending = false
            published = now
            if parent.text != now { parent.text = now }
        }

        /// An "@name" is being typed at the end (the owner's mention list follows every key).
        static func mentioning(_ s: String) -> Bool {
            guard let at = s.lastIndex(of: "@") else { return false }
            return !s[at...].contains(where: { $0 == " " || $0 == "\n" })
        }

        /// The caret stays in view (a Shift-Return at the bottom of a long message). While the text fits, the box
        /// shows it from its first line: nothing is scrolled (a scroll there, a frame before the box grew, threw the
        /// first line out of view and back - the jerk saw).
        func revealCaret(fits: Bool) {
            guard let tv = textView else { return }
            if fits { tv.scrollToTop(); return }
            tv.scrollRangeToVisible(tv.selectedRange())
            // Once the box has its new height (the step past the cap).
            DispatchQueue.main.async { [weak tv] in
                guard let tv else { return }
                tv.scrollRangeToVisible(tv.selectedRange())
            }
        }

        /// The whole text fits in the box at its tallest (it grows to show it all, so nothing needs a scroll).
        func contentFits() -> Bool {
            guard let tv = textView, let lm = tv.layoutManager, let tc = tv.textContainer else { return true }
            lm.ensureLayout(for: tc)
            return ceil(lm.usedRect(for: tc).height + tv.textContainerInset.height * 2) <= parent.maxHeight + 0.5
        }

        /// 28 px for one line, up to the cap (ai.js autosize, desktop); beyond it the box scrolls inside. A change of
        /// height (a line more or less) eases over 0.12 s; from inside a SwiftUI update it is handed over after it.
        /// (the box did not grow on a paste and stayed four lines tall after the text was
        /// deleted): the deferred path measures again when it runs - it used to carry the height taken during the
        /// update, which a later key or a send had made stale, and set that old height after the right one.
        func measure(fromUpdate: Bool, reveal: Bool = true) {
            if fromUpdate {
                DispatchQueue.main.async { [weak self] in self?.applyHeight(reveal: reveal) }
            } else {
                applyHeight(reveal: reveal)
            }
        }

        /// The box's height for the text as laid out now, and whether the whole text fits at the cap. Nil while the
        /// view has no width yet (measured at width 0 every word is a line: the box went to its tallest).
        func fittedHeight() -> (clamped: CGFloat, fits: Bool)? {
            guard let tv = textView, tv.bounds.width > 20, let lm = tv.layoutManager, let tc = tv.textContainer else { return nil }
            lm.ensureLayout(for: tc)
            let h = ceil(lm.usedRect(for: tc).height + tv.textContainerInset.height * 2)
            return (min(max(Self.lineBox, h), parent.maxHeight), h <= parent.maxHeight + 0.5)
        }

        private func applyHeight(reveal: Bool) {
            guard let m = fittedHeight() else { return }
            // The box changes only when the line count does.
            if abs(m.clamped - parent.height) > 0.5 {
                withAnimation(NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? nil : .easeOut(duration: 0.12)) {
                    parent.height = m.clamped
                }
            }
            if reveal { revealCaret(fits: m.fits) }
        }

        func textView(_ textView: NSTextView, doCommandBy sel: Selector) -> Bool {
            let nav: Nav? = sel == #selector(NSResponder.moveUp(_:)) ? .up : sel == #selector(NSResponder.moveDown(_:)) ? .down
                : (sel == #selector(NSResponder.insertTab(_:)) || (sel == #selector(NSResponder.insertNewline(_:)) && !NSEvent.modifierFlags.contains(.shift))) ? .pick
                : sel == #selector(NSResponder.cancelOperation(_:)) ? .close : nil
            // The owner reads `text` for these keys: the words typed so far go first.
            if nav != nil || sel == #selector(NSResponder.insertNewline(_:)) { publishNow() }
            if let nav, parent.onNav(nav) { return true }
            if sel == #selector(NSResponder.insertNewline(_:)) {
                if NSEvent.modifierFlags.contains(.shift) || NSEvent.modifierFlags.contains(.option) {
                    textView.insertNewlineIgnoringFieldEditor(nil); return true
                }
                parent.onSubmit(); return true
            }
            if sel == #selector(NSResponder.cancelOperation(_:)) { parent.onEscape(); return true }
            return false
        }
    }

    final class BoxTextView: NSTextView {
        weak var coordinator: Coordinator?
        /// Drawn while the box is empty; a new value redraws the box (nothing else does).
        var placeholder = "" {
            didSet { if placeholder != oldValue, string.isEmpty { needsDisplay = true } }
        }
        /// The "@Agent" pills' ranges and colours (ComposerTextView.paintMentions); drawn under the text.
        var pills: [(NSRange, NSColor)] = [] {
            didSet {
                let same = pills.count == oldValue.count && zip(pills, oldValue).allSatisfy { NSEqualRanges($0.0, $1.0) && $0.1 == $1.1 }
                if !same { needsDisplay = true }
            }
        }

        /// Under the text: called first by `draw` below.
        private func drawPills() {
            if !pills.isEmpty, let lm = layoutManager, let tc = textContainer {
                let len = (string as NSString).length
                for (r, c) in pills where NSMaxRange(r) <= len {
                    let g = lm.glyphRange(forCharacterRange: r, actualCharacterRange: nil)
                    lm.enumerateEnclosingRects(forGlyphRange: g, withinSelectedGlyphRange: NSRange(location: NSNotFound, length: 0),
                                               in: tc) { rr, _ in
                        let b = rr.offsetBy(dx: self.textContainerOrigin.x, dy: self.textContainerOrigin.y).insetBy(dx: -3, dy: 0)
                        c.withAlphaComponent(0.14).setFill()
                        NSBezierPath(roundedRect: b, xRadius: 6, yRadius: 6).fill()
                    }
                }
            }
        }

        // The pointer ("remove this line from the input, it lags a lot"): the I-beam is
        // NSTextView's own, from its cursor rects, and the caret is the system's insertion point. Nothing here runs on a
        // mouse move. An earlier version had added a `.mouseMoved` + `.cursorUpdate` tracking area, an I-beam set in
        // `cursorUpdate(with:)` and a hit test of the whole window on every move (`liaIsTopmost`); the I-beam it set
        // fought SwiftUI's own pointer update in the hosting view on every move, and the hit test ran the window's
        // SwiftUI hit testing per event - the lagging line. Under a modal of ours (the media library over the composer,
        // ) the rects are still taken back, when the modal opens and given back when it closes
        // (LiaModalCenter's stack, no mouse event at all), so the modal's buttons are not text.
        private var covered = false
        private var modalWatch: AnyCancellable?

        override func resetCursorRects() {
            guard !covered else { return }
            super.resetCursorRects()
        }

        private func setCovered(_ c: Bool) {
            guard c != covered else { return }
            covered = c
            window?.invalidateCursorRects(for: self)
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard window != nil else { modalWatch = nil; return }
            setCovered(LiaModalCenter.shared.isOpen)
            if modalWatch == nil {
                modalWatch = LiaModalCenter.shared.$stack
                    .map { !$0.isEmpty }
                    .removeDuplicates()
                    .receive(on: DispatchQueue.main)
                    .sink { [weak self] open in MainActor.assumeIsolated { self?.setCovered(open) } }
            }
        }

        /// The placeholder shows and hides with the first and the last character: the box is drawn again then only.
        override func didChangeText() {
            super.didChangeText()
            syncPlaceholder()
        }

        /// Text typed or put in from outside: a redraw only when the placeholder appears or goes.
        func syncPlaceholder() {
            let shown = string.isEmpty
            guard shown != placeholderShown else { return }
            placeholderShown = shown
            if !placeholder.isEmpty { needsDisplay = true }
        }
        private var placeholderShown = true

        /// (0.2.11, the box jerked as a line was added): AppKit scrolled to the caret on the key that
        /// made a new line, a frame before the box grew, so the first line went out of view and came back. While the
        /// whole text fits in the box at its tallest there is nothing to scroll to.
        override func scrollRangeToVisible(_ range: NSRange) {
            if coordinator?.contentFits() ?? false { scrollToTop(); return }
            super.scrollRangeToVisible(range)
        }

        /// A new width re-wraps the text: the height is measured again (the first real width comes after makeNSView).
        override func setFrameSize(_ newSize: NSSize) {
            let old = frame.width
            super.setFrameSize(newSize)
            if abs(newSize.width - old) > 0.5 { coordinator?.measure(fromUpdate: true, reveal: false) }
        }

        func scrollToTop() {
            guard let sv = enclosingScrollView else { return }
            let clip = sv.contentView
            guard clip.bounds.origin.y != 0 else { return }
            clip.scroll(to: .zero)
            sv.reflectScrolledClipView(clip)
        }

        override func keyDown(with event: NSEvent) {
            if string.isEmpty, event.modifierFlags.intersection([.command, .control, .option]).isEmpty,
               let c = event.charactersIgnoringModifiers, c.count == 1, let n = Int(c), n >= 1, n <= 9,
               coordinator?.parent.onDigit(n) == true { return }
            super.keyDown(with: event)
        }

        /// ⌘V with only a picture or a Finder file on the clipboard did nothing - a plain-text view
        /// enables Paste only for text. Paste is on whenever the clipboard holds something the box takes.
        override func validateUserInterfaceItem(_ item: NSValidatedUserInterfaceItem) -> Bool {
            if item.action == #selector(paste(_:)) {
                return isEditable && ClipboardPaste.canPaste(types: (NSPasteboard.general.types ?? []).map(\.rawValue))
            }
            return super.validateUserInterfaceItem(item)
        }

        /// ⌘V reaches `paste` even when the menu's own validation would not have let it through.
        override func performKeyEquivalent(with event: NSEvent) -> Bool {
            if window?.firstResponder === self, isEditable,
               event.modifierFlags.intersection(.deviceIndependentFlagsMask).subtracting([.capsLock, .numericPad, .function]) == .command,
               event.charactersIgnoringModifiers?.lowercased() == "v" {
                paste(nil)
                return true
            }
            return super.performKeyEquivalent(with: event)
        }

        /// Files copied in Finder and pictures become attachments (as a drop or the paperclip); text, formatted or
        /// not, goes in as plain words, a long one as a chip (ClipboardPaste has the order).
        override func paste(_ sender: Any?) {
            let pb = NSPasteboard.general
            switch ClipboardPaste.kind(types: (pb.types ?? []).map(\.rawValue)) {
            case .files:
                let urls = (pb.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]) ?? []
                if !urls.isEmpty { coordinator?.parent.onPasteFiles(urls); return }
                pastePlain(pb, sender)
            case .image(let type):
                // A pasted picture is never written to a file on this Mac - its bytes wait in memory
                // (ChatAttach.memoryURL) and go up like a dropped file.
                if let img = Self.image(pb, type: type) {
                    coordinator?.parent.onPasteFiles([ChatAttach.memoryURL(img.data, name: img.name)]); return
                }
                pastePlain(pb, sender)
            case .text:
                pastePlain(pb, sender)
            case .richText:
                if let s = Self.richString(pb), !s.isEmpty { insertPlain(s) }
            case .none:
                NSSound.beep()
            }
        }

        private func pastePlain(_ pb: NSPasteboard, _ sender: Any?) {
            if let s = pb.string(forType: .string), LongPaste.isLong(s) {
                coordinator?.parent.onPasteLongText(s); return
            }
            if pb.string(forType: .string) != nil { pasteAsPlainText(sender); return }
            if let s = Self.richString(pb), !s.isEmpty { insertPlain(s) }
        }

        private func insertPlain(_ s: String) {
            if LongPaste.isLong(s) { coordinator?.parent.onPasteLongText(s); return }
            insertText(s, replacementRange: selectedRange())
        }

        /// The picture's bytes: PNG, JPEG and GIF as they are; TIFF and HEIC (and anything else) as PNG.
        private static func image(_ pb: NSPasteboard, type: String) -> (data: Data, name: String)? {
            let t = NSPasteboard.PasteboardType(type)
            if ["public.png", "public.jpeg", "com.compuserve.gif"].contains(type), let d = pb.data(forType: t), !d.isEmpty {
                return (d, ClipboardPaste.imageName(type: type))
            }
            let img = pb.data(forType: t).flatMap { NSImage(data: $0) } ?? NSImage(pasteboard: pb)
            guard let tiff = img?.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
                  let png = rep.representation(using: .png, properties: [:]) else { return nil }
            return (png, ClipboardPaste.imageName(type: "public.png"))
        }

        /// The words of RTF / RTFD / HTML on the clipboard, without the formatting.
        private static func richString(_ pb: NSPasteboard) -> String? {
            if let d = pb.data(forType: .rtf), let a = NSAttributedString(rtf: d, documentAttributes: nil) { return a.string }
            if let d = pb.data(forType: .rtfd), let a = NSAttributedString(rtfd: d, documentAttributes: nil) { return a.string }
            if let d = pb.data(forType: .html), let a = NSAttributedString(html: d, documentAttributes: nil) {
                return a.string.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            return nil
        }

        /// The placeholder, where the caret of the empty box stands: the text container's origin plus the empty line's
        /// fragment (the same origin as the words), so it sits on the line the words will take.
        override func draw(_ dirtyRect: NSRect) {
            drawPills()
            super.draw(dirtyRect)
            guard string.isEmpty, !placeholder.isEmpty else { return }
            let f = font ?? NSFont.systemFont(ofSize: 15)
            let attrs: [NSAttributedString.Key: Any] = [.font: f,
                                                        .foregroundColor: NSColor(AppConfig.text3)]   // ai.js: placeholder is --text-3
            let o = textContainerOrigin
            var line = layoutManager?.extraLineFragmentRect ?? .zero
            if line.height <= 0 { line = NSRect(x: 0, y: 0, width: bounds.width, height: Coordinator.lineHeight(self)) }
            let r = NSRect(x: o.x + line.minX, y: o.y + line.minY, width: max(0, bounds.width - o.x - line.minX), height: line.height)
            guard r.intersects(dirtyRect) else { return }
            (placeholder as NSString).draw(with: r, options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine], attributes: attrs)
        }
    }
}

/// Hands the composer's typed words to its `text` now (ComposerTextView.publishDelay): the owner's Send button calls
/// it before reading `text`.
@MainActor
final class ComposerFlush {
    weak var coordinator: ComposerTextView.Coordinator?
    func now() { coordinator?.publishNow() }
    /// The picked agent goes in at the mention, wherever it is in the text.
    func complete(_ spot: AgentMention.Spot, name: String) -> Bool {
        guard let c = coordinator else { return false }
        c.complete(spot, name: name)
        return true
    }
}

/// Files dropped on the chat or picked with "Add files or photos": the read lane (ai.js composerRead).
enum ComposerFiles {
    @MainActor static func pick() -> [URL] {
        let p = NSOpenPanel()
        p.allowsMultipleSelection = true
        p.canChooseDirectories = false
        return p.runModal() == .OK ? Array(p.urls.prefix(6)) : []
    }

    static func load(_ url: URL) -> (name: String, mime: String, data: Data)? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        let type = UTType(filenameExtension: url.pathExtension)
        let mime = type?.preferredMIMEType ?? "application/octet-stream"
        return (url.lastPathComponent, mime, data)
    }
}
