import Foundation

// Rows of the SQLite library database. Same tables and columns as the Android app's Room schema (version 4) and
// the Windows app, so the logic ported from there reads the same. Enums are stored as their names (TEXT), as Room
// does. Property names are the column names: don't rename them.

public enum LibraryType: String, Codable, Sendable, CaseIterable { case MOVIES, SHOWS }

public enum MediaKind: String, Codable, Sendable { case MOVIE, EPISODE }

public enum MatchState: String, Codable, Sendable {
    /// Parsed but not yet looked up on TMDB.
    case PENDING
    case MATCHED
    /// TMDB returned nothing usable; needs a manual fix.
    case UNMATCHED
    /// Chosen by the user via "Fix match"; never overwritten by a rescan.
    case MANUAL
    /// Not a movie or episode (home videos, tutorials…): kept out of the library and the "needs a match" list.
    case IGNORED
}

public struct AccountEntity: Codable, Hashable, Sendable {
    public var email: String
    public var displayName: String
    public var photoUrl: String?
    public var addedAt: Int64

    public init(email: String, displayName: String, photoUrl: String? = nil, addedAt: Int64) {
        self.email = email; self.displayName = displayName; self.photoUrl = photoUrl; self.addedAt = addedAt
    }
}

public struct LibraryFolderEntity: Codable, Hashable, Sendable, Identifiable {
    public var id: Int64
    public var accountEmail: String
    /// Drive folder id, a local folder path, or smb://host/share/path.
    public var driveFolderId: String
    public var name: String
    public var type: LibraryType
    public var lastScannedAt: Int64

    public init(id: Int64 = 0, accountEmail: String, driveFolderId: String, name: String, type: LibraryType, lastScannedAt: Int64 = 0) {
        self.id = id; self.accountEmail = accountEmail; self.driveFolderId = driveFolderId; self.name = name
        self.type = type; self.lastScannedAt = lastScannedAt
    }
}

public struct MediaFileEntity: Codable, Hashable, Sendable, Identifiable {
    /// Drive file id, a local file path, or smb://host/share/path. Primary key across all sources.
    public var driveId: String
    public var accountEmail: String
    public var libraryFolderId: Int64
    public var name: String
    public var parentId: String
    /// Folder names between the library root and the file, joined with "/".
    public var relativePath: String
    public var sizeBytes: Int64
    public var modifiedTime: String?
    public var mimeType: String
    public var durationMs: Int64
    public var width: Int
    public var height: Int
    public var kind: MediaKind
    public var parsedTitle: String
    public var parsedYear: Int?
    public var season: Int?
    public var episode: Int?
    public var episodeEnd: Int?
    public var movieId: Int?
    public var showId: Int?
    public var matchState: MatchState
    public var addedAt: Int64

    public var id: String { driveId }

    public init(driveId: String, accountEmail: String, libraryFolderId: Int64, name: String, parentId: String = "",
                relativePath: String = "", sizeBytes: Int64 = 0, modifiedTime: String? = nil, mimeType: String = "",
                durationMs: Int64 = 0, width: Int = 0, height: Int = 0, kind: MediaKind, parsedTitle: String = "",
                parsedYear: Int? = nil, season: Int? = nil, episode: Int? = nil, episodeEnd: Int? = nil,
                movieId: Int? = nil, showId: Int? = nil, matchState: MatchState = .PENDING, addedAt: Int64 = 0) {
        self.driveId = driveId; self.accountEmail = accountEmail; self.libraryFolderId = libraryFolderId
        self.name = name; self.parentId = parentId; self.relativePath = relativePath; self.sizeBytes = sizeBytes
        self.modifiedTime = modifiedTime; self.mimeType = mimeType; self.durationMs = durationMs; self.width = width
        self.height = height; self.kind = kind; self.parsedTitle = parsedTitle; self.parsedYear = parsedYear
        self.season = season; self.episode = episode; self.episodeEnd = episodeEnd; self.movieId = movieId
        self.showId = showId; self.matchState = matchState; self.addedAt = addedAt
    }
}

public struct SubtitleFileEntity: Codable, Hashable, Sendable {
    public var driveId: String
    public var accountEmail: String
    public var libraryFolderId: Int64
    public var parentId: String
    public var name: String

