import Foundation

/// 0.2.11 ("The Chrome Web Store answered 204"): how an extension is fetched from the Chrome Web
/// Store. Pure (the Linux tests check it); the download itself is ExtensionsInstaller's.
///
/// Why 204: Google's update service answers 204 No Content ("no update for you") when the `prodversion` it is told
/// is older than the extension's `minimum_chrome_version`. We sent a fixed "126.0" (Chrome of June 2024); current
/// Bitwarden and 1Password builds need newer Chrome, so the service had nothing to give. Now the version is
/// today's Chrome stable, estimated from the 4-week release train (it never goes stale), and the request carries
/// the platform fields Chrome itself sends.
enum ChromeStore {
    /// Chrome 131 reached stable; a new major ships every 4 weeks.
    static let anchorMajor = 131
    static let anchorDate = Date(timeIntervalSince1970: 1_731_369_600)   // 00:00 UTC

    /// A 32-letter id (a-p), alone or inside a chromewebstore.google.com / chrome.google.com/webstore link.
    static func id(_ raw: String) -> String? {
        let s = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard let r = s.range(of: "[a-p]{32}", options: [.regularExpression, .backwards]) else { return nil }
        return String(s[r])
    }

    /// Chrome stable's major version on `date` (one behind the estimate, so a late release never overshoots).
    static func chromeMajor(on date: Date) -> Int {
        let weeks = date.timeIntervalSince(anchorDate) / (7 * 86_400)
        return max(anchorMajor, anchorMajor + Int(weeks / 4) - 1)
    }

    /// The update-service requests to try in order: today's Chrome with the platform fields, then without them, then
    /// a fixed known-good version (for an extension whose newest build Google withholds from very new Chrome, rare).
    static func downloadURLs(_ id: String, on date: Date = Date(), arm: Bool = true) -> [URL] {
        let now = "\(chromeMajor(on: date)).0.0.0"
        let arch = arm ? "arm64" : "x86-64"
        let x = "id%3D" + id + "%26installsource%3Dondemand%26uc"
        let base = "https://clients2.google.com/service/update2/crx?response=redirect&acceptformat=crx2,crx3"
        let variants = [
            "&os=mac&arch=\(arch)&os_arch=\(arch)&nacl_arch=\(arm ? "arm" : "x86-64")&prod=chromecrx&prodchannel=stable&prodversion=\(now)",
            "&prodversion=\(now)",
            "&prodversion=131.0.0.0",
        ]
        return variants.compactMap { URL(string: base + $0 + "&x=" + x) }
    }

    /// A Chrome-like User-Agent for the same version (the service tolerates any, some mirrors do not).
    static func userAgent(on date: Date = Date()) -> String {
        "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/\(chromeMajor(on: date)).0.0.0 Safari/537.36"
    }

    /// The body is a CRX ("Cr24") or a plain zip ("PK\u{3}\u{4}"), not an HTML error page.
    static func isPackage(_ d: Data) -> Bool {
        let b = [UInt8](d.prefix(4))
        guard b.count == 4 else { return false }
        return b == [0x43, 0x72, 0x32, 0x34] || b == [0x50, 0x4B, 0x03, 0x04]
    }
}
