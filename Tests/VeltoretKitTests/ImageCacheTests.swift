import XCTest
@testable import VeltoretKit

final class ImageCacheTests: XCTestCase {
    private var dir: URL!

    override func setUp() {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("veltoret-tests/\(UUID().uuidString)")
    }

    override func tearDown() { try? FileManager.default.removeItem(at: dir) }

    private final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var n = 0
        var value: Int { lock.lock(); defer { lock.unlock() }; return n }
        func bump() { lock.lock(); n += 1; lock.unlock() }
    }

    func testDownloadsOnceAndServesFromDisk() async throws {
        let calls = Counter()
        let session = FakeHttp.session(delay: 0.05) { r in
            calls.bump()
            return r.url!.path.contains("missing") ? (404, Data()) : (200, Data([1, 2, 3]))
        }
        let cache = ImageCache(directory: dir, session: session)
        let url = "https://image.tmdb.org/t/p/w342/abc.jpg"
        let results = await withTaskGroup(of: URL?.self) { group -> [URL?] in
            for _ in 0..<5 { group.addTask { await cache.file(for: url) } }
            var out: [URL?] = []
            for await r in group { out.append(r) }
            return out
        }
        XCTAssertEqual(1, calls.value)
        XCTAssertTrue(results.allSatisfy { $0 == cache.path(for: url) })
        XCTAssertEqual(Data([1, 2, 3]), try Data(contentsOf: results[0]!))
        XCTAssertEqual(40, cache.path(for: url).lastPathComponent.count) // SHA-1 hex

        // Offline later: still served from disk.
        let again = ImageCache(directory: dir, session: FakeHttp.session { _ in nil })
        let offline = await again.file(for: url)
        XCTAssertEqual(results[0], offline)

        let missing = await cache.file(for: "https://image.tmdb.org/t/p/w342/missing.jpg")
        XCTAssertNil(missing)
        let none = await cache.file(for: nil)
        XCTAssertNil(none)
        await cache.prefetch([url, "https://image.tmdb.org/t/p/w500/abc.jpg"])
        XCTAssertEqual(3, calls.value)
    }

    func testTrimDropsLeastRecentlyUsedToNinetyPercent() throws {
        let cache = ImageCache(directory: dir, session: FakeHttp.session { _ in nil }, maxBytes: 1000)
        let fm = FileManager.default
        for i in 0..<5 {
            let f = cache.path(for: "u\(i)")
            fm.createFile(atPath: f.path, contents: Data(repeating: 0, count: 300))
            var url = f
            var v = URLResourceValues()
            v.contentAccessDate = Date(timeIntervalSince1970: TimeInterval(1000 * (i + 1)))
            v.contentModificationDate = Date(timeIntervalSince1970: TimeInterval(1000 * (i + 1)))
            try url.setResourceValues(v)
        }
        cache.trim()
        XCTAssertFalse(cache.isCached("u0"))
        XCTAssertFalse(cache.isCached("u1"))
        XCTAssertTrue(cache.isCached("u2")) // 900 bytes left: at the 90% target
        XCTAssertTrue(cache.isCached("u3"))
        XCTAssertTrue(cache.isCached("u4"))
    }
}
