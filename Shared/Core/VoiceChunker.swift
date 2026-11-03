import Foundation

// Voice input: the Mac records 16 kHz mono 16-bit, cuts the speech
// into chunks at a pause (>= 400 ms of quiet after speech) or at 8 s, and sends each chunk at once to
// POST /agents/voice/transcribe (google/gemini-2.5-flash-lite on OpenRouter, ~$0.0006 a minute). The server takes
// 2.4-3.7 s a chunk, so meanwhile Apple's on-device recognizer writes a live DRAFT from the same audio: the draft of a
// chunk shows at once and the server's text replaces it when it comes (VoiceAssembly). A chunk without speech is never
// sent. The take stops by itself after 20 s without speech and at 5 minutes; the server also holds 30 s a chunk, 5 min
// a take and 60 min a member a UTC day. Answers come back in any order and are put together in seq order. Everything
// here is pure (no audio, no network): ChatDictation.swift drives it.

enum VoiceChunker {
    static let sampleRate = 16000
    static let route = "/agents/voice/transcribe"
    static let prevMax = 400

    /// A 16 kHz mono 16-bit PCM WAV (44-byte header, little-endian).
    static func wav(_ samples: [Int16]) -> Data {
        let dataBytes = samples.count * 2
        var d = Data(capacity: 44 + dataBytes)
        func u32(_ v: UInt32) { var x = v.littleEndian; withUnsafeBytes(of: &x) { d.append(contentsOf: $0) } }
        func u16(_ v: UInt16) { var x = v.littleEndian; withUnsafeBytes(of: &x) { d.append(contentsOf: $0) } }
        d.append(contentsOf: Array("RIFF".utf8)); u32(UInt32(36 + dataBytes)); d.append(contentsOf: Array("WAVE".utf8))
        d.append(contentsOf: Array("fmt ".utf8)); u32(16); u16(1); u16(1); u32(UInt32(sampleRate)); u32(UInt32(sampleRate * 2)); u16(2); u16(16)
        d.append(contentsOf: Array("data".utf8)); u32(UInt32(dataBytes))
        for s in samples { u16(UInt16(bitPattern: s)) }
        return d
    }

    static func seconds(_ samples: [Int16]) -> Double { Double(samples.count) / Double(sampleRate) }

    /// The root mean square of a frame, 0...1.
    static func rms(_ samples: ArraySlice<Int16>) -> Double {
        guard !samples.isEmpty else { return 0 }
        var sum = 0.0
        for s in samples { let x = Double(s) / 32768.0; sum += x * x }
        return (sum / Double(samples.count)).squareRoot()
    }

    /// The request body of one chunk.
    /// `agent`: whose composer it is; the server books the cost to that agent (unknown or nil -> Lia).
    static func body(samples: [Int16], take: String, seq: Int, lang: String?, prev: String, agent: String? = nil) -> JSONObject {
        var b: JSONObject = ["audio": wav(samples).base64EncodedString(), "seconds": (seconds(samples) * 1000).rounded() / 1000,
                             "take": take, "seq": seq]
        if let lang, !lang.isEmpty { b["lang_hint"] = lang }
        if let agent, !agent.isEmpty { b["agent"] = agent }
        let p = String(prev.suffix(prevMax))
        if !p.isEmpty { b["prev"] = p }
        return b
    }
}

/// The live draft's language: picked by itself, never from the keyboard layout, the system locale alone
/// or a setting. A take starts with the language last detected (saved), else the first preferred language Apple's
/// recognizer supports; each server answer of >= 3 words is the truth for its language (the App file runs
/// NLLanguageRecognizer on it), and when that differs from the draft's locale and a supported locale exists, the next
/// stretches switch to it. Pure string logic on locale identifiers ("en-US" and "en_US" are the same).
enum VoiceLocale {
    static let serverMinWords = 3
    static let draftMinWords = 4
    static let draftMinConfidence = 0.5
    static let defaultsKey = "voice.draftLocale"

