import Foundation

// The side panel's web services (App/Workspace/WindowWebPanels.swift), the rules without WebKit:
// 1. a panel page uses one store of its service for every workspace of the Liaison account (the default for every
// service), or, for a service the person switched to per workspace, the workspace browser's own data store;
// 2. one live session of a shared service at a time (Telegram / WhatsApp Web refuse a second one): the other
// workspace's instance is unloaded, and "Open as Tab" hands the page over to the main browser;
// 3. a link that opens a new window or leaves the service opens in the main browser;
// 4. downloads go where the browser's go (one folder per client).

/// Where a panel service keeps its sign-in.
enum WebPanelScope: String, Equatable {
    /// The workspace's own browser store: each workspace signs in on its own (the person's choice per service).
    case workspace
    /// One store for this service in every workspace of the Liaison account (the default).
    case shared
}

/// Where a navigation from a panel page goes.
enum WebPanelRoute: Equatable {
    /// Loads in the panel.
    case stay
    /// Cancelled in the panel and opened in a tab of the current workspace's browser.
    case openInMain(URL)
    /// A link to another app (mailto:, tel:, tg:): handed to macOS.
    case external(URL)
    /// Dropped.
    case ignore
}

enum WebPanelRules {
    // MARK: - services and stores

    /// A service is its registrable domain ("web.telegram.org" -> "telegram.org"); nil: no host.
    static func serviceKey(_ url: URL?) -> String? {
        guard let h = url?.host?.lowercased(), !h.isEmpty else { return nil }
        return registrable(h)
    }

    /// Second-level public suffixes common enough to matter (the same list as SharedSignIns); otherwise the last
    /// two labels.
    private static let twoLevel: Set<String> = [
        "co.uk", "org.uk", "ac.uk", "gov.uk", "com.au", "net.au", "org.au", "co.jp", "ne.jp", "or.jp", "com.br",
        "com.mx", "co.nz", "co.in", "co.za", "com.tr", "com.cn", "com.hk", "com.sg", "co.kr", "com.ar", "com.ua", "co.il",
    ]

    static func registrable(_ host: String) -> String {
        var h = host.lowercased()
        while h.hasPrefix(".") { h.removeFirst() }
        while h.hasSuffix(".") { h.removeLast() }
        let parts = h.split(separator: ".")
        guard parts.count > 2 else { return h }
        let last2 = parts.suffix(2).joined(separator: ".")
        return twoLevel.contains(last2) ? parts.suffix(3).joined(separator: ".") : last2
    }

    /// The Liaison account part of a workspace browser key ("acct|p:profile" -> "acct"), as SharedSignIns groups.
    static func group(of workspaceKey: String?) -> String {
        let k = workspaceKey ?? "_none"
        guard let r = k.range(of: "|p:") else { return k }
        return String(k[..<r.lowerBound])
    }

    /// The browser key whose data store a panel page uses. `.workspace`: the workspace browser's own key (the page
    /// IS that browser: same cookies). `.shared`: one key per Liaison account and service, still "<acct>|p:..." so
    /// SharedSignIns keeps it in the account's group (Google stays signed in there too).
    static func storeKey(workspace: String?, service: String, scope: WebPanelScope) -> String? {
        switch scope {
        case .workspace: return workspace
        case .shared: return group(of: workspace) + "|p:~panel:" + service
        }
    }

    /// Where a service signs in: the same sign-in in every workspace unless the person
    /// switched that service to per workspace (`perWorkspace`). "No stored choice" is shared, for everyone, including
    /// installs from before this rule. No service key (no host): the workspace's own store.
    static func scope(service: String?, perWorkspace: Set<String>) -> WebPanelScope {
        guard let service, !service.isEmpty else { return .workspace }
        return perWorkspace.contains(service) ? .workspace : .shared
    }

    /// The person's per-workspace choices after switching `service` to `scope`.
    static func choosing(_ scope: WebPanelScope, for service: String, perWorkspace: Set<String>) -> Set<String> {
        var out = perWorkspace
        if scope == .workspace { out.insert(service) } else { out.remove(service) }
        return out
    }

    /// One panel web view per workspace and site: each workspace has its own page, open state and place.
    static func viewKey(workspace: String?, site: URL) -> String { (workspace ?? "_none") + "|" + site.absoluteString }

    // MARK: - one live session

