import SwiftUI
import AppKit

// The workspace's tabs as a grid of pictures (Safari's tab overview). Opened by \u{2318}\u{21E7}\\ or the
// menu (the pinch-in trigger was removed); a click opens a tab, \u{00D7} closes one, Esc or a click outside leaves.

extension Notification.Name {
    /// Posted to toggle the tab overview of the window in front (the menu, the hidden shortcut).
    static let wsTabOverview = Notification.Name("lia.ws.tabOverview")
}

struct TabOverview: View {
    @ObservedObject var browser: BrowserModel
    let accent: Color
    let close: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduce
    @State private var keys = WSKeyMonitor()
    @State private var shown = false

    private static let columns = [GridItem(.adaptive(minimum: 210, maximum: 300), spacing: 16)]

    var body: some View {
        ZStack {
            Color.black.opacity(shown ? 0.14 : 0)
                .contentShape(Rectangle())
                .onTapGesture(perform: close)
                .accessibilityHidden(true)
            panel
                .padding(.horizontal, 28)
                .padding(.top, AppConfig.barHeight + 18)
                .padding(.bottom, 28)
                .scaleEffect(shown || reduce ? 1 : 1.04)
                .opacity(shown ? 1 : 0)
        }
        .onAppear(perform: appear)
        .onDisappear { keys.stop() }
    }

    private func appear() {
        withAnimation(WSMotion.navigation(reduce)) { shown = true }
        keys.start { e in
            MainActor.assumeIsolated { () -> Bool in
                guard e.keyCode == 53 else { return false }
                close()
                return true
            }
        }
        let said: String = "Tab overview, \(browser.tabs.count) tabs"
        AccessibilityNotification.Announcement(said).post()
    }

    private var panel: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            ScrollView {
                LazyVGrid(columns: Self.columns, spacing: 16) {
                    ForEach(browser.tabs) { t in card(t) }
                }
                .padding(6)
                .animation(WSMotion.navigation(reduce), value: browser.tabs.map(\.id))
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .wsGlass(WS.radius)
        .shadow(color: Color.black.opacity(0.18), radius: 30, y: 12)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text("Tab overview"))
        .accessibilityAddTraits(.isModal)
    }

    private var header: some View {
        HStack(spacing: 10) {
            Text("\(browser.tabs.count) tabs").font(LiaFont.ui(15, .semibold)).foregroundStyle(WS.ink)
                .accessibilityAddTraits(.isHeader)
            Spacer()
            Button { _ = browser.openHome(); close() } label: {
                Label("New Tab", systemImage: "plus")
            }
            .buttonStyle(WSButtonStyle(small: true))
            .liaPointer()
            Button("Done", action: close)
                .buttonStyle(WSButtonStyle(primary: true, small: true))
                .liaPointer()
                .accessibilityHint(Text("Escape also closes the overview"))
        }
        .padding(.horizontal, 6)
    }

    private func card(_ t: BrowserTab) -> some View {
        TabOverviewCard(tab: t, selected: t.id == browser.selectedID, accent: accent,
                        open: {
                            browser.selectedID = t.id
                            close()
                        },
                        closeTab: { withAnimation(WSMotion.navigation(reduce)) { browser.close(t) } })
            .transition(reduce ? AnyTransition.opacity : AnyTransition.scale(scale: 0.9).combined(with: .opacity))
    }
}

/// One tab in the overview: its picture (a shimmering skeleton while it is taken), favicon and title; \u{00D7} on hover.
private struct TabOverviewCard: View {
    @ObservedObject var tab: BrowserTab
    let selected: Bool
    let accent: Color
    let open: () -> Void
    let closeTab: () -> Void
    @State private var image: NSImage?
    @State private var loading = true
    @State private var hover = false

    var body: some View {
        Button(action: open) { face }
            .buttonStyle(.liaPlain)
            .liaPointer()
            .overlay(alignment: .topTrailing) { closeButton }
            .onHover { hover = $0 }
            .task(id: tab.id) {
                loading = true
                image = await TabSnapshotCache.shared.image(for: tab)
                loading = false
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text(tab.chipTitle))
            .accessibilityValue(Text(a11yValue))
            .accessibilityAddTraits(.isButton)
            .accessibilityAddTraits(selected ? .isSelected : [])
            .accessibilityAction { open() }
            .accessibilityAction(named: Text("Close Tab"), closeTab)
    }

    private var a11yValue: String {
        var parts: [String] = []
        if let h = tab.savedURL?.host { parts.append(h) }
        if selected { parts.append("current tab") }
        return parts.joined(separator: ", ")
    }

    private var face: some View {
        VStack(alignment: .leading, spacing: 8) {
            thumb
            HStack(spacing: 6) {
                TabFavicon(tab: tab)
                Text(tab.chipTitle).font(LiaFont.ui(12.5, selected ? .semibold : .regular))
                    .foregroundStyle(selected ? WS.ink : WS.text2).lineLimit(1)
            }
            .padding(.horizontal, 2)
        }
        .padding(8)
        .background(selected ? WS.surface : (hover ? WS.washHover : WS.wash),
                    in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(selected ? accent : Color.clear, lineWidth: 2))
        .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .animation(WSMotion.micro, value: hover)
    }

    @ViewBuilder private var thumb: some View {
        ZStack {
            if let image {
                Image(nsImage: image).resizable().aspectRatio(contentMode: .fill)
                    .frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity, alignment: .top)
                    .transition(.opacity)
            } else if loading && !tab.isStart {
                // The page's shape while its picture is taken.
                WSSkeletonBlock(height: 132, radius: 0).wsShimmer()
            } else {
                WS.soft
                Image(systemName: tab.isStart ? "plus" : "globe")
                    .font(.system(size: 24, weight: .light)).foregroundStyle(WS.text3)
            }
        }
        .frame(height: 132)
        .frame(maxWidth: .infinity)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(WS.line, lineWidth: 1))
        .animation(WSMotion.micro, value: image == nil)
    }

    @ViewBuilder private var closeButton: some View {
        if hover {
            Button(action: closeTab) {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .bold)).foregroundStyle(WS.text2)
                    .frame(width: 22, height: 22)
                    .background(.regularMaterial, in: Circle())
                    .overlay(Circle().stroke(WS.line, lineWidth: 1))
            }
            .buttonStyle(.liaPlain)
            .liaPointer()
            .padding(4)
            .transition(.opacity)
            .accessibilityHidden(true)
        }
    }
}
