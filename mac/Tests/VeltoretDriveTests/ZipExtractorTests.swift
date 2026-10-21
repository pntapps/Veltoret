import Foundation
import XCTest
import VeltoretKit
@testable import VeltoretDrive

final class ZipExtractorTests: XCTestCase {
    private let chunk = 8 * 1024 * 1024

    private func setup(_ zip: Data, zipName: String = "Show.S01.zip") -> (FakeDriveClient, String, String) {
        let drive = FakeDriveClient()
        let parent = drive.add("root", "Shows", folder: true)
        let zipId = drive.add(parent, zipName, zip)
        return (drive, parent, zipId)
    }

    private func run(_ drive: FakeDriveClient, _ parent: String, _ zipId: String, after: ZipAfterExtract = .keep,
                     zipName: String = "Show.S01.zip") async throws -> ExtractResult {
        try await ZipExtractor(drive: drive).run("a@b.c", zipId: zipId, zipName: zipName, parentId: parent, after: after) { _ in }
    }

    private func filePaths(_ drive: FakeDriveClient, except zipId: String) -> [String: Data] {
        var out: [String: Data] = [:]
        for item in drive.items.values where !item.file.isFolder && item.file.id != zipId {
            out[drive.pathOf(item.file.id)!] = item.bytes
        }
        return out
    }

    func testEntriesArriveByteIdenticalInAFolderNamedAfterTheZip() async throws {
        for dataDescriptors in [false, true] {
            let e1 = randomBytes(4, chunk + 500)
            let e2 = randomBytes(5, 3000)
            let (drive, parent, zipId) = setup(TestZip.make(dataDescriptors: dataDescriptors,
                                                            [("Season 1/S01E01.mkv", e1), ("Season 1/S01E02.mkv", e2)]))

            let result = try await run(drive, parent, zipId)

            XCTAssertEqual(result.count, 2)
            XCTAssertNil(result.zipNote)
            XCTAssertEqual(drive.items[result.folderId]?.file.name, "Show.S01")
            let files = filePaths(drive, except: zipId)
            XCTAssertEqual(files["Shows/Show.S01/Season 1/S01E01.mkv"], e1)
            XCTAssertEqual(files["Shows/Show.S01/Season 1/S01E02.mkv"], e2)
            XCTAssertNotNil(drive.items[zipId]) // Keep
        }
    }

    func testStoredAndZip64EntriesAreRead() async throws {
        let e1 = randomBytes(8, 70_000)
        let e2 = Data()
        for (store, zip64) in [(true, false), (true, true), (false, true)] {
            let zip = TestZip.make(store: store, zip64: zip64, [TestZip.Entry(name: "a/one.mkv", bytes: e1),
                                                                TestZip.Entry(name: "two.srt", bytes: e2)])
            let (drive, parent, zipId) = setup(zip)
            let result = try await run(drive, parent, zipId)
            XCTAssertEqual(result.count, 2, "store \(store) zip64 \(zip64)")
            let files = filePaths(drive, except: zipId)
            XCTAssertEqual(files["Shows/Show.S01/a/one.mkv"], e1)
            XCTAssertEqual(files["Shows/Show.S01/two.srt"], e2)
        }
    }

    func testJunkIsSkippedAndDotDotSegmentsCantEscapeTheFolder() async throws {
        let (drive, parent, zipId) = setup(TestZip.make([
            ("__MACOSX/Season 1/._S01E01.mkv", Data(count: 10)),
            ("Season 1/._S01E01.mkv", Data(count: 10)),
            ("Season 1/.DS_Store", Data(count: 10)),
            ("Thumbs.db", Data(count: 10)),
            ("desktop.ini", Data(count: 10)),
            ("../../evil.mkv", Data(count: 20)),
            ("Season 1/./../S01E03.mkv", Data(count: 30)),
        ]))

        let result = try await run(drive, parent, zipId)

        XCTAssertEqual(result.count, 2)
        XCTAssertEqual(filePaths(drive, except: zipId).keys.sorted(), ["Shows/Show.S01/Season 1/S01E03.mkv", "Shows/Show.S01/evil.mkv"])
    }

