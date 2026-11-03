import XCTest
import Foundation
@testable import Liaison

/// The sign-in constellation: the brand marks parse, and the bubbles sit inside the frame without piling up.
final class BrandMarksTests: XCTestCase {
    func testEveryMarkParsesAndFitsTheViewBox() {
        XCTAssertFalse(BrandMarks.all.isEmpty)
        XCTAssertEqual(Set(BrandMarks.all.map(\.id)).count, BrandMarks.all.count, "ids are unique")
        for m in BrandMarks.all {
            // a mark from the product's file may have no path; every other mark needs one
            if m.asset != nil && m.d.isEmpty { continue }
            let cmds = SVGPath.parse(m.d)
            XCTAssertTrue(cmds.count >= 4, m.id)
            XCTAssertEqual(cmds.first.map { if case .move = $0 { return true } else { return false } }, true, m.id)
            // only the commands SVGPath knows, so the whole string was read (a stop would leave numbers unread)
            let letters = Set(m.d.filter(\.isLetter))
            XCTAssertTrue(letters.isSubset(of: Set("MLCQZ")), "\(m.id): \(letters)")
            XCTAssertEqual(cmds.count, m.d.filter(\.isLetter).count, m.id)
            var drawn = 0
            for c in cmds {
                var pts: [(Double, Double)] = []
                switch c {
                case let .move(x, y), let .line(x, y): pts = [(x, y)]
                case let .cubic(a, b, c2, d, e, f): pts = [(a, b), (c2, d), (e, f)]; drawn += 1
                case let .quad(a, b, c2, d): pts = [(a, b), (c2, d)]; drawn += 1
                case .close: break
                }
                if case .line = c { drawn += 1 }
                for p in pts {
                    XCTAssertTrue(p.0 >= -0.6 && p.0 <= 24.6 && p.1 >= -0.6 && p.1 <= 24.6, "\(m.id) \(p)")
                }
            }
            XCTAssertTrue(drawn >= 2, m.id)
        }
    }

    func testDarkGlyphs() {
        for id in ["github", "vercel", "notion", "tiktok", "openai"] {
            XCTAssertTrue(BrandMarks.needsLightGlyphOnDark(BrandMarks.mark(id)!.hex), id)
        }
        for id in ["meta", "whatsapp", "gmail", "claude", "cloudflare", "figma", "canva", "stripe"] {
            XCTAssertFalse(BrandMarks.needsLightGlyphOnDark(BrandMarks.mark(id)!.hex), id)
        }
    }

    func testBrandLogoFiles() {
        // every mark the orbit shows is the product's file but Vercel's
        let shown = Set(OrbitLayout.allSpots.map(\.markId))
        for id in shown where id != "vercel" { XCTAssertNotNil(BrandMarks.mark(id)?.asset, id) }
        XCTAssertNil(BrandMarks.mark("vercel")?.asset)
        XCTAssertEqual(Set(BrandMarks.assetNames).count, BrandMarks.assetNames.count)
        for n in BrandMarks.assetNames { XCTAssertTrue(n.hasPrefix("brand-") && n == n.lowercased(), n) }
        for id in ["codex", "midjourney", "openai", "higgsfield", "github"] { XCTAssertEqual(BrandMarks.mark(id)?.template, true, id) }
        // OpenAI / ChatGPT: the product's file, in its own black (white in dark), not simple-icons' purple
        XCTAssertEqual(BrandMarks.mark("openai")?.asset, "brand-openai")
        XCTAssertEqual(BrandMarks.mark("openai")?.hex, 0x000000)
        for id in ["claudecode", "canva", "gmail", "googledrive", "googlecalendar", "slack", "meta", "figma", "whatsapp"] {
            XCTAssertEqual(BrandMarks.mark(id)?.template, false, id)
        }
        // logos with a background of their own fill the whole bubble
        XCTAssertEqual(BrandMarks.mark("higgsfield")?.bubbleFill, 0xD3FF1A)
        let fills: Set<String> = ["canva", "instagram", "facebook", "stripe"]
        for m in BrandMarks.all { XCTAssertEqual(m.fillsBubble, fills.contains(m.id), m.id) }
        for m in BrandMarks.all where m.id != "higgsfield" { XCTAssertNil(m.bubbleFill, m.id) }
        // ChatGPT is OpenAI: no separate mark in the orbit
        XCTAssertFalse(shown.contains("chatgpt"))
        XCTAssertTrue(OrbitLayout.sets["crea"]!.contains { $0.markId == "openai" })
        // the image sets are in the catalog (from the repo root on Linux, next to this file on a Mac)
        let roots = [URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent(),
                     URL(fileURLWithPath: FileManager.default.currentDirectoryPath)]
        let catalog = roots.map { $0.appendingPathComponent("Resources/Assets.xcassets") }
            .first { FileManager.default.fileExists(atPath: $0.path) }
        XCTAssertNotNil(catalog)
        guard let catalog else { return }
        // Third-party brand logos are not part of this public extract (trademarks of their owners); the catalog
        // check runs only where they are present.
        guard let first = BrandMarks.assetNames.first,
              FileManager.default.fileExists(atPath: catalog.appendingPathComponent("\(first).imageset").path) else { return }
        for name in BrandMarks.assetNames {
            let set = catalog.appendingPathComponent("\(name).imageset")
            XCTAssertTrue(FileManager.default.fileExists(atPath: set.appendingPathComponent("Contents.json").path), name)
            XCTAssertTrue(FileManager.default.fileExists(atPath: set.appendingPathComponent("\(name).png").path), name)
            XCTAssertTrue(FileManager.default.fileExists(atPath: set.appendingPathComponent("\(name)@2x.png").path), name)
        }
    }

