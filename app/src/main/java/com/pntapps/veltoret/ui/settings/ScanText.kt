package com.pntapps.veltoret.ui.settings

import com.pntapps.veltoret.data.db.LibraryFolderEntity
import com.pntapps.veltoret.data.library.ScanState
import com.pntapps.veltoret.ui.util.Format

/** Scan wording shared by the phone/tablet and TV settings screens. */
object ScanText {

    fun videos(n: Int) = "$n video${if (n == 1) "" else "s"}"

    fun title(s: ScanState) = when {
        s.folderIds == null -> "Scanning your library"
        s.currentFolder.isNotEmpty() -> "Scanning ${s.currentFolder}"
        else -> "Scanning folder"
    }

    /** What the scan is doing right now: "Reading Movies · folder 2 of 4", "Matching with TMDB · 12 of 40". */
    fun step(s: ScanState) = when {
        s.toMatch > 0 -> "Matching with TMDB · ${s.matched} of ${s.toMatch}"
        s.currentFolder.isNotEmpty() && s.foldersTotal > 1 ->
            "Reading ${s.currentFolder} · folder ${minOf(s.foldersDone + 1, s.foldersTotal)} of ${s.foldersTotal}"
        s.currentFolder.isNotEmpty() -> "Reading ${s.currentFolder}"
        else -> s.phase.ifBlank { "Starting" }
    }

    /** "340 videos · 12 new · 10 identified". */
    fun counts(s: ScanState) = buildList {
        add(videos(s.filesFound))
        if (s.newFiles > 0) add("${s.newFiles} new")
        if (s.identified > 0) add("${s.identified} identified")
    }.joinToString(" · ")

    /** The line under "Scan library now" when no scan is running. */
    fun idle(s: ScanState, lastScanAt: Long): String {
        val broken = s.folderErrors.size
        return when {
            broken > 0 -> "$broken folder${if (broken == 1) "" else "s"} couldn't be read. Details are under Sources."
            s.cancelled -> "Last scan was cancelled ${Format.relative(s.lastFinishedAt).lowercase()}"
            s.error != null -> "Last scan had a problem: ${s.error}"
            s.lastFinishedAt > 0 -> {
                val what = when (val n = s.folderIds?.size) {
                    null -> "Last scan"
                    1 -> "Folder scan"
                    else -> "Scan of $n folders"
                }
                "$what ${Format.relative(s.lastFinishedAt).lowercase()}: ${counts(s)}"
            }
            else -> "Last scanned ${Format.relative(lastScanAt).lowercase()}"
        }
    }

    /** The line under a library folder: its video count and last scan, its error, or live progress. */
    fun folder(folder: LibraryFolderEntity, count: Int, s: ScanState): String = when {
        s.running && s.currentFolderId == folder.id ->
            "Scanning… ${s.currentPath.ifEmpty { "top folder" }}"
        s.folderErrors[folder.id] != null -> s.folderErrors.getValue(folder.id)
        s.waiting(folder.id) -> "${videos(count)} · waiting to scan"
        folder.lastScannedAt <= 0 -> "Not scanned yet"
        else -> "${videos(count)} · scanned ${Format.relative(folder.lastScannedAt).lowercase()}"
    }
}
