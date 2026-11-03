import Foundation
import CryptoKit

/// Browser extensions, step one: turns a folder, a .zip, a .crx or a Chrome Web Store id into an unpacked folder
/// with a manifest.json, staged next to the installed ones (`ExtensionsHost` asks the person, then moves it in).
/// Nothing here needs WebKit: it runs on macOS 14 too (the host refuses to load there).
enum ExtensionsInstaller {
    /// The one suggestion offered in Settings (its Chrome Web Store id). 0.2.11: 1Password's preset is gone (its
    /// extension unlocks through the 1Password app's native messaging, which WebKit cannot reach; it still installs
    /// from its store link, at the person's own choice).
    static let bitwardenID = "nngceckbapebfimnlniiiahkandclblb"

    enum Source {
        case folder(URL)
        case zip(URL)
        case crx(URL)
        case store(String)
    }

    /// An unpacked extension waiting for the person's yes.
    struct Staged {
        let dir: URL
        let id: String
        let name: String
        let version: String
        /// Asks for every website (`<all_urls>`, `*://*/*`, http(s)://*/*), in permissions or content scripts.
        let allSites: Bool
        /// The API permissions it asks for (tabs, storage, contextMenus...), as written in the manifest.
        let permissions: [String]
        let source: String
    }

    struct Failure: LocalizedError {
        let message: String
        init(_ m: String) { message = m }
        var errorDescription: String? { message }
    }

