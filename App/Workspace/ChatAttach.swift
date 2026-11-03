import SwiftUI
import AppKit
import UniformTypeIdentifiers
import ImageIO

/// Files in a team conversation. Each file is uploaded as soon as it is attached (POST /intelligence/attach,
/// the read lane: R2 keeps the bytes, the ad account never sees them), and the turn carries the uploaded files in
/// `attachments` (lia-agents /agents/turn reads images and documents: at most 4 images + 2 files, 10 MB each, 16 MB in
/// all). A file the server will not take (type, size, count) or that fails to upload falls back to text: a small
/// text-like file is inlined in a fenced block under its name, anything else is only named "[attached: name, size]".
/// The chip says which way each file went; the person's bubble shows uploaded files as tiles and fallbacks as cards.
/// Everything put in the input lives on the server (ComposerLane): a video goes to Storage > Uploads,
/// a HEIC / TIFF / BMP picture is read as a PNG made here, a pasted or dropped picture is never written to a file on
/// this Mac (it waits in memory under a `lia-mem:` address until it is up), and nothing offers a local path.
/// Any other file up to 100 MB is streamed as it is (/intelligence/attach-stream) and the server reads its text;
/// every file that goes up is in Storage > Uploads.
enum ChatAttach {
    static let inlineLimit = 200 * 1024
    static let maxFiles = 6
    static let textTypes: Set<String> = ["csv", "tsv", "txt", "text", "json", "md", "markdown", "log", "yaml", "yml", "xml"]
    static let imageTypes: Set<String> = ["png", "jpg", "jpeg", "gif", "heic", "webp", "tiff", "bmp"]
    /// What the agents' model reads (the server's list); anything else goes the text way.
    static let uploadImageTypes: Set<String> = ["png", "jpg", "jpeg", "gif", "webp"]
    static let uploadDocTypes: Set<String> = ["pdf", "doc", "docx", "xls", "xlsx", "ppt", "pptx", "csv", "tsv", "txt", "text",
                                              "md", "markdown", "json", "xml", "log", "yaml", "yml", "rtf", "odt", "html", "htm"]
    static let uploadLimit = 10 * 1024 * 1024
    static let totalLimit = 16 * 1024 * 1024
    static let maxImages = 4
    static let maxDocs = 2

    /// Where a file stands: on its way up, uploaded (the model reads it), or sent as text with the reason.
    enum Upload: Equatable {
        case uploading
        case uploaded(ChatAttachment)
        case fallback(String)
        /// Picked in the media library: already stored (R2 or Meta), it travels as an [attached_creative] marker.
        case library(MediaItem)
    }

    /// A file picked or dropped, ready to go with the next message.
    struct File: Identifiable, Equatable {
        let url: URL
        let name: String
        let bytes: Int
        /// The file's text, used when the file falls back to text (nil: only its name would reach the agent).
        let inline: String?
        var state: Upload = .uploading
        var id: URL { url }
        var ext: String { (name as NSString).pathExtension.lowercased() }
        var isImage: Bool { ChatAttach.imageTypes.contains(ext) }
        var uploading: Bool { state == .uploading }
        var uploaded: ChatAttachment? { if case .uploaded(let a) = state { return a }; return nil }
        /// Counts against the server's limits (uploaded or on its way).
        var goesUp: Bool { uploading || uploaded != nil }
        var readsAsImage: Bool { ChatAttach.uploadImageTypes.contains(ext) }
        var library: MediaItem? { if case .library(let m) = state { return m }; return nil }
        /// Read by the agents' model (counts against the server's per-message limits); a video goes to Storage.
        var readLane: Bool { ComposerLane.of(name: name, bytes: bytes) == .read }
        /// Bytes held in memory (a paste, a dropped picture, a converted HEIC), not a file on this Mac.
        var inMemory: Bool { url.scheme == ChatAttach.memScheme }

        /// A media library pick as a tray file (its id is a made-up address, never opened).: an input file from
        /// Uploads goes as the attachment it already is (the model reads it again, nothing is uploaded twice).
        static func fromLibrary(_ m: MediaItem) -> File {
            if let a = m.attachment {
                return File(url: ChatAttach.draftURL(a), name: a.name, bytes: a.bytes, inline: nil, state: .uploaded(a))
            }
            let addr = URL(string: "lia-media:" + (m.id.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? "item"))
                ?? URL(fileURLWithPath: "/lia-media/" + UUID().uuidString)
            let label = m.name.isEmpty ? (m.isVideo || m.isVideoUpload ? "Video" : "Image") : m.name
            return File(url: addr, name: label, bytes: 0, inline: nil, state: .library(m))
        }
    }

    /// One "[attached: ...]" mention in a message, with whether its content went inline.
    struct Ref: Identifiable, Equatable {
        let name: String
        let size: String
        let inlined: Bool
        /// A media library item ([attached_creative ...]): its key (r2_key, image hash or video id).
        var creative: String? = nil
        var id: String { creative.map { "c:" + $0 } ?? (name + "|" + size) }
        var ext: String { (name as NSString).pathExtension.lowercased() }
        var isImage: Bool { ChatAttach.imageTypes.contains(ext) }
    }

    /// Files attached in this session, by name, for the preview card and Quick Look.
    @MainActor static var local: [String: URL] = [:]

    // MARK: bytes in memory (no temporary files)

    static let memScheme = "lia-mem"
    /// A dialogue's restored draft file (ChatDraftFiles): its R2 key, never opened as a file.
    static let draftScheme = "lia-att"
    @MainActor private static var memory: [URL: Data] = [:]
    @MainActor private static var memoryOrder: [URL] = []

