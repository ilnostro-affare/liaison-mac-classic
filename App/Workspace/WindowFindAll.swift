import SwiftUI

// "Search All Tabs" in the find bar (Arc, Edge): counts the matches in every loaded tab of the
// workspace (sleeping tabs have no page to search and are said to be skipped) and lists the tabs that have any;
// a click selects that tab and the find bar opens there on the same text.

/// The text and the mode carried to the next tab's find bar (each tab's page has its own bar).
@MainActor
enum WSFindCarry {
    static var query: String?
    static var allTabs = false
}

private struct FindHit: Identifiable {
    let tab: BrowserTab
    let n: Int
    var id: UUID { tab.id }
}

struct FindAllTabsList: View {
    @ObservedObject var browser: BrowserModel
    let query: String
    let current: UUID
    let onPick: (BrowserTab) -> Void
    @State private var counts: [FindHit] = []
    @State private var searching = false
    @State private var skipped = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            headerLine
            ForEach(counts) { row in
                FindAllRow(tab: row.tab, count: row.n, current: row.tab.id == current) { onPick(row.tab) }
            }
        }
        .padding(6)
        .frame(width: 300, alignment: .leading)
        // Readable over any page: a strong white under the glass.
        .background(WS.surface.opacity(0.94), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .wsGlass(14)
        .shadow(color: Color.black.opacity(0.10), radius: 14, y: 6)
        .task(id: query + "|" + browser.tabs.map(\.id.uuidString).joined()) { await run() }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text("Matches in all tabs"))
    }

    private var headerLine: some View {
        HStack(spacing: 6) {
            if searching { ProgressView().controlSize(.mini) }
            Text(summary).font(LiaFont.ui(11.5)).foregroundStyle(WS.text3)
        }
        .padding(.horizontal, 6)
        .frame(height: 22)
    }

    private var summary: String {
        if query.isEmpty { return "Type to search every open tab" }
        if searching && counts.isEmpty { return "Searching tabs\u{2026}" }
        let total = counts.reduce(0) { $0 + $1.n }
        var s = counts.isEmpty ? "No matches in other tabs" : "\(total) matches in \(counts.count) tab\(counts.count == 1 ? "" : "s")"
        if skipped > 0 { s += " \u{00B7} \(skipped) sleeping skipped" }
        return s
    }

    private func run() async {
        let q = query
        guard !q.isEmpty else { counts = []; skipped = 0; return }
        try? await Task.sleep(nanoseconds: 200_000_000)
        guard !Task.isCancelled else { return }
        searching = true
        defer { searching = false }
        let tabs = browser.tabs.filter { !$0.isStart }
        let live = tabs.filter { !$0.asleep && $0.pendingURL == nil }
        skipped = tabs.count - live.count
        var out: [FindHit] = []
        for t in live {
            let n = await t.countMatches(q)
            guard !Task.isCancelled else { return }
            if n > 0 { out.append(FindHit(tab: t, n: n)) }
        }
        counts = out.sorted { $0.n > $1.n }
        AccessibilityNotification.Announcement(summary).post()
    }
}

private struct FindAllRow: View {
    @ObservedObject var tab: BrowserTab
    let count: Int
    let current: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                TabFavicon(tab: tab)
                Text(tab.displayTitle).font(LiaFont.ui(12.5, current ? .semibold : .regular)).foregroundStyle(WS.ink).lineLimit(1)
                Spacer(minLength: 6)
                Text("\(count)").font(LiaFont.ui(11.5, .semibold)).monospacedDigit().foregroundStyle(WS.text2)
                    .padding(.horizontal, 6).frame(height: 18)
                    .background(WS.soft, in: Capsule())
            }
            .padding(.horizontal, 6)
            .frame(height: 30)
            .contentShape(Rectangle())
        }
        .buttonStyle(.liaPlain)
        .liaHover(.fill, radius: 8)
        .accessibilityLabel(Text("\(tab.displayTitle), \(count) matches\(current ? ", this tab" : "")"))
    }
}
