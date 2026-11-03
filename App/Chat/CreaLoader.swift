import SwiftUI
import AppKit
import UniformTypeIdentifiers

// Crea's pictures showed Retry right after they were made. The server cause (the agents
// worker signed with another secret than /intelligence/plot verifies) is fixed there; here the Mac is hardened:
// the link is absolute on the AI host, a refused link (403 "Link expired" / "Forbidden") is signed again by reading
// the dialogue (every read of /agents/dlg signs Crea's pictures anew), one quiet retry after a short pause covers the
// network, and only then the person sees Retry. One loader for the chat block and the Canvas board.

/// The dialogue a Crea block is in: where its links are signed again.
struct CreaContext: Equatable {
    let profile: String
    let dlg: String
    var key: String { profile + "|" + dlg }
}

/// Fresh signed links by picture id, from reading the dialogue again. The newest link wins over the block's own.
@MainActor
enum CreaLinks {
    private static var fresh: [String: String] = [:]
    private static var inflight: [String: Task<Void, Never>] = [:]
    private static var lastRead: [String: Date] = [:]

    /// The link to load a picture from now.
    static func link(_ p: CreaImages.Picture) -> String { fresh[p.id] ?? p.url }

    static func absolute(_ p: CreaImages.Picture) -> URL? {
        let raw = link(p)
        guard !raw.isEmpty else { return nil }
        return CreaImages.absoluteURL(raw, aiBase: AppConfig.aiBase, agentsBase: AppConfig.agentsBase)
    }

    /// Reads the dialogue's newest pages (up to 4 x 100 messages, stopping once `wanted` is found) and keeps every
    /// Crea picture's new link. Several pictures failing at once share one read; a read in the last 5 s is reused.
    /// True when `wanted` got a link different from `old`.
    static func refresh(_ ctx: CreaContext, wanted: String, old: String, auth: AuthStore) async -> Bool {
        if let t = inflight[ctx.key] {
            await t.value
        } else if let at = lastRead[ctx.key], Date().timeIntervalSince(at) < 5 {
            // just read: what it found is in `fresh`
        } else {
            let t = Task { @MainActor in
                let api = LiaAPI(auth: auth)
                var before: Int? = nil
                for _ in 0..<4 {
                    guard let page = try? await api.dialogPage(profile: ctx.profile, dlg: ctx.dlg, before: before, limit: 100) else { break }
                    var found = false
                    for m in page.messages {
                        for (id, u) in CreaImages.links(in: m.blocks) {
                            fresh[id] = u
                            if id == wanted { found = true }
                        }
                    }
                    guard !found, page.hasMore, let b = DlgMerge.before(page.messages) else { break }
                    before = b
                }
            }
            inflight[ctx.key] = t
            await t.value
            inflight[ctx.key] = nil
            lastRead[ctx.key] = Date()
        }
        guard let now = fresh[wanted], !now.isEmpty else { return false }
        return now != old
    }
}

@MainActor
enum CreaLoader {
    enum Outcome {
        case image(NSImage)
        /// Still being made: a spinner.
        case generating
        /// Retry for the person.
        case failed
        case cancelled
    }

    /// The picture already in memory (by its id: a re-signed link is the same picture).
    /// Edit area (CreaRegionEdit.swift): the newest version made on this Mac comes first, everywhere the picture is
    /// shown, downloaded or sent to Met; Undo there brings the picture itself back.
    static func cached(_ p: CreaImages.Picture) -> NSImage? {
        CreaRegionStore.shared.image(p.id) ?? ImageCache.shared.image(cacheKey(p))
    }
    static func bytes(_ p: CreaImages.Picture) -> Data? {
        CreaRegionStore.shared.data(p.id) ?? CreaBytes.data(cacheKey(p))
    }
    private static func cacheKey(_ p: CreaImages.Picture) -> String { "crea:" + p.id }

