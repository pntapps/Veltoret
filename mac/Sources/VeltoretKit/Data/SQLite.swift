import Foundation
import SQLite3

// A small SQLite layer (the Windows app's Microsoft.Data.Sqlite + Dapper): named "@param" binding, array
// expansion for "IN @ids", and Codable rows. Column names equal the entities' property names, as in Room.

public enum SQLValue: Equatable, Sendable {
    case null
    case int(Int64)
    case double(Double)
    case text(String)
    case blob(Data)
}

/// Anything that can be bound to a statement parameter.
public protocol SQLBindable {
    var sqlValue: SQLValue { get }
}

extension Int: SQLBindable { public var sqlValue: SQLValue { .int(Int64(self)) } }
extension Int64: SQLBindable { public var sqlValue: SQLValue { .int(self) } }
extension Int32: SQLBindable { public var sqlValue: SQLValue { .int(Int64(self)) } }
extension Double: SQLBindable { public var sqlValue: SQLValue { .double(self) } }
extension Float: SQLBindable { public var sqlValue: SQLValue { .double(Double(self)) } }
extension Bool: SQLBindable { public var sqlValue: SQLValue { .int(self ? 1 : 0) } }
extension String: SQLBindable { public var sqlValue: SQLValue { .text(self) } }
extension Data: SQLBindable { public var sqlValue: SQLValue { .blob(self) } }
extension SQLValue: SQLBindable { public var sqlValue: SQLValue { self } }
extension Optional: SQLBindable where Wrapped: SQLBindable {
    public var sqlValue: SQLValue { self?.sqlValue ?? .null }
}

/// An array argument: `"… WHERE driveId IN @ids"` with `["ids": SQLList(ids)]` expands to `IN (@ids_0, @ids_1, …)`.
public struct SQLList: SQLBindable {
    public let values: [SQLValue]
    public init<S: Sequence>(_ items: S) where S.Element: SQLBindable { values = items.map(\.sqlValue) }
    public var sqlValue: SQLValue { .null }
}

public struct SQLiteError: Error, CustomStringConvertible {
    public let code: Int32
    public let message: String
    public let sql: String
    public var description: String { "SQLite \(code): \(message) [\(sql.prefix(120))]" }
}

/// One result row, by column name.
public struct SQLRow {
    public let values: [String: SQLValue]

    public subscript(_ column: String) -> SQLValue { values[column] ?? .null }

    public func int(_ c: String) -> Int64? {
        switch self[c] {
        case .int(let v): return v
        case .double(let d): return Int64(d)
        case .text(let s): return Int64(s)
        default: return nil
        }
    }
    public func double(_ c: String) -> Double? {
        switch self[c] {
        case .int(let v): return Double(v)
        case .double(let d): return d
        case .text(let s): return Double(s)
        default: return nil
        }
    }
    public func string(_ c: String) -> String? {
        switch self[c] {
        case .text(let s): return s
        case .int(let v): return String(v)
        case .double(let d): return String(d)
        default: return nil
        }
    }

    public func decode<T: Decodable>(_ type: T.Type = T.self) throws -> T {
        try T(from: RowDecoder(row: self))
    }
}

// MARK: - Connection

/// One SQLite connection. Not thread-safe by itself: VeltoretDb serializes access.
final class SQLiteConnection {
    private(set) var handle: OpaquePointer?

    init(path: String) throws {
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
        let rc = sqlite3_open_v2(path, &handle, flags, nil)
        if rc != SQLITE_OK {
            let msg = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "open failed"
            sqlite3_close(handle)
            throw SQLiteError(code: rc, message: msg, sql: path)
        }
        sqlite3_busy_timeout(handle, 5000)
    }

    deinit { sqlite3_close(handle) }

    func exec(_ sql: String) throws {
        var err: UnsafeMutablePointer<CChar>?
        let rc = sqlite3_exec(handle, sql, nil, nil, &err)
        if rc != SQLITE_OK {
            let msg = err.map { String(cString: $0) } ?? "error"
            sqlite3_free(err)
            throw SQLiteError(code: rc, message: msg, sql: sql)
        }
    }

