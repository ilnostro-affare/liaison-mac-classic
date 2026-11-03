import XCTest
import Foundation
@testable import Liaison

/// The screenshot card for the Mac's own screenshots (Shared/Core/ScreenshotWatch.swift).
final class ScreenshotWatchTests: XCTestCase {
    private let launch = Date(timeIntervalSince1970: 1_000_000)

    func testFreshOnlyAfterLaunchAndWithinSixtySeconds() {
        let now = launch.addingTimeInterval(100)
        XCTAssertTrue(ScreenshotWatch.isFresh(created: now.addingTimeInterval(-3), launchedAt: launch, now: now))
        XCTAssertTrue(ScreenshotWatch.isFresh(created: now.addingTimeInterval(-60), launchedAt: launch, now: now))
        XCTAssertFalse(ScreenshotWatch.isFresh(created: now.addingTimeInterval(-61), launchedAt: launch, now: now))
        // taken before the app started: an old file, even if found right away
        XCTAssertFalse(ScreenshotWatch.isFresh(created: launch.addingTimeInterval(-5), launchedAt: launch, now: launch.addingTimeInterval(1)))
    }

    func testShowNowWhenActiveOrJustActivated() {
        let now = launch.addingTimeInterval(60)
        let created = now.addingTimeInterval(-2)
        XCTAssertEqual(ScreenshotWatch.decide(created: created, launchedAt: launch, now: now, appActive: true, becameActiveAt: nil), .showNow)
        XCTAssertEqual(ScreenshotWatch.decide(created: created, launchedAt: launch, now: now, appActive: false, becameActiveAt: now.addingTimeInterval(-4)), .showNow)
        XCTAssertEqual(ScreenshotWatch.decide(created: created, launchedAt: launch, now: now, appActive: false, becameActiveAt: now.addingTimeInterval(-6)), .later)
        XCTAssertEqual(ScreenshotWatch.decide(created: created, launchedAt: launch, now: now, appActive: false, becameActiveAt: nil), .later)
        XCTAssertEqual(ScreenshotWatch.decide(created: launch.addingTimeInterval(-30), launchedAt: launch, now: now, appActive: true, becameActiveAt: nil), .ignore)
        XCTAssertEqual(ScreenshotWatch.decide(created: now.addingTimeInterval(-90), launchedAt: launch, now: launch.addingTimeInterval(200), appActive: true, becameActiveAt: nil), .ignore)
    }

    func testDeferredWaitsTwoMinutes() {
        let at = launch.addingTimeInterval(10)
        XCTAssertTrue(ScreenshotWatch.pendingStillValid(detectedAt: at, now: at.addingTimeInterval(119)))
        XCTAssertTrue(ScreenshotWatch.pendingStillValid(detectedAt: at, now: at.addingTimeInterval(120)))
        XCTAssertFalse(ScreenshotWatch.pendingStillValid(detectedAt: at, now: at.addingTimeInterval(121)))
    }

    func testCreatedDateIsNewest() {
        let a = launch, b = launch.addingTimeInterval(5)
        XCTAssertEqual(ScreenshotWatch.createdDate([a, nil, b]), b)
        XCTAssertNil(ScreenshotWatch.createdDate([nil, nil]))
    }

