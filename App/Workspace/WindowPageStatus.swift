import SwiftUI
import WebKit

// The site answered 404 or 5xx. After each load the main document's status is read in our content
// world (`performance.getEntriesByType('navigation')[0].responseStatus`, Safari 17+; 0 when unknown); 400 or more
// shows a small card at the bottom of the page offering to ask Lia whether the site is down. \u{00D7} hides it for
// that address.

struct PageStatusCard: View {
    @ObservedObject var tab: BrowserTab
    let ws: WorkspaceModel
    @Environment(\.accessibilityReduceMotion) private var reduce
    @State private var code = 0
    @State private var dismissed: URL?
    @State private var probe = 0

    private static let js = "const e = performance.getEntriesByType('navigation')[0]; return (e && e.responseStatus) ? e.responseStatus : 0;"

    private var host: String { tab.url?.host ?? "this site" }
    private var visible: Bool { code >= 400 && dismissed != tab.url && !tab.isLoading && tab.loadError == nil && !tab.crashed }

    var body: some View {
        ZStack(alignment: .bottom) {
            Color.clear
            if visible { card.transition(reduce ? AnyTransition.opacity : AnyTransition.move(edge: .bottom).combined(with: .opacity)) }
        }
        .allowsHitTesting(visible)
        .animation(WSMotion.navigation(reduce), value: visible)
        .onAppear { check() }
        .onChange(of: tab.isLoading) { _, l in if l { code = 0 } else { check() } }
        .onChange(of: tab.url) { _, _ in code = 0 }
    }

    private var card: some View {
        HStack(spacing: 10) {
            Image(systemName: code >= 500 ? "exclamationmark.icloud" : "questionmark.folder")
                .font(.system(size: 13, weight: .semibold)).foregroundStyle(WS.amberInk)
            message
                .font(LiaFont.ui(13)).foregroundStyle(WS.ink)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            Button("Ask") { ask() }
                .buttonStyle(WSButtonStyle(primary: true, small: true))
                .liaPointer()
            Button { dismissed = tab.url } label: {
                Image(systemName: "xmark").font(.system(size: 9.5, weight: .bold)).foregroundStyle(WS.text2)
                    .frame(width: 22, height: 22)
            }
            .buttonStyle(.liaPlain)
            .liaHover(.icon, radius: 7)
            .accessibilityLabel(Text("Dismiss"))
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .frame(maxWidth: 560)
        .wsGlass(16)
        .shadow(color: Color.black.opacity(0.12), radius: 16, y: 6)
        .padding(.bottom, 18)
        .padding(.horizontal, 18)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text("This page answered \(code)"))
    }

    private var message: Text {
        let tail: String = code >= 500 ? ". Ask Lia to check whether \(host) is down?" : ". Ask Lia whether the address is right?"
        let head = Text("This page answered ")
        let num = Text(verbatim: String(code)).fontWeight(.semibold)
        return head + num + Text(verbatim: tail)
    }

    private func check() {
        guard !tab.isStart, !tab.isLoading else { return }
        probe += 1
        let mine = probe
        let t = tab
        Task { @MainActor in
            let r = try? await t.webView.callAsyncJavaScript(Self.js, arguments: [:], in: nil, contentWorld: BrowserModel.agentWorld)
            guard mine == probe else { return }
            let n = (r as? NSNumber)?.intValue ?? (r as? Int) ?? 0
            code = n
            if n >= 400 { AccessibilityNotification.Announcement("This page answered \(n)").post() }
        }
    }

    private func ask() {
        let u = tab.url?.absoluteString ?? host
        ws.askTeam(code >= 500
                   ? "\(u) answered \(code). Check whether \(host) is down or it's only this page."
                   : "\(u) answered \(code) (not found). Is the address right, and where should I go instead?")
        dismissed = tab.url
    }
}
