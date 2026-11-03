import XCTest
import Foundation
#if canImport(Liaison)
@testable import Liaison
#endif

// Lia 1.4 modes: what the stream carries, what the person sends back, how the thread reads it.
// Expected strings are ai.js's own, so a drift from the site fails here.
final class ModesTests: XCTestCase {
    private func obj(_ s: String) -> JSONObject { JSONRead.object(Data(s.utf8))! }

    func testModeDefaultsToAutoForAnythingUnknown() {
        XCTAssertEqual(LiaModel.mode(model: nil, rmode: nil), .auto)
        XCTAssertEqual(LiaModel.mode(model: "lia13", rmode: "confirm"), .auto)
        XCTAssertEqual(LiaModel.mode(model: "lia14", rmode: "plan"), .auto)   // no Plan in Lia 2.0
        XCTAssertEqual(LiaModel.mode(model: "lia20", rmode: "manual"), .manual)
        XCTAssertEqual(LiaModel.mode(model: "lia20", rmode: "plan"), .auto)
        XCTAssertEqual(LiaModel.mode(model: "lia14", rmode: "manual"), .manual)
        XCTAssertEqual(LiaModel.mode(model: "lia14", rmode: "build"), .auto)
        XCTAssertEqual(LiaModel.mode(model: "lia13", rmode: "manual"), .auto)
    }

