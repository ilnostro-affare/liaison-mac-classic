import AppKit
import CoreGraphics

/// What would be cut off if the app relaunched now, for the update policy (UpdatePolicy) and the Restart
/// confirmation. Agent runs and changes waiting for a Yes come from the workspace (WorkspaceModel.working /
/// approvals, mirrored app-wide in MenuBarStatus); unsent composer text and runs outside the team chat (Dev cloud,
/// Crea jobs) register themselves here.
@MainActor
final class AppBusy {
    static let shared = AppBusy()

    /// Composers with text that was not sent (one key per composer on screen).
    private var drafts: Set<String> = []
    /// Work in progress that is not an agent turn in a conversation (a Dev / Crea run, an import, a copy job).
    private var holds: Set<String> = []

    /// A composer's text changed: `hasText` false (sent, cleared, or the composer went away) forgets it.
    func setDraft(_ key: String, hasText: Bool) {
        if hasText { drafts.insert(key) } else { drafts.remove(key) }
    }

    /// Something long started / ended; the update waits while any hold is open.
    func hold(_ token: String) { holds.insert(token) }
    func release(_ token: String) { holds.remove(token) }

    var snapshot: UpdatePolicy.Busy {
        let ws = WorkspaceModel.current
        let runs = max(MenuBarStatus.shared.items.count, ws?.working.count ?? 0)
        let gates = max(MenuBarStatus.shared.waiting, ws?.approvals.count ?? 0)
        return UpdatePolicy.Busy(agentRuns: runs, gatesPending: gates, unsentDrafts: drafts.count, otherRuns: holds.count)
    }

    /// Seconds since the last keyboard, mouse or trackpad input anywhere on this Mac (no permission needed).
    static var systemIdle: TimeInterval {
        guard let any = CGEventType(rawValue: ~0) else { return 0 }
        return CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: any)
    }
}
