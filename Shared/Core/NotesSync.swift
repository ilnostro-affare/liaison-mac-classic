import Foundation

// Notes that sync between the person's devices, end-to-end encrypted. The pure half: the
// envelope, the plaintext, the recovery key, the wire, and the merge rules. The cipher itself (CryptoKit AES-GCM) and
// the Keychain live in App/Workspace/NotesCrypto.swift and come in through `NotesCipher`, so all of this runs in the
// Linux tests. The format is a format shared with the web and iPhone clients; the server is the notes server.

enum NotesSyncMode: String, Equatable { case local, synced }

/// What the notes panel says about the cloud, small and quiet.
enum NotesSyncStatus: Equatable {
    case off, syncing, synced, offline, needsKey, error(String)

    var line: String {
        switch self {
        case .off: return "Saved on this Mac as you type."
        case .syncing: return "Syncing\u{2026}"
        case .synced: return "Synced"
        case .offline: return "Offline. Saved on this Mac; it syncs when you are back."
        case .needsKey: return "Enter your recovery key to sync on this Mac."
        case .error(let m): return m
        }
    }
}

enum NotesKeys {
    /// The Mac's panel is one text per workspace: this note.
    static let mainId = "main"
    static let kidLabel = "liaison-notes-kid-v1"
    static let keychainService = "com.liaisone.mac.notes-key"
    /// The panel's text (unchanged: it is the local copy in either mode).
    static func text(_ ws: String) -> String { "lia_ws_notes_" + ws }
    /// The sync mode and state are the member's (two accounts on one Mac never share them). The keys
    /// had the workspace only; `adoptLegacy` moves them under the member once.
    static func mode(_ ws: String, member: String) -> String { "lia_ws_notes_mode_\(member)_\(ws)" }
    static func state(_ ws: String, member: String) -> String { "lia_ws_notes_sync_\(member)_\(ws)" }
    static func legacyMode(_ ws: String) -> String { "lia_ws_notes_mode_" + ws }
    static func legacyState(_ ws: String) -> String { "lia_ws_notes_sync_" + ws }

    /// Moves per-workspace keys under `member`, once (the first member to open the workspace on this Mac
    /// after the update takes them; a key already there wins and the old one is dropped).
    static func adoptLegacy(_ d: UserDefaults, member: String, ws: String) {
        guard !member.isEmpty else { return }
        for (old, new) in [(legacyMode(ws), mode(ws, member: member)), (legacyState(ws), state(ws, member: member))] {
            guard let v = d.object(forKey: old) else { continue }
            if d.object(forKey: new) == nil { d.set(v, forKey: new) }
            d.removeObject(forKey: old)
        }
    }
    /// The server's key for a note (the notes server notesKey): one key per note.
    static func server(member: String, ws: String, id: String) -> String { "notes:\(member):\(ws):\(id)" }

    static func isId(_ s: String) -> Bool {
        !s.isEmpty && s.count <= 64 && s.unicodeScalars.allSatisfy { ($0.isASCII && (CharacterSet.alphanumerics.contains($0))) || $0 == "-" || $0 == "_" }
    }
    /// A new note's id: "n_" and 20 random letters and digits.
    static func newId() -> String {
        let a = Array("abcdefghijklmnopqrstuvwxyz0123456789")
        return "n_" + String((0..<20).map { _ in a[Int.random(in: 0..<a.count)] })
    }
}

// MARK: envelope and plaintext

struct NoteEnvelope: Equatable {
    static let version = 1
    static let alg = "A256GCM"
    let kid: String
    let nonce: Data
    let ct: Data

    var json: JSONObject {
        ["v": Self.version, "alg": Self.alg, "kid": kid, "n": nonce.base64EncodedString(), "ct": ct.base64EncodedString()]
    }

    static func isKid(_ s: String) -> Bool { s.count == 16 && s.allSatisfy { $0.isHexDigit && !$0.isUppercase } }

    /// The server's own check (the notes server notesEnvelope): v 1, A256GCM, 16-hex kid, 12-byte nonce, ct with its tag.
    static func parse(_ any: Any?) -> NoteEnvelope? {
        guard let o = any as? JSONObject, JSONRead.int(o, "v") == version, JSONRead.string(o, "alg") == alg,
              let kid = o["kid"] as? String, isKid(kid),
              let ns = o["n"] as? String, let n = Data(base64Encoded: ns), n.count == 12,
              let cs = o["ct"] as? String, let c = Data(base64Encoded: cs), c.count >= 16 else { return nil }
        return NoteEnvelope(kid: kid, nonce: n, ct: c)
    }
}