    func testStreamCarriesGateAskPlan() {
        let g = ChatEvent.parse(line: #"data:{"type":"gate","id":"a3","gate":{"plan_id":"p1","tool":"update_entity","entity":"ad set change","title":"Milan","diff":[{"label":"Budget","old":"€10","new":"€20"}]}}"#)
        guard case .gate(let o)? = g else { return XCTFail("gate not parsed") }
        let gate = Gate(json: o)
        XCTAssertEqual(gate?.planId, "p1")
        XCTAssertEqual(gate?.diff, [GateDiffRow(label: "Budget", old: "€10", new: "€20")])
        guard case .ask? = ChatEvent.parse(line: #"data:{"type":"ask","ask":{"question":"Which goal?","field":"objective","options":["Leads","Sales"]}}"#) else { return XCTFail("ask") }
        guard case .plan? = ChatEvent.parse(line: #"data:{"type":"plan","plan":{"items":[{"id":"1"}]}}"#) else { return XCTFail("plan") }
        XCTAssertEqual(ChatEvent.parse(line: #"data:{"type":"gate"}"#), .ignored("gate"))
    }

    func testLiveTurnKeepsTheQuestionOnTheMessage() {
        var t = LiveTurn(startedAt: 0)
        t.apply(.actStart(id: "1", tool: "update_entity", label: "x", fields: ["daily_budget", "geo"], status: nil), now: 1)
        XCTAssertEqual(t.actStep, "Budget +1")
        t.apply(.gate(obj(#"{"plan_id":"p9","tool":"create_campaign","entity":"campaign","title":"Spring"}"#)), now: 2)
        t.apply(.done(cites: [], ms: 5), now: 3)
        var m = t.message(id: "m1")
        XCTAssertEqual(m.gate?.planId, "p9")
        XCTAssertEqual(m.gate?.done, false)
        m.markGateDone()
        XCTAssertEqual(m.gate?.done, true)
        XCTAssertEqual((m.saveJSON()["gate"] as? JSONObject)?["done"] as? Bool, true)
    }

    func testStoredMessageWritesTheAnsweredGateBack() {
        let raw = obj(#"{"role":"assistant","content":"Ready","actsHTML":"<i>","gate":{"plan_id":"p2","tool":"update_entity","entity":"campaign change","title":"A","done":false}}"#)
        var m = ChatMessage(json: raw, index: 0)!
        m.markGateDone()
        let saved = m.saveJSON()
        XCTAssertEqual(saved["actsHTML"] as? String, "<i>")
        XCTAssertEqual((saved["gate"] as? JSONObject)?["done"] as? Bool, true)
    }

    func testGateOptionsByModeAndFinal() {
        let g = Gate(json: obj(#"{"plan_id":"p","tool":"create_ad","entity":"ad"}"#))!
        XCTAssertEqual(g.options(mode: .auto), [.yes, .no])          // Lia 2.0: one Yes for the task
        XCTAssertEqual(g.options(mode: .manual), [.yes, .all, .no])  // Lia 2.0 Manual = 1.4 Auto
        let f = Gate(json: obj(#"{"plan_id":"p","tool":"activate_entity","entity":"campaign","final":true}"#))!
        XCTAssertEqual(f.options(mode: .auto), [.yes, .no])
        XCTAssertEqual(f.stepName, "Turn on")
    }

    /// No hold card; the bar above the input is Yes / (Yes to all) / No, and only a click applies.
    /// A digit never applies a write, a spending (final) change included.
    func testGateBarAnswersAreYesNoAndDigitsNeverApply() {
        let g = Gate(json: obj(#"{"plan_id":"p","tool":"create_ad","entity":"ad"}"#))!
        let f = Gate(json: obj(#"{"plan_id":"p","tool":"activate_entity","entity":"campaign","final":true}"#))!
        XCTAssertEqual(g.options(mode: .manual).map(\.label), ["Yes", "Yes to all", "No"])
        XCTAssertEqual(f.options(mode: .manual).map(\.label), ["Yes", "No"])
        for gate in [g, f] {
            for mode in [RunMode.auto, .manual] {
                let opts = gate.options(mode: mode)
                XCTAssertEqual(opts.first, .yes)
                XCTAssertEqual(opts.last, .no)
                for n in 0...4 {
                    if let a = gate.digitAnswer(n, mode: mode) { XCTAssertFalse(a.appliesWrite, "digit \(n) applied a write") }
                }
                XCTAssertEqual(gate.digitAnswer(opts.count, mode: mode), .no)
            }
        }
    }

    func testGateReplyMatchesTheSite() {
        let g = Gate(json: obj(#"{"plan_id":"p1","tool":"create_campaign","entity":"campaign","title":"Spring \"A\""}"#))!
        XCTAssertEqual(ModeReply.gate(g, answer: .no, auto: false, outcome: nil),
                       #"[gate_reply] {"plan_id":"p1","entity":"campaign","title":"Spring \"A\"","answer":"no"}"#)
        XCTAssertEqual(ModeReply.gate(g, answer: .all, auto: false, outcome: .init(createdId: "120")),
                       #"[gate_reply] {"plan_id":"p1","entity":"campaign","title":"Spring \"A\"","answer":"yes","how":"all","created_id":"120"}"#)
        XCTAssertEqual(ModeReply.gate(g, answer: .yes, auto: true, outcome: .init(error: "Meta said no")),
                       #"[gate_reply] {"plan_id":"p1","entity":"campaign","title":"Spring \"A\"","answer":"error","how":"auto","error":"Meta said no"}"#)
        XCTAssertEqual(ModeReply.gate(g, answer: .yes, auto: false, outcome: .init(createdId: nil, job: "j1", pending: true)),
                       #"[gate_reply] {"plan_id":"p1","entity":"campaign","title":"Spring \"A\"","answer":"yes","job":"j1","pending":true,"created_id":null}"#)
    }

    func testAskReplyMatchesTheSite() {
        let a = AskQuestion(json: obj(#"{"question":"Which goal?","field":"objective","options":["Leads"]}"#))!
        XCTAssertEqual(ModeReply.ask(a, answer: "Leads", index: 0, typed: false),
                       #"[ask_reply] {"question":"Which goal?","field":"objective","answer":"Leads","i":0}"#)
        XCTAssertEqual(ModeReply.ask(a, answer: String(repeating: "x", count: 300), index: nil, typed: true).count,
                       #"[ask_reply] {"question":"Which goal?","field":"objective","answer":"","typed":true}"#.count + 300)
        XCTAssertEqual(ModeReply.planNo(), #"[plan_reply] {"answer":"no"}"#)
    }

    func testRepliesReadAsQuotes() {
        let q = ModeReply.quote(for: #"[gate_reply] {"plan_id":"p1","entity":"ad set","title":"Milan","answer":"yes","how":"all"}"#)
        XCTAssertEqual(q?.question, "Create the ad set «Milan»?")
        XCTAssertEqual(q?.answer, "Yes to all")
        XCTAssertEqual(q?.planId, "p1")
        XCTAssertEqual(ModeReply.quote(for: #"[gate_reply] {"entity":"undo","title":"B","answer":"no"}"#)?.question, "Undo the change to «B»?")
        XCTAssertEqual(ModeReply.quote(for: #"[gate_reply] {"entity":"campaign change","title":"B","answer":"error"}"#)?.answer, "Yes · Meta refused it")
        XCTAssertEqual(ModeReply.quote(for: #"[gate_reply] {"entity":"campaign","final":true,"answer":"no"}"#)?.answer, "No, I will edit it")
        XCTAssertEqual(ModeReply.quote(for: #"[ask_reply] {"question":"Q?","field":"budget_level","answer":"Campaign"}"#)?.question, "Where the budget sits")
        XCTAssertEqual(ModeReply.quote(for: #"[plan_reply] {"answer":"publish_on"}"#)?.answer, "Publish and turn on")
        XCTAssertEqual(ModeReply.quote(for: #"[plan_reply] {"answer":"apply","items":[{"created_id":null}]}"#)?.answer, "Apply")
        XCTAssertEqual(ModeReply.quote(for: "[quick_action]  New ad set ")?.answer, "New ad set")
        XCTAssertNil(ModeReply.quote(for: "hello"))
    }

    func testStepsBelongToThisRun() {
        let g1 = Gate(json: obj(#"{"plan_id":"a","tool":"create_campaign","entity":"campaign","title":"C"}"#))
        let g2 = Gate(json: obj(#"{"plan_id":"b","tool":"update_entity","entity":"ad set change","title":"S","diff":[{"label":"Budget","new":"€5"},{"label":"Estimated audience","new":"1M"}]}"#))
        let msgs: [(role: ChatMessage.Role, content: String, gate: Gate?)] = [
            (.user, "old run", nil), (.assistant, "", g1), (.user, "make a campaign", nil),
            (.assistant, "", g1), (.user, #"[gate_reply] {"plan_id":"a","answer":"yes"}"#, nil),
            (.assistant, "", g2),
        ]
        let steps = RunSteps.from(messages: msgs, liveStep: nil, gateOpen: true)
        XCTAssertEqual(steps.map(\.name), ["Campaign", "Budget"])
        XCTAssertEqual(steps.map(\.state), [.done, .cur])
        XCTAssertEqual(steps.last?.subtitle, "S · €5 · 1M")

        let g3 = Gate(json: obj(#"{"plan_id":"c","tool":"update_entity","entity":"ad change","diff":[{"label":"Texts"},{"label":"Link"},{"label":"Button"}]}"#))
        XCTAssertEqual(g3?.stepName, "Texts +2")
        let no: [(role: ChatMessage.Role, content: String, gate: Gate?)] = [
            (.user, "go", nil), (.assistant, "", g1), (.user, #"[gate_reply] {"plan_id":"a","answer":"no"}"#, nil),
            (.assistant, "", g3), (.user, "something else", nil),
        ]
        XCTAssertEqual(RunSteps.from(messages: no.dropLast().map { $0 }, liveStep: "Budget", gateOpen: false).map(\.state), [.no, .cur, .cur])
    }

    func testActNamesFromFields() {
        XCTAssertEqual(RunSteps.actName(tool: "update_entity", fields: ["status"], status: "PAUSED"), "Pause")
        XCTAssertEqual(RunSteps.actName(tool: "update_ad", fields: ["foo"], status: nil), "Edit · ad")
        XCTAssertEqual(RunSteps.actName(tool: "create_ad_set", fields: [], status: nil), "Ad set")
        XCTAssertEqual(RunSteps.actName(tool: "get_campaigns", fields: [], status: nil), "Change")
    }

    func testChatDocKeepsTheModelChoice() {
        let data = Data(#"{"ok":true,"chat":{"id":"c1","model":"lia14","rmode":"manual","messages":[]}}"#.utf8)
        let doc = ChatDoc.parse(data, fallbackId: "c1")!
        XCTAssertEqual(LiaModel.mode(model: doc.model, rmode: doc.rmode), .manual)
        let body = doc.saveBody(messages: [])["chat"] as? JSONObject
        XCTAssertEqual(body?["rmode"] as? String, "manual")
    }

    func testOrderedJSONEscapesLikeStringify() {
        XCTAssertEqual(OrderedJSON.string("a/b\n«é»\u{01}"), #""a/b\n«é»\u0001""#)
    }
}
