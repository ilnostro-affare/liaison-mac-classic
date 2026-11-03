import XCTest
import Foundation
@testable import Liaison

/// Paths of Dev's project in an answer are chips (a file or a folder) that open in the Canvas.
final class FileChipsTests: XCTestCase {
    private let none = KnownRepos.Snapshot()

    private func files(_ s: [InlineSegment]) -> [FileRef] {
        s.compactMap { if case .file(let f) = $0 { return f }; return nil }
    }

    func testCodeSpansThatArePathsBecomeFileChips() {
        let s = InlineChips.segments("Edited `frontend/landing/index.html` and `frontend/landing/favicon.svg`.", ents: [:], repos: none)
        XCTAssertEqual(files(s).map(\.path), ["frontend/landing/index.html", "frontend/landing/favicon.svg"])
        XCTAssertEqual(files(s).map(\.isDir), [false, false])
        // the backticks stay around the chip (the code run carries it), the sentence around them
        XCTAssertEqual(s.first, .text("Edited `"))
        XCTAssertEqual(s.last, .text("`."))
        XCTAssertEqual(files(InlineChips.segments("see `index.html`", ents: [:], repos: none)).map(\.path), ["index.html"])
        XCTAssertEqual(files(InlineChips.segments("see `src/app.ts:42`", ents: [:], repos: none)).map(\.path), ["src/app.ts"])
    }

    func testBoxFolderIsAFolderChipNormalisedToTheProject() {
        let s = InlineChips.segments("Cloned into `/workspace/project/acme`.", ents: [:], repos: none)
        XCTAssertEqual(files(s), [FileRef(path: "acme", isDir: true, written: "/workspace/project/acme")])
        let f = files(InlineChips.segments("Wrote /workspace/project/acme/src/a.js today", ents: [:], repos: none))
        XCTAssertEqual(f.map(\.path), ["acme/src/a.js"])
        XCTAssertEqual(files(InlineChips.segments("the folder `frontend/landing/`", ents: [:], repos: none)),
                       [FileRef(path: "frontend/landing", isDir: true, written: "frontend/landing/")])
        XCTAssertEqual(FileChips.normalize("./src/a.js"), "src/a.js")
        XCTAssertEqual(FileChips.normalize("/workspace/project"), "")
    }

    func testBarePathsNeedASlashAndAFileName() {
        let s = InlineChips.segments("Changed src/dev/x.js and README.md, see deploy.sh.", ents: [:], repos: none)
        XCTAssertEqual(files(s).map(\.path), ["src/dev/x.js"])
        XCTAssertTrue(files(InlineChips.segments("cats and/or dogs, 1/2 of it", ents: [:], repos: none)).isEmpty)
        // a sentence's full stop is not part of it
        XCTAssertEqual(files(InlineChips.segments("Look at app/main.py.", ents: [:], repos: none)).map(\.written), ["app/main.py"])
    }

    func testUrlsDomainsBranchesAndReposStayWhatTheyAre() {
        let s = InlineChips.segments("Open https://site.com/a/index.html and bakery.liaisone.app/menu.html", ents: [:], repos: none)
        XCTAssertTrue(files(s).isEmpty)
        XCTAssertTrue(s.contains(.url("https://site.com/a/index.html")))
        let b = InlineChips.segments("Pushed `claude/app-versions` and `feat/landing`", ents: [:], repos: none)
        XCTAssertTrue(files(b).isEmpty)
        XCTAssertTrue(b.contains(.github(.branch("claude/app-versions"))))
        XCTAssertTrue(b.contains(.github(.branch("feat/landing"))))
        let known = KnownRepos.Snapshot(repos: ["jdoe/site"], preferred: ["jdoe/site"])
        let r = InlineChips.segments("Cloned `jdoe/site`", ents: [:], repos: known)
        XCTAssertTrue(files(r).isEmpty)
        XCTAssertTrue(r.contains(.github(.repo("jdoe/site"))))
        XCTAssertTrue(files(InlineChips.segments("[docs](https://x.com/docs/a.md)", ents: [:], repos: none)).isEmpty)
    }

    func testCodeThatIsNotAPathStaysCode() {
        for t in ["`npm run build`", "`console.log`", "`items.map`", "`/agents/dev/files`", "`1.5`", "`-v`", "`@scope/pkg`",
                  "`a/b`", "`and/or`", "`https://x.com/a.js`", "`~/notes.txt`"] {
            XCTAssertTrue(files(InlineChips.segments(t, ents: [:], repos: none)).isEmpty, t)
        }
        XCTAssertEqual(files(InlineChips.segments("`package.json` and `node_modules/`", ents: [:], repos: none)).map(\.isDir),
                       [false, true])
        XCTAssertEqual(files(InlineChips.segments("`src/lib`", ents: [:], repos: none)).map(\.isDir), [true])
        XCTAssertEqual(files(InlineChips.segments("`Dockerfile`", ents: [:], repos: none)).map(\.path), ["Dockerfile"])
    }

    func testImagesAndNames() {
        XCTAssertTrue(FileRef(path: "a/logo.PNG", isDir: false, written: "a/logo.PNG").isImage)
        XCTAssertFalse(FileRef(path: "a/app.js", isDir: false, written: "a/app.js").isImage)
        XCTAssertEqual(FileRef(path: "a/b/c.css", isDir: false, written: "").name, "c.css")
        XCTAssertEqual(FileRef(path: "", isDir: true, written: "").name, "Project")
    }

    func testMatchFindsTheChangedFile() {
        let list = ["frontend/landing/index.html", "frontend/landing/style.css", "docs/index.html"]
        XCTAssertEqual(FileChips.match("frontend/landing/index.html", in: list), "frontend/landing/index.html")
        XCTAssertEqual(FileChips.match("./frontend/landing/style.css", in: list), "frontend/landing/style.css")
        XCTAssertEqual(FileChips.match("landing/index.html", in: list), "frontend/landing/index.html")
        XCTAssertEqual(FileChips.match("style.css", in: list), "frontend/landing/style.css")
        XCTAssertNil(FileChips.match("index.html", in: list))   // two of them: not guessed
        XCTAssertNil(FileChips.match("app.js", in: list))
        XCTAssertEqual(FileChips.match("acme/frontend/landing/style.css", in: ["frontend/landing/style.css"]),
                       "frontend/landing/style.css")
    }
}
