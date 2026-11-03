import SwiftUI

/// An agent's run mode as a small segmented control in our glass: the track and the selected
/// segment are the chrome's glass (the selected one `strong`, as the selected tab in the strip), never the system's
/// blue. One control for every dialogue that has modes: Team and Met (Auto / Manual approvals) and Dev (Auto /
/// Manual), always in the conversation's header.
struct GlassModeControl<Value: Hashable>: View {
    struct Option {
        let label: String
        let value: Value
        /// The segment's tip.
        let help: String
    }

    let options: [Option]
    @Binding var selection: Value
    /// What the control sets ("Approval mode", "Dev mode").
    let name: String

    @Namespace private var pill
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// The control sits on the theme's surface (the conversation header), not over the bar's tint,
    /// so `wsBarOnDark` is false there and the glass drew white in the dark theme. In dark it is the dark glass.
    @Environment(\.colorScheme) private var scheme
    @Environment(\.wsBarOnDark) private var barOnDark

    var body: some View {
        HStack(spacing: 2) {
            ForEach(options.indices, id: \.self) { i in
                segment(options[i])
            }
        }
        .padding(2)
        .background(Capsule().fill(WS.ink.opacity(0.05)))
        .chromeGlass(Capsule())
        .environment(\.wsBarOnDark, barOnDark || scheme == .dark)
        .fixedSize()
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text(name))
    }

    private func segment(_ o: Option) -> some View {
        let on = o.value == selection
        let weight: Font.Weight = on ? .semibold : .medium
        return Button {
            guard !on else { return }
            if reduceMotion { selection = o.value } else { withAnimation(.spring(response: 0.28, dampingFraction: 0.86)) { selection = o.value } }
        } label: {
            Text(o.label)
                .font(LiaFont.ui(12, weight))
                .foregroundStyle(on ? WS.ink : WS.text2)
                .lineLimit(1)
                .padding(.horizontal, 12).frame(height: 24)
                .background {
                    if on {
                        Color.clear
                            .chromeGlass(Capsule(), strong: true)
                            .matchedGeometryEffect(id: "pill", in: pill)
                    }
                }
                .contentShape(Capsule())
                // (Auto / Manual did not react to the pointer): the unselected segment takes
                // the wash in its own capsule; the selected one has nothing to do on a click and stays as it is.
                .liaHoverWash(Capsule(), enabled: !on)
        }
        .buttonStyle(.liaPlain)
        .liaPointer()
        .liaTip(o.help)
        .accessibilityLabel(Text(o.label))
        .accessibilityHint(Text(o.help))
        .accessibilityAddTraits(on ? .isSelected : [])
    }
}
