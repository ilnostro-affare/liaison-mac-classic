import SwiftUI
import AppKit
import WebKit
import UniformTypeIdentifiers
import OSLog

/// "Report a problem" is our own form over the workspace, not Mail (it replaced SetxFeedback's
/// mailto). Glass and compact like the browser's popups. It attaches by itself: the time, the app and macOS versions,
/// the workspace, the page in front (address and title), the dialogue in front and the last ~200 lines of the app's
/// recent logs (this process's unified log for the last 15 minutes, with the agent's own steps); the person writes
/// what happened and may add a screenshot (the window as it was when the form opened, or an image file).
/// Sent to POST https://lia.liaisone.com/agents/report (lia-agents, kept in R2 under the member).
@MainActor
enum ReportProblem {
    static func open(ws: WorkspaceModel?) {
        let ctx = context(ws)
        let agentLines = agentLog(ws)
        Task { @MainActor in
            // Settings may just have closed: the window in front is the workspace's.
            try? await Task.sleep(nanoseconds: 80_000_000)
            let shot = await WindowShot.png(NSApp.mainWindow ?? NSApp.keyWindow)
            let id = UUID()
            let form = ReportProblemForm(context: ctx, agentLines: agentLines, windowShot: shot, auth: ws?.auth)
            LiaModalCenter.shared.present(id, style: .bare, content: AnyView(form),
                                          onDismiss: { LiaModalCenter.shared.remove(id) })
        }
    }

    /// What the app saw, in the order the form lists it.
    static func context(_ ws: WorkspaceModel?) -> [(key: String, value: String)] {
        let info = Bundle.main.infoDictionary
        let v = info?["CFBundleShortVersionString"] as? String ?? "?"
        let b = info?["CFBundleVersion"] as? String ?? "?"
        let iso = ISO8601DateFormatter()
        iso.timeZone = .current
        var out: [(key: String, value: String)] = [
            ("time", iso.string(from: Date())),
            ("app_version", "\(v) (\(b))"),
            ("macos", ProcessInfo.processInfo.operatingSystemVersionString),
        ]
        guard let ws else { return out }
        if let p = ws.profile {
            out.append(("workspace", p.name))
            out.append(("workspace_id", p.id))
        }
        if let t = ws.currentBrowser?.selected {
            out.append(("page_url", t.isStart ? "Home (new tab)" : (t.url?.absoluteString ?? "")))
            out.append(("page_title", t.displayTitle))
        }
        if let dlg = ws.sheet {
            out.append(("dialogue_id", dlg))
            var lines: [(who: String, text: String)] = []
            if let c = ws.chatIfOpen(dlg) {
                for it in c.items.suffix(12) {
                    let who = it.agent.flatMap { ws.agent($0)?.name } ?? (it.message.role == .user ? "You" : "Agent")
                    lines.append((who, FeedText.plain(it.message.content)))
                }
            }
            let title = ws.dialogueTitle(dlg)
            out.append(("dialogue", title + (lines.isEmpty ? "" : "\n" + ProblemReport.dialogue(lines))))
        }
        return out
    }

    /// The agent's last steps in this workspace's browser (in memory), as log lines with their times.
    static func agentLog(_ ws: WorkspaceModel?) -> [(Date, String)] {
        guard let b = ws?.currentBrowser else { return [] }
        return b.agent.log.recent.map { e in (e.at, ProblemReport.line(at: e.at, source: "agent", e.event + (e.text.isEmpty ? "" : " " + e.text))) }
    }

    /// This process's unified log since `since` (newest last, at most `limit`), read off the main thread.
    nonisolated static func osLog(since: Date, limit: Int = 400) -> [(Date, String)] {
        guard let store = try? OSLogStore(scope: .currentProcessIdentifier),
              let entries = try? store.getEntries(at: store.position(date: since)) else { return [] }
        var out: [(Date, String)] = []
        for e in entries {
            guard let l = e as? OSLogEntryLog else { continue }
            let source = l.category.isEmpty ? l.subsystem : l.category
            out.append((l.date, ProblemReport.line(at: l.date, source: source, l.composedMessage)))
            if out.count > limit * 4 { out.removeFirst(out.count - limit) }
        }
        return Array(out.suffix(limit))
    }
}