    func testResumeSkipsFilesAlreadyThereWithTheSameSize() async throws {
        let e1 = randomBytes(6, 5000)
        let e2 = randomBytes(7, 6000)
        let (drive, parent, zipId) = setup(TestZip.make([("S01E01.mkv", e1), ("S01E02.mkv", e2)]))
        let earlier = drive.add(parent, "Show.S01", folder: true)
        drive.add(earlier, "S01E01.mkv", e1)            // finished on an earlier run
        drive.add(earlier, "S01E02.mkv", Data(count: 100)) // cut short: different size, uploaded again

        let result = try await run(drive, parent, zipId)

        XCTAssertEqual(result.folderId, earlier)
        XCTAssertEqual(result.count, 2)
        XCTAssertEqual(drive.uploadCalls, 1)
    }

    func testArchiveIsRemovedOnlyAfterEverythingWasExtracted() async throws {
        for (after, note) in [(ZipAfterExtract.trash, "ZIP moved to trash"), (.delete, "ZIP deleted")] {
            let (drive, parent, zipId) = setup(TestZip.make([("S01E01.mkv", Data(count: 100))]))
            var forgotten: [String] = []
            let result = try await ZipExtractor(drive: drive, forgetArchive: { forgotten.append($0) })
                .run("a@b.c", zipId: zipId, zipName: "Show.S01.zip", parentId: parent, after: after) { _ in }
            XCTAssertEqual(result.zipNote, note)
            XCTAssertEqual(forgotten, [zipId])
            XCTAssertEqual(drive.trashed.contains(zipId), after == .trash)
            XCTAssertEqual(drive.deleted.contains(zipId), after == .delete)
        }
    }

    func testArchiveThatProducedNothingIsKept() async throws {
        for after in [ZipAfterExtract.trash, .delete] {
            let (drive, parent, zipId) = setup(TestZip.make([("__MACOSX/x", Data(count: 3)), (".DS_Store", Data(count: 3))]))
            let result = try await run(drive, parent, zipId, after: after)
            XCTAssertEqual(result.count, 0)
            XCTAssertNil(result.zipNote)
            XCTAssertTrue(drive.trashed.isEmpty)
            XCTAssertTrue(drive.deleted.isEmpty)
        }
    }

    func testArchiveIsKeptWhenAnUploadFails() async {
        let (drive, parent, zipId) = setup(TestZip.make([("a.mkv", Data(count: 10)), ("b.mkv", Data(count: 10))]))
        drive.uploadFailure = { $0 == "b.mkv" ? DriveIOError("network") : nil }
        let e = await asyncError { _ = try await self.run(drive, parent, zipId, after: .delete) }
        XCTAssertTrue(e is DriveIOError)
        XCTAssertTrue(drive.deleted.isEmpty)
    }

    func testFullDriveFailsWithCountAndAdvice() async {
        let (drive, parent, zipId) = setup(TestZip.make([("a.mkv", Data(count: 10)), ("b.mkv", Data(count: 10))]))
        drive.uploadFailure = { $0 == "b.mkv" ? DriveStorageFullError() : nil }
        let e = await asyncError { _ = try await self.run(drive, parent, zipId) }
        XCTAssertEqual((e as? ExtractFailedError)?.message,
                       "Google Drive is full after 1 file. Free up space (and empty Drive's trash), then extract again: it continues where it stopped.")
    }

    func testDamagedZipIsReported() async {
        let whole = TestZip.make([("a.mkv", Data(count: 200_000)), ("b.mkv", Data(count: 200_000))])
        // Cut off part-way through the first entry's compressed data.
        let (drive, parent, zipId) = setup(whole.prefix(60))
        let e = await asyncError { _ = try await self.run(drive, parent, zipId) }
        // Either flagged as an unreadable archive (no retry) or as a read error the job retries.
        XCTAssertTrue(e is ExtractFailedError || e is DriveIOError, "\(String(describing: e))")
    }

