import Foundation
import Compression
import XCTest
import VeltoretKit
@testable import VeltoretDrive

/// Answers every request with a closure (GoogleAuthTests.Answer).
final class Answer: HttpTransport, @unchecked Sendable {
    private let answer: (URLRequest) -> HttpResponse
    init(_ answer: @escaping (URLRequest) -> HttpResponse) { self.answer = answer }
    func send(_ request: URLRequest) async throws -> HttpResponse { answer(request) }
}

/// Minimal in-memory Drive resumable endpoint that records each chunk's Content-Range (Android test's FakeDrive).
final class FakeUploadTransport: HttpTransport, @unchecked Sendable {
    var ranges: [String] = []
    var received = Data()
    var uploads = 0
    /// Answer chunks with this status and body instead (a full account, a permission problem…).
    var refuse: (code: Int, body: String)?

    func send(_ request: URLRequest) async throws -> HttpResponse {
        if request.httpMethod == "POST" {
            return HttpResponse(status: 200, headers: ["Location": "https://upload.example/session"])
        }
        if let refuse { return HttpResponse(status: refuse.code, body: Data(refuse.body.utf8)) }
        let range = request.value(forHTTPHeaderField: "Content-Range")!
        ranges.append(range)
        received.append(request.httpBody ?? Data())
        // "bytes a-b/total" or "bytes */total": complete once the total is known and reached.
        let total = String(range[range.index(after: range.lastIndex(of: "/")!)...])
        if total != "*" && Int64(received.count) == Int64(total)! {
            uploads += 1
            return HttpResponse(status: 200, json: "{\"id\":\"f\(uploads)\",\"name\":\"x\",\"size\":\"\(total)\"}")
        }
        return HttpResponse(status: 308)
    }
}

final class FixedTokens: TokenProvider, @unchecked Sendable {
    private let lock = NSLock()
    private(set) var issued = 0
    private(set) var invalidated: [String] = []
    func accessToken(_ email: String) async throws -> String {
        lock.withLock { issued += 1; return "token-\(issued)" }
    }
    func invalidate(_ email: String) { lock.withLock { invalidated.append(email) } }
}

/// An in-memory Google Drive for extraction tests.
final class FakeDriveClient: DriveClient, @unchecked Sendable {
    struct Item { var file: DriveFile; var bytes: Data }

    private let lock = NSLock()
    private var _items: [String: Item] = [:]
    private(set) var trashed: [String] = []
    private(set) var deleted: [String] = []
    private(set) var downloads = 0
    private(set) var uploadCalls = 0
    var free: Int64? = 100_000_000
    /// Uploads of this file name fail with this error.
    var uploadFailure: (String) -> Error? = { _ in nil }
    private var next = 0

    var items: [String: Item] { lock.withLock { _items } }

    @discardableResult
    func add(_ parent: String, _ name: String, _ bytes: Data? = nil, folder: Bool = false) -> String {
        lock.withLock {
            next += 1
            let id = "id\(next)"
            _items[id] = Item(file: DriveFile(id: id, name: name, mimeType: folder ? DriveFile.folderMime : "application/octet-stream",
                                              size: folder ? nil : String(bytes?.count ?? 0), parents: [parent]),
                              bytes: bytes ?? Data())
            return id
        }
    }

    func children(_ parent: String) -> [Item] { items.values.filter { $0.file.parents!.contains(parent) } }

    func pathOf(_ id: String) -> String? {
        let all = items
        guard let item = all[id] else { return nil }
        let parent = item.file.parents![0]
        return all[parent] != nil ? pathOf(parent)! + "/" + item.file.name : item.file.name
    }

    func listChildren(_ email: String, folderId: String, orderBy: String?) async throws -> [DriveFile] {
        children(folderId).map(\.file)
    }

    func createFolder(_ email: String, parentId: String, name: String) async throws -> DriveFile {
        let id = add(parentId, name, folder: true)
        return items[id]!.file
    }

    func trash(_ email: String, id: String) async throws { lock.withLock { trashed.append(id) } }

    func deletePermanently(_ email: String, id: String) async throws {
        lock.withLock { deleted.append(id); _items[id] = nil }
    }

    func freeBytes(_ email: String) async throws -> Int64? { free }

    func openRead(_ email: String, id: String) async throws -> ByteSource {
        lock.withLock { downloads += 1 }
        return DataByteSource(items[id]!.bytes)
    }

    func upload(_ email: String, parentId: String, name: String, mimeType: String, size: Int64,
                open: @escaping () throws -> ByteStream, onProgress: ((Int64, Int64) -> Void)?) async throws -> DriveFile {
        lock.withLock { uploadCalls += 1 }
        if let failure = uploadFailure(name) { throw failure }
        let s = try open()
        defer { s.close() }
        var data = Data()
        while true {
            let d = try await s.read(max: 1 << 20)
            if d.isEmpty { break }
            data.append(d)
        }
        onProgress?(Int64(data.count), size)
        let id = add(parentId, name, data)
        return items[id]!.file
    }
}

func randomBytes(_ seed: UInt64, _ n: Int) -> Data {
    var state = seed &* 6364136223846793005 &+ 1442695040888963407
    var out = Data(count: n)
    out.withUnsafeMutableBytes { raw in
        let p = raw.bindMemory(to: UInt8.self)
        for i in 0..<n {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            p[i] = UInt8(truncatingIfNeeded: state >> 33)
        }
    }
    return out
}

