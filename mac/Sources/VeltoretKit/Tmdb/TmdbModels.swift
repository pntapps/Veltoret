import Foundation

// TMDB v3 responses (Android TmdbModels.kt, Windows TmdbModels.cs). Decoded with `TmdbClient.makeDecoder()`
// (snake_case → camelCase). Decoding is lenient like System.Text.Json with the client's options: missing keys take
// the default, numbers may arrive as strings.

extension KeyedDecodingContainer {
    func tmdb<T: Decodable>(_ key: Key, _ fallback: T) -> T {
        (try? decodeIfPresent(T.self, forKey: key)) ?? fallback
    }
    func tmdbOpt<T: Decodable>(_ key: Key) -> T? {
        (try? decodeIfPresent(T.self, forKey: key)) ?? nil
    }
    func tmdbInt(_ key: Key) -> Int? {
        if let i = (try? decodeIfPresent(Int.self, forKey: key)) ?? nil { return i }
        if let s = (try? decodeIfPresent(String.self, forKey: key)) ?? nil { return Int(s.trimmingCharacters(in: .whitespaces)) }
        if let d = (try? decodeIfPresent(Double.self, forKey: key)) ?? nil { return Int(d) }
        return nil
    }
    func tmdbDouble(_ key: Key) -> Double? {
        if let d = (try? decodeIfPresent(Double.self, forKey: key)) ?? nil { return d }
        if let s = (try? decodeIfPresent(String.self, forKey: key)) ?? nil { return Double(s.trimmingCharacters(in: .whitespaces)) }
        return nil
    }
    func tmdbBool(_ key: Key) -> Bool {
        if let b = (try? decodeIfPresent(Bool.self, forKey: key)) ?? nil { return b }
        if let s = (try? decodeIfPresent(String.self, forKey: key)) ?? nil { return s.lowercased() == "true" }
        return false
    }
}

public struct TmdbPage<T: Decodable & Sendable & Hashable>: Decodable, Sendable, Hashable {
    public var page: Int
    public var results: [T]
    public var totalResults: Int
    public var totalPages: Int

    enum CodingKeys: String, CodingKey { case page, results, totalResults, totalPages }
    public init(page: Int = 1, results: [T] = [], totalResults: Int = 0, totalPages: Int = 1) {
        self.page = page; self.results = results; self.totalResults = totalResults; self.totalPages = totalPages
    }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        page = c.tmdbInt(.page) ?? 1
        results = c.tmdb(.results, [])
        totalResults = c.tmdbInt(.totalResults) ?? 0
        totalPages = c.tmdbInt(.totalPages) ?? 1
    }
}

public struct TmdbVideos: Decodable, Sendable, Hashable {
    public var results: [TmdbVideo]
    enum CodingKeys: String, CodingKey { case results }
    public init(results: [TmdbVideo] = []) { self.results = results }
    public init(from decoder: Decoder) throws {
        results = try decoder.container(keyedBy: CodingKeys.self).tmdb(.results, [])
    }
}

/// A trailer, teaser or clip TMDB links to; `key` is the YouTube video id when `site` is "YouTube".
public struct TmdbVideo: Decodable, Sendable, Hashable {
    public var key: String
    public var site: String
    public var type: String
    public var name: String
    public var official: Bool
    public var publishedAt: String?

    enum CodingKeys: String, CodingKey { case key, site, type, name, official, publishedAt }
    public init(key: String = "", site: String = "", type: String = "", name: String = "", official: Bool = false,
                publishedAt: String? = nil) {
        self.key = key; self.site = site; self.type = type; self.name = name; self.official = official
        self.publishedAt = publishedAt
    }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        key = c.tmdb(.key, ""); site = c.tmdb(.site, ""); type = c.tmdb(.type, ""); name = c.tmdb(.name, "")
        official = c.tmdbBool(.official); publishedAt = c.tmdbOpt(.publishedAt)
    }
}

public struct TmdbMovieSummary: Decodable, Sendable, Hashable, Identifiable {
    public var id: Int
    public var title: String
    public var originalTitle: String?
    public var releaseDate: String?
    public var posterPath: String?
    public var backdropPath: String?
    public var overview: String?
    public var voteAverage: Double
    public var voteCount: Int

