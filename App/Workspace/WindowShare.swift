import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// (the part that works without a server): a workspace's tabs, pins and groups as a file a colleague
/// opens in their own Liaison (Import Tabs…). Live sync between two people needs the server and a decision on whose
/// Meta access a shared workspace uses, so it is not done here; this hands over the set-up, not the session.
enum WorkspaceShare {
    struct Pack: Codable {
        var format = 1
        var name: String
        var tabs: [SavedTab]
        var groups: [BrowserModel.TabGroupInfo]
    }

    /// Save the workspace's tabs (pinned ones and groups included) to a file.
    @MainActor
    static func export(_ browser: BrowserModel, name: String, ws: WorkspaceModel) {
        let tabs = browser.tabs.compactMap { t -> SavedTab? in
            guard let u = t.savedURL else { return nil }   // The page each tab is on now, pinned ones too
            return SavedTab(url: u.absoluteString, title: t.savedTitle, pinned: t.pinned ? true : nil, group: t.group, name: t.customTitle)
        }
        let b = Pack(name: name, tabs: tabs, groups: browser.groups)
        guard let data = try? JSONEncoder().encode(b) else { return }
        let p = NSSavePanel()
        p.nameFieldStringValue = name + " tabs.json"
        p.allowedContentTypes = [.json]
        guard p.runModal() == .OK, let url = p.url else { return }
        do { try data.write(to: url); ws.show("Saved \(tabs.count) tabs", symbol: "square.and.arrow.up") }
        catch { ws.show("Could not save the file", symbol: "exclamationmark.triangle") }
    }

    /// Open a colleague's file: its tabs open in this workspace (with this workspace's own sign-ins).
    @MainActor
    static func importTabs(into browser: BrowserModel, ws: WorkspaceModel) {
        let p = NSOpenPanel()
        p.allowedContentTypes = [.json]
        p.allowsMultipleSelection = false
        guard p.runModal() == .OK, let url = p.url, let data = try? Data(contentsOf: url),
              let b = try? JSONDecoder().decode(Pack.self, from: data) else { return }
        var opened = 0
        for t in b.tabs.prefix(40) {
            guard let u = URL(string: t.url), ["http", "https"].contains(u.scheme?.lowercased() ?? "") else { continue }
            let tab = browser.newTab(url: u, select: false)
            if t.pinned == true { browser.setPinned(tab, true) }
            opened += 1
        }
        ws.show("Opened \(opened) tabs from \(b.name)", symbol: "square.and.arrow.down")
    }
}
