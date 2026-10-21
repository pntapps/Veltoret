import Foundation

/// Looks titles up on TMDB and caches the results in the database (port of Android/Windows TmdbRepository).
public final class TmdbRepository: @unchecked Sendable {
    public static let day: Int64 = 24 * 60 * 60 * 1000
    private static let recommendationPages = 2
    private static let trailerTypes = ["Trailer", "Teaser"]

    public let api: TmdbClient
    private let catalog: CatalogDao
    private let lock = NSLock()
    /// "movie:603" → YouTube id, or "" when the title has no trailer.
    private var trailers: [String: String] = [:]
    private var collections: [Int: TmdbCollection] = [:]

    public init(api: TmdbClient, catalog: CatalogDao) {
        self.api = api
        self.catalog = catalog
    }

    public func searchMovies(_ q: String, year: Int? = nil) async throws -> [TmdbMovieSummary] {
        try await api.searchMovie(q, year: year).results
    }

    public func searchShows(_ q: String, year: Int? = nil) async throws -> [TmdbTvSummary] {
        try await api.searchTv(q, year: year).results
    }

    /// Throws `TmdbKeyMissingError` or `TmdbError` when the key doesn't work.
    public func validateKey() async throws { try await api.configuration() }

    /// The best movie match, retrying without the year when the year-filtered search is empty.
    /// `exactOnly`: accept only an exact title match (fallback names guessed by trimming a file name).
    public func findMovie(title: String, year: Int?, exactOnly: Bool = false) async throws -> TmdbMovieSummary? {
        var results = year != nil ? try await searchMovies(title, year: year) : []
        if results.isEmpty { results = try await searchMovies(title) }
        return Self.pickBest(results, wantTitle: title, wantYear: year, exactOnly: exactOnly,
                             title: { $0.title }, originalTitle: { $0.originalTitle }, date: { $0.releaseDate },
                             votes: { $0.voteCount })
    }

    public func findShow(title: String, year: Int?, exactOnly: Bool = false) async throws -> TmdbTvSummary? {
        var results = year != nil ? try await searchShows(title, year: year) : []
        if results.isEmpty { results = try await searchShows(title) }
        return Self.pickBest(results, wantTitle: title, wantYear: year, exactOnly: exactOnly,
                             title: { $0.name }, originalTitle: { $0.originalName }, date: { $0.firstAirDate },
                             votes: { $0.voteCount })
    }

    public func ensureMovie(_ id: Int, maxAgeMs: Int64 = 30 * TmdbRepository.day) async throws {
        if let existing = try catalog.movie(id), nowMillis() - existing.updatedAt < maxAgeMs { return }
        let d = try await api.movie(id)
        let certification = d.releaseDates?.results.first(where: { $0.country == "US" })?
            .releaseDates.first(where: { !$0.certification.trimmingCharacters(in: .whitespaces).isEmpty })?.certification
        try catalog.upsertMovie(MovieEntity(
            tmdbId: d.id,
            title: d.title,
            originalTitle: d.originalTitle,
            overview: d.overview ?? "",
            tagline: Self.blankToNil(d.tagline),
            releaseDate: d.releaseDate,
            year: Self.yearOf(d.releaseDate),
            runtimeMin: (d.runtime ?? 0) > 0 ? d.runtime : nil,
            rating: d.voteAverage,
            certification: certification,
            posterPath: d.posterPath,
            backdropPath: d.backdropPath,
            genres: d.genres.map(\.name).joined(separator: ","),
            collectionId: d.collection?.id,
            collectionName: d.collection?.name,
            director: d.credits?.crew.first(where: { $0.job == "Director" })?.name,
            updatedAt: nowMillis()))
        try catalog.replaceCredits("movie", d.id, Self.toCredits(d.credits?.cast, "movie", d.id))
    }

