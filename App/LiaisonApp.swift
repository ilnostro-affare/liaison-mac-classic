import SwiftUI
import TipKit

@main
struct LiaisonApp: App {
    @StateObject private var auth = AuthStore()
    @AppStorage("lia_theme") private var theme = ThemeSetting.auto.rawValue
    @ObservedObject private var live = MenuBarStatus.shared
    private var menuBarShown: Binding<Bool> { Binding(get: { live.visible }, set: { _ in }) }

    init() {
        LiaFont.registerBundled()
        // Our own tabs and workspaces; no system window tabs (no "Show Tab Bar", no merged windows).
        NSWindow.allowsAutomaticWindowTabbing = false
        // In-context tips (TipKit), each shown once.
        LiaTips.configureAtLaunch()
        Trackers.prepare()
        // Was the last run cut short? (set back to true when the app quits normally)
        let d = UserDefaults.standard
        CrashNotice.previousRunCrashed = d.object(forKey: Prefs.cleanExit) != nil && !d.bool(forKey: Prefs.cleanExit)
        d.set(false, forKey: Prefs.cleanExit)
        NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { _ in
            UserDefaults.standard.set(true, forKey: Prefs.cleanExit)
        }
        Updates.shared.start()
        // The agents at work around the MacBook's notch (nothing on a Mac without one; UserDefaults `notchIsland`).
        Task { @MainActor in NotchIsland.shared.install() }
        // The screenshot card for the Mac's own screenshots (saved files; the clipboard is only logged; Settings > Notifications).
        Task { @MainActor in ScreenshotWatcher.shared.start() }
    }

    var body: some Scene {
        WindowGroup("Liaison", id: "main") {
            RootView()
                .environmentObject(auth)
                .preferredColorScheme(ThemeSetting(rawValue: theme)?.scheme)
                // The theme also drives the app's NSAppearance, so every window, panel, menu and popover
                // (and "System" after a forced Dark/Light, which preferredColorScheme(nil) alone does not undo) follows.
                .onAppear { ThemeSetting(rawValue: theme)?.applyToApp() }
                .onChange(of: theme) { _, t in ThemeSetting(rawValue: t)?.applyToApp() }
                .frame(minWidth: 1100, minHeight: 680)
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1512, height: 900)
        .commands { LiaCommands(); WorkspaceCommands() }

        // Instead of Live Activities (no macOS API): the agents at work in the menu bar, while anything runs or waits.
        MenuBarExtra(isInserted: menuBarShown) { LiveStatusMenu() } label: { LiveStatusLabel() }
            .menuBarExtraStyle(.window)

        // A private window (nothing kept, no agents). Links from other apps never open one.
        WindowGroup("Private Window", id: "private") { PrivateBrowserWindow() }
            .windowStyle(.hiddenTitleBar)
            .defaultSize(width: 1100, height: 760)
            .handlesExternalEvents(matching: [])
    }
}

extension ThemeSetting {
    /// System: nil (the Mac's own appearance); Light / Dark: that appearance for the whole app.
    @MainActor func applyToApp() {
        switch self {
        case .auto: NSApp.appearance = nil
        case .light: NSApp.appearance = NSAppearance(named: .aqua)
        case .dark: NSApp.appearance = NSAppearance(named: .darkAqua)
        }
    }
}

/// Signed out, or the server ended the session: the sign-in (the account stays saved). Signed in: the window,
/// rebuilt when the account changes.
struct RootView: View {
    @EnvironmentObject private var auth: AuthStore

    var body: some View {
        if auth.phase == .signedOut || auth.sessionExpired {
            SignInView()
        } else {
            SignedInRoot(auth: auth).id(auth.activeId)
        }
    }
}

private struct SignedInRoot: View {
    @StateObject private var app: AppModel
    private let auth: AuthStore
    init(auth: AuthStore) { self.auth = auth; _app = StateObject(wrappedValue: AppModel(auth: auth)) }

    var body: some View {
        Group {
            // The app is only the workspace (browser + agent team); the classic chat is the web's.
            WorkspaceWindow(auth: auth)
        }
        .environmentObject(app)
        .focusedSceneObject(app)
        // A creator code from the sign-up, delivered once the session is up (or on a later launch)
        .task { await CreatorCodeSync.flush(auth: auth) }
    }
}

/// ⌘N new chat, ⌘K search, ⌘, settings, ⌘⇧R Relay, ⌘T new browser tab (ai.js has none; these are the Mac's).
struct LiaCommands: Commands {
    @FocusedObject private var app: AppModel?

    var body: some Commands {
        CommandGroup(after: .appInfo) {
            Button("Check for Updates\u{2026}") { Updates.shared.check() }.disabled(!Updates.shared.configured)
        }
        CommandGroup(replacing: .appSettings) {
            Button("Settings\u{2026}") { app?.openSettings() }.keyboardShortcut(",").disabled(app == nil)
        }
        CommandMenu("Develop") {
            // The browser benchmark (WebVoyager / Online-Mind2Web tasks) in the current chat's browser
            Button("Run Browser Benchmark\u{2026}") { if let app { BenchRunner.shared.choose(app: app) } }.disabled(app == nil)
            Button("Stop Browser Benchmark") { BenchRunner.shared.stop() }
        }
    }
}
