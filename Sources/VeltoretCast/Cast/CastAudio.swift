import Foundation
import VeltoretKit

/// Picks the audio language on a Chromecast (Android CastAudio, exact). The Default Media Receiver can't switch
/// audio tracks (it plays the file's default one), so the streamed copy marks every other audio track's TrackType
/// as 0x20 ("control"). Only those bytes change, so the size and offsets stay (seeking works) and the file itself
/// is never touched. MKV only.
public enum CastAudio {
    /// An MKV audio track: its TrackNumber and where its TrackType value sits in the file, plus extra labels from the
    /// TrackEntry when present.
    public struct Track: Hashable, Sendable {
        public var number: Int64
        public var typeOffset: Int64
        public var typeLength: Int
        public var language: String?
        public var codecId: String?
        public var name: String?
        public init(number: Int64, typeOffset: Int64, typeLength: Int, language: String? = nil, codecId: String? = nil, name: String? = nil) {
            self.number = number; self.typeOffset = typeOffset; self.typeLength = typeLength
            self.language = language; self.codecId = codecId; self.name = name
        }
    }

    /// Reads up to `length` bytes at `position` (fewer at the end of the file).
    public typealias Reader = (_ position: Int64, _ length: Int) async throws -> Data

    private static let hiddenType: UInt8 = 0x20
    private static let idEbml: Int64 = 0x1A45DFA3
    private static let idSegment: Int64 = 0x18538067
    private static let idSeekHead: Int64 = 0x114D9B74
    private static let idSeek: Int64 = 0x4DBB
    private static let idSeekId: Int64 = 0x53AB
    private static let idSeekPosition: Int64 = 0x53AC
    private static let idCluster: Int64 = 0x1F43B675
    private static let idTracks: Int64 = 0x1654AE6B
    private static let idTrackEntry: Int64 = 0xAE
    private static let idTrackNumber: Int64 = 0xD7
    private static let idTrackType: Int64 = 0x83
    private static let typeAudio: Int64 = 2
    private static let idLanguage: Int64 = 0x22B59C
    private static let idLanguageBcp47: Int64 = 0x22B59D
    private static let idCodecId: Int64 = 0x86
    private static let idName: Int64 = 0x536E

    /// The file's audio tracks, or empty when it isn't MKV or its Tracks can't be found.
    public static func audioTracks(_ reader: @escaping Reader) async -> [Track] {
        do { return try await parse(Cursor(reader)) } catch { return [] }
    }

    /// A reader over a ByteSource (Storage.openRead).
    public static func reader(_ source: ByteSource) -> Reader {
        { position, length in
            var out = Data()
            while out.count < length {
                let chunk = try await source.read(at: position + Int64(out.count), count: length - out.count)
                if chunk.isEmpty { break }
                out.append(chunk)
            }
            return out
        }
    }

    /// Byte changes that leave only track `keep` audible; none when it isn't one of `tracks`.
    public static func hideAllBut(_ tracks: [Track], keep: Int64) -> [Int64: UInt8] {
        var patches: [Int64: UInt8] = [:]
        if tracks.count < 2 || !tracks.contains(where: { $0.number == keep }) { return patches }
        for t in tracks where t.number != keep {
            // A big-endian unsigned int: zeros, then the new type in the last byte.
            for i in 0..<t.typeLength { patches[t.typeOffset + Int64(i)] = i == t.typeLength - 1 ? hiddenType : 0 }
        }
        return patches
    }

    /// Applies `patches` to `buffer`, which holds bytes from `position`.
    public static func apply(_ patches: [Int64: UInt8], position: Int64, buffer: inout Data) {
        if patches.isEmpty { return }
        let count = Int64(buffer.count)
        let base = buffer.startIndex
        for (offset, value) in patches where offset >= position && offset < position + count {
            buffer[base + Int(offset - position)] = value
        }
    }

    private static func parse(_ c: Cursor) async throws -> [Track] {
        guard let ebml = try await c.element(0), ebml.id == idEbml, ebml.size != nil else { return [] }
        guard let segment = try await c.element(ebml.end), segment.id == idSegment else { return [] }
        let segmentEnd = segment.size.map { segment.data + $0 } ?? Int64.max
        var tracksAt: Int64?
        var p = segment.data
        // Tracks normally come before the first Cluster; some files store them after it (SeekHead says where).
        for _ in 0..<64 {
            if p >= segmentEnd { return [] }
            guard let e = try await c.element(p) else { return [] }
            switch e.id {
            case idTracks:
                return try await tracks(c, e)
            case idSeekHead:
                if tracksAt == nil, let t = try await seekTarget(c, e, wanted: idTracks) { tracksAt = segment.data + t }
            case idCluster:
                guard let target = tracksAt, target > p else { return [] }
                p = target
                continue
            default: break
            }
            if e.size == nil { return [] }
            p = e.end
        }
        return []
    }

