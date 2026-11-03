import SwiftUI

/// \u{2318}/ the keyboard map, grouped and searchable, every key drawn as a small cap. Mirrors
/// WorkspaceCommands (the menu bar) plus the keys inside a conversation.
struct ShortcutsSheet: View {
    @ObservedObject var ws: WorkspaceModel
    @Environment(\.liaDismiss) private var dismiss
    @State private var query = ""
    @FocusState private var focused: Bool

    var body: some View {
        VStack(spacing: 0) {
            header
            Rectangle().fill(WS.line).frame(height: 1)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 18) {
                    let groups = ShortcutMap.filtered(query)
                    ForEach(groups) { g in ShortcutGroupView(group: g) }
                    if groups.isEmpty {
                        Text("No shortcut matches \u{201C}\(query)\u{201D}.")
                            .font(LiaFont.ui(13)).foregroundStyle(WS.text3)
                            .frame(maxWidth: .infinity).padding(.top, 40)
                    }
                }
                .padding(20)
            }
        }
        .frame(width: 640, height: 560)
        .background(WS.surface)
        .onAppear { focused = true }
    }

    private var header: some View {
        HStack(spacing: 12) {
            Text("Keyboard Shortcuts").font(LiaFont.ui(17, .bold)).foregroundStyle(WS.ink)
            Spacer(minLength: 12)
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").font(.system(size: 12)).foregroundStyle(WS.text3)
                TextField("Search", text: $query)
                    .textFieldStyle(.plain).font(LiaFont.ui(13)).focused($focused)
            }
            .padding(.horizontal, 10)
            .frame(width: 220, height: 32)
            .background(WS.soft, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            Button { close() } label: {
                Image(systemName: "xmark").font(.system(size: 11, weight: .semibold)).foregroundStyle(WS.text2)
                    .frame(width: 28, height: 28)
                    .background(WS.soft, in: Circle())
            }
            .buttonStyle(.liaPlain).liaPointer()
            .keyboardShortcut(.cancelAction)
            .accessibilityLabel(Text("Close"))
        }
        .padding(.horizontal, 20)
        .frame(height: 60)
    }

    private func close() {
        dismiss()
        ws.showShortcuts = false
    }
}

private struct ShortcutGroupView: View {
    let group: ShortcutMap.Group

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(group.title.uppercased())
                .font(LiaFont.ui(11, .semibold)).foregroundStyle(WS.text3)
                .padding(.bottom, 4)
            VStack(spacing: 0) {
                ForEach(Array(group.items.enumerated()), id: \.offset) { i, item in
                    if i > 0 { Rectangle().fill(WS.line).frame(height: 1).padding(.leading, 12) }
                    ShortcutRow(item: item)
                }
            }
            .background(WS.soft.opacity(0.55), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
    }
}

private struct ShortcutRow: View {
    let item: ShortcutMap.Item

    var body: some View {
        HStack(spacing: 10) {
            Text(item.action).font(LiaFont.ui(13)).foregroundStyle(WS.ink).lineLimit(1)
            Spacer(minLength: 10)
            ForEach(Array(item.combos.enumerated()), id: \.offset) { i, combo in
                if i > 0 { Text("or").font(LiaFont.ui(11)).foregroundStyle(WS.text3) }
                HStack(spacing: 3) {
                    ForEach(Array(combo.enumerated()), id: \.offset) { KeyCap($0.element) }
                }
            }
        }
        .padding(.horizontal, 12)
        .frame(minHeight: 36)
        .accessibilityElement(children: .combine)
    }
}

/// The map itself. Keys as caps, in macOS order (\u{2303} \u{2325} \u{21E7} \u{2318}); several combos for one action read "or".
enum ShortcutMap {
    struct Item { let action: String; let combos: [[String]] }
    struct Group: Identifiable { let title: String; let items: [Item]; var id: String { title } }

    private static let cmd = "\u{2318}", shift = "\u{21E7}", opt = "\u{2325}", ctrl = "\u{2303}", ret = "\u{23CE}"

