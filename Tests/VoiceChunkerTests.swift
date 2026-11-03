import XCTest
import Foundation
@testable import Liaison

/// Voice input (Shared/Core/VoiceChunker.swift): the WAV, the cutting decisions, the in-order assembly (drafts, server texts, live tail), the replies.
final class VoiceChunkerTests: XCTestCase {
    private let sr = 16000
    /// `ms` of a tone loud enough to be speech
    private func speech(_ ms: Int) -> [Int16] { (0..<(sr * ms / 1000)).map { i in Int16(Double(8000) * sin(Double(i) * 0.3)) } }
    /// `ms` of near-silence (room noise)
    private func quiet(_ ms: Int) -> [Int16] { (0..<(sr * ms / 1000)).map { i in Int16(i % 2 == 0 ? 20 : -20) } }
    private func chunks(_ cuts: [VoiceCut]) -> [[Int16]] { cuts.compactMap { if case .chunk(let s) = $0 { return s } else { return nil } } }
    private func stops(_ cuts: [VoiceCut]) -> [VoiceStopReason] { cuts.compactMap { if case .stop(let r) = $0 { return r } else { return nil } } }

    func testWavHeader() {
        let d = VoiceChunker.wav([1, -1, 300])
        XCTAssertEqual(d.count, 44 + 6)
        XCTAssertEqual(String(decoding: d[0..<4], as: UTF8.self), "RIFF")
        XCTAssertEqual(String(decoding: d[8..<12], as: UTF8.self), "WAVE")
        XCTAssertEqual(String(decoding: d[36..<40], as: UTF8.self), "data")
        let le = { (i: Int) -> UInt32 in UInt32(d[i]) | UInt32(d[i + 1]) << 8 | UInt32(d[i + 2]) << 16 | UInt32(d[i + 3]) << 24 }
        XCTAssertEqual(le(24), 16000)          // sample rate
        XCTAssertEqual(le(28), 32000)          // byte rate
        XCTAssertEqual(le(40), 6)              // data size
        XCTAssertEqual(le(4), 36 + 6)
        XCTAssertEqual(d[22], 1)               // mono
        XCTAssertEqual(d[34], 16)              // 16-bit
        XCTAssertEqual([d[44], d[45], d[46], d[47]], [1, 0, 0xFF, 0xFF])
    }

    func testBodyShape() {
        let b = VoiceChunker.body(samples: Array(repeating: 0, count: 8000), take: "t1", seq: 2, lang: "ru", prev: String(repeating: "a", count: 500) + "z")
        XCTAssertEqual(b["take"] as? String, "t1")
        XCTAssertEqual(b["seq"] as? Int, 2)
        XCTAssertEqual(b["seconds"] as? Double, 0.5)
        XCTAssertEqual(b["lang_hint"] as? String, "ru")
        XCTAssertEqual((b["prev"] as? String)?.count, 400)
        XCTAssertTrue((b["prev"] as? String)?.hasSuffix("z") == true)
        let audio = Data(base64Encoded: b["audio"] as? String ?? "")
        XCTAssertEqual(audio?.count, 44 + 16000)
        let empty = VoiceChunker.body(samples: [0], take: "t", seq: 0, lang: nil, prev: "")
        XCTAssertNil(empty["prev"])
        XCTAssertNil(empty["lang_hint"])
    }

    func testSilenceIsNeverSent() {
        var c = VoiceCutter()
        let out = c.feed(quiet(15_000))
        XCTAssertTrue(chunks(out).isEmpty)
        XCTAssertNil(c.finish())
    }

    func testCutAtPause() {
        var c = VoiceCutter()
        var out = c.feed(quiet(500) + speech(1500))
        XCTAssertTrue(chunks(out).isEmpty)
        out = c.feed(quiet(300))
        XCTAssertTrue(chunks(out).isEmpty)          // 300 ms is not a pause yet
        out = c.feed(quiet(200))
        let got = chunks(out)
        XCTAssertEqual(got.count, 1)
        // the lead-in is at most 300 ms, then the speech and the pause
        XCTAssertTrue(got[0].count <= sr * (300 + 1500 + 500) / 1000)
        XCTAssertTrue(got[0].count >= sr * (1500 + 400) / 1000)
    }

