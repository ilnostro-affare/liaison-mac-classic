import Foundation

/// "the screenshot card doesn't appear when I take screenshots". The card (WindowScreenshot.swift)
/// also opens for the Mac's own screenshots: a file the system marked as a screen capture (\u{2318}\u{21E7}3/4/5).
/// The decisions are here, pure; App/Workspace/ScreenshotWatcher.swift watches the screenshot folder (and Spotlight)
/// and shows the card.
/// (after dcf82d7): "any copied picture becomes a screenshot". A picture on the clipboard carries
/// nothing documented that says it came from the screenshot keys (\u{2318}\u{2303}\u{21E7}4 puts a plain PNG, the same as
/// Copy Image in Preview), so the clipboard no longer opens the card unless its types carry one of
/// `clipboardScreenshotMarkers`, which is empty until a real marker is seen in the product's log (the watcher logs the types).
enum ScreenshotWatch {
    /// A screenshot file found later than this after it was written is an old one (a copied folder, a restore).
    /// 60 s (was 15): with the floating thumbnail macOS writes the file only when the thumbnail goes (about 5 s, longer
    /// while the pointer rests on it), and Spotlight's import, the second way a file is found, can lag behind that.
    static let maxAge: TimeInterval = 60
    /// A new picture in the folder that is not (yet) marked and not named like a screenshot is looked at again for this
    /// long: the system can add `kMDItemIsScreenCapture` after the file appears.
    static let recheckWindow: TimeInterval = 20
    /// Liaison counts as "in front" this long after it became active (the screenshot UI takes the front for a moment).
    static let activeGrace: TimeInterval = 5
    /// A screenshot taken while another app was in front waits this long for Liaison to come back.
    static let deferWindow: TimeInterval = 120

    enum Decision: Equatable { case showNow, later, ignore }

    /// A screenshot file is ours to show: written after the app started, and found within `maxAge` of being written.
    static func isFresh(created: Date, launchedAt: Date, now: Date) -> Bool {
        guard created >= launchedAt.addingTimeInterval(-1) else { return false }
        let age = now.timeIntervalSince(created)
        return age <= maxAge && age >= -maxAge   // a clock a few seconds ahead still counts
    }

    /// Liaison is in front, or came to the front within `activeGrace`.
    static func inFront(appActive: Bool, becameActiveAt: Date?, now: Date) -> Bool {
        if appActive { return true }
        guard let at = becameActiveAt else { return false }
        return now.timeIntervalSince(at) <= activeGrace && now >= at
    }

    /// What to do with a screenshot file just found.
    static func decide(created: Date, launchedAt: Date, now: Date, appActive: Bool, becameActiveAt: Date?) -> Decision {
        guard isFresh(created: created, launchedAt: launchedAt, now: now) else { return .ignore }
        return inFront(appActive: appActive, becameActiveAt: becameActiveAt, now: now) ? .showNow : .later
    }

    /// A screenshot kept for later is still shown when Liaison comes to the front at `now`.
    static func pendingStillValid(detectedAt: Date, now: Date) -> Bool {
        let wait = now.timeIntervalSince(detectedAt)
        return wait >= 0 && wait <= deferWindow
    }

    /// The newest of the dates Spotlight gives (the file is written when the floating thumbnail goes, after the
    /// capture itself); nil when it gives none.
    static func createdDate(_ dates: [Date?]) -> Date? {
        dates.compactMap { $0 }.max()
    }

    // MARK: - Clipboard

    /// Marks a picture Liaison itself put on the clipboard (the card's Copy), so it never opens the card again.
    static let ownMarkerType = "com.liaisone.mac.own-copy"
    /// The forms a screenshot on the clipboard comes in.
    static let imageTypes: Set<String> = ["public.png", "public.tiff", "NeXT TIFF v4.0 pasteboard type"]
    static let fileURLTypes: Set<String> = ["public.file-url", "NSFilenamesPboardType"]
    /// Pasteboard types that only the screenshot keys put. None is known: empty, so the clipboard never
    /// opens the card. Add one only after seeing it in `log show` for \u{2318}\u{2303}\u{21E7}4 and not for a copied image.
    static let clipboardScreenshotMarkers: Set<String> = []
    /// A picture that came with these was copied from a page or a document (a browser's Copy Image puts the address
    /// and HTML next to it), not taken with the screenshot keys, which put only the picture.
    static let notScreenshotTypes: Set<String> = [
        "public.url", "Apple URL pasteboard type", "public.html", "Apple HTML pasteboard type", "com.apple.webarchive",
        "Apple Web Archive pasteboard type", "public.rtf", "com.apple.flat-rtfd", "public.utf8-plain-text", "NSStringPboardType",
    ]

    /// The pasteboard's types say Liaison wrote it.
    static func isOwnWrite(types: [String], changeCount: Int, ownChangeCount: Int?) -> Bool {
        if types.contains(ownMarkerType) { return true }
        if let own = ownChangeCount, own == changeCount { return true }
        return false
    }

