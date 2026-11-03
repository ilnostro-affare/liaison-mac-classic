import SwiftUI

/// (/02/03/06): the workspace's commands in the macOS menu bar, with the browser's usual keys, so they
/// can be found in the menus and in Help's search. They act on the window in front (WorkspaceModel.current).
struct WorkspaceCommands: Commands {
    @Environment(\.openWindow) private var openWindow
    /// The workspace window's commands do nothing while a private window is in front.
    /// Settings (its own NSWindow) counts too: \u{2318}W / \u{2318}T there must not act on the hidden workspace.
    @MainActor private var privateInFront: Bool {
        guard let id = NSApp.keyWindow?.identifier?.rawValue else { return false }
        return id.hasPrefix("private") || id == "lia-settings"
    }
    @MainActor private var ws: WorkspaceModel? { privateInFront ? nil : WorkspaceModel.current }
    @MainActor private var browser: BrowserModel? { ws?.currentBrowser }
    @MainActor private var tab: BrowserTab? { ws?.currentBrowser?.selected }

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("New Tab") { _ = browser?.openHome() }.keyboardShortcut("t")
            Button("New Private Window") { openWindow(id: "private") }.keyboardShortcut("n", modifiers: [.command, .shift])
            Button("Reopen Closed Tab") { browser?.reopenClosed() }.keyboardShortcut("t", modifiers: [.command, .shift])
            Button("Import from Another Browser\u{2026}") { ws?.showImport = true }
            Button("Open Location\u{2026}") { ws?.addressFocus += 1 }.keyboardShortcut("l")
            Button("Command Palette\u{2026}") { ws?.palette = .commands }.keyboardShortcut("k")
            Button("Search Tabs\u{2026}") { ws?.palette = .tabs }.keyboardShortcut("a", modifiers: [.command, .shift])
            Divider()
            // This \u{2318}W shadows the system's Close: in a private window or Settings it closes that window.
            Button("Close Tab") {
                if privateInFront { NSApp.keyWindow?.performClose(nil) } else if let b = browser, let t = b.selected { b.close(t) }
            }
            .keyboardShortcut("w")
        }
        // The system's own Print item (also \u{2318}P) is replaced, so the key has one owner.
        CommandGroup(replacing: .printItem) {
            Button("Print\u{2026}") { tab?.printPage() }.keyboardShortcut("p")
        }
        CommandGroup(after: .pasteboard) {
            Button("Copy Link") {
                guard let u = tab?.url?.absoluteString else { return }
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(u, forType: .string)
                ws?.show("Link copied", symbol: "link")
            }
            .keyboardShortcut("c", modifiers: [.command, .shift])
        }
        CommandGroup(replacing: .textEditing) {
            Button("Find\u{2026}") {
                // With a conversation open, \u{2318}F searches the conversation.
                if let w = ws, w.sheet != nil { w.chatFind += 1 } else { ws?.openFind() }
            }
            .keyboardShortcut("f")
            Button("Find Next") { ws?.findStep(backwards: false) }.keyboardShortcut("g")
            Button("Find Previous") { ws?.findStep(backwards: true) }.keyboardShortcut("g", modifiers: [.command, .shift])
        }
        CommandGroup(before: .toolbar) {
            Button("Reload Page") { tab?.reload() }.keyboardShortcut("r")
            Button("Reload Page From Origin") { tab?.reload(fromOrigin: true) }.keyboardShortcut("r", modifiers: [.command, .shift])
            Divider()
            Button("Zoom In") { tab?.zoomIn() }.keyboardShortcut("+")
            Button("Zoom In") { tab?.zoomIn() }.keyboardShortcut("=")   // \u{2318}= on keyboards without a + key
            Button("Zoom Out") { tab?.zoomOut() }.keyboardShortcut("-")
            Button("Actual Size") { tab?.zoomReset() }.keyboardShortcut("0")
            Divider()
            Button("Show Reader") { if let w = ws, let t = tab { ReaderCenter.shared.show(t, ws: w) } }.keyboardShortcut("r", modifiers: [.command, .option])
            Button("Picture in Picture") { if let w = ws, let t = tab { ReaderCenter.shared.pictureInPicture(t, ws: w) } }
            // 0.2.11: on-device translation (PageTranslator); the same toggle as the tab's Translate button.
            Button("Translate Page") { if let w = tab?.loadedWebView { PageTranslateCenter.shared.model(for: w).translate() } }
            Button("Show Original") { if let w = tab?.loadedWebView { PageTranslateCenter.shared.existing(w)?.showOriginal() } }
            Button("Translate Selection") { if let w = tab?.loadedWebView { PageTranslateCenter.shared.model(for: w).translateSelection() } }
            Divider()
            Button("Notes") { WSExtras.shared.notesOpen.toggle() }
            Button("Side Panel") { WSExtras.shared.panelOpen.toggle() }
            Button("Take Screenshot") { if let t = tab { WSScreenshot.take(t) } }   // \u{2318}\u{21E7}2 in the window
            Button("Vertical Tabs") { UserDefaults.standard.set(!Prefs.flag(Prefs.verticalTabs, default: false), forKey: Prefs.verticalTabs) }
            Button("Compact Mode") { UserDefaults.standard.set(!Prefs.flag(Prefs.compactMode, default: false), forKey: Prefs.compactMode) }
            Divider()
            Button("Downloads") { ws?.showDownloads.toggle() }.keyboardShortcut("l", modifiers: [.command, .option])
            Divider()
        }
        CommandMenu("History") {
            Button("Show All History") { ws?.showHistory = true }.keyboardShortcut("y")
            Divider()
            Button("Back") { tab?.webView.goBack() }.keyboardShortcut("[")
            Button("Forward") { tab?.webView.goForward() }.keyboardShortcut("]")
        }
        CommandMenu("Tabs") {
            Button("Pin or Unpin Tab") { if let b = browser, let t = b.selected { b.setPinned(t, !t.pinned) } }.keyboardShortcut("d")
            Button("Mute or Unmute Tab") { if let t = tab { t.setMuted(!t.muted) } }.keyboardShortcut("m", modifiers: [.command, .shift])   // \u{2325}\u{2318}M is Minimize All
            Button("Show Tab Overview") { NotificationCenter.default.post(name: .wsTabOverview, object: nil) }   // \u{2318}\u{21E7}\\ in the window
            Button("Split With New Tab") { if let b = browser { b.splitID == nil ? b.split() : b.unsplit() } }.keyboardShortcut("n", modifiers: [.command, .option])
            Divider()
            Button("Show Next Tab") { browser?.selectNext(true) }.keyboardShortcut(.rightArrow, modifiers: [.command, .option])
            Button("Show Previous Tab") { browser?.selectNext(false) }.keyboardShortcut(.leftArrow, modifiers: [.command, .option])
            // \u{2303}Tab goes through tabs in the order they were last used (the switcher shows while \u{2303} is held).
            Button("Recent Tabs") { ws?.mruStep(true) }.keyboardShortcut(.tab, modifiers: .control)
            Button("Recent Tabs Backwards") { ws?.mruStep(false) }.keyboardShortcut(.tab, modifiers: [.control, .shift])
            Divider()
            ForEach(0..<9, id: \.self) { i in
                Button(i == 8 ? "Last Tab" : "Tab \(i + 1)") { browser?.select(index: i) }
                    .keyboardShortcut(KeyEquivalent(Character(String(i + 1))), modifiers: .command)
            }
        }
        CommandMenu("Workspaces") {
            Button("Next Workspace") { ws?.selectNextProfile(true) }.keyboardShortcut(.rightArrow, modifiers: [.control, .option])
            Button("Previous Workspace") { ws?.selectNextProfile(false) }.keyboardShortcut(.leftArrow, modifiers: [.control, .option])
            Divider()
            ForEach(0..<9, id: \.self) { i in
                Button("Workspace \(i + 1)") { ws?.selectIndex(i) }
                    .keyboardShortcut(KeyEquivalent(Character(String(i + 1))), modifiers: .control)
            }
            Divider()
            Button("Workspace Settings\u{2026}") { if let w = ws, let p = w.profile { w.editingProfile = p } }
        }
        CommandMenu("Agents") {
            Button("Ask Lia About Selection") { ws?.askAboutSelection() }.keyboardShortcut("e")
            Button("Lia Chat") {
                guard let w = ws else { return }
                if w.sheet == "team" { w.sheet = nil } else { w.openTeam() }
            }
            .keyboardShortcut("j")
            Divider()
            ForEach(Array(AgentInfo.fallback.filter { !$0.lead }.prefix(7).enumerated()), id: \.offset) { i, a in
                Button(a.name) { ws?.openAgent(a.id) }
                    .keyboardShortcut(KeyEquivalent(Character(String(i + 1))), modifiers: [.command, .option])   // \u{2318}\u{21E7}3-5 belong to macOS screenshots
            }
            Divider()
            Button("Journal") { if let w = ws { w.showJournal = true; Task { await w.loadJournal() } } }
        }
        CommandGroup(replacing: .help) {
            Button("Keyboard Shortcuts") { ws?.showShortcuts = true }.keyboardShortcut("/")
            // What is open goes first: its Esc / Return buttons would compete with the welcome's Skip and Continue.
            Button("Morning Tour") { if let w = ws { TourOverlay.start(w) } }
            Button("Show Welcome Again") { if let w = ws { w.sheet = nil; w.peek = nil; w.palette = nil; w.onboarding = true } }
        }
    }
}
