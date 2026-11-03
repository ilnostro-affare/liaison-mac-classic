import SwiftUI
import AppKit

// The last finished download on a mini card in the downloads popover's header: Open, Show in Finder.
// Apps and installers (.dmg .pkg .app .command .sh .exe ...) get an amber warning in their row and Open asks
// first (Chrome Safe Browsing's explanation, without its verdicts: we don't scan files).

@MainActor
enum WSDownloadSafety {
    static let risky: Set<String> = ["dmg", "pkg", "mpkg", "app", "command", "sh", "tool", "exe", "msi", "bat", "jar", "scpt", "workflow"]

    static func isRisky(_ item: DownloadsCenter.Item) -> Bool {
        let ext = (item.dest?.pathExtension ?? (item.name as NSString).pathExtension).lowercased()
        guard risky.contains(ext) else { return false }
        // Our own Liaison.dmg (liaisone.com and its subdomains, never a Dev site) is not warned about.
        return !DownloadSource.isOurs(item.sourceURL)
    }

    /// The site it came from, when the tab is still there.
    static func host(_ item: DownloadsCenter.Item) -> String {
        item.webView?.url?.host ?? "the site it came from"
    }

    static func warning(_ item: DownloadsCenter.Item) -> String {
        "Apps and installers can harm your Mac. Open only if you trust \(host(item))."
    }

    /// Open, asking first for an app or an installer.
    static func open(_ item: DownloadsCenter.Item) {
        guard item.state == .done else { return }
        guard isRisky(item) else { DownloadsCenter.shared.open(item); return }
        let a = NSAlert()
        a.alertStyle = .warning
        a.messageText = "Open \u{201C}\(item.name)\u{201D}?"
        a.informativeText = warning(item)
        a.addButton(withTitle: "Cancel")
        a.addButton(withTitle: "Open")
        if a.runModal() == .alertSecondButtonReturn { DownloadsCenter.shared.open(item) }
    }
}

/// The amber line under a risky finished download's name.
struct DownloadRiskLine: View {
    @ObservedObject var item: DownloadsCenter.Item

    var body: some View {
        if item.state == .done, WSDownloadSafety.isRisky(item) {
            HStack(alignment: .top, spacing: 4) {
                Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 9)).foregroundStyle(WS.amber)
                Text(WSDownloadSafety.warning(item))
                    .font(LiaFont.ui(11)).foregroundStyle(WS.amberInk)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .accessibilityElement(children: .combine)
        }
    }
}

/// The newest finished download, with Open and Show in Finder (Send to Crea is gone).
struct LastDownloadCard: View {
    let ws: WorkspaceModel
    @ObservedObject private var center = DownloadsCenter.shared

    private var last: DownloadsCenter.Item? {
        center.items.filter { $0.state == .done && $0.dest != nil }.max { $0.started < $1.started }
    }

    var body: some View {
        if let it = last { LastDownloadFace(item: it) }
    }
}

private struct LastDownloadFace: View {
    @ObservedObject var item: DownloadsCenter.Item

    private var icon: NSImage {
        if let d = item.dest, FileManager.default.fileExists(atPath: d.path) { return NSWorkspace.shared.icon(forFile: d.path) }
        return NSWorkspace.shared.icon(forFile: "/")
    }

    var body: some View {
        HStack(spacing: 8) {
            Image(nsImage: icon).resizable().interpolation(.high).frame(width: 26, height: 26)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                Text("Last download").font(LiaFont.ui(10.5, .medium)).foregroundStyle(WS.text3)
                Text(item.name).font(LiaFont.ui(12.5, .semibold)).foregroundStyle(WS.ink).lineLimit(1).truncationMode(.middle)
            }
            Spacer(minLength: 6)
            Button("Open") { WSDownloadSafety.open(item) }
                .buttonStyle(DownloadMiniButtonStyle())
            Button { DownloadsCenter.shared.reveal(item) } label: {
                Image(systemName: "magnifyingglass").font(.system(size: 11, weight: .semibold))
            }
            .buttonStyle(DownloadMiniButtonStyle(square: true))
            .liaTip("Show in Finder")
            .accessibilityLabel(Text("Show in Finder"))
        }
        .padding(.horizontal, 10).padding(.vertical, 8)
        .background(WS.soft, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text("Last download, \(item.name)"))
    }
}

/// The downloads list's own small buttons: 22 pt high, a hairline and a soft press, the whole shape clickable.
struct DownloadMiniButtonStyle: ButtonStyle {
    var square = false

    func makeBody(configuration: Configuration) -> some View {
        DownloadMiniFace(configuration: configuration, square: square)
    }
}

private struct DownloadMiniFace: View {
    let configuration: ButtonStyleConfiguration
    let square: Bool
    @Environment(\.isEnabled) private var enabled
    @State private var hover = false

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 6, style: .continuous)
        configuration.label
            .font(LiaFont.ui(11.5, .medium))
            .foregroundStyle(enabled ? WS.ink : WS.text3)
            .padding(.horizontal, square ? 0 : 9)
            .frame(width: square ? 22 : nil, height: 22)
            .background(configuration.isPressed ? WS.line2 : (hover ? WS.soft : WS.surface), in: shape)
            .overlay(shape.stroke(WS.line2, lineWidth: 0.5))
            .contentShape(shape)
            .onHover { hover = $0 }
            .liaPointer()
    }
}
