import XCTest
import Foundation
@testable import Liaison

/// The Code tab's source - the repositories cloned into Dev's project, their local branches and the
/// git reads (GET /agents/dev/repos, /agents/dev/git).
final class DevReposTests: XCTestCase {
    private func data(_ s: String) -> Data { Data(s.utf8) }

    private let reposJSON = """
    {"ok":true,"repos":[
      {"dir":"liaison-mac","branch":"dev/hero","remote":"https://github.com/o/liaison-mac.git","base":"main","dirty":3,
       "branches":[{"name":"main","ahead":0,"current":false},{"name":"dev/hero","ahead":2,"current":true},{"name":"dev/hero","ahead":9}]},
      {"dir":".","branch":"main","remote":"git@github.com:acme/site.git","base":"main","dirty":0,"branches":[{"name":"main","ahead":0,"current":true}]},
      {"dir":"","branch":"x"}
    ]}
    """

    func testParseRepos() throws {
        let repos = try DevRepos.parse(data(reposJSON)).get()
        XCTAssertEqual(repos.map(\.dir), ["liaison-mac", "."])
        let r = repos[0]
        XCTAssertEqual(r.branch, "dev/hero")
        XCTAssertEqual(r.base, "main")
        XCTAssertEqual(r.dirty, 3)
        XCTAssertEqual(r.branches.map(\.name), ["main", "dev/hero"], "a duplicate branch is dropped")
        XCTAssertEqual(r.branches[1].ahead, 2)
        XCTAssertTrue(r.branches[1].current)
        XCTAssertEqual(r.name, "liaison-mac")
        XCTAssertEqual(r.label, "liaison-mac \u{00b7} dev/hero")
        XCTAssertEqual(r.slug, "o/liaison-mac")
        XCTAssertEqual(r.dirtyText, "3 uncommitted")
        // a clone at the project's root is named after its remote
        XCTAssertEqual(repos[1].name, "site")
        XCTAssertEqual(repos[1].slug, "acme/site")
        XCTAssertNil(repos[1].dirtyText)
        // none, an error, garbage
        XCTAssertEqual(try DevRepos.parse(data("{\"ok\":true,\"repos\":[]}")).get(), [])
        XCTAssertEqual(DevRepos.parse(data("{\"ok\":false,\"error\":\"Dev is asleep\"}")), .failure(DevFilesError("Dev is asleep")))
        XCTAssertEqual(DevRepos.parse(data("nope")), .failure(DevFilesError("Could not read the repositories.")))
    }

    func testBranchTitlesAndPick() throws {
        let r = try DevRepos.parse(data(reposJSON)).get()[0]
        XCTAssertEqual(r.branches[0].menuTitle, "main")
        XCTAssertEqual(r.branches[1].menuTitle, "dev/hero  +2 \u{00b7} checked out")
        XCTAssertNil(r.branches[0].aheadText)
        XCTAssertEqual(r.pick("main"), "main")
        XCTAssertEqual(r.pick("gone"), "dev/hero")
        XCTAssertEqual(r.pick(nil), "dev/hero")
        XCTAssertEqual(r.scopeNote(branch: "dev/hero", scope: .changes), "dev/hero \u{2192} main")
        XCTAssertEqual(r.scopeNote(branch: "main", scope: .changes), "main")
        XCTAssertEqual(r.scopeNote(branch: "dev/hero", scope: .work), "Not committed on dev/hero")
        XCTAssertEqual(r.scopeNote(branch: "main", scope: .files), "main, read only")
    }

    func testPushPreselectsItsRepositoryAndBranch() throws {
        let repos = try DevRepos.parse(data(reposJSON)).get()
        func push(_ repo: String, _ branch: String) -> DevPush? {
            DevPush(ChatBlock(tool: "dev_push", data: ["kind": "dev_push", "repo": repo, "branch": branch]))
        }
        let a = DevRepos.preselect(repos, push: push("o/liaison-mac", "main"))
        XCTAssertEqual(a?.dir, "liaison-mac"); XCTAssertEqual(a?.branch, "main")
        // case and ".git" do not matter; a branch that is not local opens the checked-out one
        let b = DevRepos.preselect(repos, push: push("O/Liaison-Mac.git", "dev/elsewhere"))
        XCTAssertEqual(b?.dir, "liaison-mac"); XCTAssertEqual(b?.branch, "dev/hero")
        // the root clone, by its remote
        XCTAssertEqual(DevRepos.preselect(repos, push: push("acme/site", "main"))?.dir, ".")
        // another owner's repository of the same name is not this clone
        XCTAssertNil(DevRepos.preselect(repos, push: push("someone/liaison-mac", "main")))
        // no repo named: the only clone holding the branch
        XCTAssertEqual(DevRepos.preselect(repos, push: push("", "dev/hero"))?.dir, "liaison-mac")
        XCTAssertNil(DevRepos.preselect(repos, push: push("", "main")), "two clones hold main: none is guessed")
        XCTAssertNil(DevRepos.preselect(repos, push: nil))
        XCTAssertNil(DevRepos.preselect([], push: push("o/liaison-mac", "main")))
        // a clone without a remote matches by its folder
        let bare = DevRepo(dir: "app", branch: "main", remote: "", base: "main", dirty: 0, branches: [])
        XCTAssertTrue(bare.matches(push: "o/app"))
        XCTAssertTrue(bare.matches(push: "app"))
        XCTAssertFalse(bare.matches(push: "o/other"))
    }

