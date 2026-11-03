import AppKit

/// /02: tiny system sounds for what happens in a conversation while the person is looking at the app.
/// Off by default (Settings: `Prefs.sounds`); never while the app is in the background (notifications cover that,
/// /03); silent when "Play user interface sound effects" is off in System Settings.
@MainActor
enum ChatSounds {
    enum Cue: String {
        /// An agent's message arrived.
        case message = "Pop"
        /// An agent needs a Yes.
        case approval = "Glass"
        /// A task finished (a browser task ended, a change was applied).
        case done = "Hero"
    }

    private static var last: [Cue: Date] = [:]

    /// The system's "Play user interface sound effects" (a missing key reads as on, the system default).
    static var systemAllows: Bool {
        guard let d = UserDefaults(suiteName: "com.apple.systemsound"),
              d.object(forKey: "com.apple.sound.uiaudio.enabled") != nil else { return true }
        return d.bool(forKey: "com.apple.sound.uiaudio.enabled")
    }

    static var enabled: Bool { Prefs.flag(Prefs.sounds, default: false) && NSApp.isActive && systemAllows }

    /// Plays `cue` unless the same cue played in the last 0.6 s (a team run lands several messages at once).
    static func play(_ cue: Cue) {
        guard enabled else { return }
        let now = Date()
        if let t = last[cue], now.timeIntervalSince(t) < 0.6 { return }
        last[cue] = now
        guard let s = NSSound(named: NSSound.Name(cue.rawValue)) else { return }
        s.volume = 0.35
        s.play()
    }
}
