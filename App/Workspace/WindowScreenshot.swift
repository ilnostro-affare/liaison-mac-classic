import SwiftUI
import AppKit
import WebKit
import UniformTypeIdentifiers

// "Take Screenshot" (\u{2318}\u{21E7}2 or the tab menu): the visible page as an image, in a small floating
// card with Copy, Download and Send to Lia.: the picture is not saved on this Mac to be sent - Send to
// Lia uploads it (POST /intelligence/attach, the composer's own route) and it waits in Lia's composer as an uploaded
// picture Lia sees; Download goes through the app's downloads (no save panel). Dragging the card's picture onto a
// conversation attaches it the same way (ChatAttach.receive).
// The card shows the whole picture with Copy and Send to\u{2026}: Send to lists every agent the dock
// shows; a pick uploads through the composer's route, opens that agent's dialogue and the picture waits above its input
// (and in Storage > Uploads, which the server's attach index fills). Copy copies and closes. Download is a small icon.

struct WSShot: Identifiable {
    let id = UUID()
    let image: NSImage
    let title: String
    let host: String
    let at = Date()

    /// "Ads Manager at 14.05.33.png"
    var fileName: String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        let base = (title.isEmpty ? host : title)
            .components(separatedBy: CharacterSet(charactersIn: "/\\:?*\"<>|")).joined(separator: " ")
            .trimmingCharacters(in: .whitespaces)
        return String((base.isEmpty ? "Screenshot" : base).prefix(60)) + " " + f.string(from: at) + ".png"
    }

    var png: Data? {
        guard let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff) else { return nil }
        return rep.representation(using: .png, properties: [:])
    }
}

@MainActor
enum WSScreenshot {
    static func take(_ tab: BrowserTab) {
        guard !tab.isStart else { return }
        let config = WKSnapshotConfiguration()
        let title = tab.displayTitle
        let host = tab.url?.host ?? ""
        tab.webView.takeSnapshot(with: config) { image, _ in
            MainActor.assumeIsolated {
                guard let image else {
                    WorkspaceModel.current?.show("Couldn\u{2019}t take a screenshot of this page", symbol: "exclamationmark.triangle")
                    return
                }
                WSExtras.shared.shot = WSShot(image: image, title: title, host: host)
                AccessibilityNotification.Announcement("Screenshot taken").post()
            }
        }
    }

    static func copy(_ s: WSShot) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.writeObjects([s.image])
        ScreenshotWatcher.shared.noteOwnWrite()   // our own Copy never opens the card again
    }

    /// Into the workspace's downloads folder, listed with the downloads (no save panel). True when written.
    static func download(_ s: WSShot) -> Bool {
        guard let data = s.png else { return false }
        return DownloadsCenter.shared.save(data, name: s.fileName) != nil
    }

    /// The agents a screenshot can go to, as the dock shows them: Lia first, then the others in dock order, without
    /// those hidden in this workspace.
    static func agents(_ ws: WorkspaceModel) -> [AgentInfo] {
        let lead = ws.roster.filter { $0.lead }
        return lead + ws.shownAgents(DockOrder.sorted(ws.roster.filter { !$0.lead }))
    }

    /// Why `agent` cannot take a screenshot now (nil: it can).
    static func unavailable(_ agent: AgentInfo, ws: WorkspaceModel) -> String? {
        if agent.soon { return "Coming soon" }
        if ws.isLocked(agent.id) { return "Needs an ad account" }
        if !ws.dialogueIds.contains(DialogueSummary.dlg(forAgent: agent.id)) { return "Not in this workspace" }
        return nil
    }

    /// Uploaded through the composer's own route (ChatAttach.upload: /intelligence/attach, or the
    /// stream route for a very large picture; the server lists it in Storage > Uploads), then that agent's dialogue
    /// opens as a dock click opens it and the picture waits above its input, not sent. The reason it failed otherwise.
    static func send(_ s: WSShot, to agent: AgentInfo, ws: WorkspaceModel) async -> String? {
        guard let data = s.png else { return "Couldn\u{2019}t make the picture." }
        let dlg = DialogueSummary.dlg(forAgent: agent.id)
        guard unavailable(agent, ws: ws) == nil, let chat = ws.chat(for: dlg) else { return "\(agent.name) is not in this workspace." }
        let f = ChatAttach.File(url: ChatAttach.memoryURL(data, name: s.fileName), name: s.fileName, bytes: data.count, inline: nil)
        switch await ChatAttach.upload(f, auth: chat.auth) {
        case .uploaded(let a):
            CreaDraftFiles.put(ChatAttach.File(url: f.url, name: f.name, bytes: f.bytes, inline: nil, state: .uploaded(a)), in: chat.key)
        case .library(let m):
            CreaDraftFiles.put(ChatAttach.File.fromLibrary(m), in: chat.key)
        case .fallback(let why):
            return why
        case .uploading:
            return "Couldn\u{2019}t upload the picture."
        }
        ws.openAgent(agent.id)   // the composer of that dialogue takes it when it is on screen
        NotificationCenter.default.post(name: .liaCreaAttach, object: nil)
        return nil
    }
}

