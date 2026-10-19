package com.pntapps.veltoret.data.tmdb

import com.pntapps.veltoret.data.db.CatalogDao
import com.pntapps.veltoret.data.db.CreditEntity
import com.pntapps.veltoret.data.db.EpisodeEntity
import com.pntapps.veltoret.data.db.MovieEntity
import com.pntapps.veltoret.data.db.RecommendationEntity
import com.pntapps.veltoret.data.db.SeasonEntity
import com.pntapps.veltoret.data.db.ShowEntity
import com.pntapps.veltoret.data.library.FilenameParser

/** Looks titles up on TMDB and caches the results in Room. */
class TmdbRepository(private val api: TmdbApi, private val catalog: CatalogDao) {

    suspend fun searchMovies(query: String, year: Int? = null): List<TmdbMovieSummary> =
        api.searchMovie(query, year).results

    suspend fun searchShows(query: String, year: Int? = null): List<TmdbTvSummary> =
        api.searchTv(query, year).results

    suspend fun validateKey() {
        api.configuration()
    }

    /** Finds the best movie match, retrying without the year when the year-filtered search is empty. */
    /** [exactOnly]: accept only an exact title match (for fallback names guessed by trimming a file name). */
    suspend fun findMovie(title: String, year: Int?, exactOnly: Boolean = false): TmdbMovieSummary? {
        val withYear = if (year != null) searchMovies(title, year) else emptyList()
        val results = withYear.ifEmpty { searchMovies(title) }
        return pickBest(results, title, year, exactOnly, { it.title }, { it.originalTitle }, { it.releaseDate }, { it.voteCount })
    }

    suspend fun findShow(title: String, year: Int?, exactOnly: Boolean = false): TmdbTvSummary? {
        val withYear = if (year != null) searchShows(title, year) else emptyList()
        val results = withYear.ifEmpty { searchShows(title) }
        return pickBest(results, title, year, exactOnly, { it.name }, { it.originalName }, { it.firstAirDate }, { it.voteCount })
    }

    suspend fun ensureMovie(id: Int, maxAgeMs: Long = 30L * DAY) {
        val existing = catalog.movie(id)
        if (existing != null && System.currentTimeMillis() - existing.updatedAt < maxAgeMs) return
        val d = api.movie(id)
        val certification = d.releaseDates?.results
            ?.firstOrNull { it.country == "US" }
            ?.releaseDates?.firstOrNull { it.certification.isNotBlank() }?.certification
        catalog.upsertMovie(
            MovieEntity(
                tmdbId = d.id,
                title = d.title,
                originalTitle = d.originalTitle,
                overview = d.overview.orEmpty(),
                tagline = d.tagline?.takeIf { it.isNotBlank() },
                releaseDate = d.releaseDate,
                year = yearOf(d.releaseDate),
                runtimeMin = d.runtime?.takeIf { it > 0 },
                rating = d.voteAverage,
                certification = certification,
                posterPath = d.posterPath,
                backdropPath = d.backdropPath,
                genres = d.genres.joinToString(",") { it.name },
                collectionId = d.collection?.id,
                collectionName = d.collection?.name,
                director = d.credits?.crew?.firstOrNull { it.job == "Director" }?.name,
                updatedAt = System.currentTimeMillis(),
            )
        )
        catalog.replaceCredits("movie", d.id, d.credits?.cast.orEmpty().toCredits("movie", d.id))
    }

