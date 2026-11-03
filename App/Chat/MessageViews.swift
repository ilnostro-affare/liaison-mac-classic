import SwiftUI
import AppKit

// The thread, sized as the site draws it (ai.js injectCSS, ai/index.html):
// the agent's answer in the interface face 14 / 1.5 (AnswerText; Newsreader retired), the person's bubble 14 / 1.55 with corners 16 16 4 16.

private struct MarkdownCompactKey: EnvironmentKey { static let defaultValue = false }
extension EnvironmentValues {
    /// Thinking blocks use the same markdown at a smaller, quieter size.
    var markdownCompact: Bool {
        get { self[MarkdownCompactKey.self] }
        set { self[MarkdownCompactKey.self] = newValue }
    }
}

/// A message's Markdown blocks, parsed once per text (MarkdownView's body runs on every redraw, and
/// again for every row each time a dialogue opens).
@MainActor
enum MarkdownBlockCache {
    private static var cache: [String: [MDBlock]] = [:]
    static func blocks(_ text: String) -> [MDBlock] {
        if let b = cache[text] { return b }
        let b = Markdown.blocks(text)
        if cache.count > 800 { cache.removeAll(keepingCapacity: true) }
        cache[text] = b
        return b
    }
}

/// Lia's answer as ai.js renders it: withCites (citations placed by their offsets) -> mdLite (blocks) -> chips. Each
/// block is an AnswerText (CSS line boxes, Newsreader with Georgia for what it cannot draw, chips as real boxes), and
/// the blocks stand apart by the site's margins, collapsed as the browser collapses them.
struct MarkdownView: View {
    let text: String
    var ents: [String: ChatEntity] = [:]
    var cites: [ChatCite] = []
    @Environment(\.markdownCompact) private var compact
    /// A11Y-04: the conversation's text size (1 outside the conversation sheet).
    @Environment(\.liaTextScale) private var scale
    /// The window's handler (MainWindow): http(s) to the browser.
    @Environment(\.openURL) private var outerOpenURL
    /// A branch chip with a private preview opens it in the Canvas (the thread's Dev card route).
    @Environment(\.devPreviewOpen) private var devOpen

