import Foundation

/// The tiny bit of NetBIOS used to put a name on a server found by address: a "node status" query (UDP 137)
/// asks a machine for its names, as Windows' `nbtstat -A` does. Routers and NAS boxes running Samba usually
/// answer even when they don't announce themselves.
public enum NetBios {
    public static let port: UInt16 = 137

    /// A node status (NBSTAT) request for the wildcard name "*".
    public static func nodeStatusQuery(_ transactionId: Int) -> [UInt8] {
        var o = [UInt8](repeating: 0, count: 50)
        o[0] = UInt8((transactionId >> 8) & 0xFF)
        o[1] = UInt8(transactionId & 0xFF)
        o[5] = 1 // one question
        o[12] = 32 // encoded name length
        // "*" padded with zeros to 16 bytes, each byte split into two letters ('A' + nibble).
        var raw = [UInt8](repeating: 0, count: 16)
        raw[0] = UInt8(ascii: "*")
        for i in 0..<raw.count {
            o[13 + i * 2] = UInt8(ascii: "A") + ((raw[i] >> 4) & 0xF)
            o[14 + i * 2] = UInt8(ascii: "A") + (raw[i] & 0xF)
        }
        // o[45] = 0 ends the name; type NBSTAT (0x21), class IN (1).
        o[47] = 0x21
        o[49] = 1
        return o
    }

    /// The machine's own name from a node status answer: the unique "file server" name (suffix 0x20), else its
    /// unique workstation name (0x00). Nil if the answer can't be read.
    public static func parseNodeStatus(_ data: [UInt8], length: Int? = nil) -> String? {
        let len = min(length ?? data.count, data.count)
        func at(_ i: Int) -> UInt8? { i >= 0 && i < len ? data[i] : nil }
        var offset = 12
        while true {
            guard let b = at(offset) else { return nil }
            if b == 0 { break }
            offset += Int(b) + 1
        }
        offset += 1 + 2 + 2 + 4 + 2 // end of name, type, class, TTL, data length
        guard let count = at(offset) else { return nil }
        offset += 1
        var unique: [(name: String, suffix: UInt8)] = []
        for i in 0..<Int(count) {
            let start = offset + i * 18
            if start + 18 > len { continue }
            let nameBytes = data[start..<(start + 15)]
            let name = String(decoding: nameBytes, as: UTF8.self)
                .trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "\0")))
            let suffix = data[start + 15]
            let group = (data[start + 16] & 0x80) != 0
            if !group && !name.isEmpty { unique.append((name, suffix)) }
        }
        if let u = unique.first(where: { $0.suffix == 0x20 }) { return u.name }
        if let u = unique.first(where: { $0.suffix == 0x00 }) { return u.name }
        return nil
    }
}
