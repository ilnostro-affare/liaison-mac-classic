import XCTest
import Foundation
#if canImport(Liaison)
@testable import Liaison
#endif

// The "Quick answer" bar: ai.js quizOptOk, _qzPlain, quizBarMount's rules, quizBarSync and quizBarAnswered.
final class QuizTests: XCTestCase {
    private func obj(_ s: String) -> JSONObject { JSONRead.object(Data(s.utf8)) ?? [:] }
    private func quizBlock(_ s: String) -> ChatBlock { ChatBlock(tool: "ask_choice", data: obj(s)) }
    private func assistant(_ content: String, _ blocks: [ChatBlock] = []) -> ChatMessage {
        ChatMessage(role: .assistant, content: content, blocks: blocks)
    }
    private let two = #"{"kind":"quiz","question":"Which one?","options":[{"label":"**Broad**","send":"Use broad","hint":"_wide_ reach"},{"label":"Narrow"}]}"#

    func testOptionValidation() {
        XCTAssertTrue(Quiz.optionOK("Broad audience"))
        XCTAssertTrue(Quiz.optionOK("Pause (for now)"))
        XCTAssertFalse(Quiz.optionOK(""))
        XCTAssertFalse(Quiz.optionOK(String(repeating: "a", count: 91)))
        XCTAssertTrue(Quiz.optionOK(String(repeating: "a", count: 90)))
        XCTAssertFalse(Quiz.optionOK("{\"label\""))
        XCTAssertFalse(Quiz.optionOK("a [b]"))
        XCTAssertFalse(Quiz.optionOK("x\":\"y"))
        XCTAssertFalse(Quiz.optionOK("\"quoted"))
        XCTAssertFalse(Quiz.optionOK("quoted\""))
        XCTAssertFalse(Quiz.optionOK("\u{043f}\u{0430}\u{0443}\u{0437}\u{0430})"))
        XCTAssertFalse(Quiz.optionOK("(open"))
    }

    func testPlainLabel() {
        XCTAssertEqual(Quiz.plain("**Bold** choice"), "Bold choice")
        XCTAssertEqual(Quiz.plain("  `code` and _it_ *x* "), "code and it x")
        XCTAssertEqual(Quiz.plain("a ** b"), "a  b")
    }

