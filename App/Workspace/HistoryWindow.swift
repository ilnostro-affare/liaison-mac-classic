import SwiftUI
import AppKit

/// (\u{2318}Y): the current workspace's history, grouped by day, searchable; a click opens the page in
/// a new tab; \u{00D7} on a row forgets it; "Clear\u{2026}" forgets the last hour, today or everything (asked first).
/// Each workspace has its own history (its own browser profile), so clearing never touches another client.
/// A second segment lists the tabs the archive rule closed (Settings \u{2192} Tabs), restorable.
/// A third segment lists the tab groups put away (Saved Groups): Restore or Delete.
/// A skeleton list until the entries are read.
struct HistoryWindow: View {
    @ObservedObject var ws: WorkspaceModel
    /// Opens Settings at a tab ("tabs"): the archive rule lives there.
    var openSettings: (String) -> Void = { _ in }
    @Environment(\.liaDismiss) private var dismiss
    @State private var query = ""
    @State private var entries: [HistoryStore.Entry] = []
    @State private var loaded = false
    @State private var segment: HistorySegment = .history
    @State private var confirm: HistoryClearRange?
    @FocusState private var focused: Bool

    private var account: String? { ws.currentBrowser?.account }
    private var workspaceName: String { ws.profile?.name ?? "this workspace" }

