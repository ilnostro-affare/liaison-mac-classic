import SwiftUI
import AppKit

// Notes per workspace (Vivaldi Notes, Arc Notes): a glass panel under the top bar with one text,
// saved as it is typed in UserDefaults (`lia_ws_notes_<profileId>`). On this Mac, nothing leaves the Mac.
// "@" offers the agents; a line with "@Name" goes to that agent's composer (Ask, or \u{2318}\u{23CE} for the last
// line), where the person sends it. Lines sent before show "Sent to Name \u{2713}".
// On this Mac / Synced per workspace. Synced notes are encrypted on the Mac (AES-GCM, a key in
// the Keychain) before they go to Liaison and come back on the person's other devices (NotesSyncEngine.swift). The text
// above stays the local copy in both modes.

struct WorkspaceNotesPanel: View {
    @ObservedObject var ws: WorkspaceModel
    let profileId: String
    let name: String
    let close: () -> Void
    /// Lines already sent, line text -> agent id (`lia_ws_notes_sent_<profileId>`).
    @State private var sent: [String: String] = [:]
    @State private var text = ""
    @State private var loaded = false
    @State private var saveToken = 0
    /// Each change focuses the note (MentionTextView, which takes no @FocusState).
    @State private var focusTick = 0
    /// The panel's place, for the click-outside check.
    @State private var box = AnchorBox()
    @State private var outside = WSNotesOutside()
    @ObservedObject private var sync: NotesSyncEngine
    /// The one inline card open under the switch (confirm a change, the recovery key), nil: none.
    @State private var card: NotesCard?
    @State private var keyInput = ""
    @State private var keyError: String?
    @State private var busy = false
    /// The recovery key while its card is open (read from the Keychain once, on opening).
    @State private var shownKey = ""

    init(ws: WorkspaceModel, profileId: String, name: String, close: @escaping () -> Void) {
        self.ws = ws
        self.profileId = profileId
        self.name = name
        self.close = close
        _sync = ObservedObject(wrappedValue: NotesSyncEngine.of(profileId, member: ws.auth.memberId ?? ""))
    }

