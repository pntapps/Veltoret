import XCTest
import VeltoretKit
@testable import VeltoretPlayerKit

/// A FileSource serving in-memory files (DataByteSource), counting opens and closes.
private final class MemoryFileSource: FileSource, @unchecked Sendable {
    let files: [String: Data]
    private let lock = NSLock()
    private(set) var opened = 0
    private(set) var closed = 0
    var failOpen = false

    init(_ files: [String: Data]) { self.files = files }

    final class Counting: ByteSource, @unchecked Sendable {
        let inner: DataByteSource
        let onClose: () -> Void
        init(_ d: Data, onClose: @escaping () -> Void) { inner = DataByteSource(d); self.onClose = onClose }
        var length: Int64 { inner.length }
        func read(at offset: Int64, count: Int) async throws -> Data { try await inner.read(at: offset, count: count) }
        func close() { onClose() }
    }

    var counts: (Int, Int) { lock.lock(); defer { lock.unlock() }; return (opened, closed) }

    func handles(_ account: String) -> Bool { account == "mem@test" }
    func rootId(_ account: String) -> String { "root" }
    func rootName(_ account: String) -> String { "Memory" }
    func list(_ account: String, folderId: String) async throws -> [StorageItem] { [] }
    func search(_ account: String, query: String, currentFolder: String) async throws -> [StorageItem] { [] }
    func rename(_ account: String, id: String, newName: String) async throws -> String { id }
    func remove(_ account: String, id: String) async throws {}
    func deletePermanently(_ account: String, id: String) async throws {}
    func space(_ account: String, folderId: String) async throws -> StorageSpace? { nil }
    func spaceKey(_ account: String, folderId: String) -> String? { nil }
    func move(_ account: String, id: String, fromParent: String?, toParent: String) async throws {}
    func createFolder(_ account: String, parentId: String, name: String) async throws {}
    func openRead(_ account: String, id: String) async throws -> ByteSource {
        if failOpen { throw URLError(.fileDoesNotExist) }
        guard let d = files[id] else { throw URLError(.fileDoesNotExist) }
        lock.lock(); opened += 1; lock.unlock()
        return Counting(d) { [weak self] in
            guard let self else { return }
            self.lock.lock(); self.closed += 1; self.lock.unlock()
        }
    }
}

final class MediaStreamServerTests: XCTestCase {
    private var source: MemoryFileSource!
    private var server: MediaStreamServer!
    private let big: Data = {
        var d = Data(count: 3 * 1024 * 1024 + 123)
        d.withUnsafeMutableBytes { p in for i in 0..<p.count { p[i] = UInt8(truncatingIfNeeded: i &* 31 &+ i >> 8) } }
        return d
    }()

    override func setUpWithError() throws {
        try AppServices.initForTests()
        source = MemoryFileSource(["big": big, "small": Data("hello world".utf8)])
        AppServices.storage.register(source)
        server = MediaStreamServer()
    }

    override func tearDown() { server.stop() }

    private func fetch(_ url: URL, method: String = "GET", range: String? = nil) async throws -> (Data, HTTPURLResponse) {
        var req = URLRequest(url: url)
        req.httpMethod = method
        req.cachePolicy = .reloadIgnoringLocalCacheData
        if let range { req.setValue(range, forHTTPHeaderField: "Range") }
        let (data, resp) = try await URLSession.shared.data(for: req)
        return (data, resp as! HTTPURLResponse)
    }

    func testUrlIsLoopbackWithToken() async throws {
        let url = try await server.url(account: "mem@test", fileId: "big", name: "My Movie (2020).mkv", mime: nil)
        XCTAssertEqual("127.0.0.1", url.host)
        XCTAssertEqual("http", url.scheme)
        XCTAssertEqual(4, url.pathComponents.count) // "/", token, entry, name
        XCTAssertEqual("My Movie (2020).mkv", url.lastPathComponent)
        let again = try await server.url(account: "mem@test", fileId: "big", name: "My Movie (2020).mkv", mime: nil)
        XCTAssertEqual(url, again)
    }

    func testWholeFileAndRanges() async throws {
        let url = try await server.url(account: "mem@test", fileId: "big", name: "a.mkv", mime: nil)

        let (all, r0) = try await fetch(url)
        XCTAssertEqual(200, r0.statusCode)
        XCTAssertEqual(big, all)
        XCTAssertEqual("bytes", r0.value(forHTTPHeaderField: "Accept-Ranges"))
        XCTAssertEqual("video/x-matroska", r0.value(forHTTPHeaderField: "Content-Type"))

        let (part, r1) = try await fetch(url, range: "bytes=100-199")
        XCTAssertEqual(206, r1.statusCode)
        XCTAssertEqual(big.subdata(in: 100..<200), part)
        XCTAssertEqual("bytes 100-199/\(big.count)", r1.value(forHTTPHeaderField: "Content-Range"))
        XCTAssertEqual("100", r1.value(forHTTPHeaderField: "Content-Length"))

        // Seeking near the end (open-ended), across chunk boundaries.
        let from = big.count - 1_500_000
        let (tail, r2) = try await fetch(url, range: "bytes=\(from)-")
        XCTAssertEqual(206, r2.statusCode)
        XCTAssertEqual(big.subdata(in: from..<big.count), tail)

        let (suffix, r3) = try await fetch(url, range: "bytes=-10")
        XCTAssertEqual(206, r3.statusCode)
        XCTAssertEqual(big.suffix(10), suffix)

        // An end past the file is clamped.
        let (clamped, r4) = try await fetch(url, range: "bytes=\(big.count - 5)-\(big.count + 1000)")
        XCTAssertEqual(206, r4.statusCode)
        XCTAssertEqual(big.suffix(5), clamped)

        let (_, r5) = try await fetch(url, range: "bytes=\(big.count)-")
        XCTAssertEqual(416, r5.statusCode)
        XCTAssertEqual("bytes */\(big.count)", r5.value(forHTTPHeaderField: "Content-Range"))
    }