    /// An address for bytes the person put in the box without a file (a paste, a dragged picture). `add` / `load`
    /// take it like a file URL; the bytes stay in memory (the newest 24) until they are on the server.
    @MainActor static func memoryURL(_ data: Data, name: String) -> URL {
        var c = URLComponents()
        c.scheme = memScheme
        c.host = "local"
        c.path = "/" + UUID().uuidString + "/" + (name.isEmpty ? "file" : name.replacingOccurrences(of: "/", with: "-"))
        let u = c.url ?? URL(string: memScheme + "://local/" + UUID().uuidString)!
        memory[u] = data
        memoryOrder.append(u)
        if memoryOrder.count > 24 { memory[memoryOrder.removeFirst()] = nil }
        return u
    }

    @MainActor static func memoryData(_ url: URL) -> Data? { memory[url] }

    /// A restored draft file's address (its key; the name last so `lastPathComponent` is the name).
    static func draftURL(_ a: ChatAttachment) -> URL {
        var c = URLComponents()
        c.scheme = draftScheme
        c.host = "draft"
        c.path = "/" + (a.key.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? "key") + "/" + a.name.replacingOccurrences(of: "/", with: "-")
        return c.url ?? URL(string: draftScheme + "://draft/" + UUID().uuidString)!
    }

    @MainActor
    static func load(_ url: URL) -> File? {
        if let data = memory[url] {
            // A pasted or dropped photo goes up as a JPEG of at most 2560 px (ImageFit); a screenshot
            // (a PNG up to 10 MB) as it is.
            if let src = CGImageSourceCreateWithData(data as CFData, nil), ImageFit.types.contains(ComposerLane.ext(url.lastPathComponent)),
               let fit = fitted(src, name: url.lastPathComponent, bytes: data.count) {
                return file(url: memoryURL(fit.data, name: fit.name), name: fit.name, data: fit.data)
            }
            return file(url: url, name: url.lastPathComponent, data: data)
        }
        guard url.isFileURL else { return nil }
        let values = try? url.resourceValues(forKeys: [.fileSizeKey, .isDirectoryKey])
        if values?.isDirectory == true { return nil }
        let bytes = values?.fileSize ?? 0
        let name = url.lastPathComponent
        // A photo from Finder (a big JPEG, a HEIC) goes up made smaller, held in memory (never a file).
        if ImageFit.types.contains(ComposerLane.ext(name)), let src = CGImageSourceCreateWithURL(url as CFURL, nil),
           let fit = fitted(src, name: name, bytes: bytes) {
            return file(url: memoryURL(fit.data, name: fit.name), name: fit.name, data: fit.data)
        }
        // A picture the model does not read as it is: a PNG made here, held in memory (never a file).
        if ComposerLane.of(name: name, bytes: bytes) == .readAsPNG, let png = pngData(url) {
            let base = (name as NSString).deletingPathExtension
            return load(memoryURL(png, name: (base.isEmpty ? "Image" : base) + ".png"))
        }
        var inline: String?
        if textTypes.contains((name as NSString).pathExtension.lowercased()), bytes <= inlineLimit,
           let data = try? Data(contentsOf: url), let s = String(data: data, encoding: .utf8) {
            inline = s
        }
        return File(url: url, name: name, bytes: bytes, inline: inline)
    }

    private static func file(url: URL, name: String, data: Data) -> File {
        var inline: String?
        if textTypes.contains((name as NSString).pathExtension.lowercased()), data.count <= inlineLimit {
            inline = String(data: data, encoding: .utf8)
        }
        return File(url: url, name: name, bytes: data.count, inline: inline)
    }

