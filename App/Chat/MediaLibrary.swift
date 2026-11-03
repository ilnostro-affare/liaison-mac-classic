import SwiftUI
import AppKit
import AVFoundation
import UniformTypeIdentifiers

/// The media library as the workspace's attach sheet (the paperclip in a conversation): Uploads, Meta images,
/// Meta videos. "Upload from Mac\u{2026}" (the system picker) or a drop puts JPG / PNG (8 MB) and MP4 / MOV (200 MB) on
/// Uploads with a progress ring and a cancel; they come back already picked. (Uploads is the one place for
/// every file): any other file up to 100 MB goes to Uploads too (the input lane, /intelligence/attach-stream), and
/// Uploads lists every file ever put in an agent's input (the server's index) beside the library's own. Up to `limit`
/// items are picked; "Attach" hands them to the composer, where a pick travels as an [attached_creative] marker
/// (no upload: R2 or Meta already holds it). Tiles are uniform squares whose pictures load as they scroll in.
struct MediaLibrarySheet: View {
    let auth: AuthStore
    let account: String?
    /// How many more items the composer takes.
    var limit = 6
    /// The picks, and the files that are not library media (for the composer's own attach flow).
    let onPick: ([MediaItem], [URL]) -> Void
    @Environment(\.liaDismiss) private var dismiss
    @StateObject private var lib = MediaLibraryModel()
    @State private var dropping = false
    @State private var confirmDelete: MediaItem?
    @State private var viewing: MediaItem?
    /// A document from Uploads in the attachment preview (a PDF in PDFKit, text as text, else Open).
    @State private var viewingFile: AttachmentPreviewPopup.Item?

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().overlay(WS.line)
            if let line = lib.metaLine { metaStrip(line) }
            grid
            Divider().overlay(WS.line)
            footer
        }
        .frame(width: 680, height: 520)
        .background(WS.surface)
        .overlay { if dropping { dropHint } }
        .onDrop(of: [.fileURL], isTargeted: $dropping) { ps in receive(ps) }
        .task {
            // The sheet's account, else the workspace profile's; none: Uploads only.
            let acct = (account ?? "").isEmpty ? WorkspaceModel.current?.profile?.metaAccount : account
            lib.configure(auth: auth, account: acct, limit: limit)
            await lib.load()
        }
        .onDisappear { lib.cancelAll() }
        .liaModal(item: $viewing, style: .bare) { (it: MediaItem) in MediaViewer(item: it, auth: auth) }
        .liaModal(item: $viewingFile) { item in AttachmentPreviewPopup(item: item, auth: auth) }
        .overlay {
            if let it = confirmDelete {
                LiaConfirm(title: "Delete from Uploads?",
                           sub: "It disappears from Uploads. Chats where it was sent keep it, and ads already shipped keep their own copy in Meta.",
                           yes: "Delete", danger: true,
                           onYes: { confirmDelete = nil; Task { await lib.delete(it) } },
                           onNo: { confirmDelete = nil })
            }
        }
    }

    // MARK: header

    private var header: some View {
        HStack(spacing: 12) {
            Text("Media library").font(LiaFont.ui(15, .semibold)).foregroundStyle(WS.ink)
                .accessibilityAddTraits(.isHeader)
            tabs
            Spacer()
            Button { lib.add(ChatAttach.pick()) } label: {
                Label("Upload from Mac\u{2026}", systemImage: "arrow.up.doc")
            }
            .buttonStyle(WSButtonStyle(small: true))
            .liaPointer()
            .liaTip("Any file up to 100 MB")
            Button { dismiss() } label: {
                Image(systemName: "xmark").font(.system(size: 11, weight: .bold)).foregroundStyle(WS.text2)
                    .frame(width: 28, height: 28).background(WS.soft, in: Circle()).contentShape(Circle())
            }
            .buttonStyle(.liaPlain).liaPointer()
            .accessibilityLabel(Text("Close"))
        }
        .padding(.horizontal, 18).frame(height: 58)
    }

    private var tabs: some View {
        HStack(spacing: 2) {
            ForEach(MediaLibraryModel.Tab.allCases, id: \.self) { t in
                let off = t != .uploads && !lib.metaAvailable
                Button { lib.tab = t } label: {
                    Text(t.rawValue).font(LiaFont.ui(12, .medium))
                        .foregroundStyle(lib.tab == t ? WS.ink : WS.text2)
                        .padding(.horizontal, 11).frame(height: 26)
                        .background(lib.tab == t ? WS.surface : Color.clear, in: Capsule())
                        .shadow(color: lib.tab == t ? Color.black.opacity(0.08) : .clear, radius: 2, y: 1)
                        .contentShape(Capsule())
                }
                .buttonStyle(.liaPlain).liaPointer()
                .disabled(off)
                .opacity(off ? 0.45 : 1)
                .liaTip(off ? MediaLibraryModel.connectLine : nil)
                .accessibilityAddTraits(lib.tab == t ? .isSelected : [])
            }
        }
        .padding(2)
        .background(WS.soft, in: Capsule())
    }

    /// One line under the header when Meta's shelves are out; Uploads work as usual.
    private func metaStrip(_ line: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "info.circle").font(.system(size: 11, weight: .semibold)).foregroundStyle(WS.text3)
            Text(line).font(LiaFont.ui(12)).foregroundStyle(WS.text2).lineLimit(1)
            if lib.metaFailed {
                Button("Retry") { Task { await lib.load() } }
                    .buttonStyle(.liaPlain).font(LiaFont.ui(12, .semibold)).foregroundStyle(WS.blue).liaPointer()
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 18).frame(height: 32)
        .background(WS.soft.opacity(0.6))
        .overlay(alignment: .bottom) { Rectangle().fill(WS.line).frame(height: 1) }
    }

    // MARK: grid

    private var grid: some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 112, maximum: 170), spacing: 10)], spacing: 10) {
                if lib.tab == .uploads {
                    ForEach(lib.running) { r in MediaUploadTile(row: r, onCancel: { lib.cancel(r.id) }, onRetry: { lib.retry(r.id) }) }
                }
                if !lib.loaded {
                    ForEach(0..<12, id: \.self) { _ in
                        RoundedRectangle(cornerRadius: 12, style: .continuous).fill(WS.soft).aspectRatio(1, contentMode: .fit)
                    }
                } else {
                    ForEach(lib.rows) { (it: MediaItem) in tile(it) }
                }
            }
            .padding(16)
            if lib.loaded { emptyState }
        }
    }

    @ViewBuilder private var emptyState: some View {
        if let e = lib.error {
            VStack(spacing: 8) {
                Text(e).font(LiaFont.ui(12.5)).foregroundStyle(WS.text2).multilineTextAlignment(.center)
                Button("Try again") { Task { await lib.load() } }.buttonStyle(WSButtonStyle(small: true))
            }
            .frame(maxWidth: .infinity).padding(.top, 30)
        } else if lib.rows.isEmpty && (lib.tab != .uploads || lib.running.isEmpty) {
            VStack(spacing: 6) {
                Image(systemName: lib.tab == .videos ? "play.rectangle" : "photo.on.rectangle").font(.system(size: 22)).foregroundStyle(WS.text3)
                Text(lib.tab == .uploads ? "Drop files here or upload from your Mac" : "Nothing here yet")
                    .font(LiaFont.ui(12.5)).foregroundStyle(WS.text2)
            }
            .frame(maxWidth: .infinity).padding(.top, 40)
        }
    }

    private func tile(_ it: MediaItem) -> some View {
        let n = lib.picked.firstIndex(of: it.id).map { $0 + 1 }
        // A right click opened a different wrong file each time. The catcher that fires is chosen
        // among equal-sized tiles (LazyVGrid keeps hosted views of other tiles around), so the right click's list is
        // built for the tile under the pointer (the one hovered), never for whichever tile's catcher fired.
        return MediaTile(item: it, auth: auth, order: n, menu: { ctxItems(it) },
                         rightMenu: { [lib] in ctxItems(lib.hoveredItem ?? it) },
                         onHover: { [lib] h in
                             if h { lib.hoverId = it.id } else if lib.hoverId == it.id { lib.hoverId = nil }
                         }) { lib.toggle(it) }
    }

    private func ctxItems(_ it: MediaItem) -> [LiaCtxItem] {
        var out: [LiaCtxItem] = [LiaCtxItem(title: "View", icon: "eye") { openItem(it) }]
        if it.source == .metaVideo {
            out.append(LiaCtxItem(title: "Open in Facebook", icon: "arrow-square-out") {
                Task {
                    if let u = await LiaAPI(auth: auth).videoPermalink(videoId: it.id) { ExternalLink.openInSystemBrowser(u) }
                    else { lib.note = "Facebook link unavailable for this video" }
                }
            })
        }
        if it.source == .upload || it.source == .file {
            out.append(.sep)
            out.append(LiaCtxItem(title: "Delete from Uploads", icon: "trash", danger: true) { confirmDelete = it })
        }
        return out
    }

    /// A picture or a video in the lightbox; any other file of Uploads in the attachment preview.
    private func openItem(_ it: MediaItem) {
        if it.isFile, it.fileKind != "image" {
            guard let u = (it.url ?? it.preview).flatMap(URL.init(string:)) else { return }
            viewingFile = AttachmentPreviewPopup.Item(name: it.name.isEmpty ? "File" : it.name, source: .remote(u), image: false)
        } else {
            viewing = it
        }
    }

    // MARK: footer

    private var footer: some View {
        HStack(spacing: 10) {
            if let note = lib.note {
                Label(note, systemImage: "exclamationmark.triangle.fill")
                    .font(LiaFont.ui(12)).foregroundStyle(WS.amberInk).lineLimit(1)
            } else if !lib.running.filter({ $0.error == nil }).isEmpty {
                Text("Uploading \(lib.running.filter { $0.error == nil }.count)\u{2026} closing cancels it")
                    .font(LiaFont.ui(12)).foregroundStyle(WS.text3)
            } else {
                Text("Up to \(limit) \u{00b7} library items need no upload").font(LiaFont.ui(12)).foregroundStyle(WS.text3)
            }
            Spacer()
            Button("Cancel") { dismiss() }.buttonStyle(WSButtonStyle(small: true))
            Button(lib.picked.isEmpty ? "Attach" : "Attach \(lib.picked.count)") { attach() }
                .buttonStyle(WSButtonStyle(primary: true, small: true))
                .disabled(lib.picked.isEmpty)
                .opacity(lib.picked.isEmpty ? 0.5 : 1)
                .keyboardShortcut(.defaultAction)
        }
        .padding(.horizontal, 18).frame(height: 54)
    }

    private var dropHint: some View {
        RoundedRectangle(cornerRadius: 18, style: .continuous)
            .strokeBorder(WS.blue.opacity(0.7), style: StrokeStyle(lineWidth: 2, dash: [6, 5]))
            .background(WS.blue.opacity(0.06), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay(Label("Drop to upload", systemImage: "arrow.up.doc").font(LiaFont.ui(14, .semibold)).foregroundStyle(WS.blue))
            .padding(10)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }

    // MARK: actions

    private func receive(_ providers: [NSItemProvider]) -> Bool {
        let ps = providers.filter { $0.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) }
        guard !ps.isEmpty else { return false }
        let model = lib
        for p in ps.prefix(12) {
            _ = p.loadObject(ofClass: URL.self) { url, _ in
                guard let url else { return }
                Task { @MainActor in model.add([url]) }
            }
        }
        return true
    }

    private func attach() {
        let chosen = lib.chosen
        let other = lib.passThrough
        lib.passThrough = []
        dismiss()
        onPick(chosen, other)
    }
}

