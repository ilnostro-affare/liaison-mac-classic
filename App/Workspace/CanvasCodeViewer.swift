import SwiftUI
import AppKit

// ("make the viewer like Claude's code viewer"): Dev's files and diffs in the Canvas's Code tab.
// A file: its tab (name, close), the path as a breadcrumb, line numbers in a gutter, syntax colours (CodeSyntax,
// built off the main thread and kept per file), no wrapping (long lines scroll sideways), search in the file, lines
// picked in the gutter for Copy and "Attach as context" (path:line range into the composer). An NSTextView: the
// system's own I-beam, selection and scrolling, laid out only where it is looked at.
// A diff: unified (old / new numbers, red / green lines, the changed words marked) or side by side, long unchanged
// runs folded behind "Show N lines", the lines between hunks read from the file on demand. Lazy rows, a measured
// width so a long line scrolls sideways instead of being cut.

// MARK: - colours and the face

enum CodeInk {
    static let font = NSFont.monospacedSystemFont(ofSize: 11.5, weight: .regular)
    static let lineHeight: CGFloat = 18
    /// One character's advance in the face (it is monospaced).
    static let charWidth: CGFloat = ("M" as NSString).size(withAttributes: [.font: font]).width

    static let text = AnswerInk.text
    static let gutter = AnswerInk.text4
    /// The code's own ground (WS.surface), opaque, shared by the text and the line-number gutter so
    /// code scrolled sideways passes UNDER the numbers; `gutterEdge` is the gutter's right hairline.
    static let ground = AnswerInk.dyn((0x1A1D22, 1), (0xFFFFFF, 1))
    static let gutterEdge = AnswerInk.line2
    static let keyword = AnswerInk.dyn((0xC678DD, 1), (0x8250DF, 1))
    static let string = AnswerInk.dyn((0x98C379, 1), (0x0A7F3F, 1))
    static let comment = AnswerInk.dyn((0xffffff, 0.42), (0x11141a, 0.45))
    static let number = AnswerInk.dyn((0xD19A66, 1), (0xB35900, 1))
    static let type = AnswerInk.dyn((0x56B6C2, 1), (0x0E7490, 1))
    static let tag = AnswerInk.dyn((0xE06C75, 1), (0x116329, 1))
    static let attribute = AnswerInk.dyn((0xD19A66, 1), (0x953800, 1))
    static let match = AnswerInk.dyn((0xF5C542, 0.30), (0xF5C542, 0.45))
    static let current = AnswerInk.dyn((0xF5A524, 0.65), (0xF5A524, 0.70))
    static let picked = AnswerInk.dyn((0x5B78FF, 0.20), (0x3B5BFD, 0.14))

    static func color(_ k: CodeTokenKind) -> NSColor {
        switch k {
        case .plain: return text
        case .keyword: return keyword
        case .string: return string
        case .comment: return comment
        case .number: return number
        case .type: return type
        case .tag: return tag
        case .attribute: return attribute
        }
    }
}

/// A file's coloured text and where each line starts (UTF-16), built off the main thread.
final class CodeAttrBox: @unchecked Sendable {
    let text: NSAttributedString
    let lineStarts: [Int]
    let lines: [String]
    /// The longest line in character cells (a tab counts as 4): the text's width without wrapping.
    let longest: Int
    init(text: NSAttributedString, lineStarts: [Int], lines: [String]) {
        self.text = text; self.lineStarts = lineStarts; self.lines = lines
        longest = lines.reduce(0) { m, l in max(m, l.count + l.reduce(0) { $1 == "\t" ? $0 + 3 : $0 }) }
    }

    static func make(path: String, text raw: String) -> CodeAttrBox {
        let lines = DevCodeLines.make(raw)
        let pieces = CodeSyntax.highlight(lines, lang: CodeLang.of(path: path))
        let out = NSMutableAttributedString()
        let para = NSMutableParagraphStyle()
        para.minimumLineHeight = CodeInk.lineHeight
        para.maximumLineHeight = CodeInk.lineHeight
        para.lineBreakMode = .byClipping
        var starts: [Int] = []
        starts.reserveCapacity(lines.count)
        var at = 0
        for (i, line) in pieces.enumerated() {
            starts.append(at)
            for p in line {
                out.append(NSAttributedString(string: p.text, attributes: [.foregroundColor: CodeInk.color(p.kind)]))
                at += (p.text as NSString).length
            }
            if i < pieces.count - 1 { out.append(NSAttributedString(string: "\n")); at += 1 }
        }
        out.addAttributes([.font: CodeInk.font, .paragraphStyle: para], range: NSRange(location: 0, length: out.length))
        return CodeAttrBox(text: out, lineStarts: starts.isEmpty ? [0] : starts, lines: lines)
    }

