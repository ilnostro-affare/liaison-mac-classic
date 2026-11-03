import SwiftUI
import WebKit

// Boosts UI: "Edit Site Style\u{2026}" in the tab menu: the person's own CSS for a site (Boosts, matched by
// host suffix). Preview puts it on the open page from our content world without saving; Save keeps it and reloads.

struct BoostEditor: View {
    let target: WSBoostTarget
    let close: () -> Void
    @State private var host = ""
    @State private var css = ""
    @State private var previewed = false

    private var cleanHost: String { host.trimmingCharacters(in: .whitespaces).lowercased() }
    private var existing: Bool { Boosts.all[cleanHost] != nil }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Site Style").font(LiaFont.ui(17, .bold)).foregroundStyle(WS.ink)
            Text("Your own CSS for this site, for example hiding a banner. It styles the page only; no script runs in it.")
                .font(LiaFont.ui(12.5)).foregroundStyle(WS.text2)
                .fixedSize(horizontal: false, vertical: true)
            hostField
            cssField
            buttons
        }
        .padding(20)
        .frame(width: 480)
        .onAppear {
            host = target.host
            css = Boosts.all[target.host] ?? ""
        }
    }

    private var hostField: some View {
        HStack(spacing: 8) {
            Text("Site").font(LiaFont.ui(12.5, .medium)).foregroundStyle(WS.text2).frame(width: 34, alignment: .leading)
            TextField("example.com", text: $host)
                .textFieldStyle(.roundedBorder)
                .font(LiaFont.ui(13))
                .accessibilityLabel(Text("Site"))
                .accessibilityHint(Text("Covers its subdomains too"))
        }
    }

    private var cssField: some View {
        TextEditor(text: $css)
            .font(LiaFont.ui(12.5))
            .scrollContentBackground(.hidden)
            .padding(6)
            .frame(height: 200)
            .background(WS.soft, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(WS.line2, lineWidth: 1))
            .overlay(alignment: .topLeading) {
                if css.isEmpty {
                    Text("[aria-label=\"Promo\"] { display: none !important; }")
                        .font(LiaFont.ui(12.5)).foregroundStyle(WS.text3)
                        .padding(.horizontal, 11).padding(.vertical, 6)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                }
            }
            .accessibilityLabel(Text("CSS"))
    }

    private var buttons: some View {
        HStack(spacing: 8) {
            if existing {
                Button("Remove") { remove() }.buttonStyle(WSButtonStyle(small: true))
            }
            Spacer()
            Button("Cancel") { cancel() }.buttonStyle(WSButtonStyle(small: true))
            Button("Preview") { preview() }.buttonStyle(WSButtonStyle(small: true))
                .disabled(target.tab == nil)
                .accessibilityHint(Text("Shows the style on the open page without saving"))
            Button("Save") { save() }.buttonStyle(WSButtonStyle(primary: true, small: true))
                .disabled(cleanHost.isEmpty)
        }
        .liaPointer()
    }

    private func preview() {
        guard let tab = target.tab else { return }
        previewed = true
        tab.webView.callAsyncJavaScript(Boosts.script, arguments: ["css": css], in: nil, in: BrowserModel.agentWorld) { _ in }
    }

    private func save() {
        guard !cleanHost.isEmpty else { return }
        Boosts.set(css, for: cleanHost)
        target.tab?.reload()
        close()
    }

    private func remove() {
        Boosts.set(nil, for: cleanHost)
        target.tab?.reload()
        close()
    }

    /// A preview that was not saved goes away with a reload.
    private func cancel() {
        if previewed { target.tab?.reload() }
        close()
    }
}
