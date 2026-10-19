package com.pntapps.veltoret.data.db

import androidx.room.Dao
import androidx.room.Insert
import androidx.room.OnConflictStrategy
import androidx.room.Query
import androidx.room.Transaction
import androidx.room.Update
import androidx.room.Upsert
import kotlinx.coroutines.flow.Flow

@Dao
interface AccountDao {
    @Query("SELECT * FROM accounts ORDER BY addedAt")
    fun observeAccounts(): Flow<List<AccountEntity>>

    @Query("SELECT * FROM accounts ORDER BY addedAt")
    suspend fun accounts(): List<AccountEntity>

    @Upsert
    suspend fun upsert(account: AccountEntity)

    @Query("DELETE FROM accounts WHERE email = :email")
    suspend fun delete(email: String)

    @Query("SELECT * FROM library_folders ORDER BY type, name")
    fun observeFolders(): Flow<List<LibraryFolderEntity>>

    @Query("SELECT * FROM library_folders")
    suspend fun folders(): List<LibraryFolderEntity>

    @Insert(onConflict = OnConflictStrategy.IGNORE)
    suspend fun insertFolder(folder: LibraryFolderEntity): Long

    @Query("UPDATE library_folders SET lastScannedAt = :time WHERE id = :id")
    suspend fun markFolderScanned(id: Long, time: Long)

    @Query("DELETE FROM library_folders WHERE id = :id")
    suspend fun deleteFolder(id: Long)

    @Query("DELETE FROM library_folders WHERE accountEmail = :email")
    suspend fun deleteFoldersForAccount(email: String)
}

/** Videos found in one library folder (Settings shows it next to the folder). */
data class FolderVideoCount(val folderId: Long, val videos: Int)

@Dao
interface MediaFileDao {
    @Query("SELECT * FROM media_files WHERE libraryFolderId = :folderId")
    suspend fun filesInFolder(folderId: Long): List<MediaFileEntity>

    @Query("SELECT * FROM media_files WHERE driveId = :id")
    suspend fun file(id: String): MediaFileEntity?

    @Query("SELECT * FROM media_files WHERE driveId IN (:ids)")
    suspend fun files(ids: List<String>): List<MediaFileEntity>

    @Query("SELECT * FROM media_files WHERE matchState = 'PENDING'")
    suspend fun pending(): List<MediaFileEntity>

    @Query("SELECT libraryFolderId AS folderId, COUNT(*) AS videos FROM media_files GROUP BY libraryFolderId")
    fun observeFolderCounts(): Flow<List<FolderVideoCount>>

    @Query("SELECT * FROM media_files WHERE matchState = 'UNMATCHED' ORDER BY name")
    fun observeUnmatched(): Flow<List<MediaFileEntity>>

    @Query("SELECT * FROM media_files WHERE matchState = 'IGNORED' ORDER BY name")
    fun observeIgnored(): Flow<List<MediaFileEntity>>

    @Query("UPDATE media_files SET matchState = :state, movieId = NULL, showId = NULL WHERE driveId IN (:ids)")
    suspend fun setMatchState(ids: List<String>, state: MatchState)

    @Query("SELECT * FROM media_files WHERE movieId = :movieId ORDER BY (accountEmail = 'device') DESC, height DESC, sizeBytes DESC")
    fun observeForMovie(movieId: Int): Flow<List<MediaFileEntity>>

    @Query("SELECT * FROM media_files WHERE movieId = :movieId ORDER BY (accountEmail = 'device') DESC, height DESC, sizeBytes DESC")
    suspend fun forMovie(movieId: Int): List<MediaFileEntity>

    @Query("SELECT * FROM media_files WHERE showId = :showId ORDER BY season, episode, (accountEmail = 'device') DESC")
    fun observeForShow(showId: Int): Flow<List<MediaFileEntity>>

    @Query("SELECT * FROM media_files WHERE showId = :showId ORDER BY season, episode, (accountEmail = 'device') DESC")
    suspend fun forShow(showId: Int): List<MediaFileEntity>

    @Query("SELECT * FROM media_files WHERE kind = 'EPISODE' AND showId IS NOT NULL")
    fun observeEpisodeFiles(): Flow<List<MediaFileEntity>>

    @Query("SELECT DISTINCT movieId AS titleId, accountEmail FROM media_files WHERE movieId IS NOT NULL")
    fun observeMovieSources(): Flow<List<TitleSource>>

    @Query("SELECT * FROM media_files WHERE movieId = :movieId AND accountEmail = 'device' ORDER BY height DESC, sizeBytes DESC LIMIT 1")
    suspend fun deviceCopyOfMovie(movieId: Int): MediaFileEntity?