    /// The 1-based line holding UTF-16 offset `i`.
    func line(at i: Int) -> Int {
        var lo = 0, hi = lineStarts.count - 1
        while lo < hi {
            let mid = (lo + hi + 1) / 2
            if lineStarts[mid] <= i { lo = mid } else { hi = mid - 1 }
        }
        return lo + 1
    }

    /// The UTF-16 range of lines a...b (1-based, inclusive), without the last line's newline.
    func range(lines a: Int, _ b: Int) -> NSRange {
        let lo = max(1, min(a, b)), hi = min(lineStarts.count, max(a, b))
        let start = lineStarts[lo - 1]
        let end = hi < lineStarts.count ? lineStarts[hi] - 1 : text.length
        return NSRange(location: start, length: max(0, end - start))
    }
}

/// Built files, by path and text, for the app's life (at most 24; a file opened again draws at once).
@MainActor
final class CodeViewCache {
    static let shared = CodeViewCache()
    private var boxes: [String: CodeAttrBox] = [:]
    private var order: [String] = []

    static func key(_ path: String, _ text: String) -> String { path + "|" + String(text.utf8.count) + "|" + String(text.hashValue) }

    func get(_ k: String) -> CodeAttrBox? { boxes[k] }

    func put(_ k: String, _ b: CodeAttrBox) {
        boxes[k] = b
        order.removeAll { $0 == k }
        order.append(k)
        while order.count > 24 { boxes[order.removeFirst()] = nil }
    }
}

// MARK: - a file

/// The file viewer: tab, breadcrumb, toolbar (search, Copy, Attach as context), the text.
struct CodeFileViewer: View {
    let path: String
    /// The breadcrumb's first part: the project, the repository or the site's folder.
    let root: String
    let text: String
    var onClose: (() -> Void)? = nil
    @StateObject private var ctl = CodeTextController()
    @State private var box: CodeAttrBox?
    @State private var searching = false
    @State private var query = ""
    @State private var hits: [Int] = []
    @State private var hit = 0
    @State private var picked: ClosedRange<Int>?
    @State private var attached = false
    @FocusState private var searchFocus: Bool

    private var name: String { path.split(separator: "/").last.map(String.init) ?? path }