    var changes: Int { Int(sqlite3_changes(handle)) }
    var lastInsertRowId: Int64 { sqlite3_last_insert_rowid(handle) }

    /// Runs one statement and returns its rows (empty for writes).
    @discardableResult
    func run(_ sql: String, _ args: [String: SQLBindable]) throws -> [SQLRow] {
        let (text, bindings) = Self.expand(sql, args)
        var stmt: OpaquePointer?
        let rc = sqlite3_prepare_v2(handle, text, -1, &stmt, nil)
        guard rc == SQLITE_OK, let stmt else {
            throw SQLiteError(code: rc, message: String(cString: sqlite3_errmsg(handle)), sql: text)
        }
        defer { sqlite3_finalize(stmt) }
        for (name, value) in bindings {
            let idx = sqlite3_bind_parameter_index(stmt, "@" + name)
            if idx == 0 { continue }
            Self.bind(stmt, idx, value)
        }
        var rows: [SQLRow] = []
        let count = sqlite3_column_count(stmt)
        var names: [String] = []
        for i in 0..<count { names.append(String(cString: sqlite3_column_name(stmt, i))) }
        while true {
            let step = sqlite3_step(stmt)
            if step == SQLITE_DONE { break }
            guard step == SQLITE_ROW else {
                throw SQLiteError(code: step, message: String(cString: sqlite3_errmsg(handle)), sql: text)
            }
            var dict: [String: SQLValue] = [:]
            dict.reserveCapacity(Int(count))
            for i in 0..<count {
                let v: SQLValue
                switch sqlite3_column_type(stmt, i) {
                case SQLITE_INTEGER: v = .int(sqlite3_column_int64(stmt, i))
                case SQLITE_FLOAT: v = .double(sqlite3_column_double(stmt, i))
                case SQLITE_TEXT: v = .text(String(cString: sqlite3_column_text(stmt, i)))
                case SQLITE_BLOB:
                    let n = Int(sqlite3_column_bytes(stmt, i))
                    if let p = sqlite3_column_blob(stmt, i), n > 0 { v = .blob(Data(bytes: p, count: n)) } else { v = .blob(Data()) }
                default: v = .null
                }
                // Keep the first column of a name (SELECT m.*, … AS x never repeats names in our queries).
                if dict[names[Int(i)]] == nil { dict[names[Int(i)]] = v }
            }
            rows.append(SQLRow(values: dict))
        }
        return rows
    }

    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    private static func bind(_ stmt: OpaquePointer, _ idx: Int32, _ value: SQLValue) {
        switch value {
        case .null: sqlite3_bind_null(stmt, idx)
        case .int(let v): sqlite3_bind_int64(stmt, idx, v)
        case .double(let d): sqlite3_bind_double(stmt, idx, d)
        case .text(let s): sqlite3_bind_text(stmt, idx, s, -1, transient)
        case .blob(let d): _ = d.withUnsafeBytes { sqlite3_bind_blob(stmt, idx, $0.baseAddress, Int32(d.count), transient) }
        }
    }

    /// Expands SQLList arguments into numbered parameters.
    static func expand(_ sql: String, _ args: [String: SQLBindable]) -> (String, [(String, SQLValue)]) {
        var text = sql
        var out: [(String, SQLValue)] = []
        for (name, value) in args {
            if let list = value as? SQLList {
                let names = list.values.indices.map { "\(name)_\($0)" }
                let replacement = names.isEmpty ? "(NULL)" : "(" + names.map { "@" + $0 }.joined(separator: ", ") + ")"
                text = replaceParam(in: text, name: name, with: replacement)
                for (n, v) in zip(names, list.values) { out.append((n, v)) }
            } else {
                out.append((name, value.sqlValue))
            }
        }
        return (text, out)
    }