    func testEachHeroHasATightRing() {
        XCTAssertEqual(Set(OrbitLayout.sets.keys), Set(OrbitLayout.heroes))
        let all = OrbitLayout.allSpots
        XCTAssertEqual(Set(all.map(\.id)).count, all.count, "ids unique across sets")
        XCTAssertFalse(all.contains { $0.id == "tiktok" })
        let dev = Set((OrbitLayout.sets["dev"] ?? []).map(\.id))
        XCTAssertTrue(dev.isSuperset(of: ["claude", "claudecode", "openai", "codex"]))
        XCTAssertTrue(Set((OrbitLayout.sets["crea"] ?? []).map(\.id)).isSuperset(of: ["midjourney", "higgsfield"]))
        for h in OrbitLayout.heroes {
            let set = OrbitLayout.sets[h] ?? []
            XCTAssertTrue((5...7).contains(set.count), "\(h): \(set.count)")
            XCTAssertEqual(set.map(\.order), Array(0..<set.count), h)
            for s in set {
                XCTAssertEqual(s.world, h)
                XCTAssertNotNil(BrandMarks.mark(s.markId), s.id)
                XCTAssertTrue((40...96).contains(s.size), s.id)
                // touching the centre or a little under its edge, never far out, never mostly hidden
                XCTAssertTrue(s.tuck >= 2 && s.tuck <= 14, s.id)
                // turning, it stays in the square frame at any angle
                XCTAssertTrue(s.radius + s.size / 2 + OrbitLayout.maxDepth <= min(OrbitLayout.width, OrbitLayout.height) / 2, s.id)
                let p = s.point(turn: 0)
                XCTAssertTrue(abs(hypot(p.x, p.y) - s.radius) < 1e-9)
            }
            for (i, s) in set.enumerated() {
                for t in set[(i + 1)...] {
                    // a slight overlap between neighbours is fine, a pile is not (the ring turns as one, so this holds always)
                    let a = s.point(turn: 37), b = t.point(turn: 37)
                    XCTAssertTrue(hypot(a.x - b.x, a.y - b.y) > (s.size + t.size) / 2 - 8, "\(s.id)/\(t.id)")
                }
            }
        }
    }

