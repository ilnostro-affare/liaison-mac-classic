import XCTest
import Foundation
@testable import Liaison

/// Dev's artifacts - the thread rule, the new blocks, the artifact record, the Activity in plain words and the
/// unified diff.
final class DevArtTests: XCTestCase {
    private func e(_ id: String, run: String?, seg: Int?, fin: Bool = false, agent: String? = "dev") -> DevThread.Entry {
        DevThread.Entry(id: id, agent: agent, run: run, seg: seg, fin: fin)
    }

    func testThreadShowsFirstAndLastOfARun() {
        let list = [e("u", run: nil, seg: nil, agent: nil), e("a", run: "r1", seg: 0), e("b", run: "r1", seg: 1),
                    e("c", run: "r1", seg: 2), e("d", run: "r1", seg: 3, fin: true), e("old", run: nil, seg: nil)]
        XCTAssertEqual(DevThread.hidden(list), ["b", "c"])
        XCTAssertEqual(DevThread.visible(list).map(\.id), ["u", "a", "d", "old"])
        // one or two messages: all shown
        XCTAssertEqual(DevThread.hidden([e("a", run: "r", seg: 0)]), [])
        XCTAssertEqual(DevThread.hidden([e("a", run: "r", seg: 0), e("b", run: "r", seg: 1, fin: true)]), [])
        // older messages without run: untouched
        XCTAssertEqual(DevThread.hidden([e("x", run: nil, seg: nil), e("y", run: nil, seg: nil), e("z", run: nil, seg: nil)]), [])
        // the person's messages never hide, even with a run
        XCTAssertEqual(DevThread.hidden([e("p1", run: "r", seg: 0, agent: nil), e("p2", run: "r", seg: 1, agent: nil), e("p3", run: "r", seg: 2, agent: nil)]), [])
    }

    func testThreadLiveShowsOnlyFirstAndFin() {
        // The run streaming now never shows an intermediate message, not even the newest one
        var list = [e("u", run: nil, seg: nil, agent: nil), e("a", run: "r", seg: 0)]
        XCTAssertEqual(DevThread.hidden(list, liveRun: "r"), [])
        list.append(e("b", run: "r", seg: 1))
        XCTAssertEqual(DevThread.hidden(list, liveRun: "r"), ["b"])
        list.append(e("c", run: "r", seg: 2))
        XCTAssertEqual(DevThread.hidden(list, liveRun: "r"), ["b", "c"])
        list.append(e("f", run: "r", seg: 3, fin: true))
        XCTAssertEqual(DevThread.hidden(list, liveRun: "r"), ["b", "c"])
        XCTAssertEqual(DevThread.visible(list, liveRun: "r").map(\.id), ["u", "a", "f"])
        // another (finished) run keeps the finished rule while this one is live
        let other = [e("x", run: "o", seg: 0), e("y", run: "o", seg: 1)]
        XCTAssertEqual(DevThread.hidden(other + [e("a2", run: "r", seg: 0), e("b2", run: "r", seg: 1)], liveRun: "r"), ["b2"])
        // the turn ended without a fin: its highest seg comes back
        let ended = [e("a", run: "r", seg: 0), e("b", run: "r", seg: 1), e("c", run: "r", seg: 2)]
        XCTAssertEqual(DevThread.hidden(ended, liveRun: "r"), ["b", "c"])
        XCTAssertEqual(DevThread.hidden(ended), ["b"])
        // the person's messages never hide
        XCTAssertEqual(DevThread.hidden([e("p", run: "r", seg: 1, agent: nil)], liveRun: "r"), [])
    }

