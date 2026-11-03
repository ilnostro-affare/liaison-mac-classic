import SwiftUI
import AppKit
import WebKit

// /02, (docs/UX-BACKLOG.md): Reader for article pages and Picture in Picture from the tab menu.
// Every script here runs in BrowserModel.agentWorld (it shares the DOM, never the page's own JavaScript).

/// What Reader shows: the page's title, its site and its text blocks.
struct ReaderArticle: Equatable {
    enum Kind: String { case p, h, li, q }
    struct Block: Equatable, Identifiable { let id: Int; let kind: Kind; let text: String }
    let tabID: UUID
    let url: URL
    let title: String
    let site: String
    let blocks: [Block]
}

/// Per tab and address: does the page read like an article, does it have a video; and the article on screen.
@MainActor
final class ReaderCenter: ObservableObject {
    static let shared = ReaderCenter()

    @Published private(set) var articles: Set<String> = []
    @Published private(set) var videos: Set<String> = []
    /// The article Reader shows now (over its tab's page), nil: closed.
    @Published var open: ReaderArticle?
    @Published private(set) var loading: UUID?
    private var checked: [String] = []

    private static func key(_ tab: BrowserTab) -> String? {
        guard let u = tab.url, ["http", "https"].contains(u.scheme?.lowercased() ?? "") else { return nil }
        return tab.id.uuidString + "|" + u.absoluteString
    }

    func isArticle(_ tab: BrowserTab) -> Bool { Self.key(tab).map { articles.contains($0) } ?? false }
    func hasVideo(_ tab: BrowserTab) -> Bool { Self.key(tab).map { videos.contains($0) } ?? false }

    /// After a load: one cheap look at the page (an <article>, or a block of paragraphs over 1500 characters; a <video>).
    func detect(_ tab: BrowserTab) async {
        guard !tab.isLoading, !tab.asleep, tab.pendingURL == nil, let k = Self.key(tab), !checked.contains(k) else { return }
        checked.append(k)
        if checked.count > 300 { checked.removeFirst(100) }
        let r = try? await tab.webView.callAsyncJavaScript(Self.probeJS, arguments: [:], in: nil, contentWorld: BrowserModel.agentWorld)
        guard let o = r as? [String: Any], Self.key(tab) == k else { return }
        if (o["article"] as? Bool) == true { articles.insert(k) }
        if (o["video"] as? Bool) == true { videos.insert(k) }
    }

    /// Reader on: the text is read from the page now (it may have changed since the probe).
    func show(_ tab: BrowserTab, ws: WorkspaceModel) {
        guard let u = tab.url, loading == nil else { return }
        loading = tab.id
        Task { @MainActor in
            defer { loading = nil }
            let r = try? await tab.webView.callAsyncJavaScript(Self.extractJS, arguments: [:], in: nil, contentWorld: BrowserModel.agentWorld)
            guard let s = r as? String, let data = s.data(using: .utf8),
                  let o = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let raw = o["blocks"] as? [[String: Any]], !raw.isEmpty else {
                ws.show("Reader couldn't find the article text on this page", symbol: "text.alignleft")
                return
            }
            let blocks = raw.enumerated().compactMap { i, b -> ReaderArticle.Block? in
                guard let t = b["t"] as? String, !t.isEmpty else { return nil }
                return ReaderArticle.Block(id: i, kind: ReaderArticle.Kind(rawValue: b["k"] as? String ?? "p") ?? .p, text: t)
            }
            open = ReaderArticle(tabID: tab.id, url: u, title: o["title"] as? String ?? tab.displayTitle,
                                 site: o["site"] as? String ?? (u.host ?? ""), blocks: blocks)
            AccessibilityNotification.Announcement("Reader").post()
        }
    }

