import SwiftUI
import WebKit

// Browser extensions (password managers first: Bitwarden, then 1Password) through Apple's public WebKit API
// (WKWebExtension*, macOS 15.4+). One controller for the whole app; every tab's configuration gets it in
// `BrowserModel.configuration(account:)` via `attach(to:)`. The app targets macOS 14: every use of the API is behind
// `if #available(macOS 15.4, *)`, and behind `#if compiler(>=6.1)` so an SDK older than Xcode 16.3 still builds
// (Settings then says "Extensions need macOS 15.4 or later").
// Files: ExtensionsInstaller (folder/zip/crx/Chrome Web Store -> unpacked folder), ExtensionsTabs (our tabs and
// browsers as WKWebExtensionTab / WKWebExtensionWindow), ExtensionsToolbar (buttons in the tab group),
// Settings/SettingsExtensions (the pane).

/// One installed extension, as kept in Extensions/index.json.
struct InstalledExtension: Codable, Identifiable, Equatable {
    /// Folder name under Extensions/: the Chrome Web Store id when it has one.
    var id: String
    /// The context's `uniqueIdentifier` (and base URL host): stable, so the extension's storage survives restarts.
    var uid: String
    var name: String
    var version: String
    var enabled: Bool
    /// The person allowed what its manifest asks for (asked once, at install).
    var granted: Bool
    /// "store" or "file".
    var source: String
    var added: Date
}

@MainActor
final class ExtensionsHost: ObservableObject {
    static let shared = ExtensionsHost()

    @Published private(set) var installed: [InstalledExtension] = []
    /// An install in progress (its line), nil when idle.
    @Published private(set) var busy: String?
    /// The last failure, shown in Settings.
    @Published var problem: String?
    /// Ids loaded into the controller right now.
    @Published private(set) var loaded: Set<String> = []
    /// Bumped when an action's icon, badge or label changes (the toolbar redraws).
    @Published private(set) var revision = 0

    /// The API exists here (SDK and system).
    static var isSupported: Bool {
        #if compiler(>=6.1)
        if #available(macOS 15.4, *) { return true }
        #endif
        return false
    }

    /// The `ExtensionsEngine` (typed AnyObject: a stored property cannot carry an availability).
    private var engine: AnyObject?
    private var started = false
    /// The toolbar buttons, so an action's popover can point at its own button.
    private let anchors = NSMapTable<NSString, NSView>.strongToWeakObjects()

    private init() {
        installed = Self.readIndex()
    }

    #if compiler(>=6.1)
    /// Made on first use (the first tab's configuration, the toolbar or Settings).
    @available(macOS 15.4, *)
    private var core: ExtensionsEngine {
        if let e = engine as? ExtensionsEngine { return e }
        let e = ExtensionsEngine(host: self)
        engine = e
        return e
    }
    #endif

    // MARK: hook from BrowserModel

