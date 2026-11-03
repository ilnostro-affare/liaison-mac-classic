import SwiftUI
import AppKit
import WebKit
#if canImport(Translation)
import Translation
#endif

// The native side of page and selection translation (App/Browser/PageTranslator.swift): over the tab's web view,
// the engine that owns the on-device session, a status line while a page is translated, and the selection's
// translation popover anchored at the selection (ours on macOS 15, in the remembered language; the system's on 14.4).
// The selection is translated only from the right-click menu (no floating "Translate" chip over a
// selection). All of it is drawn by us over the page; the page itself is only read and its text nodes rewritten, in
// BrowserModel.agentWorld.

/// Over a tab's page (main window and private window).
struct TranslateTabLayer: View {
    let webView: WKWebView
    let url: URL?
    let isLoading: Bool
    var isPrivate = false

    var body: some View {
        TranslateLayerBody(model: PageTranslateCenter.shared.model(for: webView, isPrivate: isPrivate), url: url, isLoading: isLoading)
    }
}

private struct TranslateLayerBody: View {
    @ObservedObject var model: PageTranslator
    let url: URL?
    let isLoading: Bool

    var body: some View {
        GeometryReader { _ in
            ZStack(alignment: .topLeading) {
                Color.clear.allowsHitTesting(false)
                engine
                if model.choosing, model.notice == nil {
                    TranslatePageChooser(model: model)
                        .frame(maxWidth: .infinity, alignment: .top)
                        .padding(.top, 10)
                        .transition(.opacity)
                } else {
                    status
                        .frame(maxWidth: .infinity, alignment: .top)
                        .padding(.top, 10)
                }
            }
            .background(popoverAnchor)
        }
        .task(id: (url?.absoluteString ?? "") + (isLoading ? "~" : "")) {
            guard !isLoading else { return }
            // Pages that build themselves after the load event get a moment (as ReaderProbe does).
            try? await Task.sleep(nanoseconds: 600_000_000)
            guard !Task.isCancelled else { return }
            await model.pageLoaded(url)
        }
    }

    @ViewBuilder private var engine: some View {
        #if canImport(Translation)
        if #available(macOS 15.0, *) {
            if model.request != nil { PageTranslateEngine(model: model) }
            if model.selectionRequest != nil { SelectionTranslateEngine(model: model) }
        }
        #endif
    }

    // MARK: the selection

    /// The popover, anchored at the selection's rect. macOS 15: ours (SelectionTranslatePopover), in the language the
    /// person picked last. macOS 14.4: the system's, which picks its own language. "Replace with Translation" only
    /// where the page lets the person type (a field or an editable area).
    @ViewBuilder private var popoverAnchor: some View {
        #if canImport(Translation)
        let shown = Binding(get: { model.presenting != nil }, set: { if !$0 { model.presenting = nil } })
        let s = model.presenting
        if #available(macOS 15.0, *) {
            Color.clear
                .allowsHitTesting(false)
                .accessibilityHidden(true)
                .popover(isPresented: shown, attachmentAnchor: .rect(.rect(s?.rect ?? .zero)), arrowEdge: .top) {
                    SelectionTranslatePopover(model: model)
                }
        } else if #available(macOS 14.4, *) {
            let replace: ((String) -> Void)? = (s?.editable ?? false) ? { t in model.replaceSelection(with: t) } : nil
            Color.clear
                .allowsHitTesting(false)
                .accessibilityHidden(true)
                .translationPresentation(isPresented: shown, text: s?.text ?? "",
                                         attachmentAnchor: .rect(.rect(s?.rect ?? .zero)), arrowEdge: .top,
                                         replacementAction: replace)
        }
        #endif
    }

    // MARK: status

    @ViewBuilder private var status: some View {
        if let n = model.notice {
            pill { Text(n).font(LiaFont.ui(12)).foregroundStyle(WS.ink).multilineTextAlignment(.center) }
        } else {
            switch model.phase {
            case .preparing:
                pill {
                    HStack(spacing: 7) {
                        ProgressView().controlSize(.mini)
                        Text("Preparing translation\u{2026}").font(LiaFont.ui(12)).foregroundStyle(WS.ink)
                    }
                }
            case .translating where model.bar, .on where model.bar:
                // The page's bar carries its language, which can be changed here.
                TranslatePageBar(model: model)
            case .translating(let done, let total) where total > 0:
                pill {
                    HStack(spacing: 7) {
                        ProgressView().controlSize(.mini)
                        Text("Translating into \(PageTranslateCenter.name(model.target))\u{2026} \(min(100, done * 100 / max(1, total)))%")
                            .font(LiaFont.ui(12)).foregroundStyle(WS.ink).monospacedDigit()
                    }
                }
            default: EmptyView()
            }
        }
    }

    private func pill<C: View>(@ViewBuilder _ c: () -> C) -> some View {
        c()
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .frame(maxWidth: 420)
            .background(WS.pill, in: Capsule())
            .overlay(Capsule().stroke(WS.line, lineWidth: 1))
            .shadow(color: .black.opacity(0.12), radius: 8, y: 2)
            .allowsHitTesting(false)
            .transition(.opacity)
            .animation(WSMotion.micro, value: model.phase)
    }
}