    func testCutAt8Seconds() {
        var c = VoiceCutter()
        XCTAssertEqual(c.cfg.pauseMs, 400)
        XCTAssertEqual(c.cfg.maxChunkMs, 8_000)
        let out = c.feed(speech(9_000))
        let got = chunks(out)
        XCTAssertEqual(got.count, 1)
        XCTAssertEqual(got[0].count, sr * 8)
        XCTAssertEqual(c.finish()?.count, sr * 1)
    }

    func testPiecesOfAnySize() {
        var c = VoiceCutter()
        var all: [VoiceCut] = []
        let s = speech(1000) + quiet(800)
        var i = 0
        while i < s.count { let n = min(37, s.count - i); all += c.feed(Array(s[i..<(i + n)])); i += n }
        XCTAssertEqual(chunks(all).count, 1)
    }

    func testTooShortBlipIsDropped() {
        var c = VoiceCutter()
        let out = c.feed(quiet(300) + speech(60) + quiet(800))
        XCTAssertTrue(chunks(out).isEmpty)
    }

    func testIdleStopAfter20Seconds() {
        var c = VoiceCutter()
        var out = c.feed(speech(1000) + quiet(10_000))
        XCTAssertEqual(chunks(out).count, 1)
        XCTAssertTrue(stops(out).isEmpty)
        out = c.feed(quiet(9_000))
        XCTAssertTrue(stops(out).isEmpty)       // 19 s since the last speech
        out = c.feed(quiet(1000))
        XCTAssertEqual(stops(out), [.silence])
        XCTAssertTrue(c.stopped)
        XCTAssertTrue(c.feed(speech(1000)).isEmpty)
    }

    func testTakeStopsAtFiveMinutes() {
        var c = VoiceCutter()
        var all: [VoiceCut] = []
        for _ in 0..<31 { all += c.feed(speech(10_000)) }
        XCTAssertEqual(stops(all), [.takeLimit])
        let sent = chunks(all).reduce(0) { $0 + $1.count }
        XCTAssertEqual(sent, sr * 300)          // never more audio than 5 minutes
        XCTAssertEqual(VoiceStopReason.takeLimit.message, "Stopped after 5 minutes")
    }

    func testDraftTailIsWhatIsNotFinal() {
        var a = VoiceAssembly()
        a.live = "hello wrld"
        XCTAssertEqual(a.settled, "")
        XCTAssertEqual(a.draftTail, a.text.count)     // all draft
        a.cut(seq: 0)
        a.live = "how are"
        a.cut(seq: 1)
        a.live = "you"
        XCTAssertTrue(a.put(seq: 1, text: "How are"))  // chunk 0 still waits: nothing is final yet
        XCTAssertEqual(a.settled, "")
        XCTAssertEqual(a.draftTail, a.text.count)
        XCTAssertTrue(a.put(seq: 0, text: "Hello, world."))
        XCTAssertEqual(a.settled, "Hello, world. How are")
        XCTAssertTrue(a.text.hasPrefix(a.settled))
        XCTAssertEqual(a.draftTail, " you".count)       // only the live tail is a draft
        a.cut(seq: 2)
        a.put(seq: 2, text: nil)                       // a failed chunk keeps its draft, which is then final
        XCTAssertEqual(a.draftTail, 0)
    }

