import SwiftUI

// The site's dropdowns, drawn by DropdownHost. A panel lives outside the window's view tree, so what it needs
// (the app, the chat) is passed in rather than read from the environment.

/// The chat menu (ai.js openChatMenu): Pin, Rename, Change project, Remove from project, Delete.
struct ChatMenuPanel: View {
    let app: AppModel
    let chat: ChatSummary
    let projects: [ProjectSummary]

    var body: some View {
        DropdownPanelView {
            DropdownItem(title: chat.starred ? "Unpin" : "Pin", icon: chat.starred ? "menu-unpin" : "menu-pin") { app.pin(chat) }
            DropdownItem(title: "Rename", icon: "menu-rename") { app.renameRequest = chat }
            DropdownItem(title: "Change project", icon: "projects", sub: { AnyView(projectSub) }, subGrowsUp: false)
            if chat.project != nil {
                DropdownItem(title: "Remove from project", icon: "project-remove") { app.move(chat.id, toProject: nil) }
            }
            DropdownDivider()
            DropdownItem(title: "Delete", icon: "trash", danger: true) { app.deleteRequest = chat }
        }
    }

    /// ai.js pickProjectFor: "Move to project", No project, then every project.
    private var projectSub: some View {
        DropdownPanelView {
            DropdownTitle(text: "Move to project")
            DropdownItem(title: "No project", icon: "menu-chat-deleted") { app.move(chat.id, toProject: nil) }
            ForEach(projects) { p in DropdownItem(title: p.name, icon: "projects") { app.move(chat.id, toProject: p.id) } }
        }
    }
}

/// The footer menu (the server): the email, Settings, Usage, Log out. Radius 16, 7 inside, 13 px rows.
struct ProfileMenuPanel: View {
    let app: AppModel
    let email: String?
    let width: CGFloat
    let onLogout: () -> Void

    var body: some View {
        DropdownPanelView(width: width, padding: 7, radius: 16) {
            if let e = email, !e.isEmpty {
                Text(e).font(LiaFont.ui(11.5, .medium)).foregroundStyle(AppConfig.text4).lineLimit(1).truncationMode(.tail)
                    .padding(.horizontal, 12).padding(.top, 7).padding(.bottom, 8)
                    .frame(maxWidth: 240, alignment: .leading)
                    .overlay(alignment: .bottom) { Rectangle().fill(AppConfig.line).frame(height: 1) }
                    .padding(.bottom, 5)
            }
            ProfileItem(title: "Settings", icon: "general") { app.openSettings() }
            ProfileItem(title: "Usage", icon: "usage") { app.openSettings("usage") }
            Rectangle().fill(AppConfig.line).frame(height: 1).padding(.vertical, 5)
            ProfileItem(title: "Log out", icon: "menu-logout", action: onLogout)
        }
    }
}

private struct ProfileItem: View {
    let title: String
    let icon: String
    let action: () -> Void
    @State private var hover = false
    var body: some View {
        Button { DropdownHost.shared.close(); action() } label: {
            HStack(spacing: 10) {
                LiaIcon(icon, size: 18)
                Text(title).font(LiaFont.ui(13))
                Spacer(minLength: 0)
            }
            .foregroundStyle(hover ? AppConfig.ink : AppConfig.text2)
            .padding(.horizontal, 12).padding(.vertical, 9)
            .background(RoundedRectangle(cornerRadius: 11).fill(hover ? AppConfig.navSel : .clear))   // shell.build2.css: hover is --nav-sel
            .contentShape(Rectangle())
        }
        .buttonStyle(.liaPlain)
        .onHover { hover = $0 }
        .liaPointer()
    }
}

/// The Mode menu (ai.js openModelMenu): "Mode", then one row per mode with its line and a check.
struct ModeMenuPanel: View {
    let current: RunMode
    let pick: (RunMode) -> Void

    var body: some View {
        DropdownPanelView(width: 272, padding: 5) {
            Text("Mode").font(LiaFont.ui(12)).foregroundStyle(AppConfig.text3)
                .padding(.horizontal, 10).padding(.top, 7).padding(.bottom, 6)
            ForEach(LiaModel.modes) { m in ModeRow(mode: m, on: m == current) { DropdownHost.shared.close(); pick(m) } }
        }
    }
}

private struct ModeRow: View {
    let mode: RunMode
    let on: Bool
    let action: () -> Void
    @State private var hover = false
    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(mode.word).font(LiaFont.ui(13)).foregroundStyle(AppConfig.ink)
                    Text(mode.sub).font(LiaFont.ui(11.5)).foregroundStyle(AppConfig.text3).lineLimit(1).fixedSize()
                }
                Spacer(minLength: 0)
                // ai.js .ai__mmck: the blue tick, 16 px, kept in the layout and shown on the chosen row only.
                LiaIcon("mode-check", size: 16).foregroundStyle(AppConfig.accent).opacity(on ? 1 : 0)
            }
            .padding(.horizontal, 10).padding(.vertical, 7)
            .background(RoundedRectangle(cornerRadius: 8).fill(on ? AppConfig.navSel : (hover ? AppConfig.surface2 : .clear)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.liaPlain)
        .onHover { hover = $0 }
        .liaPointer()
        .accessibilityAddTraits(on ? .isSelected : [])
    }
}

