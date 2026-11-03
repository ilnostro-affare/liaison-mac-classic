import SwiftUI
import AppKit

/// The extensions' buttons at the right end of the tab group: one 26 pt button per enabled extension with an action
/// (its action icon, its badge). A click asks WebKit to perform the action; a popup comes back through the delegate
/// and opens under the button (the anchor registered here). Empty (no width) when nothing is installed or before
/// macOS 15.4.
struct ExtensionsBar: View {
    @ObservedObject var browser: BrowserModel
    @ObservedObject private var host = ExtensionsHost.shared

    var body: some View {
        HStack(spacing: 0) {
            ForEach(host.actionItems()) { item in
                ExtensionActionButton(item: item)
            }
        }
        .onAppear { host.follow(browser) }
        .onChange(of: ObjectIdentifier(browser)) { _, _ in host.follow(browser) }
    }
}

private struct ExtensionActionButton: View {
    let item: ExtensionsHost.ActionItem

    var body: some View {
        Button { ExtensionsHost.shared.performAction(item.id) } label: { face }
            .buttonStyle(.liaPlain)
            .background(ExtensionAnchor(id: item.id))
            .liaHover(.icon, radius: 8)
            .liaTip(item.label)
            .opacity(item.enabled ? 1 : 0.45)
            .accessibilityLabel(Text(item.label))
    }

    private var face: some View {
        ZStack(alignment: .bottomTrailing) {
            glyph.frame(width: 26, height: 26)
            if !item.badge.isEmpty { ExtensionBadge(text: item.badge) }
        }
        .frame(width: 26, height: 26)
    }

    @ViewBuilder private var glyph: some View {
        if let img = item.icon {
            Image(nsImage: img).resizable().interpolation(.high).frame(width: 16, height: 16)
        } else {
            Image(systemName: "puzzlepiece.extension").font(.system(size: 12, weight: .semibold)).foregroundStyle(WS.text2)
        }
    }
}

private struct ExtensionBadge: View {
    let text: String

    var body: some View {
        Text(text.count > 4 ? String(text.prefix(4)) : text)
            .font(.system(size: 8, weight: .bold))
            .foregroundStyle(Color.white)
            .padding(.horizontal, 3)
            .frame(minWidth: 12, minHeight: 11)
            .background(Capsule().fill(WS.red))
            .offset(x: 1, y: 1)
            .allowsHitTesting(false)
    }
}

/// An empty NSView behind the button: the action's popover points at it.
private struct ExtensionAnchor: NSViewRepresentable {
    let id: String

    func makeNSView(context: Context) -> NSView {
        let v = NSView()
        ExtensionsHost.shared.setAnchor(v, for: id)
        return v
    }

    func updateNSView(_ v: NSView, context: Context) { ExtensionsHost.shared.setAnchor(v, for: id) }
}