    var body: some View {
        VStack(spacing: 0) {
            tabBar
            crumbBar
            Divider().overlay(WS.line)
            ZStack {
                if let box {
                    CodeTextView(box: box, controller: ctl) { picked = $0 }
                } else {
                    ProgressView().controlSize(.small).frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
        .task(id: path + "|" + String(text.utf8.count) + "|" + String(text.suffix(48))) {
            let k = CodeViewCache.key(path, text)
            if let b = CodeViewCache.shared.get(k) { box = b; return }
            let p = path, t = text
            let b = await Task.detached(priority: .userInitiated) { CodeAttrBox.make(path: p, text: t) }.value
            guard !Task.isCancelled else { return }
            CodeViewCache.shared.put(k, b)
            box = b
            picked = nil
            if !query.isEmpty { find() }
        }
    }

    // the file's tab, as an editor's
    private var tabBar: some View {
        HStack(spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: "doc.text").font(.system(size: 10.5)).foregroundStyle(WS.text3).accessibilityHidden(true)
                Text(verbatim: name).font(LiaFont.ui(12, .medium)).foregroundStyle(WS.ink).lineLimit(1)
                if let onClose {
                    Button(action: onClose) {
                        Image(systemName: "xmark").font(.system(size: 8.5, weight: .bold)).foregroundStyle(WS.text3)
                            .frame(width: 16, height: 16).contentShape(Rectangle())
                    }
                    .buttonStyle(.liaPlain)
                    .accessibilityLabel(Text("Close \(name)"))
                }
            }
            .padding(.leading, 10).padding(.trailing, onClose == nil ? 10 : 4)
            .frame(height: 30)
            .background(WS.surface)
            .overlay(alignment: .top) { Rectangle().fill(SettingsLook.accent).frame(height: 2) }
            Spacer(minLength: 8)
            toolbar.padding(.trailing, 8)
        }
        .frame(height: 30)
        .background(Color.dyn(0x15181C, 0xFAFBFC))
    }

    private var toolbar: some View {
        HStack(spacing: 6) {
            if let r = picked, let box {
                Text(verbatim: r.lowerBound == r.upperBound ? "Line \(r.lowerBound)" : "Lines \(r.lowerBound)\u{2013}\(r.upperBound)")
                    .font(LiaFont.ui(11)).foregroundStyle(WS.text3).lineLimit(1)
                tool("doc.on.doc", "Copy") {
                    Clipboard.copy(CodeLines.text(box.lines, from: r.lowerBound, to: r.upperBound))
                }
                tool(attached ? "checkmark" : "text.badge.plus", "Attach as context") {
                    let s = CodeLines.context(path: path, lines: box.lines, from: r.lowerBound, to: r.upperBound)
                    NotificationCenter.default.post(name: .liaPutText, object: nil, userInfo: ["text": s])
                    attached = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) { attached = false }
                }
            }
            if searching {
                HStack(spacing: 4) {
                    Image(systemName: "magnifyingglass").font(.system(size: 10)).foregroundStyle(WS.text3)
                    TextField("Find in file", text: $query)
                        .textFieldStyle(.plain).font(LiaFont.ui(11.5))
                        .frame(width: 130)
                        .focused($searchFocus)
                        .onSubmit { next(NSEvent.modifierFlags.contains(.shift) ? -1 : 1) }
                        .onChange(of: query) { _, _ in find() }
                        .onExitCommand { closeSearch() }
                    Text(verbatim: hits.isEmpty ? (query.isEmpty ? "" : "0") : "\(hit + 1)/\(hits.count)")
                        .font(LiaFont.ui(10.5)).foregroundStyle(WS.text3).monospacedDigit()
                    tool("chevron.up", "Previous match") { next(-1) }
                    tool("chevron.down", "Next match") { next(1) }
                    tool("xmark", "Close search") { closeSearch() }
                }
                .padding(.horizontal, 6).frame(height: 22)
                .background(WS.surface, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).stroke(WS.line, lineWidth: 1))
            } else {
                tool("magnifyingglass", "Find in file") { searching = true; searchFocus = true }
            }
        }
    }

    private func tool(_ symbol: String, _ label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 10.5, weight: .medium)).foregroundStyle(WS.text2)
                .frame(width: 20, height: 20).contentShape(Rectangle())
        }
        .buttonStyle(.liaPlain)
        .accessibilityLabel(Text(label))
    }

    private var crumbBar: some View {
        let parts = [root] + CodeLines.crumbs(path)
        return ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 4) {
                ForEach(Array(parts.enumerated()), id: \.offset) { i, p in
                    if i > 0 { Image(systemName: "chevron.right").font(.system(size: 7.5, weight: .semibold)).foregroundStyle(WS.text3) }
                    Text(verbatim: p).font(LiaFont.ui(11, i == parts.count - 1 ? .medium : .regular))
                        .foregroundStyle(i == parts.count - 1 ? WS.text2 : WS.text3).lineLimit(1)
                }
                if picked == nil {
                    Text("Click line numbers to select lines").font(LiaFont.ui(10.5)).foregroundStyle(WS.text3.opacity(0.8))
                        .padding(.leading, 10)
                }
            }
            .padding(.horizontal, 10)
        }
        .frame(height: 24)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text("Path: " + parts.joined(separator: " / ")))
    }

    private func find() {
        guard let box else { return }
        hits = CodeLines.matches(box.lines, query: query)
        hit = 0
        ctl.mark(query: query, current: hits.first.map { _ in 0 })
    }

    private func next(_ d: Int) {
        guard !hits.isEmpty else { return }
        hit = (hit + d + hits.count) % hits.count
        ctl.mark(query: query, current: hit)
    }

    private func closeSearch() {
        searching = false
        query = ""
        hits = []
        ctl.mark(query: "", current: nil)
    }
}

/// What the toolbar asks of the text view (the view itself is AppKit's).
@MainActor
final class CodeTextController: ObservableObject {
    weak var view: CodeNSTextView?

    /// Marks every match of `query`; `current` (the index among the matches) is shown and scrolled to.
    func mark(query: String, current: Int?) {
        guard let v = view, let lm = v.layoutManager, let ts = v.textStorage else { return }
        let all = NSRange(location: 0, length: ts.length)
        lm.removeTemporaryAttribute(.backgroundColor, forCharacterRange: all)
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return }
        let s = ts.string as NSString
        var r = NSRange(location: 0, length: s.length)
        var found: [NSRange] = []
        while found.count < 5000 {
            let m = s.range(of: q, options: [.caseInsensitive], range: r)
            guard m.location != NSNotFound, m.length > 0 else { break }
            found.append(m)
            r = NSRange(location: NSMaxRange(m), length: s.length - NSMaxRange(m))
        }
        for m in found { lm.addTemporaryAttribute(.backgroundColor, value: CodeInk.match, forCharacterRange: m) }
        // the current match is the first one on the current matching line (CodeLines counts lines)
        guard let c = current, let box = v.box else { return }
        let lines = CodeLines.matches(box.lines, query: q)
        guard lines.indices.contains(c) else { return }
        let lineRange = box.range(lines: lines[c], lines[c])
        guard let m = found.first(where: { NSLocationInRange($0.location, lineRange) }) else { return }
        lm.addTemporaryAttribute(.backgroundColor, value: CodeInk.current, forCharacterRange: m)
        v.reveal(m)
    }
}