#if canImport(Translation)
/// Owns the on-device session while the page is translated: `.translationTask` hands it over and cancels it when the
/// request changes or ends (the view leaves with it).
@available(macOS 15.0, *)
private struct PageTranslateEngine: View {
    @ObservedObject var model: PageTranslator
    @State private var config: TranslationSession.Configuration?
    @State private var running: PageTranslator.Request?

    var body: some View {
        Color.clear
            .frame(width: 1, height: 1)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
            .translationTask(config) { session in
                guard let req = running else { return }
                await model.run(session, for: req)
            }
            .onAppear { take(model.request) }
            .onChange(of: model.request) { _, r in take(r) }
    }

    private func take(_ r: PageTranslator.Request?) {
        guard let r else { running = nil; config = nil; return }
        let src = r.source.map { Locale.Language(identifier: $0) }
        let dst = Locale.Language(identifier: r.target)
        running = r
        if var c = config, c.source == src, c.target == dst {
            c.invalidate()        // the same languages again: a new run of the task
            config = c
        } else {
            config = TranslationSession.Configuration(source: src, target: dst)
        }
    }
}
#endif

#if canImport(Translation)
/// Owns the session for the selection's popover while it translates (as PageTranslateEngine for the page).
@available(macOS 15.0, *)
private struct SelectionTranslateEngine: View {
    @ObservedObject var model: PageTranslator
    @State private var config: TranslationSession.Configuration?
    @State private var running: PageTranslator.SelectionRequest?

    var body: some View {
        Color.clear
            .frame(width: 1, height: 1)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
            .translationTask(config) { session in
                guard let req = running else { return }
                await model.runSelection(session, for: req)
            }
            .onAppear { take(model.selectionRequest) }
            .onChange(of: model.selectionRequest) { _, r in take(r) }
    }

    private func take(_ r: PageTranslator.SelectionRequest?) {
        guard let r else { running = nil; config = nil; return }
        let src = r.source.map { Locale.Language(identifier: $0) }
        let dst = Locale.Language(identifier: r.target)
        running = r
        if var c = config, c.source == src, c.target == dst {
            c.invalidate()
            config = c
        } else {
            config = TranslationSession.Configuration(source: src, target: dst)
        }
    }
}
#endif

/// The selection's translation (macOS 15): "English -> <language>" with a menu to pick another (kept for the next
/// selection; the page keeps its own), the translation in its own scrolling area that grows with the text up to a cap, Copy, and
/// Replace where the page lets the person type. (the product's screenshot): the text area collapsed to a sliver
/// between the menu and Copy (a ScrollView with only a max height has no height of its own in a popover); it is
/// now measured and sized to the text, at least one line, at most `maxText`.
private struct SelectionTranslatePopover: View {
    @ObservedObject var model: PageTranslator
    @ObservedObject private var center = PageTranslateCenter.shared
    @State private var targets: [String] = []
    @State private var textHeight: CGFloat = 0
    private let maxText: CGFloat = 300