    /// The clipboard holds a picture (whatever put it there): only logged, never shown on its own.
    static func clipboardHasImage(types: [String]) -> Bool {
        types.contains(where: { imageTypes.contains($0) })
    }

    /// The clipboard changed since it was last looked at and now holds a picture that is not a file, not ours, and
    /// carries a screenshot marker. With `markers` empty (the default) this is never true: a copied picture alone is
    /// not a screenshot.
    static func clipboardShows(types: [String], changeCount: Int, lastSeen: Int?, ownChangeCount: Int?,
                               markers: Set<String> = clipboardScreenshotMarkers) -> Bool {
        guard let last = lastSeen, changeCount != last else { return false }
        if isOwnWrite(types: types, changeCount: changeCount, ownChangeCount: ownChangeCount) { return false }
        if types.contains(where: { fileURLTypes.contains($0) || notScreenshotTypes.contains($0) }) { return false }
        guard types.contains(where: { markers.contains($0) }) else { return false }
        return clipboardHasImage(types: types)
    }

    // MARK: - The folder

    /// Where macOS saves screenshots: `defaults read com.apple.screencapture location` (with ~ expanded), else Desktop.
    /// The value can also be a file URL; a trailing slash is dropped.
    static func folderPath(location: String?, home: String) -> String {
        var raw = (location ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if raw.hasPrefix("file://"), let u = URL(string: raw), u.isFileURL { raw = u.path }
        while raw.count > 1, raw.hasSuffix("/") { raw.removeLast() }
        if raw.isEmpty { return (home as NSString).appendingPathComponent("Desktop") }
        if raw == "~" { return home }
        if raw.hasPrefix("~/") { return (home as NSString).appendingPathComponent(String(raw.dropFirst(2))) }
        return raw
    }

    /// The folder is inside the home folder (then the home scope already covers it).
    static func insideHome(_ path: String, home: String) -> Bool {
        let h = home.hasSuffix("/") ? home : home + "/"
        return path == home || path.hasPrefix(h)
    }

    // MARK: - Files in the folder

    /// The picture formats screencapture writes (`defaults write com.apple.screencapture type ...`).
    static let imageExtensions: Set<String> = ["png", "jpg", "jpeg", "heic", "heif", "tif", "tiff"]

    /// What the system calls a screenshot file, per language of macOS (the start of the name, before the date).
    /// Matched case-insensitively and with the apostrophe folded, so "Capture d\u{2019}\u{E9}cran" and "Capture d'\u{E9}cran" both count.
    static let namePrefixes: [String] = [
        "Screenshot", "Screen Shot",
        "\u{421}\u{43D}\u{438}\u{43C}\u{43E}\u{43A} \u{44D}\u{43A}\u{440}\u{430}\u{43D}\u{430}", "\u{417}\u{43D}\u{456}\u{43C}\u{43E}\u{43A} \u{435}\u{43A}\u{440}\u{430}\u{43D}\u{430}", "\u{417}\u{43D}\u{456}\u{43C}\u{43E}\u{43A} \u{435}\u{43A}\u{440}\u{430}\u{43D}\u{443}", "\u{417}\u{434}\u{44B}\u{43C}\u{430}\u{43A} \u{44D}\u{43A}\u{440}\u{430}\u{43D}\u{430}",
        "Bildschirmfoto", "Capture d\u{2019}\u{E9}cran", "Captura de pantalla", "Captura de Tela", "Captura de ecr\u{E3}",
        "Captura d\u{2019}ecran", "Istantanea", "Schermafbeelding", "Sk\u{E4}rmavbild", "Skjermbilde", "Sk\u{E6}rmbillede",
        "N\u{E4}ytt\u{F6}kuva", "Zrzut ekranu", "Sn\u{ED}mek obrazovky", "Sn\u{ED}mka obrazovky", "K\u{E9}perny\u{151}fot\u{F3}", "K\u{E9}perny\u{151}k\u{E9}p",
        "Captur\u{103} de ecran", "Ekran Resmi", "Ekran g\u{F6}r\u{FC}nt\u{FC}s\u{FC}", "\u{3A3}\u{3C4}\u{3B9}\u{3B3}\u{3BC}\u{3B9}\u{3CC}\u{3C4}\u{3C5}\u{3C0}\u{3BF} \u{3BF}\u{3B8}\u{3CC}\u{3BD}\u{3B7}\u{3C2}", "\u{5E6}\u{5D9}\u{5DC}\u{5D5}\u{5DD} \u{5DE}\u{5E1}\u{5DA}", "\u{644}\u{642}\u{637}\u{629} \u{634}\u{627}\u{634}\u{629}",
        "\u{30B9}\u{30AF}\u{30EA}\u{30FC}\u{30F3}\u{30B7}\u{30E7}\u{30C3}\u{30C8}", "\u{622A}\u{5C4F}", "\u{622A}\u{5716}", "\u{87A2}\u{5E55}\u{622A}\u{5716}", "\u{5C4F}\u{5E55}\u{5FEB}\u{7167}", "\u{C2A4}\u{D06C}\u{B9B0}\u{C0F7}", "\u{E20}\u{E32}\u{E1E}\u{E2B}\u{E19}\u{E49}\u{E32}\u{E08}\u{E2D}", "\u{1EA2}nh m\u{E0}n h\u{EC}nh",
        "Tangkapan Layar", "Cuplikan layar", "Snimka zaslona", "Snimak ekrana", "Posnetek zaslona", "Ekr\u{101}nuz\u{146}\u{113}mums",
        "Ekraanipilt", "Ekrano nuotrauka", "\u{938}\u{94D}\u{915}\u{94D}\u{930}\u{940}\u{928}\u{936}\u{949}\u{91F}",
    ]

    /// The file has a picture's extension.
    static func isImageName(_ name: String) -> Bool {
        let ext = (name as NSString).pathExtension.lowercased()
        return imageExtensions.contains(ext)
    }

    private static func fold(_ s: String) -> String {
        s.precomposedStringWithCanonicalMapping.replacingOccurrences(of: "\u{2019}", with: "'").lowercased()
    }

    /// The name is a system screenshot's: it starts with the system's word in any language, or with the custom
    /// `defaults write com.apple.screencapture name ...`, or it carries the date and time the system puts in it
    /// (" at 10.31.05", " 10.31.05", " um 10.31.05"). Hidden and partial files never count.
    static func screenshotName(_ name: String, customName: String? = nil) -> Bool {
        guard !name.hasPrefix("."), isImageName(name) else { return false }
        let n = fold(name)
        var prefixes = namePrefixes
        if let c = customName?.trimmingCharacters(in: .whitespacesAndNewlines), !c.isEmpty { prefixes.insert(c, at: 0) }
        // Review: the date-and-time stamp alone is no longer enough ("WhatsApp Image at
        // 10.31.05.jpeg" carries one too); a name without the system's word waits for the capture mark
        return prefixes.contains(where: { n.hasPrefix(fold($0)) })
    }

    /// "YYYY-MM-DD" followed (after a word or nothing) by a time "H.MM.SS" / "HH.MM.SS" (or with ":" / "-").
    static func hasCaptureStamp(_ name: String) -> Bool {
        let pattern = #"(19|20)\d{2}-\d{2}-\d{2}\D{0,12}?\d{1,2}[.:-]\d{2}[.:-]\d{2}"#
        guard let re = try? NSRegularExpression(pattern: pattern) else { return false }
        return re.firstMatch(in: name, range: NSRange(name.startIndex..., in: name)) != nil
    }

    /// A new file in the folder is a screenshot: a picture, and the system marked it a capture (the
    /// `kMDItemIsScreenCapture` attribute, read off the file or from Spotlight), or, while that is not there yet,
    /// its name is a screenshot's.
    static func isScreenshotFile(name: String, markedCapture: Bool, customName: String? = nil) -> Bool {
        guard !name.hasPrefix("."), isImageName(name) else { return false }
        return markedCapture || screenshotName(name, customName: customName)
    }

    /// The entries of the folder that were not there before, hidden ones left out, in name order. A file written as a
    /// temporary and renamed shows up here under its final name.
    static func newEntries(previous: Set<String>, current: [String]) -> [String] {
        Array(Set(current).subtracting(previous)).filter { !$0.hasPrefix(".") }.sorted()
    }

    /// The file has stopped growing: two looks in a row gave the same non-zero size.
    static func sizeSettled(previous: Int?, current: Int) -> Bool {
        guard let p = previous else { return false }
        return current > 0 && p == current
    }

    /// Why a file is or is not a screenshot, for the log (nil: it is one).
    static func fileRejectReason(name: String, markedCapture: Bool, customName: String? = nil) -> String? {
        if name.hasPrefix(".") { return "hidden" }
        if !isImageName(name) { return "not a picture" }
        if markedCapture { return nil }
        if screenshotName(name, customName: customName) { return nil }
        return "not marked kMDItemIsScreenCapture and not a screenshot name"
    }

    /// Why a screenshot file is not shown (nil: shown now or later), for the log.
    static func staleReason(created: Date, launchedAt: Date, now: Date) -> String? {
        if created < launchedAt.addingTimeInterval(-1) { return "written before Liaison started" }
        let age = now.timeIntervalSince(created)
        if age > maxAge { return "older than \(Int(maxAge)) s (\(Int(age)) s)" }
        if age < -maxAge { return "dated in the future (\(Int(-age)) s)" }
        return nil
    }

    /// An unmarked, unnamed picture first seen at `firstSeen` is still looked at again at `now`.
    static func shouldRecheck(firstSeen: Date, now: Date) -> Bool {
        let d = now.timeIntervalSince(firstSeen)
        return d >= 0 && d <= recheckWindow
    }

    /// A file found in the folder, deduplicated by path and by file identity (a rename keeps the inode).
    static func alreadySeen(path: String, fileID: UInt64?, seenPaths: Set<String>, seenIDs: Set<UInt64>) -> Bool {
        if seenPaths.contains(path) { return true }
        if let id = fileID, seenIDs.contains(id) { return true }
        return false
    }
}