    /// Loads a picture: a stale or refused link is signed again once (when the dialogue is known), a network or
    /// server failure is retried once after a short pause; then `.failed`.
    static func load(_ p: CreaImages.Picture, ctx: CreaContext?, auth: AuthStore) async -> Outcome {
        if let img = cached(p) { return .image(img) }
        if p.generating && CreaLinks.link(p).isEmpty { return .generating }
        var relinked = false
        var retried = false
        // No link yet (an unsigned key), or one that has expired while the dialogue sat open: sign again first.
        if CreaLinks.link(p).isEmpty || CreaImages.isStale(CreaLinks.link(p)) {
            relinked = true
            if let ctx { _ = await CreaLinks.refresh(ctx, wanted: p.id, old: CreaLinks.link(p), auth: auth) }
        }
        while true {
            if Task.isCancelled { return .cancelled }
            guard let url = CreaLinks.absolute(p) else { return p.generating ? .generating : .failed }
            let (data, status) = await fetch(url, auth: auth)
            if Task.isCancelled { return .cancelled }
            if let data, let img = NSImage(data: data) {
                CreaBytes.store(data, for: cacheKey(p))
                CreaBytes.store(data, for: url.absoluteString)
                ImageCache.shared.store(img, for: cacheKey(p))
                return .image(img)
            }
            var v = CreaImages.verdict(status: status)
            if v == .ok { v = .retry }   // 200 that is not an image: once more, then Retry
            switch v {
            case .relink where !relinked:
                relinked = true
                if let ctx, await CreaLinks.refresh(ctx, wanted: p.id, old: CreaLinks.link(p), auth: auth) { continue }
                fallthrough
            case .relink, .retry, .ok:
                if retried { return .failed }
                retried = true
                try? await Task.sleep(nanoseconds: CreaImages.retryDelay)
            case .gone:
                return .failed
            }
        }
    }

    /// GET with the session header on our hosts; the status code too (authorizedData keeps only the bytes).
    /// A 401 gets one more try with a refreshed token.
    static func fetch(_ url: URL, auth: AuthStore) async -> (Data?, Int) {
        let api = LiaAPI(auth: auth)
        let ours = LiaAPI.isOurs(url)
        for attempt in 0..<2 {
            var req = URLRequest(url: url, timeoutInterval: 30)
            LiaClient.stamp(&req)   // X-Lia-Client, our hosts only
            if ours, let t = try? await api.token(forceRefresh: attempt == 1) {
                req.setValue("Bearer \(t)", forHTTPHeaderField: "Authorization")
            }
            guard let res = try? await api.session.data(for: req) else { return (nil, 0) }
            let status = (res.1 as? HTTPURLResponse)?.statusCode ?? 0
            if status == 401 && attempt == 0 && ours { continue }
            return ((200..<300).contains(status) ? res.0 : nil, status)
        }
        return (nil, 401)
    }
}

/// The buttons the chat block and the Canvas board share.
@MainActor
enum CreaActions {
    /// Download (no folder asked, the path is set): the bytes on screen into the downloads folder;
    /// else loaded (re-signed when needed); else the signed address with dl=1, fetched into the same folder - all
    /// through the app's downloads (the toolbar's flight, the popover's row).
    static func download(_ p: CreaImages.Picture, ctx: CreaContext?, auth: AuthStore) {
        if let d = CreaLoader.bytes(p) { save(d, name: p.fileName); return }
        Task { @MainActor in
            if case .image = await CreaLoader.load(p, ctx: ctx, auth: auth), let d = CreaLoader.bytes(p) {
                save(d, name: p.fileName)
                return
            }
            let live = CreaImages.Picture(id: p.id, n: p.n, url: CreaLinks.link(p), key: p.key, idea: p.idea, w: p.w, h: p.h)
            if let dl = CreaImages.downloadURL(live, aiBase: AppConfig.aiBase, agentsBase: AppConfig.agentsBase) {
                DownloadsCenter.shared.fetch(dl, name: p.fileName)
            }
        }
    }

    static func save(_ data: Data, name: String) {
        if DownloadsCenter.shared.save(data, name: name) == nil {
            WorkspaceModel.current?.show("Could not save the image to Downloads", symbol: "exclamationmark.triangle")
        }
    }

    /// "Use draft N" back into the dialogue (in Team addressed to Crea, not the router).
    static func useDraft(_ n: Int, in chat: TeamChatModel?) {
        chat?.send((chat?.dlg == "team" ? "@Crea " : "") + CreaImages.useDraft(n))
    }

    /// The dialogue named by a board (its profile and dlg), else Crea's own.
    static func chat(profile: String?, dlg: String?) -> TeamChatModel? {
        guard let ws = WorkspaceModel.current else { return nil }
        if let dlg { return ws.chat(for: dlg, profile: profile) }
        return ws.chat(for: DialogueSummary.dlg(forAgent: "crea"))
    }
}
