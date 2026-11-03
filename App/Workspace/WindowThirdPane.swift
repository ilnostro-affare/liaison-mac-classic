import SwiftUI

/// A third pane beside a split (Arc goes to four; three is enough). BrowserModel knows one split tab only
/// (`splitID`), so the third tab is kept here, per browser, for the window's life: it shows only while a split is on
/// and the tab is neither the selected nor the split one. The stage draws it (`ThreePaneStage`), the tab menu sets it.
@MainActor
final class WSThirdPane: ObservableObject {
    static let shared = WSThirdPane()
    @Published private var ids: [ObjectIdentifier: UUID] = [:]

    /// The third tab of `b`, when it can be shown now.
    func tab(of b: BrowserModel) -> BrowserTab? {
        guard b.splitTab != nil, let id = ids[ObjectIdentifier(b)], id != b.selectedID, id != b.splitID else { return nil }
        return b.tabs.first { $0.id == id }
    }

    func isThird(_ t: BrowserTab, of b: BrowserModel) -> Bool { tab(of: b)?.id == t.id }

    func set(_ t: BrowserTab?, of b: BrowserModel) {
        let k = ObjectIdentifier(b)
        guard ids[k] != t?.id else { return }
        ids[k] = t?.id
    }

    /// A click on a pane that is not in front: it takes the front; the old front tab takes the clicked pane's role
    /// (split or third), so the three tabs stay the same and keep their places on screen.
    func focus(_ t: BrowserTab, in b: BrowserModel) {
        guard t.id != b.selectedID, let old = b.selectedID, let oldTab = b.tabs.first(where: { $0.id == old }) else { return }
        if t.id == b.splitID {
            b.splitID = old
        } else {
            set(oldTab, of: b)
        }
        b.selectedID = t.id
    }

    /// The pane's tab leaves; the other two stay as a split.
    func leave(_ t: BrowserTab, in b: BrowserModel) {
        let third = tab(of: b)
        if t.id == third?.id { set(nil, of: b); return }
        guard let third else { b.unsplit(); return }
        set(nil, of: b)
        if t.id == b.splitID {
            b.splitID = third.id
        } else if let s = b.splitID {
            // The front tab leaves: the split tab comes in front, the third one becomes the split.
            b.selectedID = s
            b.splitID = third.id
        }
    }
}

/// The tab menu's third-pane items (only while a split is on).
struct WindowThirdPaneMenu: View {
    let tab: BrowserTab
    let browser: BrowserModel
    @ObservedObject private var third = WSThirdPane.shared

    var body: some View {
        if browser.splitTab != nil {
            if third.isThird(tab, of: browser) {
                Button("Close Third Pane") { withAnimation(WSMotion.spring) { third.set(nil, of: browser) } }
            } else {
                Button("Open in Third Pane") { withAnimation(WSMotion.spring) { third.set(tab, of: browser) } }
                    .disabled(tab.id == browser.selectedID || tab.id == browser.splitID)
            }
        }
    }
}

/// (item 15): a split pane on the start page asks which open tab to show there, instead of a cramped
/// new tab. "New tab page" shows the (narrow) new tab instead; with nothing to pick the new tab shows at once.
struct SplitPickPane: View {
    let tab: BrowserTab
    @ObservedObject var browser: BrowserModel
    let showHome: () -> Void
    @ObservedObject private var third = WSThirdPane.shared

    /// Open tabs not already in a pane.
    static func candidates(_ b: BrowserModel, except t: BrowserTab) -> [BrowserTab] {
        let third = WSThirdPane.shared.tab(of: b)?.id
        return b.tabs.filter { !$0.isStart && $0.id != t.id && $0.id != b.selectedID && $0.id != b.splitID && $0.id != third }
    }

    var body: some View {
        let list = Self.candidates(browser, except: tab)
        VStack(alignment: .leading, spacing: 10) {
            Text("Pick a tab").font(LiaFont.ui(15, .semibold)).foregroundStyle(WS.ink).accessibilityAddTraits(.isHeader)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(list) { t in SplitPickRow(tab: t) { pick(t) } }
                }
            }
            .frame(maxHeight: 360)
            .fixedSize(horizontal: false, vertical: true)
            Button("New tab page", action: showHome).buttonStyle(WSButtonStyle(small: true))
        }
        .padding(16)
        .frame(maxWidth: 360)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(WS.surface)
    }

    /// The picked tab takes this pane's role; the blank start tab closes.
    private func pick(_ t: BrowserTab) {
        withAnimation(WSMotion.spring) {
            if tab.id == browser.splitID {
                browser.splitID = t.id
            } else if third.isThird(tab, of: browser) {
                third.set(t, of: browser)
            } else if tab.id == browser.selectedID {
                browser.selectedID = t.id
            }
            browser.close(tab)
        }
    }
}

private struct SplitPickRow: View {
    @ObservedObject var tab: BrowserTab
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Group {
                    if let f = tab.favicon { Image(nsImage: f).resizable().interpolation(.high) }
                    else { Image(systemName: "globe").resizable().foregroundStyle(WS.text3) }
                }
                .frame(width: 16, height: 16)
                VStack(alignment: .leading, spacing: 1) {
                    Text(tab.displayTitle).font(LiaFont.ui(13, .medium)).foregroundStyle(WS.ink).lineLimit(1)
                    Text(tab.url?.host ?? "").font(LiaFont.ui(11.5)).foregroundStyle(WS.text2).lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10).padding(.vertical, 7)
            .background(hover ? WS.hover : Color.clear, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.liaPlain)
        .onHover { hover = $0 }
        .liaPointer()
        .accessibilityLabel(Text("Show \(tab.displayTitle) in this pane"))
    }
}
