import XCTest
import Foundation
#if canImport(Liaison)
@testable import Liaison
#endif

/// Storage > Uploads is the one place for every file (Shared/Core/Uploads.swift, AttachRoute.swift ComposerLane).
final class UploadsTests: XCTestCase {
    private let MB = 1024 * 1024

    func testComposerTakesAnyFileUpTo100MB() {
        XCTAssertEqual(ComposerLane.of(name: "archive.zip", bytes: 5 * MB), .file)
        XCTAssertEqual(ComposerLane.of(name: "song.mp3", bytes: 9 * MB), .file)
        XCTAssertEqual(ComposerLane.of(name: "main.swift", bytes: 2_000), .file)
        XCTAssertEqual(ComposerLane.of(name: "notes", bytes: 10), .file)
        XCTAssertEqual(ComposerLane.of(name: "deck.pptx", bytes: 40 * MB), .file)
        XCTAssertEqual(ComposerLane.of(name: "exact.bin", bytes: 100 * MB), .file)
        XCTAssertEqual(ComposerLane.of(name: "huge.bin", bytes: 100 * MB + 1), .refuse("Over 100 MB"))
        XCTAssertEqual(ComposerLane.of(name: "huge.pdf", bytes: 101 * MB), .refuse("Over 100 MB"))
        // unchanged lanes
        XCTAssertEqual(ComposerLane.of(name: "report.pdf", bytes: 3 * MB), .read)
        XCTAssertEqual(ComposerLane.of(name: "clip.mp4", bytes: 150 * MB), .storage)
        XCTAssertEqual(ComposerLane.of(name: "photo.heic", bytes: 3 * MB), .readAsPNG)
    }

    private func json(_ s: String) -> Data { Data(s.utf8) }

    func testIndexParsesBothStoresAndDropsForeignKeys() {
        let d = json("""
        {"ok":true,"hidden":["m/uploads/v.mp4"],"uploads":[
          {"key":"ai/m/att/1__a.pdf","store":"att","name":"a.pdf","mime":"application/pdf","bytes":2048,"kind":"pdf","chat":true,"at":20,"url":"/intelligence/plot?k=1","read":true},
          {"key":"m/uploads/abc.jpg","store":"media","name":"ad.jpg","mime":"image/jpeg","bytes":9,"kind":"image","at":10,"url":"https://api.liaisone.com/meta/upload-asset?k"},
          {"key":"elsewhere/x.png","store":"att","name":"x.png"},
          {"key":"ai/m/att/2__z.zip","store":"att","name":"z.zip","kind":"archive","at":30,"read":false}
        ]}
        """)
        guard let r = UploadsIndex.parse(d, base: "https://ai.liaisone.com") else { return XCTFail("parse") }
        XCTAssertEqual(r.entries.map(\.key), ["ai/m/att/1__a.pdf", "m/uploads/abc.jpg", "ai/m/att/2__z.zip"])
        XCTAssertEqual(r.entries[0].url, "https://ai.liaisone.com/intelligence/plot?k=1")
        XCTAssertEqual(r.entries[1].url, "https://api.liaisone.com/meta/upload-asset?k")
        XCTAssertFalse(r.entries[2].read)
        XCTAssertEqual(r.hidden, ["m/uploads/v.mp4"])
        XCTAssertNil(UploadsIndex.parse(json("{\"ok\":false}")))
    }

    func testMergeIndexFirstThenLibraryMinusHidden() {
        let index = [
            UploadEntry(key: "ai/m/att/1__a.pdf", store: "att", name: "a.pdf", mime: "application/pdf", bytes: 10, kind: "pdf", at: 1),
            UploadEntry(key: "ai/m/att/2__b.png", store: "att", name: "b.png", mime: "image/png", bytes: 10, kind: "image", at: 3, url: "https://x/b"),
            UploadEntry(key: "m/uploads/c.jpg", store: "media", name: "file", mime: "image/jpeg", bytes: 10, kind: "image", at: 2),
        ]
        let library = [
            MediaItem(id: "m/uploads/c.jpg", source: .upload, name: "creative.jpg", preview: "https://api/c", seconds: nil),
            MediaItem(id: "m/uploads/old.png", source: .upload, name: "old.png", preview: "https://api/old", seconds: nil),
            MediaItem(id: "m/uploads/v.mp4", source: .upload, name: "clip.mp4", preview: "https://api/v", seconds: nil),
        ]
        let out = UploadsIndex.merge(index: index, library: library, hidden: ["m/uploads/v.mp4"])
        XCTAssertEqual(out.map(\.id), ["ai/m/att/2__b.png", "m/uploads/c.jpg", "ai/m/att/1__a.pdf", "m/uploads/old.png"])
        XCTAssertEqual(out[0].source, .file)
        XCTAssertEqual(out[0].preview, "https://x/b")
        XCTAssertNil(out[2].preview, "a document has no picture")
        XCTAssertEqual(out[1].source, .upload, "a library file stays an ad-usable upload")
        XCTAssertEqual(out[1].name, "creative.jpg", "the library's name fills an index row without one")
        XCTAssertEqual(out[1].preview, "https://api/c")
        XCTAssertFalse(out.contains { $0.id == "m/uploads/v.mp4" }, "deleted from Uploads: not shown")
        // the same key twice in the index is one tile
        let twice = UploadsIndex.merge(index: [index[0], index[0]], library: [], hidden: [])
        XCTAssertEqual(twice.count, 1)
    }

