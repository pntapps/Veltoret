package com.pntapps.veltoret.data.db

import android.content.Context
import androidx.room.AutoMigration
import androidx.room.Database
import androidx.room.Room
import androidx.room.RoomDatabase

@Database(
    entities = [
        AccountEntity::class,
        LibraryFolderEntity::class,
        MediaFileEntity::class,
        SubtitleFileEntity::class,
        MovieEntity::class,
        ShowEntity::class,
        SeasonEntity::class,
        EpisodeEntity::class,
        CreditEntity::class,
        WatchStateEntity::class,
        ArchiveFileEntity::class,
        RecommendationEntity::class,
    ],
    version = 3,
    exportSchema = true,
    // v2 adds archive_files, v3 recommendations. Keep every version's schema JSON in app/schemas so upgrades keep user data.
    autoMigrations = [AutoMigration(from = 1, to = 2), AutoMigration(from = 2, to = 3)],
)
abstract class VeltoretDatabase : RoomDatabase() {
    abstract fun accountDao(): AccountDao
    abstract fun mediaFileDao(): MediaFileDao
    abstract fun catalogDao(): CatalogDao
    abstract fun watchDao(): WatchDao

    companion object {
        fun create(context: Context): VeltoretDatabase =
            Room.databaseBuilder(context, VeltoretDatabase::class.java, "veltoret.db").build()
    }
}