    /// Any picture ImageIO reads (HEIC, TIFF, BMP), as PNG bytes.
    static func pngData(_ url: URL) -> Data? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        return png(src)
    }

    static func pngData(_ data: Data) -> Data? {
        guard let src = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        return png(src)
    }

    private static func png(_ src: CGImageSource) -> Data? {
        let opts: [CFString: Any] = [kCGImageSourceCreateThumbnailWithTransform: true, kCGImageSourceCreateThumbnailFromImageAlways: true,
                                     kCGImageSourceThumbnailMaxPixelSize: 8192]
        guard let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary) ?? CGImageSourceCreateImageAtIndex(src, 0, nil)
        else { return nil }
        let out = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(out as CFMutableData, UTType.png.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, cg, nil)
        return CGImageDestinationFinalize(dest) ? out as Data : nil
    }

    /// A picture as it goes up (ImageFit: a JPEG or PNG of at most 2560 px), or nil when it goes as it
    /// is (or could not be made). Oriented as it is shown (EXIF applied); nothing else of its metadata is kept.
    static func fitted(_ src: CGImageSource, name: String, bytes: Int) -> (data: Data, name: String)? {
        let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any]
        let w = (props?[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue ?? 0
        let h = (props?[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue ?? 0
        let alpha = (props?[kCGImagePropertyHasAlpha] as? Bool) ?? false
        let plan = ImageFit.plan(ext: ComposerLane.ext(name), bytes: bytes, longSide: max(w, h), alpha: alpha)
        let side: Int
        let type: UTType
        switch plan {
        case .keep: return nil
        case .jpeg(let s): side = s; type = .jpeg
        case .png(let s): side = s; type = .png
        }
        let opts: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceCreateThumbnailWithTransform: true,
                                     kCGImageSourceThumbnailMaxPixelSize: side]
        guard let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary) else { return nil }
        let out = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(out as CFMutableData, type.identifier as CFString, 1, nil) else { return nil }
        let p: [CFString: Any] = type == .jpeg ? [kCGImageDestinationLossyCompressionQuality: ImageFit.quality] : [:]
        CGImageDestinationAddImage(dest, cg, p as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return (out as Data, ImageFit.name(name, plan: plan))
    }

    /// A small JPEG of a picture's bytes (a kept draft's tray tile).
    static func thumbnail(_ data: Data, max: Int = 240) -> Data? {
        guard let src = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let opts: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceCreateThumbnailWithTransform: true,
                                     kCGImageSourceThumbnailMaxPixelSize: max]
        guard let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary) else { return nil }
        let out = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(out as CFMutableData, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, cg, [kCGImageDestinationLossyCompressionQuality: 0.7] as CFDictionary)
        return CGImageDestinationFinalize(dest) ? out as Data : nil
    }

    /// Why `f` cannot go up with the files already waiting (nil: it can). Checked here so the chip says it at once.
    static func refusal(_ f: File, with others: [File]) -> String? {
        switch ComposerLane.of(name: f.name, bytes: f.bytes) {
        case .refuse(let why): return why
        case .readAsPNG: return "Could not read the picture"   // load converts it; this one did not convert
        case .storage: return f.url.isFileURL ? nil : "Could not read the file"
        case .file: return f.url.isFileURL || f.inMemory ? nil : "Could not read the file"   // Any file, stored as it is
        case .read: break
        }
        let image = f.readsAsImage
        let up = others.filter { $0.goesUp && $0.readLane }
        if image && up.filter(\.readsAsImage).count >= maxImages { return "Up to 4 pictures per message" }
        if !image && up.filter({ !$0.readsAsImage }).count >= maxDocs { return "Up to 2 documents per message" }
        if up.reduce(0, { $0 + $1.bytes }) + f.bytes > totalLimit { return "Over 16 MB in one message" }
        return nil
    }

    static func mime(_ name: String) -> String {
        UTType(filenameExtension: (name as NSString).pathExtension)?.preferredMIMEType ?? "application/octet-stream"
    }

    /// The start of the reason a file did not go up because the upload failed (not because it was refused).
    static let failedPrefix = "Upload failed"

    /// (Crea answered she did not get the file): what keeps Send waiting - a file on its way up, and a
    /// file whose upload failed and that has no text to go instead (a picture would reach the agent as its name only).
    /// The chip says which; \u{00D7} removes the failed one.
    static func holdsSend(_ f: File) -> Bool {
        if f.uploading { return true }
        if case .fallback(let why) = f.state { return why.hasPrefix(failedPrefix) && f.inline == nil }
        return false
    }

    /// Uploads one file; a refusal or a failure comes back as the reason the file goes as text. A video goes to
    /// Storage > Uploads and comes back as a library pick.: never longer than UploadDeadline (the chip
    /// stopped spinning only when the request did, which for a big photo could be a quarter of an hour).
    @MainActor
    static func upload(_ f: File, auth: AuthStore) async -> Upload {
        let limit = UploadDeadline.seconds(bytes: f.bytes)
        return await withTaskGroup(of: Upload?.self) { g -> Upload in
            g.addTask { @MainActor () -> Upload? in await uploadNow(f, auth: auth) }
            g.addTask { () -> Upload? in
                try? await Task.sleep(nanoseconds: UInt64(limit * 1_000_000_000))
                return nil
            }
            let first = await g.next() ?? nil
            g.cancelAll()
            return first ?? .fallback(failedPrefix + ": it took too long. Remove it and attach it again")
        }
    }

    @MainActor
    private static func uploadNow(_ f: File, auth: AuthStore) async -> Upload {
        let lane = ComposerLane.of(name: f.name, bytes: f.bytes)
        if lane == .storage { return await store(f, auth: auth) }
        if lane == .file { return await stream(f, auth: auth) }
        let url = f.url
        var data = memory[url]
        if data == nil, url.isFileURL { data = await Task.detached(priority: .utility) { try? Data(contentsOf: url) }.value }
        guard let data else { return .fallback("Could not read the file") }
        do {
            var a = try await LiaAPI(auth: auth).uploadAttachment(filename: f.name, mime: mime(f.name), data: data)
            if a.isImage { a.preview = data }
            return .uploaded(a)
        } catch let e as UploadError {
            return .fallback("Not accepted: " + e.message)
        } catch {
            return .fallback(failedPrefix + ": " + userMessage(for: error))
        }
    }

    /// Any other file (or a readable one over 10 MB), streamed as it is to the input lane
    /// (/intelligence/attach-stream): the server keeps it in Storage > Uploads and reads its text for the agent.
    @MainActor
    private static func stream(_ f: File, auth: AuthStore) async -> Upload {
        let held = memory[f.url]
        guard held != nil || f.url.isFileURL else { return .fallback("Could not read the file") }
        do {
            var a = try await LiaAPI(auth: auth).uploadFileStream(name: f.name, mime: mime(f.name), file: held == nil ? f.url : nil, data: held)
            if a.isImage, let held { a.preview = held }
            return .uploaded(a)
        } catch let e as UploadError {
            return .fallback("Not accepted: " + e.message)
        } catch {
            return .fallback(failedPrefix + ": " + userMessage(for: error))
        }
    }

    /// A video into Storage > Uploads (streamed from its file, as the media library does).: named in the
    /// Uploads index as a chat's file, so deleting it from Uploads keeps the video this chat shows.
    @MainActor
    private static func store(_ f: File, auth: AuthStore) async -> Upload {
        guard f.url.isFileURL else { return .fallback("Could not read the file") }
        let up = MediaLibraryModel.Upload(url: f.url, name: f.name, bytes: f.bytes, mime: mime(f.name))
        do {
            let item = try await MediaUploader.send(up, auth: auth, progress: { _ in }, src: "chat", chat: true)
            MediaUploadStore.add(item, member: auth.memberId)
            return .library(item)
        } catch let e as MediaUploader.Failure {
            return .fallback("Not stored: " + e.message)
        } catch {
            return .fallback(failedPrefix + ": " + userMessage(for: error))
        }
    }

    static func size(_ bytes: Int) -> String {
        if bytes < 1024 * 1024 { return "\(max(1, Int((Double(bytes) / 1024).rounded()))) KB" }
        return String(format: "%.1f MB", Double(bytes) / 1_048_576)
    }

    /// The message text with each file after it (inline or by name); pass only the files that did not go up.
    static func compose(_ text: String, files: [File]) -> String {
        var parts: [String] = []
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if !t.isEmpty { parts.append(t) }
        for f in files {
            if let m = f.library { parts.append(m.marker); continue }
            var block = "[attached: \(f.name), \(size(f.bytes))]"
            if let body = f.inline {
                let fence = body.contains("```") ? "````" : "```"
                block += "\n" + fence + (f.ext == "text" ? "" : f.ext) + "\n" + body
                    + (body.hasSuffix("\n") ? "" : "\n") + fence
            }
            parts.append(block)
        }
        return parts.joined(separator: "\n\n")
    }

    /// The person's words without the attachment blocks, and the attachments they named.
    static func split(_ content: String) -> (text: String, refs: [Ref]) {
        guard content.contains("[attached: ") || content.contains("[attached_creative ") else { return (content, []) }
        var kept: [String] = []
        var refs: [Ref] = []
        let lines = content.components(separatedBy: "\n")
        var i = 0
        while i < lines.count {
            let line = lines[i]
            if let c = creativeMention(line) { refs.append(c); i += 1; continue }
            guard let (name, size) = mention(line) else { kept.append(line); i += 1; continue }
            var inlined = false
            if i + 1 < lines.count, lines[i + 1].hasPrefix("```") {
                let fence = String(lines[i + 1].prefix { $0 == "`" })
                var j = i + 2
                while j < lines.count, lines[j].trimmingCharacters(in: .whitespaces) != fence { j += 1 }
                inlined = true
                i = j + 1
            } else {
                i += 1
            }
            refs.append(Ref(name: name, size: size, inlined: inlined))
        }
        return (kept.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines), refs)
    }

    /// "[attached: report, final.csv, 12 KB]" -> ("report, final.csv", "12 KB").
    private static func mention(_ line: String) -> (String, String)? {
        let l = line.trimmingCharacters(in: .whitespaces)
        guard l.hasPrefix("[attached: "), l.hasSuffix("]") else { return nil }
        let inner = l.dropFirst("[attached: ".count).dropLast()
        guard let comma = inner.range(of: ", ", options: .backwards) else { return nil }
        let name = String(inner[..<comma.lowerBound]), size = String(inner[comma.upperBound...])
        return name.isEmpty ? nil : (name, size)
    }

    /// "[attached_creative video_id=123]" -> a library ref.
    private static func creativeMention(_ line: String) -> Ref? {
        let l = line.trimmingCharacters(in: .whitespaces)
        let head = "[attached_creative "
        guard l.hasPrefix(head), l.hasSuffix("]") else { return nil }
        let pair = l.dropFirst(head.count).dropLast().split(separator: "=", maxSplits: 1).map(String.init)
        guard pair.count == 2, !pair[1].isEmpty, !pair[1].contains(" ") else { return nil }
        let name: String
        switch pair[0] {
        case "video_id": name = "Meta video"
        case "image_hash": name = "Meta image"
        case "r2_key": name = "Library upload"
        default: return nil
        }
        return Ref(name: name, size: "", inlined: true, creative: pair[1])
    }

    /// What a drop on the conversation takes: files, and a picture with no file (the screenshot card, a browser's
    /// image dragged out of a page).
    static let dropTypes: [UTType] = [.fileURL, .png, .tiff, .jpeg, .image]

    /// File URLs from a drop (Finder, Desktop); a picture without a file arrives as bytes under a `lia-mem:` address.
    @MainActor
    static func receive(_ providers: [NSItemProvider], into add: @escaping @MainActor ([URL]) -> Void) -> Bool {
        var took = false
        for p in providers.prefix(maxFiles) {
            if p.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
                took = true
                _ = p.loadObject(ofClass: URL.self) { url, _ in
                    guard let url else { return }
                    Task { @MainActor in add([url]) }
                }
            } else if let type = [UTType.png, .jpeg, .tiff, .image].first(where: { p.hasItemConformingToTypeIdentifier($0.identifier) }) {
                took = true
                let name = p.suggestedName
                p.loadDataRepresentation(forTypeIdentifier: type.identifier) { data, _ in
                    guard let data, !data.isEmpty else { return }
                    Task { @MainActor in
                        // PNG and JPEG as they are; TIFF and anything else as PNG (the model reads png/jpg/gif/webp).
                        let keep = type == .png || type == .jpeg
                        guard let bytes = keep ? data : pngData(data) else { return }
                        let ext = type == .jpeg ? "jpg" : "png"
                        var base = (name ?? "").trimmingCharacters(in: .whitespaces)
                        if ChatAttach.imageTypes.contains((base as NSString).pathExtension.lowercased()) {
                            base = (base as NSString).deletingPathExtension
                        }
                        if base.isEmpty {
                            let n = ClipboardPaste.imageName(type: "public.png").replacingOccurrences(of: "Pasted", with: "Dropped")
                            base = String(n.dropLast(4))   // without ".png"
                        }
                        add([memoryURL(bytes, name: base + "." + ext)])
                    }
                }
            }
        }
        return took
    }

    @MainActor
    static func pick() -> [URL] {
        let p = NSOpenPanel()
        p.allowsMultipleSelection = true
        p.canChooseDirectories = false
        p.message = "Attach files to the message"
        return p.runModal() == .OK ? Array(p.urls.prefix(maxFiles)) : []
    }

    @MainActor
    static func icon(name: String, url: URL?) -> NSImage {
        if let url, url.isFileURL, FileManager.default.fileExists(atPath: url.path) { return NSWorkspace.shared.icon(forFile: url.path) }
        return NSWorkspace.shared.icon(for: UTType(filenameExtension: (name as NSString).pathExtension) ?? .data)
    }
}