    func testCorruptDataIsCaughtByTheCrc() async {
        var zip = TestZip.make(store: true, zip64: false, [TestZip.Entry(name: "a.mkv", bytes: randomBytes(9, 1000))])
        zip[30 + 5 + 10] ^= 0xFF // a byte inside the stored data
        let (drive, parent, zipId) = setup(zip)
        let e = await asyncError { _ = try await self.run(drive, parent, zipId) }
        XCTAssertTrue((e as? ExtractFailedError)?.message.hasPrefix("The ZIP looks damaged or incomplete") ?? false, "\(String(describing: e))")
    }

    func testEncryptedZipIsRefused() async {
        let zip = TestZip.make(store: true, zip64: false, [TestZip.Entry(name: "a.mkv", bytes: Data(count: 10), flags: 1)])
        let (drive, parent, zipId) = setup(zip)
        let e = await asyncError { _ = try await self.run(drive, parent, zipId) }
        XCTAssertEqual((e as? ExtractFailedError)?.message, "This ZIP is password-protected, which isn't supported.")
    }

    func testCrc32() {
        XCTAssertEqual(CRC32.checksum(Data("123456789".utf8)), 0xCBF4_3926)
    }

    // MARK: - TransferService

    private func tempJobs() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("veltoret-test-\(UUID().uuidString).json")
    }

    private func finished(_ service: TransferService, _ start: () -> Void) async throws -> TransferJob {
        let exp = expectation(description: "finished")
        var job: TransferJob?
        let sub = service.jobFinished.subscribe { j in
            if job == nil { job = j; exp.fulfill() }
        }
        defer { sub.cancel() }
        start()
        await fulfillment(of: [exp], timeout: 20)
        return try XCTUnwrap(job)
    }

    func testQuotaErrorFailsTheJobWithoutRetry() async throws {
        let (drive, parent, zipId) = setup(TestZip.make([("a.mkv", Data(count: 10))]))
        drive.uploadFailure = { _ in DriveStorageFullError() }
        let path = tempJobs()
        defer { try? FileManager.default.removeItem(at: path) }
        let service = TransferService(drive: drive, jobsURL: path)
        service.backoff = [0]
        let job = try await finished(service) {
            service.extract(account: "a@b.c", zipId: zipId, zipName: "Show.S01.zip", zipSize: 100, parentId: parent, after: .keep, wifiOnly: false)
        }
        XCTAssertEqual(job.state, .failed)
        XCTAssertEqual(job.attempt, 1)
        XCTAssertEqual(drive.downloads, 1)
        XCTAssertTrue(job.error?.hasPrefix("Google Drive is full.") ?? false, job.error ?? "")
    }

    func testNetworkErrorsAreRetriedFourTimesThenFail() async throws {
        let (drive, parent, zipId) = setup(TestZip.make([("a.mkv", Data(count: 10))]))
        drive.uploadFailure = { _ in DriveIOError("Connection reset") }
        let path = tempJobs()
        defer { try? FileManager.default.removeItem(at: path) }
        let service = TransferService(drive: drive, jobsURL: path)
        service.backoff = [0]
        let job = try await finished(service) {
            let first = service.extract(account: "a@b.c", zipId: zipId, zipName: "Show.S01.zip", zipSize: 100, parentId: parent,
                                        after: .keep, wifiOnly: false)
            // Extracting the same ZIP again while it runs doesn't start a second job.
            XCTAssertEqual(first.id, service.extract(account: "a@b.c", zipId: zipId, zipName: "Show.S01.zip", zipSize: 100,
                                                     parentId: parent, after: .keep, wifiOnly: false).id)
        }
        XCTAssertEqual(job.state, .failed)
        XCTAssertEqual(job.attempt, 4)
        XCTAssertEqual(drive.downloads, 4)
        XCTAssertEqual(job.error, "Connection reset")

        // Jobs survive a restart: the failed one is still listed.
        let reloaded = TransferService(drive: drive, jobsURL: path)
        XCTAssertTrue(reloaded.jobs.contains { $0.id == job.id && $0.state == .failed })
    }

    func testUploadJobUploadsTheLocalFile() async throws {
        let drive = FakeDriveClient()
        let parent = drive.add("root", "Movies", folder: true)
        let local = FileManager.default.temporaryDirectory.appendingPathComponent("veltoret-upload-\(UUID().uuidString).mkv")
        let path = tempJobs()
        let bytes = randomBytes(9, 12345)
        try bytes.write(to: local)
        defer {
            try? FileManager.default.removeItem(at: local)
            try? FileManager.default.removeItem(at: path)
        }
        let service = TransferService(drive: drive, jobsURL: path)
        service.backoff = [0]
        let job = try await finished(service) { service.upload(account: "a@b.c", parentId: parent, url: local) }
        XCTAssertEqual(job.state, .succeeded)
        let uploaded = drive.children(parent)
        XCTAssertEqual(uploaded.count, 1)
        XCTAssertEqual(uploaded.first?.file.name, local.lastPathComponent)
        XCTAssertEqual(uploaded.first?.bytes, bytes)
    }

    func testMissingLocalFileFailsAtOnce() async throws {
        let drive = FakeDriveClient()
        let path = tempJobs()
        defer { try? FileManager.default.removeItem(at: path) }
        let service = TransferService(drive: drive, jobsURL: path)
        service.backoff = [0]
        let job = try await finished(service) {
            service.upload(account: "a@b.c", parentId: "root", url: URL(fileURLWithPath: "/nonexistent/veltoret-\(UUID().uuidString).mkv"))
        }
        XCTAssertEqual(job.state, .failed)
        XCTAssertEqual(job.attempt, 1)
        XCTAssertEqual(job.error, "The file is no longer on this Mac")
    }

    func testJobsWaitWhileOffline() async throws {
        let (drive, parent, zipId) = setup(TestZip.make([("a.mkv", Data(count: 10))]))
        let path = tempJobs()
        defer { try? FileManager.default.removeItem(at: path) }
        let service = TransferService(drive: drive, jobsURL: path)
        service.constraintPoll = 0.05
        let online = Flag()
        service.isOnline = { online.value }
        let waiting = expectation(description: "waiting")
        var sawWaiting = false
        let sub = service.jobChanged.subscribe { j in
            if j.state == .waiting && !sawWaiting { sawWaiting = true; waiting.fulfill() }
        }
        defer { sub.cancel() }
        service.extract(account: "a@b.c", zipId: zipId, zipName: "Show.S01.zip", zipSize: 100, parentId: parent, after: .keep, wifiOnly: false)
        await fulfillment(of: [waiting], timeout: 5)
        XCTAssertEqual(drive.downloads, 0)
        let job = try await finished(service) { online.value = true }
        XCTAssertEqual(job.state, .succeeded)
        XCTAssertEqual(job.count, 1)
    }

    func testCheckExtract() async {
        let drive = FakeDriveClient()
        let parent = drive.add("root", "Shows", folder: true)
        drive.free = 50
        let service = TransferService(drive: drive, jobsURL: tempJobs())
        var check = await service.checkExtract(account: "a@b.c", zipName: "Show.S01.zip", zipSize: 100, parentId: parent)
        XCTAssertTrue(check.tooBig)
        drive.add(parent, "Show.S01", folder: true)
        check = await service.checkExtract(account: "a@b.c", zipName: "Show.S01.zip", zipSize: 100, parentId: parent)
        XCTAssertTrue(check.resuming)
        XCTAssertFalse(check.tooBig)
    }

    func testJunk() {
        let cases: [(String, Bool)] = [
            ("__MACOSX/a/b.mkv", true), ("Season 1/._S01E01.mkv", true), ("x/.DS_Store", true), ("Thumbs.db", true),
            ("a/desktop.ini", true), ("Season 1/S01E01.mkv", false), ("MACOSX/a.mkv", false),
        ]
        for (path, junk) in cases { XCTAssertEqual(ZipExtractor.isJunk(path), junk, path) }
    }
}

final class Flag: @unchecked Sendable {
    private let lock = NSLock()
    private var v = false
    var value: Bool {
        get { lock.withLock { v } }
        set { lock.withLock { v = newValue } }
    }
}