    func testThreadFinishedTheNewestIntermediateWins() {
        // finished (or read from pages) without a fin: the newest is the last; the previous one goes
        var list = [e("a", run: "r", seg: 0), e("b", run: "r", seg: 1)]
        XCTAssertEqual(DevThread.hidden(list), [])
        list.append(e("c", run: "r", seg: 2))
        XCTAssertEqual(DevThread.hidden(list), ["b"])
        list.append(e("d", run: "r", seg: 3))
        XCTAssertEqual(DevThread.hidden(list), ["b", "c"])
        // two runs are separate
        list += [e("x", run: "r2", seg: 0), e("y", run: "r2", seg: 1), e("z", run: "r2", seg: 2, fin: true)]
        XCTAssertEqual(DevThread.hidden(list), ["b", "c", "y"])
        // the fin message wins over a higher seg
        XCTAssertEqual(DevThread.hidden([e("a", run: "q", seg: 0), e("f", run: "q", seg: 1, fin: true), e("late", run: "q", seg: 2)]), ["late"])
    }

    func testMessageDecodesRunSegFin() {
        let m = DlgMessage(json: ["id": "m1", "seq": 4, "role": "assistant", "agent": "dev", "text": "Done", "run": "rmg2k3", "seg": 3, "fin": true])
        XCTAssertEqual(m?.run, "rmg2k3")
        XCTAssertEqual(m?.seg, 3)
        XCTAssertEqual(m?.fin, true)
        XCTAssertEqual(m?.threadEntry, DevThread.Entry(id: "m1", agent: "dev", run: "rmg2k3", seg: 3, fin: true))
        let old = DlgMessage(json: ["id": "m0", "text": "Hi"])
        XCTAssertNil(old?.run)
        XCTAssertNil(old?.seg)
        XCTAssertEqual(old?.fin, false)
        // the live msg line
        if case .message(let lm)? = DlgStreamEvent.parse(line: #"data: {"type":"msg","message":{"id":"m2","agent":"dev","text":"x","run":"r","seg":1}}"#) {
            XCTAssertEqual(lm.run, "r")
            XCTAssertEqual(lm.seg, 1)
            XCTAssertFalse(lm.fin)
        } else { XCTFail("msg") }
    }

    func testBlocks() {
        let pv = DevPreview(ChatBlock(tool: "dev_preview", data: ["kind": "dev_preview", "url": "https://a.liaisone.com/", "title": "Live site",
                                                                  "art": "art1", "changes": ["files": 3, "add": 40, "del": 2], "steps": 12, "msgs": 2,
                                                                  "site": "alex", "new": true]))
        XCTAssertEqual(pv?.meta.art, "art1")
        XCTAssertEqual(pv?.meta.changes, DevChanges(files: 3, add: 40, del: 2))
        XCTAssertEqual(pv?.meta.changes?.line, "3 files \u{00b7} +40 \u{2212}2")
        XCTAssertEqual(pv?.meta.steps, 12)
        XCTAssertEqual(pv?.site, "alex")
        XCTAssertEqual(pv?.isNew, true)
        // an older block still works
        let old = DevPreview(ChatBlock(tool: "dev_preview", data: ["kind": "dev_preview", "url": "https://a.liaisone.com/"]))
        XCTAssertNil(old?.meta.art)
        XCTAssertNil(old?.meta.fileChanges)
        XCTAssertEqual(DevPreview(ChatBlock(tool: "dev_preview", data: ["kind": "dev_preview", "url": "https://a.liaisone.com/", "changes": ["files": 0]]))?.meta.fileChanges, nil)

        let w = DevWork(ChatBlock(tool: "dev_work", data: ["kind": "dev_work", "title": "Changes", "art": "w1", "changes": ["files": 3, "add": 40, "del": 2], "steps": 5]))
        XCTAssertEqual(w?.title, "Changes")
        XCTAssertEqual(w?.summary, "Edited 3 files")
        XCTAssertEqual(DevWork(ChatBlock(tool: "dev_work", data: ["kind": "dev_work", "title": "Work", "steps": 12]))?.summary, "12 steps")
        XCTAssertNil(DevWork(ChatBlock(tool: "dev_preview", data: ["kind": "dev_preview"])))

        let p = DevPush(ChatBlock(tool: "dev_push", data: ["kind": "dev_push", "repo": "acme/site", "branch": "dev/x", "base": "main",
                                                           "url": "https://github.com/acme/site/compare/main...dev%2Fx", "commit": "abc1234",
                                                           "commits": [["sha": "abc1234ffff", "msg": "Fix footer\n\nlong"], ["sha": "def5678", "msg": "Add page"]],
                                                           "art": "p1", "changes": ["files": 2, "add": 10, "del": 1]]))
        XCTAssertEqual(p?.title, "dev/x")
        XCTAssertEqual(p?.summary, "acme/site \u{00b7} 2 commits")
        XCTAssertEqual(p?.route, "dev/x \u{2192} main")
        XCTAssertEqual(p?.url?.host, "github.com")
        XCTAssertEqual(p?.commits.first?.short, "abc1234")
        XCTAssertEqual(p?.commits.first?.title, "Fix footer")
        XCTAssertEqual(DevPush(ChatBlock(tool: "dev_push", data: ["kind": "dev_push", "repo": "a/b", "branch": "x", "commit": "abc"]))?.summary, "a/b \u{00b7} 1 commit")
        XCTAssertNil(DevPush(ChatBlock(tool: "dev_push", data: ["kind": "dev_push"])))
        XCTAssertNil(DevPush(ChatBlock(tool: "dev_push", data: ["kind": "dev_push", "branch": "x", "url": "javascript:x"]))?.url)
    }

