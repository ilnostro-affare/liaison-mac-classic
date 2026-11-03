import AppKit
import WebKit

/// window.outerWidth / outerHeight / screenX / screenY (Hetzner's robot check looped since day one,
/// Safari passed at once). WKWebView asks its UI delegate for the window's frame through a private, stable method
/// (`_webView:getWindowFrameWithCompletionHandler:`); a delegate without it answers an empty rect, so the page saw a
/// browser window of 0x0, the classic sign of a headless bot, and the check's verdict sent it round again. Every web
/// view's UI delegate in the browser answers with the real window frame (screen coordinates; WebKit flips them).
enum PageWindowFrame {
    @MainActor
    static func of(_ webView: WKWebView) -> CGRect {
        if let w = webView.window { return w.frame }
        // A tab not in a window (asleep, a background agent tab): the screen the app is on, as a full-size window.
        return NSScreen.main?.visibleFrame ?? CGRect(x: 0, y: 0, width: 1440, height: 900)
    }
}
