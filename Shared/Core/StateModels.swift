import Foundation

// Shapes read from the server: index entry { id, title, project, starred, updated },
// project { id, name, account }. Everything but id is optional: a missing field must not
// throw away the whole list (a chat saved before a field existed still has to show).
struct ChatSummary: Decodable, Identifiable, Hashable {
    let id: String
    let title: String?
    let project: String?
    let starred: Bool
    let updated: Double?

    enum CodingKeys: String, CodingKey { case id, title, project, starred, updated }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        title = try? c.decodeIfPresent(String.self, forKey: .title)
        project = try? c.decodeIfPresent(String.self, forKey: .project)
        starred = ((try? c.decodeIfPresent(Bool.self, forKey: .starred)) ?? nil) ?? false
        if let n = try? c.decodeIfPresent(Double.self, forKey: .updated) {
            updated = n
        } else if let s = try? c.decodeIfPresent(String.self, forKey: .updated), let n = Double(s) {
            updated = n
        } else {
            updated = nil
        }
    }

    var displayTitle: String {
        let t = (title ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? "Untitled chat" : t
    }
}

struct ProjectSummary: Decodable, Identifiable, Hashable {
    let id: String
    let name: String
    /// Ad account id the project is bound to; sent as `account` with every turn in this project.
    let account: String?

    enum CodingKeys: String, CodingKey { case id, name, account }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = ((try? c.decodeIfPresent(String.self, forKey: .name)) ?? nil) ?? "Project"
        if let s = try? c.decodeIfPresent(String.self, forKey: .account) {
            account = s
        } else if let n = try? c.decodeIfPresent(Int64.self, forKey: .account) {
            account = String(n)
        } else {
            account = nil
        }
    }
}

struct LiaState: Decodable {
    let chats: [ChatSummary]
    let projects: [ProjectSummary]

    enum CodingKeys: String, CodingKey { case ok, chats, projects }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        guard (try? c.decode(Bool.self, forKey: .ok)) == true else {
            throw DecodingError.dataCorruptedError(forKey: .ok, in: c, debugDescription: "state not ok")
        }
        // One broken record must not drop the whole list.
        chats = ((try? c.decode([Lossy<ChatSummary>].self, forKey: .chats)) ?? []).compactMap(\.value)
        projects = ((try? c.decode([Lossy<ProjectSummary>].self, forKey: .projects)) ?? []).compactMap(\.value)
    }

    /// Pinned (starred) first, then most recently updated.
    var sortedChats: [ChatSummary] {
        chats.sorted { a, b in
            if a.starred != b.starred { return a.starred }
            return (a.updated ?? 0) > (b.updated ?? 0)
        }
    }
}

struct Lossy<T: Decodable>: Decodable {
    let value: T?
    init(from decoder: Decoder) throws { value = try? T(from: decoder) }
}