    func testAssemblyInSeqOrder() {
        var a = VoiceAssembly()
        for i in 0..<6 { a.cut(seq: i) }       // no drafts: only the server's words
        XCTAssertTrue(a.put(seq: 1, text: "world"))   // shown at once, ahead of chunk 0
        XCTAssertEqual(a.text, "world")
        XCTAssertTrue(a.put(seq: 0, text: "Hello"))
        XCTAssertEqual(a.text, "Hello world")
        a.put(seq: 3, text: "again.")
        a.put(seq: 2, text: nil)                // a failed chunk does not hold the rest back
        XCTAssertEqual(a.text, "Hello world again.")
        a.put(seq: 4, text: ", and more")
        XCTAssertEqual(a.text, "Hello world again., and more")
        XCTAssertFalse(a.put(seq: 0, text: "dup"))
        XCTAssertTrue(a.hasWaiting)
        a.put(seq: 5, text: "")
        XCTAssertEqual(a.count, 6)
        XCTAssertFalse(a.hasWaiting)
    }

    func testDraftShowsAtOnceAndServerReplacesIt() {
        var a = VoiceAssembly()
        a.live = "hello wrld"
        XCTAssertEqual(a.text, "hello wrld")
        a.cut(seq: 0)                           // frozen as chunk 0's draft
        XCTAssertEqual(a.live, "")
        XCTAssertEqual(a.text, "hello wrld")
        a.live = "how are"
        XCTAssertEqual(a.text, "hello wrld how are")
        XCTAssertTrue(a.setDraft(seq: 0, text: "hello world"))   // the recognizer's final for that stretch
        XCTAssertEqual(a.text, "hello world how are")
        XCTAssertTrue(a.put(seq: 0, text: "Hello, world."))
        XCTAssertEqual(a.text, "Hello, world. how are")
        XCTAssertFalse(a.setDraft(seq: 0, text: "late draft"))   // the server's text stays
        XCTAssertEqual(a.piece(0), "Hello, world.")
        a.cut(seq: 1)
        a.live = ""
        XCTAssertEqual(a.text, "Hello, world. how are")
        a.put(seq: 1, text: "How are you?")
        XCTAssertEqual(a.text, "Hello, world. How are you?")
    }

    func testServerAnswersOutOfOrderOverDrafts() {
        var a = VoiceAssembly()
        a.live = "one"; a.cut(seq: 0)
        a.live = "two"; a.cut(seq: 1)
        a.live = "three"
        a.put(seq: 1, text: "Two.")
        XCTAssertEqual(a.text, "one Two. three")
        a.put(seq: 0, text: "One.")
        XCTAssertEqual(a.text, "One. Two. three")
    }

    func testEmptyAnswerAndFailureRules() {
        var a = VoiceAssembly()
        a.live = "uh hm"; a.cut(seq: 0)
        a.live = "this is a long sentence"; a.cut(seq: 1)
        a.live = "kept when it fails"; a.cut(seq: 2)
        a.put(seq: 0, text: "")                 // silence and a short draft: cleared
        XCTAssertEqual(a.piece(0), "")
        a.put(seq: 1, text: "")                 // silence but a long draft: the server likely failed, keep it
        XCTAssertEqual(a.piece(1), "this is a long sentence")
        a.put(seq: 2, text: nil)                // failed: the draft stays
        XCTAssertEqual(a.piece(2), "kept when it fails")
        XCTAssertEqual(a.text, "this is a long sentence kept when it fails")
        XCTAssertTrue(a.setDraft(seq: 2, text: "kept when it fails, final"))   // a kept draft still takes the final
        XCTAssertEqual(a.piece(2), "kept when it fails, final")
        XCTAssertFalse(a.hasWaiting)
        XCTAssertEqual(VoiceAssembly.words(" a  b\nc "), 3)
        a.live = "noise heard as four words"; a.cut(seq: 3)
        a.markDoubtful(seq: 3)
        XCTAssertEqual(a.piece(3), "noise heard as four words")   // still shown while the server is out
        a.put(seq: 3, text: "")                                   // doubtful + silence: cleared
        XCTAssertEqual(a.piece(3), "")
    }

    func testPrevBeforeChunk() {
        var a = VoiceAssembly()
        a.live = "first"; a.cut(seq: 0)
        XCTAssertEqual(a.prev(before: 0), "")
        a.live = "second"
        XCTAssertEqual(a.prev(before: 1), "first")
        a.cut(seq: 1)
        XCTAssertEqual(a.prev(before: 1), "first")   // the chunk's own draft is never its context
        XCTAssertEqual(a.prev, "first second")
    }

