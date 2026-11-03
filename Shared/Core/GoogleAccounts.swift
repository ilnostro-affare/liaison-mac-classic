import Foundation

/// A Google account signed in in a workspace's browser (Workspace settings, 17).
struct GoogleAccount: Equatable, Hashable {
    let email: String
    let name: String
    /// Position in Google's session list (the `/u/N/` index). Informational: the workspace pins `authuser=<email>`.
    let index: Int
}

/// One cookie of the workspace's store, as plain values (HTTPCookie stays on the App side).
struct GoogleCookie: Equatable {
    let name: String
    let value: String
    let domain: String
    let path: String
    var expires: Date? = nil
}

/// The Google accounts of a browser are read from `accounts.google.com/ListAccounts` (the endpoint Chrome's account
/// reconciler uses), fetched outside any page with the store's own Google cookies. Pure parts live here.
enum GoogleAccounts {
    static let listURL = URL(string: "https://accounts.google.com/ListAccounts?gpsia=1&source=ChromiumBrowser&json=standard")!
    /// A POST, as Chromium sends it (GaiaAuthFetcher: a " " body "to force an HTTP POST"). A GET
    /// answers 400 with an HTML page, so the list never parsed and the card asked a signed-in person to sign in.
    static let listMethod = "POST"
    static let listBody = Data(" ".utf8)

    /// The cookies that say who is signed in to Google (not the ones that rotate on every page): when these change,
    /// the person signed in or out and the list is read again.
    static let sessionCookieNames: Set<String> = ["SID", "__Secure-1PSID", "__Secure-3PSID", "LSID", "__Host-1PLSID",
                                                  "__Host-3PLSID", "SAPISID", "APISID", "HSID", "SSID"]

    static func sessionFingerprint(_ cookies: [GoogleCookie], now: Date = Date()) -> String {
        cookies.filter { c in sessionCookieNames.contains(c.name) && (c.expires.map { $0 > now } ?? true) }
            .map { $0.name + "@" + $0.domain.lowercased() + "=" + $0.value }
            .sorted().joined(separator: ";")
    }

    /// `["gaia.l.a.r", [["gaia.l.a", 1, "Name", "email", photo, valid, 1, 0, null, signedOut, "gaiaId", ...], ...]]`.
    /// Signed-out and invalid sessions are left out. nil: not a ListAccounts answer (a login page, an error).
    static func parse(_ data: Data) -> [GoogleAccount]? {
        guard var s = String(data: data, encoding: .utf8) else { return nil }
        // An anti-XSSI prefix (")]}'") or whitespace before the array.
        if let i = s.firstIndex(of: "[") { s = String(s[i...]) } else { return nil }
        guard let top = (try? JSONSerialization.jsonObject(with: Data(s.utf8))) as? [Any],
              top.count >= 2, (top[0] as? String) == "gaia.l.a.r", let rows = top[1] as? [Any] else { return nil }
        var out: [GoogleAccount] = []
        var seen = Set<String>()
        for (i, r) in rows.enumerated() {
            guard let a = r as? [Any], a.count > 3, let email = (a[3] as? String)?.trimmingCharacters(in: .whitespaces),
                  email.contains("@") else { continue }
            if a.count > 5, let v = number(a[5]), v == 0 { continue }        // not a valid session
            if a.count > 9, let so = number(a[9]), so == 1 { continue }      // signed out
            let key = email.lowercased()
            guard seen.insert(key).inserted else { continue }
            out.append(GoogleAccount(email: email, name: (a[2] as? String) ?? "", index: i))
        }
        return out
    }

    private static func number(_ v: Any) -> Int? {
        if let n = v as? NSNumber { return n.intValue }
        if let b = v as? Bool { return b ? 1 : 0 }
        return nil
    }

    /// The `Cookie` header a browser would send to `url`: domain and path match, not expired. Most specific path first.
    static func cookieHeader(_ cookies: [GoogleCookie], for url: URL, now: Date = Date()) -> String {
        guard let host = url.host?.lowercased() else { return "" }
        let path = url.path.isEmpty ? "/" : url.path
        let fit = cookies.filter { c in
            if let e = c.expires, e <= now { return false }
            var d = c.domain.lowercased()
            while d.hasPrefix(".") { d.removeFirst() }
            guard !d.isEmpty, host == d || host.hasSuffix("." + d) else { return false }
            let p = c.path.isEmpty ? "/" : c.path
            return path == p || path.hasPrefix(p.hasSuffix("/") ? p : p + "/")
        }
        return fit.sorted { $0.path.count > $1.path.count }.map { $0.name + "=" + $0.value }.joined(separator: "; ")
    }

    /// The account the sheet shows chosen: the saved one when it is signed in, else the first signed in; nothing
    /// signed in: the saved one (kept, the person can't pick another).
    static func preselect(saved: String?, signedIn: [GoogleAccount]) -> String? {
        let s = (saved ?? "").trimmingCharacters(in: .whitespaces)
        if let hit = signedIn.first(where: { $0.email.lowercased() == s.lowercased() }) { return hit.email }
        if let first = signedIn.first { return first.email }
        return s.isEmpty ? nil : s
    }
}

/// The Meta business that owns an ad account, read from the ad account list when the list carries it
/// (`business: {id, name}` or `business_id` per row). Today `/meta/accounts` does not: the cell stays hidden.
enum MetaBusiness {
    struct Owner: Equatable { let id: String; let name: String? }

    static func owner(of account: String, in data: Data) -> Owner? {
        let want = account.filter(\.isNumber)
        guard !want.isEmpty, let o = JSONRead.object(data) else { return nil }
        let rows = JSONRead.objects(o, "accounts").isEmpty ? JSONRead.objects(o, "data") : JSONRead.objects(o, "accounts")
        for r in rows {
            let id = (JSONRead.string(r, "id") ?? JSONRead.string(r, "account_id") ?? "").filter(\.isNumber)
            guard id == want else { continue }
            if let b = r["business"] as? JSONObject, let bid = JSONRead.string(b, "id")?.filter(\.isNumber), !bid.isEmpty {
                return Owner(id: bid, name: JSONRead.string(b, "name"))
            }
            if let bid = JSONRead.string(r, "business_id")?.filter(\.isNumber), !bid.isEmpty {
                return Owner(id: bid, name: JSONRead.string(r, "business_name"))
            }
            return nil
        }
        return nil
    }
}
