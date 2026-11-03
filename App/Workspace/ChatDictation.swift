import SwiftUI
import AVFoundation
import AppKit
import Speech
import NaturalLanguage
import OSLog

// Dictation in the composer. Hold the mic to talk (release stops) or click to start and click again to
// stop. The live transcript goes into the field.
// (server): the mic is captured with AVAudioEngine, converted to 16 kHz mono 16-bit, and cut at a
// pause or a length (Shared/Core/VoiceChunker.swift: a simple energy VAD); each chunk with speech goes at once to
// POST /agents/voice/transcribe (gemini-2.5-flash-lite on OpenRouter, ~$0.0006 a minute). Answers are put together in
// seq order; `prev` carries the last 400 characters. Silent audio is never sent. The take stops by itself after 20 s
// without speech and at 5 minutes; the server's daily limit by plan (Free 20, Pro 60, Max 120 minutes) stops it, keeps
// what was said and dims the mic with a tooltip naming the next plan (`limitTip`).
// (hybrid,: "a very big delay, it looks like it doesn't work"): the server takes 2.4-3.7 s a chunk, so
// the words used to appear 3-15 s late. Now Apple's SFSpeechRecognizer writes a live DRAFT from the same tap (the
// original-format buffers, on-device when the Mac supports it: free and fast), and chunks are cut sooner (400 ms pause,
// 8 s max). Each cut freezes the draft of that stretch as the chunk's draft (`VoiceAssembly.cut`), ends that request and
// starts a new one; the field shows, per chunk in order, the server's text when it has come, else the draft, then the
// live partial. The server's text replaces the draft; a failed chunk keeps its draft, so nothing said is lost. The
// draft's language is picked by itself (Shared/Core VoiceLocale): the language last detected (saved), else the first
// preferred language the recognizer supports; every server answer of >= 3 words is run through NLLanguageRecognizer
// and, if it is another supported language, the next stretches switch to it (and it is saved); a language with no
// recognizer locale ends the draft for the take (server only). Speech recognition denied or unavailable: no draft, the
// server path works as before.
// Needs NSMicrophoneUsageDescription and NSSpeechRecognitionUsageDescription in Info.plist and, in the sandbox,
// com.apple.security.device.audio-input.

// (on dcf82d7, macOS 27: "voice input does not work at all"; the server saw no transcribe request from
// that build, only the quota GETs): the take could die without a word. Now (1) the tap takes the bus's own format
// (nil) and converts per buffer whatever format comes, channel 0 first, so a device with another rate or several
// channels cannot leave it silent; the samples for the server are taken BEFORE the buffer is handed to the recognizer;
// (2) a watchdog restarts the engine when no buffer came for 2.5 s, and AVAudioEngineConfigurationChange (input
// switched, the engine stopped by the system) restarts it as well; three restarts and it stops with a message;
// (3) every take ends with a visible message when nothing came of it (no sound, no speech, every chunk failed);
// (4) the button's press can no longer stick when a system prompt (the speech permission) cancels the gesture;
// (5) every step is in the unified log at notice level:
// log show --predicate 'subsystem == "com.liaisone.mac" AND category == "voice"' --info --last 10m

/// Hands the mic's buffers, on the audio thread, to the recognition request of the stretch being recorded.
private final class SpeechFeed: @unchecked Sendable {
    private let lock = NSLock()
    private var request: SFSpeechAudioBufferRecognitionRequest?

    func append(_ buffer: AVAudioPCMBuffer) {
        lock.lock()
        let r = request
        lock.unlock()
        r?.append(buffer)
    }

    /// Puts `new` in place and gives back the request it replaced.
    @discardableResult
    func swap(_ new: SFSpeechAudioBufferRecognitionRequest?) -> SFSpeechAudioBufferRecognitionRequest? {
        lock.lock()
        defer { lock.unlock() }
        let old = request
        request = new
        return old
    }
}

/// Turns each tap buffer, whatever its format, into 16 kHz mono Int16. Used only on the tap's own thread (one call at a
/// time), so it keeps its converter without a lock; a new input format gets a new converter.
private final class TapConverter: @unchecked Sendable {
    private let out: AVAudioFormat
    private var conv: AVAudioConverter?
    private var from: AVAudioFormat?
    private var loggedFailure = false