    enum CodingKeys: String, CodingKey {
        case id, title, originalTitle, releaseDate, posterPath, backdropPath, overview, voteAverage, voteCount
    }
    public init(id: Int = 0, title: String = "", originalTitle: String? = nil, releaseDate: String? = nil,
                posterPath: String? = nil, backdropPath: String? = nil, overview: String? = nil, voteAverage: Double = 0,
                voteCount: Int = 0) {
        self.id = id; self.title = title; self.originalTitle = originalTitle; self.releaseDate = releaseDate
        self.posterPath = posterPath; self.backdropPath = backdropPath; self.overview = overview
        self.voteAverage = voteAverage; self.voteCount = voteCount
    }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = c.tmdbInt(.id) ?? 0; title = c.tmdb(.title, ""); originalTitle = c.tmdbOpt(.originalTitle)
        releaseDate = c.tmdbOpt(.releaseDate); posterPath = c.tmdbOpt(.posterPath); backdropPath = c.tmdbOpt(.backdropPath)
        overview = c.tmdbOpt(.overview); voteAverage = c.tmdbDouble(.voteAverage) ?? 0; voteCount = c.tmdbInt(.voteCount) ?? 0
    }
}

public struct TmdbTvSummary: Decodable, Sendable, Hashable, Identifiable {
    public var id: Int
    public var name: String
    public var originalName: String?
    public var firstAirDate: String?
    public var posterPath: String?
    public var backdropPath: String?
    public var overview: String?
    public var voteAverage: Double
    public var voteCount: Int

    enum CodingKeys: String, CodingKey {
        case id, name, originalName, firstAirDate, posterPath, backdropPath, overview, voteAverage, voteCount
    }
    public init(id: Int = 0, name: String = "", originalName: String? = nil, firstAirDate: String? = nil,
                posterPath: String? = nil, backdropPath: String? = nil, overview: String? = nil, voteAverage: Double = 0,
                voteCount: Int = 0) {
        self.id = id; self.name = name; self.originalName = originalName; self.firstAirDate = firstAirDate
        self.posterPath = posterPath; self.backdropPath = backdropPath; self.overview = overview
        self.voteAverage = voteAverage; self.voteCount = voteCount
    }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = c.tmdbInt(.id) ?? 0; name = c.tmdb(.name, ""); originalName = c.tmdbOpt(.originalName)
        firstAirDate = c.tmdbOpt(.firstAirDate); posterPath = c.tmdbOpt(.posterPath); backdropPath = c.tmdbOpt(.backdropPath)
        overview = c.tmdbOpt(.overview); voteAverage = c.tmdbDouble(.voteAverage) ?? 0; voteCount = c.tmdbInt(.voteCount) ?? 0
    }
}

public struct TmdbGenre: Decodable, Sendable, Hashable {
    public var id: Int
    public var name: String
    enum CodingKeys: String, CodingKey { case id, name }
    public init(id: Int = 0, name: String = "") { self.id = id; self.name = name }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = c.tmdbInt(.id) ?? 0; name = c.tmdb(.name, "")
    }
}

public struct TmdbCast: Decodable, Sendable, Hashable {
    public var id: Int
    public var name: String
    public var character: String?
    public var profilePath: String?
    public var order: Int
    enum CodingKeys: String, CodingKey { case id, name, character, profilePath, order }
    public init(id: Int = 0, name: String = "", character: String? = nil, profilePath: String? = nil, order: Int = 0) {
        self.id = id; self.name = name; self.character = character; self.profilePath = profilePath; self.order = order
    }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = c.tmdbInt(.id) ?? 0; name = c.tmdb(.name, ""); character = c.tmdbOpt(.character)
        profilePath = c.tmdbOpt(.profilePath); order = c.tmdbInt(.order) ?? 0
    }
}

public struct TmdbCrew: Decodable, Sendable, Hashable {
    public var id: Int
    public var name: String
    public var job: String?
    enum CodingKeys: String, CodingKey { case id, name, job }
    public init(id: Int = 0, name: String = "", job: String? = nil) { self.id = id; self.name = name; self.job = job }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = c.tmdbInt(.id) ?? 0; name = c.tmdb(.name, ""); job = c.tmdbOpt(.job)
    }
}

