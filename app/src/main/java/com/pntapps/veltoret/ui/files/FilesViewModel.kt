package com.pntapps.veltoret.ui.files

import android.content.Intent
import android.net.Uri
import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import androidx.work.WorkInfo
import androidx.work.WorkManager
import com.pntapps.veltoret.AppContainer
import com.pntapps.veltoret.data.db.AccountEntity
import com.pntapps.veltoret.data.db.LibraryType
import com.pntapps.veltoret.data.drive.DriveFile
import com.pntapps.veltoret.data.drive.DriveRepository
import com.pntapps.veltoret.data.drive.ExtractWorker
import com.pntapps.veltoret.data.drive.ZipAfterExtract
import com.pntapps.veltoret.data.drive.UploadWorker
import com.pntapps.veltoret.data.library.FilenameParser
import com.pntapps.veltoret.data.library.SyncWorker
import kotlinx.coroutines.Job
import kotlinx.coroutines.flow.MutableSharedFlow
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.SharedFlow
import kotlinx.coroutines.flow.SharingStarted
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.map
import kotlinx.coroutines.flow.stateIn
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.launch

enum class FileSort(val label: String) { Name("Name"), Modified("Last modified"), Size("Size") }

data class UploadUi(val id: String, val name: String, val progress: Float, val state: WorkInfo.State)

data class FilesState(
    val account: String? = null,
    val sharedRoot: Boolean = false,
    val stack: List<Crumb> = listOf(Crumb(DriveRepository.ROOT, "My Drive")),
    val items: List<DriveFile> = emptyList(),
    val loading: Boolean = true,
    val refreshing: Boolean = false,
    val error: String? = null,
    val sort: FileSort = FileSort.Name,
    val selection: Set<String> = emptySet(),
    val searchQuery: String? = null,
) {
    val current: Crumb get() = stack.last()
    val atSharedRoot: Boolean get() = sharedRoot && stack.size == 1
    val selecting: Boolean get() = selection.isNotEmpty()
}

class FilesViewModel(private val container: AppContainer) : ViewModel() {
    private val drive = container.driveRepository
    private val storage = container.storage
    private val _state = MutableStateFlow(FilesState())
    val state: StateFlow<FilesState> = _state.asStateFlow()

    private val _messages = MutableSharedFlow<String>(extraBufferCapacity = 4)
    val messages: SharedFlow<String> = _messages

    val accounts: StateFlow<List<AccountEntity>> = container.accountRepository.observeAccounts()
        .stateIn(viewModelScope, SharingStarted.Eagerly, emptyList())

    /** Drive folder id → library type, for "Movies library" / "TV library" badges. */
    val libraryFolders: StateFlow<Map<String, LibraryType>> = container.accountRepository.observeFolders()
        .map { list -> list.associate { it.driveFolderId to it.type } }
        .stateIn(viewModelScope, SharingStarted.Eagerly, emptyMap())

    val uploads: StateFlow<List<UploadUi>> = WorkManager.getInstance(container.appContext)
        .getWorkInfosByTagFlow(UploadWorker.TAG)
        .map { infos ->
            infos.filter { !it.state.isFinished || it.state == WorkInfo.State.FAILED }
                .map {
                    UploadUi(
                        it.id.toString(),
                        it.progress.getString(UploadWorker.KEY_NAME) ?: it.outputData.getString(UploadWorker.KEY_NAME) ?: "File",
                        it.progress.getFloat(UploadWorker.KEY_PROGRESS, 0f),
                        it.state,
                    )
                }
        }
        .stateIn(viewModelScope, SharingStarted.WhileSubscribed(5_000), emptyList())

    val extractions: StateFlow<List<ExtractUi>> = extractions(container.appContext)
        .stateIn(viewModelScope, SharingStarted.WhileSubscribed(5_000), emptyList())

    private var loadJob: Job? = null
    private val seenFinishedUploads = mutableSetOf<String>()