    init?() {
        guard let o = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: Double(VoiceChunker.sampleRate), channels: 1, interleaved: true) else { return nil }
        out = o
    }

    /// The samples of one buffer ([] while the converter is still filling); nil when it cannot convert at all.
    func convert(_ buffer: AVAudioPCMBuffer) -> [Int16]? {
        guard buffer.frameLength > 0, buffer.format.sampleRate > 0 else { return [] }
        let src = Self.mono(buffer) ?? buffer
        if conv == nil || from != src.format {
            from = src.format
            conv = AVAudioConverter(from: src.format, to: out)
            let rate = Int(src.format.sampleRate), ch = Int(src.format.channelCount), made = conv == nil ? "FAILED" : "ok"
            ChatDictation.log.notice("voice: converter \(rate) Hz \(ch) ch -> 16000 Hz mono: \(made, privacy: .public)")
        }
        guard let conv else { return nil }
        let cap = AVAudioFrameCount(Double(src.frameLength) * out.sampleRate / src.format.sampleRate) + 64
        guard let o = AVAudioPCMBuffer(pcmFormat: out, frameCapacity: cap) else { return nil }
        var fed = false
        var err: NSError?
        let status = conv.convert(to: o, error: &err) { _, st in
            if fed { st.pointee = .noDataNow; return nil }
            fed = true
            st.pointee = .haveData
            return src
        }
        if status == .error {
            if !loggedFailure {
                loggedFailure = true
                ChatDictation.log.notice("voice: conversion failed: \(err?.localizedDescription ?? "unknown", privacy: .public)")
            }
            return nil
        }
        guard o.frameLength > 0, let ch = o.int16ChannelData else { return [] }
        return Array(UnsafeBufferPointer(start: ch[0], count: Int(o.frameLength)))
    }

    /// Channel 0 of a float buffer with several channels, as a mono buffer of the same rate (a mic array or an
    /// interface with many inputs: the converter is never asked to map channels). nil: use the buffer as it is.
    private static func mono(_ b: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        guard b.format.channelCount > 1, let src = b.floatChannelData,
              let f = AVAudioFormat(standardFormatWithSampleRate: b.format.sampleRate, channels: 1),
              let m = AVAudioPCMBuffer(pcmFormat: f, frameCapacity: b.frameLength), let dst = m.floatChannelData else { return nil }
        let n = Int(b.frameLength)
        m.frameLength = b.frameLength
        if b.format.isInterleaved {
            let stride = Int(b.stride)
            for i in 0..<n { dst[0][i] = src[0][i * stride] }
        } else {
            dst[0].update(from: src[0], count: n)
        }
        return m
    }
}

@MainActor
final class ChatDictation: ObservableObject {
    nonisolated static let log = Logger(subsystem: "com.liaisone.mac", category: "voice")

