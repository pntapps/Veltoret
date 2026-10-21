import Foundation
import VeltoretKit

public enum HdrFormat: String, Sendable, Hashable { case unknown, sdr, hdr10, hlg, dolbyVision }

/// Finds out whether a video is HDR before it plays (libVLC 3 doesn't expose the transfer function): reads the
/// colour information in the container header — Matroska/WebM Video → Colour → TransferCharacteristics and the Dolby
/// Vision block addition mapping, MP4/MOV `colr` (nclx) and `dvcC`/`dvvC` boxes — and falls back to the
/// file name ("HDR", "HDR10", "DV", "HLG") when the header doesn't say. Only the first megabytes are read.
public enum HdrProbe {
    /// ITU-T H.273 transfer characteristics: SMPTE ST 2084 (PQ) and ARIB STD-B67 (HLG).
    private static let transferPq = 16, transferHlg = 18

    private static let maxRead: Int64 = 16 * 1024 * 1024
    private static let maxMoov: Int64 = 64 * 1024 * 1024

    public static func label(_ f: HdrFormat) -> String {
        switch f {
        case .dolbyVision: return "Dolby Vision"
        case .hdr10: return "HDR10"
        case .hlg: return "HLG"
        default: return "SDR"
        }
    }

    public static func isHdr(_ f: HdrFormat) -> Bool { f == .hdr10 || f == .hlg || f == .dolbyVision }

    /// The container's answer if it has one, else the file name's (or unknown). Doesn't close `source`.
    public static func detect(_ source: ByteSource, fileName: String?) async -> HdrFormat {
        var found = HdrFormat.unknown
        do { found = try await fromContainer(source) } catch { found = .unknown }
        return found != .unknown ? found : fromFileName(fileName)
    }

    /// Opens the file through Storage, probes it and closes it.
    public static func detect(account: String, fileId: String, fileName: String?) async -> HdrFormat {
        guard let s = try? await AppServices.storage.openRead(account, id: fileId) else { return fromFileName(fileName) }
        defer { s.close() }
        return await detect(s, fileName: fileName)
    }