    func testClipboardPictureFromOutside() {
        // A copied picture alone is never a screenshot (Preview, a web page, \u{2318}\u{2303}\u{21E7}4 all put a plain PNG)
        XCTAssertFalse(ScreenshotWatch.clipboardShows(types: ["public.png", "public.tiff"], changeCount: 5, lastSeen: 4, ownChangeCount: nil))
        XCTAssertFalse(ScreenshotWatch.clipboardShows(types: ["public.png"], changeCount: 5, lastSeen: 4, ownChangeCount: nil))
        XCTAssertTrue(ScreenshotWatch.clipboardScreenshotMarkers.isEmpty)
        XCTAssertTrue(ScreenshotWatch.clipboardHasImage(types: ["public.png"]))
        XCTAssertFalse(ScreenshotWatch.clipboardHasImage(types: ["public.utf8-plain-text"]))
        // only a real marker (none known yet) would let it through
        XCTAssertTrue(ScreenshotWatch.clipboardShows(types: ["public.png", "x.marker"], changeCount: 5, lastSeen: 4, ownChangeCount: nil, markers: ["x.marker"]))
        XCTAssertFalse(ScreenshotWatch.clipboardShows(types: ["x.marker"], changeCount: 5, lastSeen: 4, ownChangeCount: nil, markers: ["x.marker"]))
        // nothing changed, or never looked at yet
        XCTAssertFalse(ScreenshotWatch.clipboardShows(types: ["public.png"], changeCount: 5, lastSeen: 5, ownChangeCount: nil))
        XCTAssertFalse(ScreenshotWatch.clipboardShows(types: ["public.png"], changeCount: 5, lastSeen: nil, ownChangeCount: nil))
        // text, or a copied file (Finder puts an icon picture next to the file URL)
        XCTAssertFalse(ScreenshotWatch.clipboardShows(types: ["public.utf8-plain-text"], changeCount: 5, lastSeen: 4, ownChangeCount: nil))
        XCTAssertFalse(ScreenshotWatch.clipboardShows(types: ["public.file-url", "public.tiff"], changeCount: 5, lastSeen: 4, ownChangeCount: nil))
        // Copy Image on a web page: the picture comes with its address and HTML
        XCTAssertFalse(ScreenshotWatch.clipboardShows(types: ["public.tiff", "public.url", "public.html"], changeCount: 5, lastSeen: 4, ownChangeCount: nil))
        XCTAssertFalse(ScreenshotWatch.clipboardShows(types: ["public.tiff", "public.url", "x.marker"], changeCount: 5, lastSeen: 4, ownChangeCount: nil, markers: ["x.marker"]))
    }

    func testOwnCopyIsIgnored() {
        XCTAssertTrue(ScreenshotWatch.isOwnWrite(types: ["public.tiff", ScreenshotWatch.ownMarkerType], changeCount: 9, ownChangeCount: nil))
        XCTAssertTrue(ScreenshotWatch.isOwnWrite(types: ["public.tiff"], changeCount: 9, ownChangeCount: 9))
        XCTAssertFalse(ScreenshotWatch.isOwnWrite(types: ["public.tiff"], changeCount: 10, ownChangeCount: 9))
        XCTAssertFalse(ScreenshotWatch.clipboardShows(types: ["public.tiff", ScreenshotWatch.ownMarkerType], changeCount: 9, lastSeen: 8, ownChangeCount: nil))
        XCTAssertFalse(ScreenshotWatch.clipboardShows(types: ["public.tiff", "m"], changeCount: 9, lastSeen: 8, ownChangeCount: 9, markers: ["m"]))
    }

    func testFolder() {
        XCTAssertEqual(ScreenshotWatch.folderPath(location: nil, home: "/Users/e"), "/Users/e/Desktop")
        XCTAssertEqual(ScreenshotWatch.folderPath(location: " ", home: "/Users/e"), "/Users/e/Desktop")
        XCTAssertEqual(ScreenshotWatch.folderPath(location: "~/Pictures/Shots", home: "/Users/e"), "/Users/e/Pictures/Shots")
        XCTAssertEqual(ScreenshotWatch.folderPath(location: "/Volumes/X/Shots", home: "/Users/e"), "/Volumes/X/Shots")
        XCTAssertTrue(ScreenshotWatch.insideHome("/Users/e/Desktop", home: "/Users/e"))
        XCTAssertFalse(ScreenshotWatch.insideHome("/Users/eve/Desktop", home: "/Users/e"))
        XCTAssertFalse(ScreenshotWatch.insideHome("/Volumes/X", home: "/Users/e"))
        XCTAssertEqual(ScreenshotWatch.folderPath(location: "~/Pictures/Shots/", home: "/Users/e"), "/Users/e/Pictures/Shots")
        XCTAssertEqual(ScreenshotWatch.folderPath(location: "file:///Users/e/Pictures/My%20Shots/", home: "/Users/e"), "/Users/e/Pictures/My Shots")
        XCTAssertEqual(ScreenshotWatch.folderPath(location: "/", home: "/Users/e"), "/")
    }

