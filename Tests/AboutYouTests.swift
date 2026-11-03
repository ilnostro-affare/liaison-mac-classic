import XCTest
import Foundation
@testable import Liaison

/// The one-time About you step (acquisition-source, type-of-market, the creator code).
final class AboutYouTests: XCTestCase {
    let now = Date(timeIntervalSince1970: 1_800_000_000)

    func testRoleToMarket() {
        XCTAssertEqual(AboutYou.marketValue(.agency), "agency")
        XCTAssertEqual(AboutYou.marketValue(.owner), "freelancer")
        XCTAssertEqual(AboutYou.marketValue(.marketer), "business")
        XCTAssertEqual(AboutYou.marketValue(.developer), "other")
        XCTAssertNil(AboutYou.marketValue(nil))
        for r in LiaRole.allCases { XCTAssertTrue(AboutYou.marketValues.contains(AboutYou.marketValue(r) ?? "")) }
        XCTAssertEqual(AboutYou.sourceValue("direct"), "direct")
        XCTAssertNil(AboutYou.sourceValue("tiktok"), "unlike the sign-up, nothing is saved for no answer")
        XCTAssertEqual(AboutYou.marketField, "type-of-market")
        XCTAssertEqual(AboutYou.sourceField, "acquisition-source")
    }

    func testMissing() {
        XCTAssertEqual(AboutYou.missing([:]), ["acquisition-source", "type-of-market"])
        XCTAssertEqual(AboutYou.missing(["acquisition-source": "google"]), ["type-of-market"])
        XCTAssertEqual(AboutYou.missing(["acquisition-source": "  ", "type-of-market": "agency"]), ["acquisition-source"])
        XCTAssertEqual(AboutYou.missing(["acquisition-source": NSNull(), "type-of-market": "studio"]), ["acquisition-source"])
        XCTAssertEqual(AboutYou.missing(["acquisition-source": "google", "type-of-market": "other"]), [])
    }

    func testCustomFieldsFromMember() {
        let rec: JSONObject = ["data": ["id": "mem_1", "customFields": ["acquisition-source": "claude"]]]
        XCTAssertEqual(AboutYou.customFields(rec)?["acquisition-source"] as? String, "claude")
        XCTAssertEqual(AboutYou.customFields(["data": ["id": "mem_1"]])?.count, 0, "no customFields: all missing")
        XCTAssertNil(AboutYou.customFields(["data": NSNull()]), "no member: nothing is asked")
        XCTAssertNil(AboutYou.customFields(nil))
    }

    func testCreatedAtAndVia() {
        let iso: JSONObject = ["data": ["id": "m", "createdAt": "2027-01-15T08:00:00.123Z"]]
        let d = AboutYou.createdAt(iso)
        XCTAssertNotNil(d)
        XCTAssertNotNil(AboutYou.createdAt(["data": ["id": "m", "createdAt": "2027-01-15T08:00:00Z"]]))
        XCTAssertEqual(AboutYou.createdAt(["id": "m", "createdAt": 1_800_000_000_000])?.timeIntervalSince1970, 1_800_000_000)
        XCTAssertEqual(AboutYou.createdAt(["id": "m", "createdAt": 1_800_000_000])?.timeIntervalSince1970, 1_800_000_000)
        XCTAssertNil(AboutYou.createdAt(["id": "m"]))
        XCTAssertEqual(AboutYou.creatorVia(createdAt: now.addingTimeInterval(-3600), now: now), .signup)
        XCTAssertEqual(AboutYou.creatorVia(createdAt: now.addingTimeInterval(-10 * 24 * 3600), now: now), .settings)
        XCTAssertEqual(AboutYou.creatorVia(createdAt: nil, now: now), .settings)
    }

    func testSnoozeSevenDays() {
        let l = AboutYou.snoozing(AboutYou.Local(), now: now)
        XCTAssertTrue(AboutYou.isSnoozed(l, now: now.addingTimeInterval(6 * 24 * 3600)))
        XCTAssertFalse(AboutYou.isSnoozed(l, now: now.addingTimeInterval(7 * 24 * 3600 + 1)))
        XCTAssertEqual(AboutYou.toAsk(missing: AboutYou.fields, local: l, now: now.addingTimeInterval(3600)), [])
        XCTAssertEqual(AboutYou.toAsk(missing: AboutYou.fields, local: l, now: now.addingTimeInterval(8 * 24 * 3600)), AboutYou.fields)
    }