    private var shownTarget: String? { model.selectionTarget }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            content
            if case .done(let text) = model.selectionState {
                HStack(spacing: 8) {
                    Button("Copy") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(text, forType: .string)
                    }
                    .buttonStyle(ChatCapsuleButtonStyle(primary: false)).fixedSize().liaPointer()
                    if model.presenting?.editable ?? false {
                        Button("Replace with Translation") {
                            model.replaceSelection(with: text)
                            model.presenting = nil
                        }
                        .buttonStyle(ChatCapsuleButtonStyle()).fixedSize().liaPointer()
                    }
                    Spacer(minLength: 0)
                }
            }
            Text("Translated on this Mac.").font(LiaFont.ui(11)).foregroundStyle(WS.text3)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(14)
        .frame(width: 340, alignment: .leading)
        .fixedSize(horizontal: false, vertical: true)
        .task { await PageTranslateCenter.shared.loadTargets(); targets = PageTranslateCenter.shared.targets }
    }

    /// "English -> Russian ▾": always visible, its own row.
    private var header: some View {
        HStack(spacing: 6) {
            LiaIcon("translate", size: 14).foregroundStyle(WS.text2)
            if let from = model.selectionFrom {
                Text(PageTranslateCenter.name(from)).font(LiaFont.ui(12)).foregroundStyle(WS.text2)
                    .lineLimit(1).fixedSize()
                Text("\u{2192}").font(LiaFont.ui(12)).foregroundStyle(WS.text3)
            }
            Menu {
                ForEach(targets, id: \.self) { code in
                    Button {
                        model.translateSelection(to: code)
                    } label: {
                        if TranslateLang.same(code, shownTarget) { Label(PageTranslateCenter.name(code), systemImage: "checkmark") }
                        else { Text(PageTranslateCenter.name(code)) }
                    }
                    .disabled(TranslateLang.same(code, model.selectionFrom))
                }
            } label: {
                Text(shownTarget.map { PageTranslateCenter.name($0) } ?? "Choose Language")
                    .font(LiaFont.ui(12, .semibold)).foregroundStyle(WS.ink).lineLimit(1)
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .liaPointer()
            .accessibilityLabel(Text(shownTarget.map { "Translate into \(PageTranslateCenter.name($0))" } ?? "Choose a language"))
            Spacer(minLength: 0)
        }
        .frame(minHeight: 22)
    }

    @ViewBuilder private var content: some View {
        switch model.selectionState {
        case .working:
            HStack(spacing: 7) {
                ProgressView().controlSize(.small)
                Text("Translating\u{2026}").font(LiaFont.ui(12)).foregroundStyle(WS.text2)
            }
            .frame(maxWidth: .infinity, minHeight: 40, alignment: .leading)
        case .done(let text):
            ScrollView(.vertical) {
                Text(text).font(LiaFont.ui(13)).foregroundStyle(WS.ink)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(GeometryReader { g in
                        Color.clear.preference(key: TranslateTextHeightKey.self, value: g.size.height)
                    })
            }
            .scrollIndicators(textHeight > maxText ? .automatic : .never)
            .frame(height: min(maxText, max(20, textHeight)))
            .onPreferenceChange(TranslateTextHeightKey.self) { h in if abs(h - textHeight) > 0.5 { textHeight = h } }
        case .failed(let message):
            Text(message).font(LiaFont.ui(12)).foregroundStyle(WS.text2)
                .fixedSize(horizontal: false, vertical: true)
        case .choose(let message):
            VStack(alignment: .leading, spacing: 8) {
                Text(message).font(LiaFont.ui(12)).foregroundStyle(WS.text2)
                    .fixedSize(horizontal: false, vertical: true)
                TranslateLanguageMenu(title: "Choose Language", targets: targets, exclude: model.selectionFrom,
                                      current: shownTarget) { model.translateSelection(to: $0) }
            }
        }
    }
}

/// The measured height of the selection's translation text.
private struct TranslateTextHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

/// A capsule menu of every target language (the text's or page's own one disabled).
private struct TranslateLanguageMenu: View {
    let title: String
    let targets: [String]
    let exclude: String?
    let current: String?
    let pick: (String) -> Void

