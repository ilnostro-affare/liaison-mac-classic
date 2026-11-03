import SwiftUI
import AppKit

/// One palette over the window, two modes.
/// \u{2318}K commands: the app's actions with their keys on the right; typing filters (fuzzy, best first); a
/// calculator answer when the text is arithmetic; "Ask the team" and "Search the web" for anything else.
/// \u{2318}\u{21E7}A tabs: every tab of every workspace (the current one live, in last-used order; the others as they
/// were saved, so no workspace's browser is built just to be listed).
/// \u{2191}/\u{2193} move, Return runs the row, Esc closes (`ws.palette = nil`).
struct CommandPalette: View {
    @ObservedObject var ws: WorkspaceModel
    @EnvironmentObject private var app: AppModel
    @State private var query = ""
    @State private var index = 0
    @State private var keys = WSKeyMonitor()
    @State private var shown = false
    @FocusState private var focused: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var mode: WorkspaceModel.PaletteMode { ws.palette ?? .commands }

    var body: some View {
        let rows = PaletteRows.build(mode: mode, query: query, ws: ws, app: app)
        VStack(spacing: 0) {
            field
            Rectangle().fill(WS.line).frame(height: 1)
            list(rows)
            footer
        }
        .frame(width: 620)
        // Readable over any page: a strong white under the glass.
        .background(WS.surface.opacity(0.94), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .wsGlass(18)
        .shadow(color: Color.black.opacity(0.18), radius: 30, y: 14)
        .scaleEffect(shown || reduceMotion ? 1 : 0.97)
        .opacity(shown ? 1 : 0)
        .padding(.top, 90)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .onAppear {
            // Under the welcome or a modal the palette would be hidden yet take the keys: it does not open there.
            if ws.onboarding || LiaModalCenter.shared.isOpen { ws.palette = nil; return }
            focused = true
            withAnimation(reduceMotion ? WSMotion.micro : WSMotion.spring) { shown = true }
            keys.start { e in handleKey(e) }
        }
        .onDisappear { keys.stop() }
        .onChange(of: query) { _, _ in index = 0 }
        .onChange(of: ws.palette) { _, _ in query = ""; index = 0 }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text(mode == .tabs ? "Search tabs" : "Command palette"))
    }

    private var field: some View {
        HStack(spacing: 10) {
            Image(systemName: mode == .tabs ? "square.on.square" : "command")
                .font(.system(size: 14, weight: .medium)).foregroundStyle(WS.text3)
            TextField(mode == .tabs ? "Search tabs in every workspace" : "Type a command, a sum, or ask Lia",
                      text: $query)
                .textFieldStyle(.plain)
                .font(LiaFont.ui(16))
                .foregroundStyle(WS.ink)
                .focused($focused)
            if !query.isEmpty {
                Button { query = "" } label: {
                    Image(systemName: "xmark.circle.fill").font(.system(size: 13)).foregroundStyle(WS.text3)
                }
                .buttonStyle(.liaPlain).liaPointer()
                .accessibilityLabel(Text("Clear"))
            }
        }
        .padding(.horizontal, 16)
        .frame(height: 52)
    }