/// The window as it was, as PNG: the SwiftUI layers from the view hierarchy and every visible web page drawn over
/// them from WebKit's own snapshot (a page does not draw into a view cache). At most 1,600 px wide and under the
/// server's 4 MB of base64.
@MainActor
enum WindowShot {
    static func png(_ window: NSWindow?) async -> Data? {
        guard let w = window, let content = w.contentView, content.bounds.width > 10, content.bounds.height > 10 else { return nil }
        let bounds = content.bounds
        guard let base = content.bitmapImageRepForCachingDisplay(in: bounds) else { return nil }
        content.cacheDisplay(in: bounds, to: base)
        var pages: [(NSImage, CGRect)] = []
        for wv in webViews(in: content) where wv.window === w && !wv.isHiddenOrHasHiddenAncestor && wv.bounds.width > 4 {
            let snap: NSImage? = await withCheckedContinuation { k in wv.takeSnapshot(with: nil) { img, _ in k.resume(returning: img) } }
            guard let img = snap else { continue }
            pages.append((img, wv.convert(wv.bounds, to: content)))
        }
        var k = min(w.backingScaleFactor, 1600 / bounds.width)
        for _ in 0..<4 {
            if let d = draw(base: base, pages: pages, size: bounds.size, flipped: content.isFlipped, scale: k),
               d.count * 4 / 3 < ProblemReport.maxScreenshot - 1000 {
                return d
            }
            k *= 0.7
        }
        return nil
    }

    /// An image file (Choose Image…), scaled the same way.
    static func png(file: URL) -> Data? {
        guard let img = NSImage(contentsOf: file), img.size.width > 0, img.size.height > 0 else { return nil }
        var k = min(1, 1600 / img.size.width)
        for _ in 0..<4 {
            let size = CGSize(width: (img.size.width * k).rounded(), height: (img.size.height * k).rounded())
            if let rep = bitmap(size, scale: 1) {
                NSGraphicsContext.saveGraphicsState()
                NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
                img.draw(in: CGRect(origin: .zero, size: size))
                NSGraphicsContext.restoreGraphicsState()
                if let d = rep.representation(using: .png, properties: [:]), d.count * 4 / 3 < ProblemReport.maxScreenshot - 1000 { return d }
            }
            k *= 0.7
        }
        return nil
    }

    private static func webViews(in v: NSView) -> [WKWebView] {
        var out: [WKWebView] = []
        for s in v.subviews {
            if let w = s as? WKWebView { out.append(w) } else { out += webViews(in: s) }
        }
        return out
    }

    private static func bitmap(_ size: CGSize, scale: CGFloat) -> NSBitmapImageRep? {
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: max(1, Int(size.width * scale)),
                                   pixelsHigh: max(1, Int(size.height * scale)), bitsPerSample: 8, samplesPerPixel: 4,
                                   hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)
        rep?.size = size
        return rep
    }

    private static func draw(base: NSBitmapImageRep, pages: [(NSImage, CGRect)], size: CGSize, flipped: Bool, scale: CGFloat) -> Data? {
        guard let rep = bitmap(size, scale: scale) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        base.draw(in: CGRect(origin: .zero, size: size))
        for (img, r) in pages {
            // The context is bottom-left; the content view may be flipped.
            let y = flipped ? size.height - r.maxY : r.minY
            img.draw(in: CGRect(x: r.minX, y: y, width: r.width, height: r.height))
        }
        NSGraphicsContext.restoreGraphicsState()
        return rep.representation(using: .png, properties: [:])
    }
}

