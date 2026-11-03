import Foundation

// Lenient readers over JSONSerialization output. The chat stream and chat docs are written by a
// runner that grows fields every week; a strict Decodable would turn one new or renamed field into
// "the whole answer disappeared". Unknown fields are ignored, wrong types read as absent.
typealias JSONObject = [String: Any]

enum JSONRead {
    /// A JSON true/false, not a number. `v is Bool` is also true for an NSNumber 1 or 0, which made
    /// every field whose value was 1 (a count, a percent, a cost) read as absent.
    static func isBool(_ v: Any) -> Bool {
        #if canImport(Darwin)
        if let n = v as? NSNumber, type(of: v) != Bool.self { return CFGetTypeID(n) == CFBooleanGetTypeID() }
        return v is Bool
        #else
        // swift-corelibs: true/false parse as __NSCFBoolean (an NSNumber subclass), numbers as NSNumber.
        return type(of: v) == Bool.self || String(describing: type(of: v)) == "__NSCFBoolean"
        #endif
    }

    static func object(_ data: Data) -> JSONObject? {
        (try? JSONSerialization.jsonObject(with: data)) as? JSONObject
    }
    static func string(_ o: JSONObject?, _ k: String) -> String? {
        guard let v = o?[k] else { return nil }
        if let s = v as? String { return s }
        if let n = v as? NSNumber, !isBool(v) { return n.stringValue }
        return nil
    }
    static func int(_ o: JSONObject?, _ k: String) -> Int? {
        guard let v = o?[k] else { return nil }
        if isBool(v) { return nil }
        if let n = v as? NSNumber { return n.intValue }
        if let s = v as? String { return Int(s) }
        return nil
    }
    static func double(_ o: JSONObject?, _ k: String) -> Double? {
        guard let v = o?[k] else { return nil }
        if isBool(v) { return nil }
        if let n = v as? NSNumber { return n.doubleValue }
        if let s = v as? String { return Double(s) }
        return nil
    }
    static func bool(_ o: JSONObject?, _ k: String) -> Bool {
        guard let v = o?[k], isBool(v) else { return false }
        return (v as? Bool) ?? false
    }
    static func objects(_ o: JSONObject?, _ k: String) -> [JSONObject] {
        (o?[k] as? [Any])?.compactMap { $0 as? JSONObject } ?? []
    }
    static func strings(_ o: JSONObject?, _ k: String) -> [String] {
        (o?[k] as? [Any])?.compactMap { $0 as? String } ?? []
    }
}