struct NotePlain: Equatable {
    var title: String
    var body: String
    var u: Int

    func encoded() -> Data {
        (try? JSONSerialization.data(withJSONObject: ["title": title, "body": body, "u": u], options: [.sortedKeys])) ?? Data()
    }

    static func decode(_ d: Data) -> NotePlain? {
        guard let o = JSONRead.object(d), let b = o["body"] as? String else { return nil }
        return NotePlain(title: (o["title"] as? String) ?? "", body: b, u: JSONRead.int(o, "u") ?? 0)
    }
}

/// AES-256-GCM, injected: CryptoKit on the Mac, a fake in the Linux tests. `ct` is ciphertext followed by the 16-byte tag.
protocol NotesCipher {
    func seal(_ plaintext: Data, key: Data, aad: Data) throws -> (nonce: Data, ct: Data)
    func open(nonce: Data, ct: Data, key: Data, aad: Data) throws -> Data
}

enum NotesCrypto {
    /// Binds a ciphertext to its workspace and note: moved anywhere else it does not open.
    static func aad(ws: String, id: String) -> Data { Data("liaison-notes:v1:\(ws):\(id)".utf8) }

    static func seal(_ p: NotePlain, ws: String, id: String, key: Data, kid: String, cipher: NotesCipher) throws -> NoteEnvelope {
        let s = try cipher.seal(p.encoded(), key: key, aad: aad(ws: ws, id: id))
        return NoteEnvelope(kid: kid, nonce: s.nonce, ct: s.ct)
    }

    /// nil: another key, a moved or altered ciphertext, or not a note.
    static func open(_ e: NoteEnvelope, ws: String, id: String, key: Data, kid: String, cipher: NotesCipher) -> NotePlain? {
        guard e.kid == kid, let d = try? cipher.open(nonce: e.nonce, ct: e.ct, key: key, aad: aad(ws: ws, id: id)) else { return nil }
        return NotePlain.decode(d)
    }

    /// The bytes the key's fingerprint is hashed from: SHA-256 of these, first 8 bytes, lowercase hex.
    static func kidInput(_ key: Data) -> Data { Data(NotesKeys.kidLabel.utf8) + key }

    static func hex(_ d: Data) -> String { d.map { String(format: "%02x", $0) }.joined() }
}

// MARK: recovery key (LIA1- + base32 of key + CRC-16/CCITT-FALSE, groups of five)

enum NotesRecoveryKey {
    private static let alphabet = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZ234567")

    static func crc16(_ d: Data) -> UInt16 {
        var c: UInt16 = 0xFFFF
        for b in d {
            c ^= UInt16(b) << 8
            for _ in 0..<8 { c = (c & 0x8000) != 0 ? (c << 1) ^ 0x1021 : c << 1 }
        }
        return c
    }

    static func encode(_ key: Data) -> String {
        let c = crc16(key)
        var all = key
        all.append(UInt8(c >> 8)); all.append(UInt8(c & 0xFF))
        var out = "", bits = 0, v: UInt32 = 0
        for b in all {
            v = (v << 8) | UInt32(b); bits += 8
            while bits >= 5 { out.append(alphabet[Int((v >> UInt32(bits - 5)) & 31)]); bits -= 5 }
            v &= (1 << UInt32(bits)) - 1
        }
        if bits > 0 { out.append(alphabet[Int((v << UInt32(5 - bits)) & 31)]) }
        var groups: [String] = []
        var i = out.startIndex
        while i < out.endIndex {
            let j = out.index(i, offsetBy: 5, limitedBy: out.endIndex) ?? out.endIndex
            groups.append(String(out[i..<j])); i = j
        }
        return "LIA1-" + groups.joined(separator: "-")
    }