// MARK: - the model

@MainActor
final class MediaLibraryModel: ObservableObject {
    enum Tab: String, CaseIterable { case uploads = "Uploads", images = "Meta images", videos = "Meta videos" }

    /// One file on its way to the library.
    struct Upload: Identifiable, Equatable {
        let id = UUID()
        let url: URL
        let name: String
        let bytes: Int
        let mime: String
        var progress: Double = 0
        var error: String?
        var video: Bool { mime.hasPrefix("video/") }
        /// JPG / PNG / MP4 / MOV go to the ad library; any other file to the input lane (still Uploads).
        var libraryMedia: Bool { ["video/mp4", "video/quicktime", "image/jpeg", "image/png"].contains(mime) && (video || bytes <= AttachRoute.imageLimit) }
    }

    @Published var tab: Tab = .uploads
    @Published var uploads: [MediaItem] = []
    @Published var images: [MediaItem] = []
    @Published var videos: [MediaItem] = []
    @Published var loaded = false
    @Published var error: String?
    @Published var note: String?
    @Published var picked: [String] = []
    @Published var running: [Upload] = []
    /// The workspace has an ad account and Meta's shelves loaded (or are loading).
    @Published var metaAvailable = true
    /// Meta's shelves did not load although an ad account is set (Retry).
    @Published var metaFailed = false
    /// Files that are not library media: they go to the composer with the picks.
    var passThrough: [URL] = []
    /// The tile under the pointer (not published: read only when a right click builds its menu).
    var hoverId: String?
    var hoveredItem: MediaItem? { hoverId.flatMap { id in rows.first { $0.id == id } } }