    private var filtered: [HistoryStore.Entry] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return entries }
        return entries.filter { $0.title.lowercased().contains(q) || $0.url.lowercased().contains(q) }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Rectangle().fill(WS.line).frame(height: 1)
            segmentContent
        }
        .frame(width: 760, height: 580)
        .background(WS.surface)
        .latencyAppear("History")   // the canary's click latency
        .overlay { confirmLayer }
        .animation(WSMotion.micro, value: confirm)
        .onAppear {
            firstLoad()
            focused = true
        }
        .onChange(of: ws.profileId) { _, _ in reload() }
        .animation(WSMotion.micro, value: segment)
        .animation(WSMotion.micro, value: loaded)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text("History of \(workspaceName)"))
    }

    // MARK: header

    private var header: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 1) {
                Text("History").font(LiaFont.ui(17, .semibold)).foregroundStyle(WS.ink)
                    .accessibilityAddTraits(.isHeader)
                Text(workspaceName).font(LiaFont.ui(12)).foregroundStyle(WS.text3).lineLimit(1)
            }
            Spacer(minLength: 12)
            segmentPicker
            searchField
            if segment == .history { clearMenu } else if segment == .archived { ArchiveClearButton(browser: ws.currentBrowser) }
            Button { close() } label: {
                Image(systemName: "xmark").font(.system(size: 11, weight: .semibold)).foregroundStyle(WS.text2)
                    .frame(width: 28, height: 28)
                    .background(WS.soft, in: Circle())
            }
            .buttonStyle(.liaPlain).liaPointer()
            .keyboardShortcut(.cancelAction)
            .accessibilityLabel(Text(confirm == nil ? "Close" : "Cancel"))
        }
        .padding(.horizontal, 20)
        .frame(height: 64)
    }

    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass").font(.system(size: 12)).foregroundStyle(WS.text3)
                .accessibilityHidden(true)
            TextField(segment.searchPrompt, text: $query)
                .textFieldStyle(.plain).font(LiaFont.ui(13)).focused($focused)
                // Return opens the first match.
                .onSubmit { if segment == .history, let e = filtered.first { open(e) } }
                .accessibilityLabel(Text(segment.searchPrompt))
        }
        .padding(.horizontal, 10)
        .frame(width: 180, height: 32)
        .background(WS.soft, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private var clearMenu: some View {
        // Glass dropdown, not the system menu.
        DropdownButton(align: .trailing, radius: 12, highlight: false) {
            Text("Clear\u{2026}").font(LiaFont.ui(12.5, .medium)).foregroundStyle(WS.ink)
                .padding(.horizontal, 11)
                .frame(height: 28)
                .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(WS.line2, lineWidth: 1))
                .contentShape(Rectangle())
        } menu: {
            DropdownPanelView {
                ForEach(HistoryClearRange.allCases) { r in
                    DropdownItem(title: r.menuTitle) { confirm = r }
                }
            }
        }
        .fixedSize()
        .disabled(entries.isEmpty)
        .accessibilityLabel(Text("Clear history"))
    }

    /// History | Archived Tabs.
    private var segmentPicker: some View {
        Picker("Show", selection: $segment) {
            ForEach(HistorySegment.allCases) { s in Text(s.title).tag(s) }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .fixedSize()
        .accessibilityLabel(Text("Show history, archived tabs or saved groups"))
    }

    // MARK: list

    @ViewBuilder private var segmentContent: some View {
        switch segment {
        case .history: content
        case .archived: archivedContent
        case .saved: savedContent
        }
    }

    /// Groups put away from the tab row.
    @ViewBuilder private var savedContent: some View {
        if let b = ws.currentBrowser {
            SavedGroupsList(browser: b, query: query,
                            onRestore: { g in
                                withAnimation(WSMotion.spring) { b.restore(g) }
                                ws.show("\u{201C}\(g.name)\u{201D} restored", symbol: "rectangle.stack")
                                close()
                            },
                            onDelete: { g in
                                withAnimation(WSMotion.micro) { b.deleteSaved(g) }
                                ws.show("Saved group \u{201C}\(g.name)\u{201D} deleted", symbol: "trash")
                            },
                            onClose: { close() })
        } else {
            HistoryEmptyState(title: "No workspace open", message: "Saved groups belong to a workspace.", action: "Close") { close() }
        }
    }

    @ViewBuilder private var archivedContent: some View {
        if let b = ws.currentBrowser {
            ArchivedTabsList(browser: b, query: query,
                             onRestore: { a in
                                 b.restoreArchived(a)
                                 close()
                             },
                             onSettings: {
                                 close()
                                 openSettings("tabs")
                             })
        } else {
            HistoryEmptyState(title: "No workspace open", message: "Archived tabs belong to a workspace.", action: "Close") { close() }
        }
    }

    @ViewBuilder private var content: some View {
        let list = filtered
        if !loaded {
            // ; 0.2.10: our orbit (after 300 ms) instead of skeleton rows
            LiaLoadingOrbit(size: 96, label: "Loading history")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .transition(.opacity)
        } else if entries.isEmpty {
            HistoryEmptyState(title: "No history in \(workspaceName) yet",
                              message: "Pages you open here show up by day, so yesterday's report is one search away.",
                              action: "Open New Tab") {
                ws.currentBrowser?.openHome()
                close()
            }
        } else if list.isEmpty {
            HistoryEmptyState(title: "No pages match \u{201C}\(query)\u{201D}",
                              message: "Try a site name or a word from the page title.",
                              action: "Clear Search") { query = "" }
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2, pinnedViews: [.sectionHeaders]) {
                    ForEach(HistoryDay.group(list)) { day in
                        Section {
                            ForEach(day.entries, id: \.url) { e in
                                HistoryRow(entry: e, onOpen: { open(e) }, onRemove: { remove(e) })
                            }
                        } header: {
                            HistoryDayHeader(title: day.title)
                        }
                    }
                }
                .padding(.horizontal, 12)
                .padding(.bottom, 12)
            }
        }
    }

    @ViewBuilder private var confirmLayer: some View {
        if let r = confirm {
            LiaConfirm(title: r.confirmTitle,
                       sub: "Pages visited in \(workspaceName) in that time are forgotten. Sign-ins and open tabs stay.",
                       yes: "Clear", danger: true,
                       onYes: { clear(r) }, onNo: { confirm = nil })
                .transition(.opacity)
        }
    }

    // MARK: actions

    private func reload() { entries = HistoryStore.entries(account) }

    /// The first read happens after the window has drawn (the skeleton shows meanwhile on a large history).
    private func firstLoad() {
        Task { @MainActor in
            await Task.yield()
            reload()
            loaded = true
        }
    }

    private func open(_ e: HistoryStore.Entry) {
        guard let u = URL(string: e.url), let b = ws.currentBrowser else { return }
        b.open(u)
        close()
    }

    private func remove(_ e: HistoryStore.Entry) {
        HistoryStore.remove(e.url, account: account)
        withAnimation(WSMotion.micro) { reload() }
    }

    private func clear(_ r: HistoryClearRange) {
        HistoryStore.clear(account: account, since: r.since)
        confirm = nil
        withAnimation(WSMotion.micro) { reload() }
        ws.show(r.doneText, symbol: "clock.arrow.circlepath")
    }

    private func close() {
        if confirm != nil { confirm = nil; return }
        dismiss()
        ws.showHistory = false
    }
}