/// The text view: read only, selectable, no wrapping, its own scroll view and the line-number ruler.
struct CodeTextView: NSViewRepresentable {
    let box: CodeAttrBox
    let controller: CodeTextController
    let onPick: (ClosedRange<Int>?) -> Void

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = true
        scroll.backgroundColor = CodeInk.ground
        scroll.borderType = .noBorder
        let tv = CodeNSTextView.make()
        scroll.documentView = tv
        let ruler = CodeLineRuler(textView: tv)
        scroll.verticalRulerView = ruler
        scroll.hasVerticalRuler = true
        scroll.rulersVisible = true
        tv.ruler = ruler
        tv.onPick = onPick
        tv.show(box)
        controller.view = tv
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let tv = scroll.documentView as? CodeNSTextView else { return }
        tv.onPick = onPick
        if tv.box !== box { tv.show(box) }
        controller.view = tv
    }
}

final class CodeNSTextView: NSTextView {
    var box: CodeAttrBox?
    weak var ruler: CodeLineRuler?
    var onPick: ((ClosedRange<Int>?) -> Void)?
    /// The lines picked in the gutter (or covered by the selection), drawn in the gutter.
    private(set) var picked: ClosedRange<Int>?

    static func make() -> CodeNSTextView {
        let storage = NSTextStorage()
        let lm = NSLayoutManager()
        lm.allowsNonContiguousLayout = true
        storage.addLayoutManager(lm)
        let tc = NSTextContainer(size: NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude))
        tc.widthTracksTextView = false
        tc.heightTracksTextView = false
        tc.lineFragmentPadding = 0
        lm.addTextContainer(tc)
        let v = CodeNSTextView(frame: NSRect(x: 0, y: 0, width: 400, height: 400), textContainer: tc)
        v.isEditable = false
        v.isSelectable = true
        v.isRichText = true
        v.importsGraphics = false
        v.drawsBackground = false
        v.isHorizontallyResizable = false
        v.isVerticallyResizable = false
        v.minSize = NSSize(width: 0, height: 0)
        v.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        v.autoresizingMask = []
        v.textContainerInset = NSSize(width: 10, height: 8)
        v.isAutomaticLinkDetectionEnabled = false
        v.usesFontPanel = false
        v.allowsUndo = false
        v.focusRingType = .none
        v.selectedTextAttributes = [.backgroundColor: NSColor.selectedTextBackgroundColor]
        return v
    }

    func show(_ b: CodeAttrBox) {
        box = b
        picked = nil
        textStorage?.setAttributedString(b.text)
        setSelectedRange(NSRange(location: 0, length: 0))
        ruler?.digits = max(String(b.lineStarts.count).count, 2)
        fit()
        scroll(.zero)
        ruler?.needsDisplay = true
    }

    /// The size of the whole text, known without laying it out: no wrapping and one fixed line height. Never smaller
    /// than the visible area (a click below the last line still lands in the text).
    func fit() {
        guard let b = box else { return }
        let inset = textContainerInset
        let natural = NSSize(width: CGFloat(b.longest) * CodeInk.charWidth + inset.width * 2 + 24,
                             height: CGFloat(b.lineStarts.count) * CodeInk.lineHeight + inset.height * 2)
        let clip = enclosingScrollView?.contentSize ?? .zero
        let size = NSSize(width: max(natural.width, clip.width), height: max(natural.height, clip.height))
        if abs(frame.width - size.width) > 0.5 || abs(frame.height - size.height) > 0.5 { setFrameSize(size) }
    }

    private var clipWatch: NSObjectProtocol?

    override func viewDidMoveToSuperview() {
        super.viewDidMoveToSuperview()
        if let o = clipWatch { NotificationCenter.default.removeObserver(o); clipWatch = nil }
        guard let clip = superview as? NSClipView else { return }
        clip.postsFrameChangedNotifications = true
        clipWatch = NotificationCenter.default.addObserver(forName: NSView.frameDidChangeNotification, object: clip, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.fit() }
        }
    }

    /// Scrolls a range into view (a search match), with the system's find indicator.
    func reveal(_ r: NSRange) {
        super.scrollRangeToVisible(r)
        showFindIndicator(for: r)
    }

    /// Lines a...b picked: selected as text too, so ⌘C copies them.
    func pick(_ a: Int, _ b: Int) {
        guard let box else { return }
        let r = box.range(lines: a, b)
        picked = min(a, b)...max(a, b)
        window?.makeFirstResponder(self)
        setSelectedRange(r)
        ruler?.needsDisplay = true
        onPick?(picked)
    }

    override func setSelectedRanges(_ ranges: [NSValue], affinity: NSSelectionAffinity, stillSelecting: Bool) {
        super.setSelectedRanges(ranges, affinity: affinity, stillSelecting: stillSelecting)
        guard !stillSelecting, let box else { return }
        let r = selectedRange()
        let now: ClosedRange<Int>?
        if r.length == 0 { now = nil } else {
            let a = box.line(at: r.location), b = box.line(at: max(r.location, NSMaxRange(r) - 1))
            now = a...b
        }
        guard now != picked else { return }
        picked = now
        ruler?.needsDisplay = true
        let cb = onPick
        DispatchQueue.main.async { cb?(now) }
    }

}

