import XCTest
@testable import VeltoretPlans

/// Port of the Android/Windows VoiceQueryTest.
final class VoiceQueryTests: XCTestCase {
    typealias Parsed = VoiceQuery.Parsed
    typealias C = VoiceQuery.Candidate

    private let library: [C] = [
        C(id: 1, isShow: false, title: "The Wrecking Crew", year: 2026),
        C(id: 2, isShow: false, title: "Hokum", year: 2026),
        C(id: 3, isShow: false, title: "Spider-Man: No Way Home", year: 2021),
        C(id: 4, isShow: true, title: "Below", year: 2025),
        C(id: 5, isShow: false, title: "Below Deck Movie", year: 2019),
        C(id: 6, isShow: false, title: "Dune", year: 2021),
        C(id: 7, isShow: false, title: "Dune", year: 1984),
        C(id: 8, isShow: true, title: "House of the Dragon", year: 2022),
        C(id: 9, isShow: false, title: "1917", year: 2019),
        C(id: 10, isShow: false, title: "Don't Look Up", year: 2021),
    ]

    private func pick(_ said: String) -> Int? { VoiceQuery.best(VoiceQuery.parse(said), library)?.id }

    func testParsesSeasonsEpisodesAndFillerWords() {
        XCTAssertEqual(Parsed("Below", season: 1, episode: 2), VoiceQuery.parse("Below season 1 episode 2"))
        XCTAssertEqual(Parsed("House of the Dragon", season: 2, episode: 5), VoiceQuery.parse("play House of the Dragon S02E05 on Veltoret"))
        XCTAssertEqual(Parsed("Below", season: 1, episode: 3), VoiceQuery.parse("Below episode 3"))
        XCTAssertEqual(Parsed("Dune", year: 2021), VoiceQuery.parse("watch Dune 2021"))
        // A title that is only a year stays a title.
        XCTAssertEqual(Parsed("1917"), VoiceQuery.parse("1917"))
    }

    func testMatchesSpokenTitles() {
        XCTAssertEqual(1, pick("the wrecking crew"))
        XCTAssertEqual(1, pick("wrecking crew"))
        XCTAssertEqual(2, pick("hokum"))
        XCTAssertEqual(3, pick("spider man no way home"))
        XCTAssertEqual(10, pick("dont look up"))
        XCTAssertEqual(9, pick("1917"))
    }

    func testExactTitlesBeatLongerOnes() {
        XCTAssertEqual(4, pick("Below"))
        XCTAssertEqual(5, pick("below deck movie"))
    }

    func testEpisodesOnlyMatchShowsAndYearsPickTheRightVersion() {
        XCTAssertEqual(4, pick("Below season 1 episode 2"))
        XCTAssertEqual(6, pick("Dune 2021"))
        XCTAssertEqual(7, pick("Dune 1984"))
    }

    func testNothingCloseMeansNoMatch() {
        XCTAssertNil(pick("the godfather"))
        XCTAssertNil(pick(""))
    }
}
