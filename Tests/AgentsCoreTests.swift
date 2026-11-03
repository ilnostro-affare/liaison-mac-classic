import XCTest
import Foundation
@testable import Liaison

/// The agent team's pure pieces (Shared/Core/Agents.swift).
final class AgentsCoreTests: XCTestCase {
    /// "Show in this workspace" per agent, per account and workspace; Lia stays; never none shown.
    func testAgentVisibility() {
        let k = AgentVisibility.key(account: "m1", profile: "p2", agent: "met")
        XCTAssertEqual(k, "lia_agent_hidden_m1|p:p2|a:met")
        XCTAssertTrue(k != AgentVisibility.key(account: "m2", profile: "p2", agent: "met"))
        XCTAssertTrue(k != AgentVisibility.key(account: "m1", profile: "p3", agent: "met"))
        XCTAssertEqual(AgentVisibility.key(account: nil, profile: "p", agent: "crea"), "lia_agent_hidden__none|p:p|a:crea")

        let roster = AgentInfo.fallback   // lia (lead), met, crea
        let none: (String) -> Bool = { _ in false }
        XCTAssertEqual(AgentVisibility.shownIds(roster, isHidden: none), ["lia", "met", "crea"])
        let noMet: (String) -> Bool = { $0 == "met" }
        XCTAssertEqual(AgentVisibility.filter(roster.filter { !$0.lead }, roster: roster, isHidden: noMet).map(\.id), ["crea"])
        // The lead is pinned: a stale key never hides it, and its toggle is off.
        let all: (String) -> Bool = { _ in true }
        XCTAssertEqual(AgentVisibility.shownIds(roster, isHidden: all), ["lia"])
        XCTAssertFalse(AgentVisibility.canToggle("lia", roster: roster, isHidden: none))
        XCTAssertTrue(AgentVisibility.canToggle("met", roster: roster, isHidden: all))     // hidden: can come back
        XCTAssertTrue(AgentVisibility.canToggle("crea", roster: roster, isHidden: noMet))  // Lia still shown
        XCTAssertFalse(AgentVisibility.canToggle("ghost", roster: roster, isHidden: none))

        // Without a lead: the last shown agent cannot be turned off, and all-hidden shows everyone.
        let team = roster.filter { !$0.lead }
        XCTAssertFalse(AgentVisibility.canToggle("crea", roster: team, isHidden: noMet))
        XCTAssertTrue(AgentVisibility.canToggle("crea", roster: team, isHidden: none))
        XCTAssertEqual(AgentVisibility.shownIds(team, isHidden: all), ["met", "crea"])
        // Order of the list is kept.
        XCTAssertEqual(AgentVisibility.filter([roster[2], roster[1]], roster: roster, isHidden: none).map(\.id), ["crea", "met"])
    }

