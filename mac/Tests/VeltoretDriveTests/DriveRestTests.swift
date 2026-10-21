import Foundation
import XCTest
import VeltoretKit
@testable import VeltoretDrive

final class DriveRestTests: XCTestCase {
    private func repo(_ answer: @escaping (URLRequest) -> HttpResponse) -> DriveRepository {
        DriveRepository(http: DriveAuthTransport(tokens: FixedTokens(), inner: Answer(answer)))
    }

    private func query(_ url: URL?) -> String { (url?.query ?? "").removingPercentEncoding ?? "" }

    func testListFollowsPagesWithEscapedQuery() async throws {
        var urls: [URL] = []
        let drive = repo { r in
            urls.append(r.url!)
            let second = r.url!.query!.contains("pageToken=")
            let json = second
                ? #"{"files":[{"id":"2","name":"b","mimeType":"video/x-matroska","size":"12345678901"}]}"#
                : #"{"nextPageToken":"p2","files":[{"id":"1","name":"a","mimeType":"application/vnd.google-apps.folder"}]}"#
            return HttpResponse(status: 200, json: json)
        }
        let files = try await drive.listChildren("a@b.c", folderId: "it's\\id")
        XCTAssertEqual(files.count, 2)
        XCTAssertTrue(files[0].isFolder)
        XCTAssertEqual(files[1].sizeBytes, 12_345_678_901)
        XCTAssertEqual(urls.count, 2)
        let q = query(urls[0])
        XCTAssertTrue(q.contains("q='it\\'s\\\\id' in parents and trashed = false"), q)
        XCTAssertTrue(q.contains("orderBy=folder,name_natural"))
        XCTAssertTrue(q.contains("pageSize=1000"))
        XCTAssertTrue(q.contains("supportsAllDrives=true"))
        XCTAssertTrue(q.contains("includeItemsFromAllDrives=true"))
        XCTAssertFalse(q.contains("pageToken"))
        XCTAssertTrue(query(urls[1]).contains("pageToken=p2"))
    }

