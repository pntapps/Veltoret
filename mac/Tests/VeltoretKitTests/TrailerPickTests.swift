import XCTest
@testable import VeltoretKit

/// Port of Android TrailerPickTest.kt (Windows TrailerPickTests.cs).
final class TrailerPickTests: XCTestCase {
    private func video(_ key: String, type: String = "Trailer", official: Bool = true, date: String? = "2020-01-01",
                       site: String = "YouTube") -> TmdbVideo {
        TmdbVideo(key: key, site: site, type: type, official: official, publishedAt: date)
    }

    func testTrailerBeatsTeaserAndClips() {
        let videos = [video("clip", type: "Clip"), video("teaser", type: "Teaser"), video("trailer"), video("bts", type: "Behind the Scenes")]
        XCTAssertEqual("trailer", TmdbRepository.pickTrailer(videos, newest: false))
    }

    func testTeaserWhenThereIsNoTrailer() {
        XCTAssertEqual("teaser", TmdbRepository.pickTrailer([video("clip", type: "Clip"), video("teaser", type: "Teaser")], newest: false))
    }

    func testOfficialBeatsFanUploads() {
        XCTAssertEqual("official", TmdbRepository.pickTrailer([video("fan", official: false, date: "2019-01-01"), video("official")], newest: false))
    }

    func testMoviesTakeTheOriginalTrailerShowsTheLatest() {
        let videos = [video("rerelease", date: "2021-05-01"), video("original", date: "1999-02-01"), video("undated", date: nil)]
        XCTAssertEqual("original", TmdbRepository.pickTrailer(videos, newest: false))
        XCTAssertEqual("rerelease", TmdbRepository.pickTrailer(videos, newest: true))
    }

    func testOnlyYouTube() {
        XCTAssertNil(TmdbRepository.pickTrailer([video("vimeo", site: "Vimeo"), video("", site: "YouTube")], newest: false))
    }
}