    @Query(
        "SELECT * FROM media_files WHERE showId = :showId AND season = :season AND episode = :episode " +
            "AND accountEmail = 'device' ORDER BY height DESC LIMIT 1"
    )
    suspend fun deviceCopyOfEpisode(showId: Int, season: Int, episode: Int): MediaFileEntity?

    @Query("SELECT DISTINCT showId, season FROM media_files WHERE showId IS NOT NULL AND season IS NOT NULL")
    suspend fun showSeasons(): List<ShowSeason>

    @Upsert
    suspend fun upsert(files: List<MediaFileEntity>)

    @Query("DELETE FROM media_files WHERE driveId IN (:ids)")
    suspend fun delete(ids: List<String>)

    @Query("DELETE FROM media_files WHERE libraryFolderId = :folderId")
    suspend fun deleteForFolder(folderId: Long)

    @Query("DELETE FROM media_files WHERE accountEmail = :email")
    suspend fun deleteForAccount(email: String)

    @Query("UPDATE media_files SET name = :name WHERE driveId = :id")
    suspend fun rename(id: String, name: String)

    @Query("SELECT * FROM subtitle_files WHERE parentId = :parentId")
    suspend fun subtitlesIn(parentId: String): List<SubtitleFileEntity>

    @Query("DELETE FROM subtitle_files WHERE libraryFolderId = :folderId")
    suspend fun deleteSubtitlesForFolder(folderId: Long)

    @Query("DELETE FROM subtitle_files WHERE accountEmail = :email")
    suspend fun deleteSubtitlesForAccount(email: String)

    @Upsert
    suspend fun upsertSubtitles(subs: List<SubtitleFileEntity>)

    @Transaction
    suspend fun replaceSubtitles(folderId: Long, subs: List<SubtitleFileEntity>) {
        deleteSubtitlesForFolder(folderId)
        upsertSubtitles(subs)
    }

    @Query("SELECT * FROM archive_files ORDER BY name")
    fun observeArchives(): Flow<List<ArchiveFileEntity>>

    @Upsert
    suspend fun upsertArchives(archives: List<ArchiveFileEntity>)

    @Query("DELETE FROM archive_files WHERE libraryFolderId = :folderId")
    suspend fun deleteArchivesForFolder(folderId: Long)

    @Query("DELETE FROM archive_files WHERE accountEmail = :email")
    suspend fun deleteArchivesForAccount(email: String)

    @Query("DELETE FROM archive_files WHERE driveId = :id")
    suspend fun deleteArchive(id: String)

    @Transaction
    suspend fun replaceArchives(folderId: Long, archives: List<ArchiveFileEntity>) {
        deleteArchivesForFolder(folderId)
        upsertArchives(archives)
    }
}

@Dao
interface CatalogDao {
    @Query(
        """SELECT m.*, MIN(f.addedAt) AS addedAt, MAX(f.height) AS maxHeight, COUNT(f.driveId) AS fileCount,
                  SUM(CASE WHEN f.accountEmail = 'device' THEN 1 ELSE 0 END) AS deviceFiles
           FROM movies m JOIN media_files f ON f.movieId = m.tmdbId
           GROUP BY m.tmdbId"""
    )
    fun observeMovies(): Flow<List<MovieRow>>

    @Query(
        """SELECT s.*, MAX(f.addedAt) AS addedAt,
                  COUNT(DISTINCT (f.season * 10000 + f.episode)) AS availableEpisodes,
                  COUNT(DISTINCT CASE WHEN f.accountEmail = 'device' THEN f.season * 10000 + f.episode END) AS deviceEpisodes
           FROM shows s JOIN media_files f ON f.showId = s.tmdbId
           GROUP BY s.tmdbId"""
    )
    fun observeShows(): Flow<List<ShowRow>>

    @Query("SELECT * FROM movies WHERE tmdbId = :id")
    fun observeMovie(id: Int): Flow<MovieEntity?>

    @Query("SELECT * FROM movies WHERE tmdbId = :id")
    suspend fun movie(id: Int): MovieEntity?

    @Query("SELECT * FROM shows WHERE tmdbId = :id")
    fun observeShow(id: Int): Flow<ShowEntity?>

    @Query("SELECT * FROM shows WHERE tmdbId = :id")
    suspend fun show(id: Int): ShowEntity?

