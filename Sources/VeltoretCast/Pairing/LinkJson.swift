import Foundation

/// A message the app writes to a Veltoret TV: its fields in declaration order, nils left out.
public protocol LinkEncodable {
    var linkFields: [(String, Any?)] { get }
}

public struct LinkJsonError: Error, CustomStringConvertible {
    public let description: String
}

/// The JSON rules of the Android app's kotlinx Json (WIRE): camelCase names, nulls not written, unknown keys
/// ignored, case-sensitive names, a missing field reads as its Kotlin default. Writing is hand-ordered so the bytes
/// match the other apps (and the signature covers exactly what is sent); `/` and non-ASCII aren't escaped.
public enum LinkJson {
    /// UTF-8, no BOM.
    public static func encode(_ value: LinkEncodable) -> Data { Data(string(value).utf8) }

    public static func string(_ value: LinkEncodable) -> String {
        var out = "{"
        var first = true
        for (k, v) in value.linkFields {
            guard let v else { continue }
            if !first { out += "," }
            first = false
            out += quote(k) + ":" + write(v)
        }
        return out + "}"
    }

    private static func write(_ v: Any) -> String {
        switch v {
        case let s as String: return quote(s)
        case let b as Bool: return b ? "true" : "false"
        case let i as Int: return String(i)
        case let i as Int64: return String(i)
        case let i as Int32: return String(i)
        case let d as Double: return d == d.rounded() && abs(d) < 1e15 ? String(Int64(d)) : String(d)
        case let e as LinkEncodable: return string(e)
        case let a as [Any]: return "[" + a.map(write).joined(separator: ",") + "]"
        default: return "null"
        }
    }

    static func quote(_ s: String) -> String {
        var out = "\""
        for u in s.unicodeScalars {
            switch u {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            case "\u{08}": out += "\\b"
            case "\u{0C}": out += "\\f"
            default:
                if u.value < 0x20 { out += String(format: "\\u%04x", u.value) } else { out.unicodeScalars.append(u) }
            }
        }
        return out + "\""
    }

    public static func decode<T: Decodable>(_ type: T.Type, _ text: String) throws -> T {
        if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { throw LinkJsonError(description: "Empty body") }
        return try JSONDecoder().decode(T.self, from: Data(text.utf8))
    }

    public static func tryDecode<T: Decodable>(_ type: T.Type, _ text: String) -> T? { try? decode(type, text) }
}

extension KeyedDecodingContainer {
    /// kotlinx coerceInputValues: missing, null or mistyped → the default.
    func value<T: Decodable>(_ key: Key, _ fallback: T) -> T { ((try? decodeIfPresent(T.self, forKey: key)) ?? nil) ?? fallback }
    func optional<T: Decodable>(_ key: Key) -> T? { (try? decodeIfPresent(T.self, forKey: key)) ?? nil }
}
