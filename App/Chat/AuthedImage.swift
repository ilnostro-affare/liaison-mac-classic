import SwiftUI
import AppKit

/// An image from our workers: loaded with the session header and kept in a small memory cache.
/// AsyncImage cannot do this (no headers), which is why upload previews came back blank.
@MainActor
final class ImageCache {
    static let shared = ImageCache()
    private var items: [String: NSImage] = [:]
    private var order: [String] = []

    func image(_ key: String) -> NSImage? { items[key] }

    func store(_ img: NSImage, for key: String) {
        items[key] = img
        order.removeAll { $0 == key }   // one place per key, or a re-stored image is evicted early
        order.append(key)
        while order.count > 120, let oldest = order.first {
            order.removeFirst()
            items[oldest] = nil
        }
    }
}

struct AuthedImage: View {
    let url: String?
    let auth: AuthStore
    @State private var image: NSImage?
    @State private var failed = false

    var body: some View {
        ZStack {
            if let image {
                Image(nsImage: image).resizable().scaledToFill()
            } else if failed {
                LiaIcon("picture-in-picture", size: 20).foregroundStyle(AppConfig.text3)
            } else {
                ProgressView().controlSize(.small)
            }
        }
        .task(id: url) { await load() }
    }

    private func load() async {
        guard let url, !url.isEmpty else { failed = true; return }
        if let cached = ImageCache.shared.image(url) { image = cached; return }
        guard let data = await LiaAPI(auth: auth).authorizedData(url), let img = NSImage(data: data) else {
            failed = true
            return
        }
        ImageCache.shared.store(img, for: url)
        image = img
    }
}
