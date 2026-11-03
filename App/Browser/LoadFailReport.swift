import Foundation
import os

/// The side of LoadFailLog that touches the world: an os_log line for every card shown or failure kept
/// off a showing page, and at most one `load_fail` event per host per minute to lia-agents (LiaAPI.logEvent).
/// Called from BrowserTab.failed, the one place the card is decided. Host only, never the path or query.
@MainActor
enum LoadFailReport {
    private static let log = Logger(subsystem: "com.liaisone.mac", category: "browser")
    private static var throttle = LoadFailLog.Throttle()
    private static let client = LoadFailLog.client(version: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String)

    static func report(_ outcome: LoadFailLog.Outcome, url: URL?, domain: String, code: Int, committed: Bool,
                       retries: Int, since: Date?) {
        let host = LoadFailLog.host(url) ?? "-"
        let ms = since.map { Int(Date().timeIntervalSince($0) * 1000) } ?? 0
        log.notice("load_fail \(outcome.rawValue, privacy: .public) host=\(host, privacy: .public) \(domain, privacy: .public) \(code) retries=\(retries) ms=\(ms)")
        guard host != "-", throttle.allow(host), let auth = WorkspaceModel.current?.auth else { return }
        let fields = LoadFailLog.fields(host: host, code: code, committed: committed, showing: outcome == .kept,
                                        retries: retries, ms: ms, client: client)
        let api = LiaAPI(auth: auth)
        Task {
            // 429: the server asks us to stop; nothing more goes this run.
            if await api.logEvent(kind: LoadFailLog.kind, fields: fields) == 429 { LoadFailReport.throttle.stop() }
        }
    }
}
