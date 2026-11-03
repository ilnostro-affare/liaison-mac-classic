import XCTest
import Foundation
@testable import Liaison

/// The Code tab's source per item, the code viewer (syntax, selection context, search), the diff view
/// (word changes, folds, side by side), branch and domain chips, the dock's second click.
final class CodeViewerTests: XCTestCase {
    private let pv = URL(string: "https://pv-abcd1234.liaisone.app/")!
    private let site = URL(string: "https://bakery.liaisone.app/")!

    // MARK: syntax

    func testSwiftLineColoursKeywordsStringsNumbersComments() {
        let r = CodeSyntax.line("let x = \"hi\" + 42 // note", lang: .cLike)
        XCTAssertEqual(r.pieces.map(\.text).joined(), "let x = \"hi\" + 42 // note")
        XCTAssertTrue(r.pieces.contains(CodePiece(kind: .keyword, text: "let")))
        XCTAssertTrue(r.pieces.contains(CodePiece(kind: .string, text: "\"hi\"")))
        XCTAssertTrue(r.pieces.contains(CodePiece(kind: .number, text: "42")))
        XCTAssertTrue(r.pieces.contains(CodePiece(kind: .comment, text: "// note")))
        XCTAssertEqual(r.state, .none)
    }

    func testBlockCommentAndTripleStringCarryAcrossLines() {
        let lines = CodeSyntax.highlight(["a /* one", "two */ b", "x = \"\"\"", "inside", "\"\"\" + 1"], lang: .cLike)
        XCTAssertEqual(lines[1].first, CodePiece(kind: .comment, text: "two */"))
        XCTAssertEqual(lines[3], [CodePiece(kind: .string, text: "inside")])
        XCTAssertEqual(lines[4].first, CodePiece(kind: .string, text: "\"\"\""))
    }

    func testHTMLTagsAttributesAndPython() {
        let h = CodeSyntax.line("<a href=\"/x\">Go</a>", lang: .html).pieces
        XCTAssertTrue(h.contains(CodePiece(kind: .tag, text: "a")))
        XCTAssertTrue(h.contains(CodePiece(kind: .attribute, text: "href")))
        XCTAssertTrue(h.contains(CodePiece(kind: .string, text: "\"/x\"")))
        let p = CodeSyntax.line("def f(): # hi", lang: .python).pieces
        XCTAssertEqual(p.first, CodePiece(kind: .keyword, text: "def"))
        XCTAssertEqual(p.last, CodePiece(kind: .comment, text: "# hi"))
        XCTAssertEqual(CodeLang.of(path: "src/App.tsx"), .cLike)
        XCTAssertEqual(CodeLang.of(path: "index.html"), .html)
        XCTAssertEqual(CodeLang.of(path: "Dockerfile"), .shell)
        XCTAssertEqual(CodeLang.of(path: "notes"), .plain)
    }

    // MARK: selection, search

    func testContextForComposerNamesPathAndRange() {
        let lines = ["a", "b", "c", "d"]
        XCTAssertEqual(CodeLines.context(path: "src/app.js", lines: lines, from: 3, to: 2), "src/app.js:2-3\n```js\nb\nc\n```")
        XCTAssertEqual(CodeLines.context(path: "x.py", lines: lines, from: 1, to: 1), "x.py:1\n```py\na\n```")
        XCTAssertEqual(CodeLines.text(lines, from: 2, to: 9), "b\nc\nd")
        XCTAssertEqual(CodeLines.matches(["Foo", "bar", "FOO bar"], query: "foo"), [1, 3])
        XCTAssertEqual(CodeLines.crumbs("./sites/a/index.html"), ["sites", "a", "index.html"])
    }

    // MARK: the diff

    func testWordChangeMarksOnlyTheChangedPart() {
        let c = DiffWords.changed("let color = red", "let color = blue")
        XCTAssertEqual(c.old, DiffSpan(start: 12, length: 3))
        XCTAssertEqual(c.new, DiffSpan(start: 12, length: 4))
        // lines with almost nothing in common: the whole line is the change
        let w = DiffWords.changed("abc", "xyz uvw")
        XCTAssertNil(w.old); XCTAssertNil(w.new)
    }

    private func diff(_ ctx: Int) -> DevDiff.File {
        var lines: [String] = ["diff --git a/a.js b/a.js", "--- a/a.js", "+++ b/a.js"]
        lines.append("@@ -10,\(ctx * 2 + 1) +10,\(ctx * 2 + 1) @@")
        for k in 0..<ctx { lines.append(" c\(k)") }
        lines.append("-let v = 1")
        lines.append("+let v = 2")
        for k in 0..<ctx { lines.append(" d\(k)") }
        return DevDiff.parse(lines.joined(separator: "\n"))[0]
    }