extension LiaAPI {
    /// POST /agents/report -> the report's id. Throws with the server's words when it refused.
    func sendProblemReport(_ body: [String: Any]) async throws -> String? {
        guard let url = URL(string: AppConfig.agentsBase + "/agents/report") else { throw AuthError.network }
        for attempt in 0..<2 {
            let t = try await token(forceRefresh: attempt == 1)
            var req = URLRequest(url: url, timeoutInterval: 60)
            LiaClient.stamp(&req)   // X-Lia-Client, our hosts only
            req.httpMethod = "POST"
            req.setValue("Bearer \(t)", forHTTPHeaderField: "Authorization")
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = try JSONSerialization.data(withJSONObject: body)
            let got: (Data, URLResponse)
            do { got = try await session.data(for: req) } catch { throw AuthError.network }
            let status = (got.1 as? HTTPURLResponse)?.statusCode ?? 0
            if status == 401 && attempt == 0 { continue }
            let o = JSONRead.object(got.0)
            if (200..<300).contains(status), JSONRead.bool(o, "ok") { return JSONRead.string(o, "id") }
            throw AuthError.server(JSONRead.string(o, "error") ?? "HTTP \(status)")
        }
        throw AuthError.sessionExpired
    }
}

private struct ReportProblemForm: View {
    let context: [(key: String, value: String)]
    let agentLines: [(Date, String)]
    let windowShot: Data?
    let auth: AuthStore?
    @Environment(\.liaDismiss) private var dismiss
    @State private var text = ""
    @State private var shot: Data?
    @State private var shotImage: NSImage?
    @State private var logs: [String]?
    @State private var details = false
    @State private var sending = false
    @State private var sent = false
    @State private var error: String?
    @FocusState private var focus: Bool

    private var report: ProblemReport {
        ProblemReport(text: text, context: context, logs: logs ?? agentLines.map(\.1), screenshotB64: shot?.base64EncodedString())
    }

    var body: some View {
        ZStack {
            LiaModalScrim().onTapGesture { if !sending { dismiss() } }
            card
                .frame(width: 460)
                .wsGlass(18)
                .shadow(color: Color.black.opacity(0.18), radius: 28, y: 12)
        }
        .task { await collectLogs() }
        .onAppear { focus = true }
    }

