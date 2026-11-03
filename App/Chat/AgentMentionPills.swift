import SwiftUI
import AppKit

// "@Agent" is the message box's pill wherever an agent can be called with "@": the name in the
// agent's colour (ChipSpec.agentInk: Lia's near-black is the text's own colour) on a tint of it. Temporary attributes
// only, never part of the text (what is typed, saved and sent stays plain).

enum AgentMentionPaint {
    /// Paints `tv`'s "@Name" mentions and returns them (range, colour) for a view that draws the rounded tint itself.
    /// `squareTint`: the text system's own background (a field editor, which draws nothing of ours).
    @discardableResult
    static func paint(_ tv: NSTextView, squareTint: Bool = false) -> [(NSRange, NSColor)] {
        let len = (tv.string as NSString).length
        var out: [(NSRange, NSColor)] = []
        var runs: [(NSRange, [NSAttributedString.Key: Any])] = []
        for h in AgentChips.mentions(tv.string) where NSMaxRange(h.range) <= len {
            let c = ChipSpec.agentInk(h.color)
            var attrs: [NSAttributedString.Key: Any] = [.foregroundColor: c]
            if squareTint { attrs[.backgroundColor] = c.withAlphaComponent(0.14) }
            runs.append((h.range, attrs))
            out.append((h.range, c))
        }
        apply(tv, clear: squareTint ? [.foregroundColor, .backgroundColor] : [.foregroundColor], runs: runs)
        return out
    }

    /// Takes the paint off (a field editor goes on to another field).
    static func clear(_ tv: NSTextView) {
        apply(tv, clear: [.foregroundColor, .backgroundColor], runs: [])
    }

    /// TextKit 2 (a field editor may be one): rendering attributes, so its layout manager is never asked for (asking
    /// turns a TextKit 2 view into TextKit 1 for good). TextKit 1: the layout manager's temporary attributes.
    private static func apply(_ tv: NSTextView, clear keys: [NSAttributedString.Key], runs: [(NSRange, [NSAttributedString.Key: Any])]) {
        if let tlm = tv.textLayoutManager {
            guard let tcm = tlm.textContentManager else { return }
            for k in keys { tlm.removeRenderingAttribute(k, for: tlm.documentRange) }
            for (r, attrs) in runs {
                guard let s = tcm.location(tcm.documentRange.location, offsetBy: r.location),
                      let e = tcm.location(s, offsetBy: r.length),
                      let tr = NSTextRange(location: s, end: e) else { continue }
                for (k, v) in attrs { tlm.addRenderingAttribute(k, value: v, for: tr) }
            }
            return
        }
        guard let lm = tv.layoutManager else { return }
        let all = NSRange(location: 0, length: (tv.string as NSString).length)
        for k in keys { lm.removeTemporaryAttribute(k, forCharacterRange: all) }
        for (r, attrs) in runs { lm.addTemporaryAttributes(attrs, forCharacterRange: r) }
    }
}

/// For a SwiftUI TextField (the address bar, Home's prompt): put it in the field's `.background`. While the field is
/// being edited its text is the window's field editor (AppKit's shared NSTextView), which this paints; the field
/// editor takes no draw override of ours, so the tint is the layout manager's square background, not the box's
/// rounded one. Not editing, the field draws its own plain text.
struct AgentMentionFieldPaint: NSViewRepresentable {
    let text: String
    /// The field's focus: a change repaints (focusing does not change the text).
    var focused = false

    func makeNSView(context: Context) -> ProbeView { ProbeView() }

    func updateNSView(_ v: ProbeView, context: Context) {
        // after the TextField has handed its text to the field editor in this same update
        DispatchQueue.main.async { [weak v] in v?.paint() }
    }

    static func dismantleNSView(_ v: ProbeView, coordinator: ()) { v.stop() }

    final class ProbeView: NSView {
        private weak var painted: NSTextView?
        private var watch: NSObjectProtocol?

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        /// The field editor while it edits the field this view sits behind (its field's frame over this one).
        private var editor: NSTextView? {
            guard let w = window, let tv = w.firstResponder as? NSTextView, tv.isFieldEditor,
                  let field = tv.delegate as? NSView, field.window === w else { return nil }
            let mine = convert(bounds, to: nil)
            let theirs = field.convert(field.bounds, to: nil)
            return mine.intersects(theirs) ? tv : nil
        }

        func paint() {
            guard let tv = editor else { return }
            if painted !== tv {
                stop()
                painted = tv
                // the editing ends: the shared field editor leaves with nothing of ours on it
                watch = NotificationCenter.default.addObserver(forName: NSText.didEndEditingNotification, object: tv,
                                                               queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.stop() }
                }
            }
            AgentMentionPaint.paint(tv, squareTint: true)
        }