/// The window's two lists.
enum HistorySegment: String, CaseIterable, Identifiable {
    case history, archived, saved
    var id: String { rawValue }
    var title: String {
        switch self {
        case .history: return "History"
        case .archived: return "Archived Tabs"
        case .saved: return "Saved Groups"
        }
    }
    var searchPrompt: String {
        switch self {
        case .history: return "Search history"
        case .archived: return "Search archive"
        case .saved: return "Search saved groups"
        }
    }
}

/// "Clear Archive" in the header while the archive is shown.
private struct ArchiveClearButton: View {
    let browser: BrowserModel?

    var body: some View {
        if let b = browser { ArchiveClearFace(browser: b) }
    }
}

private struct ArchiveClearFace: View {
    @ObservedObject var browser: BrowserModel

    var body: some View {
        Button("Clear Archive") { withAnimation(WSMotion.micro) { browser.clearArchive() } }
            .buttonStyle(WSButtonStyle(small: true))
            .disabled(browser.archived.isEmpty)
            .liaPointer()
            .accessibilityLabel(Text("Clear archive"))
    }
}

/// Tabs the archive rule closed, newest first: title, host, when; Restore opens it again as a tab.
private struct ArchivedTabsList: View {
    @ObservedObject var browser: BrowserModel
    let query: String
    let onRestore: (BrowserModel.ArchivedTab) -> Void
    let onSettings: () -> Void

    private var list: [BrowserModel.ArchivedTab] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return browser.archived }
        return browser.archived.filter { $0.title.lowercased().contains(q) || $0.url.lowercased().contains(q) }
    }

    var body: some View {
        let rows = list
        if browser.archived.isEmpty {
            HistoryEmptyState(title: "No archived tabs",
                              message: "When a tab goes unused for the time you choose in Settings \u{2192} Browser \u{2192} Tabs, it closes into this list instead of being lost. Pinned tabs are never archived.",
                              action: "Open Tab Settings", perform: onSettings)
        } else if rows.isEmpty {
            HistoryEmptyState(title: "No archived tabs match \u{201C}\(query)\u{201D}",
                              message: "Try a site name or a word from the page title.",
                              action: "Open Tab Settings", perform: onSettings)
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(rows) { a in ArchivedTabRow(item: a) { onRestore(a) } }
                }
                .padding(12)
            }
        }
    }
}

private struct ArchivedTabRow: View {
    let item: BrowserModel.ArchivedTab
    let onRestore: () -> Void
    @State private var hover = false

    private var url: URL? { URL(string: item.url) }
    private var host: String {
        var h = url?.host ?? item.url
        if h.hasPrefix("www.") { h.removeFirst(4) }
        return h
    }
    private var title: String { item.title.isEmpty ? host : item.title }
    private var when: String {
        Date(timeIntervalSince1970: item.at).formatted(.relative(presentation: .named, unitsStyle: .abbreviated))
    }

