import XCTest
import Foundation
@testable import Liaison

/// The side panel's services: stores, one live session, links, downloads (Shared/Core/WebPanelRules.swift).
final class WebPanelRulesTests: XCTestCase {
    private let tg = URL(string: "https://web.telegram.org/a/")!
    private let ig = URL(string: "https://www.instagram.com/direct/inbox/")!

    func testServiceKey() {
        XCTAssertEqual(WebPanelRules.serviceKey(tg), "telegram.org")
        XCTAssertEqual(WebPanelRules.serviceKey(URL(string: "https://WEB.WhatsApp.com/")), "whatsapp.com")
        XCTAssertEqual(WebPanelRules.serviceKey(URL(string: "https://mail.google.co.uk/")), "google.co.uk")
        XCTAssertNil(WebPanelRules.serviceKey(URL(string: "about:blank")))
        XCTAssertNil(WebPanelRules.serviceKey(nil))
    }

    func testStoreKey() {
        let ws = "acct1|p:prof9"
        XCTAssertEqual(WebPanelRules.storeKey(workspace: ws, service: "telegram.org", scope: .workspace), ws)
        XCTAssertNil(WebPanelRules.storeKey(workspace: nil, service: "telegram.org", scope: .workspace))
        let shared = WebPanelRules.storeKey(workspace: ws, service: "telegram.org", scope: .shared)
        XCTAssertEqual(shared, "acct1|p:~panel:telegram.org")
        // Every workspace of the account gets the same shared store; another account another one.
        XCTAssertEqual(WebPanelRules.storeKey(workspace: "acct1|p:other", service: "telegram.org", scope: .shared), shared)
        XCTAssertEqual(WebPanelRules.storeKey(workspace: "acct2|p:prof9", service: "telegram.org", scope: .shared),
                       "acct2|p:~panel:telegram.org")
        XCTAssertEqual(WebPanelRules.storeKey(workspace: nil, service: "x.com", scope: .shared), "_none|p:~panel:x.com")
        // The shared key stays in its account's SharedSignIns group.
        XCTAssertEqual(WebPanelRules.group(of: shared), "acct1")
    }

    func testSameSignInEverywhereByDefault() {
        // No stored choice (a new install, or one from before the rule): shared, for every service.
        XCTAssertEqual(WebPanelRules.scope(service: "telegram.org", perWorkspace: []), .shared)
        XCTAssertEqual(WebPanelRules.scope(service: "google.com", perWorkspace: ["telegram.org"]), .shared)
        // Switched off per service by the person.
        XCTAssertEqual(WebPanelRules.scope(service: "telegram.org", perWorkspace: ["telegram.org"]), .workspace)
        XCTAssertEqual(WebPanelRules.scope(service: nil, perWorkspace: []), .workspace)
        let off = WebPanelRules.choosing(.workspace, for: "whatsapp.com", perWorkspace: [])
        XCTAssertEqual(off, ["whatsapp.com"])
        XCTAssertEqual(WebPanelRules.choosing(.shared, for: "whatsapp.com", perWorkspace: off), [])
    }

    func testViewKeyPerWorkspace() {
        XCTAssertTrue(WebPanelRules.viewKey(workspace: "a|p:1", site: tg) != WebPanelRules.viewKey(workspace: "a|p:2", site: tg))
        XCTAssertEqual(WebPanelRules.viewKey(workspace: nil, site: tg), "_none|" + tg.absoluteString)
    }

    func testOneLiveSessionOfASharedService() {
        let a = WebPanelRules.Live(key: "a", service: "telegram.org", workspace: "w1", scope: .shared)
        let b = WebPanelRules.Live(key: "b", service: "telegram.org", workspace: "w2", scope: .shared)
        let c = WebPanelRules.Live(key: "c", service: "whatsapp.com", workspace: "w1", scope: .shared)
        let d = WebPanelRules.Live(key: "d", service: "telegram.org", workspace: "w3", scope: .workspace)
        XCTAssertEqual(WebPanelRules.toUnload(live: [a, b, c, d], showing: b), ["a"])
        XCTAssertEqual(WebPanelRules.toUnload(live: [a, b], showing: a), ["b"])
        XCTAssertEqual(WebPanelRules.toUnload(live: [b], showing: b), [])
        // A per-workspace service has its own store per workspace: nothing to unload.
        XCTAssertEqual(WebPanelRules.toUnload(live: [a, b, d], showing: d), [])
    }

