import SwiftUI
import WebKit

/// A chart or a file served by the worker at a signed URL. Scripts run (charts are interactive), but
/// navigation away from ai.liaisone.com is refused, and nothing here shares a session with the app or
/// with the right-hand browser: the signed URL is the only credential, and it expires.
struct SignedPageView: NSViewRepresentable {
    let url: URL
    /// Documents are paper: always white, never inverted by dark mode.
    var paper = false
    /// Called once the page has finished (or failed) loading, for the sheet's spinner.
    var onLoaded: (() -> Void)? = nil

    func makeCoordinator() -> Coordinator { Coordinator(allowedHost: url.host()) }

    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        let web = WKWebView(frame: .zero, configuration: config)
        context.coordinator.onLoaded = onLoaded
        web.navigationDelegate = context.coordinator
        if paper { web.appearance = NSAppearance(named: .aqua) }
        web.setValue(false, forKey: "drawsBackground")
        web.load(URLRequest(url: url))
        return web
    }

    func updateNSView(_ nsView: WKWebView, context: Context) { context.coordinator.onLoaded = onLoaded }

    final class Coordinator: NSObject, WKNavigationDelegate {
        let allowedHost: String?
        var onLoaded: (() -> Void)?
        init(allowedHost: String?) { self.allowedHost = allowedHost }

        private func finished() {
            let done = onLoaded
            DispatchQueue.main.async { done?() }
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { finished() }
        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { finished() }
        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { finished() }

        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                     decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            let host = navigationAction.request.url?.host()
            let isMain = navigationAction.targetFrame?.isMainFrame ?? true
            if !isMain || host == nil || host == allowedHost || navigationAction.request.url?.scheme == "about" {
                decisionHandler(.allow)
            } else {
                if let u = navigationAction.request.url, navigationAction.navigationType == .linkActivated {
                    NSWorkspace.shared.open(u)
                }
                decisionHandler(.cancel)
            }
        }
    }
}
