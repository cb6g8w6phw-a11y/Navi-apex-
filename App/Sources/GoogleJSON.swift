import Foundation

/**
 * Google's map responses start with an XSSI guard (`)]}'` then a newline) and then a deeply
 * nested positional JSON array with no field names. These helpers strip the guard and walk a
 * path so a missing or moved index gives nil instead of a crash (port of Vela's GoogleResponse).
 */
enum GoogleJSON {
    private static let guards = [")]}'\n", ")]}',\n", ")]}'", ")]}", "while(1);", "for(;;);"]

    static func strip(_ body: String) -> String {
        for g in guards where body.hasPrefix(g) {
            return String(body.dropFirst(g.count)).trimmingCharacters(in: .newlines)
        }
        return body
    }

    static func parse(_ body: String) -> Any? {
        let text = strip(body)
        guard let data = text.data(using: .utf8) else { return nil }
        return try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
    }

    /** Serialize a node back to text, for the regex fallbacks. */
    static func text(_ v: Any?) -> String {
        guard let v, JSONSerialization.isValidJSONObject(v),
              let d = try? JSONSerialization.data(withJSONObject: v) else { return "" }
        return String(decoding: d, as: UTF8.self)
    }
}

func at(_ v: Any?, _ path: [Int]) -> Any? {
    var cur = v
    for i in path {
        guard let a = cur as? [Any], i >= 0, i < a.count else { return nil }
        cur = a[i]
    }
    return cur
}

func at(_ v: Any?, _ path: Int...) -> Any? { at(v, path) }

func arr(_ v: Any?) -> [Any]? { v as? [Any] }

func str(_ v: Any?) -> String? {
    if let s = v as? String { return s }
    if let n = v as? NSNumber, !isBool(n) { return n.stringValue }
    return nil
}

func dbl(_ v: Any?) -> Double? {
    if let n = v as? NSNumber, !isBool(n) { return n.doubleValue }
    if let s = v as? String { return Double(s) }
    return nil
}

func int(_ v: Any?) -> Int? {
    if let n = v as? NSNumber, !isBool(n) { return n.intValue }
    if let s = v as? String { return Int(s) }
    return nil
}

private func isBool(_ n: NSNumber) -> Bool {
    CFGetTypeID(n) == CFBooleanGetTypeID()
}