/// The [+] menu (ai.js openPlusMenu): Add files or photos, Add to project, Connectors, Web search.
/// Media library and Quick actions come with the media library and the slash commands (a later stage).
struct PlusMenuPanel: View {
    let app: AppModel
    @ObservedObject var vm: ChatViewModel
    @ObservedObject var library: LibraryStore
    @State private var webOn = WebSearchSetting.isOn

    private var webPaid: Bool { (library.profile?.planName ?? "Free") != "Free" }

    var body: some View {
        DropdownPanelView {
            DropdownItem(title: "Add files or photos", icon: "plus-add-files", iconSize: 18) {
                for u in ComposerFiles.pick() { if let f = ComposerFiles.load(u) { vm.attach(name: f.name, mime: f.mime, data: f.data) } }
            }
            DropdownItem(title: "Media library", icon: "plus-media-library", iconSize: 18) { vm.showLibrary = true }
            DropdownItem(title: "Add to project", icon: "projects", iconSize: 18, sub: { AnyView(projectSub) })
            DropdownDivider()
            DropdownItem(title: "Connectors", icon: "plus-connectors", iconSize: 18, sub: { AnyView(connectorsSub) })
            DropdownItem(title: "Quick actions", icon: "plus-quick-actions", iconSize: 18, sub: { AnyView(quickSub) })
            DropdownDivider()
            WebSearchRow(on: webOn, paid: webPaid) {
                if webPaid { webOn.toggle(); WebSearchSetting.isOn = webOn }
                else { DropdownHost.shared.close(); app.openSettings("billing") }
            }
        }
    }

    /// ai.js openAddToProjectMenu: every project (the current one lit), then Start a new project.
    private var projectSub: some View {
        DropdownPanelView {
            ForEach(library.projects) { p in
                DropdownItem(title: p.name, icon: "projects") { app.move(vm.chatId, toProject: p.id) }
                    .background(RoundedRectangle(cornerRadius: 8).fill(vm.doc.project == p.id ? AppConfig.navSel : .clear))
            }
            DropdownItem(title: "Start a new project", icon: "plus") { app.newProjectRequest = true }
        }
    }

    /// ai.js buildCommandsSub: every command by what it does, then the hint that "/" opens them in the box.
    private var quickSub: some View {
        DropdownPanelView {
            ForEach(SlashCommand.all) { c in
                DropdownItem(title: c.desc, icon: "plus-caret-right") { vm.startQuick(c) }
            }
            DropdownDivider()
            DropdownItem(title: "Type / in the message box", icon: "keyboard") { vm.focusRequest += 1 }
        }
    }

    /// ai.js buildConnectorsSub: Manage connectors, and Meta Ads, which is always on once connected.
    private var connectorsSub: some View {
        let metaOn = !library.accounts.isEmpty
        return DropdownPanelView {
            DropdownItem(title: "Manage connectors", icon: "plus-connectors") { app.openSettings("mcp") }
            DropdownDivider()
            Button {
                if !metaOn { DropdownHost.shared.close(); app.openSettings("account") }
            } label: {
                HStack(spacing: 8) {
                    LiaIcon("meta", size: 15).foregroundStyle(AppConfig.facebookBlue).frame(width: 17)
                    Text("Meta Ads").font(LiaFont.ui(11.5)).foregroundStyle(AppConfig.ink)
                    Spacer(minLength: 16)
                    MiniSwitch(on: metaOn)
                }
                .padding(.horizontal, 9).padding(.vertical, 6).contentShape(Rectangle())
            }
            .buttonStyle(.liaPlain)
            .liaHover(metaOn ? .off : .fill)
            .liaTip(metaOn ? "Meta Ads is always on" : nil)
        }
    }
}

private struct WebSearchRow: View {
    let on: Bool
    let paid: Bool
    let action: () -> Void
    @State private var hover = false
    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                LiaIcon("plus-web-search", size: 18).scaleEffect(0.88).frame(width: 17)
                Text("Web search").font(LiaFont.ui(11.5))
                Spacer(minLength: 12)
                if paid { MiniSwitch(on: on) }
                else {
                    Text("Pro").font(LiaFont.ui(10, .bold)).foregroundStyle(AppConfig.accent)
                        .padding(.horizontal, 6).padding(.vertical, 1)
                        .background(Capsule().fill(AppConfig.accent.opacity(0.12)))
                }
            }
            .foregroundStyle(AppConfig.ink)
            .padding(.horizontal, 9).padding(.vertical, 6)
            .background(RoundedRectangle(cornerRadius: 8).fill(hover ? AppConfig.surface2 : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.liaPlain)
        .onHover { h in hover = h; if h { DropdownHost.shared.closeSub() } }
        .liaPointer()
    }
}

