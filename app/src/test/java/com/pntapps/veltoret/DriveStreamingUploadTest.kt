package com.pntapps.veltoret

import com.pntapps.veltoret.data.drive.DriveApi
import com.pntapps.veltoret.data.drive.DriveRepository
import kotlinx.coroutines.runBlocking
import kotlinx.serialization.json.Json
import okhttp3.Interceptor
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.OkHttpClient
import okhttp3.Protocol
import okhttp3.Response
import okhttp3.ResponseBody.Companion.toResponseBody
import okio.Buffer
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Test
import retrofit2.Retrofit
import retrofit2.converter.kotlinx.serialization.asConverterFactory
import java.io.ByteArrayInputStream
import java.io.ByteArrayOutputStream
import java.io.FilterInputStream
import java.io.InputStream
import java.util.zip.ZipEntry
import java.util.zip.ZipInputStream
import java.util.zip.ZipOutputStream
import kotlin.random.Random

/**
 * Exercises the resumable-upload protocol against a fake Drive, including streams whose length is
 * unknown (videos piped straight out of a ZIP).
 */
class DriveStreamingUploadTest {

    /** Minimal in-memory Drive resumable endpoint that records each chunk's Content-Range. */
    private class FakeDrive : Interceptor {
        val ranges = mutableListOf<String>()
        val received = ByteArrayOutputStream()
        var uploads = 0

        override fun intercept(chain: Interceptor.Chain): Response {
            val request = chain.request()
            fun respond(code: Int, body: String = "", location: String? = null) = Response.Builder()
                .request(request).protocol(Protocol.HTTP_1_1).code(code).message("x")
                .apply { if (location != null) header("Location", location) }
                .body(body.toResponseBody("application/json".toMediaType()))
                .build()

            if (request.method == "POST") return respond(200, location = "https://upload.example/session")
            val range = request.header("Content-Range")!!
            ranges += range
            val buffer = Buffer().also { request.body!!.writeTo(it) }
            received.write(buffer.readByteArray())
            // "bytes a-b/total" or "bytes */total": complete once the total is known and reached.
            val total = range.substringAfter('/')
            return if (total != "*" && received.size().toLong() == total.toLong()) {
                uploads++
                respond(200, """{"id":"f$uploads","name":"x","size":"$total"}""")
            } else {
                respond(308)
            }
        }
    }

    private fun repository(fake: FakeDrive): DriveRepository {
        val json = Json { ignoreUnknownKeys = true }
        val http = OkHttpClient.Builder().addInterceptor(fake).build()
        val api = Retrofit.Builder().baseUrl("https://www.googleapis.com/").client(http)
            .addConverterFactory(json.asConverterFactory("application/json".toMediaType())).build()
            .create(DriveApi::class.java)
        return DriveRepository(api, http, json)
    }

    private val chunk = 8 * 1024 * 1024

    @Test
    fun unknownSizeStreamsInChunksAndDeclaresTotalAtTheEnd() = runBlocking {
        val fake = FakeDrive()
        val data = Random(1).nextBytes(chunk * 2 + 12345)
        val file = repository(fake).upload("a@b.c", "p", "v.mkv", "video/x-matroska", -1, { ByteArrayInputStream(data) }) { _, _ -> }
        assertEquals("f1", file.id)
        assertEquals(listOf("bytes 0-${chunk - 1}/*", "bytes $chunk-${2 * chunk - 1}/*", "bytes ${2 * chunk}-${data.size - 1}/${data.size}"), fake.ranges)
        assertArrayEquals(data, fake.received.toByteArray())
    }

    @Test
    fun unknownSizeExactMultipleFinishesWithEmptyFinalChunk() = runBlocking {
        val fake = FakeDrive()
        val data = Random(2).nextBytes(chunk)
        repository(fake).upload("a@b.c", "p", "v.mkv", "video/x-matroska", -1, { ByteArrayInputStream(data) }) { _, _ -> }
        assertEquals(listOf("bytes 0-${chunk - 1}/*", "bytes */$chunk"), fake.ranges)
    }

    @Test
    fun knownSizeStillWorks() = runBlocking {
        val fake = FakeDrive()
        val data = Random(3).nextBytes(chunk + 10)
        repository(fake).upload("a@b.c", "p", "v.mkv", "video/x-matroska", data.size.toLong(), { ByteArrayInputStream(data) }) { _, _ -> }
        assertEquals(listOf("bytes 0-${chunk - 1}/${data.size}", "bytes $chunk-${data.size - 1}/${data.size}"), fake.ranges)
    }

    /** Same piping the ExtractWorker uses: entries inflate straight into uploads, never touching disk. */
    @Test
    fun zipEntriesStreamStraightIntoUploads() = runBlocking {
        val episodes = listOf("Season 1/S01E01.mkv" to Random(4).nextBytes(chunk + 500), "Season 1/S01E02.mkv" to Random(5).nextBytes(3000))
        val zipBytes = ByteArrayOutputStream().also { out ->
            ZipOutputStream(out).use { zip ->
                episodes.forEach { (name, bytes) -> zip.putNextEntry(ZipEntry(name)); zip.write(bytes); zip.closeEntry() }
            }
        }.toByteArray()

        val uploaded = mutableListOf<ByteArray>()
        ZipInputStream(ByteArrayInputStream(zipBytes)).use { zip ->
            while (true) {
                val entry = zip.nextEntry ?: break
                val fake = FakeDrive()
                repository(fake).upload("a@b.c", "p", entry.name, "video/x-matroska", entry.size, { KeepOpen(zip) }) { _, _ -> }
                uploaded += fake.received.toByteArray()
            }
        }
        assertEquals(episodes.size, uploaded.size)
        episodes.forEachIndexed { i, (_, bytes) -> assertArrayEquals(bytes, uploaded[i]) }
    }

    private class KeepOpen(input: InputStream) : FilterInputStream(input) {
        override fun close() = Unit
    }
}
