import SwiftUI
import UserNotifications

/// A message the person asked to send later, or a reminder of it (kept on this Mac, `lia_ws_scheduled`).
struct ChatScheduled: Codable, Identifiable, Equatable {
    enum Kind: String, Codable { case send, remind }
    var id: String = UUID().uuidString
    var thread: String
    var text: String
    var at: Date
    var kind: Kind
    /// Files already uploaded (R2 keys), sent with the message when it goes. Older saves have none.
    var files: [StoredFile]? = nil

    struct StoredFile: Codable, Equatable { let key: String; let kind: String; let name: String; let mime: String; let bytes: Int }
    var attachments: [ChatAttachment] {
        (files ?? []).map { ChatAttachment(key: $0.key, kind: $0.kind, name: $0.name, mime: $0.mime, bytes: $0.bytes) }
    }

    /// "9:00", "Tomorrow 9:00", "Oct 14, 9:00".
    var when: String { ChatScheduled.label(at) }

    static func label(_ d: Date) -> String {
        let time = d.formatted(date: .omitted, time: .shortened)
        let cal = Calendar.current
        if cal.isDateInToday(d) { return time }
        if cal.isDateInTomorrow(d) { return "Tomorrow " + time }
        return d.formatted(.dateTime.month(.abbreviated).day()) + ", " + time
    }

    /// The presets of the Send Later menu.
    static var inAnHour: Date { Date().addingTimeInterval(3600) }
    static var tomorrowNine: Date {
        let cal = Calendar.current
        let tomorrow = cal.date(byAdding: .day, value: 1, to: Date()) ?? Date().addingTimeInterval(86_400)
        return cal.date(bySettingHour: 9, minute: 0, second: 0, of: tomorrow) ?? tomorrow
    }
}

/// The scheduled messages of every conversation. A timer (started by the dock) sends each one when its time
/// comes while the app runs; one that came due while the app was closed goes at the next launch, with a toast.
/// A reminder is a local notification the system delivers at its time (the app may be closed).
@MainActor
final class ChatScheduler: ObservableObject {
    static let shared = ChatScheduler()
    static let key = "lia_ws_scheduled"

    @Published private(set) var items: [ChatScheduled] = []
    private var timer: Timer?
    private weak var ws: WorkspaceModel?

    private init() {
        if let d = UserDefaults.standard.data(forKey: Self.key), let list = try? JSONDecoder().decode([ChatScheduled].self, from: d) {
            items = list
        }
    }

    func pending(in thread: String) -> [ChatScheduled] {
        items.filter { $0.thread == thread }.sorted { $0.at < $1.at }
    }

    /// Called by the workspace's dock when it appears: the window that sends what comes due.
    func start(_ ws: WorkspaceModel) {
        self.ws = ws
        if timer == nil {
            let t = Timer(timeInterval: 15, repeats: true) { _ in
                Task { @MainActor in ChatScheduler.shared.tick() }
            }
            RunLoop.main.add(t, forMode: .common)
            timer = t
        }
        tick()
    }

    func add(_ text: String, thread: String, at: Date, kind: ChatScheduled.Kind, attachments: [ChatAttachment] = []) {
        var t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.isEmpty && !attachments.isEmpty { t = "See the attached file(s)." }
        guard !t.isEmpty else { return }
        var s = ChatScheduled(thread: thread, text: t, at: max(at, Date().addingTimeInterval(30)), kind: kind)
        if !attachments.isEmpty {
            s.files = attachments.map { StoredFileOf($0) }
        }
        items.append(s)
        save()
        if kind == .remind { ChatReminder.schedule(s) }
        let what = kind == .send ? "Scheduled for " : "Reminder set for "
        ws?.show(what + s.when, symbol: kind == .send ? "clock" : "bell")
        ChatA11y.announce(what + s.when)
    }

    func cancel(_ s: ChatScheduled) {
        items.removeAll { $0.id == s.id }
        save()
        if s.kind == .remind { ChatReminder.cancel(s) }
    }

    /// Sends what came due. A message whose conversation is not in this window yet waits for it.
    func tick() {
        guard let ws else { return }
        let now = Date()
        for s in items where s.at <= now {
            switch s.kind {
            case .remind:
                drop(s)
                // In front the system shows nothing (Notifier's delegate), so the window says it.
                if NSApp.isActive, now.timeIntervalSince(s.at) < 120 { ws.show("Reminder: " + String(s.text.prefix(80)), symbol: "bell") }
            case .send:
                // `thread` is the dialogue's key ("profile|dlg"); one scheduled in a thread before dialogues has no
                // dialogue to go to and is dropped (the person is told).
                guard s.thread.contains("|") else {
                    drop(s)
                    ws.show("A message scheduled in an old conversation was not sent", symbol: "exclamationmark.bubble")
                    continue
                }
                guard let chat = ws.chat(key: s.thread) else { continue }
                drop(s)
                let late = now.timeIntervalSince(s.at) > 90
                Task { @MainActor in
                    await chat.load()
                    chat.send(s.text, attachments: s.attachments)
                }
                if late { ws.show("Sent the message scheduled for " + s.at.formatted(date: .omitted, time: .shortened), symbol: "paperplane") }
            }
        }
    }

