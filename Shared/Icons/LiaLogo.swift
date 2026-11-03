import SwiftUI

/// The sidebar logo (liaison-logo-*-bluesmile.svg): letters in ink, the "a" and the smile in accent.
struct LiaLogo: View {
    var height: CGFloat = 26

    var body: some View {
        let vbX: CGFloat = -2, vbY: CGFloat = 4, vbW: CGFloat = 315.32, vbH: CGFloat = 111.5
        let width = height * vbW / vbH
        ZStack {
            ForEach(Array(LiaIconData.logoLetters.enumerated()), id: \.offset) { _, part in
                SVGShape(commands: SVGPath.parse(part.d), viewBox: vbW, originX: vbX, originY: vbY, viewBoxHeight: vbH)
                    .fill(part.blue ? AppConfig.accent : AppConfig.ink)
            }
            SVGShape(commands: SVGPath.parse(LiaIconData.logoSmile), viewBox: vbW, originX: vbX, originY: vbY, viewBoxHeight: vbH)
                .stroke(AppConfig.accent, style: StrokeStyle(lineWidth: 11 * height / vbH, lineCap: .round, lineJoin: .round))
            ForEach(Array(LiaIconData.logoDots.enumerated()), id: \.offset) { _, d in
                Circle().fill(AppConfig.accent)
                    .frame(width: CGFloat(d.2 * 2) * height / vbH, height: CGFloat(d.2 * 2) * height / vbH)
                    .position(x: (CGFloat(d.0) - vbX) * height / vbH, y: (CGFloat(d.1) - vbY) * height / vbH)
            }
        }
        .frame(width: width, height: height)
        .accessibilityElement()
        .accessibilityLabel("Liaison")
    }
}

/// The mobile burger with its last bar cut short.
struct LiaBurger: View {
    var size: CGFloat = 20

    var body: some View {
        let parts = LiaIconData.icons["burger"] ?? []
        ZStack(alignment: .topLeading) {
            ForEach(Array(parts.enumerated()), id: \.offset) { i, part in
                SVGShape(commands: SVGPath.parse(part.d), viewBox: 20)
                    .fill()
                    .mask(alignment: .leading) {
                        Rectangle().frame(width: i == parts.count - 1 ? size * 0.5 : size)
                    }
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}