/// The floating card at the bottom right: the picture, Copy, Send to\u{2026} (every agent), Download, \u{00D7}.
struct ScreenshotCard: View {
    let shot: WSShot
    let ws: WorkspaceModel
    let close: () -> Void
    @State private var note: String?
    @State private var picking = false
    /// The agent the picture is on its way to (its row shows the progress).
    @State private var sendingTo: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            picture
            actions
            if let note {
                Text(note)
                    .font(LiaFont.ui(11)).foregroundStyle(WS.text3)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(12)
        .frame(width: 344, alignment: .leading)
        // Readable over any page: a strong white under the glass.
        .background(WS.surface.opacity(0.94), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .wsGlass(16)
        .shadow(color: Color.black.opacity(0.16), radius: 20, y: 8)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text("Screenshot"))
    }

    private var header: some View {
        HStack(spacing: 6) {
            Image(systemName: "camera.viewfinder").font(.system(size: 12, weight: .semibold)).foregroundStyle(WS.text2)
            Text("Screenshot").font(LiaFont.ui(13, .semibold)).foregroundStyle(WS.ink)
            Spacer()
            Button(action: close) {
                Image(systemName: "xmark").font(.system(size: 9.5, weight: .bold)).foregroundStyle(WS.text2)
                    .frame(width: 22, height: 22)
            }
            .buttonStyle(.liaPlain)
            .liaHover(.icon, radius: 7)
            .accessibilityLabel(Text("Close screenshot"))
        }
    }

    /// The whole picture, large enough to read (dragging it onto a conversation attaches it: ChatAttach.receive).
    private var picture: some View {
        Image(nsImage: shot.image)
            .resizable()
            .aspectRatio(contentMode: .fit)
            .frame(maxWidth: 320, maxHeight: 220)
            .frame(width: 320)
            .background(WS.soft, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(WS.line, lineWidth: 1))
            .onDrag {
                let p = NSItemProvider(object: shot.image)
                p.suggestedName = shot.fileName
                return p
            }
            .accessibilityLabel(Text("Screenshot of \(shot.title)"))
    }

    private var actions: some View {
        HStack(spacing: 6) {
            Button("Copy") { copy() }
                .buttonStyle(WSButtonStyle(small: true))
            Button { picking.toggle() } label: {
                HStack(spacing: 4) {
                    Text(sendingTo == nil ? "Send to\u{2026}" : "Uploading\u{2026}")
                    Image(systemName: "chevron.down").font(.system(size: 8.5, weight: .bold))
                }
            }
            .buttonStyle(WSButtonStyle(primary: true, small: true))
            .accessibilityHint(Text("Choose an agent; the picture waits in its message box"))
            .popover(isPresented: $picking, arrowEdge: .bottom) { agentList }
            Spacer(minLength: 0)
            Button(action: download) {
                Image(systemName: "arrow.down.to.line").font(.system(size: 12, weight: .semibold)).foregroundStyle(WS.text2)
                    .frame(width: 28, height: 28)
            }
            .buttonStyle(.liaPlain)
            .liaHover(.icon, radius: 8)
            .accessibilityLabel(Text("Download screenshot"))
        }
        .liaPointer()
    }

    private var agentList: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Send to").font(LiaFont.ui(11, .semibold)).foregroundStyle(WS.text3)
                .padding(.horizontal, 8).padding(.top, 2).padding(.bottom, 4)
            ForEach(WSScreenshot.agents(ws)) { a in agentRow(a) }
        }
        .padding(8)
        .frame(width: 240, alignment: .leading)
    }

    private func agentRow(_ a: AgentInfo) -> some View {
        let why = WSScreenshot.unavailable(a, ws: ws)
        return Button { send(to: a) } label: {
            HStack(spacing: 10) {
                AgentAvatar(agent: a, size: 24, status: ws.status(of: a.id), nudges: false)
                    .frame(width: 26, height: 26)
                VStack(alignment: .leading, spacing: 1) {
                    Text(a.name).font(LiaFont.ui(13, .medium)).foregroundStyle(WS.ink)
                    rowCaption(a, why: why)
                }
                Spacer(minLength: 0)
                rowTrail(a)
            }
            .padding(.horizontal, 8)
            .frame(height: 38)
            .contentShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
        }
        .buttonStyle(.liaPlain)
        .liaHover(.fill, radius: 9)
        .disabled(why != nil || sendingTo != nil)
        .opacity(why != nil ? 0.5 : 1)
        .accessibilityLabel(Text(why.map { "\(a.name), \($0)" } ?? "Send to \(a.name)"))
    }

    @ViewBuilder private func rowCaption(_ a: AgentInfo, why: String?) -> some View {
        let line = why ?? a.role
        if !line.isEmpty {
            Text(line).font(LiaFont.ui(11)).foregroundStyle(WS.text3).lineLimit(1)
        }
    }

    @ViewBuilder private func rowTrail(_ a: AgentInfo) -> some View {
        if sendingTo == a.id {
            ProgressView().controlSize(.small)
        }
    }

    private func copy() {
        WSScreenshot.copy(shot)
        ws.show("Copied", symbol: "doc.on.doc")
        close()
    }

    private func download() {
        if WSScreenshot.download(shot) { ws.show("Screenshot downloaded", symbol: "arrow.down.circle") }
        else { note = "Couldn\u{2019}t save the picture to Downloads." }
    }

    private func send(to a: AgentInfo) {
        guard sendingTo == nil else { return }
        sendingTo = a.id
        note = nil
        Task { @MainActor in
            let failed = await WSScreenshot.send(shot, to: a, ws: ws)
            sendingTo = nil
            if let failed {
                note = failed
                ws.show("Couldn\u{2019}t send to \(a.name): " + failed, symbol: "exclamationmark.triangle")
            } else {
                picking = false
                close()
            }
        }
    }
}