    var body: some View {
        HStack(spacing: 10) {
            HistoryFavicon(host: url?.host)
            Text(title).font(LiaFont.ui(13, .medium)).foregroundStyle(WS.ink).lineLimit(1).layoutPriority(1)
            Text(host).font(LiaFont.ui(12)).foregroundStyle(WS.text3).lineLimit(1)
            Spacer(minLength: 8)
            Text(when).font(LiaFont.ui(12)).foregroundStyle(WS.text3).lineLimit(1)
            Button("Restore", action: onRestore)
                .buttonStyle(WSButtonStyle(small: true))
                .liaPointer()
                .accessibilityHidden(true)
        }
        .padding(.leading, 8)
        .padding(.trailing, 4)
        .frame(height: 38)
        .background(hover ? WS.soft : Color.clear, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
        .onHover { hover = $0 }
        .contextMenu {
            Button("Restore", action: onRestore)
            Button("Copy Link") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(item.url, forType: .string)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("\(title), \(host), archived \(when)"))
        .accessibilityAddTraits(.isButton)
        .accessibilityHint(Text("Restores it as a tab"))
        .accessibilityAction(named: Text("Restore"), onRestore)
        .accessibilityAction { onRestore() }
    }
}

/// What "Clear\u{2026}" forgets.
enum HistoryClearRange: String, CaseIterable, Identifiable {
    case hour, today, all
    var id: String { rawValue }

    var menuTitle: String {
        switch self {
        case .hour: return "Last Hour"
        case .today: return "Today"
        case .all: return "All History"
        }
    }

    var confirmTitle: String {
        switch self {
        case .hour: return "Clear the last hour of history?"
        case .today: return "Clear today's history?"
        case .all: return "Clear all history?"
        }
    }

    var doneText: String {
        switch self {
        case .hour: return "Last hour of history cleared"
        case .today: return "Today's history cleared"
        case .all: return "History cleared"
        }
    }

    var since: Date? {
        switch self {
        case .hour: return Date().addingTimeInterval(-3600)
        case .today: return Calendar.current.startOfDay(for: Date())
        case .all: return nil
        }
    }
}

/// One day of history: "Today", "Yesterday", or the date.
struct HistoryDay: Identifiable {
    let id: Date
    let title: String
    let entries: [HistoryStore.Entry]

    /// Newest first. Imported pages are appended with older, unordered dates, so sort first: otherwise one day
    /// shows up as several sections with the same id.
    static func group(_ list: [HistoryStore.Entry]) -> [HistoryDay] {
        let cal = Calendar.current
        var days: [HistoryDay] = []
        var current: (day: Date, items: [HistoryStore.Entry])?
        for e in list.sorted(by: { $0.last > $1.last }) {
            let d = cal.startOfDay(for: Date(timeIntervalSince1970: e.last))
            if let c = current, c.day == d {
                current?.items.append(e)
            } else {
                if let c = current { days.append(HistoryDay(id: c.day, title: title(c.day), entries: c.items)) }
                current = (d, [e])
            }
        }
        if let c = current { days.append(HistoryDay(id: c.day, title: title(c.day), entries: c.items)) }
        return days
    }

    static func title(_ day: Date) -> String {
        let cal = Calendar.current
        if cal.isDateInToday(day) { return "Today" }
        if cal.isDateInYesterday(day) { return "Yesterday" }
        if cal.isDate(day, equalTo: Date(), toGranularity: .year) {
            return day.formatted(.dateTime.weekday(.wide).month(.wide).day())
        }
        return day.formatted(.dateTime.month(.wide).day().year())
    }
}

private struct HistoryDayHeader: View {
    let title: String

    var body: some View {
        Text(title)
            .font(LiaFont.ui(12, .semibold)).foregroundStyle(WS.text3)
            .padding(.horizontal, 8)
            .padding(.top, 12)
            .padding(.bottom, 4)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(WS.surface)
            .accessibilityAddTraits(.isHeader)
    }
}

/// A page: favicon, title, host, time. A click opens it in a new tab; \u{00D7} (on hover) forgets it.
private struct HistoryRow: View {
    let entry: HistoryStore.Entry
    let onOpen: () -> Void
    let onRemove: () -> Void
    @State private var hover = false