    func testSource() {
        XCTAssertNil(DevCodeSource.project.dir)
        XCTAssertNil(DevCodeSource.project.branch)
        let s = DevCodeSource.repo(dir: "x", branch: "dev/a")
        XCTAssertEqual(s.dir, "x"); XCTAssertEqual(s.branch, "dev/a")
        XCTAssertFalse(s == DevCodeSource.repo(dir: "x", branch: "main"))
    }

    func testParseBranchDiff() throws {
        let json = """
        {"ok":true,"changes":[{"path":"a.txt","add":1,"del":0},{"path":"img.png","add":-1,"del":-1}],
         "diff":"diff --git a/a.txt b/a.txt\\n--- a/a.txt\\n+++ b/a.txt\\n@@ -1 +1,2 @@\\n x\\n+y\\n","cut":false,
         "commits":[{"sha":"abcdef1234","msg":"Add y\\n\\nbody"}],"ref":"dev/hero","base":"main","head":"abc"}
        """
        let d = try DevGitDiff.parse(data(json)).get()
        XCTAssertFalse(d.work)
        XCTAssertEqual(d.changes.map(\.path), ["a.txt", "img.png"])
        XCTAssertTrue(d.changes[1].binary)
        XCTAssertEqual(d.commits.map(\.short), ["abcdef1"])
        XCTAssertEqual(d.commits[0].title, "Add y")
        XCTAssertEqual(d.ref, "dev/hero"); XCTAssertEqual(d.base, "main")
        let files = DevDiff.parse(d.diff)
        XCTAssertEqual(files.map(\.path), ["a.txt"])
        XCTAssertEqual(files[0].add, 1)
        XCTAssertEqual(DevGitDiff.fileList(d.changes, files).count, 2, "the server's list wins")
        XCTAssertEqual(DevGitDiff.fileList([], files), [DevFileChange(path: "a.txt", add: 1, del: 0)])
        XCTAssertEqual(d.emptyText(branch: "dev/hero", base: "main"), "dev/hero holds nothing over main.")
    }

    func testParseWorkDiff() throws {
        let json = """
        {"ok":true,"work":true,"changes":[],"diff":"","cut":false,"untracked":["new.js"," ",""]}
        """
        let d = try DevGitDiff.parse(data(json)).get()
        XCTAssertTrue(d.work)
        XCTAssertEqual(d.untracked, ["new.js"])
        XCTAssertEqual(d.commits, [])
        XCTAssertEqual(d.emptyText(branch: "dev/hero", base: "main"), "No uncommitted changes.")
        XCTAssertEqual(DevGitDiff.parse(data("{\"ok\":false,\"error\":\"bad ref\"}")), .failure(DevFilesError("bad ref")))
        let main = try DevGitDiff.parse(data("{\"ok\":true,\"changes\":[],\"diff\":\"\",\"ref\":\"main\",\"base\":\"main\"}")).get()
        XCTAssertEqual(main.emptyText(branch: "main", base: "main"), "main is the default branch: nothing to compare.")
    }

    func testGitListAndShowReuseTheFileParsers() throws {
        XCTAssertEqual(try DevFiles.parseList(data("{\"ok\":true,\"files\":[\"src/a.js\",\"README.md\"]}")).get(), ["src/a.js", "README.md"])
        XCTAssertEqual(try DevFiles.parseFile(data("{\"ok\":true,\"path\":\"a\",\"ref\":\"main\",\"content\":\"hi\"}")).get(), "hi")
    }

