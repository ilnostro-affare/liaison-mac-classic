import Foundation
import Combine

/// (macOS listed Liaison under "using significant energy"): the Mac's Low Power Mode, read live. While
/// it is on, everything that only decorates holds still or slows down: Home's sky stops moving, a working agent's
/// figure draws a few frames a second, the menu bar's figure does not dance.
@MainActor
final class EnergySaver: ObservableObject {
    static let shared = EnergySaver()
    @Published private(set) var low = ProcessInfo.processInfo.isLowPowerModeEnabled
    private var observer: NSObjectProtocol?

    private init() {
        observer = NotificationCenter.default.addObserver(forName: .NSProcessInfoPowerStateDidChange, object: nil, queue: .main) { _ in
            Task { @MainActor in
                let v = ProcessInfo.processInfo.isLowPowerModeEnabled
                if EnergySaver.shared.low != v { EnergySaver.shared.low = v }
            }
        }
    }

    /// Low Power Mode, read now (callers outside SwiftUI).
    nonisolated static var isLow: Bool { ProcessInfo.processInfo.isLowPowerModeEnabled }
}