    private static let dvName = try! NSRegularExpression(pattern: #"(^|[^a-z0-9])(dv|dovi|dolby[ ._-]?vision)([^a-z0-9]|$)"#)
    private static let hlgName = try! NSRegularExpression(pattern: #"(^|[^a-z0-9])hlg([^a-z0-9]|$)"#)

    /// Release names: "Title.2160p.DV.HDR.mkv", "Title.HDR10+.mkv", "Title.HLG.mkv".
    public static func fromFileName(_ fileName: String?) -> HdrFormat {
        guard let fileName, !fileName.isEmpty else { return .unknown }
        let n = ((fileName as NSString).lastPathComponent as NSString).deletingPathExtension.lowercased()
        let r = NSRange(location: 0, length: (n as NSString).length)
        if dvName.firstMatch(in: n, range: r) != nil { return .dolbyVision }
        if n.contains("hdr") { return .hdr10 }
        if hlgName.firstMatch(in: n, range: r) != nil { return .hlg }
        return .unknown
    }

    public static func fromContainer(_ source: ByteSource) async throws -> HdrFormat {
        let s = Reader(source)
        let head = try await s.read(12)
        if head.count >= 4 && be32(head, 0) == 0x1A45DFA3 { return try await matroska(s) }
        if head.count >= 8, let t = String(bytes: head[4..<8], encoding: .ascii),
           ["ftyp", "moov", "mdat", "wide", "free"].contains(t) { return try await mp4(s) }
        return .unknown
    }

    // ---------------------------------------------------------------------------------------------
    // Reading (a buffered cursor over a ByteSource)

    struct EndOfStream: Error {}
    struct InvalidData: Error {}

    final class Reader {
        let source: ByteSource
        var position: Int64 = 0
        private var buffer = [UInt8]()
        private var bufferStart: Int64 = 0
        private static let chunk = 256 * 1024

        init(_ source: ByteSource) { self.source = source }

        var length: Int64 { source.length >= 0 ? source.length : Int64.max }

        /// Up to `count` bytes at the position (fewer only at the end); advances.
        func read(_ count: Int) async throws -> [UInt8] {
            var out = [UInt8]()
            out.reserveCapacity(min(count, 1 << 20))
            while out.count < count {
                let bufEnd = bufferStart + Int64(buffer.count)
                if position >= bufferStart && position < bufEnd {
                    let from = Int(position - bufferStart)
                    let n = min(count - out.count, buffer.count - from)
                    out.append(contentsOf: buffer[from..<(from + n)])
                    position += Int64(n)
                    continue
                }
                try Task.checkCancellation()
                let want = max(Self.chunk, min(count - out.count, 16 << 20))
                let data = try await source.read(at: position, count: want)
                if data.isEmpty { break }
                buffer = [UInt8](data)
                bufferStart = position
            }
            return out
        }

        func readByte() async throws -> Int {
            let b = try await read(1)
            return b.isEmpty ? -1 : Int(b[0])
        }
    }

    private static func be32(_ b: [UInt8], _ i: Int) -> UInt32 {
        UInt32(b[i]) << 24 | UInt32(b[i + 1]) << 16 | UInt32(b[i + 2]) << 8 | UInt32(b[i + 3])
    }

    private static func be64(_ b: [UInt8], _ i: Int) -> UInt64 {
        var v: UInt64 = 0
        for k in 0..<8 { v = v << 8 | UInt64(b[i + k]) }
        return v
    }

    // ---------------------------------------------------------------------------------------------
    // Matroska / WebM (EBML)

    private static let idSegment: UInt32 = 0x18538067, idTracks: UInt32 = 0x1654AE6B, idTrackEntry: UInt32 = 0xAE
    private static let idCluster: UInt32 = 0x1F43B675
    private static let idTrackType: UInt32 = 0x83, idVideo: UInt32 = 0xE0, idColour: UInt32 = 0x55B0, idTransfer: UInt32 = 0x55BA
    private static let idBlockAdditionMapping: UInt32 = 0x41E4, idBlockAddIdType: UInt32 = 0x41E7
    private static let dvcC: Int64 = 0x64766343, dvvC: Int64 = 0x64767643, dvwC: Int64 = 0x64767743

    private static func matroska(_ s: Reader) async throws -> HdrFormat {
        s.position = 0
        let end = s.length
        while s.position < end && s.position < maxRead {
            let (id, size) = try await readElementHeader(s)
            if id == idSegment {
                let segEnd = size < 0 ? end : min(end, s.position &+ size)
                while s.position < segEnd && s.position < maxRead {
                    let (cid, csize) = try await readElementHeader(s)
                    if cid == idCluster { return .unknown } // tracks come before the first cluster
                    if csize < 0 { return .unknown }
                    if cid == idTracks {
                        if csize > maxRead { return .unknown }
                        let tracks = try await s.read(Int(csize))
                        if tracks.count < csize { throw EndOfStream() }
                        return matroskaTracks(tracks)
                    }
                    s.position += csize
                }
                return .unknown
            }
            if size < 0 { return .unknown }
            s.position += size
        }
        return .unknown
    }

    private static func matroskaTracks(_ tracks: [UInt8]) -> HdrFormat {
        var best = HdrFormat.unknown
        for (id, start, length) in children(tracks, 0, tracks.count) where id == idTrackEntry {
            var type: Int64 = 0
            var transfer: Int?
            var dv = false
            for (cid, cs, cl) in children(tracks, start, length) {
                if cid == idTrackType { type = readUInt(tracks, cs, cl) }
                else if cid == idBlockAdditionMapping {
                    for (mid, ms, ml) in children(tracks, cs, cl) where mid == idBlockAddIdType {
                        let v = readUInt(tracks, ms, ml)
                        if v == dvcC || v == dvvC || v == dvwC { dv = true }
                    }
                } else if cid == idVideo {
                    for (vid, vs, vl) in children(tracks, cs, cl) where vid == idColour {
                        for (kid, ks, kl) in children(tracks, vs, vl) where kid == idTransfer {
                            transfer = Int(readUInt(tracks, ks, kl))
                        }
                    }
                }
            }
            if type != 1 { continue } // video tracks only
            let f: HdrFormat = dv ? .dolbyVision
                : transfer == transferPq ? .hdr10
                : transfer == transferHlg ? .hlg
                : transfer != nil ? .sdr
                : .unknown
            if rank(f) > rank(best) { best = f }
        }
        return best
    }

    private static func rank(_ f: HdrFormat) -> Int {
        switch f {
        case .dolbyVision: return 4
        case .hdr10: return 3
        case .hlg: return 2
        case .sdr: return 1
        case .unknown: return 0
        }
    }

    /// The child elements in buf[start, start+length): (id, data start, data length).
    private static func children(_ buf: [UInt8], _ start: Int, _ length: Int) -> [(UInt32, Int, Int)] {
        var out: [(UInt32, Int, Int)] = []
        var p = start
        let end = start + length
        while p < end {
            guard let id = tryVint(buf, &p, end, keepMarker: true) else { break }
            guard let size = tryVint(buf, &p, end, keepMarker: false), size >= 0, Int64(p) + size <= Int64(end) else { break }
            out.append((UInt32(truncatingIfNeeded: id), p, Int(size)))
            p += Int(size)
        }
        return out
    }

    private static func tryVint(_ buf: [UInt8], _ p: inout Int, _ end: Int, keepMarker: Bool) -> Int64? {
        if p >= end { return nil }
        let first = Int(buf[p])
        var len = 1
        while len <= 8 && (first & (0x80 >> (len - 1))) == 0 { len += 1 }
        if len > 8 || p + len > end { return nil }
        var v = Int64(keepMarker ? first : first & (0xFF >> len))
        var allOnes = v == Int64(0xFF >> len)
        if len > 1 {
            for i in 1..<len {
                v = (v << 8) | Int64(buf[p + i])
                if buf[p + i] != 0xFF { allOnes = false }
            }
        }
        p += len
        return !keepMarker && allOnes ? -1 : v
    }

    private static func readElementHeader(_ s: Reader) async throws -> (UInt32, Int64) {
        let id = try await readStreamVint(s, keepMarker: true)
        let size = try await readStreamVint(s, keepMarker: false)
        return (UInt32(truncatingIfNeeded: id), size)
    }

    private static func readStreamVint(_ s: Reader, keepMarker: Bool) async throws -> Int64 {
        let first = try await s.readByte()
        if first < 0 { throw EndOfStream() }
        var len = 1
        while len <= 8 && (first & (0x80 >> (len - 1))) == 0 { len += 1 }
        if len > 8 { throw InvalidData() }
        var v = Int64(keepMarker ? first : first & (0xFF >> len))
        var allOnes = v == Int64(0xFF >> len)
        if len > 1 {
            let rest = try await s.read(len - 1)
            if rest.count < len - 1 { throw EndOfStream() }
            for b in rest {
                v = (v << 8) | Int64(b)
                if b != 0xFF { allOnes = false }
            }
        }
        return !keepMarker && allOnes ? -1 : v
    }

    private static func readUInt(_ buf: [UInt8], _ start: Int, _ length: Int) -> Int64 {
        var v: Int64 = 0
        for i in 0..<min(length, 8) { v = (v << 8) | Int64(buf[start + i]) }
        return v
    }

    // ---------------------------------------------------------------------------------------------
    // MP4 / MOV (ISO BMFF)

    private static let containers: Set<String> = ["moov", "trak", "mdia", "minf", "stbl"]
    private static let dvEntries: Set<String> = ["dvh1", "dvhe", "dva1", "dvav", "dav1"]
    private static let visualEntries: Set<String> = ["hvc1", "hev1", "avc1", "avc3", "av01", "vp09", "dvh1", "dvhe", "dva1",
                                                     "dvav", "dav1", "mp4v"]

    private static func ascii(_ b: [UInt8], _ i: Int) -> String {
        String(decoding: b[i..<(i + 4)], as: UTF8.self)
    }

    private static func mp4(_ s: Reader) async throws -> HdrFormat {
        s.position = 0
        let end = s.length
        while s.position + 8 <= end {
            let at = s.position
            var header = try await s.read(8)
            if header.count < 8 { break }
            var size = Int64(be32(header, 0))
            let type = ascii(header, 4)
            var headerLength: Int64 = 8
            if size == 1 {
                let ext = try await s.read(8)
                if ext.count < 8 { break }
                header += ext
                let big = be64(header, 8)
                guard big <= UInt64(Int64.max) else { break }
                size = Int64(big)
                headerLength = 16
            } else if size == 0 {
                if end == Int64.max { break }
                size = end - at
            }
            if size < headerLength { break }
            if type == "moov" {
                let bodyLength = size - headerLength
                if bodyLength > maxMoov { return .unknown }
                let moov = try await s.read(Int(bodyLength))
                if moov.count < bodyLength { throw EndOfStream() }
                return mp4Boxes(moov, 0, moov.count)
            }
            // moov may come after mdat (no "fast start"): skip over the media data.
            s.position = at + size
        }
        return .unknown
    }

    private static func mp4Boxes(_ buf: [UInt8], _ start: Int, _ length: Int) -> HdrFormat {
        var best = HdrFormat.unknown
        for (type, bs, bl) in boxes(buf, start, length) {
            let f: HdrFormat
            if containers.contains(type) { f = mp4Boxes(buf, bs, bl) }
            else if type == "stsd" && bl > 8 { f = mp4Boxes(buf, bs + 8, bl - 8) } // version/flags, entry count
            else if visualEntries.contains(type) && bl >= 78 { f = visualEntry(type, buf, bs + 78, bl - 78) }
            else { continue }
            if rank(f) > rank(best) { best = f }
        }
        return best
    }

    private static func visualEntry(_ type: String, _ buf: [UInt8], _ start: Int, _ length: Int) -> HdrFormat {
        if dvEntries.contains(type) { return .dolbyVision }
        var result = HdrFormat.unknown
        for (child, cs, cl) in boxes(buf, start, length) {
            if child == "dvcC" || child == "dvvC" || child == "dvwC" { return .dolbyVision }
            if child == "colr" && cl >= 10 && ascii(buf, cs) == "nclx" {
                let transfer = Int(buf[cs + 6]) << 8 | Int(buf[cs + 7])
                result = transfer == transferPq ? .hdr10 : transfer == transferHlg ? .hlg : .sdr
            }
        }
        return result
    }

    private static func boxes(_ buf: [UInt8], _ start: Int, _ length: Int) -> [(String, Int, Int)] {
        var out: [(String, Int, Int)] = []
        var p = start
        let end = start + length
        while p + 8 <= end {
            var size = Int64(be32(buf, p))
            let type = ascii(buf, p + 4)
            var header: Int64 = 8
            if size == 1 && p + 16 <= end {
                let big = be64(buf, p + 8)
                if big > UInt64(Int64.max) { break }
                size = Int64(big)
                header = 16
            } else if size == 0 { size = Int64(end - p) }
            if size < header || Int64(p) + size > Int64(end) { break }
            out.append((type, p + Int(header), Int(size - header)))
            p += Int(size)
        }
        return out
    }
}