    init {
        viewModelScope.launch {
            accounts.collect { list ->
                val current = _state.value.account
                if (current == null || list.none { it.email == current }) {
                    list.firstOrNull()?.let { selectAccount(it.email) } ?: _state.update { it.copy(account = null, loading = false, items = emptyList()) }
                }
            }
        }
        // Refresh the open folder whenever an upload into it completes.
        viewModelScope.launch {
            WorkManager.getInstance(container.appContext).getWorkInfosByTagFlow(UploadWorker.TAG).collect { infos ->
                val done = infos.filter { it.state == WorkInfo.State.SUCCEEDED && seenFinishedUploads.add(it.id.toString()) }
                if (done.any { it.outputData.getString(UploadWorker.KEY_PARENT) == _state.value.current.id }) load(refresh = true)
            }
        }
        // ...and when an extraction finishes, so the new folder appears.
        viewModelScope.launch {
            WorkManager.getInstance(container.appContext).getWorkInfosByTagFlow(ExtractWorker.TAG).collect { infos ->
                if (infos.any { it.state == WorkInfo.State.SUCCEEDED && seenFinishedUploads.add(it.id.toString()) }) load(refresh = true)
            }
        }
    }

    fun selectAccount(email: String) {
        _state.update { FilesState(account = email, sort = it.sort, stack = listOf(Crumb(storage.rootId(email), storage.rootName(email)))) }
        load()
    }

    fun setSharedRoot(shared: Boolean) {
        val root = if (shared) Crumb("shared", "Shared with me") else Crumb(DriveRepository.ROOT, "My Drive")
        _state.update { it.copy(sharedRoot = shared, stack = listOf(root), selection = emptySet(), searchQuery = null) }
        load()
    }

    fun open(folder: DriveFile) {
        _state.update { it.copy(stack = it.stack + Crumb(folder.id, folder.name), selection = emptySet(), searchQuery = null) }
        load()
    }

    fun goTo(index: Int) {
        _state.update { it.copy(stack = it.stack.take(index + 1), selection = emptySet(), searchQuery = null) }
        load()
    }

    /** Returns true if the back press was consumed. */
    fun back(): Boolean {
        val s = _state.value
        return when {
            s.selecting -> { clearSelection(); true }
            s.searchQuery != null -> { setSearch(null); true }
            s.stack.size > 1 -> { goTo(s.stack.size - 2); true }
            else -> false
        }
    }

    fun setSort(sort: FileSort) = _state.update { it.copy(sort = sort, items = sorted(it.items, sort)) }

    fun setSearch(query: String?) {
        _state.update { it.copy(searchQuery = query) }
        if (query == null) load() else if (query.length >= 2) load()
    }

    fun toggleSelection(id: String) = _state.update {
        it.copy(selection = if (id in it.selection) it.selection - id else it.selection + id)
    }

    fun clearSelection() = _state.update { it.copy(selection = emptySet()) }

    fun load(refresh: Boolean = false) {
        val s = _state.value
        val email = s.account ?: return
        loadJob?.cancel()
        _state.update { it.copy(loading = !refresh, refreshing = refresh, error = null) }
        loadJob = viewModelScope.launch {
            try {
                val items = when {
                    s.searchQuery != null && s.searchQuery.length >= 2 -> storage.search(email, s.searchQuery, s.current.id)
                    s.atSharedRoot -> drive.listSharedWithMe(email)
                    else -> storage.list(email, s.current.id)
                }
                // Only what Veltoret can use: folders, videos, subtitles (loaded in the player) and ZIPs (extracted).
                val useful = items.filter {
                    it.isFolder || FilenameParser.isVideo(it.name, it.mimeType) || it.mimeType.startsWith("video/") ||
                        FilenameParser.isSubtitle(it.name) || FilenameParser.isArchive(it.name)
                }
                _state.update { it.copy(items = sorted(useful, it.sort), loading = false, refreshing = false) }
            } catch (e: Exception) {
                _state.update { it.copy(loading = false, refreshing = false, error = e.message ?: "Couldn't load this folder") }
            }
        }
    }

    private fun sorted(items: List<DriveFile>, sort: FileSort): List<DriveFile> {
        val folders = items.filter { it.isFolder }
        val files = items.filterNot { it.isFolder }
        fun List<DriveFile>.apply() = when (sort) {
            FileSort.Name -> sortedWith(compareBy(String.CASE_INSENSITIVE_ORDER) { it.name })
            FileSort.Modified -> sortedByDescending { it.modifiedTime }
            FileSort.Size -> sortedByDescending { it.sizeBytes }
        }
        return folders.apply() + files.apply()
    }

    private fun mutate(success: String, block: suspend (String) -> Unit) {
        val email = _state.value.account ?: return
        viewModelScope.launch {
            try {
                block(email)
                _messages.tryEmit(success)
                load(refresh = true)
            } catch (e: Exception) {
                _messages.tryEmit(e.message ?: "Something went wrong")
            }
        }
    }

