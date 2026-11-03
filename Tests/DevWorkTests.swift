import XCTest
import Foundation
@testable import Liaison

/// Dev's work in separate messages with a short status, Manual mode's question, its activity on the Canvas and
/// in "What did Dev do?", and long pastes in the composer.
final class DevWorkTests: XCTestCase {
    func testDevLinesParse() {
        XCTAssertEqual(DevLine.parse(line: #"data:{"type":"dev_status","text":"Editing files","agent":"dev"}"#), .status("Editing files"))
        XCTAssertNil(DevLine.parse(line: #"data:{"type":"dev_status","text":"  "}"#))
        XCTAssertEqual(DevLine.parse(line: #"data: {"type":"segment_end","agent":"dev","dlg":"dev"}"#), .segmentEnd)
        XCTAssertEqual(DevLine.parse(line: #"data:{"type":"dev_confirm","id":"d3","tool":"run","summary":"Run: npm test"}"#),
                       .confirm(id: "d3", tool: "run", summary: "Run: npm test"))
        XCTAssertEqual(DevLine.parse(line: #"data:{"type":"act_start","id":"d1","tool":"write_file","label":"Edit file","targs":{"path":"index.html","bytes":12}}"#),
                       .actStart(id: "d1", tool: "write_file", args: ["path": "index.html", "bytes": "12"]))
        XCTAssertEqual(DevLine.parse(line: #"data:{"type":"act_done","id":"d1","sum":"Saved index.html"}"#), .actDone(id: "d1", sum: "Saved index.html"))
        // Lia 2.0's act_done (an object) and another agent's lines are not Dev's.
        XCTAssertNil(DevLine.parse(line: #"data:{"type":"act_done","id":"x","sum":{"ok":true}}"#))
        XCTAssertNil(DevLine.parse(line: #"data:{"type":"act_start","id":"x","tool":"get_campaigns","targs":{}}"#))
        XCTAssertNil(DevLine.parse(line: #"data:{"type":"dev_status","text":"x","agent":"met"}"#))
        XCTAssertNil(DevLine.parse(line: "event: ping"))
    }

    func testSegmentEndStartsANewBubble() {
        // the stored copy came first and closed the bubble: the same agent writes on below
        XCTAssertEqual(DevSegment.onEnd(liveAgent: nil, liveOpen: false, turnAgent: "dev"), .restart("dev"))
        // no stored copy: what streamed is kept, then the next bubble
        XCTAssertEqual(DevSegment.onEnd(liveAgent: "dev", liveOpen: true, turnAgent: "dev"), .finishAndRestart("dev"))
        XCTAssertEqual(DevSegment.onEnd(liveAgent: nil, liveOpen: false, turnAgent: nil), .ignore)
    }

    func testConfirmBlockAndReply() {
        let b = ChatBlock(tool: "dev_confirm", data: ["kind": "dev_confirm", "tool": "run", "summary": "Run: npm run build", "status": "pending"])
        let c = DevConfirm(b)
        XCTAssertEqual(c?.tool, "run")
        XCTAssertEqual(c?.status, "pending")
        XCTAssertEqual(c?.shown, "npm run build")
        XCTAssertEqual(c?.isCommand, true)
        XCTAssertEqual(c?.title, "Dev wants to run a command")
        let e = DevConfirm(ChatBlock(tool: "dev_confirm", data: ["kind": "dev_confirm", "tool": "write_file", "summary": "Edit index.html"]))
        XCTAssertEqual(e?.shown, "Edit index.html")
        XCTAssertEqual(e?.isCommand, false)
        XCTAssertNil(DevConfirm(ChatBlock(tool: "dev_preview", data: ["kind": "dev_preview", "url": "https://a.b/"])))
        XCTAssertEqual(DevConfirm.first(in: [ChatBlock(tool: "dev_preview", data: ["kind": "dev_preview"]), b])?.tool, "run")
        XCTAssertEqual(DevConfirm.reply(true), #"[gate_reply] {"dev":"yes"}"#)
        XCTAssertEqual(DevConfirm.reply(false), #"[gate_reply] {"dev":"no"}"#)
        // the person's answer is a machine message: never shown as their bubble
        XCTAssertTrue(AgentOf.isMachine(ChatMessage(role: .user, content: DevConfirm.reply(true))))
    }

    func testDevModeStored() {
        XCTAssertEqual(DevMode.stored(nil), .auto)
        XCTAssertEqual(DevMode.stored("manual"), .manual)
        XCTAssertEqual(DevMode.stored("x"), .auto)
        XCTAssertEqual(DevMode.key(profile: "p1"), "lia_dev_mode_p1")
    }

    func testStepsReadAsOneLine() {
        XCTAssertEqual(DevStep.start(id: "1", tool: "write_file", args: ["path": "/workspace/project/src/app.js"], at: 0).text, "Edited src/app.js")
        let run = DevStep.start(id: "2", tool: "run", args: ["command": "npm test"], at: 0)
        XCTAssertEqual(run.text, "npm test")
        XCTAssertTrue(run.code)
        XCTAssertEqual(run.kind, .command)
        XCTAssertEqual(DevStep.start(id: "3", tool: "start_preview", args: [:], at: 0).text, "Opened the preview")
        XCTAssertEqual(DevStep.start(id: "4", tool: "git_clone", args: ["repo": "acme/site"], at: 0).text, "Cloned acme/site")
        XCTAssertEqual(DevStep.start(id: "5", tool: "git_push", args: ["repo": "acme/site", "branch": "dev/footer"], at: 0).text, "Pushed dev/footer to acme/site")
        XCTAssertEqual(DevStep.start(id: "6", tool: "github_api", args: ["method": "post", "path": "/repos/acme/site/pulls"], at: 0).text,
                       "GitHub POST /repos/acme/site/pulls")
        XCTAssertEqual(DevStep.start(id: "7", tool: "check_preview", args: ["path": "/"], at: 0).text, "Checked the page")
        let pub = DevStep.start(id: "8", tool: "publish_site", args: [:], at: 0)
        XCTAssertEqual(pub.text, "Published the site")
        XCTAssertEqual(pub.symbol, "globe")
        XCTAssertTrue(DevStep.failed("Not published"))
        XCTAssertEqual(DevPreview(ChatBlock(tool: "dev_preview", data: ["kind": "dev_preview", "url": "https://alex-rossi.liaisone.com/", "title": "Live site"]))?.isLive, true)
        XCTAssertEqual(DevLine.parse(line: #"data:{"type":"act_start","id":"d9","tool":"publish_site","targs":{}}"#),
                       .actStart(id: "d9", tool: "publish_site", args: [:]))
        XCTAssertEqual(DevStep.task(id: "t1", title: "Fix the footer", at: 0).text, "Took the task \u{00ab}Fix the footer\u{00bb}")
        XCTAssertTrue(DevStep.failed("Exit 1"))
        XCTAssertFalse(DevStep.failed("Exit 0"))
        XCTAssertFalse(DevStep.failed("Saved index.html"))
        XCTAssertTrue(DevStep.failed("GitHub 403"))
        XCTAssertEqual(DevStep.symbol(historyKind: run.phrase.kind), "terminal")
        XCTAssertEqual(run.phrase.text, "Ran npm test")
        XCTAssertNil(DevStep.symbol(historyKind: "open:Google"))
    }

    func testActivityFollowsTheStream() {
        var a = DevActivity()
        a.on(.status("Editing files"), at: 1)
        XCTAssertEqual(a.status, "Editing files")
        a.on(.actStart(id: "d1", tool: "write_file", args: ["path": "index.html"]), at: 2)
        XCTAssertEqual(a.steps.count, 1)
        XCTAssertTrue(a.steps[0].running)
        a.on(.actDone(id: "d1", sum: "Saved index.html"), at: 3)
        XCTAssertEqual(a.steps[0].result, "Saved index.html")
        XCTAssertFalse(a.steps[0].failed)
        XCTAssertNil(a.status)
        a.on(.actStart(id: "d2", tool: "run", args: ["command": "npm test"]), at: 4)
        a.on(.actDone(id: "d2", sum: "Exit 2"), at: 5)
        XCTAssertTrue(a.steps[1].failed)
        a.on(.actStart(id: "d3", tool: "check_preview", args: [:]), at: 6)
        a.end()
        XCTAssertEqual(a.steps[2].result, "Stopped")
        a.add(DevStep.task(id: "t", title: "x", at: 7))
        a.add(DevStep.task(id: "t", title: "x", at: 8))
        XCTAssertEqual(a.steps.count, 4)
    }

    func testTypingLine() {
        XCTAssertEqual(TypingLine.text(devStatus: "Running command", live: nil), "Running command")
        XCTAssertNil(TypingLine.text(devStatus: nil, live: nil))
        var l = LiveTurn(startedAt: 0)
        l.status.pick = { $0[0] }
        l.apply(.reason("x"), now: 1)
        // thinking is not a tool phrase: "<Name> is writing"
        XCTAssertNil(TypingLine.text(devStatus: nil, live: l))
        l.apply(.actStart(id: "a", tool: "get_campaigns", label: "Campaigns"), now: 5000)
        XCTAssertNotNil(TypingLine.text(devStatus: nil, live: l))
        l.apply(.actDone(id: "a"), now: 6000)
        l.apply(.delta("Hi"), now: 9000)
        XCTAssertNil(TypingLine.text(devStatus: nil, live: l))
    }

    func testLongPaste() {
        XCTAssertFalse(LongPaste.isLong(String(repeating: "a", count: 1500)))
        XCTAssertTrue(LongPaste.isLong(String(repeating: "a", count: 1501)))
        XCTAssertFalse(LongPaste.isLong(Array(repeating: "x", count: 20).joined(separator: "\n")))
        XCTAssertTrue(LongPaste.isLong(Array(repeating: "x", count: 21).joined(separator: "\n")))
        XCTAssertEqual(LongPaste.size(String(repeating: "a", count: 2345)), "2,345 chars")
        let b = LongPaste.block(name: "Pasted text.txt", text: "line\n```code```")
        XCTAssertTrue(b.hasPrefix("[attached: Pasted text.txt, 15 chars]\n````\n"))
        XCTAssertTrue(b.hasSuffix("\n````"))
    }

    func testCanvasActivityTab() {
        let fresh = CanvasState.activity(profile: "p", over: nil)
        XCTAssertEqual(fresh.tab, .activity)
        XCTAssertEqual(fresh.item.kind, .activity)
        // Activity, then Code (last)
        XCTAssertEqual(fresh.tabs, [.activity, .code])
        let page = CanvasItem(block: ChatBlock(tool: "dev_preview", data: ["kind": "dev_preview", "url": "https://a.dev.liaisone.com/"]), profile: "p")!
        // a preview arriving switches to Preview, from Activity and from the same page's Code
        let shown = CanvasState.arriving(page, over: fresh)
        XCTAssertEqual(shown.tab, .preview)
        XCTAssertEqual(shown.tabs, [.preview, .activity, .code])
        var code = shown
        code.tab = .code
        XCTAssertEqual(CanvasState.arriving(page, over: code).tab, .preview)
        // Dev starting again shows Dev working now (each artifact keeps its own activity), the width stays
        var wide = shown
        wide.mobile = true
        let again = CanvasState.activity(profile: "p", over: wide)
        XCTAssertEqual(again.item.kind, .activity)
        XCTAssertEqual(again.tab, .activity)
        XCTAssertTrue(again.mobile)
    }

    func testDevContinueBlock() {
        let b = ChatBlock(tool: "dev_continue", data: ["kind": "dev_continue", "why": "time", "label": "Continue", "text": "continue",
                                                      "minutes": 60, "spent_usd": 1.23, "steps": 140])
        let c = DevContinue(b)
        XCTAssertEqual(c?.why, "time")
        XCTAssertEqual(c?.label, "Continue")
        XCTAssertEqual(c?.text, "continue")
        XCTAssertEqual(c?.minutes, 60)
        XCTAssertEqual(c?.steps, 140)
        XCTAssertEqual(c?.reason, "Dev paused after 60 minutes of work")
        let cost = DevContinue(ChatBlock(tool: "dev_continue", data: ["kind": "dev_continue", "why": "cost", "spent_usd": 1.234]))
        XCTAssertEqual(cost?.reason, "Dev paused after spending $1.23")
        XCTAssertEqual(cost?.label, "Continue")
        XCTAssertEqual(cost?.text, "continue")
        let hops = DevContinue(ChatBlock(tool: "dev_continue", data: ["kind": "dev_continue", "why": "HOPS", "steps": 140, "label": "Keep going", "text": "go on"]))
        XCTAssertEqual(hops?.reason, "Dev paused after 140 steps")
        XCTAssertEqual(hops?.label, "Keep going")
        XCTAssertEqual(hops?.text, "go on")
        XCTAssertEqual(DevContinue(ChatBlock(tool: "dev_continue", data: ["why": "weird"]))?.reason, "Dev paused")
        XCTAssertNil(DevContinue(ChatBlock(tool: "dev_confirm", data: ["kind": "dev_confirm"])))
        XCTAssertEqual(DevContinue.first(in: [ChatBlock(tool: "dev_preview", data: ["kind": "dev_preview"]), b])?.why, "time")
        // the stream's block event decodes to the same block
        let ev = ChatEvent.parse(line: #"data: {"type":"block","id":"dk","tool":"dev_continue","data":{"kind":"dev_continue","why":"cost","label":"Continue","text":"continue"}}"#)
        if case .some(.block(let sb)) = ev { XCTAssertEqual(DevContinue(sb)?.why, "cost") } else { XCTFail("no block event") }
    }
}
