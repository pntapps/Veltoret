package com.pntapps.veltoret.data.library

import com.pntapps.veltoret.data.db.AccountDao
import com.pntapps.veltoret.data.db.ArchiveFileEntity
import com.pntapps.veltoret.data.db.CatalogDao
import com.pntapps.veltoret.data.db.LibraryFolderEntity
import com.pntapps.veltoret.data.db.LibraryType
import com.pntapps.veltoret.data.db.MatchState
import com.pntapps.veltoret.data.db.MediaFileDao
import com.pntapps.veltoret.data.db.MediaFileEntity
import com.pntapps.veltoret.data.db.MediaKind
import com.pntapps.veltoret.data.db.SubtitleFileEntity
import com.pntapps.veltoret.data.demo.DemoLibrary
import com.pntapps.veltoret.data.drive.DriveFile
import com.pntapps.veltoret.data.net.Connectivity
import com.pntapps.veltoret.data.storage.Storage
import com.pntapps.veltoret.data.settings.SettingsRepository
import com.pntapps.veltoret.data.tmdb.TmdbKeyMissingException
import com.pntapps.veltoret.data.tmdb.TmdbRepository
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.sync.Mutex

data class ScanState(
    val running: Boolean = false,
    val phase: String = "",
    val filesFound: Int = 0,
    val toMatch: Int = 0,
    val matched: Int = 0,
    val error: String? = null,
    val lastFinishedAt: Long = 0,
)

/**
 * Walks every library folder in Drive, mirrors its videos and subtitles into Room, and matches
 * new files against TMDB. Files already matched are never looked up again, so rescans are cheap.
 */