    private var key: String { "lia_ws_notes_" + profileId }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            header
            syncRow
            if let c = card { cardView(c) }
            editor
            NotesOtherList(notes: sync.mode == .synced ? sync.others : [],
                           add: { id in text = sync.addToMain(id, mainText: text) },
                           delete: { id in sync.deleteOther(id) })
            NotesMentionPicker(agents: mentionable, partial: NoteMentions.partial(text)) { a in insert(a) }
            NotesMentionLines(lines: mentionLines, sent: sent, agent: { ws.agent($0) },
                              send: { send($0) }, open: { ws.openAgent($0) })
            footer
        }
        .padding(12)
        .frame(width: 320, height: panelHeight)
        .background { sendShortcut }
        // Readable over any page: a white card, not a see-through glass.
        .background(WS.surface, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).stroke(WS.line2, lineWidth: 1))
        .shadow(color: Color.black.opacity(0.14), radius: 20, y: 8)
        .background(AnchorReader(box: box))
        .onAppear {
            sync.attach(ws.auth)
            load()
            outside.start(panel: box, close: close)
        }
        // Synced: once on open, then every 30 s while the panel is open (typing syncs 2 s after the last key).
        .task(id: sync.mode) {
            guard sync.mode == .synced else { return }
            while !Task.isCancelled {
                await sync.sync()
                try? await Task.sleep(nanoseconds: 30_000_000_000)
            }
        }
        .onChange(of: sync.mainRevision) { _, _ in text = UserDefaults.standard.string(forKey: key) ?? "" }
        .onDisappear {
            outside.stop()
            save()
        }
        .onChange(of: text) { _, t in
            scheduleSave()
            if loaded { sync.typed(t) }
        }
        .onExitCommand { close() }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text("Notes for \(name)"))
    }

    private var header: some View {
        HStack(spacing: 6) {
            Image(systemName: "note.text").font(.system(size: 12, weight: .semibold)).foregroundStyle(WS.text2)
            Text(name.isEmpty ? "Notes" : "Notes \u{00B7} \(name)")
                .font(LiaFont.ui(13, .semibold)).foregroundStyle(WS.ink).lineLimit(1)
            Spacer()
            // 28 pt, the whole square takes the click (a plain button otherwise answers only on the glyph).
            Button(action: close) {
                Image(systemName: "xmark").font(.system(size: 10.5, weight: .bold)).foregroundStyle(WS.text2)
                    .frame(width: 28, height: 28)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.liaPlain)
            .liaHover(.icon, radius: 8)
            .accessibilityLabel(Text("Close notes"))
        }
    }

    private var panelHeight: CGFloat {
        var h: CGFloat = 396
        if !mentionLines.isEmpty { h += 80 }
        if sync.mode == .synced && !sync.others.isEmpty { h += min(CGFloat(sync.others.count), 3) * 26 + 22 }
        if card != nil { h += 112 }
        return h
    }

    // MARK: On this Mac / Synced

    private static let lockTip = "End-to-end encrypted. Notes are encrypted on your devices before upload; Liaison can't read them."

    private var modeBinding: Binding<NotesSyncMode> {
        Binding(get: { sync.mode }, set: { m in
            guard m != sync.mode else { return }
            if m == .synced { card = .confirmSync } else { card = nil; sync.disableSync() }
        })
    }

    private var syncRow: some View {
        HStack(spacing: 6) {
            Picker("", selection: modeBinding) {
                Text("On this Mac").tag(NotesSyncMode.local)
                Text("Synced").tag(NotesSyncMode.synced)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .controlSize(.small)
            .frame(width: 170)
            .accessibilityLabel(Text("Where notes are kept"))
            Image(systemName: "lock.fill")
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundStyle(sync.mode == .synced ? WS.green : WS.text3)
                .frame(width: 22, height: 22)
                .contentShape(Rectangle())
                .liaTip(Self.lockTip)
                .accessibilityLabel(Text(Self.lockTip))
            Spacer(minLength: 0)
            Menu {
                if sync.keyPlace != nil {
                    Button("Show Recovery Key\u{2026}") { shownKey = sync.recoveryKey() ?? ""; card = shownKey.isEmpty ? nil : .showKey }
                }
                Button("Enter Recovery Key\u{2026}") { keyInput = ""; keyError = nil; card = .enterKey }
                Divider()
                Button("Delete Synced Copies\u{2026}") { card = .confirmPurge }
            } label: {
                Image(systemName: "ellipsis").font(.system(size: 11, weight: .bold)).foregroundStyle(WS.text2)
                    .frame(width: 24, height: 22)
                    .contentShape(Rectangle())
            }
            .menuStyle(.button)
            .buttonStyle(.liaPlain)
            .menuIndicator(.hidden)
            .fixedSize()
            .accessibilityLabel(Text("Sync options"))
        }
    }

    @ViewBuilder private var footer: some View {
        HStack(spacing: 6) {
            if sync.mode == .synced {
                Circle().fill(statusColor).frame(width: 6, height: 6).accessibilityHidden(true)
            }
            Text(sync.mode == .synced ? sync.status.line : (sync.notice ?? NotesSyncStatus.off.line))
                .font(LiaFont.ui(11)).foregroundStyle(WS.text3).lineLimit(1).truncationMode(.tail)
            Spacer(minLength: 0)
            if sync.mode == .synced && sync.status == .needsKey && card == nil {
                Button("Enter key") { keyInput = ""; keyError = nil; card = .enterKey }
                    .buttonStyle(.liaPlain).font(LiaFont.ui(11, .semibold)).foregroundStyle(WS.blue).liaPointer()
            }
        }
    }

    private var statusColor: Color {
        switch sync.status {
        case .synced: return WS.green
        case .syncing: return WS.blue
        case .offline, .needsKey: return WS.amber
        case .error: return WS.red
        case .off: return WS.text3
        }
    }

    @ViewBuilder private func cardView(_ c: NotesCard) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            switch c {
            case .confirmSync:
                cardText("Sync the notes of this workspace? They are encrypted on this Mac before upload and appear on your other devices signed in to Liaison.")
                cardButtons(cancel: "Cancel", ok: "Sync") { card = nil; sync.enableSync(mainText: text) }
            case .confirmPurge:
                cardText("Delete the synced copies of this workspace's notes from your Liaison cloud? This Mac keeps its copy and stops syncing.")
                cardButtons(cancel: "Cancel", ok: busy ? "Deleting\u{2026}" : "Delete", destructive: true) {
                    busy = true
                    Task {
                        let err = await sync.deleteCloudCopies()
                        busy = false
                        if let err { keyError = err } else { card = nil }
                    }
                }
                if let e = keyError { Text(e).font(LiaFont.ui(11)).foregroundStyle(WS.red) }
            case .showKey:
                let k = shownKey
                cardText(sync.keyPlace == .iCloud
                         ? "Your other Apple devices get the key through iCloud Keychain. On the web or a phone, enter this key once. Keep it private."
                         : "The key is kept on this Mac only. Enter this key once on your other devices to read synced notes. Keep it private.")
                Text(k).font(.system(size: 10.5, design: .monospaced)).foregroundStyle(WS.ink).textSelection(.enabled)
                    .lineLimit(2).fixedSize(horizontal: false, vertical: true)
                cardButtons(cancel: "Done", ok: "Copy") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(k, forType: .string)
                    shownKey = ""
                    card = nil
                }
            case .enterKey:
                cardText("Enter the recovery key from a device that already syncs notes.")
                TextField("LIA1-\u{2026}", text: $keyInput)
                    .textFieldStyle(.roundedBorder).font(.system(size: 11, design: .monospaced))
                    .onSubmit { useKey() }
                if let e = keyError { Text(e).font(LiaFont.ui(11)).foregroundStyle(WS.red).lineLimit(2) }
                cardButtons(cancel: "Cancel", ok: busy ? "Checking\u{2026}" : "Use Key") { useKey() }
            }
        }
        .padding(10)
        .background(WS.line.opacity(0.5), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .transition(.opacity)
    }

    private func useKey() {
        guard !busy else { return }
        busy = true
        Task {
            let err = await sync.enterRecoveryKey(keyInput)
            busy = false
            if let err { keyError = err } else { keyInput = ""; card = nil }
        }
    }

    private func cardText(_ t: String) -> some View {
        Text(t).font(LiaFont.ui(11.5)).foregroundStyle(WS.text2).fixedSize(horizontal: false, vertical: true)
    }

    private func cardButtons(cancel: String, ok: String, destructive: Bool = false, action: @escaping () -> Void) -> some View {
        HStack(spacing: 6) {
            Spacer(minLength: 0)
            Button(cancel) { card = nil; keyError = nil }
                .buttonStyle(.liaPlain).font(LiaFont.ui(11.5, .semibold)).foregroundStyle(WS.text2)
                .padding(.horizontal, 10).frame(height: 24)
                .contentShape(Capsule())
                .liaHover(.fill, radius: 12)
            Button(ok, action: action)
                .buttonStyle(.liaPlain).font(LiaFont.ui(11.5, .semibold)).foregroundStyle(.white)
                .padding(.horizontal, 12).frame(height: 24)
                .background(destructive ? WS.red : WS.blue, in: Capsule())
                .contentShape(Capsule())
                .liaPointer()
                .disabled(busy)
        }
    }

    /// "@Agent" in the note is the message box's pill (MentionTextView: an NSTextView drawing the
    /// rounded tint under the name in the agent's colour); it was a SwiftUI TextEditor.
    private var editor: some View {
        MentionTextView(text: $text, fontSize: 13, focusTick: focusTick, onEscape: close)
            .padding(6)
            .background(WS.surface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(WS.line, lineWidth: 1))
            .overlay(alignment: .topLeading) { placeholder }
            .accessibilityLabel(Text("Notes"))
    }

    @ViewBuilder private var placeholder: some View {
        if text.isEmpty {
            Text("Client context, logins to ask for, what was agreed\u{2026}")
                .font(LiaFont.ui(13)).foregroundStyle(WS.text3)
                .padding(.horizontal, 11).padding(.vertical, 6)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
    }

    private var sentKey: String { "lia_ws_notes_sent_" + profileId }

    /// The agents a note can name (not the ones still to come).
    private var mentionable: [AgentInfo] { ws.roster.filter { !$0.soon } }

    private var mentionLines: [NoteMentions.Line] { NoteMentions.lines(text, agents: mentionable) }

    /// The picked agent replaces the "@part" being typed at the end of the note.
    private func insert(_ a: AgentInfo) {
        let part = NoteMentions.partial(text) ?? ""
        if text.hasSuffix("@" + part) { text.removeLast(part.count + 1) }
        text += "@" + a.name + " "
        focusTick += 1
    }

    /// The line waits in the agent's composer (WorkspaceModel.draft); the person sends it there, so
    /// the line is not marked sent here. Lines no longer in the note are forgotten from the old "sent" map.
    private func send(_ line: NoteMentions.Line) {
        let body = line.body.isEmpty ? line.text : line.body
        ws.draft("Reminder from notes: " + body, toAgent: line.agent)
        let alive = Set(mentionLines.map(\.text))
        let kept = sent.filter { alive.contains($0.key) }
        if kept != sent { sent = kept; UserDefaults.standard.set(sent, forKey: sentKey) }
    }

    /// \u{2318}\u{23CE}: the last line naming an agent that was not sent yet.
    private var sendShortcut: some View {
        Button("") { if let l = mentionLines.last(where: { sent[$0.text] == nil }) { send(l) } }
            .keyboardShortcut(.return, modifiers: .command)
            // Off when there is nothing to send, so the new tab's own \u{2318}\u{23CE} (search) keeps working.
            .disabled(!mentionLines.contains { sent[$0.text] == nil })
            .buttonStyle(.liaPlain)
            .opacity(0)
            .frame(width: 0, height: 0)
            .accessibilityHidden(true)
    }

    private func load() {
        text = UserDefaults.standard.string(forKey: key) ?? ""
        sent = (UserDefaults.standard.dictionary(forKey: sentKey) as? [String: String]) ?? [:]
        loaded = true
        DispatchQueue.main.async { focusTick += 1 }
    }

    /// Half a second after the last key (and when the panel closes).
    private func scheduleSave() {
        guard loaded else { return }
        saveToken += 1
        let t = saveToken
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { if t == saveToken { save() } }
    }

    private func save() {
        guard loaded else { return }
        if text.isEmpty { UserDefaults.standard.removeObject(forKey: key) } else { UserDefaults.standard.set(text, forKey: key) }
    }
}

