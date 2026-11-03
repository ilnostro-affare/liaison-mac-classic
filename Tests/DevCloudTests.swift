import XCTest
import Foundation
@testable import Liaison

/// Dev's cloud - parsing {ok, cloud}, the request bodies, host and name normalisation, the cell's status, and
/// Dev's new `http_request` tool and `run` with secrets in the live stream and the Activity.
final class DevCloudTests: XCTestCase {
    private let sample = #"""
    {"ok":true,"cloud":{"internet":true,"sites":["api.stripe.com","*.example.com"],"env":{"NODE_ENV":"production","N":3},
     "setup":"npm ci","at":1760000000000,"keys_ready":true,
     "secrets":[{"id":"s1","name":"STRIPE_KEY","hosts":["api.stripe.com"],"paths":["/v1/"],"header":"Authorization","prefix":"Bearer","at":5,"set":true},
                {"id":"s2","name":"MAIL_KEY","hosts":[],"header":"X-Api-Key","prefix":"","set":false}]}}
    """#

    func testParsesTheWholeCloud() throws {
        guard case .success(let c) = DevCloud.parse(Data(sample.utf8)) else { return XCTFail("no cloud") }
        XCTAssertTrue(c.internet)
        XCTAssertEqual(c.sites, ["api.stripe.com", "*.example.com"])
        XCTAssertEqual(c.env, ["NODE_ENV": "production", "N": "3"])
        XCTAssertEqual(c.setup, "npm ci")
        XCTAssertEqual(c.at, 1760000000000)
        XCTAssertTrue(c.keysReady)
        XCTAssertEqual(c.secrets.count, 2)
        let s = c.secrets[0]
        XCTAssertEqual(s.id, "s1"); XCTAssertEqual(s.name, "STRIPE_KEY")
        XCTAssertEqual(s.hosts, ["api.stripe.com"]); XCTAssertEqual(s.paths, ["/v1/"])
        XCTAssertEqual(s.header, "Authorization"); XCTAssertEqual(s.prefix, "Bearer")
        XCTAssertTrue(s.set); XCTAssertTrue(s.hasAdvanced)   // it has a path prefix
        XCTAssertEqual(s.sitesText, "api.stripe.com")
        let m = c.secrets[1]
        XCTAssertEqual(m.header, "X-Api-Key"); XCTAssertEqual(m.prefix, "")   // an empty prefix is "none", kept
        XCTAssertFalse(m.set); XCTAssertTrue(m.hasAdvanced)
        XCTAssertEqual(m.sitesText, "No website")
        XCTAssertEqual(c.envRows.map(\.name), ["N", "NODE_ENV"])
    }

    func testDefaultsAndErrors() {
        guard case .success(let c) = DevCloud.parse(Data(#"{"ok":true,"cloud":{"secrets":[{"id":"k","name":"A"}]}}"#.utf8)) else {
            return XCTFail("no cloud")
        }
        XCTAssertTrue(c.internet); XCTAssertTrue(c.keysReady); XCTAssertEqual(c.setup, ""); XCTAssertEqual(c.at, 0)
        XCTAssertEqual(c.secrets.first?.header, "Authorization"); XCTAssertEqual(c.secrets.first?.prefix, "Bearer")
        XCTAssertEqual(c.secrets.first?.set, true)
        guard case .success(let off) = DevCloud.parse(Data(#"{"ok":true,"cloud":{"internet":false,"keys_ready":false}}"#.utf8)) else {
            return XCTFail("no cloud")
        }
        XCTAssertFalse(off.internet); XCTAssertFalse(off.keysReady)
        XCTAssertEqual(DevCloud.parse(Data(#"{"ok":false,"error":"Name is taken."}"#.utf8)), .failure(DevFilesError("Name is taken.")))
        XCTAssertEqual(DevCloud.parse(Data("nope".utf8)), .failure(DevFilesError("Could not read Dev's cloud.")))
        XCTAssertEqual(DevCloud.parse(Data(#"{"ok":true}"#.utf8)), .failure(DevFilesError("Could not read Dev's cloud.")))
    }

    func testCellStatus() {
        XCTAssertNil(DevCloud.cellStatus(nil))
        XCTAssertEqual(DevCloud(internet: false, secrets: [DevCloudSecret(id: "a", name: "A", hosts: [])]).cellStatus, "Internet off")
        XCTAssertEqual(DevCloud(secrets: [DevCloudSecret(id: "a", name: "A", hosts: [])]).cellStatus, "1 key")
        XCTAssertEqual(DevCloud(secrets: [DevCloudSecret(id: "a", name: "A", hosts: []), DevCloudSecret(id: "b", name: "B", hosts: [])]).cellStatus, "2 keys")
        XCTAssertEqual(DevCloud(sites: ["a.com"]).cellStatus, "1 site")
        XCTAssertEqual(DevCloud().cellStatus, "Online")
        XCTAssertEqual(DevCloud.internetLine(true), "Dev can reach the web, install packages and call APIs.")
        XCTAssertEqual(DevCloud.internetLine(false), "Dev works offline.")
    }

    func testHostAndNameNormalisation() {
        XCTAssertEqual(DevCloud.host(" https://API.Stripe.com/v1/charges?x=1 "), "api.stripe.com")
        XCTAssertEqual(DevCloud.host("*.Stripe.com"), "*.stripe.com")
        XCTAssertEqual(DevCloud.host("my-shop.com:8080/"), "my-shop.com")
        XCTAssertEqual(DevCloud.host("user@host.io."), "host.io")
        XCTAssertTrue(DevCloud.isHost("api.stripe.com")); XCTAssertTrue(DevCloud.isHost("*.stripe.com"))
        XCTAssertFalse(DevCloud.isHost("localhost")); XCTAssertFalse(DevCloud.isHost("a..b")); XCTAssertFalse(DevCloud.isHost("a b.com"))
        XCTAssertFalse(DevCloud.isHost("a.*.com"))
        XCTAssertEqual(DevCloud.adding(site: "https://My-Shop.com/", to: ["a.com"]), ["a.com", "my-shop.com"])
        XCTAssertNil(DevCloud.adding(site: "a.com", to: ["a.com"]))
        XCTAssertNil(DevCloud.adding(site: "nothing", to: []))
        XCTAssertEqual(DevCloud.hosts("api.stripe.com, https://files.stripe.com/x\napi.stripe.com"), ["api.stripe.com", "files.stripe.com"])
        XCTAssertEqual(DevCloud.envName("stripe key"), "STRIPE_KEY")
        XCTAssertEqual(DevCloud.envName("  my-api.key!! "), "MY_API_KEY")
        XCTAssertEqual(DevCloud.envName("1password"), "_1PASSWORD")
        XCTAssertEqual(DevCloud.envName("---"), "")
        XCTAssertEqual(DevCloud.paths("v1/, /v2/\n/v1/\n  "), ["/v1/", "/v2/"])
        let rows = [DevCloudEnvRow(name: "node env", value: "x"), DevCloudEnvRow(name: " ", value: "dropped"), DevCloudEnvRow(name: "NODE_ENV", value: "y")]
        XCTAssertEqual(DevCloud.env(rows), ["NODE_ENV": "y"])
    }

    func testRequestBodies() {
        let b = DevCloudBody.cloud(profile: "p1", internet: false)
        XCTAssertEqual(b["profile"] as? String, "p1"); XCTAssertEqual(b["internet"] as? Bool, false)
        XCTAssertNil(b["sites"]); XCTAssertNil(b["env"]); XCTAssertNil(b["setup"])
        let all = DevCloudBody.cloud(profile: "p", sites: ["a.com"], env: ["A": "1"], setup: "")
        XCTAssertEqual(all["sites"] as? [String], ["a.com"]); XCTAssertEqual(all["env"] as? [String: String], ["A": "1"])
        XCTAssertEqual(all["setup"] as? String, "")
        XCTAssertNil(all["internet"])

        let n = DevCloudBody.secret(profile: "p", name: "stripe key", value: "sk_1", hosts: ["api.stripe.com"])
        XCTAssertEqual(n["name"] as? String, "STRIPE_KEY"); XCTAssertEqual(n["value"] as? String, "sk_1")
        XCTAssertNil(n["id"]); XCTAssertEqual(n["header"] as? String, "Authorization"); XCTAssertEqual(n["prefix"] as? String, "Bearer")
        XCTAssertEqual(n["hosts"] as? [String], ["api.stripe.com"]); XCTAssertEqual(n["paths"] as? [String], [])
        // an edit with an empty value keeps the key: no "value" goes
        let e = DevCloudBody.secret(profile: "p", id: "s1", name: "A", value: "", hosts: ["a.com"], paths: ["/v1/"], header: " ", prefix: "")
        XCTAssertEqual(e["id"] as? String, "s1"); XCTAssertNil(e["value"])
        XCTAssertEqual(e["header"] as? String, "Authorization"); XCTAssertEqual(e["prefix"] as? String, "")
        XCTAssertEqual(e["paths"] as? [String], ["/v1/"])
        let d = DevCloudBody.deleteSecret(profile: "p", id: "s1")
        XCTAssertEqual(d["id"] as? String, "s1"); XCTAssertEqual(d["profile"] as? String, "p")

        XCTAssertEqual(DevCloudBody.secretProblem(isNew: true, name: "", value: "x", hosts: ["a.com"]), "Give the key a name.")
        XCTAssertEqual(DevCloudBody.secretProblem(isNew: true, name: "A", value: " ", hosts: ["a.com"]), "Paste the key.")
        XCTAssertNil(DevCloudBody.secretProblem(isNew: false, name: "A", value: "", hosts: ["a.com"]))
        XCTAssertEqual(DevCloudBody.secretProblem(isNew: false, name: "A", value: "", hosts: []), "Add the website this key is for.")
        XCTAssertNotNil(DevCloudBody.secretProblem(isNew: false, name: "A", value: "", hosts: ["nohost"]))
    }

    // MARK: http_request and run with secrets

    func testHttpRequestInTheLiveStream() {
        XCTAssertTrue(DevLine.tools.contains("http_request"))
        guard case let .actStart(id, tool, args)? = DevLine.parse(line: #"data:{"type":"act_start","id":"h1","tool":"http_request","targs":{"method":"POST","url":"api.stripe.com/v1/charges"}}"#) else {
            return XCTFail("no act_start")
        }
        XCTAssertEqual(id, "h1"); XCTAssertEqual(tool, "http_request")
        let s = DevStep.start(id: id, tool: tool, args: args, at: 1)
        XCTAssertEqual(s.kind, .request); XCTAssertEqual(s.symbol, "network")
        XCTAssertEqual(s.text, "POST api.stripe.com/v1/charges"); XCTAssertEqual(s.subject, "api.stripe.com")
        let g = DevStep.start(id: "h2", tool: "http_request", args: ["url": "https://api.stripe.com/v1/balance?x=1"], at: 2)
        XCTAssertEqual(g.text, "Called api.stripe.com/v1/balance")
        XCTAssertEqual(DevStep.start(id: "h3", tool: "http_request", args: [:], at: 3).text, "Called a service")
        XCTAssertEqual(DevStep.symbol(historyKind: g.phrase.kind), "network")
        XCTAssertEqual(DevToolPhrases.labels["http_request"], "Request")
        XCTAssertEqual(DevToolPhrases.all["http_request"]?.first, "Calling an API")
        XCTAssertEqual(ToolPhrases.title("http_request"), "Calling an API")
        XCTAssertEqual(DevConfirm(tool: "http_request", summary: "POST api.stripe.com/v1/charges").title, "Dev wants to call a service")

        var a = DevActivity()
        a.on(.actStart(id: "h1", tool: "http_request", args: args), at: 1)
        a.on(.actDone(id: "h1", sum: "Status 200"), at: 2)
        XCTAssertEqual(a.steps.first?.failed, false)
        a.on(.actStart(id: "h2", tool: "http_request", args: ["url": "api.stripe.com/v1/x"]), at: 3)
        a.on(.actDone(id: "h2", sum: "Status 404"), at: 4)
        XCTAssertEqual(a.steps.last?.failed, true)
        XCTAssertTrue(DevStep.failed("Failed")); XCTAssertFalse(DevStep.failed("Status 302"))
        XCTAssertEqual(DevActivityGroups.failures(a.steps), "1 request failed")
    }

    func testRunWithSecrets() {
        let s = DevStep.start(id: "r", tool: "run", args: ["command": "node pay.js", "secrets": "STRIPE_KEY,MAIL_KEY"], at: 1)
        XCTAssertEqual(s.kind, .command); XCTAssertTrue(s.code)
        XCTAssertEqual(s.text, "node pay.js \u{00b7} uses STRIPE_KEY, MAIL_KEY")
        XCTAssertEqual(DevStep.secretNames(#"["A", "B"]"#), ["A", "B"])
        XCTAssertEqual(DevStep.secretNames(nil), [])
        XCTAssertEqual(DevStep.start(id: "r2", tool: "run", args: ["command": "ls"], at: 1).text, "ls")
    }

    func testActivitySentenceForRequests() {
        func req(_ id: String, _ url: String) -> DevStep { DevStep.start(id: id, tool: "http_request", args: ["url": url], at: 0) }
        XCTAssertEqual(DevActivityGroups.sentence([req("1", "api.stripe.com/v1/a")]), "Called api.stripe.com")
        XCTAssertEqual(DevActivityGroups.sentence([req("1", "api.stripe.com/v1/a"), req("2", "api.stripe.com/v1/b")]),
                       "Called api.stripe.com 2 times")
        XCTAssertEqual(DevActivityGroups.sentence([req("1", "api.stripe.com/v1/a"), req("2", "api.sendgrid.com/v3/mail")]),
                       "Called 2 APIs")
        let edit = DevStep.start(id: "e", tool: "write_file", args: ["path": "pay.js"], at: 0)
        XCTAssertEqual(DevActivityGroups.sentence([edit, req("1", "api.stripe.com/v1/a")]), "Edited pay.js, called api.stripe.com")
        XCTAssertEqual(DevActivityGroups.sentence([req("1", ""), req("2", "")]), "Made 2 API calls")
    }
    // The Sites editor - one site per line, wildcards, invalid lines named.
    func testSitesEditorParsesLines() {
        let d = DevCloudSites.parse("""
        https://API.Stripe.com/v1/charges
        *.Example.com

