import Foundation
import Combine

/// Chats and projects for the drawer (GET /intelligence/state).
@MainActor
final class LibraryStore: ObservableObject {
    @Published private(set) var state: LiaState?
    @Published private(set) var errorText: String?
    @Published private(set) var accounts: [AdAccount] = []
    /// Name and letter are cached so the avatar never waits for the network on launch.
    @Published private(set) var profile: MemberProfile?
    @Published private(set) var relayUnread = 0
    @Published private(set) var cachedLetter: String = UserDefaults.standard.string(forKey: "lia_profile_letter") ?? ""
    private var accountsLoaded = false
    private let auth: AuthStore

    init(auth: AuthStore) { self.auth = auth }

    var projects: [ProjectSummary] { state?.projects ?? [] }
    var pinned: [ChatSummary] { state?.sortedChats.filter(\.starred) ?? [] }
    var recents: [ChatSummary] { state?.sortedChats.filter { !$0.starred } ?? [] }

    func project(_ id: String?) -> ProjectSummary? {
        guard let id else { return nil }
        return projects.first { $0.id == id }
    }

    /// A project's last activity: its newest chat.
    func projectUpdated(_ id: String) -> Double? {
        state?.chats.filter { $0.project == id }.compactMap(\.updated).max()
    }

    func chats(inProject id: String) -> [ChatSummary] {
        state?.sortedChats.filter { $0.project == id } ?? []
    }

    /// Ad accounts for the chat chip. An empty answer is never cached (ai.js: an expired session
    /// answers with an empty list, and remembering it kept the picker dead for the whole session).
    func loadAccounts(force: Bool = false) async {
        if accountsLoaded && !force { return }
        if let list = try? await LiaAPI(auth: auth).adAccounts(), !list.isEmpty {
            accounts = list
            accountsLoaded = true
        }
    }

    func loadProfile() async {
        guard let p = await LiaAPI(auth: auth).memberProfile() else { return }
        profile = p
        if !p.email.isEmpty { auth.rememberEmail(p.email) }
        cachedLetter = p.letter
        UserDefaults.standard.set(p.letter, forKey: "lia_profile_letter")
        ChatMeFace.store(p)
        // The person's colour and photo, then the workspaces' pictures, from the server.
        AvatarStore.shared.setPerson(id: p.id, email: p.email)
        let a = auth
        Task { await AvatarStore.shared.refresh(auth: a) }
    }

    func apply(profile p: MemberProfile) {
        profile = p
        cachedLetter = p.letter
        UserDefaults.standard.set(p.letter, forKey: "lia_profile_letter")
        ChatMeFace.store(p)
        AvatarStore.shared.setPerson(id: p.id, email: p.email)
    }

    func forgetProfile() {
        profile = nil
        cachedLetter = ""
        UserDefaults.standard.removeObject(forKey: "lia_profile_letter")
        ChatMeFace.store(nil)
        AvatarStore.shared.setPerson(id: nil, email: nil)
    }

    var avatarLetter: String { profile?.letter ?? (cachedLetter.isEmpty ? "" : cachedLetter) }

    func loadRelayUnread() async {
        if let dir = try? await LiaAPI(auth: auth).relayDirectory() {
            relayUnread = RelayDirectory.unread(in: nil, projects: dir.projects)
        }
    }

    func reload() async {
        do {
            state = try await LiaAPI(auth: auth).state()
            errorText = nil
        } catch {
            errorText = userMessage(for: error)
        }
    }
}
