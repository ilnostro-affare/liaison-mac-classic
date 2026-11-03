import Foundation

/// One workspace's notes in the cloud, end-to-end encrypted. The panel's text stays the local
/// copy (`lia_ws_notes_<ws>`) in both modes; in Synced this pushes what changed and pulls what other devices wrote.
/// Everything leaves the Mac as an AES-GCM envelope (NotesCrypto.swift); the key never goes to Liaison.
@MainActor
final class NotesSyncEngine: ObservableObject {
    /// One engine per member and workspace (it was per workspace: a second account on this Mac shared its state).
    private static var engines: [String: NotesSyncEngine] = [:]
    static func of(_ ws: String, member: String) -> NotesSyncEngine {
        let k = member + "|" + ws
        if let e = engines[k] { return e }
        let e = NotesSyncEngine(ws: ws, member: member)
        engines[k] = e
        return e
    }

    let ws: String
    /// The member this engine's state belongs to ("" when the app did not know yet: keys are used then).
    let owner: String
    private var modeKey: String { owner.isEmpty ? NotesKeys.legacyMode(ws) : NotesKeys.mode(ws, member: owner) }
    private var stateKey: String { owner.isEmpty ? NotesKeys.legacyState(ws) : NotesKeys.state(ws, member: owner) }
    @Published private(set) var mode: NotesSyncMode
    @Published private(set) var status: NotesSyncStatus
    /// Notes other than the panel's (conflict copies, notes written on the web or the phone).
    @Published private(set) var others: [NoteLocal] = []
    @Published private(set) var keyPlace: NotesKeyring.Place?
    /// Bumped when a change from another device replaced the panel's text: the panel reads it again.
    @Published private(set) var mainRevision = 0
    /// A sentence for the panel when sync turned itself off (another device deleted the synced copies).
    @Published private(set) var notice: String?

    private var state: NotesSyncState
    private weak var auth: AuthStore?
    private var running = false
    private var again = false
    private var kidChecked: String?
    /// The key read from the Keychain once per member (the Keychain is not asked every 30 s).
    private var cachedKey: (member: String, key: Data)?
    /// When this Mac made and claimed a new key. KV (and two devices on two edges) can let a second claim land
    /// within a minute, so ~70 s later the server's kid is read again; another one means this Mac lost the race and
    /// stops (asks for the recovery key) instead of writing notes under a key nobody else has.
    private var claimedAt: Date?
    private var syncToken = 0
    private let cipher = CryptoKitNotesCipher()

    private init(ws: String, member: String) {
        self.ws = ws
        self.owner = member
        NotesKeys.adoptLegacy(UserDefaults.standard, member: member, ws: ws)
        let mk = member.isEmpty ? NotesKeys.legacyMode(ws) : NotesKeys.mode(ws, member: member)
        let sk = member.isEmpty ? NotesKeys.legacyState(ws) : NotesKeys.state(ws, member: member)
        let m = NotesSyncMode(rawValue: UserDefaults.standard.string(forKey: mk) ?? "") ?? .local
        mode = m
        status = m == .synced ? .syncing : .off
        if let d = UserDefaults.standard.data(forKey: sk), let s = try? JSONDecoder().decode(NotesSyncState.self, from: d) {
            state = s
        } else {
            state = NotesSyncState()
        }
        others = sortedOthers()
    }

    func attach(_ auth: AuthStore) {
        self.auth = auth
        if keyPlace == nil, let m = auth.memberId { keyPlace = NotesKeyring.load(member: m)?.place }
    }

    private var nowMs: Int { Int(Date().timeIntervalSince1970 * 1000) }
    private var member: String? { auth?.memberId }

    // MARK: the panel's actions

    /// The text changed in the panel (every key): the main note is dirty; a sync follows two seconds after the last key.
    func typed(_ text: String) {
        guard mode == .synced else { return }
        let before = state
        state.edit(main: text, now: nowMs)
        guard state != before else { return }
        persist()
        scheduleSync(after: 2)
    }

