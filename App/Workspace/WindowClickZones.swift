import SwiftUI
import AppKit

// Mouse input SwiftUI does not hand over on macOS 14: the middle button (middle-click closes a tab),
// The right button where a popover opens instead of a menu, and a pinch on the page.

/// A marker behind a view: a middle or right click inside it runs `action` (and is used up). One local monitor per
/// app serves every zone; a zone never takes a click itself, so the SwiftUI view above it keeps its own clicks.
struct WSMouseZone: NSViewRepresentable {
    enum Kind { case middle, right }
    let kind: Kind
    let action: () -> Void

    func makeNSView(context: Context) -> ZoneView {
        let v = ZoneView()
        v.kind = kind
        v.action = action
        return v
    }

    func updateNSView(_ v: ZoneView, context: Context) {
        v.kind = kind
        v.action = action
    }

    final class ZoneView: NSView {
        static let all = NSHashTable<ZoneView>.weakObjects()
        private static var monitor: Any?
        var kind: Kind = .middle
        var action: (() -> Void)?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if window != nil {
                Self.all.add(self)
                Self.install()
            } else {
                Self.all.remove(self)
            }
        }

        /// Only a marker: never takes a click.
        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        private static func install() {
            guard monitor == nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: [.otherMouseDown, .rightMouseDown]) { e in
                let used = MainActor.assumeIsolated { () -> Bool in
                    let kind: Kind
                    if e.type == .rightMouseDown { kind = .right } else if e.buttonNumber == 2 { kind = .middle } else { return false }
                    guard let z = ZoneView.zone(for: e, kind: kind) else { return false }
                    z.action?()
                    return true
                }
                return used ? nil : e
            }
        }

        /// The zone under the pointer in the event's window (only its visible part: a tab scrolled out of the row
        /// keeps its bounds but is not under the pointer).
        private static func zone(for e: NSEvent, kind: Kind) -> ZoneView? {
            guard let w = e.window else { return nil }
            // Zones can nest (a tab inside the tab row): the innermost one under the pointer wins.
            return all.allObjects.filter { z in
                z.kind == kind && z.window === w && !z.isHiddenOrHasHiddenAncestor
                    && z.visibleRect.contains(z.convert(e.locationInWindow, from: nil))
            }.min { $0.visibleRect.width * $0.visibleRect.height < $1.visibleRect.width * $1.visibleRect.height }
        }
    }
}

// (pinch-in for the tab overview) removed,: every pinch is the page's own zoom.