/// The preview of one file that went as text (not uploaded): a thumbnail for an image attached on this Mac, the
/// file's icon otherwise. A click opens it. Under it, when the agent got only the name, a footnote says so.
@MainActor
struct ChatAttachCard: View {
    let ref: ChatAttach.Ref
    /// In the person's dark bubble.
    var dark = true
    @State private var thumb: NSImage?
    @State private var hover = false
    /// A click opens the file in a preview popup.
    @State private var preview: AttachmentPreviewPopup.Item?

    private var url: URL? { ChatAttach.local[ref.name] }
    /// Only a real file of the person's opens as a file; bytes in memory open as what they are.
    private var fileURL: URL? { url.flatMap { $0.isFileURL ? $0 : nil } }
    private var fg: Color { dark ? .white : WS.ink }
    private var fg2: Color { dark ? .white.opacity(0.65) : WS.text2 }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Button(action: open) { tile }
                .buttonStyle(.liaPlain)
                .disabled(url == nil)
                .onHover { hover = $0 }
                .liaPointer()
                .accessibilityLabel(Text("Attachment \(ref.name), \(ref.size)"))
                .accessibilityHint(Text(url == nil ? "Not on this Mac" : "Opens the file"))
            if !ref.inlined {
                Text("Not uploaded: the agent got only the name and size.")
                    .font(LiaFont.ui(11)).foregroundStyle(fg2)
            }
        }
        .task(id: ref.id) { await loadThumb() }
        .liaModal(item: $preview) { item in AttachmentPreviewPopup(item: item) }
    }

    @ViewBuilder private var tile: some View {
        if let thumb {
            Image(nsImage: thumb).resizable().aspectRatio(contentMode: .fill)
                .frame(maxWidth: 220, maxHeight: 160).frame(minWidth: 80, minHeight: 60)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(fg.opacity(hover ? 0.5 : 0.15)))
        } else {
            HStack(spacing: 8) {
                Image(nsImage: ChatAttach.icon(name: ref.name, url: url)).resizable().frame(width: 26, height: 26)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 1) {
                    Text(ref.name).font(LiaFont.ui(12.5, .medium)).foregroundStyle(fg).lineLimit(1).truncationMode(.middle)
                    Text(ref.size).font(LiaFont.ui(11)).foregroundStyle(fg2)
                }
            }
            .padding(.horizontal, 10).padding(.vertical, 7)
            .frame(maxWidth: 260, alignment: .leading)
            .background(fg.opacity(hover ? 0.16 : 0.10), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
    }

    private func open() {
        if let u = fileURL { preview = AttachmentPreviewPopup.Item(name: ref.name, source: .file(u), image: ref.isImage); return }
        if let u = url, let d = ChatAttach.memoryData(u), let s = String(data: d, encoding: .utf8), !ref.isImage {
            preview = AttachmentPreviewPopup.Item(name: ref.name, source: .text(s))
        }
    }

    private func loadThumb() async {
        guard ref.isImage, let url else { return }
        if let d = ChatAttach.memoryData(url) { thumb = NSImage(data: d); return }
        guard url.isFileURL else { return }
        let img = await Task.detached(priority: .utility) { NSImage(contentsOf: url) }.value
        thumb = img
    }
}