    static let connectLine = "Connect Meta to see your ad media."
    /// The strip under the header (nil: Meta is fine).
    var metaLine: String? {
        if metaFailed { return "Meta media did not load. Uploads work as usual." }
        return metaAvailable ? nil : Self.connectLine
    }

    private var auth: AuthStore?
    private var account: String?
    private var limit = 6
    private var tasks: [UUID: Task<Void, Never>] = [:]

    var rows: [MediaItem] { tab == .uploads ? uploads : tab == .images ? images : videos }
    var chosen: [MediaItem] {
        let all = uploads + images + videos
        return picked.compactMap { k in all.first { $0.id == k } }
    }

    func configure(auth: AuthStore, account: String?, limit: Int) {
        self.auth = auth
        self.account = account
        self.limit = max(1, limit)
    }

    /// Without Meta (no ad account, or the read failed) the sheet stays on Uploads: the server's list when it
    /// answers, else the uploads this Mac made (MediaUploadStore). No error screen for a missing Meta.
    func load() async {
        guard let auth else { return }
        error = nil
        let hasAccount = !(account ?? "").isEmpty
        let member = auth.memberId
        // The server's Uploads index (every input file, named library uploads, what was deleted) beside the
        // library's own shelf. Either can fail alone; the other still fills the tab.
        let indexCall = Task { @MainActor in try? await LiaAPI(auth: auth).uploadsIndex() }
        var library: [MediaItem]
        do {
            let r = try await LiaAPI(auth: auth).mediaLibrary(account: hasAccount ? account : nil)
            library = MediaUploadStore.merge(server: r.uploads, member: member)
            images = r.images; videos = r.videos
            metaAvailable = hasAccount
            metaFailed = false
        } catch {
            // media_library answers 403 meta_not_connected before it lists our own uploads.
            library = MediaUploadStore.merge(server: nil, member: member)
            images = []; videos = []
            metaAvailable = false
            metaFailed = hasAccount
        }
        let index = await indexCall.value
        uploads = UploadsIndex.merge(index: index?.entries ?? [], library: library, hidden: index?.hidden ?? [])
        if !metaAvailable && tab != .uploads { tab = .uploads }
        loaded = true
    }

