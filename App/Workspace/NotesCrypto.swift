import Foundation
import CryptoKit
import Security

// The Mac's half of the notes encryption (format: the shared notes format; pure parts: Shared/Core/NotesSync.swift).

/// AES-256-GCM through CryptoKit: a fresh random 12-byte nonce per seal, `ct` = ciphertext + 16-byte tag.
struct CryptoKitNotesCipher: NotesCipher {
    func seal(_ plaintext: Data, key: Data, aad: Data) throws -> (nonce: Data, ct: Data) {
        let box = try AES.GCM.seal(plaintext, using: SymmetricKey(data: key), nonce: AES.GCM.Nonce(), authenticating: aad)
        return (box.nonce.withUnsafeBytes { Data($0) }, box.ciphertext + box.tag)
    }

    func open(nonce: Data, ct: Data, key: Data, aad: Data) throws -> Data {
        guard ct.count >= 16 else { throw CryptoKitError.incorrectParameterSize }
        let box = try AES.GCM.SealedBox(nonce: AES.GCM.Nonce(data: nonce), ciphertext: ct.prefix(ct.count - 16), tag: ct.suffix(16))
        return try AES.GCM.open(box, using: SymmetricKey(data: key), authenticating: aad)
    }
}

enum NotesKeyring {
    /// The key's fingerprint the server keeps: SHA-256("liaison-notes-kid-v1" || key), first 8 bytes, hex.
    static func kid(_ key: Data) -> String { NotesCrypto.hex(Data(SHA256.hash(data: NotesCrypto.kidInput(key))).prefix(8)) }

    static func newKey() -> Data { SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) } }

    enum Place: Equatable { case iCloud, thisMac }

    private static func query(_ member: String, modern: Bool) -> [String: Any] {
        var q: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                kSecAttrService as String: NotesKeys.keychainService,
                                kSecAttrAccount as String: member]
        if modern {
            q[kSecUseDataProtectionKeychain as String] = true
            q[kSecAttrSynchronizable as String] = kSecAttrSynchronizableAny
        }
        return q
    }

    /// The member's content key and where it is kept, or nil.
    static func load(member: String) -> (key: Data, place: Place)? {
        for modern in [true, false] {
            var q = query(member, modern: modern)
            q[kSecReturnData as String] = true
            q[kSecReturnAttributes as String] = true
            q[kSecMatchLimit as String] = kSecMatchLimitOne
            var out: AnyObject?
            guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let a = out as? [String: Any],
                  let d = a[kSecValueData as String] as? Data, d.count == 32 else { continue }
            let synced = (a[kSecAttrSynchronizable as String] as? Bool) ?? ((a[kSecAttrSynchronizable as String] as? NSNumber)?.boolValue ?? false)
            // 0.2.11: a key an earlier build kept in the login keychain moves to iCloud Keychain once this build may
            // use it (added there first; the old copy goes only after that succeeded, so the key is never lost).
            if !modern, migrateToICloud(d, member: member) { return (d, .iCloud) }
            return (d, modern && synced ? .iCloud : .thisMac)
        }
        return nil
    }

    /// Saves the key, best place first, -> where it went (nil when no keychain took it):
    /// 1. iCloud Keychain: a synchronizable item in the data-protection keychain. Needs a keychain access group, which
    /// the signed app has when it carries `keychain-access-groups` or `com.apple.application-identifier` (both come
    /// with the Developer ID provisioning profile, scripts/build-local.sh); without one macOS answers
    /// errSecMissingEntitlement (-34018).
    /// 2. The data-protection keychain on this Mac only (same entitlement; an account without iCloud Keychain sync).
    /// 3. The login keychain (an ad-hoc or profile-less build): this Mac only.
    @discardableResult
    static func save(_ key: Data, member: String) -> Place? {
        // Never delete first. Deleting the synchronizable item (kSecAttrSynchronizableAny) made iCloud Keychain
        // delete it on every other Mac too, the one whose key the synced notes use included. An item that is there
        // is updated in place; one is added only when none is.
        backup(key, member: member)
        if let cur = load(member: member) {
            if cur.key == key { return cur.place }
            let upd = [kSecValueData as String: key] as CFDictionary
            for modern in [true, false] where SecItemUpdate(query(member, modern: modern) as CFDictionary, upd) == errSecSuccess {
                return load(member: member)?.place ?? cur.place
            }
        }
        for sync in [true, false] {
            var add = query(member, modern: true)
            add[kSecAttrSynchronizable as String] = sync
            add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
            add[kSecAttrLabel as String] = "Liaison notes key"
            add[kSecValueData as String] = key
            let st = SecItemAdd(add as CFDictionary, nil)
            if st == errSecSuccess { return sync ? .iCloud : .thisMac }
            NSLog("[notes] keychain (data protection, sync %d): %d", sync ? 1 : 0, Int(st))
            // No access group at all: the non-synchronizable try would fail the same way.
            if st == errSecMissingEntitlement { break }
        }
        var local = query(member, modern: false)
        local[kSecAttrLabel as String] = "Liaison notes key"
        local[kSecValueData as String] = key
        let st = SecItemAdd(local as CFDictionary, nil)
        if st == errSecSuccess { return .thisMac }
        NSLog("[notes] keychain (login): %d", Int(st))
        return nil
    }

    private static func migrateToICloud(_ key: Data, member: String) -> Bool {
        var add = query(member, modern: true)
        add[kSecAttrSynchronizable as String] = true
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        add[kSecAttrLabel as String] = "Liaison notes key"
        add[kSecValueData as String] = key
        guard SecItemAdd(add as CFDictionary, nil) == errSecSuccess else { return false }
        SecItemDelete(query(member, modern: false) as CFDictionary)
        return true
    }

    /// An add-only copy under the key's own fingerprint (account "member#kid"), synchronizable when allowed.
    /// Two Macs that made keys at once write one `member` item and iCloud keeps one of them; the copies keep both,
    /// so the Mac whose key lost the item still finds the account's key by the server's kid.
    private static func backup(_ key: Data, member: String) {
        for sync in [true, false] {
            var add = query(member + "#" + kid(key), modern: true)
            add[kSecAttrSynchronizable as String] = sync
            add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
            add[kSecAttrLabel as String] = "Liaison notes key"
            add[kSecValueData as String] = key
            let st = SecItemAdd(add as CFDictionary, nil)
            if st == errSecSuccess || st == errSecDuplicateItem || st == errSecMissingEntitlement { return }
        }
    }

    /// The member's key whose fingerprint is `want` (the server's kid): the main item, else its copy.
    static func load(member: String, kid want: String) -> Data? {
        if let k = load(member: member), kid(k.key) == want { return k.key }
        if let k = load(member: member + "#" + want), kid(k.key) == want { return k.key }
        return nil
    }

    static func delete(member: String) {
        for modern in [true, false] { SecItemDelete(query(member, modern: modern) as CFDictionary) }
    }
}