    var body: some View {
        let marked = CiteMark.apply(text, cites: cites)
        let blocks = MarkdownBlockCache.blocks(marked.text)
        let chip = onChip(marked.groups)
        let parts = Self.parts(blocks)
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(parts.enumerated()), id: \.offset) { i, part in
                partView(part, groups: marked.groups, chip: chip)
                    .padding(.top, i == 0 ? 0 : gap(parts[i - 1].last, part.first))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// (0.2.11: "I can only select a paragraph at a time"): the text blocks in a row - paragraphs,
    /// headings, lists - are one text view (AnswerFlow), so a selection runs across them and ⌘A takes the message;
    /// a table, a code block or a rule stands between two runs as its own view.
    enum Part {
        case flow([MDBlock])
        case block(MDBlock)
        var first: MDBlock { switch self { case .flow(let b): return b[0]; case .block(let b): return b } }
        var last: MDBlock { switch self { case .flow(let b): return b[b.count - 1]; case .block(let b): return b } }
    }

    static func parts(_ blocks: [MDBlock]) -> [Part] {
        var out: [Part] = []
        var run: [MDBlock] = []
        for b in blocks {
            switch b {
            case .heading, .paragraph, .bullets, .numbered:
                run.append(b)
            case .table, .code, .rule:
                if !run.isEmpty { out.append(.flow(run)); run = [] }
                out.append(.block(b))
            }
        }
        if !run.isEmpty { out.append(.flow(run)) }
        return out
    }

    @ViewBuilder
    private func partView(_ part: Part, groups: [[ChatCite]], chip: @escaping (ChipAction, NSRect) -> Void) -> some View {
        switch part {
        case .flow(let blocks):
            AnswerFlow(items: flowItems(blocks), strut: base, ents: ents, groups: groups, onChip: chip)
        case .block(let b):
            blockView(b, groups: groups, chip: chip)
        }
    }

    /// The run's blocks as the flow's paragraphs, each with the space the site puts above it.
    private func flowItems(_ blocks: [MDBlock]) -> [AnswerFlow.Item] {
        var items: [AnswerFlow.Item] = []
        for (k, b) in blocks.enumerated() {
            let g: CGFloat = k == 0 ? 0 : gap(blocks[k - 1], b)
            switch b {
            case let .heading(_, t):
                // div.md-h: 700 at 1em, --text.
                items.append(.init(text: t, style: { var s = base; s.weight = .bold; s.tone = .text; return s }(), gap: g))
            case .paragraph(let t):
                items.append(.init(text: t, style: base, gap: g))
            case .bullets(let list):
                // ul.md-l: padding-left 18, li margin 2 0, the marker outside in the item's face.
                for (j, it) in list.enumerated() {
                    items.append(.init(text: it, style: { var s = base; s.marker = "\u{2022}"; s.indent = 18; return s }(),
                                       gap: j == 0 ? g : 2, blank: j == 0))
                }
            case .numbered(let list):
                for (j, it) in list.enumerated() {
                    items.append(.init(text: it, style: { var s = base; s.marker = "\(j + 1)."; s.indent = 18; return s }(),
                                       gap: j == 0 ? g : 2, blank: j == 0))
                }
            case .table, .code, .rule:
                break
            }
        }
        return items
    }

    /// .ai__atext: .md-p 0 0 12, .md-h 22 0 7 (none above when first), .md-l 0 0 9, .md-tw and .md-pre 0 0 10, .md-hr
    /// 12 0. In a thought (.tl__txt) .md-p is 0 0 7 and .md-h keeps the base 14 0 6.
    private func margins(_ b: MDBlock) -> (top: CGFloat, bottom: CGFloat) {
        switch b {
        case .heading: return compact ? (14, 6) : (22, 7)
        case .paragraph: return (0, compact ? 7 : 12)
        case .bullets, .numbered: return (0, 9)
        case .table, .code: return (0, 10)
        case .rule: return (12, 12)
        }
    }

    private func gap(_ a: MDBlock, _ b: MDBlock) -> CGFloat { max(margins(a).bottom, margins(b).top) }

    /// The interface face at 14 / 1.5, as the person's bubble (was Newsreader 16 / 1.72). .tl__txt: 400 11.5px the interface face, 1.62, --text-3, bold --text-2.
    private var base: AnswerStyle {
        var s = AnswerStyle()
        if compact {
            s.face = .ui
            s.size = 11.5
            s.tone = .text3
            s.boldTone = .text2
            s.factor = 1.62
        }
        s.size *= scale
        return s
    }

    private func onChip(_ groups: [[ChatCite]]) -> (ChipAction, NSRect) -> Void {
        let ents = self.ents
        let open = outerOpenURL
        let devOpen = devOpen
        return { action, rect in
            switch action {
            case .entity(let id): EntityPopup.show(.entity(id), ents: ents, anchor: rect)
            case .namesake(let key): EntityPopup.show(.namesake(key), ents: ents, anchor: rect)
            case .link(let u): if let url = URL(string: u) { open(url) }
            case .cite(let gi): if groups.indices.contains(gi) { CiteCard.show(groups[gi], anchor: rect) { open($0) } }
            case .copy(let s): Clipboard.copy(s)
            case .github(let ref): ChipGitHub.open(ref, open: open, devOpen: devOpen)
            case .file(let f): CanvasFileOpen.open(f)   // the text view answers it first (AnswerTextNSView)
            }
        }
    }

    private func line(_ t: String, _ style: AnswerStyle, _ groups: [[ChatCite]], _ chip: @escaping (ChipAction, NSRect) -> Void) -> some View {
        AnswerText(text: t, style: style, ents: ents, groups: groups, onChip: chip)
    }

    @ViewBuilder
    private func blockView(_ block: MDBlock, groups: [[ChatCite]], chip: @escaping (ChipAction, NSRect) -> Void) -> some View {
        switch block {
        case let .heading(_, t):
            // div.md-h: 700 at 1em, --text.
            line(t, { var s = base; s.weight = .bold; s.tone = .text; return s }(), groups, chip)
        case .paragraph(let t):
            line(t, base, groups, chip)
        case .bullets(let items):
            // ul.md-l: padding-left 18, li margin 2 0, the marker outside in the item's face.
            VStack(alignment: .leading, spacing: 2) {
                ForEach(Array(items.enumerated()), id: \.offset) { _, it in
                    line(it, { var s = base; s.marker = "\u{2022}"; s.indent = 18; return s }(), groups, chip)
                }
            }
        case .numbered(let items):
            VStack(alignment: .leading, spacing: 2) {
                ForEach(Array(items.enumerated()), id: \.offset) { i, it in
                    line(it, { var s = base; s.marker = "\(i + 1)."; s.indent = 18; return s }(), groups, chip)
                }
            }
        case let .table(header, rows):
            AnswerTable(header: header, rows: rows, base: base, compact: compact, scale: scale, ents: ents, groups: groups, onChip: chip)
        case .code(let c):
            CodeBlockView(code: c, scale: scale)
        case .rule:
            // .md-hr: 1 px --line-2.
            Rectangle().fill(AppConfig.line2).frame(height: 1)
        }
    }
}

/// pre.md-pre: var(--font-mono) (Inter inside the answer) 12 / 1.5, rgba(127,127,127,.09), radius 9, padding 11 13.
/// "Copy" at the top right on hover copies the code, then reads "Copied" for a moment.
private struct CodeBlockView: View {
    let code: String
    var scale: CGFloat = 1
    @State private var hover = false
    @State private var copied = false

    var body: some View {
        ScrollView(.horizontal, showsIndicators: true) {
            Text(verbatim: code).font(LiaFont.inter((12 * scale).rounded())).lineSpacing(3.5 * scale)
                .foregroundStyle(AppConfig.ink)
                .textSelection(.enabled)
                .padding(.horizontal, 13).padding(.vertical, 11)
        }
        .background(RoundedRectangle(cornerRadius: 9).fill(Color(white: 0.5).opacity(0.09)))
        .overlay(alignment: .topTrailing) { copyButton }
        .onHover { hover = $0 }
    }

