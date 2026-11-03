import XCTest
import Foundation
@testable import Liaison

/// The tab strip's pure rules (Shared/Core/TabStrip.swift).
final class TabStripTests: XCTestCase {
    private func slots(_ s: [(String?, Bool)]) -> [TabStrip.Slot] { s.map { TabStrip.Slot(group: $0.0, pinned: $0.1) } }

    func testGroupsAreGatheredWhereTheirFirstTabIs() {
        // a A b A B a c: the strays inside A's and B's runs leave them.
        let s = slots([("A", false), (nil, false), ("A", false), ("B", false), (nil, false), ("B", false), ("A", false)])
        let o = TabStrip.order(s, pinnedGroups: [])
        XCTAssertEqual(o, [0, 2, 6, 1, 3, 5, 4])
        XCTAssertTrue(TabStrip.groupsContiguous(o.map { s[$0].group }))
    }

    func testPinnedTabsThenPinnedGroupsThenTheRest() {
        let s = slots([(nil, false), ("G", false), (nil, true), ("P", false), (nil, true), ("G", false), ("P", false)])
        let o = TabStrip.order(s, pinnedGroups: ["P"])
        XCTAssertEqual(o, [2, 4, 3, 6, 0, 1, 5])
    }

    func testOrderedStripIsLeftAlone() {
        let s = slots([(nil, true), ("P", false), (nil, false), ("A", false), ("A", false), (nil, false)])
        XCTAssertTrue(TabStrip.isOrdered(s, pinnedGroups: ["P"]))
        XCTAssertEqual(TabStrip.order(s, pinnedGroups: ["P"]), Array(0..<6))
        XCTAssertFalse(TabStrip.isOrdered(slots([("A", false), (nil, false), ("A", false)]), pinnedGroups: []))
    }

    func testContiguity() {
        XCTAssertTrue(TabStrip.groupsContiguous(["A", "A", nil, "B", nil]))
        XCTAssertFalse(TabStrip.groupsContiguous(["A", "B", "A"]))
        XCTAssertFalse(TabStrip.groupsContiguous(["A", nil, "A"]))
        XCTAssertTrue(TabStrip.groupsContiguous([]))
    }

    func testDropJoinsOnlyBetweenTwoTabsOfOneGroup() {
        XCTAssertEqual(TabStrip.groupAfterDrop(["A", nil, "A"], index: 1, target: nil), "A")
        XCTAssertNil(TabStrip.groupAfterDrop(["A", nil, "B"], index: 1, target: nil))
        XCTAssertEqual(TabStrip.groupAfterDrop(["A", nil, nil], index: 1, target: "A"), "A")
        XCTAssertNil(TabStrip.groupAfterDrop([nil, nil], index: 0, target: nil))
    }

    func testSiteNames() {
        XCTAssertEqual(SiteName.word(host: "github.com", title: nil), "GitHub")
        XCTAssertEqual(SiteName.word(host: "app.hubspot.com", title: nil), "Hubspot")
        XCTAssertEqual(SiteName.word(host: "app.hubspot.com", title: "HubSpot | Contacts"), "HubSpot")
        XCTAssertEqual(SiteName.word(host: "mail.google.com", title: "Inbox (3) - sam@x.com - Gmail"), "Gmail")
        XCTAssertEqual(SiteName.word(host: "mail.google.com", title: "Loading"), "Google")
        XCTAssertEqual(SiteName.word(host: "docs.google.com", title: "Plan - Google Docs"), "Google")
        XCTAssertEqual(SiteName.word(host: "www.bbc.co.uk", title: nil), "Bbc")
        XCTAssertEqual(SiteName.word(host: "adsmanager.facebook.com", title: nil), "Facebook")
        XCTAssertEqual(SiteName.word(host: "localhost", title: nil), "Localhost")
        XCTAssertEqual(SiteName.word(host: nil, title: "x"), "Tab")
        XCTAssertTrue(SiteName.word(host: "averyveryveryverylongcompanyname.com", title: nil).count <= 18)
    }

