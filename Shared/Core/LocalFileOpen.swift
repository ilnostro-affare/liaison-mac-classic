import Foundation

/// An .html file opened from another app (Finder, the Claude app) shows in a new browser tab; before,
/// the link reached the window and was dropped, so the window came forward with nothing in it. Only the kinds a
/// browser shows go to a tab; Info.plist declares the same list (CFBundleDocumentTypes) so macOS sends them here.
enum LocalFileOpen {
    static let extensions: Set<String> = ["html", "htm", "xhtml", "shtml", "svg", "webarchive"]

    static func opens(_ url: URL) -> Bool {
        url.isFileURL && extensions.contains(url.pathExtension.lowercased())
    }
}
