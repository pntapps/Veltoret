package com.pntapps.veltoret.data.db

import androidx.room.Embedded
import androidx.room.Entity
import androidx.room.Index
import androidx.room.PrimaryKey

enum class LibraryType { MOVIES, SHOWS }

enum class MediaKind { MOVIE, EPISODE }

enum class MatchState {
    /** Parsed but not yet looked up on TMDB. */
    PENDING,
    MATCHED,
    /** TMDB returned nothing usable; needs a manual fix. */
    UNMATCHED,
    /** Chosen by the user via "Fix match"; never overwritten by a rescan. */
    MANUAL,
    /** Not a movie or episode (home videos, tutorials…): kept out of the library and the "needs a match" list. */
    IGNORED,
}

@Entity(tableName = "accounts")
data class AccountEntity(
    @PrimaryKey val email: String,
    val displayName: String,
    val photoUrl: String?,
    val addedAt: Long,
)

@Entity(
    tableName = "library_folders",
    indices = [Index(value = ["accountEmail", "driveFolderId", "type"], unique = true)],
)
data class LibraryFolderEntity(
    @PrimaryKey(autoGenerate = true) val id: Long = 0,
    val accountEmail: String,
    val driveFolderId: String,
    val name: String,
    val type: LibraryType,
    val lastScannedAt: Long = 0,
)

@Entity(
    tableName = "media_files",
    indices = [Index("movieId"), Index("showId"), Index("libraryFolderId"), Index("matchState")],
)
data class MediaFileEntity(
    @PrimaryKey val driveId: String,
    val accountEmail: String,
    val libraryFolderId: Long,
    val name: String,
    val parentId: String,
    /** Folder names between the library root and the file, joined with "/". */
    val relativePath: String,
    val sizeBytes: Long,
    val modifiedTime: String?,
    val mimeType: String,
    val durationMs: Long,
    val width: Int,
    val height: Int,
    val kind: MediaKind,
    val parsedTitle: String,
    val parsedYear: Int?,
    val season: Int?,
    val episode: Int?,
    val episodeEnd: Int?,
    val movieId: Int?,
    val showId: Int?,
    val matchState: MatchState,
    val addedAt: Long,
)

@Entity(tableName = "subtitle_files", indices = [Index("parentId")])
data class SubtitleFileEntity(
    @PrimaryKey val driveId: String,
    val accountEmail: String,
    val libraryFolderId: Long,
    val parentId: String,
    val name: String,
)

@Entity(tableName = "movies")
data class MovieEntity(
    @PrimaryKey val tmdbId: Int,
    val title: String,
    val originalTitle: String?,
    val overview: String,
    val tagline: String?,
    val releaseDate: String?,
    val year: Int?,
    val runtimeMin: Int?,
    val rating: Double,
    val certification: String?,
    val posterPath: String?,
    val backdropPath: String?,
    /** Comma-separated genre names. */
    val genres: String,
    val collectionId: Int?,
    val collectionName: String?,
    val director: String?,
    val updatedAt: Long,
)

@Entity(tableName = "shows")
data class ShowEntity(
    @PrimaryKey val tmdbId: Int,
    val name: String,
    val overview: String,
    val tagline: String?,
    val firstAirDate: String?,
    val year: Int?,
    val lastAirDate: String?,
    val status: String?,
    val rating: Double,
    val certification: String?,
    val posterPath: String?,
    val backdropPath: String?,
    val genres: String,
    val network: String?,
    val seasonCount: Int,
    val episodeCount: Int,
    val episodeRuntimeMin: Int?,
    val creator: String?,
    val updatedAt: Long,
)

@Entity(tableName = "seasons", primaryKeys = ["showId", "seasonNumber"])
data class SeasonEntity(
    val showId: Int,
    val seasonNumber: Int,
    val name: String,
    val overview: String,
    val posterPath: String?,
    val episodeCount: Int,
    val airDate: String?,
    val fetchedAt: Long,
)

@Entity(tableName = "episodes", primaryKeys = ["showId", "seasonNumber", "episodeNumber"])
data class EpisodeEntity(
    val showId: Int,
    val seasonNumber: Int,
    val episodeNumber: Int,
    val name: String,
    val overview: String,
    val stillPath: String?,
    val airDate: String?,
    val runtimeMin: Int?,
    val rating: Double,
)

@Entity(tableName = "credits", primaryKeys = ["mediaType", "mediaId", "personId"])
data class CreditEntity(
    val mediaType: String,
    val mediaId: Int,
    val personId: Int,
    val name: String,
    val character: String?,
    val profilePath: String?,
    val ord: Int,
)

/**
 * TMDB's "recommendations" for a movie or show, in TMDB's order. Only the ones in the library are shown
 * ("More like this"), so the ids of titles the user doesn't have are kept too, in case they're added later.
 */
@Entity(tableName = "recommendations", primaryKeys = ["mediaType", "mediaId"])
data class RecommendationEntity(
    /** "movie" or "tv", as in [CreditEntity.mediaType]. */
    val mediaType: String,
    val mediaId: Int,
    /** Comma-separated TMDB ids of the same type, best match first. */
    val recommendedIds: String,
    val fetchedAt: Long,
)

/**
 * Watch progress, keyed by *what* was watched rather than which file, so several versions of the
 * same movie (1080p / 4K, or copies in two accounts) share one progress record.
 * See [com.pntapps.veltoret.data.library.WatchKeys].
 */
@Entity(tableName = "watch_state", indices = [Index("showId")])
data class WatchStateEntity(
    @PrimaryKey val key: String,
    val positionMs: Long,
    val durationMs: Long,
    val watched: Boolean,
    val lastWatchedAt: Long,
    val lastFileId: String?,
    val movieId: Int?,
    val showId: Int?,
    val season: Int?,
    val episode: Int?,
)

val WatchStateEntity.progress: Float
    get() = if (durationMs > 0) (positionMs.toFloat() / durationMs).coerceIn(0f, 1f) else 0f

data class ShowSeason(val showId: Int, val season: Int)

/** A .zip found inside a library folder. Videos inside archives can't be streamed until extracted. */
@Entity(tableName = "archive_files", indices = [Index("libraryFolderId")])
data class ArchiveFileEntity(
    @PrimaryKey val driveId: String,
    val accountEmail: String,
    val libraryFolderId: Long,
    val parentId: String,
    val name: String,
    val sizeBytes: Long,
    val relativePath: String,
)

data class MovieRow(
    @Embedded val movie: MovieEntity,
    val addedAt: Long,
    val maxHeight: Int,
    val fileCount: Int,
    /** Copies stored on this device (playable offline). */
    val deviceFiles: Int,
)

data class ShowRow(
    @Embedded val show: ShowEntity,
    val addedAt: Long,
    val availableEpisodes: Int,
    /** Episodes with a copy on this device (playable offline). */
    val deviceEpisodes: Int,
)
