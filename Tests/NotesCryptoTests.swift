import XCTest
import Foundation
@testable import Liaison

#if canImport(CryptoKit)
/// The real AES-GCM (CryptoKit) against the shared notes-format test vector, which the web client's tests open
/// with WebCrypto: the Mac, the web and the phone read one format.
/// Mac only (no CryptoKit on Linux; the pure half is NotesSyncTests).
final class NotesCryptoTests: XCTestCase {
    private let key = Data((0..<32).map { UInt8($0) })

    func testSpecVectorOpens() throws {
        let env = try XCTUnwrap(NoteEnvelope.parse([
            "v": 1, "alg": "A256GCM", "kid": "a8398741ee383df1", "n": "oKGio6Slpqeoqaqr",
            "ct": "nToIRDGnZ51YR8+2axav/FyOO3/2zmBWvkJP6BqLRF28Oi6RygJhH3O+ceozS7TPdyt2eFLgKk5xbnbsZglhRT4ljQxoF4a90uNc",
        ] as [String: Any]))
        XCTAssertEqual(NotesKeyring.kid(key), "a8398741ee383df1")
        let p = NotesCrypto.open(env, ws: "pf_test", id: "main", key: key, kid: "a8398741ee383df1", cipher: CryptoKitNotesCipher())
        XCTAssertEqual(p, NotePlain(title: "Hello", body: "Line 1\nLine 2", u: 1760000000000))
        XCTAssertNil(NotesCrypto.open(env, ws: "pf_test", id: "other", key: key, kid: "a8398741ee383df1", cipher: CryptoKitNotesCipher()))
    }

    func testSealOpenWithAFreshNonce() throws {
        let c = CryptoKitNotesCipher(), kid = NotesKeyring.kid(key)
        let p = NotePlain(title: "", body: "Secret", u: 1)
        let a = try NotesCrypto.seal(p, ws: "w", id: "main", key: key, kid: kid, cipher: c)
        let b = try NotesCrypto.seal(p, ws: "w", id: "main", key: key, kid: kid, cipher: c)
        XCTAssertNotEqual(a.nonce, b.nonce)
        XCTAssertEqual(a.nonce.count, 12)
        XCTAssertEqual(NotesCrypto.open(a, ws: "w", id: "main", key: key, kid: kid, cipher: c), p)
        XCTAssertEqual(NotesKeyring.newKey().count, 32)
    }
}
#endif
