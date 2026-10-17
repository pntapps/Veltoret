package com.pntapps.veltoret.data.library

import com.pntapps.veltoret.data.db.ArchiveFileEntity
import com.pntapps.veltoret.data.db.CatalogDao
import com.pntapps.veltoret.data.db.CreditEntity
import com.pntapps.veltoret.data.db.EpisodeEntity
import com.pntapps.veltoret.data.db.MediaFileDao
import com.pntapps.veltoret.data.db.MediaFileEntity
import com.pntapps.veltoret.data.db.MovieEntity
import com.pntapps.veltoret.data.db.MovieRow
import com.pntapps.veltoret.data.db.SeasonEntity
import com.pntapps.veltoret.data.db.ShowEntity
import com.pntapps.veltoret.data.db.ShowRow
import com.pntapps.veltoret.data.db.SubtitleFileEntity
import com.pntapps.veltoret.data.net.Connectivity
import com.pntapps.veltoret.data.storage.LocalStorage
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.combine
import kotlinx.coroutines.flow.first

class LibraryRepository(
    private val catalog: CatalogDao,
    private val files: MediaFileDao,
    private val connectivity: Connectivity,
) {

    // Offline, the library is what can actually play: titles with a copy on this device.
    fun movies(): Flow<List<MovieRow>> = combine(catalog.observeMovies(), connectivity.online) { rows, online ->
        if (online) rows else rows.filter { it.deviceFiles > 0 }
    }
    fun shows(): Flow<List<ShowRow>> = combine(catalog.observeShows(), connectivity.online) { rows, online ->
        if (online) rows else rows.filter { it.deviceEpisodes > 0 }.map { it.copy(availableEpisodes = it.deviceEpisodes) }
    }
    fun movie(id: Int): Flow<MovieEntity?> = catalog.observeMovie(id)
    fun movieFiles(id: Int): Flow<List<MediaFileEntity>> = files.observeForMovie(id)
    fun show(id: Int): Flow<ShowEntity?> = catalog.observeShow(id)
    fun seasons(showId: Int): Flow<List<SeasonEntity>> = catalog.observeSeasons(showId)
    fun episodes(showId: Int): Flow<List<EpisodeEntity>> = catalog.observeEpisodes(showId)
    fun showFiles(showId: Int): Flow<List<MediaFileEntity>> = files.observeForShow(showId)
    fun credits(type: String, id: Int): Flow<List<CreditEntity>> = catalog.observeCredits(type, id)
    fun unmatched(): Flow<List<MediaFileEntity>> = files.observeUnmatched()
    fun ignored(): Flow<List<MediaFileEntity>> = files.observeIgnored()
    fun episodeFiles(): Flow<List<MediaFileEntity>> = combine(files.observeEpisodeFiles(), connectivity.online) { list, online ->
        if (online) list else list.filter { LocalStorage.isLocal(it.accountEmail) }
    }

    /** The same movie or episode stored on this device, if [file] lives on Drive and a device copy exists. */
    suspend fun deviceCopy(file: MediaFileEntity): MediaFileEntity? = when {
        LocalStorage.isLocal(file.accountEmail) -> null
        file.movieId != null -> files.deviceCopyOfMovie(file.movieId)
        file.showId != null && file.season != null && file.episode != null ->
            files.deviceCopyOfEpisode(file.showId, file.season, file.episode)
        else -> null
    }
    fun allEpisodes(): Flow<List<EpisodeEntity>> = catalog.observeAllEpisodes()
    fun archives(): Flow<List<ArchiveFileEntity>> = files.observeArchives()
    suspend fun forgetArchive(driveId: String) = files.deleteArchive(driveId)

    suspend fun file(id: String): MediaFileEntity? = files.file(id)
    suspend fun movieEntity(id: Int): MovieEntity? = catalog.movie(id)
    suspend fun showEntity(id: Int): ShowEntity? = catalog.show(id)
    suspend fun episode(showId: Int, season: Int, episode: Int): EpisodeEntity? = catalog.episode(showId, season, episode)
    suspend fun subtitlesBeside(file: MediaFileEntity): List<SubtitleFileEntity> = files.subtitlesIn(file.parentId)

    suspend fun searchIds(query: String): Pair<List<Int>, List<Int>> =
        catalog.searchMovieIds(query) to catalog.searchShowIds(query)

    /** The episode file that follows [file], preferring a copy from the same account (device copies only when offline). */
    suspend fun nextEpisodeFile(file: MediaFileEntity): MediaFileEntity? {
        val showId = file.showId ?: return null
        val season = file.season ?: return null
        val last = file.episodeEnd ?: file.episode ?: return null
        return files.forShow(showId)
            .filter { it.season != null && it.episode != null && it.season > 0 }
            .filter { connectivity.isOnline || LocalStorage.isLocal(it.accountEmail) } // offline: only what can play
            .filter { (it.season!! to it.episode!!).isAfter(season to last) }
            .sortedWith(compareBy({ it.season }, { it.episode }, { if (it.accountEmail == file.accountEmail) 0 else 1 }))
            .firstOrNull()
    }

    /** The episode file before [file] (same season ordering as [nextEpisodeFile]). */
    suspend fun previousEpisodeFile(file: MediaFileEntity): MediaFileEntity? {
        val showId = file.showId ?: return null
        val season = file.season ?: return null
        val episode = file.episode ?: return null
        return files.forShow(showId)
            .filter { it.season != null && it.episode != null && it.season > 0 }
            .filter { connectivity.isOnline || LocalStorage.isLocal(it.accountEmail) } // offline: only what can play
            .filter { (season to episode).isAfter(it.season!! to (it.episodeEnd ?: it.episode!!)) }
            .sortedWith(compareByDescending<MediaFileEntity> { it.season }.thenByDescending { it.episode }
                .thenBy { if (it.accountEmail == file.accountEmail) 0 else 1 })
            .firstOrNull()
    }

    suspend fun showFilesOnce(showId: Int): List<MediaFileEntity> = files.forShow(showId)

    suspend fun episodesOnce(showId: Int): List<EpisodeEntity> = catalog.observeEpisodes(showId).first()

    private fun Pair<Int, Int>.isAfter(other: Pair<Int, Int>) =
        first > other.first || (first == other.first && second > other.second)
}
