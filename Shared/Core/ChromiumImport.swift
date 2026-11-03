import Foundation

/// Import from Chromium browsers (Dia, Chrome, Arc, Brave, Edge…): the pure parts, tested on Linux. The Keychain,
/// the AES decryption and WebKit are in App/Workspace/ImporterSignIns.swift.
///
/// Sign-ins: the profile's `Cookies` SQLite (`Network/Cookies` in newer builds). An encrypted value starts with "v10":
/// AES-128-CBC under a key derived from the browser's Keychain password ("<Browser> Safe Storage"). Since cookie DB
/// version 24 the decrypted value starts with a 32-byte SHA-256 of the host, which is dropped here.
/// Tabs: the newest `Sessions/Session_*` (or the old `Current Session`) in SNSS, read defensively; Arc keeps its
/// sidebar in `StorableSidebar.json` next to "User Data".
enum ChromiumImport {
    /// At most this many tabs come from one browser profile.
    static let tabCap = 50

    // MARK: - time

    /// Chromium's times are microseconds since 1601-01-01 (UTC). 0: none.
    static func date(_ v: Int64) -> Date? {
        v > 0 ? Date(timeIntervalSince1970: Double(v) / 1_000_000 - 11_644_473_600) : nil
    }

    // MARK: - cookies

    /// One row of the `cookies` table as read.
    struct Row: Equatable, Sendable {
        var host: String
        var name: String
        var value: String
        var encrypted: Data
        var path: String
        var expires: Int64
        var secure: Bool
        var httpOnly: Bool
        /// 1 unspecified, 0 no restriction, 1 lax, 2 strict.
        var sameSite: Int
        var persistent: Bool
    }

    /// A cookie ready to become an HTTPCookie.
    struct Cookie: Equatable, Sendable {
        let domain: String
        let name: String
        let value: String
        let path: String
        /// nil: a session cookie.
        let expires: Date?
        let secure: Bool
        let httpOnly: Bool
        /// "lax", "strict", "none" or nil (unspecified).
        let sameSite: String?
    }

    static func sameSite(_ v: Int) -> String? {
        switch v {
        case 0: return "none"
        case 1: return "lax"
        case 2: return "strict"
        default: return nil
        }
    }

    /// "v10"/"v11" + ciphertext: the ciphertext. nil: not an encrypted value this importer knows.
    static func ciphertext(_ encrypted: Data) -> Data? {
        let b = [UInt8](encrypted)
        guard b.count > 3, b[0] == 0x76, b[2] == 0x30 || b[2] == 0x31, b[1] == 0x31 else { return nil }   // "v10" / "v11"
        let rest = Data(b[3...])
        return rest.count % 16 == 0 ? rest : nil
    }

    /// The decrypted bytes (padding already removed) as the cookie's value: the 32-byte host hash dropped when the
    /// DB says version 24 or later. nil: not text.
    static func plaintext(_ decrypted: Data, dbVersion: Int) -> String? {
        var d = decrypted
        if dbVersion >= 24 {
            guard d.count >= 32 else { return nil }
            d = d.subdata(in: 32..<d.count)
        }
        return String(data: d, encoding: .utf8)
    }

    /// A row as a cookie. `decrypted`: the decrypted bytes of `encrypted_value` (nil when it could not be decrypted).
    /// nil: expired, no host, or an encrypted value that could not be read.
    static func cookie(_ r: Row, decrypted: Data?, dbVersion: Int, now: Date = Date()) -> Cookie? {
        let host = r.host.trimmingCharacters(in: .whitespaces)
        guard !host.isEmpty, !r.name.isEmpty || !r.value.isEmpty || !r.encrypted.isEmpty else { return nil }
        let value: String
        if r.encrypted.isEmpty {
            value = r.value
        } else {
            guard let d = decrypted, let v = plaintext(d, dbVersion: dbVersion) else { return nil }
            value = v
        }
        guard !value.contains(where: { $0 == "\n" || $0 == "\r" || $0 == "\0" }) else { return nil }
        var expires: Date?
        if r.persistent {
            guard let e = date(r.expires) else { return nil }
            if e <= now { return nil }
            expires = e
        }
        return Cookie(domain: host, name: r.name, value: value, path: r.path.isEmpty ? "/" : r.path, expires: expires,
                      secure: r.secure, httpOnly: r.httpOnly, sameSite: sameSite(r.sameSite))
    }

    /// The Keychain generic password services a browser's cookie key may live under, most likely first.
    /// `browser`: the importer's display name ("Google Chrome", "Dia · Work", "Brave Beta").
    static func safeStorageServices(_ browser: String) -> [String] {
        let base = browser.components(separatedBy: " \u{00B7} ").first?.trimmingCharacters(in: .whitespaces) ?? browser
        let l = base.lowercased()
        var names: [String] = []
        if l.contains("chrome") { names = ["Chrome"] }
        else if l.contains("edge") { names = ["Microsoft Edge"] }
        else if l.contains("brave") { names = ["Brave", "Brave Browser"] }
        else if l.contains("opera") { names = ["Opera"] }
        else if l.contains("yandex") { names = ["Yandex"] }
        else if l.contains("chromium") { names = ["Chromium"] }
        else if l.contains("arc") { names = ["Arc"] }
        else if l.contains("dia") { names = ["Dia"] }
        let first = base.split(separator: " ").first.map(String.init) ?? base
        names += [base, first]
        // without the channel ("Comet Beta" -> "Comet")
        for ch in [" Beta", " Dev", " Canary", " Nightly"] where base.hasSuffix(ch) { names.append(String(base.dropLast(ch.count))) }
        var seen = Set<String>()
        return names.filter { !$0.isEmpty && seen.insert($0).inserted }.map { $0 + " Safe Storage" }
    }