    private var url: URL? { URL(string: entry.url) }
    private var host: String {
        var h = url?.host ?? entry.url
        if h.hasPrefix("www.") { h.removeFirst(4) }
        return h
    }
    private var title: String { entry.title.isEmpty ? host : entry.title }
    private var time: String { Date(timeIntervalSince1970: entry.last).formatted(date: .omitted, time: .shortened) }

    var body: some View {
        HStack(spacing: 4) {
            Button(action: onOpen) { face }
                .buttonStyle(.liaPlain)
                .accessibilityLabel(Text("\(title), \(host), \(time)"))
                .accessibilityHint(Text("Opens in a new tab"))
                .accessibilityAction(named: Text("Remove from History"), onRemove)
            Button(action: onRemove) {
                Image(systemName: "xmark").font(.system(size: 9, weight: .bold)).foregroundStyle(WS.text3)
                    .frame(width: 22, height: 22)
            }
            .buttonStyle(.liaPlain)
            .liaHover(.icon, radius: 6)
            .opacity(hover ? 1 : 0)
            .accessibilityLabel(Text("Remove \(title) from history"))
            .accessibilityHidden(!hover)
        }
        .padding(.trailing, 8)
        .background(hover ? WS.soft : Color.clear, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
        .onHover { hover = $0 }
        .contextMenu {
            Button("Open in New Tab", action: onOpen)
            Button("Copy Link") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(entry.url, forType: .string)
            }
            Divider()
            Button("Remove from History", action: onRemove)
        }
    }

    private var face: some View {
        HStack(spacing: 10) {
            HistoryFavicon(host: url?.host)
            Text(title).font(LiaFont.ui(13, .medium)).foregroundStyle(WS.ink).lineLimit(1)
                .layoutPriority(1)
            Text(host).font(LiaFont.ui(12)).foregroundStyle(WS.text3).lineLimit(1)
            Spacer(minLength: 8)
            Text(time).font(LiaFont.ui(12)).foregroundStyle(WS.text3).monospacedDigit()
        }
        .padding(.leading, 8)
        .frame(height: 34)
        .contentShape(Rectangle())
        .liaPointer()
    }
}

/// The site's icon from memory or the disk cache (never fetched from here); a globe without one.
private struct HistoryFavicon: View {
    let host: String?
    @State private var image: NSImage?

    var body: some View {
        Group {
            if let image { Image(nsImage: image).resizable().interpolation(.high) }
            else { Image(systemName: "globe").resizable().foregroundStyle(WS.text3) }
        }
        .frame(width: 16, height: 16)
        .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
        .accessibilityHidden(true)
        .task(id: host) {
            guard let host else { image = nil; return }
            if let c = Favicons.cached(host) { image = c; return }
            image = await Favicons.icon(host: host, candidates: [])
        }
    }
}

/// A friendly line and one action instead of a bare list.
private struct HistoryEmptyState: View {
    let title: String
    let message: String
    let action: String
    let perform: () -> Void

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: "clock").font(.system(size: 30, weight: .light)).foregroundStyle(WS.text3)
                .accessibilityHidden(true)
            Text(title).font(LiaFont.ui(16, .semibold)).foregroundStyle(WS.ink).multilineTextAlignment(.center)
            Text(message).font(LiaFont.ui(13)).foregroundStyle(WS.text2).multilineTextAlignment(.center)
                .frame(maxWidth: 360)
                .fixedSize(horizontal: false, vertical: true)
            Button(action, action: perform)
                .buttonStyle(WSButtonStyle(small: true))
                .liaPointer()
                .padding(.top, 4)
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Tab groups put away, newest first: colour, name, page count; Restore brings the tabs back as the group.
private struct SavedGroupsList: View {
    @ObservedObject var browser: BrowserModel
    let query: String
    let onRestore: (BrowserModel.SavedGroup) -> Void
    let onDelete: (BrowserModel.SavedGroup) -> Void
    let onClose: () -> Void

