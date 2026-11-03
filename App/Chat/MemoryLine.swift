import SwiftUI

/// "Saved to memory" (ai.js memLineHTML 3145, -i): one folded line per turn, above the cards and the answer.
/// Closed by default; open, each fact in curly quotes with where it went. Nothing in the chat edits memory.
struct MemoryLine: View {
    let items: [MemorySaved]
    @State private var open = false
    @State private var hover = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button { withAnimation(.easeOut(duration: 0.18)) { open.toggle() } } label: {
                HStack(spacing: 7) {
                    // Under the pointer the line brightens a step.
                    LiaIcon("memory", size: 14).foregroundStyle(hover ? AppConfig.text2 : AppConfig.text3)
                    Text("Saved to memory").fontWeight(.bold).foregroundStyle(hover ? AppConfig.ink : AppConfig.text2)
                    if let n = MemorySaved.count(items.count) {
                        Text(n).fontWeight(.semibold).foregroundStyle(hover ? AppConfig.text3 : AppConfig.text4)
                    }
                    LedgerCaret(open: open, hover: hover)
                }
                .font(LiaFont.ui(12.5))
                .frame(minHeight: 22)
                .contentShape(Rectangle())
            }
            .buttonStyle(.liaPlain)
            .liaHover(.text, isHovered: $hover)
            .accessibilityLabel(items.count > 1 ? "Saved \(items.count) facts to memory" : "Saved to memory")

            if open {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(items.enumerated()), id: \.offset) { _, it in
                        VStack(alignment: .leading, spacing: 1) {
                            Text("\u{201c}" + it.text + "\u{201d}")
                                .font(LiaFont.ui(13)).foregroundStyle(AppConfig.text2).lineSpacing(2)
                                .fixedSize(horizontal: false, vertical: true)
                                .textSelection(.enabled)
                            Text(it.whereLine).font(LiaFont.ui(11, .semibold)).foregroundStyle(AppConfig.text4)
                        }
                        .padding(.vertical, 4)
                    }
                }
                .padding(.leading, 12)
                .overlay(alignment: .leading) { Rectangle().fill(AppConfig.line).frame(width: 2) }
                .padding(.top, 4).padding(.bottom, 2).padding(.leading, 2)
                .transition(.blurReveal)
            }
        }
        .padding(.bottom, 8)
    }
}