    // MARK: - tabs

    /// The session file to read among a `Sessions` folder's names: the newest `Session_<time>`; nil when none.
    static func sessionFile(_ names: [String]) -> String? {
        var best: (String, UInt64)?
        for n in names where n.hasPrefix("Session_") {
            let t = UInt64(n.dropFirst("Session_".count)) ?? 0
            if best == nil || t > best!.1 { best = (n, t) }
        }
        return best?.0
    }

    /// http(s) only, each once, in order, at most `cap`.
    static func cleanTabs(_ urls: [String], cap: Int = tabCap) -> [String] {
        var out: [String] = []
        var seen = Set<String>()
        for raw in urls {
            guard out.count < cap else { break }
            guard let u = URL(string: raw), let s = u.scheme?.lowercased(), s == "http" || s == "https",
                  let h = u.host, !h.isEmpty else { continue }
            if seen.insert(u.absoluteString).inserted { out.append(u.absoluteString) }
        }
        return out
    }

    /// The open tabs of an SNSS session file (Chromium's session service): per tab the navigation at its selected
    /// index, tabs and windows that were closed left out, in window then tab order. nil: not an SNSS file.
    /// Unknown commands are skipped; a truncated tail (the browser writing right now) ends the read.
    static func sessionTabs(_ data: Data) -> [String]? {
        let b = [UInt8](data)
        guard b.count >= 8, b[0] == 0x53, b[1] == 0x4E, b[2] == 0x53, b[3] == 0x53 else { return nil }   // "SNSS"
        func i32(_ a: ArraySlice<UInt8>, _ off: Int) -> Int32? {
            let s = a.startIndex + off
            guard off >= 0, s + 4 <= a.endIndex else { return nil }
            return Int32(bitPattern: UInt32(a[s]) | UInt32(a[s + 1]) << 8 | UInt32(a[s + 2]) << 16 | UInt32(a[s + 3]) << 24)
        }
        struct Tab {
            var seq: Int
            var navs: [Int32: String] = [:]
            var selected: Int32?
            var window: Int32?
            var index: Int32?
            var closed = false
        }
        var tabs: [Int32: Tab] = [:]
        var windowOrder: [Int32: Int] = [:]
        var closedWindows = Set<Int32>()
        var seq = 0
        func touch(_ id: Int32) { if tabs[id] == nil { tabs[id] = Tab(seq: seq); seq += 1 } }

        var i = 8
        while i + 2 <= b.count {
            let size = Int(b[i]) | Int(b[i + 1]) << 8
            i += 2
            guard size >= 1, i + size <= b.count else { break }
            let cmd = b[i]
            let p = b[(i + 1)..<(i + size)]
            i += size
            switch cmd {
            case 6:   // UpdateTabNavigation: pickle (u32 size) tab_id, index, url string, …
                guard let tab = i32(p, 4), let idx = i32(p, 8), let len = i32(p, 12), len >= 0 else { continue }
                let s = p.startIndex + 16
                guard s + Int(len) <= p.endIndex, let url = String(bytes: b[s..<(s + Int(len))], encoding: .utf8) else { continue }
                touch(tab)
                tabs[tab]?.navs[idx] = url
            case 7:   // SetSelectedNavigationIndex: tab_id, index
                guard let tab = i32(p, 0), let idx = i32(p, 4) else { continue }
                touch(tab)
                tabs[tab]?.selected = idx
            case 0:   // SetTabWindow: window_id, tab_id
                guard let win = i32(p, 0), let tab = i32(p, 4) else { continue }
                touch(tab)
                tabs[tab]?.window = win
                if windowOrder[win] == nil { windowOrder[win] = windowOrder.count }
            case 2:   // SetTabIndexInWindow: tab_id, index
                guard let tab = i32(p, 0), let idx = i32(p, 4) else { continue }
                touch(tab)
                tabs[tab]?.index = idx
            case 16:  // TabClosed: tab_id, close time
                guard let tab = i32(p, 0) else { continue }
                tabs[tab]?.closed = true
            case 17:  // WindowClosed: window_id, close time
                guard let win = i32(p, 0) else { continue }
                closedWindows.insert(win)
            default:
                continue
            }
        }
        let open = tabs.values.filter { t in
            !t.closed && !t.navs.isEmpty && !(t.window.map { closedWindows.contains($0) } ?? false)
        }
        let sorted = open.sorted { a, b in
            let wa = a.window.flatMap { windowOrder[$0] } ?? Int.max, wb = b.window.flatMap { windowOrder[$0] } ?? Int.max
            if wa != wb { return wa < wb }
            let ia = a.index ?? Int32.max, ib = b.index ?? Int32.max
            if ia != ib { return ia < ib }
            return a.seq < b.seq
        }
        let urls: [String] = sorted.compactMap { t in
            if let s = t.selected, let u = t.navs[s] { return u }
            return t.navs.max { $0.key < $1.key }?.value
        }
        return cleanTabs(urls)
    }

    /// Arc's `StorableSidebar.json`: every tab item's `savedURL`, in sidebar order. nil: not that JSON.
    static func arcTabs(_ data: Data) -> [String]? {
        guard let top = try? JSONSerialization.jsonObject(with: data) as? [String: Any], top["sidebar"] != nil else { return nil }
        var urls: [String] = []
        func walk(_ v: Any) {
            if let d = v as? [String: Any] {
                if let tab = d["tab"] as? [String: Any], let u = tab["savedURL"] as? String { urls.append(u) }
                for k in d.keys.sorted() where k != "tab" { walk(d[k]!) }
            } else if let a = v as? [Any] {
                for x in a { walk(x) }
            }
        }
        walk(top["sidebar"]!)
        return cleanTabs(urls)
    }
}
