import Foundation

/// Where a file the person adds goes (ai.js composerUpload,: the READ / ADS lanes are gone).
/// JPG and PNG up to 8 MB and MP4 / MOV up to 200 MB go to the media library, where Lia sees them and an ad can use
/// them; any other picture and every document is read by Lia (/intelligence/attach).
enum AttachRoute: Equatable {
    case creativeImage
    case creativeVideo
    case read
    case refuse(String)

    static let metaTypes: [String: String] = ["image/jpeg": "img", "image/png": "img", "video/mp4": "vid", "video/quicktime": "vid"]
    static let imageLimit = 8 * 1024 * 1024
    static let videoLimit = 200 * 1024 * 1024

    /// ai.js READ_DOC.
    static func isDocument(_ name: String) -> Bool {
        let ext = (name.split(separator: ".").last.map(String.init) ?? "").lowercased()
        return name.contains(".") && ["pdf", "doc", "docx", "ppt", "pptx", "xls", "xlsx", "csv", "tsv", "txt", "md", "json", "xml", "rtf", "odt"].contains(ext)
    }

    static func route(name: String, mime: String, bytes: Int) -> AttachRoute {
        let kind = metaTypes[mime.lowercased()]
        if kind == nil && (isDocument(name) || mime.hasPrefix("text/") || mime == "application/pdf" || mime == "application/json") { return .read }
        if kind == nil && mime.hasPrefix("image/") { return .read }
        guard let kind else { return .refuse("Meta accepts JPG, PNG, MP4, MOV. \u{00ab}" + String(name.prefix(24)) + "\u{00bb} is none of these") }
        if kind == "img" { return bytes > imageLimit ? .read : .creativeImage }
        if bytes > videoLimit { return .refuse("Under 200 MB for video in v1 (Meta itself takes up to 4 GB, we will raise this)") }
        return .creativeVideo
    }

    /// Where the storyboard's four frames are taken, as fractions of the clip (ai.js liaVideoBoard).
    static let boardAt: [Double] = [0.1, 0.35, 0.65, 0.9]
}

/// "everything we put in the input lives on the server, not on the device". Where a file in a
/// workspace composer goes (a drop, the paperclip, a paste, the screenshot card): the agents' model reads pictures and
/// documents (POST /intelligence/attach, R2); a picture the model does not read as it is (HEIC, TIFF, BMP) is turned
/// into a PNG on the Mac first; a video goes to Storage > Uploads (creative_upload_stream) and travels as an
/// [attached_creative r2_key=...] marker. ("add a server path for any files"): any other file up to 100 MB
/// (or a readable one over 10 MB) is stored as it is (`file`: POST /intelligence/attach-stream, R2 ai/{m}/att/), lands
/// in Storage > Uploads like every input file, and the server reads its text for the model (Office, OpenDocument,
/// RTF, code, any text); a file with no text in it (audio, archives, programs) reaches the model by name, type and size.
enum ComposerLane: Equatable {
    case read
    case readAsPNG
    case storage
    case file
    case refuse(String)

    /// What the agents' model reads (the server's LIA_ATT_KIND list).
    static let readImages: Set<String> = ["png", "jpg", "jpeg", "gif", "webp"]
    static let readDocs: Set<String> = ["pdf", "doc", "docx", "xls", "xlsx", "ppt", "pptx", "csv", "tsv", "txt", "text",
                                        "md", "markdown", "json", "xml", "log", "yaml", "yml", "rtf", "odt", "html", "htm"]
    /// Pictures made readable by a conversion to PNG on the Mac.
    static let convertImages: Set<String> = ["heic", "heif", "tiff", "tif", "bmp"]
    /// What Storage > Uploads takes as a video (Meta's MP4 / MOV).
    static let videos: Set<String> = ["mp4", "mov"]
    static let readLimit = 10 * 1024 * 1024
    /// The streamed lane's ceiling (the server's UPL_MAX_BYTES; Cloudflare's request-body limit).
    static let fileLimit = 100 * 1024 * 1024
    /// Code and markup the server reads as text (the server's TEXT_EXT, beyond `readDocs`): the icon says "code".
    static let codeTypes: Set<String> = ["css", "scss", "less", "js", "mjs", "cjs", "ts", "tsx", "jsx", "py", "rb", "go", "rs", "java", "kt",
                                         "swift", "c", "h", "cc", "cpp", "hpp", "cs", "php", "sh", "bash", "zsh", "sql", "ini", "toml",
                                         "cfg", "conf", "env", "tex", "srt", "vtt", "ics", "vcf", "svg", "ipynb", "vue", "svelte", "graphql",
                                         "proto", "diff", "patch", "jsonl", "ndjson", "xhtml"]