    func testHead() async throws {
        let url = try await server.url(account: "mem@test", fileId: "small", name: "a.srt", mime: "text/plain")
        let (body, r) = try await fetch(url, method: "HEAD")
        XCTAssertEqual(200, r.statusCode)
        XCTAssertTrue(body.isEmpty)
        XCTAssertEqual("11", r.value(forHTTPHeaderField: "Content-Length"))
        XCTAssertEqual("text/plain", r.value(forHTTPHeaderField: "Content-Type"))
        let (b2, r2) = try await fetch(url, range: "bytes=6-")
        XCTAssertEqual(206, r2.statusCode)
        XCTAssertEqual("world", String(decoding: b2, as: UTF8.self))
    }

    func testWrongTokenOrEntryIs404() async throws {
        let url = try await server.url(account: "mem@test", fileId: "small", name: "a.srt", mime: nil)
        var c = URLComponents(url: url, resolvingAgainstBaseURL: false)!
        let parts = url.pathComponents
        c.path = "/" + String(repeating: "0", count: parts[1].count) + "/" + parts[2] + "/a.srt"
        let (_, r) = try await fetch(c.url!)
        XCTAssertEqual(404, r.statusCode)
        c.path = "/" + parts[1] + "/nope/a.srt"
        let (_, r2) = try await fetch(c.url!)
        XCTAssertEqual(404, r2.statusCode)
    }

    func testConcurrentRequests() async throws {
        let url = try await server.url(account: "mem@test", fileId: "big", name: "a.mkv", mime: nil)
        let bigCopy = big
        try await withThrowingTaskGroup(of: Void.self) { group in
            for i in 0..<8 {
                group.addTask {
                    let start = i * 300_000
                    let end = start + 1_200_000 - 1
                    var req = URLRequest(url: url)
                    req.setValue("bytes=\(start)-\(end)", forHTTPHeaderField: "Range")
                    let (d, resp) = try await URLSession.shared.data(for: req)
                    XCTAssertEqual(206, (resp as! HTTPURLResponse).statusCode)
                    XCTAssertEqual(bigCopy.subdata(in: start..<min(end + 1, bigCopy.count)), d)
                }
            }
            try await group.waitForAll()
        }
    }

    func testSourcesCloseWhenConnectionsEnd() async throws {
        let url = try await server.url(account: "mem@test", fileId: "big", name: "a.mkv", mime: nil)
        let session = URLSession(configuration: .ephemeral)
        var req = URLRequest(url: url)
        req.setValue("bytes=0-99", forHTTPHeaderField: "Range")
        _ = try await session.data(for: req)
        req.setValue("bytes=100-199", forHTTPHeaderField: "Range")
        _ = try await session.data(for: req)
        session.invalidateAndCancel()
        server.stop()
        for _ in 0..<50 {
            let (o, c) = source.counts
            if o > 0 && o == c { break }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        let (opened, closed) = source.counts
        XCTAssertGreaterThan(opened, 0)
        XCTAssertEqual(opened, closed)
    }

    func testOpenFailureIsReported() async throws {
        let url = try await server.url(account: "mem@test", fileId: "small", name: "a.srt", mime: nil)
        source.failOpen = true
        let exp = expectation(description: "reported")
        let sub = server.streamFailed.subscribe { f in if f.fileId == "small" { exp.fulfill() } }
        let (_, r) = try await fetch(url)
        XCTAssertEqual(502, r.statusCode)
        await fulfillment(of: [exp], timeout: 5)
        XCTAssertNotNil(server.lastError(account: "mem@test", fileId: "small"))
        sub.cancel()
    }

    func testRangeParsing() {
        XCTAssertEqual(.whole, MediaStreamServer.parseRange(nil, length: 10))
        XCTAssertEqual(.range(2, 9), MediaStreamServer.parseRange("bytes=2-", length: 10))
        XCTAssertEqual(.range(7, 9), MediaStreamServer.parseRange("bytes=-3", length: 10))
        XCTAssertEqual(.range(0, 9), MediaStreamServer.parseRange("bytes=-30", length: 10))
        XCTAssertEqual(.range(2, 4), MediaStreamServer.parseRange("bytes=2-4", length: 10))
        XCTAssertEqual(.unsatisfiable, MediaStreamServer.parseRange("bytes=10-", length: 10))
        XCTAssertEqual(.whole, MediaStreamServer.parseRange("items=1-2", length: 10))
    }
}