    func testOnlyMissingAndUnanswered() {
        var l = AboutYou.Local()
        XCTAssertEqual(AboutYou.toAsk(missing: ["type-of-market"], local: l, now: now), ["type-of-market"])
        l = AboutYou.answering(l, ["acquisition-source": "google"], now: now)
        XCTAssertEqual(AboutYou.toAsk(missing: AboutYou.fields, local: l, now: now), ["type-of-market"],
                       "answered here: not asked again even while Memberstack still lacks it")
        XCTAssertEqual(AboutYou.toAsk(missing: ["first-name"], local: AboutYou.Local(), now: now), [])
    }

    func testAnswersAndCanSave() {
        XCTAssertFalse(AboutYou.canSave(asked: AboutYou.fields, source: "google", role: nil))
        XCTAssertTrue(AboutYou.canSave(asked: AboutYou.fields, source: "google", role: .agency))
        XCTAssertTrue(AboutYou.canSave(asked: ["type-of-market"], source: nil, role: .owner))
        XCTAssertFalse(AboutYou.canSave(asked: ["acquisition-source"], source: "tiktok", role: nil))
        XCTAssertFalse(AboutYou.canSave(asked: [], source: "google", role: .owner))
        XCTAssertEqual(AboutYou.answers(asked: ["type-of-market"], source: "google", role: .agency), ["type-of-market": "agency"],
                       "a question that was not asked is not saved")
        XCTAssertEqual(AboutYou.answers(asked: AboutYou.fields, source: "direct", role: .marketer),
                       ["acquisition-source": "direct", "type-of-market": "business"])
        let b = AboutYou.body(["type-of-market": "agency"])
        XCTAssertEqual(b["customFields"] as? [String: String], ["type-of-market": "agency"])
    }

    func testPendingDelivery() {
        var l = AboutYou.answering(AboutYou.snoozing(AboutYou.Local(), now: now), ["type-of-market": "agency"], now: now)
        XCTAssertNil(l.snoozedUntil, "Save clears a snooze")
        XCTAssertEqual(AboutYou.toSend(l, now: now), ["type-of-market": "agency"])
        XCTAssertEqual(AboutYou.after(l, sent: ["type-of-market": "agency"], outcome: .retry), l, "retry keeps it")
        l = AboutYou.after(l, sent: ["type-of-market": "agency"], outcome: .saved)
        XCTAssertTrue(l.pending.isEmpty)
        XCTAssertNil(l.pendingAt)
        XCTAssertEqual(l.answered, ["type-of-market"])
        XCTAssertNil(AboutYou.toSend(l, now: now))
        let old = AboutYou.answering(AboutYou.Local(), ["acquisition-source": "google"], now: now)
        XCTAssertNil(AboutYou.toSend(old, now: now.addingTimeInterval(61 * 24 * 3600)), "too old: dropped")
        // a newer answer for the same field is not cleared by an older send
        let newer = AboutYou.answering(old, ["acquisition-source": "claude"], now: now)
        XCTAssertEqual(AboutYou.after(newer, sent: ["acquisition-source": "google"], outcome: .saved).pending, ["acquisition-source": "claude"])
    }

    func testCodable() {
        let l = AboutYou.answering(AboutYou.Local(), ["type-of-market": "other"], now: now)
        XCTAssertEqual(AboutYou.decode(AboutYou.encode(l)), l)
        XCTAssertEqual(AboutYou.decode(Data("junk".utf8)), AboutYou.Local())
        XCTAssertEqual(AboutYou.decode(nil), AboutYou.Local())
        XCTAssertEqual(AboutYou.key(member: "mem_1"), "lia_about_you_mem_1")
    }