    func testReasonsForTheLog() {
        XCTAssertNil(ScreenshotWatch.fileRejectReason(name: "Any.png", markedCapture: true))
        XCTAssertNil(ScreenshotWatch.fileRejectReason(name: "Screenshot 2026-10-22 at 10.31.05.png", markedCapture: false))
        XCTAssertEqual(ScreenshotWatch.fileRejectReason(name: ".Screenshot x.png", markedCapture: true), "hidden")
        XCTAssertEqual(ScreenshotWatch.fileRejectReason(name: "clip.mov", markedCapture: true), "not a picture")
        XCTAssertNotNil(ScreenshotWatch.fileRejectReason(name: "holiday.png", markedCapture: false))
        let now = launch.addingTimeInterval(500)
        XCTAssertNil(ScreenshotWatch.staleReason(created: now.addingTimeInterval(-10), launchedAt: launch, now: now))
        XCTAssertEqual(ScreenshotWatch.staleReason(created: launch.addingTimeInterval(-10), launchedAt: launch, now: now), "written before Liaison started")
        XCTAssertNotNil(ScreenshotWatch.staleReason(created: now.addingTimeInterval(-61), launchedAt: launch, now: now))
        XCTAssertNotNil(ScreenshotWatch.staleReason(created: now.addingTimeInterval(61), launchedAt: launch, now: now))
        // the reason and the decision agree
        for age in [-70.0, -10, 0, 30, 59, 61, 120] {
            let c = now.addingTimeInterval(-age)
            XCTAssertEqual(ScreenshotWatch.staleReason(created: c, launchedAt: launch, now: now) == nil,
                           ScreenshotWatch.isFresh(created: c, launchedAt: launch, now: now), "\(age)")
        }
    }

    func testRecheckWindow() {
        XCTAssertTrue(ScreenshotWatch.shouldRecheck(firstSeen: launch, now: launch.addingTimeInterval(5)))
        XCTAssertTrue(ScreenshotWatch.shouldRecheck(firstSeen: launch, now: launch.addingTimeInterval(20)))
        XCTAssertFalse(ScreenshotWatch.shouldRecheck(firstSeen: launch, now: launch.addingTimeInterval(21)))
        XCTAssertFalse(ScreenshotWatch.shouldRecheck(firstSeen: launch, now: launch.addingTimeInterval(-1)))
    }

    // The folder watch.

    func testScreenshotNamesInManyLanguages() {
        let yes = [
            "Screenshot 2026-10-22 at 10.31.05.png", "Screen Shot 2019-03-01 at 9.02.11 PM.png", "Screenshot.png",
            "Screenshot 2026-10-22 at 10.31.05 (2).png", "screenshot 2026-10-22 at 10.31.05.PNG",
            "\u{421}\u{43D}\u{438}\u{43C}\u{43E}\u{43A} \u{44D}\u{43A}\u{440}\u{430}\u{43D}\u{430} 2026-10-22 \u{432} 10.31.05.png", "Bildschirmfoto 2026-10-22 um 10.31.05.png",
            "Capture d\u{2019}\u{E9}cran 2026-10-22 \u{E0} 10.31.05.png", "Capture d'\u{E9}cran 2026-10-22 \u{E0} 10.31.05.png",
            "Captura de pantalla 2026-10-22 a las 10.31.05.jpg", "\u{30B9}\u{30AF}\u{30EA}\u{30FC}\u{30F3}\u{30B7}\u{30E7}\u{30C3}\u{30C8} 2026-10-22 10.31.05.heic",
            "\u{622A}\u{5C4F}2026-10-22 10.31.05.png", "\u{C2A4}\u{D06C}\u{B9B0}\u{C0F7} 2026-10-22 \u{C624}\u{C804} 10.31.05.png", "Zrzut ekranu 2026-10-22 o 10.31.05.tiff",
        ]
        for n in yes { XCTAssertTrue(ScreenshotWatch.screenshotName(n), n) }
        let no = [
            "Screenshot 2026-10-22 at 10.31.05.mov", "Screen Recording 2026-10-22 at 10.31.05.mov", "holiday.png",
            // Review: a date and a time alone are not a screenshot's (it waits for the capture mark)
            "WhatsApp Image 2026-10-22 at 10.31.05.jpeg", "Xyzzy 2026-10-22 kl. 10.31.05.png",
            "report.pdf", ".Screenshot 2026-10-22 at 10.31.05.png", "Screenshot 2026-10-22 at 10.31.05.png.sb-1a2b",
            "IMG_2041.HEIC", "Invoice 2026-10-22.png",
        ]
        for n in no { XCTAssertFalse(ScreenshotWatch.screenshotName(n), n) }
    }