    /// The 32 key bytes, or nil (not a recovery key, a typo the checksum catches).
    static func decode(_ s: String) -> Data? {
        var t = s.uppercased().filter { !$0.isWhitespace && $0 != "-" }
        guard t.hasPrefix("LIA1") else { return nil }
        t.removeFirst(4)
        t = String(t.map { $0 == "0" ? "O" : $0 == "1" ? "I" : $0 == "8" ? "B" : $0 })
        guard t.count == 55 else { return nil }
        var bytes = Data(), bits = 0, v: UInt32 = 0
        for ch in t {
            guard let i = alphabet.firstIndex(of: ch) else { return nil }
            v = (v << 5) | UInt32(i); bits += 5
            if bits >= 8 { bytes.append(UInt8((v >> UInt32(bits - 8)) & 0xFF)); bits -= 8; v &= (1 << UInt32(bits)) - 1 }
        }
        guard bytes.count == 34 else { return nil }
        let key = bytes.prefix(32)
        let c = UInt16(bytes[bytes.startIndex + 32]) << 8 | UInt16(bytes[bytes.startIndex + 33])
        return crc16(Data(key)) == c ? Data(key) : nil
    }
}

// MARK: local state and the merge rules (the shared notes format "Merge rules")

/// One note as this device keeps it. `base` is the server's u it last saw (nil: never on the server).
struct NoteLocal: Codable, Equatable, Identifiable {
    var id: String
    var title: String
    var body: String
    var u: Int
    var base: Int?
    var dirty: Bool
    var deleted: Bool
    /// The server's id of the write this device last made or saw (the notes server `rev`); nil.
    var rev: String? = nil

    static func clean(_ r: NoteRemotePlain) -> NoteLocal {
        NoteLocal(id: r.id, title: r.title, body: r.body, u: r.u, base: r.u, dirty: false, deleted: r.deleted, rev: r.rev)
    }

    /// The row's name: the title, else the first line, else "Note".
    var name: String {
        let t = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if !t.isEmpty { return t }
        let first = body.split(whereSeparator: \.isNewline).first.map(String.init)?.trimmingCharacters(in: .whitespaces) ?? ""
        return first.isEmpty ? "Note" : String(first.prefix(60))
    }
}

/// A server note, decrypted (title and body empty for a tombstone).
struct NoteRemotePlain: Equatable {
    var id: String
    var u: Int
    var deleted: Bool
    var title: String
    var body: String
    /// The stored write's rev and the revs it replaced (newest last); empty from an older server.
    var rev: String? = nil
    var h: [String] = []
}

/// The device's whole sync state for one workspace (UserDefaults `lia_ws_notes_sync_<ws>`).
struct NotesSyncState: Codable, Equatable {
    var notes: [NoteLocal] = []
    var since: Int = 0
    /// The list cursor. `after` breaks ties of `since` (a page cut inside one r); `cursor` is the Durable
    /// Object's change number, used once the server answered one (exact: no overlap, no ties).
    var after: String? = nil
    var cursor: Int? = nil
    /// The server time of this device's first list since sync was turned on. A purge (another device's
    /// "Delete synced copies") after it stops syncing here; one before it is history.
    var joinedAt: Int? = nil

    func note(_ id: String) -> NoteLocal? { notes.first { $0.id == id } }
    mutating func set(_ n: NoteLocal) {
        if let i = notes.firstIndex(where: { $0.id == n.id }) { notes[i] = n } else { notes.append(n) }
    }
    mutating func remove(_ id: String) { notes.removeAll { $0.id == id } }

    /// The panel's text changed: the main note is dirty with this body.
    mutating func edit(main body: String, now: Int) {
        var n = note(NotesKeys.mainId) ?? NoteLocal(id: NotesKeys.mainId, title: "", body: "", u: 0, base: nil, dirty: false, deleted: false)
        guard n.body != body || n.deleted else { return }
        n.body = body; n.u = max(now, n.u + 1); n.dirty = true; n.deleted = false
        set(n)
    }

    /// Turning sync on: the panel's text goes up as a new note (the server's 409 merges it with a main note already
    /// there) and everything else is read again from the start.
    mutating func restart(mainBody: String, now: Int) {
        since = 0
        after = nil
        cursor = nil
        joinedAt = nil
        notes = mainBody.isEmpty ? [] : [NoteLocal(id: NotesKeys.mainId, title: "", body: mainBody, u: now, base: nil, dirty: true, deleted: false)]
    }

