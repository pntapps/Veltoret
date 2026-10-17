package com.pntapps.veltoret.data.library

import com.pntapps.veltoret.data.auth.GoogleAuthManager
import com.pntapps.veltoret.data.db.AccountDao
import com.pntapps.veltoret.data.db.AccountEntity
import com.pntapps.veltoret.data.db.CatalogDao
import com.pntapps.veltoret.data.db.LibraryFolderEntity
import com.pntapps.veltoret.data.db.LibraryType
import com.pntapps.veltoret.data.db.MediaFileDao
import com.pntapps.veltoret.data.drive.DriveRepository
import com.pntapps.veltoret.data.storage.LocalStorage
import kotlinx.coroutines.flow.Flow

class AccountRepository(
    private val accounts: AccountDao,
    private val files: MediaFileDao,
    private val catalog: CatalogDao,
    private val drive: DriveRepository,
    private val local: LocalStorage,
    private val auth: GoogleAuthManager,
) {
    fun observeAccounts(): Flow<List<AccountEntity>> = accounts.observeAccounts()
    fun observeFolders(): Flow<List<LibraryFolderEntity>> = accounts.observeFolders()
    suspend fun accounts(): List<AccountEntity> = accounts.accounts()

    /** Call after Drive access was granted; reads the profile and stores the account. */
    suspend fun addAccount(email: String, accessToken: String?): AccountEntity {
        if (accessToken != null) auth.remember(email, accessToken)
        val about = drive.about(email)
        val entity = AccountEntity(
            email = email,
            displayName = about.user?.displayName ?: email.substringBefore('@'),
            photoUrl = about.user?.photoLink,
            addedAt = System.currentTimeMillis(),
        )
        accounts.upsert(entity)
        return entity
    }

    /** "This device" appears as an account once the user chooses to use local files. */
    suspend fun ensureDeviceAccount() {
        if (accounts.accounts().none { it.email == LocalStorage.ACCOUNT }) {
            accounts.upsert(AccountEntity(LocalStorage.ACCOUNT, LocalStorage.DISPLAY_NAME, null, System.currentTimeMillis()))
        }
    }

    suspend fun removeAccount(email: String) {
        if (LocalStorage.isLocal(email)) accounts.folders().filter { it.accountEmail == email }.forEach { local.release(it.driveFolderId) }
        accounts.deleteFoldersForAccount(email)
        files.deleteForAccount(email)
        files.deleteSubtitlesForAccount(email)
        files.deleteArchivesForAccount(email)
        accounts.delete(email)
        catalog.prune()
        auth.forget(email)
    }

    suspend fun addLibraryFolder(email: String, folderId: String, name: String, type: LibraryType) {
        if (LocalStorage.isLocal(email)) ensureDeviceAccount()
        accounts.insertFolder(LibraryFolderEntity(accountEmail = email, driveFolderId = folderId, name = name, type = type))
    }

    suspend fun removeLibraryFolder(folder: LibraryFolderEntity) {
        files.deleteForFolder(folder.id)
        files.deleteSubtitlesForFolder(folder.id)
        files.deleteArchivesForFolder(folder.id)
        accounts.deleteFolder(folder.id)
        // Give back folder access unless another library folder still lives inside it.
        if (LocalStorage.isLocal(folder.accountEmail) &&
            accounts.folders().none { it.accountEmail == folder.accountEmail && it.driveFolderId == folder.driveFolderId }
        ) {
            local.release(folder.driveFolderId)
        }
        catalog.prune()
    }
}