    public init(driveId: String, accountEmail: String, libraryFolderId: Int64, parentId: String, name: String) {
        self.driveId = driveId; self.accountEmail = accountEmail; self.libraryFolderId = libraryFolderId
        self.parentId = parentId; self.name = name
    }
}

private func splitList(_ s: String) -> [String] {
    s.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
}

public struct MovieEntity: Codable, Hashable, Sendable, Identifiable {
    public var tmdbId: Int
    public var title: String
    public var originalTitle: String?
    public var overview: String
    public var tagline: String?
    public var releaseDate: String?
    public var year: Int?
    public var runtimeMin: Int?
    public var rating: Double
    public var certification: String?
    public var posterPath: String?
    public var backdropPath: String?
    /// Comma-separated genre names.
    public var genres: String
    public var collectionId: Int?
    public var collectionName: String?
    public var director: String?
    public var updatedAt: Int64

    public var id: Int { tmdbId }
    public var genreList: [String] { splitList(genres) }

    public init(tmdbId: Int, title: String, originalTitle: String? = nil, overview: String = "", tagline: String? = nil,
                releaseDate: String? = nil, year: Int? = nil, runtimeMin: Int? = nil, rating: Double = 0,
                certification: String? = nil, posterPath: String? = nil, backdropPath: String? = nil, genres: String = "",
                collectionId: Int? = nil, collectionName: String? = nil, director: String? = nil, updatedAt: Int64 = 0) {
        self.tmdbId = tmdbId; self.title = title; self.originalTitle = originalTitle; self.overview = overview
        self.tagline = tagline; self.releaseDate = releaseDate; self.year = year; self.runtimeMin = runtimeMin
        self.rating = rating; self.certification = certification; self.posterPath = posterPath
        self.backdropPath = backdropPath; self.genres = genres; self.collectionId = collectionId
        self.collectionName = collectionName; self.director = director; self.updatedAt = updatedAt
    }
}

public struct ShowEntity: Codable, Hashable, Sendable, Identifiable {
    public var tmdbId: Int
    public var name: String
    public var overview: String
    public var tagline: String?
    public var firstAirDate: String?
    public var year: Int?
    public var lastAirDate: String?
    public var status: String?
    public var rating: Double
    public var certification: String?
    public var posterPath: String?
    public var backdropPath: String?
    public var genres: String
    public var network: String?
    public var seasonCount: Int
    public var episodeCount: Int
    public var episodeRuntimeMin: Int?
    public var creator: String?
    public var updatedAt: Int64
    /// The next episode TMDB says will air (season, number, name, "yyyy-MM-dd"); nil when none is announced.
    public var nextEpisodeSeason: Int?
    public var nextEpisodeNumber: Int?
    public var nextEpisodeName: String?
    public var nextEpisodeAirDate: String?

    public var id: Int { tmdbId }
    public var genreList: [String] { splitList(genres) }

    public init(tmdbId: Int, name: String, overview: String = "", tagline: String? = nil, firstAirDate: String? = nil,
                year: Int? = nil, lastAirDate: String? = nil, status: String? = nil, rating: Double = 0,
                certification: String? = nil, posterPath: String? = nil, backdropPath: String? = nil, genres: String = "",
                network: String? = nil, seasonCount: Int = 0, episodeCount: Int = 0, episodeRuntimeMin: Int? = nil,
                creator: String? = nil, updatedAt: Int64 = 0, nextEpisodeSeason: Int? = nil, nextEpisodeNumber: Int? = nil,
                nextEpisodeName: String? = nil, nextEpisodeAirDate: String? = nil) {
        self.tmdbId = tmdbId; self.name = name; self.overview = overview; self.tagline = tagline
        self.firstAirDate = firstAirDate; self.year = year; self.lastAirDate = lastAirDate; self.status = status
        self.rating = rating; self.certification = certification; self.posterPath = posterPath
        self.backdropPath = backdropPath; self.genres = genres; self.network = network; self.seasonCount = seasonCount
        self.episodeCount = episodeCount; self.episodeRuntimeMin = episodeRuntimeMin; self.creator = creator
        self.updatedAt = updatedAt; self.nextEpisodeSeason = nextEpisodeSeason; self.nextEpisodeNumber = nextEpisodeNumber
        self.nextEpisodeName = nextEpisodeName; self.nextEpisodeAirDate = nextEpisodeAirDate
    }
}