    func toggle(_ it: MediaItem) {
        if let i = picked.firstIndex(of: it.id) { picked.remove(at: i); note = nil; return }
        guard picked.count + passThrough.count < limit else { note = "Up to \(limit) per message"; return }
        picked.append(it.id)
    }

    /// Files from the picker or a drop: library media upload; anything else waits for Attach as a plain file.
    func add(_ urls: [URL]) {
        note = nil
        for u in urls {
            let values = try? u.resourceValues(forKeys: [.fileSizeKey, .isDirectoryKey])
            if values?.isDirectory == true { continue }
            let bytes = values?.fileSize ?? 0
            let mime = UTType(filenameExtension: u.pathExtension)?.preferredMIMEType ?? "application/octet-stream"
            let video = ["video/mp4", "video/quicktime"].contains(mime)
            if video && bytes > AttachRoute.videoLimit { note = "\(u.lastPathComponent): over 200 MB"; continue }
            // Any other file goes to Uploads as well (the input lane), up to 100 MB.
            if !video && bytes > ComposerLane.fileLimit { note = "\(u.lastPathComponent): over 100 MB"; continue }
            let up = Upload(url: u, name: u.lastPathComponent, bytes: bytes, mime: mime)
            tab = .uploads
            running.insert(up, at: 0)
            start(up)
        }
    }

    func cancel(_ id: UUID) {
        tasks[id]?.cancel()
        tasks[id] = nil
        running.removeAll { $0.id == id }
    }

    func retry(_ id: UUID) {
        guard let i = running.firstIndex(where: { $0.id == id }) else { return }
        running[i].error = nil
        running[i].progress = 0
        start(running[i])
    }

    func cancelAll() {
        for t in tasks.values { t.cancel() }
        tasks = [:]
    }

    private func start(_ up: Upload) {
        guard let auth else { return }
        let id = up.id
        let onProgress: @Sendable (Double) -> Void = { [weak self] p in
            Task { @MainActor in self?.setProgress(id, p) }
        }
        // Holds the model until the upload ends; cancelAll (the sheet closing) ends it.
        tasks[id] = Task { @MainActor in
            do {
                let item = try await MediaUploader.send(up, auth: auth, progress: onProgress)
                guard !Task.isCancelled else { return }
                self.finished(id, item: item)
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled else { return }
                self.failed(id, (error as? MediaUploader.Failure)?.message ?? userMessage(for: error))
            }
        }
    }

    private func finished(_ id: UUID, item: MediaItem) {
        tasks[id] = nil
        running.removeAll { $0.id == id }
        uploads.insert(item, at: 0)
        if item.source == .upload { MediaUploadStore.add(item, member: auth?.memberId) }
        if picked.count + passThrough.count < limit { picked.append(item.id) }
    }

    private func failed(_ id: UUID, _ why: String) {
        tasks[id] = nil
        if let i = running.firstIndex(where: { $0.id == id }) { running[i].error = why }
    }

    private func setProgress(_ id: UUID, _ p: Double) {
        guard let i = running.firstIndex(where: { $0.id == id }), running[i].error == nil else { return }
        if p - running[i].progress >= 0.01 || p >= 1 { running[i].progress = p }
    }

    /// Delete from Uploads. The index row goes first; bytes a chat holds stay (an input file always, a library
    /// file a chat carries); a library file no chat holds - or one the index never knew - is deleted for real by
    /// upload_delete, as before.
    func delete(_ it: MediaItem) async {
        guard let auth else { return }
        let api = LiaAPI(auth: auth)
        let d = await api.deleteUpload(key: it.id)
        var ok = d.ok && (it.isFile || !d.deleteBytes)
        var why = d.error
        if it.source == .upload && (d.deleteBytes || !d.ok) {
            let r = try? await api.mcpPost("upload_delete", ["r2_key": it.id])
            ok = r.map { JSONRead.bool($0, "ok") } ?? false
            why = r.flatMap { JSONRead.string($0, "error") } ?? why
        }
        if ok {
            uploads.removeAll { $0.id == it.id }
            picked.removeAll { $0 == it.id }
            MediaUploadStore.remove(it.id, member: auth.memberId)
        } else {
            note = why ?? "Delete failed"
        }
    }
}