    func testCustomScreenshotName() {
        XCTAssertFalse(ScreenshotWatch.screenshotName("Shot.png"))
        XCTAssertTrue(ScreenshotWatch.screenshotName("Shot.png", customName: "Shot"))
        XCTAssertTrue(ScreenshotWatch.screenshotName("Shot 3.png", customName: " Shot "))
        XCTAssertFalse(ScreenshotWatch.screenshotName("Other.png", customName: "Shot"))
    }

    func testMarkedCaptureWinsOverName() {
        XCTAssertTrue(ScreenshotWatch.isScreenshotFile(name: "Any name.png", markedCapture: true))
        XCTAssertFalse(ScreenshotWatch.isScreenshotFile(name: "Any name.png", markedCapture: false))
        XCTAssertTrue(ScreenshotWatch.isScreenshotFile(name: "Screenshot 2026-10-22 at 10.31.05.png", markedCapture: false))
        // never a movie or a hidden temporary, whatever the mark
        XCTAssertFalse(ScreenshotWatch.isScreenshotFile(name: "Screen Recording.mov", markedCapture: true))
        XCTAssertFalse(ScreenshotWatch.isScreenshotFile(name: ".tmp-shot.png", markedCapture: true))
    }

    func testDirectoryDiff() {
        let before: Set<String> = ["a.txt", "Screenshot 1.png"]
        XCTAssertEqual(ScreenshotWatch.newEntries(previous: before, current: ["a.txt", "Screenshot 1.png"]), [])
        // a temporary renamed to its final name: only the final name is new, the hidden one never counts
        XCTAssertEqual(ScreenshotWatch.newEntries(previous: before, current: ["a.txt", ".Screenshot 2.png.XXXX"]), [])
        XCTAssertEqual(ScreenshotWatch.newEntries(previous: before.union([".Screenshot 2.png.XXXX"]), current: ["a.txt", "Screenshot 2.png", "Screenshot 1.png"]), ["Screenshot 2.png"])
        // a removed file is not new
        XCTAssertEqual(ScreenshotWatch.newEntries(previous: before, current: ["b.png", "a.txt"]), ["b.png"])
    }

    func testSizeSettledAndDedup() {
        XCTAssertFalse(ScreenshotWatch.sizeSettled(previous: nil, current: 100))
        XCTAssertFalse(ScreenshotWatch.sizeSettled(previous: 0, current: 0))
        XCTAssertFalse(ScreenshotWatch.sizeSettled(previous: 50, current: 100))
        XCTAssertTrue(ScreenshotWatch.sizeSettled(previous: 100, current: 100))
        XCTAssertTrue(ScreenshotWatch.alreadySeen(path: "/d/a.png", fileID: nil, seenPaths: ["/d/a.png"], seenIDs: []))
        XCTAssertTrue(ScreenshotWatch.alreadySeen(path: "/d/renamed.png", fileID: 7, seenPaths: ["/d/a.png"], seenIDs: [7]))
        XCTAssertFalse(ScreenshotWatch.alreadySeen(path: "/d/b.png", fileID: 8, seenPaths: ["/d/a.png"], seenIDs: [7]))
    }
}
