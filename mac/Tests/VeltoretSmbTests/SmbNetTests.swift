import XCTest
import VeltoretKit
@testable import VeltoretSmb

/// Mac additions: the socket helpers behind the quick probe and the sweep.
final class SmbNetTests: XCTestCase {
    func testProbeOfAClosedLocalPortFailsFastAsUnreachable() {
        let started = Date()
        XCTAssertThrowsError(try SmbNet.probe(host: "127.0.0.1", port: 9, timeoutMs: 2_000)) { e in
            XCTAssertEqual(SmbErrors.couldntReach, SmbErrors.describe(e))
        }
        XCTAssertLessThan(Date().timeIntervalSince(started), 2.5)
    }

    func testUnknownHostIsWorded() {
        XCTAssertThrowsError(try SmbNet.probe(host: "no-such-host.invalid", port: 445, timeoutMs: 500)) { e in
            XCTAssertEqual(SmbErrors.unknownHost, SmbErrors.describe(e))
        }
    }

    func testLocalNetworkIsReadable() {
        // Any answer is fine (CI may have no network); it must not crash and must be a sane prefix.
        if let net = SmbNet.localNetwork() {
            XCTAssertTrue((0...32).contains(net.prefix))
            print("local network: \(SmbNet.format(net.ownAddress))/\(net.prefix) gateway \(net.gateway ?? "-")")
        }
    }

    func testOpenReadOfAShareRootIsRefused() async throws {
        let store = SmbServerStore(url: FileManager.default.temporaryDirectory.appendingPathComponent("smb-\(UUID()).json"),
                                   secrets: MemorySecretStore())
        let files = SmbFileSource(servers: store)
        do {
            _ = try await files.openRead("smb://nas", id: "smb://nas/Media")
            XCTFail("expected an error")
        } catch let e as SmbError {
            XCTAssertEqual("\"Media\" isn't a file", e.message)
        }
        do {
            _ = try await files.list("smb://nas", folderId: "smb://nas/Media")
            XCTFail("expected an error")
        } catch let e as SmbError {
            XCTAssertEqual("This network server was removed from Veltoret", e.message)
        }
    }
}