    /// Gives a new tab's configuration the app's extension controller (macOS 15.4+; nothing otherwise).
    func attach(to configuration: WKWebViewConfiguration) {
        #if compiler(>=6.1)
        if #available(macOS 15.4, *) {
            configuration.webExtensionController = core.controller
            start()
        }
        #endif
    }

    /// Loads the enabled extensions once per launch (the first tab, or Settings).
    func start() {
        guard Self.isSupported, !started else { return }
        started = true
        ExtensionsInstaller.cleanStaging()
        Task { @MainActor in
            for e in installed where e.enabled { await load(e) }
        }
    }

    // MARK: install / enable / remove

    func install(_ source: ExtensionsInstaller.Source) {
        guard Self.isSupported else { problem = "Extensions need macOS 15.4 or later."; return }
        guard busy == nil else { return }
        start()
        busy = "Installing\u{2026}"
        problem = nil
        Task { @MainActor in
            defer { busy = nil }
            do {
                let s = try await ExtensionsInstaller.stage(source)
                guard await confirm(s) else { ExtensionsInstaller.discard(s); return }
                let old = installed.first { $0.id == s.id }
                if old != nil { unloadContext(s.id) }
                _ = try ExtensionsInstaller.commit(s)
                let e = InstalledExtension(id: s.id, uid: old?.uid ?? UUID().uuidString.lowercased(), name: s.name, version: s.version,
                                           enabled: true, granted: true, source: s.source, added: old?.added ?? Date())
                upsert(e)
                await load(e)
            } catch {
                // 0.2.11: plain words; the installer's own failures already are, a file system error is not.
                NSLog("[extensions] install failed: %@", String(describing: error))
                problem = (error as? ExtensionsInstaller.Failure)?.message ?? "Couldn\u{2019}t add this extension."
            }
        }
    }

    func setEnabled(_ id: String, _ on: Bool) {
        guard var e = installed.first(where: { $0.id == id }), e.enabled != on else { return }
        e.enabled = on
        upsert(e)
        if on { start(); Task { @MainActor in await load(e) } } else { unloadContext(id) }
    }

    /// Unloads it, removes its stored data (its vault cache, settings) and its folder.
    func remove(_ id: String) {
        guard installed.contains(where: { $0.id == id }) else { return }
        let finish: () -> Void = { [weak self] in
            self?.unloadContext(id)
            ExtensionsInstaller.remove(id: id)
            self?.installed.removeAll { $0.id == id }
            self?.writeIndex()
        }
        #if compiler(>=6.1)
        if #available(macOS 15.4, *), let e = engine as? ExtensionsEngine, e.contexts[id] != nil {
            e.removeData(id) { finish() }
            return
        }
        #endif
        finish()
    }

    private func load(_ e: InstalledExtension) async {
        #if compiler(>=6.1)
        if #available(macOS 15.4, *) {
            do {
                let name = try await core.load(e)
                loaded.insert(e.id)
                // WebKit resolves the localized name better than the installer did.
                if let name, !name.isEmpty, name != e.name, var cur = installed.first(where: { $0.id == e.id }) {
                    cur.name = name
                    upsert(cur)
                }
                revision += 1
            } catch {
                NSLog("[extensions] %@ failed to load: %@", e.id, String(describing: error))
                problem = "\(e.name) couldn\u{2019}t start in Liaison. Not every Chrome extension works in Safari\u{2019}s engine."
            }
        }
        #endif
    }

    private func unloadContext(_ id: String) {
        #if compiler(>=6.1)
        if #available(macOS 15.4, *), let e = engine as? ExtensionsEngine { e.unload(id) }
        #endif
        loaded.remove(id)
        revision += 1
    }

    /// The one question at install: what the extension may do.
    private func confirm(_ s: ExtensionsInstaller.Staged) async -> Bool {
        let api = s.permissions.filter { !["nativeMessaging"].contains($0) }
        let title = s.allSites ? "\(s.name) wants to read and change data on all websites" : "Add \(s.name)?"
        var info = s.allSites ? "Password managers need this to fill sign-in forms on the sites you visit." : ""
        if !api.isEmpty { info += (info.isEmpty ? "" : "\n\n") + "It also uses: " + api.joined(separator: ", ") + "." }
        info += (info.isEmpty ? "" : "\n\n") + "You are asked once; you can remove it in Settings \u{203A} Advanced \u{203A} Extensions."
        return await ask(title, info, allow: "Allow and Add")
    }

    /// An alert: a sheet on the front window when there is one, else app-modal.
    func ask(_ title: String, _ info: String, allow: String) async -> Bool {
        let a = NSAlert()
        a.messageText = title
        a.informativeText = info
        a.addButton(withTitle: allow)
        a.addButton(withTitle: "Cancel")
        if let w = NSApp.keyWindow ?? NSApp.mainWindow, w.attachedSheet == nil {
            return await withCheckedContinuation { (c: CheckedContinuation<Bool, Never>) in
                a.beginSheetModal(for: w) { r in c.resume(returning: r == .alertFirstButtonReturn) }
            }
        }
        return a.runModal() == .alertFirstButtonReturn
    }

    // MARK: toolbar

    struct ActionItem: Identifiable {
        let id: String
        let label: String
        let icon: NSImage?
        let badge: String
        let enabled: Bool
    }

    /// The enabled, loaded extensions that have an action, for the selected tab of the followed browser.
    func actionItems() -> [ActionItem] {
        _ = revision
        #if compiler(>=6.1)
        if #available(macOS 15.4, *), let e = engine as? ExtensionsEngine {
            return installed.filter { $0.enabled }.compactMap { e.actionItem($0) }
        }
        #endif
        return []
    }

    /// A click on an extension's button: WebKit opens its popup (the delegate shows it) or fires `action.onClicked`.
    func performAction(_ id: String) {
        #if compiler(>=6.1)
        if #available(macOS 15.4, *), let e = engine as? ExtensionsEngine { e.performAction(id) }
        #endif
    }

    /// The tab group shows this browser: its tabs are the ones extensions see first (re-followed on workspace change).
    func follow(_ browser: BrowserModel) {
        #if compiler(>=6.1)
        if #available(macOS 15.4, *) { core.tabs.follow(browser) }
        #endif
    }

    func setAnchor(_ v: NSView, for id: String) { anchors.setObject(v, forKey: id as NSString) }
    func anchor(for id: String) -> NSView? {
        guard let v = anchors.object(forKey: id as NSString), v.window != nil else { return nil }
        return v
    }

    func actionsChanged() { revision += 1 }

    /// Its icon: from WebKit when loaded, else from the manifest on disk.
    func icon(_ id: String) -> NSImage? {
        #if compiler(>=6.1)
        if #available(macOS 15.4, *), let e = engine as? ExtensionsEngine, let img = e.icon(id) { return img }
        #endif
        return ExtensionsInstaller.iconFile(in: ExtensionsInstaller.folder(for: id)).flatMap { NSImage(contentsOf: $0) }
    }

    func entry(_ id: String) -> InstalledExtension? { installed.first { $0.id == id } }

    // MARK: index

    private static var indexURL: URL { ExtensionsInstaller.root.appendingPathComponent("index.json") }

    private static func readIndex() -> [InstalledExtension] {
        guard let d = try? Data(contentsOf: indexURL) else { return [] }
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        let list = (try? dec.decode([InstalledExtension].self, from: d)) ?? []
        // A folder deleted by hand: forget it.
        return list.filter { FileManager.default.fileExists(atPath: ExtensionsInstaller.folder(for: $0.id).path) }
    }

    private func writeIndex() {
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let d = try? enc.encode(installed) else { return }
        try? FileManager.default.createDirectory(at: ExtensionsInstaller.root, withIntermediateDirectories: true)
        try? d.write(to: Self.indexURL, options: .atomic)
    }

    private func upsert(_ e: InstalledExtension) {
        if let i = installed.firstIndex(where: { $0.id == e.id }) { installed[i] = e } else { installed.append(e) }
        writeIndex()
    }
}