    func testCanvasItemsPerArtifact() {
        let a = CanvasItem(block: ChatBlock(tool: "dev_preview", data: ["kind": "dev_preview", "url": "https://pv.liaisone.com/", "art": "t1"]), profile: "p")!
        let b = CanvasItem(block: ChatBlock(tool: "dev_preview", data: ["kind": "dev_preview", "url": "https://pv.liaisone.com/", "art": "t2"]), profile: "p")!
        XCTAssertTrue(a.id != b.id)
        XCTAssertEqual(a.art, "t1")
        // without art the old id stays
        let c = CanvasItem(block: ChatBlock(tool: "dev_preview", data: ["kind": "dev_preview", "url": "https://pv.liaisone.com/"]), profile: "p")!
        XCTAssertEqual(c.id, "devPreview|https://pv.liaisone.com/")
        // a second turn's preview of the same address starts on its own Preview, not the first one's tab
        var s = CanvasState.opening(a, over: nil)
        s.tab = .code
        XCTAssertEqual(CanvasState.opening(b, over: s).tab, .preview)

        let w = CanvasItem(block: ChatBlock(tool: "dev_work", data: ["kind": "dev_work", "title": "Changes", "art": "w", "changes": ["files": 1, "add": 1, "del": 0]]), profile: "p")!
        XCTAssertEqual(w.kind, .devWork)
        XCTAssertEqual(CanvasState(item: w).tabs, [.activity, .code])
        XCTAssertEqual(CanvasState(item: w).tab, .activity)
        XCTAssertTrue(w.prefersChanges)

        let push = CanvasItem(block: ChatBlock(tool: "dev_push", data: ["kind": "dev_push", "repo": "a/b", "branch": "dev/x", "url": "https://github.com/a/b/compare/main...dev%2Fx", "art": "g"]), profile: "p")!
        XCTAssertEqual(push.kind, .devPush)
        XCTAssertNil(push.previewURL)
        XCTAssertEqual(CanvasState(item: push).tabs, [.activity, .code])
        XCTAssertEqual(CanvasState(item: push).tab, .code)
        XCTAssertEqual(CanvasState.arriving(push, over: CanvasState(item: a)).tab, .code)
        XCTAssertTrue(push.prefersChanges)
        // no record: no Changes scope, the files as before
        XCTAssertFalse(c.hasChanges)
        XCTAssertFalse(c.prefersChanges)
    }