    /// Stores show details plus full episode lists for `seasons`.
    public func ensureShow(_ id: Int, seasons seasonsNeeded: Set<Int>, maxAgeMs: Int64 = 7 * TmdbRepository.day) async throws {
        let existing = try catalog.show(id)
        let now = nowMillis()
        if existing == nil || now - existing!.updatedAt >= maxAgeMs {
            let d = try await api.tv(id)
            let creator = d.createdBy.map(\.name).joined(separator: ", ")
            let rating = d.contentRatings?.results.first(where: { $0.country == "US" })?.rating
            try catalog.upsertShow(ShowEntity(
                tmdbId: d.id,
                name: d.name,
                overview: d.overview ?? "",
                tagline: Self.blankToNil(d.tagline),
                firstAirDate: d.firstAirDate,
                year: Self.yearOf(d.firstAirDate),
                lastAirDate: d.lastAirDate,
                status: d.status,
                rating: d.voteAverage,
                certification: Self.blankToNil(rating),
                posterPath: d.posterPath,
                backdropPath: d.backdropPath,
                genres: d.genres.map(\.name).joined(separator: ","),
                network: d.networks.first?.name,
                seasonCount: d.numberOfSeasons,
                episodeCount: d.numberOfEpisodes,
                episodeRuntimeMin: d.episodeRunTime.first,
                creator: Self.blankToNil(creator),
                updatedAt: now,
                nextEpisodeSeason: d.nextEpisode?.seasonNumber,
                nextEpisodeNumber: d.nextEpisode?.episodeNumber,
                nextEpisodeName: Self.blankToNil(d.nextEpisode?.name),
                nextEpisodeAirDate: Self.blankToNil(d.nextEpisode?.airDate)))
            try catalog.upsertSeasons(d.seasons.map {
                SeasonEntity(showId: d.id, seasonNumber: $0.seasonNumber, name: $0.name, overview: $0.overview ?? "",
                             posterPath: $0.posterPath, episodeCount: $0.episodeCount, airDate: $0.airDate, fetchedAt: 0)
            })
            try catalog.replaceCredits("tv", d.id, Self.toCredits(d.credits?.cast, "tv", d.id))
        }
        for seasonNumber in seasonsNeeded.sorted() {
            let season = try catalog.season(id, seasonNumber)
            if let season, now - season.fetchedAt < maxAgeMs { continue }
            let s: TmdbSeasonDetail
            do {
                s = try await api.season(id, seasonNumber)
            } catch let e as TmdbKeyMissingError {
                throw e
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                continue // runCatching in Android: a missing season doesn't fail the show
            }
            try catalog.upsertSeasons([SeasonEntity(
                showId: id, seasonNumber: s.seasonNumber, name: s.name, overview: s.overview ?? "",
                posterPath: s.posterPath ?? season?.posterPath, episodeCount: s.episodes.count, airDate: s.airDate,
                fetchedAt: now)])
            try catalog.upsertEpisodes(s.episodes.map {
                EpisodeEntity(showId: id, seasonNumber: $0.seasonNumber, episodeNumber: $0.episodeNumber, name: $0.name,
                              overview: $0.overview ?? "", stillPath: $0.stillPath, airDate: $0.airDate,
                              runtimeMin: $0.runtime, rating: $0.voteAverage)
            })
        }
    }

    /// Stores TMDB's recommendations for a movie (`type` "movie") or show ("tv"). Fetches the first two pages
    /// (20 titles each) so a personal library has a fair chance of owning some.
    public func ensureRecommendations(type: String, id: Int, maxAgeMs: Int64 = 30 * TmdbRepository.day) async throws {
        if let fetchedAt = try catalog.recommendationsFetchedAt(type, id), nowMillis() - fetchedAt < maxAgeMs { return }
        var ids: [Int] = []
        for page in 1...Self.recommendationPages {
            let pages: Int
            if type == "movie" {
                let p = try await api.movieRecommendations(id, page: page)
                ids += p.results.map(\.id)
                pages = p.totalPages
            } else {
                let p = try await api.tvRecommendations(id, page: page)
                ids += p.results.map(\.id)
                pages = p.totalPages
            }
            if page >= pages { break }
        }
        var seen = Set<Int>()
        let distinct = ids.filter { seen.insert($0).inserted && $0 != id }
        try catalog.upsertRecommendations(RecommendationEntity(
            mediaType: type, mediaId: id, recommendedIds: distinct.map(String.init).joined(separator: ","),
            fetchedAt: nowMillis()))
    }

    /// The YouTube id of the title's trailer (`type` "movie" or "tv"), or nil when TMDB lists none.
    /// Kept for the session; nothing is stored in the database.
    public func trailer(type: String, id: Int) async throws -> String? {
        let key = "\(type):\(id)"
        let known = lock.withLock { trailers[key] }
        if let known { return known.isEmpty ? nil : known }
        let videos = type == "movie" ? try await api.movieVideos(id) : try await api.tvVideos(id)
        let picked = Self.pickTrailer(videos.results, newest: type == "tv")
        lock.withLock { trailers[key] = picked ?? "" }
        return picked
    }

    /// A movie collection with all its parts, oldest first (undated last). Kept for the session.
    public func collection(_ id: Int) async throws -> TmdbCollection {
        let cached = lock.withLock { collections[id] }
        if let cached { return cached }
        var c = try await api.collection(id)
        c.parts = c.parts.enumerated().sorted { a, b in
            let x = (a.element.releaseDate ?? "").isEmpty ? "9999" : a.element.releaseDate!
            let y = (b.element.releaseDate ?? "").isEmpty ? "9999" : b.element.releaseDate!
            return x != y ? Self.ordinalLess(x, y) : a.offset < b.offset // OrderBy is stable
        }.map(\.element)
        let sorted = c
        lock.withLock { collections[id] = sorted }
        return c
    }

