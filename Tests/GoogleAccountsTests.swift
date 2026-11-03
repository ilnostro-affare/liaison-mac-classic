import XCTest
import Foundation
@testable import Liaison

/// Workspace settings: Google accounts signed in in the browser, the owning Meta business (Shared/Core/GoogleAccounts.swift).
final class GoogleAccountsTests: XCTestCase {
    func testParse() {
        let raw = """
        ["gaia.l.a.r",[["gaia.l.a",1,"Sam D","sam@gmail.com","https://p/1.jpg",1,1,0,null,1,"111",null,null,null,null,1],\
        ["gaia.l.a",1,"Work","Sam@Company.com","https://p/2.jpg",1,1,0,null,0,"222"],\
        ["gaia.l.a",1,"Old","old@gmail.com","",1,1,0,null,1,"333"],\
        ["gaia.l.a",1,"Bad","bad@gmail.com","",0,1,0,null,0,"444"],\
        ["gaia.l.a",1,"Dup","sam@company.com","",1,1,0,null,0,"555"]]]
        """
        // [9] == 1 is signed out: the first and the third are left out, the invalid one too, the duplicate too.
        let a = GoogleAccounts.parse(Data(raw.utf8))
        XCTAssertEqual(a?.map(\.email), ["Sam@Company.com"])
        XCTAssertEqual(a?.first?.index, 1)
        XCTAssertEqual(a?.first?.name, "Work")
        let ok = #"["gaia.l.a.r",[["gaia.l.a",1,"A","a@x.com","",1,1,0,null,0,"1"],["gaia.l.a",1,"B","b@x.com","",1,1,0]]]"#
        XCTAssertEqual(GoogleAccounts.parse(Data(ok.utf8))?.map(\.email), ["a@x.com", "b@x.com"])
        XCTAssertEqual(GoogleAccounts.parse(Data((")]}'\n" + ok).utf8))?.count, 2)
        XCTAssertEqual(GoogleAccounts.parse(Data(#"["gaia.l.a.r",[]]"#.utf8)), [])
        XCTAssertNil(GoogleAccounts.parse(Data("<html>Sign in</html>".utf8)))
        XCTAssertNil(GoogleAccounts.parse(Data(#"{"a":1}"#.utf8)))
    }

    func testCookieHeader() {
        let u = GoogleAccounts.listURL
        let past = Date(timeIntervalSince1970: 1)
        let cs = [
            GoogleCookie(name: "SID", value: "s", domain: ".google.com", path: "/"),
            GoogleCookie(name: "LSID", value: "l", domain: "accounts.google.com", path: "/ListAccounts"),
            GoogleCookie(name: "X", value: "x", domain: "mail.google.com", path: "/"),
            GoogleCookie(name: "OLD", value: "o", domain: ".google.com", path: "/", expires: past),
            GoogleCookie(name: "EVIL", value: "e", domain: "evilgoogle.com", path: "/"),
            GoogleCookie(name: "P", value: "p", domain: ".google.com", path: "/mail"),
        ]
        XCTAssertEqual(GoogleAccounts.cookieHeader(cs, for: u), "LSID=l; SID=s")
    }

    func testPreselect() {
        let a = [GoogleAccount(email: "a@x.com", name: "", index: 0), GoogleAccount(email: "B@x.com", name: "", index: 1)]
        XCTAssertEqual(GoogleAccounts.preselect(saved: "b@x.com", signedIn: a), "B@x.com")
        XCTAssertEqual(GoogleAccounts.preselect(saved: "gone@x.com", signedIn: a), "a@x.com")
        XCTAssertEqual(GoogleAccounts.preselect(saved: nil, signedIn: a), "a@x.com")
        XCTAssertEqual(GoogleAccounts.preselect(saved: "kept@x.com", signedIn: []), "kept@x.com")
        XCTAssertNil(GoogleAccounts.preselect(saved: " ", signedIn: []))
    }

    func testMetaBusiness() {
        let today = #"{"ok":true,"accounts":[{"id":"123","name":"A","blocked":null}]}"#
        XCTAssertNil(MetaBusiness.owner(of: "123", in: Data(today.utf8)))
        let later = #"{"accounts":[{"id":"9","business":{"id":"77","name":"Other"}},{"id":"123","business":{"id":"555","name":"Acme Studio"}}]}"#
        XCTAssertEqual(MetaBusiness.owner(of: "act_123", in: Data(later.utf8)), MetaBusiness.Owner(id: "555", name: "Acme Studio"))
        let flat = #"{"data":[{"account_id":"123","business_id":"556"}]}"#
        XCTAssertEqual(MetaBusiness.owner(of: "123", in: Data(flat.utf8))?.id, "556")
        XCTAssertNil(MetaBusiness.owner(of: "124", in: Data(later.utf8)))
        XCTAssertNil(MetaBusiness.owner(of: "", in: Data(later.utf8)))
    }
}