public struct SeasonEntity: Codable, Hashable, Sendable {
    public var showId: Int
    public var seasonNumber: Int
    public var name: String
    public var overview: String
    public var posterPath: String?
    public var episodeCount: Int
    public var airDate: String?
    public var fetchedAt: Int64

    public init(showId: Int, seasonNumber: Int, name: String, overview: String = "", posterPath: String? = nil,
                episodeCount: Int = 0, airDate: String? = nil, fetchedAt: Int64 = 0) {
        self.showId = showId; self.seasonNumber = seasonNumber; self.name = name; self.overview = overview
        self.posterPath = posterPath; self.episodeCount = episodeCount; self.airDate = airDate; self.fetchedAt = fetchedAt
    }
}

public struct EpisodeEntity: Codable, Hashable, Sendable {
    public var showId: Int
    public var seasonNumber: Int
    public var episodeNumber: Int
    public var name: String
    public var overview: String
    public var stillPath: String?
    public var airDate: String?
    public var runtimeMin: Int?
    public var rating: Double

    public init(showId: Int, seasonNumber: Int, episodeNumber: Int, name: String, overview: String = "",
                stillPath: String? = nil, airDate: String? = nil, runtimeMin: Int? = nil, rating: Double = 0) {
        self.showId = showId; self.seasonNumber = seasonNumber; self.episodeNumber = episodeNumber; self.name = name
        self.overview = overview; self.stillPath = stillPath; self.airDate = airDate; self.runtimeMin = runtimeMin
        self.rating = rating
    }
}

public struct CreditEntity: Codable, Hashable, Sendable {
    /// "movie" or "tv".
    public var mediaType: String
    public var mediaId: Int
    public var personId: Int
    public var name: String
    public var character: String?
    public var profilePath: String?
    public var ord: Int

    public init(mediaType: String, mediaId: Int, personId: Int, name: String, character: String? = nil,
                profilePath: String? = nil, ord: Int) {
        self.mediaType = mediaType; self.mediaId = mediaId; self.personId = personId; self.name = name
        self.character = character; self.profilePath = profilePath; self.ord = ord
    }
}

/// TMDB's "recommendations" for a movie or show, in TMDB's order. Only the ones in the library are shown
/// ("More like this"), so the ids of titles the user doesn't have are kept too, in case they're added later.
public struct RecommendationEntity: Codable, Hashable, Sendable {
    public var mediaType: String
    public var mediaId: Int
    /// Comma-separated TMDB ids of the same type, best match first.
    public var recommendedIds: String
    public var fetchedAt: Int64

    public var ids: [Int] { recommendedIds.split(separator: ",").compactMap { Int($0) }.filter { $0 != 0 } }

    public init(mediaType: String, mediaId: Int, recommendedIds: String, fetchedAt: Int64) {
        self.mediaType = mediaType; self.mediaId = mediaId; self.recommendedIds = recommendedIds; self.fetchedAt = fetchedAt
    }
}

/// "Watch later": a movie ("movie") or show ("tv") the user saved. Shows also get new-episode alerts.
public struct WatchlistEntity: Codable, Hashable, Sendable {
    public var mediaType: String
    public var mediaId: Int
    public var addedAt: Int64

    public init(mediaType: String, mediaId: Int, addedAt: Int64) {
        self.mediaType = mediaType; self.mediaId = mediaId; self.addedAt = addedAt
    }
}

/// "Remind me": a notification at `at` (epoch ms) for a movie, a show, or one episode (season and episode set).
/// Title is kept so the reminder still reads well if the title leaves the library.
public struct ReminderEntity: Codable, Hashable, Sendable, Identifiable {
    public var id: Int64
    public var mediaType: String
    public var mediaId: Int
    public var season: Int?
    public var episode: Int?
    public var title: String
    public var at: Int64
    public var createdAt: Int64

    public init(id: Int64 = 0, mediaType: String, mediaId: Int, season: Int? = nil, episode: Int? = nil, title: String,
                at: Int64, createdAt: Int64) {
        self.id = id; self.mediaType = mediaType; self.mediaId = mediaId; self.season = season; self.episode = episode
        self.title = title; self.at = at; self.createdAt = createdAt
    }
}

