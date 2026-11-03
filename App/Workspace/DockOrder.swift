import SwiftUI
import UniformTypeIdentifiers

/// The person's order of the agents in the dock (Lia always first, outside it), kept on this Mac.
/// Agents the order does not know yet (new on the server) keep their roster place after the known ones.
enum DockOrder {
    static let key = "lia_dock_order"

    static func sorted(_ agents: [AgentInfo]) -> [AgentInfo] {
        let saved = UserDefaults.standard.stringArray(forKey: key) ?? []
        guard !saved.isEmpty else { return agents }
        let rank = Dictionary(saved.enumerated().map { ($1, $0) }, uniquingKeysWith: { a, _ in a })
        return agents.enumerated().sorted { a, b in
            let ra = rank[a.element.id] ?? saved.count + a.offset, rb = rank[b.element.id] ?? saved.count + b.offset
            return ra < rb
        }.map(\.element)
    }

    /// `id` moves to where `target` is (before it when coming from the right, after it when coming from the left).
    static func move(_ id: String, onto target: String, in agents: [AgentInfo]) {
        var ids = sorted(agents).map(\.id)
        guard id != target, let from = ids.firstIndex(of: id), let to = ids.firstIndex(of: target) else { return }
        ids.remove(at: from)
        ids.insert(id, at: to)
        UserDefaults.standard.set(ids, forKey: key)
    }

    static var isCustom: Bool { !(UserDefaults.standard.stringArray(forKey: key) ?? []).isEmpty }
    static func reset() { UserDefaults.standard.removeObject(forKey: key) }

    /// A drop on agent `target`: another agent (the dock's own drag) reorders; text, a link or a file goes to the
    /// Agent as before. `reordered` runs on the main actor after a move.
    @MainActor
    static func drop(_ providers: [NSItemProvider], on target: String, ws: WorkspaceModel, reordered: @escaping () -> Void) -> Bool {
        let carriesFile = providers.contains {
            $0.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) || $0.hasItemConformingToTypeIdentifier(UTType.url.identifier)
        }
        guard !carriesFile, let p = providers.first(where: { $0.canLoadObject(ofClass: NSString.self) }) else {
            return DockDrop.dropOnAgent(providers, agent: target, ws: ws)
        }
        _ = p.loadObject(ofClass: NSString.self) { obj, _ in
            guard let s = obj as? NSString else { return }
            let str = (s as String).trimmingCharacters(in: .whitespacesAndNewlines)
            Task { @MainActor in
                if let id = DockDrop.agentId(str) {
                    guard let a = ws.agent(id), let t = ws.agent(target), !a.lead, !t.lead else { return }
                    move(id, onto: target, in: ws.roster.filter { !$0.lead })
                    reordered()
                } else if !str.isEmpty {
                    await DockDrop.send("Look at this: \(str)", to: target, ws: ws)
                }
            }
        }
        return true
    }
}
