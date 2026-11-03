import SwiftUI
import AppKit
import WebKit

// P2 round (docs/UX-BACKLOG.md): the window's extra layers in one place, so WorkspaceWindow keeps one line per
// Feature: the screenshot card, the notes panel, the site style editor, the diagnostics
// Sheet, the agent beside the page and the compact top bar's state.

/// The window's extra state. One window (the workspace window is the only one), so one shared object: tab menus,
/// the top bar and the stage reach it without threading it through every view.
@MainActor
final class WSExtras: ObservableObject {
    static let shared = WSExtras()

    /// The workspace's notes panel.
    @Published var notesOpen = false
    /// The web panel at the right of the page.
    @Published var panelOpen = false
    /// The last screenshot, shown in its floating card.
    @Published var shot: WSShot?
    /// The site whose style is being edited.
    @Published var boost: WSBoostTarget?
    /// Liaison://perf
    @Published var perfOpen = false
    /// The agent whose own browser is shown beside the page (nil: none).
    @Published var agentBeside: String?
    /// The compact top bar is out (the pointer reached the top edge).
    @Published var compactShown = false

    /// Roughly the launch (the first time the window asked for this object).
    let since = Date()
}

/// The site and the tab it was opened from (the tab reloads to preview).
struct WSBoostTarget: Identifiable {
    let id = UUID()
    let host: String
    weak var tab: BrowserTab?
}

/// The window's extra layers and the \u{2318}\u{21E7}2 shortcut.
struct WSExtrasHost: ViewModifier {
    @ObservedObject var ws: WorkspaceModel
    @ObservedObject private var extras = WSExtras.shared
    @Environment(\.accessibilityReduceMotion) private var reduce

    func body(content: Content) -> some View {
        content
            .overlay(alignment: .bottomTrailing) { shotLayer }
            .overlay(alignment: .topTrailing) { notesLayer }
            .background { screenshotShortcut }
            .animation(WSMotion.navigation(reduce), value: extras.shot?.id)
            .animation(WSMotion.navigation(reduce), value: extras.notesOpen)
            .liaModal(item: $extras.boost) { t in BoostEditor(target: t) { extras.boost = nil } }
            .liaModal(isPresented: $extras.perfOpen) { PerfSheet(ws: ws) { extras.perfOpen = false } }
            .onChange(of: ws.profileId) { _, _ in extras.agentBeside = nil }
    }

    @ViewBuilder private var shotLayer: some View {
        if let s = extras.shot {
            ScreenshotCard(shot: s, ws: ws) { extras.shot = nil }
                .padding(.trailing, 22)
                .padding(.bottom, 120)
                .transition(reduce ? AnyTransition.opacity : AnyTransition.move(edge: .trailing).combined(with: .opacity))
                .id(s.id)
        }
    }

    @ViewBuilder private var notesLayer: some View {
        if extras.notesOpen, let pid = ws.profileId {
            WorkspaceNotesPanel(ws: ws, profileId: pid, name: ws.profile?.name ?? "") { extras.notesOpen = false }
                .id(pid)
                .padding(.trailing, 22)
                .padding(.top, AppConfig.barHeight + 14)
                .transition(reduce ? AnyTransition.opacity : AnyTransition.move(edge: .top).combined(with: .opacity))
        }
    }

    /// \u{2318}\u{21E7}2 until the menu has its own item ("Take Screenshot").
    private var screenshotShortcut: some View {
        Button("") { if let t = ws.currentBrowser?.selected { WSScreenshot.take(t) } }
            .keyboardShortcut("2", modifiers: [.command, .shift])
            .buttonStyle(.liaPlain)
            .opacity(0)
            .frame(width: 0, height: 0)
            .accessibilityHidden(true)
    }
}

/// The top bar's own extra buttons: notes and the web panel.
struct WSBarExtras: View {
    @ObservedObject var ws: WorkspaceModel
    @ObservedObject private var extras = WSExtras.shared
    @Environment(\.accessibilityReduceMotion) private var reduce

    var body: some View {
        HStack(spacing: 2) {
            barButton("note.text", on: extras.notesOpen,
                      label: extras.notesOpen ? "Hide notes" : "Notes for this workspace") { extras.notesOpen.toggle() }
                .background(AnchorReader(box: WSNotesOutside.trigger))
            barButton("sidebar.right", on: extras.panelOpen,
                      label: extras.panelOpen ? "Hide side panel" : "Side panel") {
                withAnimation(WSMotion.navigation(reduce)) { extras.panelOpen.toggle() }
            }
        }
        .disabled(ws.profile == nil)
    }

    private func barButton(_ symbol: String, on: Bool, label: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 12.5, weight: .semibold))
                .foregroundStyle(on ? WS.ink : WS.text2)
                .frame(width: 30, height: 30)
                .background(on ? WS.surface.opacity(0.85) : Color.clear, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                // The whole 30 pt square takes the click: a plain button with a clear ground answered only on the
                // glyph, so a click beside it did nothing (notes did not open on the first click).
                .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .buttonStyle(.liaPlain)
        .liaHover(.icon, radius: 10)
        .accessibilityLabel(Text(label))
        .accessibilityAddTraits(on ? .isSelected : [])
    }
}

// MARK: - the tab menu's extra items

extension Notification.Name {
    /// Object: the tab's uuid string. Its pill (or its sidebar row) turns into the rename field.
    static let wsRenameTab = Notification.Name("wsRenameTab")
}

/// Items every tab menu shows (the row's and the vertical sidebar's): rename, screenshot, site style.
struct WindowTabExtraItems: View {
    let tab: BrowserTab
    let ws: WorkspaceModel

    var body: some View {
        Button("Rename Tab\u{2026}") {
            NotificationCenter.default.post(name: .wsRenameTab, object: tab.id.uuidString)
        }
        if tab.customTitle != nil {
            Button("Use Page Title") {
                tab.customTitle = nil
                ws.currentBrowser?.saveTabs()
            }
        }
        Button("Take Screenshot") { WSScreenshot.take(tab) }
            .disabled(tab.isStart)
        Button("Edit Site Style\u{2026}") {
            if let h = tab.url?.host { WSExtras.shared.boost = WSBoostTarget(host: Self.siteHost(h), tab: tab) }
        }
        .disabled(tab.isStart || tab.url?.host == nil)
    }

    /// "www.example.com" edits example.com (Boosts match by suffix).
    static func siteHost(_ h: String) -> String {
        let l = h.lowercased()
        return l.hasPrefix("www.") ? String(l.dropFirst(4)) : l
    }
}

/// "Agent Beside Me": an agent's own browser in a pane at the right of the page (read-only).
struct WindowAgentBesideMenu: View {
    let ws: WorkspaceModel

    var body: some View {
        let agents = ws.roster.filter { !$0.soon && !$0.lead }
        let cur = WSExtras.shared.agentBeside
        if !agents.isEmpty, ws.profile != nil {
            Menu("Agent Beside Me") {
                ForEach(agents) { a in
                    Button { WSExtras.shared.agentBeside = cur == a.id ? nil : a.id } label: {
                        if cur == a.id { Label("\(a.name)\u{2019}s Browser", systemImage: "checkmark") } else { Text("\(a.name)\u{2019}s Browser") }
                    }
                }
                if cur != nil {
                    Divider()
                    Button("Close Agent Pane") { WSExtras.shared.agentBeside = nil }
                }
            }
        }
    }
}
