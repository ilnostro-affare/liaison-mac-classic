import XCTest
import Foundation
@testable import Liaison

/// Notes sync, the pure half (Shared/Core/NotesSync.swift): the envelope, the recovery key (the spec's vector
/// in the shared notes format), the wire, and the merge rules. The cipher is a fake here (no CryptoKit on Linux);
/// the real AES-GCM is checked against the spec's vector in NotesCryptoTests (Mac only) and in the site's
/// The server's tests (WebCrypto).
final class NotesSyncTests: XCTestCase {
    /// Not a cipher: XOR with the key and a checksum "tag" over aad + plaintext, enough to prove the AAD is bound.
    struct FakeCipher: NotesCipher {
        struct Bad: Error {}
        func tag(_ p: Data, _ aad: Data, _ key: Data) -> Data {
            let c = NotesRecoveryKey.crc16(aad + p + key)
            return Data((0..<16).map { UInt8(truncatingIfNeeded: Int(c) >> ($0 % 2 == 0 ? 8 : 0)) })
        }
        func xor(_ d: Data, _ key: Data) -> Data { Data(d.enumerated().map { $0.element ^ key[$0.offset % key.count] }) }
        func seal(_ plaintext: Data, key: Data, aad: Data) throws -> (nonce: Data, ct: Data) {
            (Data(repeating: 9, count: 12), xor(plaintext, key) + tag(plaintext, aad, key))
        }
        func open(nonce: Data, ct: Data, key: Data, aad: Data) throws -> Data {
            guard ct.count >= 16 else { throw Bad() }
            let p = xor(ct.prefix(ct.count - 16), key)
            guard tag(p, aad, key) == ct.suffix(16) else { throw Bad() }
            return p
        }
    }

    private let key = Data((0..<32).map { UInt8($0) })
    private let kid = "a8398741ee383df1"

    func testRecoveryKeyVectorFromTheSpec() {
        XCTAssertEqual(NotesRecoveryKey.crc16(Data("123456789".utf8)), 0x29B1)
        let rk = NotesRecoveryKey.encode(key)
        XCTAssertEqual(rk, "LIA1-AAAQE-AYEAU-DAOCA-JBIFQ-YDIOB-4IBCE-QTCQK-RMFYY-DENBW-HA5DY-PSHMY")
        XCTAssertEqual(NotesRecoveryKey.decode(rk), key)
        XCTAssertEqual(NotesRecoveryKey.decode(rk.lowercased().replacingOccurrences(of: "-", with: " ")), key, "case and spaces do not matter")
        var typo = Array(rk)
        typo[10] = typo[10] == "A" ? "B" : "A"
        XCTAssertNil(NotesRecoveryKey.decode(String(typo)), "the checksum catches a typo")
        XCTAssertNil(NotesRecoveryKey.decode("LIA1-AAAA"))
        XCTAssertNil(NotesRecoveryKey.decode(""))
        let random = Data((0..<32).map { _ in UInt8.random(in: 0...255) })
        XCTAssertEqual(NotesRecoveryKey.decode(NotesRecoveryKey.encode(random)), random)
    }

    func testEnvelopeShape() throws {
        let e = try NotesCrypto.seal(NotePlain(title: "T", body: "Hello", u: 5), ws: "pf_a", id: "main", key: key, kid: kid, cipher: FakeCipher())
        let j = e.json
        XCTAssertEqual(Set(j.keys), ["v", "alg", "kid", "n", "ct"])
        XCTAssertEqual(j["v"] as? Int, 1); XCTAssertEqual(j["alg"] as? String, "A256GCM")
        XCTAssertEqual(NoteEnvelope.parse(j), e)
        let text = String(data: try JSONSerialization.data(withJSONObject: j), encoding: .utf8) ?? ""
        XCTAssertFalse(text.contains("Hello"), "the body is not in the envelope")
        var bad = j; bad["v"] = 2
        XCTAssertNil(NoteEnvelope.parse(bad))
        bad = j; bad["n"] = Data(count: 16).base64EncodedString()
        XCTAssertNil(NoteEnvelope.parse(bad), "a nonce is 12 bytes")
        bad = j; bad["kid"] = "ABCDEF0123456789"
        XCTAssertNil(NoteEnvelope.parse(bad), "kid is lowercase hex")
        XCTAssertTrue(NoteEnvelope.isKid(kid))
    }

