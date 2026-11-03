import SwiftUI
import AppKit
import Quartz
import WebKit

// What a click on an attached file opens (ai.js / liaLightbox): a picture in the lightbox over the chat column,
// a document in a viewer. The site opens documents in its side canvas; here they open in a sheet - Quick Look for a
// file still on this Mac (it reads PDF, Office, text and CSV natively), the signed page for one already sent.

/// .lia-lightbox: rgba(0,0,0,.72) over the column, the picture at most 880 wide and 88% high with radius 14, its name
/// in 600 12px white at .85 under it, a 32 px round close button over the top-right corner. A click outside or Esc closes.
struct AttachmentLightbox: View {
    struct Item: Identifiable {
        let id = UUID()
        var image: NSImage? = nil
        var url: URL? = nil
        var name: String = ""
    }

    let item: Item
    var auth: AuthStore? = nil
    let onClose: () -> Void
    @State private var shown = false
    @State private var xHover = false

    var body: some View {
        GeometryReader { g in
            ZStack {
                Color.black.opacity(0.72)
                    .contentShape(Rectangle())
                    .onTapGesture(perform: onClose)
                VStack(spacing: 10) {
                    picture(maxW: min(880, max(100, g.size.width - 60)), maxH: max(100, g.size.height * 0.88 - 40))
                        .overlay(alignment: .topTrailing) { close.offset(x: 14, y: -14) }
                    if !item.name.isEmpty {
                        Text(verbatim: item.name).font(LiaFont.ui(12, .semibold)).foregroundStyle(Color.white.opacity(0.85))
                            .lineLimit(1).truncationMode(.middle)
                    }
                }
                .padding(30)
                .scaleEffect(shown ? 1 : 0.98)
            }
            .frame(width: g.size.width, height: g.size.height)
        }
        .opacity(shown ? 1 : 0)
        .onAppear { withAnimation(.easeOut(duration: 0.14)) { shown = true } }
        .background(
            // Esc anywhere in the window closes it, as the site's keydown listener does.
            Button("", action: onClose).keyboardShortcut(.cancelAction).opacity(0).allowsHitTesting(false)
        )
        .accessibilityAddTraits(.isModal)
    }

    @ViewBuilder
    private func picture(maxW: CGFloat, maxH: CGFloat) -> some View {
        if let img = item.image {
            let s = img.size
            let k: CGFloat = min(1, min(maxW / max(1, s.width), maxH / max(1, s.height)))
            Image(nsImage: img).resizable().interpolation(.high)
                .frame(width: max(1, s.width * k), height: max(1, s.height * k))
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        } else if let url = item.url, let auth {
            AuthedImage(url: url.absoluteString, auth: auth)
                .scaledToFit()
                .frame(maxWidth: maxW, maxHeight: maxH)
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        } else {
            RoundedRectangle(cornerRadius: 14).fill(AppConfig.surface3).frame(width: 240, height: 160)
        }
    }

    /// .lia-lightbox__x: 32 px circle, --ink-2, 1 px --line-2, --text.
    private var close: some View {
        Button(action: onClose) {
            LiaIcon("x", size: 15)
                .foregroundStyle(AppConfig.ink)
                .frame(width: 32, height: 32)
                .background(Circle().fill(AppConfig.ink2))
                .overlay(Circle().stroke(AppConfig.line2, lineWidth: 1))
                .contentShape(Circle())
        }
        .buttonStyle(.liaPlain)
        .liaHoverWash(Circle())
        .accessibilityLabel("Close")
    }
}

/// A document the person attached, in the window's modal (liaModal), framed like BlockSheet: the icon tile, the name
/// over its kind, the close; the document on paper below.
struct AttachmentDocSheet: View {
    struct Item: Identifiable {
        let id = UUID()
        let name: String
        var data: Data? = nil
        var url: URL? = nil
    }

    let item: Item
    @Environment(\.liaDismiss) private var dismiss
    @State private var loading = true
    /// A .docx card opened an empty white page (the signed address answers the bytes; a web view
    /// draws nothing for Office). Only HTML, Markdown and charts (no extension) go to the page; any other file is
    /// fetched and shown by Quick Look, an SVG as a picture.
    @State private var fetched: Data?
    @State private var failed = false