    func testCanvasKeepsTheProjectPreview() {
        // Changes and a push carry the project's preview: Preview first, then Activity, then Code
        let w = CanvasItem(block: ChatBlock(tool: "dev_work", data: ["kind": "dev_work", "title": "Changes", "art": "w",
                                                                     "changes": ["files": 1, "add": 1, "del": 0], "preview": "https://pv.liaisone.com/"]), profile: "p")!
        XCTAssertEqual(w.previewURL?.absoluteString, "https://pv.liaisone.com/")
        XCTAssertEqual(CanvasState(item: w).tabs, [.preview, .activity, .code])
        XCTAssertEqual(CanvasState(item: w).tab, .preview)
        let push = CanvasItem(block: ChatBlock(tool: "dev_push", data: ["kind": "dev_push", "repo": "a/b", "branch": "dev/x", "art": "g",
                                                                       "url": "https://github.com/a/b/compare/main...dev%2Fx",
                                                                       "preview": "https://site.liaisone.com/"]), profile: "p")!
        XCTAssertEqual(CanvasState(item: push).tabs, [.preview, .activity, .code])
        XCTAssertEqual(CanvasState(item: push).tab, .preview)
        XCTAssertEqual(push.push?.url?.host, "github.com")
        // a bad address is no page
        XCTAssertNil(CanvasItem(block: ChatBlock(tool: "dev_work", data: ["kind": "dev_work", "preview": "javascript:x"]), profile: "p")!.previewURL)

        // no page of its own: the dialogue's newest one; a preview's own address always wins
        let page = URL(string: "https://last.liaisone.com/")!
        let bare = CanvasItem(block: ChatBlock(tool: "dev_work", data: ["kind": "dev_work", "title": "Work", "art": "w2"]), profile: "p")!
        XCTAssertEqual(CanvasState(item: bare).tabs, [.activity, .code])
        XCTAssertEqual(bare.withPage(page).previewURL, page)
        XCTAssertEqual(CanvasState(item: bare.withPage(page)).tabs, [.preview, .activity, .code])
        XCTAssertEqual(bare.withPage(page).id, bare.id)
        XCTAssertEqual(w.withPage(page).previewURL?.absoluteString, "https://pv.liaisone.com/")
        let pv = CanvasItem(block: ChatBlock(tool: "dev_preview", data: ["kind": "dev_preview", "url": "https://pv2.liaisone.com/"]), profile: "p")!
        XCTAssertEqual(pv.withPage(page).previewURL?.absoluteString, "https://pv2.liaisone.com/")

        // the pages blocks name
        XCTAssertEqual(CanvasItem.page(of: ChatBlock(tool: "dev_preview", data: ["kind": "dev_preview", "url": "https://a.liaisone.com/"]))?.host, "a.liaisone.com")
        XCTAssertEqual(CanvasItem.page(of: ChatBlock(tool: "dev_push", data: ["kind": "dev_push", "repo": "a/b", "preview": "https://b.liaisone.com/"]))?.host, "b.liaisone.com")
        XCTAssertNil(CanvasItem.page(of: ChatBlock(tool: "dev_push", data: ["kind": "dev_push", "repo": "a/b"])))
        XCTAssertNil(CanvasItem.page(of: ChatBlock(tool: "dev_confirm", data: ["kind": "dev_confirm"])))

        // Dev starts working: the live Activity keeps the Preview tab, opening on Activity
        let s = CanvasState.activity(profile: "p", page: page, over: nil)
        XCTAssertEqual(s.tabs, [.preview, .activity, .code])
        XCTAssertEqual(s.tab, .activity)
        XCTAssertEqual(CanvasState.activity(profile: "p", over: nil).tabs, [.activity, .code])
        // already on the live Activity: a newer page comes in
        let newer = URL(string: "https://newer.liaisone.com/")!
        XCTAssertEqual(CanvasState.activity(profile: "p", page: newer, over: s).item.previewURL, newer)
        XCTAssertEqual(CanvasState.activity(profile: "p", over: s).item.previewURL, page)
    }