    func testRosterParsesAndFallsBack() {
        let json = ##"{"ok":true,"version":"v1","agents":[{"id":"met","name":"Met","role":"Meta Ads","shape":"square","color":"#3B5BFD","write":true,"browser":true,"lead":false,"on_call":false,"writes_first":false,"soon":false},{"id":"x"}]}"##
        let r = AgentInfo.parseRoster(Data(json.utf8))
        XCTAssertEqual(r?.count, 1)
        XCTAssertEqual(r?.first?.shape, .square)
        XCTAssertEqual(r?.first?.colorHex, 0x3B5BFD)
        XCTAssertEqual(r?.first?.write, true)
        XCTAssertNil(AgentInfo.parseRoster(Data(#"{"ok":false}"#.utf8)))
        XCTAssertEqual(AgentInfo.fallback.count, 3)   // Lee retired; Rep, Seara, Giggs
        XCTAssertFalse(AgentInfo.fallback.contains { ["lee", "rep", "seara", "giggs"].contains($0.id) })
        XCTAssertEqual(AgentInfo.fallback.filter(\.write).map(\.id), ["met"])
        XCTAssertEqual(Set(AgentInfo.fallback.map(\.shape)).count, 3)
        XCTAssertEqual(AgentInfo.lookup("seara", in: [])?.name, "Seara")   // old dialogues still name it
        XCTAssertEqual(AgentInfo.hex("#e8572a"), 0xE8572A)
        XCTAssertNil(AgentInfo.hex("red"))
    }

    func testProfilesAndBrowserKey() {
        let json = ##"{"ok":true,"profiles":[{"id":"p1","name":"Acme Studio","color":"#13A3B0","meta_account":"123456","meta_account_name":"DC","google_customer":null}]}"##
        let p = CompanyProfile.parseList(Data(json.utf8))?.first
        XCTAssertEqual(p?.metaAccount, "123456")
        XCTAssertNil(p?.googleCustomer)
        XCTAssertEqual(p?.colorHex, 0x13A3B0)
        XCTAssertEqual(p?.adsManagerURL?.absoluteString, "https://adsmanager.facebook.com/adsmanager/manage/campaigns?act=123456")
        XCTAssertEqual(CompanyProfile.browserKey(account: "mem1", profile: "p1"), "mem1|p:p1")
        XCTAssertTrue(CompanyProfile.browserKey(account: "mem1", profile: "p1") != CompanyProfile.browserKey(account: "mem1", profile: "p2"))
        XCTAssertNil(CompanyProfile(id: "p", name: "n").adsManagerURL)
    }

    func testTeamLines() {
        XCTAssertEqual(TeamLine.parse(line: #"data:{"type":"agent_start","agent":"lee","from":null}"#), .agentStart(agent: "lee", from: nil))
        XCTAssertEqual(TeamLine.parse(line: #"data:{"type":"agent_start","agent":"met","from":"lia"}"#), .agentStart(agent: "met", from: "lia"))
        XCTAssertEqual(TeamLine.parse(line: #"data:{"type":"team_wait","agent":"met"}"#), .wait(agent: "met"))
        XCTAssertEqual(TeamLine.parse(line: #"data:{"type":"team_cap","left":["crea"]}"#), .cap(["crea"]))
        XCTAssertEqual(TeamLine.parse(line: #"data:{"type":"team_done","turns":2}"#), .done)
        XCTAssertNil(TeamLine.parse(line: #"data:{"type":"delta","text":"hi","agent":"lia"}"#))
        XCTAssertEqual(TeamLine.agent(line: #"data:{"type":"delta","text":"hi","agent":"lia"}"#), "lia")
        XCTAssertNil(TeamLine.parse(line: ""))
    }

    func testMessageAgentAndMachine() {
        let o: JSONObject = ["role": "assistant", "content": "x", "agent": "rep"]
        let m = ChatMessage(json: o, index: 0)!
        XCTAssertEqual(AgentOf.message(m), "rep")
        XCTAssertTrue(AgentOf.isMachine(ChatMessage(role: .user, content: "[browser_result] {}")))
        XCTAssertTrue(AgentOf.isMachine(ChatMessage(role: .user, content: "[handoff] Lia → Met: x")))
        XCTAssertFalse(AgentOf.isMachine(ChatMessage(role: .user, content: "how many leads?")))
    }

    func testAdsManagerAccountSwitch() {
        XCTAssertEqual(AdsManagerAccount.of(URL(string: "https://adsmanager.facebook.com/adsmanager/manage/campaigns?act=987&x=1")), "987")
        XCTAssertEqual(AdsManagerAccount.of(URL(string: "https://business.facebook.com/adsmanager/manage/adsets?act=55")), "55")
        XCTAssertEqual(AdsManagerAccount.of(URL(string: "https://www.facebook.com/adsmanager/act_42/overview")), "42")
        XCTAssertNil(AdsManagerAccount.of(URL(string: "https://google.com/?act=1")))
        let ps = [CompanyProfile(id: "a", name: "A", metaAccount: "111"), CompanyProfile(id: "b", name: "B", metaAccount: "222")]
        XCTAssertEqual(AdsManagerAccount.owner(of: URL(string: "https://adsmanager.facebook.com/adsmanager/manage/campaigns?act=222"), current: "a", profiles: ps)?.id, "b")
        XCTAssertNil(AdsManagerAccount.owner(of: URL(string: "https://adsmanager.facebook.com/adsmanager/manage/campaigns?act=111"), current: "a", profiles: ps))
        XCTAssertNil(AdsManagerAccount.owner(of: URL(string: "https://adsmanager.facebook.com/adsmanager/manage/campaigns?act=333"), current: "a", profiles: ps))
    }

    func testMentions() {
        let r = AgentInfo.fallback
        XCTAssertEqual(AgentMention.partial("ask @Cr"), "Cr")
        XCTAssertNil(AgentMention.partial("mail me@ex"))
        XCTAssertNil(AgentMention.partial("no mention"))
        XCTAssertEqual(AgentMention.suggestions("hey @l", roster: r).map(\.id), ["lia"])
        // The team is Lia, Met, Crea (Dev when flagged); Rep, Seara and Giggs are retired
        XCTAssertEqual(r.map(\.id), ["lia", "met", "crea"])
        XCTAssertEqual(AgentMention.complete("hey @Cr", with: r[2]), "hey @Crea ")
    }

    func testFeedText() {
        let (t, b) = FeedText.split("**Morning report is ready.** 47 leads yesterday; CPL rose to €6.64.\n@Met: move the budget")
        XCTAssertEqual(t, "Morning report is ready.")
        XCTAssertEqual(b, "47 leads yesterday; CPL rose to €6.64.")
        let long = String(repeating: "word ", count: 40)
        let (t2, _) = FeedText.split(long, titleMax: 30)
        XCTAssertTrue(t2.count <= 31 && t2.hasSuffix("\u{2026}"))
        XCTAssertEqual(FeedText.split("").0, "")
        XCTAssertEqual(FeedText.route("adsmanager.facebook.com"), .open)
        XCTAssertEqual(FeedText.route("https://x.com/a b"), .open)
        XCTAssertEqual(FeedText.route("how did yesterday go?"), .team)
        XCTAssertEqual(FeedText.route("@Met leads"), .team)
    }

    func testProfileAccounts() {
        let many = Data(#"{"ok":true,"profiles":[{"id":"p1","name":"Shop","meta_account":"111","meta_accounts":[{"id":"111","name":"A"},{"id":"act_222","name":"B"}]},{"id":"p2","name":"Old","meta_account":"333","meta_account_name":"C"},{"id":"p3","name":"None"}]}"#.utf8)
        let list = CompanyProfile.parseList(many) ?? []
        XCTAssertEqual(list.count, 3)
        XCTAssertEqual(list[0].metaAccounts.map(\.id), ["111", "222"])
        XCTAssertEqual(list[1].metaAccounts.map(\.name), ["C"])
        XCTAssertTrue(list[2].metaAccounts.isEmpty)
        XCTAssertEqual(CompanyProfile.accountsBody([("1", "x")]), [["id": "1", "name": "x"]])
    }
}