// MARK: - uploads kept on this Mac

/// The uploads this Mac made (r2 key, name, preview address), per member, newest first, at most 60. The server's
/// list wins when it answers; this keeps Uploads full when media_library cannot answer (no Meta connected).
@MainActor
enum MediaUploadStore {
    private static let cap = 60
    private static func key(_ member: String?) -> String { "lia.media.uploads." + (member ?? "anon") }

    static func items(member: String?) -> [MediaItem] {
        guard let rows = UserDefaults.standard.array(forKey: key(member)) as? [[String: String]] else { return [] }
        return rows.compactMap { r in
            guard let id = r["id"], !id.isEmpty else { return nil }
            return MediaItem(id: id, source: .upload, name: r["name"] ?? "", preview: r["preview"], seconds: nil)
        }
    }

    private static func save(_ items: [MediaItem], member: String?) {
        let rows: [[String: String]] = items.prefix(cap).map { m in
            var r = ["id": m.id, "name": m.name]
            if let p = m.preview { r["preview"] = p }
            return r
        }
        UserDefaults.standard.set(rows, forKey: key(member))
    }

    static func add(_ item: MediaItem, member: String?) {
        var all = items(member: member).filter { $0.id != item.id }
        all.insert(item, at: 0)
        save(all, member: member)
    }

    static func remove(_ id: String, member: String?) {
        save(items(member: member).filter { $0.id != id }, member: member)
    }

    /// The server's uploads (when it answered) with this Mac's names for them, then the ones only this Mac knows.
    /// A server answer also drops the local rows it no longer has (deleted elsewhere).
    static func merge(server: [MediaItem]?, member: String?) -> [MediaItem] {
        let local = items(member: member)
        guard let server else { return local }
        let names = Dictionary(local.map { ($0.id, $0.name) }, uniquingKeysWith: { a, _ in a })
        let out = server.map { s in
            s.name.isEmpty ? MediaItem(id: s.id, source: s.source, name: names[s.id] ?? "", preview: s.preview, seconds: s.seconds) : s
        }
        save(out, member: member)
        return out
    }
}

// MARK: - the upload (progress, cancel)

/// One file into the media library: a picture as creative_upload (base64 JSON), a video streamed from disk as
/// creative_upload_stream (the file never sits in memory whole). Progress comes from the upload task's delegate;
/// cancelling the calling task cancels the request.
@MainActor
enum MediaUploader {
    struct Failure: Error { let message: String }

