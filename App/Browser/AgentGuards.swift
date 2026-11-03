import Foundation

/// Where the web agent never acts (product rule): Meta's and Google's ad tools. Met changes those through
/// plans; the browser agent only refuses. One check, used before every click, key, pick or date and every navigate.
enum AgentGuards {
    static let adToolRefusal = "not done: Liaison never acts inside Meta or Google ad tools; Met does that through plans."

    /// Hosts that are an ad tool whatever the path (the host itself or any subdomain of it).
    private static let adHosts = [
        "business.facebook.com", "adsmanager.facebook.com",
        "ads.google.com", "business.google.com", "analytics.google.com", "tagmanager.google.com", "merchants.google.com",
    ]
    /// facebook.com (and its subdomains) only under these paths.
    private static let facebookAdPaths = ["/adsmanager", "/ads/", "/business", "/events_manager"]

    static func isAdTool(url: URL?) -> Bool {
        guard let url, var host = url.host?.lowercased() else { return false }
        if host.hasSuffix(".") { host.removeLast() }
        func under(_ d: String) -> Bool { host == d || host.hasSuffix("." + d) }
        if adHosts.contains(where: under) { return true }
        if under("facebook.com") {
            let path = url.path.lowercased()
            if path == "/ads" || facebookAdPaths.contains(where: { path.hasPrefix($0) }) { return true }
        }
        return false
    }
}
