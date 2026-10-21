import Foundation
import XCTest
import VeltoretKit
@testable import VeltoretDrive

/// Port of the Android DriveStreamingUploadTest: the resumable-upload protocol against a fake Drive, including
/// streams whose length is unknown (videos piped straight out of a ZIP).
final class DriveStreamingUploadTests: XCTestCase {
    private let chunk = 8 * 1024 * 1024

    private func repository(_ fake: FakeUploadTransport) -> DriveRepository {
        DriveRepository(http: DriveAuthTransport(tokens: FixedTokens(), inner: fake))
    }

    func testUnknownSizeStreamsInChunksAndDeclaresTotalAtTheEnd() async throws {
        let fake = FakeUploadTransport()
        let data = randomBytes(1, chunk * 2 + 12345)
        let file = try await repository(fake).upload("a@b.c", parentId: "p", name: "v.mkv", mimeType: "video/x-matroska", size: -1,
                                                      open: { DataByteStream(data) })
        XCTAssertEqual(file.id, "f1")
        XCTAssertEqual(fake.ranges, ["bytes 0-\(chunk - 1)/*", "bytes \(chunk)-\(2 * chunk - 1)/*",
                                     "bytes \(2 * chunk)-\(data.count - 1)/\(data.count)"])
        XCTAssertEqual(fake.received, data)
    }

    func testUnknownSizeExactMultipleFinishesWithEmptyFinalChunk() async throws {
        let fake = FakeUploadTransport()
        let data = randomBytes(2, chunk)
        try await repository(fake).upload("a@b.c", parentId: "p", name: "v.mkv", mimeType: "video/x-matroska", size: -1,
                                          open: { DataByteStream(data) })
        XCTAssertEqual(fake.ranges, ["bytes 0-\(chunk - 1)/*", "bytes */\(chunk)"])
    }

    func testKnownSizeStillWorks() async throws {
        let fake = FakeUploadTransport()
        let data = randomBytes(3, chunk + 10)
        try await repository(fake).upload("a@b.c", parentId: "p", name: "v.mkv", mimeType: "video/x-matroska",
                                          size: Int64(data.count), open: { DataByteStream(data) })
        XCTAssertEqual(fake.ranges, ["bytes 0-\(chunk - 1)/\(data.count)", "bytes \(chunk)-\(data.count - 1)/\(data.count)"])
    }

    /// Same piping the extractor uses: entries inflate straight into uploads, never touching disk.
    func testZipEntriesStreamStraightIntoUploads() async throws {
        let episodes = [("Season 1/S01E01.mkv", randomBytes(4, chunk + 500)), ("Season 1/S01E02.mkv", randomBytes(5, 3000))]
        let source = DataByteSource(TestZip.make(episodes))

        var uploaded: [Data] = []
        for entry in try await ZipArchive.entries(source) {
            let fake = FakeUploadTransport()
            let stream = try await ZipArchive.open(source, entry)
            try await repository(fake).upload("a@b.c", parentId: "p", name: entry.path, mimeType: "video/x-matroska",
                                              size: entry.uncompressedSize, open: { NonClosingStream(stream) })
            stream.close()
            uploaded.append(fake.received)
        }
        XCTAssertEqual(uploaded.count, episodes.count)
        for i in 0..<episodes.count { XCTAssertEqual(uploaded[i], episodes[i].1) }
    }

    func testFullDriveIsReportedAsSuch() async {
        let fake = FakeUploadTransport()
        fake.refuse = (403, #"{"error":{"code":403,"errors":[{"domain":"usageLimits","reason":"storageQuotaExceeded"}]}}"#)
        let e = await asyncError {
            try await self.repository(fake).upload("a@b.c", parentId: "p", name: "v.mkv", mimeType: "video/x-matroska", size: 10,
                                                   open: { DataByteStream(Data(count: 10)) })
        }
        XCTAssertTrue(e is DriveStorageFullError, "\(String(describing: e))")
    }

    func testOtherRefusalsStayOrdinaryErrors() async {
        let fake = FakeUploadTransport()
        fake.refuse = (403, #"{"error":{"errors":[{"reason":"insufficientFilePermissions"}]}}"#)
        let e = await asyncError {
            try await self.repository(fake).upload("a@b.c", parentId: "p", name: "v.mkv", mimeType: "video/x-matroska", size: 10,
                                                   open: { DataByteStream(Data(count: 10)) })
        }
        XCTAssertTrue(e is DriveIOError, "\(String(describing: e))")
    }
}