    private static func replaceParam(in sql: String, name: String, with replacement: String) -> String {
        let pattern = "@" + NSRegularExpression.escapedPattern(for: name) + "(?![A-Za-z0-9_])"
        guard let re = try? NSRegularExpression(pattern: pattern) else { return sql }
        let range = NSRange(sql.startIndex..., in: sql)
        return re.stringByReplacingMatches(in: sql, range: range, withTemplate: NSRegularExpression.escapedTemplate(for: replacement))
    }
}

// MARK: - Row decoding

struct RowDecoder: Decoder {
    let row: SQLRow
    var codingPath: [CodingKey] = []
    var userInfo: [CodingUserInfoKey: Any] = [:]

    func container<Key: CodingKey>(keyedBy type: Key.Type) throws -> KeyedDecodingContainer<Key> {
        KeyedDecodingContainer(RowKeyed<Key>(row: row))
    }
    func unkeyedContainer() throws -> UnkeyedDecodingContainer {
        throw DecodingError.typeMismatch([Any].self, .init(codingPath: codingPath, debugDescription: "Rows are keyed"))
    }
    func singleValueContainer() throws -> SingleValueDecodingContainer {
        // A single-column row (e.g. SELECT DISTINCT showId).
        ColumnDecoder(value: row.values.values.first ?? .null, codingPath: codingPath)
    }
}

private struct RowKeyed<Key: CodingKey>: KeyedDecodingContainerProtocol {
    let row: SQLRow
    var codingPath: [CodingKey] = []
    var allKeys: [Key] { row.values.keys.compactMap { Key(stringValue: $0) } }

    func contains(_ key: Key) -> Bool { row.values[key.stringValue] != nil }
    func decodeNil(forKey key: Key) throws -> Bool { row[key.stringValue] == .null }
    func decode<T: Decodable>(_ type: T.Type, forKey key: Key) throws -> T {
        try T(from: ColumnDecoder(value: row[key.stringValue], codingPath: codingPath + [key]))
    }
    func nestedContainer<NestedKey: CodingKey>(keyedBy type: NestedKey.Type, forKey key: Key) throws -> KeyedDecodingContainer<NestedKey> {
        KeyedDecodingContainer(RowKeyed<NestedKey>(row: row))
    }
    func nestedUnkeyedContainer(forKey key: Key) throws -> UnkeyedDecodingContainer {
        throw DecodingError.typeMismatch([Any].self, .init(codingPath: codingPath, debugDescription: "Unsupported"))
    }
    func superDecoder() throws -> Decoder { RowDecoder(row: row) }
    func superDecoder(forKey key: Key) throws -> Decoder { RowDecoder(row: row) }
}

private struct ColumnDecoder: Decoder, SingleValueDecodingContainer {
    let value: SQLValue
    var codingPath: [CodingKey]
    var userInfo: [CodingUserInfoKey: Any] { [:] }

    func container<Key: CodingKey>(keyedBy type: Key.Type) throws -> KeyedDecodingContainer<Key> {
        throw mismatch(Key.self)
    }
    func unkeyedContainer() throws -> UnkeyedDecodingContainer { throw mismatch([Any].self) }
    func singleValueContainer() throws -> SingleValueDecodingContainer { self }

    private func mismatch(_ t: Any.Type) -> DecodingError {
        .typeMismatch(t, .init(codingPath: codingPath, debugDescription: "Column value \(value) isn't \(t)"))
    }

    func decodeNil() -> Bool { value == .null }

    private func int64() throws -> Int64 {
        switch value {
        case .int(let v): return v
        case .double(let d): return Int64(d)
        case .text(let s): if let v = Int64(s) { return v }
        default: break
        }
        throw mismatch(Int64.self)
    }
    private func dbl() throws -> Double {
        switch value {
        case .int(let v): return Double(v)
        case .double(let d): return d
        case .text(let s): if let v = Double(s) { return v }
        default: break
        }
        throw mismatch(Double.self)
    }

