import AppKit
import CoreServices
import Intents
import os
import Security
import UserNotifications

/// (/03): macOS notifications while the window is in the background: an agent needs a Yes, an agent
/// finished. Each kind can be turned off in Settings (Prefs); the system's Focus and notification settings apply.
/// A click on one opens its conversation.
/// Posted only for a stored message that needs the person (AgentAttention: an approval card, a final
/// answer or a question in the agent's own dialogue), never for activity lines or an acknowledgement; the body is the
/// message's own first words. The icon macOS draws is the bundle's AppIcon (icon C, Resources/Assets.xcassets) of the
/// copy Launch Services prefers for com.liaisone.mac (logIconCopies); an agent's own notification carries its mascot
/// (AgentPush).
@MainActor
enum Notifier {
    enum Kind { case approval, done }

    private static var asked = false
    private static let delegate = NotifierDelegate()

    /// At launch: a click on a notification from an earlier run still opens its conversation.
    static func setUp() {
        UNUserNotificationCenter.current().delegate = delegate
        // The notification's icon is the one Launch Services holds for the app: a release with a new AppIcon could still
        // show the old one until the bundle is registered again (the Dock reads the bundle, Notification Center the cache).
        _ = LSRegisterURL(Bundle.main.bundleURL as CFURL, true)
        logIconCopies()
    }

    private static let log = Logger(subsystem: "com.liaisone.mac", category: "notify")

