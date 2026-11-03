import Foundation

/// The in-app browser's password manager: which saved accounts a page gets, when to offer saving, and the masking
/// that keeps passwords away from the agents (pure, tested on Linux). The Keychain and WebKit parts are in
/// App/Browser/PasswordStore.swift and PasswordTab.swift.
enum PasswordMatch {
    /// Public suffixes of two labels that are common enough to matter here ("example.co.uk" is a site, "co.uk" is not),
    /// and hosting suffixes whose subdomains belong to different people.
    static let twoLabelSuffixes: Set<String> = [
        "co.uk", "org.uk", "ac.uk", "gov.uk", "me.uk", "ltd.uk", "plc.uk",
        "com.au", "net.au", "org.au", "edu.au", "gov.au", "co.nz", "org.nz", "net.nz",
        "co.jp", "ne.jp", "or.jp", "ac.jp", "go.jp", "co.kr", "or.kr", "co.in", "net.in", "org.in", "co.id", "co.il", "co.za",
        "co.th", "com.br", "net.br", "org.br", "com.mx", "com.ar", "com.co", "com.pe", "com.tr", "com.cn", "net.cn", "org.cn",
        "com.hk", "com.tw", "com.sg", "com.my", "com.ph", "com.pk", "com.vn", "com.eg", "com.sa", "com.ua", "com.pl",
        "github.io", "gitlab.io", "herokuapp.com", "vercel.app", "netlify.app", "pages.dev", "workers.dev", "web.app",
        "firebaseapp.com", "blogspot.com", "myshopify.com", "azurewebsites.net", "cloudfront.net", "appspot.com",
    ]

    /// Lowercased, without a trailing dot.
    static func normalizedHost(_ host: String) -> String {
        var h = host.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        while h.hasSuffix(".") { h.removeLast() }
        return h
    }

    /// The host without a leading "www.": the same site for an exact match.
    static func bareHost(_ host: String) -> String {
        let h = normalizedHost(host)
        return h.hasPrefix("www.") ? String(h.dropFirst(4)) : h
    }

    private static func isIP(_ h: String) -> Bool {
        h.contains(":") || (!h.isEmpty && h.allSatisfy { $0.isNumber || $0 == "." })
    }

    /// The registrable domain (eTLD+1): "accounts.google.com" -> "google.com", "login.bbc.co.uk" -> "bbc.co.uk".
    /// An IP address or a one-label host is itself.
    static func registrableDomain(_ host: String) -> String {
        let h = normalizedHost(host)
        guard !isIP(h) else { return h }
        let parts = h.split(separator: ".").map(String.init)
        guard parts.count > 2 else { return h }
        let lastTwo = parts.suffix(2).joined(separator: ".")
        if twoLabelSuffixes.contains(lastTwo) { return parts.suffix(3).joined(separator: ".") }
        return lastTwo
    }

    /// The same host, "www." aside.
    static func sameHost(_ a: String, _ b: String) -> Bool { bareHost(a) == bareHost(b) }

    /// The same site (registrable domain).
    static func sameSite(_ a: String, _ b: String) -> Bool { registrableDomain(a) == registrableDomain(b) }

    /// Saved accounts for a page on `host`: the ones saved on this very host first, then the ones saved on another
    /// host of the same site (accounts.google.com's page lists mail.google.com's accounts second).
    static func split<T>(_ items: [T], host: String, hostOf: (T) -> String) -> (exact: [T], related: [T]) {
        var exact: [T] = [], related: [T] = []
        for i in items {
            let h = hostOf(i)
            if sameHost(h, host) { exact.append(i) } else if sameSite(h, host) { related.append(i) }
        }
        return (exact, related)
    }

    /// Whether a frame's form may be read or filled: the top page itself, or a frame of the very same host.
    /// A frame of any other origin (an ad, a widget, a payment provider) never is.
    static func frameAllowed(topHost: String?, frameHost: String?, isMain: Bool) -> Bool {
        if isMain { return true }
        guard let t = topHost, let f = frameHost, !t.isEmpty else { return false }
        return normalizedHost(t) == normalizedHost(f)
    }

    enum FillCheck: Equatable { case ok, insecure, notWeb }

    /// Passwords are filled only into https pages; http gets a warning instead.
    static func fillCheck(scheme: String?) -> FillCheck {
        switch scheme?.lowercased() {
        case "https": return .ok
        case "http": return .insecure
        default: return .notWeb
        }
    }
}

/// When to offer saving a password that was just submitted.
enum PasswordOffer {
    enum Decision: Equatable { case none, save, update(user: String) }

    /// An account already saved for the host, with its password when it could be read.
    struct Known: Equatable {
        let user: String
        let password: String?
    }