    private static func blankToNil(_ s: String?) -> String? {
        guard let s, !s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return s
    }

    private static func toCredits(_ cast: [TmdbCast]?, _ type: String, _ id: Int) -> [CreditEntity] {
        var seen = Set<Int>()
        return (cast ?? []).prefix(30).filter { seen.insert($0.id).inserted }.map {
            CreditEntity(mediaType: type, mediaId: id, personId: $0.id, name: $0.name, character: $0.character,
                         profilePath: $0.profilePath, ord: $0.order)
        }
    }

    /// Ordinal (UTF-16 code unit) comparison, as .NET's StringComparer.Ordinal.
    static func ordinalLess(_ a: String, _ b: String) -> Bool { a.utf16.lexicographicallyPrecedes(b.utf16) }

    /// Strict on purpose (see CLAUDE.md): exact or close partial titles only, a year bonus, and no guesses for short
    /// yearless names that only match something nobody has rated.
    public static func pickBest<T>(
        _ results: [T],
        wantTitle: String,
        wantYear: Int?,
        exactOnly: Bool,
        title: (T) -> String,
        originalTitle: (T) -> String?,
        date: (T) -> String?,
        votes: (T) -> Int
    ) -> T? {
        if results.isEmpty { return nil }
        let want = FilenameParser.normalizeForCompare(wantTitle)
        if want.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return nil }
        var best: T?
        var bestScore = 0.0
        for (i, item) in results.prefix(8).enumerated() {
            let names = [title(item), originalTitle(item)].compactMap { $0 }.map { FilenameParser.normalizeForCompare($0) }
            let y = yearOf(date(item))
            let yearDiff: Int? = (wantYear != nil && y != nil) ? abs(y! - wantYear!) : nil
            let exact = names.contains(want)
            // A partial title match ("vids" vs "ambient vids") only counts when the names are close in
            // length or the year agrees; otherwise any short filename would grab an obscure title.
            let partial = !exact && names.contains { n in
                (n.contains(want) || want.contains(n)) &&
                    (Double(min(n.utf16.count, want.utf16.count)) / Double(max(n.utf16.count, want.utf16.count)) >= 0.6
                        || yearDiff == 0)
            }
            if !exact && !partial { continue }
            // Fallback names (see FilenameParser titleCandidates) need the exact title and, when known, a close year.
            if exactOnly && (!exact || (yearDiff != nil && yearDiff! > 1)) { continue }
            var score = exact ? 3.0 : 1.0
            score -= Double(i) * 0.15
            switch yearDiff {
            case nil: break
            case 0: score += 2.0
            case 1: score += 1.0
            default: score -= 0.5
            }
            // Prefer titles people have actually rated; breaks ties between remakes and obscure uploads.
            score += min(log10(Double(votes(item)) + 1.0), 4.0) * 0.25
            // A bare title with no year that only matches something nobody has heard of is a guess.
            if wantYear == nil && votes(item) < 20 && want.utf16.count < 12 { continue }
            if best == nil || score > bestScore {
                best = item
                bestScore = score
            }
        }
        return best
    }

    public static func yearOf(_ date: String?) -> Int? {
        guard let date else { return nil }
        let head = date.count > 4 ? String(date.prefix(4)) : date
        return Int(head)
    }

    /// YouTube trailers first, then teasers (no clips or featurettes); official uploads first. Movies take
    /// the earliest (the original trailer, not a re-release); shows take the newest (the latest season's).
    public static func pickTrailer(_ videos: [TmdbVideo], newest: Bool) -> String? {
        func compare(_ a: TmdbVideo, _ b: TmdbVideo) -> Int {
            let ta = trailerTypes.firstIndex(of: a.type) ?? -1, tb = trailerTypes.firstIndex(of: b.type) ?? -1
            if ta != tb { return ta < tb ? -1 : 1 }
            if a.official != b.official { return a.official ? -1 : 1 }
            // ISO dates sort as text; undated videos go last either way.
            let x = a.publishedAt ?? "", y = b.publishedAt ?? ""
            if x.isEmpty || y.isEmpty {
                return x.count == y.count ? 0 : (y.count < x.count ? -1 : 1)
            }
            if x == y { return 0 }
            let less = newest ? ordinalLess(y, x) : ordinalLess(x, y)
            return less ? -1 : 1
        }
        let candidates = videos.enumerated().filter {
            $0.element.site.lowercased() == "youtube" && !$0.element.key.trimmingCharacters(in: .whitespaces).isEmpty
                && trailerTypes.contains($0.element.type)
        }
        return candidates.sorted { l, r in
            let c = compare(l.element, r.element)
            return c != 0 ? c < 0 : l.offset < r.offset
        }.first?.element.key
    }
}
