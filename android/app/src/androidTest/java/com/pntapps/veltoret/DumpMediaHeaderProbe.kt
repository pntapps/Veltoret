package com.pntapps.veltoret

import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import com.pntapps.veltoret.data.drive.DriveAccount
import com.pntapps.veltoret.ui.util.container
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.runBlocking
import okhttp3.Request
import org.junit.Assume.assumeTrue
import org.junit.Test
import org.junit.runner.RunWith
import java.io.File

/**
 * Diagnostic only (run manually with -e name <prefix>): saves the first 4 MB of a library file to
 * the app's external files dir so its container structure can be inspected on a computer.
 */
@RunWith(AndroidJUnit4::class)
class DumpMediaHeaderProbe {
    @Test
    fun dumpHeader(): Unit = runBlocking {
        val prefix = InstrumentationRegistry.getArguments().getString("name")
        assumeTrue("pass -e name <file name prefix>", prefix != null)
        val context = InstrumentationRegistry.getInstrumentation().targetContext
        val app = context.container
        val movies = app.libraryRepository.movies().first()
        val file = movies.flatMap { app.libraryRepository.movieFiles(it.movie.tmdbId).first() }
            .first { it.name.startsWith(prefix!!) }
        val request = Request.Builder()
            .url("https://www.googleapis.com/drive/v3/files/${file.driveId}?alt=media&supportsAllDrives=true")
            .tag(DriveAccount::class.java, DriveAccount(file.accountEmail))
            .header("Range", "bytes=0-4194303")
            .build()
        app.driveHttp.newCall(request).execute().use { response ->
            val out = File(context.getExternalFilesDir(null), "head.bin")
            out.writeBytes(response.body.bytes())
            android.util.Log.i("HeaderProbe", "code=${response.code} type=${response.header("Content-Type")} bytes=${out.length()} name=${file.name}")
        }
    }
}