    func testInputFileFromUploadsTravelsAsAttachment() {
        let pdf = UploadEntry(key: "ai/m/att/1__a.pdf", store: "att", name: "a.pdf", mime: "application/pdf", bytes: 2048, kind: "pdf", url: "https://x/a").mediaItem
        XCTAssertEqual(pdf.attachment?.key, "ai/m/att/1__a.pdf")
        XCTAssertEqual(pdf.attachment?.kind, "file")
        XCTAssertEqual(pdf.attachment?.url, "https://x/a")
        let png = UploadEntry(key: "ai/m/att/2__b.png", store: "att", name: "b.png", mime: "image/png", bytes: 2048, kind: "image").mediaItem
        XCTAssertEqual(png.attachment?.kind, "image")
        let bigPng = UploadEntry(key: "ai/m/att/3__c.png", store: "att", name: "c.png", mime: "image/png", bytes: 11 * MB, kind: "image").mediaItem
        XCTAssertEqual(bigPng.attachment?.kind, "file", "a picture the model does not open as one is a file")
        let lib = UploadEntry(key: "m/uploads/c.jpg", store: "media", name: "c.jpg", mime: "image/jpeg", bytes: 9, kind: "image").mediaItem
        XCTAssertNil(lib.attachment, "a library file travels as its creative marker")
        XCTAssertEqual(lib.marker, "[attached_creative r2_key=m/uploads/c.jpg]")
    }

    func testDeleteAnswer() {
        let kept = UploadDeleteAnswer.parse(json("{\"ok\":true,\"kept\":true,\"delete_bytes\":false}"))
        XCTAssertTrue(kept.ok); XCTAssertTrue(kept.kept); XCTAssertFalse(kept.deleteBytes)
        let gone = UploadDeleteAnswer.parse(json("{\"ok\":true,\"kept\":false,\"delete_bytes\":true}"))
        XCTAssertTrue(gone.deleteBytes)
        XCTAssertFalse(UploadDeleteAnswer.parse(nil).ok)
        XCTAssertEqual(UploadDeleteAnswer.parse(json("{\"ok\":false,\"error\":\"nope\"}")).error, "nope")
    }

    func testKindsAndIcons() {
        XCTAssertEqual(UploadKind.of(name: "a.pdf", mime: ""), "pdf")
        XCTAssertEqual(UploadKind.of(name: "a.svg", mime: "image/svg+xml"), "code")
        XCTAssertEqual(UploadKind.of(name: "a.xlsx", mime: ""), "sheet")
        XCTAssertEqual(UploadKind.of(name: "a.key", mime: ""), "slides")
        XCTAssertEqual(UploadKind.of(name: "a.zip", mime: "application/zip"), "archive")
        XCTAssertEqual(UploadKind.of(name: "a.py", mime: ""), "code")
        XCTAssertEqual(UploadKind.of(name: "a.mp3", mime: ""), "audio")
        XCTAssertEqual(UploadKind.of(name: "noext", mime: ""), "file")
        XCTAssertTrue(UploadKind.isSVG(name: "logo.SVG", mime: ""))
        XCTAssertTrue(UploadKind.isSVG(name: "noext", mime: "image/svg+xml"))
        XCTAssertFalse(UploadKind.isSVG(name: "a.png", mime: "image/png"))
        XCTAssertEqual(UploadKind.symbol("pdf"), "doc.richtext")
        XCTAssertEqual(UploadKind.symbol("nope"), "doc")
        XCTAssertEqual(UploadKind.badge("Report.final.DOCX"), "DOCX")
        XCTAssertEqual(UploadKind.badge("Makefile"), "FILE")
    }