    func decode(_ type: Bool.Type) throws -> Bool { try int64() != 0 }
    func decode(_ type: String.Type) throws -> String {
        switch value {
        case .text(let s): return s
        case .int(let v): return String(v)
        case .double(let d): return String(d)
        default: throw mismatch(String.self)
        }
    }
    func decode(_ type: Double.Type) throws -> Double { try dbl() }
    func decode(_ type: Float.Type) throws -> Float { Float(try dbl()) }
    func decode(_ type: Int.Type) throws -> Int { Int(try int64()) }
    func decode(_ type: Int8.Type) throws -> Int8 { Int8(truncatingIfNeeded: try int64()) }
    func decode(_ type: Int16.Type) throws -> Int16 { Int16(truncatingIfNeeded: try int64()) }
    func decode(_ type: Int32.Type) throws -> Int32 { Int32(truncatingIfNeeded: try int64()) }
    func decode(_ type: Int64.Type) throws -> Int64 { try int64() }
    func decode(_ type: UInt.Type) throws -> UInt { UInt(truncatingIfNeeded: try int64()) }
    func decode(_ type: UInt8.Type) throws -> UInt8 { UInt8(truncatingIfNeeded: try int64()) }
    func decode(_ type: UInt16.Type) throws -> UInt16 { UInt16(truncatingIfNeeded: try int64()) }
    func decode(_ type: UInt32.Type) throws -> UInt32 { UInt32(truncatingIfNeeded: try int64()) }
    func decode(_ type: UInt64.Type) throws -> UInt64 { UInt64(truncatingIfNeeded: try int64()) }
    func decode<T: Decodable>(_ type: T.Type) throws -> T {
        if type == Data.self, case .blob(let d) = value { return d as! T }
        return try T(from: self)
    }
}

// MARK: - Row encoding (for upserts)

/// Encodes an Encodable entity into column → value pairs. Nil optionals become NULL columns.
final class RowEncoder: Encoder {
    var values: [(String, SQLValue)] = []
    var codingPath: [CodingKey] = []
    var userInfo: [CodingUserInfoKey: Any] = [:]

    static func columns<T: Encodable>(_ value: T) throws -> [(String, SQLValue)] {
        let e = RowEncoder()
        try value.encode(to: e)
        return e.values
    }

    func set(_ key: String, _ v: SQLValue) {
        if let i = values.firstIndex(where: { $0.0 == key }) { values[i].1 = v } else { values.append((key, v)) }
    }

    func container<Key: CodingKey>(keyedBy type: Key.Type) -> KeyedEncodingContainer<Key> {
        KeyedEncodingContainer(RowKeyedEncoder<Key>(encoder: self))
    }
    func unkeyedContainer() -> UnkeyedEncodingContainer { fatalError("Rows are keyed") }
    func singleValueContainer() -> SingleValueEncodingContainer { fatalError("Rows are keyed") }
}

private struct RowKeyedEncoder<Key: CodingKey>: KeyedEncodingContainerProtocol {
    let encoder: RowEncoder
    var codingPath: [CodingKey] = []

    mutating func encodeNil(forKey key: Key) throws { encoder.set(key.stringValue, .null) }
    mutating func encode(_ value: Bool, forKey key: Key) throws { encoder.set(key.stringValue, value.sqlValue) }
    mutating func encode(_ value: String, forKey key: Key) throws { encoder.set(key.stringValue, .text(value)) }
    mutating func encode(_ value: Double, forKey key: Key) throws { encoder.set(key.stringValue, .double(value)) }
    mutating func encode(_ value: Float, forKey key: Key) throws { encoder.set(key.stringValue, .double(Double(value))) }
    mutating func encode(_ value: Int, forKey key: Key) throws { encoder.set(key.stringValue, .int(Int64(value))) }
    mutating func encode(_ value: Int32, forKey key: Key) throws { encoder.set(key.stringValue, .int(Int64(value))) }
    mutating func encode(_ value: Int64, forKey key: Key) throws { encoder.set(key.stringValue, .int(value)) }
    mutating func encode<T: Encodable>(_ value: T, forKey key: Key) throws {
        encoder.set(key.stringValue, try ColumnEncoder.encode(value))
    }