    var others: [NoteLocal] { notes.filter { $0.id != NotesKeys.mainId && !$0.deleted } }
    var dirty: [NoteLocal] { notes.filter(\.dirty) }
}

enum NotesMerge {
    /// `unsync`: the panel's note (main) was deleted elsewhere: this Mac keeps its text and only forgets the synced
    /// copy (it wrote "" over the panel before). `setWithCopy`: this device's own write was replaced unseen
    /// (two writes on one base, KV): the remote wins the note and this device's text becomes a conflict copy.
    enum Pulled: Equatable { case keep, set(NoteLocal), remove, unsync, setWithCopy(NoteLocal, NoteLocal) }

    /// True when the remote write neither is this device's last write nor was made on top of it (the notes server h).
    static func replacedUnseen(local l: NoteLocal, remote: NoteRemotePlain) -> Bool {
        guard let mine = l.rev, let theirs = remote.rev, mine != theirs else { return false }
        return !remote.h.contains(mine)
    }

    /// A note from a list: one this device did not change is replaced (or removed, for a tombstone); one it changed is
    /// kept and pushed (its push meets the 409 and goes through `conflict`).
    static func pulled(local: NoteLocal?, remote: NoteRemotePlain, newId: String = NotesKeys.newId(), now: Int = 0) -> Pulled {
        guard let l = local else { return remote.deleted ? .keep : .set(.clean(remote)) }
        if l.base == remote.u { return .keep }
        if l.dirty { return .keep }
        if remote.deleted { return l.id == NotesKeys.mainId ? .unsync : .remove }
        if replacedUnseen(local: l, remote: remote), !l.deleted, l.body != remote.body || l.title != remote.title {
            let copy = NoteLocal(id: newId, title: copyTitle(l.title), body: l.body, u: max(now, l.u + 1), base: nil, dirty: true, deleted: false)
            return .setWithCopy(.clean(remote), copy)
        }
        return .set(.clean(remote))
    }

    /// A purge made on another device after this one joined: stop syncing this workspace, keep the text.
    static func purgedElsewhere(purgedAt: Int?, joinedAt: Int?) -> Bool {
        guard let p = purgedAt, let j = joinedAt else { return false }
        return p > j
    }

    struct Resolution: Equatable {
        /// This note's new state (dirty: write it again with base = remote.u).
        var note: NoteLocal
        /// A conflict copy to create (a new note, dirty, never on the server).
        var copy: NoteLocal?
    }

    static func copyTitle(_ title: String) -> String {
        let t = title.trimmingCharacters(in: .whitespacesAndNewlines)
        return (t.isEmpty ? "Note" : t) + " (conflict copy)"
    }

    /// A 409: both sides changed since `local.base`. Nothing is lost: an edit beats a delete, and when both edited
    /// different text the newer u wins the note and the other side becomes a conflict copy.
    static func conflict(local: NoteLocal, remote: NoteRemotePlain, newId: String, now: Int) -> Resolution {
        var winner = local
        winner.base = remote.u
        if remote.deleted && local.deleted { winner.dirty = false; return Resolution(note: winner, copy: nil) }
        if remote.deleted { winner.dirty = true; return Resolution(note: winner, copy: nil) }
        if local.deleted { return Resolution(note: .clean(remote), copy: nil) }
        if remote.title == local.title && remote.body == local.body { return Resolution(note: .clean(remote), copy: nil) }
        if local.u > remote.u {
            winner.dirty = true
            let lost = NoteLocal(id: newId, title: copyTitle(remote.title), body: remote.body, u: now, base: nil, dirty: true, deleted: false)
            return Resolution(note: winner, copy: lost)
        }
        let lost = NoteLocal(id: newId, title: copyTitle(local.title), body: local.body, u: now, base: nil, dirty: true, deleted: false)
        return Resolution(note: .clean(remote), copy: lost)
    }

    /// "Add to note": an other note's text appended to the main one.
    static func appended(_ main: String, _ other: NoteLocal) -> String {
        let t = other.title.trimmingCharacters(in: .whitespacesAndNewlines)
        let block = (t.isEmpty ? "" : t + "\n") + other.body
        if main.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return block }
        return main + (main.hasSuffix("\n") ? "\n" : "\n\n") + block
    }
}

// MARK: the wire (the notes server answers)

