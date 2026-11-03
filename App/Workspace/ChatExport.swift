import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// A conversation exported for a client: Markdown (as written) or a printable PDF (Letter pages).
@MainActor
enum ChatExport {
    struct Line: Identifiable {
        let id: String
        let who: String
        let time: Date?
        let text: String
    }

    /// The stored messages, oldest first (error cards and machine replies are not in `items`' text worth sending).
    static func lines(_ chat: TeamChatModel, name: (String?) -> String) -> [Line] {
        chat.items.filter { !chat.errorItems.contains($0.id) }.compactMap { item in
            let text = item.message.content.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return nil }
            return Line(id: item.id, who: item.agent == nil ? "You" : name(item.agent),
                        time: item.message.ts.map { Date(timeIntervalSince1970: $0 / 1000) }, text: text)
        }
    }

    static func markdown(title: String, lines: [Line]) -> String {
        var out = "# \(title)\n\n_Exported from Liaison \u{00b7} \(Date().formatted(date: .abbreviated, time: .shortened))_\n"
        for l in lines {
            let when = l.time.map { " \u{00b7} " + $0.formatted(date: .abbreviated, time: .shortened) } ?? ""
            out += "\n---\n\n**\(l.who)**\(when)\n\n\(l.text)\n"
        }
        return out
    }

    static func saveMarkdown(title: String, lines: [Line]) -> Bool {
        guard let url = ask(title, ext: "md", type: UTType(filenameExtension: "md") ?? .plainText) else { return false }
        do { try markdown(title: title, lines: lines).write(to: url, atomically: true, encoding: .utf8); return true } catch { return false }
    }

    static func savePDF(title: String, lines: [Line]) -> Bool {
        guard let url = ask(title, ext: "pdf", type: .pdf), let data = pdf(title: title, lines: lines) else { return false }
        return (try? data.write(to: url)) != nil
    }

    private static func ask(_ title: String, ext: String, type: UTType) -> URL? {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [type]
        panel.canCreateDirectories = true
        let safe = title.components(separatedBy: CharacterSet(charactersIn: "/:\\")).joined(separator: "-")
        panel.nameFieldStringValue = "\(safe) \(Date().formatted(.iso8601.year().month().day())).\(ext)"
        return panel.runModal() == .OK ? panel.url : nil
    }

    // MARK: PDF

    private static let pageW: CGFloat = 612
    private static let pageH: CGFloat = 792
    private static let margin: CGFloat = 48
    private static var width: CGFloat { pageW - margin * 2 }

    /// Each message is measured, messages are packed into pages, each page is drawn by ImageRenderer into a PDF
    /// context (vector text). A message taller than a page gets a taller page of its own rather than being cut.
    static func pdf(title: String, lines: [Line]) -> Data? {
        let data = NSMutableData()
        var box = CGRect(x: 0, y: 0, width: pageW, height: pageH)
        guard let consumer = CGDataConsumer(data: data as CFMutableData),
              let ctx = CGContext(consumer: consumer, mediaBox: &box, nil) else { return nil }
        let heights = lines.map { height(of: ChatPrintRow(line: $0)) }
        let headerH = height(of: ChatPrintHeader(title: title))
        for (i, page) in paginate(heights, first: headerH + 16).enumerated() {
            let content = ChatPrintPage(title: i == 0 ? title : nil, lines: page.map { lines[$0] })
                .frame(width: width, alignment: .topLeading)
            let r = ImageRenderer(content: content)
            r.proposedSize = ProposedViewSize(width: width, height: nil)
            r.render { size, draw in
                var mb = CGRect(x: 0, y: 0, width: pageW, height: max(pageH, size.height + margin * 2))
                ctx.beginPage(mediaBox: &mb)
                ctx.saveGState()
                ctx.translateBy(x: margin, y: mb.height - margin - size.height)
                draw(ctx)
                ctx.restoreGState()
                ctx.endPage()
            }
        }
        ctx.closePDF()
        return data as Data
    }

    private static func height<V: View>(of v: V) -> CGFloat {
        let r = ImageRenderer(content: v.frame(width: width, alignment: .leading))
        r.proposedSize = ProposedViewSize(width: width, height: nil)
        var h: CGFloat = 0
        r.render { size, _ in h = size.height }
        return h
    }

    /// Indices of the messages on each page (12 pt between messages).
    private static func paginate(_ heights: [CGFloat], first: CGFloat) -> [[Int]] {
        let room = pageH - margin * 2
        var pages: [[Int]] = [[]]
        var used = first
        for (i, h) in heights.enumerated() {
            if !pages[pages.count - 1].isEmpty, used + h > room {
                pages.append([])
                used = 0
            }
            pages[pages.count - 1].append(i)
            used += h + 12
        }
        return pages
    }
}

private struct ChatPrintPage: View {
    let title: String?
    let lines: [ChatExport.Line]
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let title { ChatPrintHeader(title: title).padding(.bottom, 4) }
            ForEach(lines) { ChatPrintRow(line: $0) }
        }
    }
}

private struct ChatPrintHeader: View {
    let title: String
    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(.system(size: 18, weight: .semibold)).foregroundStyle(Color.black)
            Text("Exported from Liaison \u{00b7} " + Date().formatted(date: .abbreviated, time: .shortened))
                .font(.system(size: 10)).foregroundStyle(Color.gray)
        }
    }
}

private struct ChatPrintRow: View {
    let line: ChatExport.Line
    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Text(line.who).font(.system(size: 11, weight: .semibold))
                if let t = line.time {
                    Text(t.formatted(date: .abbreviated, time: .shortened)).font(.system(size: 9.5)).foregroundStyle(Color.gray)
                }
            }
            Text(rich).font(.system(size: 11)).fixedSize(horizontal: false, vertical: true)
        }
        .foregroundStyle(Color.black)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var rich: AttributedString {
        let opts = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        return (try? AttributedString(markdown: line.text, options: opts)) ?? AttributedString(line.text)
    }
}

/// The header's "More" menu: Export \u{25B8} Markdown\u{2026} / PDF\u{2026}.
struct ChatHeaderMenu: View {
    let onMarkdown: () -> Void
    let onPDF: () -> Void

    var body: some View {
        Menu {
            Menu("Export") {
                Button("Markdown\u{2026}", action: onMarkdown)
                Button("PDF\u{2026}", action: onPDF)
            }
        } label: {
            Image(systemName: "ellipsis").font(.system(size: 13, weight: .semibold)).foregroundStyle(WS.text2)
                .frame(width: 32, height: 32)
                .background(WS.soft, in: Circle())
                .contentShape(Circle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .liaPointer()
        .accessibilityLabel(Text("More actions"))
    }
}