    func testArtRecordParse() {
        let json = #"""
        {"ok":true,"id":"a1","kind":"dev_push","title":"dev/x","at":1700000000000,"source":"git","repo":"acme/site","branch":"dev/x","base":"main",
         "url":"https://github.com/acme/site/compare/main...dev%2Fx",
         "activity":[{"t":"msg","text":"Starting.","at":1},{"t":"step","tool":"write_file","targs":{"path":"/workspace/project/index.html"},"sum":"Saved index.html","failed":false,"ms":20,"at":2},
                     {"t":"step","tool":"run","targs":{"command":"npm test"},"sum":"Exit 1","failed":true,"at":3},{"t":"msg","text":"  ","at":4}],
         "changes":[{"path":"index.html","add":3,"del":1},{"path":"logo.png","add":-1,"del":-1}],
         "diff":"diff --git a/index.html b/index.html\n","cut":true,"commits":[{"sha":"abc","msg":"x"}]}
        """#
        guard case .success(let r) = DevArtRecord.parse(Data(json.utf8)) else { return XCTFail("parse") }
        XCTAssertEqual(r.kind, "dev_push")
        XCTAssertTrue(r.isGit)
        XCTAssertEqual(r.branch, "dev/x")
        XCTAssertEqual(r.activity.count, 3)
        if case .step(let s) = r.activity[1] {
            XCTAssertEqual(s.text, "Edited index.html")
            XCTAssertEqual(s.subject, "index.html")
            XCTAssertEqual(s.result, "Saved index.html")
            XCTAssertFalse(s.running)
        } else { XCTFail("step") }
        if case .step(let s) = r.activity[2] { XCTAssertTrue(s.failed) } else { XCTFail("failed step") }
        XCTAssertEqual(r.changes.map(\.binary), [false, true])
        XCTAssertTrue(r.cut)
        XCTAssertEqual(r.commits.count, 1)
        if case .failure(let e) = DevArtRecord.parse(Data(#"{"ok":false,"error":"not found"}"#.utf8)) {
            XCTAssertEqual(e.message, "not found")
        } else { XCTFail("error") }
        if case .failure = DevArtRecord.parse(Data("<html>".utf8)) {} else { XCTFail("junk") }
    }

    private func step(_ id: String, _ tool: String, _ args: [String: String], failed: Bool = false, done: Bool = true) -> DevArtEntry {
        var s = DevStep.start(id: id, tool: tool, args: args, at: 0)
        if done { s.result = failed ? "Exit 1" : "ok"; s.failed = failed }
        return .step(s)
    }

    func testActivityGroupsAndSentences() {
        let entries: [DevArtEntry] = [
            .msg(id: "1", text: "Let me look."),
            step("a", "write_file", ["path": "index.html"]),
            step("b", "write_file", ["path": "css/styles.css"]),
            step("c", "write_file", ["path": "index.html"]),
            step("d", "check_preview", ["path": "/"]),
            .msg(id: "2", text: "Now the tests."),
            step("e", "run", ["command": "npm i"]),
            step("f", "run", ["command": "npm test"], failed: true),
            step("g", "run", ["command": "npm run build"]),
            step("h", "write_file", ["path": "a.js"]), step("i", "write_file", ["path": "b.js"]),
            step("j", "write_file", ["path": "c.js"]), step("k", "write_file", ["path": "d.js"]),
        ]
        let g = DevActivityGroups.make(entries)
        XCTAssertEqual(g.map(\.kind), [.message, .steps, .message, .steps])
        XCTAssertEqual(g[1].text, "Edited index.html and styles.css, checked the page")
        XCTAssertNil(g[1].failures)
        XCTAssertEqual(g[1].steps.count, 4)
        XCTAssertEqual(g[3].text, "Ran 3 commands, edited 4 files")
        XCTAssertEqual(g[3].failures, "1 command failed")
        XCTAssertEqual(DevActivityGroups.failures([{ var s = DevStep.start(id: "x", tool: "write_file", args: [:], at: 0); s.failed = true; return s }()]), "1 step failed")
        XCTAssertEqual(DevActivityGroups.sentence([DevStep.start(id: "1", tool: "write_file", args: [:], at: 0)]), "Edited a file")
        XCTAssertEqual(DevActivityGroups.sentence([DevStep.start(id: "1", tool: "run", args: ["command": "ls"], at: 0)]), "Ran a command")
        XCTAssertEqual(DevActivityGroups.sentence([DevStep.start(id: "1", tool: "git_clone", args: ["repo": "acme/site"], at: 0),
                                                   DevStep.start(id: "2", tool: "git_push", args: ["repo": "acme/site", "branch": "x"], at: 0)]),
                       "Cloned acme/site, pushed the code")
        XCTAssertEqual(DevActivityGroups.list(["a", "b", "c"]), "a, b and c")
        // a running step marks its group
        let live = DevActivityGroups.make([step("z", "run", ["command": "npm i"], done: false)])
        XCTAssertTrue(live[0].running)
        XCTAssertEqual(DevActivityGroups.make([]), [])
    }

    func testLiveActivityKeepsMessagesBetweenSteps() {
        var a = DevActivity()
        a.note(id: "m0", text: "On it.", run: "r")
        a.clear(keepingRun: "r")     // the first step starts the turn: the run's message stays
        XCTAssertEqual(a.notes.count, 1)
        a.on(.actStart(id: "d1", tool: "write_file", args: ["path": "index.html"]), at: 1)
        a.on(.actDone(id: "d1", sum: "Saved"), at: 2)
        a.note(id: "m1", text: "Checking it.", run: "r")
        a.note(id: "m1", text: "Checking it now.", run: "r")   // the stored copy again: one message, new text
        a.on(.actStart(id: "d2", tool: "check_preview", args: [:]), at: 3)
        let kinds = a.entries.map { e -> String in if case .msg(_, let t, _) = e { return t } else { return "step" } }
        XCTAssertEqual(kinds, ["On it.", "step", "Checking it now.", "step"])
        XCTAssertEqual(DevActivityGroups.make(a.entries).map(\.kind), [.message, .steps, .message, .steps])
        a.clear(keepingRun: "other")
        XCTAssertTrue(a.isBlank)
        a.note(id: "x", text: "  ", run: nil)
        XCTAssertTrue(a.isBlank)
        // The words Dev writes after its first message stream in the Activity (a draft)...
        a.on(.actStart(id: "s1", tool: "write_file", args: ["path": "a.js"]), at: 1)
        a.stream("Now the", run: "r", at: 5)
        a.stream("Now the styles.", run: "r", at: 6)
        var groups = DevActivityGroups.make(a.entries)
        XCTAssertEqual(groups.map(\.kind), [.steps, .message])
        XCTAssertEqual(groups.last?.text, "Now the styles.")
        XCTAssertEqual(groups.last?.streaming, true)
        XCTAssertEqual(groups.last?.at, 5)
        // ...and its stored copy takes the draft's place (and time), no longer streaming
        a.on(.actStart(id: "s2", tool: "run", args: ["command": "npm test"]), at: 7)
        a.note(id: "m5", text: "Now the styles.", run: "r", at: 9)
        XCTAssertNil(a.draft)
        groups = DevActivityGroups.make(a.entries)
        XCTAssertEqual(groups.map(\.kind), [.steps, .message, .steps])
        XCTAssertEqual(groups[1].streaming, false)
        XCTAssertEqual(groups[1].at, 5)
        // a draft with no stored copy is kept as a message; the final one's draft is dropped
        a.stream("Checking.", run: "r", at: 10)
        a.keepDraft(id: "l-1")
        XCTAssertNil(a.draft)
        XCTAssertEqual(a.notes.last?.text, "Checking.")
        a.stream("All done!", run: "r", at: 11)
        XCTAssertFalse(a.isBlank)
        a.dropDraft()
        XCTAssertFalse(DevActivityGroups.make(a.entries).contains { $0.text == "All done!" })
        a.stream("   ", run: "r", at: 12)
        XCTAssertNil(a.draft)
        // a saved record's messages carry their time
        let rec = DevArtRecord(json: ["id": "x", "activity": [["t": "msg", "text": "Hi", "at": 1700000000000.0]]])
        XCTAssertEqual(DevActivityGroups.make(rec.activity).first?.at, 1700000000000)
    }

    func testDiffParse() {
        let diff = """
        diff --git a/index.html b/index.html
        index 1111111..2222222 100644
        --- a/index.html
        +++ b/index.html
        @@ -10,4 +10,5 @@ <body>
         <h1>Hi</h1>
        -<p>Old</p>
        +<p>New</p>
        +<p>More</p>
         <footer>
        \\ No newline at end of file
        @@ -40 +41 @@
        --- a dashed line deleted
        +++ a plus line added
        diff --git a/new.js b/new.js
        new file mode 100644
        index 0000000..3333333
        --- /dev/null
        +++ b/new.js
        @@ -0,0 +1,2 @@
        +let a = 1
        +
        diff --git a/logo.png b/logo.png
        index 4444444..5555555 100644
        Binary files a/logo.png and b/logo.png differ
        diff --git a/gone.txt b/gone.txt
        deleted file mode 100644
        --- a/gone.txt
        +++ /dev/null
        @@ -1 +0,0 @@
        -bye

        """
        let files = DevDiff.parse(diff)
        XCTAssertEqual(files.map(\.path), ["index.html", "new.js", "logo.png", "gone.txt"])
        let f = files[0]
        XCTAssertEqual(f.hunks.count, 2)
        XCTAssertEqual(f.add, 3)
        XCTAssertEqual(f.del, 2)
        let h = f.hunks[0]
        XCTAssertEqual(h.label, "Lines 10\u{2013}14")
        XCTAssertEqual(h.lines.map(\.kind), [.context, .del, .add, .add, .context])
        XCTAssertEqual(h.lines[0].old, 10); XCTAssertEqual(h.lines[0].new, 10)
        XCTAssertEqual(h.lines[1].old, 11); XCTAssertNil(h.lines[1].new)
        XCTAssertNil(h.lines[2].old); XCTAssertEqual(h.lines[2].new, 11)
        XCTAssertEqual(h.lines[4].old, 12); XCTAssertEqual(h.lines[4].new, 13)
        XCTAssertEqual(h.lines[1].text, "<p>Old</p>")
        // "--- " and "+++ " inside a hunk are its lines, not headers
        XCTAssertEqual(f.hunks[1].lines.map(\.text), ["-- a dashed line deleted", "++ a plus line added"])
        XCTAssertEqual(f.hunks[1].label, "Line 41")
        XCTAssertEqual(files[1].add, 2)
        XCTAssertEqual(files[1].hunks[0].lines[1].text, "")
        XCTAssertTrue(files[2].binary)
        XCTAssertTrue(files[2].hunks.isEmpty)
        XCTAssertEqual(files[3].del, 1)
        XCTAssertEqual(files[3].hunks[0].label, "Line 1")
        XCTAssertEqual(DevDiff.file("logo.png", in: files)?.binary, true)
        XCTAssertNil(DevDiff.file("nope", in: files))
        XCTAssertEqual(DevDiff.parse(""), [])
    }

    func testDiffPlainUnifiedAndRename() {
        let plain = "--- a/x.txt\n+++ b/x.txt\n@@ -1,2 +1,2 @@\n-a\n+b\n c\n--- a/y.txt\n+++ b/y.txt\n@@ -3 +3 @@\n-q\n+r\n"
        let files = DevDiff.parse(plain)
        XCTAssertEqual(files.map(\.path), ["x.txt", "y.txt"])
        XCTAssertEqual(files[1].hunks[0].lines.map(\.old), [3, nil])
        let rename = "diff --git a/old.txt b/new.txt\nsimilarity index 90%\nrename from old.txt\nrename to new.txt\n--- a/old.txt\n+++ b/new.txt\n@@ -1 +1 @@\n-x\n+y\n"
        let r = DevDiff.parse(rename)
        XCTAssertEqual(r.first?.path, "new.txt")
        XCTAssertEqual(r.first?.oldPath, "old.txt")
        XCTAssertEqual(DevDiff.file("old.txt", in: r)?.path, "new.txt")
        XCTAssertEqual(DevDiff.hunkHeader("@@ -10,7 +12 @@ func")?.0, 10)
        XCTAssertEqual(DevDiff.hunkHeader("@@ -10,7 +12 @@ func")?.3, 1)
        XCTAssertNil(DevDiff.hunkHeader("@@ nonsense"))
        // Windows line ends are read too
        XCTAssertEqual(DevDiff.parse("--- a/w\r\n+++ b/w\r\n@@ -1 +1 @@\r\n-a\r\n+b\r\n").first?.hunks.first?.lines.map(\.text), ["a", "b"])
    }
}
