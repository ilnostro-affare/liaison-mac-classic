import Foundation

// What a conversation keeps (pictures, links) as the chat and the agent's profile draw it.
// Pure pieces, tested on Linux.

/// A picture the person put in a conversation, by its stored key.
enum MediaKeys {
    /// AppConfig.apiBase (Core is built without SwiftUI on Linux, so the host is repeated here).
    static let apiBase = "https://api.liaisone.com"

    /// A media library upload: `{member}/uploads/...` (the API worker creative_upload). Its bytes are served by
    /// api.liaisone.com/meta/upload-asset, which takes the member from the key's own prefix (no signature), so the
    /// address can be rebuilt from the key alone after a restart. A video shows its poster (`<key>.poster.jpg`).
    static func uploadAssetURL(_ key: String?) -> String? {
        guard let key, let slash = key.firstIndex(of: "/") else { return nil }
        let member = String(key[..<slash])
        guard !member.isEmpty, key[slash...].hasPrefix("/uploads/"), !key.contains(" ") else { return nil }
        let lower = key.lowercased()
        let shown = lower.hasSuffix(".mp4") || lower.hasSuffix(".mov") ? key + ".poster.jpg" : key
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        guard let m = member.addingPercentEncoding(withAllowedCharacters: allowed),
              let k = shown.addingPercentEncoding(withAllowedCharacters: allowed) else { return nil }
        return apiBase + "/meta/upload-asset?member_id=" + m + "&key=" + k
    }

    /// A conversation attachment (`ai/{member}/att/...`, /intelligence/attach): only a signed address reads it, and
    /// only the server can sign. True when the item needs that address from the server.
    static func isSignedAttachment(_ key: String?) -> Bool {
        guard let key else { return false }
        return key.hasPrefix("ai/") && key.contains("/att/")
    }

    /// The address a stored picture is drawn from: the server's own (relative to `base` when it is a path), else one
    /// rebuilt from a library key, else nil (an attachment the server has not signed).
    static func pictureURL(url: String?, key: String?, base: String) -> String? {
        if let u = url?.trimmingCharacters(in: .whitespaces), !u.isEmpty {
            return u.hasPrefix("http") ? u : base + (u.hasPrefix("/") ? u : "/" + u)
        }
        return uploadAssetURL(key)
    }
}

/// The Links tab of an agent's profile: only links a person would open.
enum AgentLinks {
    /// Our own hosts and machine addresses (the server's DLG_INTERNAL_HOST): liaisone.com/.io and their subdomains,
    /// *.workers.dev, R2, localhost and private networks. Approval logs and hand-over packets carry these.
    static func isInternal(_ host: String?) -> Bool {
        guard var h = host?.lowercased().trimmingCharacters(in: .whitespaces), !h.isEmpty else { return true }
        if h.hasSuffix(".") { h.removeLast() }
        let ours = ["liaisone.com", "liaisone.io", "workers.dev", "r2.dev", "r2.cloudflarestorage.com"]
        if ours.contains(where: { h == $0 || h.hasSuffix("." + $0) }) { return true }
        if h == "localhost" || h.hasPrefix("127.") || h.hasPrefix("10.") || h.hasPrefix("192.168.") { return true }
        return false
    }

    /// The link's address when it is one to show: http(s), a real host, not ours.
    static func address(_ s: String?) -> URL? {
        guard let s = s?.trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty,
              let u = URL(string: s), let scheme = u.scheme?.lowercased(), scheme == "http" || scheme == "https",
              let host = u.host, host.contains("."), !isInternal(host) else { return nil }
        return u
    }

    /// "www.example.com" -> "example.com".
    static func host(_ u: URL) -> String {
        let h = (u.host ?? "").lowercased()
        return h.hasPrefix("www.") ? String(h.dropFirst(4)) : h
    }

    /// The row's title: the server's title when it says more than the host, else the path's last readable part,
    /// else the host.
    static func title(_ u: URL, served: String?) -> String {
        let h = host(u)
        if let t = served?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty,
           t.lowercased() != h, t.lowercased() != (u.host ?? "").lowercased() {
            return t
        }
        let parts = u.path.split(separator: "/").map { ($0.removingPercentEncoding ?? String($0)) }
        if let last = parts.last(where: { !$0.isEmpty && $0.count <= 80 }) {
            let words = last.replacingOccurrences(of: "-", with: " ").replacingOccurrences(of: "_", with: " ")
            let base = (words as NSString).deletingPathExtension
            if !base.isEmpty, base.rangeOfCharacter(from: .letters) != nil { return base.prefix(1).uppercased() + base.dropFirst() }
        }
        return h
    }

    /// Dev's previews and live sites: the server marks them `name: "dev"`; they live on our own
    /// hosts (*.liaisone.com), which `address` hides, so they are let through by that mark.
    static func isDev(_ it: DlgItem) -> Bool { it.kind == .links && it.name == "dev" }

    /// The address a Links row opens: a person's link by the usual rule; Dev's preview or site when it is http(s)
    /// with a real host, ours included.
    static func link(_ it: DlgItem) -> URL? {
        if let u = address(it.url) { return u }
        guard isDev(it), let s = it.url?.trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty,
              let u = URL(string: s), let scheme = u.scheme?.lowercased(), scheme == "http" || scheme == "https",
              let host = u.host, host.contains(".") else { return nil }
        return u
    }

    /// A Dev row is the published site ("Live site \u{00B7} <slug>"), else a preview.
    static func isLiveSite(_ it: DlgItem) -> Bool { (it.title ?? "").lowercased().hasPrefix("live site") }

    /// The links worth listing, in order, each address once.
    static func visible(_ items: [DlgItem]) -> [DlgItem] {
        var seen = Set<String>()
        return items.filter { it in
            guard it.kind == .links, let u = link(it) else { return false }
            return seen.insert(u.absoluteString).inserted
        }
    }
}