    private func drop(_ s: ChatScheduled) {
        items.removeAll { $0.id == s.id }
        save()
    }

    private func save() {
        if let d = try? JSONEncoder().encode(items) { UserDefaults.standard.set(d, forKey: Self.key) }
    }
}

/// "Remind Me": a local notification at the chosen time with the message; a click opens the conversation
/// (Notifier's delegate reads "thread").
enum ChatReminder {
    static func schedule(_ s: ChatScheduled) {
        let c = UNUserNotificationCenter.current()
        c.requestAuthorization(options: [.alert, .sound]) { ok, _ in
            guard ok else { return }
            let n = UNMutableNotificationContent()
            n.title = "Reminder"
            n.body = String(s.text.prefix(240))
            n.sound = .default
            n.userInfo = ["thread": s.thread]
            let parts = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute, .second], from: s.at)
            let trigger = UNCalendarNotificationTrigger(dateMatching: parts, repeats: false)
            c.add(UNNotificationRequest(identifier: "lia.remind." + s.id, content: n, trigger: trigger))
        }
    }

    static func cancel(_ s: ChatScheduled) {
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: ["lia.remind." + s.id])
    }
}

/// What the Send button's context menu offers.
struct ChatSendLaterMenu: View {
    let enabled: Bool
    let onPick: (Date, ChatScheduled.Kind) -> Void
    let onCustom: (ChatScheduled.Kind) -> Void

    var body: some View {
        Group {
            Button("Send in 1 Hour") { onPick(ChatScheduled.inAnHour, .send) }
            Button("Send Tomorrow at 9:00") { onPick(ChatScheduled.tomorrowNine, .send) }
            Button("Send Later\u{2026}") { onCustom(.send) }
            Divider()
            Button("Remind Me in 1 Hour") { onPick(ChatScheduled.inAnHour, .remind) }
            Button("Remind Me Tomorrow at 9:00") { onPick(ChatScheduled.tomorrowNine, .remind) }
            Button("Remind Me\u{2026}") { onCustom(.remind) }
        }
        .disabled(!enabled)
    }
}

/// A custom time for Send Later / Remind Me.
struct ChatSendLaterPicker: View {
    @State var kind: ChatScheduled.Kind
    @State private var date = ChatScheduled.tomorrowNine
    let onSchedule: (Date, ChatScheduled.Kind) -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Picker("", selection: $kind) {
                Text("Send").tag(ChatScheduled.Kind.send)
                Text("Remind me").tag(ChatScheduled.Kind.remind)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .accessibilityLabel(Text("Send the message or remind me"))
            DatePicker("Time", selection: $date, in: Date()..., displayedComponents: [.date, .hourAndMinute])
                .datePickerStyle(.graphical)
                .labelsHidden()
            Text(kind == .send ? "Sends while Liaison is open (or when it next opens)." : "A notification with this message.")
                .font(LiaFont.ui(11.5)).foregroundStyle(WS.text3)
            HStack {
                Spacer()
                Button("Cancel", action: onCancel).buttonStyle(WSButtonStyle(small: true))
                Button(kind == .send ? "Schedule" : "Remind Me") { onSchedule(date, kind) }
                    .buttonStyle(WSButtonStyle(primary: true, small: true))
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(14)
        .frame(width: 300)
    }
}

/// A scheduled message in the thread: "Scheduled \u{00b7} 9:00" with Edit and Cancel.
struct ChatScheduledBubble: View {
    let item: ChatScheduled
    let onEdit: () -> Void
    let onCancel: () -> Void

    var body: some View {
        HStack {
            Spacer(minLength: 70)
            VStack(alignment: .trailing, spacing: 4) {
                Text(item.text).font(LiaFont.ui(14)).foregroundStyle(WS.ink).lineLimit(4)
                    .padding(.horizontal, 14).padding(.vertical, 9)
                    .background(RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .strokeBorder(WS.ink.opacity(0.35), style: StrokeStyle(lineWidth: 1, dash: [4, 3])))
                HStack(spacing: 8) {
                    Label(caption, systemImage: item.kind == .send ? "clock" : "bell")
                        .font(LiaFont.ui(11.5, .medium)).foregroundStyle(WS.text2)
                    Button("Edit", action: onEdit).buttonStyle(.liaPlain).font(LiaFont.ui(11.5, .semibold)).foregroundStyle(WS.ink).liaPointer()
                    Button("Cancel", action: onCancel).buttonStyle(.liaPlain).font(LiaFont.ui(11.5, .semibold)).foregroundStyle(WS.bad).liaPointer()
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("\(caption): \(item.text)"))
        .accessibilityAction(named: Text("Edit"), onEdit)
        .accessibilityAction(named: Text("Cancel"), onCancel)
    }

    private var caption: String { (item.kind == .send ? "Scheduled \u{00b7} " : "Reminder \u{00b7} ") + item.when }
}

private func StoredFileOf(_ a: ChatAttachment) -> ChatScheduled.StoredFile {
    ChatScheduled.StoredFile(key: a.key, kind: a.kind, name: a.name, mime: a.mime, bytes: a.bytes)
}
