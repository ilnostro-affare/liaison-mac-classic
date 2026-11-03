import SwiftUI
import AppKit

// Every popup of the window as the site draws its modals (shell.js .setx-overlay / .setx-modal, ai.js bdModal):
// a veil over the WHOLE window - rgba(8,10,18,.5) on a 7 px blur - that takes the pointer, so nothing behind it
// lights on hover or reacts to a click; a click on the veil closes, and so does Esc. The card sits centred,
// radius 18, 1 px --line, no shadow (the veil already separates it).
// A `.sheet` cannot do this: it is a window of its own, the window behind keeps its hover, and a click beside it
// does nothing. So the popups are drawn here, in one host at the window's root (MainWindow), stacked in the order
// they opened; `.liaModal` at any call site puts its content on that stack.

/// The popup's own close, for content that closes itself (Cancel, ×, after a pick). Replaces `\.dismiss`,
/// which does nothing outside a sheet.
struct LiaDismissAction {
    var run: () -> Void = {}
    func callAsFunction() { run() }
}

private struct LiaDismissKey: EnvironmentKey { static let defaultValue = LiaDismissAction() }

extension EnvironmentValues {
    var liaDismiss: LiaDismissAction {
        get { self[LiaDismissKey.self] }
        set { self[LiaDismissKey.self] = newValue }
    }
}

/// How the host frames the content: `.card` gives it the site's card (clip, radius, hairline) over the veil;
/// `.bare` draws nothing around it - for content that brings its own veil and card (LiaConfirm).
enum LiaModalStyle { case card, bare }

@MainActor
final class LiaModalCenter: ObservableObject {
    static let shared = LiaModalCenter()

    struct Entry: Identifiable {
        let id: UUID
        var content: AnyView
        var style: LiaModalStyle
        var onDismiss: () -> Void
    }

    @Published private(set) var stack: [Entry] = []

    var isOpen: Bool { !stack.isEmpty }

    func present(_ id: UUID, style: LiaModalStyle, content: AnyView, onDismiss: @escaping () -> Void) {
        let e = Entry(id: id, content: content, style: style, onDismiss: onDismiss)
        if let i = stack.firstIndex(where: { $0.id == id }) {
            stack[i] = e
            return
        }
        // Whatever floats over the window goes: an open dropdown, a tip, the focus in the composer.
        DropdownHost.shared.close()
        TipHost.shared.dismiss()
        NSApp.keyWindow?.makeFirstResponder(nil)
        stack.append(e)
    }

    func remove(_ id: UUID) {
        stack.removeAll { $0.id == id }
    }

    /// Esc and the veil: the top popup closes the way its own Cancel would.
    func dismissTop() {
        stack.last?.onDismiss()
    }
}

/// The stack, drawn over the whole window. Attached once, in MainWindow.
struct LiaModalHost: View {
    @ObservedObject private var center = LiaModalCenter.shared

    var body: some View {
        ZStack {
            ForEach(Array(center.stack.enumerated()), id: \.element.id) { i, e in
                LiaModalLayer(entry: e, layer: 100 + i)
                    .transition(.opacity)
                    .zIndex(Double(i))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .animation(.easeOut(duration: 0.16), value: center.stack.map { $0.id })
        .allowsHitTesting(center.isOpen)
        // The popups follow the app's theme (WS is light/dark), like the window they sit over.
        .background(LiaModalEscape(active: center.isOpen).frame(width: 1, height: 1))
        .ignoresSafeArea()
    }
}

private struct LiaModalLayer: View {
    let entry: LiaModalCenter.Entry
    let layer: Int

    var body: some View {
        let dismiss = LiaDismissAction(run: entry.onDismiss)
        ZStack {
            if entry.style == .card {
                LiaModalScrim()
                    .onTapGesture { entry.onDismiss() }
                entry.content
                    // An opaque card (the sheets were see-through, the page behind read through
                    // their text). A click on the card's own ground stays on the card; only the veil closes.
                    .background(LiaModalCard.fill.contentShape(Rectangle()))
                    .clipShape(RoundedRectangle(cornerRadius: LiaModalCard.radius, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: LiaModalCard.radius, style: .continuous).stroke(LiaModalCard.edge, lineWidth: 1))
                    .shadow(color: Color.black.opacity(0.16), radius: 30, y: 14)
                    .padding(24)
            } else {
                entry.content
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(TipOccluder(layer: layer))
        .environment(\.liaDismiss, dismiss)
        .environment(\.liaTipLayer, layer)
    }
}

/// The card every `.card` popup sits on: the workspace's surface (white / dark), rounded, a hairline.
enum LiaModalCard {
    static let fill = WS.surface
    static let edge = Color.dyn(dark: (0xFFFFFF, 0.10), light: (0x0E1014, 0.10))
    static let radius: CGFloat = 20
}

/// The veil under every popup: a plain dim, no blur (the blurred screen under the rename popup looked
/// odd; the site's 7 px blur is not carried over). It takes every hover and click.
struct LiaModalScrim: View {
    var body: some View {
        Rectangle().fill(Color.black.opacity(0.28))
            .contentShape(Rectangle())
    }
}

/// .setx-modal__x: 34 px, radius 9, --surface-2 on a 1 px --line-2, the glyph --text-2; hover --surface-3 and
/// Text. A plain grey control like every other icon button (not the brand blue).
struct LiaModalCloseButton: View {
    var size: CGFloat = 30
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            LiaIcon("x", size: 15)
                .foregroundStyle(hover ? AppConfig.ink : AppConfig.text2)
                .frame(width: size, height: size)
                .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(hover ? AppConfig.surface3 : AppConfig.surface2))
                .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).stroke(AppConfig.line2, lineWidth: 1))
                .contentShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
        }
        .buttonStyle(.liaPlain)
        .onHover { hover = $0 }
        .liaPointer()
        .animation(.easeOut(duration: 0.12), value: hover)
        .accessibilityLabel("Close")
    }
}