/// An uploaded file in the person's bubble (from this Mac or from the thread's stored `att`): a picture as a
/// thumbnail, a document as its icon, name and size. A click opens the copy on this Mac, else the signed link.
@MainActor
struct ChatAttachmentTile: View {
    let attachment: ChatAttachment
    var auth: AuthStore? = nil
    @State private var hover = false
    @State private var localImage: NSImage?
    @State private var preview: AttachmentPreviewPopup.Item?

    /// A real file of the person's (not bytes in memory, not a kept draft's address).
    private var localURL: URL? { ChatAttach.local[attachment.name].flatMap { $0.isFileURL ? $0 : nil } }

    var body: some View {
        Button(action: open) { tile }
            .buttonStyle(.liaPlain)
            .onHover { hover = $0 }
            .liaPointer()
            .accessibilityLabel(Text("\(attachment.isImage ? "Picture" : "File") \(attachment.name)" + (attachment.sizeLabel.map { ", " + $0 } ?? "")))
            .accessibilityHint(Text("Opens the file"))
            .liaModal(item: $preview) { item in AttachmentPreviewPopup(item: item, auth: auth) }
    }

    @ViewBuilder private var tile: some View {
        if attachment.isImage { picture } else { document }
    }

    @ViewBuilder private var picture: some View {
        Group {
            if let d = attachment.preview, let img = NSImage(data: d) {
                Image(nsImage: img).resizable().aspectRatio(contentMode: .fill)
            } else if let auth, let u = attachment.absoluteURL(base: AppConfig.aiBase) {
                // A small copy, given up after a while (UploadThumbs) - never a spinner for good.
                UploadThumb(key: attachment.key, url: u.absoluteString, auth: auth) { namedPicture }
            } else if let localImage {
                Image(nsImage: localImage).resizable().aspectRatio(contentMode: .fill)
            } else {
                // Stored without a signed address (the server signs it on read) and not on this Mac: say what it is.
                namedPicture
            }
        }
        .task(id: attachment.key) { await loadLocal() }
        .frame(width: 140, height: 104)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(Color.white.opacity(hover ? 0.5 : 0.15)))
    }

    /// A picture that cannot be shown: its symbol and name.
    private var namedPicture: some View {
        ZStack {
            Color.white.opacity(0.1)
            VStack(spacing: 4) {
                Image(systemName: "photo").font(.system(size: 16))
                Text(attachment.name).font(LiaFont.ui(10.5)).lineLimit(1).truncationMode(.middle).padding(.horizontal, 8)
            }
            .foregroundStyle(Color.white.opacity(0.7))
        }
    }

    private var document: some View {
        HStack(spacing: 8) {
            Image(nsImage: ChatAttach.icon(name: attachment.name, url: localURL)).resizable().frame(width: 26, height: 26)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                Text(attachment.name).font(LiaFont.ui(12.5, .medium)).foregroundStyle(.white).lineLimit(1).truncationMode(.middle)
                Text(attachment.sizeLabel ?? attachment.badge).font(LiaFont.ui(11)).foregroundStyle(.white.opacity(0.65))
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 7)
        .frame(maxWidth: 260, alignment: .leading)
        .background(Color.white.opacity(hover ? 0.16 : 0.10), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    /// The preview popup.: the server's copy first (the file lives there); the copy
    /// on this Mac only when the message carries no address.
    private func open() {
        if let u = attachment.absoluteURL(base: AppConfig.aiBase) {
            preview = AttachmentPreviewPopup.Item(name: attachment.name, source: .remote(u), image: attachment.isImage)
        } else if let u = localURL {
            preview = AttachmentPreviewPopup.Item(name: attachment.name, source: .file(u), image: attachment.isImage)
        }
    }

    /// The copy on this Mac, when the stored message carries no address and no bytes.
    private func loadLocal() async {
        guard attachment.preview == nil, attachment.url == nil, let u = localURL else { return }
        localImage = await Task.detached(priority: .utility) { NSImage(contentsOf: u) }.value
    }
}

/// The files waiting over the input for the next message: 44 pt tiles, a
/// picture as its thumbnail, any other file as its icon and name. \u{00D7} removes one; a click previews it (Quick Look).
/// The state (uploading, ready, as text) is a small mark on the tile and its tip.
struct ChatAttachTray: View {
    let files: [ChatAttach.File]
    /// For a library pick's thumbnail.
    var auth: AuthStore? = nil
    let onRemove: (ChatAttach.File) -> Void
    @State private var preview: AttachmentPreviewPopup.Item?

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(files) { f in ChatAttachTile(file: f, auth: auth, onOpen: { open(f) }, onRemove: { onRemove(f) }) }
            }
            .padding(.top, 6).padding(.trailing, 6).padding(.bottom, 1)
        }
        .liaModal(item: $preview) { item in AttachmentPreviewPopup(item: item, auth: auth) }
    }

    /// The file in the preview popup.: an uploaded file opens its server copy; the
    /// person's own file (on its way up, or sent as text) opens from where it is; a library pick opens nothing.
    private func open(_ f: ChatAttach.File) {
        guard let item = ChatAttach.previewItem(f) else { return }
        // A file opened from the input shows on the right, over the preview and the web, when the right
        // pane carries ComposerFileOverlay; the popup otherwise.
        if !ComposerFileViewer.shared.show(item) { preview = item }
    }
}