    private func list(_ rows: [PaletteRow]) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 1) {
                    ForEach(Array(rows.enumerated()), id: \.element.id) { i, row in
                        rowView(row, i: i, previous: i > 0 ? rows[i - 1].section : nil)
                    }
                    if rows.isEmpty {
                        Text(mode == .tabs ? "No tabs match." : "Nothing matches.")
                            .font(LiaFont.ui(13)).foregroundStyle(WS.text3)
                            .frame(maxWidth: .infinity).padding(.vertical, 22)
                    }
                }
                .padding(6)
            }
            .frame(maxHeight: 380)
            .fixedSize(horizontal: false, vertical: rows.count < 9)
            .onChange(of: index) { _, i in
                guard rows.indices.contains(i) else { return }
                proxy.scrollTo(rows[i].id)
            }
        }
    }

    @ViewBuilder
    private func rowView(_ row: PaletteRow, i: Int, previous: String?) -> some View {
        if let s = row.section, s != previous {
            Text(s.uppercased())
                .font(LiaFont.ui(10.5, .semibold)).foregroundStyle(WS.text3)
                .padding(.horizontal, 10).padding(.top, i == 0 ? 4 : 10).padding(.bottom, 3)
        }
        PaletteRowView(row: row, selected: i == index)
            .id(row.id)
            .contentShape(Rectangle())
            .onHover { if $0 { index = i } }
            .onTapGesture { run(row) }
            .liaPointer()
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isButton)
            .accessibilityAddTraits(i == index ? .isSelected : [])
            .accessibilityAction { run(row) }
    }

    private var footer: some View {
        HStack(spacing: 14) {
            hint("\u{2191}\u{2193}", "Move")
            hint("\u{23CE}", "Run")
            hint("esc", "Close")
            Spacer()
            Button(mode == .tabs ? "Commands  \u{2318}K" : "Tabs  \u{2318}\u{21E7}A") {
                ws.palette = mode == .tabs ? .commands : .tabs
            }
            .buttonStyle(.liaPlain).font(LiaFont.ui(11.5, .medium)).foregroundStyle(WS.text2).liaPointer()
        }
        .padding(.horizontal, 16)
        .frame(height: 34)
        .background(WS.soft.opacity(0.6))
    }

    private func hint(_ key: String, _ label: String) -> some View {
        HStack(spacing: 5) {
            KeyCap(key, small: true)
            Text(label).font(LiaFont.ui(11.5)).foregroundStyle(WS.text3)
        }
    }

    // MARK: keys and actions

    private func handleKey(_ e: NSEvent) -> Bool {
        guard ws.palette != nil, e.window?.isKeyWindow ?? false else { return false }
        if let tv = e.window?.firstResponder as? NSTextView, tv.hasMarkedText() { return false }
        let mods = e.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if mods.contains(.command) || mods.contains(.control) || mods.contains(.option) { return false }
        let rows = PaletteRows.build(mode: mode, query: query, ws: ws, app: app)
        switch e.keyCode {
        case 125: if !rows.isEmpty { index = min(rows.count - 1, index + 1) }; return true
        case 126: if !rows.isEmpty { index = max(0, index - 1) }; return true
        case 36, 76:
            if rows.indices.contains(index) { run(rows[index]) } else { close() }
            return true
        case 53: close(); return true
        default: return false
        }
    }

    private func run(_ row: PaletteRow) {
        close()
        // The palette goes first: an action that opens a sheet or moves focus gets the window to itself.
        DispatchQueue.main.async { row.action() }
    }

    private func close() { ws.palette = nil }
}

// MARK: - rows

struct PaletteRow: Identifiable {
    let id: String
    let title: String
    var detail: String = ""
    var symbol: String = "circle"
    var icon: NSImage? = nil
    var agent: AgentInfo? = nil
    /// Key caps on the right (e.g. ["\u{2318}", "T"]); empty: the Return hint on the selected row.
    var keys: [String] = []
    var section: String? = nil
    /// More words the fuzzy match looks at (not shown).
    var aliases: String = ""
    let action: () -> Void
}

@MainActor
enum PaletteRows {
    static func build(mode: WorkspaceModel.PaletteMode, query: String, ws: WorkspaceModel, app: AppModel) -> [PaletteRow] {
        let q = query.trimmingCharacters(in: .whitespaces)
        switch mode {
        case .tabs: return tabs(q, ws: ws)
        case .commands: return commands(q, ws: ws, app: app)
        }
    }

    // MARK: commands (/10/11, )