    func testAADBindsTheNoteAndKey() throws {
        let c = FakeCipher()
        let p = NotePlain(title: "", body: "Client wants two logins", u: 7)
        let e = try NotesCrypto.seal(p, ws: "pf_a", id: "main", key: key, kid: kid, cipher: c)
        XCTAssertEqual(NotesCrypto.open(e, ws: "pf_a", id: "main", key: key, kid: kid, cipher: c), p)
        XCTAssertNil(NotesCrypto.open(e, ws: "pf_b", id: "main", key: key, kid: kid, cipher: c), "moved to another workspace")
        XCTAssertNil(NotesCrypto.open(e, ws: "pf_a", id: "n_x", key: key, kid: kid, cipher: c), "moved to another note")
        XCTAssertNil(NotesCrypto.open(e, ws: "pf_a", id: "main", key: key, kid: "0000000000000000", cipher: c), "another key's envelope")
        XCTAssertEqual(NotesCrypto.aad(ws: "pf_test", id: "main"), Data("liaison-notes:v1:pf_test:main".utf8))
        XCTAssertEqual(NotesCrypto.kidInput(Data([1])), Data("liaison-notes-kid-v1".utf8) + Data([1]))
        XCTAssertEqual(NotesCrypto.hex(Data([0xa8, 0x03])), "a803")
    }