struct NoteRemote: Equatable {
    let id: String
    let u: Int
    let r: Int
    let deleted: Bool
    let env: NoteEnvelope?
    var rev: String? = nil
    var h: [String] = []

    static func parse(_ o: JSONObject) -> NoteRemote? {
        guard let id = o["id"] as? String, NotesKeys.isId(id), let u = JSONRead.int(o, "u") else { return nil }
        let d = JSONRead.bool(o, "d")
        let e = NoteEnvelope.parse(o["env"])
        if !d && e == nil { return nil }
        let rev = (o["rev"] as? String).flatMap { $0.count <= 32 ? $0 : nil }
        let h = ((o["h"] as? [Any]) ?? []).compactMap { $0 as? String }
        return NoteRemote(id: id, u: u, r: JSONRead.int(o, "r") ?? 0, deleted: d, env: d ? nil : e, rev: rev, h: h)
    }
}

struct NotesListPage: Equatable {
    let notes: [NoteRemote]
    let more: Bool
    let nextSince: Int
    /// The tie-break of next_since (cursor mode), the Durable Object's change number, the last purge, the
    /// server's clock. nil: an older server.
    var nextAfter: String? = nil
    var nextCursor: Int? = nil
    var purgedAt: Int? = nil
    var now: Int? = nil
}

enum NotesPutResult: Equatable {
    case ok(u: Int, rev: String?)
    case conflict(NoteRemote)
    case gone
    case keyMismatch
    case failed(String)
}

enum NotesWire {
    static func listPage(_ d: Data) -> NotesListPage? {
        guard let o = JSONRead.object(d), JSONRead.bool(o, "ok") else { return nil }
        return NotesListPage(notes: JSONRead.objects(o, "notes").compactMap(NoteRemote.parse),
                             more: JSONRead.bool(o, "more"), nextSince: JSONRead.int(o, "next_since") ?? 0,
                             nextAfter: o["next_after"] as? String, nextCursor: JSONRead.int(o, "next_cursor"),
                             purgedAt: JSONRead.int(o, "purged_at"), now: JSONRead.int(o, "now"))
    }

    /// The query of the next list call: the change number once the server gave one, else since + after
    /// (`after` is sent even when empty, which is what tells the server this client pages by (r, id)).
    static func listQuery(ws: String, since: Int, after: String?, cursor: Int?) -> [(String, String)] {
        if let c = cursor { return [("ws", ws), ("cursor", String(c))] }
        return [("ws", ws), ("since", String(since)), ("after", after ?? "")]
    }

    static func write(status: Int, _ d: Data) -> NotesPutResult {
        let o = JSONRead.object(d)
        let err = JSONRead.string(o, "error") ?? ""
        if status == 200, JSONRead.bool(o, "ok"), let u = JSONRead.int(o, "u") { return .ok(u: u, rev: JSONRead.string(o, "rev")) }
        if status == 409, err == "conflict", let c = o?["current"] as? JSONObject, let r = NoteRemote.parse(c) { return .conflict(r) }
        if status == 410 { return .gone }
        if status == 409, err == "key_mismatch" { return .keyMismatch }
        if status == 413 { return .failed(err == "too_many_notes" ? "This workspace has too many synced notes." : "This note is too long to sync.") }
        if status == 429 { return .failed("Syncing paused for a moment. It tries again shortly.") }
        return .failed("Notes could not sync. It tries again shortly.")
    }

    static func putBody(ws: String, id: String, env: NoteEnvelope, u: Int, base: Int?) -> JSONObject {
        var b: JSONObject = ["ws": ws, "id": id, "env": env.json, "u": u]
        b["base"] = base.map { $0 as Any } ?? NSNull()
        return b
    }

    static func deleteBody(ws: String, id: String, u: Int, base: Int?) -> JSONObject {
        var b: JSONObject = ["ws": ws, "id": id, "u": u]
        b["base"] = base.map { $0 as Any } ?? NSNull()
        return b
    }

    /// GET/POST /agents/notes/key: the stored fingerprint (nil: none yet), or the existing one on a 409.
    static func kid(_ d: Data) -> String? {
        guard let k = JSONRead.string(JSONRead.object(d), "kid"), NoteEnvelope.isKid(k) else { return nil }
        return k
    }
}