    /// `src` / `chat` name the upload in the Uploads index (a composer video: "chat", true - an Uploads delete then keeps
    /// the video the chat shows). A file that is not ad media goes to the input lane and comes back as a `.file` item.
    static func send(_ up: MediaLibraryModel.Upload, auth: AuthStore, progress: @escaping @Sendable (Double) -> Void,
                     src: String = "library", chat: Bool = false) async throws -> MediaItem {
        let api = LiaAPI(auth: auth)
        if !up.libraryMedia {
            do {
                let a = try await api.uploadFileStream(name: up.name, mime: up.mime, file: up.url, data: nil, src: src, progress: progress)
                progress(1)
                return MediaItem(id: a.key, source: .file, name: a.name, preview: a.isImage ? a.absoluteURL(base: AppConfig.aiBase)?.absoluteString : nil,
                                 seconds: nil, mime: a.mime, bytes: a.bytes, url: a.absoluteURL(base: AppConfig.aiBase)?.absoluteString, chat: true)
            } catch let e as UploadError {
                throw Failure(message: e.message)
            }
        }
        let delegate = UploadProgress(onProgress: progress)
        var picture: Data?
        let body: Data?
        let endpoint: String
        if up.video {
            let q = up.mime.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? up.mime
            endpoint = AppConfig.mcpBase + "/call/creative_upload_stream?mime=" + q
            body = nil
        } else {
            let url = up.url
            guard let data = await Task.detached(priority: .utility, operation: { try? Data(contentsOf: url) }).value else {
                throw Failure(message: "Could not read the file")
            }
            picture = data
            let json: [String: Any] = ["filename": up.name, "mime": up.mime, "data": data.base64EncodedString()]
            body = try JSONSerialization.data(withJSONObject: json)
            endpoint = AppConfig.mcpBase + "/call/creative_upload"
        }
        guard let url = URL(string: endpoint) else { throw Failure(message: "Upload failed") }
        var result: JSONObject?
        for attempt in 0..<2 {
            try Task.checkCancellation()
            let token = try await api.token(forceRefresh: attempt == 1)
            var req = URLRequest(url: url, timeoutInterval: 600)
            LiaClient.stamp(&req)   // X-Lia-Client, our hosts only
            req.httpMethod = "POST"
            req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            req.setValue(up.video ? up.mime : "application/json", forHTTPHeaderField: "Content-Type")
            let pair: (Data, URLResponse)
            do {
                if let body {
                    pair = try await URLSession.shared.upload(for: req, from: body, delegate: delegate)
                } else {
                    pair = try await URLSession.shared.upload(for: req, fromFile: up.url, delegate: delegate)
                }
            } catch {
                if Task.isCancelled || (error as? URLError)?.code == .cancelled { throw CancellationError() }
                throw Failure(message: "Network error. Check the connection and retry")
            }
            let status = (pair.1 as? HTTPURLResponse)?.statusCode ?? 0
            if status == 401 && attempt == 0 { continue }
            if status == 401 { throw Failure(message: "Session expired. Sign in again") }
            if status >= 500 { throw Failure(message: "Liaison could not store the file (HTTP \(status))") }
            result = JSONRead.object(pair.0) ?? [:]
            break
        }
        guard let r = result, JSONRead.bool(r, "ok"), let key = JSONRead.string(r, "r2_key") else {
            throw Failure(message: result.flatMap { JSONRead.string($0, "error") } ?? "Upload failed")
        }
        progress(1)
        if up.video {
            if let poster = await posterFrame(up.url) {
                CreativePreviews.shared.store(poster, for: key)
                _ = try? await api.creativeUpload(filename: "poster.jpg", mime: "image/jpeg", data: poster, extra: ["poster_for": key])
            }
        } else if let picture {
            CreativePreviews.shared.store(picture, for: key)
        }
        await api.registerUpload(key: key, name: up.name, mime: up.mime, bytes: up.bytes, src: src, chat: chat)
        return MediaItem(id: key, source: .upload, name: up.name, preview: JSONRead.string(r, "preview"), seconds: nil,
                         mime: up.mime, bytes: up.bytes, chat: chat)
    }

    /// The first moments of a video on disk as a JPEG, off the main thread.
    nonisolated static func posterFrame(_ url: URL) async -> Data? {
        await Task.detached(priority: .utility) { () -> Data? in
            let g = AVAssetImageGenerator(asset: AVURLAsset(url: url))
            g.appliesPreferredTrackTransform = true
            g.maximumSize = CGSize(width: 1024, height: 1024)
            guard let cg = try? g.copyCGImage(at: CMTime(seconds: 0.1, preferredTimescale: 600), actualTime: nil) else { return nil }
            return NSBitmapImageRep(cgImage: cg).representation(using: .jpeg, properties: [.compressionFactor: 0.8])
        }.value
    }
}

private final class UploadProgress: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    let onProgress: @Sendable (Double) -> Void
    init(onProgress: @escaping @Sendable (Double) -> Void) { self.onProgress = onProgress }

    func urlSession(_ session: URLSession, task: URLSessionTask, didSendBodyData bytesSent: Int64,
                    totalBytesSent: Int64, totalBytesExpectedToSend: Int64) {
        guard totalBytesExpectedToSend > 0 else { return }
        // The last few percent are the server storing it: the ring stops short of full until the answer comes.
        onProgress(min(0.97, Double(totalBytesSent) / Double(totalBytesExpectedToSend)))
    }
}

// MARK: - tiles

extension MediaItem {
    /// An upload that is a video: its preview is the file itself, not a picture.
    var isVideoUpload: Bool {
        source == .upload && [".mp4", ".mov"].contains { name.lowercased().hasSuffix($0) || id.lowercased().hasSuffix($0) }
    }
}

/// A file on its way up: its name, a progress ring and Cancel; a failure says why with Retry and Remove.
private struct MediaUploadTile: View {
    let row: MediaLibraryModel.Upload
    let onCancel: () -> Void
    let onRetry: () -> Void

