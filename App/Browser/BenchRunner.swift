import SwiftUI
import AppKit
import WebKit

/// Runs a browser benchmark in the current chat's browser ("fix the result on the market"): tasks from
/// a JSONL file - WebVoyager ({id, ques, web}) or Online-Mind2Web ({task_id, task_description|confirmed_task, website}) -
/// one after another, each in a new tab from its own start site, with the same agent the person uses (real clicks,
/// the same model, no help). For each task it writes the final answer, success as the agent saw it, steps, model
/// calls, time and cost, and the trajectory with a screenshot per step (what an LLM judge such as WebJudge reads), to
/// ~/Downloads/Liaison Bench/<time>/. Nothing goes to the chat; Lia is not involved.
@MainActor
final class BenchRunner: ObservableObject {
    static let shared = BenchRunner()
    @Published private(set) var running = false
    @Published private(set) var progress = ""
    private var job: Task<Void, Never>?

    struct Item { let id: String; let task: String; let site: URL? }

    static func parse(_ text: String) -> [Item] {
        text.split(separator: "\n").compactMap { line -> Item? in
            guard let o = JSONRead.object(Data(line.utf8)) else { return nil }
            let id = JSONRead.string(o, "id") ?? JSONRead.string(o, "task_id") ?? UUID().uuidString
            guard let task = JSONRead.string(o, "ques") ?? JSONRead.string(o, "task_description") ?? JSONRead.string(o, "confirmed_task") else { return nil }
            let site = (JSONRead.string(o, "web") ?? JSONRead.string(o, "website")).flatMap { s -> URL? in
                URL(string: s.lowercased().hasPrefix("http") ? s : "https://" + s)
            }
            return Item(id: id, task: task, site: site)
        }
    }

    func choose(app: AppModel) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = []
        panel.allowsOtherFileTypes = true
        panel.message = "A benchmark file: WebVoyager or Online-Mind2Web tasks, one JSON object per line"
        guard panel.runModal() == .OK, let url = panel.url, let text = try? String(contentsOf: url, encoding: .utf8) else { return }
        let items = Self.parse(text)
        guard !items.isEmpty else { return }
        start(items, name: url.deletingPathExtension().lastPathComponent, app: app)
    }

    func stop() { job?.cancel() }

    private func start(_ items: [Item], name: String, app: AppModel) {
        guard !running else { return }
        let chat: String = app.currentChatId ?? { () -> String in app.newChat(); return app.currentChatId ?? "bench" }()
        if !app.browserLayout(chat).open { app.updateBrowserLayout(chat) { $0.open = true } }
        let browser = app.browser(for: chat)
        let auth = app.auth
        let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
        let dir = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Liaison Bench").appendingPathComponent(name + " " + stamp)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        running = true
        job = Task { [weak self] in
            var okCount = 0
            for (k, item) in items.enumerated() {
                if Task.isCancelled { break }
                self?.progress = "\(k + 1)/\(items.count) · \(item.id)"
                let taskDir = dir.appendingPathComponent(item.id.replacingOccurrences(of: "/", with: "_"))
                try? FileManager.default.createDirectory(at: taskDir, withIntermediateDirectories: true)
                browser.web.traceDir = taskDir
                browser.agent.log.chatId = chat
                browser.agent.log.send = { c, events in await LiaAPI(auth: auth).agentLog(chatId: c, events: events) }
                let today = DateFormatter.localizedString(from: Date(), dateStyle: .long, timeStyle: .none)
                let goal = item.task + (item.site.map { " (Start on \($0.absoluteString); today is \(today).)" } ?? " (Today is \(today).)")
                let t0 = Date()
                let message: String? = await withCheckedContinuation { k in
                    var resumed = false
                    let finish: (String?) -> Void = { m in if !resumed { resumed = true; k.resume(returning: m) } }
                    browser.web.onEnd = { finish(nil) }
                    browser.web.run(task: "bench:" + item.id, goal: goal, tab: "new", url: item.site?.absoluteString, api: LiaAPI(auth: auth), chatId: chat) { m in finish(m) }
                    // a task gets 8 minutes at most
                    Task { @MainActor in try? await Task.sleep(nanoseconds: 480_000_000_000); if !resumed { browser.web.cancel() } }
                }
                let res = message.flatMap { JSONRead.object(Data($0.dropFirst(BrowserResult.tag.count).utf8)) } ?? [:]
                let ok = (res["ok"] as? Bool) ?? false
                if ok { okCount += 1 }
                let row: [String: Any] = ["id": item.id, "task": item.task, "site": item.site?.absoluteString ?? "", "agent_ok": ok,
                                          "answer": JSONRead.string(res, "summary") ?? "", "why": JSONRead.string(res, "why") ?? (message == nil ? "stopped or timed out" : ""),
                                          "final_url": JSONRead.string(res, "url") ?? "", "steps": (res["steps"] as? Int) ?? 0,
                                          "seconds": Int(Date().timeIntervalSince(t0))]
                Self.append(row, to: dir.appendingPathComponent("results.jsonl"))
                // close the task's tab so the next one starts clean
                if let tab = browser.tabs.last, browser.tabs.count > 1 { browser.close(tab) }
            }
            browser.web.traceDir = nil
            self?.progress = "done: \(okCount)/\(items.count) the agent called finished · \(dir.path)"
            self?.running = false
            NSWorkspace.shared.activateFileViewerSelecting([dir])
        }
    }

    private static func append(_ row: [String: Any], to file: URL) {
        guard let d = try? JSONSerialization.data(withJSONObject: row), var line = String(data: d, encoding: .utf8) else { return }
        line += "\n"
        if let h = try? FileHandle(forWritingTo: file) { h.seekToEndOfFile(); h.write(Data(line.utf8)); try? h.close() }
        else { try? line.write(to: file, atomically: true, encoding: .utf8) }
    }
}
