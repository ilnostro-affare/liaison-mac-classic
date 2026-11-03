import SwiftUI
import Darwin

// Liaison://perf, a diagnostics sheet for the beta: each opened workspace's tabs (loaded or asleep),
// downloads, the app's memory (resident size from mach_task_basic_info) and how long it has been running.

struct PerfSheet: View {
    let ws: WorkspaceModel
    let close: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Diagnostics").font(LiaFont.ui(17, .semibold)).foregroundStyle(WS.ink)
                Spacer()
                Button("Copy") { copy() }.buttonStyle(WSButtonStyle(small: true)).liaPointer()
                Button("Done", action: close).buttonStyle(WSButtonStyle(primary: true, small: true)).liaPointer()
                    .keyboardShortcut(.defaultAction)
            }
            TimelineView(.periodic(from: .now, by: 2)) { _ in content }
        }
        .padding(20)
        .frame(width: 520)
    }

    private var content: some View {
        let lines = PerfReport.lines(ws)
        return ScrollView {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(Array(lines.enumerated()), id: \.offset) { _, l in
                    HStack(alignment: .firstTextBaseline) {
                        Text(l.0).font(LiaFont.ui(13, l.1.isEmpty ? .semibold : .regular))
                            .foregroundStyle(l.1.isEmpty ? WS.ink : WS.text2)
                        Spacer(minLength: 12)
                        Text(l.1).font(LiaFont.mono(12.5)).foregroundStyle(WS.ink)
                            .textSelection(.enabled)
                    }
                    .padding(.top, l.1.isEmpty ? 8 : 0)
                    .accessibilityElement(children: .combine)
                }
            }
        }
        .frame(height: 360)
    }

    private func copy() {
        let s = PerfReport.lines(ws).map { $0.1.isEmpty ? "\n" + $0.0 : "\($0.0): \($0.1)" }.joined(separator: "\n")
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(s, forType: .string)
        ws.show("Diagnostics copied", symbol: "doc.on.doc")
    }
}

@MainActor
enum PerfReport {
    /// (label, value); an empty value is a section title.
    static func lines(_ ws: WorkspaceModel) -> [(String, String)] {
        var out: [(String, String)] = [("App", "")]
        let info = Bundle.main.infoDictionary
        let short: String = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build: String = info?["CFBundleVersion"] as? String ?? "?"
        out.append(("Version", "\(short) (\(build))"))
        var memory = "unknown"
        if let bytes = residentMemory() { memory = ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .memory) }
        out.append(("Memory (resident)", memory))
        out.append(("Running for", duration(uptime())))
        out.append(("macOS", ProcessInfo.processInfo.operatingSystemVersionString))
        let dl = DownloadsCenter.shared
        out.append(("Downloads", "\(dl.items.count) listed, \(dl.active.count) running"))
        for (name, b) in browsers(ws) {
            out.append((name, ""))
            let loaded = b.tabs.filter { !$0.asleep && !$0.isStart && $0.pendingURL == nil }.count
            let asleep = b.tabs.filter { $0.asleep || $0.pendingURL != nil }.count
            out.append(("Tabs", "\(b.tabs.count) (\(loaded) loaded, \(asleep) asleep)"))
            for t in b.tabs.prefix(30) {
                let state: String = t.isStart ? "new" : (t.asleep || t.pendingURL != nil ? "asleep" : (t.isLoading ? "loading" : "loaded"))
                out.append(("  " + String(t.displayTitle.prefix(44)), state))
            }
        }
        return out
    }

    /// The workspace browsers opened this launch (WorkspaceModel.openBrowsers; falls back to the current workspace).
    private static func browsers(_ ws: WorkspaceModel) -> [(String, BrowserModel)] {
        let names = Dictionary(ws.profiles.map { ($0.id, $0.name) }, uniquingKeysWith: { a, _ in a })
        let d = ws.openBrowsers
        if !d.isEmpty {
            return d.keys.sorted().compactMap { k -> (String, BrowserModel)? in
                guard let b = d[k] else { return nil }
                let parts = k.split(separator: "|", maxSplits: 1).map(String.init)
                let base = names[parts.first ?? k] ?? k
                return (parts.count > 1 ? "\(base) \u{00B7} \(parts[1]) (agent)" : base, b)
            }
        }
        guard let p = ws.profile, let b = ws.currentBrowser else { return [] }
        return [(p.name, b)]
    }

    static func residentMemory() -> UInt64? {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / MemoryLayout<natural_t>.size)
        let kr = withUnsafeMutablePointer(to: &info) { p in
            p.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count) }
        }
        return kr == KERN_SUCCESS ? UInt64(info.resident_size) : nil
    }

    /// Since the process started (sysctl), else since the window first asked.
    static func uptime() -> TimeInterval {
        var kinfo = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, getpid()]
        if sysctl(&mib, 4, &kinfo, &size, nil, 0) == 0 {
            let tv = kinfo.kp_proc.p_un.__p_starttime
            let start = Double(tv.tv_sec) + Double(tv.tv_usec) / 1_000_000
            if start > 0 { return Date().timeIntervalSince1970 - start }
        }
        return Date().timeIntervalSince(WSExtras.shared.since)
    }

    static func duration(_ s: TimeInterval) -> String {
        let f = DateComponentsFormatter()
        f.allowedUnits = [.day, .hour, .minute, .second]
        f.unitsStyle = .abbreviated
        f.maximumUnitCount = 3
        return f.string(from: s) ?? "\(Int(s)) s"
    }
}