    private var copyButton: some View {
        Button(action: copy) {
            HStack(spacing: 4) {
                Image(systemName: copied ? "checkmark" : "doc.on.doc").font(.system(size: 9.5, weight: .semibold))
                Text(copied ? "Copied" : "Copy").font(LiaFont.ui(11, .semibold))
            }
            .foregroundStyle(AppConfig.text2)
            .padding(.horizontal, 7).frame(height: 20)
            .background(RoundedRectangle(cornerRadius: 6).fill(AppConfig.ddBg))
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(AppConfig.line2))
        }
        .buttonStyle(.liaPlain)
        .liaHoverWash(RoundedRectangle(cornerRadius: 6))
        .padding(6)
        .opacity(hover || copied ? 1 : 0)
        .animation(.easeOut(duration: 0.12), value: hover)
        .accessibilityLabel(Text(copied ? "Copied" : "Copy code"))
    }

    private func copy() {
        Clipboard.copy(code)
        copied = true
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_400_000_000)
            copied = false
        }
    }
}

/// table.md-t, fitted to the message (a two-column table ran past the bubble, its long column cut
/// off mid-word). The table always takes the message's width: short columns keep their one-line width, long ones share
/// the rest and wrap (a word too long for its column breaks), inline markdown, chips and selection as in the rest of
/// the answer (each cell is an AnswerText). Only when a column would get narrower than TableFit.readable does the
/// table keep readable widths and scroll sideways, its scroller always shown. Look: a rounded box with a 1 px
/// Line-2 border, the header row tinted (th 700 uppercase .03em --text-3), 1 px rules between rows and columns.
/// In a thought the base sizes apply: th 10.5, td 12.5.
private struct AnswerTable: View {
    let header: [String]
    let rows: [[String]]
    let base: AnswerStyle
    let compact: Bool
    var scale: CGFloat = 1
    let ents: [String: ChatEntity]
    let groups: [[ChatCite]]
    let onChip: (ChipAction, NSRect) -> Void

    private var th: AnswerStyle {
        var s = base
        s.size = (compact ? 10.5 : 11.5) * scale
        s.weight = .bold
        s.tone = .text3
        s.boldTone = nil
        s.uppercase = true
        s.tracking = 0.03
        s.wraps = true
        return s
    }

    private var td: AnswerStyle {
        var s = base
        s.size = (compact ? 12.5 : 13.5) * scale
        s.tabular = true
        s.wraps = true
        return s
    }

    private var padX: CGFloat { compact ? 8 : 10 }
    private static let radius: CGFloat = 10

    var body: some View {
        // The first child fits whenever the room is at least TableFit.minimumWidth (its ideal width); otherwise
        // the scrolling one is used. Neither is ever wider than what it shows.
        ViewThatFits(in: .horizontal) {
            grid(scroll: false)
            ScrollView(.horizontal) {
                grid(scroll: true)
                    .padding(.bottom, 12)   // room for the scroller under the last row
            }
            .scrollIndicators(.visible, axes: .horizontal)
        }
        .background(RoundedRectangle(cornerRadius: Self.radius, style: .continuous).fill(Color(white: 0.5).opacity(0.03)))
        .clipShape(RoundedRectangle(cornerRadius: Self.radius, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Self.radius, style: .continuous).strokeBorder(AppConfig.line2, lineWidth: 1))
    }

    private func grid(scroll: Bool) -> some View {
        let n = max(1, header.count)
        return AnswerTableLayout(columns: n, scroll: scroll) {
            ForEach(0..<n, id: \.self) { c in
                cell(c < header.count ? header[c] : "", style: th, col: c, isHeader: true)
            }
            ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                ForEach(0..<n, id: \.self) { c in
                    cell(c < row.count ? row[c] : "", style: td, col: c, isHeader: false)
                }
            }
        }
    }

    private func cell(_ text: String, style: AnswerStyle, col: Int, isHeader: Bool) -> some View {
        AnswerText(text: text, style: style, ents: ents, groups: groups, onChip: onChip)
            .padding(.horizontal, padX)
            .padding(.vertical, isHeader ? 7 : 6)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(isHeader ? Color(white: 0.5).opacity(0.08) : Color.clear)
            .overlay(alignment: .top) {
                if !isHeader { Rectangle().fill(AppConfig.line2).frame(height: 1) }
            }
            .overlay(alignment: .leading) {
                if col > 0 { Rectangle().fill(AppConfig.line2.opacity(0.7)).frame(width: 1) }
            }
    }
}

/// Places the table's cells (children row by row, `columns` per row) at the widths TableFit gives: the proposed
/// width shared out (fitting), or readable widths (`scroll`, inside the horizontal scroll view). Each row is as tall
/// as its tallest cell at its column's width; every cell is proposed the row's height, so backgrounds and rules line up.
/// Without a proposed width the table reports TableFit.minimumWidth, which is what ViewThatFits compares.
struct AnswerTableLayout: Layout {
    let columns: Int
    var scroll = false

    struct Cache { var cols: [TableFit.Column] }