    static func commands(_ q: String, ws: WorkspaceModel, app: AppModel) -> [PaletteRow] {
        let all = commandList(ws: ws, app: app)
        guard !q.isEmpty else { return all }
        var out: [PaletteRow] = []
        if let value = Calc.evaluate(q) {
            let s = Calc.format(value)
            out.append(PaletteRow(id: "calc", title: "= \(s)", detail: "Copy the result", symbol: "equal.square", section: "Answer") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(s, forType: .string)
                ws.show("Copied \(s)", symbol: "doc.on.doc")
            })
        }
        let scored = all.compactMap { r -> (PaletteRow, Int)? in
            let a = Fuzzy.score(q, r.title), b = r.aliases.isEmpty ? nil : Fuzzy.score(q, r.aliases).map { $0 - 20 }
            guard let s = [a, b].compactMap({ $0 }).max() else { return nil }
            return (r, s)
        }
        // Stable: equal scores keep the list's own order.
        let ranked = scored.enumerated().sorted { x, y in
            x.element.1 != y.element.1 ? x.element.1 > y.element.1 : x.offset < y.offset
        }
        out += ranked.prefix(12).map { var r = $0.element.0; r.section = nil; return r }
        let lia = ws.roster.first { $0.lead }
        out.append(PaletteRow(id: "ask", title: "Ask Lia: \(q)", detail: "Lia hands it to the right agent", symbol: "sparkles",
                              agent: lia, section: "Anything else") { ws.askTeam(q) })
        out.append(PaletteRow(id: "web", title: "Search the web", detail: q, symbol: "magnifyingglass", section: "Anything else") {
            if let u = BrowserModel.resolve(q) { ws.currentBrowser?.open(u) }
        })
        return out
    }

    private static func commandList(ws: WorkspaceModel, app: AppModel) -> [PaletteRow] {
        let b = ws.currentBrowser
        let tab = b?.selected
        var r: [PaletteRow] = []
        func add(_ id: String, _ title: String, _ symbol: String, _ keys: [String] = [], section: String,
                 aliases: String = "", detail: String = "", _ action: @escaping () -> Void) {
            r.append(PaletteRow(id: id, title: title, detail: detail, symbol: symbol, keys: keys, section: section, aliases: aliases, action: action))
        }
        let tabs = "Tabs", page = "Page", agents = "Agents", spaces = "Workspaces", app_ = "App"
        add("newtab", "New Tab", "plus.square", ["\u{2318}", "T"], section: tabs) { _ = b?.openHome() }
        add("reopen", "Reopen Closed Tab", "arrow.uturn.backward.square", ["\u{2318}", "\u{21E7}", "T"], section: tabs, aliases: "undo close restore") { b?.reopenClosed() }
        add("pin", tab?.pinned == true ? "Unpin Tab" : "Pin Tab", tab?.pinned == true ? "pin.slash" : "pin", ["\u{2318}", "D"], section: tabs, aliases: "bookmark favorite") {
            if let b, let t = b.selected { b.setPinned(t, !t.pinned) }
        }
        add("mute", tab?.muted == true ? "Unmute Tab" : "Mute Tab", tab?.muted == true ? "speaker.wave.2" : "speaker.slash", ["\u{21E7}", "\u{2318}", "M"], section: tabs, aliases: "sound audio") {
            if let t = b?.selected { t.setMuted(!t.muted) }
        }
        add("split", b?.splitID == nil ? "Split View" : "Close Split View", "rectangle.split.2x1", ["\u{2325}", "\u{2318}", "N"], section: tabs, aliases: "side by side") {
            if let b { b.splitID == nil ? b.split() : b.unsplit() }
        }
        add("tabsearch", "Search Tabs", "square.on.square", ["\u{2318}", "\u{21E7}", "A"], section: tabs, aliases: "switch find tab") {
            ws.palette = .tabs
        }
        add("copylink", "Copy Link", "link", ["\u{2318}", "\u{21E7}", "C"], section: page, aliases: "url address share") {
            guard let u = b?.selected?.url?.absoluteString else { return }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(u, forType: .string)
            ws.show("Link copied", symbol: "link")
        }
        add("find", "Find on Page", "text.magnifyingglass", ["\u{2318}", "F"], section: page, aliases: "search text") { ws.openFind() }
        add("reload", "Reload Page", "arrow.clockwise", ["\u{2318}", "R"], section: page, aliases: "refresh") { b?.selected?.reload() }
        add("zoomin", "Zoom In", "plus.magnifyingglass", ["\u{2318}", "+"], section: page, aliases: "bigger larger") { b?.selected?.zoomIn() }
        add("zoomout", "Zoom Out", "minus.magnifyingglass", ["\u{2318}", "\u{2212}"], section: page, aliases: "smaller") { b?.selected?.zoomOut() }
        add("zoom0", "Actual Size", "1.magnifyingglass", ["\u{2318}", "0"], section: page, aliases: "zoom reset 100") { b?.selected?.zoomReset() }
        add("print", "Print", "printer", ["\u{2318}", "P"], section: page, aliases: "pdf") { b?.selected?.printPage() }
        add("downloads", "Downloads", "arrow.down.circle", ["\u{2325}", "\u{2318}", "L"], section: page, aliases: "files") { ws.showDownloads = true }
        add("askSel", "Ask Lia About Selection", "text.bubble", ["\u{2318}", "E"], section: agents, aliases: "explain page") { ws.askAboutSelection() }
        add("team", "Lia Chat", "sparkles", ["\u{2318}", "J"], section: agents, aliases: "team lia conversation") { ws.openTeam() }
        let order = AgentInfo.fallback.filter { !$0.lead }.prefix(7).map(\.id)
        for a in ws.roster where !a.lead {
            let keys = order.firstIndex(of: a.id).map { ["\u{2325}", "\u{2318}", String($0 + 1)] } ?? []
            r.append(PaletteRow(id: "agent-\(a.id)", title: "Talk to \(a.name)", detail: a.shownRole, symbol: "person", agent: a, keys: keys,
                                section: agents, aliases: "\(a.role) \(a.shownRole) agent conversation") { ws.openAgent(a.id) })
        }
        add("journal", "Journal", "list.bullet.rectangle", section: agents, aliases: "history changes log undo") {
            ws.showJournal = true
            Task { await ws.loadJournal() }
        }
        for (i, p) in ws.profiles.enumerated() where p.id != ws.profile?.id {
            r.append(PaletteRow(id: "ws-\(p.id)", title: "Switch to \(p.name)", detail: "", symbol: "circle.fill",
                                keys: i < 9 ? ["\u{2303}", String(i + 1)] : [], section: spaces, aliases: "workspace client") { ws.select(p.id) })
        }
        add("wsSettings", "Workspace Settings", "slider.horizontal.3", section: spaces, aliases: "rename client profile") {
            ws.editingProfile = ws.profile
        }
        add("settings", "Settings", "gearshape", ["\u{2318}", ","], section: app_, aliases: "preferences") { app.openSettings() }
        add("shortcuts", "Keyboard Shortcuts", "keyboard", ["\u{2318}", "/"], section: app_, aliases: "keys help") { ws.showShortcuts = true }
        return r
    }

    // MARK: tabs

    static func tabs(_ q: String, ws: WorkspaceModel) -> [PaletteRow] {
        var out: [PaletteRow] = []
        // The workspace in front: its live tabs, last used first.
        if let p = ws.profile, let b = ws.currentBrowser {
            var rows: [(PaletteRow, Int)] = []
            for (i, t) in b.recentTabs.enumerated() where !t.isStart {
                let host = t.url?.host ?? t.savedURL?.host ?? ""
                let row = PaletteRow(id: "t-\(t.id.uuidString)", title: t.displayTitle, detail: host, symbol: "globe",
                                     icon: t.favicon ?? Favicons.cached(host), keys: i == 0 ? ["Current"] : [], section: p.name) { [weak b] in
                    b?.selectedID = t.id
                }
                if let s = match(q, row.title, host) { rows.append((row, s)) }
            }
            out += order(rows, q)
        }
        // The others, as saved: choosing one opens that workspace and its tab.
        for p in ws.profiles where p.id != ws.profile?.id {
            let key = CompanyProfile.browserKey(account: ws.auth.activeId, profile: p.id)
            guard let saved = BrowserMemory.load(chat: "ws", account: key) else { continue }
            var rows: [(PaletteRow, Int)] = []
            for (i, t) in saved.tabs.enumerated() {
                guard let u = URL(string: t.url) else { continue }
                let host = u.host ?? ""
                let title = t.title.isEmpty ? host : t.title
                let row = PaletteRow(id: "s-\(p.id)-\(i)", title: title, detail: host, symbol: "globe", icon: Favicons.cached(host),
                                     section: p.name) { openSaved(u, in: p, ws: ws) }
                if let s = match(q, title, host) { rows.append((row, s)) }
            }
            out += order(rows, q)
        }
        return out
    }

    private static func match(_ q: String, _ title: String, _ host: String) -> Int? {
        guard !q.isEmpty else { return 0 }
        return [Fuzzy.score(q, title), Fuzzy.score(q, host).map { $0 - 5 }].compactMap { $0 }.max()
    }

    private static func order(_ rows: [(PaletteRow, Int)], _ q: String) -> [PaletteRow] {
        guard !q.isEmpty else { return rows.map(\.0) }
        return rows.enumerated().sorted { x, y in
            x.element.1 != y.element.1 ? x.element.1 > y.element.1 : x.offset < y.offset
        }.map(\.element.0)
    }

    private static func openSaved(_ u: URL, in p: CompanyProfile, ws: WorkspaceModel) {
        ws.select(p.id)
        let b = ws.browser(for: p)
        if let t = b.tabs.first(where: { ($0.savedURL ?? $0.url)?.absoluteString == u.absoluteString }) {
            b.selectedID = t.id
        } else {
            b.open(u)
        }
    }
}