    func testSearchReadsOnlyTheFirstPage() async throws {
        var calls = 0
        let drive = repo { r in
            calls += 1
            XCTAssertTrue(r.url!.query!.contains("pageSize=200"))
            return HttpResponse(status: 200, json: #"{"nextPageToken":"more","files":[]}"#)
        }
        _ = try await drive.search("a@b.c", text: "dune")
        XCTAssertEqual(calls, 1)
    }

    func testTrashAndMoveSendTheRightBodies() async throws {
        var seen: [(method: String, url: String, body: String)] = []
        let drive = repo { r in
            seen.append((r.httpMethod!, r.url!.absoluteString.removingPercentEncoding!, String(decoding: r.httpBody ?? Data(), as: UTF8.self)))
            return HttpResponse(status: 200, json: #"{"id":"x"}"#)
        }
        try await drive.trash("a@b.c", id: "x")
        try await drive.move("a@b.c", id: "x", fromParent: "from", toParent: "to")
        try await drive.move("a@b.c", id: "x", fromParent: nil, toParent: "to")
        XCTAssertEqual(seen[0].method, "PATCH")
        XCTAssertEqual(seen[0].body, #"{"trashed":true}"#)
        XCTAssertEqual(seen[1].body, "{}")
        XCTAssertTrue(seen[1].url.contains("addParents=to"))
        XCTAssertTrue(seen[1].url.contains("removeParents=from"))
        XCTAssertFalse(seen[2].url.contains("removeParents"))
    }

    func testDeleteErrors() async {
        for (code, message) in [(403, "Only the owner of this file can delete it permanently"), (500, "Delete failed (HTTP 500)")] {
            let drive = repo { _ in HttpResponse(status: code) }
            let e = await asyncError { try await drive.deletePermanently("a@b.c", id: "x") }
            XCTAssertEqual((e as? DriveIOError)?.message, message)
        }
    }

    func testFreeBytes() async throws {
        let cases: [(String, Int64?)] = [
            (#"{"storageQuota":{"limit":"16106127360","usage":"4509715660"}}"#, 16_106_127_360 - 4_509_715_660),
            (#"{"storageQuota":{"usage":"4509715660"}}"#, nil),
            (#"{"storageQuota":{"limit":"100","usage":"200"}}"#, 0),
        ]
        for (json, free) in cases {
            let drive = repo { _ in HttpResponse(status: 200, json: json) }
            let got = try await drive.freeBytes("a@b.c")
            XCTAssertEqual(got, free)
        }
    }

    func testStorageSummaryText() {
        let space = DriveRepository.spaceFrom(StorageQuota(limit: "16106127360", usage: "4509715660"))!
        XCTAssertEqual(DriveFormat.storageSummary(space), "Google storage · 4.2 GB used of 15.0 GB · 10.8 GB free")
        XCTAssertFalse(DriveFormat.storageAlmostFull(space))
        XCTAssertTrue(DriveFormat.storageAlmostFull(StorageSpace(name: "Google storage", used: 90, total: 100, free: 10)))
        XCTAssertFalse(DriveFormat.storageAlmostFull(StorageSpace(name: "Google storage", used: 89, total: 100, free: 11)))
        XCTAssertNil(DriveFormat.storageFraction(StorageSpace(name: "Google storage", used: 5, total: nil, free: nil)))
        XCTAssertEqual(DriveFormat.storageSummary(StorageSpace(name: "Google storage", used: 0, total: nil, free: nil)),
                       "Google storage · 0 B used")
    }

    func testBytes() {
        let cases: [(Int64, String)] = [
            (0, "—"), (-5, "—"), (512, "512 B"), (1536, "2 KB"), (5 * 1024 * 1024, "5 MB"),
            (1_610_612_736, "1.5 GB"), (2_199_023_255_552, "2.0 TB"),
        ]
        for (n, text) in cases { XCTAssertEqual(DriveFormat.bytes(n), text, "\(n)") }
    }

    func testClock() {
        XCTAssertEqual(DriveFormat.clock(245_000), "4:05")
        XCTAssertEqual(DriveFormat.clock(3_729_000), "1:02:09")
    }

    func testDriveDateAndMime() {
        XCTAssertNil(DriveFormat.driveDate(nil))
        XCTAssertNil(DriveFormat.driveDate("not a date"))
        XCTAssertNotNil(DriveFormat.driveDate("2025-03-04T12:00:00.000Z"))
        XCTAssertEqual(DriveFormat.mimeFor("Movie.MKV"), "video/x-matroska")
        XCTAssertEqual(DriveFormat.mimeFor("noext"), "application/octet-stream")
    }

    /// A Drive file served by byte ranges, like alt=media.
    private final class RangeServer: HttpTransport, @unchecked Sendable {
        let data: Data
        var opens = 0
        init(_ data: Data) { self.data = data }
        func send(_ request: URLRequest) async throws -> HttpResponse {
            opens += 1
            XCTAssertTrue(request.url!.query!.contains("alt=media"))
            XCTAssertNotNil(request.value(forHTTPHeaderField: "Authorization"))
            let range = request.value(forHTTPHeaderField: "Range")!
            let from = Int(range.dropFirst("bytes=".count).dropLast())!
            if from >= data.count { return HttpResponse(status: 416) }
            return HttpResponse(status: 206, headers: ["Content-Range": "bytes \(from)-\(data.count - 1)/\(data.count)"],
                                body: data.subdata(in: from..<data.count))
        }
    }

    func testRangeStreamSeeksAndReadsTheRightBytes() async throws {
        let data = randomBytes(11, 10 * 1024 * 1024 + 123)
        let server = RangeServer(data)
        let drive = DriveRepository(http: DriveAuthTransport(tokens: FixedTokens(), inner: server))
        let s = DriveRangeStream(drive: drive, email: "a@b.c", id: "id", length: Int64(data.count))
        defer { s.close() }
        XCTAssertEqual(s.length, Int64(data.count))

        func check(_ at: Int, _ n: Int) async throws {
            let got = try await s.read(at: Int64(at), count: n)
            XCTAssertEqual(got.count, min(n, data.count - at))
            XCTAssertEqual(got, data.subdata(in: at..<(at + got.count)))
        }

        try await check(0, 1000)
        try await check(1000, 600_000)         // sequential: same connection
        try await check(2_000_000, 1000)       // short forward seek: read through
        let opensBefore = server.opens
        try await check(9_000_000, 3000)       // far seek: new range
        XCTAssertEqual(server.opens, opensBefore + 1)
        try await check(10, 10)                // backwards
        try await check(data.count - 50, 500)  // tail
        let end = try await s.read(at: Int64(data.count), count: 10)
        XCTAssertEqual(end.count, 0)
    }

    func testDriveFileSourceHandlesGoogleAccountsOnly() {
        let files = DriveFileSource(drive: repo { _ in HttpResponse(status: 500) })
        XCTAssertTrue(files.handles("a@b.c"))
        XCTAssertFalse(files.handles(Accounts.device))
        XCTAssertFalse(files.handles("smb://nas"))
        XCTAssertEqual(files.rootId("a@b.c"), "root")
        XCTAssertEqual(files.rootName("a@b.c"), "My Drive")
        XCTAssertEqual(files.spaceKey("a@b.c", folderId: "x"), "a@b.c")
        XCTAssertEqual(DriveFileSource.sharedRoot, "shared")
    }
}
