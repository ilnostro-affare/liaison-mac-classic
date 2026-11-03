import SwiftUI

/// Tab stacks (Vivaldi) on top of tab groups. "Stack Under…" puts a tab right after another and both in one
/// group; a group made this way is a stack, and its chip reads "Stack of 3" until it is renamed. Which groups are
/// stacks is kept here (UserDefaults), BrowserModel only knows groups.
enum WSTabStacks {
    static let defaultName = "Stack"
    private static let key = "lia_tab_stacks"

    static func ids() -> Set<String> {
        Set(UserDefaults.standard.stringArray(forKey: key) ?? [])
    }

    static func isStack(_ g: BrowserModel.TabGroupInfo) -> Bool { ids().contains(g.id) }

    /// The chip's text: "Stack of N" for a stack that still has its default name.
    static func chipName(_ g: BrowserModel.TabGroupInfo, count: Int) -> String {
        isStack(g) && g.name == defaultName ? "Stack of \(count)" : g.name
    }

    private static func remember(_ id: String) {
        var s = ids()
        s.insert(id)
        UserDefaults.standard.set(Array(s), forKey: key)
    }

    /// `tab` goes under `target`: into the target's group (stack or not), or a new stack of the two.
    @MainActor static func stack(_ tab: BrowserTab, under target: BrowserTab, in b: BrowserModel) {
        guard tab.id != target.id, !tab.pinned, !target.pinned else { return }
        withAnimation(WSMotion.spring) {
            if let g = b.group(of: target) {
                b.addTab(tab, to: g)
            } else if let g = b.makeGroup([target, tab], name: defaultName) {
                remember(g.id)
                // makeGroup keeps the row's order; the stacked tab goes right after the target.
                if let i = b.tabs.firstIndex(where: { $0.id == tab.id }), let j = b.tabs.firstIndex(where: { $0.id == target.id }), i < j {
                    b.move(tab.id, to: target.id)
                }
            }
        }
        b.objectWillChange.send()
        AccessibilityNotification.Announcement("\(tab.displayTitle) stacked under \(target.displayTitle)").post()
    }
}

/// The tab menu's "Stack Under…": the other unpinned tabs of the row.
struct WindowTabStackMenu: View {
    let tab: BrowserTab
    let browser: BrowserModel

    var body: some View {
        let targets = browser.tabs.filter { $0.id != tab.id && !$0.pinned }
        if !tab.pinned && !targets.isEmpty {
            Menu("Stack Under\u{2026}") {
                ForEach(targets) { t in
                    Button(label(t)) { WSTabStacks.stack(tab, under: t, in: browser) }
                        .disabled(tab.group != nil && t.group == tab.group)
                }
            }
        }
    }

    private func label(_ t: BrowserTab) -> String {
        let title = t.displayTitle
        let short = title.count > 48 ? String(title.prefix(47)) + "\u{2026}" : title
        if let g = browser.group(of: t) { return short + " (" + WSTabStacks.chipName(g, count: browser.tabs(in: g).count) + ")" }
        return short
    }
}