    static func ext(_ name: String) -> String {
        guard name.contains(".") else { return "" }
        return (name.split(separator: ".").last.map(String.init) ?? "").lowercased()
    }

    static func of(name: String, bytes: Int) -> ComposerLane {
        let e = ext(name)
        if readImages.contains(e) || readDocs.contains(e) {
            if bytes <= readLimit { return .read }
            return bytes > fileLimit ? .refuse("Over 100 MB") : .file
        }
        if convertImages.contains(e) { return .readAsPNG }
        if videos.contains(e) { return bytes > AttachRoute.videoLimit ? .refuse("Over 200 MB") : .storage }
        return bytes > fileLimit ? .refuse("Over 100 MB") : .file
    }
}

/// "I closed the messenger and the screenshot left the input; like text, it must stay there until I
/// remove it myself." The composer's files that are already on the server, kept with the unsent text per dialogue
/// (UserDefaults, across closing the messenger and a relaunch): an uploaded file by its R2 key (a picture with a small
/// thumbnail, so the tray shows it without a request), a Storage / Meta pick by its id. Nothing on this Mac is named.
enum ComposerDraftFiles {
    enum Entry: Equatable {
        /// `preview` holds the thumbnail (or nothing).
        case uploaded(ChatAttachment)
        case library(MediaItem)
    }

    static func encode(_ entries: [Entry]) -> Data? {
        let rows: [[String: Any]] = entries.map { e in
            switch e {
            case .uploaded(let a):
                var r: [String: Any] = ["t": "att", "key": a.key, "kind": a.kind, "name": a.name, "mime": a.mime, "bytes": a.bytes]
                if let u = a.url { r["url"] = u }
                if let p = a.preview { r["thumb"] = p.base64EncodedString() }
                return r
            case .library(let m):
                var r: [String: Any] = ["t": "lib", "id": m.id, "source": m.source.rawValue, "name": m.name]
                if let p = m.preview { r["preview"] = p }
                if let s = m.seconds { r["seconds"] = s }
                return r
            }
        }
        return try? JSONSerialization.data(withJSONObject: rows)
    }

    static func decode(_ data: Data?) -> [Entry] {
        guard let data, let rows = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]] else { return [] }
        return rows.compactMap { r in
            switch r["t"] as? String {
            case "att":
                guard let key = r["key"] as? String, !key.isEmpty, let name = r["name"] as? String else { return nil }
                let thumb = (r["thumb"] as? String).flatMap { Data(base64Encoded: $0) }
                return .uploaded(ChatAttachment(key: key, kind: (r["kind"] as? String) == "image" ? "image" : "file", name: name,
                                                mime: r["mime"] as? String ?? "", bytes: (r["bytes"] as? NSNumber)?.intValue ?? 0,
                                                url: r["url"] as? String, preview: thumb))
            case "lib":
                guard let id = r["id"] as? String, !id.isEmpty, let src = (r["source"] as? String).flatMap(MediaItem.Source.init(rawValue:))
                else { return nil }
                return .library(MediaItem(id: id, source: src, name: r["name"] as? String ?? "", preview: r["preview"] as? String,
                                          seconds: (r["seconds"] as? NSNumber)?.doubleValue))
            default:
                return nil
            }
        }
    }
}
