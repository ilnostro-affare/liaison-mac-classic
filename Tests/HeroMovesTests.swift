import XCTest
import Foundation
@testable import Liaison

/// Point 4: the heroes' working moves and the picker that chains them.
final class HeroMovesTests: XCTestCase {
    func testEveryMoveStartsAndEndsAtRest() {
        for m in HeroMove.allCases {
            for dir in [-1.0, 1.0] {
                XCTAssertTrue(HeroMoves.pose(m, 0, dir: dir).isRest(), "\(m) at 0")
                XCTAssertTrue(HeroMoves.pose(m, 1, dir: dir).isRest(), "\(m) at 1")
                XCTAssertTrue(HeroMoves.pose(m, 0.0005, dir: dir).distance(to: .rest) < 0.02, "\(m) just after the start")
                XCTAssertTrue(HeroMoves.pose(m, 0.9995, dir: dir).distance(to: .rest) < 0.02, "\(m) just before the end")
            }
        }
    }

    func testMovesAreContinuous() {
        for m in HeroMove.allCases {
            var last = HeroPose.rest
            var worst = 0.0
            var t = 0.0
            while t <= 1.0 {
                let p = HeroMoves.pose(m, t, dir: 1)
                worst = max(worst, p.distance(to: last))
                last = p
                t += 0.0005
            }
            XCTAssertTrue(worst < 0.03, "\(m) jumps by \(worst)")
        }
    }

    func testMovesStayNearTheFigure() {
        for m in HeroMove.allCases {
            for i in 0...400 {
                let p = HeroMoves.pose(m, Double(i) / 400, dir: -1)
                XCTAssertTrue(abs(p.dx) <= 0.25 && p.lift >= -0.001 && p.lift <= 0.3, "\(m) leaves its place")
                XCTAssertTrue(p.sx > 0.3 && p.sx < 1.6 && p.sy > 0.3 && p.sy < 1.6, "\(m) scale")
                XCTAssertTrue(p.eyeOpen >= 0 && p.eyeOpen <= 1.0001 && p.eyeScale > 0.5 && p.eyeScale < 1.5, "\(m) eyes")
            }
        }
    }

    func testMovesAreDistinct() {
        let samples = HeroMove.allCases.map { m in (1...9).map { HeroMoves.pose(m, Double($0) / 10, dir: 1) } }
        for i in 0..<samples.count {
            for j in (i + 1)..<samples.count {
                let diff = zip(samples[i], samples[j]).map { $0.distance(to: $1) }.max() ?? 0
                XCTAssertTrue(diff > 0.02, "\(HeroMove.allCases[i]) looks like \(HeroMove.allCases[j])")
            }
        }
    }

    func testDurationsFitTheSlot() {
        XCTAssertTrue(HeroMove.allCases.count >= 7 && HeroMove.allCases.count <= 10)
        for m in HeroMove.allCases {
            XCTAssertTrue(m.duration >= 1.5 && m.duration <= 3.0 && m.duration <= HeroMoves.slot, "\(m)")
        }
        XCTAssertEqual(HeroMoves.slot * 2, 6.0)
    }

    func testPickerNeverRepeatsAndIsDeterministic() {
        for agent in ["lia", "dev", "met", "crea", "rep", "x"] {
            var prev: HeroMove?
            for c in 0..<500 {
                let m = HeroMoves.next(agent: agent, cycle: c, previous: prev)
                XCTAssertTrue(m != prev, "\(agent) repeats at \(c)")
                XCTAssertEqual(m, HeroMoves.next(agent: agent, cycle: c, previous: prev))
                prev = m
            }
        }
    }

    func testPickerFollowsPersonality() {
        func favourite(_ agent: String) -> HeroMove {
            var seq = HeroMoves.Sequence(agent: agent)
            var counts: [HeroMove: Int] = [:]
            for c in 0..<3000 { counts[seq.at(c), default: 0] += 1 }
            return counts.max { $0.value < $1.value }!.key
        }
        XCTAssertEqual(favourite("dev"), .pancake)
        XCTAssertEqual(favourite("met"), .dash)
        XCTAssertEqual(favourite("crea"), .jelly)
        XCTAssertEqual(favourite("lia"), .float)
    }

    func testEveryMoveComesUpAndNudgeCanBeOff() {
        var seen = Set<HeroMove>()
        var alone = HeroMoves.Sequence(agent: "dev", allowNudge: false)
        var all = HeroMoves.Sequence(agent: "dev")
        for c in 0..<600 {
            XCTAssertTrue(alone.at(c) != .nudge)
            seen.insert(all.at(c))
        }
        XCTAssertEqual(seen.count, HeroMove.allCases.count)
    }

    func testDifferentHeroesDoNotMoveInStep() {
        var a = HeroMoves.Sequence(agent: "dev"), b = HeroMoves.Sequence(agent: "crea")
        let same = (0..<50).filter { a.at($0) == b.at($0) }.count
        XCTAssertTrue(same < 25)
    }

    func testSequenceStepsAndRestarts() {
        var s = HeroMoves.Sequence(agent: "lia")
        let forward = (0..<20).map { s.at($0) }
        XCTAssertEqual(s.at(5), forward[5])   // going back starts over, same answer
        var fresh = HeroMoves.Sequence(agent: "lia")
        XCTAssertEqual(fresh.at(19), forward[19])
    }

    func testSequencePoseRestsBetweenMoves() {
        var s = HeroMoves.Sequence(agent: "met")
        XCTAssertTrue(s.pose(elapsed: 0).isRest())
        for c in 0..<10 {
            let m = s.at(c)
            let gap = Double(c) * HeroMoves.slot + (m.duration + HeroMoves.slot) / 2
            XCTAssertTrue(s.pose(elapsed: gap).isRest(), "slot \(c) rests after \(m)")
            XCTAssertTrue(s.pose(elapsed: Double(c) * HeroMoves.slot + 0.001).distance(to: .rest) < 0.02)
        }
    }

    func testDirectionIsASide() {
        for c in 0..<50 { XCTAssertTrue(abs(HeroMoves.direction(agent: "lia", cycle: c)) == 1) }
        XCTAssertEqual(HeroMoves.normalizedDegrees(360), 0)
        XCTAssertEqual(HeroMoves.normalizedDegrees(-190), 170)
    }
}
