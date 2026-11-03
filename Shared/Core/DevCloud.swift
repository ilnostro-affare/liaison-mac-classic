import Foundation

// Dev's cloud. One per workspace, born with Dev: it cannot be renamed and no second one is
// made; only what is inside changes (internet, keys, sites, environment variables, a setup script). Every Dev step
// re-reads it on the server, so a change reaches Dev at its next step. Key values are never sent back.
// Contract: lia-agents (GET /agents/dev/cloud, POST /agents/dev/cloud, /cloud/secret, /cloud/secret/delete);
// every call answers {ok, cloud}; an error is {ok:false, error:"<sentence>"}.

/// One key: Dev uses it only for its sites (the header is added there), never sees its value.
struct DevCloudSecret: Equatable, Identifiable {
    let id: String
    let name: String
    let hosts: [String]
    let paths: [String]
    let header: String
    let prefix: String
    let at: Double
    /// The server holds a value for it.
    let set: Bool

    static let defaultHeader = "Authorization"
    static let defaultPrefix = "Bearer"

    init(id: String, name: String, hosts: [String], paths: [String] = [], header: String = DevCloudSecret.defaultHeader,
         prefix: String = DevCloudSecret.defaultPrefix, at: Double = 0, set: Bool = true) {
        self.id = id; self.name = name; self.hosts = hosts; self.paths = paths
        self.header = header; self.prefix = prefix; self.at = at; self.set = set
    }