extension ChatAttach {
    /// What a tray file opens as (nil: nothing to open). An uploaded file opens its server copy; the person's own
    /// file (on its way up, or sent as text) opens from where it is; a library pick opens nothing.
    @MainActor
    static func previewItem(_ f: File) -> AttachmentPreviewPopup.Item? {
        guard f.library == nil else { return nil }
        if let a = f.uploaded, let u = a.absoluteURL(base: AppConfig.aiBase), a.isImage || !f.url.isFileURL {
            return AttachmentPreviewPopup.Item(name: f.name, source: .remote(u), image: a.isImage)
        } else if f.url.isFileURL {
            return AttachmentPreviewPopup.Item(name: f.name, source: .file(f.url), image: f.isImage)
        } else if !f.isImage, let d = memoryData(f.url), let s = String(data: d, encoding: .utf8) {
            return AttachmentPreviewPopup.Item(name: f.name, source: .text(s))
        }
        return nil
    }
}

/// One tile of the tray.
private struct ChatAttachTile: View {
    let file: ChatAttach.File
    var auth: AuthStore?
    let onOpen: () -> Void
    let onRemove: () -> Void
    @State private var thumb: NSImage?
    @State private var hover = false

    private var picture: Bool { file.library != nil || ((isPicture || isSVG) && thumb != nil) }
    /// A picture from the media library (an uploaded file with no bytes on this Mac) is a square
    /// thumbnail like a pasted one, not a file chip: its kind says picture even when its name has no extension.
    private var isPicture: Bool { file.isImage || file.uploaded?.isImage == true }
    /// An SVG chip shows its picture, not a file icon.
    private var isSVG: Bool { UploadKind.isSVG(name: file.name, mime: "") }

