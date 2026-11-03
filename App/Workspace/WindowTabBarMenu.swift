import SwiftUI
import AppKit

// ("a right-click on the empty tab bar does nothing"): the tab bar's own menus, from Safari's,
// Chrome's and Arc's. A right-click on the strip's empty room (and the free room after +) opens `bar`; a right-click
// on + opens `plus`. Only what BrowserModel can do: no bookmarks, no second browser window (a chat has one browser).
// Behaviour only; the look is LiaCtxGlassPanel's.
extension Notification.Name {
    /// 0.2.11: a right-click on the window bar's free room outside the tab strip; object: the window. The strip of
    /// that window opens `TabBarMenu.bar` at the pointer.
    static let wsTabBarMenu = Notification.Name("lia.ws.tabBarMenu")
}

@MainActor
enum TabBarMenu {
    /// The bar's free room (WorkspaceWindow's row, beside Share) asks the window's strip for its menu.
    static func requestBar(in window: NSWindow) {
        NotificationCenter.default.post(name: .wsTabBarMenu, object: window)
    }

    /// What a menu needs from the view that opens it.
    struct Hooks {
        var newTab: () -> Void
        var privateWindow: () -> Void
        /// The selected tab's back/forward list (what a right-click on the empty room did before).
        var tabHistory: (() -> Void)?
    }

    /// The empty room of the strip: new tabs and windows, reopen, groups, arrange, overview.
    static func bar(browser b: BrowserModel, ws: WorkspaceModel, hooks h: Hooks) -> [LiaCtxItem] {
        var out = creation(b, hooks: h)
        out.append(contentsOf: reopening(b))
        out.append(.sep)
        out.append(LiaCtxItem(title: "New Tab Group", icon: "folders") { newGroup(b) })
        if TabTidy.canRun(b), !TabTidy.shared.running {
            out.append(LiaCtxItem(title: "Tidy Tabs", icon: "folders") { TabTidy.shared.run(b, ws: ws) })
        }
        if !b.groups.isEmpty {
            let all = Set(b.groups.map(\.id))
            if b.groups.contains(where: { !$0.collapsed }) {
                out.append(LiaCtxItem(title: "Collapse All Groups", icon: "collapse") {
                    withAnimation(WSMotion.spring) { b.setCollapsed(all, true) }
                })
            }
            if b.groups.contains(where: \.collapsed) {
                out.append(LiaCtxItem(title: "Expand All Groups", icon: "menu-expand") {
                    withAnimation(WSMotion.spring) { b.setCollapsed(all, false) }
                })
            }
        }
        if b.tabs.filter({ !$0.pinned && $0.group == nil }).count > 1 {
            out.append(LiaCtxItem(title: "Arrange Tabs By", icon: "list-bullets", sub: [
                LiaCtxItem(title: "Title") { withAnimation(WSMotion.spring) { b.arrange(by: .title) } },
                LiaCtxItem(title: "Website") { withAnimation(WSMotion.spring) { b.arrange(by: .website) } },
            ]))
        }
        out.append(.sep)
        out.append(LiaCtxItem(title: "Show All Tabs", icon: "squares-four") {
            NotificationCenter.default.post(name: .wsTabOverview, object: nil)
        })
        out.append(LiaCtxItem(title: "Search Tabs\u{2026}", icon: "magnifying-glass") { ws.palette = .tabs })
        if let history = h.tabHistory, b.selected?.canGoBack == true || b.selected?.canGoForward == true {
            out.append(LiaCtxItem(title: "Tab History\u{2026}", icon: "clock-counter-clockwise") {
                // after this menu has gone, so the history's dropdown is not toggled shut with it
                DispatchQueue.main.async { history() }
            })
        }
        let vertical = Prefs.flag(Prefs.verticalTabs, default: false)
        out.append(LiaCtxItem(title: vertical ? "Show Tabs in the Bar" : "Show Tabs in a Sidebar", icon: "sidebar-simple") {
            UserDefaults.standard.set(!vertical, forKey: Prefs.verticalTabs)
        })
        return out
    }

    /// The + button: the kinds of new tab (Safari's long-press on + lists recently closed tabs, so they are here too).
    static func plus(browser b: BrowserModel, hooks h: Hooks) -> [LiaCtxItem] {
        var out = creation(b, hooks: h)
        if !b.groups.isEmpty {
            out.append(LiaCtxItem(title: "New Tab in Group", icon: "plus", sub: b.groups.map { g in
                LiaCtxItem(title: WSTabStacks.chipName(g, count: b.tabs(in: g).count)) {
                    withAnimation(WSMotion.spring) { _ = b.newTab(inGroup: g) }
                }
            }))
        }
        out.append(LiaCtxItem(title: "New Tab Group", icon: "folders") { newGroup(b) })
        out.append(contentsOf: reopening(b))
        return out
    }

    private static func creation(_ b: BrowserModel, hooks h: Hooks) -> [LiaCtxItem] {
        [
            LiaCtxItem(title: "New Tab", icon: "plus") { h.newTab() },
            LiaCtxItem(title: "New Private Window", icon: "lock-key") { h.privateWindow() },
        ]
    }

    /// Reopen Closed Tab, Recently Closed (the last ten), Saved Groups (put away, ): only when there is any.
    private static func reopening(_ b: BrowserModel) -> [LiaCtxItem] {
        var out: [LiaCtxItem] = []
        guard !b.closed.isEmpty || !b.savedGroups.isEmpty else { return out }
        out.append(.sep)
        if !b.closed.isEmpty {
            out.append(LiaCtxItem(title: "Reopen Closed Tab", icon: "arrow-counter-clockwise") {
                withAnimation(WSMotion.spring) { b.reopenClosed() }
            })
            let recent = Array(b.closed.indices.reversed().prefix(10))
            if recent.count > 1 {
                out.append(LiaCtxItem(title: "Recently Closed", icon: "clock-counter-clockwise", sub: recent.map { i in
                    let c = b.closed[i]
                    let url = c.url
                    return LiaCtxItem(title: short(c.title.isEmpty ? (c.url.host ?? c.url.absoluteString) : c.title)) {
                        // looked up again: the list may have changed while the menu was open
                        guard let n = b.closed.lastIndex(where: { $0.url == url }) else { return }
                        withAnimation(WSMotion.spring) { b.reopenClosed(at: n) }
                    }
                }))
            }
        }
        if !b.savedGroups.isEmpty {
            out.append(LiaCtxItem(title: "Saved Groups", icon: "archive", sub: b.savedGroups.prefix(10).map { s in
                LiaCtxItem(title: short(s.name)) {
                    guard let g = b.savedGroups.first(where: { $0.id == s.id }) else { return }
                    withAnimation(WSMotion.spring) { b.restore(g) }
                }
            }))
        }
        return out
    }

    private static func newGroup(_ b: BrowserModel) {
        var made: BrowserModel.TabGroupInfo?
        withAnimation(WSMotion.spring) { made = b.newGroupWithNewTab() }
        if let g = made { TabGroupActions.askName(g) }
    }

    private static func short(_ s: String) -> String { s.count > 48 ? String(s.prefix(47)) + "\u{2026}" : s }
}
