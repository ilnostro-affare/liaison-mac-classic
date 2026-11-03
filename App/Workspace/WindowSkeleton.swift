import SwiftUI

// Skeletons instead of spinners for native lists (History) and tab pictures (tab overview).
// A soft shimmer runs across them; with Reduce Motion they stay still.

extension View {
    /// A light band sweeping across the view's own shape (static with Reduce Motion).
    func wsShimmer() -> some View { modifier(WSShimmer()) }
}

private struct WSShimmer: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduce
    @State private var phase: CGFloat = -1

    func body(content: Content) -> some View {
        content
            .overlay { band }
            .mask { content }
            .onAppear {
                guard !reduce else { return }
                withAnimation(.easeInOut(duration: 1.4).repeatForever(autoreverses: false)) { phase = 1 }
            }
    }

    @ViewBuilder private var band: some View {
        if !reduce {
            GeometryReader { g in
                LinearGradient(colors: [WS.shimmer.opacity(0), WS.shimmer, WS.shimmer.opacity(0)],
                               startPoint: .leading, endPoint: .trailing)
                    .frame(width: g.size.width * 0.4)
                    .offset(x: phase * g.size.width)
            }
            .allowsHitTesting(false)
        }
    }
}

/// One grey placeholder shape.
struct WSSkeletonBlock: View {
    var width: CGFloat? = nil
    var height: CGFloat
    var radius: CGFloat = 6

    var body: some View {
        RoundedRectangle(cornerRadius: radius, style: .continuous)
            .fill(WS.soft)
            .frame(width: width, height: height)
    }
}

/// Rows shaped like history rows (icon, title, host, time) while the list loads.
struct WSSkeletonRows: View {
    var count = 9
    private static let titles: [CGFloat] = [220, 300, 180, 260, 240, 160, 280, 200, 230]

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            WSSkeletonBlock(width: 70, height: 10).padding(.horizontal, 8).padding(.top, 16).padding(.bottom, 8)
            ForEach(0..<count, id: \.self) { i in row(i) }
        }
        .wsShimmer()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("Loading"))
    }

    private func row(_ i: Int) -> some View {
        HStack(spacing: 10) {
            WSSkeletonBlock(width: 16, height: 16, radius: 4)
            WSSkeletonBlock(width: Self.titles[i % Self.titles.count], height: 11)
            WSSkeletonBlock(width: 90, height: 10)
            Spacer(minLength: 8)
            WSSkeletonBlock(width: 44, height: 10)
        }
        .padding(.horizontal, 8)
        .frame(height: 34)
    }
}