    /// Asks the page's first video for Picture in Picture. WebKit wants a click inside the page for it, so a
    /// menu item is usually refused: then the person is told to use the video's own button. Honest, not faked.
    func pictureInPicture(_ tab: BrowserTab, ws: WorkspaceModel) {
        let js = """
        const v = document.querySelector('video');
        if (!v) return 'none';
        if (document.pictureInPictureElement === v) return 'ok';
        try { await v.requestPictureInPicture(); return 'ok'; } catch (e) { return 'denied'; }
        """
        Task { @MainActor in
            let r = try? await tab.webView.callAsyncJavaScript(js, arguments: [:], in: nil, contentWorld: BrowserModel.agentWorld)
            switch r as? String {
            case "ok": break
            case "none": ws.show("No video on this page", symbol: "pip")
            default: ws.show("Use the video's own picture-in-picture button", symbol: "pip")
            }
        }
    }

    private static let probeJS = """
    const art = document.querySelector('article');
    let article = !!art && (art.innerText || '').length > 1500;
    if (!article) {
      const m = new Map();
      for (const p of document.querySelectorAll('p')) {
        const n = (p.innerText || '').trim().length;
        if (n < 40 || !p.parentElement) continue;
        const k = p.parentElement; m.set(k, (m.get(k) || 0) + n);
      }
      for (const v of m.values()) if (v > 1500) { article = true; break; }
    }
    return { article: article, video: !!document.querySelector('video') };
    """

