import XCTest
import VeltoretKit
@testable import VeltoretSmb

/// Port of Windows SmbServerStoreTest (passwords: Keychain via SecretStoring instead of DPAPI).
final class SmbServerStoreTests: XCTestCase {
    private var dir: URL!
    private var file: URL { dir.appendingPathComponent("smb_servers.json") }
    private var secrets: MemorySecretStore!

    override func setUp() {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("veltoret-smb-test-\(UUID().uuidString)")
        secrets = MemorySecretStore()
    }

    override func tearDown() { try? FileManager.default.removeItem(at: dir) }

    func testSavesServersAndKeepsPasswordsOutOfTheFile() throws {
        let store = SmbServerStore(url: file, secrets: secrets)
        store.save(SmbServer(host: "NAS", username: "me", domain: "HOME", name: "MYNAS"), password: "s3cret pass")

        let server = try XCTUnwrap(store.server("smb://nas"))
        XCTAssertEqual("nas", server.host)
        XCTAssertEqual("MYNAS", server.name)
        XCTAssertEqual("HOME", server.domain)
        XCTAssertFalse(server.guest)
        XCTAssertEqual("s3cret pass", store.password("smb://nas"))
        XCTAssertFalse(try String(contentsOf: file, encoding: .utf8).contains("s3cret"))
        XCTAssertEqual("s3cret pass", secrets.getString("smb-smb://nas"))

        // A fresh store reads the same file back.
        let again = SmbServerStore(url: file, secrets: secrets)
        XCTAssertEqual("s3cret pass", again.password("smb://nas"))
        XCTAssertEqual(1, again.servers.count)
    }

    func testGuestHasAnEmptyPasswordAndRemoveForgetsIt() {
        let store = SmbServerStore(url: file, secrets: secrets)
        store.save(SmbServer(host: "192.168.0.1", name: "ROUTER-AX"), password: "")
        XCTAssertTrue(store.server("smb://192.168.0.1")!.guest)
        XCTAssertEqual("", store.password("smb://192.168.0.1"))

        store.remove("smb://192.168.0.1")
        XCTAssertNil(store.server("smb://192.168.0.1"))
        XCTAssertNil(store.password("smb://192.168.0.1"))
        XCTAssertTrue(SmbServerStore(url: file, secrets: secrets).servers.isEmpty)
    }

    func testUnreadablePasswordMeansSignInAgain() throws {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try #"{ "servers": [ { "host": "nas", "port": 445, "username": "me", "domain": "", "name": "nas", "password": "bm90LWRwYXBp" } ] }"#
            .write(to: file, atomically: true, encoding: .utf8)
        let store = SmbServerStore(url: file, secrets: secrets)
        XCTAssertNotNil(store.server("smb://nas"))
        XCTAssertNil(store.password("smb://nas"))
    }

    func testRemoveDeletesTheKeychainItemAndFiresChanged() {
        let store = SmbServerStore(url: file, secrets: secrets)
        var fired = 0
        let sub = store.changed.subscribe { fired += 1 }
        store.save(SmbServer(host: "nas", username: "me"), password: "pw")
        store.remove("smb://nas")
        XCTAssertNil(secrets.get("smb-smb://nas"))
        XCTAssertEqual(2, fired)
        sub.cancel()
    }

    func testErrorsAreWordedForPeople() {
        XCTAssertEqual("Wrong username or password",
                       SmbErrors.describe(SmbStatusError(.logonFailure, "Sign in")))
        let wrapped = NSError(domain: "x", code: 1, userInfo: [NSLocalizedDescriptionKey: "x",
                                                               NSUnderlyingErrorKey: SmbStatusError(.objectPathNotFound, "Open")])
        XCTAssertEqual("That folder or file isn't on the server any more", SmbErrors.describe(wrapped))
        XCTAssertEqual("Couldn't find that server on your network. Check the address.",
                       SmbErrors.describe(SmbSocketError.hostNotFound("nas")))
        XCTAssertEqual("Couldn't reach the server. Check that it's on and that you're on the same Wi-Fi.",
                       SmbErrors.describe(SmbSocketError.refused))
        XCTAssertEqual("Something went wrong talking to the server",
                       SmbErrors.describe(NSError(domain: "x", code: 0, userInfo: [NSLocalizedDescriptionKey: ""])))
    }

    // Mac additions: AMSMB2 (libsmb2) reports statuses as POSIX errors.
    func testLibraryErrorsAreWordedForPeople() {
        func posix(_ code: POSIXErrorCode, _ text: String) -> Error {
            POSIXError(code, userInfo: [NSLocalizedDescriptionKey: text])
        }
        XCTAssertEqual("Wrong username or password",
                       SmbErrors.describe(posix(.ECONNREFUSED, "Error code 61: Session setup failed with (0xc000006d) STATUS_LOGON_FAILURE")))
        XCTAssertEqual("The server has no shared folder with that name",
                       SmbErrors.describe(posix(.ENOENT, "Error code 2: Tree Connect failed STATUS_BAD_NETWORK_NAME")))
        XCTAssertEqual("This user account is disabled on the server",
                       SmbErrors.describe(posix(.EACCES, "STATUS_ACCOUNT_DISABLED")))
        XCTAssertEqual("The connection to the server was lost", SmbErrors.describe(posix(.ENETRESET, "")))
        XCTAssertEqual("Something went wrong talking to the server", SmbErrors.describe(posix(.EDOM, "Error code 33: odd")))
        XCTAssertEqual("Already worded", SmbErrors.describe(SmbError("Already worded", underlying: posix(.ENOENT, ""))))
        XCTAssertTrue(SmbErrors.isDropped(posix(.ENETRESET, "")))
        XCTAssertTrue(SmbErrors.isDropped(posix(.EACCES, "STATUS_USER_SESSION_DELETED")))
        XCTAssertFalse(SmbErrors.isDropped(posix(.ENOENT, "STATUS_OBJECT_NAME_NOT_FOUND")))
        XCTAssertFalse(SmbErrors.isDropped(SmbError("x")))
    }

    func testMimeTypesFromExtensions() {
        XCTAssertEqual("video/x-matroska", SmbMime.forName("Heat (1995).MKV"))
        XCTAssertEqual("application/octet-stream", SmbMime.forName("README"))
    }

    func testServerAccountsAreBackFilled() throws {
        try AppServices.initForTests()
        let store = SmbServerStore(url: file, secrets: secrets)
        store.save(SmbServer(host: "nas", name: "MYNAS"), password: "")
        try SmbAccounts.ensureServerAccounts(AppServices.accountDao, store)
        let row = try XCTUnwrap(try AppServices.accountDao.accounts().first { $0.email == "smb://nas" })
        XCTAssertEqual("MYNAS", row.displayName)
        let added = row.addedAt
        try SmbAccounts.addServerAccount(AppServices.accountDao, SmbServer(host: "nas", name: "Renamed"))
        let again = try XCTUnwrap(try AppServices.accountDao.accounts().first { $0.email == "smb://nas" })
        XCTAssertEqual(added, again.addedAt)
        XCTAssertEqual("Renamed", again.displayName)
    }

    func testHiddenEntriesAreSkipped() {
        XCTAssertTrue(SmbFileSource.isHidden(".DS_Store"))
        XCTAssertTrue(SmbFileSource.isHidden("$RECYCLE.BIN"))
        XCTAssertFalse(SmbFileSource.isHidden("Movies"))
    }
}