private struct PaletteRowView: View {
    let row: PaletteRow
    let selected: Bool

    var body: some View {
        HStack(spacing: 10) {
            leading.frame(width: 24, height: 24)
            Text(row.title).font(LiaFont.ui(13.5, .medium)).foregroundStyle(WS.ink).lineLimit(1).truncationMode(.middle)
            if !row.detail.isEmpty {
                Text(row.detail).font(LiaFont.ui(12)).foregroundStyle(WS.text3).lineLimit(1).truncationMode(.middle)
            }
            Spacer(minLength: 8)
            trailing
        }
        .padding(.horizontal, 10)
        .frame(height: 36)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(selected ? WS.soft : Color.clear, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    @ViewBuilder private var leading: some View {
        if let a = row.agent { AgentAvatar(agent: a, size: 22) }
        else if let img = row.icon {
            Image(nsImage: img).resizable().interpolation(.high).frame(width: 16, height: 16)
                .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
        } else {
            Image(systemName: row.symbol).font(.system(size: 13, weight: .medium)).foregroundStyle(WS.text2)
        }
    }

    @ViewBuilder private var trailing: some View {
        if row.keys == ["Current"] {
            Text("Current").font(LiaFont.ui(11, .medium)).foregroundStyle(WS.text3)
        } else if !row.keys.isEmpty {
            HStack(spacing: 3) { ForEach(Array(row.keys.enumerated()), id: \.offset) { KeyCap($0.element, small: true) } }
        } else if selected {
            Image(systemName: "return").font(.system(size: 10, weight: .semibold)).foregroundStyle(WS.text3)
        }
    }
}

/// A key drawn as a small rounded cap.
struct KeyCap: View {
    let label: String
    var small = false
    init(_ label: String, small: Bool = false) { self.label = label; self.small = small }

    var body: some View {
        Text(label)
            .font(LiaFont.ui(small ? 10.5 : 12, .medium))
            .foregroundStyle(WS.text2)
            .padding(.horizontal, small ? 4 : 6)
            .frame(minWidth: small ? 18 : 24, minHeight: small ? 18 : 24)
            .background(WS.surface, in: RoundedRectangle(cornerRadius: small ? 5 : 6, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: small ? 5 : 6, style: .continuous).stroke(WS.line2, lineWidth: 1))
            .shadow(color: Color.black.opacity(0.06), radius: 0, y: 1)
            .accessibilityLabel(Text(KeyCap.spoken(label)))
    }

    static func spoken(_ s: String) -> String {
        switch s {
        case "\u{2318}": return "Command"
        case "\u{21E7}": return "Shift"
        case "\u{2325}": return "Option"
        case "\u{2303}": return "Control"
        case "\u{23CE}": return "Return"
        case "\u{2191}": return "Up arrow"
        case "\u{2193}": return "Down arrow"
        case "\u{2190}": return "Left arrow"
        case "\u{2192}": return "Right arrow"
        case "\u{21E5}": return "Tab"
        case "esc": return "Escape"
        default: return s
        }
    }
}

// MARK: - fuzzy match

enum Fuzzy {
    /// nil: `q`'s letters are not all in `text` in order. Higher is better: a prefix, word starts and runs score more,
    /// gaps and a long text score less.
    static func score(_ q: String, _ text: String) -> Int? {
        let p = Array(q.lowercased().filter { $0 != " " }), t = Array(text.lowercased())
        guard !p.isEmpty else { return 0 }
        if text.lowercased().hasPrefix(q.lowercased()) { return 1000 - t.count }
        var score = 0, ti = 0, last = -2
        for c in p {
            var found = false
            while ti < t.count {
                if t[ti] == c {
                    let wordStart = ti == 0 || !(t[ti - 1].isLetter || t[ti - 1].isNumber)
                    score += 10 + (wordStart ? 25 : 0) + (ti == last + 1 ? 15 : 0) - min(ti - last - 1, 8)
                    last = ti; ti += 1; found = true
                    break
                }
                ti += 1
            }
            if !found { return nil }
        }
        if text.lowercased().contains(q.lowercased()) { score += 120 }
        return score - t.count / 4
    }
}

// MARK: - calculator

/// A tiny arithmetic parser: + \u{2212} \u{00D7} \u{00F7} * / ^, parentheses, decimals (a comma when there is no point), a
/// postfix % (= /100). Currency signs and spaces are ignored ("12.4 \u{20AC} / 3"). nil: not a sum, or not finite.
enum Calc {
    static func evaluate(_ input: String) -> Double? {
        var s = input.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("=") { s.removeFirst() }
        let map: [Character: Character] = ["\u{00D7}": "*", "x": "*", "X": "*", "\u{00F7}": "/", "\u{2212}": "-", "\u{2013}": "-"]
        var chars: [Character] = []
        for c in s where !" \u{20AC}$\u{00A3}\u{00A0}_'".contains(c) { chars.append(map[c] ?? c) }
        if !chars.contains("."), chars.contains(",") { chars = chars.map { $0 == "," ? "." : $0 } }
        guard chars.allSatisfy({ "0123456789.+-*/^%()".contains($0) }), chars.contains(where: { $0.isNumber }) else { return nil }
        // A sum needs an operation: a bare number (or "-4") is not one.
        let body = chars.drop { $0 == "-" || $0 == "+" }
        guard body.contains(where: { "+-*/^%".contains($0) }) else { return nil }
        var p = Parser(c: chars)
        guard let v = p.expr(), p.i == chars.count, v.isFinite else { return nil }
        return v
    }

    static func format(_ v: Double) -> String {
        if v == 0 { return "0" }
        if abs(v) >= 1e15 || abs(v) < 1e-6 { return String(format: "%.6g", v) }
        var s = String(format: "%.6f", v)
        while s.hasSuffix("0") { s.removeLast() }
        if s.hasSuffix(".") { s.removeLast() }
        return s == "-0" ? "0" : s
    }

    private struct Parser {
        let c: [Character]
        var i = 0
        var depth = 0

        mutating func peek() -> Character? { i < c.count ? c[i] : nil }

        mutating func expr() -> Double? {
            guard var v = term() else { return nil }
            while let o = peek(), o == "+" || o == "-" {
                i += 1
                guard let r = term() else { return nil }
                v = o == "+" ? v + r : v - r
            }
            return v
        }

        mutating func term() -> Double? {
            guard var v = power() else { return nil }
            while let o = peek(), o == "*" || o == "/" {
                i += 1
                guard let r = power() else { return nil }
                if o == "/" { guard r != 0 else { return nil }; v /= r } else { v *= r }
            }
            return v
        }

        mutating func power() -> Double? {
            guard let b = unary() else { return nil }
            if peek() == "^" {
                i += 1
                guard let e = power() else { return nil }
                return Foundation.pow(b, e)
            }
            return b
        }

        mutating func unary() -> Double? {
            if peek() == "-" { i += 1; return unary().map { -$0 } }
            if peek() == "+" { i += 1; return unary() }
            return postfix()
        }

        mutating func postfix() -> Double? {
            guard var v = primary() else { return nil }
            while peek() == "%" { i += 1; v /= 100 }
            return v
        }

        mutating func primary() -> Double? {
            if peek() == "(" {
                depth += 1
                guard depth < 64 else { return nil }
                i += 1
                guard let v = expr(), peek() == ")" else { return nil }
                i += 1
                depth -= 1
                return v
            }
            let start = i
            var dots = 0
            while let ch = peek(), ch.isNumber || ch == "." { if ch == "." { dots += 1 }; i += 1 }
            guard i > start, dots <= 1 else { return nil }
            return Double(String(c[start..<i]))
        }
    }
}