    func testRingNeverStopsTurning() {
        let s = OrbitSpot(id: "x", world: "lia", order: 0, angle: 0, size: 50, tuck: 5)
        let a = s.point(turn: 0), b = s.point(turn: 10)
        XCTAssertTrue(b.y > a.y, "y down: clockwise from east goes down")
        let w = 360 / OrbitLayout.ringTurn
        for t in stride(from: 0.0, through: 30.0, by: 0.5) {
            let d = (OrbitLayout.ringAngle(t + 0.1) - OrbitLayout.ringAngle(t) + 360).truncatingRemainder(dividingBy: 360)
            XCTAssertTrue(abs(d - w * 0.1) < 1e-9, "even at \(t)")
        }
        XCTAssertTrue((60...90).contains(OrbitLayout.ringTurn))
        // a spat-out bubble already turns with the ring (the angle is the clock's; the jelly is only radial)
        let spot = OrbitLayout.sets["dev"]![0]
        let p1 = OrbitLayout.bubble(spot, from: "lia", to: "dev", tau: 0.5, t: 10)
        let p2 = OrbitLayout.bubble(spot, from: "lia", to: "dev", tau: 0.5, t: 12)
        XCTAssertTrue(abs(atan2(p1.y, p1.x) - atan2(p2.y, p2.x)) > 0.01)
        for i in 0..<20 {
            for k in 0..<40 { XCTAssertTrue(abs(OrbitLayout.breath(i, t: Double(k) * 0.7) - 1) <= 0.0101) }
        }
    }

    func testJellySpitAndPull() {
        let r = 100.0
        let start = OrbitLayout.spit(0, radius: r)
        XCTAssertEqual(start.opacity, 0)
        XCTAssertTrue(abs(start.dr + 65) < 1e-9, "starts under the centre")
        let k = OrbitLayout.jellyKeys
        var t = 0.0, peaks: [Double] = []
        for key in k { t += key.time; peaks.append(OrbitLayout.spit(t - 1e-9, radius: r).dr) }
        XCTAssertTrue(peaks[0] > 3 && peaks[0] <= 6, "\(peaks)")
        for i in 1..<(k.count - 1) {
            XCTAssertTrue(abs(peaks[i]) < abs(peaks[i - 1]), "smaller")
            XCTAssertTrue((peaks[i] > 0) != (peaks[i - 1] > 0), "back and forth")
        }
        XCTAssertTrue(k.count - 2 >= 3, "about three bounces")
        let done = OrbitLayout.spit(OrbitLayout.jellyTotal + 0.01, radius: r)
        XCTAssertTrue(done.dr == 0 && done.scale == 1 && done.opacity == 1)
        var prev = OrbitLayout.spit(0.001, radius: r)
        for f in 1..<200 {
            let cur = OrbitLayout.spit(0.001 + Double(f) / 120, radius: r)
            XCTAssertTrue(abs(cur.dr - prev.dr) < 6 && abs(cur.scale - prev.scale) < 0.06, "frame \(f)")
            prev = cur
        }
        let p0 = OrbitLayout.pull(0), p1 = OrbitLayout.pull(OrbitLayout.pullDuration)
        XCTAssertTrue(p0.k == 1 && p0.scale == 1 && p0.opacity == 1)
        XCTAssertTrue(abs(p1.k - OrbitLayout.pullRadius) < 1e-9 && p1.opacity == 0)
        for s in OrbitLayout.allSpots { XCTAssertTrue(s.radius * OrbitLayout.pullRadius < OrbitLayout.centreSize / 2, s.id) }
        XCTAssertTrue(OrbitLayout.spitAt(from: "lia") + OrbitLayout.jellyTotal + 0.4 < OrbitLayout.duration("dev"))
    }

    func testDirectorRunsForever() {
        var d = OrbitLayout.Director(), seen: [String] = []
        var t = 0.0
        while t < 60 {
            d.step(t, holdLia: false)
            if seen.last != d.to { seen.append(d.to) }
            t += 1.0 / 60
        }
        XCTAssertEqual(Array(seen.prefix(11)), ["team", "lia", "dev", "met", "crea", "team", "lia", "dev", "met", "crea", "team"])
        // the email field: Lia now, and she stays
        d.step(t, holdLia: true)
        XCTAssertEqual(d.to, "lia")
        let at = d.changeAt
        d.step(t + 100, holdLia: true)
        XCTAssertEqual(d.to, "lia")
        XCTAssertEqual(d.changeAt, at)
        XCTAssertEqual(OrbitLayout.nextStage(after: "rep"), "team")
    }