    /// ~/Library/Application Support/Liaison/Extensions
    static var root: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("Liaison/Extensions", isDirectory: true)
    }

    static func folder(for id: String) -> URL { root.appendingPathComponent(id, isDirectory: true) }

    // MARK: staging

    static func stage(_ source: Source) async throws -> Staged {
        let work = root.appendingPathComponent(".staging/" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        do {
            let unpacked = work.appendingPathComponent("x", isDirectory: true)
            var origin = "file"
            switch source {
            case .folder(let u):
                try FileManager.default.copyItem(at: u, to: unpacked)
            case .zip(let u):
                try await unzip(u, to: unpacked)
            case .crx(let u):
                let zip = work.appendingPathComponent("p.zip")
                try zipPayload(ofCRX: Data(contentsOf: u)).write(to: zip)
                try await unzip(zip, to: unpacked)
            case .store(let raw):
                guard let id = storeID(raw) else { throw Failure("This isn\u{2019}t a Chrome Web Store link. Copy the address of the extension\u{2019}s page and paste it here.") }
                let zip = work.appendingPathComponent("p.zip")
                try zipPayload(ofCRX: await download(id)).write(to: zip)
                try await unzip(zip, to: unpacked)
                origin = "store:" + id
            }
            guard let dir = manifestFolder(in: unpacked) else { throw Failure("This isn\u{2019}t a browser extension (there is no manifest.json in it).") }
            // Chrome's signed-content folder: of no use to WebKit.
            try? FileManager.default.removeItem(at: dir.appendingPathComponent("_metadata"))
            return try describe(dir, origin: origin)
        } catch {
            try? FileManager.default.removeItem(at: work)
            throw error
        }
    }

    /// Drops a staged folder (the person said no).
    static func discard(_ s: Staged) { cleanStaging() }

    /// Moves a staged folder to Extensions/<id>/, replacing an older version.
    static func commit(_ s: Staged) throws -> URL {
        let dest = folder(for: s.id)
        let fm = FileManager.default
        if fm.fileExists(atPath: dest.path) { try fm.removeItem(at: dest) }
        try fm.moveItem(at: s.dir, to: dest)
        cleanStaging()
        return dest
    }

    static func cleanStaging() {
        try? FileManager.default.removeItem(at: root.appendingPathComponent(".staging"))
    }

    static func remove(id: String) {
        try? FileManager.default.removeItem(at: folder(for: id))
    }

    // MARK: Chrome Web Store

    /// A 32-letter id (a-p), alone or inside a chromewebstore.google.com / chrome.google.com/webstore link.
    static func storeID(_ raw: String) -> String? { ChromeStore.id(raw) }

    /// 0.2.11: the update service answered 204 to the fixed prodversion 126 (older than what current extensions
    /// require, see ChromeStore). Tries today's Chrome version first, then the fallbacks; the first CRX wins.
    static func download(_ id: String) async throws -> Data {
        var arm = false
        #if arch(arm64)
        arm = true
        #endif
        var offline = false
        for url in ChromeStore.downloadURLs(id, arm: arm) {
            var req = URLRequest(url: url)
            req.timeoutInterval = 60
            req.setValue(ChromeStore.userAgent(), forHTTPHeaderField: "User-Agent")
            do {
                let (data, response) = try await URLSession.shared.data(for: req)
                let code = (response as? HTTPURLResponse)?.statusCode ?? 0
                if code == 200, ChromeStore.isPackage(data) { return data }
                NSLog("[extensions] store %@ answered %d (%d bytes) for %@", id, code, data.count, url.query ?? "")
            } catch {
                NSLog("[extensions] store %@: %@", id, error.localizedDescription)
                offline = (error as? URLError).map { [.notConnectedToInternet, .networkConnectionLost, .cannotFindHost, .timedOut].contains($0.code) } ?? false
                if offline { break }
            }
        }
        throw Failure(offline ? "Couldn\u{2019}t reach the Chrome Web Store. Check your internet connection."
                              : "Couldn\u{2019}t download this extension. Check the link.")
    }

    // MARK: CRX

    /// The zip inside a CRX: CRX3 ("Cr24", version 3, header length, protobuf header) or CRX2 ("Cr24", version 2,
    /// key length, signature length, key, signature). A plain zip comes back unchanged.
    static func zipPayload(ofCRX data: Data) throws -> Data {
        let b = [UInt8](data)
        if b.count >= 4, b[0] == 0x50, b[1] == 0x4B, b[2] == 0x03, b[3] == 0x04 { return data }
        guard b.count >= 12, b[0] == 0x43, b[1] == 0x72, b[2] == 0x32, b[3] == 0x34 else {
            throw Failure("This file isn\u{2019}t a browser extension.")
        }
        func u32(_ at: Int) -> Int { Int(b[at]) | Int(b[at + 1]) << 8 | Int(b[at + 2]) << 16 | Int(b[at + 3]) << 24 }
        let version = u32(4)
        let start: Int
        switch version {
        case 3: start = 12 + u32(8)
        case 2:
            guard b.count >= 16 else { throw Failure("Couldn\u{2019}t open this file. It may be damaged.") }
            start = 16 + u32(8) + u32(12)
        default: throw Failure("This extension\u{2019}s package format isn\u{2019}t supported.")
        }
        guard start + 4 <= b.count, b[start] == 0x50, b[start + 1] == 0x4B else { throw Failure("Couldn\u{2019}t open this file. It may be damaged.") }
        return Data(b[start...])
    }

    // MARK: unzip

    /// `/usr/bin/ditto -x -k` (the app is not sandboxed), off the main thread.
    static func unzip(_ zip: URL, to dest: URL) async throws {
        try FileManager.default.createDirectory(at: dest, withIntermediateDirectories: true)
        let status: Int32 = try await Task.detached {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
            p.arguments = ["-x", "-k", zip.path, dest.path]
            p.standardOutput = FileHandle.nullDevice
            p.standardError = FileHandle.nullDevice
            try p.run()
            p.waitUntilExit()
            return p.terminationStatus
        }.value
        if status != 0 { throw Failure("Couldn\u{2019}t open this file. It may be damaged.") }
    }

    // MARK: manifest

    /// The folder holding manifest.json: the root, or its only subfolder (a zipped folder).
    static func manifestFolder(in dir: URL) -> URL? {
        let fm = FileManager.default
        if fm.fileExists(atPath: dir.appendingPathComponent("manifest.json").path) { return dir }
        let subs = (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.isDirectoryKey]))?
            .filter { !$0.lastPathComponent.hasPrefix(".") && !$0.lastPathComponent.hasPrefix("__MACOSX") } ?? []
        for s in subs where fm.fileExists(atPath: s.appendingPathComponent("manifest.json").path) { return s }
        return nil
    }

    static func manifest(in dir: URL) -> [String: Any]? {
        guard let d = try? Data(contentsOf: dir.appendingPathComponent("manifest.json")) else { return nil }
        // Some manifests carry a BOM or comments Chrome tolerates; the BOM at least.
        let clean = d.starts(with: [0xEF, 0xBB, 0xBF]) ? d.dropFirst(3) : d
        return (try? JSONSerialization.jsonObject(with: Data(clean))) as? [String: Any]
    }

    static func describe(_ dir: URL, origin: String) throws -> Staged {
        guard let m = manifest(in: dir) else { throw Failure("This extension\u{2019}s manifest.json couldn\u{2019}t be read.") }
        let name = localized(m["name"] as? String ?? "", in: dir, manifest: m)
        let version = m["version"] as? String ?? ""
        var hosts: [String] = []
        var perms: [String] = []
        for key in ["permissions", "host_permissions"] {
            for p in m[key] as? [String] ?? [] {
                if p.contains("://") || p == "<all_urls>" { hosts.append(p) } else if key == "permissions" { perms.append(p) }
            }
        }
        for cs in m["content_scripts"] as? [[String: Any]] ?? [] { hosts += cs["matches"] as? [String] ?? [] }
        let wide: Set<String> = ["<all_urls>", "*://*/*", "http://*/*", "https://*/*"]
        let id: String
        if origin.hasPrefix("store:") { id = String(origin.dropFirst(6)) }
        else if let key = m["key"] as? String, let k = chromeID(publicKey: key) { id = k }
        else { id = slug(name.isEmpty ? dir.lastPathComponent : name) }
        return Staged(dir: dir, id: id, name: name.isEmpty ? id : name, version: version,
                      allSites: hosts.contains { wide.contains($0) }, permissions: perms, source: origin.hasPrefix("store:") ? "store" : "file")
    }

    /// "__MSG_extName__" from _locales/<default_locale or en>/messages.json.
    static func localized(_ s: String, in dir: URL, manifest m: [String: Any]) -> String {
        guard s.hasPrefix("__MSG_"), s.hasSuffix("__") else { return s }
        let key = String(s.dropFirst(6).dropLast(2)).lowercased()
        for loc in [m["default_locale"] as? String, "en", "en_US"].compactMap({ $0 }) {
            let f = dir.appendingPathComponent("_locales/\(loc)/messages.json")
            guard let d = try? Data(contentsOf: f), let j = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any] else { continue }
            for (k, v) in j where k.lowercased() == key {
                if let msg = (v as? [String: Any])?["message"] as? String { return msg }
            }
        }
        return s
    }

    /// Chrome's id for a manifest "key": SHA-256 of the DER key, first 16 bytes, each nibble 0-f written as a-p.
    static func chromeID(publicKey: String) -> String? {
        guard let der = Data(base64Encoded: publicKey, options: .ignoreUnknownCharacters) else { return nil }
        let digest = SHA256.hash(data: der)
        let letters = Array("abcdefghijklmnop")
        var out = ""
        for byte in digest.prefix(16) { out.append(letters[Int(byte >> 4)]); out.append(letters[Int(byte & 0x0F)]) }
        return out
    }

    static func slug(_ s: String) -> String {
        let allowed = Set("abcdefghijklmnopqrstuvwxyz0123456789-")
        let t = String(s.lowercased().map { allowed.contains($0) ? $0 : "-" }).split(separator: "-").joined(separator: "-")
        return t.isEmpty ? "ext-" + String(UUID().uuidString.prefix(8)).lowercased() : String(t.prefix(48))
    }

    /// The manifest's largest icon up to 128 px (Settings shows it even when the extension is not loaded).
    static func iconFile(in dir: URL) -> URL? {
        guard let m = manifest(in: dir) else { return nil }
        var icons = m["icons"] as? [String: String] ?? [:]
        if icons.isEmpty, let a = (m["action"] ?? m["browser_action"]) as? [String: Any] {
            if let d = a["default_icon"] as? [String: String] { icons = d }
            else if let s = a["default_icon"] as? String { icons = ["16": s] }
        }
        let best = icons.compactMap { k, v in Int(k).map { ($0, v) } }.filter { $0.0 <= 128 }.max { $0.0 < $1.0 }
        guard let path = best?.1 ?? icons.values.first else { return nil }
        return dir.appendingPathComponent(path.hasPrefix("/") ? String(path.dropFirst()) : path)
    }
}
