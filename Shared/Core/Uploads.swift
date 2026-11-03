import Foundation

/// Storage > Uploads is the one place for every file. "Any media files, and generations that
/// went into ads, go to Uploads, so everything is at hand; if I paste a PDF I can also open it in Uploads. If I delete,
/// I delete from Uploads, but in the chat where I pasted it, or what was generated, it stays in the chat."
///
/// The server keeps one index row per file (lia-uploads.js, GET /intelligence/uploads): every file put in an agent's
/// input (store "att", R2 ai/{m}/att/...: pictures, PDFs, documents, video, any type up to 100 MB, screenshots) and
/// every library upload a client registered (store "media", {m}/uploads/...). media_library still lists the library's
/// own R2 prefix, so the tab is the two merged: index rows first (newest first), then library-only uploads made before
/// the index existed or by a path that does not register (Crea's Make an ad, until it does), minus what was deleted.
struct UploadEntry: Equatable {
    let key: String
    /// "att" (an input file, signed address) or "media" (the ad library, /meta/upload-asset).
    let store: String
    let name: String
    let mime: String
    let bytes: Int
    /// image, video, audio, pdf, doc, sheet, slides, text, code, archive, app, file (the server's uplKind).
    let kind: String
    let src: String
    /// A chat holds the bytes: a delete from Uploads hides the row and keeps them.
    let chat: Bool
    let at: Double
    let url: String?
    /// The model reads it (false: described to the model by name, type and size).
    let read: Bool

    init(key: String, store: String, name: String, mime: String, bytes: Int, kind: String, src: String = "input",
         chat: Bool = false, at: Double = 0, url: String? = nil, read: Bool = true) {
        self.key = key; self.store = store; self.name = name; self.mime = mime; self.bytes = bytes; self.kind = kind
        self.src = src; self.chat = chat; self.at = at; self.url = url; self.read = read
    }

    init?(json o: JSONObject) {
        guard let key = JSONRead.string(o, "key"), !key.isEmpty else { return nil }
        let store = JSONRead.string(o, "store") == "media" ? "media" : "att"
        // An input file lives under /att/, a library file under /uploads/: anything else is not a row we can open.
        guard store == "att" ? key.contains("/att/") : key.contains("/uploads/") else { return nil }
        let name = JSONRead.string(o, "name") ?? ""
        let mime = JSONRead.string(o, "mime") ?? ""
        self.init(key: key, store: store, name: name.isEmpty ? "file" : name, mime: mime, bytes: JSONRead.int(o, "bytes") ?? 0,
                  kind: JSONRead.string(o, "kind") ?? UploadKind.of(name: name, mime: mime), src: JSONRead.string(o, "src") ?? "input",
                  chat: JSONRead.bool(o, "chat"), at: JSONRead.double(o, "at") ?? 0, url: JSONRead.string(o, "url"),
                  read: (o["read"] as? Bool) ?? true)
    }

    /// As a tile of the Uploads tab. A library file stays `.upload` (it travels as an [attached_creative] marker and
    /// can become an ad); an input file is `.file` and travels as an attachment the model reads.
    var mediaItem: MediaItem {
        if store == "media" {
            return MediaItem(id: key, source: .upload, name: name, preview: url, seconds: nil, mime: mime, bytes: bytes, url: url, chat: chat)
        }
        return MediaItem(id: key, source: .file, name: name, preview: kind == "image" ? url : nil, seconds: nil,
                         mime: mime, bytes: bytes, url: url, chat: true)
    }
}

enum UploadsIndex {
    /// GET /intelligence/uploads -> {ok, uploads: [...], hidden: [object keys]}; nil when it did not answer ok.
    /// `base` makes a relative signed address (/intelligence/plot?...) absolute.
    static func parse(_ data: Data, base: String = "") -> (entries: [UploadEntry], hidden: Set<String>)? {
        guard let o = JSONRead.object(data), JSONRead.bool(o, "ok") else { return nil }
        let hidden = (o["hidden"] as? [Any] ?? []).compactMap { $0 as? String }
        let entries = JSONRead.objects(o, "uploads").compactMap(UploadEntry.init(json:)).map { e -> UploadEntry in
            guard let u = e.url, u.hasPrefix("/") else { return e }
            return UploadEntry(key: e.key, store: e.store, name: e.name, mime: e.mime, bytes: e.bytes, kind: e.kind, src: e.src,
                               chat: e.chat, at: e.at, url: base + u, read: e.read)
        }
        return (entries, Set(hidden))
    }