    func testRouteLinksLeaveThePanel() {
        let out = URL(string: "https://example.com/article")!
        XCTAssertEqual(WebPanelRules.route(out, site: tg, mainFrame: true, newWindow: false, userClick: true), .openInMain(out))
        // A redirect or a script navigation (not a click) stays: sign-in flows.
        XCTAssertEqual(WebPanelRules.route(out, site: tg, mainFrame: true, newWindow: false, userClick: false), .stay)
        // Inside the service it stays.
        let inside = URL(string: "https://web.telegram.org/k/#@durov")!
        XCTAssertEqual(WebPanelRules.route(inside, site: tg, mainFrame: true, newWindow: false, userClick: true), .stay)
        // A subframe never leaves.
        XCTAssertEqual(WebPanelRules.route(out, site: tg, mainFrame: false, newWindow: false, userClick: true), .stay)
        // \u{2318}-click: a new tab of the main browser, even inside the service.
        XCTAssertEqual(WebPanelRules.route(inside, site: tg, mainFrame: true, newWindow: false, userClick: true, newTabGesture: true),
                       .openInMain(inside))
    }

    func testRouteNewWindowsOpenInMain() {
        let out = URL(string: "https://example.com/")!
        XCTAssertEqual(WebPanelRules.route(out, site: ig, mainFrame: true, newWindow: true, userClick: false), .openInMain(out))
        XCTAssertEqual(WebPanelRules.route(ig, site: ig, mainFrame: true, newWindow: true, userClick: true), .openInMain(ig))
        XCTAssertEqual(WebPanelRules.route(URL(string: "about:blank"), site: ig, mainFrame: true, newWindow: true, userClick: false), .ignore)
        XCTAssertEqual(WebPanelRules.route(nil, site: ig, mainFrame: true, newWindow: true, userClick: false), .ignore)
    }

    func testRouteShimsSignInsAndSchemes() {
        let shim = URL(string: "https://l.instagram.com/?u=https%3A%2F%2Fexample.com")!
        XCTAssertEqual(WebPanelRules.route(shim, site: ig, mainFrame: true, newWindow: false, userClick: true), .openInMain(shim))
        let google = URL(string: "https://accounts.google.com/o/oauth2/auth?x=1")!
        XCTAssertEqual(WebPanelRules.route(google, site: URL(string: "https://app.slack.com/client")!, mainFrame: true,
                                           newWindow: false, userClick: true), .stay)
        let fb = URL(string: "https://www.facebook.com/login/?next=x")!
        XCTAssertEqual(WebPanelRules.route(fb, site: URL(string: "https://www.messenger.com/")!, mainFrame: true,
                                           newWindow: false, userClick: true), .stay)
        let wnet = URL(string: "https://static.whatsapp.net/x")!
        XCTAssertEqual(WebPanelRules.route(wnet, site: URL(string: "https://web.whatsapp.com/")!, mainFrame: true,
                                           newWindow: false, userClick: true), .stay)
        let mail = URL(string: "mailto:a@b.c")!
        XCTAssertEqual(WebPanelRules.route(mail, site: tg, mainFrame: true, newWindow: false, userClick: true), .external(mail))
        XCTAssertEqual(WebPanelRules.route(mail, site: tg, mainFrame: true, newWindow: false, userClick: false), .ignore)
        XCTAssertEqual(WebPanelRules.route(URL(string: "file:///etc/hosts"), site: tg, mainFrame: true, newWindow: false, userClick: true), .ignore)
        XCTAssertEqual(WebPanelRules.route(URL(string: "blob:https://web.telegram.org/1"), site: tg, mainFrame: true,
                                           newWindow: false, userClick: true), .stay)
    }

    func testDownloads() {
        let base = URL(fileURLWithPath: "/Users/x/Downloads", isDirectory: true)
        XCTAssertEqual(WebPanelRules.downloadFolder(base: base, client: "Acme", perClient: false), base)
        XCTAssertEqual(WebPanelRules.downloadFolder(base: base, client: " ", perClient: true), base)
        XCTAssertEqual(WebPanelRules.downloadFolder(base: base, client: "A/B: C", perClient: true).path,
                       "/Users/x/Downloads/Liaison/A-B- C")
        var taken: Set<String> = ["/d/report.csv", "/d/report (1).csv"]
        let d = URL(fileURLWithPath: "/d", isDirectory: true)
        XCTAssertEqual(WebPanelRules.uniqueFile(in: d, name: "report.csv") { taken.contains($0.path) }.path, "/d/report (2).csv")
        taken = []
        XCTAssertEqual(WebPanelRules.uniqueFile(in: d, name: "notes") { taken.contains($0.path) }.path, "/d/notes")
        XCTAssertEqual(WebPanelRules.uniqueFile(in: d, name: "") { _ in false }.lastPathComponent, "download")
    }
}