public struct TmdbCredits: Decodable, Sendable, Hashable {
    public var cast: [TmdbCast]
    public var crew: [TmdbCrew]
    enum CodingKeys: String, CodingKey { case cast, crew }
    public init(cast: [TmdbCast] = [], crew: [TmdbCrew] = []) { self.cast = cast; self.crew = crew }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        cast = c.tmdb(.cast, []); crew = c.tmdb(.crew, [])
    }
}

public struct TmdbCollectionRef: Decodable, Sendable, Hashable {
    public var id: Int
    public var name: String
    enum CodingKeys: String, CodingKey { case id, name }
    public init(id: Int = 0, name: String = "") { self.id = id; self.name = name }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = c.tmdbInt(.id) ?? 0; name = c.tmdb(.name, "")
    }
}

public struct TmdbReleaseDates: Decodable, Sendable, Hashable {
    public var results: [TmdbCountryReleases]
    enum CodingKeys: String, CodingKey { case results }
    public init(results: [TmdbCountryReleases] = []) { self.results = results }
    public init(from decoder: Decoder) throws { results = try decoder.container(keyedBy: CodingKeys.self).tmdb(.results, []) }
}

public struct TmdbCountryReleases: Decodable, Sendable, Hashable {
    /// "iso_3166_1".
    public var country: String
    public var releaseDates: [TmdbReleaseDate]
    // convertFromSnakeCase turns "iso_3166_1" into "iso31661".
    enum CodingKeys: String, CodingKey { case country = "iso31661", releaseDates }
    public init(country: String = "", releaseDates: [TmdbReleaseDate] = []) { self.country = country; self.releaseDates = releaseDates }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        country = c.tmdb(.country, ""); releaseDates = c.tmdb(.releaseDates, [])
    }
}

public struct TmdbReleaseDate: Decodable, Sendable, Hashable {
    public var certification: String
    enum CodingKeys: String, CodingKey { case certification }
    public init(certification: String = "") { self.certification = certification }
    public init(from decoder: Decoder) throws {
        certification = try decoder.container(keyedBy: CodingKeys.self).tmdb(.certification, "")
    }
}

public struct TmdbContentRatings: Decodable, Sendable, Hashable {
    public var results: [TmdbContentRating]
    enum CodingKeys: String, CodingKey { case results }
    public init(results: [TmdbContentRating] = []) { self.results = results }
    public init(from decoder: Decoder) throws { results = try decoder.container(keyedBy: CodingKeys.self).tmdb(.results, []) }
}

public struct TmdbContentRating: Decodable, Sendable, Hashable {
    public var country: String
    public var rating: String
    enum CodingKeys: String, CodingKey { case country = "iso31661", rating }
    public init(country: String = "", rating: String = "") { self.country = country; self.rating = rating }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        country = c.tmdb(.country, ""); rating = c.tmdb(.rating, "")
    }
}

public struct TmdbMovieDetail: Decodable, Sendable, Hashable {
    public var id: Int
    public var title: String
    public var originalTitle: String?
    public var overview: String?
    public var tagline: String?
    public var releaseDate: String?
    public var runtime: Int?
    public var voteAverage: Double
    public var posterPath: String?
    public var backdropPath: String?
    public var genres: [TmdbGenre]
    /// "belongs_to_collection".
    public var collection: TmdbCollectionRef?
    public var credits: TmdbCredits?
    public var releaseDates: TmdbReleaseDates?

    enum CodingKeys: String, CodingKey {
        case id, title, originalTitle, overview, tagline, releaseDate, runtime, voteAverage, posterPath, backdropPath,
             genres, collection = "belongsToCollection", credits, releaseDates
    }
    public init(id: Int = 0, title: String = "") { self.id = id; self.title = title; voteAverage = 0; genres = [] }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = c.tmdbInt(.id) ?? 0; title = c.tmdb(.title, ""); originalTitle = c.tmdbOpt(.originalTitle)
        overview = c.tmdbOpt(.overview); tagline = c.tmdbOpt(.tagline); releaseDate = c.tmdbOpt(.releaseDate)
        runtime = c.tmdbInt(.runtime); voteAverage = c.tmdbDouble(.voteAverage) ?? 0; posterPath = c.tmdbOpt(.posterPath)
        backdropPath = c.tmdbOpt(.backdropPath); genres = c.tmdb(.genres, []); collection = c.tmdbOpt(.collection)
        credits = c.tmdbOpt(.credits); releaseDates = c.tmdbOpt(.releaseDates)
    }
}

