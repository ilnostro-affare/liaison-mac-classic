import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
#endif

/// 0.2.11: where the morning tour's spotlight and card go. Pure, so the Linux
/// tests check it. All rects are in the overlay's own space, top-left origin.
enum TourGeometry {
    /// The anchor grown by `pad` and clipped to the window; nil (no ring, the card in the middle) when nothing of it
    /// is on screen, when it is a sliver, or when it would cover most of the window (a ring around the whole page is
    /// no pointer: in a small window the tab strip or the feed is nearly everything).
    static func hole(_ anchor: CGRect, pad: CGFloat, in size: CGSize) -> CGRect? {
        guard size.width > 0, size.height > 0, anchor.width.isFinite, anchor.height.isFinite else { return nil }
        let grown = anchor.insetBy(dx: -pad, dy: -pad)
        let clipped = grown.intersection(CGRect(origin: .zero, size: size))
        guard !clipped.isNull, clipped.width >= 12, clipped.height >= 12 else { return nil }
        // Mostly outside the window (an anchor scrolled or slid away): pointing at its edge would mislead.
        if clipped.width * clipped.height < 0.5 * grown.width * grown.height { return nil }
        if clipped.width * clipped.height > 0.55 * size.width * size.height { return nil }
        return clipped
    }

    /// The card's centre: below the hole if it fits, else above, else right, else left, else on the side with the most
    /// room; always inside the window (`margin` from every edge when the window is big enough for the card).
    static func cardCenter(card: CGSize, hole: CGRect?, in size: CGSize, margin m: CGFloat, gap: CGFloat) -> CGPoint {
        let w = card.width, h = card.height
        func clampX(_ x: CGFloat) -> CGFloat {
            let lo = m + w / 2, hi = size.width - m - w / 2
            return hi < lo ? size.width / 2 : min(max(x, lo), hi)
        }
        func clampY(_ y: CGFloat) -> CGFloat {
            let lo = m + h / 2, hi = size.height - m - h / 2
            return hi < lo ? size.height / 2 : min(max(y, lo), hi)
        }
        guard let r = hole else { return CGPoint(x: size.width / 2, y: size.height / 2) }
        if r.maxY + gap + h + m <= size.height { return CGPoint(x: clampX(r.midX), y: r.maxY + gap + h / 2) }
        if r.minY - gap - h - m >= 0 { return CGPoint(x: clampX(r.midX), y: r.minY - gap - h / 2) }
        if r.maxX + gap + w + m <= size.width { return CGPoint(x: r.maxX + gap + w / 2, y: clampY(r.midY)) }
        if r.minX - gap - w - m >= 0 { return CGPoint(x: r.minX - gap - w / 2, y: clampY(r.midY)) }
        // Nowhere free: the side with the most room, clamped (it may overlap the hole, never leaves the window).
        let below = size.height - r.maxY, above = r.minY
        let y = below >= above ? r.maxY + gap + h / 2 : r.minY - gap - h / 2
        return CGPoint(x: clampX(r.midX), y: clampY(y))
    }
}
