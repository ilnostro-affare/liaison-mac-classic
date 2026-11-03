import SwiftUI

/// One namespace for the window, so an agent's figure in the dock and the same figure in the open
/// conversation's header are one element (matchedGeometryEffect): opening a conversation, it flies up.
private struct WSHeroNamespaceKey: EnvironmentKey { static let defaultValue: Namespace.ID? = nil }

extension EnvironmentValues {
    var wsHero: Namespace.ID? {
        get { self[WSHeroNamespaceKey.self] }
        set { self[WSHeroNamespaceKey.self] = newValue }
    }
}

extension View {
    /// The figure of `agent` takes part in the dock ⇄ header flight when a namespace is set; `source` marks the one
    /// on screen that leads (the header while its conversation is open, the dock otherwise).
    @ViewBuilder func wsHero(_ agent: String, source: Bool, in ns: Namespace.ID?) -> some View {
        if let ns { matchedGeometryEffect(id: "hero-" + agent, in: ns, properties: .frame, isSource: source) } else { self }
    }
}