/// Line numbers beside the text: the picked lines tinted; a click picks a line, shift-click or a drag a range.
final class CodeLineRuler: NSRulerView {
    weak var textView: CodeNSTextView?
    var digits = 2 { didSet { if digits != oldValue { ruleThickness = thickness } } }
    private var anchor: Int?

    init(textView: CodeNSTextView) {
        self.textView = textView
        super.init(scrollView: nil, orientation: .verticalRuler)
        clientView = textView
        ruleThickness = thickness
        // (the code pane was white but for the numbers): since macOS 14 a view does not clip
        // its drawing, and the opaque gutter's fill spread over the code and the file list
        clipsToBounds = true
    }

    required init(coder: NSCoder) { fatalError("not used") }

    private var thickness: CGFloat { CGFloat(digits) * CodeInk.charWidth + 22 }

    override var isFlipped: Bool { true }

    /// ("the code draws over the numbers"): no ruler chrome, but an opaque gutter on the code's ground
    /// above the text, with a hairline at its right edge, so a line scrolled sideways goes under the numbers.
    override var isOpaque: Bool { true }
    override func draw(_ dirtyRect: NSRect) {
        // only inside the gutter, whatever rect AppKit asks to draw
        let r = dirtyRect.intersection(bounds)
        guard !r.isEmpty else { return }
        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(rect: bounds).setClip()
        CodeInk.ground.setFill()
        r.fill()
        drawHashMarksAndLabels(in: r)
        CodeInk.gutterEdge.setFill()
        NSRect(x: bounds.maxX - 1, y: r.minY, width: 1, height: r.height).fill()
        NSGraphicsContext.restoreGraphicsState()
    }

    override func drawHashMarksAndLabels(in rect: NSRect) {
        guard let tv = textView, let lm = tv.layoutManager, let tc = tv.textContainer, let box = tv.box else { return }
        let visible = tv.visibleRect
        let glyphs = lm.glyphRange(forBoundingRect: visible, in: tc)
        let chars = lm.characterRange(forGlyphRange: glyphs, actualGlyphRange: nil)
        var line = box.line(at: chars.location)
        let attrs: [NSAttributedString.Key: Any] = [.font: CodeInk.font, .foregroundColor: CodeInk.gutter]
        let picked = tv.picked
        let inset = tv.textContainerInset.height
        let total = box.lineStarts.count
        while line <= total {
            let start = box.lineStarts[line - 1]
            if start > NSMaxRange(chars) && line > 1 { break }
            // The line's first fragment and its baseline inside it (TextKit's own, so the number sits on the code's
            // baseline whatever the paragraph's fixed height does); a wrapped line is numbered on its first row only.
            let frag: NSRect
            var baseOff: CGFloat = CodeInk.lineHeight + CodeInk.font.descender
            if start >= (tv.textStorage?.length ?? 0) {
                frag = lm.extraLineFragmentRect.height > 0 ? lm.extraLineFragmentRect
                    : lm.lineFragmentRect(forGlyphAt: max(0, lm.numberOfGlyphs - 1), effectiveRange: nil)
            } else {
                let g = lm.glyphIndexForCharacter(at: start)
                frag = lm.lineFragmentRect(forGlyphAt: g, effectiveRange: nil)
                baseOff = lm.location(forGlyphAt: g).y
            }
            let y = convert(NSPoint(x: 0, y: frag.minY + inset), from: tv).y
            if y > bounds.maxY { break }
            if let p = picked, p.contains(line) {
                CodeInk.picked.setFill()
                NSRect(x: 0, y: y, width: bounds.width, height: frag.height).fill()
            }
            let s = String(line) as NSString
            let w = s.size(withAttributes: attrs).width
            // without .usesLineFragmentOrigin the rect's origin is the baseline (flipped: y grows down)
            s.draw(with: NSRect(x: bounds.width - 10 - w, y: y + baseOff, width: w + 2, height: CodeInk.lineHeight),
                   options: [], attributes: attrs, context: nil)
            line += 1
        }
    }

    private func line(at event: NSEvent) -> Int? {
        guard let tv = textView, let lm = tv.layoutManager, let tc = tv.textContainer, let box = tv.box else { return nil }
        var p = tv.convert(event.locationInWindow, from: nil)
        p.x = tv.textContainerInset.width + 1
        p.y -= tv.textContainerInset.height
        let g = lm.glyphIndex(for: p, in: tc)
        let c = lm.characterIndexForGlyph(at: g)
        return box.line(at: c)
    }