    func makeCache(subviews: Subviews) -> Cache {
        let n = max(1, columns)
        var minW = [CGFloat](repeating: 0, count: n)
        var natW = [CGFloat](repeating: 0, count: n)
        for (i, sv) in subviews.enumerated() {
            let c = i % n
            minW[c] = max(minW[c], sv.sizeThatFits(ProposedViewSize(width: 0, height: nil)).width)
            natW[c] = max(natW[c], sv.sizeThatFits(.unspecified).width)
        }
        return Cache(cols: (0..<n).map { TableFit.Column(min: ceil(minW[$0]), natural: ceil(natW[$0])) })
    }

    func updateCache(_ cache: inout Cache, subviews: Subviews) {
        cache = makeCache(subviews: subviews)
    }

    private func widths(_ proposal: ProposedViewSize, _ cache: Cache) -> [CGFloat] {
        if scroll { return TableFit.scrollWidths(cache.cols) }
        let room: CGFloat
        if let w = proposal.width, w.isFinite { room = w } else { room = TableFit.minimumWidth(cache.cols) }
        return TableFit.fit(cache.cols, available: room).widths
    }

    private func rowHeights(_ subviews: Subviews, _ ws: [CGFloat]) -> [CGFloat] {
        let n = max(1, columns)
        let rows = (subviews.count + n - 1) / n
        var hs = [CGFloat](repeating: 0, count: rows)
        for (i, sv) in subviews.enumerated() {
            let h = sv.sizeThatFits(ProposedViewSize(width: ws[i % n], height: nil)).height
            hs[i / n] = max(hs[i / n], ceil(h))
        }
        return hs
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout Cache) -> CGSize {
        let ws = widths(proposal, cache)
        let hs = rowHeights(subviews, ws)
        return CGSize(width: ws.reduce(0, +), height: hs.reduce(0, +))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout Cache) {
        let n = max(1, columns)
        // Laid out at the width actually given (the bounds), so the cells never run past it.
        let ws = widths(scroll ? proposal : ProposedViewSize(width: bounds.width, height: nil), cache)
        let hs = rowHeights(subviews, ws)
        var y: CGFloat = bounds.minY
        var row = 0
        var x: CGFloat = bounds.minX
        for (i, sv) in subviews.enumerated() {
            let c = i % n
            if c == 0 && i > 0 { y += hs[row]; row += 1; x = bounds.minX }
            sv.place(at: CGPoint(x: x, y: y), anchor: .topLeading, proposal: ProposedViewSize(width: ws[c], height: hs[row]))
            x += ws[c]
        }
    }
}

/// The person's message. An answer to one of Lia's questions reads as the question quoted small and
/// grey over a small bubble (ai.js userBubble, `.ai__ans`).
struct UserBubble: View {
    let message: ChatMessage
    var auth: AuthStore? = nil
    var onOpen: (ChatAttachment) -> Void = { _ in }
    @State private var hover = false
    @State private var copied = false

    var body: some View {
        if let q = ModeReply.quote(for: message.content) {
            VStack(alignment: .trailing, spacing: 4) {
                Text(q.question).font(LiaFont.ui(12)).foregroundStyle(AppConfig.text3)
                Text(q.answer).font(LiaFont.ui(13.5)).foregroundStyle(AppConfig.ink)
                    .padding(.horizontal, 13).padding(.vertical, 7)
                    .background(UnevenRoundedRectangle(topLeadingRadius: 16, bottomLeadingRadius: 16, bottomTrailingRadius: 4, topTrailingRadius: 16).fill(AppConfig.userBubble))
            }
            .frame(maxWidth: .infinity, alignment: .trailing)
            .id(q.planId.map { "ans-" + $0 })
        } else {
            plain
        }
    }