    func testPlaintextRoundTrip() {
        let p = NotePlain(title: "Ti\"tle", body: "Line 1\nLine 2 \u{1F600}", u: 1760000000000)
        XCTAssertEqual(NotePlain.decode(p.encoded()), p)
        // the spec's vector plaintext as another client writes it
        XCTAssertEqual(NotePlain.decode(Data(#"{"title":"Hello","body":"Line 1\nLine 2","u":1760000000000}"#.utf8)),
                       NotePlain(title: "Hello", body: "Line 1\nLine 2", u: 1760000000000))
        XCTAssertNil(NotePlain.decode(Data("{}".utf8)))
    }

    func testKeysAndIds() {
        XCTAssertEqual(NotesKeys.server(member: "mem_1", ws: "pf_a", id: "main"), "notes:mem_1:pf_a:main")
        XCTAssertEqual(NotesKeys.text("pf_a"), "lia_ws_notes_pf_a", "the local copy is the panel's own key")
        XCTAssertTrue(NotesKeys.isId("main")); XCTAssertTrue(NotesKeys.isId(NotesKeys.newId()))
        XCTAssertFalse(NotesKeys.isId("a:b")); XCTAssertFalse(NotesKeys.isId("")); XCTAssertFalse(NotesKeys.isId("\u{00E9}"))
        XCTAssertFalse(NotesKeys.newId() == NotesKeys.newId())
    }

    private func local(_ id: String = "main", body: String, u: Int, base: Int?, dirty: Bool, deleted: Bool = false) -> NoteLocal {
        NoteLocal(id: id, title: "", body: body, u: u, base: base, dirty: dirty, deleted: deleted)
    }
    private func remote(_ id: String = "main", body: String, u: Int, deleted: Bool = false) -> NoteRemotePlain {
        NoteRemotePlain(id: id, u: u, deleted: deleted, title: "", body: deleted ? "" : body)
    }

    func testPulledNotes() {
        XCTAssertEqual(NotesMerge.pulled(local: nil, remote: remote(body: "a", u: 5)), .set(local(body: "a", u: 5, base: 5, dirty: false)))
        XCTAssertEqual(NotesMerge.pulled(local: nil, remote: remote(body: "", u: 5, deleted: true)), .keep, "a tombstone of a note never seen")
        XCTAssertEqual(NotesMerge.pulled(local: local(body: "a", u: 5, base: 5, dirty: false), remote: remote(body: "a", u: 5)), .keep, "already seen")
        XCTAssertEqual(NotesMerge.pulled(local: local(body: "a", u: 5, base: 5, dirty: false), remote: remote(body: "b", u: 9)),
                       .set(local(body: "b", u: 9, base: 9, dirty: false)), "not changed here: the remote replaces it")
        XCTAssertEqual(NotesMerge.pulled(local: local(body: "a", u: 5, base: 5, dirty: false), remote: remote(body: "", u: 9, deleted: true)), .unsync,
                       "the panel's note deleted elsewhere keeps this Mac's text")
        XCTAssertEqual(NotesMerge.pulled(local: local("n_1", body: "a", u: 5, base: 5, dirty: false), remote: remote("n_1", body: "", u: 9, deleted: true)), .remove)
        XCTAssertEqual(NotesMerge.pulled(local: local(body: "mine", u: 8, base: 5, dirty: true), remote: remote(body: "b", u: 9)), .keep,
                       "changed here: kept, its push merges")
    }

    func testConflictNewerWinsAndTheOtherBecomesACopy() {
        let mineNewer = NotesMerge.conflict(local: local(body: "mine", u: 20, base: 5, dirty: true), remote: remote(body: "theirs", u: 10), newId: "n_c", now: 30)
        XCTAssertEqual(mineNewer.note.body, "mine"); XCTAssertTrue(mineNewer.note.dirty); XCTAssertEqual(mineNewer.note.base, 10)
        XCTAssertEqual(mineNewer.copy?.body, "theirs"); XCTAssertEqual(mineNewer.copy?.id, "n_c"); XCTAssertNil(mineNewer.copy?.base)
        XCTAssertEqual(mineNewer.copy?.title, "Note (conflict copy)"); XCTAssertEqual(mineNewer.copy?.dirty, true)

        let theirsNewer = NotesMerge.conflict(local: local(body: "mine", u: 8, base: 5, dirty: true), remote: remote(body: "theirs", u: 10), newId: "n_c", now: 30)
        XCTAssertEqual(theirsNewer.note, local(body: "theirs", u: 10, base: 10, dirty: false))
        XCTAssertEqual(theirsNewer.copy?.body, "mine", "this Mac's text is not lost")

        let same = NotesMerge.conflict(local: local(body: "x", u: 8, base: 5, dirty: true), remote: remote(body: "x", u: 10), newId: "n_c", now: 30)
        XCTAssertNil(same.copy, "the same text on both sides makes no copy")
        XCTAssertFalse(same.note.dirty)
    }

    func testConflictEditBeatsDelete() {
        let r1 = NotesMerge.conflict(local: local(body: "kept", u: 8, base: 5, dirty: true), remote: remote(body: "", u: 10, deleted: true), newId: "n", now: 30)
        XCTAssertEqual(r1.note.body, "kept"); XCTAssertTrue(r1.note.dirty); XCTAssertEqual(r1.note.base, 10); XCTAssertNil(r1.copy)
        let r2 = NotesMerge.conflict(local: local(body: "", u: 12, base: 5, dirty: true, deleted: true), remote: remote(body: "edited", u: 10), newId: "n", now: 30)
        XCTAssertEqual(r2.note, local(body: "edited", u: 10, base: 10, dirty: false), "a delete here does not erase an edit there")
        let r3 = NotesMerge.conflict(local: local(body: "", u: 12, base: 5, dirty: true, deleted: true), remote: remote(body: "", u: 10, deleted: true), newId: "n", now: 30)
        XCTAssertFalse(r3.note.dirty); XCTAssertNil(r3.copy)
    }

    func testStateEditsAndRestart() {
        var s = NotesSyncState()
        s.edit(main: "hello", now: 100)
        XCTAssertEqual(s.note("main")?.dirty, true); XCTAssertEqual(s.note("main")?.u, 100)
        s.set(NoteLocal(id: "main", title: "", body: "hello", u: 100, base: 100, dirty: false, deleted: false))
        s.edit(main: "hello", now: 200)
        XCTAssertEqual(s.note("main")?.dirty, false, "the same text is not an edit")
        s.edit(main: "hello!", now: 50)
        XCTAssertEqual(s.note("main")?.u, 101, "u never goes back with a clock that did")
        s.set(local("n_1", body: "other", u: 1, base: 1, dirty: false))
        s.set(local("n_2", body: "gone", u: 1, base: 1, dirty: true, deleted: true))
        XCTAssertEqual(s.others.map(\.id), ["n_1"])
        XCTAssertEqual(Set(s.dirty.map(\.id)), ["main", "n_2"])
        s.since = 999
        s.restart(mainBody: "local text", now: 300)
        XCTAssertEqual(s.since, 0); XCTAssertEqual(s.notes.count, 1)
        XCTAssertEqual(s.note("main")?.base, nil); XCTAssertEqual(s.note("main")?.dirty, true)
        s.restart(mainBody: "", now: 400)
        XCTAssertTrue(s.notes.isEmpty, "an empty note is not uploaded")
        let enc = try? JSONEncoder().encode(s)
        XCTAssertNotNil(enc)
    }

    func testAppendedAndName() {
        let o = NoteLocal(id: "n", title: "Call notes", body: "Budget 500", u: 1, base: 1, dirty: false, deleted: false)
        XCTAssertEqual(NotesMerge.appended("Main", o), "Main\n\nCall notes\nBudget 500")
        XCTAssertEqual(NotesMerge.appended("", o), "Call notes\nBudget 500")
        XCTAssertEqual(NotesMerge.appended("Main\n", o), "Main\n\nCall notes\nBudget 500")
        XCTAssertEqual(o.name, "Call notes")
        XCTAssertEqual(NoteLocal(id: "n", title: " ", body: "\nFirst line\nsecond", u: 1, base: nil, dirty: false, deleted: false).name, "First line")
        XCTAssertEqual(NoteLocal(id: "n", title: "", body: "", u: 1, base: nil, dirty: false, deleted: false).name, "Note")
    }

    func testWire() {
        let env = #"{"v":1,"alg":"A256GCM","kid":"a8398741ee383df1","n":"oKGio6Slpqeoqaqr","ct":"nToIRDGnZ51YR8+2axav/FyOO3/2zmBWvkJP6BqLRF28Oi6RygJhH3O+ceozS7TPdyt2eFLgKk5xbnbsZglhRT4ljQxoF4a90uNc"}"#
        let list = #"{"ok":true,"ws":"pf_a","notes":[{"id":"main","u":5,"r":6,"d":false,"s":120,"env":\#(env)},{"id":"n_2","u":7,"r":8,"d":true,"s":0},{"id":"bad","u":1,"r":1,"d":false}],"more":true,"next_since":7,"now":9}"#
        guard let page = NotesWire.listPage(Data(list.utf8)) else { return XCTFail("no page") }
        XCTAssertEqual(page.notes.map(\.id), ["main", "n_2"], "a live note without an envelope is dropped")
        XCTAssertEqual(page.notes[0].env?.kid, "a8398741ee383df1"); XCTAssertEqual(page.notes[0].env?.nonce.count, 12)
        XCTAssertTrue(page.notes[1].deleted); XCTAssertNil(page.notes[1].env)
        XCTAssertTrue(page.more); XCTAssertEqual(page.nextSince, 7)
        XCTAssertNil(NotesWire.listPage(Data(#"{"ok":false,"error":"unauthorized"}"#.utf8)))

        XCTAssertEqual(NotesWire.write(status: 200, Data(#"{"ok":true,"id":"main","u":11,"r":12}"#.utf8)), .ok(u: 11, rev: nil))
        XCTAssertEqual(NotesWire.write(status: 200, Data(#"{"ok":true,"id":"main","u":11,"r":12,"rev":"0a1b2c3d"}"#.utf8)), .ok(u: 11, rev: "0a1b2c3d"))
        let c = NotesWire.write(status: 409, Data(#"{"ok":false,"error":"conflict","current":{"id":"main","u":9,"r":9,"d":false,"env":\#(env)}}"#.utf8))
        if case .conflict(let r) = c { XCTAssertEqual(r.u, 9) } else { XCTFail("conflict") }
        XCTAssertEqual(NotesWire.write(status: 410, Data(#"{"ok":false,"error":"gone"}"#.utf8)), .gone)
        XCTAssertEqual(NotesWire.write(status: 409, Data(#"{"ok":false,"error":"key_mismatch","kid":"0000000000000000"}"#.utf8)), .keyMismatch)
        XCTAssertEqual(NotesWire.write(status: 413, Data(#"{"ok":false,"error":"too_many_notes"}"#.utf8)), .failed("This workspace has too many synced notes."))

        let pb = NotesWire.putBody(ws: "pf_a", id: "main", env: NoteEnvelope.parse(JSONRead.object(Data(env.utf8)))!, u: 5, base: nil)
        XCTAssertTrue(pb["base"] is NSNull, "a new note says base null")
        XCTAssertEqual(pb["u"] as? Int, 5)
        XCTAssertEqual(NotesWire.deleteBody(ws: "w", id: "i", u: 1, base: 4)["base"] as? Int, 4)
        XCTAssertEqual(NotesWire.kid(Data(#"{"ok":true,"kid":"a8398741ee383df1"}"#.utf8)), "a8398741ee383df1")
        XCTAssertNil(NotesWire.kid(Data(#"{"ok":true,"kid":null}"#.utf8)))
    }

    // MARK: review fixes

    func testLostWriteBecomesAConflictCopy() {
        var mine = local(body: "mine", u: 10, base: 10, dirty: false)
        mine.rev = "aaaa1111"
        var theirs = remote(body: "theirs", u: 11)
        theirs.rev = "bbbb2222"; theirs.h = ["0000ffff"]
        guard case .setWithCopy(let n, let copy) = NotesMerge.pulled(local: mine, remote: theirs, newId: "n_c", now: 50) else { return XCTFail("a write replaced unseen") }
        XCTAssertEqual(n.body, "theirs"); XCTAssertEqual(n.rev, "bbbb2222")
        XCTAssertEqual(copy.body, "mine"); XCTAssertEqual(copy.id, "n_c"); XCTAssertTrue(copy.dirty); XCTAssertNil(copy.base)
        theirs.h = ["0000ffff", "aaaa1111"]
        XCTAssertEqual(NotesMerge.pulled(local: mine, remote: theirs), .set(.clean(theirs)), "made on top of this device's write: no copy")
        var old = theirs; old.rev = nil; old.h = []
        XCTAssertEqual(NotesMerge.pulled(local: mine, remote: old), .set(.clean(old)), "an older server: no detection, as before")
        var same = theirs; same.h = []; same.body = "mine"
        XCTAssertEqual(NotesMerge.pulled(local: mine, remote: same), .set(.clean(same)), "the same text needs no copy")
    }

    func testPurgeElsewhereAndOldState() throws {
        XCTAssertTrue(NotesMerge.purgedElsewhere(purgedAt: 200, joinedAt: 100))
        XCTAssertFalse(NotesMerge.purgedElsewhere(purgedAt: 50, joinedAt: 100), "a purge before this Mac joined is history")
        XCTAssertFalse(NotesMerge.purgedElsewhere(purgedAt: nil, joinedAt: 100))
        XCTAssertFalse(NotesMerge.purgedElsewhere(purgedAt: 200, joinedAt: nil))
        let old = #"{"notes":[{"id":"main","title":"","body":"x","u":1,"base":1,"dirty":false,"deleted":false}],"since":5}"#
        let st = try JSONDecoder().decode(NotesSyncState.self, from: Data(old.utf8))
        XCTAssertEqual(st.since, 5); XCTAssertNil(st.cursor); XCTAssertNil(st.joinedAt); XCTAssertNil(st.notes[0].rev, "an older state still reads")
        var s = st; s.cursor = 9; s.after = "k"; s.joinedAt = 3
        s.restart(mainBody: "y", now: 10)
        XCTAssertNil(s.cursor); XCTAssertNil(s.after); XCTAssertNil(s.joinedAt)
    }

    func testListPageCursorFields() {
        let list = #"{"ok":true,"ws":"pf_a","notes":[{"id":"n_2","u":7,"r":8,"d":true,"s":0,"rev":"0a0a0a0a","h":["01010101"],"q":12}],"more":true,"next_since":8,"next_after":"n_2","next_cursor":12,"purged_at":90,"now":100}"#
        guard let page = NotesWire.listPage(Data(list.utf8)) else { return XCTFail("no page") }
        XCTAssertEqual(page.nextAfter, "n_2"); XCTAssertEqual(page.nextCursor, 12); XCTAssertEqual(page.purgedAt, 90); XCTAssertEqual(page.now, 100)
        XCTAssertEqual(page.notes[0].rev, "0a0a0a0a"); XCTAssertEqual(page.notes[0].h, ["01010101"])
        let q1 = NotesWire.listQuery(ws: "pf_a", since: 5, after: nil, cursor: nil)
        XCTAssertEqual(q1.map { $0.0 + "=" + $0.1 }, ["ws=pf_a", "since=5", "after="], "after is always sent: the server pages by (r, id)")
        XCTAssertEqual(NotesWire.listQuery(ws: "pf_a", since: 5, after: "k", cursor: 7).map { $0.0 + "=" + $0.1 }, ["ws=pf_a", "cursor=7"])
        let old = NotesWire.listPage(Data(#"{"ok":true,"notes":[],"more":false,"next_since":3}"#.utf8))
        XCTAssertNil(old?.nextCursor); XCTAssertNil(old?.purgedAt)
    }

    func testStateKeysAreTheMembersAndMigrateOnce() {
        guard let d = UserDefaults(suiteName: "notes-keys-test-\(UUID().uuidString)") else { return XCTFail("defaults") }
        d.set("synced", forKey: NotesKeys.legacyMode("pf_a"))
        d.set(Data([1, 2]), forKey: NotesKeys.legacyState("pf_a"))
        NotesKeys.adoptLegacy(d, member: "mem_1", ws: "pf_a")
        XCTAssertEqual(d.string(forKey: NotesKeys.mode("pf_a", member: "mem_1")), "synced")
        XCTAssertEqual(d.data(forKey: NotesKeys.state("pf_a", member: "mem_1")), Data([1, 2]))
        XCTAssertNil(d.object(forKey: NotesKeys.legacyMode("pf_a")), "moved, not copied")
        NotesKeys.adoptLegacy(d, member: "mem_2", ws: "pf_a")
        XCTAssertNil(d.object(forKey: NotesKeys.mode("pf_a", member: "mem_2")), "a second member does not inherit the first's state")
        XCTAssertTrue(NotesKeys.mode("pf_a", member: "mem_1") != NotesKeys.mode("pf_a", member: "mem_2"))
    }

    func testStatusLines() {
        XCTAssertEqual(NotesSyncStatus.off.line, "Saved on this Mac as you type.")
        XCTAssertEqual(NotesSyncStatus.synced.line, "Synced")
        XCTAssertTrue(NotesSyncStatus.offline.line.hasPrefix("Offline"))
    }
}
