import AppKit
import AVFoundation

/// What the browser draws from a video before it goes up (ai.js liaVideoPoster / liaVideoBoard):
/// a poster from the first moments, and the storyboard, four frames at 10/35/65/90% in a 2x2 JPEG with 4 px white
/// gutters, each frame at most 512 px on its long side.
enum VideoFrames {
    private static func asset(_ data: Data) -> (AVURLAsset, URL)? {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".mov")
        guard (try? data.write(to: url)) != nil else { return nil }
        return (AVURLAsset(url: url), url)
    }

    private static func jpeg(_ cg: CGImage, quality: Double = 0.8) -> Data? {
        NSBitmapImageRep(cgImage: cg).representation(using: .jpeg, properties: [.compressionFactor: quality])
    }

    /// Off the main thread: writing the file and decoding a frame can take a second on a large video.
    static func poster(_ data: Data) async -> Data? {
        await Task.detached(priority: .userInitiated) { posterNow(data) }.value
    }

    private static func posterNow(_ data: Data) -> Data? {
        guard let (a, url) = asset(data) else { return nil }
        defer { try? FileManager.default.removeItem(at: url) }
        let g = AVAssetImageGenerator(asset: a)
        g.appliesPreferredTrackTransform = true
        g.maximumSize = CGSize(width: 1024, height: 1024)
        guard let cg = try? g.copyCGImage(at: CMTime(seconds: 0.1, preferredTimescale: 600), actualTime: nil) else { return nil }
        return jpeg(cg)
    }

    static func board(_ data: Data) async -> Data? {
        await Task.detached(priority: .utility) { await boardNow(data) }.value
    }

    private static func boardNow(_ data: Data) async -> Data? {
        guard let (a, url) = asset(data) else { return nil }
        defer { try? FileManager.default.removeItem(at: url) }
        guard let dur = try? await a.load(.duration), dur.seconds > 0 else { return nil }
        let g = AVAssetImageGenerator(asset: a)
        g.appliesPreferredTrackTransform = true
        g.maximumSize = CGSize(width: 512, height: 512)
        var frames: [CGImage] = []
        for f in AttachRoute.boardAt {
            let t = CMTime(seconds: max(0.05, dur.seconds * f), preferredTimescale: 600)
            if let (cg, _) = try? await g.image(at: t) { frames.append(cg) }
        }
        guard frames.count == 4, let first = frames.first else { return nil }
        let cw = first.width, ch = first.height
        let w = cw * 2 + 4, h = ch * 2 + 4
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        for (n, cg) in frames.enumerated() {
            // Core Graphics counts rows from the bottom: the first frame belongs top left.
            let x = (n % 2) * (cw + 4), yTop = (n / 2) * (ch + 4)
            ctx.draw(cg, in: CGRect(x: x, y: h - yTop - ch, width: cw, height: ch))
        }
        guard let out = ctx.makeImage() else { return nil }
        return jpeg(out)
    }
}

/// The picture of a creative this Mac uploaded, so the person's message can show it above the bubble.
/// The newest `limit` of each kept, oldest out first.
@MainActor
final class CreativePreviews {
    static let shared = CreativePreviews()
    static let limit = 40
    private var images: [String: Data] = [:]
    private var imageOrder: [String] = []
    private var urls: [String: String] = [:]
    private var urlOrder: [String] = []
    func store(_ d: Data, for key: String) {
        images[key] = d
        Self.touch(key, in: &imageOrder)
        while imageOrder.count > Self.limit { images[imageOrder.removeFirst()] = nil }
    }
    func data(for key: String) -> Data? { images[key] }
    /// A library pick's preview address, for the message that carries it.
    func remember(_ item: MediaItem) {
        guard let p = item.preview, !item.isVideoUpload else { return }
        urls[item.id] = p
        Self.touch(item.id, in: &urlOrder)
        while urlOrder.count > Self.limit { urls[urlOrder.removeFirst()] = nil }
    }
    /// The remembered address, else one rebuilt from a library upload's key: a picture sent days ago (or before a
    /// restart, when nothing is remembered) still draws instead of falling back to "Library upload".
    func url(for key: String) -> String? { urls[key] ?? MediaKeys.uploadAssetURL(key) }

    private static func touch(_ key: String, in order: inout [String]) {
        order.removeAll { $0 == key }
        order.append(key)
    }
}
