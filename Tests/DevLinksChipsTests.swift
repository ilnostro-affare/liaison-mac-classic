import XCTest
import Foundation
@testable import Liaison

/// One Preview | Live per Dev item, Dev cards linked to their pages, GitHub chips, the diff's rows.
final class DevLinksChipsTests: XCTestCase {
    private let pv = URL(string: "https://pv-abcd1234.liaisone.app/")!
    private let site = URL(string: "https://bakery.liaisone.app/")!

    /// A work item with steps only ("Work \u{00B7} 1 step") draws no card; one that edited files does.
    func testBareWorkHasNoCard() {
        let bare = DevWork(ChatBlock(tool: "dev_work", data: ["kind": "dev_work", "title": "Work", "steps": 1]))!
        XCTAssertTrue(bare.isBare)
        let none = DevWork(ChatBlock(tool: "dev_work", data: ["kind": "dev_work", "changes": ["files": 0], "steps": 3,
                                                              "preview": "https://pv-abcd1234.liaisone.app/"]))!
        XCTAssertTrue(none.isBare)
        let edited = DevWork(ChatBlock(tool: "dev_work", data: ["kind": "dev_work", "changes": ["files": 2, "add": 5, "del": 1]]))!
        XCTAssertFalse(edited.isBare)
    }

    func testPrivatePreviewOpensOnPreviewWithLiveBeside() {
        let c = CanvasLiveChoice.resolve(own: pv, isDev: true, fallback: nil, chosen: nil)
        XCTAssertEqual(c.preview, pv)
        XCTAssertNil(c.site)
        XCTAssertTrue(c.showsSwitch)
        XCTAssertFalse(c.live)
        XCTAssertTrue(CanvasLiveChoice.resolve(own: pv, isDev: true, fallback: nil, chosen: true).live)
    }

    func testLiveSiteItemShowsBothWhenAPreviewIsKnownPreviewFirst() {
        let c = CanvasLiveChoice.resolve(own: site, isDev: true, fallback: pv, chosen: nil)
        XCTAssertEqual(c.preview, pv)
        XCTAssertEqual(c.site, site)
        XCTAssertTrue(c.showsSwitch)
        XCTAssertFalse(c.live)
        // the person can always go back to Preview
        XCTAssertFalse(CanvasLiveChoice.resolve(own: site, isDev: true, fallback: pv, chosen: false).live)
        XCTAssertTrue(CanvasLiveChoice.resolve(own: site, isDev: true, fallback: pv, chosen: true).live)
    }

    func testLiveSiteAloneIsLiveWithNoSwitch() {
        let c = CanvasLiveChoice.resolve(own: site, isDev: true, fallback: nil, chosen: false)
        XCTAssertNil(c.preview)
        XCTAssertFalse(c.showsSwitch)
        XCTAssertTrue(c.live)
    }

    func testOtherPagesAndNonDevItemsHaveNoLive() {
        let other = URL(string: "https://example.com/")!
        XCTAssertFalse(CanvasLiveChoice.resolve(own: other, isDev: true, fallback: pv, chosen: true).offersLive)
        XCTAssertFalse(CanvasLiveChoice.resolve(own: pv, isDev: false, fallback: nil, chosen: true).live)
        // a fallback that is not private is never the Preview side
        let c = CanvasLiveChoice.resolve(own: nil, isDev: true, fallback: site, chosen: nil)
        XCTAssertNil(c.preview)
    }

    func testItemCarriesPrivatePageAndChoosesFromIt() {
        let b = ChatBlock(tool: "dev_preview", data: ["kind": "dev_preview", "url": site.absoluteString, "title": "Live site"])
        let item = CanvasItem(block: b, profile: "p")!.withPrivatePage(pv)
        XCTAssertEqual(item.privatePage, pv)
        XCTAssertEqual(item.liveChoice(chosen: nil).preview, pv)
        // the id does not change with the private page
        XCTAssertEqual(item.id, CanvasItem(block: b, profile: "p")!.id)
        // a work item with no page of its own gets the private preview as its Preview tab
        let w = ChatBlock(tool: "dev_work", data: ["kind": "dev_work", "title": "Work"])
        let wi = CanvasItem(block: w, profile: "p")!.withPrivatePage(pv)
        XCTAssertEqual(wi.previewURL, pv)
        XCTAssertTrue(CanvasState(item: wi).tabs.contains(.preview))
        XCTAssertNil(CanvasItem(block: w, profile: nil)!.withPrivatePage(pv).privatePage)
    }

    func testCardLinksResolveFromBlockThenDialogueThenRegistry() {
        var l = DevItemLinks.resolve(own: nil, dialoguePreview: nil, dialoguePage: nil, siteLive: nil)
        XCTAssertTrue(l.isEmpty)
        l = DevItemLinks.resolve(own: nil, dialoguePreview: pv, dialoguePage: nil, siteLive: site)
        XCTAssertEqual(l.preview, pv)
        XCTAssertEqual(l.live, site)
        l = DevItemLinks.resolve(own: site, dialoguePreview: nil, dialoguePage: nil, siteLive: nil)
        XCTAssertNil(l.preview)
        XCTAssertEqual(l.live, site)
    }