    func testSaveOutcome() {
        XCTAssertEqual(AboutYou.saveOutcome(status: 200, json: ["data": ["id": "m"]]), .saved)
        XCTAssertEqual(AboutYou.saveOutcome(status: 0, json: nil), .retry)
        XCTAssertEqual(AboutYou.saveOutcome(status: 401, json: nil), .retry)
        XCTAssertEqual(AboutYou.saveOutcome(status: 429, json: nil), .retry)
        XCTAssertEqual(AboutYou.saveOutcome(status: 503, json: nil), .retry)
        XCTAssertEqual(AboutYou.saveOutcome(status: 200, json: [:]), .retry)
        XCTAssertEqual(AboutYou.saveOutcome(status: 400, json: ["code": "invalid-custom-field"]), .refused("invalid-custom-field"))
        XCTAssertEqual(AboutYou.saveOutcome(status: 403, json: nil), .refused("http_403"))
    }

    func testSilentRoleFill() {
        XCTAssertEqual(AboutYou.silent(toAsk: AboutYou.fields, role: .agency), ["type-of-market": "agency"],
                       "a role this Mac knows is sent without asking")
        XCTAssertEqual(AboutYou.silent(toAsk: AboutYou.fields, role: nil), [:])
        XCTAssertEqual(AboutYou.silent(toAsk: ["acquisition-source"], role: .agency), [:], "not missing: not sent")
    }

    func testWelcomeAsksSource() {
        XCTAssertTrue(AboutYou.welcomeAsksSource(customFields: [:], local: AboutYou.Local()))
        XCTAssertTrue(AboutYou.welcomeAsksSource(customFields: nil, local: AboutYou.Local()), "not read: asked")
        XCTAssertFalse(AboutYou.welcomeAsksSource(customFields: ["acquisition-source": "claude"], local: AboutYou.Local()),
                       "the email sign-up saved it: not asked twice")
        let l = AboutYou.answering(AboutYou.Local(), ["acquisition-source": "google"], now: now)
        XCTAssertFalse(AboutYou.welcomeAsksSource(customFields: [:], local: l))
    }
}

/// The welcome and the role per Liaison account.
final class AccountPrefsTests: XCTestCase {
    func r(_ member: String, owner: String?, go: Bool, gr: String?, mo: Bool?, mr: String?) -> AccountPrefs.Resolved {
        AccountPrefs.resolve(member: member, owner: owner, globalOnboarded: go, globalRole: gr, memberOnboarded: mo, memberRole: mr)
    }

    func testMigrationGivesTheMacsValuesToTheAccountInFront() {
        XCTAssertEqual(r("A", owner: nil, go: true, gr: "marketer", mo: nil, mr: nil),
                       AccountPrefs.Resolved(onboarded: true, role: "marketer", inherits: true))
    }

    func testAnotherAccountStartsWithTheWelcome() {
        // A new Google account on a Mac that had been through the welcome
        XCTAssertEqual(r("B", owner: "A", go: true, gr: "marketer", mo: nil, mr: nil),
                       AccountPrefs.Resolved(onboarded: false, role: "", inherits: false))
    }

    func testOwnKeysWin() {
        XCTAssertEqual(r("B", owner: "A", go: false, gr: nil, mo: true, mr: "developer"),
                       AccountPrefs.Resolved(onboarded: true, role: "developer", inherits: false))
        XCTAssertEqual(r("A", owner: "A", go: true, gr: "agency", mo: false, mr: ""),
                       AccountPrefs.Resolved(onboarded: false, role: "", inherits: false), "Start over cleared A's own keys")
        XCTAssertEqual(r("A", owner: "A", go: true, gr: "agency", mo: nil, mr: nil),
                       AccountPrefs.Resolved(onboarded: true, role: "agency", inherits: false))
        XCTAssertEqual(r("C", owner: nil, go: false, gr: "bogus", mo: nil, mr: nil),
                       AccountPrefs.Resolved(onboarded: false, role: "", inherits: true), "a fresh Mac")
    }

    func testKeys() {
        XCTAssertEqual(AccountPrefs.onboardedKey("mem_1"), "lia_onboarded_mem_1")
        XCTAssertEqual(AccountPrefs.roleKey("mem_1"), "lia_role_mem_1")
    }
}