/// The pure part: which lines name an agent, and the "@part" being typed at the end.
enum NoteMentions {
    struct Line: Identifiable, Equatable {
        var id: String { text }
        /// The whole line as written.
        let text: String
        let agent: String
        /// The line without the "@Name".
        let body: String
    }

    static func lines(_ note: String, agents: [AgentInfo]) -> [Line] {
        var out: [Line] = []
        var seen = Set<String>()
        for raw in note.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard line.contains("@"), !seen.contains(line), let m = match(line, agents: agents) else { continue }
            seen.insert(line)
            out.append(Line(text: line, agent: m.0.id, body: m.1))
        }
        return out
    }

    /// The first "@Name" in the line naming an agent (case-insensitive, a whole word).
    private static func match(_ line: String, agents: [AgentInfo]) -> (AgentInfo, String)? {
        for a in agents.sorted(by: { $0.name.count > $1.name.count }) {
            let tag = "@" + a.name
            guard let r = line.range(of: tag, options: .caseInsensitive) else { continue }
            if r.upperBound < line.endIndex, line[r.upperBound].isLetter || line[r.upperBound].isNumber { continue }
            var body = line
            body.removeSubrange(r)
            body = body.replacingOccurrences(of: "  ", with: " ").trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
            return (a, body)
        }
        return nil
    }

    /// "…@me" at the very end of the note -> "me"; "" right after "@"; nil when no "@" is being typed.
    static func partial(_ note: String) -> String? {
        guard let at = note.lastIndex(of: "@") else { return nil }
        if at > note.startIndex {
            let before = note[note.index(before: at)]
            guard before.isWhitespace || before.isNewline else { return nil }
        }
        let part = note[note.index(after: at)...]
        guard part.count <= 12, part.allSatisfy({ $0.isLetter || $0.isNumber }) else { return nil }
        return String(part)
    }
}