    /** Stores show details plus full episode lists for [seasonsNeeded]. */
    suspend fun ensureShow(id: Int, seasonsNeeded: Set<Int>, maxAgeMs: Long = 7L * DAY) {
        val existing = catalog.show(id)
        val now = System.currentTimeMillis()
        if (existing == null || now - existing.updatedAt >= maxAgeMs) {
            val d = api.tv(id)
            catalog.upsertShow(
                ShowEntity(
                    tmdbId = d.id,
                    name = d.name,
                    overview = d.overview.orEmpty(),
                    tagline = d.tagline?.takeIf { it.isNotBlank() },
                    firstAirDate = d.firstAirDate,
                    year = yearOf(d.firstAirDate),
                    lastAirDate = d.lastAirDate,
                    status = d.status,
                    rating = d.voteAverage,
                    certification = d.contentRatings?.results?.firstOrNull { it.country == "US" }?.rating
                        ?.takeIf { it.isNotBlank() },
                    posterPath = d.posterPath,
                    backdropPath = d.backdropPath,
                    genres = d.genres.joinToString(",") { it.name },
                    network = d.networks.firstOrNull()?.name,
                    seasonCount = d.numberOfSeasons,
                    episodeCount = d.numberOfEpisodes,
                    episodeRuntimeMin = d.episodeRunTime.firstOrNull(),
                    creator = d.createdBy.joinToString(", ") { it.name }.ifBlank { null },
                    updatedAt = now,
                )
            )
            catalog.upsertSeasons(
                d.seasons.map {
                    SeasonEntity(
                        showId = d.id,
                        seasonNumber = it.seasonNumber,
                        name = it.name,
                        overview = it.overview.orEmpty(),
                        posterPath = it.posterPath,
                        episodeCount = it.episodeCount,
                        airDate = it.airDate,
                        fetchedAt = 0,
                    )
                }
            )
            catalog.replaceCredits("tv", d.id, d.credits?.cast.orEmpty().toCredits("tv", d.id))
        }
        for (seasonNumber in seasonsNeeded) {
            val season = catalog.season(id, seasonNumber)
            if (season != null && now - season.fetchedAt < maxAgeMs) continue
            val s = runCatching { api.season(id, seasonNumber) }.getOrNull() ?: continue
            catalog.upsertSeasons(
                listOf(
                    SeasonEntity(
                        showId = id,
                        seasonNumber = s.seasonNumber,
                        name = s.name,
                        overview = s.overview.orEmpty(),
                        posterPath = s.posterPath ?: season?.posterPath,
                        episodeCount = s.episodes.size,
                        airDate = s.airDate,
                        fetchedAt = now,
                    )
                )
            )
            catalog.upsertEpisodes(
                s.episodes.map {
                    EpisodeEntity(
                        showId = id,
                        seasonNumber = it.seasonNumber,
                        episodeNumber = it.episodeNumber,
                        name = it.name,
                        overview = it.overview.orEmpty(),
                        stillPath = it.stillPath,
                        airDate = it.airDate,
                        runtimeMin = it.runtime,
                        rating = it.voteAverage,
                    )
                }
            )
        }
    }

    /**
     * Stores TMDB's recommendations for a movie ([type] "movie") or show ("tv"). Fetches the first
     * [RECOMMENDATION_PAGES] pages (20 titles each) so a personal library has a fair chance of owning some.
     */
    suspend fun ensureRecommendations(type: String, id: Int, maxAgeMs: Long = 30L * DAY) {
        val fetchedAt = catalog.recommendationsFetchedAt(type, id)
        if (fetchedAt != null && System.currentTimeMillis() - fetchedAt < maxAgeMs) return
        val ids = mutableListOf<Int>()
        for (page in 1..RECOMMENDATION_PAGES) {
            val (results, pages) = if (type == "movie") api.movieRecommendations(id, page).let { p -> p.results.map { it.id } to p.totalPages }
            else api.tvRecommendations(id, page).let { p -> p.results.map { it.id } to p.totalPages }
            ids += results
            if (page >= pages) break
        }
        catalog.upsertRecommendations(
            RecommendationEntity(type, id, ids.distinct().filter { it != id }.joinToString(","), System.currentTimeMillis())
        )
    }

    /**
     * The YouTube id of the title's trailer ([type] "movie" or "tv"), or null when TMDB lists none.
     * Fetched when a detail page opens and kept for the session; nothing is stored in the database.
     */
    suspend fun trailer(type: String, id: Int): String? {
        val key = "$type:$id"
        trailers[key]?.let { return it.ifEmpty { null } }
        val videos = if (type == "movie") api.movieVideos(id).results else api.tvVideos(id).results
        return pickTrailer(videos, newest = type == "tv").also { trailers[key] = it.orEmpty() }
    }