        func stop() {
            if let w = watch { NotificationCenter.default.removeObserver(w) }
            watch = nil
            if let tv = painted { AgentMentionPaint.clear(tv) }
            painted = nil
        }
    }
}

/// A plain multi-line text box whose "@Agent" mentions are the message box's pills (Notes). An NSTextView of our own
/// so the rounded tint can be drawn under the text (PillTextView's one `draw`), as ComposerTextView's BoxTextView.
struct MentionTextView: NSViewRepresentable {
    @Binding var text: String
    var fontSize: CGFloat = 13
    /// Each change makes the box the first responder.
    var focusTick = 0
    var onEscape: () -> Void = {}

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.scrollerStyle = .overlay
        let tv = PillTextView(usingTextLayoutManager: false)
        tv.delegate = context.coordinator
        tv.isRichText = false
        tv.importsGraphics = false
        tv.allowsUndo = true
        tv.drawsBackground = false
        tv.font = NSFont(name: "Nunito", size: fontSize) ?? .systemFont(ofSize: fontSize)
        tv.textColor = NSColor(WS.ink)
        tv.minSize = .zero
        tv.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        tv.isVerticallyResizable = true
        tv.isHorizontallyResizable = false
        tv.autoresizingMask = [.width]
        tv.textContainer?.widthTracksTextView = true
        tv.textContainer?.containerSize = NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude)
        tv.string = text
        scroll.documentView = tv
        context.coordinator.textView = tv
        context.coordinator.repaint()
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        let c = context.coordinator
        c.parent = self
        guard let tv = c.textView else { return }
        if tv.string != text {
            tv.string = text
            // text put in from outside (an agent picked from the list): the caret at its end
            tv.setSelectedRange(NSRange(location: (text as NSString).length, length: 0))
            c.repaint()
        }
        if c.lastFocus != focusTick {
            c.lastFocus = focusTick
            DispatchQueue.main.async { tv.window?.makeFirstResponder(tv) }
        }
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: MentionTextView
        weak var textView: PillTextView?
        var lastFocus: Int
        init(_ p: MentionTextView) { parent = p; lastFocus = p.focusTick - 1 }

        func repaint() {
            guard let tv = textView else { return }
            tv.pills = AgentMentionPaint.paint(tv)
        }

        func textDidChange(_ notification: Notification) {
            guard let tv = textView else { return }
            repaint()
            if parent.text != tv.string { parent.text = tv.string }
        }

        func textView(_ textView: NSTextView, doCommandBy sel: Selector) -> Bool {
            if sel == #selector(NSResponder.cancelOperation(_:)) { parent.onEscape(); return true }
            return false
        }
    }

    final class PillTextView: NSTextView {
        /// The "@Agent" pills' ranges and colours (AgentMentionPaint); drawn under the text.
        var pills: [(NSRange, NSColor)] = [] {
            didSet {
                let same = pills.count == oldValue.count && zip(pills, oldValue).allSatisfy { NSEqualRanges($0.0, $1.0) && $0.1 == $1.1 }
                if !same { needsDisplay = true }
            }
        }

        override func draw(_ dirtyRect: NSRect) {
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
            super.draw(dirtyRect)
        }
    }
}

/// One line of SwiftUI text whose "@Agent" mentions are drawn as the message box's pills (Home's rotating example,
/// "@Lia find flights\u{2026}"). The tint sits 3 pt out on each side under the name, so nothing moves.
struct MentionPillText: View {
    let text: String
    let font: Font
    let color: Color

    private var parts: [(String, NSColor?)] {
        let ns = text as NSString
        var out: [(String, NSColor?)] = []
        var at = 0
        for h in AgentChips.mentions(text) where h.range.location >= at {
            if h.range.location > at { out.append((ns.substring(with: NSRange(location: at, length: h.range.location - at)), nil)) }
            out.append((ns.substring(with: h.range), ChipSpec.agentInk(h.color)))
            at = NSMaxRange(h.range)
        }
        if at < ns.length { out.append((ns.substring(from: at), nil)) }
        return out
    }

    var body: some View {
        HStack(spacing: 0) {
            ForEach(Array(parts.enumerated()), id: \.offset) { _, p in
                if let c = p.1 {
                    Text(verbatim: p.0).foregroundStyle(Color(nsColor: c))
                        .background(RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(Color(nsColor: c).opacity(0.14)).padding(.horizontal, -3))
                } else {
                    Text(verbatim: p.0).foregroundStyle(color)
                }
            }
        }
        .font(font)
        .lineLimit(1)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: text))
    }
}