    /// "en_US" -> "en-US".
    static func normal(_ id: String) -> String { id.replacingOccurrences(of: "_", with: "-") }
    /// The language code, lowercased ("pt-BR" -> "pt", "zh-Hans-CN" -> "zh").
    static func language(_ id: String) -> String {
        String(normal(id).split(separator: "-").first ?? "").lowercased()
    }
    /// The region code, uppercased, when the identifier has one ("zh-Hans-CN" -> "CN", "en" -> nil).
    static func region(_ id: String) -> String? {
        let parts = normal(id).split(separator: "-").dropFirst()
        return parts.first(where: { $0.count == 2 || ($0.count == 3 && $0.allSatisfy(\.isNumber)) }).map { $0.uppercased() }
    }

    /// The usual region of a language when the person's own languages name none.
    private static let usualRegion: [String: String] = [
        "en": "US", "es": "ES", "pt": "BR", "zh": "CN", "ja": "JP", "ko": "KR", "uk": "UA", "sv": "SE", "da": "DK",
        "nb": "NO", "cs": "CZ", "el": "GR", "he": "IL", "hi": "IN", "vi": "VN", "ar": "SA", "ms": "MY", "ca": "ES",
    ]

    /// The best supported locale for a language: the person's own preferred locale of that language when supported,
    /// else a supported one in a region from the person's preferred languages, else the language's usual region
    /// ("fr" -> "fr-FR", "en" -> "en-US"), else the first in order. nil when no supported locale speaks it.
    static func best(for lang: String, supported: [String], preferred: [String]) -> String? {
        let l = language(lang)
        guard !l.isEmpty else { return nil }
        let cands = supported.map(normal).filter { language($0) == l }.sorted()
        guard !cands.isEmpty else { return nil }
        let pref = preferred.map(normal)
        for p in pref where language(p) == l {
            if let hit = cands.first(where: { $0.lowercased() == p.lowercased() }) { return hit }
            if let r = region(p), let hit = cands.first(where: { region($0) == r }) { return hit }
        }
        for p in pref { if let r = region(p), let hit = cands.first(where: { region($0) == r }) { return hit } }
        let usual = usualRegion[l] ?? l.uppercased()
        if let hit = cands.first(where: { region($0) == usual }) { return hit }
        return cands[0]
    }

    /// The locale a take starts with: the saved one when still supported, else the first preferred language that has
    /// a supported locale. nil: the draft is skipped (server only).
    static func initial(saved: String?, preferred: [String], supported: [String]) -> String? {
        let sup = supported.map(normal)
        if let s = saved.map(normal), let hit = sup.first(where: { $0.lowercased() == s.lowercased() }) { return hit }
        for p in preferred { if let hit = best(for: language(p), supported: sup, preferred: preferred) { return hit } }
        return nil
    }

    enum Decision: Equatable {
        /// Keep the draft's locale.
        case stay
        /// The next stretches are drafted in this locale (and it is saved for the next take).
        case use(String)
        /// The person speaks a language Apple's recognizer has no locale for: no draft for the rest of the take.
        case unsupported
    }

    /// After a server answer: what the draft does next. `detected` is the language the answer is in (nil when
    /// unsure); answers shorter than 3 words never change anything.
    static func decide(detected: String?, words: Int, current: String?, supported: [String], preferred: [String]) -> Decision {
        guard words >= serverMinWords, let d = detected.map(language), !d.isEmpty, d != "und" else { return .stay }
        if let c = current, language(c) == d { return .stay }
        return best(for: d, supported: supported, preferred: preferred).map { .use($0) } ?? .unsupported
    }

    /// A draft of >= 4 words whose own language scores under 0.5 for its locale is doubtful (likely noise heard as
    /// words); it is still shown until the server's text comes, and a server "silence" then clears it.
    static func draftDoubtful(words: Int, confidence: Double?) -> Bool {
        words >= draftMinWords && (confidence ?? 0) < draftMinConfidence
    }
}

/// Why a take stopped by itself.
enum VoiceStopReason: Equatable {
    case silence, takeLimit

    var message: String {
        switch self {
        case .silence: return "Stopped: no speech for 20 seconds"
        case .takeLimit: return "Stopped after 5 minutes"
        }
    }
}

