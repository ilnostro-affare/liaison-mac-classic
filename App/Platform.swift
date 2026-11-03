import SwiftUI
import AppKit
import CoreText

/// What iOS did with UIPasteboard / UIImage / SFSafariViewController, done the Mac way, in one place.
enum Clipboard {
    static func copy(_ s: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(s, forType: .string)
    }

    static func copy(_ url: URL) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.writeObjects([url as NSURL])
        NSPasteboard.general.setString(url.absoluteString, forType: .string)
    }
}

/// Links outside the app. The right-hand browser is the person's own browsing; a link in Lia's text
/// opens there (`BrowserModel.open`), and anything that needs the site's own session (billing,
/// email change) goes to the system browser, where the person is signed in to liaisone.com.
enum ExternalLink {
    static func openInSystemBrowser(_ url: URL) { NSWorkspace.shared.open(url) }
}

typealias PlatformImage = NSImage

extension Image {
    init(platformImage: PlatformImage) { self.init(nsImage: platformImage) }
}

extension NSImage {
    static func fromData(_ d: Data) -> NSImage? { NSImage(data: d) }
}

/// The two typefaces the site ships: Nunito for the interface, Newsreader for Lia's answers.
/// Bundled in Resources/Fonts (OFL) and registered at launch; if a face is missing the system font
/// stands in, so a missing file degrades the look, never the app.
enum LiaFont {
    static func registerBundled() {
        guard let dir = Bundle.main.url(forResource: "Fonts", withExtension: nil),
              let files = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else { return }
        for f in files where f.pathExtension.lowercased() == "ttf" {
            CTFontManagerRegisterFontsForURL(f as CFURL, .process, nil)
        }
    }

    private static let hasNunito = NSFont(name: "Nunito", size: 13) != nil

    static func ui(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        hasNunito ? .custom("Nunito", size: size).weight(weight) : .system(size: size, weight: weight)
    }

    /// Newsreader at an explicit weight and optical size, the way the browser draws it (font-optical-sizing:
    /// auto, so opsz follows the px size). Built from the variable font's own axes rather than
    /// `.custom("Newsreader")`: that name is the typographic family, not a face CoreText resolves, so the
    /// regular run fell back to the system sans while a bold run (resolved by traits) found the serif.
    static func answer(_ size: CGFloat = 16, _ weight: Font.Weight = .regular, tabular: Bool = false) -> Font {
        if let f = answerFace(size, weight, tabular: tabular) { return Font(f) }
        return .system(size: size, weight: weight, design: .serif)
    }

    /// The same face slanted, for *emphasis*: the bundled Newsreader has no italic, and the site's browser
    /// synthesizes an oblique for `em` the same way.
    static func answerOblique(_ size: CGFloat = 16, _ weight: Font.Weight = .regular, tabular: Bool = false) -> Font {
        if let f = answerFace(size, weight, oblique: true, tabular: tabular) { return Font(f) }
        return .system(size: size, weight: weight, design: .serif).italic()
    }

    private static var faceCache: [String: CTFont] = [:]

    private static func numeric(_ w: Font.Weight) -> Double {
        switch w {
        case .ultraLight, .thin: return 200
        case .light: return 300
        case .medium: return 500
        case .semibold: return 600
        case .bold: return 700
        case .heavy, .black: return 800
        default: return 400
        }
    }

    static func answerFace(_ size: CGFloat, _ weight: Font.Weight, oblique: Bool = false, tabular: Bool = false) -> CTFont? {
        let wght: Double = numeric(weight)
        let key: String = "\(size)|\(wght)|\(oblique)|\(tabular)"
        if let hit = faceCache[key] { return hit }
        // The site loads Newsreader:opsz,wght@6..16 from Google Fonts, so above 16 px the optical size stays at 16.
        let opsz: Double = min(max(Double(size), 6), 16)
        // ai.js .ai__atext: 'Newsreader', Georgia, serif. Newsreader has no Cyrillic, so the browser draws those letters
        // in Georgia (macOS ships it with Cyrillic). The cascade list does the same for SwiftUI Text; the answer's own
        // text view assigns Georgia explicitly per character (AnswerFonts.fallback), which does not depend on it.
        let cascade: [CTFontDescriptor] = [CTFontDescriptorCreateWithNameAndSize(georgiaName(weight, italic: oblique) as CFString, size)]
        for name in ["Newsreader16pt-Regular", "NewsreaderRoman-Regular"] {
            if let f = variableFace(name: name, family: "Newsreader", size: size, axes: [0x7767_6874: wght, 0x6F70_737A: opsz],
                                    oblique: oblique, tabular: tabular, cascade: cascade) {
                faceCache[key] = f
                return f
            }
        }
        return nil
    }

