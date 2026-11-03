import SwiftUI

/// A11Y-04: the conversation's text size from Settings (`Prefs.chatTextSize`: 0 small, 1 default, 2 large,
/// 3 extra large) as a factor for the bubble and composer fonts.
enum ChatTextScale {
    static func factor(_ level: Int) -> CGFloat {
        switch level {
        case 0: return 0.9
        case 2: return 1.15
        case 3: return 1.3
        default: return 1
        }
    }

    static func ui(_ size: CGFloat, _ weight: Font.Weight = .regular, level: Int) -> Font {
        LiaFont.ui((size * factor(level)).rounded(), weight)
    }
}

extension ChatTextScale {
    /// The factor for the level saved in Settings now (outside a view, e.g. the Settings preview).
    static var current: CGFloat {
        let d = UserDefaults.standard
        return factor(d.object(forKey: Prefs.chatTextSize) == nil ? 1 : d.integer(forKey: Prefs.chatTextSize))
    }
}

private struct LiaTextScaleKey: EnvironmentKey { static let defaultValue: CGFloat = 1 }

extension EnvironmentValues {
    /// A11Y-04: the factor agent replies (MarkdownView, AssistantMessageView, LiveTurnView, ChatArtifactCard) apply
    /// to their font sizes. 1 everywhere except inside the conversation sheet, which sets it from Settings.
    var liaTextScale: CGFloat {
        get { self[LiaTextScaleKey.self] }
        set { self[LiaTextScaleKey.self] = newValue }
    }
}