    /// The Uploads tab: the index (newest first, a library row's own preview and name kept when the index has none),
    /// then the library's uploads the index does not know, minus every key deleted from Uploads.
    static func merge(index: [UploadEntry], library: [MediaItem], hidden: Set<String>) -> [MediaItem] {
        let lib = Dictionary(library.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        var seen = Set<String>()
        var out: [MediaItem] = []
        for e in index.sorted(by: { $0.at > $1.at }) where !hidden.contains(e.key) && !seen.contains(e.key) {
            seen.insert(e.key)
            var m = e.mediaItem
            if let l = lib[e.key] {
                m = MediaItem(id: m.id, source: m.source, name: (e.name == "file" && !l.name.isEmpty) ? l.name : e.name,
                              preview: l.preview ?? m.preview, seconds: l.seconds, mime: m.mime, bytes: m.bytes, url: m.url, chat: m.chat)
            }
            out.append(m)
        }
        for l in library where !hidden.contains(l.id) && !seen.contains(l.id) {
            seen.insert(l.id)
            out.append(l)
        }
        return out
    }
}

/// POST /intelligence/uploads/delete -> {ok, store, kept, delete_bytes}. `deleteBytes`: the library file no chat holds
/// (or one the index never knew) is deleted for real by upload_delete; anything a chat holds stays where it is.
struct UploadDeleteAnswer: Equatable {
    let ok: Bool
    let deleteBytes: Bool
    let kept: Bool
    let error: String?

    static func parse(_ data: Data?) -> UploadDeleteAnswer {
        guard let data, let o = JSONRead.object(data) else { return UploadDeleteAnswer(ok: false, deleteBytes: false, kept: false, error: nil) }
        return UploadDeleteAnswer(ok: JSONRead.bool(o, "ok"), deleteBytes: JSONRead.bool(o, "delete_bytes"), kept: JSONRead.bool(o, "kept"),
                                  error: JSONRead.string(o, "error"))
    }
}

/// What a file is, for its icon (the server's uplKind, the same words).
enum UploadKind {
    static func of(name: String, mime: String) -> String {
        let m = mime.lowercased()
        let e = ComposerLane.ext(name)
        if e == "svg" { return "code" }
        if m.hasPrefix("image/") || ["png", "jpg", "jpeg", "gif", "webp", "heic", "heif", "tif", "tiff", "bmp", "avif"].contains(e) { return "image" }
        if m.hasPrefix("video/") || ["mp4", "mov", "m4v", "webm", "avi", "mkv", "wmv", "flv", "3gp"].contains(e) { return "video" }
        if m.hasPrefix("audio/") || ["mp3", "m4a", "wav", "aac", "ogg", "oga", "flac", "aif", "aiff", "opus", "wma"].contains(e) { return "audio" }
        if m == "application/pdf" || e == "pdf" { return "pdf" }
        if ["doc", "docx", "odt", "rtf", "pages"].contains(e) { return "doc" }
        if ["xls", "xlsx", "ods", "numbers", "csv", "tsv"].contains(e) { return "sheet" }
        if ["ppt", "pptx", "odp", "key"].contains(e) { return "slides" }
        if ["zip", "rar", "7z", "tar", "gz", "tgz", "bz2", "xz", "zst", "dmg", "iso", "pkg"].contains(e) { return "archive" }
        if ["exe", "msi", "app", "dll", "so", "dylib", "bin", "jar", "apk", "ipa", "deb", "rpm"].contains(e) { return "app" }
        if ["txt", "text", "md", "markdown", "log"].contains(e) { return "text" }
        if m.hasPrefix("text/") || m.contains("json") || m.contains("xml") || m.contains("javascript") || ComposerLane.codeTypes.contains(e) { return "code" }
        return "file"
    }

    /// An SVG shows as its picture (the Uploads tile, the composer chip), though its kind stays
    /// "code" (the server's word, and the preview opens it as a picture, never as its source).
    static func isSVG(name: String, mime: String) -> Bool {
        let e = ComposerLane.ext(name)
        return e == "svg" || e == "svgz" || mime.lowercased().hasPrefix("image/svg")
    }

    /// The SF Symbol of a kind (the Uploads tile and the composer chip).
    static func symbol(_ kind: String) -> String {
        switch kind {
        case "image": return "photo"
        case "video": return "play.rectangle"
        case "audio": return "waveform"
        case "pdf": return "doc.richtext"
        case "doc": return "doc.text"
        case "sheet": return "tablecells"
        case "slides": return "rectangle.on.rectangle"
        case "text": return "doc.plaintext"
        case "code": return "chevron.left.forwardslash.chevron.right"
        case "archive": return "archivebox"
        case "app": return "app.dashed"
        default: return "doc"
        }
    }

