import AppKit
import WebKit

/// Real input for the open web ("an imitation of a real click, and fast"). The events go
/// straight to the web view as AppKit mouse and key events, so the page gets trusted events exactly as from a person
/// (a script's el.click is marked untrusted and some sites ignore it). They are sent to the web view itself, not
/// through the window, so the agent's overlay above it never takes them. Never used on Meta's pages.
@MainActor
enum WebInput {
    /// A point in the web view's own space with the origin top-left (what AgentBridge measures) -> window space.
    private static func windowPoint(_ p: CGPoint, in w: WKWebView) -> NSPoint {
        let local = NSPoint(x: p.x, y: w.isFlipped ? p.y : w.bounds.height - p.y)
        return w.convert(local, to: nil)
    }

    private static func mouse(_ type: NSEvent.EventType, at p: CGPoint, in w: WKWebView, clicks: Int = 1) -> NSEvent? {
        guard let win = w.window else { return nil }
        return NSEvent.mouseEvent(with: type, location: windowPoint(p, in: w), modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                  windowNumber: win.windowNumber, context: nil, eventNumber: 0, clickCount: clicks,
                                  pressure: type == .leftMouseUp ? 0 : 1)
    }

    /// Move, press, release: ~60 ms in all, so hover menus and :active styles see a person's click.
    @discardableResult
    static func click(at p: CGPoint, in w: WKWebView) async -> Bool {
        guard w.window != nil else { return false }
        if let m = mouse(.mouseMoved, at: p, in: w) { w.mouseMoved(with: m) }
        try? await Task.sleep(nanoseconds: 25_000_000)
        guard let down = mouse(.leftMouseDown, at: p, in: w), let up = mouse(.leftMouseUp, at: p, in: w) else { return false }
        w.mouseDown(with: down)
        try? await Task.sleep(nanoseconds: 35_000_000)
        w.mouseUp(with: up)
        return true
    }

    /// Text as key presses into the focused field (a few ms a character: fast, and still the page's own key events).
    @discardableResult
    static func type(_ text: String, in w: WKWebView, enter: Bool) async -> Bool {
        guard let win = w.window else { return false }
        if win.firstResponder !== w { win.makeFirstResponder(w) }
        for ch in text {
            // A line break is Return ("\r\n" is one Character); anything else goes by its characters.
            let isReturn = ch == "\n" || ch == "\r\n" || ch == "\r"
            let s = isReturn ? "\r" : String(ch)
            if let e = key(.keyDown, s, code: isReturn ? 36 : 0, in: win) { w.keyDown(with: e) }
            if let e = key(.keyUp, s, code: isReturn ? 36 : 0, in: win) { w.keyUp(with: e) }
            try? await Task.sleep(nanoseconds: 4_000_000)
        }
        if enter { await press(code: 36, chars: "\r", in: w) }
        return true
    }

    static func press(code: UInt16, chars: String, in w: WKWebView) async {
        guard let win = w.window else { return }
        if win.firstResponder !== w { win.makeFirstResponder(w) }
        if let e = key(.keyDown, chars, code: code, in: win) { w.keyDown(with: e) }
        try? await Task.sleep(nanoseconds: 20_000_000)
        if let e = key(.keyUp, chars, code: code, in: win) { w.keyUp(with: e) }
    }

    private static func key(_ type: NSEvent.EventType, _ chars: String, code: UInt16, in win: NSWindow) -> NSEvent? {
        NSEvent.keyEvent(with: type, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                         windowNumber: win.windowNumber, context: nil, characters: chars, charactersIgnoringModifiers: chars,
                         isARepeat: false, keyCode: code)
    }
}