    var body: some View {
        RoundedRectangle(cornerRadius: 12, style: .continuous).fill(WS.soft)
            .aspectRatio(1, contentMode: .fit)
            .overlay {
                VStack(spacing: 6) {
                    if let e = row.error {
                        Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 16)).foregroundStyle(WS.amberInk)
                        Text(e).font(LiaFont.ui(10.5)).foregroundStyle(WS.text2).multilineTextAlignment(.center).lineLimit(3)
                        HStack(spacing: 6) {
                            Button("Retry", action: onRetry).buttonStyle(WSButtonStyle(small: true))
                            Button { onCancel() } label: { Image(systemName: "trash").font(.system(size: 11)) }
                                .buttonStyle(.liaPlain).foregroundStyle(WS.text2).liaPointer()
                                .accessibilityLabel(Text("Remove"))
                        }
                    } else {
                        ZStack {
                            Circle().stroke(WS.line2, lineWidth: 3)
                            Circle().trim(from: 0, to: max(0.02, row.progress))
                                .stroke(WS.blue, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                                .rotationEffect(.degrees(-90))
                                .animation(.linear(duration: 0.2), value: row.progress)
                            Button(action: onCancel) {
                                Image(systemName: "xmark").font(.system(size: 10, weight: .bold)).foregroundStyle(WS.text2)
                                    .frame(width: 30, height: 30).contentShape(Circle())
                            }
                            .buttonStyle(.liaPlain).liaPointer()
                            .accessibilityLabel(Text("Cancel upload of \(row.name)"))
                        }
                        .frame(width: 36, height: 36)
                        Text("\(Int(row.progress * 100))% \u{00b7} \(ChatAttach.size(row.bytes))")
                            .font(LiaFont.ui(10.5).monospacedDigit()).foregroundStyle(WS.text3)
                    }
                    Text(row.name).font(LiaFont.ui(11, .medium)).foregroundStyle(WS.ink).lineLimit(1).truncationMode(.middle)
                }
                .padding(8)
            }
            .accessibilityElement(children: .contain)
            .accessibilityLabel(Text(row.error.map { "\(row.name): \($0)" } ?? "\(row.name), uploading, \(Int(row.progress * 100)) percent"))
    }
}

/// One library item as a uniform square: the preview cropped to fill (loaded when the tile appears), the play mark
/// and length on a video, the pick's order number, and a menu button on hover (the same items as the right click).
private struct MediaTile: View {
    let item: MediaItem
    let auth: AuthStore
    /// 1-based position among the picks (nil: not picked).
    let order: Int?
    let menu: () -> [LiaCtxItem]
    /// The right click's list (built for the hovered tile, see MediaLibrarySheet.tile).
    var rightMenu: (() -> [LiaCtxItem])? = nil
    var onHover: ((Bool) -> Void)? = nil
    let onToggle: () -> Void
    @State private var hover = false
    @ObservedObject private var host = DropdownHost.shared

    private var isVideo: Bool { item.isVideo || item.isVideoUpload }
    private var isSVG: Bool { UploadKind.isSVG(name: item.name.isEmpty ? item.id : item.name, mime: item.mime ?? "") }
    private var menuKey: AnyHashable { AnyHashable("media-tile-" + item.id) }
    private var selected: Bool { order != nil }

    var body: some View {
        let local: NSImage? = CreativePreviews.shared.data(for: item.id).flatMap { NSImage(data: $0) }
        Color.clear
            .aspectRatio(1, contentMode: .fit)
            .background(WS.soft)
            .overlay { picture(local) }
            .overlay {
                if isVideo && !item.isFile && (local != nil || (item.preview != nil && !item.isVideoUpload)) {
                    Image(systemName: "play.fill").font(.system(size: 11)).foregroundStyle(Color.white)
                        .frame(width: 26, height: 26).background(Circle().fill(Color.black.opacity(0.45)))
                }
            }
            .overlay(alignment: .bottomTrailing) {
                if let d = item.durationLabel {
                    Text(d).font(LiaFont.ui(10, .semibold).monospacedDigit()).foregroundStyle(Color.white)
                        .padding(.horizontal, 5).padding(.vertical, 1)
                        .background(Capsule().fill(Color.black.opacity(0.6))).padding(6)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(selected ? WS.blue : WS.line, lineWidth: selected ? 2.5 : 1))
            .overlay(alignment: .topLeading) {
                if let order {
                    Text("\(order)").font(LiaFont.ui(11, .bold)).foregroundStyle(Color.white).frame(width: 20, height: 20)
                        .background(Circle().fill(WS.blue)).padding(6)
                }
            }
            .overlay(alignment: .topTrailing) {
                if hover || host.owner == menuKey { menuButton.padding(5) }
            }
            .scaleEffect(hover ? 1.02 : 1)
            .animation(.easeOut(duration: 0.12), value: hover)
            .contentShape(Rectangle())
            .onTapGesture { onToggle() }
            .onHover { h in hover = h; onHover?(h) }
            .liaPointer()
            .liaContextMenu(rightMenu ?? menu)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text((item.name.isEmpty ? (isVideo ? "Video" : "Image") : item.name) + (selected ? ", selected" : "")))
            .accessibilityAddTraits(.isButton)
            .accessibilityAction { onToggle() }
    }