    override func mouseDown(with event: NSEvent) {
        guard let l = line(at: event) else { return }
        if event.modifierFlags.contains(.shift), let a = anchor ?? textView?.picked?.lowerBound {
            textView?.pick(a, l)
        } else {
            anchor = l
            textView?.pick(l, l)
        }
    }

    override func mouseDragged(with event: NSEvent) {
        guard let a = anchor, let l = line(at: event) else { return }
        textView?.pick(a, l)
        textView?.autoscroll(with: event)
    }

    // the gutter keeps the arrow: one cursor rect, set by AppKit (never pushed here)
    override func resetCursorRects() { addCursorRect(bounds, cursor: .arrow) }
}

// MARK: - a diff

/// One file's diff, unified or side by side (remembered), with folds and gaps that open on a click.
struct CodeDiffViewer: View {
    let change: DevFileChange
    let file: DevDiff.File?
    let cut: Bool
    /// The last file of the diff (where a cut diff stops).
    let last: Bool
    /// Reads the file as it is after the change, for the lines between hunks (nil: they cannot be shown).
    var loadNew: (@MainActor (String) async -> String?)? = nil
    @AppStorage("lia_canvas_diff_split") private var split = false
    @State private var view: DevDiffView?
    @State private var open: Set<Int> = []
    @State private var newLines: [String]?
    @State private var reading = false
    @State private var note: String?

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().overlay(WS.line)
            content
        }
        .task(id: change.path) { await build(newText: nil, opening: nil) }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "doc.text").font(.system(size: 10.5)).foregroundStyle(WS.text3).accessibilityHidden(true)
            Text(verbatim: change.path).font(.system(size: 11.5, weight: .medium, design: .monospaced)).foregroundStyle(WS.ink)
                .lineLimit(1).truncationMode(.middle)
                .textSelection(.enabled)
            DiffCounts(add: change.add, del: change.del, binary: change.binary)
            Spacer(minLength: 8)
            if let note { Text(note).font(LiaFont.ui(11)).foregroundStyle(WS.text3).lineLimit(1) }
            HStack(spacing: 2) {
                seg("Unified", !split) { split = false }
                seg("Side by side", split) { split = true }
            }
            .padding(2)
            .background(WS.ink.opacity(0.06), in: Capsule())
        }
        .padding(.horizontal, 12).frame(height: 34)
    }

    private func seg(_ t: String, _ on: Bool, _ act: @escaping () -> Void) -> some View {
        Button(action: act) {
            Text(t).font(LiaFont.ui(11, .medium)).foregroundStyle(on ? WS.ink : WS.text2)
                .padding(.horizontal, 9).frame(height: 20)
                .background(on ? WS.surface : Color.clear, in: Capsule())
                .contentShape(Capsule())
        }
        .buttonStyle(.liaPlain)
        .accessibilityAddTraits(on ? .isSelected : [])
    }

    @ViewBuilder private var content: some View {
        if change.binary || (file?.binary ?? false) {
            DiffNote(words: "A binary file: there are no lines to show.")
        } else if let file, !file.hunks.isEmpty {
            if let v = view {
                GeometryReader { g in
                    ScrollView([.horizontal, .vertical]) {
                        if split { splitRows(v, viewport: g.size.width) } else { unifiedRows(v, viewport: g.size.width) }
                    }
                }
            } else {
                Color.clear
            }
        } else if cut {
            DiffNote(words: "The rest of the changes is too long to show here.")
        } else {
            DiffNote(words: "No changes to show for this file.")
        }
    }

    private func gutter(_ v: DevDiffView) -> CGFloat { CGFloat(v.digits) * CodeInk.charWidth + 12 }
    private func textWidth(_ v: DevDiffView) -> CGFloat { CGFloat(v.longest) * CodeInk.charWidth + 28 }

    private func unifiedRows(_ v: DevDiffView, viewport: CGFloat) -> some View {
        let g = gutter(v)
        let width = max(viewport, g * 2 + 22 + textWidth(v))
        let rows = DevDiffView.visible(v.unified, open: open)
        return LazyVStack(alignment: .leading, spacing: 0) {
            ForEach(rows) { r in
                switch r.kind {
                case .hunk(let label): hunkRow(label)
                case .fold(let grp, let n): foldRow(n) { _ = open.insert(grp) }
                case .gap(let gi, let n): gapRow(v, gap: gi, count: n)
                case .line:
                    DiffUnifiedLine(row: r, gutter: g)
                }
            }
            foot(v)
        }
        .frame(width: width, alignment: .leading)
        .padding(.vertical, 4)
    }

    private func splitRows(_ v: DevDiffView, viewport: CGFloat) -> some View {
        let g = gutter(v)
        let half = max(viewport / 2, g + 22 + textWidth(v))
        let rows = DevDiffView.visible(v.split, open: open)
        return LazyVStack(alignment: .leading, spacing: 0) {
            ForEach(rows) { r in
                switch r.kind {
                case .hunk(let label): hunkRow(label)
                case .fold(let grp, let n): foldRow(n) { _ = open.insert(grp) }
                case .gap(let gi, let n): gapRow(v, gap: gi, count: n)
                case .pair:
                    HStack(spacing: 0) {
                        DiffSplitHalf(side: r.left, gutter: g).frame(width: half, alignment: .leading)
                        Rectangle().fill(WS.line).frame(width: 1)
                        DiffSplitHalf(side: r.right, gutter: g).frame(width: half, alignment: .leading)
                    }
                }
            }
            foot(v)
        }
        .frame(width: half * 2 + 1, alignment: .leading)
        .padding(.vertical, 4)
    }

    private func hunkRow(_ label: String) -> some View {
        Text(verbatim: label)
            .font(LiaFont.ui(11, .medium)).foregroundStyle(WS.text3)
            .padding(.horizontal, 12).padding(.vertical, 4)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(WS.soft)
            .accessibilityAddTraits(.isHeader)
    }

    private func foldRow(_ n: Int, _ act: @escaping () -> Void) -> some View {
        Button(action: act) {
            HStack(spacing: 6) {
                Image(systemName: "arrow.up.and.down").font(.system(size: 9.5, weight: .semibold))
                Text(n == 1 ? "Show 1 line" : "Show \(n) lines").font(LiaFont.ui(11, .medium))
                Spacer(minLength: 0)
            }
            .foregroundStyle(SettingsLook.accent)
            .padding(.horizontal, 12).frame(height: 24)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(SettingsLook.accentSoft.opacity(0.6))
            .contentShape(Rectangle())
        }
        .buttonStyle(.liaPlain)
        .accessibilityLabel(Text("Show \(n) unchanged lines"))
    }

    @ViewBuilder private func gapRow(_ v: DevDiffView, gap: Int, count n: Int) -> some View {
        if loadNew != nil, newLines == nil {
            Button { Task { await readGap(v, gap: gap) } } label: {
                HStack(spacing: 6) {
                    if reading { ProgressView().controlSize(.mini) } else {
                        Image(systemName: "arrow.up.and.down").font(.system(size: 9.5, weight: .semibold))
                    }
                    Text(n == 1 ? "Show 1 unchanged line" : "Show \(n) unchanged lines").font(LiaFont.ui(11, .medium))
                    Spacer(minLength: 0)
                }
                .foregroundStyle(SettingsLook.accent)
                .padding(.horizontal, 12).frame(height: 24)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(SettingsLook.accentSoft.opacity(0.6))
                .contentShape(Rectangle())
            }
            .buttonStyle(.liaPlain)
            .disabled(reading)
        } else {
            Text(n == 1 ? "1 unchanged line" : "\(n) unchanged lines")
                .font(LiaFont.ui(11)).foregroundStyle(WS.text3)
                .padding(.horizontal, 12).frame(height: 22)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(WS.soft.opacity(0.6))
        }
    }

    @ViewBuilder private func foot(_ v: DevDiffView) -> some View {
        if v.tooLong {
            Text("The rest of this file\u{2019}s changes is too long to show here.").font(LiaFont.ui(12)).foregroundStyle(WS.text3)
                .padding(.horizontal, 12).padding(.vertical, 10)
        } else if cut && last {
            Text("The rest of the changes is too long to show here.").font(LiaFont.ui(12)).foregroundStyle(WS.text3)
                .padding(.horizontal, 12).padding(.vertical, 10)
        }
    }

    /// The file after the change, read once; the gaps become folds, the one clicked opens.
    private func readGap(_ v: DevDiffView, gap: Int) async {
        guard let loadNew, !reading else { return }
        reading = true
        defer { reading = false }
        guard let t = await loadNew(change.path) else { note = "Could not read the file."; return }
        let lines = DevDiffView.lines(t)
        guard let f = file, DevDiffView.fits(f, newText: lines) else {
            note = "The file changed since: its other lines are not shown."
            newLines = []
            return
        }
        newLines = lines
        await build(newText: lines, opening: v.gaps[gap]?.newStart)
    }

    private func build(newText: [String]?, opening start: Int?) async {
        guard let file, !file.hunks.isEmpty else { return }
        let f = file, p = change.path
        let built = await Task.detached(priority: .userInitiated) { DevDiffView.make(f, path: p, newText: newText) }.value
        guard !Task.isCancelled else { return }
        view = built
        if let s = start, let g = DevDiffView.group(startingAt: s, in: built.unified) { open.insert(g) }
    }
}