    @Query("SELECT * FROM seasons WHERE showId = :showId ORDER BY CASE WHEN seasonNumber = 0 THEN 9999 ELSE seasonNumber END")
    fun observeSeasons(showId: Int): Flow<List<SeasonEntity>>

    @Query("SELECT * FROM seasons WHERE showId = :showId AND seasonNumber = :season")
    suspend fun season(showId: Int, season: Int): SeasonEntity?

    @Query("SELECT * FROM episodes WHERE showId = :showId ORDER BY seasonNumber, episodeNumber")
    fun observeEpisodes(showId: Int): Flow<List<EpisodeEntity>>

    @Query("SELECT * FROM episodes WHERE showId = :showId AND seasonNumber = :season AND episodeNumber = :episode")
    suspend fun episode(showId: Int, season: Int, episode: Int): EpisodeEntity?

    @Query("SELECT * FROM episodes")
    fun observeAllEpisodes(): Flow<List<EpisodeEntity>>

    @Query("SELECT * FROM credits WHERE mediaType = :type AND mediaId = :id ORDER BY ord LIMIT 30")
    fun observeCredits(type: String, id: Int): Flow<List<CreditEntity>>

    @Upsert suspend fun upsertMovie(movie: MovieEntity)
    @Upsert suspend fun upsertShow(show: ShowEntity)
    @Upsert suspend fun upsertSeasons(seasons: List<SeasonEntity>)
    @Upsert suspend fun upsertEpisodes(episodes: List<EpisodeEntity>)

    @Transaction
    suspend fun replaceCredits(type: String, id: Int, credits: List<CreditEntity>) {
        deleteCredits(type, id)
        insertCredits(credits)
    }

    @Insert(onConflict = OnConflictStrategy.REPLACE)
    suspend fun insertCredits(credits: List<CreditEntity>)

    @Query("DELETE FROM credits WHERE mediaType = :type AND mediaId = :id")
    suspend fun deleteCredits(type: String, id: Int)

    @Query("DELETE FROM movies WHERE tmdbId NOT IN (SELECT movieId FROM media_files WHERE movieId IS NOT NULL)")
    suspend fun pruneMovies()

    @Query("DELETE FROM shows WHERE tmdbId NOT IN (SELECT showId FROM media_files WHERE showId IS NOT NULL)")
    suspend fun pruneShows()

    @Query("DELETE FROM seasons WHERE showId NOT IN (SELECT tmdbId FROM shows)")
    suspend fun pruneSeasons()

    @Query("DELETE FROM episodes WHERE showId NOT IN (SELECT tmdbId FROM shows)")
    suspend fun pruneEpisodes()

    @Query(
        """DELETE FROM credits WHERE (mediaType = 'movie' AND mediaId NOT IN (SELECT tmdbId FROM movies))
           OR (mediaType = 'tv' AND mediaId NOT IN (SELECT tmdbId FROM shows))"""
    )
    suspend fun pruneCredits()

    @Query("SELECT * FROM recommendations WHERE mediaType = :type AND mediaId = :id")
    fun observeRecommendations(type: String, id: Int): Flow<RecommendationEntity?>

    @Query("SELECT fetchedAt FROM recommendations WHERE mediaType = :type AND mediaId = :id")
    suspend fun recommendationsFetchedAt(type: String, id: Int): Long?

    @Upsert suspend fun upsertRecommendations(recommendations: RecommendationEntity)

    @Query(
        """DELETE FROM recommendations WHERE (mediaType = 'movie' AND mediaId NOT IN (SELECT tmdbId FROM movies))
           OR (mediaType = 'tv' AND mediaId NOT IN (SELECT tmdbId FROM shows))"""
    )
    suspend fun pruneRecommendations()

    @Transaction
    suspend fun prune() {
        pruneMovies(); pruneShows(); pruneSeasons(); pruneEpisodes(); pruneCredits(); pruneRecommendations()
    }

    /** Title, original title, director, collection or cast; title matches first. */
    @Query(
        """SELECT id, reason FROM (
             SELECT m.tmdbId AS id, m.year AS year,
               CASE
                 WHEN m.title LIKE '%' || :q || '%' OR m.originalTitle LIKE '%' || :q || '%' THEN NULL
                 WHEN m.director LIKE '%' || :q || '%' THEN 'Directed by ' || m.director
                 WHEN m.collectionName LIKE '%' || :q || '%' THEN m.collectionName
                 ELSE (SELECT c.name FROM credits c WHERE c.mediaType = 'movie' AND c.mediaId = m.tmdbId
                       AND c.name LIKE '%' || :q || '%' ORDER BY c.ord LIMIT 1)
               END AS reason
             FROM movies m
             WHERE m.title LIKE '%' || :q || '%' OR m.originalTitle LIKE '%' || :q || '%'
               OR m.director LIKE '%' || :q || '%' OR m.collectionName LIKE '%' || :q || '%'
               OR EXISTS (SELECT 1 FROM credits c WHERE c.mediaType = 'movie' AND c.mediaId = m.tmdbId AND c.name LIKE '%' || :q || '%')
           ) ORDER BY reason IS NOT NULL, year DESC LIMIT 60"""
    )
    suspend fun searchMovies(q: String): List<SearchHit>