    private var plain: some View {
        let shown = UserText.display(message.content)
        return VStack(alignment: .trailing, spacing: 6) {
            // ai.js userBubble: documents in their row, then the pictures in a row of their own, then the bubble.
            let docs = message.attachments.filter { !$0.isImage }, pics = message.attachments.filter(\.isImage)
            if !docs.isEmpty {
                HStack(spacing: 8) {
                    ForEach(docs) { a in AttachmentTile(attachment: a, auth: auth).onTapGesture { onOpen(a) }.liaHoverWash(RoundedRectangle(cornerRadius: 14, style: .continuous)) }
                }
                .frame(maxWidth: .infinity, alignment: .trailing)
            }
            let keys = UserText.creativeKeys(message.content)
            let shots = keys.compactMap { CreativePreviews.shared.data(for: $0) }.compactMap(NSImage.init(data:))
            let remote = keys.filter { CreativePreviews.shared.data(for: $0) == nil }.compactMap { CreativePreviews.shared.url(for: $0) }
            if !pics.isEmpty || !shots.isEmpty || (!remote.isEmpty && auth != nil) {
                HStack(spacing: 6) {
                    ForEach(pics) { a in AttachmentTile(attachment: a, auth: auth).onTapGesture { onOpen(a) }.liaHoverWash(RoundedRectangle(cornerRadius: 14, style: .continuous)) }
                    ForEach(Array(shots.enumerated()), id: \.offset) { _, img in
                        Image(nsImage: img).resizable().scaledToFill().frame(width: 100, height: 100)
                            .clipShape(RoundedRectangle(cornerRadius: 12))
                    }
                    if let auth {
                        ForEach(remote, id: \.self) { u in
                            AuthedImage(url: u, auth: auth).frame(width: 100, height: 100).clipShape(RoundedRectangle(cornerRadius: 12))
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .trailing)
            }
            if !shown.isEmpty {
                HStack {
                    Spacer(minLength: 0)
                    Text(shown)
                        .font(LiaFont.ui(14))
                        .lineSpacing(7.7)
                        .foregroundStyle(AppConfig.ink)
                        .padding(.horizontal, 15).padding(.vertical, 11)
                        .background(UnevenRoundedRectangle(topLeadingRadius: 16, bottomLeadingRadius: 16, bottomTrailingRadius: 4, topTrailingRadius: 16).fill(AppConfig.userBubble))
                        .textSelection(.enabled)
                }
                // 78% of the 820 thread
                .frame(maxWidth: 640, alignment: .trailing)
                .frame(maxWidth: .infinity, alignment: .trailing)
            }
            // Time and copy, shown on hover (ai.js .ai__umeta).
            HStack(spacing: 6) {
                if let ts = message.ts { MessageTime(date: Date(timeIntervalSince1970: ts / 1000)) }
                MetaButton(icon: copied ? nil : "copy", system: copied ? "checkmark" : nil, help: "Copy message") {
                    Clipboard.copy(shown); flash($copied)
                }
            }
            .font(LiaFont.ui(11.5)).foregroundStyle(AppConfig.text4)
            .opacity(hover || copied ? 1 : 0)
        }
        .onHover { hover = $0 }
    }
}

func flash(_ b: Binding<Bool>, for seconds: Double = 2) {
    b.wrappedValue = true
    DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { b.wrappedValue = false }
}

/// 24 px icon button under a message.
struct MetaButton: View {
    var icon: String?
    var system: String? = nil
    var help: String
    var on = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Group {
                if let system { Image(systemName: system).font(.system(size: 12, weight: .semibold)) }
                else if let icon { LiaIcon(icon, size: 16) }
            }
            .frame(width: 24, height: 24)
            .contentShape(RoundedRectangle(cornerRadius: 7))
        }
        .buttonStyle(.liaPlain)
        // The site's .ai__mb:hover: a surface ground and the glyph at full ink.
        .liaHover(.icon, radius: 7, tint: on ? AppConfig.ink : AppConfig.text3)
        .accessibilityLabel(help)
    }
}

struct AttachmentTile: View {
    let attachment: ChatAttachment
    var auth: AuthStore? = nil
    private let side: CGFloat = 118

    var body: some View {
        Group {
            if attachment.isImage {
                if let d = attachment.preview, let img = NSImage(data: d) {
                    Image(nsImage: img).resizable().scaledToFill()
                } else if let url = attachment.absoluteURL(base: AppConfig.aiBase), let auth {
                    AuthedImage(url: url.absoluteString, auth: auth).frame(maxWidth: .infinity, maxHeight: .infinity).clipped()
                } else {
                    AppConfig.surface2
                }
            } else {
                VStack(alignment: .leading, spacing: 3) {
                    HStack(alignment: .top) {
                        LiaIcon("note", size: 18).foregroundStyle(AppConfig.text3)
                        Spacer()
                        Text(attachment.badge)
                            .font(LiaFont.ui(9, .bold))
                            .foregroundStyle(AppConfig.text2)
                            .padding(.horizontal, 5).padding(.vertical, 2)
                            .background(RoundedRectangle(cornerRadius: 4).fill(AppConfig.surface2))
                    }
                    Spacer(minLength: 0)
                    Text(attachment.name).font(LiaFont.ui(12, .semibold)).foregroundStyle(AppConfig.ink).lineLimit(2)
                    if let size = attachment.sizeLabel {
                        Text(size).font(LiaFont.ui(11)).foregroundStyle(AppConfig.text4)
                    }
                }
                .padding(9)
                .background(AppConfig.surface)
            }
        }
        .frame(width: side, height: side)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(AppConfig.line2, lineWidth: 1))
        .accessibilityLabel(attachment.name)
    }
}

/// A chart or a file Lia made (ai.js blkFile / blkPlot header).
struct BlockCard: View {
    let block: ChatBlock
    let onOpen: (ChatBlock) -> Void

    var body: some View {
        Button { onOpen(block) } label: {
            HStack(spacing: 12) {
                ZStack {
                    RoundedRectangle(cornerRadius: 8).fill(AppConfig.surface2)
                    LiaIcon(block.isChart ? "usage" : "note", size: 18).foregroundStyle(AppConfig.text2)
                }
                .frame(width: 36, height: 40)
                VStack(alignment: .leading, spacing: 2) {
                    Text(block.displayTitle).font(LiaFont.ui(13.5, .semibold)).foregroundStyle(AppConfig.ink).lineLimit(1)
                    Text(subtitle).font(LiaFont.ui(12)).foregroundStyle(AppConfig.text3)
                }
                Spacer()
            }
            .padding(10)
            .frame(maxWidth: 420, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 12).fill(AppConfig.surface))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(AppConfig.line2, lineWidth: 1))
        }
        .buttonStyle(.liaPlain)
        .liaHover(.fill, radius: 12)
        .accessibilityLabel("\(block.displayTitle), \(block.kindLabel)")
    }

    private var subtitle: String {
        let ext = (block.filename?.split(separator: ".").last.map { String($0).uppercased() })
        let size = block.bytes.map { ByteCountFormatter.string(fromByteCount: Int64($0), countStyle: .file) }
        return [block.kindLabel, ext, size].compactMap { $0 }.joined(separator: " \u{00b7} ")
    }
}