#if compiler(>=6.1)

// MARK: - engine (macOS 15.4+)

/// The controller, the loaded contexts, and the delegate: tabs, windows, the action popup, permission prompts,
/// native messaging (refused for now). Each delegate method cites its page in Apple's documentation; signatures were
/// checked against WebKit's WKWebExtensionControllerDelegate.h (NS_SWIFT_NAME).
@available(macOS 15.4, *)
@MainActor
final class ExtensionsEngine: NSObject, WKWebExtensionControllerDelegate {
    /// `init`: the default configuration, which is persistent (extension storage survives restarts).
    let controller = WKWebExtensionController()
    private(set) var contexts: [String: WKWebExtensionContext] = [:]
    private unowned let host: ExtensionsHost
    private(set) lazy var tabs = ExtTabTracker(controller: controller)

    init(host: ExtensionsHost) {
        self.host = host
        super.init()
        controller.delegate = self
    }

    /// Loads Extensions/<id>/ and returns WebKit's display name.
    func load(_ e: InstalledExtension) async throws -> String? {
        if let c = contexts[e.id] { return c.webExtension.displayName }
        let ext = try await WKWebExtension(resourceBaseURL: ExtensionsInstaller.folder(for: e.id))
        let ctx = WKWebExtensionContext(for: ext)
        ctx.uniqueIdentifier = e.uid
        if let base = URL(string: "webkit-extension://" + e.uid + "/") { ctx.baseURL = base }
        ctx.inspectionName = e.name
        #if DEBUG
        ctx.isInspectable = true
        #endif
        if e.granted { grantRequested(ctx) }
        tabs.refresh()
        try controller.load(ctx)
        contexts[e.id] = ctx
        return ext.displayName
    }

