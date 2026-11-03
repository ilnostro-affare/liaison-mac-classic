import SwiftUI
import WebKit

/// "Preview" in the approval card when the change is about an existing ad: Meta's own rendering of the ad in
/// a placement (the API worker /meta/ad-preview returns an iframe to Meta's preview), drawn in a small web view with its own
/// non-persistent store, with a placement switcher (Feed / Instagram / Desktop). When Meta has no preview for it, the
/// ad's creative picture (get_creatives through the MCP gateway, read-only) stands in. Creatives and new ads have no
/// ad id to preview yet, so the button shows only for an ad.
struct ChatAdPreviewButton: View {
    let adId: String
    let auth: AuthStore
    @State private var open = false

    /// The ad id of a change about an ad (nil for anything else).
    static func adId(_ g: Gate) -> String? {
        let kind = (g.entityType.isEmpty ? g.entity : g.entityType).lowercased().trimmingCharacters(in: .whitespaces)
        guard kind == "ad" || kind == "ads" else { return nil }
        let id = g.entityId.filter(\.isNumber)
        return id.isEmpty ? nil : id
    }

    var body: some View {
        Button("Preview") { open = true }
            .buttonStyle(WSButtonStyle(small: true))
            .accessibilityHint(Text("Shows Meta's preview of the ad"))
            .popover(isPresented: $open, arrowEdge: .top) { ChatAdPreviewPanel(adId: adId, auth: auth) }
    }
}

/// The placements the switcher offers (Meta's ad_format names).
enum ChatAdFormat: String, CaseIterable, Identifiable {
    case feed = "MOBILE_FEED_STANDARD"
    case instagram = "INSTAGRAM_STANDARD"
    case desktop = "DESKTOP_FEED_STANDARD"
    var id: String { rawValue }
    var label: String {
        switch self {
        case .feed: return "Feed"
        case .instagram: return "Instagram"
        case .desktop: return "Desktop"
        }
    }
    var size: CGSize { self == .desktop ? CGSize(width: 520, height: 560) : CGSize(width: 350, height: 580) }
}

private struct ChatAdPreviewPanel: View {
    let adId: String
    let auth: AuthStore
    @State private var format: ChatAdFormat = .feed
    /// Meta's preview HTML by placement; "" means Meta had none for it.
    @State private var html: [ChatAdFormat: String] = [:]
    @State private var creative: CreativePreview?
    @State private var creativeFailed = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Picker("Placement", selection: $format) {
                ForEach(ChatAdFormat.allCases) { f in Text(f.label).tag(f) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 300)
            .accessibilityLabel(Text("Placement"))
            content
        }
        .padding(12)
        .task(id: format) { await load(format) }
    }

    @ViewBuilder private var content: some View {
        if let h = html[format], !h.isEmpty {
            ChatAdPreviewWeb(html: h)
                .frame(width: format.size.width, height: format.size.height)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .accessibilityLabel(Text("Meta's \(format.label) preview of ad \(adId)"))
        } else if html[format] != nil {
            fallback
        } else {
            LiaLoadingOrbit(size: 88, label: "Loading the preview").frame(width: 300, height: 200)
        }
    }

    /// Meta had no preview: the creative's picture, or a plain line.
    @ViewBuilder private var fallback: some View {
        if let p = creative, let s = p.best, let url = URL(string: s) {
            VStack(alignment: .leading, spacing: 6) {
                AsyncImage(url: url) { img in img.resizable().scaledToFit() } placeholder: { ProgressView() }
                    .frame(width: 300, height: 300)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .accessibilityLabel(Text("Creative of \(p.name ?? "the ad")"))
                HStack(spacing: 6) {
                    if p.isVideo { Label("Video", systemImage: "play.rectangle").font(LiaFont.ui(11.5, .medium)) }
                    Text(p.name ?? "Ad \(adId)").font(LiaFont.ui(12.5, .medium)).lineLimit(1)
                }
                .foregroundStyle(WS.text2)
                Text("Meta's preview is not available; this is the creative.").font(LiaFont.ui(11)).foregroundStyle(WS.text3)
            }
        } else if creativeFailed {
            Text("No preview for this ad.").font(LiaFont.ui(13)).foregroundStyle(WS.text2).frame(width: 300, height: 60)
        } else {
            LiaLoadingOrbit(size: 88, label: "Loading the creative").frame(width: 300, height: 200)
        }
    }

    private func load(_ f: ChatAdFormat) async {
        guard html[f] == nil else { return }
        let got = await LiaAPI(auth: auth).adPreview(ad: adId, format: f.rawValue)
        html[f] = got ?? ""
        if got == nil, creative == nil, !creativeFailed {
            let c = await LiaAPI(auth: auth).creativePreviews(adIds: [adId])[adId]
            if let c, c.best != nil { creative = c } else { creativeFailed = true }
        }
    }
}

/// Meta's preview iframe in a web view of its own (non-persistent store: no cookies kept, the Liaison session never
/// enters it). Links open in the person's browser.
private struct ChatAdPreviewWeb: NSViewRepresentable {
    let html: String

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> WKWebView {
        let cfg = WKWebViewConfiguration()
        cfg.websiteDataStore = .nonPersistent()
        let v = WKWebView(frame: .zero, configuration: cfg)
        v.navigationDelegate = context.coordinator
        v.setValue(false, forKey: "drawsBackground")
        load(v)
        context.coordinator.loaded = html
        return v
    }

    func updateNSView(_ v: WKWebView, context: Context) {
        if context.coordinator.loaded != html { load(v); context.coordinator.loaded = html }
    }

    private func load(_ v: WKWebView) {
        let page = "<!doctype html><html><head><meta name=viewport content=\"width=device-width\"><style>"
            + "html,body{margin:0;padding:0;background:transparent}body{display:flex;justify-content:center}"
            + "iframe{border:0;max-width:100%}</style></head><body>" + html + "</body></html>"
        v.loadHTMLString(page, baseURL: URL(string: "https://www.facebook.com/"))
    }

    final class Coordinator: NSObject, WKNavigationDelegate {
        var loaded: String?

        func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
                     decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            // A click inside the preview (a link-activated top-level navigation) goes to the person's browser.
            if action.navigationType == .linkActivated, action.targetFrame?.isMainFrame ?? true, let u = action.request.url {
                NSWorkspace.shared.open(u)
                decisionHandler(.cancel)
                return
            }
            decisionHandler(.allow)
        }
    }
}