/// What the cutter decided after some audio.
enum VoiceCut: Equatable {
    case chunk([Int16])
    case stop(VoiceStopReason)
}

/// The cutting decisions, fed with 16 kHz samples in pieces of any size (split here into 20 ms frames). A simple
/// energy VAD: a frame is speech when its RMS is over max(minLevel, noise floor x floorRatio); the floor follows the
/// quiet frames slowly.
struct VoiceCutter {
    struct Config: Equatable {
        var frameMs = 20
        var pauseMs = 400
        var maxChunkMs = 8_000
        var idleStopMs = 20_000
        var takeMaxMs = 300_000
        var minSpeechMs = 160
        var preRollMs = 300
        var minLevel = 0.01
        var floorRatio = 3.0
    }

    let cfg: Config
    private(set) var stopped = false
    private(set) var takeMs = 0
    /// Some stretch of this take held enough speech to be sent (>= minSpeechMs over the threshold).
    private(set) var heardSpeech = false
    /// The loudest 20 ms frame of the take (RMS, 0...1): the log's "is the mic giving any sound at all".
    private(set) var peak = 0.0
    private var buf: [Int16] = []
    private var carry: [Int16] = []
    private var speechMs = 0
    private var silenceRun = 0
    private var sinceSpeech = 0
    private var floor = 0.003

    init(_ cfg: Config = Config()) { self.cfg = cfg }

    private var frameLen: Int { VoiceChunker.sampleRate * cfg.frameMs / 1000 }
    private func ms(_ n: Int) -> Int { n * 1000 / VoiceChunker.sampleRate }

    /// The threshold now (for tests and a level meter).
    var threshold: Double { max(cfg.minLevel, floor * cfg.floorRatio) }

    mutating func feed(_ samples: [Int16]) -> [VoiceCut] {
        guard !stopped else { return [] }
        carry.append(contentsOf: samples)
        var out: [VoiceCut] = []
        let n = frameLen
        var i = 0
        while carry.count - i >= n, !stopped {
            let frame = carry[i..<(i + n)]
            i += n
            out += step(frame)
        }
        carry.removeFirst(i)
        return out
    }

    private mutating func step(_ frame: ArraySlice<Int16>) -> [VoiceCut] {
        let level = VoiceChunker.rms(frame)
        let speech = level > threshold
        peak = max(peak, level)
        if !speech { floor = floor * 0.95 + min(level, 0.05) * 0.05 }
        buf.append(contentsOf: frame)
        takeMs += cfg.frameMs
        var out: [VoiceCut] = []
        if speech {
            speechMs += cfg.frameMs; silenceRun = 0; sinceSpeech = 0
            if speechMs >= cfg.minSpeechMs { heardSpeech = true }
        } else {
            sinceSpeech += cfg.frameMs
            if speechMs > 0 { silenceRun += cfg.frameMs }
            else {
                // no speech yet in this chunk: keep only a short lead-in, so a quiet room is never sent
                let keep = VoiceChunker.sampleRate * cfg.preRollMs / 1000
                if buf.count > keep { buf.removeFirst(buf.count - keep) }
            }
        }
        if speechMs > 0 && silenceRun >= cfg.pauseMs { if let c = cut() { out.append(c) } }
        else if ms(buf.count) >= cfg.maxChunkMs { if let c = cut() { out.append(c) } }
        if takeMs >= cfg.takeMaxMs {
            if let c = cut() { out.append(c) }
            stopped = true
            out.append(.stop(.takeLimit))
        } else if sinceSpeech >= cfg.idleStopMs {
            if let c = cut() { out.append(c) }
            stopped = true
            out.append(.stop(.silence))
        }
        return out
    }

    /// The chunk so far, when it holds enough speech; the buffer starts again either way.
    private mutating func cut() -> VoiceCut? {
        defer { buf = []; speechMs = 0; silenceRun = 0 }
        return speechMs >= cfg.minSpeechMs ? .chunk(buf) : nil
    }