    private var card: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Report a problem").font(LiaFont.ui(15, .semibold)).foregroundStyle(WS.ink)
                Spacer()
                LiaModalCloseButton(size: 26) { dismiss() }
            }
            if sent {
                sentView
            } else {
                editor
                screenshotRow
                attached
                footer
            }
        }
        .padding(16)
    }

    private var editor: some View {
        TextEditor(text: $text)
            .font(LiaFont.ui(13))
            .scrollContentBackground(.hidden)
            .focused($focus)
            .padding(6)
            .frame(height: 110)
            .background(WS.field, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(WS.line2, lineWidth: 1))
            .overlay(alignment: .topLeading) {
                if text.isEmpty {
                    Text("What happened, and what did you expect?")
                        .font(LiaFont.ui(13)).foregroundStyle(WS.text3)
                        .padding(.horizontal, 11).padding(.vertical, 6)
                        .allowsHitTesting(false)
                }
            }
            .accessibilityLabel(Text("What happened"))
    }

    @ViewBuilder private var screenshotRow: some View {
        HStack(spacing: 8) {
            if let img = shotImage {
                Image(nsImage: img).resizable().aspectRatio(contentMode: .fit)
                    .frame(height: 44)
                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).stroke(WS.line2, lineWidth: 1))
                Text("Screenshot").font(LiaFont.ui(12)).foregroundStyle(WS.text2)
                Button("Remove") { shot = nil; shotImage = nil }
                    .buttonStyle(WSButtonStyle(small: true))
            } else {
                if windowShot != nil {
                    Button { set(windowShot) } label: { Label("Add Window Screenshot", systemImage: "camera.viewfinder") }
                        .buttonStyle(WSButtonStyle(small: true))
                }
                Button { choose() } label: { Label("Choose Image\u{2026}", systemImage: "photo") }
                    .buttonStyle(WSButtonStyle(small: true))
            }
            Spacer(minLength: 0)
        }
    }

    /// What goes with the words, folded by default.
    private var attached: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button { withAnimation(.easeOut(duration: 0.15)) { details.toggle() } } label: {
                HStack(spacing: 5) {
                    Image(systemName: details ? "chevron.down" : "chevron.right").font(.system(size: 9, weight: .bold))
                    Text("Attached: version, page, dialogue and \(logs.map { "\(min($0.count, ProblemReport.maxLogs)) log lines" } ?? "logs\u{2026}")")
                        .font(LiaFont.ui(12))
                }
                .foregroundStyle(WS.text2)
                .contentShape(Rectangle())
            }
            .buttonStyle(.liaPlain)
            if details {
                ScrollView {
                    VStack(alignment: .leading, spacing: 3) {
                        ForEach(Array(context.enumerated()), id: \.offset) { _, kv in
                            Text("\(kv.key): \(kv.value)").lineLimit(3)
                        }
                        ForEach(Array(ProblemReport.tail(logs ?? []).suffix(40).enumerated()), id: \.offset) { _, l in
                            Text(l).lineLimit(1).foregroundStyle(WS.text3)
                        }
                    }
                    .font(.system(size: 10.5, design: .monospaced))
                    .foregroundStyle(WS.text2)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(height: 130)
                .padding(8)
                .background(WS.field, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            }
        }
    }

    private var footer: some View {
        HStack(spacing: 8) {
            if let error {
                Text(error).font(LiaFont.ui(12)).foregroundStyle(WS.bad).lineLimit(2)
            }
            Spacer(minLength: 0)
            Button("Cancel") { dismiss() }
                .buttonStyle(WSButtonStyle(small: true))
                .disabled(sending)
            Button(sending ? "Sending\u{2026}" : "Send") { send() }
                .buttonStyle(WSButtonStyle(primary: true, small: true))
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(sending || !report.canSend || auth == nil)
        }
    }

    private var sentView: some View {
        HStack(spacing: 8) {
            Image(systemName: "checkmark.circle.fill").font(.system(size: 18)).foregroundStyle(WS.blue)
            Text("Sent. Thank you, we\u{2019}ll look into it.").font(LiaFont.ui(13, .medium)).foregroundStyle(WS.ink)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 8)
    }

    private func set(_ d: Data?) {
        shot = d
        shotImage = d.flatMap { NSImage(data: $0) }
    }

    private func choose() {
        let p = NSOpenPanel()
        p.allowedContentTypes = [.image]
        p.allowsMultipleSelection = false
        p.canChooseDirectories = false
        guard p.runModal() == .OK, let u = p.url else { return }
        if let d = WindowShot.png(file: u) { set(d); error = nil } else { error = "That image could not be read." }
    }

    private func collectLogs() async {
        let since = Date().addingTimeInterval(-15 * 60)
        let os = await Task.detached(priority: .utility) { ReportProblem.osLog(since: since) }.value
        let all = (os + agentLines).sorted { $0.0 < $1.0 }.map(\.1)
        logs = ProblemReport.tail(all)
    }

    private func send() {
        guard let auth, !sending, report.canSend else { return }
        sending = true
        error = nil
        let body = report.body()
        Task { @MainActor in
            do {
                _ = try await LiaAPI(auth: auth).sendProblemReport(body)
                sending = false
                withAnimation(.easeOut(duration: 0.2)) { sent = true }
                try? await Task.sleep(nanoseconds: 1_400_000_000)
                dismiss()
            } catch {
                sending = false
                self.error = userMessage(for: error)
            }
        }
    }
}