    private static func tracks(_ c: Cursor, _ tracks: Element) async throws -> [Track] {
        var output: [Track] = []
        guard let size = tracks.size else { return output }
        try await children(c, tracks.data, tracks.data + size) { entry in
            guard entry.id == idTrackEntry, entry.size != nil else { return }
            var number: Int64?
            var type: Int64?
            var typeAt: Int64 = 0
            var typeLength = 0
            var language: String?, codec: String?, name: String?
            try await children(c, entry.data, entry.end) { field in
                guard let len = field.size else { return }
                let length = Int(len)
                switch field.id {
                case idTrackNumber: number = try await c.uint(field.data, length)
                case idTrackType: type = try await c.uint(field.data, length); typeAt = field.data; typeLength = length
                case idLanguage where length > 0 && length <= 64: if language == nil { language = try await c.text(field.data, length) }
                case idLanguageBcp47 where length > 0 && length <= 64: language = try await c.text(field.data, length)
                case idCodecId where length > 0 && length <= 64: codec = try await c.text(field.data, length)
                case idName where length > 0 && length <= 256: name = try await c.text(field.data, length)
                default: break
                }
            }
            if type == typeAudio, let n = number, typeLength >= 1 && typeLength <= 8 {
                output.append(Track(number: n, typeOffset: typeAt, typeLength: typeLength, language: language, codecId: codec, name: name))
            }
        }
        return output
    }

    /// The segment-relative position the SeekHead gives for element `wanted`.
    private static func seekTarget(_ c: Cursor, _ head: Element, wanted: Int64) async throws -> Int64? {
        guard let size = head.size else { return nil }
        var found: Int64?
        try await children(c, head.data, head.data + size) { seek in
            guard seek.id == idSeek, seek.size != nil, found == nil else { return }
            var id: Int64?
            var position: Int64?
            try await children(c, seek.data, seek.end) { f in
                guard let len = f.size else { return }
                switch f.id {
                case idSeekId: id = try await c.uint(f.data, Int(len))
                case idSeekPosition: position = try await c.uint(f.data, Int(len))
                default: break
                }
            }
            if id == wanted { found = position }
        }
        return found
    }

    private static func children(_ c: Cursor, _ start: Int64, _ end: Int64, _ block: (Element) async throws -> Void) async throws {
        var p = start
        while p < end {
            guard let e = try await c.element(p) else { return }
            try await block(e)
            guard e.size != nil else { return }
            p = e.end
        }
    }

    /// An EBML element: `data` is where its content starts; `size` is nil when unknown.
    private struct Element {
        let id: Int64
        let data: Int64
        let size: Int64?
        var end: Int64 { data + (size ?? 0) }
    }

    private struct CursorError: Error {}

    /// Reads the file in 64 KiB windows (at most 16 reads), so walking the header costs only a few reads.
    private final class Cursor {
        private static let windowSize = 64 * 1024
        private let reader: Reader
        private var windowStart: Int64 = -1
        private var window: [UInt8] = []
        private var reads = 0

        init(_ reader: @escaping Reader) { self.reader = reader }

        func byte(_ position: Int64) async throws -> Int {
            if windowStart < 0 || position < windowStart || position >= windowStart + Int64(window.count) {
                reads += 1
                if reads > 16 { throw CursorError() }
                window = [UInt8](try await reader(position, Self.windowSize))
                windowStart = position
                if window.isEmpty { throw CursorError() }
            }
            return Int(window[Int(position - windowStart)])
        }

        func uint(_ position: Int64, _ length: Int) async throws -> Int64 {
            var v: Int64 = 0
            for i in 0..<max(0, length) { v = (v << 8) | Int64(try await byte(position + Int64(i))) }
            return v
        }

        func text(_ position: Int64, _ length: Int) async throws -> String {
            var bytes: [UInt8] = []
            for i in 0..<length { bytes.append(UInt8(try await byte(position + Int64(i)))) }
            var s = String(decoding: bytes, as: UTF8.self)
            while s.hasSuffix("\0") { s.removeLast() }
            return s
        }

        func element(_ position: Int64) async throws -> Element? {
            let first = try await byte(position)
            let idLength = UInt32(first).leadingZeroBitCount - 23
            if idLength < 1 || idLength > 4 { return nil }
            let id = try await uint(position, idLength)
            let sizeAt = position + Int64(idLength)
            let sizeFirst = try await byte(sizeAt)
            let sizeLength = UInt32(sizeFirst).leadingZeroBitCount - 23
            if sizeLength < 1 || sizeLength > 8 { return nil }
            var size = Int64(sizeFirst & (0xFF >> sizeLength))
            var allOnes = size == Int64(0xFF >> sizeLength)
            for i in 1..<sizeLength where sizeLength > 1 {
                let b = try await byte(sizeAt + Int64(i))
                size = (size << 8) | Int64(b)
                if b != 0xFF { allOnes = false }
            }
            return Element(id: id, data: sizeAt + Int64(sizeLength), size: allOnes ? nil : size)
        }
    }
}
