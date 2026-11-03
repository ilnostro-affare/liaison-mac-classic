import SwiftUI
import AppKit

/// Liaison's own drawn icons (LiaIconData, extracted from the web). Coloured by foregroundStyle,
/// never tinted blue by a List or a NavigationLink: they render as plain shapes.
struct LiaIcon: View {
    let name: String
    var size: CGFloat = 20

    init(_ name: String, size: CGFloat = 20) {
        self.name = name
        self.size = size
    }

    var body: some View {
        let parts = LiaIconData.icons[name] ?? []
        ZStack {
            ForEach(Array(parts.enumerated()), id: \.offset) { _, part in
                if part.fill {
                    SVGShape(commands: SVGPath.parse(part.d), viewBox: 20).fill(style: FillStyle(eoFill: false))
                } else {
                    SVGShape(commands: SVGPath.parse(part.d), viewBox: 20)
                        .stroke(style: StrokeStyle(lineWidth: max(0.8, part.stroke) * size / 20, lineCap: .round, lineJoin: .round))
                }
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

struct SVGShape: Shape {
    let commands: [SVGCommand]
    var viewBox: CGFloat = 20
    var originX: CGFloat = 0
    var originY: CGFloat = 0
    var viewBoxHeight: CGFloat? = nil

    func path(in rect: CGRect) -> Path {
        let sx = rect.width / viewBox
        let sy = rect.height / (viewBoxHeight ?? viewBox)
        func p(_ x: Double, _ y: Double) -> CGPoint {
            CGPoint(x: rect.minX + (CGFloat(x) - originX) * sx, y: rect.minY + (CGFloat(y) - originY) * sy)
        }
        var path = Path()
        for c in commands {
            switch c {
            case let .move(x, y): path.move(to: p(x, y))
            case let .line(x, y): path.addLine(to: p(x, y))
            case let .cubic(a, b, c2, d, e, f): path.addCurve(to: p(e, f), control1: p(a, b), control2: p(c2, d))
            case let .quad(a, b, c2, d): path.addQuadCurve(to: p(c2, d), control: p(a, b))
            case .close: path.closeSubpath()
            }
        }
        return path
    }
}

/// The Liaison "a" mark. While Lia works the smile draws itself over and over (web: .lia-amark .sm,
/// stroke-dasharray 160, 2.2s linear); finished, it stands still.
struct AMark: View {
    var size: CGFloat = 16
    var animating = true
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let letter = SVGPath.parse(LiaIconData.amarkLetter)
        let smile = SVGPath.parse(LiaIconData.amarkSmile)
        TimelineView(.animation(paused: !animating || reduceMotion)) { ctx in
            // shell.build2.css liaDraw, 2.2 s: the smile draws in (0-45%), holds (45-70%), then leaves from its start.
            let t = ctx.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 2.2) / 2.2
            let still = !animating || reduceMotion
            let from = still || t < 0.7 ? 0 : (t - 0.7) / 0.3
            let to = still ? 1 : min(1, t / 0.45)
            ZStack {
                SVGShape(commands: letter, viewBox: 118, originX: 40, viewBoxHeight: 120).fill()
                SVGShape(commands: smile, viewBox: 118, originX: 40, viewBoxHeight: 120)
                    .trim(from: from, to: to)
                    .stroke(style: StrokeStyle(lineWidth: 11 * size / 118, lineCap: .round, lineJoin: .round))
                ForEach(Array(LiaIconData.amarkDots.enumerated()), id: \.offset) { _, d in
                    Circle()
                        .frame(width: CGFloat(d.2 * 2) * size / 118, height: CGFloat(d.2 * 2) * size / 118)
                        .position(x: CGFloat(d.0 - 40) * size / 118, y: CGFloat(d.1) * size / 120 * (120.0 / 118.0))
                }
            }
            .frame(width: size, height: size * 120 / 118)
        }
        .accessibilityHidden(true)
    }
}

enum ThemeSetting: String, CaseIterable, Identifiable {
    case dark, light, auto
    var id: String { rawValue }
    var label: String { rawValue.capitalized }
    var scheme: ColorScheme? {
        switch self {
        case .dark: return .dark
        case .light: return .light
        case .auto: return nil
        }
    }
}

extension LiaIcon {
    /// Menus draw images, not shapes: the icon is rendered once into an image. With no colour it is a
    /// template (it takes the menu's tint); with a colour it is baked in, which is how Delete gets the muted red.
    @MainActor private static var cache: [String: NSImage] = [:]

    @MainActor static func image(_ name: String, size: CGFloat = 16, color: Color? = nil) -> Image {
        let key = "\(name)@\(size)@\(color == nil ? "t" : "c")"
        if let img = cache[key] { return Image(nsImage: img).renderingMode(color == nil ? .template : .original) }
        let renderer = ImageRenderer(content: LiaIcon(name, size: size).foregroundStyle(color ?? Color.black))
        renderer.scale = 2
        guard let ns = renderer.nsImage else { return Image(systemName: "circle") }
        ns.isTemplate = color == nil
        cache[key] = ns
        return Image(nsImage: ns).renderingMode(color == nil ? .template : .original)
    }

    @MainActor static var trash: Image { image("trash", color: AppConfig.bad) }
}

/// "17 minutes ago", "yesterday", like the Claude app lists.
func relativeTime(_ ms: Double?) -> String? {
    guard let ms, ms > 0 else { return nil }
    let f = RelativeDateTimeFormatter()
    f.unitsStyle = .full
    f.dateTimeStyle = .named
    return f.localizedString(for: Date(timeIntervalSince1970: ms > 1e11 ? ms / 1000 : ms), relativeTo: Date())
}
