package com.pntapps.veltoret

import android.net.Uri
import android.os.Bundle
import android.os.SystemClock
import android.provider.DocumentsContract
import android.system.Os
import android.system.OsConstants
import android.util.Log
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import org.junit.Test
import org.junit.runner.RunWith
import java.io.FileInputStream

/**
 * Manual probe (not part of the normal suite): how expensive is it to jump to the end of a large video
 * opened through a granted SAF folder, the way Media3's ContentDataSource does? Run with
 * `am instrument -w -e class com.pntapps.veltoret.SafSeekProbe ...` after granting a folder that holds
 * a big file. Results go to logcat tag "SafSeekProbe".
 */
@RunWith(AndroidJUnit4::class)
class SafSeekProbe {
    @Test
    fun probe() {
        val context = InstrumentationRegistry.getInstrumentation().targetContext
        val resolver = context.contentResolver
        // Optional `-e name <part of file name>` to pick a file that hasn't been read recently (cold cache).
        val name = InstrumentationRegistry.getArguments().getString("name")
        val big = resolver.persistedUriPermissions.asSequence()
            .filter { DocumentsContract.isTreeUri(it.uri) }
            .flatMap { perm -> walk(context, perm.uri, DocumentsContract.getTreeDocumentId(perm.uri), 0) }
            .filter { name == null || Uri.decode(it.first.toString()).contains(name, ignoreCase = true) }
            .maxByOrNull { it.second } ?: run { Log.w(TAG, "no granted files"); return }
        val (uri, size) = big
        Log.i(TAG, "file=$uri size=$size")

        // Exactly what ContentDataSource does.
        var t = SystemClock.elapsedRealtime()
        val extras = Bundle().apply { putBoolean("android.provider.extra.ACCEPT_ORIGINAL_MEDIA_FORMAT", true) }
        val afd = resolver.openTypedAssetFileDescriptor(uri, "*/*", extras)!!
        val st = Os.fstat(afd.fileDescriptor)
        Log.i(TAG, "open took=${SystemClock.elapsedRealtime() - t}ms isReg=${OsConstants.S_ISREG(st.st_mode)} isFifo=${OsConstants.S_ISFIFO(st.st_mode)} isSock=${OsConstants.S_ISSOCK(st.st_mode)} afdLength=${afd.length}")
        FileInputStream(afd.fileDescriptor).use { input ->
            t = SystemClock.elapsedRealtime()
            val skipped = input.skip(size - 1_000_000)
            Log.i(TAG, "skip to end took=${SystemClock.elapsedRealtime() - t}ms skipped=$skipped")
            t = SystemClock.elapsedRealtime()
            val buf = ByteArray(1 shl 20)
            val n = input.read(buf)
            Log.i(TAG, "read 1MB at end took=${SystemClock.elapsedRealtime() - t}ms n=$n")
        }
        afd.close()

        // The alternative: plain openFileDescriptor + positioned reads.
        t = SystemClock.elapsedRealtime()
        resolver.openFileDescriptor(uri, "r")!!.use { pfd ->
            val st2 = Os.fstat(pfd.fileDescriptor)
            Log.i(TAG, "pfd open took=${SystemClock.elapsedRealtime() - t}ms isReg=${OsConstants.S_ISREG(st2.st_mode)}")
            t = SystemClock.elapsedRealtime()
            val buf = ByteArray(1 shl 20)
            val n = Os.pread(pfd.fileDescriptor, buf, 0, buf.size, size - 2_000_000)
            Log.i(TAG, "pread 1MB near end took=${SystemClock.elapsedRealtime() - t}ms n=$n")
        }
    }

    private fun walk(context: android.content.Context, tree: android.net.Uri, docId: String, depth: Int): Sequence<Pair<android.net.Uri, Long>> = sequence {
        if (depth > 4) return@sequence
        val children = DocumentsContract.buildChildDocumentsUriUsingTree(tree, docId)
        val cols = arrayOf(
            DocumentsContract.Document.COLUMN_DOCUMENT_ID,
            DocumentsContract.Document.COLUMN_MIME_TYPE,
            DocumentsContract.Document.COLUMN_SIZE,
        )
        val rows = context.contentResolver.query(children, cols, null, null, null)?.use { c ->
            buildList { while (c.moveToNext()) add(Triple(c.getString(0), c.getString(1), c.getLong(2))) }
        } ?: emptyList()
        for ((id, mime, size) in rows) {
            if (mime == DocumentsContract.Document.MIME_TYPE_DIR) yieldAll(walk(context, tree, id, depth + 1))
            else yield(DocumentsContract.buildDocumentUriUsingTree(tree, id) to size)
        }
    }

    private companion object { const val TAG = "SafSeekProbe" }
}
