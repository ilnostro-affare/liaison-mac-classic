// Minimal XCTest stand-in for Linux toolchains whose XCTest runtime does not start
// (swiftwasm 5.10 image: SIGILL on an empty suite). Same call sites as XCTest, so the
// test files are shared with Xcode unchanged except for the import, which the runner strips.
import Foundation

class XCTestCase {
    required init() {}
}

var shimFailures = 0
var shimCurrent = ""

private func fail(_ msg: String, _ file: StaticString, _ line: UInt) {
    shimFailures += 1
    print("FAIL \(shimCurrent) \(file):\(line) \(msg)")
}

func XCTAssertEqual<T: Equatable>(_ a: @autoclosure () throws -> T, _ b: @autoclosure () throws -> T, _ m: String = "", file: StaticString = #file, line: UInt = #line) {
    do { let x = try a(), y = try b(); if x != y { fail("\(x) != \(y) \(m)", file, line) } } catch { fail("threw \(error)", file, line) }
}
func XCTAssertTrue(_ a: @autoclosure () throws -> Bool, _ m: String = "", file: StaticString = #file, line: UInt = #line) {
    do { if try !a() { fail("not true \(m)", file, line) } } catch { fail("threw \(error)", file, line) }
}
func XCTAssertFalse(_ a: @autoclosure () throws -> Bool, _ m: String = "", file: StaticString = #file, line: UInt = #line) {
    do { if try a() { fail("not false \(m)", file, line) } } catch { fail("threw \(error)", file, line) }
}
func XCTAssertNil(_ a: @autoclosure () throws -> Any?, _ m: String = "", file: StaticString = #file, line: UInt = #line) {
    do { if let v = try a() { fail("not nil: \(v) \(m)", file, line) } } catch { fail("threw \(error)", file, line) }
}
func XCTAssertNotNil(_ a: @autoclosure () throws -> Any?, _ m: String = "", file: StaticString = #file, line: UInt = #line) {
    do { if try a() == nil { fail("nil \(m)", file, line) } } catch { fail("threw \(error)", file, line) }
}
func XCTAssertThrowsError<T>(_ a: @autoclosure () throws -> T, _ m: String = "", file: StaticString = #file, line: UInt = #line) {
    do { _ = try a(); fail("did not throw \(m)", file, line) } catch {}
}
func XCTFail(_ m: String = "", file: StaticString = #file, line: UInt = #line) { fail(m, file, line) }

func shimRun<T: XCTestCase>(_ type: T.Type, _ tests: [(String, (T) -> () throws -> Void)]) -> Int {
    var ran = 0
    for (name, body) in tests {
        shimCurrent = "\(T.self).\(name)"
        do { try body(T())() } catch { shimFailures += 1; print("FAIL \(shimCurrent) threw \(error)") }
        ran += 1
    }
    return ran
}