    @ViewBuilder
    private func picture(_ local: NSImage?) -> some View {
        if let local {
            Image(nsImage: local).resizable().scaledToFill()
        } else if isSVG, let u = item.url ?? item.preview {
            // An SVG is its picture, not the code symbol (the file face while it loads or fails).
            SVGRemoteThumb(url: u, auth: auth) { fileFace }
        } else if item.isFile && (item.fileKind != "image" || item.preview == nil) {
            fileFace
        } else if let p = item.preview, !item.isVideoUpload {
            // (endless spinners): a small copy kept under the item's key, given up after a while;
            // a picture that cannot be had shows its file face.
            UploadThumb(key: item.id, url: p, auth: auth) { fileFace }
        } else {
            Image(systemName: isVideo ? "play.rectangle" : "photo").font(.system(size: 18)).foregroundStyle(WS.text3)
        }
    }

    /// A file of Uploads that is not a picture: its type's symbol, its extension and its name.
    private var fileFace: some View {
        VStack(spacing: 6) {
            Image(systemName: UploadKind.symbol(item.fileKind)).font(.system(size: 22, weight: .regular)).foregroundStyle(WS.text2)
                .accessibilityHidden(true)
            Text(UploadKind.badge(item.name)).font(LiaFont.ui(9.5, .bold)).foregroundStyle(WS.text3)
                .padding(.horizontal, 5).padding(.vertical, 1)
                .background(Capsule().fill(WS.surface))
            Text(item.name).font(LiaFont.ui(10.5, .medium)).foregroundStyle(WS.ink)
                .lineLimit(2).multilineTextAlignment(.center).truncationMode(.middle)
                .padding(.horizontal, 8)
            if item.bytes > 0 {
                Text(ChatAttach.size(item.bytes)).font(LiaFont.ui(9.5)).foregroundStyle(WS.text3)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var menuButton: some View {
        DropdownButton(align: .trailing, help: "More", radius: 7, highlight: false, key: menuKey) {
            Image(systemName: "ellipsis").font(.system(size: 11, weight: .bold)).foregroundStyle(Color.white)
                .frame(width: 24, height: 24)
                .background(Circle().fill(Color.black.opacity(0.5)))
                .contentShape(Circle())
        } menu: {
            DropdownPanelView(minWidth: 180, padding: 5, radius: 12) {
                ForEach(menu()) { (m: LiaCtxItem) in
                    if m.separator {
                        DropdownDivider()
                    } else {
                        DropdownItem(title: m.title, icon: m.icon, danger: m.danger, fontSize: 12.5, action: m.action)
                    }
                }
            }
        }
    }
}

/// The library's lightbox: the item at the largest size that fits the window, aspect kept, a video playing in place
/// with the system player. Esc or a click beside the card closes it.
private struct MediaViewer: View {
    let item: MediaItem
    let auth: AuthStore
    @Environment(\.liaDismiss) private var dismiss
    @State private var mediaWidth: CGFloat = 0

    private var isVideo: Bool { item.isVideo || item.isVideoUpload }

    var body: some View {
        GeometryReader { (g: GeometryProxy) in
            ZStack {
                LiaModalScrim().onTapGesture { dismiss() }
                card(maxWidth: max(200, g.size.width - 120), maxHeight: max(160, g.size.height - 150))
            }
            .frame(width: g.size.width, height: g.size.height)
        }
    }

    private func card(maxWidth: CGFloat, maxHeight: CGFloat) -> some View {
        let local: NSImage? = CreativePreviews.shared.data(for: item.id).flatMap { NSImage(data: $0) }
        return VStack(alignment: .leading, spacing: 10) {
            Group {
                if isVideo {
                    CreativeVideoView(poster: item.source == .upload ? nil : item.preview, auth: auth,
                                      maxWidth: maxWidth, maxHeight: maxHeight, localPoster: local, autoplay: true) { [item, auth] in
                        if item.source == .upload { return item.preview }
                        return await LiaAPI(auth: auth).videoSource(videoId: item.id)
                    }
                } else {
                    FittedAuthedImage(url: item.preview, auth: auth, maxWidth: maxWidth, maxHeight: maxHeight, local: local)
                }
            }
            .background(GeometryReader { (m: GeometryProxy) in
                Color.clear
                    .onAppear { mediaWidth = m.size.width }
                    .onChange(of: m.size.width) { _, w in mediaWidth = w }
            })
            HStack(spacing: 10) {
                Text(item.name.isEmpty ? (isVideo ? "Video" : "Image") : item.name)
                    .font(LiaFont.ui(12.5, .medium)).foregroundStyle(WS.ink).lineLimit(1).truncationMode(.middle)
                if let d = item.durationLabel {
                    Text(d).font(LiaFont.ui(11.5).monospacedDigit()).foregroundStyle(WS.text3)
                }
                Spacer(minLength: 8)
                LiaModalCloseButton(size: 26) { dismiss() }
            }
            .frame(width: max(240, mediaWidth))
        }
        .padding(12)
        .fixedSize()
        .background(RoundedRectangle(cornerRadius: 20, style: .continuous).fill(WS.surface))
        .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).stroke(WS.line, lineWidth: 1))
        .contentShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
    }
}
