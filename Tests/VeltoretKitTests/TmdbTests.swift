import Foundation
import XCTest
@testable import VeltoretKit

/// Fakes HTTP for a URLSession: `FakeHttp.session { request in (200, data) }` (nil → 404). Each session gets its own
/// handler (routed by a header), so tests can run side by side. `requests(of:)` lists what a session sent.
final class FakeHttp: URLProtocol, @unchecked Sendable {
    typealias Handler = (URLRequest) -> (Int, Data)?
    private static let lock = NSLock()
    nonisolated(unsafe) private static var handlers: [String: Handler] = [:]
    nonisolated(unsafe) private static var log: [String: [URLRequest]] = [:]
    private static let header = "X-Fake-Http"

    static func session(delay: TimeInterval = 0, _ handler: @escaping Handler) -> URLSession {
        let id = UUID().uuidString
        lock.lock(); handlers[id] = { r in
            if delay > 0 { Thread.sleep(forTimeInterval: delay) }
            return handler(r)
        }; log[id] = []; lock.unlock()
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [FakeHttp.self]
        config.httpAdditionalHeaders = [header: id]
        let s = URLSession(configuration: config)
        s.sessionDescription = id
        return s
    }

    static func requests(of session: URLSession) -> [URLRequest] {
        lock.lock(); defer { lock.unlock() }
        return log[session.sessionDescription ?? ""] ?? []
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let id = request.value(forHTTPHeaderField: Self.header) ?? ""
        Self.lock.lock(); let h = Self.handlers[id]; Self.log[id, default: []].append(request); Self.lock.unlock()
        let request = self.request
        DispatchQueue.global().async {
            let result = h?(request)
            let status = result?.0 ?? 404
            let body = result?.1 ?? Data("{}".utf8)
            let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1",
                                           headerFields: ["Content-Type": "application/json"])!
            self.client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            self.client?.urlProtocol(self, didLoad: body)
            self.client?.urlProtocolDidFinishLoading(self)
        }
    }

    override func stopLoading() {}
}

final class TmdbTests: XCTestCase {
    func testV3KeyGoesInQueryWithLanguage() {
        let url = TmdbClient.buildUrl("search/movie", key: "abc123", [("query", "The Matrix"), ("year", nil)])
        XCTAssertEqual("https://api.themoviedb.org/3/search/movie?query=The%20Matrix&language=en-US&api_key=abc123", url)
    }

    func testBearerTokenStaysOutOfUrl() {
        let url = TmdbClient.buildUrl("configuration", key: "eyJhbGciOi.x.y")
        XCTAssertEqual("https://api.themoviedb.org/3/configuration?language=en-US", url)
    }

    func testBearerTokenIsSentAsHeader() async throws {
        let session = FakeHttp.session { _ in (200, Data("{}".utf8)) }
        let client = TmdbClient(session: session, keyProvider: { "eyJtoken" })
        try await client.configuration()
        XCTAssertEqual("Bearer eyJtoken", FakeHttp.requests(of: session)[0].value(forHTTPHeaderField: "Authorization"))
    }

    func testMissingKeyThrows() async {
        let client = TmdbClient(session: FakeHttp.session { _ in (200, Data("{}".utf8)) }, keyProvider: { "  " })
        do {
            try await client.configuration()
            XCTFail("expected TmdbKeyMissingError")
        } catch {
            XCTAssertTrue(error is TmdbKeyMissingError)
        }
    }

