import Foundation
import Compression
import VeltoretKit

/// The archive itself can't be read (damaged, truncated, not a ZIP). `message` is for the user's log line.
public struct ZipFormatError: Error, LocalizedError, CustomStringConvertible, Sendable {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var errorDescription: String? { message }
    public var description: String { message }
}

/// The ZIP uses something Veltoret can't read (encryption, a compression method other than store/deflate).
public struct ZipUnsupportedError: Error, LocalizedError, CustomStringConvertible, Sendable {
    public let encrypted: Bool
    public init(encrypted: Bool) { self.encrypted = encrypted }
    public var message: String { encrypted ? "encrypted entry" : "compression method not supported" }
    public var errorDescription: String? { message }
    public var description: String { message }
}

/// One entry from the central directory.
public struct ZipEntry: Hashable, Sendable {
    public var path: String
    public var method: Int
    public var flags: Int
    public var crc32: UInt32
    public var compressedSize: Int64
    public var uncompressedSize: Int64
    public var localHeaderOffset: Int64

    public var isDirectory: Bool { path.hasSuffix("/") || path.hasSuffix("\\") }
    /// General-purpose bit 0 (or WinZip AES, method 99).
    public var isEncrypted: Bool { flags & 1 != 0 || method == 99 }
}

/// A ZIP read by random access (central directory first, then each entry by range), so a ZIP in Drive can be
/// unpacked without downloading it to this Mac. Supports store and deflate, data descriptors and ZIP64.
public enum ZipArchive {
    private static let eocdSig: UInt32 = 0x0605_4b50
    private static let zip64LocatorSig: UInt32 = 0x0706_4b50
    private static let zip64EocdSig: UInt32 = 0x0606_4b50
    private static let centralSig: UInt32 = 0x0201_4b50
    private static let localSig: UInt32 = 0x0403_4b50

    static func readFully(_ source: ByteSource, at offset: Int64, count: Int) async throws -> Data {
        var out = Data()
        while out.count < count {
            let part = try await source.read(at: offset + Int64(out.count), count: count - out.count)
            if part.isEmpty { break }
            out.append(part)
        }
        return out
    }

    /// The entries in the order of their data in the archive.
    public static func entries(_ source: ByteSource) async throws -> [ZipEntry] {
        let length = source.length
        if length < 22 { throw ZipFormatError("too short to be a ZIP") }

        // End of central directory: in the last 22 + 65535 bytes.
        let tailLen = Int(min(length, 22 + 65_535 + 20))
        let tailStart = length - Int64(tailLen)
        let tail = try await readFully(source, at: tailStart, count: tailLen)
        if tail.count < tailLen { throw ZipFormatError("the archive ended early") }
        var eocd = -1
        var i = tail.count - 22
        while i >= 0 {
            if tail.u32(i) == eocdSig { eocd = i; break }
            i -= 1
        }
        if eocd < 0 { throw ZipFormatError("no central directory found") }

        var total = Int64(tail.u16(eocd + 10))
        var cdSize = Int64(tail.u32(eocd + 12))
        var cdOffset = Int64(tail.u32(eocd + 16))

        // ZIP64: a locator sits right before the classic record.
        if eocd >= 20 && tail.u32(eocd - 20) == zip64LocatorSig {
            let recordOffset = Int64(tail.u64(eocd - 20 + 8))
            let rec = try await readFully(source, at: recordOffset, count: 56)
            if rec.count < 56 || rec.u32(0) != zip64EocdSig { throw ZipFormatError("bad ZIP64 directory") }
            total = Int64(rec.u64(32))
            cdSize = Int64(rec.u64(40))
            cdOffset = Int64(rec.u64(48))
        }
        if cdOffset < 0 || cdSize < 0 || cdOffset + cdSize > length { throw ZipFormatError("the central directory is outside the file") }
        if cdSize > 512 * 1024 * 1024 { throw ZipFormatError("the central directory is too large") }

        let cd = try await readFully(source, at: cdOffset, count: Int(cdSize))
        if cd.count < cdSize { throw ZipFormatError("the archive ended early") }

        var entries: [ZipEntry] = []
        var p = 0
        while p + 46 <= cd.count && (entries.count < total || total == 0xFFFF) {
            if cd.u32(p) != centralSig { break }
            let flags = Int(cd.u16(p + 8))
            let method = Int(cd.u16(p + 10))
            let crc = cd.u32(p + 16)
            var comp = Int64(cd.u32(p + 20))
            var uncomp = Int64(cd.u32(p + 24))
            let nameLen = Int(cd.u16(p + 28))
            let extraLen = Int(cd.u16(p + 30))
            let commentLen = Int(cd.u16(p + 32))
            var offset = Int64(cd.u32(p + 42))
            let nameStart = p + 46
            guard nameStart + nameLen + extraLen <= cd.count else { throw ZipFormatError("a directory entry is cut short") }
            let nameBytes = cd.subdata(in: nameStart..<(nameStart + nameLen))
            let name = decodeName(nameBytes, utf8Flag: flags & 0x800 != 0)

            // ZIP64 extra field (0x0001): only the fields that are 0xFFFFFFFF in the header, in this order.
            var e = nameStart + nameLen
            let extraEnd = e + extraLen
            while e + 4 <= extraEnd {
                let tag = cd.u16(e)
                let size = Int(cd.u16(e + 2))
                let dataStart = e + 4
                if tag == 0x0001 {
                    var q = dataStart
                    if uncomp == 0xFFFF_FFFF && q + 8 <= dataStart + size { uncomp = Int64(cd.u64(q)); q += 8 }
                    if comp == 0xFFFF_FFFF && q + 8 <= dataStart + size { comp = Int64(cd.u64(q)); q += 8 }
                    if offset == 0xFFFF_FFFF && q + 8 <= dataStart + size { offset = Int64(cd.u64(q)); q += 8 }
                }
                e = dataStart + size
            }
            entries.append(ZipEntry(path: name, method: method, flags: flags, crc32: crc, compressedSize: comp,
                                    uncompressedSize: uncomp, localHeaderOffset: offset))
            p = extraEnd + commentLen
        }
        if entries.isEmpty && total > 0 { throw ZipFormatError("the central directory is damaged") }
        return entries.sorted { $0.localHeaderOffset < $1.localHeaderOffset }
    }

