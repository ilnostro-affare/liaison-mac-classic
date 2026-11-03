import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// Drag and drop between the dock and the page.
/// An agent dragged out of the dock carries the string "lia-agent:<id>". Dropped on the page (the page's own drop
/// target calls `DockDrop.handle`), it opens that agent's conversation and sends it the page in front.
/// Text, a link or a file dropped on an agent in the dock opens its conversation and sends "Look at this: ...".
enum DockDrop {
    static let prefix = "lia-agent:"
    /// What the dock's agents accept, and what a page drop target should register to receive an agent.
    static let types: [UTType] = [.fileURL, .url, .plainText, .utf8PlainText, .text]

    /// The drag item of an agent in the dock.
    static func provider(agent id: String) -> NSItemProvider {
        NSItemProvider(object: (prefix + id) as NSString)
    }

    /// For the page's drop target: an agent dropped on the page opens its conversation with the page as
    /// context. Returns false (and does nothing) when no provider can carry a string; true when one can (a string
    /// that turns out not to be an agent is ignored).
    @MainActor @discardableResult
    static func handle(_ providers: [NSItemProvider], ws: WorkspaceModel) -> Bool {
        guard let p = providers.first(where: { $0.canLoadObject(ofClass: NSString.self) }) else { return false }
        _ = p.loadObject(ofClass: NSString.self) { obj, _ in
            guard let s = obj as? NSString else { return }
            let str = s as String
            Task { @MainActor in
                guard let id = agentId(str) else { return }
                let url = ws.currentBrowser?.selected?.url?.absoluteString ?? ""
                await send(url.isEmpty ? "Look at this page." : "Look at this page: \(url)", to: id, ws: ws)
            }
        }
        return true
    }

    /// The agent's id in a dragged string ("lia-agent:met" -> "met"), nil for anything else.
    static func agentId(_ s: String) -> String? {
        guard s.hasPrefix(prefix) else { return nil }
        let id = String(s.dropFirst(prefix.count)).trimmingCharacters(in: .whitespacesAndNewlines)
        return id.isEmpty ? nil : id
    }

    /// Something dropped on agent `id` in the dock. A file sends its name, a link its address, text itself.
    @MainActor
    static func dropOnAgent(_ providers: [NSItemProvider], agent id: String, ws: WorkspaceModel) -> Bool {
        if let p = providers.first(where: { $0.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) }) {
            _ = p.loadObject(ofClass: URL.self) { url, _ in
                guard let url else { return }
                let name = url.lastPathComponent
                Task { @MainActor in await send("Look at this: \(name)", to: id, ws: ws) }
            }
            return true
        }
        if let p = providers.first(where: { $0.hasItemConformingToTypeIdentifier(UTType.url.identifier) }) {
            _ = p.loadObject(ofClass: URL.self) { url, _ in
                guard let url else { return }
                let s = url.absoluteString
                Task { @MainActor in await send("Look at this: \(s)", to: id, ws: ws) }
            }
            return true
        }
        if let p = providers.first(where: { $0.canLoadObject(ofClass: NSString.self) }) {
            _ = p.loadObject(ofClass: NSString.self) { obj, _ in
                guard let s = obj as? NSString else { return }
                let t = (s as String).trimmingCharacters(in: .whitespacesAndNewlines)
                // Another agent dragged onto this one: nothing to send.
                guard !t.isEmpty, agentId(t) == nil else { return }
                Task { @MainActor in await send("Look at this: \(t)", to: id, ws: ws) }
            }
            return true
        }
        return false
    }

    /// Opens the agent's dialogue and sends `text` as the person's message.
    @MainActor
    static func send(_ text: String, to id: String, ws: WorkspaceModel) async {
        ws.send(text, toAgent: id)
    }
}