/// What a widget can open. Held in one place so the thread does not grow a closure per block.
struct WidgetActions {
    var openCreatives: (CreativePerformance?, DateRange?, String?) -> Void = { _, _, _ in }
    var openCreative: (CreativeStat, DateRange?, String?) -> Void = { _, _, _ in }
    var openLeads: (LeadsSummary) -> Void = { _ in }
    /// One ad by id and name (the retention block's thumbnail, ai.js data-blk-act="ad"), and the account the block
    /// says it is in (nil = the block did not say; the router then refuses rather than guess).
    var openAd: (String, String, String?) -> Void = { _, _, _ in }
    var openSettings: (String) -> Void = { _ in }
}

struct AssistantMessageView: View {
    let message: ChatMessage
    let ents: [String: ChatEntity]
    let onOpenBlock: (ChatBlock) -> Void
    var auth: AuthStore? = nil
    var widgets = WidgetActions()
    var onFeedback: (String) -> Void = { _ in }
    var onDetails: (String, String, String) -> Void = { _, _, _ in }
    var onRetry: (() -> Void)? = nil
    var onOpenPlan: (() -> Void)? = nil
    /// The answer goes on in the next message (a browser task ran between them): one answer to the person, so
    /// the thumbs, copy and time sit only under its last part.
    var continues = false
    @State private var hover = false
    /// A11Y-04: the conversation's text size (1 outside the conversation sheet).
    @Environment(\.liaTextScale) private var scale

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            let memo = MemorySaved.items(message.blocks)
            if !memo.isEmpty { MemoryLine(items: memo) }
            AnswerBlocks(blocks: message.blocks, after: false, auth: auth, onOpenBlock: onOpenBlock, widgets: widgets)
            if !message.content.isEmpty || !message.cites.isEmpty { MarkdownView(text: message.content, ents: ents, cites: message.cites) }
            AnswerBlocks(blocks: message.blocks, after: true, auth: auth, onOpenBlock: onOpenBlock, widgets: widgets)
            if message.stopped {
                // ai.js aiStopNoticeHTML
                HStack(spacing: 10) {
                    Text("Stopped.")
                        .font(LiaFont.ui((12.5 * scale).rounded())).foregroundStyle(AppConfig.text3)
                    if let onRetry {
                        Button("Retry", action: onRetry).buttonStyle(ChatCapsuleButtonStyle()).liaHoverWash(Capsule())
                    }
                }
            }
            if let onOpenPlan, let p = PlanState(json: message.plan) {
                // ai.js planRowHTML: "Open plan" with its state
                Button(action: onOpenPlan) {
                    HStack(spacing: 5) {
                        Text("Open plan")
                        Text(planState(p)).fontWeight(.regular).foregroundStyle(WS.text3)
                    }
                }
                .buttonStyle(ChatCapsuleButtonStyle(primary: false))
                .liaHoverWash(Capsule())
            }
            if !continues {
                MessageFooter(message: message, onFeedback: onFeedback, onDetails: onDetails)
                    .opacity(hover ? 1 : 0)
            }
        }
        .onHover { hover = $0 }
    }

    private func planState(_ p: PlanState) -> String {
        guard p.done else { return "\(p.parts) part" + (p.parts == 1 ? "" : "s") }
        switch p.answer { case "stopped": return "Cut off"; case "no": return "Not published"; case "apply": return "Applied"; default: return "Published" }
    }
}

/// Thumbs, copy and time under an answer (ai.js aMetaHTML). The exact date is the time's tooltip.
struct MessageFooter: View {
    let message: ChatMessage
    let onFeedback: (String) -> Void
    var onDetails: (String, String, String) -> Void = { _, _, _ in }
    @State private var copied = false
    @State private var detailsFor: String?

    private var date: Date? { message.ts.map { Date(timeIntervalSince1970: $0 / 1000) } }

