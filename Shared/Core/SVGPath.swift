import Foundation

/// Minimal SVG path reader for Liaison's icons: M L H V C Q Z, absolute and relative, implicit repeats.
/// Output is platform neutral so it compiles and is tested on Linux; the SwiftUI Shape replays it.
enum SVGCommand: Equatable {
    case move(Double, Double)
    case line(Double, Double)
    case cubic(Double, Double, Double, Double, Double, Double)
    case quad(Double, Double, Double, Double)
    case close
}

enum SVGPath {
    static func parse(_ d: String) -> [SVGCommand] {
        var tokens: [String] = []
        var num = ""
        func flush() { if !num.isEmpty { tokens.append(num); num = "" } }
        for ch in d {
            if "MLHVCQZmlhvcqz".contains(ch) { flush(); tokens.append(String(ch)) }
            else if ch == "-" { if !num.isEmpty, !num.hasSuffix("e") { flush() }; num.append(ch) }
            else if ch == "," || ch.isWhitespace { flush() }
            else if ch == "." && num.contains(".") && !num.contains("e") { flush(); num = "." }
            else { num.append(ch) }
        }
        flush()

        var out: [SVGCommand] = []
        var i = 0, cmd = "M"
        var x = 0.0, y = 0.0, sx = 0.0, sy = 0.0
        func next() -> Double? {
            guard i < tokens.count, let v = Double(tokens[i]) else { return nil }
            i += 1
            return v
        }
        while i < tokens.count {
            if Double(tokens[i]) == nil { cmd = tokens[i]; i += 1 }
            let rel = cmd == cmd.lowercased()
            switch cmd.uppercased() {
            case "M":
                guard let a = next(), let b = next() else { return out }
                x = rel ? x + a : a; y = rel ? y + b : b; sx = x; sy = y
                out.append(.move(x, y))
                cmd = rel ? "l" : "L"   // extra pairs after M are lines
            case "L":
                guard let a = next(), let b = next() else { return out }
                x = rel ? x + a : a; y = rel ? y + b : b
                out.append(.line(x, y))
            case "H":
                guard let a = next() else { return out }
                x = rel ? x + a : a
                out.append(.line(x, y))
            case "V":
                guard let b = next() else { return out }
                y = rel ? y + b : b
                out.append(.line(x, y))
            case "C":
                guard let a = next(), let b = next(), let c = next(), let e = next(), let f = next(), let g = next() else { return out }
                let ox = rel ? x : 0, oy = rel ? y : 0
                out.append(.cubic(a + ox, b + oy, c + ox, e + oy, f + ox, g + oy))
                x = f + ox; y = g + oy
            case "Q":
                guard let a = next(), let b = next(), let c = next(), let e = next() else { return out }
                let ox = rel ? x : 0, oy = rel ? y : 0
                out.append(.quad(a + ox, b + oy, c + ox, e + oy))
                x = c + ox; y = e + oy
            case "Z":
                out.append(.close)
                x = sx; y = sy
            default:
                return out
            }
        }
        return out
    }
}