    init?(json o: JSONObject) {
        let i = (JSONRead.string(o, "id") ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let n = (JSONRead.string(o, "name") ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !i.isEmpty || !n.isEmpty else { return nil }
        id = i.isEmpty ? n : i
        name = n
        hosts = JSONRead.strings(o, "hosts").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        paths = JSONRead.strings(o, "paths").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        // A missing header is the default one; a missing prefix too (an empty one is "no prefix").
        let h = (JSONRead.string(o, "header") ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        header = h.isEmpty ? Self.defaultHeader : h
        prefix = o["prefix"] == nil ? Self.defaultPrefix : (JSONRead.string(o, "prefix") ?? "").trimmingCharacters(in: .whitespaces)
        at = JSONRead.double(o, "at") ?? 0
        set = o["set"] == nil ? true : JSONRead.bool(o, "set")
    }

    /// The grey line under the name: its sites ("api.stripe.com, *.stripe.com"), else "No website".
    var sitesText: String { hosts.isEmpty ? "No website" : hosts.joined(separator: ", ") }

    /// The advanced settings differ from the defaults (the form opens its Advanced part).
    var hasAdvanced: Bool { !paths.isEmpty || header != Self.defaultHeader || prefix != Self.defaultPrefix }
}

struct DevCloud: Equatable {
    var internet: Bool
    var sites: [String]
    var env: [String: String]
    var setup: String
    /// When it was last edited (ms; 0: never).
    var at: Double
    /// false: the server cannot store keys yet (a note; Add key is off).
    var keysReady: Bool
    var secrets: [DevCloudSecret]

    init(internet: Bool = true, sites: [String] = [], env: [String: String] = [:], setup: String = "", at: Double = 0,
         keysReady: Bool = true, secrets: [DevCloudSecret] = []) {
        self.internet = internet; self.sites = sites; self.env = env; self.setup = setup; self.at = at
        self.keysReady = keysReady; self.secrets = secrets
    }

    init(json o: JSONObject) {
        internet = o["internet"] == nil ? true : JSONRead.bool(o, "internet")
        sites = JSONRead.strings(o, "sites").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        var e: [String: String] = [:]
        for (k, v) in (o["env"] as? JSONObject) ?? [:] where !k.isEmpty {
            if let s = v as? String { e[k] = s } else if let n = v as? NSNumber, !JSONRead.isBool(v) { e[k] = n.stringValue }
        }
        env = e
        setup = JSONRead.string(o, "setup") ?? ""
        at = JSONRead.double(o, "at") ?? 0
        keysReady = o["keys_ready"] == nil ? true : JSONRead.bool(o, "keys_ready")
        secrets = JSONRead.objects(o, "secrets").compactMap { DevCloudSecret(json: $0) }
    }

    /// `{ok:true, cloud}` -> the cloud; `{ok:false, error}` (or anything unreadable) -> its words.
    static func parse(_ data: Data) -> Result<DevCloud, DevFilesError> {
        guard let o = JSONRead.object(data) else { return .failure(DevFilesError("Could not read Dev's cloud.")) }
        guard JSONRead.bool(o, "ok"), let c = o["cloud"] as? JSONObject else {
            let e = (JSONRead.string(o, "error") ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            return .failure(DevFilesError(e.isEmpty ? "Could not read Dev's cloud." : e))
        }
        return .success(DevCloud(json: c))
    }

    /// The header cell's small status: "Internet off", else "2 keys", else "1 site", else "Online".
    var cellStatus: String {
        if !internet { return "Internet off" }
        if !secrets.isEmpty { return secrets.count == 1 ? "1 key" : "\(secrets.count) keys" }
        if !sites.isEmpty { return sites.count == 1 ? "1 site" : "\(sites.count) sites" }
        return "Online"
    }

    /// The cell's status before the cloud was read (nil: "Cloud" alone).
    static func cellStatus(_ c: DevCloud?) -> String? { c?.cellStatus }

    /// The Internet toggle's line.
    static func internetLine(_ on: Bool) -> String {
        on ? "Dev can reach the web, install packages and call APIs." : "Dev works offline."
    }

    /// The environment variables as editor rows, by name.
    var envRows: [DevCloudEnvRow] { env.keys.sorted().map { DevCloudEnvRow(name: $0, value: env[$0] ?? "") } }

    // MARK: normalisation (the server does the same; the Mac does it to show and check before sending)

    /// "https://API.Stripe.com/v1/x" -> "api.stripe.com"; "*.Stripe.com" stays a wildcard. "" when nothing is left.
    static func host(_ raw: String) -> String {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if let r = s.range(of: "://") { s = String(s[r.upperBound...]) }
        if let at = s.firstIndex(of: "@") { s = String(s[s.index(after: at)...]) }
        if let cut = s.firstIndex(where: { $0 == "/" || $0 == "?" || $0 == "#" }) { s = String(s[..<cut]) }
        if let colon = s.lastIndex(of: ":") { s = String(s[..<colon]) }
        while s.hasSuffix(".") { s.removeLast() }
        return s
    }

    /// A host the server accepts: "api.stripe.com" or "*.stripe.com" (a dot, letters, digits and dashes).
    static func isHost(_ h: String) -> Bool {
        var s = Substring(h)
        if s.hasPrefix("*.") { s = s.dropFirst(2) }
        guard s.contains("."), !s.hasPrefix("."), !s.contains("..") else { return false }
        return s.allSatisfy { ($0.isASCII && ($0.isLetter || $0.isNumber)) || $0 == "-" || $0 == "." }
    }

    /// The list with one more site (normalised); nil when it is not a host or is already there.
    static func adding(site raw: String, to list: [String]) -> [String]? {
        let h = host(raw)
        guard isHost(h), !list.contains(h) else { return nil }
        return list + [h]
    }

    /// Several hosts typed into one field ("api.stripe.com, files.stripe.com"), normalised, without repeats.
    static func hosts(_ raw: String) -> [String] {
        var out: [String] = []
        for part in raw.split(whereSeparator: { $0 == "," || $0 == "\n" || $0 == " " }) {
            let h = host(String(part))
            if !h.isEmpty, !out.contains(h) { out.append(h) }
        }
        return out
    }

    /// "stripe key" -> "STRIPE_KEY": upper case, anything else than letters and digits as one "_", none at the ends;
    /// a leading digit gets a "_" before it.
    static func envName(_ raw: String) -> String {
        var out = ""
        var gap = false
        for c in raw.trimmingCharacters(in: .whitespacesAndNewlines) {
            if c.isASCII && (c.isLetter || c.isNumber) {
                if gap && !out.isEmpty { out.append("_") }
                gap = false
                out.append(contentsOf: String(c).uppercased())
            } else {
                gap = true
            }
        }
        if let f = out.first, f.isNumber { out = "_" + out }
        return out
    }

    /// Path prefixes typed with commas or one per line: trimmed, each starting with "/", without repeats.
    static func paths(_ raw: String) -> [String] {
        var out: [String] = []
        for part in raw.split(whereSeparator: { $0 == "," || $0 == "\n" }) {
            var p = part.trimmingCharacters(in: .whitespaces)
            guard !p.isEmpty else { continue }
            if !p.hasPrefix("/") { p = "/" + p }
            if !out.contains(p) { out.append(p) }
        }
        return out
    }

    /// The editor's rows as the `env` object: names normalised, empty names dropped, a later row wins.
    static func env(_ rows: [DevCloudEnvRow]) -> [String: String] {
        var out: [String: String] = [:]
        for r in rows {
            let n = envName(r.name)
            if !n.isEmpty { out[n] = r.value }
        }
        return out
    }
}

/// One NAME=value row of the Advanced editor.
struct DevCloudEnvRow: Equatable, Identifiable {
    let id: UUID
    var name: String
    var value: String
    init(id: UUID = UUID(), name: String = "", value: String = "") { self.id = id; self.name = name; self.value = value }
}

/// The request bodies (profile is the workspace id).
enum DevCloudBody {
    /// POST /agents/dev/cloud: only what changes.
    static func cloud(profile: String, internet: Bool? = nil, sites: [String]? = nil, env: [String: String]? = nil,
                      setup: String? = nil) -> JSONObject {
        var b: JSONObject = ["profile": profile]
        if let internet { b["internet"] = internet }
        if let sites { b["sites"] = sites }
        if let env { b["env"] = env }
        if let setup { b["setup"] = setup }
        return b
    }

    /// POST /agents/dev/cloud/secret. `id` edits an existing key; an empty `value` on an edit keeps the current one.
    /// An empty header is the default; the prefix goes as typed (empty: no prefix).
    static func secret(profile: String, id: String? = nil, name: String, value: String, hosts: [String],
                       paths: [String] = [], header: String = DevCloudSecret.defaultHeader,
                       prefix: String = DevCloudSecret.defaultPrefix) -> JSONObject {
        var b: JSONObject = ["profile": profile, "name": DevCloud.envName(name), "hosts": hosts, "paths": paths]
        if let id, !id.isEmpty { b["id"] = id }
        if !value.isEmpty { b["value"] = value }
        let h = header.trimmingCharacters(in: .whitespacesAndNewlines)
        b["header"] = h.isEmpty ? DevCloudSecret.defaultHeader : h
        b["prefix"] = prefix.trimmingCharacters(in: .whitespaces)
        return b
    }

    /// POST /agents/dev/cloud/secret/delete.
    static func deleteSecret(profile: String, id: String) -> JSONObject { ["profile": profile, "id": id] }

    /// What is wrong with a key form before it is sent (nil: it can go).
    static func secretProblem(isNew: Bool, name: String, value: String, hosts: [String]) -> String? {
        if DevCloud.envName(name).isEmpty { return "Give the key a name." }
        if isNew && value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return "Paste the key." }
        if hosts.isEmpty { return "Add the website this key is for." }
        if let bad = hosts.first(where: { !DevCloud.isHost($0) }) { return "\u{201c}\(bad)\u{201d} is not a website address." }
        return nil
    }
}

// MARK: - the Sites editor (one field, one site per line, `*.domain.com` allowed)

/// What the Sites editor's text says: the hosts it saves, and the lines that cannot be saved (with the reason).
/// Server rules (lia-devcloud.js cloudHost / cloudHostMatch): "api.x.com" or "*.x.com" (letters, digits, dashes and
/// dots, at least two labels after "*."); "*.x.com" matches every sub-host of x.com but not x.com itself; at most 50.
struct DevCloudSitesDraft: Equatable {
    struct Problem: Equatable {
        /// 1-based line number in the editor.
        let line: Int
        /// What was typed (trimmed).
        let text: String
        let reason: String

        /// "Line 3: \u{201c}foo\u{201d} - not a website address."
        var message: String { "Line \(line): \u{201c}\(text)\u{201d} \u{2014} \(reason)" }
    }

    let hosts: [String]
    let problems: [Problem]
    /// Repeats left out (the same host twice, or written two ways).
    let repeats: Int

    var isValid: Bool { problems.isEmpty }
}

enum DevCloudSites {
    /// The server keeps at most this many.
    static let limit = 50

    /// The editor's text for the saved list: one host per line.
    static func text(_ sites: [String]) -> String { sites.joined(separator: "\n") }

    /// Parses the editor: a site per line (commas and spaces split too, so a pasted list works); blank lines and
    /// "#" comments are skipped. Each entry is trimmed, its scheme, path, port and user dropped, lower-cased; repeats
    /// are dropped; an entry that is not a host is reported with its line.
    static func parse(_ text: String) -> DevCloudSitesDraft {
        var hosts: [String] = []
        var problems: [DevCloudSitesDraft.Problem] = []
        var repeats = 0
        let lines = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
            .split(separator: "\n", omittingEmptySubsequences: false)
        for (i, rawLine) in lines.enumerated() {
            var line = String(rawLine)
            if let hash = line.firstIndex(of: "#") { line = String(line[..<hash]) }
            for part in line.split(whereSeparator: { $0 == "," || $0 == ";" || $0 == " " || $0 == "\t" }) {
                let typed = part.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !typed.isEmpty else { continue }
                let h = DevCloud.host(typed)
                if let why = problem(h) {
                    problems.append(.init(line: i + 1, text: typed, reason: why))
                } else if hosts.contains(h) {
                    repeats += 1
                } else if hosts.count >= limit {
                    problems.append(.init(line: i + 1, text: typed, reason: "over the limit of \(limit) sites."))
                } else {
                    hosts.append(h)
                }
            }
        }
        return DevCloudSitesDraft(hosts: hosts, problems: problems, repeats: repeats)
    }

    /// Why a normalised host cannot be saved (nil: it can).
    static func problem(_ h: String) -> String? {
        if h.isEmpty { return "not a website address." }
        if h == "*" || h == "*." { return "a wildcard needs a domain, as in *.example.com." }
        let rest = h.hasPrefix("*.") ? String(h.dropFirst(2)) : h
        if rest.contains("*") { return "use * only at the start, as in *.example.com." }
        if !rest.allSatisfy({ ($0.isASCII && ($0.isLetter || $0.isNumber)) || $0 == "-" || $0 == "." }) {
            return "only letters, digits, dashes and dots."
        }
        if rest.hasPrefix(".") || rest.contains("..") { return "not a website address." }
        if !rest.contains(".") {
            return h.hasPrefix("*.") ? "a wildcard needs a domain, as in *.example.com." : "not a website address (no domain ending such as .com)."
        }
        return DevCloud.isHost(h) ? nil : "not a website address."
    }

    /// The editor's text differs from the saved list (as a list: order and repeats count, spacing does not).
    static func changed(_ text: String, from sites: [String]) -> Bool {
        let d = parse(text)
        return !d.problems.isEmpty || d.hosts != sites
    }
}