    func testUnifiedFoldsLongContextAndPairsSides() {
        let v = DevDiffView.make(diff(10), path: "a.js")
        // the gap above line 10 is not carried by the diff
        guard case .gap(_, let n)? = v.unified.first?.kind else { return XCTFail("no gap") }
        XCTAssertEqual(n, 9)
        XCTAssertEqual(v.gaps[0]?.newStart, 1)
        let folds = v.unified.filter { if case .fold = $0.kind { return true }; return false }
        XCTAssertEqual(folds.count, 0, "10 + 10 context lines in two runs: each run is 10, not over 8 + 2*3")
        let long = DevDiffView.make(diff(20), path: "a.js")
        let lf = long.unified.filter { if case .fold = $0.kind { return true }; return false }
        XCTAssertEqual(lf.count, 2)
        let shown = DevDiffView.visible(long.unified, open: [])
        XCTAssertTrue(shown.count < long.unified.count)
        XCTAssertEqual(DevDiffView.visible(long.unified, open: [0, 1]).count, long.unified.count - 2)
        // the changed pair: word span on both sides, side by side on one row
        let del = long.unified.first { $0.lineKind == .del }
        XCTAssertEqual(del?.changed, DiffSpan(start: 8, length: 1))
        let pair = long.split.first { $0.left?.kind == .del }
        XCTAssertEqual(pair?.right?.kind, .add)
        XCTAssertEqual(pair?.right?.number, 30)
    }

    func testKnownNewTextFoldsTheGapInstead() {
        let file = diff(2)
        var text = (1...30).map { "line \($0)" }
        for (i, l) in ["c0", "c1", "let v = 2", "d0", "d1"].enumerated() { text[9 + i] = l }
        let v = DevDiffView.make(file, path: "a.js", newText: text)
        XCTAssertTrue(v.gaps.isEmpty)
        guard case .fold(_, let n)? = v.unified.first?.kind else { return XCTFail("no fold") }
        XCTAssertEqual(n, 9)
        XCTAssertEqual(DevDiffView.visible(v.unified, open: [0]).first?.text, "line 1")
    }

    // MARK: the Code tab's source

    func testCodeSourceFollowsTheItemsSiteNotTheFirstRepository() {
        let meta = DevRepo(dir: "Meta-Api", branch: "main", remote: "https://github.com/o/Meta-Api", base: "main", dirty: 0, branches: [])
        let sites = DevSites(sites: [DevSite(slug: "bakery", url: site, dir: "/workspace/project/sites/bakery/")],
                             next: nil, previewKind: "static", previewDir: "sites/new")
        XCTAssertEqual(DevCodeScope.pick(push: nil, page: site, repos: [meta], sites: sites), .folder("sites/bakery"))
        XCTAssertEqual(DevCodeScope.pick(push: nil, page: pv, repos: [meta], sites: sites), .folder("sites/new"))
        XCTAssertEqual(DevCodeScope.pick(push: nil, page: nil, repos: [meta], sites: sites), .project)
        // the project without its clones; a folder relative to itself
        let entries = ["Meta-Api/", "Meta-Api/full/x.md", "sites/bakery/index.html", "README.md"]
        XCTAssertEqual(DevCodeScope.projectEntries(entries, repos: [meta]), ["sites/bakery/index.html", "README.md"])
        XCTAssertEqual(DevCodeScope.folderEntries(entries, dir: "sites/bakery"), ["index.html"])
        XCTAssertEqual(DevCodeScope.projectPath("index.html", in: "sites/bakery"), "sites/bakery/index.html")
        let menu = DevCodeScope.siteFolders(sites, repos: [meta])
        XCTAssertEqual(menu.map(\.dir), ["sites/new", "sites/bakery"])
        XCTAssertEqual(menu.last?.label, "bakery.liaisone.app")
    }

    func testCutProjectListingReadsItsOwnFoldersAndChangesStayInTheItemsFolder() {
        let meta = DevRepo(dir: "Meta-Api", branch: "main", remote: "https://github.com/o/Meta-Api", base: "main", dirty: 0, branches: [])
        // the box's listing stops at 400 entries; a clone sorting first fills it
        let cut = ["Meta-Api"] + (1..<DevCodeScope.listCap).map { "Meta-Api/full/f\($0).md" }
        XCTAssertTrue(DevCodeScope.isCut(cut))
        XCTAssertTrue(DevCodeScope.projectEntries(cut, repos: [meta]).isEmpty)
        XCTAssertEqual(DevCodeScope.extraDirs(cut, repos: [meta], sites: ["/workspace/project/landing-v2/", "landing-v2/css"]), ["landing-v2"])
        XCTAssertEqual(DevCodeScope.extraDirs(["a/x", "b/", "Meta-Api/full/y"], repos: [meta], sites: ["Meta-Api/site"]), ["a", "b"])
        XCTAssertEqual(DevCodeScope.prefixed(["index.html", "css/"], dir: "landing-v2"), ["landing-v2/index.html", "landing-v2/css/"])
        // a live site card's changes: its own folder only; another card: the project without the clones
        XCTAssertTrue(DevCodeScope.owns("landing-v2/index.html", folder: "/workspace/project/landing-v2", repos: [meta]))
        XCTAssertFalse(DevCodeScope.owns("Meta-Api/full/a.md", folder: "landing-v2", repos: [meta]))
        XCTAssertFalse(DevCodeScope.owns("landing-v2x/a", folder: "landing-v2", repos: [meta]))
        XCTAssertTrue(DevCodeScope.owns("README.md", folder: nil, repos: [meta]))
        XCTAssertFalse(DevCodeScope.owns("Meta-Api/full/a.md", folder: nil, repos: [meta]))
    }