    /// Base is the default branch's name; a commit id (older servers) is not taken for one.
    func testDiffBaseIsABranchName() {
        XCTAssertEqual(DevGitDiff.branchName("main"), "main")
        XCTAssertEqual(DevGitDiff.branchName("3f9c0d1e2a3b4c5d6e7f8091a2b3c4d5e6f70812"), "")
        XCTAssertEqual(DevGitDiff.branchName(nil), "")
        let d = try? DevGitDiff.parse(Data(#"{"ok":true,"changes":[],"diff":"","ref":"dev/x","base":"3f9c0d1e2a3b4c5d6e7f8091a2b3c4d5e6f70812","base_sha":"3f9c0d1e2a3b4c5d6e7f8091a2b3c4d5e6f70812"}"#.utf8)).get()
        XCTAssertEqual(d?.emptyText(branch: "dev/x", base: "main"), "dev/x holds nothing over main.")
        let e = try? DevGitDiff.parse(Data(#"{"ok":true,"changes":[],"diff":"","ref":"dev/x","base":"trunk"}"#.utf8)).get()
        XCTAssertEqual(e?.emptyText(branch: "dev/x", base: "main"), "dev/x holds nothing over trunk.")
    }

    /// The live sites beside the private preview; Live publishes only a static preview.
    func testDevSitesLiveAndNext() {
        let j = #"{"ok":true,"sites":[{"slug":"acme","url":"https://acme.liaisone.com/","dir":"site","at":1},{"slug":"x","url":"http://evil.com/","dir":""}],"next":{"slug":"acme-k7q2","url":"https://acme-k7q2.liaisone.com/"},"preview":{"kind":"static","dir":"site"}}"#
        guard case .success(let s) = DevSites.parse(Data(j.utf8)) else { return XCTFail("parse") }
        XCTAssertEqual(s.sites.map(\.slug), ["acme"])          // a non-liaisone address is never taken
        XCTAssertEqual(s.live?.slug, "acme")                     // published from the folder the preview shows
        XCTAssertEqual(s.next?.url.host, "acme-k7q2.liaisone.com")
        XCTAssertTrue(s.canPublish)
        let server = #"{"ok":true,"sites":[],"next":null,"preview":{"kind":"server","dir":null}}"#
        guard case .success(let t) = DevSites.parse(Data(server.utf8)) else { return XCTFail("parse") }
        XCTAssertNil(t.live)
        XCTAssertFalse(t.canPublish)
        XCTAssertTrue(DevSites.isPrivatePreview(URL(string: "https://pv-b1-a-c.liaisone.com/")))
        XCTAssertFalse(DevSites.isPrivatePreview(URL(string: "https://acme.liaisone.com/")))
        guard case .success(let p) = DevSites.parsePublished(Data(#"{"ok":true,"url":"https://acme.liaisone.com/","site":"acme"}"#.utf8)) else { return XCTFail("published") }
        XCTAssertEqual(p.slug, "acme")
        guard case .failure(let e) = DevSites.parsePublished(Data(#"{"ok":false,"error":"Not published: app.js hold the value of one of the cloud's keys"}"#.utf8)) else { return XCTFail("refused") }
        XCTAssertTrue(e.message.contains("app.js"))
    }

    /// Server: the sites list and a publish answer on liaisone.app (and .com during the move); never our own
    /// hosts, the apex, a preview or another domain.
    func testDevSitesOnLiaisoneApp() {
        let j = #"{"ok":true,"sites":[{"slug":"acme","url":"https://acme.liaisone.app/","dir":"site","at":2},{"slug":"old","url":"https://old.liaisone.com/","dir":"old","at":1},{"slug":"api","url":"https://api.liaisone.com/","dir":""},{"slug":"apex","url":"https://liaisone.app/","dir":""},{"slug":"pv","url":"https://pv-abcd1234.liaisone.app/","dir":""},{"slug":"si","url":"https://x.liaisone.si/","dir":""}],"next":{"slug":"acme-k7q2","url":"https://acme-k7q2.liaisone.app/"},"preview":{"kind":"static","dir":"site"}}"#
        guard case .success(let s) = DevSites.parse(Data(j.utf8)) else { return XCTFail("parse") }
        XCTAssertEqual(s.sites.map(\.slug), ["acme", "old"])
        XCTAssertEqual(s.live?.url.absoluteString, "https://acme.liaisone.app/")
        XCTAssertEqual(s.next?.url.host, "acme-k7q2.liaisone.app")
        guard case .success(let p) = DevSites.parsePublished(Data(#"{"ok":true,"url":"https://acme.liaisone.app/","site":"acme"}"#.utf8)) else { return XCTFail("published") }
        XCTAssertEqual(p.url.host, "acme.liaisone.app")
        XCTAssertTrue(DevSites.isPrivatePreview(URL(string: "https://pv-b1-a-c.liaisone.app/")))
        guard case .failure = DevSites.parsePublished(Data(#"{"ok":true,"url":"https://lia.liaisone.com/","site":"lia"}"#.utf8)) else { return XCTFail("ours is no site") }
    }
}