    func testSnakeCaseModelsParse() throws {
        let json = """
            {"id":603,"title":"The Matrix","original_title":"The Matrix","release_date":"1999-03-30","runtime":136,
             "vote_average":8.2,"genres":[{"id":28,"name":"Action"}],"belongs_to_collection":{"id":2344,"name":"The Matrix Collection"},
             "credits":{"cast":[{"id":6384,"name":"Keanu Reeves","character":"Neo","profile_path":"/k.jpg","order":0}],
                        "crew":[{"id":9339,"name":"Lilly Wachowski","job":"Director"}]},
             "release_dates":{"results":[{"iso_3166_1":"US","release_dates":[{"certification":""},{"certification":"R"}]}]}}
            """
        let d = try TmdbClient.makeDecoder().decode(TmdbMovieDetail.self, from: Data(json.utf8))
        XCTAssertEqual("1999-03-30", d.releaseDate)
        XCTAssertEqual(136, d.runtime)
        XCTAssertEqual(2344, d.collection?.id)
        XCTAssertEqual("Neo", d.credits?.cast[0].character)
        XCTAssertEqual("/k.jpg", d.credits?.cast[0].profilePath)
        XCTAssertEqual("US", d.releaseDates?.results[0].country)
        XCTAssertEqual("R", d.releaseDates?.results[0].releaseDates[1].certification)

        let tv = try TmdbClient.makeDecoder().decode(TmdbTvDetail.self, from: Data(
            #"{"id":1,"name":"X","next_episode_to_air":{"season_number":2,"episode_number":5,"air_date":"2026-01-01"},"episode_run_time":[45],"number_of_seasons":3}"#.utf8))
        XCTAssertEqual(5, tv.nextEpisode?.episodeNumber)
        XCTAssertEqual(45, tv.episodeRunTime[0])
        XCTAssertEqual(3, tv.numberOfSeasons)
    }

    private func s(_ id: Int, _ title: String, _ date: String?, votes: Int = 1000) -> TmdbMovieSummary {
        TmdbMovieSummary(id: id, title: title, releaseDate: date, voteCount: votes)
    }

    private func pick(_ r: [TmdbMovieSummary], _ title: String, _ year: Int?, exactOnly: Bool = false) -> TmdbMovieSummary? {
        TmdbRepository.pickBest(r, wantTitle: title, wantYear: year, exactOnly: exactOnly, title: { $0.title },
                                originalTitle: { $0.originalTitle }, date: { $0.releaseDate }, votes: { $0.voteCount })
    }

    func testPickBestPrefersExactTitleAndYear() {
        let r = [s(1, "The Matrix Reloaded", "2003-05-15"), s(2, "The Matrix", "1999-03-30"), s(3, "The Matrix", "2021-01-01", votes: 5)]
        XCTAssertEqual(2, pick(r, "The Matrix", 1999)?.id)
    }

    func testPickBestRejectsShortYearlessObscureMatches() {
        XCTAssertNil(pick([s(1, "Vids", nil, votes: 3)], "vids", nil))
        XCTAssertNil(pick([s(1, "Ambient Vids", "2010-01-01")], "vids", nil)) // partial, lengths far apart, no year
        XCTAssertEqual(1, pick([s(1, "Ambient Vids", "2010-01-01")], "vids", 2010)?.id) // year agrees
    }

    func testExactOnlyNeedsExactTitleAndCloseYear() {
        let r = [s(1, "Some Movie", "2015-01-01")]
        XCTAssertNil(pick(r, "Some Movie", 2020, exactOnly: true))
        XCTAssertEqual(1, pick(r, "Some Movie", 2016, exactOnly: true)?.id)
        XCTAssertNil(pick([s(1, "Some Movie Two", "2015-01-01")], "Some Movie", 2015, exactOnly: true))
    }

    func testYearOfReadsTheFirstFourCharacters() {
        XCTAssertEqual(1999, TmdbRepository.yearOf("1999-03-30"))
        XCTAssertNil(TmdbRepository.yearOf(""))
        XCTAssertNil(TmdbRepository.yearOf(nil))
    }

    // Mac additions: the repository caches what it fetches.

    func testEnsureMovieStoresDetailsAndCredits() async throws {
        let db = try VeltoretDb()
        let catalog = CatalogDao(db)
        let session = FakeHttp.session { r in
            guard r.url!.path.hasSuffix("/movie/603") else { return nil }
            return (200, Data("""
                {"id":603,"title":"The Matrix","release_date":"1999-03-30","runtime":136,"tagline":" ",
                 "genres":[{"id":28,"name":"Action"},{"id":878,"name":"Science Fiction"}],
                 "credits":{"cast":[{"id":1,"name":"Keanu Reeves","order":0},{"id":1,"name":"Dup","order":1}],
                            "crew":[{"id":9,"name":"Lana Wachowski","job":"Director"}]},
                 "release_dates":{"results":[{"iso_3166_1":"US","release_dates":[{"certification":"R"}]}]}}
                """.utf8))
        }
        let repo = TmdbRepository(api: TmdbClient(session: session, keyProvider: { "k" }), catalog: catalog)
        try await repo.ensureMovie(603)
        let m = try XCTUnwrap(try catalog.movie(603))
        XCTAssertEqual(1999, m.year)
        XCTAssertNil(m.tagline)
        XCTAssertEqual("R", m.certification)
        XCTAssertEqual("Action,Science Fiction", m.genres)
        XCTAssertEqual("Lana Wachowski", m.director)
        XCTAssertEqual(1, try catalog.credits("movie", 603).count)
        try await repo.ensureMovie(603) // fresh: no second request
        XCTAssertEqual(1, FakeHttp.requests(of: session).count)
    }

    func testCollectionSortsPartsOldestFirstUndatedLast() async throws {
        let session = FakeHttp.session { _ in
            (200, Data(#"{"id":1,"name":"C","parts":[{"id":3,"title":"c","release_date":""},{"id":2,"title":"b","release_date":"2003-01-01"},{"id":1,"title":"a","release_date":"1999-01-01"}]}"#.utf8))
        }
        let repo = TmdbRepository(api: TmdbClient(session: session, keyProvider: { "k" }), catalog: CatalogDao(try VeltoretDb()))
        let c = try await repo.collection(1)
        XCTAssertEqual([1, 2, 3], c.parts.map(\.id))
        _ = try await repo.collection(1)
        XCTAssertEqual(1, FakeHttp.requests(of: session).count)
    }

    func testHttpErrorsExplain() async {
        let client = TmdbClient(session: FakeHttp.session { _ in (401, Data()) }, keyProvider: { "bad" })
        do {
            try await client.configuration()
            XCTFail("expected an error")
        } catch let e as TmdbError {
            XCTAssertEqual(401, e.statusCode)
            XCTAssertTrue(e.message.contains("didn't accept the API key"))
        } catch {
            XCTFail("\(error)")
        }
    }
}
