package com.pntapps.veltoret.data.tmdb

import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable

@Serializable
data class TmdbPage<T>(
    val page: Int = 1,
    val results: List<T> = emptyList(),
    @SerialName("total_results") val totalResults: Int = 0,
    @SerialName("total_pages") val totalPages: Int = 1,
)

@Serializable
data class TmdbVideos(val results: List<TmdbVideo> = emptyList())

/** A trailer, teaser or clip TMDB links to; [key] is the YouTube video id when [site] is "YouTube". */
@Serializable
data class TmdbVideo(
    val key: String = "",
    val site: String = "",
    val type: String = "",
    val name: String = "",
    val official: Boolean = false,
    @SerialName("published_at") val publishedAt: String? = null,
)

@Serializable
data class TmdbMovieSummary(
    val id: Int,
    val title: String = "",
    @SerialName("original_title") val originalTitle: String? = null,
    @SerialName("release_date") val releaseDate: String? = null,
    @SerialName("poster_path") val posterPath: String? = null,
    @SerialName("backdrop_path") val backdropPath: String? = null,
    val overview: String? = null,
    @SerialName("vote_average") val voteAverage: Double = 0.0,
    @SerialName("vote_count") val voteCount: Int = 0,
)

@Serializable
data class TmdbTvSummary(
    val id: Int,
    val name: String = "",
    @SerialName("original_name") val originalName: String? = null,
    @SerialName("first_air_date") val firstAirDate: String? = null,
    @SerialName("poster_path") val posterPath: String? = null,
    @SerialName("backdrop_path") val backdropPath: String? = null,
    val overview: String? = null,
    @SerialName("vote_average") val voteAverage: Double = 0.0,
    @SerialName("vote_count") val voteCount: Int = 0,
)

@Serializable
data class TmdbGenre(val id: Int, val name: String)

@Serializable
data class TmdbCast(
    val id: Int,
    val name: String,
    val character: String? = null,
    @SerialName("profile_path") val profilePath: String? = null,
    val order: Int = 0,
)

@Serializable
data class TmdbCrew(
    val id: Int,
    val name: String,
    val job: String? = null,
)

@Serializable
data class TmdbCredits(
    val cast: List<TmdbCast> = emptyList(),
    val crew: List<TmdbCrew> = emptyList(),
)

@Serializable
data class TmdbCollectionRef(val id: Int, val name: String)

@Serializable
data class TmdbReleaseDates(val results: List<TmdbCountryReleases> = emptyList())

@Serializable
data class TmdbCountryReleases(
    @SerialName("iso_3166_1") val country: String,
    @SerialName("release_dates") val releaseDates: List<TmdbReleaseDate> = emptyList(),
)

@Serializable
data class TmdbReleaseDate(val certification: String = "")

@Serializable
data class TmdbContentRatings(val results: List<TmdbContentRating> = emptyList())

@Serializable
data class TmdbContentRating(
    @SerialName("iso_3166_1") val country: String,
    val rating: String = "",
)

@Serializable
data class TmdbMovieDetail(
    val id: Int,
    val title: String = "",
    @SerialName("original_title") val originalTitle: String? = null,
    val overview: String? = null,
    val tagline: String? = null,
    @SerialName("release_date") val releaseDate: String? = null,
    val runtime: Int? = null,
    @SerialName("vote_average") val voteAverage: Double = 0.0,
    @SerialName("poster_path") val posterPath: String? = null,
    @SerialName("backdrop_path") val backdropPath: String? = null,
    val genres: List<TmdbGenre> = emptyList(),
    @SerialName("belongs_to_collection") val collection: TmdbCollectionRef? = null,
    val credits: TmdbCredits? = null,
    @SerialName("release_dates") val releaseDates: TmdbReleaseDates? = null,
)

@Serializable
data class TmdbNetwork(val name: String)

@Serializable
data class TmdbCreator(val name: String)

@Serializable
data class TmdbSeasonSummary(
    @SerialName("season_number") val seasonNumber: Int,
    val name: String = "",
    val overview: String? = null,
    @SerialName("poster_path") val posterPath: String? = null,
    @SerialName("episode_count") val episodeCount: Int = 0,
    @SerialName("air_date") val airDate: String? = null,
)

@Serializable
data class TmdbTvDetail(
    val id: Int,
    val name: String = "",
    val overview: String? = null,
    val tagline: String? = null,
    @SerialName("first_air_date") val firstAirDate: String? = null,
    @SerialName("last_air_date") val lastAirDate: String? = null,
    val status: String? = null,
    @SerialName("vote_average") val voteAverage: Double = 0.0,
    @SerialName("poster_path") val posterPath: String? = null,
    @SerialName("backdrop_path") val backdropPath: String? = null,
    val genres: List<TmdbGenre> = emptyList(),
    val networks: List<TmdbNetwork> = emptyList(),
    @SerialName("created_by") val createdBy: List<TmdbCreator> = emptyList(),
    @SerialName("number_of_seasons") val numberOfSeasons: Int = 0,
    @SerialName("number_of_episodes") val numberOfEpisodes: Int = 0,
    @SerialName("episode_run_time") val episodeRunTime: List<Int> = emptyList(),
    val seasons: List<TmdbSeasonSummary> = emptyList(),
    val credits: TmdbCredits? = null,
    @SerialName("content_ratings") val contentRatings: TmdbContentRatings? = null,
)

@Serializable
data class TmdbEpisode(
    @SerialName("episode_number") val episodeNumber: Int,
    @SerialName("season_number") val seasonNumber: Int,
    val name: String = "",
    val overview: String? = null,
    @SerialName("still_path") val stillPath: String? = null,
    @SerialName("air_date") val airDate: String? = null,
    val runtime: Int? = null,
    @SerialName("vote_average") val voteAverage: Double = 0.0,
)

@Serializable
data class TmdbSeasonDetail(
    @SerialName("season_number") val seasonNumber: Int,
    val name: String = "",
    val overview: String? = null,
    @SerialName("poster_path") val posterPath: String? = null,
    @SerialName("air_date") val airDate: String? = null,
    val episodes: List<TmdbEpisode> = emptyList(),
)
