import Foundation

/// Several pictures in one message are a fan of cards (like stories), not a column of tiles. The
/// geometry only: each card's angle and horizontal shift around a common bottom point, and the box the fan needs so
/// it never changes size when it opens on hover. Card 0 is drawn first (bottom); the last one is on top.
enum PhotoFan {
    /// At most this many cards; the rest is a "+N" badge.
    static let maxCards = 4

    /// The cards' angles in degrees, left to right (fewer cards, fewer angles).
    static func angles(count: Int) -> [Double] {
        switch min(max(count, 0), maxCards) {
        case 0: return []
        case 1: return [0]
        case 2: return [-4, 4]
        case 3: return [-6, 0, 6]
        default: return [-8, -3, 3, 8]
        }
    }

    /// How far the fan spreads when the pointer is on it.
    static let openFactor = 1.6
    /// Points of horizontal shift per degree.
    static let shiftPerDegree = 2.0

    struct Card: Equatable {
        /// Degrees, clockwise.
        let angle: Double
        /// From the fan's centre, in points.
        let x: Double
    }

    static func cards(count: Int, open: Bool) -> [Card] {
        let k = open ? openFactor : 1
        return angles(count: count).map { a in Card(angle: a * k, x: a * k * shiftPerDegree) }
    }

    /// "+N" for the pictures past `maxCards`; nil when all fit.
    static func more(count: Int) -> Int? { count > maxCards ? count - maxCards : nil }

    /// The box of the open fan (the widest it gets): `width`, `height`, and `lift`, how far the cards' bottom sits
    /// over the box's bottom (a rotated card's lower corner dips under its pivot).
    static func extent(count: Int, cardWidth w: Double, cardHeight h: Double) -> (width: Double, height: Double, lift: Double) {
        var maxX = 0.0, maxUp = 0.0, maxDown = 0.0
        for c in cards(count: count, open: true) {
            let r = c.angle * .pi / 180
            // Corners relative to the pivot (bottom centre), y up; rotated clockwise by r.
            for (cx, cy) in [(-w / 2, 0.0), (w / 2, 0.0), (-w / 2, h), (w / 2, h)] {
                let x = c.x + cx * cos(r) + cy * sin(r)
                let y = -cx * sin(r) + cy * cos(r)
                maxX = max(maxX, abs(x))
                maxUp = max(maxUp, y)
                maxDown = max(maxDown, -y)
            }
        }
        return ((2 * maxX).rounded(.up), (maxUp + maxDown).rounded(.up), maxDown.rounded(.up))
    }
}
