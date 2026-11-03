import XCTest
import Foundation
@testable import Liaison

/// Home, the welcome and the tips: roles, the workspace's summed yesterday, the tip gate, the team row,
/// the repository rows and the activity's copy on disk.
final class HomeCoreTests: XCTestCase {
    func testRolesKeepTheirStoredValuesAndOrder() {
        XCTAssertEqual(LiaRole.allCases.map(\.rawValue), ["developer", "marketer", "agency", "owner"])
        XCTAssertEqual(LiaRole.stored("agency"), .agency)
        XCTAssertEqual(LiaRole.stored(" Owner "), .owner)
        XCTAssertEqual(LiaRole.stored("marketer"), .marketer)
        XCTAssertNil(LiaRole.stored(""))
        XCTAssertNil(LiaRole.stored("designer"))
        XCTAssertNil(LiaRole.stored(nil))
        XCTAssertTrue(LiaRole.developer.githubFirst)
        XCTAssertFalse(LiaRole.marketer.githubFirst)
        for r in LiaRole.allCases { XCTAssertFalse(r.title.isEmpty); XCTAssertFalse(r.line.isEmpty) }
    }

    // The brief's sums and periods: BriefPeriodTests.

    func testTipGate() {
        XCTAssertFalse(TipGate.open(onboarded: false, touring: false, tourEnabled: true, tourSeen: true))
        XCTAssertFalse(TipGate.open(onboarded: true, touring: true, tourEnabled: true, tourSeen: true))
        XCTAssertFalse(TipGate.open(onboarded: true, touring: false, tourEnabled: true, tourSeen: false))
        XCTAssertTrue(TipGate.open(onboarded: true, touring: false, tourEnabled: false, tourSeen: false))
        XCTAssertTrue(TipGate.open(onboarded: true, touring: false, tourEnabled: true, tourSeen: true))
    }

    func testTeamRowFits() {
        let six = TeamRowFit.fit(count: 6, width: 540)
        XCTAssertEqual(six.cell, 76); XCTAssertEqual(six.spacing, 14)
        let seven = TeamRowFit.fit(count: 7, width: 540)
        XCTAssertTrue(7 * seven.cell + 6 * seven.spacing <= 540)
        XCTAssertEqual(seven.cell, 72)
        let ten = TeamRowFit.fit(count: 8, width: 540)
        XCTAssertTrue(8 * ten.cell + 7 * ten.spacing <= 540)
        XCTAssertTrue(ten.cell >= 52)
        XCTAssertEqual(TeamRowFit.fit(count: 1, width: 10).cell, 76)
    }

    func testRepoRowText() {
        var r = RepoActivity(fullName: "jdoe/site", htmlURL: nil, commits7d: 3, commits30d: 1200, weeks: [], lastCommit: nil, openPRs: 0)
        XCTAssertEqual(RepoRowText.commitLine(r), "No commits yet")
        XCTAssertNil(RepoRowText.prBadge(r.openPRs))
        XCTAssertEqual(RepoRowText.prBadge(4), "4")
        XCTAssertEqual(RepoRowText.prBadge(140), "99+")
        XCTAssertEqual(RepoRowText.counts(r), "3 \u{00b7} 999+")
        r.lastCommit = .init(message: String(repeating: "a", count: 200), at: Date(), author: nil)
        let line = RepoRowText.commitLine(r, limit: 50)
        XCTAssertEqual(line.count, 50)
        XCTAssertTrue(line.hasSuffix("\u{2026}"))
        r.lastCommit = .init(message: "  ", at: Date(), author: nil)
        XCTAssertEqual(RepoRowText.commitLine(r), "No message")
        XCTAssertEqual(RepoRowText.clip("a\nb", 10), "a b")
    }

    func testActivityCopyReadsBackAndStale() {
        let json = #"{"ok":true,"stale":true,"repos":[{"full_name":"jdoe/site","html_url":"https://github.com/jdoe/site","commits_7d":2,"commits_30d":9,"weeks":[1,0,3],"open_prs":1,"last_commit":{"message":"Fix header","at":1760000000000,"author":"jdoe"}},{"full_name":"acme/app","weeks":[]}]}"#
        guard let a = RepoActivity.parseAnswer(Data(json.utf8)) else { return XCTFail("no answer") }
        XCTAssertTrue(a.stale)
        XCTAssertEqual(a.list.count, 2)
        let back = RepoActivity.parseList(RepoActivity.encodeList(a.list))
        XCTAssertEqual(back, a.list)
        XCTAssertEqual(RepoActivity.parseAnswer(Data(#"{"ok":true,"repos":[]}"#.utf8))?.stale, false)
        XCTAssertNil(RepoActivity.parseAnswer(Data("nope".utf8)))
    }

    func testProblemReportBody() {
        var r = ProblemReport(text: "  It froze  ", context: [("app_version", "0.2.7 (1)"), ("page_url", ""), ("dialogue", String(repeating: "x", count: 3000))],
                              logs: (0..<250).map { "line \($0)" } + ["", String(repeating: "y", count: 700)], screenshotB64: "AAAA")
        XCTAssertTrue(r.canSend)
        let b = r.body()
        XCTAssertEqual(b["text"] as? String, "It froze")
        let ctx = b["context"] as? [String: String] ?? [:]
        XCTAssertNil(ctx["page_url"])
        XCTAssertEqual(ctx["app_version"], "0.2.7 (1)")
        XCTAssertEqual(ctx["dialogue"]?.count, 2000)
        let logs = b["logs"] as? [String] ?? []
        XCTAssertEqual(logs.count, 200)
        XCTAssertEqual(logs.last?.count, 600)
        XCTAssertEqual(logs.first, "line 51")
        XCTAssertEqual(b["screenshot_b64"] as? String, "AAAA")
        r.screenshotB64 = String(repeating: "A", count: ProblemReport.maxScreenshot + 1)
        XCTAssertNil(r.body()["screenshot_b64"])
        r.text = " \n "
        XCTAssertFalse(r.canSend)
        XCTAssertEqual(ProblemReport.dialogue([("You", "hi\nthere"), ("Met", "ok")]), "You: hi there\nMet: ok")
        XCTAssertTrue(ProblemReport.line(at: Date(), source: "WebKit", "a\nb").hasSuffix(" [WebKit] a b"))
    }
}
