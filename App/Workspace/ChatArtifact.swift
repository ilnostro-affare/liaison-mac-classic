import SwiftUI
import AppKit

/// A long agent answer (a markdown table of more than 5 rows, or more than 1500 characters) folds into a
/// compact card, "Report \u{00b7} 12 rows", with Open (the full rendered content in a wide sheet) and Copy.
enum ChatArtifact {
    static let minRows = 5
    static let minChars = 1500

    struct Info: Equatable {
        /// Rows of the largest table (0: no table).
        let rows: Int
        let words: Int
        /// The first line of prose, for the card's preview.
        let lead: String

        var title: String {
            if rows > ChatArtifact.minRows { return "Report \u{00b7} \(rows) rows" }
            return "Report \u{00b7} \(words) words"
        }
    }

    /// Nil when the message reads fine as a bubble.
    static func detect(_ content: String) -> Info? {
        let rows = largestTable(content)
        guard rows > minRows || content.count > minChars else { return nil }
        let words = content.split(whereSeparator: { $0 == " " || $0 == "\n" }).count
        return Info(rows: rows, words: words, lead: lead(content))
    }

    /// Body rows of the largest markdown table (header and the |---| line not counted).
    static func largestTable(_ content: String) -> Int {
        var best = 0, run = 0
        for raw in content.components(separatedBy: "\n") {
            let l = raw.trimmingCharacters(in: .whitespaces)
            if l.hasPrefix("|") {
                let isRule = !l.isEmpty && l.allSatisfy { "|-: ".contains($0) }
                if !isRule { run += 1 }
            } else {
                best = max(best, run - 1)
                run = 0
            }
        }
        return max(0, max(best, run - 1))
    }

    private static func lead(_ content: String) -> String {
        for raw in content.components(separatedBy: "\n") {
            var l = raw.trimmingCharacters(in: .whitespaces)
            if l.isEmpty || l.hasPrefix("|") || l.hasPrefix("```") { continue }
            while l.hasPrefix("#") || l.hasPrefix("*") || l.hasPrefix("-") || l.hasPrefix(">") { l = String(l.dropFirst()).trimmingCharacters(in: .whitespaces) }
            let plain = l.replacingOccurrences(of: "**", with: "").replacingOccurrences(of: "`", with: "")
            if !plain.isEmpty { return plain.count > 160 ? String(plain.prefix(159)) + "\u{2026}" : plain }
        }
        return ""
    }

    static func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}

/// The folded answer in the agent's bubble: icon, title, the first line, Open and Copy.
struct ChatArtifactCard: View {
    let message: ChatMessage
    let info: ChatArtifact.Info
    var auth: AuthStore? = nil
    @State private var open = false
    @State private var copied = false
    /// A11Y-04: the conversation's text size (1 outside the conversation sheet).
    @Environment(\.liaTextScale) private var scale

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: info.rows > ChatArtifact.minRows ? "tablecells" : "doc.richtext")
                    .font(.system(size: 14, weight: .medium)).foregroundStyle(WS.text2)
                    .frame(width: 28, height: 28).background(WS.surface, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                    .accessibilityHidden(true)
                Text(info.title).font(LiaFont.ui((13.5 * scale).rounded(), .semibold)).foregroundStyle(WS.ink)
            }
            if !info.lead.isEmpty {
                Text(info.lead).font(LiaFont.ui((13 * scale).rounded())).foregroundStyle(WS.text2).lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 8) {
                Button { open = true } label: { pill("Open", symbol: "arrow.up.left.and.arrow.down.right", solid: true) }
                    .buttonStyle(.liaPlain).liaPointer()
                    .accessibilityLabel(Text("Open \(info.title)"))
                Button(action: copy) { pill(copied ? "Copied" : "Copy", symbol: copied ? "checkmark" : "doc.on.doc", solid: false) }
                    .buttonStyle(.liaPlain).liaPointer()
                    .accessibilityLabel(Text(copied ? "Copied" : "Copy the report"))
            }
        }
        .frame(minWidth: 240, alignment: .leading)
        .sheet(isPresented: $open) { ChatArtifactSheet(message: message, info: info, auth: auth) }
        .accessibilityElement(children: .contain)
    }

    private func pill(_ title: String, symbol: String, solid: Bool) -> some View {
        HStack(spacing: 5) {
            Image(systemName: symbol).font(.system(size: 10, weight: .semibold))
            Text(title).font(LiaFont.ui((12 * scale).rounded(), .semibold))
        }
        .foregroundStyle(solid ? WS.onInk : WS.ink)
        .padding(.horizontal, 10).frame(height: 26)
        .background(solid ? WS.ink : WS.surface, in: Capsule())
        .overlay(Capsule().stroke(solid ? Color.clear : WS.line2))
    }

    private func copy() {
        ChatArtifact.copy(message.content)
        withAnimation(.easeOut(duration: 0.15)) { copied = true }
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            withAnimation(.easeOut(duration: 0.15)) { copied = false }
        }
    }
}

/// The full answer, rendered, in a wide sheet.
struct ChatArtifactSheet: View {
    let message: ChatMessage
    let info: ChatArtifact.Info
    var auth: AuthStore? = nil
    @Environment(\.dismiss) private var dismiss
    @State private var copied = false

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollView {
                AssistantMessageView(message: message, ents: [:], onOpenBlock: { _ in }, auth: auth)
                    .textSelection(.enabled)
                    .padding(24)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(minWidth: 820, idealWidth: 1000, minHeight: 540, idealHeight: 720)
        .background(WS.surface)
    }

    private var header: some View {
        HStack(spacing: 10) {
            Text(info.title).font(LiaFont.ui(15, .semibold)).foregroundStyle(WS.ink)
                .accessibilityAddTraits(.isHeader)
            Spacer()
            Button(copied ? "Copied" : "Copy") {
                ChatArtifact.copy(message.content)
                copied = true
            }
            .keyboardShortcut("c", modifiers: [.command, .shift])
            Button("Done") { dismiss() }
                .keyboardShortcut(.defaultAction)
        }
        .padding(.horizontal, 20).padding(.vertical, 12)
    }
}