    func testAssemblyPrevIsLast400() {
        var a = VoiceAssembly()
        a.cut(seq: 0)
        a.put(seq: 0, text: String(repeating: "x", count: 600))
        XCTAssertEqual(a.prev.count, 400)
        XCTAssertEqual(a.prev(before: 1).count, 400)
    }

    func testReplies() {
        XCTAssertEqual(VoiceReply.parse(["ok": true, "text": " Hi "], status: 200), VoiceReply(text: "Hi", status: 200))
        XCTAssertEqual(VoiceReply.parse(["ok": true, "text": ""], status: 200).text, "")
        let d = VoiceReply.parse(["ok": false, "error": "voice_daily_limit"], status: 429)
        XCTAssertTrue(d.stop && d.text == nil)
        XCTAssertEqual(d.error, "Voice limit for today reached")
        XCTAssertEqual(VoiceReply.parse(["ok": false, "error": "voice_take_limit"], status: 429).error, "Stopped after 5 minutes")
        XCTAssertTrue(VoiceReply.parse([:], status: 404).stop)
        let f = VoiceReply.parse(["ok": false, "error": "voice_failed"], status: 502)
        XCTAssertTrue(f.text == nil && !f.stop && f.error == nil)
        // the log's status and code ("voice does not work at all" had nothing to read)
        XCTAssertEqual(f.status, 502)
        XCTAssertEqual(f.code, "voice_failed")
        XCTAssertNil(VoiceReply.parse(["ok": true, "text": "x"], status: 200).code)
        XCTAssertNil(VoiceReply(text: nil).status)
    }

    /// The take's own evidence: whether any stretch held speech, and the loudest frame (a dead mic reads ~0).
    func testCutterHeardSpeechAndPeak() {
        var c = VoiceCutter()
        _ = c.feed(quiet(1000))
        XCTAssertFalse(c.heardSpeech)
        XCTAssertTrue(c.peak < 0.01)
        _ = c.feed(Array(repeating: 0, count: sr))
        XCTAssertFalse(c.heardSpeech)
        _ = c.feed(speech(400))
        XCTAssertTrue(c.heardSpeech)
        XCTAssertTrue(c.peak > 0.1)
        var blip = VoiceCutter()
        _ = blip.feed(speech(60) + quiet(500))
        XCTAssertFalse(blip.heardSpeech)
    }

    func testPlanQuota() {
        let free: JSONObject = ["ok": false, "error": "voice_daily_limit", "plan": "free", "limit_minutes": 20, "next_plan": "pro", "next_limit_minutes": 60, "used_seconds": 1195]
        let d = VoiceReply.parse(free, status: 429)
        XCTAssertTrue(d.stop)
        XCTAssertEqual(d.error, "You\u{2019}ve used today\u{2019}s 20 minutes of voice input. Upgrade to Pro for 60 minutes a day.")
        XCTAssertTrue(d.quota?.exhausted == true)
        let pro = VoiceQuota.parse(["plan": "pro", "limit_minutes": 60, "next_plan": "max", "next_limit_minutes": 120, "left_seconds": 0])
        XCTAssertEqual(pro?.tip, "You\u{2019}ve used today\u{2019}s 60 minutes of voice input. Upgrade to Max for 120 minutes a day.")
        let max = VoiceQuota.parse(["plan": "max", "limit_minutes": 120, "next_plan": NSNull(), "next_limit_minutes": NSNull(), "left_seconds": 30])
        XCTAssertEqual(max?.tip, "You\u{2019}ve used today\u{2019}s 120 minutes of voice input. It resets tomorrow.")
        XCTAssertTrue(max?.exhausted == false)
        let ok = VoiceReply.parse(["ok": true, "text": "Hi", "plan": "pro", "limit_minutes": 60, "left_seconds": 100], status: 200)
        XCTAssertTrue(ok.quota?.leftSeconds == 100)
        XCTAssertTrue(VoiceQuota.parse(["ok": true]) == nil)
    }