class LibraryScanner(
    private val accounts: AccountDao,
    private val files: MediaFileDao,
    private val catalog: CatalogDao,
    private val storage: Storage,
    private val tmdb: TmdbRepository,
    private val settings: SettingsRepository,
    private val connectivity: Connectivity,
) {
    private val mutex = Mutex()
    private val _state = MutableStateFlow(ScanState())
    val state: StateFlow<ScanState> = _state.asStateFlow()

    suspend fun scanAll() {
        if (!mutex.tryLock()) return // a scan is already running; its result will cover this request
        try {
            val errors = mutableListOf<String>()
            _state.value = ScanState(running = true, phase = "Reading your folders")
            // The debug demo library has no real Drive folders behind it.
            // Offline: device folders still refresh; Drive folders and TMDB wait for the connection to return
            // (VeltoretApp rescans when it does). Skipping them also keeps Drive titles in the library.
            val online = connectivity.isOnline
            for (folder in accounts.folders().filter { it.accountEmail != DemoLibrary.EMAIL }) {
                if (!online && !storage.isLocal(folder.accountEmail)) continue
                try {
                    scanFolder(folder)
                } catch (e: CancellationException) {
                    throw e
                } catch (e: Exception) {
                    errors += "${folder.name}: ${e.message ?: e.javaClass.simpleName}"
                }
            }
            if (online) try {
                matchPending()
                refreshShows()
            } catch (e: CancellationException) {
                throw e
            } catch (e: Exception) {
                errors += e.message ?: "Could not reach TMDB"
            }
            catalog.prune()
            val now = System.currentTimeMillis()
            settings.setLastScan(now)
            _state.update { ScanState(running = false, filesFound = it.filesFound, matched = it.matched, error = errors.firstOrNull(), lastFinishedAt = now) }
        } catch (e: CancellationException) {
            _state.update { it.copy(running = false) }
            throw e
        } finally {
            mutex.unlock()
        }
    }

    private suspend fun scanFolder(folder: LibraryFolderEntity) {
        val existing = files.filesInFolder(folder.id).associateBy { it.driveId }
        val seen = mutableListOf<MediaFileEntity>()
        val subtitles = mutableListOf<SubtitleFileEntity>()
        val archives = mutableListOf<ArchiveFileEntity>()
        val queue = ArrayDeque<Pair<String, List<String>>>()
        val visited = mutableSetOf<String>()
        queue.add(folder.driveFolderId to emptyList())

        while (queue.isNotEmpty()) {
            val (folderId, path) = queue.removeFirst()
            if (!visited.add(folderId)) continue
            for (child in storage.list(folder.accountEmail, folderId, orderBy = "folder")) {
                when {
                    child.isFolder -> queue.add(child.id to path + child.name)
                    FilenameParser.isSubtitle(child.name) ->
                        subtitles += SubtitleFileEntity(child.id, folder.accountEmail, folder.id, folderId, child.name)
                    FilenameParser.isArchive(child.name) && !storage.isLocal(folder.accountEmail) ->
                        archives += ArchiveFileEntity(
                            child.id, folder.accountEmail, folder.id, folderId, child.name, child.sizeBytes, path.joinToString("/"),
                        )
                    FilenameParser.isVideo(child.name, child.mimeType) && !isSample(child) -> {
                        seen += toEntity(child, folder, folderId, path, existing[child.id])
                        _state.update { it.copy(filesFound = it.filesFound + 1) }
                    }
                }
            }
        }

        files.upsert(seen)
        val gone = existing.keys - seen.mapTo(HashSet()) { it.driveId }
        if (gone.isNotEmpty()) files.delete(gone.toList())
        files.replaceSubtitles(folder.id, subtitles)
        files.replaceArchives(folder.id, archives)
        accounts.markFolderScanned(folder.id, System.currentTimeMillis())
    }

    private fun isSample(file: DriveFile) =
        file.name.contains("sample", ignoreCase = true) && file.sizeBytes in 1 until 150L * 1024 * 1024

    private fun toEntity(
        file: DriveFile,
        folder: LibraryFolderEntity,
        parentId: String,
        path: List<String>,
        previous: MediaFileEntity?,
    ): MediaFileEntity {
        val relativePath = path.joinToString("/")
        val meta = file.videoMediaMetadata
        val duration = meta?.durationMillis?.toLongOrNull() ?: previous?.durationMs ?: 0L
        if (previous != null && previous.name == file.name && previous.relativePath == relativePath) {
            return previous.copy(
                parentId = parentId,
                sizeBytes = file.sizeBytes,
                modifiedTime = file.modifiedTime,
                durationMs = duration,
                width = meta?.width ?: previous.width,
                height = meta?.height ?: previous.height,
            )
        }

        val manual = previous?.matchState == MatchState.MANUAL
        val ignored = previous?.matchState == MatchState.IGNORED
        val base = MediaFileEntity(
            driveId = file.id,
            accountEmail = folder.accountEmail,
            libraryFolderId = folder.id,
            name = file.name,
            parentId = parentId,
            relativePath = relativePath,
            sizeBytes = file.sizeBytes,
            modifiedTime = file.modifiedTime,
            mimeType = file.mimeType,
            durationMs = duration,
            width = meta?.width ?: 0,
            height = meta?.height ?: 0,
            kind = if (folder.type == LibraryType.MOVIES) MediaKind.MOVIE else MediaKind.EPISODE,
            parsedTitle = "",
            parsedYear = null,
            season = null,
            episode = null,
            episodeEnd = null,
            movieId = if (manual) previous.movieId else null,
            showId = if (manual) previous.showId else null,
            matchState = when {
                manual -> MatchState.MANUAL
                ignored -> MatchState.IGNORED
                else -> MatchState.PENDING
            },
            addedAt = previous?.addedAt ?: System.currentTimeMillis(),
        )
        return if (folder.type == LibraryType.MOVIES) {
            val guess = FilenameParser.parseMovie(file.name, path)
            base.copy(parsedTitle = guess.title, parsedYear = guess.year)
        } else {
            val guess = FilenameParser.parseEpisode(file.name, path)
            if (guess == null) {
                base.copy(
                    parsedTitle = FilenameParser.clean(file.name),
                    matchState = when {
                        manual -> MatchState.MANUAL
                        ignored -> MatchState.IGNORED
                        else -> MatchState.UNMATCHED
                    },
                )
            } else {
                base.copy(
                    parsedTitle = guess.showTitle,
                    parsedYear = guess.showYear,
                    season = guess.season,
                    episode = guess.episode,
                    episodeEnd = guess.episodeEnd,
                )
            }
        }
    }

    private suspend fun matchPending() {
        val pending = files.pending()
        if (pending.isEmpty()) return
        _state.update { it.copy(phase = "Matching with TMDB", toMatch = pending.size, matched = 0) }

        val groups = pending.groupBy { Triple(it.kind, FilenameParser.normalizeForCompare(it.parsedTitle), it.parsedYear) }
        for ((key, group) in groups) {
            val sample = group.first()
            val updated = try {
                if (key.first == MediaKind.MOVIE) {
                    val match = tmdb.findMovie(sample.parsedTitle, sample.parsedYear)
                    if (match != null) {
                        tmdb.ensureMovie(match.id)
                        group.map { it.copy(movieId = match.id, showId = null, matchState = MatchState.MATCHED) }
                    } else null
                } else {
                    val match = tmdb.findShow(sample.parsedTitle, sample.parsedYear)
                    if (match != null) {
                        tmdb.ensureShow(match.id, group.mapNotNullTo(HashSet()) { it.season })
                        group.map { it.copy(showId = match.id, movieId = null, matchState = MatchState.MATCHED) }
                    } else null
                }
            } catch (e: TmdbKeyMissingException) {
                throw e
            } catch (e: CancellationException) {
                throw e
            } catch (e: Exception) {
                // Network hiccup: leave as PENDING so the next scan retries.
                _state.update { it.copy(matched = it.matched + group.size) }
                continue
            }
            files.upsert(updated ?: group.map { it.copy(matchState = MatchState.UNMATCHED) })
            _state.update { it.copy(matched = it.matched + group.size) }
        }
    }

    /** Keeps ongoing shows fresh and fetches episode lists for newly added seasons. */
    private suspend fun refreshShows() {
        files.showSeasons().groupBy { it.showId }.forEach { (showId, seasons) ->
            runCatching { tmdb.ensureShow(showId, seasons.mapTo(HashSet()) { it.season }) }
                .onFailure { if (it is CancellationException || it is TmdbKeyMissingException) throw it }
        }
    }

    /** "Fix match": pins files to a TMDB title chosen by the user. */
    suspend fun applyManualMatch(fileIds: List<String>, kind: MediaKind, tmdbId: Int) {
        val targets = files.files(fileIds)
        if (kind == MediaKind.MOVIE) {
            tmdb.ensureMovie(tmdbId)
            files.upsert(
                targets.map {
                    it.copy(kind = MediaKind.MOVIE, movieId = tmdbId, showId = null, season = null, episode = null,
                        episodeEnd = null, matchState = MatchState.MANUAL)
                }
            )
        } else {
            val updated = targets.map { file ->
                val guess = FilenameParser.parseEpisode(file.name, file.relativePath.split('/').filter { it.isNotEmpty() })
                file.copy(
                    kind = MediaKind.EPISODE,
                    showId = tmdbId,
                    movieId = null,
                    season = file.season ?: guess?.season ?: 1,
                    episode = file.episode ?: guess?.episode ?: 1,
                    matchState = MatchState.MANUAL,
                )
            }
            tmdb.ensureShow(tmdbId, updated.mapNotNullTo(HashSet()) { it.season })
            files.upsert(updated)
        }
        catalog.prune()
    }

    /** Keeps files out of the library until restored; survives rescans. */
    suspend fun ignore(fileIds: List<String>) {
        files.setMatchState(fileIds, MatchState.IGNORED)
        catalog.prune()
    }

    /** Puts ignored files back up for automatic matching on the next scan. */
    suspend fun restore(fileIds: List<String>) = files.setMatchState(fileIds, MatchState.PENDING)

    suspend fun onFileRenamed(driveId: String, newName: String) = files.rename(driveId, newName)

    suspend fun onFilesRemoved(driveIds: List<String>) {
        files.delete(driveIds)
        catalog.prune()
    }
}
