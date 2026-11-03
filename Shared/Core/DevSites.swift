import Foundation

// Dev's Preview stays private (its pv-<token> address is ours, never shown); beside it
// the Canvas shows the workspace's Live site, and choosing Live publishes the previewed folder there on the person's own
// click. Contract: GET /agents/dev/sites?profile, POST /agents/dev/publish {profile, site?, name?}.

/// One of the workspace's live sites, or the address a new one would get.
struct DevSite: Equatable, Identifiable {
    let slug: String
    let url: URL
    /// The folder it was published from ("" the project's top, nil unknown).
    let dir: String?
    var id: String { slug }
}

struct DevSites: Equatable {
    let sites: [DevSite]
    /// The address a first publish would get.
    let next: DevSite?
    /// "static" | "server" (a dev server: published by Dev, not from here); nil: no preview running.
    let previewKind: String?
    /// The folder the static preview shows.
    let previewDir: String?

    /// Only https addresses of a site on the sites domain (server: <slug>.liaisone.app, and <slug>.liaisone.com
    /// while the move runs; DevPickerHost.domains). Liaison's own hosts, the apex, a preview and anything else: nil.
    static func siteURL(_ s: String?) -> URL? {
        guard let s, let u = URL(string: s), case .site? = DevPickerHost.kind(u) else { return nil }
        return u
    }

    static func parse(_ data: Data) -> Result<DevSites, DevFilesError> {
        guard let o = JSONRead.object(data) else { return .failure(DevFilesError("Could not read the sites.")) }
        guard JSONRead.bool(o, "ok") else { return .failure(DevFilesError(JSONRead.string(o, "error") ?? "Could not read the sites.")) }
        func site(_ x: JSONObject?) -> DevSite? {
            guard let slug = JSONRead.string(x, "slug"), !slug.isEmpty, let u = siteURL(JSONRead.string(x, "url")) else { return nil }
            return DevSite(slug: slug, url: u, dir: JSONRead.string(x, "dir"))
        }
        let pv = o["preview"] as? JSONObject
        return .success(DevSites(sites: JSONRead.objects(o, "sites").compactMap(site), next: site(o["next"] as? JSONObject),
                                 previewKind: JSONRead.string(pv, "kind"), previewDir: JSONRead.string(pv, "dir")))
    }

    /// The live site of what the preview shows: the one published from the same folder, else the only one; nil: none yet.
    var live: DevSite? {
        if let d = previewDir, let s = sites.first(where: { $0.dir == d }) { return s }
        return sites.count == 1 ? sites[0] : nil
    }

    /// Whether Live can publish from the Canvas (a static preview; a dev server's site is built and published by Dev).
    var canPublish: Bool { previewKind == "static" && previewDir != nil }

    /// Our private preview host (pv-<token>.liaisone.app, .liaisone.com before server): never shown, never opened outside the Canvas.
    static func isPrivatePreview(_ u: URL?) -> Bool { u?.host?.lowercased().hasPrefix("pv-") == true }

    /// The other sites published from the same folder as the live one (older "new address" publishes), newest first.
    var siblings: [DevSite] {
        guard let l = live else { return [] }
        return sites.filter { $0.slug != l.slug && $0.dir != nil && $0.dir == l.dir }
    }

    /// POST /agents/dev/publish's answer -> the site it went to.
    static func parsePublished(_ data: Data) -> Result<DevSite, DevFilesError> {
        guard let o = JSONRead.object(data) else { return .failure(DevFilesError("Not published.")) }
        guard JSONRead.bool(o, "ok"), let u = siteURL(JSONRead.string(o, "url")) else {
            return .failure(DevFilesError(JSONRead.string(o, "error") ?? "Not published."))
        }
        return .success(DevSite(slug: JSONRead.string(o, "site") ?? (u.host ?? ""), url: u, dir: nil))
    }
}

/// ("Update overwrites the published project - add 'Publish to a new domain'"): what the two
/// buttons under a live site ask before anything goes public. Update says plainly that it replaces the live site;
/// a new address says the live one stays as it is.
struct DevPublishAsk: Equatable {
    let title: String
    let text: String
    let button: String

    /// Update: the preview replaces what `host` shows now.
    static func replace(host: String) -> DevPublishAsk {
        DevPublishAsk(title: "Replace the live site?",
                      text: "Everything at \(host) is replaced by what the Preview shows now, for anyone who has the address. The site keeps its address.",
                      button: "Replace Live Site")
    }

    /// Publish to a new address: the preview goes to `next` (nil: the server picks a free one) as a site of its own.
    static func fresh(next: String?, keeps live: String) -> DevPublishAsk {
        let at = next.map { "It goes live at \($0)" } ?? "It goes live at a new address"
        return DevPublishAsk(title: "Publish to a new address?",
                             text: "\(at), as a new site for anyone who has the address. \(live) stays exactly as it is.",
                             button: "Publish")
    }
}