          my-shop.com:8080/
        api.stripe.com
        user@files.stripe.com.
        a.com, b.com
        # a comment
        c.com # trailing comment
        """)
        XCTAssertEqual(d.hosts, ["api.stripe.com", "*.example.com", "my-shop.com", "files.stripe.com", "a.com", "b.com", "c.com"])
        XCTAssertEqual(d.repeats, 1)
        XCTAssertTrue(d.isValid)
    }

    func testSitesEditorReportsBadLines() {
        let d = DevCloudSites.parse("ok.com\nlocalhost\n*\n*.com\napi.*.com\nmy_shop.com\nexample..com\nhttp://")
        XCTAssertEqual(d.hosts, ["ok.com"])
        XCTAssertEqual(d.problems.map(\.line), [2, 3, 4, 5, 6, 7, 8])
        XCTAssertEqual(d.problems[0].text, "localhost")
        XCTAssertTrue(d.problems[1].reason.contains("*.example.com"))
        XCTAssertTrue(d.problems[2].reason.contains("*.example.com"))
        XCTAssertTrue(d.problems[3].reason.contains("only at the start"))
        XCTAssertTrue(d.problems[4].reason.contains("letters"))
        XCTAssertFalse(d.isValid)
        XCTAssertTrue(d.problems[0].message.hasPrefix("Line 2: "))
    }

    func testSitesEditorLimitAndRoundTrip() {
        let many = (1...52).map { "s\($0).com" }.joined(separator: "\n")
        let d = DevCloudSites.parse(many)
        XCTAssertEqual(d.hosts.count, DevCloudSites.limit)
        XCTAssertEqual(d.problems.map(\.line), [51, 52])
        let sites = ["api.stripe.com", "*.example.com"]
        XCTAssertEqual(DevCloudSites.parse(DevCloudSites.text(sites)).hosts, sites)
        XCTAssertFalse(DevCloudSites.changed("api.stripe.com\n\n  *.EXAMPLE.com  \n", from: sites))
        XCTAssertTrue(DevCloudSites.changed("api.stripe.com", from: sites))
        XCTAssertTrue(DevCloudSites.changed("api.stripe.com\n*.example.com\nbad", from: sites))
        XCTAssertTrue(DevCloudSites.parse("").hosts.isEmpty)
        // every saved host passes the server's own check
        for h in d.hosts + sites { XCTAssertTrue(DevCloud.isHost(h), h) }
    }
}