/// Watch progress, keyed by *what* was watched rather than which file, so several versions of the same movie
/// (1080p / 4K, or copies in two accounts) share one progress record. See WatchKeys.
public struct WatchStateEntity: Codable, Hashable, Sendable {
    public var key: String
    public var positionMs: Int64
    public var durationMs: Int64
    public var watched: Bool
    public var lastWatchedAt: Int64
    public var lastFileId: String?
    public var movieId: Int?
    public var showId: Int?
    public var season: Int?
    public var episode: Int?

    public var progress: Float {
        durationMs > 0 ? min(max(Float(positionMs) / Float(durationMs), 0), 1) : 0
    }

    public init(key: String, positionMs: Int64 = 0, durationMs: Int64 = 0, watched: Bool = false, lastWatchedAt: Int64 = 0,
                lastFileId: String? = nil, movieId: Int? = nil, showId: Int? = nil, season: Int? = nil, episode: Int? = nil) {
        self.key = key; self.positionMs = positionMs; self.durationMs = durationMs; self.watched = watched
        self.lastWatchedAt = lastWatchedAt; self.lastFileId = lastFileId; self.movieId = movieId; self.showId = showId
        self.season = season; self.episode = episode
    }
}

public struct ShowSeason: Hashable, Sendable {
    public var showId: Int
    public var season: Int
    public init(showId: Int, season: Int) { self.showId = showId; self.season = season }
}

/// A .zip found inside a library folder. Videos inside archives can't be streamed until extracted.
public struct ArchiveFileEntity: Codable, Hashable, Sendable, Identifiable {
    public var driveId: String
    public var accountEmail: String
    public var libraryFolderId: Int64
    public var parentId: String
    public var name: String
    public var sizeBytes: Int64
    public var relativePath: String

    public var id: String { driveId }

    public init(driveId: String, accountEmail: String, libraryFolderId: Int64, parentId: String, name: String,
                sizeBytes: Int64, relativePath: String) {
        self.driveId = driveId; self.accountEmail = accountEmail; self.libraryFolderId = libraryFolderId
        self.parentId = parentId; self.name = name; self.sizeBytes = sizeBytes; self.relativePath = relativePath
    }
}

public struct MovieRow: Hashable, Sendable, Identifiable {
    public var movie: MovieEntity
    public var addedAt: Int64
    public var maxHeight: Int
    public var fileCount: Int
    public var deviceFiles: Int
    public var id: Int { movie.tmdbId }
    public init(movie: MovieEntity, addedAt: Int64, maxHeight: Int, fileCount: Int, deviceFiles: Int) {
        self.movie = movie; self.addedAt = addedAt; self.maxHeight = maxHeight; self.fileCount = fileCount
        self.deviceFiles = deviceFiles
    }
}

public struct ShowRow: Hashable, Sendable, Identifiable {
    public var show: ShowEntity
    public var addedAt: Int64
    public var availableEpisodes: Int
    public var deviceEpisodes: Int
    public var id: Int { show.tmdbId }
    public init(show: ShowEntity, addedAt: Int64, availableEpisodes: Int, deviceEpisodes: Int) {
        self.show = show; self.addedAt = addedAt; self.availableEpisodes = availableEpisodes; self.deviceEpisodes = deviceEpisodes
    }
}

/// A search result and why it matched when it wasn't the title ("Tom Hanks", "Directed by …").
public struct SearchHit: Codable, Hashable, Sendable {
    public var id: Int
    public var reason: String?
    public init(id: Int, reason: String?) { self.id = id; self.reason = reason }
}

/// One source (account email, "device" or "smb://host") that holds a copy of a movie or an episode of a show.
public struct TitleSource: Codable, Hashable, Sendable {
    public var titleId: Int
    public var accountEmail: String
    public init(titleId: Int, accountEmail: String) { self.titleId = titleId; self.accountEmail = accountEmail }
}

/// Videos found in one library folder (Settings shows it next to the folder).
public struct FolderVideoCount: Codable, Hashable, Sendable {
    public var folderId: Int64
    public var videos: Int
    public init(folderId: Int64, videos: Int) { self.folderId = folderId; self.videos = videos }
}
