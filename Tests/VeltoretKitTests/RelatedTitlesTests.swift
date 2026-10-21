import XCTest
@testable import VeltoretKit

/// Port of Android RelatedTitlesTest.kt (Windows RelatedTitlesTests.cs).
final class RelatedTitlesTests: XCTestCase {
    private let library: [Int: String] = [1: "Self", 2: "Two", 3: "Three", 4: "Four", 5: "Five"]

    func testKeepsTmdbOrderAndOnlyLibraryTitles() {
        XCTAssertEqual(["Four", "Two", "Five"], RelatedTitles.inLibrary([99, 4, 2, 77, 5], library, selfId: 1))
    }

    func testSkipsSelfAndRepeats() {
        XCTAssertEqual(["Three", "Two"], RelatedTitles.inLibrary([1, 3, 3, 2, 1], library, selfId: 1))
    }

    func testCapsAtLimit() {
        XCTAssertEqual(["Two", "Three"], RelatedTitles.inLibrary([2, 3, 4, 5], library, selfId: 1, limit: 2))
    }

    func testNothingRecommendedOrNotFetchedIsEmpty() {
        XCTAssertTrue(RelatedTitles.inLibrary(RelatedTitles.parseIds(nil), library, selfId: 1).isEmpty)
        XCTAssertTrue(RelatedTitles.inLibrary(RelatedTitles.parseIds(""), library, selfId: 1).isEmpty)
    }

    func testParsesStoredIds() {
        XCTAssertEqual([12, 345, 6], RelatedTitles.parseIds("12,345, 6,,x"))
    }
}