    private var route: FileView {
        let e = (item.name as NSString).pathExtension
        return e.isEmpty ? .page : FileView.of(ext: e)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                LiaIcon("note", size: 16).foregroundStyle(AppConfig.text2)
                    .frame(width: 30, height: 30)
                    .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(AppConfig.surface2))
                VStack(alignment: .leading, spacing: 1) {
                    Text(verbatim: item.name).font(LiaFont.ui(14, .semibold)).foregroundStyle(AppConfig.ink)
                        .lineLimit(1).truncationMode(.middle)
                    Text("Attachment").font(LiaFont.ui(11.5)).foregroundStyle(AppConfig.text3)
                }
                Spacer(minLength: 12)
                if loading && item.data == nil && item.url != nil && !failed { ProgressView().controlSize(.small) }
                LiaModalCloseButton(size: 28) { dismiss() }
            }
            .padding(.horizontal, 16).padding(.vertical, 12)
            .overlay(alignment: .bottom) { Rectangle().fill(AppConfig.line).frame(height: 1) }
            Group {
                if let d = item.data ?? fetched {
                    if route == .svg { SVGImageView(data: d).padding(16) } else { QuickLookFileView(data: d, name: item.name) }
                } else if let u = item.url, route == .page || route == .none {
                    SignedPageView(url: u, paper: true, onLoaded: { loading = false })
                } else if item.url != nil && !failed {
                    Color.white
                } else if failed {
                    Text("This file could not be loaded").font(LiaFont.ui(12.5)).foregroundStyle(Color(hex: 0x8A8F98))
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    Text("This file cannot be shown yet").font(LiaFont.ui(12.5)).foregroundStyle(Color(hex: 0x8A8F98))
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .background(Color.white)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(AppConfig.line, lineWidth: 1))
            .padding(12)
        }
        .frame(minWidth: 720, idealWidth: 980, maxWidth: 1100, minHeight: 520, idealHeight: 720, maxHeight: 820)
        .background(AppConfig.ink2)
        .task(id: item.id) { await fetch() }
    }

    private func fetch() async {
        guard item.data == nil, let u = item.url, route != .page, route != .none else { return }
        guard LiaAPI.isOurs(u), let (d, r) = try? await URLSession.shared.data(from: u),
              (r as? HTTPURLResponse)?.statusCode == 200, d.count <= 60 * 1024 * 1024
        else { failed = true; loading = false; return }
        fetched = d
        loading = false
    }
}

/// Quick Look over a file already on this Mac. Its text (PDF, Office, RTF, plain text) is selectable and copyable in
/// Quick Look's own view; nothing here turns that off.
struct QuickLookURLView: NSViewRepresentable {
    let url: URL

    func makeNSView(context: Context) -> QLPreviewView {
        let v: QLPreviewView = QLPreviewView(frame: .zero, style: .normal)
        v.autostarts = true
        v.previewItem = url as NSURL
        return v
    }

    func updateNSView(_ v: QLPreviewView, context: Context) {
        if (v.previewItem as? NSURL)?.absoluteString != url.absoluteString { v.previewItem = url as NSURL }
    }

    static func dismantleNSView(_ nsView: QLPreviewView, coordinator: ()) {
        nsView.close()
    }
}

/// An SVG as a picture (it showed its source). NSImage reads SVG on macOS 14; when it cannot, the
/// picture is drawn by a web view as an <img> (no scripts run in an <img>), never as the file's text.
struct SVGImageView: View {
    let data: Data

    var body: some View {
        if let img = NSImage(data: data), img.size.width > 0, img.size.height > 0 {
            Image(nsImage: img).resizable().interpolation(.high).scaledToFit()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            SVGWebImage(data: data)
        }
    }
}

