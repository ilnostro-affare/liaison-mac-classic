import SwiftUI
import AppKit

// (docs/UX-BACKLOG.md): site search in the address field. A keyword then Tab switches the field to
// "Search <Site>" (a chip before the text); Return searches that site; Backspace on an empty field leaves the mode.
// The field's Paste and Go / Paste and Search / Paste and Ask the Team.

struct SiteSearch: Identifiable, Equatable {
    let id: String
    let name: String
    let keywords: [String]
    let symbol: String
    /// The query is appended, percent-encoded.
    let base: String

    func url(_ q: String) -> URL? {
        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: "&+=?#")
        guard let e = q.trimmingCharacters(in: .whitespaces).addingPercentEncoding(withAllowedCharacters: allowed) else { return nil }
        return URL(string: base + e)
    }

    static let all: [SiteSearch] = [
        SiteSearch(id: "adlibrary", name: "Meta Ad Library", keywords: ["meta", "fb"], symbol: "rectangle.stack",
                   base: "https://www.facebook.com/ads/library/?active_status=all&ad_type=all&country=ALL&media_type=all&search_type=keyword_unordered&q="),
        // Meta has no stable public search URL for Business Help; a Google search limited to it is the honest route.
        SiteSearch(id: "metahelp", name: "Meta Business Help", keywords: ["help"], symbol: "questionmark.circle",
                   base: "https://www.google.com/search?q=site%3Afacebook.com%2Fbusiness%2Fhelp+"),
        SiteSearch(id: "gads", name: "Google Ads Help", keywords: ["gads"], symbol: "questionmark.circle",
                   base: "https://support.google.com/google-ads/search?q="),
        SiteSearch(id: "youtube", name: "YouTube", keywords: ["yt"], symbol: "play.rectangle", base: "https://www.youtube.com/results?search_query="),
    ]

    /// The preset a typed keyword names (exactly, any case), nil: none.
    static func match(_ typed: String) -> SiteSearch? {
        let k = typed.trimmingCharacters(in: .whitespaces).lowercased()
        guard !k.isEmpty, !k.contains(" ") else { return nil }
        return all.first { $0.keywords.contains(k) }
    }
}

/// The chip in the address field while a site search is on.
struct SiteSearchChip: View {
    let site: SiteSearch

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: site.symbol).font(.system(size: 10, weight: .semibold))
            Text("Search \(site.name)").font(LiaFont.ui(12, .medium)).lineLimit(1)
        }
        .foregroundStyle(WS.blue)
        .padding(.horizontal, 7)
        .frame(height: 22)
        .background(WS.blue.opacity(0.1), in: Capsule())
        .fixedSize()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("Searching \(site.name). Press Delete on an empty field to leave."))
    }
}

/// The address field's menu. Paste and Go when the clipboard is an address, else Paste and Search; and
/// Paste and Ask the Team. Plus the usual editing items (this menu replaces the field's own).
struct OmniFieldMenu: View {
    let omni: OmniboxModel

    var body: some View {
        let clip = NSPasteboard.general.string(forType: .string)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let isAddress = OmniboxModel.looksLikeAddress(clip)
        Button("Cut") { NSApp.sendAction(#selector(NSText.cut(_:)), to: nil, from: nil) }
        Button("Copy") { NSApp.sendAction(#selector(NSText.copy(_:)), to: nil, from: nil) }
        Button("Paste") { NSApp.sendAction(#selector(NSText.paste(_:)), to: nil, from: nil) }.disabled(clip.isEmpty)
        Button(isAddress ? "Paste and Go" : "Paste and Search") { omni.pasteAndGo() }.disabled(clip.isEmpty)
        Button("Paste and Ask Lia") { omni.pasteAndAsk() }.disabled(clip.isEmpty)
        Divider()
        Button("Select All") { NSApp.sendAction(#selector(NSText.selectAll(_:)), to: nil, from: nil) }
    }
}