    /// What the person allowed at install: the manifest's permissions and every site it asks for. Optional
    /// permissions are not included (they are asked for when the extension requests them).
    private func grantRequested(_ ctx: WKWebExtensionContext) {
        let ext = ctx.webExtension
        for p in ext.requestedPermissions { ctx.setPermissionStatus(.grantedExplicitly, for: p) }
        for m in ext.requestedPermissionMatchPatterns.union(ext.allRequestedMatchPatterns) {
            ctx.setPermissionStatus(.grantedExplicitly, for: m)
        }
    }

    func unload(_ id: String) {
        guard let c = contexts[id] else { return }
        c.action(for: nil)?.closePopup()
        try? controller.unload(c)
        contexts[id] = nil
    }

    /// Removes the extension's stored data (storage, local storage, IndexedDB), then calls `done`.
    func removeData(_ id: String, done: @escaping () -> Void) {
        guard let c = contexts[id] else { done(); return }
        let types = WKWebExtensionController.allExtensionDataTypes
        controller.fetchDataRecord(ofTypes: types, for: c) { [weak self] record in
            guard let self, let record else { done(); return }
            self.controller.removeData(ofTypes: types, from: [record]) { done() }
        }
    }

    private func id(of context: WKWebExtensionContext) -> String? {
        contexts.first { $0.value === context }?.key
    }

    // MARK: toolbar

    func actionItem(_ e: InstalledExtension) -> ExtensionsHost.ActionItem? {
        guard let c = contexts[e.id], let a = c.action(for: tabs.currentTab) else { return nil }
        let label = a.label.isEmpty ? (c.webExtension.displayName ?? e.name) : a.label
        return ExtensionsHost.ActionItem(id: e.id, label: label, icon: a.icon(for: CGSize(width: 16, height: 16)),
                                         badge: a.badgeText, enabled: a.isEnabled)
    }

    func performAction(_ id: String) {
        guard let c = contexts[id] else { return }
        c.performAction(for: tabs.currentTab)
    }

    func icon(_ id: String) -> NSImage? {
        contexts[id]?.webExtension.icon(for: CGSize(width: 32, height: 32))
    }

    // MARK: windows and tabs

    // https://developer.apple.com/documentation/webkit/wkwebextensioncontrollerdelegate/webextensioncontroller(_:openwindowsfor:)
    @objc(webExtensionController:openWindowsForExtensionContext:)
    func webExtensionController(_ controller: WKWebExtensionController, openWindowsFor extensionContext: WKWebExtensionContext) -> [any WKWebExtensionWindow] {
        tabs.refresh()
        return tabs.allWindows
    }

    // https://developer.apple.com/documentation/webkit/wkwebextensioncontrollerdelegate/webextensioncontroller(_:focusedwindowfor:)
    @objc(webExtensionController:focusedWindowForExtensionContext:)
    func webExtensionController(_ controller: WKWebExtensionController, focusedWindowFor extensionContext: WKWebExtensionContext) -> (any WKWebExtensionWindow)? {
        tabs.refresh()
        return tabs.focusedWindow
    }

    // https://developer.apple.com/documentation/webkit/wkwebextensioncontrollerdelegate/webextensioncontroller(_:opennewtabusing:for:completionhandler:)
    @objc(webExtensionController:openNewTabUsingConfiguration:forExtensionContext:completionHandler:)
    func webExtensionController(_ controller: WKWebExtensionController, openNewTabUsing configuration: WKWebExtension.TabConfiguration,
                                for extensionContext: WKWebExtensionContext,
                                completionHandler: @escaping ((any WKWebExtensionTab)?, (any Error)?) -> Void) {
        guard let b = (configuration.window as? ExtWindow)?.browser ?? tabs.currentBrowser else {
            completionHandler(nil, ExtensionsInstaller.Failure("No browser is open."))
            return
        }
        let t = b.newTab(url: configuration.url, select: configuration.shouldBeActive)
        completionHandler(tabs.tab(for: t, in: b), nil)
    }