    static var groups: [Group] {
        let agents: [Item] = AgentInfo.fallback.filter { !$0.lead }.prefix(7).enumerated().map { i, a in
            Item(action: "Talk to \(a.name)", combos: [[opt, cmd, String(i + 1)]])
        }
        // Built in steps: one literal joined with `+` inside the big one is slow for the type checker.
        var team: [Item] = [
            Item(action: "Ask Lia About Selection", combos: [[cmd, "E"]]),
            Item(action: "Lia Chat", combos: [[cmd, "J"]]),
        ]
        team += agents
        team += [
            Item(action: "Send Message", combos: [[ret]]),
            Item(action: "New Line", combos: [[shift, ret]]),
            Item(action: "Edit Last Message", combos: [["\u{2191}"]]),
            Item(action: "Stop the Agent", combos: [["esc"]]),
            Item(action: "Approve the Change", combos: [[cmd, ret]]),
            Item(action: "Search the Conversation", combos: [[cmd, "F"]]),
        ]
        return [
            Group(title: "Tabs", items: [
                Item(action: "New Tab", combos: [[cmd, "T"]]),
                Item(action: "Reopen Closed Tab", combos: [[shift, cmd, "T"]]),
                Item(action: "Close Tab", combos: [[cmd, "W"]]),
                Item(action: "Search Tabs in Every Workspace", combos: [[shift, cmd, "A"]]),
                Item(action: "Pin or Unpin Tab", combos: [[cmd, "D"]]),
                Item(action: "Mute or Unmute Tab", combos: [[shift, cmd, "M"]]),
                Item(action: "Group Selected Tabs", combos: [[opt, cmd, "G"]]),
                Item(action: "Show Reader", combos: [[opt, cmd, "R"]]),
                Item(action: "Split View", combos: [[opt, cmd, "N"]]),
                Item(action: "Next Tab", combos: [[opt, cmd, "\u{2192}"], [ctrl, "Tab"]]),
                Item(action: "Previous Tab", combos: [[opt, cmd, "\u{2190}"], [ctrl, shift, "Tab"]]),
                Item(action: "Tab 1 to 8", combos: [[cmd, "1\u{2013}8"]]),
                Item(action: "Last Tab", combos: [[cmd, "9"]]),
                Item(action: "Open Link in Peek", combos: [[shift, "Click"]]),
            ]),
            Group(title: "Address & Page", items: [
                Item(action: "Open Location", combos: [[cmd, "L"]]),
                Item(action: "Command Palette", combos: [[cmd, "K"]]),
                Item(action: "Copy Link", combos: [[shift, cmd, "C"]]),
                Item(action: "Find on Page", combos: [[cmd, "F"]]),
                Item(action: "Find Next", combos: [[cmd, "G"]]),
                Item(action: "Find Previous", combos: [[shift, cmd, "G"]]),
                Item(action: "Reload Page", combos: [[cmd, "R"]]),
                Item(action: "Reload From Origin", combos: [[shift, cmd, "R"]]),
                Item(action: "Back", combos: [[cmd, "["]]),
                Item(action: "Forward", combos: [[cmd, "]"]]),
                Item(action: "Zoom In", combos: [[cmd, "+"]]),
                Item(action: "Zoom Out", combos: [[cmd, "\u{2212}"]]),
                Item(action: "Actual Size", combos: [[cmd, "0"]]),
                Item(action: "Print", combos: [[cmd, "P"]]),
                Item(action: "Downloads", combos: [[opt, cmd, "L"]]),
            ]),
            Group(title: "Workspaces", items: [
                Item(action: "Next Workspace", combos: [[ctrl, opt, "\u{2192}"]]),
                Item(action: "Previous Workspace", combos: [[ctrl, opt, "\u{2190}"]]),
                Item(action: "Workspace 1 to 9", combos: [[ctrl, "1\u{2013}9"]]),
            ]),
            Group(title: "Agents & Approvals", items: team),
            Group(title: "Window", items: [
                Item(action: "Keyboard Shortcuts", combos: [[cmd, "/"]]),
                Item(action: "Settings", combos: [[cmd, ","]]),
                Item(action: "Close Palette, Peek or Sheet", combos: [["esc"]]),
                Item(action: "Minimize", combos: [[cmd, "M"]]),
                Item(action: "Full Screen", combos: [[ctrl, cmd, "F"]]),
                Item(action: "Hide Liaison", combos: [[cmd, "H"]]),
                Item(action: "Quit Liaison", combos: [[cmd, "Q"]]),
            ]),
        ]
    }

    /// Rows whose action matches the text (fuzzy), or a group whose title does (the whole group).
    static func filtered(_ query: String) -> [Group] {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return groups }
        return groups.compactMap { g in
            if Fuzzy.score(q, g.title).map({ $0 >= 900 }) == true { return g }
            let items = g.items.filter { Fuzzy.score(q, $0.action) != nil }
            return items.isEmpty ? nil : Group(title: g.title, items: items)
        }
    }
}
