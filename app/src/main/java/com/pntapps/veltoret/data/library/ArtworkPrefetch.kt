package com.pntapps.veltoret.data.library

import android.content.Context
import coil3.SingletonImageLoader
import coil3.request.CachePolicy
import coil3.request.ImageRequest
import coil3.size.Size
import com.pntapps.veltoret.data.db.CatalogDao
import com.pntapps.veltoret.data.tmdb.TmdbImages
import kotlinx.coroutines.flow.first

/**
 * Downloads library artwork into the image disk cache after a scan, so posters and backdrops show up
 * offline even for titles the user never scrolled to. Uses exactly the URLs the screens request (the
 * cache is keyed by URL), skips anything already cached, and decodes at a tiny size since only the
 * downloaded bytes matter.
 */
class ArtworkPrefetch(private val context: Context, private val catalog: CatalogDao) {

    suspend fun run() {
        val loader = SingletonImageLoader.get(context)
        val disk = loader.diskCache ?: return
        val movies = catalog.observeMovies().first()
        val shows = catalog.observeShows().first()
        val urls = buildList {
            for (m in movies) {
                add(TmdbImages.poster(m.movie.posterPath))              // grids, rows, search
                add(TmdbImages.poster(m.movie.posterPath, "w500"))      // detail page
                add(TmdbImages.backdrop(m.movie.backdropPath))          // detail page, featured
                add(TmdbImages.backdrop(m.movie.backdropPath, "w780"))  // Continue Watching
            }
            for (s in shows) {
                add(TmdbImages.poster(s.show.posterPath))
                add(TmdbImages.poster(s.show.posterPath, "w500"))
                add(TmdbImages.backdrop(s.show.backdropPath))
                add(TmdbImages.backdrop(s.show.backdropPath, "w780"))
            }
            // Episode stills for shows that can play offline.
            val offlineShows = shows.filter { it.deviceEpisodes > 0 }.map { it.show.tmdbId }.toSet()
            for (ep in catalog.observeAllEpisodes().first()) {
                if (ep.showId in offlineShows) add(TmdbImages.still(ep.stillPath))
            }
        }.filterNotNull().distinct()

        for (url in urls) {
            val cached = disk.openSnapshot(url)?.use { true } == true
            if (cached) continue
            loader.execute(
                ImageRequest.Builder(context)
                    .data(url)
                    .size(Size(32, 32))
                    .memoryCachePolicy(CachePolicy.DISABLED)
                    .build()
            )
        }
    }
}