    var body: some View {
        Button(action: onOpen) { face }
            .buttonStyle(.liaPlain)
            .liaPointer()
            .onHover { hover = $0 }
            .overlay(alignment: .topTrailing) { remove.offset(x: 6, y: -6) }
            .overlay(alignment: .bottomLeading) { stateMark.padding(3) }
            .help(file.name + " \u{00B7} " + ChatAttachChipState.help(file))
            .accessibilityElement(children: .contain)
            .accessibilityLabel(Text("\(file.name), \(ChatAttachChipState.spoken(file))"))
            .accessibilityHint(Text("Opens a preview"))
            .task(id: file.id) { await loadThumb() }
    }

    @ViewBuilder private var face: some View {
        if let m = file.library {
            ChatCreativeThumb(key: m.id, preview: m.isVideoUpload ? nil : m.preview, video: m.isVideo || m.isVideoUpload, auth: auth)
                .frame(width: 44, height: 44)
                .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
                .overlay(border)
        } else if isSVG, let thumb {
            Image(nsImage: thumb).resizable().interpolation(.high).aspectRatio(contentMode: .fit)
                .padding(4)
                .frame(width: 44, height: 44)
                .background(WS.soft)
                .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
                .overlay(border)
        } else if isPicture, let thumb {
            Image(nsImage: thumb).resizable().aspectRatio(contentMode: .fill)
                .frame(width: 44, height: 44)
                .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
                .overlay(border)
        } else if isPicture, file.uploaded != nil {
            // Its thumbnail on its way from the server (or not to be had): the same square, with the picture symbol.
            Image(systemName: "photo").font(.system(size: 13)).foregroundStyle(WS.text3)
                .frame(width: 44, height: 44)
                .background(WS.soft)
                .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
                .overlay(border)
        } else {
            HStack(spacing: 6) {
                Image(nsImage: ChatAttach.icon(name: file.name, url: file.url)).resizable().frame(width: 24, height: 24)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 1) {
                    Text(file.name).font(LiaFont.ui(11.5, .medium)).foregroundStyle(WS.ink).lineLimit(1).truncationMode(.middle)
                    Text(ChatAttach.size(file.bytes)).font(LiaFont.ui(10)).foregroundStyle(WS.text3).lineLimit(1)
                }
                .frame(maxWidth: 104, alignment: .leading)
            }
            .padding(.horizontal, 8)
            .frame(height: 44)
            .background(WS.soft, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            .overlay(border)
        }
    }

    private var border: some View {
        RoundedRectangle(cornerRadius: 9, style: .continuous).stroke(hover ? WS.ink.opacity(0.25) : WS.line2, lineWidth: 1)
    }

    private var remove: some View {
        Button(action: onRemove) {
            Image(systemName: "xmark").font(.system(size: 7.5, weight: .bold)).foregroundStyle(WS.onInk)
                .frame(width: 16, height: 16)
                .background(WS.ink.opacity(0.75), in: Circle())
                .overlay(Circle().stroke(WS.surface, lineWidth: 1.5))
                .contentShape(Circle())
        }
        .buttonStyle(.liaPlain).liaPointer()
        .accessibilityLabel(Text("Remove \(file.name)"))
    }

    /// Uploading: a spinner; sent as text or by name: an amber mark (the tip says why); ready: nothing.
    @ViewBuilder private var stateMark: some View {
        switch file.state {
        case .uploading:
            ProgressView().controlSize(.mini)
                .padding(2).background(WS.surface.opacity(0.9), in: Circle())
                .accessibilityHidden(true)
        case .fallback:
            Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 8.5)).foregroundStyle(WS.amberInk)
                .padding(2.5).background(WS.surface.opacity(0.9), in: Circle())
                .accessibilityHidden(true)
        case .uploaded, .library:
            EmptyView()
        }
    }

    private func loadThumb() async {
        if isSVG, file.library == nil {
            let u = file.url
            var d = ChatAttach.memoryData(u)
            if d == nil, u.isFileURL { d = await Task.detached(priority: .utility) { try? Data(contentsOf: u) }.value }
            if let d { thumb = SVGRaster.thumbnail(d, side: 44) }
            return
        }
        guard isPicture, file.library == nil else { return }
        // Bytes this Mac holds (a paste, an upload's own bytes, a kept draft's thumbnail) before any file.
        if let d = ChatAttach.memoryData(file.url) ?? file.uploaded?.preview {
            let small = await Task.detached(priority: .utility) { ChatAttach.thumbnail(d, max: 132) }.value
            thumb = NSImage(data: small ?? d)
            return
        }
        // A picture picked in the media library has only its server copy: a small one of it.
        if let a = file.uploaded, let auth, let u = a.absoluteURL(base: AppConfig.aiBase) {
            thumb = await UploadThumbs.shared.image(key: a.key, url: u.absoluteString, auth: auth)
            return
        }
        guard file.url.isFileURL else { return }
        let url = file.url
        let img = await Task.detached(priority: .utility) { () -> NSImage? in
            guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
            let opts: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                         kCGImageSourceCreateThumbnailWithTransform: true,
                                         kCGImageSourceThumbnailMaxPixelSize: 132]
            guard let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary) else { return nil }
            return NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
        }.value
        thumb = img
    }
}

/// The chip's state: uploading (spinner), ready, or the fallback with its reason named ("Over 10 MB \u{00b7} as text").
struct ChatAttachChipState: View {
    let file: ChatAttach.File