    /// Georgia's faces as the browser picks them for a weight: 400 and 500 take the regular, 600 and up the bold.
    static func georgiaName(_ weight: Font.Weight, italic: Bool) -> String {
        let bold = numeric(weight) >= 600
        switch (bold, italic) {
        case (false, false): return "Georgia"
        case (true, false): return "Georgia-Bold"
        case (false, true): return "Georgia-Italic"
        case (true, true): return "Georgia-BoldItalic"
        }
    }

    /// Inter, which the site's answer column uses for its sans (`.ai__atext{--font-sans:'Inter'}`): the entity chips,
    /// inline code, the source chips' letter tiles. Google Fonts serves it at opsz 14 when no optical size is asked.
    static func interFace(_ size: CGFloat, _ weight: Font.Weight) -> CTFont? {
        let wght: Double = numeric(weight)
        let key: String = "inter|\(size)|\(wght)"
        if let hit = faceCache[key] { return hit }
        guard let f = variableFace(name: "Inter-Regular", family: "Inter", size: size, axes: [0x7767_6874: wght, 0x6F70_737A: 14]) else { return nil }
        faceCache[key] = f
        return f
    }

    /// Nunito, the interface face, at an explicit weight (the variable file's default instance is ExtraLight).
    static func nunitoFace(_ size: CGFloat, _ weight: Font.Weight) -> CTFont? {
        let wght: Double = numeric(weight)
        let key: String = "nunito|\(size)|\(wght)"
        if let hit = faceCache[key] { return hit }
        for name in ["Nunito-ExtraLight", "Nunito-Regular"] {
            if let f = variableFace(name: name, family: "Nunito", size: size, axes: [0x7767_6874: wght]) {
                faceCache[key] = f
                return f
            }
        }
        return nil
    }

    private static func variableFace(name: String, family: String, size: CGFloat, axes: [UInt32: Double], oblique: Bool = false,
                                     tabular: Bool = false, cascade: [CTFontDescriptor] = []) -> CTFont? {
        var variation: [NSNumber: NSNumber] = [:]
        for (tag, v) in axes { variation[NSNumber(value: tag)] = NSNumber(value: v) }
        var attrs: [CFString: Any] = [
            kCTFontNameAttribute: name as CFString,
            kCTFontVariationAttribute: variation as CFDictionary,
        ]
        // .md-t td{font-variant-numeric:tabular-nums}
        if tabular {
            let tnum: [CFString: Any] = [kCTFontOpenTypeFeatureTag: "tnum" as CFString, kCTFontOpenTypeFeatureValue: NSNumber(value: 1)]
            attrs[kCTFontFeatureSettingsAttribute] = [tnum as CFDictionary] as CFArray
        }
        if !cascade.isEmpty { attrs[kCTFontCascadeListAttribute] = cascade as CFArray }
        let desc: CTFontDescriptor = CTFontDescriptorCreateWithAttributes(attrs as CFDictionary)
        var m: CGAffineTransform = oblique ? CGAffineTransform(a: 1, b: 0, c: 0.2, d: 1, tx: 0, ty: 0) : .identity
        let f: CTFont = CTFontCreateWithFontDescriptor(desc, size, &m)
        let fam: String = CTFontCopyFamilyName(f) as String
        return fam.hasPrefix(family) ? f : nil
    }

    /// Inter as a SwiftUI font (the answer column's sans); the system sans if the file is missing.
    static func inter(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        if let f = interFace(size, weight) { return Font(f) }
        return .system(size: size, weight: weight)
    }

    /// No typewriter faces in the UI: the app's sans with digits of one width. `code` is for code only.
    static func mono(_ size: CGFloat) -> Font { ui(size).monospacedDigit() }
    static func code(_ size: CGFloat) -> Font { .system(size: size, design: .monospaced) }
}