    /// (notifications with the old logo): Notification Center draws the icon of the copy Launch Services
    /// prefers for the bundle id, not of the copy that posted. Liaison and Liaison Dev share com.liaisone.mac and the
    /// release carries the higher CFBundleVersion (a UTC build number; a Dev build's is 1), so a Dev build's banners
    /// show the icon of /Applications/Liaison.app, whatever it is. Logged at launch so the cause can be read in
    /// Console (subsystem com.liaisone.mac, category notify).
    private static func logIconCopies() {
        guard let id = Bundle.main.bundleIdentifier else { return }
        let copies = NSWorkspace.shared.urlsForApplications(withBundleIdentifier: id)
        guard copies.count > 1 else { return }
        let me = Bundle.main.bundleURL.standardizedFileURL
        let list = copies.map { u -> String in
            let b = Bundle(url: u)
            let v = (b?.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?") + " ("
                + (b?.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?") + ")"
            return (u.standardizedFileURL == me ? "* " : "") + u.path + " " + v
        }.joined(separator: "; ")
        log.notice("\(copies.count) copies registered for \(id, privacy: .public); banners use the preferred one's icon: \(list, privacy: .public)")
    }

    /// The notification's body: the message's first line, plain, at most 140 characters.
    nonisolated static func snippet(_ text: String?) -> String? {
        guard let t = text?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty else { return nil }
        let line = t.split(whereSeparator: \.isNewline).first.map(String.init) ?? t
        let plain = line.replacingOccurrences(of: "**", with: "").replacingOccurrences(of: "`", with: "")
            .trimmingCharacters(in: CharacterSet(charactersIn: "#>*- ").union(.whitespaces))
        guard !plain.isEmpty else { return nil }
        return plain.count > 140 ? String(plain.prefix(139)) + "\u{2026}" : plain
    }

    static func post(_ kind: Kind, agent: String, agentId: String? = nil, client: String?, dialogue: String, text: String? = nil) {
        guard !NSApp.isActive, !Prefs.flag("lia_notify_dnd", default: false) else { return }
        if kind == .done, let id = agentId, !Prefs.flag("lia_notify_agent_" + id) { return }
        switch kind {
        case .approval: guard Prefs.flag(Prefs.notifyApprovals) else { return }
        case .done: guard Prefs.flag(Prefs.notifyDone) else { return }
        }
        let c = UNUserNotificationCenter.current()
        c.delegate = delegate
        let send = {
            let n = UNMutableNotificationContent()
            n.title = kind == .approval ? "\(agent) needs your Yes" : agent
            if let client { n.subtitle = client }
            n.body = kind == .approval ? (snippet(text) ?? "A change is ready to approve.")
                                       : (snippet(text) ?? "The answer is in the conversation.")
            n.threadIdentifier = client ?? "liaison"   // grouped by workspace
            n.userInfo = ["dialogue": dialogue]
            if kind == .approval { n.sound = .default }
            let content = AgentPush.content(n, kind: kind, agent: agent, agentId: agentId, client: client, dialogue: dialogue)
            c.add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
        }
        if asked { send(); return }
        c.requestAuthorization(options: [.alert, .sound, .badge]) { ok, _ in
            Task { @MainActor in asked = true; if ok { send() } }
        }
    }
}

extension Notifier {
    /// An update is downloaded while the app is in the background and could not install by itself (work was
    /// in progress). Once per version (Updates); a click brings the app to the front, where the banner has Restart.
    static func postUpdate(version: String) {
        guard !NSApp.isActive, !Prefs.flag("lia_notify_dnd", default: false) else { return }
        let c = UNUserNotificationCenter.current()
        c.requestAuthorization(options: [.alert, .sound, .badge]) { ok, _ in
            guard ok else { return }
            let n = UNMutableNotificationContent()
            n.title = "Restart, a new update is out"
            n.body = "Liaison \(version) is ready. Restart when you finish what you are doing."
            n.threadIdentifier = "liaison-update"
            n.userInfo = ["update": version]
            c.add(UNNotificationRequest(identifier: "liaison-update-" + version, content: n, trigger: nil))
        }
    }
}

/// (each agent's notifications with that agent's mascot). The banner's left icon is always the app's
/// own (the cloud with the agents, AppIcon) and cannot change per notification. What can:
/// A communication notification (INSendMessageIntent, macOS 12+): the agent becomes the sender, its mascot the
/// avatar, the app icon a small badge on it (as Messages and Slack). Needs the Communication Notifications
/// capability (entitlement com.apple.developer.usernotifications.communication, in the provisioning profile) and
/// NSUserActivityTypes [INSendMessageIntent] in Info.plist; both are read at run time.
/// Otherwise an attachment: the mascot as the thumbnail on the right.
/// General notifications (an update) stay plain: the app icon is the cloud logo with every agent.
@MainActor
enum AgentPush {
    static let entitlement = "com.apple.developer.usernotifications.communication"
    private static let log = Logger(subsystem: "com.liaisone.mac", category: "notify")

    /// The communication style is possible in this build: the entitlement is signed in and the intent is declared.
    static let communication: Bool = {
        let declared = (Bundle.main.object(forInfoDictionaryKey: "NSUserActivityTypes") as? [String])?.contains("INSendMessageIntent") ?? false
        guard declared, let task = SecTaskCreateFromSelf(nil) else { return false }
        let v = SecTaskCopyValueForEntitlement(task, entitlement as CFString, nil)
        return (v as? Bool) == true
    }()

    private static var avatars: [String: Data] = [:]

    static func content(_ n: UNMutableNotificationContent, kind: Notifier.Kind, agent: String, agentId: String?,
                        client: String?, dialogue: String) -> UNNotificationContent {
        guard let id = agentId, let png = avatar(id) else { return n }
        if communication {
            // The sender's name is the banner's title; what the agent wants goes in the subtitle.
            let what = kind == .approval ? "Needs your Yes" : nil
            n.subtitle = [what, client].compactMap { $0 }.joined(separator: " \u{00B7} ")
            let image = INImage(imageData: png)
            let sender = INPerson(personHandle: INPersonHandle(value: "agent:" + id, type: .unknown), nameComponents: nil,
                                  displayName: agent, image: image, contactIdentifier: nil, customIdentifier: "agent:" + id)
            let intent = INSendMessageIntent(recipients: nil, outgoingMessageType: .outgoingMessageText, content: n.body,
                                             speakableGroupName: nil, conversationIdentifier: dialogue, serviceName: nil,
                                             sender: sender, attachments: nil)
            // (setImage(_:forParameterNamed:) is iOS-only; on macOS the sender's INPerson carries the avatar)
            let interaction = INInteraction(intent: intent, response: nil)
            interaction.direction = .incoming
            interaction.donate { error in if let error { log.error("donate: \(error.localizedDescription, privacy: .public)") } }
            do { return try n.updating(from: intent) } catch {
                log.error("communication style refused: \(error.localizedDescription, privacy: .public)")
                n.title = kind == .approval ? "\(agent) needs your Yes" : agent
                n.subtitle = client ?? ""
            }
        }
        if let a = attachment(id, png) { n.attachments = [a] }
        return n
    }

    /// The mascot on a soft disc of its own colour, 256 px PNG (light drawing, the avatar is shown in a circle).
    static func avatar(_ id: String) -> Data? {
        if let d = avatars[id] { return d }
        let info = WorkspaceModel.current?.agent(id) ?? AgentInfo.fallback.first { $0.id == id }
        let hex = info?.colorHex ?? 0x1F2430
        let side: CGFloat = 256
        let img = NSImage(size: NSSize(width: side, height: side), flipped: false) { r in
            NSColor.white.setFill()
            NSBezierPath(ovalIn: r).fill()
            NSColor(srgbHex: hex).withAlphaComponent(0.14).setFill()
            NSBezierPath(ovalIn: r).fill()
            // The landing's mascot artwork (Assets push-<id>, rendered from site/browser/assets/cloud-icon.svg); an
            // agent without one gets the app's own drawn figure.
            if let art = NSImage(named: "push-" + id) {
                art.draw(in: r.insetBy(dx: side * 0.13, dy: side * 0.13))
            } else {
                var figure: NSImage?
                NSAppearance(named: .aqua)?.performAsCurrentDrawingAppearance {
                    figure = AgentBlotImage.image(id, color: hex, u: 0, size: side * 0.64)
                }
                figure?.draw(in: r.insetBy(dx: side * 0.18, dy: side * 0.18))
            }
            return true
        }
        guard let cg = img.cgImage(forProposedRect: nil, context: nil, hints: nil),
              let d = NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:]) else { return nil }
        avatars[id] = d
        return d
    }

    /// A fresh file per notification: the system moves an attachment's file into its own store.
    private static func attachment(_ id: String, _ png: Data) -> UNNotificationAttachment? {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("lia-push", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("\(id)-\(UUID().uuidString).png")
        guard (try? png.write(to: url)) != nil else { return nil }
        return try? UNNotificationAttachment(identifier: "agent-" + id, url: url,
                                             options: [UNNotificationAttachmentOptionsTypeHintKey: "public.png"])
    }
}

private final class NotifierDelegate: NSObject, UNUserNotificationCenterDelegate {
    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        let info = response.notification.request.content.userInfo
        // "thread" is a scheduled reminder made before dialogues (its key is a "profile|dlg" now too).
        let key = (info["dialogue"] as? String) ?? (info["thread"] as? String)
        Task { @MainActor in
            NSApp.activate(ignoringOtherApps: true)
            if let key { WorkspaceModel.current?.openDialogue(key: key) }
            completionHandler()
        }
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([])   // in front: the window shows it already
    }
}