    func testGitHubRefsFromLinks() {
        let pr = GitHubRef.parse("https://github.com/jdoe/site/pull/12")
        XCTAssertEqual(pr, .pr("jdoe/site", 12))
        XCTAssertEqual(pr?.label, "site#12")
        XCTAssertEqual(pr?.webURL?.absoluteString, "https://github.com/jdoe/site/pull/12")
        let br = GitHubRef.parse("https://github.com/jdoe/site/tree/dev/landing-light-theme")
        XCTAssertEqual(br?.kind, .branch)
        XCTAssertEqual(br?.branch, "dev/landing-light-theme")
        XCTAssertEqual(br?.webURL?.absoluteString, "https://github.com/jdoe/site/tree/dev/landing-light-theme")
        let c = GitHubRef.parse("https://github.com/jdoe/site/commit/ABCDEF1234567")
        XCTAssertEqual(c?.kind, .commit)
        XCTAssertEqual(c?.label, "abcdef1")
        XCTAssertEqual(GitHubRef.parse("https://github.com/jdoe/site/compare/main...dev/x")?.branch, "dev/x")
        XCTAssertNil(GitHubRef.parse("https://github.com/jdoe/site"))
        XCTAssertNil(GitHubRef.parse("https://gitlab.com/jdoe/site/pull/1"))
        XCTAssertNil(GitHubRef.parse("https://github.com/jdoe/site/issues/3"))
    }

    func testDevBranchNames() {
        XCTAssertTrue(GitHubRef.isDevBranch("dev/landing-light-theme"))
        XCTAssertFalse(GitHubRef.isDevBranch("dev/"))
        XCTAssertFalse(GitHubRef.isDevBranch("feature/x"))
        XCTAssertFalse(GitHubRef.isDevBranch("dev/a..b"))
    }

    func testInlineChipsTurnGitHubIntoChips() {
        let s = InlineChips.segments("Pushed dev/landing-light-theme, PR https://github.com/jdoe/site/pull/7.", ents: [:])
        XCTAssertTrue(s.contains(.github(.branch("dev/landing-light-theme"))))
        XCTAssertTrue(s.contains(.github(.pr("jdoe/site", 7))))
        // the full stop stays text
        if case .text(let t)? = s.last { XCTAssertEqual(t, ".") } else { XCTFail("no trailing text") }
        let md = InlineChips.segments("[the PR](https://github.com/jdoe/site/pull/9)", ents: [:])
        XCTAssertEqual(md, [.github(.pr("jdoe/site", 9))])
        // a path is not a branch, and a plain link stays a link
        XCTAssertFalse(InlineChips.segments("src/dev/x.js", ents: [:]).contains { if case .github = $0 { return true }; return false })
        XCTAssertTrue(InlineChips.segments("[Site](https://example.com/a)", ents: [:]).contains { if case .link = $0 { return true }; return false })
    }

    func testStructuredBlocks() {
        let pr = ChatBlock(tool: "dev_pr", data: ["kind": "dev_pr", "repo": "jdoe/site", "number": 4, "title": "Light theme",
                                                  "url": "https://github.com/jdoe/site/pull/4", "state": "open",
                                                  "branch": "dev/light", "base": "main"])
        let p = GitHubRefBlock.parse(pr)
        XCTAssertEqual(p?.ref, .pr("jdoe/site", 4))
        XCTAssertEqual(p?.info.title, "Light theme")
        XCTAssertEqual(p?.info.route, "main \u{2190} dev/light")
        XCTAssertEqual(p?.info.stateText, "Open")
        let br = ChatBlock(tool: "dev_branch", data: ["kind": "dev_branch", "repo": "jdoe/site", "branch": "dev/light",
                                                      "url": "https://github.com/jdoe/site/tree/dev/light",
                                                      "commit": ["msg": "Make it light\nmore", "at": 1_760_000_000_000.0]])
        let b = GitHubRefBlock.parse(br)
        XCTAssertEqual(b?.ref, .branch("dev/light", repo: "jdoe/site"))
        XCTAssertEqual(b?.info.lastMessage, "Make it light")
        XCTAssertNotNil(b?.info.lastAt)
        // a branch named alone and with its repository share one cache entry
        XCTAssertEqual(GitHubRef.branch("dev/light").key, GitHubRef.branch("dev/light", repo: "jdoe/site").key)
        let merged = GitHubRefInfo(title: "a", ahead: 2).merged(GitHubRefInfo(state: "merged"))
        XCTAssertEqual(merged.title, "a")
        XCTAssertEqual(merged.state, "merged")
        XCTAssertEqual(merged.aheadBehind, "2 ahead")
    }

    func testDiffLayoutAndCodeLines() {
        let diff = "diff --git a/x b/x\n--- a/x\n+++ b/x\n@@ -1,2 +1,3 @@\n a\n-b\n+c\n+d\n"
        let files = DevDiff.parse(diff)
        let l = DevDiffLayout.make(files.first)
        XCTAssertEqual(l.rows.count, 1 + 4)
        XCTAssertFalse(l.tooLong)
        XCTAssertEqual(l.digits, 2)
        XCTAssertEqual(DevDiffLayout.make(nil), .empty)
        XCTAssertEqual(DevCodeLines.make("a\nb\n"), ["a", "b"])
        XCTAssertEqual(DevCodeLines.make(""), [""])
        XCTAssertEqual(DevCodeLines.make("a\r\nb"), ["a", "b"])
    }
}