    func testThemeColors() {
        XCTAssertEqual(CSSColor.parse("#1a73e8"), 0x1A73E8)
        XCTAssertEqual(CSSColor.parse(" #FFF "), 0xFFFFFF)
        XCTAssertEqual(CSSColor.parse("#1a73e8cc"), 0x1A73E8)
        XCTAssertEqual(CSSColor.parse("rgb(26, 115, 232)"), 0x1A73E8)
        XCTAssertEqual(CSSColor.parse("rgba(255,0,0,.5)"), 0xFF0000)
        XCTAssertEqual(CSSColor.parse("white"), 0xFFFFFF)
        XCTAssertNil(CSSColor.parse("#12"))
        XCTAssertNil(CSSColor.parse("var(--x)"))
        XCTAssertNil(CSSColor.parse(nil))
        XCTAssertTrue(CSSColor.isTint(0x1A73E8))
        XCTAssertFalse(CSSColor.isTint(0xFFFFFF))
        XCTAssertFalse(CSSColor.isTint(0x202124))
        XCTAssertFalse(CSSColor.isTint(0x888888))
    }

    func testTabNameReply() {
        let ok = Suggest.parseTabName(Data(#"{"ok":true,"name":"Research and planning tabs","emoji":"🔎"}"#.utf8))
        XCTAssertEqual(ok?.name.count, 18)
        XCTAssertEqual(ok?.emoji, "🔎")
        XCTAssertNil(ok?.cat)
        // a stray emoji is dropped, the name stays
        let noEmoji = Suggest.parseTabName(Data(#"{"ok":true,"name":"Research","emoji":"R"}"#.utf8))
        XCTAssertEqual(noEmoji?.name, "Research")
        XCTAssertNil(noEmoji?.emoji)
        XCTAssertNil(Suggest.parseTabName(Data(#"{"ok":true,"name":"","emoji":"🔎"}"#.utf8)))
        XCTAssertNil(Suggest.parseTabName(Data(#"{"ok":false,"name":"Research","emoji":"🔎"}"#.utf8)))
        XCTAssertEqual(Suggest.oneEmoji("👩‍💻 x"), "👩‍💻")
        XCTAssertEqual(Suggest.oneEmoji("❤️"), "❤️")
        XCTAssertNil(Suggest.oneEmoji("1"))
        XCTAssertNil(Suggest.oneEmoji(nil))
    }

    // A tab a page opens goes right after its opener (after the opener's earlier ones); pinned or grouped
    // openers send it to the end, outside every group.
    func testLinkTabGoesAfterItsOpener() {
        let s = slots([(nil, false), (nil, false), (nil, false)])
        XCTAssertEqual(TabStrip.linkTabIndex(s, opener: 0, openedBy: [false, false, false]), 1)
        XCTAssertEqual(TabStrip.linkTabIndex(s, opener: 2, openedBy: [false, false, false]), 3)
        // no opener, or one that is gone: the end
        XCTAssertEqual(TabStrip.linkTabIndex(s, opener: nil, openedBy: []), 3)
        XCTAssertEqual(TabStrip.linkTabIndex(s, opener: 7, openedBy: []), 3)
    }

    func testSeveralLinksKeepTheirOpeningOrder() {
        // opener at 0; tabs 1 and 2 were opened from it, 3 was not.
        var s = slots([(nil, false), (nil, false), (nil, false), (nil, false)])
        var by = [false, true, true, false]
        let i = TabStrip.linkTabIndex(s, opener: 0, openedBy: by)
        XCTAssertEqual(i, 3)
        s.insert(TabStrip.Slot(group: nil, pinned: false), at: i)
        by.insert(true, at: i)
        XCTAssertEqual(TabStrip.linkTabIndex(s, opener: 0, openedBy: by), 4)
        // the strip's order leaves the run where it is
        XCTAssertEqual(TabStrip.order(s, pinnedGroups: []), [0, 1, 2, 3, 4])
    }

    func testLinkFromPinnedGoesToTheEndAndFromGroupStaysInItsGroup() {
        let s = slots([(nil, true), ("g", false), ("g", false), (nil, false), ("h", false)])
        let none = [Bool](repeating: false, count: s.count)
        // pinned: the end, no group
        XCTAssertEqual(TabStrip.linkTabPlace(s, opener: 0, openedBy: none).index, 5)
        XCTAssertNil(TabStrip.linkTabPlace(s, opener: 0, openedBy: none).group)
        // Grouped, like pinned: the end of the strip, loose
        let p = TabStrip.linkTabPlace(s, opener: 1, openedBy: none)
        XCTAssertEqual(p.index, 5)
        XCTAssertNil(p.group)
        XCTAssertEqual(TabStrip.linkTabPlace(s, opener: 4, openedBy: none).index, 5)
        XCTAssertNil(TabStrip.linkTabPlace(s, opener: 4, openedBy: none).group)
        // a loose tab right before a group: the new tab sits between them, outside the group
        XCTAssertEqual(TabStrip.linkTabIndex(s, opener: 3, openedBy: none), 4)
        XCTAssertNil(TabStrip.linkTabPlace(s, opener: 3, openedBy: none).group)
        var after = s
        after.insert(TabStrip.Slot(group: nil, pinned: false), at: 4)
        XCTAssertTrue(TabStrip.isOrdered(after, pinnedGroups: []))
        // the one from a group, at the end and loose, keeps the strip ordered too
        var atEnd = s
        atEnd.insert(TabStrip.Slot(group: nil, pinned: false), at: p.index)
        XCTAssertTrue(TabStrip.isOrdered(atEnd, pinnedGroups: []))
    }

    func testLinksFromAGroupedTabGoToTheEndOutsideTheGroup() {
        // G0 (opener) g1 (opened by it) g2: the next one goes to the end, in no group.
        let s = slots([("g", false), ("g", false), ("g", false), (nil, false)])
        let p = TabStrip.linkTabPlace(s, opener: 0, openedBy: [false, true, false, false])
        XCTAssertEqual(p.index, 4)
        XCTAssertNil(p.group)
    }

    func testRunStopsAtAGroupOrAMovedTab() {
        // tab 1 came from the opener but was put into a group since: the run ends before it.
        let s = slots([(nil, false), ("g", false), (nil, false)])
        XCTAssertEqual(TabStrip.linkTabIndex(s, opener: 0, openedBy: [false, true, true]), 1)
    }

    func testLinkWantsNewTab() {
        XCTAssertTrue(TabStrip.linkWantsNewTab(command: true, button: 1))
        XCTAssertTrue(TabStrip.linkWantsNewTab(command: false, button: 4))
        XCTAssertFalse(TabStrip.linkWantsNewTab(command: false, button: 1))
        XCTAssertFalse(TabStrip.linkWantsNewTab(command: false, button: 0))
    }

    // The group's icon comes from its category, drawn from the app's own icon set.
    func testTabNameCarriesCategory() {
        let r = Suggest.parseTabName(Data(#"{"ok":true,"name":"Ads work","cat":" Ads "}"#.utf8))
        XCTAssertEqual(r?.name, "Ads work")
        XCTAssertEqual(r?.cat, "ads")
        XCTAssertNil(r?.emoji)
        XCTAssertNil(Suggest.parseTabName(Data(#"{"ok":true,"name":"Ads work","cat":"rocket"}"#.utf8))?.cat)
    }

    func testEveryCategoryHasAnIconOfTheSet() {
        let cats = ["code", "design", "ads", "analytics", "money", "shop", "mail", "chat", "social", "docs", "calendar", "travel",
                    "learn", "video", "music", "news", "cloud", "people", "search", "health", "home", "work", "folder"]
        XCTAssertEqual(Set(cats), Set(TabGroupCat.icons.keys))
        for c in cats {
            let icon = TabGroupCat.icon(c)
            XCTAssertNotNil(LiaIconData.icons[icon], "no icon \(icon) for \(c)")
            if c != "folder" { XCTAssertTrue(icon != TabGroupCat.fallback, c) }
        }
        XCTAssertEqual(TabGroupCat.icon("ADS"), "megaphone")
        // an old group (emoji only) or an unknown category: the folder
        XCTAssertEqual(TabGroupCat.icon(nil), "folder-simple")
        XCTAssertEqual(TabGroupCat.icon("🔎"), "folder-simple")
        XCTAssertNotNil(LiaIconData.icons[TabGroupCat.fallback])
    }

    func testTidyGroupsCarryCategory() {
        let json = #"{"ok":true,"groups":[{"name":"Code","icon":"chevron","cat":"code","tab_ids":["a","b"]},{"name":"Misc","tab_ids":["c","d"]}]}"#
        let g = Suggest.parseGroups(Data(json.utf8))
        XCTAssertEqual(g.map(\.cat), ["code", nil])
        XCTAssertEqual(Suggest.applicable(g, available: ["a", "b"]).first?.cat, "code")
    }

    func testSelectedTabShowsOnlyClose() {
        let sel = TabButtons.shown(selected: true, width: 220, sound: true, article: true)
        XCTAssertEqual(sel, TabButtons.Shown(speaker: false, reader: false))
        XCTAssertEqual(TabButtons.shown(selected: true, width: nil, sound: true, article: true), TabButtons.Shown(speaker: false, reader: false))
    }

    func testOtherTabsKeepSpeakerAndReaderOnlyWhenWide() {
        XCTAssertEqual(TabButtons.shown(selected: false, width: 200, sound: true, article: true), TabButtons.Shown(speaker: true, reader: true))
        XCTAssertEqual(TabButtons.shown(selected: false, width: 180, sound: false, article: true), TabButtons.Shown(speaker: false, reader: true))
        XCTAssertEqual(TabButtons.shown(selected: false, width: 179, sound: true, article: true), TabButtons.Shown(speaker: true, reader: false))
        XCTAssertEqual(TabButtons.shown(selected: false, width: 60, sound: false, article: true), TabButtons.Shown(speaker: false, reader: false))
        XCTAssertEqual(TabButtons.shown(selected: false, width: 220, sound: false, article: false), TabButtons.Shown(speaker: false, reader: false))
        XCTAssertEqual(TabButtons.shown(selected: false, width: nil, sound: false, article: true).reader, true)
    }

    // The key never lies over the close button of a narrow tab.
    func testKeyOnlyOnAWideSelectedTab() {
        XCTAssertTrue(TabButtons.showsKey(selected: true, width: 220))
        XCTAssertTrue(TabButtons.showsKey(selected: true, width: nil))
        XCTAssertTrue(TabButtons.showsKey(selected: true, width: TabButtons.keyMinWidth))
        XCTAssertFalse(TabButtons.showsKey(selected: true, width: 90))
        XCTAssertFalse(TabButtons.showsKey(selected: true, width: 56))
        XCTAssertFalse(TabButtons.showsKey(selected: false, width: 220))
    }

    // A collapsed group hides all its tabs; the tab in front leaves it.
    func testCollapsedGroupHidesEveryTabButPinned() {
        let s = slots([(nil, true), ("g", false), ("g", false), (nil, false)])
        XCTAssertEqual(TabStrip.hidden(s, collapsed: ["g"]), [false, true, true, false])
        XCTAssertEqual(TabStrip.hidden(s, collapsed: []), [false, false, false, false])
    }

    func testSelectionAfterCollapsePrefersRightThenLeft() {
        let s = slots([(nil, false), ("g", false), ("g", false), (nil, false)])
        XCTAssertEqual(TabStrip.selectionAfterCollapse(s, selected: 1, collapsed: ["g"]), 3)
        XCTAssertEqual(TabStrip.selectionAfterCollapse(s, selected: 2, collapsed: ["g"]), 3)
        let left = slots([(nil, false), ("g", false), ("g", false)])
        XCTAssertEqual(TabStrip.selectionAfterCollapse(left, selected: 2, collapsed: ["g"]), 0)
        // another collapsed group to the right is passed over
        let two = slots([(nil, false), ("g", false), ("h", false)])
        XCTAssertEqual(TabStrip.selectionAfterCollapse(two, selected: 1, collapsed: ["g", "h"]), 0)
        // a tab that still shows stays
        XCTAssertEqual(TabStrip.selectionAfterCollapse(s, selected: 0, collapsed: ["g"]), 0)
    }

    func testSelectionAfterCollapseFallsBackToPinnedThenNothing() {
        let pinned = slots([(nil, true), ("g", false)])
        XCTAssertEqual(TabStrip.selectionAfterCollapse(pinned, selected: 1, collapsed: ["g"]), 0)
        let only = slots([("g", false), ("g", false)])
        XCTAssertNil(TabStrip.selectionAfterCollapse(only, selected: 0, collapsed: ["g"]))
    }

    // The tab in front when its group collapsed stays by the folder after you leave it.
    func testKeptTabShowsAndDoesNotExpand() {
        let s = slots([(nil, false), ("g", false), ("g", false), (nil, false)])
        XCTAssertEqual(TabStrip.hidden(s, collapsed: ["g"], kept: [2]), [false, true, false, false])
        XCTAssertNil(TabStrip.groupToExpand(s, selected: 2, collapsed: ["g"], kept: [2]))
        XCTAssertEqual(TabStrip.groupToExpand(s, selected: 1, collapsed: ["g"], kept: [2]), "g")
        XCTAssertEqual(TabStrip.relativeTab(s, from: 0, forward: true, collapsed: ["g"], kept: [2]), 2)
        XCTAssertEqual(TabStrip.selectionAfterCollapse(s, selected: 2, collapsed: ["g"], kept: [2]), 2)
    }

    // A click on the closed folder after you left its kept tab hides it; the next click opens.
    func testFolderClick() {
        XCTAssertEqual(TabStrip.folderClick(collapsed: false, kept: nil, selected: "a"), .collapse)
        XCTAssertEqual(TabStrip.folderClick(collapsed: true, kept: "a", selected: "a"), .expand)
        XCTAssertEqual(TabStrip.folderClick(collapsed: true, kept: "a", selected: "b"), .hideKept)
        XCTAssertEqual(TabStrip.folderClick(collapsed: true, kept: "a", selected: nil), .hideKept)
        XCTAssertEqual(TabStrip.folderClick(collapsed: true, kept: nil, selected: "b"), .expand)
    }

    func testOneHome() {
        let s = slots([(nil, true), (nil, false), ("g", false), (nil, false), (nil, false)])
        // pinned and grouped start pages are not the Home
        XCTAssertEqual(TabStrip.homeTab(s, start: [true, true, true, false, true], selected: 3), 4)
        XCTAssertEqual(TabStrip.homeTab(s, start: [true, true, true, false, true], selected: 1), 1)
        XCTAssertNil(TabStrip.homeTab(s, start: [true, false, true, false, false], selected: 0))
    }

    func testGroupToExpand() {
        let s = slots([(nil, false), ("g", false), ("h", false)])
        XCTAssertEqual(TabStrip.groupToExpand(s, selected: 1, collapsed: ["g"]), "g")
        XCTAssertNil(TabStrip.groupToExpand(s, selected: 2, collapsed: ["g"]))
        XCTAssertNil(TabStrip.groupToExpand(s, selected: 0, collapsed: ["g"]))
        XCTAssertNil(TabStrip.groupToExpand(s, selected: nil, collapsed: ["g"]))
    }

    func testRelativeTabSkipsCollapsedGroups() {
        let s = slots([(nil, false), ("g", false), ("g", false), (nil, false)])
        XCTAssertEqual(TabStrip.relativeTab(s, from: 0, forward: true, collapsed: ["g"]), 3)
        XCTAssertEqual(TabStrip.relativeTab(s, from: 3, forward: false, collapsed: ["g"]), 0)
        XCTAssertEqual(TabStrip.relativeTab(s, from: 3, forward: true, collapsed: ["g"]), 0)
        XCTAssertEqual(TabStrip.relativeTab(s, from: 0, forward: true, collapsed: []), 1)
        XCTAssertNil(TabStrip.relativeTab(slots([(nil, false), ("g", false)]), from: 0, forward: true, collapsed: ["g"]))
    }

    func testArrangeSortsOnlyLooseTabsInTheirPlaces() {
        // pinned P, loose c, group g g, loose a, loose B
        let s = slots([(nil, true), (nil, false), ("g", false), ("g", false), (nil, false), (nil, false)])
        let keys = ["P", "c", "z", "y", "a", "B"]
        XCTAssertEqual(TabStrip.arranged(s, keys: keys), [0, 4, 2, 3, 5, 1])
        // equal keys keep their order
        let e = slots([(nil, false), (nil, false), (nil, false)])
        XCTAssertEqual(TabStrip.arranged(e, keys: ["b", "a", "b"]), [1, 0, 2])
    }

    func testSiteKeyGroupsOneSiteAndSendsEmptyLast() {
        let a = TabStrip.siteKey(host: "www.github.com", title: "Z")
        let b = TabStrip.siteKey(host: "github.com", title: "A")
        let c = TabStrip.siteKey(host: "apple.com", title: "Q")
        let none = TabStrip.siteKey(host: nil, title: "")
        XCTAssertTrue(c < b && b < a)
        XCTAssertTrue(a < none)
    }
}