    var body: some View {
        Menu {
            ForEach(targets, id: \.self) { code in
                Button {
                    pick(code)
                } label: {
                    if TranslateLang.same(code, current) { Label(PageTranslateCenter.name(code), systemImage: "checkmark") }
                    else { Text(PageTranslateCenter.name(code)) }
                }
                .disabled(TranslateLang.same(code, exclude))
            }
        } label: {
            Text(title).font(LiaFont.ui(12, .semibold)).foregroundStyle(WS.ink)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .background(WS.soft, in: Capsule())
        .liaPointer()
    }
}

/// The person asked to translate the page and no language is settled for it: the first time (ask
/// which language, then remember it for pages), or the page is already in the remembered one (never
/// "already in English"). The languages, a suggestion first. Over the page, at the top, until a pick or Close.
private struct TranslatePageChooser: View {
    @ObservedObject var model: PageTranslator
    @State private var targets: [String] = []

    var body: some View {
        let from = model.pageLanguage
        let next = PageTranslateCenter.shared.pagePick(for: from)
        HStack(spacing: 8) {
            LiaIcon("translate", size: 14).foregroundStyle(WS.text2)
            Text(from.map { "This page is in \(PageTranslateCenter.name($0)). Translate into:" } ?? "Translate this page into:")
                .font(LiaFont.ui(12)).foregroundStyle(WS.ink).lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
            if let next {
                Button(PageTranslateCenter.name(next)) { model.translate(to: next) }
                    .buttonStyle(ChatCapsuleButtonStyle()).fixedSize().liaPointer()
            }
            TranslateLanguageMenu(title: next == nil ? "Choose Language" : "Other\u{2026}", targets: targets,
                                  exclude: from, current: nil) { model.translate(to: $0) }
            Button {
                model.choosing = false
            } label: {
                Image(systemName: "xmark").font(.system(size: 10, weight: .semibold)).foregroundStyle(WS.text2)
                    .frame(width: 18, height: 18)
            }
            .buttonStyle(.plain)
            .liaPointer()
            .accessibilityLabel(Text("Close"))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .frame(maxWidth: 520)
        .background(WS.pill, in: Capsule())
        .overlay(Capsule().stroke(WS.line, lineWidth: 1))
        .shadow(color: .black.opacity(0.12), radius: 8, y: 2)
        .task { await PageTranslateCenter.shared.loadTargets(); targets = PageTranslateCenter.shared.targets }
    }
}

/// The page's translate bar while it translates and a few seconds after: "Translated into <Russian ▾>" (the menu
/// switches the page to another language and remembers it for pages), the progress, Show Original, close.
private struct TranslatePageBar: View {
    @ObservedObject var model: PageTranslator
    @ObservedObject private var center = PageTranslateCenter.shared
    @State private var targets: [String] = []