/// Writes test ZIPs: deflated or stored, with or without data descriptors (what a writer that can't seek back
/// produces), optionally as ZIP64.
enum TestZip {
    struct Entry {
        var name: String
        var bytes: Data
        var flags: UInt16 = 0
    }

    private static func le16(_ v: UInt16, _ d: inout Data) { d.append(UInt8(v & 0xFF)); d.append(UInt8(v >> 8)) }
    private static func le32(_ v: UInt32, _ d: inout Data) { for i in 0..<4 { d.append(UInt8((v >> (8 * UInt32(i))) & 0xFF)) } }
    private static func le64(_ v: UInt64, _ d: inout Data) { for i in 0..<8 { d.append(UInt8((v >> (8 * UInt64(i))) & 0xFF)) } }

    static func deflate(_ data: Data) -> Data {
        if data.isEmpty { return Data([0x03, 0x00]) } // an empty final fixed-Huffman block
        let capacity = data.count + data.count / 10 + 1024
        var out = Data(count: capacity)
        let n = out.withUnsafeMutableBytes { dst in
            data.withUnsafeBytes { src in
                compression_encode_buffer(dst.bindMemory(to: UInt8.self).baseAddress!, capacity,
                                          src.bindMemory(to: UInt8.self).baseAddress!, data.count, nil, COMPRESSION_ZLIB)
            }
        }
        precondition(n > 0)
        out.count = n
        return out
    }

    static func make(dataDescriptors: Bool = false, store: Bool = false, zip64: Bool = false, _ entries: [Entry]) -> Data {
        var out = Data()
        var central = Data()
        for e in entries {
            let name = Data(e.name.utf8)
            let payload = store ? e.bytes : deflate(e.bytes)
            let crc = CRC32.checksum(e.bytes)
            let offset = UInt32(out.count)
            let flags: UInt16 = e.flags | 0x800 | (dataDescriptors ? 0x8 : 0)
            let method: UInt16 = store ? 0 : 8
            le32(0x0403_4b50, &out); le16(20, &out); le16(flags, &out); le16(method, &out); le16(0, &out); le16(0x21, &out)
            le32(dataDescriptors ? 0 : crc, &out)
            le32(dataDescriptors ? 0 : UInt32(payload.count), &out)
            le32(dataDescriptors ? 0 : UInt32(e.bytes.count), &out)
            le16(UInt16(name.count), &out); le16(0, &out)
            out.append(name)
            out.append(payload)
            if dataDescriptors {
                le32(0x0807_4b50, &out); le32(crc, &out); le32(UInt32(payload.count), &out); le32(UInt32(e.bytes.count), &out)
            }
            le32(0x0201_4b50, &central); le16(zip64 ? 45 : 20, &central); le16(zip64 ? 45 : 20, &central)
            le16(flags, &central); le16(method, &central); le16(0, &central); le16(0x21, &central)
            le32(crc, &central)
            le32(zip64 ? 0xFFFF_FFFF : UInt32(payload.count), &central)
            le32(zip64 ? 0xFFFF_FFFF : UInt32(e.bytes.count), &central)
            le16(UInt16(name.count), &central); le16(zip64 ? 28 : 0, &central); le16(0, &central)
            le16(0, &central); le16(0, &central); le32(0, &central)
            le32(zip64 ? 0xFFFF_FFFF : offset, &central)
            central.append(name)
            if zip64 {
                le16(0x0001, &central); le16(24, &central)
                le64(UInt64(e.bytes.count), &central); le64(UInt64(payload.count), &central); le64(UInt64(offset), &central)
            }
        }
        let cdOffset = out.count
        out.append(central)
        if zip64 {
            let recordOffset = out.count
            le32(0x0606_4b50, &out); le64(44, &out); le16(45, &out); le16(45, &out); le32(0, &out); le32(0, &out)
            le64(UInt64(entries.count), &out); le64(UInt64(entries.count), &out)
            le64(UInt64(central.count), &out); le64(UInt64(cdOffset), &out)
            le32(0x0706_4b50, &out); le32(0, &out); le64(UInt64(recordOffset), &out); le32(1, &out)
            le32(0x0605_4b50, &out); le16(0, &out); le16(0, &out); le16(0xFFFF, &out); le16(0xFFFF, &out)
            le32(0xFFFF_FFFF, &out); le32(0xFFFF_FFFF, &out); le16(0, &out)
        } else {
            le32(0x0605_4b50, &out); le16(0, &out); le16(0, &out)
            le16(UInt16(entries.count), &out); le16(UInt16(entries.count), &out)
            le32(UInt32(central.count), &out); le32(UInt32(cdOffset), &out); le16(0, &out)
        }
        return out
    }

    static func make(dataDescriptors: Bool = false, _ entries: [(String, Data)]) -> Data {
        make(dataDescriptors: dataDescriptors, entries.map { Entry(name: $0.0, bytes: $0.1) })
    }
}

/// Runs an async throwing block and returns its error (XCTAssertThrowsError for async code).
func asyncError(_ body: () async throws -> Void, file: StaticString = #filePath, line: UInt = #line) async -> Error? {
    do {
        try await body()
        XCTFail("Expected an error", file: file, line: line)
        return nil
    } catch {
        return error
    }
}