    /** Name, creator or cast; name matches first. */
    @Query(
        """SELECT id, reason FROM (
             SELECT s.tmdbId AS id, s.year AS year,
               CASE
                 WHEN s.name LIKE '%' || :q || '%' THEN NULL
                 WHEN s.creator LIKE '%' || :q || '%' THEN 'Created by ' || s.creator
                 ELSE (SELECT c.name FROM credits c WHERE c.mediaType = 'tv' AND c.mediaId = s.tmdbId
                       AND c.name LIKE '%' || :q || '%' ORDER BY c.ord LIMIT 1)
               END AS reason
             FROM shows s
             WHERE s.name LIKE '%' || :q || '%' OR s.creator LIKE '%' || :q || '%'
               OR EXISTS (SELECT 1 FROM credits c WHERE c.mediaType = 'tv' AND c.mediaId = s.tmdbId AND c.name LIKE '%' || :q || '%')
           ) ORDER BY reason IS NOT NULL, year DESC LIMIT 60"""
    )
    suspend fun searchShows(q: String): List<SearchHit>
}

@Dao
interface PlansDao {
    @Query("SELECT * FROM watchlist ORDER BY addedAt DESC")
    fun observeWatchlist(): Flow<List<WatchlistEntity>>

    @Query("SELECT * FROM watchlist")
    suspend fun watchlist(): List<WatchlistEntity>

    @Query("SELECT EXISTS(SELECT 1 FROM watchlist WHERE mediaType = :type AND mediaId = :id)")
    fun observeInWatchlist(type: String, id: Int): Flow<Boolean>

    @Query("SELECT EXISTS(SELECT 1 FROM watchlist WHERE mediaType = :type AND mediaId = :id)")
    suspend fun isInWatchlist(type: String, id: Int): Boolean

    @Upsert suspend fun addToWatchlist(item: WatchlistEntity)

    @Query("DELETE FROM watchlist WHERE mediaType = :type AND mediaId = :id")
    suspend fun removeFromWatchlist(type: String, id: Int)

    @Query("SELECT * FROM reminders ORDER BY at")
    fun observeReminders(): Flow<List<ReminderEntity>>

    @Query("SELECT * FROM reminders ORDER BY at")
    suspend fun reminders(): List<ReminderEntity>

    @Query("SELECT * FROM reminders WHERE mediaType = :type AND mediaId = :id ORDER BY at")
    fun observeRemindersFor(type: String, id: Int): Flow<List<ReminderEntity>>

    @Query("SELECT * FROM reminders WHERE id = :id")
    suspend fun reminder(id: Long): ReminderEntity?

    @Insert suspend fun insertReminder(reminder: ReminderEntity): Long
    @Update suspend fun updateReminder(reminder: ReminderEntity)

    /** Returns how many rows went (0 when another caller deleted it first). */
    @Query("DELETE FROM reminders WHERE id = :id")
    suspend fun deleteReminder(id: Long): Int
}

@Dao
interface WatchDao {
    @Query("SELECT * FROM watch_state")
    fun observeAll(): Flow<List<WatchStateEntity>>

    @Query("SELECT * FROM watch_state WHERE `key` = :key")
    suspend fun get(key: String): WatchStateEntity?

    @Query("SELECT * FROM watch_state WHERE `key` = :key")
    fun observe(key: String): Flow<WatchStateEntity?>

    @Query("SELECT * FROM watch_state WHERE showId = :showId")
    suspend fun forShow(showId: Int): List<WatchStateEntity>

    @Query("SELECT DISTINCT showId FROM watch_state WHERE showId IS NOT NULL")
    suspend fun watchedShowIds(): List<Int>

    @Query("SELECT * FROM watch_state WHERE showId = :showId")
    fun observeForShow(showId: Int): Flow<List<WatchStateEntity>>

    @Upsert
    suspend fun upsert(state: WatchStateEntity)

    @Upsert
    suspend fun upsertAll(states: List<WatchStateEntity>)
}