    var body: some View {
        HStack(spacing: 2) {
            MetaButton(icon: nil, system: message.feedback == "up" ? "hand.thumbsup.fill" : "hand.thumbsup",
                       help: "Good response", on: message.feedback == "up") {
                onFeedback("up")
                if message.feedback != "up" { detailsFor = "up" }
            }
            MetaButton(icon: nil, system: message.feedback == "down" ? "hand.thumbsdown.fill" : "hand.thumbsdown",
                       help: "Bad response", on: message.feedback == "down") {
                onFeedback("down")
                if message.feedback != "down" { detailsFor = "down" }
            }
            MetaButton(icon: copied ? nil : "copy", system: copied ? "checkmark" : nil, help: "Copy answer") {
                Clipboard.copy(message.content); flash($copied)
            }
            if let date {
                MessageTime(date: date)
                    .font(LiaFont.ui(11.5)).foregroundStyle(AppConfig.text4)
                    .padding(.leading, 4)
            }
            Spacer(minLength: 0)
        }
        .liaModal(item: Binding(get: { detailsFor.map { FeedbackTarget(verdict: $0) } }, set: { if $0 == nil { detailsFor = nil } })) { t in
            FeedbackSheet(verdict: t.verdict) { topic, note in
                onDetails(t.verdict, topic, note)
                detailsFor = nil
            } onSkip: { detailsFor = nil }
        }
    }
}

/// "13 minutes ago" under a message, the exact moment ("Oct 11, 2026, 12:23 AM") as its tooltip.
/// Relative for a week, then the short date; it moves on by itself every minute.
struct MessageTime: View {
    let date: Date

    private static let exact: DateFormatter = {
        let f = DateFormatter(); f.setLocalizedDateFormatFromTemplate("MMMdyyyyjmm"); return f
    }()
    private static let day: DateFormatter = {
        let f = DateFormatter(); f.setLocalizedDateFormatFromTemplate("MMMdyyyy"); return f
    }()
    private static let relative: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter(); f.unitsStyle = .full; f.dateTimeStyle = .named; return f
    }()

    static func label(_ date: Date, now: Date) -> String {
        let s = now.timeIntervalSince(date)
        if s < 60 { return "just now" }
        if s > 7 * 86400 { return day.string(from: date) }
        return relative.localizedString(for: date, relativeTo: now)
    }

    var body: some View {
        TimelineView(.periodic(from: .now, by: 60)) { ctx in
            Text(Self.label(date, now: ctx.date)).lineLimit(1)
        }
        .liaTip(Self.exact.string(from: date))
    }
}

struct FeedbackTarget: Identifiable { let verdict: String; var id: String { verdict } }

/// ai.js openFeedback: optional details after a thumb; the thumb itself is already sent.
struct FeedbackSheet: View {
    let verdict: String
    let onSend: (String, String) -> Void
    let onSkip: () -> Void

    static let topics = [
        "The numbers are wrong",
        "Wrong account, campaign or date range",
        "It did not do what I asked",
        "It stopped short of an answer",
        "A card proposed the wrong change",
        "It replied in the wrong language",
        "It claimed something it had not done",
        "It was too slow",
        "Something in the interface",
        "Something else",
    ]

    @State private var topic = ""
    @State private var note = ""
    @FocusState private var noteFocused: Bool

    // ai.js openFeedback in .ai__websell-card.ai__fbcard: 420 wide, --ink-2, padding 18 18 14, radius 16.
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // .ai__websell-h: display face 17 / 600.
            Text(verdict == "up" ? "What worked here?" : "What went wrong?")
                .font(LiaFont.ui(17, .semibold)).foregroundStyle(AppConfig.ink)
            // .ai__websell-p: 13.5 / 1.5 --text-2, margin 10 0 16.
            Text("Optional, and it goes straight to us. Nothing from your account or your ad data is attached.")
                .font(LiaFont.ui(13.5)).lineSpacing(1.8).foregroundStyle(AppConfig.text2)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 10).padding(.bottom, 16)
            if verdict == "down" {
                // .ai__fbfield: margin 2 0 12; label 10 / 700, .07em, capitals, --text-4, 6 below.
                VStack(alignment: .leading, spacing: 0) {
                    Text("Closest match".uppercased()).font(LiaFont.ui(10, .bold)).tracking(0.7)
                        .foregroundStyle(AppConfig.text4).padding(.bottom, 6)
                    FeedbackTopicSelect(topic: $topic, topics: Self.topics, width: 384)
                    // .ai__fbhint: 11 --text-4, 6 above.
                    Text("You can send without choosing.").font(LiaFont.ui(11)).foregroundStyle(AppConfig.text4)
                        .padding(.top, 6)
                }
                .padding(.top, 2).padding(.bottom, 12)
            }
            // .ai__fbta: min-height 84, --ctl, 1 px --line-2 (the accent while focused), radius 9, 12.5 / 1.5,
            // padding 9 11, margin-bottom 4.
            TextEditor(text: $note)
                .font(LiaFont.ui(12.5))
                .lineSpacing(1.7)
                .foregroundStyle(AppConfig.ink)
                .scrollContentBackground(.hidden)
                .focused($noteFocused)
                .padding(.horizontal, 6).padding(.vertical, 7)
                .frame(height: 84)
                .background(RoundedRectangle(cornerRadius: 9).fill(AppConfig.ctl))
                .overlay(RoundedRectangle(cornerRadius: 9).stroke(noteFocused ? AppConfig.accent : AppConfig.line2, lineWidth: 1))
                .overlay(alignment: .topLeading) {
                    if note.isEmpty {
                        Text(verdict == "up" ? "What was useful about this answer?" : "What did you expect instead?")
                            .font(LiaFont.ui(12.5)).foregroundStyle(AppConfig.text4)
                            .padding(.horizontal, 11).padding(.vertical, 9).allowsHitTesting(false)
                    }
                }
                .padding(.bottom, 4 + 16)
            // .ai__websell-b: right-aligned, 8 apart.
            HStack(spacing: 8) {
                Spacer()
                Button(action: onSkip) {
                    // .ai__websell-x: 32 high, 0 12, radius 9, transparent, 1 px --line, --text-2.
                    Text("Cancel").font(LiaFont.ui(13)).foregroundStyle(AppConfig.text2)
                        .padding(.horizontal, 12).frame(height: 32)
                        .overlay(RoundedRectangle(cornerRadius: 9).stroke(AppConfig.line, lineWidth: 1))
                        .contentShape(RoundedRectangle(cornerRadius: 9))
                }
                .buttonStyle(.liaPlain).liaHover(.fill, radius: 9).keyboardShortcut(.cancelAction)
                Button { onSend(topic, note) } label: {
                    // .ai__websell-go: 32 high, 0 14, radius 9, the accent, white 600.
                    Text("Send").font(LiaFont.ui(13, .semibold)).foregroundStyle(AppConfig.onAccent)
                        .padding(.horizontal, 14).frame(height: 32)
                        .background(RoundedRectangle(cornerRadius: 9).fill(AppConfig.accent))
                        .contentShape(RoundedRectangle(cornerRadius: 9))
                }
                .buttonStyle(.liaPlain).liaHover(.solid).keyboardShortcut(.defaultAction)
            }
        }
        .padding(.horizontal, 18).padding(.top, 18).padding(.bottom, 14)
        .frame(width: 420)
        .background(AppConfig.ink2)
        .onAppear { DispatchQueue.main.asyncAfter(deadline: .now() + 0.03) { noteFocused = true } }
        .onDisappear { DropdownHost.shared.close() }
    }
}