public struct TmdbNetwork: Decodable, Sendable, Hashable {
    public var name: String
    enum CodingKeys: String, CodingKey { case name }
    public init(name: String = "") { self.name = name }
    public init(from decoder: Decoder) throws { name = try decoder.container(keyedBy: CodingKeys.self).tmdb(.name, "") }
}

public struct TmdbCreator: Decodable, Sendable, Hashable {
    public var name: String
    enum CodingKeys: String, CodingKey { case name }
    public init(name: String = "") { self.name = name }
    public init(from decoder: Decoder) throws { name = try decoder.container(keyedBy: CodingKeys.self).tmdb(.name, "") }
}

public struct TmdbSeasonSummary: Decodable, Sendable, Hashable {
    public var seasonNumber: Int
    public var name: String
    public var overview: String?
    public var posterPath: String?
    public var episodeCount: Int
    public var airDate: String?
    enum CodingKeys: String, CodingKey { case seasonNumber, name, overview, posterPath, episodeCount, airDate }
    public init(seasonNumber: Int = 0, name: String = "", overview: String? = nil, posterPath: String? = nil,
                episodeCount: Int = 0, airDate: String? = nil) {
        self.seasonNumber = seasonNumber; self.name = name; self.overview = overview; self.posterPath = posterPath
        self.episodeCount = episodeCount; self.airDate = airDate
    }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        seasonNumber = c.tmdbInt(.seasonNumber) ?? 0; name = c.tmdb(.name, ""); overview = c.tmdbOpt(.overview)
        posterPath = c.tmdbOpt(.posterPath); episodeCount = c.tmdbInt(.episodeCount) ?? 0; airDate = c.tmdbOpt(.airDate)
    }
}

public struct TmdbNextEpisode: Decodable, Sendable, Hashable {
    public var seasonNumber: Int
    public var episodeNumber: Int
    public var name: String
    public var airDate: String?
    enum CodingKeys: String, CodingKey { case seasonNumber, episodeNumber, name, airDate }
    public init(seasonNumber: Int = 0, episodeNumber: Int = 0, name: String = "", airDate: String? = nil) {
        self.seasonNumber = seasonNumber; self.episodeNumber = episodeNumber; self.name = name; self.airDate = airDate
    }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        seasonNumber = c.tmdbInt(.seasonNumber) ?? 0; episodeNumber = c.tmdbInt(.episodeNumber) ?? 0
        name = c.tmdb(.name, ""); airDate = c.tmdbOpt(.airDate)
    }
}

public struct TmdbTvDetail: Decodable, Sendable, Hashable {
    public var id: Int
    public var name: String
    public var overview: String?
    public var tagline: String?
    public var firstAirDate: String?
    public var lastAirDate: String?
    public var status: String?
    public var voteAverage: Double
    public var posterPath: String?
    public var backdropPath: String?
    public var genres: [TmdbGenre]
    public var networks: [TmdbNetwork]
    public var createdBy: [TmdbCreator]
    public var numberOfSeasons: Int
    public var numberOfEpisodes: Int
    public var episodeRunTime: [Int]
    public var seasons: [TmdbSeasonSummary]
    public var credits: TmdbCredits?
    public var contentRatings: TmdbContentRatings?
    /// "next_episode_to_air".
    public var nextEpisode: TmdbNextEpisode?