    @Published private(set) var listening = false
    /// What was heard so far in this take: per chunk the server's words or, until they come, the live draft.
    @Published private(set) var transcript = ""
    /// How many characters at the end of `transcript` are the draft, not the server's words yet (the
    /// composer draws them in a shell until they are replaced).
    @Published private(set) var draftTail = 0
    /// Bumped when the transcript went back to nothing (the server heard only noise): the composer drops the draft.
    @Published private(set) var cleared = 0
    /// Send waits while the last words are replaced, at most `sendHoldMax` seconds (a slow network never locks it).
    @Published private(set) var sendHeld = false
    static let sendHoldMax: TimeInterval = 6
    private var holdGen = 0
    /// A short message for the person when dictation cannot start, broke off or stopped by itself.
    @Published var error: String?
    /// Stopped listening, but chunks are still being transcribed: their words still land in `transcript` (every stop -
    /// the person's, 20 s of silence, 5 minutes, a limit - keeps what was said).
    @Published private(set) var finishing = false {
        didSet {
            guard finishing != oldValue else { return }
            holdGen += 1
            sendHeld = finishing
            guard finishing else { return }
            let g = holdGen
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.sendHoldMax) { [weak self] in
                guard let self, self.holdGen == g else { return }
                self.sendHeld = false
            }
        }
    }
    /// Today's voice minutes are used (Free 20, Pro 60, Max 120): the mic is dim and this is its
    /// tooltip ("Upgrade to Pro for 60 minutes a day"). Cleared on the next UTC day.
    @Published private(set) var limitTip: String?
    private var limitDay: String?

    /// The account the chunks are sent as; nil -> the app's current one.
    var auth: AuthStore?
    /// The agent whose composer this is ("lia", "dev", "crea", "met"): the voice's cost is that agent's in Usage.
    /// nil (the address bar) -> the server books it to Lia.
    var agent: String?

    private var engine: AVAudioEngine?
    private var cutter = VoiceCutter()
    private var assembly = VoiceAssembly()
    private var take = 0
    private var takeId = ""
    private var seq = 0
    private var failures = 0
    private var inflight = 0

    // the take's health (the watchdog, the log, the message at the end)
    private var configObserver: NSObjectProtocol?
    private var watchdog: Timer?
    private var lastAudio = Date()
    private var lastLevelLog = Date()
    private var takeStarted = Date()
    private var buffers = 0
    private var restarts = 0
    private var engineStarted = false
    private var takeClosed = false
    private var chunksOK = 0
    private var chunksFailed = 0

    // the live draft (Apple's recognizer)
    private let feed = SpeechFeed()
    private var recognizer: SFSpeechRecognizer?
    /// The draft's locale ("en-US"); nil: no draft in this take.
    private var draftLocale: String?
    /// The person speaks a language the recognizer has no locale for: no draft for the rest of this take.
    private var draftOff = false
    private var stretch = 0
    private var liveStretch: Int?
    private var stretchSeq: [Int: Int] = [:]
    private var tasks: [Int: SFSpeechRecognitionTask] = [:]

    init(auth: AuthStore? = nil) { self.auth = auth }

    func toggle() { listening ? stop() : start() }

    /// The tooltip while today's minutes are used; nil (and forgotten) once the UTC day has turned.
    var blockedTip: String? { limitDay == Self.utcDay ? limitTip : nil }

    private static var utcDay: String {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: Date())
    }

    private func note(_ q: VoiceQuota?) {
        guard let q else { return }
        if q.exhausted { limitTip = q.tip; limitDay = Self.utcDay } else { limitTip = nil; limitDay = nil }
    }

    private var quotaAsked: Date?

    /// Asks the server once in a while (the composer's appear) whether today's minutes are used, so the mic is dim
    /// before the person presses it.
    func refreshQuota() {
        if let t = quotaAsked, Date().timeIntervalSince(t) < 300 { return }
        quotaAsked = Date()
        guard let a = auth ?? AppModel.current?.auth ?? WorkspaceModel.current?.auth else { return }
        let api = LiaAPI(auth: a)
        Task { [weak self] in
            let q = await api.voiceQuota()
            if let q {
                let plan = q.plan, left = q.leftSeconds ?? -1, lim = q.limitMinutes
                Self.log.notice("voice: quota \(plan, privacy: .public), left \(left) s of \(lim) min")
            } else {
                Self.log.notice("voice: quota unknown (no answer)")
            }
            self?.note(q)
        }
    }

    func start() {
        // a take whose last answer is in can never hold the mic (a count that went wrong must not lock it for good)
        if finishing && inflight == 0 && !listening { finishing = false }
        // the previous take's last words are still coming: a new take now would drop them
        guard !listening, !finishing, blockedTip == nil else {
            let l = listening, f = finishing, b = blockedTip != nil
            Self.log.notice("voice: start ignored (listening \(l), finishing \(f), daily limit \(b))")
            return
        }
        error = nil
        transcript = ""
        draftTail = 0
        listening = true
        take += 1
        takeId = "t" + String(UInt64(Date().timeIntervalSince1970 * 1000), radix: 36) + String(Int.random(in: 0..<1296), radix: 36)
        seq = 0
        failures = 0
        cutter = VoiceCutter()
        assembly = VoiceAssembly()
        endDrafts()
        recognizer = nil
        draftLocale = nil
        draftOff = false
        takeStarted = Date()
        lastLevelLog = Date()
        buffers = 0
        restarts = 0
        engineStarted = false
        takeClosed = false
        chunksOK = 0
        chunksFailed = 0
        let mine = take
        Task { await begin(mine) }
    }

    /// The person stopped: the chunk being recorded is cut and sent (if it holds speech), and every chunk in flight
    /// still adds its words, in order.
    func stop() {
        guard listening || engine != nil else { return }
        let id = takeId
        Self.log.notice("voice \(id, privacy: .public): stop")
        wind(take)
    }

    private func begin(_ mine: Int) async {
        let id = takeId
        let mic = AVCaptureDevice.authorizationStatus(for: .audio)
        let device = AVCaptureDevice.default(for: .audio)?.localizedName ?? "none"
        Self.log.notice("voice \(id, privacy: .public): start; microphone permission \(Self.name(mic), privacy: .public); default input \(device, privacy: .public)")
        // No microphone access -> say so and open the Microphone pane of Privacy & Security
        guard await Self.microphoneAuthorized() else {
            Self.log.notice("voice \(id, privacy: .public): microphone not allowed")
            Self.openMicrophoneSettings()
            return fail(mine, "Turn on Liaison in System Settings \u{203a} Privacy & Security \u{203a} Microphone.")
        }
        guard mine == take, listening else {
            Self.log.notice("voice \(id, privacy: .public): stopped before the microphone started")
            return closeIfIdle(mine)
        }
        guard startEngine(mine) else { return }
        startWatchdog(mine)
        // the draft comes second: the mic never waits on the speech prompt; denied or unavailable -> server only
        let before = SFSpeechRecognizer.authorizationStatus()
        let speechOK = await Self.speechAuthorized()
        Self.log.notice("voice \(id, privacy: .public): speech recognition \(Self.name(before), privacy: .public) -> \(speechOK ? "allowed" : "not allowed (server text only)", privacy: .public)")
        guard speechOK, mine == take, listening else { return }
        let saved = UserDefaults.standard.string(forKey: VoiceLocale.defaultsKey)
        guard let loc = VoiceLocale.initial(saved: saved, preferred: Locale.preferredLanguages, supported: Self.supportedLocales) else {
            let langs = Locale.preferredLanguages.joined(separator: ",")
            Self.log.notice("voice \(id, privacy: .public): no recognizer locale for \(langs, privacy: .public) (server text only)")
            return
        }
        useLocale(loc)
        let onDevice = recognizer?.supportsOnDeviceRecognition ?? false
        let draft = draftLocale ?? "unavailable for \(loc)"
        Self.log.notice("voice \(id, privacy: .public): draft \(draft, privacy: .public), on-device \(onDevice)")
        openStretch(mine)
    }

    // MARK: the engine

    /// A new engine with the tap on the input's own format. false: it could not start (the take failed with a message).
    private func startEngine(_ mine: Int) -> Bool {
        let id = takeId
        let eng = AVAudioEngine()
        let input = eng.inputNode
        let hw = input.inputFormat(forBus: 0)
        let tapFmt = input.outputFormat(forBus: 0)
        let hwRate = Int(hw.sampleRate), hwCh = Int(hw.channelCount), tapRate = Int(tapFmt.sampleRate), tapCh = Int(tapFmt.channelCount)
        Self.log.notice("voice \(id, privacy: .public): input \(hwRate) Hz \(hwCh) ch, tap \(tapRate) Hz \(tapCh) ch")
        guard hw.channelCount > 0, hw.sampleRate > 0, tapFmt.channelCount > 0, tapFmt.sampleRate > 0 else {
            fail(mine, "No microphone found. Check the input device in System Settings \u{203a} Sound.")
            return false
        }
        guard let conv = TapConverter() else {
            fail(mine, "The microphone couldn\u{2019}t start.")
            return false
        }
        Self.installTap(input, converter: conv, feed: feed, sink: { [weak self] samples in self?.heard(mine, samples) })
        eng.prepare()
        do { try eng.start() } catch {
            let why = String(describing: error)
            Self.log.notice("voice \(id, privacy: .public): engine start failed: \(why, privacy: .public)")
            input.removeTap(onBus: 0)
            fail(mine, "The microphone couldn\u{2019}t start.")
            return false
        }
        engine = eng
        engineStarted = true
        lastAudio = Date()
        // the input switched (headphones, another device) or the system stopped the engine: the tap gets nothing more
        configObserver = NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange, object: eng, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.engineChanged(mine) }
        }
        Self.log.notice("voice \(id, privacy: .public): engine running")
        return true
    }

    private func engineChanged(_ mine: Int) {
        guard mine == take, listening else { return }
        let id = takeId
        Self.log.notice("voice \(id, privacy: .public): audio configuration changed; restarting the engine")
        restartEngine(mine)
    }

    private func restartEngine(_ mine: Int) {
        restarts += 1
        teardown()
        guard restarts <= 3 else {
            return halt(mine, "The microphone isn\u{2019}t sending any sound. Check the input device in System Settings \u{203a} Sound.")
        }
        _ = startEngine(mine)
    }

    /// Once a second while listening: no buffer for 2.5 s means the engine is not delivering.
    private func startWatchdog(_ mine: Int) {
        watchdog?.invalidate()
        let t = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick(mine) }
        }
        // .common: the timer also fires while the mouse is held on the mic (event tracking)
        RunLoop.main.add(t, forMode: .common)
        watchdog = t
    }

    private func stopWatchdog() {
        watchdog?.invalidate()
        watchdog = nil
    }

    private func tick(_ mine: Int) {
        guard mine == take, listening, engine != nil else { return }
        let quiet = Date().timeIntervalSince(lastAudio)
        guard quiet > 2.5 else { return }
        let id = takeId, n = buffers, r = restarts
        Self.log.notice("voice \(id, privacy: .public): no audio for \(quiet, format: .fixed(precision: 1)) s (buffers so far \(n), restarts \(r))")
        restartEngine(mine)
    }

    // MARK: audio -> chunks -> server

    private func heard(_ mine: Int, _ samples: [Int16]) {
        guard mine == take, listening else { return }
        lastAudio = Date()
        buffers += 1
        if buffers == 1 {
            let id = takeId
            Self.log.notice("voice \(id, privacy: .public): first audio (\(samples.count) samples)")
        }
        for cut in cutter.feed(samples) {
            switch cut {
            case .chunk(let s): send(s, mine)
            // 20 s of silence with nothing heard at all in this take: the mic gives no sound (muted, wrong input)
            case .stop(let reason):
                halt(mine, reason == .silence && seq == 0 ? "Didn\u{2019}t hear anything. Check the input device in System Settings \u{203a} Sound." : reason.message)
            }
        }
        if Date().timeIntervalSince(lastLevelLog) >= 5 {
            lastLevelLog = Date()
            let id = takeId, n = buffers, p = cutter.peak, th = cutter.threshold, sp = cutter.heardSpeech, c = seq
            Self.log.notice("voice \(id, privacy: .public): buffers \(n), peak \(p, format: .fixed(precision: 4)), threshold \(th, format: .fixed(precision: 4)), speech \(sp), chunks \(c)")
        }
    }

    private func send(_ samples: [Int16], _ mine: Int) {
        let n = seq
        seq += 1
        let prev = assembly.prev(before: n)
        cutStretch(n, mine)
        let body = VoiceChunker.body(samples: samples, take: takeId, seq: n, lang: langHint, prev: prev, agent: agent)
        let id = takeId, secs = VoiceChunker.seconds(samples), lang = langHint ?? "-"
        guard let a = auth ?? AppModel.current?.auth ?? WorkspaceModel.current?.auth else {
            Self.log.notice("voice \(id, privacy: .public): chunk \(n) not sent: signed out")
            return answered(mine, n, VoiceReply(text: nil, error: "Sign in to use voice input.", stop: true))
        }
        Self.log.notice("voice \(id, privacy: .public): chunk \(n) sent (\(secs, format: .fixed(precision: 2)) s, lang \(lang, privacy: .public))")
        let api = LiaAPI(auth: a)
        inflight += 1
        Task { [weak self] in
            let r = await api.voiceTranscribe(body)
            self?.answered(mine, n, r, sent: true)
        }
    }

    private func answered(_ mine: Int, _ n: Int, _ r: VoiceReply, sent: Bool = false) {
        let id = takeId
        let status = r.status.map(String.init) ?? "no answer"
        let code = r.code.map { " " + $0 } ?? ""
        let got = r.text.map { "\($0.count) chars" } ?? "failed"
        let stops = r.stop ? ", stop" : ""
        Self.log.notice("voice \(id, privacy: .public): chunk \(n) answer \(status, privacy: .public)\(code, privacy: .public), \(got, privacy: .public)\(stops, privacy: .public)")
        guard mine == take else { return }
        if sent { inflight = max(0, inflight - 1) }
        if r.text == nil { chunksFailed += 1 } else { chunksOK += 1 }
        note(r.quota)
        if assembly.put(seq: n, text: r.text) { show() }
        if let t = r.text { learnLanguage(t, mine) }
        defer { closeIfIdle(mine) }
        if r.stop {
            halt(mine, r.error)
        } else if r.text == nil {
            failures += 1
            if failures >= 3 { halt(mine, "Couldn\u{2019}t transcribe. Check your connection.") }
        } else {
            failures = 0
        }
    }

    private func show() {
        let t = assembly.text
        // a closed take with nothing in flight has no draft left to replace
        let tail = takeClosed && inflight == 0 ? 0 : assembly.draftTail
        if t != transcript {
            if t.isEmpty && !transcript.isEmpty { cleared += 1 }
            transcript = t
        }
        if tail != draftTail { draftTail = tail }
    }

    /// Stopped by itself (a limit, silence, failures): the message stays; what was said is still finished.
    private func halt(_ mine: Int, _ message: String?) {
        guard mine == take else { return }
        if let message {
            let id = takeId
            Self.log.notice("voice \(id, privacy: .public): stopped by itself: \(message, privacy: .public)")
            error = message
        }
        wind(mine)
    }

    /// Every stop: the mic off at once, the chunk being recorded cut and sent if it holds speech, then `finishing`
    /// until the last answer of this take is in. Drafts of chunks already cut still take their final words.
    private func wind(_ mine: Int) {
        listening = false
        stopWatchdog()
        teardown()
        if let last = cutter.finish() {
            send(last, mine)
        } else {
            // nothing worth sending since the last cut: the live partial goes with it
            if let id = liveStretch { tasks.removeValue(forKey: id)?.cancel() }
            liveStretch = nil
            feed.swap(nil)?.endAudio()
            assembly.live = ""
            show()
        }
        closeIfIdle(mine)
    }

    /// `finishing` follows the answers in flight; once the take is over and its last answer is in, a take that
    /// gave nothing says why (instead of silence): no sound from the mic, no speech, or every chunk failed.
    private func closeIfIdle(_ mine: Int) {
        guard mine == take else { return }
        finishing = !listening && inflight > 0
        guard !listening, inflight == 0, !takeClosed else { return }
        takeClosed = true
        // the take is over: whatever is still a draft stays as written, no longer in its shell
        draftTail = 0
        let id = takeId, secs = Date().timeIntervalSince(takeStarted), n = buffers, p = cutter.peak, sp = cutter.heardSpeech
        let ok = chunksOK, bad = chunksFailed, chars = transcript.count
        Self.log.notice("voice \(id, privacy: .public): take done in \(secs, format: .fixed(precision: 1)) s; buffers \(n), peak \(p, format: .fixed(precision: 4)), speech \(sp), chunks ok \(ok) failed \(bad), \(chars) chars in the field")
        guard error == nil, engineStarted else { return }
        let message: String?
        if n == 0 && secs >= 1.5 {
            message = "The microphone isn\u{2019}t sending any sound. Check the input device in System Settings \u{203a} Sound."
        } else if !sp && secs >= 1.5 {
            message = "Didn\u{2019}t hear anything. Check the input device in System Settings \u{203a} Sound."
        } else if bad > 0 && transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            message = "Couldn\u{2019}t transcribe. Try again."
        } else {
            message = nil
        }
        if let message {
            Self.log.notice("voice \(id, privacy: .public): told the person: \(message, privacy: .public)")
            error = message
        }
    }

    private func fail(_ mine: Int, _ message: String) {
        guard mine == take else { return }
        let id = takeId
        Self.log.notice("voice \(id, privacy: .public): failed: \(message, privacy: .public)")
        error = message
        listening = false
        takeClosed = true
        stopWatchdog()
        teardown()
        endDrafts()
        finishing = inflight > 0
    }

    private func teardown() {
        if let o = configObserver {
            NotificationCenter.default.removeObserver(o)
            configObserver = nil
        }
        if let e = engine {
            e.stop()
            e.inputNode.removeTap(onBus: 0)
        }
        engine = nil
    }

    /// The server's hint: the draft's language when known (the language last detected), else the system's.
    private var langHint: String? { draftLocale.map(VoiceLocale.language) ?? Locale.current.language.languageCode?.identifier }

    // MARK: the live draft

    private static let supportedLocales: [String] = SFSpeechRecognizer.supportedLocales().map(\.identifier)

    private func useLocale(_ id: String) {
        guard let r = SFSpeechRecognizer(locale: Locale(identifier: id)), r.isAvailable else {
            recognizer = nil
            draftLocale = nil
            return
        }
        recognizer = r
        draftLocale = VoiceLocale.normal(id)
    }

    /// A new recognition request for the audio from now on; its partials are the live tail.
    private func openStretch(_ mine: Int) {
        guard mine == take, listening, !draftOff, let rec = recognizer, rec.isAvailable else { return }
        let req = SFSpeechAudioBufferRecognitionRequest()
        req.shouldReportPartialResults = true
        req.taskHint = .dictation
        req.addsPunctuation = true
        if rec.supportsOnDeviceRecognition { req.requiresOnDeviceRecognition = true }
        stretch += 1
        let id = stretch
        let task = rec.recognitionTask(with: req) { [weak self] result, error in
            let text = result?.bestTranscription.formattedString
            let done = (result?.isFinal ?? false) || error != nil
            let err = error.map { ($0 as NSError).domain + " " + String(($0 as NSError).code) + ": " + $0.localizedDescription }
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.drafted(mine, id, text, done, err) } }
        }
        tasks[id] = task
        liveStretch = id
        feed.swap(req)?.endAudio()
    }

    /// The cutter cut chunk `n`: the stretch's words so far become its draft, its request ends (its final words still
    /// update that draft) and the next stretch starts.
    private func cutStretch(_ n: Int, _ mine: Int) {
        assembly.cut(seq: n)
        if let id = liveStretch {
            stretchSeq[id] = n
            liveStretch = nil
            feed.swap(nil)?.endAudio()
        }
        checkDraft(n)
        openStretch(mine)
    }

    private func drafted(_ mine: Int, _ id: Int, _ text: String?, _ done: Bool, _ err: String? = nil) {
        // a closed take's late recognizer words never touch the field again (the person may be typing)
        guard mine == take, !takeClosed else { return }
        if let err {
            let t = takeId
            Self.log.notice("voice \(t, privacy: .public): draft \(id) ended: \(err, privacy: .public)")
        }
        if done { tasks[id] = nil }
        guard let text else { return }
        if id == liveStretch {
            assembly.live = text
        } else if let n = stretchSeq[id] {
            assembly.setDraft(seq: n, text: text)
            if done { checkDraft(n) }
        } else { return }
        show()
    }

    /// A draft of >= 4 words that reads as noise for its locale stays on screen until the server's text comes; a
    /// server "silence" then clears it.
    private func checkDraft(_ n: Int) {
        guard let loc = draftLocale else { return }
        let d = assembly.piece(n)
        let words = VoiceAssembly.words(d)
        guard words >= VoiceLocale.draftMinWords else { return }
        let nl = NLLanguageRecognizer()
        nl.processString(d)
        let lang = VoiceLocale.language(loc)
        let conf = nl.languageHypotheses(withMaximum: 5).first(where: { VoiceLocale.language($0.key.rawValue) == lang })?.value
        if VoiceLocale.draftDoubtful(words: words, confidence: conf) { assembly.markDoubtful(seq: n) }
    }

    /// Each server answer is the truth for its language: another supported language switches the next stretches
    /// (and is saved); a language without a recognizer locale ends the draft for this take.
    private func learnLanguage(_ text: String, _ mine: Int) {
        guard !draftOff else { return }
        let words = VoiceAssembly.words(text)
        guard words >= VoiceLocale.serverMinWords else { return }
        let nl = NLLanguageRecognizer()
        nl.processString(text)
        guard let top = nl.languageHypotheses(withMaximum: 1).first, top.value >= 0.5 else { return }
        switch VoiceLocale.decide(detected: top.key.rawValue, words: words, current: draftLocale,
                                  supported: Self.supportedLocales, preferred: Locale.preferredLanguages) {
        case .stay: return
        case .use(let id):
            UserDefaults.standard.set(id, forKey: VoiceLocale.defaultsKey)
            let t = takeId
            Self.log.notice("voice \(t, privacy: .public): draft language -> \(id, privacy: .public)")
            guard SFSpeechRecognizer.authorizationStatus() == .authorized else { return }
            let hadDraft = recognizer != nil
            useLocale(id)
            // no draft running yet (none could start): the next cut opens one in the new language
            if !hadDraft, recognizer != nil, liveStretch == nil, listening, mine == take { openStretch(mine) }
        case .unsupported:
            draftOff = true
            recognizer = nil
            draftLocale = nil
            if let id = liveStretch { tasks.removeValue(forKey: id)?.cancel() }
            liveStretch = nil
            feed.swap(nil)?.endAudio()
            assembly.live = ""
            show()
        }
    }

    /// Ends every request of the take that is gone (a new take, a failure).
    private func endDrafts() {
        feed.swap(nil)?.endAudio()
        for t in tasks.values { t.cancel() }
        tasks = [:]
        liveStretch = nil
        stretchSeq = [:]
    }

    // MARK: off the main actor (the audio callbacks come on their own queue)

    /// Converts each buffer, as the mic gives it, to 16 kHz mono Int16 for the server first, then hands it to the
    /// draft's request (`feed`), and the samples to `sink` on the main actor. The tap takes the bus's own format (nil):
    /// a format that is not the hardware's would throw.
    nonisolated private static func installTap(_ input: AVAudioInputNode, converter: TapConverter, feed: SpeechFeed,
                                               sink: @escaping @MainActor ([Int16]) -> Void) {
        input.installTap(onBus: 0, bufferSize: 4096, format: nil) { buffer, _ in
            let samples = converter.convert(buffer)
            feed.append(buffer)
            guard let samples, !samples.isEmpty else { return }
            DispatchQueue.main.async { MainActor.assumeIsolated { sink(samples) } }
        }
    }

    private static func openMicrophoneSettings() {
        if let u = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone") { NSWorkspace.shared.open(u) }
    }

    nonisolated private static func microphoneAuthorized() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: return true
        case .denied, .restricted: return false
        default: return await AVCaptureDevice.requestAccess(for: .audio)
        }
    }

    /// Speech recognition for the draft; asked once, alongside the microphone. Denied -> no draft, nothing said.
    nonisolated private static func speechAuthorized() async -> Bool {
        switch SFSpeechRecognizer.authorizationStatus() {
        case .authorized: return true
        case .denied, .restricted: return false
        default:
            return await withCheckedContinuation { c in
                SFSpeechRecognizer.requestAuthorization { c.resume(returning: $0 == .authorized) }
            }
        }
    }

    nonisolated private static func name(_ s: AVAuthorizationStatus) -> String {
        switch s {
        case .authorized: return "allowed"
        case .denied: return "denied"
        case .restricted: return "restricted"
        case .notDetermined: return "not asked yet"
        @unknown default: return "unknown"
        }
    }

    nonisolated private static func name(_ s: SFSpeechRecognizerAuthorizationStatus) -> String {
        switch s {
        case .authorized: return "allowed"
        case .denied: return "denied"
        case .restricted: return "restricted"
        case .notDetermined: return "not asked yet"
        @unknown default: return "unknown"
        }
    }
}