/// The agents list while "@" is being typed: figure, name, role.
private struct NotesMentionPicker: View {
    let agents: [AgentInfo]
    let partial: String?
    let pick: (AgentInfo) -> Void

    private var shown: [AgentInfo] {
        guard let p = partial?.lowercased() else { return [] }
        return p.isEmpty ? agents : agents.filter { $0.name.lowercased().hasPrefix(p) }
    }

    var body: some View {
        if !shown.isEmpty {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(shown) { a in row(a) }
            }
            .padding(4)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(WS.line2, lineWidth: 1))
            .accessibilityElement(children: .contain)
            .accessibilityLabel(Text("Agents"))
        }
    }

    private func row(_ a: AgentInfo) -> some View {
        Button { pick(a) } label: {
            HStack(spacing: 8) {
                AgentAvatar(agent: a, size: 20)
                Text(a.name).font(LiaFont.ui(12.5, .semibold)).foregroundStyle(WS.ink)
                Text(a.shownRole).font(LiaFont.ui(11.5)).foregroundStyle(WS.text3).lineLimit(1)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 8).frame(height: 28)
            .contentShape(Rectangle())
        }
        .buttonStyle(.liaPlain)
        .liaHover(.fill, radius: 8)
        .accessibilityLabel(Text("\(a.name), \(a.shownRole)"))
    }
}

/// The note's lines that name an agent: Send, or "Sent to Name \u{2713}" (opens that conversation).
private struct NotesMentionLines: View {
    let lines: [NoteMentions.Line]
    let sent: [String: String]
    let agent: (String) -> AgentInfo?
    let send: (NoteMentions.Line) -> Void
    let open: (String) -> Void