    /// On this Mac -> Synced (after the person confirmed the upload): this workspace's text goes up encrypted.
    func enableSync(mainText: String) {
        notice = nil
        state.restart(mainBody: mainText, now: nowMs)
        setMode(.synced)
        persist()
        Task { await sync() }
    }

    /// Synced -> On this Mac: syncing stops; the text stays on this Mac and the cloud copies stay until deleted.
    func disableSync() {
        setMode(.local)
        status = .off
    }

    /// "Delete synced copies": every note of this workspace in the cloud becomes a tombstone; this Mac keeps its text.
    func deleteCloudCopies() async -> String? {
        guard let auth else { return "Sign in to delete the synced copies." }
        do {
            guard try await LiaAPI(auth: auth).notesPurge(ws: ws) else { return "The synced copies could not be deleted. Try again." }
        } catch {
            return "The synced copies could not be deleted. Try again."
        }
        state = NotesSyncState()
        persist()
        setMode(.local)
        status = .off
        return nil
    }

    /// "Add to note": another note's text goes at the end of the panel's, and that note is deleted. -> the new text.
    func addToMain(_ id: String, mainText: String) -> String {
        guard let o = state.note(id) else { return mainText }
        let text = NotesMerge.appended(mainText, o)
        markDeleted(id)
        return text
    }

    func deleteOther(_ id: String) { markDeleted(id) }

    private func markDeleted(_ id: String) {
        guard var n = state.note(id) else { return }
        if n.base == nil { state.remove(id) } else { n.deleted = true; n.dirty = true; n.u = max(nowMs, n.u + 1); state.set(n) }
        persist()
        scheduleSync(after: 0.5)
    }

    /// The recovery key for the web, the phone or a Mac without iCloud Keychain; nil when this Mac has no key.
    func recoveryKey() -> String? {
        guard let m = member, let k = NotesKeyring.load(member: m) else { return nil }
        return NotesRecoveryKey.encode(k.key)
    }

    /// The person typed a recovery key. -> nil when it was taken, else the sentence to show.
    func enterRecoveryKey(_ text: String) async -> String? {
        guard let auth, let m = member else { return "Sign in to sync notes." }
        guard let key = NotesRecoveryKey.decode(text) else { return "That is not a recovery key. Check it and try again." }
        let kid = NotesKeyring.kid(key)
        let api = LiaAPI(auth: auth)
        do {
            let server = try await api.notesKid()
            if let s = server, s != kid { return "This recovery key is not the one your synced notes use." }
            guard let place = NotesKeyring.save(key, member: m) else { return "The Keychain did not accept the key." }
            if server == nil { guard try await api.notesClaimKid(kid) == kid else { return "Another device set up a different key. Use its recovery key." } }
            keyPlace = place
            kidChecked = m
            cachedKey = (m, key)
        } catch {
            return "Liaison could not be reached. Try again."
        }
        await sync()
        return nil
    }

    // MARK: sync

