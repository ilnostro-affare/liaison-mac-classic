import Foundation

/// Passwords exported as CSV, for Settings › Browser › Passwords › Import (pure, tested on Linux).
///
/// A third-party app cannot read iCloud Keychain website passwords (Apple keeps them to Safari and the Passwords app),
/// so they come in as the file those apps export:
/// The Passwords app (File › Export All Passwords) and Safari: `Title,URL,Username,Password,Notes,OTPAuth`;
/// Chrome, Edge, Brave, Arc, Dia (Settings › Passwords › Export): `name,url,username,password,note`.
/// Other managers' exports work when they have a url and a password column (Firefox, Bitwarden's `login_uri`...).
enum PasswordCSV {
    enum Format: String, Equatable, Sendable {
        case apple, chromium, other
        var label: String {
            switch self {
            case .apple: return "Passwords app or Safari"
            case .chromium: return "Chrome, Edge, Brave or Arc"
            case .other: return "password manager"
            }
        }
    }

    struct Entry: Equatable, Sendable {
        let title: String
        let url: String
        /// "https" or "http".
        let scheme: String
        /// Lowercased, no port.
        let host: String
        let username: String
        let password: String
        let note: String
    }

    struct Result: Equatable, Sendable {
        var entries: [Entry] = []
        /// Rows without a web address or a password (app entries, notes, passkeys).
        var skipped = 0
        /// nil: the file has no url and password columns, so it is not a password export.
        var format: Format?
    }

    // MARK: - CSV

    /// RFC 4180 rows: quoted fields may hold commas, quotes ("") and line breaks; CRLF, LF or CR end a row; a UTF-8
    /// BOM is dropped; blank lines are skipped.
    static func rows(_ text: String) -> [[String]] {
        var s = Array(text.unicodeScalars)
        if s.first == "\u{FEFF}" { s.removeFirst() }
        var out: [[String]] = []
        var row: [String] = []
        var field = String.UnicodeScalarView()
        var quoted = false
        var i = 0
        func endRow() {
            row.append(String(field))
            field = String.UnicodeScalarView()
            if !(row.count == 1 && row[0].isEmpty) { out.append(row) }
            row = []
        }
        while i < s.count {
            let c = s[i]
            if quoted {
                if c == "\"" {
                    if i + 1 < s.count, s[i + 1] == "\"" { field.append("\""); i += 2; continue }
                    quoted = false
                } else {
                    field.append(c)
                }
                i += 1
                continue
            }
            switch c {
            case "\"":
                quoted = true
            case ",":
                row.append(String(field))
                field = String.UnicodeScalarView()
            case "\r", "\n":
                endRow()
                if c == "\r", i + 1 < s.count, s[i + 1] == "\n" { i += 1 }
            default:
                field.append(c)
            }
            i += 1
        }
        if !field.isEmpty || !row.isEmpty { endRow() }
        return out
    }

    // MARK: - passwords

    private static let urlNames = ["url", "website", "login_uri", "origin", "web site", "login url", "origin_url"]
    private static let userNames = ["username", "login_username", "login", "user", "user name", "email"]
    private static let passwordNames = ["password", "login_password"]
    private static let noteNames = ["notes", "note", "extra", "comments"]
    private static let titleNames = ["title", "name"]

    /// The site of an address: scheme and host. A bare "example.com" counts as https. nil: no web address
    /// (an app entry such as android://, an empty cell).
    static func site(_ raw: String) -> (scheme: String, host: String)? {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else { return nil }
        if !s.contains("://") { s = "https://" + s }
        guard let c = URLComponents(string: s), let scheme = c.scheme?.lowercased(), scheme == "http" || scheme == "https",
              let h = c.host?.lowercased(), !h.isEmpty, h.contains(".") || h == "localhost" else { return nil }
        return (scheme, h.hasSuffix(".") ? String(h.dropLast()) : h)
    }

    static func parse(_ text: String) -> Result {
        let all = rows(text)
        guard let head = all.first else { return Result() }
        let names = head.map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
        func col(_ wanted: [String]) -> Int? {
            for w in wanted { if let i = names.firstIndex(of: w) { return i } }
            return nil
        }
        guard let urlCol = col(urlNames), let pwCol = col(passwordNames) else { return Result() }
        let userCol = col(userNames), noteCol = col(noteNames), titleCol = col(titleNames)
        var r = Result()
        if names.contains("otpauth") || (names.contains("title") && names.contains("notes")) { r.format = .apple }
        else if names.contains("name") && names.contains("url") && names.contains("note") { r.format = .chromium }
        else { r.format = .other }
        var index: [String: Int] = [:]
        for row in all.dropFirst() {
            func cell(_ i: Int?) -> String { guard let i, i < row.count else { return "" }; return row[i] }
            let password = cell(pwCol)
            guard !password.isEmpty, let site = site(cell(urlCol)) else { r.skipped += 1; continue }
            let e = Entry(title: cell(titleCol).trimmingCharacters(in: .whitespacesAndNewlines), url: cell(urlCol).trimmingCharacters(in: .whitespacesAndNewlines),
                          scheme: site.scheme, host: site.host, username: cell(userCol).trimmingCharacters(in: .whitespacesAndNewlines),
                          password: password, note: cell(noteCol))
            // The same account twice (an export can repeat one): the later row wins.
            let key = e.scheme + "://" + e.host + "|" + e.username
            if let at = index[key] { r.entries[at] = e } else { index[key] = r.entries.count; r.entries.append(e) }
        }
        return r
    }
}

// MARK: - Chromium's own store

extension PasswordCSV {
    /// One row of a Chromium profile's `Login Data` (`logins`: origin_url, username_value, password_value) whose
    /// password was decrypted (the browser's "Safe Storage" key, the same "v10" AES-CBC as its cookies, without the
    /// cookies' 32-byte host hash). nil: no web address, no password, or bytes that are not text.
    static func chromiumLogin(origin: String, username: String, decrypted: Data?) -> Entry? {
        guard let d = decrypted, let password = String(data: d, encoding: .utf8), !password.isEmpty,
              !password.contains("\0"), let site = site(origin) else { return nil }
        return Entry(title: site.host, url: origin, scheme: site.scheme, host: site.host,
                     username: username.trimmingCharacters(in: .whitespacesAndNewlines), password: password, note: "")
    }

    /// The same account once (the later one wins), in the order first seen.
    static func dedupe(_ entries: [Entry]) -> [Entry] {
        var out: [Entry] = []
        var index: [String: Int] = [:]
        for e in entries {
            let key = e.scheme + "://" + e.host + "|" + e.username
            if let at = index[key] { out[at] = e } else { index[key] = out.count; out.append(e) }
        }
        return out
    }
}