    // Synthesized Codable skips nil optionals through these; record them as NULL instead.
    mutating func encodeIfPresent(_ value: Bool?, forKey key: Key) throws { encoder.set(key.stringValue, value.sqlValue) }
    mutating func encodeIfPresent(_ value: String?, forKey key: Key) throws { encoder.set(key.stringValue, value.sqlValue) }
    mutating func encodeIfPresent(_ value: Double?, forKey key: Key) throws { encoder.set(key.stringValue, value.sqlValue) }
    mutating func encodeIfPresent(_ value: Float?, forKey key: Key) throws { encoder.set(key.stringValue, value.sqlValue) }
    mutating func encodeIfPresent(_ value: Int?, forKey key: Key) throws { encoder.set(key.stringValue, value.sqlValue) }
    mutating func encodeIfPresent(_ value: Int32?, forKey key: Key) throws { encoder.set(key.stringValue, value.sqlValue) }
    mutating func encodeIfPresent(_ value: Int64?, forKey key: Key) throws { encoder.set(key.stringValue, value.sqlValue) }
    mutating func encodeIfPresent<T: Encodable>(_ value: T?, forKey key: Key) throws {
        encoder.set(key.stringValue, try value.map(ColumnEncoder.encode) ?? .null)
    }

    mutating func nestedContainer<NestedKey: CodingKey>(keyedBy keyType: NestedKey.Type, forKey key: Key) -> KeyedEncodingContainer<NestedKey> {
        KeyedEncodingContainer(RowKeyedEncoder<NestedKey>(encoder: encoder))
    }
    mutating func nestedUnkeyedContainer(forKey key: Key) -> UnkeyedEncodingContainer { fatalError("Unsupported") }
    mutating func superEncoder() -> Encoder { encoder }
    mutating func superEncoder(forKey key: Key) -> Encoder { encoder }
}

/// Encodes one column value (enums with raw values, Data, numbers).
private final class ColumnEncoder: Encoder, SingleValueEncodingContainer {
    var value: SQLValue = .null
    var codingPath: [CodingKey] = []
    var userInfo: [CodingUserInfoKey: Any] = [:]

    static func encode<T: Encodable>(_ v: T) throws -> SQLValue {
        if let b = v as? SQLBindable { return b.sqlValue }
        let e = ColumnEncoder()
        try v.encode(to: e)
        return e.value
    }

    func container<Key: CodingKey>(keyedBy type: Key.Type) -> KeyedEncodingContainer<Key> { fatalError("Columns are single values") }
    func unkeyedContainer() -> UnkeyedEncodingContainer { fatalError("Columns are single values") }
    func singleValueContainer() -> SingleValueEncodingContainer { self }

    func encodeNil() throws { value = .null }
    func encode(_ v: Bool) throws { value = v.sqlValue }
    func encode(_ v: String) throws { value = .text(v) }
    func encode(_ v: Double) throws { value = .double(v) }
    func encode(_ v: Float) throws { value = .double(Double(v)) }
    func encode(_ v: Int) throws { value = .int(Int64(v)) }
    func encode(_ v: Int8) throws { value = .int(Int64(v)) }
    func encode(_ v: Int16) throws { value = .int(Int64(v)) }
    func encode(_ v: Int32) throws { value = .int(Int64(v)) }
    func encode(_ v: Int64) throws { value = .int(v) }
    func encode(_ v: UInt) throws { value = .int(Int64(v)) }
    func encode(_ v: UInt8) throws { value = .int(Int64(v)) }
    func encode(_ v: UInt16) throws { value = .int(Int64(v)) }
    func encode(_ v: UInt32) throws { value = .int(Int64(v)) }
    func encode(_ v: UInt64) throws { value = .int(Int64(v)) }
    func encode<T: Encodable>(_ v: T) throws { value = try ColumnEncoder.encode(v) }
}
