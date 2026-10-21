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
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.sync.Mutex

data class ScanState(
    val running: Boolean = false,
    val phase: String = "",
    val filesFound: Int = 0,
    val toMatch: Int = 0,
    /** Files looked up on TMDB so far in this scan (found or not). */
    val matched: Int = 0,
    val error: String? = null,
    val lastFinishedAt: Long = 0,
    /** Library folders this scan covers; null means the whole library. */
    val folderIds: Set<Long>? = null,
    val foldersTotal: Int = 0,
    val foldersDone: Int = 0,
    /** Folders this scan has finished reading. */
    val doneFolderIds: Set<Long> = emptySet(),
    val currentFolderId: Long? = null,
    val currentFolder: String = "",
    /** Sub-folder being read, relative to the library folder ("Breaking Bad/Season 2"). */
    val currentPath: String = "",
    val newFiles: Int = 0,
    /** Files TMDB identified in this scan. */
    val identified: Int = 0,
    val cancelled: Boolean = false,
    /** Why a folder couldn't be read in its latest scan, by folder id. Kept until that folder scans cleanly. */
    val folderErrors: Map<Long, String> = emptyMap(),
) {
    fun covers(folderId: Long) = running && (folderIds == null || folderId in folderIds)

    /** Part of the running scan but not read yet. */
    fun waiting(folderId: Long) = covers(folderId) && folderId != currentFolderId && folderId !in doneFolderIds

    /** Progress of the current step from 0 to 1, or null when it can't be measured yet. */
    val progress: Float?
        get() = when {
            !running -> null
            toMatch > 0 -> matched.toFloat() / toMatch
            foldersTotal > 1 -> foldersDone.toFloat() / foldersTotal
            else -> null
        }
}