    var body: some View {
        switch file.state {
        case .uploading:
            HStack(spacing: 4) {
                ProgressView().controlSize(.mini).accessibilityHidden(true)
                Text("Uploading\u{2026}").font(LiaFont.ui(11)).foregroundStyle(WS.text3)
            }
        case .uploaded:
            Label("Ready", systemImage: "checkmark.circle.fill").labelStyle(.titleAndIcon)
                .font(LiaFont.ui(11)).foregroundStyle(WS.text3)
        case .library:
            Text("From library").font(LiaFont.ui(11)).foregroundStyle(WS.text3)
        case .fallback(let why):
            HStack(spacing: 4) {
                Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 9)).foregroundStyle(WS.amberInk)
                    .accessibilityHidden(true)
                Text(why + " \u{00b7} " + (file.inline != nil ? "as text" : "name only"))
                    .font(LiaFont.ui(11)).foregroundStyle(WS.text2).lineLimit(1).truncationMode(.tail)
                    .frame(maxWidth: 200, alignment: .leading)
            }
        }
    }

    static func help(_ f: ChatAttach.File) -> String {
        switch f.state {
        case .uploading: return "Uploading \u{00b7} Send waits until it is done"
        case .uploaded: return "Uploaded \u{00b7} the agent reads this file"
        case .library: return "From the media library \u{00b7} no upload needed"
        case .fallback(let why):
            return why + (f.inline != nil ? ". The agent reads the file's text instead." : ". The agent receives only the file's name and size.")
        }
    }

    static func spoken(_ f: ChatAttach.File) -> String {
        switch f.state {
        case .uploading: return "uploading"
        case .uploaded: return "uploaded, the agent reads it"
        case .library: return "from the media library"
        case .fallback(let why): return why + (f.inline != nil ? ", sent as text" : ", only the name is sent")
        }
    }
}

/// A media library item's picture: the copy kept on this Mac (an upload's poster), else its preview address, else a
/// symbol. Loads lazily (AuthedImage starts when it appears).
struct ChatCreativeThumb: View {
    let key: String
    let preview: String?
    var video = false
    var auth: AuthStore? = nil

    var body: some View {
        ZStack {
            WS.soft
            if let d = CreativePreviews.shared.data(for: key), let img = NSImage(data: d) {
                Image(nsImage: img).resizable().scaledToFill()
            } else if let auth, let p = preview ?? CreativePreviews.shared.url(for: key) {
                AuthedImage(url: p, auth: auth)
            } else {
                Image(systemName: video ? "play.rectangle" : "photo").font(.system(size: 11)).foregroundStyle(WS.text3)
            }
        }
    }
}

/// A media library item in the person's bubble ([attached_creative ...]): its picture when this Mac knows it, else
/// what it is.
struct ChatCreativeCard: View {
    let ref: ChatAttach.Ref
    var auth: AuthStore? = nil

    private var known: Bool {
        guard let k = ref.creative else { return false }
        return CreativePreviews.shared.data(for: k) != nil || CreativePreviews.shared.url(for: k) != nil
    }

    var body: some View {
        Group {
            if known, let k = ref.creative {
                ChatCreativeThumb(key: k, preview: nil, video: ref.name == "Meta video", auth: auth)
                    .frame(width: 140, height: 104)
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(Color.white.opacity(0.15)))
            } else {
                Label(ref.name, systemImage: ref.name == "Meta video" ? "play.rectangle" : "photo")
                    .font(LiaFont.ui(12.5, .medium)).foregroundStyle(.white)
                    .padding(.horizontal, 10).padding(.vertical, 7)
                    .background(Color.white.opacity(0.10), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("\(ref.name) from the media library"))
    }
}

/// The composer's files stay in its dialogue like its text, until the person removes or sends them -
/// across closing the messenger and a relaunch. Only what is already on the server is kept (ComposerDraftFiles): an
/// uploaded file by its key (a picture with a small thumbnail), a Storage / Meta pick by its id. A file still on its
/// way up is kept once it is up (the composer saves on every change of its files).
@MainActor
enum ChatDraftFiles {
    private static func key(_ thread: String) -> String { "lia_ws_draft_files_" + thread }
    /// Thumbnails made this run, by attachment key (a save on every change does not redraw them).
    private static var thumbs: [String: Data] = [:]

    static func save(_ files: [ChatAttach.File], thread: String) {
        let entries: [ComposerDraftFiles.Entry] = files.compactMap { f in
            if let m = f.library { return .library(m) }
            guard var a = f.uploaded else { return nil }
            if a.isImage, let full = a.preview {
                if thumbs[a.key] == nil, let t = ChatAttach.thumbnail(full) { thumbs[a.key] = t }
                a.preview = thumbs[a.key] ?? (full.count <= 64 * 1024 ? full : nil)
            } else {
                a.preview = nil
            }
            return .uploaded(a)
        }
        if entries.isEmpty {
            UserDefaults.standard.removeObject(forKey: key(thread))
        } else if let data = ComposerDraftFiles.encode(entries) {
            UserDefaults.standard.set(data, forKey: key(thread))
        }
    }

    /// The kept files as tray files (nothing on this Mac is opened for them).
    static func restore(_ thread: String) -> [ChatAttach.File] {
        ComposerDraftFiles.decode(UserDefaults.standard.data(forKey: key(thread))).map { e in
            switch e {
            case .library(let m):
                CreativePreviews.shared.remember(m)
                return ChatAttach.File.fromLibrary(m)
            case .uploaded(let a):
                return ChatAttach.File(url: ChatAttach.draftURL(a), name: a.name, bytes: a.bytes, inline: nil, state: .uploaded(a))
            }
        }
    }

    static func clear(_ thread: String) { UserDefaults.standard.removeObject(forKey: key(thread)) }
}
