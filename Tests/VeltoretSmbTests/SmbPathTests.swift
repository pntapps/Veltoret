import XCTest
@testable import VeltoretSmb

/// Port of Windows SmbPathTest.
final class SmbPathTests: XCTestCase {
    func testReadsWindowsPaths() {
        let p = SmbPath.fromUserInput("\\\\192.168.0.10\\h\\My Movies")!
        XCTAssertEqual("192.168.0.10", p.host)
        XCTAssertEqual("h", p.share)
        XCTAssertEqual(["My Movies"], p.segments)
    }

    func testReadsOtherWaysPeopleTypeAddresses() {
        XCTAssertEqual(SmbPath(host: "nas", share: "Media", segments: ["Films"]), SmbPath.fromUserInput("smb://NAS/Media/Films/"))
        XCTAssertEqual(SmbPath(host: "192.168.0.10", share: "share", segments: []), SmbPath.fromUserInput(" 192.168.0.10/share "))
        XCTAssertEqual(SmbPath(host: "router", share: nil, segments: []), SmbPath.fromUserInput("router"))
        XCTAssertNil(SmbPath.fromUserInput("   "))
        XCTAssertNil(SmbPath.fromUserInput("\\\\"))
    }

    func testIdsRoundTrip() throws {
        let p = SmbPath(host: "192.168.0.10", share: "h", segments: ["Movies", "Heat (1995).mkv"])
        XCTAssertEqual("smb://192.168.0.10/h/Movies/Heat (1995).mkv", p.id)
        XCTAssertEqual(p, try SmbPath.parse(p.id))
        XCTAssertEqual("Movies\\Heat (1995).mkv", p.sharePath)
        XCTAssertEqual("Heat (1995).mkv", p.name)
    }

    func testWalksUpAndDown() throws {
        let server = try SmbPath.parse("smb://nas")
        XCTAssertNil(server.share)
        XCTAssertEqual("", server.child("Media").sharePath)
        XCTAssertEqual("smb://nas/Media/TV", server.child("Media").child("TV").id)
        XCTAssertEqual("smb://nas/Media", try SmbPath.parse("smb://nas/Media/TV").parent!.id)
        XCTAssertEqual("smb://nas", try SmbPath.parse("smb://nas/Media").parent!.id)
        XCTAssertNil(server.parent)
    }

    func testAccountIsTheServer() {
        XCTAssertEqual("smb://nas", SmbPath.accountOf(" NAS "))
        XCTAssertTrue(SmbPath.isSmb("smb://nas/Media"))
        XCTAssertFalse(SmbPath.isSmb("device"))
        XCTAssertFalse(SmbPath.isSmb(nil))
    }

    // Windows additions

    func testHostIsLowercasedButNamesKeepTheirCase() throws {
        let p = try SmbPath.parse("smb://NAS/Media/Films")
        XCTAssertEqual("nas", p.host)
        XCTAssertEqual("smb://nas/Media/Films", p.id)
    }

    func testUpperCaseSchemeIsNotStrippedFromInput() {
        // Android removes only the lowercase "smb:" prefix; "SMB://nas" keeps "SMB:" as the host.
        XCTAssertEqual("smb:", SmbPath.fromUserInput("SMB://nas/share")!.host)
    }

    func testUncForDisplay() throws {
        XCTAssertEqual("\\\\nas\\Media\\TV", try SmbPath.parse("smb://nas/Media/TV").unc)
        XCTAssertEqual("\\\\nas", try SmbPath.parse("smb://nas").unc)
    }

    // Mac additions

    func testFilePathUsesSlashesForAmsmb2() throws {
        XCTAssertEqual("Movies/Heat (1995).mkv", try SmbPath.parse("smb://nas/h/Movies/Heat (1995).mkv").filePath)
        XCTAssertEqual("", try SmbPath.parse("smb://nas/h").filePath)
    }

    func testParseRejectsOtherIds() {
        XCTAssertThrowsError(try SmbPath.parse("device"))
        XCTAssertThrowsError(try SmbPath.parse("smb://"))
    }
}