    /// The person stopped: the last chunk, if it holds speech. Nothing more is taken after this.
    mutating func finish() -> [Int16]? {
        guard !stopped else { return nil }
        stopped = true
        buf.append(contentsOf: carry)
        carry = []
        if case .chunk(let s)? = cut() { return s }
        return nil
    }
}

/// The take's text, chunk by chunk in seq order, whatever order the answers come back in.
/// Each chunk has a draft (Apple's recognizer, at once) and, later, the server's text, which replaces the draft. An
/// empty server answer (silence) clears the chunk only when its draft is short (<= 2 words) or doubtful, since otherwise
/// the server more likely failed; a failed chunk (nil) keeps its draft, so nothing said is lost. `live` is the recognizer's partial
/// for the stretch being recorded now (not cut yet); it is shown at the end.
struct VoiceAssembly: Equatable {
    private enum Answer: Equatable { case server(String), keepDraft }

    /// The number of chunks cut so far (seq 0..<count).
    private(set) var count = 0
    /// The live partial of the stretch not cut yet.
    var live = ""
    private var drafts: [Int: String] = [:]
    private var answers: [Int: Answer] = [:]
    private var doubtful: Set<Int> = []

    /// What one chunk shows now.
    func piece(_ seq: Int) -> String {
        if case .server(let t)? = answers[seq] { return t }
        return drafts[seq] ?? ""
    }

    /// Every cut chunk in order (no live tail).
    var committed: String { (0..<count).reduce("") { Self.join($0, piece($1)) } }
    /// The whole transcript: the chunks in order, then the live partial.
    var text: String { Self.join(committed, live) }
    /// The start of `text` that is final - the chunks in order up to the first one without its answer
    /// (a kept draft counts as answered). Always a prefix of `text`; the rest is draft (shown in a shell).
    var settled: String {
        var out = ""
        for seq in 0..<count {
            guard answers[seq] != nil else { break }
            out = Self.join(out, piece(seq))
        }
        return out
    }
    /// How many characters at the end of `text` are not final yet.
    var draftTail: Int { max(0, text.count - settled.count) }

    /// The last 400 characters before chunk `seq`, the context sent with it.
    func prev(before seq: Int) -> String { String((0..<min(seq, count)).reduce("") { Self.join($0, piece($1)) }.suffix(VoiceChunker.prevMax)) }
    /// The last 400 characters of every cut chunk.
    var prev: String { String(committed.suffix(VoiceChunker.prevMax)) }
    /// Some cut chunk has no answer yet.
    var hasWaiting: Bool { (0..<count).contains { answers[$0] == nil } }

    /// The cutter cut chunk `seq`: the live partial so far becomes its draft and the live tail starts again.
    mutating func cut(seq: Int) {
        guard seq >= 0, drafts[seq] == nil, answers[seq] == nil else { return }
        drafts[seq] = live.trimmingCharacters(in: .whitespacesAndNewlines)
        live = ""
        count = max(count, seq + 1)
    }

    /// The recognizer's later (final) words for a chunk already cut; ignored once the server's text is in.
    @discardableResult
    mutating func setDraft(seq: Int, text t: String) -> Bool {
        guard seq >= 0, seq < count else { return false }
        if case .server? = answers[seq] { return false }
        let before = text
        drafts[seq] = t.trimmingCharacters(in: .whitespacesAndNewlines)
        return text != before
    }

    /// The draft of chunk `seq` reads as noise for its locale (VoiceLocale.draftDoubtful): it stays on screen, but an
    /// empty server answer clears it whatever its length.
    mutating func markDoubtful(seq: Int) { if seq >= 0 && seq < count { doubtful.insert(seq) } }

    /// The server's answer for one chunk (nil: it failed) -> true when the text changed. The first answer wins.
    @discardableResult
    mutating func put(seq: Int, text piece: String?) -> Bool {
        guard seq >= 0, answers[seq] == nil else { return false }
        let before = text
        count = max(count, seq + 1)
        let draft = drafts[seq] ?? ""
        if let p = piece?.trimmingCharacters(in: .whitespacesAndNewlines) {
            answers[seq] = (p.isEmpty && Self.words(draft) > 2 && !doubtful.contains(seq)) ? .keepDraft : .server(p)
        } else {
            answers[seq] = .keepDraft
        }
        return text != before
    }

