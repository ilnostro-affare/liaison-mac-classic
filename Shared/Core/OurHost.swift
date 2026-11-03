import Foundation

/// Liaison's own hosts: liaisone.com and its subdomains, and nothing that merely ends in the same letters
/// (evilliaisone.com). Only these get the session header.
/// Server: never Dev's sites or previews - they are the person's own code. On liaisone.app they are not ours by
/// domain; on liaisone.com (their old domain, still served during the move) they are told apart by DevPickerHost,
/// whose reserved names cover every host of ours.
enum OurHost {
    static func matches(_ host: String?) -> Bool {
        guard let h = host?.lowercased() else { return false }
        guard h == "liaisone.com" || h.hasSuffix(".liaisone.com"), !h.hasPrefix("pv-") else { return false }
        return DevPickerHost.kind(host: h) == nil
    }
}

/// A download that came from Liaison itself (our Liaison.dmg from lia.liaisone.com/dl/mac): https on one of our own
/// hosts (never a Dev site, OurHost excludes them). Only these skip the "apps and installers can harm your Mac" warning.
enum DownloadSource {
    static func isOurs(_ url: URL?) -> Bool {
        guard let u = url, u.scheme?.lowercased() == "https" else { return false }
        return OurHost.matches(u.host)
    }
}
