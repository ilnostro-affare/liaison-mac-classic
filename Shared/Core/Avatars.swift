import Foundation

/// The person's face and the workspaces' pictures. Pure parts; the store and the views are
/// App/Settings/AvatarViews.swift, the server is lia-agents `/agents/avatar` (the backend).

/// Whose picture: the person's, or a workspace's.
enum AvatarWho: Hashable {
    case me
    case workspace(String)

    /// The server's name for it and the cache's: "me", "ws:<profile>".
    var id: String {
        switch self {
        case .me: return "me"
        case .workspace(let p): return "ws:" + p
        }
    }

    /// POST /agents/avatar's body (an empty key clears).
    func body(key: String) -> [String: Any] {
        switch self {
        case .me: return ["target": "me", "key": key]
        case .workspace(let p): return ["target": "ws", "profile": p, "key": key]
        }
    }
}

/// One stored picture: its R2 key (an input file) and a signed address to read it.
struct AvatarEntry: Equatable {
    let key: String
    let url: String
}

/// GET /agents/avatar: `{ok, me: {key, url} | null, workspaces: {profile: {key, url}}}`.
struct AvatarSet: Equatable {
    var me: AvatarEntry?
    var workspaces: [String: AvatarEntry] = [:]

    /// Every picture by `AvatarWho.id`.
    var byId: [String: AvatarEntry] {
        var out: [String: AvatarEntry] = [:]
        if let me { out[AvatarWho.me.id] = me }
        for (p, e) in workspaces { out[AvatarWho.workspace(p).id] = e }
        return out
    }

    static func entry(_ o: JSONObject?) -> AvatarEntry? {
        guard let o, let key = JSONRead.string(o, "key"), key.contains("/att/"),
              let url = JSONRead.string(o, "url"), !url.isEmpty else { return nil }
        return AvatarEntry(key: key, url: url)
    }

    /// nil: not an answer of this route (an error, a login page).
    static func parse(_ data: Data) -> AvatarSet? {
        guard let o = JSONRead.object(data), JSONRead.bool(o, "ok") else { return nil }
        var s = AvatarSet(me: entry(o["me"] as? JSONObject))
        for (p, v) in (o["workspaces"] as? JSONObject) ?? [:] {
            if let e = entry(v as? JSONObject) { s.workspaces[p] = e }
        }
        return s
    }
}

enum PersonAvatar {
    /// The side a picture is stored at (square, never upscaled).
    static let side = 512

    /// The default face's colour: one of the workspaces' palette, picked by a stable hash of the member id (or the
    /// email), so a person keeps their colour on every Mac and launch. Case and spaces never change it.
    static func colorHex(seed: String) -> UInt32 {
        let p = CompanyProfile.palette
        return p[Int(fnv1a(seed.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()) % UInt32(p.count))]
    }

    /// FNV-1a, 32 bits: stable across launches (Swift's `hashValue` is seeded per process).
    static func fnv1a(_ s: String) -> UInt32 {
        var h: UInt32 = 0x811C9DC5
        for b in s.utf8 { h = (h ^ UInt32(b)) &* 0x01000193 }
        return h
    }

    /// The centred square of a `w` x `h` picture (pixels), and the side it is stored at.
    static func crop(width w: Int, height h: Int, max: Int = side) -> (x: Int, y: Int, side: Int, out: Int) {
        let s = Swift.max(0, Swift.min(w, h))
        return ((w - s) / 2, (h - s) / 2, s, Swift.min(s, max))
    }

    /// A folder name for a member's cached pictures: letters, digits, "-" and "_" only.
    static func folder(_ seed: String) -> String {
        let t = seed.lowercased().map { c -> String in (c.isASCII && (c.isLetter || c.isNumber)) || c == "-" || c == "_" ? String(c) : "_" }.joined()
        return t.isEmpty ? "_none" : String(t.prefix(80))
    }
}