    /** "movie:603" → YouTube id, or "" when the title has no trailer. */
    private val trailers = java.util.concurrent.ConcurrentHashMap<String, String>()

    private fun List<TmdbCast>.toCredits(type: String, id: Int) = take(30).distinctBy { it.id }.map {
        CreditEntity(type, id, it.id, it.name, it.character, it.profilePath, it.order)
    }

    private fun <T> pickBest(
        results: List<T>,
        wantTitle: String,
        wantYear: Int?,
        exactOnly: Boolean,
        title: (T) -> String,
        originalTitle: (T) -> String?,
        date: (T) -> String?,
        votes: (T) -> Int,
    ): T? {
        if (results.isEmpty()) return null
        val want = FilenameParser.normalizeForCompare(wantTitle)
        if (want.isBlank()) return null
        return results.take(8).withIndex().mapNotNull { (index, item) ->
            val names = listOfNotNull(title(item), originalTitle(item)).map(FilenameParser::normalizeForCompare)
            val y = yearOf(date(item))
            val yearDiff = if (wantYear != null && y != null) kotlin.math.abs(y - wantYear) else null
            val exact = names.any { it == want }
            // A partial title match ("vids" vs "ambient vids") only counts when the names are close in
            // length or the year agrees; otherwise any short filename would grab an obscure title.
            val partial = !exact && names.any { n ->
                (n.contains(want) || want.contains(n)) &&
                    (minOf(n.length, want.length).toDouble() / maxOf(n.length, want.length) >= 0.6 || yearDiff == 0)
            }
            if (!exact && !partial) return@mapNotNull null
            // Fallback names (see FilenameParser.TitleCandidate) need the exact title and, when known, a close year.
            if (exactOnly && (!exact || (yearDiff != null && yearDiff > 1))) return@mapNotNull null
            var score = if (exact) 3.0 else 1.0
            score -= index * 0.15
            score += when (yearDiff) {
                null -> 0.0
                0 -> 2.0
                1 -> 1.0
                else -> -0.5
            }
            // Prefer titles people have actually rated; breaks ties between remakes and obscure uploads.
            score += kotlin.math.min(kotlin.math.log10(votes(item) + 1.0), 4.0) * 0.25
            // A bare title with no year that only matches something nobody has heard of is a guess.
            if (wantYear == null && votes(item) < 20 && want.length < 12) return@mapNotNull null
            item to score
        }.maxByOrNull { it.second }?.first
    }

    companion object {
        private const val DAY = 24L * 60 * 60 * 1000
        private const val RECOMMENDATION_PAGES = 2
        fun yearOf(date: String?): Int? = date?.take(4)?.toIntOrNull()

        /**
         * YouTube trailers first, then teasers (no clips or featurettes); official uploads first. Movies take
         * the earliest (the original trailer, not a re-release); shows take the newest (the latest season's).
         */
        fun pickTrailer(videos: List<TmdbVideo>, newest: Boolean): String? = videos
            .filter { it.site.equals("YouTube", ignoreCase = true) && it.key.isNotBlank() && it.type in TRAILER_TYPES }
            .sortedWith(
                compareBy<TmdbVideo>({ TRAILER_TYPES.indexOf(it.type) }, { !it.official }).thenComparator { a, b ->
                    // ISO dates sort as text; undated videos go last either way.
                    val x = a.publishedAt.orEmpty()
                    val y = b.publishedAt.orEmpty()
                    when {
                        x.isEmpty() || y.isEmpty() -> y.length.compareTo(x.length).coerceIn(-1, 1)
                        newest -> y.compareTo(x)
                        else -> x.compareTo(y)
                    }
                }
            )
            .firstOrNull()?.key

        private val TRAILER_TYPES = listOf("Trailer", "Teaser")
    }
}
