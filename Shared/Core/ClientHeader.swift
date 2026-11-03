import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking   // URLRequest on Linux (the Core tests)
#endif

/// (server the web repo, docs/CLIENTS.md): every request to our hosts says which app sent it, so the
/// admin can show who runs the Mac app and on which version:
/// X-Lia-Client: mac/0.2.10 (202610190001; macOS 26.0; arm64; release)
/// Liaison Dev (a plain `build-local.sh` build: URL scheme liaison-dev, no update feed) says `dev`. Nothing personal is
/// ever in it: no name, email, host name or device id. Only liaisone.com and its subdomains get it (OurHost), never
/// Memberstack, Stripe, Meta or a page in the browser. The server's parser (lia-client.js) is strict: each field is
/// cut to the same character set and length here, and a field we cannot know is "-".
enum LiaClient {
    static let header = "X-Lia-Client"

    enum Channel: String { case release, dev }

    /// The header's value. Each field is cleaned to what the server accepts.
    static func value(platform: String = "mac", version: String, build: String, os: String, arch: String, channel: Channel) -> String {
        "\(platform)/\(cleanVersion(version)) (\(clean(build, set: buildSet, max: 24)); \(osField(os)); \(clean(arch, set: archSet, max: 12)); \(channel.rawValue))"
    }

    /// "macOS 26.0", "macOS 15.6.1": the patch only when it is not zero.
    static func osName(_ v: OperatingSystemVersion, name: String = "macOS") -> String {
        "\(name) \(v.majorVersion).\(v.minorVersion)" + (v.patchVersion > 0 ? ".\(v.patchVersion)" : "")
    }

    /// Dev unless this is the release build: scheme `liaison` (not liaison-dev) and an https update feed.
    static func channel(urlScheme: String?, feed: String?) -> Channel {
        let s = (urlScheme ?? "").lowercased()
        if s == "liaison-dev" { return .dev }
        let f = (feed ?? "").trimmingCharacters(in: .whitespaces)
        return f.hasPrefix("https://") ? .release : .dev
    }

    static var arch: String {
        #if arch(arm64)
        return "arm64"
        #elseif arch(x86_64)
        return "x86_64"
        #else
        return "-"
        #endif
    }

    /// This build's value, made once from Info.plist and the system.
    static let current: String = {
        let b = Bundle.main
        let version = b.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
        let build = b.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? ""
        let ch = channel(urlScheme: b.object(forInfoDictionaryKey: "LiaURLScheme") as? String,
                         feed: b.object(forInfoDictionaryKey: "SUFeedURL") as? String)
        return value(version: version, build: build, os: osName(ProcessInfo.processInfo.operatingSystemVersion), arch: arch, channel: ch)
    }()

    /// Adds the header when the request goes to one of our hosts; any other host gets nothing.
    static func stamp(_ req: inout URLRequest, value: String = LiaClient.current) {
        guard OurHost.matches(req.url?.host) else { return }
        req.setValue(value, forHTTPHeaderField: header)
    }

    // MARK: cleaning (the server's lia-client.js character sets)

    private static let versionSet = Set("0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz.+-")
    private static let buildSet = Set("0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz.-")
    private static let osSet = Set("0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz ._-")
    private static let archSet = Set("0123456789abcdefghijklmnopqrstuvwxyz_")

    private static func clean(_ s: String, set: Set<Character>, max: Int) -> String {
        let out = String(s.filter { set.contains($0) }.prefix(max))
        return out.isEmpty ? "-" : out
    }

    /// A version starts with a digit; anything else (an unset Info.plist) is "0".
    private static func cleanVersion(_ s: String) -> String {
        let out = String(s.filter { versionSet.contains($0) }.prefix(24))
        guard let f = out.first, f.isASCII, f.isNumber else { return "0" }
        return out
    }

    /// Starts with a letter, at most 32 characters, no doubled or trailing spaces.
    private static func osField(_ s: String) -> String {
        var out = String(s.filter { osSet.contains($0) }.split(separator: " ").joined(separator: " ").prefix(32))
        while out.hasSuffix(" ") { out.removeLast() }
        guard let f = out.first, f.isASCII, f.isLetter else { return "-" }
        return out
    }
}
