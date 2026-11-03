import SwiftUI
import AppKit

// Motion values after BoardUI (MIT): agent-log reveal (6pt blur, 4pt lift,
// 0.42s on cubic (0.22, 1, 0.36, 1)). Numbers ported, no code taken. The work ledger ("Thinking", "Worked for 12s",
// the phase rows) and the thinking dots were removed (no status lines in the chat).
let softEase = Animation.timingCurve(0.22, 1, 0.36, 1, duration: 0.42)

private struct BlurReveal: ViewModifier {
    let hidden: Bool
    func body(content: Content) -> some View {
        content.blur(radius: hidden ? 6 : 0).offset(y: hidden ? 4 : 0).opacity(hidden ? 0 : 1)
    }
}

extension AnyTransition {
    static var blurReveal: AnyTransition {
        .modifier(active: BlurReveal(hidden: true), identity: BlurReveal(hidden: false))
    }
}

func formatDuration(_ ms: Int?) -> String? {
    guard let ms, ms > 0 else { return nil }
    let s = max(1, Int((Double(ms) / 1000).rounded()))
    return s < 60 ? "\(s)s" : "\(s / 60):\(String(format: "%02d", s % 60))"
}

/// The ledger's chevron (ai.js .tl__car): shown on hover or while open, turned over when open.
struct LedgerCaret: View {
    let open: Bool
    let hover: Bool
    var body: some View {
        LiaIcon("caret-down", size: 11).foregroundStyle(AppConfig.text4)
            .opacity(open || hover ? 1 : 0)
            .rotationEffect(.degrees(open ? 180 : 0))
            .animation(.easeOut(duration: 0.12), value: hover)
            .animation(.easeOut(duration: 0.15), value: open)
    }
}

struct LiveTurnView: View {
    let turn: LiveTurn
    let since: Date
    let ents: [String: ChatEntity]
    let onOpenBlock: (ChatBlock) -> Void
    var auth: AuthStore? = nil
    var widgets = WidgetActions()
    /// A11Y-04: the conversation's text size (1 outside the conversation sheet).
    @Environment(\.liaTextScale) private var scale

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // No "Thinking" / tool-step lines in the chat; "<Name> is writing" (ChatTypingIndicator) is the
            // only sign of work. The timeline stays in the data (the agent's log, the dock, the menu bar).
            let memo = MemorySaved.items(turn.blocks)
            if !memo.isEmpty { MemoryLine(items: memo) }
            AnswerBlocks(blocks: turn.blocks, after: false, auth: auth, onOpenBlock: onOpenBlock, widgets: widgets)
                .transition(.blurReveal)
            if !turn.text.isEmpty { MarkdownView(text: turn.text, ents: ents.merging(turn.ents) { _, n in n }) }
            AnswerBlocks(blocks: turn.blocks, after: true, auth: auth, onOpenBlock: onOpenBlock, widgets: widgets)
                .transition(.blurReveal)
            if let e = turn.error {
                Text("Something went wrong: \(e). Try again.").font(LiaFont.ui((14 * scale).rounded())).foregroundStyle(AppConfig.bad)
            }
        }
        .animation(softEase, value: turn.blocks.count)
    }
}
