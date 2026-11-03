import Foundation

// "Reload pressed 2-3 times in a row, afterwards it may not reload at all." The toolbar's Reload
// turns into Stop while the page loads, so the second click of a quick double click landed on Stop and cancelled
// the reload the first click had just started. The pure rules of that button, and of the address a reload uses.
enum ReloadButton {
    enum Action: Equatable { case reload, stop }

    /// A click this soon after a Reload click is another Reload (never Stop), and the button keeps its Reload face.
    static let grace: Double = 1.2

    /// Parameter sinceReload: seconds since this button last reloaded (nil: it did not, or long ago).
    static func showsStop(loading: Bool, sinceReload: Double?) -> Bool {
        guard loading else { return false }
        if let s = sinceReload, s >= 0, s < grace { return false }
        return true
    }

    static func action(loading: Bool, sinceReload: Double?) -> Action {
        showsStop(loading: loading, sinceReload: sinceReload) ? .stop : .reload
    }
}

// A YouTube video opened at a timestamp (`&t=120s`) went back to that OLD time on Reload. YouTube
// never writes the playing position into the address, so a reload of the address replays the `t` the tab was opened
// with. Before a reload (and before a tab goes to sleep) the address gets the position the video is at now.
enum MediaResume {
    /// Below this a video is at its start: the address loses its `t` instead of getting `t=0s`.
    static let minSeconds: Double = 2

    /// A YouTube page whose `t` is the video's start position: /watch, /live/<id>, youtu.be/<id>. Not Shorts (they
    /// have no position in the address) and not the home page or a channel.
    static func applies(to url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased(), scheme == "https" || scheme == "http",
              var host = url.host?.lowercased() else { return false }
        if host.hasPrefix("www.") { host.removeFirst(4) }
        let path = url.path
        if host == "youtu.be" { return path.count > 1 }
        guard host == "youtube.com" || host == "m.youtube.com" || host == "music.youtube.com" else { return false }
        if path == "/watch" {
            return URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.contains { $0.name == "v" && !($0.value ?? "").isEmpty } ?? false
        }
        return path.hasPrefix("/live/") && path.count > "/live/".count
    }

    /// The same address with `t` set to `seconds` (whole seconds, `t=125s`), in place of any `t` it had; under
    /// `minSeconds` the `t` goes. nil: not a page this applies to, or not a usable time (NaN, infinite, negative).
    static func url(_ url: URL, at seconds: Double) -> URL? {
        guard applies(to: url), seconds.isFinite, seconds >= 0,
              var c = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        var items = c.queryItems ?? []
        let value: String? = seconds < minSeconds ? nil : "\(Int(seconds.rounded(.down)))s"
        if let i = items.firstIndex(where: { $0.name == "t" }) {
            if let value { items[i].value = value } else { items.remove(at: i) }
            items.removeAll { $0.name == "t" && $0.value != value }   // a second `t`, if the address had one
        } else if let value {
            items.append(URLQueryItem(name: "t", value: value))
        }
        c.queryItems = items.isEmpty ? nil : items
        // `#t=1m30s` (older share links) would win over the query on YouTube: it goes.
        if let f = c.fragment, f.hasPrefix("t=") { c.fragment = nil }
        return c.url
    }
}
