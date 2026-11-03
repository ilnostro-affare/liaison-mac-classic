import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

// "Can't find this site" for a site that works (and works in another workspace). Every workspace
// has its own WKWebsiteDataStore, so its own network session (DNS answers, pooled connections, HTTP/3 alt-svc); one
// of them can fail a lookup or a connect once (after sleep, a Wi-Fi/VPN change, a stale pooled connection) while
// another store is fine. The card used to appear on that first failure. The pure decision of what a failed main-frame
// load does: ignored, tried again after a short pause, or shown as the card.
enum LoadFailure {
    enum Decision: Equatable {
        /// Not worth a card: cancelled, superseded by a newer navigation, a load the page replaced.
        case ignore
        /// Try the same address again after this many seconds (transient network failure).
        case retry(after: Double)
        /// Show the card.
        case show
    }

    static let urlDomain = "NSURLErrorDomain"
    static let webKitDomain = "WebKitErrorDomain"

    /// NSURLErrorCancelled.
    static let cancelled = -999
    /// Lookup / connect failures that are often transient: timed out (-1001), cannot find host (-1003), cannot connect
    /// (-1004), connection lost (-1005), DNS lookup failed (-1006), not connected to the internet (-1009).
    static let transient: Set<Int> = [-1001, -1003, -1004, -1005, -1006, -1009]

    /// Pauses before the automatic tries (attempt 0, 1); after them the card shows (Safari waits about a second).
    static let backoff: [Double] = [1.0, 2.0]
    static var maxRetries: Int { backoff.count }

    /// Parameters:
    /// Attempt: automatic tries already made for this address (0 on the person's own load).
    /// Current: the failure belongs to the tab's latest main-frame navigation (false: a newer one replaced it).
    /// Committed: the page had committed (WKNavigationDelegate didFail, not didFailProvisionalNavigation).
    /// Web: the address is http(s) (only those are tried again).
    /// Showing: a committed page at this same address is still on screen (a reload, the reload after a restore,
    /// a retry of it): the page stays, a network failure never covers it ("Can't find this site"
    /// over admin.example.com that had loaded).
    static func decide(domain: String, code: Int, attempt: Int, current: Bool, committed: Bool, web: Bool = true,
                       showing: Bool = false) -> Decision {
        guard current else { return .ignore }
        if domain == urlDomain && code == cancelled { return .ignore }
        // Frame load interrupted (a policy change, a navigation the page replaced) / plug-in handled.
        if domain == webKitDomain && (code == 102 || code == 204) { return .ignore }
        // The page committed: it is on screen and its host answered. A failure of its later bytes never replaces it
        // with a card (Safari keeps the page too).
        if committed { return .ignore }
        if domain == urlDomain, transient.contains(code) {
            if web, attempt >= 0, attempt < backoff.count { return .retry(after: backoff[attempt]) }
            if showing { return .ignore }
        }
        return .show
    }

    /// The same page for `showing`: scheme, host, path and query alike (the fragment is the page's own).
    static func sameAddress(_ a: URL?, _ b: URL?) -> Bool {
        guard let a, let b else { return false }
        func strip(_ u: URL) -> String {
            guard var c = URLComponents(url: u, resolvingAgainstBaseURL: false) else { return u.absoluteString }
            let host = c.host?.lowercased(), scheme = c.scheme?.lowercased()
            c.fragment = nil
            c.host = host
            c.scheme = scheme
            var s = c.string ?? u.absoluteString
            if s.hasSuffix("/") { s.removeLast() }
            return s
        }
        return strip(a) == strip(b)
    }

    /// The cache policy of a load the person asked to be fresh: Reload revalidates the page with the server (the
    /// cached copy only if the server says it is current), Reload from Origin (\u{2318}\u{21E7}R, Option-click) skips the
    /// cache altogether. A plain navigation keeps the protocol's policy.
    enum Fresh: Equatable { case normal, revalidate, origin }
    static func cachePolicy(_ f: Fresh) -> URLRequest.CachePolicy {
        switch f {
        case .normal: return .useProtocolCachePolicy
        case .revalidate: return .reloadRevalidatingCacheData
        case .origin: return .reloadIgnoringLocalCacheData   // the one WebKit maps to a from-origin load
        }
    }
}