    struct Live: Equatable {
        let key: String
        let service: String
        let workspace: String
        let scope: WebPanelScope
    }

    /// The live panel views to unload before `showing` is shown: a shared service's other instances (another
    /// workspace's, all on the same store and session). A per-workspace service has its own store per workspace, so
    /// nothing of it is unloaded.
    static func toUnload(live: [Live], showing: Live) -> [String] {
        guard showing.scope == .shared else { return [] }
        return live.filter { $0.key != showing.key && $0.service == showing.service && $0.scope == .shared }.map(\.key)
    }

    // MARK: - navigation

    /// Link shims that bounce to another site (Instagram's and Facebook's "l." hosts, t.co).
    static let linkShims: Set<String> = ["l.instagram.com", "l.facebook.com", "lm.facebook.com", "l.messenger.com", "t.co", "l.threads.net"]

    /// Other domains that are still the service (its sign-in, its own second domain).
    static let aliases: [String: Set<String>] = [
        "whatsapp.com": ["whatsapp.net"],
        "messenger.com": ["facebook.com"],
        "instagram.com": ["facebook.com"],
        "notion.so": ["notion.com", "notion.site"],
        "slack.com": ["slack-edge.com"],
    ]

    /// Sign-in pages any service may send the person to: they load in the panel, or the sign-in never completes.
    static func isSignIn(_ url: URL) -> Bool {
        let h = url.host?.lowercased() ?? ""
        if ["accounts.google.com", "appleid.apple.com", "login.microsoftonline.com", "login.live.com"].contains(h) { return true }
        if registrable(h) == "facebook.com" {
            let p = url.path.lowercased()
            return p.hasPrefix("/login") || p.contains("/dialog/oauth")
        }
        return false
    }

    /// Whether `url` is still the panel's service `site`.
    static func sameService(_ url: URL, site: URL) -> Bool {
        guard let s = serviceKey(site), let t = serviceKey(url) else { return false }
        return t == s || aliases[s]?.contains(t) == true
    }

    /// A navigation from a panel page.
    /// `newWindow`: the page asked for a new window or tab (target=_blank, window.open without a size).
    /// `userClick`: a link the person clicked (WKNavigationType.linkActivated).
    /// `newTabGesture`: \u{2318}-click or the middle button: a new tab, as in the browser.
    static func route(_ target: URL?, site: URL, mainFrame: Bool, newWindow: Bool, userClick: Bool,
                      newTabGesture: Bool = false) -> WebPanelRoute {
        guard let target, let scheme = target.scheme?.lowercased() else { return newWindow ? .ignore : .stay }
        if ["about", "blob", "data", "javascript"].contains(scheme) { return newWindow ? .ignore : .stay }
        guard ["http", "https"].contains(scheme) else {
            if scheme == "file" { return .ignore }
            return userClick ? .external(target) : .ignore
        }
        if newWindow { return .openInMain(target) }
        guard mainFrame else { return .stay }
        guard userClick else { return .stay }
        if newTabGesture { return .openInMain(target) }
        if let h = target.host?.lowercased(), linkShims.contains(h) { return .openInMain(target) }
        if isSignIn(target) || sameService(target, site: site) { return .stay }
        return .openInMain(target)
    }

    // MARK: - downloads

    /// The folder a download goes to: ~/Downloads, or ~/Downloads/Liaison/<client> with on (as the browser).
    static func downloadFolder(base: URL, client: String?, perClient: Bool) -> URL {
        guard perClient, let name = client?.trimmingCharacters(in: .whitespaces), !name.isEmpty else { return base }
        let safe = name.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
        return base.appendingPathComponent("Liaison", isDirectory: true).appendingPathComponent(safe, isDirectory: true)
    }

    /// "report.csv", then "report (1).csv", ...: the first name that is not taken.
    static func uniqueFile(in dir: URL, name: String, exists: (URL) -> Bool) -> URL {
        let clean = name.isEmpty ? "download" : name.replacingOccurrences(of: "/", with: "-")
        var dest = dir.appendingPathComponent(clean)
        let base = dest.deletingPathExtension().lastPathComponent, ext = dest.pathExtension
        var n = 1
        while exists(dest) {
            dest = dir.appendingPathComponent("\(base) (\(n))" + (ext.isEmpty ? "" : ".\(ext)")); n += 1
        }
        return dest
    }
}