    static func words(_ s: String) -> Int { s.split(whereSeparator: { $0.isWhitespace }).count }

    static func join(_ a: String, _ b: String) -> String {
        let p = b.trimmingCharacters(in: .whitespacesAndNewlines)
        if p.isEmpty { return a }
        if a.isEmpty { return p }
        if let f = p.first, ",.!?;:)\u{2026}".contains(f) { return a + p }
        return a + " " + p
    }
}

/// The server's answer to one chunk.
/// The day's voice minutes by plan (Free 20, Pro 60, Max 120; server lia-voice.js voicePlan). Read
/// from GET /agents/voice/quota and from every transcribe answer; past the limit the mic goes dim with `tip`.
struct VoiceQuota: Equatable {
    var plan: String
    var limitMinutes: Int
    var nextPlan: String?
    var nextLimitMinutes: Int?
    /// Seconds left today; nil when the answer did not say.
    var leftSeconds: Double?

    var exhausted: Bool { (leftSeconds ?? 1) <= 0.5 }

    static func name(_ plan: String) -> String { plan.isEmpty ? plan : plan.prefix(1).uppercased() + plan.dropFirst() }

    /// The mic's tooltip once today's minutes are used.
    var tip: String {
        let used = "You\u{2019}ve used today\u{2019}s \(limitMinutes) minutes of voice input."
        if let n = nextPlan, let m = nextLimitMinutes { return used + " Upgrade to \(Self.name(n)) for \(m) minutes a day." }
        return used + " It resets tomorrow."
    }

    static func parse(_ o: JSONObject) -> VoiceQuota? {
        guard let plan = JSONRead.string(o, "plan"), let lim = (o["limit_minutes"] as? NSNumber)?.intValue, lim > 0 else { return nil }
        return VoiceQuota(plan: plan, limitMinutes: lim, nextPlan: JSONRead.string(o, "next_plan"),
                          nextLimitMinutes: (o["next_limit_minutes"] as? NSNumber)?.intValue,
                          leftSeconds: (o["left_seconds"] as? NSNumber)?.doubleValue)
    }
}

struct VoiceReply: Equatable {
    /// The words heard ("" for silence); nil when this chunk failed.
    var text: String?
    /// A message for the person.
    var error: String?
    /// Stop the take (a limit, or voice is not available).
    var stop = false
    /// The plan's minutes and what is left (nil when the answer did not carry them).
    var quota: VoiceQuota?
    /// The HTTP status (nil: no answer at all - offline, timeout, signed out) and the server's error code, for the log.
    var status: Int? = nil
    var code: String? = nil

    static let dailyLimit = "Voice limit for today reached"

    static func parse(_ o: JSONObject, status: Int) -> VoiceReply {
        let code = (JSONRead.string(o, "error") ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        var r = parseBody(o, status: status, code: code)
        r.status = status
        r.code = code.isEmpty ? nil : code
        return r
    }

    private static func parseBody(_ o: JSONObject, status: Int, code: String) -> VoiceReply {
        let q = VoiceQuota.parse(o)
        if (200..<300).contains(status), (o["ok"] as? Bool) ?? true {
            return VoiceReply(text: (JSONRead.string(o, "text") ?? "").trimmingCharacters(in: .whitespacesAndNewlines), quota: q)
        }
        if code == "voice_daily_limit" {
            var spent = q
            spent?.leftSeconds = 0
            return VoiceReply(text: nil, error: spent?.tip ?? dailyLimit, stop: true, quota: spent)
        }
        if code == "voice_take_limit" { return VoiceReply(text: nil, error: VoiceStopReason.takeLimit.message, stop: true) }
        if status == 404 || status == 405 || status == 503 { return VoiceReply(text: nil, error: "Voice input isn\u{2019}t available right now.", stop: true) }
        if status == 429 { return VoiceReply(text: nil, error: "Usage limit reached. Try again later.", stop: true) }
        return VoiceReply(text: nil, error: nil, stop: false)
    }
}
