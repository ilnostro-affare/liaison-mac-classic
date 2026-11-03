import XCTest
import Foundation
@testable import Liaison

/// Repositories and commits in Dev's text are GitHub chips, like branches; each opens its GitHub page.
final class GitHubEntityChipsTests: XCTestCase {
    private let known = KnownRepos.Snapshot(repos: ["sam/site"], preferred: ["sam/site"])

    private func githubs(_ s: [InlineSegment]) -> [GitHubRef] {
        s.compactMap { if case .github(let r) = $0 { return r }; return nil }
    }

    func testRepoRefPagesAndParse() {
        let r = GitHubRef.repo("sam/site")
        XCTAssertEqual(r.label, "sam/site")
        XCTAssertEqual(r.webURL?.absoluteString, "https://github.com/sam/site")
        XCTAssertEqual(GitHubRef.parseRepo("https://github.com/sam/site"), r)
        XCTAssertEqual(GitHubRef.parseRepo("https://github.com/sam/site.git"), r)
        XCTAssertNil(GitHubRef.parseRepo("https://github.com/sam/site/pull/3"))
        XCTAssertNil(GitHubRef.parseRepo("https://gitlab.com/sam/site"))
        XCTAssertEqual(GitHubRef.commit("ABC1234def", repo: "sam/site").webURL?.absoluteString,
                       "https://github.com/sam/site/commit/abc1234def")
        XCTAssertEqual(GitHubRef.branch("dev/landing-light-theme", repo: "sam/site").webURL?.absoluteString,
                       "https://github.com/sam/site/tree/dev/landing-light-theme")
    }

    func testKnownRepoNameIsAChipUnknownIsText() {
        let s = InlineChips.segments("Cloned Sam/Site and acme/app.", ents: [:], repos: known)
        XCTAssertEqual(githubs(s), [.repo("sam/site")])
        // a repository's own page written as an address
        XCTAssertEqual(githubs(InlineChips.segments("see https://github.com/acme/app", ents: [:], repos: known)), [.repo("acme/app")])
        // "and/or" with nothing known stays words
        XCTAssertTrue(githubs(InlineChips.segments("cats and/or dogs", ents: [:], repos: known)).isEmpty)
    }

    func testCommitShaNeedsContextAndARepo() {
        // the word commit close by
        XCTAssertEqual(githubs(InlineChips.segments("Pushed commit 1a2b3c4 to main.", ents: [:], repos: known)),
                       [.commit("1a2b3c4", repo: "sam/site")])
        // a code span
        XCTAssertEqual(githubs(InlineChips.segments("Done in `9f8e7d6c5b`.", ents: [:], repos: known)),
                       [.commit("9f8e7d6c5b", repo: "sam/site")])
        // no context: text
        XCTAssertTrue(githubs(InlineChips.segments("The color 1a2b3c4 looks fine", ents: [:], repos: known)).isEmpty)
        // no repository known: text
        XCTAssertTrue(githubs(InlineChips.segments("commit 1a2b3c4", ents: [:], repos: KnownRepos.Snapshot())).isEmpty)
        // two repositories, none named: text; named in the text: that one
        let two = KnownRepos.Snapshot(repos: ["sam/site", "acme/app"])
        XCTAssertTrue(githubs(InlineChips.segments("commit 1a2b3c4", ents: [:], repos: two)).isEmpty)
        XCTAssertTrue(githubs(InlineChips.segments("acme/app: commit 1a2b3c4", ents: [:], repos: two))
                        .contains(.commit("1a2b3c4", repo: "acme/app")))
    }

    func testCommitShaFalsePositives() {
        // all digits, all letters, upper case, too short, inside a word or a path: never a commit
        for t in ["commit 1234567", "commit deadbee", "commit ABC1234", "commit a1b2c3", "commit x1a2b3c4d",
                  "commit src/1a2b3c4", "commit #1a2b3c4", "commit 1a2b3c4.js"] {
            XCTAssertTrue(githubs(InlineChips.segments(t, ents: [:], repos: known)).isEmpty, t)
        }
    }

    func testKnownCommitNeedsNoContext() {
        let s = KnownRepos.Snapshot(repos: ["acme/app", "sam/site"],
                                    commits: ["1a2b3c4d5e6f7a8b9c0d1e2f3a4b5c6d7e8f9a0b": "acme/app"])
        XCTAssertEqual(githubs(InlineChips.segments("Fixed in 1a2b3c4 yesterday", ents: [:], repos: s)),
                       [.commit("1a2b3c4", repo: "acme/app")])
    }

    func testBranchChipStaysABranch() {
        XCTAssertEqual(githubs(InlineChips.segments("on dev/landing-light-theme now", ents: [:], repos: known)),
                       [.branch("dev/landing-light-theme")])
    }

    // GET /agents/github/ref -> the card's facts
    func testRefInfoFromServer() {
        let pr = Data(#"{"ok":true,"ref":{"kind":"pr","repo":"o/r","number":14,"title":"0.2.11 final","url":"https://github.com/o/r/pull/14","state":"open","author":{"login":"sam","avatar":"https://a.b/c.png"},"at":1792668433000,"additions":4860,"deletions":1023,"files":105,"commits":14,"base":"main","head":"claude/x"}}"#.utf8)
        let i = GitHubRefInfo.fromServer(pr)
        XCTAssertEqual(i?.title, "0.2.11 final")
        XCTAssertEqual(i?.state, "open")
        XCTAssertEqual(i?.author, "sam")
        XCTAssertEqual(i?.avatar?.absoluteString, "https://a.b/c.png")
        XCTAssertEqual(i?.additions, 4860)
        XCTAssertEqual(i?.deletions, 1023)
        XCTAssertEqual(i?.files, 105)
        XCTAssertEqual(i?.repo, "o/r")
        XCTAssertEqual(i?.fetched, true)
        let br = Data(#"{"ok":true,"ref":{"kind":"branch","repo":"o/r","branch":"feat/x","url":"https://github.com/o/r/tree/feat/x","title":"Last commit","at":1,"base":"main","ahead":5,"behind":2,"files":10,"additions":519,"deletions":10,"pr":{"number":7,"title":"Feat X","state":"merged"}}}"#.utf8)
        let b = GitHubRefInfo.fromServer(br)
        XCTAssertEqual(b?.lastMessage, "Last commit")
        XCTAssertEqual(b?.title, "Feat X")
        XCTAssertEqual(b?.prNumber, 7)
        XCTAssertEqual(b?.state, "merged")
        XCTAssertEqual(b?.ahead, 5)
        XCTAssertNil(GitHubRefInfo.fromServer(Data(#"{"ok":false,"error":"x"}"#.utf8)))
        // merged keeps the server's facts over an empty block
        let m = GitHubRefInfo(title: "From a block").merged(i!)
        XCTAssertEqual(m.title, "0.2.11 final")
        XCTAssertTrue(m.fetched)
    }
}