    var body: some View {
        if !lines.isEmpty {
            ScrollView {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(lines) { l in row(l) }
                }
            }
            .frame(maxHeight: 76)
        }
    }

    private func row(_ l: NoteMentions.Line) -> some View {
        let name = agent(l.agent)?.name ?? l.agent.capitalized
        return HStack(spacing: 6) {
            Text(l.text).font(LiaFont.ui(11.5)).foregroundStyle(WS.text2).lineLimit(1).truncationMode(.tail)
            Spacer(minLength: 4)
            if let to = sent[l.text] {
                let n = agent(to)?.name ?? to.capitalized
                Button { open(to) } label: {
                    Text("Sent to \(n) \u{2713}").font(LiaFont.ui(11, .semibold)).foregroundStyle(WS.green)
                        .padding(.horizontal, 8).frame(height: 22)
                        .background(WS.green.opacity(0.1), in: Capsule())
                        .contentShape(Capsule())
                }
                .buttonStyle(.liaPlain)
                .liaPointer()
                .accessibilityLabel(Text("Sent to \(n). Open the conversation"))
            } else {
                Button { send(l) } label: {
                    Text("Ask \(name)").font(LiaFont.ui(11, .semibold)).foregroundStyle(.white)
                        .padding(.horizontal, 9).frame(height: 22)
                        .background(WS.blue, in: Capsule())
                        .contentShape(Capsule())
                }
                .buttonStyle(.liaPlain)
                .liaPointer()
                .accessibilityLabel(Text("Open \(name) with this line in the message"))
            }
        }
    }
}

/// Closes the notes on a click anywhere outside the panel (and its own bar button, which toggles it itself) or on Esc.
/// Used from the main thread only (onAppear / onDisappear; AppKit calls local monitors on the main thread).
final class WSNotesOutside {
    /// The top bar's notes button, set by WSBarExtras: a click there is the button's own toggle.
    static let trigger = AnchorBox()
    private var monitors: [Any] = []

    func start(panel: AnchorBox, close: @escaping () -> Void) {
        stop()
        if let m = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown], handler: { e in
            MainActor.assumeIsolated {
                guard let w = panel.window, e.window === w else { return }
                let p = w.convertPoint(toScreen: e.locationInWindow)
                if panel.screenRect.contains(p) || WSNotesOutside.trigger.screenRect.contains(p) { return }
                // A dropdown or a popup over the window is not "outside the notes".
                if DropdownHost.shared.isOpen || LiaModalCenter.shared.isOpen { return }
                close()
            }
            return e
        }) { monitors.append(m) }
        if let m = NSEvent.addLocalMonitorForEvents(matching: .keyDown, handler: { e in
            let used: Bool = MainActor.assumeIsolated {
                guard e.keyCode == 53, let w = panel.window, e.window === w,
                      !DropdownHost.shared.isOpen, !LiaModalCenter.shared.isOpen else { return false }
                close()
                return true
            }
            return used ? nil : e
        }) { monitors.append(m) }
    }

    func stop() {
        for m in monitors { NSEvent.removeMonitor(m) }
        monitors.removeAll()
    }
}

/// The inline card under the notes' switch.
enum NotesCard: Equatable { case confirmSync, confirmPurge, showKey, enterKey }

/// The workspace's other synced notes (conflict copies, notes from the web or the phone): Add to note, Delete.
private struct NotesOtherList: View {
    let notes: [NoteLocal]
    let add: (String) -> Void
    let delete: (String) -> Void

    var body: some View {
        if !notes.isEmpty {
            VStack(alignment: .leading, spacing: 2) {
                Text("Other notes").font(LiaFont.ui(11, .semibold)).foregroundStyle(WS.text3)
                ScrollView {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(notes) { n in row(n) }
                    }
                }
                .frame(maxHeight: 78)
            }
        }
    }

    private func row(_ n: NoteLocal) -> some View {
        HStack(spacing: 6) {
            Text(n.name).font(LiaFont.ui(11.5)).foregroundStyle(WS.text2).lineLimit(1).truncationMode(.tail)
            Spacer(minLength: 4)
            Button("Add to note") { add(n.id) }
                .buttonStyle(.liaPlain).font(LiaFont.ui(11, .semibold)).foregroundStyle(WS.blue)
                .liaPointer()
                .liaTip("Add to the note and delete this copy")
            Button { delete(n.id) } label: {
                Image(systemName: "trash").font(.system(size: 10, weight: .semibold)).foregroundStyle(WS.text3)
                    .frame(width: 22, height: 22).contentShape(Rectangle())
            }
            .buttonStyle(.liaPlain)
            .liaHover(.icon, radius: 6)
            .accessibilityLabel(Text("Delete \(n.name)"))
        }
        .frame(height: 24)
    }
}
