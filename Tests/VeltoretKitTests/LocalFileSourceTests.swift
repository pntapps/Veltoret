import XCTest
@testable import VeltoretKit

final class LocalFileSourceTests: XCTestCase {
    private var dir: String!
    private let src = LocalFileSource()

    override func setUp() {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("veltoret-tests/\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        dir = LocalFileSource.normalize(base.path)
    }

    override func tearDown() { try? FileManager.default.removeItem(atPath: dir) }

    private func write(_ name: String, _ text: String = "x") {
        FileManager.default.createFile(atPath: dir + "/" + name, contents: Data(text.utf8))
    }

    func testRootListsPlacesAndVolumes() async throws {
        XCTAssertEqual(LocalFileSource.root, src.rootId(Accounts.device))
        XCTAssertEqual("This Mac", src.rootName(Accounts.device))
        let places = try await src.list(Accounts.device, folderId: LocalFileSource.root)
        XCTAssertFalse(places.isEmpty)
        XCTAssertTrue(places.allSatisfy { $0.isFolder && !$0.canTrash && $0.parents == [LocalFileSource.root] })
        XCTAssertEqual(FileManager.default.homeDirectoryForCurrentUser.path.trimmingCharacters(in: CharacterSet(charactersIn: "/")),
                       places[0].id.trimmingCharacters(in: CharacterSet(charactersIn: "/")))
        XCTAssertFalse(places.contains { $0.id == "/" })
    }

    func testListsFoldersFirstWithMimeTypesAndSkipsHidden() async throws {
        write("b.mkv"); write("a.srt"); write(".DS_Store"); write("A10.mkv"); write("A9.mkv")
        try FileManager.default.createDirectory(atPath: dir + "/Season 1", withIntermediateDirectories: false)
        let items = try await src.list(Accounts.device, folderId: dir + "/")
        XCTAssertEqual(["Season 1", "a.srt", "A9.mkv", "A10.mkv", "b.mkv"], items.map(\.name))
        XCTAssertTrue(items[0].isFolder)
        let mkv = items[4]
        XCTAssertEqual("video/x-matroska", mkv.mimeType)
        XCTAssertEqual(1, mkv.sizeBytes)
        XCTAssertEqual(dir + "/b.mkv", mkv.id)
        XCTAssertEqual(dir, mkv.parents[0])
        XCTAssertNotNil(mkv.modifiedTime)
        let hits = try await src.search(Accounts.device, query: "SEASON", currentFolder: dir)
        XCTAssertEqual(1, hits.count)
    }

    func testMissingFolderExplains() async {
        do {
            _ = try await src.list(Accounts.device, folderId: dir + "/nope")
            XCTFail("expected an error")
        } catch {
            XCTAssertTrue((error as? LocalFileError)?.message.hasPrefix("This folder isn't available") == true)
        }
    }

    func testRenameMoveCreateReadAndTrash() async throws {
        write("old.mkv", "hello")
        let renamed = try await src.rename(Accounts.device, id: dir + "/old.mkv", newName: " new.mkv ")
        XCTAssertEqual(dir + "/new.mkv", renamed)
        XCTAssertTrue(FileManager.default.fileExists(atPath: renamed))
        let caseOnly = try await src.rename(Accounts.device, id: renamed, newName: "New.mkv")
        XCTAssertEqual(dir + "/New.mkv", caseOnly)

        try await src.createFolder(Accounts.device, parentId: dir, name: "Sub")
        try await src.move(Accounts.device, id: caseOnly, fromParent: dir, toParent: dir + "/Sub")
        let moved = dir + "/Sub/New.mkv"
        XCTAssertTrue(FileManager.default.fileExists(atPath: moved))

        let s = try await src.openRead(Accounts.device, id: moved)
        XCTAssertEqual(5, s.length)
        let chunk = try await s.read(at: 1, count: 3)
        XCTAssertEqual(Data("ell".utf8), chunk)
        s.close()

        let space = try await src.space(Accounts.device, folderId: dir)
        XCTAssertNotNil(space)
        XCTAssertGreaterThan(space?.total ?? 0, 0)
        XCTAssertNotNil(src.spaceKey(Accounts.device, folderId: dir))
        XCTAssertNil(src.spaceKey(Accounts.device, folderId: LocalFileSource.root))

        do {
            try await src.createFolder(Accounts.device, parentId: dir, name: "a/b")
            XCTFail("expected an error")
        } catch {}

        try await src.remove(Accounts.device, id: moved)
        XCTAssertFalse(FileManager.default.fileExists(atPath: moved))
    }

    func testNormalize() {
        XCTAssertEqual("/", LocalFileSource.normalize("/"))
        XCTAssertEqual("/Users/x/Movies", LocalFileSource.normalize("/Users/x/Movies/"))
        XCTAssertEqual("/Users/x", LocalFileSource.normalize("/Users/x/Movies/.."))
    }

    func testMimeTypes() {
        XCTAssertEqual("video/x-matroska", MimeTypes.forName("A.MKV"))
        XCTAssertEqual("application/x-subrip", MimeTypes.forName("a.en.srt"))
        XCTAssertEqual("application/octet-stream", MimeTypes.forName("noext"))
    }
}
