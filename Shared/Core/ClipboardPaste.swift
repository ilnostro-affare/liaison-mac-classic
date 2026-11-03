import Foundation

/// "With an image or a document on the clipboard, ⌘V does nothing." What a paste into the message box
/// becomes, read from the pasteboard's type identifiers (pure, so the order is tested on Linux):
/// 1. files copied in Finder (file urls) -> attachments, like a drop or the paperclip
/// 2. text copied with its formatting (Pages, Word, Excel, a web page: a plain string beside RTF/HTML, often with a
/// picture of the selection too) -> the words, as plain text
/// 3. an image (a screenshot copied with ⌘⌃⇧4, "Copy Image") -> an attachment
/// 4. plain text -> the words (a long one becomes a chip, as before)
/// 5. RTF/HTML with no plain string -> the words, read out of the formatting
enum ClipboardPaste {
    enum Kind: Equatable {
        case files
        /// The pasteboard type to read the image from (its bytes go up as they are, TIFF/HEIC as PNG).
        case image(String)
        case text
        case richText
        case none
    }

    static let fileURL = "public.file-url"
    static let plain: Set<String> = ["public.utf8-plain-text", "public.utf16-plain-text", "public.plain-text", "NSStringPboardType"]
    static let rich: Set<String> = ["public.rtf", "com.apple.flat-rtfd", "public.html", "com.apple.webarchive", "NeXT Rich Text Format v1.0 pasteboard type"]
    /// In the order an image is taken: the pasteboard often holds one picture in several forms.: a
    /// photo's JPEG before its HEIC (the HEIC was made into a full-size PNG, tens of MB, before it could go up).
    static let images: [String] = ["public.png", "public.jpeg", "public.heic", "public.heif", "com.compuserve.gif", "public.tiff",
                                   "NeXT TIFF v4.0 pasteboard type"]

    static func kind(types: [String]) -> Kind {
        let set = Set(types)
        if set.contains(fileURL) { return .files }
        let hasPlain = !set.isDisjoint(with: plain)
        let hasRich = !set.isDisjoint(with: rich)
        if hasPlain && hasRich { return .text }
        if let img = images.first(where: set.contains) { return .image(img) }
        if hasPlain { return .text }
        if hasRich { return .richText }
        return .none
    }

    /// Whether ⌘V has anything to put in the box (the Paste menu item is enabled for it).
    static func canPaste(types: [String]) -> Bool { kind(types: types) != .none }

    /// The file name a pasted image is attached under.
    static func imageName(type: String, at date: Date = Date()) -> String {
        let ext: String
        switch type {
        case "public.jpeg": ext = "jpg"
        case "com.compuserve.gif": ext = "gif"
        default: ext = "png"   // PNG as is; TIFF and HEIC are converted (the agents read png/jpg/gif/webp)
        }
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        return "Pasted image \(f.string(from: date)).\(ext)"
    }
}