private struct DiffNote: View {
    let words: String
    var body: some View {
        Text(words).font(LiaFont.ui(12.5)).foregroundStyle(WS.text3)
            .multilineTextAlignment(.center).padding(14)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct DiffCounts: View {
    let add: Int
    let del: Int
    let binary: Bool
    var body: some View {
        if binary {
            Text("binary").font(LiaFont.ui(11)).foregroundStyle(WS.text3)
        } else {
            (Text(verbatim: "+\(add)").foregroundColor(DevDiffLook.add) + Text(verbatim: " \u{2212}\(del)").foregroundColor(DevDiffLook.del))
                .font(.system(size: 11, weight: .medium, design: .monospaced)).fixedSize()
        }
    }
}

/// A line's pieces as SwiftUI text: syntax colours, the changed words on a stronger ground.
enum CodeAttr {
    static func line(_ pieces: [CodePiece], changed: DiffSpan?, kind: DevDiff.Line.Kind) -> AttributedString {
        var out = AttributedString()
        var at = 0
        let mark: NSColor = kind == .add ? AnswerInk.dyn((0x3FB950, 0.38), (0x1A7F37, 0.26))
            : AnswerInk.dyn((0xF85149, 0.38), (0xCF222E, 0.24))
        for p in pieces {
            let color = Color(nsColor: CodeInk.color(p.kind))
            guard let c = changed, at < c.end, at + p.text.count > c.start else {
                var a = AttributedString(p.text); a.foregroundColor = color; out += a
                at += p.text.count
                continue
            }
            // split the piece at the changed span's edges
            let chars = Array(p.text)
            let s = max(0, c.start - at), e = min(chars.count, c.end - at)
            if s > 0 { var a = AttributedString(String(chars[0..<s])); a.foregroundColor = color; out += a }
            var m = AttributedString(String(chars[s..<e])); m.foregroundColor = color; m.backgroundColor = Color(nsColor: mark); out += m
            if e < chars.count { var a = AttributedString(String(chars[e...])); a.foregroundColor = color; out += a }
            at += chars.count
        }
        return out
    }
}

private struct DiffUnifiedLine: View, Equatable {
    let row: DiffUnifiedRow
    let gutter: CGFloat

    var body: some View {
        let mono = Font.system(size: 11.5, design: .monospaced)
        let k = row.lineKind
        let sign: String = k == .add ? "+" : k == .del ? "\u{2212}" : " "
        let tint: Color = k == .add ? DevDiffLook.add : k == .del ? DevDiffLook.del : WS.text3
        let bg: Color = k == .add ? DevDiffLook.addSoft : k == .del ? DevDiffLook.delSoft : Color.clear
        HStack(spacing: 0) {
            Text(verbatim: row.old.map(String.init) ?? "").font(mono).foregroundStyle(WS.text3)
                .frame(width: gutter, alignment: .trailing)
            Text(verbatim: row.new.map(String.init) ?? "").font(mono).foregroundStyle(WS.text3)
                .frame(width: gutter, alignment: .trailing)
            Text(verbatim: sign).font(mono).foregroundStyle(tint).frame(width: 22, alignment: .center)
            Text(row.pieces.isEmpty ? AttributedString(" ") : CodeAttr.line(row.pieces, changed: row.changed, kind: k))
                .font(mono)
                .lineLimit(1)
                .fixedSize()
                .padding(.trailing, 12)
            Spacer(minLength: 0)
        }
        .frame(height: CodeInk.lineHeight)
        .background(bg)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text((k == .add ? "Added: " : k == .del ? "Removed: " : "") + row.text))
    }
}

private struct DiffSplitHalf: View, Equatable {
    let side: DiffSide?
    let gutter: CGFloat