    /// UTF-8 when flagged (or valid UTF-8), else code page 437 (the ZIP default).
    static func decodeName(_ bytes: Data, utf8Flag: Bool) -> String {
        if let s = String(data: bytes, encoding: .utf8) { return s }
        let cp437 = String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(CFStringEncodings.dosLatinUS.rawValue)))
        return String(data: bytes, encoding: cp437) ?? String(decoding: bytes, as: UTF8.self)
    }

    /// Where the entry's data starts (after its local header).
    public static func dataOffset(_ source: ByteSource, _ entry: ZipEntry) async throws -> Int64 {
        let head = try await readFully(source, at: entry.localHeaderOffset, count: 30)
        if head.count < 30 || head.u32(0) != localSig { throw ZipFormatError("an entry's header is missing") }
        return entry.localHeaderOffset + 30 + Int64(head.u16(26)) + Int64(head.u16(28))
    }

    /// The entry's uncompressed bytes as a stream (CRC-checked at the end).
    public static func open(_ source: ByteSource, _ entry: ZipEntry) async throws -> ZipEntryStream {
        if entry.isEncrypted { throw ZipUnsupportedError(encrypted: true) }
        if entry.method != 0 && entry.method != 8 { throw ZipUnsupportedError(encrypted: false) }
        let start = try await dataOffset(source, entry)
        if start + entry.compressedSize > source.length && source.length >= 0 { throw ZipFormatError("the archive ended early") }
        return try ZipEntryStream(source: source, entry: entry, dataStart: start)
    }
}

/// Inflates (or copies) one entry from its range of the archive.
public final class ZipEntryStream: ByteStream {
    private static let inputChunk = 256 * 1024

    private let source: ByteSource
    private let entry: ZipEntry
    private let dataStart: Int64
    /// Compressed bytes read from the archive so far.
    public private(set) var consumed: Int64 = 0
    private var produced: Int64 = 0
    private var crc = CRC32()
    private var done = false

    private var stream: UnsafeMutablePointer<compression_stream>?
    private var input: UnsafeMutablePointer<UInt8>?
    private var inputCapacity = 0

    init(source: ByteSource, entry: ZipEntry, dataStart: Int64) throws {
        self.source = source
        self.entry = entry
        self.dataStart = dataStart
        if entry.method == 8 {
            let s = UnsafeMutablePointer<compression_stream>.allocate(capacity: 1)
            // COMPRESSION_ZLIB is raw DEFLATE (RFC 1951), which is what ZIP stores.
            guard compression_stream_init(s, COMPRESSION_STREAM_DECODE, COMPRESSION_ZLIB) == COMPRESSION_STATUS_OK else {
                s.deallocate()
                throw ZipFormatError("couldn't start the decompressor")
            }
            stream = s
            inputCapacity = Self.inputChunk
            input = UnsafeMutablePointer<UInt8>.allocate(capacity: inputCapacity)
            s.pointee.src_size = 0
        }
    }