    var body: some View {
        HStack(spacing: 8) {
            if case .translating = model.phase { ProgressView().controlSize(.mini) } else {
                LiaIcon("translate", size: 14).foregroundStyle(WS.text2)
            }
            Text(model.phase == .on ? "Translated into" : "Translating into").font(LiaFont.ui(12)).foregroundStyle(WS.ink)
                .lineLimit(1).fixedSize()
            Menu {
                ForEach(targets, id: \.self) { code in
                    Button {
                        model.translate(to: code)
                    } label: {
                        if TranslateLang.same(code, center.pageTarget) { Label(PageTranslateCenter.name(code), systemImage: "checkmark") }
                        else { Text(PageTranslateCenter.name(code)) }
                    }
                    .disabled(TranslateLang.same(code, model.pageLanguage))
                }
            } label: {
                Text(PageTranslateCenter.name(model.target)).font(LiaFont.ui(12, .semibold)).foregroundStyle(WS.ink).lineLimit(1)
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .padding(.horizontal, 8).padding(.vertical, 2)
            .background(WS.soft, in: Capsule())
            .liaPointer()
            .accessibilityLabel(Text("Language: \(PageTranslateCenter.name(model.target)). Change"))
            if case .translating(let done, let total) = model.phase, total > 0 {
                Text("\(min(100, done * 100 / max(1, total)))%").font(LiaFont.ui(12)).foregroundStyle(WS.text3).monospacedDigit()
            }
            Button("Show Original") { model.showOriginal() }
                .buttonStyle(ChatCapsuleButtonStyle(primary: false)).fixedSize().liaPointer()
            Button {
                model.hideBar()
            } label: {
                Image(systemName: "xmark").font(.system(size: 10, weight: .semibold)).foregroundStyle(WS.text2)
                    .frame(width: 18, height: 18)
            }
            .buttonStyle(.plain)
            .liaPointer()
            .accessibilityLabel(Text("Close"))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .frame(maxWidth: 520)
        .background(WS.pill, in: Capsule())
        .overlay(Capsule().stroke(WS.line, lineWidth: 1))
        .shadow(color: .black.opacity(0.12), radius: 8, y: 2)
        .transition(.opacity)
        .task { await PageTranslateCenter.shared.loadTargets(); targets = PageTranslateCenter.shared.targets }
    }
}

// MARK: - the tab's button

/// "Translate" in the selected tab (and the private window's address row): shown when the page is in a language the
/// person does not read, or while it is translated. A click translates or shows the original; its menu picks the
/// language and "Always translate" for the site.
struct TranslatePageButton: View {
    let webView: WKWebView
    var isPrivate = false
    var onDark = false

    var body: some View {
        TranslateButtonBody(model: PageTranslateCenter.shared.model(for: webView, isPrivate: isPrivate), onDark: onDark)
    }
}

private struct TranslateButtonBody: View {
    @ObservedObject var model: PageTranslator
    /// The remembered page target (changed in another tab: this menu follows).
    @ObservedObject private var center = PageTranslateCenter.shared
    let onDark: Bool
    @State private var targets: [String] = []

    var body: some View {
        if model.offer || model.phase != .off || model.choosing {
            let on = model.phase.isActive
            Menu {
                if on {
                    Button("Show Original") { model.showOriginal() }
                } else if let to = model.suggestedTarget {
                    Button("Translate to \(PageTranslateCenter.name(to))") { model.translate(to: to) }
                } else {
                    // No language picked for pages yet: the page asks.
                    Button("Translate Page\u{2026}") { model.translate() }
                }
                Menu("Translate To") {
                    ForEach(targets, id: \.self) { code in
                        Button {
                            model.translate(to: code)
                        } label: {
                            // The check: the page's remembered target (none before the first pick).
                            if TranslateLang.same(code, center.pageTarget) { Label(PageTranslateCenter.name(code), systemImage: "checkmark") }
                            else { Text(PageTranslateCenter.name(code)) }
                        }
                        .disabled(TranslateLang.same(code, model.pageLanguage))
                    }
                }
                if !model.isPrivate, let lang = model.pageLanguage, let site = model.siteName {
                    Divider()
                    Toggle("Always Translate \(PageTranslateCenter.name(lang)) on \(site)", isOn: Binding(
                        get: { model.alwaysOn }, set: { model.setAlways($0) }))
                }
                Divider()
                Text(model.pageLanguage.map { "Page in \(PageTranslateCenter.name($0)). Translated on this Mac." } ?? "Translated on this Mac.")
            } label: {
                glyph(on: on)
            } primaryAction: {
                model.toggle()
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .liaPointer()
            .accessibilityLabel(Text(on ? "Show original page" : "Translate page"))
            .task { await PageTranslateCenter.shared.loadTargets(); targets = PageTranslateCenter.shared.targets }
            .transition(.opacity)
        }
    }

    @ViewBuilder private func glyph(on: Bool) -> some View {
        Group {
            switch model.phase {
            case .preparing, .translating: ProgressView().controlSize(.mini)
            default: LiaIcon("translate", size: 14)
            }
        }
        .foregroundStyle(on ? WS.onInk : (onDark ? Color.white.opacity(0.75) : WS.text2))
        .frame(width: 24, height: 18)
        .background(on ? WS.ink : (onDark ? Color.white.opacity(0.12) : WS.soft), in: Capsule())
    }
}
