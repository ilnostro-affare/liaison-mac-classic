import SwiftUI

/// Under an agent's acknowledgement in another agent's dialogue ("Got it, I'll answer in our
/// chat") - where the work goes on. A click opens that agent's dialogue at the task.
/// ("a strange chip ... 'working' in purple ... remove them entirely"): no status words any more - the link
/// only. The same link stands under a handed task's first row in its owner's dialogue, back to where it was asked
/// ("Asked in Lia's dialogue"), on the side of the bubble it belongs to.
struct ChatAckLink: View {
    /// The agent whose colour the link takes (the dialogue it opens).
    let agent: AgentInfo
    /// What the link says; nil: "Open in <agent>'s dialogue".
    var caption: String? = nil
    /// The person's bubble is on the right: its link too.
    var trailing = false
    let onOpen: () -> Void

    private var text: String { caption ?? "Open in \(agent.name)'s dialogue" }

    var body: some View {
        Button(action: onOpen) {
            HStack(spacing: 5) {
                Image(systemName: trailing ? "arrow.turn.up.left" : "arrow.turn.down.right").font(.system(size: 10, weight: .semibold))
                Text(text).font(LiaFont.ui(11.5, .medium)).lineLimit(1).truncationMode(.tail)
            }
            .frame(maxWidth: 320, alignment: trailing ? .trailing : .leading)
            .fixedSize(horizontal: false, vertical: true)
            .foregroundStyle(Color(hex: agent.colorHex))
            .padding(.horizontal, 9).padding(.vertical, 4)
            .background(WS.soft, in: Capsule())
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .padding(.leading, trailing ? 0 : 38)   // under the bubble, past the agent's figure (30 + 8)
        .padding(.trailing, trailing ? 6 : 0)
        .padding(.top, 4)
        .frame(maxWidth: .infinity, alignment: trailing ? .trailing : .leading)
        .help(text)
        .accessibilityLabel(Text(text))
    }

    /// "Asked in Lia's dialogue" (Team is Lia's).
    static func askedIn(_ name: String) -> String { "Asked in \(name)'s dialogue" }
}