    /// No second browser window in Liaison: the window's pages open as tabs of the current browser (Bitwarden's
    /// "pop out" lands in a tab).
    // https://developer.apple.com/documentation/webkit/wkwebextensioncontrollerdelegate/webextensioncontroller(_:opennewwindowusing:for:completionhandler:)
    @objc(webExtensionController:openNewWindowUsingConfiguration:forExtensionContext:completionHandler:)
    func webExtensionController(_ controller: WKWebExtensionController, openNewWindowUsing configuration: WKWebExtension.WindowConfiguration,
                                for extensionContext: WKWebExtensionContext,
                                completionHandler: @escaping ((any WKWebExtensionWindow)?, (any Error)?) -> Void) {
        guard let b = tabs.currentBrowser else {
            completionHandler(nil, ExtensionsInstaller.Failure("No browser is open."))
            return
        }
        for u in configuration.tabURLs { b.newTab(url: u) }
        completionHandler(tabs.window(for: b), nil)
    }

    // MARK: action popup

    /// The popover WebKit prepares for the action (sized to the popup page), shown under the extension's button.
    // https://developer.apple.com/documentation/webkit/wkwebextensioncontrollerdelegate/webextensioncontroller(_:presentactionpopup:for:completionhandler:)
    @objc(webExtensionController:presentPopupForAction:forExtensionContext:completionHandler:)
    func webExtensionController(_ controller: WKWebExtensionController, presentActionPopup action: WKWebExtension.Action,
                                for context: WKWebExtensionContext, completionHandler: @escaping ((any Error)?) -> Void) {
        guard let pop = action.popupPopover else {
            completionHandler(ExtensionsInstaller.Failure("This extension has no popup."))
            return
        }
        if let id = id(of: context), let anchor = host.anchor(for: id) {
            pop.show(relativeTo: anchor.bounds, of: anchor, preferredEdge: .minY)
        } else if let content = (NSApp.keyWindow ?? NSApp.mainWindow)?.contentView {
            // No button on screen (toolbar hidden): the top right corner of the window.
            let r = NSRect(x: content.bounds.maxX - 60, y: content.isFlipped ? 8 : content.bounds.maxY - 40, width: 30, height: 30)
            pop.show(relativeTo: r, of: content, preferredEdge: .minY)
        } else {
            completionHandler(ExtensionsInstaller.Failure("No window to show the popup in."))
            return
        }
        completionHandler(nil)
    }

    // https://developer.apple.com/documentation/webkit/wkwebextensioncontrollerdelegate/webextensioncontroller(_:didupdate:forextensioncontext:)
    @objc(webExtensionController:didUpdateAction:forExtensionContext:)
    func webExtensionController(_ controller: WKWebExtensionController, didUpdate action: WKWebExtension.Action,
                                forExtensionContext context: WKWebExtensionContext) {
        host.actionsChanged()
    }

    // MARK: permissions

    /// Granted without asking when the manifest asked for them and the person allowed that at install; else a sheet.
    // https://developer.apple.com/documentation/webkit/wkwebextensioncontrollerdelegate/webextensioncontroller(_:promptforpermissions:in:for:completionhandler:)
    @objc(webExtensionController:promptForPermissions:inTab:forExtensionContext:completionHandler:)
    func webExtensionController(_ controller: WKWebExtensionController, promptForPermissions permissions: Set<WKWebExtension.Permission>,
                                in tab: (any WKWebExtensionTab)?, for extensionContext: WKWebExtensionContext,
                                completionHandler: @escaping (Set<WKWebExtension.Permission>, Date?) -> Void) {
        let confirmed = confirmedPermissions(extensionContext)
        let rest = permissions.subtracting(confirmed)
        if rest.isEmpty { completionHandler(permissions, nil); return }
        let name = displayName(extensionContext)
        let list = rest.map(\.rawValue).sorted().joined(separator: ", ")
        Task { @MainActor in
            let ok = await host.ask("\(name) asks for more permissions", "It wants: \(list).", allow: "Allow")
            completionHandler(ok ? permissions : permissions.intersection(confirmed), nil)
        }
    }

