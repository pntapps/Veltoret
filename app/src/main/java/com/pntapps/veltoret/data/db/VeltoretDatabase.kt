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
    ],
    version = 2,
    exportSchema = true,
    // v2 adds archive_files. Keep every version's schema JSON in app/schemas so upgrades keep user data.
    autoMigrations = [AutoMigration(from = 1, to = 2)],
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