    func scheduleSync(after seconds: Double) {
        syncToken += 1
        let t = syncToken
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            guard let self, t == self.syncToken else { return }
            await self.sync()
        }
    }

    private enum KeyState { case ready(Data), needsKey, failed(String) }

    func sync() async {
        guard mode == .synced, let auth, let m = member, owner.isEmpty || owner == m else { return }
        if running { again = true; return }
        running = true
        defer {
            running = false
            if again { again = false; Task { await self.sync() } }
        }
        status = .syncing
        let api = LiaAPI(auth: auth)
        do {
            let key: Data
            switch try await readyKey(api, member: m) {
            case .ready(let k): key = k
            case .needsKey: status = .needsKey; return
            case .failed(let s): status = .error(s); return
            }
            let kid = NotesKeyring.kid(key)
            if let c = claimedAt, Date().timeIntervalSince(c) >= 70 {
                let server = try await api.notesKid()
                claimedAt = nil
                if let s = server, s != kid {
                    // Lost the claim race: another device's key is the account's. Adopt it if iCloud Keychain brought
                    // it, else ask for its recovery key; never overwrite with ours.
                    cachedKey = nil
                    kidChecked = nil
                    if let k = NotesKeyring.load(member: m, kid: s) { cachedKey = (m, k); kidChecked = m; scheduleSync(after: 0.5) }
                    else { status = .needsKey }
                    return
                }
            }
            var problem: String?
            for _ in 0..<3 {
                let dirty = state.dirty
                if dirty.isEmpty { break }
                for n in dirty {
                    if let p = try await push(n, api: api, key: key, kid: kid, depth: 0) { problem = p }
                }
            }
            let page = try await api.notesList(ws: ws, since: state.since, after: state.after, cursor: state.cursor)
            if state.joinedAt == nil { state.joinedAt = page.now ?? nowMs }
            // Another device deleted the synced copies after this Mac joined: stop syncing, keep every word here.
            if NotesMerge.purgedElsewhere(purgedAt: page.purgedAt, joinedAt: state.joinedAt) {
                state.joinedAt = nil
                persist()
                setMode(.local)
                status = .off
                notice = "The synced copies were deleted on another device. This Mac kept its notes; turn on Synced to upload them again."
                return
            }
            var unreadable = 0
            for r in page.notes {
                guard mode == .synced else { return }
                if !apply(r, key: key, kid: kid) { unreadable += 1 }
            }
            state.since = page.since
            state.after = page.after
            state.cursor = page.cursor
            persist()
            if let problem { status = .error(problem) }
            else if unreadable > 0 { status = .error(unreadable == 1 ? "1 synced note uses another key." : "\(unreadable) synced notes use another key.") }
            else { status = .synced }
        } catch AuthError.network {
            status = .offline
        } catch AuthError.sessionExpired {
            status = .error("Sign in again to sync notes.")
        } catch is CancellationError {
            status = .off
        } catch {
            status = .error("Notes could not sync. It tries again shortly.")
        }
    }

    private func readyKey(_ api: LiaAPI, member m: String) async throws -> KeyState {
        if let c = cachedKey, c.member == m, kidChecked == m { return .ready(c.key) }
        if let k = NotesKeyring.load(member: m) {
            keyPlace = k.place
            if kidChecked != m {
                let kid = NotesKeyring.kid(k.key)
                let server = try await api.notesKid()
                if server == nil {
                    guard try await api.notesClaimKid(kid) == kid else { return .needsKey }
                } else if let s = server, s != kid {
                    // ICloud Keychain may hold the account's key under its fingerprint (two devices made keys
                    // at once and the one item kept the other's): adopt it.
                    guard let other = NotesKeyring.load(member: m, kid: s) else { return .needsKey }
                    kidChecked = m
                    cachedKey = (m, other)
                    return .ready(other)
                }
                kidChecked = m
            }
            cachedKey = (m, k.key)
            return .ready(k.key)
        }
        // No key on this Mac: when another device already made one, this Mac waits for it (iCloud Keychain) or for
        // the recovery key; it never makes a second key.
        if let s = try await api.notesKid() {
            if let k = NotesKeyring.load(member: m, kid: s) { kidChecked = m; cachedKey = (m, k); return .ready(k) }
            return .needsKey
        }
        let key = NotesKeyring.newKey()
        guard let place = NotesKeyring.save(key, member: m) else { return .failed("The Keychain did not accept the notes key.") }
        let kid = NotesKeyring.kid(key)
        guard try await api.notesClaimKid(kid) == kid else {
            // Another device won. Its key is not deleted from the Keychain here (it deleted the synchronizable
            // item, which iCloud Keychain then deleted on the winner too); ours stays, under its own fingerprint.
            return .needsKey
        }
        keyPlace = place
        kidChecked = m
        cachedKey = (m, key)
        claimedAt = Date()
        scheduleSync(after: 75)
        return .ready(key)
    }

    /// One dirty note up. -> a sentence when it could not go (the rest still syncs).
    private func push(_ sent: NoteLocal, api: LiaAPI, key: Data, kid: String, depth: Int) async throws -> String? {
        guard depth < 3 else { return nil }
        let result: NotesPutResult
        if sent.deleted {
            guard sent.base != nil else { state.remove(sent.id); return nil }
            result = try await api.notesDelete(ws: ws, id: sent.id, u: sent.u, base: sent.base)
        } else {
            let plain = NotePlain(title: sent.title, body: sent.body, u: sent.u)
            let env = try NotesCrypto.seal(plain, ws: ws, id: sent.id, key: key, kid: kid, cipher: cipher)
            result = try await api.notesPut(ws: ws, id: sent.id, env: env, u: sent.u, base: sent.base)
        }
        switch result {
        case .ok(let u, let rev):
            if sent.deleted { state.remove(sent.id); return nil }
            guard var cur = state.note(sent.id) else { return nil }
            cur.base = u
            cur.rev = rev
            // Typed while the call ran: still dirty, pushed again with the new base.
            if cur.body == sent.body && cur.title == sent.title && !cur.deleted { cur.dirty = false; cur.u = u }
            state.set(cur)
            return nil
        case .conflict(let r):
            guard let plain = plain(r, key: key, kid: kid) else { return "A synced note uses another key." }
            guard let cur = state.note(sent.id) else { return nil }
            let res = NotesMerge.conflict(local: cur, remote: plain, newId: NotesKeys.newId(), now: nowMs)
            setNote(res.note)
            if let c = res.copy { state.set(c) }
            persist()
            if res.note.dirty, let again = state.note(sent.id) { return try await push(again, api: api, key: key, kid: kid, depth: depth + 1) }
            return nil
        case .gone:
            if sent.deleted { state.remove(sent.id); return nil }
            guard var cur = state.note(sent.id) else { return nil }
            cur.base = nil
            state.set(cur)
            return try await push(cur, api: api, key: key, kid: kid, depth: depth + 1)
        case .keyMismatch:
            kidChecked = nil
            cachedKey = nil
            return "Your synced notes use another key. Enter the recovery key."
        case .failed(let s):
            return s
        }
    }

    private func plain(_ r: NoteRemote, key: Data, kid: String) -> NoteRemotePlain? {
        if r.deleted { return NoteRemotePlain(id: r.id, u: r.u, deleted: true, title: "", body: "", rev: r.rev, h: r.h) }
        guard let e = r.env, let p = NotesCrypto.open(e, ws: ws, id: r.id, key: key, kid: kid, cipher: cipher) else { return nil }
        return NoteRemotePlain(id: r.id, u: r.u, deleted: false, title: p.title, body: p.body, rev: r.rev, h: r.h)
    }

    /// A note from the list. -> false when it could not be opened.
    private func apply(_ r: NoteRemote, key: Data, kid: String) -> Bool {
        guard let p = plain(r, key: key, kid: kid) else { return false }
        switch NotesMerge.pulled(local: state.note(r.id), remote: p, newId: NotesKeys.newId(), now: nowMs) {
        case .keep: break
        case .set(let n): setNote(n)
        case .setWithCopy(let n, let copy):
            // This device's write was replaced unseen; its text stays, as a conflict copy.
            setNote(n)
            state.set(copy)
        case .remove: state.remove(r.id)
        case .unsync:
            // The panel's note was deleted elsewhere. The text stays on this Mac (it was cleared); it is
            // simply no longer synced until it is edited again.
            state.remove(r.id)
        }
        return true
    }

    private func setNote(_ n: NoteLocal) {
        let old = state.note(n.id)
        state.set(n)
        // Never clears the panel (a deleted main keeps this Mac's text)
        if n.id == NotesKeys.mainId, !n.deleted, old?.body != n.body { writeMain(n.body) }
    }

    /// The panel's text replaced by another device's.
    private func writeMain(_ text: String) {
        let k = NotesKeys.text(ws)
        if text.isEmpty { UserDefaults.standard.removeObject(forKey: k) } else { UserDefaults.standard.set(text, forKey: k) }
        mainRevision += 1
    }

    private func setMode(_ m: NotesSyncMode) {
        mode = m
        UserDefaults.standard.set(m.rawValue, forKey: modeKey)
    }

    private func persist() {
        if let d = try? JSONEncoder().encode(state) { UserDefaults.standard.set(d, forKey: stateKey) }
        others = sortedOthers()
    }

    private func sortedOthers() -> [NoteLocal] { state.others.sorted { $0.u > $1.u } }
}