    // MARK: chips

    func testBranchNamesByPrefixNotFilePaths() {
        XCTAssertTrue(GitHubRef.isBranchName("feat/hero"))
        XCTAssertTrue(GitHubRef.isBranchName("claude/app-versions"))
        XCTAssertTrue(GitHubRef.isBranchName("release/0.2.11"))
        XCTAssertFalse(GitHubRef.isBranchName("and/or"))
        XCTAssertFalse(GitHubRef.isBranchName("docs/RELEASE.md"))
        XCTAssertFalse(GitHubRef.isBranchName("fix/readme.md"))
        let segs = InlineChips.segments("Pushed **fix/nav** and `claude/x`, then release/1.2.", ents: [:])
        XCTAssertTrue(segs.contains(.github(.branch("fix/nav"))))
        XCTAssertTrue(segs.contains(.github(.branch("claude/x"))))
        XCTAssertTrue(segs.contains(.github(.branch("release/1.2"))))
        KnownBranches.shared.add("jdoe/landing")
        XCTAssertTrue(InlineChips.segments("on jdoe/landing now", ents: [:]).contains(.github(.branch("jdoe/landing"))))
    }

    func testBareDomainsBecomeSiteChipsButFileNamesDoNot() {
        let s = InlineChips.segments("Live at bakery.liaisone.app. See deploy.sh and Liaison.app, or github.com/o/r/pull/3", ents: [:])
        XCTAssertTrue(s.contains(.url("https://bakery.liaisone.app")))
        XCTAssertTrue(s.contains(.github(.pr("o/r", 3))))
        XCTAssertFalse(s.contains(.url("https://deploy.sh")))
        XCTAssertFalse(s.contains { if case .url(let u) = $0 { return u.contains("Liaison") }; return false })
        XCTAssertEqual(DomainChip.label("https://www.bakery.liaisone.app/menu/"), "bakery.liaisone.app/menu")
        XCTAssertFalse(DomainChip.isDomain("index.md"))
    }

    func testDialogueGivesABranchItsRepositoryAndTurnsPreview() {
        let push = ChatBlock(tool: "dev_push", data: ["kind": "dev_push", "repo": "o/site", "branch": "dev/hero"])
        let prev = ChatBlock(tool: "dev_preview", data: ["kind": "dev_preview", "url": pv.absoluteString, "title": "Preview"])
        let links = GitHubDialogue.links([
            .init(run: "r1", blocks: [prev], text: ""),
            .init(run: "r1", blocks: [push], text: "Pushed dev/hero and fix/nav"),
        ])
        let hero = links.first { $0.ref.branch == "dev/hero" }
        XCTAssertEqual(hero?.ref.repo, "o/site")
        XCTAssertEqual(hero?.info.preview, pv)
        XCTAssertEqual(links.first { $0.ref.branch == "fix/nav" }?.info.preview, pv)
    }

    // MARK: the dock

    func testSecondClickWaitsForSlideAndFirstFrame() {
        let o: TimeInterval = 100
        XCTAssertTrue(DockToggle.closes(click: 50, openedAt: nil, settledAt: nil, now: 50))
        XCTAssertFalse(DockToggle.closes(click: o + 0.3, openedAt: o, settledAt: o + 0.2, now: o + 0.3))
        // made while the thread was being laid out, handled later: ignored
        XCTAssertFalse(DockToggle.closes(click: o + 0.7, openedAt: o, settledAt: o + 1.2, now: o + 1.3))
        XCTAssertTrue(DockToggle.closes(click: o + 1.3, openedAt: o, settledAt: o + 1.2, now: o + 1.3))
        // never settled: closes after giveUp
        XCTAssertFalse(DockToggle.closes(click: o + 1, openedAt: o, settledAt: nil, now: o + 1))
        XCTAssertTrue(DockToggle.closes(click: o + 5, openedAt: o, settledAt: nil, now: o + 5))
    }
}

final class CodeViewerDiffFitTests: XCTestCase {
    func testANewerFileIsNotUsedForGaps() {
        let f = DevDiff.parse("--- a/x\n+++ b/x\n@@ -3,1 +3,1 @@\n-a\n+b")[0]
        XCTAssertTrue(DevDiffView.fits(f, newText: ["1", "2", "b", "4"]))
        XCTAssertFalse(DevDiffView.fits(f, newText: ["1", "2", "c", "4"]))
        let v = DevDiffView.make(f, path: "x", newText: ["1", "2", "c", "4"])
        XCTAssertFalse(v.gaps.isEmpty)
        let ok = DevDiffView.make(f, path: "x", newText: ["1", "2", "b", "4"])
        XCTAssertEqual(DevDiffView.group(startingAt: 1, in: ok.unified), 0)
        XCTAssertEqual(DevDiffView.lines("a\nb\n"), ["a", "b"])
    }
}