/// button.ai__fbsel and its .ai__menu: --ctl, 1 px --line-2 (--line-3 on hover), radius 9, 12.5 px, padding 9 11,
/// Text-3 until a topic is set, then --text; the menu opens 6 below at the field's width with .ai__modelrow rows.
struct FeedbackTopicSelect: View {
    @Binding var topic: String
    let topics: [String]
    let width: CGFloat
    @State private var hover = false

    var body: some View {
        DropdownButton(gap: 6, highlight: false) {
            HStack(spacing: 8) {
                Text(topic.isEmpty ? "Choose one, or skip this" : topic)
                    .font(LiaFont.ui(12.5)).lineLimit(1).truncationMode(.tail)
                    .foregroundStyle(topic.isEmpty ? AppConfig.text3 : AppConfig.ink)
                    .frame(maxWidth: .infinity, alignment: .leading)
                LiaIcon("caret-down", size: 13).foregroundStyle(AppConfig.text4)
            }
            .padding(.horizontal, 11).padding(.vertical, 9)
            .frame(width: width)
            .background(RoundedRectangle(cornerRadius: 9).fill(AppConfig.ctl))
            .overlay(RoundedRectangle(cornerRadius: 9).stroke(hover ? AppConfig.line3 : AppConfig.line2, lineWidth: 1))
            .contentShape(RoundedRectangle(cornerRadius: 9))
        } menu: {
            DropdownPanelView(width: width) {
                ForEach(topics, id: \.self) { t in
                    FeedbackTopicRow(title: t, current: t == topic) { topic = t }
                }
            }
        }
        .onHover { hover = $0 }
    }
}

/// button.ai__modelrow in the topic menu: padding 6 9, radius 8, the title 11.5 / 700, --surface-2 under the pointer.
private struct FeedbackTopicRow: View {
    let title: String
    let current: Bool
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button {
            DropdownHost.shared.close()
            action()
        } label: {
            Text(title).font(LiaFont.ui(11.5, .bold)).foregroundStyle(AppConfig.ink).lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 9).padding(.vertical, 6)
                .background(RoundedRectangle(cornerRadius: 8).fill(hover ? AppConfig.surface2 : Color.clear))
                .contentShape(Rectangle())
        }
        .buttonStyle(.liaPlain)
        .onHover { hover = $0 }
        .liaPointer()
        .accessibilityAddTraits(current ? .isSelected : [])
    }
}

/// The site's small buttons (`.setx-btn`, modal buttons): 12.5 / 500, radius 9; primary = ink on canvas.
struct LiaButtonStyle: ButtonStyle {
    var primary = false
    var danger = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(LiaFont.ui(12.5, .semibold))
            .foregroundStyle(primary ? AppConfig.composeBg : (danger ? AppConfig.destructive : AppConfig.ink))
            .padding(.horizontal, 13).padding(.vertical, 7)
            .background(RoundedRectangle(cornerRadius: 9).fill(primary ? AppConfig.ink : AppConfig.surface2))
            .opacity(configuration.isPressed ? 0.75 : 1)
            .contentShape(RoundedRectangle(cornerRadius: 9))
            // Hover: the grey face a step firmer (a second surface-2 under it), a filled one eases back.
            .liaHover(primary ? .solid : .fill, radius: 9)
    }
}