/// An SVG's thumbnail (the Uploads tile, the composer chip) is its picture, rasterised once at
/// `side` points (2x pixels) through NSImage (macOS 14 reads SVG); nil when NSImage cannot read it.
enum SVGRaster {
    @MainActor
    static func thumbnail(_ data: Data, side: CGFloat) -> NSImage? {
        guard let src = NSImage(data: data), src.size.width > 0, src.size.height > 0 else { return nil }
        let k = min(side / src.size.width, side / src.size.height, 8)
        let size = NSSize(width: max(1, (src.size.width * k).rounded()), height: max(1, (src.size.height * k).rounded()))
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width * 2), pixelsHigh: Int(size.height * 2),
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return src }
        rep.size = size
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        src.draw(in: NSRect(origin: .zero, size: size))
        NSGraphicsContext.restoreGraphicsState()
        let out = NSImage(size: size)
        out.addRepresentation(rep)
        return out
    }
}

/// An SVG on our host (an Uploads tile) as its picture, fitted; `fallback` while it loads or when it cannot be read.
struct SVGRemoteThumb<Fallback: View>: View {
    let url: String
    let auth: AuthStore
    var side: CGFloat = 240
    @ViewBuilder let fallback: () -> Fallback
    @State private var image: NSImage?

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image).resizable().interpolation(.high).scaledToFit().padding(10)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                fallback()
            }
        }
        .task(id: url) { await load() }
    }

    private func load() async {
        let key = "svg|" + url
        if let c = ImageCache.shared.image(key) { image = c; return }
        guard let d = await LiaAPI(auth: auth).authorizedData(url), let img = SVGRaster.thumbnail(d, side: side) else { return }
        ImageCache.shared.store(img, for: key)
        image = img
    }
}

/// Text in a viewer (the attachment preview, the right pane): selectable and copyable, never editable (
/// ). An NSTextView, so a long file (up to 400,000 characters) scrolls without laying out as one Text.
struct SelectableTextView: NSViewRepresentable {
    let text: String

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSTextView.scrollableTextView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        if let tv = scroll.documentView as? NSTextView {
            tv.isEditable = false
            tv.isSelectable = true
            tv.isRichText = false
            tv.drawsBackground = false
            tv.textContainerInset = NSSize(width: 12, height: 14)
            tv.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
            tv.textColor = .labelColor
            tv.string = text
        }
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        if let tv = scroll.documentView as? NSTextView, tv.string != text { tv.string = text }
    }
}

private struct SVGWebImage: NSViewRepresentable {
    let data: Data

    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        let web = WKWebView(frame: .zero, configuration: config)
        web.setValue(false, forKey: "drawsBackground")
        let b64 = data.base64EncodedString()
        let html = "<!doctype html><html><head><meta charset=\"utf-8\"><style>html,body{margin:0;height:100%;background:transparent}"
            + "body{display:flex;align-items:center;justify-content:center}img{max-width:100%;max-height:100%}</style></head>"
            + "<body><img src=\"data:image/svg+xml;base64,\(b64)\"></body></html>"
        web.loadHTMLString(html, baseURL: nil)
        return web
    }

    func updateNSView(_ nsView: WKWebView, context: Context) {}
}

/// Quick Look's own view over a temporary copy of the bytes. The copy lives in the app's temporary folder and is
/// replaced by the next preview of the same name.
struct QuickLookFileView: NSViewRepresentable {
    let data: Data
    let name: String

    static func tempURL(for name: String, data: Data) -> URL? {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("lia-attachments", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var safe = name.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
        if safe.isEmpty { safe = "file" }
        if !safe.contains(".") { safe += ".txt" }
        let u = dir.appendingPathComponent(safe)
        do { try data.write(to: u, options: .atomic) } catch { return nil }
        return u
    }

    func makeNSView(context: Context) -> QLPreviewView {
        let v: QLPreviewView = QLPreviewView(frame: .zero, style: .normal)
        v.autostarts = true
        if let u = Self.tempURL(for: name, data: data) { v.previewItem = u as NSURL }
        return v
    }

    func updateNSView(_ nsView: QLPreviewView, context: Context) {}

    static func dismantleNSView(_ nsView: QLPreviewView, coordinator: ()) {
        nsView.close()
    }
}
