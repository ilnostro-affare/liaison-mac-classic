import SwiftUI

/// A file or a picture opened FROM THE INPUT (a composer chip) opens on the right, over the
/// preview and the web, not in a popup. The right pane (CanvasPane) carries `ComposerFileOverlay` as an overlay; while
/// one is on screen, `ComposerFileViewer.shared.show(item)` puts the file there and answers true, and the tray opens its
/// popup only when no pane took it (no browser open, an older layout).
///
/// Wiring (CanvasPane.swift, owned by another round): on the pane's outermost view,
/// .overlay { ComposerFileOverlay(auth: auth) }
/// Nothing else: the overlay registers itself while it is on screen and closes with Esc or its close button.
/// A document from the chips opens on the right even when nothing is there (no Dev canvas, no agent
/// browser): the conversation sheet `.holdsComposerFiles` and, while `item` is set, shows a right side of its own
/// carrying the overlay (ConversationSheet's right-side Group). The agent's browser carries the overlay too.
@MainActor
final class ComposerFileViewer: ObservableObject {
    static let shared = ComposerFileViewer()
    @Published private(set) var item: AttachmentPreviewPopup.Item?
    /// Overlays on screen (one per window's right pane).
    private var hosts = 0
    /// Views that open a right side of their own for a file (the conversation sheet).
    private var holders = 0

    /// Shows `item` over the right pane; false when no pane is on screen and nothing opens one (the caller opens its
    /// popup instead).
    @discardableResult
    func show(_ item: AttachmentPreviewPopup.Item) -> Bool {
        guard hosts > 0 || holders > 0 else { return false }
        self.item = item
        return true
    }

    fileprivate func hold() { holders += 1 }
    fileprivate func release() {
        holders = max(0, holders - 1)
        if holders == 0 && hosts == 0 { item = nil }
    }

    func close() { item = nil }

    fileprivate func attach() { hosts += 1 }
    fileprivate func detach() {
        hosts = max(0, hosts - 1)
        // A holder's own right side comes and goes with the item: switching panes must not close the file.
        if hosts == 0 && holders == 0 { item = nil }
    }
}

/// The file over the right pane: the attachment preview filling the pane, with its own close.
struct ComposerFileOverlay: View {
    var auth: AuthStore? = nil
    @ObservedObject private var viewer = ComposerFileViewer.shared

    var body: some View {
        ZStack {
            if let item = viewer.item {
                AttachmentPreviewPopup(item: item, auth: auth, fill: true)
                    .environment(\.liaDismiss, LiaDismissAction(run: { ComposerFileViewer.shared.close() }))
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(WS.line, lineWidth: 1))
                    .padding(8)
                    .transition(.opacity)
                    .onExitCommand { ComposerFileViewer.shared.close() }
                    .id(item.id)
            }
        }
        .animation(.easeOut(duration: 0.15), value: viewer.item?.id)
        .onAppear { viewer.attach() }
        .onDisappear { viewer.detach() }
    }
}

extension View {
    /// The view opens a right side for a composer file when no pane is there (see ComposerFileViewer).
    func holdsComposerFiles() -> some View {
        onAppear { ComposerFileViewer.shared.hold() }
            .onDisappear { ComposerFileViewer.shared.release() }
    }
}