    // https://developer.apple.com/documentation/webkit/wkwebextensioncontrollerdelegate/webextensioncontroller(_:promptforpermissiontoaccess:in:for:completionhandler:)
    @objc(webExtensionController:promptForPermissionToAccessURLs:inTab:forExtensionContext:completionHandler:)
    func webExtensionController(_ controller: WKWebExtensionController, promptForPermissionToAccess urls: Set<URL>,
                                in tab: (any WKWebExtensionTab)?, for extensionContext: WKWebExtensionContext,
                                completionHandler: @escaping (Set<URL>, Date?) -> Void) {
        let patterns = confirmedPatterns(extensionContext)
        let covered = urls.filter { u in patterns.contains { $0.matches(u) } }
        let rest = urls.subtracting(covered)
        if rest.isEmpty { completionHandler(urls, nil); return }
        let name = displayName(extensionContext)
        let hosts = Set(rest.compactMap { $0.host }).sorted().prefix(5).joined(separator: ", ")
        Task { @MainActor in
            let ok = await host.ask("Allow \(name) on \(hosts.isEmpty ? "this site" : hosts)?",
                                    "It will be able to read and change data on it.", allow: "Allow")
            completionHandler(ok ? urls : covered, nil)
        }
    }

    // https://developer.apple.com/documentation/webkit/wkwebextensioncontrollerdelegate/webextensioncontroller(_:promptforpermissionmatchpatterns:in:for:completionhandler:)
    @objc(webExtensionController:promptForPermissionMatchPatterns:inTab:forExtensionContext:completionHandler:)
    func webExtensionController(_ controller: WKWebExtensionController, promptForPermissionMatchPatterns matchPatterns: Set<WKWebExtension.MatchPattern>,
                                in tab: (any WKWebExtensionTab)?, for extensionContext: WKWebExtensionContext,
                                completionHandler: @escaping (Set<WKWebExtension.MatchPattern>, Date?) -> Void) {
        let patterns = confirmedPatterns(extensionContext)
        let covered = matchPatterns.filter { p in patterns.contains { $0.matches(p) } }
        let rest = matchPatterns.subtracting(covered)
        if rest.isEmpty { completionHandler(matchPatterns, nil); return }
        let name = displayName(extensionContext)
        let all = rest.contains { $0.matchesAllURLs || $0.matchesAllHosts }
        let list = rest.map(\.string).sorted().prefix(5).joined(separator: ", ")
        Task { @MainActor in
            let ok = await host.ask(all ? "\(name) wants to read and change data on all websites" : "Allow \(name) on \(list)?",
                                    "It will be able to read and change data on these sites.", allow: "Allow")
            completionHandler(ok ? matchPatterns : covered, nil)
        }
    }

    private func confirmedPermissions(_ c: WKWebExtensionContext) -> Set<WKWebExtension.Permission> {
        guard let id = id(of: c), host.entry(id)?.granted == true else { return [] }
        return c.webExtension.requestedPermissions
    }

    private func confirmedPatterns(_ c: WKWebExtensionContext) -> Set<WKWebExtension.MatchPattern> {
        guard let id = id(of: c), host.entry(id)?.granted == true else { return [] }
        return c.webExtension.requestedPermissionMatchPatterns.union(c.webExtension.allRequestedMatchPatterns)
    }

    private func displayName(_ c: WKWebExtensionContext) -> String {
        c.webExtension.displayName ?? id(of: c).flatMap { host.entry($0)?.name } ?? "This extension"
    }

    // MARK: native messaging (not supported yet; Bitwarden works without its desktop app)

    // https://developer.apple.com/documentation/webkit/wkwebextensioncontrollerdelegate/webextensioncontroller(_:sendmessage:toapplicationwithidentifier:for:replyhandler:)
    @objc(webExtensionController:sendMessage:toApplicationWithIdentifier:forExtensionContext:replyHandler:)
    func webExtensionController(_ controller: WKWebExtensionController, sendMessage message: Any, toApplicationWithIdentifier applicationIdentifier: String?,
                                for extensionContext: WKWebExtensionContext, replyHandler: @escaping (Any?, (any Error)?) -> Void) {
        replyHandler(nil, ExtensionsInstaller.Failure("Native messaging is not supported in Liaison yet."))
    }

    // https://developer.apple.com/documentation/webkit/wkwebextensioncontrollerdelegate/webextensioncontroller(_:connectusing:for:completionhandler:)
    @objc(webExtensionController:connectUsingMessagePort:forExtensionContext:completionHandler:)
    func webExtensionController(_ controller: WKWebExtensionController, connectUsing port: WKWebExtension.MessagePort,
                                for extensionContext: WKWebExtensionContext, completionHandler: @escaping ((any Error)?) -> Void) {
        completionHandler(ExtensionsInstaller.Failure("Native messaging is not supported in Liaison yet."))
    }
}

#endif
