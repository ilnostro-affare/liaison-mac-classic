import SwiftUI
import AppKit
import ImageIO

/// "Media library > Uploads shows many tiles as endless spinners." Each tile downloaded the whole file
/// (a photo of 5-80 MB, all of them at once), decoded it at full size on the main thread, and kept it under its signed
/// address - which is new on every load of the index, so nothing was ever found in the cache the next time and every
/// opening started all the downloads again. Here a picture of Uploads (and of a sent message, and of the composer's
/// tray) is fetched at most four at a time, given up after 45 s, made small off the main thread (360 px), and kept
/// under its R2 key, which never changes. A picture that cannot be had is remembered for two minutes and its tile shows
/// the file's face instead of a spinner.
@MainActor
final class UploadThumbs {
    static let shared = UploadThumbs()
    static let side = 360
    static let parallel = 4
    static let timeout: Double = 45
    private static let retryAfter: TimeInterval = 120
    private static let cap = 240

    private var images: [String: NSImage] = [:]
    private var order: [String] = []
    private var failed: [String: Date] = [:]
    private var active = 0
    private var waiting: [CheckedContinuation<Void, Never>] = []

    func cached(_ key: String) -> NSImage? { images[key] }

    /// Failed lately (its tile shows the fallback at once).
    func failedRecently(_ key: String) -> Bool {
        guard let at = failed[key] else { return false }
        return Date().timeIntervalSince(at) < Self.retryAfter
    }

    /// The small picture of `key` (its file at `url`), or nil when it cannot be had (or the caller went away).
    func image(key: String, url: String, auth: AuthStore) async -> NSImage? {
        if let i = images[key] { return i }
        if failedRecently(key) { return nil }
        await acquire()
        defer { release() }
        if let i = images[key] { return i }   // another tile with the same key got it while this one waited
        if Task.isCancelled { return nil }
        let api = LiaAPI(auth: auth)
        let timeout = Self.timeout
        let data: Data? = await withTaskGroup(of: Data?.self) { g -> Data? in
            g.addTask { @MainActor () -> Data? in await api.authorizedData(url) }
            g.addTask { () -> Data? in
                try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                return nil
            }
            let first = await g.next() ?? nil
            g.cancelAll()
            return first
        }
        // Scrolled away: nothing is remembered, the tile tries again when it is back.
        if Task.isCancelled { return nil }
        let side = Self.side
        let cg: CGImage? = await Task.detached(priority: .utility) { () -> CGImage? in
            guard let data, let src = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
            let opts: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                         kCGImageSourceCreateThumbnailWithTransform: true,
                                         kCGImageSourceThumbnailMaxPixelSize: side]
            return CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary)
        }.value
        guard let cg else {
            failed[key] = Date()
            return nil
        }
        let img = NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
        store(img, key)
        return img
    }

    private func store(_ img: NSImage, _ key: String) {
        images[key] = img
        failed[key] = nil
        order.removeAll { $0 == key }
        order.append(key)
        while order.count > Self.cap, let oldest = order.first {
            order.removeFirst()
            images[oldest] = nil
        }
    }

    private func acquire() async {
        if active < Self.parallel { active += 1; return }
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in waiting.append(c) }
    }

    /// The slot goes to the next waiting tile (or is freed).
    private func release() {
        if waiting.isEmpty { active -= 1 } else { waiting.removeFirst().resume() }
    }
}

/// A picture of Uploads by its R2 key: a spinner while it loads (45 s at most), the picture, or `fallback` when it
/// cannot be had - never a spinner for good.
struct UploadThumb<Fallback: View>: View {
    let key: String
    let url: String?
    let auth: AuthStore
    let fallback: () -> Fallback
    @State private var image: NSImage?
    @State private var failed = false

    init(key: String, url: String?, auth: AuthStore, @ViewBuilder fallback: @escaping () -> Fallback) {
        self.key = key
        self.url = url
        self.auth = auth
        self.fallback = fallback
    }

    var body: some View {
        ZStack {
            if let image {
                Image(nsImage: image).resizable().scaledToFill()
            } else if failed {
                fallback()
            } else {
                ProgressView().controlSize(.small)
            }
        }
        .task(id: key) { await load() }
    }

    private func load() async {
        let thumbs = UploadThumbs.shared
        if let i = thumbs.cached(key) { image = i; return }
        guard let url, !url.isEmpty, !thumbs.failedRecently(key) else { failed = true; return }
        let img = await thumbs.image(key: key, url: url, auth: auth)
        if Task.isCancelled { return }
        if let img { image = img } else { failed = true }
    }
}
