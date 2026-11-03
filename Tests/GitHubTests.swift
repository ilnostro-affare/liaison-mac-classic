import XCTest
import Foundation
@testable import Liaison

/// GitHub for Dev: the connection's status, the repositories the app reaches, a workspace's repositories.
final class GitHubTests: XCTestCase {
    func testProfileWithAndWithoutRepos() {
        let json = #"{"ok":true,"profiles":[{"id":"p1","name":"Shop","github_repos":[{"full_name":"sam/site","installation_id":11},{"full_name":"Sam/Site","installation_id":11},{"full_name":"acme/app","installation_id":"22"},{"full_name":"bad","installation_id":1},{"full_name":"x/y"}]},{"id":"p2","name":"Old"},{"id":"p3","name":"Odd","github_repos":"nope"}]}"#
        let list = CompanyProfile.parseList(Data(json.utf8)) ?? []
        XCTAssertEqual(list.count, 3)
        XCTAssertEqual(list[0].githubRepos.map(\.fullName), ["sam/site", "acme/app"])
        XCTAssertEqual(list[0].githubRepos.map(\.installationId), [11, 22])
        XCTAssertTrue(list[1].githubRepos.isEmpty)
        XCTAssertTrue(list[2].githubRepos.isEmpty)
        XCTAssertFalse(list[0] == CompanyProfile(id: "p1", name: "Shop"))
    }

    func testRepoBodyAndAddingKeepsTheLimit() {
        let a = WorkspaceRepo(fullName: "sam/site", installationId: 11)
        let body = WorkspaceRepo.body([a])
        XCTAssertEqual(body.first?["full_name"] as? String, "sam/site")
        XCTAssertEqual(body.first?["installation_id"] as? Int, 11)
        let many = (0..<25).map { WorkspaceRepo(fullName: "o/r\($0)", installationId: 1) }
        let added = WorkspaceRepo.adding(many + [a], to: [WorkspaceRepo(fullName: "JDOE/site", installationId: 11)])
        XCTAssertEqual(added.count, WorkspaceRepo.limit)
        XCTAssertEqual(added.first?.fullName, "JDOE/site")
        XCTAssertFalse(added.dropFirst().contains { $0.id == a.id })
        XCTAssertEqual(WorkspaceRepo.body(many).count, WorkspaceRepo.limit)
    }

    func testStatusConnectedAndNot() {
        let on = #"{"ok":true,"connected":true,"login":"sam","avatar":"https://avatars.githubusercontent.com/u/1","installations":[{"id":5,"account":"sam","type":"User"},{"id":6,"account":"acme-org","type":"Organization"},{"account":"no-id"}],"manage_url":"https://github.com/apps/liaisone/installations/new"}"#
        let s = GitHubStatus.parse(Data(on.utf8))
        XCTAssertEqual(s?.connected, true)
        XCTAssertEqual(s?.login, "sam")
        XCTAssertEqual(s?.avatar?.host, "avatars.githubusercontent.com")
        XCTAssertEqual(s?.installations.map(\.id), [5, 6])
        XCTAssertEqual(s?.installations.last?.type, "Organization")
        XCTAssertEqual(s?.installedOnLine, "Installed on: sam, acme-org")
        XCTAssertEqual(s?.manageURL?.absoluteString, "https://github.com/apps/liaisone/installations/new")

        let off = #"{"ok":true,"connected":false,"login":null,"installations":[],"manage_url":"javascript:alert(1)"}"#
        let t = GitHubStatus.parse(Data(off.utf8))
        XCTAssertEqual(t?.connected, false)
        XCTAssertNil(t?.login)
        XCTAssertNil(t?.installedOnLine)
        XCTAssertNil(t?.manageURL)
        XCTAssertNil(GitHubStatus.parse(Data(#"{"ok":false,"error":"x"}"#.utf8)))
    }

    func testReposListAndFilter() {
        let json = #"{"ok":true,"repos":[{"full_name":"sam/site","private":true,"default_branch":"main","installation_id":5,"html_url":"https://github.com/sam/site"},{"full_name":"acme/app","private":false,"default_branch":"dev","installation_id":6,"html_url":"https://github.com/acme/app"},{"full_name":"nope","installation_id":1},{"full_name":"a/b"}]}"#
        let list = GitHubRepo.parseList(Data(json.utf8)) ?? []
        XCTAssertEqual(list.map(\.fullName), ["sam/site", "acme/app"])
        XCTAssertEqual(list.map(\.isPrivate), [true, false])
        XCTAssertEqual(list[1].defaultBranch, "dev")
        XCTAssertEqual(list[0].htmlURL?.absoluteString, "https://github.com/sam/site")
        XCTAssertEqual(WorkspaceRepo(list[0]).installationId, 5)
        XCTAssertEqual(GitHubRepo.filter(list, " ACME ").map(\.fullName), ["acme/app"])
        XCTAssertEqual(GitHubRepo.filter(list, "").count, 2)
        XCTAssertNil(GitHubRepo.parseList(Data(#"{"ok":false}"#.utf8)))
    }

    func testPollStopsWhenConnectedOrAfterThreeMinutes() {
        let t0 = Date(timeIntervalSince1970: 0)
        XCTAssertTrue(GitHubPoll.shouldContinue(started: t0, now: t0.addingTimeInterval(60), connected: false))
        XCTAssertFalse(GitHubPoll.shouldContinue(started: t0, now: t0.addingTimeInterval(60), connected: true))
        XCTAssertFalse(GitHubPoll.shouldContinue(started: t0, now: t0.addingTimeInterval(181), connected: false))
    }

    /// The callback address gives state and code; the finish answer is connected, confirm or failed.
    func testFinishParamsAndAnswers() {
        let st = String(repeating: "a1", count: 20)
        let cb = URL(string: "https://lia.liaisone.com/agents/github/callback?code=Abc_9-x&installation_id=5&setup_action=install&state=\(st)")!
        let p = GitHubFinish.params(cb)
        XCTAssertEqual(p?.state, st)
        XCTAssertEqual(p?.code, "Abc_9-x")
        XCTAssertNil(GitHubFinish.params(URL(string: "https://lia.liaisone.com/agents/github/callback?setup_action=update")!))
        XCTAssertNil(GitHubFinish.params(URL(string: "https://lia.liaisone.com/agents/github/callback?code=a&state=short")!))
        XCTAssertNil(GitHubFinish.params(URL(string: "https://lia.liaisone.com/agents/github/callback?code=a%20b&state=\(st)")!))
        let link = URL(string: "liaison://github/connect?state=\(st)&code=q")!
        XCTAssertTrue(GitHubFinish.isLink(link))
        XCTAssertFalse(GitHubFinish.isLink(URL(string: "liaison://settings/github")!))
        XCTAssertEqual(GitHubFinish.params(link)?.code, "q")

        let ok = GitHubFinish.parse(Data(#"{"ok":true,"connected":true,"login":"sam","installations":[]}"#.utf8))
        if case .connected(let s) = ok { XCTAssertEqual(s.login, "sam") } else { XCTFail("connected") }
        XCTAssertEqual(GitHubFinish.parse(Data(#"{"ok":false,"confirm":true,"login":"eve","current":"sam"}"#.utf8)), .confirm(login: "eve", current: "sam"))
        XCTAssertEqual(GitHubFinish.parse(Data(#"{"ok":false,"error":"This GitHub link was started from another Liaison account."}"#.utf8)), .failed("This GitHub link was started from another Liaison account."))
        XCTAssertEqual(GitHubFinish.parse(Data("nope".utf8)), .failed("GitHub did not connect. Try again."))
    }
}