    func testParse() {
        let q = Quiz(data: obj(two))!
        XCTAssertEqual(q.question, "Which one?")
        XCTAssertEqual(q.options.map(\.label), ["Broad", "Narrow"])
        XCTAssertEqual(q.options.map(\.send), ["Use broad", "Narrow"])
        XCTAssertEqual(q.options[0].hint, "wide reach")
        XCTAssertNil(q.options[1].hint)
        XCTAssertTrue(q.shows)
        XCTAssertFalse(q.isEntity)
        XCTAssertNil(Quiz(data: obj(#"{"kind":"plot"}"#)))
    }

    func testRules() {
        // fewer than two valid options: no bar
        XCTAssertFalse(Quiz(data: obj(#"{"kind":"quiz","options":[{"label":"One"},{"label":"[debris]"}]}"#))!.shows)
        // five at most
        let many = (1...7).map { #"{"label":"Opt \#($0)"}"# }.joined(separator: ",")
        XCTAssertEqual(Quiz(data: obj(#"{"kind":"quiz","options":[\#(many)]}"#))!.options.count, 5)
        // answered (any truthy value) hides it
        XCTAssertFalse(Quiz(data: obj(#"{"kind":"quiz","answered":1,"options":[{"label":"A"},{"label":"B"}]}"#))!.shows)
        XCTAssertFalse(Quiz(data: obj(#"{"kind":"quiz","answered":true,"options":[{"label":"A"},{"label":"B"}]}"#))!.shows)
        XCTAssertTrue(Quiz(data: obj(#"{"kind":"quiz","answered":0,"options":[{"label":"A"},{"label":"B"}]}"#))!.shows)
        // targeting_fork is not a question to print; long ones are cut at 200
        XCTAssertNil(Quiz(data: obj(#"{"kind":"quiz","question":"targeting_fork","options":[]}"#))!.question)
        let long = String(repeating: "q", count: 260)
        XCTAssertEqual(Quiz(data: obj(#"{"kind":"quiz","question":"\#(long)","options":[]}"#))!.question?.count, 200)
        // synthetic shows with no options
        XCTAssertTrue(Quiz(data: obj(#"{"kind":"quiz","synthetic":1,"options":[]}"#))!.shows)
    }

    func testEntityQuiz() {
        XCTAssertTrue(Quiz(data: obj(#"{"kind":"quiz","options":[{"label":"A","send":"Copy A (id 120212345678901)"},{"label":"B"}]}"#))!.isEntity)
        XCTAssertFalse(Quiz(data: obj(#"{"kind":"quiz","options":[{"label":"A","send":"Copy A (id 1202)"},{"label":"B"}]}"#))!.isEntity)
        XCTAssertTrue(Quiz(data: obj(#"{"kind":"quiz","question":"Which Ad Set to copy?","options":[{"label":"A"},{"label":"B"}]}"#))!.isEntity)
        XCTAssertTrue(Quiz(data: obj(#"{"kind":"quiz","question":"какую кампанию?","options":[]}"#))!.isEntity)
        XCTAssertTrue(Quiz(data: obj(#"{"kind":"quiz","synthetic":1,"options":[]}"#))!.isEntity)
        XCTAssertEqual(Quiz.pickText(name: "Broad 2", id: "120200000000001"), "[quick_action] Broad 2 (id 120200000000001)")
    }

    func testFindActive() {
        let q = quizBlock(two)
        XCTAssertEqual(QuizFind.active([ChatMessage(role: .user, content: "hi"), assistant("pick", [q])])?.place, .message(1))
        // a user message after it supersedes it
        XCTAssertNil(QuizFind.active([assistant("pick", [q]), ChatMessage(role: .user, content: "mine")]))
        // only the newest assistant message decides (quizBarSync breaks after the first one)
        XCTAssertNil(QuizFind.active([assistant("pick", [q]), assistant("more text")]))
        // answered: nothing
        XCTAssertNil(QuizFind.active([assistant("pick", [q.patched { $0["answered"] = 1 }])]))
        // Prose
        let prose = assistant("\u{0412}\u{044b}\u{0431}\u{0435}\u{0440}\u{0438}\u{0442}\u{0435} \u{0448}\u{0430}\u{0431}\u{043b}\u{043e}\u{043d} \u{0434}\u{043b}\u{044f} \u{043a}\u{043e}\u{043f}\u{0438}\u{0438}")
        let s = QuizFind.active([prose])
        XCTAssertEqual(s?.quiz.synthetic, true)
        XCTAssertEqual(s?.quiz.shows, true)
        XCTAssertNil(QuizFind.active([assistant("Which audience do you prefer?")]))
    }

    func testLive() {
        XCTAssertEqual(QuizFind.live([quizBlock(two)])?.place, .live)
        XCTAssertNil(QuizFind.live([quizBlock(two).patched { $0["answered"] = 1 }]))
        XCTAssertNil(QuizFind.live([ChatBlock(tool: "x", kind: "plot", url: "/p", type: nil, filename: nil, bytes: nil)]))
    }

    func testToClose() {
        let q = quizBlock(two)
        XCTAssertEqual(QuizFind.toClose([assistant("pick", [q]), assistant("later")]), 0)
        XCTAssertNil(QuizFind.toClose([assistant("pick", [q]), ChatMessage(role: .user, content: "x"), assistant("later")]))
        XCTAssertNil(QuizFind.toClose([assistant("pick", [q.patched { $0["answered"] = 1 }])]))
        let prose = assistant("\u{041d}\u{0430} \u{043e}\u{0441}\u{043d}\u{043e}\u{0432}\u{0435} \u{043a}\u{0430}\u{043a}\u{043e}\u{0433}\u{043e} \u{0430}\u{0434}\u{0441}\u{0435}\u{0442}\u{0430}?")
        XCTAssertEqual(QuizFind.toClose([prose]), 0)
        XCTAssertNil(QuizFind.toClose([assistant("plain")]))
    }

    func testMarkAnsweredPersistsInStoredCopy() {
        let stored = obj(#"{"role":"assistant","content":"pick","actsHTML":"<i>","blocks":[{"tool":"plot","data":{"kind":"plot","url":"/p"}},{"tool":"ask_choice","data":\#(two)}]}"#)
        var m = ChatMessage(json: stored, index: 3)!
        XCTAssertNotNil(QuizFind.active([m]))
        m.markQuizAnswered()
        XCTAssertNil(QuizFind.active([m]))
        let saved = m.saveJSON()
        XCTAssertEqual(saved["actsHTML"] as? String, "<i>")
        let bs = JSONRead.objects(saved, "blocks")
        XCTAssertEqual(bs.count, 2)
        XCTAssertTrue(Quiz.truthy((bs[1]["data"] as? JSONObject)?["answered"]))
        XCTAssertNil((bs[0]["data"] as? JSONObject)?["answered"])
        // reopened from what was saved, the bar stays gone
        XCTAssertNil(QuizFind.active([ChatMessage(json: saved, index: 3)!]))
    }

    func testTwoQuizzesTheLastIsShownAndMarked() {
        let other = #"{"kind":"quiz","question":"Which two?","options":[{"label":"Leads"},{"label":"Sales"}]}"#
        var m = assistant("pick", [quizBlock(two), quizBlock(other)])
        XCTAssertEqual(QuizFind.active([m])?.quiz.question, QuizFind.live(m.blocks)?.quiz.question)
        m.markQuizAnswered()
        XCTAssertNil(QuizFind.active([m]))
        XCTAssertFalse(Quiz.truthy(m.blocks[0].raw?["answered"]))
        XCTAssertTrue(Quiz.truthy(m.blocks[1].raw?["answered"]))
    }

    func testMarkAnsweredOnAppMessageAndSynthetic() {
        var m = assistant("pick", [quizBlock(two)])
        m.markQuizAnswered()
        let d = JSONRead.objects(m.saveJSON(), "blocks").first?["data"] as? JSONObject
        XCTAssertTrue(Quiz.truthy(d?["answered"]))

        let words = "\u{041a}\u{0430}\u{043a}\u{043e}\u{0439} \u{0430}\u{0434}\u{0441}\u{0435}\u{0442} \u{0432}\u{0437}\u{044f}\u{0442}\u{044c}?"
        var s = ChatMessage(json: obj(#"{"role":"assistant","content":"\#(words)"}"#), index: 0)!
        XCTAssertEqual(QuizFind.active([s])?.quiz.synthetic, true)
        s.markQuizAnswered()
        XCTAssertNil(QuizFind.active([s]))
        let sd = JSONRead.objects(s.saveJSON(), "blocks").first?["data"] as? JSONObject
        XCTAssertEqual(JSONRead.string(sd, "kind"), "quiz")
        XCTAssertTrue(Quiz.truthy(sd?["synthetic"]))
        XCTAssertTrue(Quiz.truthy(sd?["answered"]))
    }

    func testTruthy() {
        XCTAssertFalse(Quiz.truthy(nil))
        XCTAssertFalse(Quiz.truthy(NSNull()))
        XCTAssertFalse(Quiz.truthy(""))
        XCTAssertFalse(Quiz.truthy(0))
        XCTAssertTrue(Quiz.truthy(1))
        XCTAssertTrue(Quiz.truthy(true))
        XCTAssertFalse(Quiz.truthy(false))
        XCTAssertTrue(Quiz.truthy("1"))
    }
}
