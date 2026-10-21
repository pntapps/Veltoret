import Foundation

public struct CastProtocolError: Error, CustomStringConvertible {
    public let description: String
    public init(_ description: String) { self.description = description }
}

/// The Cast v2 protobuf `extensions.api.cast_channel.CastMessage`, hand-encoded (proto2, 7 fields):
/// 1 protocol_version (varint, 0), 2 source_id, 3 destination_id, 4 namespace, 5 payload_type (varint: 0 STRING,
/// 1 BINARY), 6 payload_utf8, 7 payload_binary. On the wire each message is a 4-byte big-endian length + the bytes.
public struct CastMessage: Hashable, Sendable {
    public static let nsConnection = "urn:x-cast:com.google.cast.tp.connection"
    public static let nsHeartbeat = "urn:x-cast:com.google.cast.tp.heartbeat"
    public static let nsReceiver = "urn:x-cast:com.google.cast.receiver"
    public static let nsMedia = "urn:x-cast:com.google.cast.media"

    public var sourceId: String
    public var destinationId: String
    public var namespace: String
    public var payloadUtf8: String?
    public var payloadBinary: Data?

    public init(sourceId: String, destinationId: String, namespace: String, payloadUtf8: String?, payloadBinary: Data? = nil) {
        self.sourceId = sourceId; self.destinationId = destinationId; self.namespace = namespace
        self.payloadUtf8 = payloadUtf8; self.payloadBinary = payloadBinary
    }

    public func encode() -> Data {
        var out = Data()
        Self.writeVarintField(&out, 1, 0)
        Self.writeBytesField(&out, 2, Data(sourceId.utf8))
        Self.writeBytesField(&out, 3, Data(destinationId.utf8))
        Self.writeBytesField(&out, 4, Data(namespace.utf8))
        Self.writeVarintField(&out, 5, payloadBinary != nil ? 1 : 0)
        if let payloadBinary { Self.writeBytesField(&out, 7, payloadBinary) }
        else { Self.writeBytesField(&out, 6, Data((payloadUtf8 ?? "").utf8)) }
        return out
    }

    /// The message with its 4-byte big-endian length prefix.
    public func frame() -> Data {
        let body = encode()
        var frame = Data(count: 4)
        let n = UInt32(body.count)
        frame[0] = UInt8(n >> 24 & 0xFF); frame[1] = UInt8(n >> 16 & 0xFF); frame[2] = UInt8(n >> 8 & 0xFF); frame[3] = UInt8(n & 0xFF)
        frame.append(body)
        return frame
    }

    public static func decode(_ input: Data) throws -> CastMessage {
        let data = [UInt8](input)
        var source = "", destination = "", ns = ""
        var utf8: String?
        var binary: Data?
        var p = 0
        while p < data.count {
            let key = try readVarint(data, &p)
            let field = Int(key >> 3)
            let wire = Int(key & 7)
            switch wire {
            case 0:
                _ = try readVarint(data, &p)
            case 2:
                let lenRaw = try readVarint(data, &p)
                guard lenRaw <= UInt64(data.count), p + Int(lenRaw) <= data.count else { throw CastProtocolError("Bad length") }
                let len = Int(lenRaw)
                let bytes = Data(data[p..<(p + len)])
                p += len
                switch field {
                case 2: source = String(decoding: bytes, as: UTF8.self)
                case 3: destination = String(decoding: bytes, as: UTF8.self)
                case 4: ns = String(decoding: bytes, as: UTF8.self)
                case 6: utf8 = String(decoding: bytes, as: UTF8.self)
                case 7: binary = bytes
                default: break
                }
            case 1: p += 8
            case 5: p += 4
            default: throw CastProtocolError("Bad wire type")
            }
        }
        return CastMessage(sourceId: source, destinationId: destination, namespace: ns, payloadUtf8: utf8, payloadBinary: binary)
    }

    private static func writeVarint(_ out: inout Data, _ value: UInt64) {
        var v = value
        while v >= 0x80 { out.append(UInt8(truncatingIfNeeded: v | 0x80)); v >>= 7 }
        out.append(UInt8(v))
    }

    private static func writeVarintField(_ out: inout Data, _ field: Int, _ v: UInt64) {
        writeVarint(&out, UInt64(field << 3))
        writeVarint(&out, v)
    }

    private static func writeBytesField(_ out: inout Data, _ field: Int, _ value: Data) {
        writeVarint(&out, UInt64((field << 3) | 2))
        writeVarint(&out, UInt64(value.count))
        out.append(value)
    }

    private static func readVarint(_ data: [UInt8], _ p: inout Int) throws -> UInt64 {
        var v: UInt64 = 0
        var shift: UInt64 = 0
        while true {
            if p >= data.count || shift > 63 { throw CastProtocolError("Bad varint") }
            let b = data[p]; p += 1
            v |= UInt64(b & 0x7F) << shift
            if b & 0x80 == 0 { return v }
            shift += 7
        }
    }
}