    deinit { close() }

    public func close() {
        if let s = stream {
            compression_stream_destroy(s)
            s.deallocate()
            stream = nil
        }
        input?.deallocate()
        input = nil
    }

    private func finish() throws -> Data {
        if !done {
            done = true
            if produced != entry.uncompressedSize {
                throw ZipFormatError("an entry is shorter than the directory says")
            }
            if crc.value != entry.crc32 { throw ZipFormatError("CRC mismatch in \(entry.path)") }
        }
        return Data()
    }

    public func read(max: Int) async throws -> Data {
        if done || max <= 0 { return Data() }
        if entry.method == 0 { return try await readStored(max) }
        return try await readDeflated(max)
    }

    private func readStored(_ max: Int) async throws -> Data {
        let left = entry.compressedSize - consumed
        if left <= 0 { return try finish() }
        let n = Int(min(Int64(max), left))
        let d = try await source.read(at: dataStart + consumed, count: n)
        if d.isEmpty { throw ZipFormatError("the archive ended early") }
        consumed += Int64(d.count)
        produced += Int64(d.count)
        crc.update(d)
        return d
    }

    private func readDeflated(_ max: Int) async throws -> Data {
        guard let s = stream, let input else { return Data() }
        var stalls = 0
        while true {
            try Task.checkCancellation()
            var allIn = consumed >= entry.compressedSize
            if s.pointee.src_size == 0 && !allIn {
                let n = Int(min(Int64(inputCapacity), entry.compressedSize - consumed))
                let d = try await source.read(at: dataStart + consumed, count: n)
                if d.isEmpty { throw ZipFormatError("the archive ended early") }
                d.copyBytes(to: input, count: d.count)
                s.pointee.src_ptr = UnsafePointer(input)
                s.pointee.src_size = d.count
                consumed += Int64(d.count)
                allIn = consumed >= entry.compressedSize
            }
            let capacity = Swift.max(64 * 1024, Swift.min(max, 1 << 20))
            var out = Data(count: capacity)
            let before = s.pointee.src_size
            let (status, written): (compression_status, Int) = out.withUnsafeMutableBytes { raw in
                s.pointee.dst_ptr = raw.bindMemory(to: UInt8.self).baseAddress!
                s.pointee.dst_size = capacity
                let flags = allIn ? Int32(COMPRESSION_STREAM_FINALIZE.rawValue) : 0
                let st = compression_stream_process(s, flags)
                return (st, capacity - s.pointee.dst_size)
            }
            if status == COMPRESSION_STATUS_ERROR { throw ZipFormatError("the compressed data is damaged") }
            if written > 0 {
                out.count = written
                produced += Int64(written)
                crc.update(out)
                if produced > entry.uncompressedSize { throw ZipFormatError("an entry is longer than the directory says") }
                return out
            }
            if status == COMPRESSION_STATUS_END || (allIn && s.pointee.src_size == 0 && produced == entry.uncompressedSize) {
                return try finish()
            }
            if before == s.pointee.src_size {
                stalls += 1
                if stalls > 2 { throw ZipFormatError("the compressed data ended early") }
            } else {
                stalls = 0
            }
        }
    }
}

/// CRC-32 (IEEE 802.3), as ZIP uses.
public struct CRC32 {
    private static let table: [UInt32] = (0..<256).map { i -> UInt32 in
        var c = UInt32(i)
        for _ in 0..<8 { c = (c & 1) != 0 ? 0xEDB8_8320 ^ (c >> 1) : c >> 1 }
        return c
    }

    private var crc: UInt32 = 0xFFFF_FFFF
    public init() {}

    public mutating func update(_ data: Data) {
        var c = crc
        data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            for b in raw { c = Self.table[Int((c ^ UInt32(b)) & 0xFF)] ^ (c >> 8) }
        }
        crc = c
    }

    public var value: UInt32 { crc ^ 0xFFFF_FFFF }

    public static func checksum(_ data: Data) -> UInt32 {
        var c = CRC32()
        c.update(data)
        return c.value
    }
}

extension Data {
    func u16(_ i: Int) -> UInt16 {
        let b = startIndex + i
        return UInt16(self[b]) | UInt16(self[b + 1]) << 8
    }

    func u32(_ i: Int) -> UInt32 {
        let b = startIndex + i
        return UInt32(self[b]) | UInt32(self[b + 1]) << 8 | UInt32(self[b + 2]) << 16 | UInt32(self[b + 3]) << 24
    }

    func u64(_ i: Int) -> UInt64 { UInt64(u32(i)) | UInt64(u32(i + 4)) << 32 }
}