    private var list: [BrowserModel.SavedGroup] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return browser.savedGroups }
        return browser.savedGroups.filter { g in
            g.name.lowercased().contains(q) || g.pages.contains { $0.title.lowercased().contains(q) || $0.url.lowercased().contains(q) }
        }
    }

    var body: some View {
        content.onAppear { browser.reloadSaved() }
    }

    @ViewBuilder private var content: some View {
        let rows = list
        if browser.savedGroups.isEmpty {
            HistoryEmptyState(title: "No saved groups",
                              message: "Right-click a group\u{2019}s label in the tab row and choose Put Away: its tabs close and the group waits here, one click from coming back.",
                              action: "Close", perform: onClose)
        } else if rows.isEmpty {
            HistoryEmptyState(title: "No saved groups match \u{201C}\(query)\u{201D}",
                              message: "Try the group\u{2019}s name or a site in it.",
                              action: "Close", perform: onClose)
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(rows) { g in
                        SavedGroupRow(group: g, onRestore: { onRestore(g) }, onDelete: { onDelete(g) })
                    }
                }
                .padding(12)
            }
        }
    }
}

private struct SavedGroupRow: View {
    let group: BrowserModel.SavedGroup
    let onRestore: () -> Void
    let onDelete: () -> Void
    @State private var hover = false

    private var count: String { group.pages.count == 1 ? "1 page" : "\(group.pages.count) pages" }
    private var hosts: String {
        var seen: [String] = []
        for p in group.pages {
            guard var h = URL(string: p.url)?.host else { continue }
            if h.hasPrefix("www.") { h.removeFirst(4) }
            if !seen.contains(h) { seen.append(h) }
        }
        return seen.prefix(3).joined(separator: ", ")
    }

    var body: some View {
        HStack(spacing: 10) {
            // Groups have no colour. Never an emoji; their category's icon, else a folder.
            Group {
                LiaIcon(TabGroupCat.icon(group.cat), size: 14).foregroundStyle(WS.text2)
            }
            .frame(width: 16, height: 16)
            .accessibilityHidden(true)
            Text(group.name).font(LiaFont.ui(13, .medium)).foregroundStyle(WS.ink).lineLimit(1).layoutPriority(1)
            Text(count).font(LiaFont.ui(12)).foregroundStyle(WS.text2).lineLimit(1).monospacedDigit()
            Text(hosts).font(LiaFont.ui(12)).foregroundStyle(WS.text3).lineLimit(1)
            Spacer(minLength: 8)
            Button(action: onDelete) {
                Image(systemName: "trash").font(.system(size: 11, weight: .medium)).foregroundStyle(WS.text3)
                    .frame(width: 24, height: 24)
            }
            .buttonStyle(.liaPlain)
            .liaHover(.icon, radius: 6)
            .opacity(hover ? 1 : 0.0001)
            .accessibilityHidden(true)
            Button("Restore", action: onRestore)
                .buttonStyle(WSButtonStyle(small: true))
                .liaPointer()
                .accessibilityHidden(true)
        }
        .padding(.leading, 10)
        .padding(.trailing, 4)
        .frame(height: 40)
        .background(hover ? WS.soft : Color.clear, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
        .onHover { hover = $0 }
        .contextMenu {
            Button("Restore", action: onRestore)
            Divider()
            Button("Delete", action: onDelete)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("Saved group \(group.name), \(count)\(hosts.isEmpty ? "" : ", " + hosts)"))
        .accessibilityAddTraits(.isButton)
        .accessibilityHint(Text("Restores its tabs as a group"))
        .accessibilityAction { onRestore() }
        .accessibilityAction(named: Text("Restore"), onRestore)
        .accessibilityAction(named: Text("Delete"), onDelete)
    }
}
