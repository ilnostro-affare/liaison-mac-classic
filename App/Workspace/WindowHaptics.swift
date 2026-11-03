import AppKit

/// A light tap on a Force Touch trackpad at snap moments (HIG: only where something clicks into place).
/// No-ops on a mouse or a trackpad without the Taptic Engine; the system honours its own haptics setting.
enum WSHaptics {
    /// Something lined up: the split divider at 50 %, a dragged tab in its new slot.
    @MainActor static func alignment() {
        NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
    }

    /// A level changed: another workspace came in by swipe.
    @MainActor static func level() {
        NSHapticFeedbackManager.defaultPerformer.perform(.levelChange, performanceTime: .now)
    }
}