    func testFileViewRoutes() {
        XCTAssertEqual(FileView.of(ext: "docx"), .quickLook)
        XCTAssertEqual(FileView.of(ext: "XLSX"), .quickLook)
        XCTAssertEqual(FileView.of(ext: "pptx"), .quickLook)
        XCTAssertEqual(FileView.of(ext: "pages"), .quickLook)
        XCTAssertEqual(FileView.of(ext: "rtf"), .quickLook)
        XCTAssertEqual(FileView.of(ext: "pdf"), .pdf)
        XCTAssertEqual(FileView.of(ext: "svg"), .svg)
        XCTAssertEqual(FileView.of(ext: "png"), .image)
        XCTAssertEqual(FileView.of(ext: "md"), .page)
        XCTAssertEqual(FileView.of(ext: "html"), .page)
        XCTAssertEqual(FileView.of(ext: "swift"), .text)
        XCTAssertEqual(FileView.of(ext: "csv"), .text)
        XCTAssertEqual(FileView.of(ext: "zip"), FileView.none)
        XCTAssertEqual(FileView.of(ext: "dmg"), FileView.none)
    }

    // MARK: a photo uploaded forever

    func testImageFitKeepsScreenshotsAndShrinksPhotos() {
        // a screenshot (a PNG up to 10 MB) goes as it is, even a large one
        XCTAssertEqual(ImageFit.plan(ext: "png", bytes: 3 * MB, longSide: 3024, alpha: false), .keep)
        XCTAssertEqual(ImageFit.plan(ext: "PNG", bytes: 10 * MB, longSide: 5120, alpha: true), .keep)
        // a photo pasted as PNG (over 10 MB): a JPEG of 2560 px, a PNG when it has transparency
        XCTAssertEqual(ImageFit.plan(ext: "png", bytes: 24 * MB, longSide: 4032, alpha: false), .jpeg(maxSide: 2560))
        XCTAssertEqual(ImageFit.plan(ext: "png", bytes: 24 * MB, longSide: 4032, alpha: true), .png(maxSide: 2560))
        // a JPEG: small and within 2560 as it is; a 7 MB photo or a big one made smaller
        XCTAssertEqual(ImageFit.plan(ext: "jpg", bytes: 900_000, longSide: 1600, alpha: false), .keep)
        XCTAssertEqual(ImageFit.plan(ext: "jpeg", bytes: 7 * MB, longSide: 4000, alpha: false), .jpeg(maxSide: 2560))
        XCTAssertEqual(ImageFit.plan(ext: "jpg", bytes: 2 * MB, longSide: 4000, alpha: false), .jpeg(maxSide: 2560))
        XCTAssertEqual(ImageFit.plan(ext: "jpg", bytes: 4 * MB, longSide: 0, alpha: false), .jpeg(maxSide: 2560))
        // HEIC / TIFF / BMP: always made (a JPEG; a PNG with transparency)
        XCTAssertEqual(ImageFit.plan(ext: "heic", bytes: 2 * MB, longSide: 4032, alpha: false), .jpeg(maxSide: 2560))
        XCTAssertEqual(ImageFit.plan(ext: "tiff", bytes: MB, longSide: 800, alpha: true), .png(maxSide: 2560))
        // not touched: GIF (it may move), WebP, any other file
        XCTAssertEqual(ImageFit.plan(ext: "gif", bytes: 9 * MB, longSide: 4000, alpha: false), .keep)
        XCTAssertEqual(ImageFit.plan(ext: "webp", bytes: 12 * MB, longSide: 6000, alpha: false), .keep)
        XCTAssertEqual(ImageFit.plan(ext: "pdf", bytes: 30 * MB, longSide: 0, alpha: false), .keep)
    }

    func testImageFitNames() {
        XCTAssertEqual(ImageFit.name("IMG_1234.HEIC", plan: .jpeg(maxSide: 2560)), "IMG_1234.jpg")
        XCTAssertEqual(ImageFit.name("Pasted image 2026-10-22 at 10.00.00.png", plan: .jpeg(maxSide: 2560)), "Pasted image 2026-10-22 at 10.00.00.jpg")
        XCTAssertEqual(ImageFit.name("scan.tiff", plan: .png(maxSide: 2560)), "scan.png")
        XCTAssertEqual(ImageFit.name("shot.png", plan: .keep), "shot.png")
        // a made picture is read by the model (the read lane), never the streamed one
        XCTAssertEqual(ComposerLane.of(name: ImageFit.name("IMG_1.HEIC", plan: .jpeg(maxSide: 2560)), bytes: 2 * MB), .read)
    }

    func testUploadDeadlineEndsEverySpinner() {
        XCTAssertEqual(UploadDeadline.seconds(bytes: 0), 90)
        XCTAssertEqual(UploadDeadline.seconds(bytes: 1_310_720), 100)
        XCTAssertTrue(UploadDeadline.seconds(bytes: 100 * MB) > 800)
        XCTAssertEqual(UploadDeadline.seconds(bytes: 1_000 * MB), 1200)
    }

    func testPastedPhotoPrefersItsJPEG() {
        XCTAssertEqual(ClipboardPaste.kind(types: ["public.heic", "public.jpeg", "public.tiff"]), .image("public.jpeg"))
        XCTAssertEqual(ClipboardPaste.kind(types: ["public.png", "public.jpeg"]), .image("public.png"))
    }
}