    fun rename(file: DriveFile, newName: String) = mutate("Renamed") { email ->
        val newId = storage.rename(email, file.id, newName.trim())
        if (newId == file.id) {
            container.scanner.onFileRenamed(file.id, newName.trim())
            if (file.isFolder) SyncWorker.runNow(container.appContext)
        } else {
            // Device files get a new id when renamed: forget the old one and rescan.
            container.scanner.onFilesRemoved(listOf(file.id))
            SyncWorker.runNow(container.appContext)
        }
    }

    fun trash(ids: Collection<String>) = mutate(removedMessage(ids.size)) { email ->
        ids.forEach { storage.remove(email, it) }
        container.scanner.onFilesRemoved(ids.toList())
        clearSelection()
        if (_state.value.items.any { it.id in ids && it.isFolder }) SyncWorker.runNow(container.appContext)
    }

    fun move(ids: Collection<String>, target: Crumb) = mutate("Moved to ${target.name}") { email ->
        val parentsById = _state.value.items.associate { it.id to it.parents.firstOrNull() }
        ids.forEach { storage.move(email, it, parentsById[it] ?: _state.value.current.id, target.id) }
        // Device and network-share ids change when files move: forget the old ones (the rescan adds them back).
        if (storage.isLocal(email) || storage.isSmb(email)) container.scanner.onFilesRemoved(ids.toList())
        clearSelection()
        SyncWorker.runNow(container.appContext)
    }

    fun createFolder(name: String) = mutate("Folder created") { email ->
        storage.createFolder(email, _state.value.current.id, name.trim())
    }

    private fun removedMessage(count: Int): String {
        val what = if (count == 1) "1 item" else "$count items"
        return if (storage.isLocal(_state.value.account) || storage.isSmb(_state.value.account)) "Deleted $what" else if (count == 1) "Moved to trash" else "$what moved to trash"
    }

    /** Switches the Files tab to "This device", creating it if this is the first local folder. */
    fun useDevice() {
        viewModelScope.launch {
            container.accountRepository.ensureDeviceAccount()
            selectAccount(com.pntapps.veltoret.data.storage.LocalStorage.ACCOUNT)
        }
    }

    /** Takes access to a folder picked with the system folder picker. Returns it for the "add to library" prompt. */
    suspend fun adoptDeviceFolder(treeUri: Uri): DriveFile? = try {
        container.accountRepository.ensureDeviceAccount()
        storage.local.adopt(treeUri).also {
            if (_state.value.account != com.pntapps.veltoret.data.storage.LocalStorage.ACCOUNT) {
                selectAccount(com.pntapps.veltoret.data.storage.LocalStorage.ACCOUNT)
            } else if (_state.value.stack.size == 1) load(refresh = true)
        }
    } catch (e: Exception) {
        _messages.tryEmit(e.message ?: "Couldn't open that folder")
        null
    }

    fun extract(file: DriveFile, wifiOnly: Boolean, after: ZipAfterExtract) {
        val email = _state.value.account ?: return
        val parent = file.parents.firstOrNull() ?: _state.value.current.id
        ExtractWorker.enqueue(container.appContext, email, file.id, file.name, parent, wifiOnly, after)
        _messages.tryEmit("Extracting ${file.name} in the background")
    }

    fun upload(uris: List<Uri>) {
        val s = _state.value
        val email = s.account ?: return
        if (s.atSharedRoot) {
            _messages.tryEmit("Open a folder first to upload into it")
            return
        }
        uris.forEach { uri ->
            runCatching {
                container.appContext.contentResolver.takePersistableUriPermission(uri, Intent.FLAG_GRANT_READ_URI_PERMISSION)
            }
            UploadWorker.enqueue(container.appContext, email, s.current.id, uri)
        }
        _messages.tryEmit("Uploading ${uris.size} file${if (uris.size == 1) "" else "s"}")
    }

    fun setLibrary(folder: DriveFile, type: LibraryType) {
        val email = _state.value.account ?: return
        viewModelScope.launch {
            container.accountRepository.addLibraryFolder(email, folder.id, folder.name, type)
            SyncWorker.runNow(container.appContext)
            _messages.tryEmit("${folder.name} added to your ${if (type == LibraryType.MOVIES) "Movies" else "TV Shows"} library")
        }
    }
}