/// The mic in the composer. A press starts listening; held longer than a moment, letting go stops (hold to talk);
/// a short click keeps listening until the next click.
/// Three dots side by side, rising and fading a little one after another (a quiet wave); still with Reduce Motion.
struct DictationWaitDots: View {
    var still = false

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: still)) { ctx in
            let t = ctx.date.timeIntervalSinceReferenceDate
            HStack(spacing: 3) {
                ForEach(0..<3, id: \.self) { i in
                    let phase: Double = still ? 0 : sin(t * 2 * .pi / 1.2 - Double(i) * 0.9)
                    Circle()
                        .fill(WS.text2)
                        .frame(width: 4, height: 4)
                        .offset(y: CGFloat(-1.5 * max(0, phase)))
                        .opacity(0.45 + 0.4 * max(0, phase))
                }
            }
        }
        .frame(width: 20, height: 14)
        .accessibilityHidden(true)
    }
}

struct ChatMicButton: View {
    @ObservedObject var dictation: ChatDictation
    @State private var pressedAt: Date?
    @State private var wasListening = false
    @State private var pulse = false
    /// true while the press lasts; SwiftUI resets it also when the gesture is CANCELLED (a system prompt - the speech
    /// permission on the first take - takes the mouse), where onEnded never comes and `pressedAt` would stay set and
    /// make every later press do nothing.
    @GestureState private var pressing = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        icon
            .frame(width: 30, height: 34)
            .contentShape(Rectangle())
            .opacity(blocked ? 0.4 : 1)
            .gesture(press)
            .liaPointer()
            .liaTip(blocked ? dictation.blockedTip : nil)
            .onAppear { dictation.refreshQuota() }
            .accessibilityElement(children: .ignore)
            .accessibilityAddTraits(.isButton)
            .accessibilityLabel(Text(dictation.listening ? "Stop dictation" : "Dictate"))
            .accessibilityValue(Text(dictation.listening ? "Listening" : dictation.finishing ? "Finishing" : ""))
            .accessibilityAction { dictation.toggle() }
            .onChange(of: dictation.listening) { _, on in animatePulse(on) }
            .onChange(of: pressing) { _, p in if !p { release() } }
    }

    private var blocked: Bool { !dictation.listening && !dictation.finishing && dictation.blockedTip != nil }

    private var tipText: String {
        if dictation.listening { return "Stop dictation" }
        if dictation.finishing { return "Finishing\u{2026}" }
        if let t = dictation.blockedTip { return t }
        return "Dictate \u{00b7} hold to talk or click"
    }

    private var icon: some View {
        ZStack {
            if dictation.listening {
                Circle().fill(Color.red.opacity(0.14)).frame(width: 28, height: 28)
                    .scaleEffect(pulse ? 1.15 : 0.9)
            }
            // finishing: the mic is off, the last words are still being replaced (three dots in a quiet
            // wave say so; Send waits meanwhile)
            if dictation.finishing && !dictation.listening {
                DictationWaitDots(still: reduceMotion)
            } else {
                Image(systemName: dictation.listening ? "mic.fill" : blocked ? "mic.slash" : "mic")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(dictation.listening ? Color.red : WS.text2)
            }
        }
    }

    private var press: some Gesture {
        DragGesture(minimumDistance: 0)
            .updating($pressing) { _, state, _ in state = true }
            .onChanged { _ in
                guard pressedAt == nil else { return }
                pressedAt = Date()
                wasListening = dictation.listening
                if !wasListening { dictation.start() }
            }
            .onEnded { _ in release() }
    }

    /// The press is over (ended, or cancelled): once per press, whichever comes first.
    private func release() {
        guard let at = pressedAt else { return }
        pressedAt = nil
        if wasListening || Date().timeIntervalSince(at) > 0.45 { dictation.stop() }
    }

    private func animatePulse(_ on: Bool) {
        guard on, !reduceMotion else { pulse = false; return }
        withAnimation(.easeInOut(duration: 0.7).repeatForever(autoreverses: true)) { pulse = true }
    }
}

/// Wires dictation to the composer (start, transcript, errors, a stop when the view goes).
struct DictationHooks: ViewModifier {
    @ObservedObject var dictation: ChatDictation
    let onStart: () -> Void
    let onHeard: (String) -> Void
    let onError: (String) -> Void
    var onCleared: () -> Void = {}

    func body(content: Content) -> some View {
        content
            .onChange(of: dictation.listening) { _, on in
                if on { onStart() }
                ChatA11y.announce(on ? "Listening" : "Dictation stopped")
            }
            .onChange(of: dictation.transcript) { _, t in onHeard(t) }
            .onChange(of: dictation.cleared) { _, _ in onCleared() }
            .onChange(of: dictation.error) { _, e in if let e { onError(e) } }
            .onDisappear { dictation.stop() }
    }
}