    // A raw string: the regular expressions keep their single backslashes.
    private static let extractJS = #"""
    const host = location.hostname.replace(/^www\./, '');
    const meta = (p) => { const e = document.querySelector('meta[property="' + p + '"]'); return e && e.content ? e.content.trim() : ''; };
    const m = new Map();
    for (const p of document.querySelectorAll('p')) {
      const n = (p.innerText || '').trim().length;
      if (n < 40 || !p.parentElement) continue;
      const k = p.parentElement; m.set(k, (m.get(k) || 0) + n);
    }
    let best = null, score = 0;
    for (const [k, v] of m) if (v > score) { best = k; score = v; }
    const art = document.querySelector('article');
    if (!best) best = art;
    if (!best) return JSON.stringify({ blocks: [] });
    const outer = best.closest('article');
    const root = outer && (outer.innerText || '').length < (best.innerText || '').length * 3 ? outer : best;
    const h1 = root.querySelector('h1') || document.querySelector('h1');
    const title = meta('og:title') || (h1 ? h1.innerText.trim() : '') || document.title;
    const out = [];
    for (const el of root.querySelectorAll('p, h2, h3, h4, li, blockquote, pre')) {
      if (el.closest('nav, aside, footer, form, button, figcaption')) continue;
      const tag = el.tagName.toLowerCase();
      if (tag === 'li' && el.querySelector('p')) continue;
      if (tag === 'p' && el.closest('blockquote, li')) continue;
      const t = (el.innerText || '').replace(/\s+/g, ' ').trim();
      if (!t) continue;
      const k = tag[0] === 'h' ? 'h' : tag === 'li' ? 'li' : tag === 'blockquote' ? 'q' : 'p';
      out.push({ k: k, t: t.slice(0, 6000) });
      if (out.length > 500) break;
    }
    return JSON.stringify({ title: title, site: meta('og:site_name') || host, blocks: out });
    """#
}

/// Reader's look: White, Sepia, Dark.
enum ReaderTheme: String, CaseIterable, Identifiable {
    case white, sepia, dark
    var id: String { rawValue }
    var title: String { rawValue.capitalized }
    var background: Color {
        switch self {
        case .white: return Color.white
        case .sepia: return Color(hex: 0xF8F1E3)
        case .dark: return Color(hex: 0x1C1C1E)
        }
    }
    var ink: Color {
        switch self {
        case .white: return Color(hex: 0x1D1D1F)
        case .sepia: return Color(hex: 0x4B3A2A)
        case .dark: return Color(hex: 0xE5E5E7)
        }
    }
    var secondary: Color { ink.opacity(0.6) }
}

/// The selected tab's investigations (behind its face): the article / video probe after each load.
struct ReaderProbe: View {
    @ObservedObject var tab: BrowserTab

    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .task(id: (tab.url?.absoluteString ?? "") + (tab.isLoading ? "~" : "")) {
                guard !tab.isLoading, !tab.isStart else { return }
                // Pages that build themselves after the load event get a moment.
                try? await Task.sleep(nanoseconds: 700_000_000)
                guard !Task.isCancelled else { return }
                await ReaderCenter.shared.detect(tab)
            }
            .accessibilityHidden(true)
    }
}

/// The "Reader" button in the selected tab when its page reads like an article.
struct ReaderTabButton: View {
    @ObservedObject var tab: BrowserTab
    let ws: WorkspaceModel
    @ObservedObject private var center = ReaderCenter.shared

    var body: some View {
        if center.isArticle(tab) {
            let on = center.open?.tabID == tab.id
            Button { toggle(on) } label: {
                Group {
                    if center.loading == tab.id { ProgressView().controlSize(.mini) }
                    else { Image(systemName: "text.alignleft").font(.system(size: 11, weight: .semibold)) }
                }
                .foregroundStyle(on ? WS.onInk : WS.text2)
                .frame(width: 22, height: 18)
                .background(on ? WS.ink : WS.soft, in: Capsule())
            }
            .buttonStyle(.liaPlain)
            .liaPointer()
            .liaTip(on ? "Close Reader" : "Show Reader")
            .accessibilityLabel(Text(on ? "Close Reader" : "Show Reader"))
            .transition(.opacity)
        }
    }

    private func toggle(_ on: Bool) {
        if on { center.open = nil } else { center.show(tab, ws: ws) }
    }
}

/// The page's own extras for the tab menu: Reader and Picture in Picture when the probe saw an article or a video.
struct WindowPageMenuItems: View {
    let tab: BrowserTab
    let ws: WorkspaceModel

    var body: some View {
        let center = ReaderCenter.shared
        if center.isArticle(tab) {
            Button(center.open?.tabID == tab.id ? "Close Reader" : "Show Reader") {
                if center.open?.tabID == tab.id { center.open = nil } else { center.show(tab, ws: ws) }
            }
        }
        if center.hasVideo(tab) {
            Button("Picture in Picture") { center.pictureInPicture(tab, ws: ws) }
        }
    }
}

/// Over the page card: Reader for this tab, when it is open; it closes when the page navigates away.
struct ReaderLayer: View {
    @ObservedObject var tab: BrowserTab
    let ws: WorkspaceModel
    @ObservedObject private var center = ReaderCenter.shared
    @Environment(\.accessibilityReduceMotion) private var reduce

    var body: some View {
        ZStack {
            if let a = center.open, a.tabID == tab.id {
                ReaderOverlay(article: a, ws: ws) { center.open = nil }
                    .transition(reduce ? AnyTransition.opacity : AnyTransition.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(WSMotion.navigation(reduce), value: center.open?.tabID)
        .onChange(of: tab.url) { _, u in
            if let a = center.open, a.tabID == tab.id, u != a.url { center.open = nil }
        }
    }
}

/// /02: the article in New York (serif) at ~680 pt, themes and size; "Summarise with Lia"; Esc closes.
struct ReaderOverlay: View {
    let article: ReaderArticle
    @ObservedObject var ws: WorkspaceModel
    let close: () -> Void
    @AppStorage("lia_reader_theme") private var themeRaw = ReaderTheme.white.rawValue
    @AppStorage("lia_reader_size") private var size: Double = 19

    private var theme: ReaderTheme { ReaderTheme(rawValue: themeRaw) ?? .white }
    /// Esc is Reader's only while nothing sits over it (a conversation or the palette own their Esc then).
    private var ownsEscape: Bool { ws.sheet == nil && ws.palette == nil }

    var body: some View {
        VStack(spacing: 0) {
            ReaderToolbar(theme: theme, themeRaw: $themeRaw, size: $size, ownsEscape: ownsEscape, close: close, summarise: summarise)
            Rectangle().fill(theme.ink.opacity(0.08)).frame(height: 1)
            ScrollView { text }
        }
        .background(theme.background)
        .environment(\.colorScheme, theme == .dark ? .dark : .light)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text("Reader: \(article.title)"))
    }

    private var text: some View {
        VStack(alignment: .leading, spacing: size * 0.8) {
            Text(article.site.uppercased())
                .font(.system(size: 12, weight: .semibold)).tracking(1)
                .foregroundStyle(theme.secondary)
            Text(article.title)
                .font(.system(size: size * 1.6, weight: .bold, design: .serif))
                .foregroundStyle(theme.ink)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityAddTraits(.isHeader)
            ForEach(article.blocks) { b in ReaderBlockView(block: b, size: size, theme: theme) }
        }
        .textSelection(.enabled)
        .frame(maxWidth: 680, alignment: .leading)
        .padding(.horizontal, 32)
        .padding(.vertical, 36)
        .frame(maxWidth: .infinity)
    }

    private func summarise() {
        let url = article.url.absoluteString
        close()
        ws.send("Summarise this article: \(url)", toAgent: "lia")
    }
}

private struct ReaderBlockView: View {
    let block: ReaderArticle.Block
    let size: Double
    let theme: ReaderTheme

    var body: some View {
        switch block.kind {
        case .h:
            Text(block.text)
                .font(.system(size: size * 1.2, weight: .semibold, design: .serif))
                .foregroundStyle(theme.ink)
                .padding(.top, size * 0.4)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityAddTraits(.isHeader)
        case .li:
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text("\u{2022}").foregroundStyle(theme.secondary)
                paragraph
            }
        case .q:
            HStack(spacing: 14) {
                Rectangle().fill(theme.ink.opacity(0.25)).frame(width: 3)
                paragraph.italic()
            }
        case .p:
            paragraph
        }
    }

    private var paragraph: some View {
        Text(block.text)
            .font(.system(size: size, design: .serif))
            .lineSpacing(size * 0.45)
            .foregroundStyle(theme.ink)
            .fixedSize(horizontal: false, vertical: true)
    }
}

private struct ReaderToolbar: View {
    let theme: ReaderTheme
    @Binding var themeRaw: String
    @Binding var size: Double
    var ownsEscape = true
    let close: () -> Void
    let summarise: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Button(action: close) {
                Image(systemName: "xmark").font(.system(size: 11, weight: .semibold)).frame(width: 26, height: 26)
            }
            .buttonStyle(.liaPlain)
            .keyboardShortcut(ownsEscape ? KeyboardShortcut.cancelAction : nil)
            .liaPointer()
            .accessibilityLabel(Text("Close Reader"))
            Spacer(minLength: 8)
            themes
            sizeControls
            Button(action: summarise) { Label("Summarise with Lia", systemImage: "sparkles") }
                .buttonStyle(WSButtonStyle(small: true))
                .liaPointer()
                .accessibilityHint(Text("Asks Lia for a summary of this article"))
        }
        .foregroundStyle(theme.ink)
        .padding(.horizontal, 14)
        .frame(height: 46)
    }

    private var themes: some View {
        HStack(spacing: 6) {
            ForEach(ReaderTheme.allCases) { t in
                Button { themeRaw = t.rawValue } label: {
                    Circle().fill(t.background)
                        .frame(width: 20, height: 20)
                        .overlay(Circle().stroke(t == theme ? WS.blue : theme.ink.opacity(0.25), lineWidth: t == theme ? 2 : 1))
                }
                .buttonStyle(.liaPlain)
                .liaPointer()
                .accessibilityLabel(Text("\(t.title) theme"))
                .accessibilityAddTraits(t == theme ? .isSelected : [])
            }
        }
    }

    private var sizeControls: some View {
        HStack(spacing: 2) {
            sizeButton("textformat.size.smaller", "Smaller text", -2).disabled(size <= 14)
            sizeButton("textformat.size.larger", "Larger text", 2).disabled(size >= 28)
        }
    }

    private func sizeButton(_ symbol: String, _ label: String, _ step: Double) -> some View {
        Button { size = min(28, max(14, size + step)) } label: {
            Image(systemName: symbol).font(.system(size: 12, weight: .medium)).frame(width: 26, height: 26)
        }
        .buttonStyle(.liaPlain)
        .liaPointer()
        .accessibilityLabel(Text(label))
    }
}