    static func sameUser(_ a: String, _ b: String) -> Bool {
        a.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == b.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    /// Saving turned off, the site on the "Never" list, an empty password: nothing.
    /// The account is saved with this password: nothing; with another one: "Update password?".
    /// No user name was found: when exactly one account is saved, its password is the one that changed; when this
    /// password is already saved for any account, nothing.
    /// Otherwise: "Save password?".
    static func decide(user: String, password: String, known: [Known], never: Bool, enabled: Bool) -> Decision {
        guard enabled, !never, !password.isEmpty else { return .none }
        let u = user.trimmingCharacters(in: .whitespacesAndNewlines)
        if !u.isEmpty {
            if let k = known.first(where: { sameUser($0.user, u) }) {
                return k.password == password ? .none : .update(user: k.user)
            }
            return .save
        }
        if known.contains(where: { $0.password == password }) { return .none }
        if known.count == 1 { return .update(user: known[0].user) }
        return .save
    }

    /// "/login/" and "/login" are one page.
    static func normalizedPath(_ p: String) -> String {
        var s = p.isEmpty ? "/" : p
        while s.count > 1 && s.hasSuffix("/") { s.removeLast() }
        return s.lowercased()
    }

    /// After a submit: the same page still shows a password field, so the sign-in did not go through (wrong password,
    /// a captcha). Nothing is offered then; a later successful submit is.
    static func loginFailed(submitPath: String, nowPath: String, passwordFieldShown: Bool) -> Bool {
        passwordFieldShown && normalizedPath(submitPath) == normalizedPath(nowPath)
    }
}

/// What reaches the agents of a page never holds a password: AgentBridge masks secret fields in the page itself;
/// this is the second line, applied to everything the bridge hands back to Swift.
enum SecretMask {
    static let dots = "\u{2022}\u{2022}\u{2022}\u{2022}"

    /// The same words AgentBridge's `secret` reads in a field's name, id, label or placeholder.
    static let secretWords = "(password|passwd|passwort|passcode|pwd|contrase|пароль|mot de passe|cvc|cvv|card.?num|card.?no\\b|cc.?num|credit.?card|security.?code|iban|one.?time|(^|[^a-z])otp([^a-z]|$))"

    static func looksSecret(_ words: String) -> Bool {
        !words.isEmpty && words.range(of: secretWords, options: [.regularExpression, .caseInsensitive]) != nil
    }

    /// A text field's value as the agent may see it: masked when the field's own words name a secret.
    static func maskedValue(_ value: String, kind: String, words: String) -> String {
        guard !value.isEmpty, value != dots, kind == "text" || kind == "number", looksSecret(words) else { return value }
        return dots
    }

    /// Every password Liaison saw this session (filled or submitted) replaced by dots wherever it shows up in text: a
    /// page that echoes a password (a "show password" field read as text, a confirmation screen) still sends none.
    /// Secrets shorter than 4 characters are left alone (they would mask ordinary words).
    static func scrub(_ text: String, secrets: [String]) -> String {
        guard !text.isEmpty else { return text }
        var out = text
        for s in Set(secrets).sorted(by: { $0.count > $1.count }) where s.count >= 4 {
            if out.contains(s) { out = out.replacingOccurrences(of: s, with: dots) }
        }
        return out
    }
}

/// Saved accounts are offered AT the sign-in field (Safari, Chrome), not only by the key in the
/// address bar. The page's script reports the focused field's box in CSS pixels of the top page's viewport; this is
/// where the suggestions anchor in the web view (points, y down: WKWebView is flipped) and whether they show at all.
enum PasswordSuggest {
    /// The field's box in the web view's points (CSS pixels times the page zoom and the magnification), clipped to
    /// the view. nil: not a usable box, or the field is outside the visible page.
    static func anchor(x: Double, y: Double, width: Double, height: Double, zoom: Double, view: CGSize) -> CGRect? {
        guard [x, y, width, height, zoom].allSatisfy(\.isFinite), width >= 2, height >= 2, zoom > 0,
              view.width > 0, view.height > 0 else { return nil }
        let r = CGRect(x: x * zoom, y: y * zoom, width: width * zoom, height: height * zoom)
        let clipped = r.intersection(CGRect(origin: .zero, size: view))
        guard !clipped.isNull, clipped.width >= 2, clipped.height >= 2 else { return nil }
        return clipped
    }

    /// The suggestions show for a focus in the top page's sign-in field, on an https page with saved accounts for
    /// it, in a tab the person sees, while no agent is working there, and not right after our own fill focused it.
    static func shows(isMain: Bool, insecure: Bool, accounts: Int, visible: Bool, agentHere: Bool, justFilled: Bool) -> Bool {
        isMain && !insecure && accounts > 0 && visible && !agentHere && !justFilled
    }

    /// How long after a fill a focus is ours (the fill focuses the fields it fills) and opens nothing.
    static let afterFill: TimeInterval = 1.5
}
