import Foundation

/// When a downloaded update installs by itself and when the person is only told.
/// The rule: a relaunch never lands in the middle of work. It happens by itself only at a moment the person is not
/// working in the app (just launched, just woke the Mac, came back after a long while, or away from the Mac), and only
/// when nothing would be lost (no agent run, no change waiting for a Yes, no unsent text, no Dev / Crea run).
/// Otherwise the update waits and says so: a banner in the window, an inbox row, a Home card and, in the background,
/// a system notification. It also installs when the app quits (Sparkle's install on quit).
public enum UpdatePolicy {
    /// What is going on in the app right now (AppBusy fills it).
    public struct Busy: Equatable {
        public var agentRuns: Int
        public var gatesPending: Int
        public var unsentDrafts: Int
        /// Dev / Crea runs and anything else that registered itself as work in progress.
        public var otherRuns: Int

        public init(agentRuns: Int = 0, gatesPending: Int = 0, unsentDrafts: Int = 0, otherRuns: Int = 0) {
            self.agentRuns = agentRuns
            self.gatesPending = gatesPending
            self.unsentDrafts = unsentDrafts
            self.otherRuns = otherRuns
        }

        public static let none = Busy()

        public var any: Bool { agentRuns > 0 || gatesPending > 0 || unsentDrafts > 0 || otherRuns > 0 }

        /// Short phrases for the Restart confirmation ("2 agents are working", "1 change waits for your Yes").
        public var reasons: [String] {
            var out: [String] = []
            if agentRuns > 0 { out.append(agentRuns == 1 ? "an agent is working" : "\(agentRuns) agents are working") }
            if otherRuns > 0 { out.append(otherRuns == 1 ? "a run is in progress" : "\(otherRuns) runs are in progress") }
            if gatesPending > 0 { out.append(gatesPending == 1 ? "a change waits for your Yes" : "\(gatesPending) changes wait for your Yes") }
            if unsentDrafts > 0 { out.append(unsentDrafts == 1 ? "a message is not sent yet" : "\(unsentDrafts) messages are not sent yet") }
            return out
        }
    }

    /// Why the policy is asked now.
    public enum Moment: Equatable {
        /// The app just started (the update was downloaded in an earlier run, or found right at launch).
        case launch
        /// The Mac woke from sleep.
        case wake
        /// The app came to the front after being in the background for a long while.
        case reactivated
        /// The update finished downloading.
        case ready
        /// The periodic re-check while an update waits.
        case timer
    }

    public struct Context: Equatable {
        public var moment: Moment
        public var busy: Busy
        /// Seconds since the app started.
        public var sinceLaunch: TimeInterval
        /// Seconds since the Mac last woke (nil: not since launch).
        public var sinceWake: TimeInterval?
        /// Seconds since the app came back to the front after a long absence (nil: it did not).
        public var sinceReactivation: TimeInterval?
        /// Seconds since the person's last keyboard / mouse input anywhere on the Mac.
        public var systemIdle: TimeInterval
        /// The app is in front.
        public var appActive: Bool

        public init(moment: Moment, busy: Busy, sinceLaunch: TimeInterval, sinceWake: TimeInterval? = nil,
                    sinceReactivation: TimeInterval? = nil, systemIdle: TimeInterval, appActive: Bool) {
            self.moment = moment
            self.busy = busy
            self.sinceLaunch = sinceLaunch
            self.sinceWake = sinceWake
            self.sinceReactivation = sinceReactivation
            self.systemIdle = systemIdle
            self.appActive = appActive
        }
    }

    public enum Decision: Equatable {
        /// Install and relaunch now, without asking.
        case installNow
        /// Keep it ready and tell the person (banner, inbox, Home; a system notification when `system`).
        case notify(system: Bool)
    }

    /// Right after launch: the windows are only just back, nothing has been typed yet.
    public static let launchGrace: TimeInterval = 120
    /// Right after a wake: the person is opening the lid, not yet back at work.
    public static let wakeGrace: TimeInterval = 180
    /// Right after coming back to the app after `reactivationGap`.
    public static let reactivationGrace: TimeInterval = 60
    /// How long in the background counts as "the person left the app".
    public static let reactivationGap: TimeInterval = 30 * 60
    /// No input on the Mac this long: the person is away (15 min, so a long read or a video is not cut off).
    public static let awayIdle: TimeInterval = 15 * 60
    /// Within a grace window the person must not have been typing / clicking in the last few seconds.
    public static let graceQuiet: TimeInterval = 4
    /// How often to look again while an update waits (and Sparkle's own check interval).
    public static let recheckInterval: TimeInterval = 15 * 60
    public static let checkInterval: TimeInterval = 3600
    /// "Later" hides the banner this long (the Home card and the inbox row stay).
    public static let laterSnooze: TimeInterval = 4 * 3600
    /// Coming to the front checks for an update at most this often.
    public static let activeCheckGap: TimeInterval = 10 * 60

    public static func decide(_ c: Context) -> Decision {
        let notify = Decision.notify(system: !c.appActive)
        if c.busy.any { return notify }
        // The person is away from the Mac: a relaunch costs them nothing.
        if c.systemIdle >= awayIdle { return .installNow }
        let quiet = c.systemIdle >= graceQuiet
        if c.sinceLaunch <= launchGrace, quiet || c.moment == .launch { return .installNow }
        if let w = c.sinceWake, w <= wakeGrace, quiet || c.moment == .wake { return .installNow }
        if let r = c.sinceReactivation, r <= reactivationGrace, quiet || c.moment == .reactivated { return .installNow }
        return notify
    }

    /// The person pressed Restart: ask first when something would be cut off.
    public static func needsConfirm(_ busy: Busy) -> Bool { busy.any }

    /// The confirmation's text, e.g. "An agent is working and a message is not sent yet. Restart anyway?".
    public static func confirmText(_ busy: Busy) -> String {
        let r = busy.reasons
        guard !r.isEmpty else { return "Restart Liaison now?" }
        let joined: String
        if r.count == 1 { joined = r[0] }
        else { joined = r.dropLast().joined(separator: ", ") + " and " + r[r.count - 1] }
        return joined.prefix(1).uppercased() + joined.dropFirst() + ". Restart anyway?"
    }

    /// The window's banner shows for a ready version unless the person chose Later for that same version recently.
    public static func bannerVisible(ready: String?, snoozedVersion: String?, snoozedUntil: Date?, now: Date) -> Bool {
        guard let ready, !ready.isEmpty else { return false }
        guard snoozedVersion == ready, let until = snoozedUntil else { return true }
        return now >= until
    }

    /// The app came to the front: is that "coming back" (a reactivation grace) rather than a switch between apps?
    public static func isReturn(backgroundFor seconds: TimeInterval) -> Bool { seconds >= reactivationGap }

    /// Whether a system notification for this version has already been posted (once per version).
    public static func shouldPostSystem(version: String, alreadyPosted: String?, appActive: Bool) -> Bool {
        !appActive && alreadyPosted != version
    }
}