/// ai.js .ai__sw: the small switch inside a menu row, 26x15.
struct MiniSwitch: View {
    let on: Bool
    var body: some View {
        ZStack(alignment: on ? .trailing : .leading) {
            Capsule().fill(on ? AppConfig.accent : AppConfig.line3)
            Circle().fill(.white).frame(width: 11, height: 11).padding(2)
        }
        .frame(width: 26, height: 15)
        .animation(.easeOut(duration: 0.15), value: on)
    }
}

/// The chat's ad accounts (ai.js openHomeAccMenu): a new chat picks one; an existing chat lists its accounts
/// with a remove x, then "Add ad account…" turns the panel into a search over the rest.
struct AccountMenuPanel: View {
    @ObservedObject var vm: ChatViewModel
    @ObservedObject var library: LibraryStore
    @State private var adding = false
    @State private var query = ""
    @FocusState private var findFocus: Bool

    var body: some View {
        DropdownPanelView(minWidth: 200, padding: 5, radius: 12) {
            if vm.isEmpty {
                list(library.accounts, searchable: library.accounts.count > 6, empty: "Nothing here") { a in
                    DropdownHost.shared.close(); vm.setSingleAccount(a)
                }
            } else if adding {
                let rest = library.accounts.filter { a in !vm.accounts.contains { $0.id == a.id } }
                list(rest, searchable: true, empty: rest.isEmpty ? "Nothing to add" : "No match") { a in
                    vm.toggleAccount(a); adding = false; query = ""
                }
            } else {
                if vm.accounts.isEmpty {
                    Text("No account selected").font(LiaFont.ui(12)).foregroundStyle(AppConfig.text3).padding(.horizontal, 11).padding(.vertical, 9)
                }
                ForEach(vm.accounts, id: \.id) { a in
                    HStack(spacing: 6) {
                        Text(a.name).font(LiaFont.ui(12)).foregroundStyle(AppConfig.text3).lineLimit(1)
                        Spacer(minLength: 12)
                        Button { vm.toggleAccount(AdAccount(id: a.id, name: a.name, blocked: false)) } label: { LiaIcon("x", size: 12).frame(width: 18, height: 18).contentShape(Rectangle()) }
                            .buttonStyle(.liaPlain).liaHover(.icon, radius: 5, tint: AppConfig.text3)
                    }
                    .padding(.horizontal, 11).padding(.vertical, 6)
                }
                Rectangle().fill(AppConfig.line2).frame(height: 1).padding(.vertical, 5)
                PopRow(title: "Add ad account\u{2026}", icon: "plus") { adding = true }
            }
        }
        .frame(maxWidth: 320)
        .task { await library.loadAccounts() }
    }

    @ViewBuilder
    private func list(_ items: [AdAccount], searchable: Bool, empty: String, pick: @escaping (AdAccount) -> Void) -> some View {
        if searchable {
            TextField("", text: $query, prompt: Text("Search accounts\u{2026}").foregroundColor(AppConfig.text4))
                .textFieldStyle(.plain).font(LiaFont.ui(12.5)).focused($findFocus)
                .padding(.horizontal, 11).padding(.vertical, 7)
                .background(RoundedRectangle(cornerRadius: 8).fill(AppConfig.surface2.opacity(0.6)))
                .padding(.bottom, 3)
                .onAppear { DispatchQueue.main.asyncAfter(deadline: .now() + 0.03) { findFocus = true } }
        }
        let rows = items.filter { query.isEmpty || $0.name.lowercased().contains(query.lowercased()) }
        if rows.isEmpty {
            Text(items.isEmpty && !adding ? empty : (query.isEmpty ? empty : "No match"))
                .font(LiaFont.ui(12)).foregroundStyle(AppConfig.text3).padding(.horizontal, 11).padding(.vertical, 9)
        }
        ScrollView {
            VStack(alignment: .leading, spacing: 1) {
                ForEach(rows) { a in PopRow(title: a.name, warn: a.blocked ? "unpaid" : nil) { pick(a) } }
            }
        }
        .frame(maxHeight: 360)
        .fixedSize(horizontal: false, vertical: rows.count < 12)
    }
}

/// .bd-pop__it: 12.5 px medium, 7x11, radius 8.
private struct PopRow: View {
    let title: String
    var icon: String? = nil
    var warn: String? = nil
    let action: () -> Void
    @State private var hover = false
    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                if let icon { LiaIcon(icon, size: 11) }
                Text(title).font(LiaFont.ui(12.5, .medium)).lineLimit(1)
                Spacer(minLength: 8)
                if let warn {
                    Text(warn).font(LiaFont.ui(9.5, .semibold)).tracking(0.3).foregroundStyle(AppConfig.warn)
                        .padding(.horizontal, 7).padding(.vertical, 2)
                        .background(RoundedRectangle(cornerRadius: 6).fill(AppConfig.warn.opacity(0.14)))
                }
            }
            .foregroundStyle(AppConfig.ink)
            .padding(.horizontal, 11).padding(.vertical, 7)
            .background(RoundedRectangle(cornerRadius: 8).fill(hover ? AppConfig.surface2 : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.liaPlain)
        .onHover { hover = $0 }
        .liaPointer()
    }
}