    func testLocaleMatching() {
        let sup = ["en_US", "en_GB", "en_AU", "fr_FR", "fr_CA", "it_IT", "ru_RU", "pt_BR", "pt_PT", "zh_CN", "zh_TW"]
        XCTAssertEqual(VoiceLocale.language("zh-Hans-CN"), "zh")
        XCTAssertEqual(VoiceLocale.region("zh-Hans-CN"), "CN")
        XCTAssertNil(VoiceLocale.region("en"))
        XCTAssertEqual(VoiceLocale.best(for: "en", supported: sup, preferred: ["en-GB"]), "en-GB")
        XCTAssertEqual(VoiceLocale.best(for: "en", supported: sup, preferred: ["ru-RU"]), "en-US")
        XCTAssertEqual(VoiceLocale.best(for: "fr", supported: sup, preferred: ["en-CA"]), "fr-CA")   // the person's region
        XCTAssertEqual(VoiceLocale.best(for: "fr", supported: sup, preferred: ["it-IT"]), "fr-FR")
        XCTAssertEqual(VoiceLocale.best(for: "pt", supported: sup, preferred: ["pt-PT", "en-US"]), "pt-PT")
        XCTAssertEqual(VoiceLocale.best(for: "zh-Hant-TW", supported: sup, preferred: ["zh-Hant-TW"]), "zh-TW")
        XCTAssertNil(VoiceLocale.best(for: "ka", supported: sup, preferred: ["ka-GE"]))
    }

    func testInitialLocale() {
        let sup = ["en_US", "it_IT", "ru_RU"]
        XCTAssertEqual(VoiceLocale.initial(saved: "ru_RU", preferred: ["en-US"], supported: sup), "ru-RU")
        XCTAssertEqual(VoiceLocale.initial(saved: "xx-YY", preferred: ["ka-GE", "it-IT"], supported: sup), "it-IT")
        XCTAssertEqual(VoiceLocale.initial(saved: nil, preferred: ["en"], supported: sup), "en-US")
        XCTAssertNil(VoiceLocale.initial(saved: nil, preferred: ["ka-GE"], supported: sup))
        XCTAssertNil(VoiceLocale.initial(saved: nil, preferred: [], supported: []))
    }

    func testLocaleSwitchAfterServerAnswer() {
        let sup = ["en_US", "it_IT", "ru_RU"]
        XCTAssertEqual(VoiceLocale.decide(detected: "ru", words: 5, current: "en-US", supported: sup, preferred: ["en-US"]), .use("ru-RU"))
        XCTAssertEqual(VoiceLocale.decide(detected: "ru", words: 2, current: "en-US", supported: sup, preferred: []), .stay)   // too short
        XCTAssertEqual(VoiceLocale.decide(detected: "en", words: 5, current: "en_US", supported: sup, preferred: []), .stay)   // same
        XCTAssertEqual(VoiceLocale.decide(detected: "ka", words: 5, current: "en-US", supported: sup, preferred: []), .unsupported)
        XCTAssertEqual(VoiceLocale.decide(detected: nil, words: 5, current: "en-US", supported: sup, preferred: []), .stay)
        XCTAssertEqual(VoiceLocale.decide(detected: "und", words: 5, current: "en-US", supported: sup, preferred: []), .stay)
        XCTAssertEqual(VoiceLocale.decide(detected: "it", words: 3, current: nil, supported: sup, preferred: []), .use("it-IT"))
        XCTAssertTrue(VoiceLocale.draftDoubtful(words: 4, confidence: 0.3))
        XCTAssertFalse(VoiceLocale.draftDoubtful(words: 3, confidence: 0.1))
        XCTAssertFalse(VoiceLocale.draftDoubtful(words: 6, confidence: 0.8))
    }
}