    /// The badge on a tile: the extension, upper case, at most five letters ("FILE" without one).
    static func badge(_ name: String) -> String {
        let e = ComposerLane.ext(name)
        return e.isEmpty ? "FILE" : String(e.uppercased().prefix(5))
    }
}

/// How a file opens in the Mac's viewers (the attachment preview, the document sheet). The site shows
/// every file but an archive; here: a PDF in PDFKit, an SVG as a picture (never its source), a picture as a picture,
/// text and code as text, the server's own page for HTML and Markdown (it renders them), and Quick Look for the rest
/// (Word, Excel, PowerPoint, Pages, Numbers, Keynote, RTF, audio, video, ...). An archive or a program: Open only.
enum FileView: Equatable {
    case page, pdf, svg, image, text, quickLook, none

    static let imageTypes: Set<String> = ["png", "jpg", "jpeg", "gif", "heic", "heif", "webp", "tif", "tiff", "bmp", "avif"]
    static let textTypes: Set<String> = ["csv", "tsv", "txt", "text", "json", "log", "yaml", "yml", "xml"]

    /// The route for a file name's extension (lower or upper case).
    static func of(ext raw: String) -> FileView {
        let e = raw.lowercased()
        if e == "pdf" { return .pdf }
        if e == "svg" || e == "svgz" { return .svg }
        if imageTypes.contains(e) { return .image }
        if ["html", "htm", "md", "markdown"].contains(e) { return .page }
        if textTypes.contains(e) || ComposerLane.codeTypes.contains(e) { return .text }
        switch UploadKind.of(name: "f." + e, mime: "") {
        case "archive", "app": return .none
        default: return .quickLook
        }
    }
}

/// "a photo of ~7 MB pasted or dragged into the box uploads forever, a screenshot goes fine". A photo
/// went up whole (a 7 MB JPEG as 9 MB of base64), or worse, as a PNG made from it: a 12 MP HEIC or a pasted photo is
/// 20-80 MB as PNG, past the read lane's 10 MB, so it took the streamed lane, where the server keeps a picture over
/// 10 MB as a file the model does not open (Crea answered she did not get it). What a picture in the input becomes
/// before it goes up (pure; the encoding is ChatAttach's): a PNG up to 10 MB (a screenshot) stays as it is, a GIF / WebP
/// as it is; a photo (JPEG over 3 MB or over 2560 px, HEIC, HEIF, TIFF, BMP, a PNG over 10 MB) becomes a JPEG at most
/// 2560 px on its long side, quality 0.85 (a picture with transparency a PNG of that size). The model looks at pictures
/// at about 2048 px anyway.
enum ImageFit {
    static let maxSide = 2560
    static let quality = 0.85
    /// A JPEG up to this size, within `maxSide`, goes as it is.
    static let keepJPEGBytes = 3 * 1024 * 1024
    /// A PNG up to this size (a screenshot) goes as it is.
    static let keepPNGBytes = ComposerLane.readLimit
    /// Pictures this decides about (anything else is not touched).
    static let types: Set<String> = ["png", "jpg", "jpeg", "heic", "heif", "tiff", "tif", "bmp"]

    enum Plan: Equatable {
        case keep
        case jpeg(maxSide: Int)
        case png(maxSide: Int)
    }

    /// `longSide` 0: not known (only the size decides). `alpha`: the picture has transparency.
    static func plan(ext raw: String, bytes: Int, longSide: Int, alpha: Bool) -> Plan {
        let e = raw.lowercased()
        guard types.contains(e) else { return .keep }
        let small = longSide <= maxSide
        switch e {
        case "png":
            if bytes <= keepPNGBytes { return .keep }
        case "jpg", "jpeg":
            if bytes <= keepJPEGBytes && small { return .keep }
            return .jpeg(maxSide: maxSide)
        default:
            break
        }
        return alpha ? .png(maxSide: maxSide) : .jpeg(maxSide: maxSide)
    }

    /// The name a re-encoded picture goes under ("IMG_1234.HEIC" -> "IMG_1234.jpg").
    static func name(_ name: String, plan: Plan) -> String {
        let ext: String
        switch plan {
        case .keep: return name
        case .jpeg: ext = "jpg"
        case .png: ext = "png"
        }
        let base = (name as NSString).deletingPathExtension
        return (base.isEmpty ? "Image" : base) + "." + ext
    }
}

/// An upload in the input never spins forever. How long one may take in all before it is given up and
/// the chip says so: a minute and a half, plus a second per 128 KB (an uplink of about 1 Mbit/s), at most 20 minutes.
enum UploadDeadline {
    static func seconds(bytes: Int) -> Double {
        min(1200, 90 + Double(max(0, bytes)) / 131_072)
    }
}