/**
 * Walks the library folders in Drive and on the device, mirrors their videos and subtitles into Room,
 * and matches new files against TMDB. Files already matched are never looked up again, so rescans are cheap.
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

    @Volatile private var cancelRequested = false

    private companion object {
        /** TMDB lookups per unmatched title at most (each is one or two searches). */
        const val MAX_CANDIDATES = 6
    }

    /** Thrown at the next checkpoint after [cancel]; folders already read keep their results. */
    private class ScanCancelled : Exception()

    suspend fun scanAll() = scan(null)

    /** Stops the running scan at the next folder or TMDB lookup. */
    fun cancel() {
        if (_state.value.running) cancelRequested = true
    }

    private fun checkCancelled() {
        if (cancelRequested) throw ScanCancelled()
    }

    /** Scans [folderIds], or every library folder when null. */
    suspend fun scan(folderIds: Set<Long>?) {
        if (!mutex.tryLock()) return // a scan is already running; its result will cover this request
        cancelRequested = false
        try {
            val errors = mutableListOf<String>()
            // The debug demo library has no real Drive folders behind it.
            val all = accounts.folders().filter { it.accountEmail != DemoLibrary.EMAIL }
            val folderErrors = _state.value.folderErrors.filterKeys { id -> all.any { it.id == id } }.toMutableMap()
            // Offline: device folders still refresh; Drive folders and TMDB wait for the connection to return
            // (VeltoretApp rescans when it does). Skipping them also keeps Drive titles in the library.
            val online = connectivity.isOnline
            val targets = all.filter { (folderIds == null || it.id in folderIds) && (online || storage.isLocal(it.accountEmail)) }
            _state.value = ScanState(
                running = true, phase = "Reading your folders", folderIds = folderIds,
                foldersTotal = targets.size, folderErrors = folderErrors.toMap(),
            )
            for (folder in targets) {
                checkCancelled()
                _state.update { it.copy(currentFolderId = folder.id, currentFolder = folder.name, currentPath = "") }
                try {
                    scanFolder(folder)
                    folderErrors.remove(folder.id)
                } catch (e: CancellationException) {
                    throw e
                } catch (e: ScanCancelled) {
                    throw e
                } catch (e: Exception) {
                    val reason = folderError(e)
                    folderErrors[folder.id] = reason
                    errors += "${folder.name}: $reason"
                }
                _state.update { it.copy(foldersDone = it.foldersDone + 1, doneFolderIds = it.doneFolderIds + folder.id, folderErrors = folderErrors.toMap()) }
            }
            _state.update { it.copy(currentFolderId = null, currentFolder = "", currentPath = "") }
            if (online) try {
                matchPending()
                // Refreshing every show is a whole-library job; a single-folder scan skips it.
                if (folderIds == null) {
                    refreshShows()
                    refreshRecommendations()
                }
            } catch (e: CancellationException) {
                throw e
            } catch (e: ScanCancelled) {
                throw e
            } catch (e: Exception) {
                errors += e.message ?: "Could not reach TMDB"
            }
            catalog.prune()
            val now = System.currentTimeMillis()
            if (folderIds == null) settings.setLastScan(now)
            _state.update { it.copy(running = false, phase = "", error = errors.firstOrNull(), lastFinishedAt = now) }
        } catch (e: ScanCancelled) {
            catalog.prune()
            _state.update {
                it.copy(
                    running = false, phase = "", cancelled = true, currentFolderId = null, currentFolder = "",
                    currentPath = "", lastFinishedAt = System.currentTimeMillis(),
                )
            }
        } catch (e: CancellationException) {
            // The worker was stopped (Cancel in the notification, or by the system).
            _state.update {
                it.copy(
                    running = false, phase = "", cancelled = true, currentFolderId = null, currentFolder = "",
                    currentPath = "", lastFinishedAt = System.currentTimeMillis(),
                )
            }
            throw e
        } finally {
            cancelRequested = false
            mutex.unlock()
        }
    }

    private fun folderError(e: Exception): String = when (e) {
        // A device folder whose permission is gone (app reinstalled, SD card swapped...).
        is SecurityException -> "Veltoret lost access to this folder. Remove it and add it again."
        else -> e.message ?: e.javaClass.simpleName
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
            checkCancelled()
            _state.update { it.copy(currentPath = path.joinToString("/")) }
            for (child in storage.list(folder.accountEmail, folderId, orderBy = "folder")) {
                when {
                    child.isFolder -> queue.add(child.id to path + child.name)
                    FilenameParser.isSubtitle(child.name) ->
                        subtitles += SubtitleFileEntity(child.id, folder.accountEmail, folder.id, folderId, child.name)
                    // ZIP extraction uploads to Drive, so archives are only listed for Drive folders.
                    FilenameParser.isArchive(child.name) && !storage.isLocal(folder.accountEmail) && !storage.isSmb(folder.accountEmail) ->
                        archives += ArchiveFileEntity(
                            child.id, folder.accountEmail, folder.id, folderId, child.name, child.sizeBytes, path.joinToString("/"),
                        )
                    FilenameParser.isVideo(child.name, child.mimeType) && !isSample(child) -> {
                        val previous = existing[child.id]
                        seen += toEntity(child, folder, folderId, path, previous)
                        _state.update { it.copy(filesFound = it.filesFound + 1, newFiles = it.newFiles + if (previous == null) 1 else 0) }
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
        // Unmatched files fall through and are parsed again (back to PENDING) when the parser now reads
        // their name differently, e.g. after a parser fix; otherwise they'd stay unmatched forever.
        if (previous != null && previous.name == file.name && previous.relativePath == relativePath &&
            !(previous.matchState == MatchState.UNMATCHED && parsesDifferently(file.name, path, folder.type, previous))
        ) {
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

    private fun parsesDifferently(name: String, path: List<String>, type: LibraryType, previous: MediaFileEntity): Boolean =
        if (type == LibraryType.MOVIES) {
            val guess = FilenameParser.parseMovie(name, path)
            guess.title != previous.parsedTitle || guess.year != previous.parsedYear
        } else {
            val guess = FilenameParser.parseEpisode(name, path)
            guess != null && (guess.showTitle != previous.parsedTitle || guess.showYear != previous.parsedYear ||
                guess.season != previous.season || guess.episode != previous.episode)
        }

    private suspend fun matchPending() {
        val pending = files.pending()
        if (pending.isEmpty()) return
        _state.update { it.copy(phase = "Matching with TMDB", toMatch = pending.size, matched = 0) }

        val groups = pending.groupBy { Triple(it.kind, FilenameParser.normalizeForCompare(it.parsedTitle), it.parsedYear) }
        for ((key, group) in groups) {
            checkCancelled()
            val sample = group.first()
            val updated = try {
                val path = sample.relativePath.split('/').filter { it.isNotEmpty() }
                // The parser's guess first, then its fallbacks (the file's own title, trimmed leftovers...).
                val candidates = listOf(FilenameParser.TitleCandidate(sample.parsedTitle, sample.parsedYear)) +
                    if (key.first == MediaKind.MOVIE) FilenameParser.movieCandidates(sample.name, path)
                    else FilenameParser.showCandidates(sample.name, path)
                val lookups = candidates.distinctBy { FilenameParser.normalizeForCompare(it.title) to it.year }.take(MAX_CANDIDATES)
                if (key.first == MediaKind.MOVIE) {
                    val match = lookups.firstNotNullOfOrNull { tmdb.findMovie(it.title, it.year, it.exactOnly) }
                    if (match != null) {
                        tmdb.ensureMovie(match.id)
                        group.map { it.copy(movieId = match.id, showId = null, matchState = MatchState.MATCHED) }
                    } else null
                } else {
                    val match = lookups.firstNotNullOfOrNull { tmdb.findShow(it.title, it.year, it.exactOnly) }
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
            _state.update { it.copy(matched = it.matched + group.size, identified = it.identified + (updated?.size ?: 0)) }
        }
    }

    /** Keeps ongoing shows fresh and fetches episode lists for newly added seasons. */
    private suspend fun refreshShows() {
        files.showSeasons().groupBy { it.showId }.forEach { (showId, seasons) ->
            runCatching { tmdb.ensureShow(showId, seasons.mapTo(HashSet()) { it.season }) }
                .onFailure { if (it is CancellationException || it is TmdbKeyMissingException) throw it }
        }
    }

    /** Fetches "More like this" for titles that have none yet or a month-old list. Detail pages also fetch on open. */
    private suspend fun refreshRecommendations() {
        val ids = catalog.observeMovies().first().map { "movie" to it.movie.tmdbId } +
            catalog.observeShows().first().map { "tv" to it.show.tmdbId }
        for ((type, id) in ids) {
            checkCancelled()
            runCatching { tmdb.ensureRecommendations(type, id) }
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
