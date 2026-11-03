import XCTest
import Foundation
@testable import Liaison

final class AgentHistoryTests: XCTestCase {
    private func cal() -> Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }

    func testStepsReadAsAPersonWouldSayThem() {
        let open = AgentStepPhrase.of(.navigate(URL(string: "https://www.ryanair.com/it/en")!))
        XCTAssertEqual(open?.text, "Opened Ryanair")
        XCTAssertEqual(AgentStepPhrase.of(.navigate(URL(string: "https://flights.google.com/x")!))?.text, "Opened Google Flights")
        XCTAssertEqual(AgentStepPhrase.of(.navigate(URL(string: "https://accounts.google.com/")!))?.text, "Opened Google")
        XCTAssertEqual(AgentStepPhrase.site(URL(string: "https://adsmanager.facebook.com/adsmanager/manage")), "Ads Manager")
        XCTAssertEqual(AgentStepPhrase.site(URL(string: "https://www.bbc.co.uk/news")), "Bbc")
        XCTAssertEqual(AgentStepPhrase.of(.click(id: "k3"), control: "Search")?.text, "Clicked \u{00ab}Search\u{00bb}")
        XCTAssertEqual(AgentStepPhrase.of(.click(id: "k3"))?.text, "Clicked on the page")
        XCTAssertEqual(AgentStepPhrase.of(.type(id: "q", text: "Rome", enter: true))?.text, "Searched for \u{00ab}Rome\u{00bb}")
        XCTAssertEqual(AgentStepPhrase.of(.setDate(id: "d", year: 2026, month: 10, day: 12))?.text, "Picked 12 Oct")
        XCTAssertEqual(AgentStepPhrase.of(.pick(id: "f", text: "Ro", option: "Rome Fiumicino"))?.text, "Chose \u{00ab}Rome Fiumicino\u{00bb}")
        XCTAssertNil(AgentStepPhrase.of(.wait(seconds: 1)))
        XCTAssertNil(AgentStepPhrase.of(.done(ok: true, summary: "x")))
        XCTAssertNil(AgentStepPhrase.of(.invalid("bad")))
    }

    func testTheControlNameComesFromTheSnapshot() {
        let snap = "TEXT:\nhello\n\nCONTROLS:\n[a1] link \u{00ab}Home\u{00bb}\n[k3f] button \u{00ab}Search flights\u{00bb} \u{00b7} in \u{00ab}Form\u{00bb}"
        XCTAssertEqual(AgentStepPhrase.controlName("k3f", in: snap), "Search flights")
        XCTAssertEqual(AgentStepPhrase.controlName("a1", in: snap), "Home")
        XCTAssertNil(AgentStepPhrase.controlName("zz", in: snap))
        XCTAssertNil(AgentStepPhrase.controlName("k3f", in: nil))
    }

    func testRepeatedStepsMergeIntoOne() {
        var t = AgentTaskRecord(id: "1", agent: "lia", title: "Book tickets", started: Date(timeIntervalSince1970: 0))
        let at = Date(timeIntervalSince1970: 10)
        t.add(AgentStepPhrase.of(.navigate(URL(string: "https://ryanair.com")!))!, at: at)
        t.add(AgentStepPhrase.of(.setDate(id: "d", year: 2026, month: 10, day: 12))!, at: at)
        t.add(AgentStepPhrase.of(.setDate(id: "d", year: 2026, month: 10, day: 19))!, at: at)
        t.add(AgentStepPhrase.of(.scroll(down: true))!, at: at)
        t.add(AgentStepPhrase.of(.scroll(down: true))!, at: at)
        t.add(AgentStepPhrase.of(.click(id: "a"), control: "Select")!, at: at)
        t.add(AgentStepPhrase.of(.click(id: "a"), control: "Select")!, at: at)
        t.add(AgentStepPhrase.of(.click(id: "b"), control: "Continue")!, at: at)
        XCTAssertEqual(t.steps.map(\.text), ["Opened Ryanair", "Picked dates", "Looked through the page",
                                             "Clicked \u{00ab}Select\u{00bb}", "Clicked \u{00ab}Continue\u{00bb}"])
    }

    func testStepsAreCapped() {
        var t = AgentTaskRecord(id: "1", agent: "lia", title: "x", started: Date())
        for i in 0..<100 { t.add(AgentStepPhrase.Phrase(text: "Opened \(i)", kind: "open:\(i)"), at: Date()) }
        XCTAssertEqual(t.steps.count, AgentTaskRecord.maxSteps)
        XCTAssertEqual(t.steps.last?.text, "Opened 99")
    }

    func testTheLogKeeps200TasksAndRoundTrips() {
        var log = AgentHistoryLog()
        for i in 0..<230 { log.upsert(AgentTaskRecord(id: "t\(i)", agent: "lia", title: "Task \(i)", started: Date(timeIntervalSince1970: Double(i)))) }
        XCTAssertEqual(log.tasks.count, AgentHistoryLog.cap)
        XCTAssertEqual(log.tasks.first?.id, "t30")
        var t = log.tasks[5]; t.end(.done, summary: "Found 3 flights", at: Date(timeIntervalSince1970: 300))
        log.upsert(t)
        XCTAssertEqual(log.tasks.count, AgentHistoryLog.cap)
        let back = AgentHistoryLog.decode(log.encoded()!)
        XCTAssertEqual(back, log)
        XCTAssertEqual(back?.tasks[5].outcome, .done)
    }

    func testARunningTaskFromAnEarlierLaunchIsClosed() {
        var log = AgentHistoryLog()
        log.upsert(AgentTaskRecord(id: "a", agent: "lia", title: "x", started: Date(timeIntervalSince1970: 0)))
        log.closeStale(at: Date(timeIntervalSince1970: 50))
        XCTAssertEqual(log.tasks[0].outcome, .stopped)
        XCTAssertEqual(log.tasks[0].summary, "Interrupted")
        XCTAssertNotNil(log.tasks[0].ended)
    }

    func testDurations() {
        var t = AgentTaskRecord(id: "1", agent: "lia", title: "x", started: Date(timeIntervalSince1970: 0))
        XCTAssertNil(t.duration)
        t.end(.done, summary: "", at: Date(timeIntervalSince1970: 35)); XCTAssertEqual(t.duration, "35 s")
        t.end(.done, summary: "", at: Date(timeIntervalSince1970: 250)); XCTAssertEqual(t.duration, "4 min")
    }

    func testTasksGroupByDay() {
        let c = cal()
        let now = Date(timeIntervalSince1970: 1_791_000_000)   // 03:20 UTC
        func task(_ id: String, _ ago: Double) -> AgentTaskRecord {
            AgentTaskRecord(id: id, agent: "lia", title: id, started: now.addingTimeInterval(-ago))
        }
        let g = AgentHistoryDays.groups([task("old", 86400 * 3), task("today1", 600), task("y", 86400), task("today2", 60)], now: now, calendar: c)
        XCTAssertEqual(g.map(\.title), ["Today", "Yesterday", "Wed, 30 Sep"])
        XCTAssertEqual(g[0].tasks.map(\.id), ["today2", "today1"])
        XCTAssertEqual(AgentHistoryDays.groups([task("ly", 86400 * 400)], now: now, calendar: c).first?.title, "29 Aug 2025")
    }

    func testFileNamesAreSafe() {
        XCTAssertEqual(AgentHistoryLog.fileName("acc:1|p2|agent-lia"), "acc_1_p2_agent-lia.json")
        XCTAssertEqual(AgentHistoryLog.fileName("../x"), "___x.json")
    }

    func testEachDialogueShowsOnlyItsOwnBrowser() {
        // Lia's dialogue never shows Met's browser, whoever spoke or worked there.
        XCTAssertEqual(AgentPaneChoice.shown(dlg: "team"), "lia")
        XCTAssertEqual(AgentPaneChoice.shown(dlg: "met"), "met")
        XCTAssertEqual(AgentPaneChoice.shown(dlg: "dev"), "dev")
        XCTAssertEqual(AgentPaneChoice.shown(dlg: ""), "lia")
        // A teammate's browser work goes to the teammate's own dialogue; Lia's to Team.
        XCTAssertEqual(AgentPaneChoice.owner(agent: "met"), "met")
        XCTAssertEqual(AgentPaneChoice.owner(agent: "lia"), "team")
        XCTAssertEqual(AgentPaneChoice.owner(agent: "crea"), "crea")
    }

    func testToolTitles() {
        XCTAssertEqual(ToolPhrases.title("create_campaign"), "Setting up the campaign")
        XCTAssertEqual(ToolPhrases.title("no_such_tool"), "Reading the data")
    }

    func testGoToFindsTheReportAfterTheTask() {
        XCTAssertEqual(AgentTaskLink.dialogueKey(session: "dlg:p1:team"), "p1|team")
        XCTAssertNil(AgentTaskLink.dialogueKey(session: "chat-123"))
        XCTAssertNil(AgentTaskLink.dialogueKey(session: nil))
        XCTAssertEqual(AgentTaskLink.split("p1|met")?.dlg, "met")
        XCTAssertNil(AgentTaskLink.split("met"))
        let end = Date(timeIntervalSince1970: 1000)
        let c = [
            AgentTaskLink.Candidate(id: "m1", seq: 1, ts: end.addingTimeInterval(-60), agent: "met"),   // before the end
            AgentTaskLink.Candidate(id: "m2", seq: 2, ts: end.addingTimeInterval(1), agent: nil),       // the person's
            AgentTaskLink.Candidate(id: "l-x", seq: 0, ts: end.addingTimeInterval(2), agent: "met"),    // local copy
            AgentTaskLink.Candidate(id: "m3", seq: 3, ts: end.addingTimeInterval(3), agent: "lia"),
            AgentTaskLink.Candidate(id: "m4", seq: 4, ts: end.addingTimeInterval(4), agent: "met"),
            AgentTaskLink.Candidate(id: "m5", seq: 5, ts: nil, agent: "met"),
        ]
        XCTAssertEqual(AgentTaskLink.result(c, ended: end, agent: "met"), "m4")
        XCTAssertEqual(AgentTaskLink.result(c, ended: end, agent: "nova"), "m3")
        XCTAssertNil(AgentTaskLink.result(c, ended: end.addingTimeInterval(100), agent: "met"))
        var r = AgentTaskRecord(id: "t", agent: "met", title: "Find flights", started: end)
        XCTAssertFalse(r.canGoTo)
        r.dialogue = "p1|met"
        r.end(.done, summary: "Found", at: end)
        XCTAssertTrue(r.canGoTo)
        var log = AgentHistoryLog()
        log.upsert(r)
        XCTAssertEqual(AgentHistoryLog.decode(log.encoded()!)?.tasks.first?.dialogue, "p1|met")
        // a log saved before these fields still reads
        let old = #"{"tasks":[{"id":"a","agent":"met","title":"T","started":1,"outcome":"done","summary":"","steps":[]}]}"#
        XCTAssertNil(AgentHistoryLog.decode(Data(old.utf8))?.tasks.first?.dialogue)
        XCTAssertEqual(AgentHistoryLog.decode(Data(old.utf8))?.tasks.count, 1)
    }
}