    var body: some View {
        let mono = Font.system(size: 11.5, design: .monospaced)
        HStack(spacing: 0) {
            if let s = side {
                Text(verbatim: String(s.number)).font(mono).foregroundStyle(WS.text3).frame(width: gutter, alignment: .trailing)
                Text(verbatim: s.kind == .add ? "+" : s.kind == .del ? "\u{2212}" : " ").font(mono)
                    .foregroundStyle(s.kind == .add ? DevDiffLook.add : s.kind == .del ? DevDiffLook.del : WS.text3)
                    .frame(width: 22, alignment: .center)
                Text(s.pieces.isEmpty ? AttributedString(" ") : CodeAttr.line(s.pieces, changed: s.changed, kind: s.kind))
                    .font(mono).lineLimit(1).fixedSize().padding(.trailing, 12)
                Spacer(minLength: 0)
            } else {
                Spacer(minLength: 0)
            }
        }
        .frame(maxWidth: .infinity, minHeight: CodeInk.lineHeight, maxHeight: CodeInk.lineHeight, alignment: .leading)
        .background(side.map { $0.kind == .add ? DevDiffLook.addSoft : $0.kind == .del ? DevDiffLook.delSoft : Color.clear }
                    ?? WS.soft.opacity(0.5))
    }
}