/// Esc closes the top popup. An open dropdown keeps its own Esc; only this window's keys count.
private struct LiaModalEscape: NSViewRepresentable {
    let active: Bool

    final class Coordinator {
        var monitor: Any?
        weak var view: NSView?
        deinit { if let m = monitor { NSEvent.removeMonitor(m) } }
    }

    final class PassView: NSView {
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSView {
        let v = PassView()
        context.coordinator.view = v
        return v
    }

    func updateNSView(_ v: NSView, context: Context) {
        let c = context.coordinator
        c.view = v
        if active && c.monitor == nil {
            c.monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak c] e in
                guard let c, e.keyCode == 53, let w = c.view?.window, e.window === w else { return e }
                let handled: Bool = MainActor.assumeIsolated { () -> Bool in
                    if DropdownHost.shared.isOpen { return false }
                    guard LiaModalCenter.shared.isOpen else { return false }
                    LiaModalCenter.shared.dismissTop()
                    return true
                }
                return handled ? nil : e
            }
        } else if !active, let m = c.monitor {
            NSEvent.removeMonitor(m)
            c.monitor = nil
        }
    }

    static func dismantleNSView(_ v: NSView, coordinator: Coordinator) {
        if let m = coordinator.monitor { NSEvent.removeMonitor(m); coordinator.monitor = nil }
    }
}

// MARK: - presenting

private struct LiaModalPresenter<M: View>: ViewModifier {
    @Binding var isPresented: Bool
    let style: LiaModalStyle
    let modal: () -> M
    @State private var id = UUID()

    func body(content: Content) -> some View {
        content
            .onAppear { sync(isPresented) }
            .onChange(of: isPresented) { _, v in sync(v) }
            .onDisappear { LiaModalCenter.shared.remove(id) }
    }

    private func sync(_ on: Bool) {
        let center = LiaModalCenter.shared
        if on {
            let b: Binding<Bool> = $isPresented
            center.present(id, style: style, content: AnyView(modal()), onDismiss: { b.wrappedValue = false })
        } else {
            center.remove(id)
        }
    }
}

private struct LiaModalItemPresenter<Item: Identifiable, M: View>: ViewModifier {
    @Binding var item: Item?
    let style: LiaModalStyle
    let modal: (Item) -> M
    @State private var id = UUID()

    func body(content: Content) -> some View {
        content
            .onAppear { sync() }
            .onChange(of: item?.id) { _, _ in sync() }
            .onDisappear { LiaModalCenter.shared.remove(id) }
    }

    private func sync() {
        let center = LiaModalCenter.shared
        if let it = item {
            let b: Binding<Item?> = $item
            center.present(id, style: style, content: AnyView(modal(it)), onDismiss: { b.wrappedValue = nil })
        } else {
            center.remove(id)
        }
    }
}

extension View {
    /// The site's modal in place of `.sheet(isPresented:)`: over the whole window, the veil takes hover and
    /// clicks, a click on it or Esc sets `isPresented` to false.
    func liaModal<M: View>(isPresented: Binding<Bool>, style: LiaModalStyle = .card,
                           @ViewBuilder content: @escaping () -> M) -> some View {
        modifier(LiaModalPresenter(isPresented: isPresented, style: style, modal: content))
    }

    /// The site's modal in place of `.sheet(item:)`.
    func liaModal<Item: Identifiable, M: View>(item: Binding<Item?>, style: LiaModalStyle = .card,
                                               @ViewBuilder content: @escaping (Item) -> M) -> some View {
        modifier(LiaModalItemPresenter(item: item, style: style, modal: content))
    }
}
