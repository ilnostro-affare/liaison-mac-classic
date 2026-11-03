import SwiftUI

/// A copy job on Meta's side, as it runs ("Copying 3 of 5") and where it stopped if it failed. Since
/// The conversation shows it only once it stopped (no running status lines in the chat).
struct ChatJobProgress: View {
    let progress: TeamChatModel.JobProgress

    private var fraction: Double { progress.total > 0 ? Double(progress.done) / Double(progress.total) : 0 }
    private var title: String {
        if let e = progress.error {
            return progress.total > 0 ? "\(progress.done) of \(progress.total) copied \u{00B7} stopped: \(e)" : "Stopped: \(e)"
        }
        return progress.total > 0 ? "Copying \(progress.done) of \(progress.total)\u{2026}" : "Copying\u{2026}"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(LiaFont.ui(13, .medium)).foregroundStyle(progress.error == nil ? WS.text2 : WS.bad)
            if progress.total > 0 {
                ProgressView(value: fraction).progressViewStyle(.linear).tint(progress.error == nil ? WS.ink : WS.bad)
            }
        }
        .frame(maxWidth: 396, alignment: .leading)
        .chatCard()
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text(title))
    }
}