    enum CodingKeys: String, CodingKey {
        case id, name, overview, tagline, firstAirDate, lastAirDate, status, voteAverage, posterPath, backdropPath, genres,
             networks, createdBy, numberOfSeasons, numberOfEpisodes, episodeRunTime, seasons, credits, contentRatings,
             nextEpisode = "nextEpisodeToAir"
    }
    public init(id: Int = 0, name: String = "") {
        self.id = id; self.name = name; voteAverage = 0; genres = []; networks = []; createdBy = []
        numberOfSeasons = 0; numberOfEpisodes = 0; episodeRunTime = []; seasons = []
    }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = c.tmdbInt(.id) ?? 0; name = c.tmdb(.name, ""); overview = c.tmdbOpt(.overview); tagline = c.tmdbOpt(.tagline)
        firstAirDate = c.tmdbOpt(.firstAirDate); lastAirDate = c.tmdbOpt(.lastAirDate); status = c.tmdbOpt(.status)
        voteAverage = c.tmdbDouble(.voteAverage) ?? 0; posterPath = c.tmdbOpt(.posterPath)
        backdropPath = c.tmdbOpt(.backdropPath); genres = c.tmdb(.genres, []); networks = c.tmdb(.networks, [])
        createdBy = c.tmdb(.createdBy, []); numberOfSeasons = c.tmdbInt(.numberOfSeasons) ?? 0
        numberOfEpisodes = c.tmdbInt(.numberOfEpisodes) ?? 0; episodeRunTime = c.tmdb(.episodeRunTime, [])
        seasons = c.tmdb(.seasons, []); credits = c.tmdbOpt(.credits); contentRatings = c.tmdbOpt(.contentRatings)
        nextEpisode = c.tmdbOpt(.nextEpisode)
    }
}

/// A movie collection ("The Matrix Collection") and every movie in it.
public struct TmdbCollection: Decodable, Sendable, Hashable, Identifiable {
    public var id: Int
    public var name: String
    public var overview: String?
    public var posterPath: String?
    public var backdropPath: String?
    public var parts: [TmdbMovieSummary]
    enum CodingKeys: String, CodingKey { case id, name, overview, posterPath, backdropPath, parts }
    public init(id: Int = 0, name: String = "", overview: String? = nil, posterPath: String? = nil,
                backdropPath: String? = nil, parts: [TmdbMovieSummary] = []) {
        self.id = id; self.name = name; self.overview = overview; self.posterPath = posterPath
        self.backdropPath = backdropPath; self.parts = parts
    }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = c.tmdbInt(.id) ?? 0; name = c.tmdb(.name, ""); overview = c.tmdbOpt(.overview)
        posterPath = c.tmdbOpt(.posterPath); backdropPath = c.tmdbOpt(.backdropPath); parts = c.tmdb(.parts, [])
    }
}

public struct TmdbEpisode: Decodable, Sendable, Hashable {
    public var episodeNumber: Int
    public var seasonNumber: Int
    public var name: String
    public var overview: String?
    public var stillPath: String?
    public var airDate: String?
    public var runtime: Int?
    public var voteAverage: Double
    enum CodingKeys: String, CodingKey { case episodeNumber, seasonNumber, name, overview, stillPath, airDate, runtime, voteAverage }
    public init(episodeNumber: Int = 0, seasonNumber: Int = 0, name: String = "") {
        self.episodeNumber = episodeNumber; self.seasonNumber = seasonNumber; self.name = name; voteAverage = 0
    }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        episodeNumber = c.tmdbInt(.episodeNumber) ?? 0; seasonNumber = c.tmdbInt(.seasonNumber) ?? 0
        name = c.tmdb(.name, ""); overview = c.tmdbOpt(.overview); stillPath = c.tmdbOpt(.stillPath)
        airDate = c.tmdbOpt(.airDate); runtime = c.tmdbInt(.runtime); voteAverage = c.tmdbDouble(.voteAverage) ?? 0
    }
}

public struct TmdbSeasonDetail: Decodable, Sendable, Hashable {
    public var seasonNumber: Int
    public var name: String
    public var overview: String?
    public var posterPath: String?
    public var airDate: String?
    public var episodes: [TmdbEpisode]
    enum CodingKeys: String, CodingKey { case seasonNumber, name, overview, posterPath, airDate, episodes }
    public init(seasonNumber: Int = 0, name: String = "", episodes: [TmdbEpisode] = []) {
        self.seasonNumber = seasonNumber; self.name = name; self.episodes = episodes
    }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        seasonNumber = c.tmdbInt(.seasonNumber) ?? 0; name = c.tmdb(.name, ""); overview = c.tmdbOpt(.overview)
        posterPath = c.tmdbOpt(.posterPath); airDate = c.tmdbOpt(.airDate); episodes = c.tmdb(.episodes, [])
    }
}

/// Any JSON body (the /configuration call only checks that the key works).
public struct TmdbAnyJson: Decodable, Sendable {
    public init() {}
    public init(from decoder: Decoder) throws {}
}