    func testCloudAndItsMorph() {
        let cloud = OrbitLayout.bodyShape(morph: 0, scale: 1)
        // one flat bottom: the base, and the circles that reach it, end on the same line
        XCTAssertEqual(cloud.base.y1, 76)
        XCTAssertTrue(cloud.base.corner * 2 == cloud.base.y1 - cloud.base.y0, "round ends")
        for c in cloud.circles {
            XCTAssertTrue(c.y + c.r <= cloud.base.y1 + 1e-9, "nothing below the base")
            XCTAssertTrue(abs(c.x) + c.r <= OrbitLayout.width / 2 && abs(c.y) + c.r <= OrbitLayout.height / 2)
        }
        let big = cloud.circles[0]
        XCTAssertTrue(cloud.circles.allSatisfy { $0.r <= big.r }, "the big bump")
        XCTAssertTrue(big.x > 0 && cloud.circles[1].x < 0, "big top centre-right, small top-left")
        // the heroes sit inside their bumps
        let bumps = ["lia": 0, "met": 1, "dev": 2]
        for (h, i) in bumps {
            let s = OrbitLayout.cloudSpots[h]!, c = cloud.circles[i]
            XCTAssertTrue(hypot(s.x - c.x, s.y - c.y) + s.scale * 45 <= c.r + 2, h)
        }
        let crea = OrbitLayout.cloudSpots["crea"]!
        XCTAssertTrue(crea.y - crea.scale * 45 >= cloud.base.y0 - 2 && crea.y + crea.scale * 45 <= cloud.base.y1, "crea in the base")
        // morph 1: every piece is the centre circle
        let circle = OrbitLayout.bodyShape(morph: 1, scale: 1)
        let R = OrbitLayout.centreSize / 2
        for c in circle.circles { XCTAssertTrue(c.x == 0 && c.y == 0 && c.r == R) }
        XCTAssertEqual(circle.base, OrbitLayout.BodyShape.Box(x0: -R, y0: -R, x1: R, y1: R, corner: R))
        XCTAssertEqual(OrbitLayout.cloudStops, ["crea", "met", "lia", "dev"])
        let tints = OrbitLayout.heroes.map { OrbitLayout.tint($0) }
        for i in 0..<tints.count { for j in (i + 1)..<tints.count { XCTAssertTrue(tints[i] != tints[j]) } }
    }

    func testSceneIsContinuous() {
        // every change, sampled at 60 fps: the body, the heroes and the bubbles never jump
        let pairs = [("team", "lia"), ("lia", "dev"), ("crea", "team"), ("dev", "lia")]
        for (a, b) in pairs {
            var lastBody = OrbitLayout.body(from: a, to: b, tau: 0)
            var lastFig = OrbitLayout.heroes.map { OrbitLayout.figure($0, from: a, to: b, tau: 0) }
            for f in 1..<150 {
                let tau = Double(f) / 60
                let body = OrbitLayout.body(from: a, to: b, tau: tau)
                XCTAssertTrue(abs(body.scale - lastBody.scale) < 0.05 && abs(body.morph - lastBody.morph) < 0.08, "\(a)->\(b) body \(f)")
                lastBody = body
                let figs = OrbitLayout.heroes.map { OrbitLayout.figure($0, from: a, to: b, tau: tau) }
                for (x, y) in zip(figs, lastFig) {
                    XCTAssertTrue(hypot(x.x - y.x, x.y - y.y) < 24 && abs(x.scale - y.scale) < 0.08, "\(a)->\(b) hero \(f)")
                }
                lastFig = figs
            }
            // and it ends where the stage stands
            let end = OrbitLayout.body(from: a, to: b, tau: 5)
            XCTAssertTrue(abs(end.scale - 1) < 1e-9 && end.mix == 1 && end.morph == (b == "team" ? 0 : 1))
        }
        XCTAssertEqual(OrbitLayout.figure("dev", from: "lia", to: "dev", tau: 5), OrbitLayout.Figure())
        XCTAssertEqual(OrbitLayout.figure("lia", from: "lia", to: "dev", tau: 5).opacity, 0)
        XCTAssertEqual(OrbitLayout.pop(5).scale, 1)
    }
}
