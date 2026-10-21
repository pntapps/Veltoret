package com.pntapps.veltoret

import android.util.Log
import androidx.media3.common.MimeTypes
import androidx.media3.common.util.UnstableApi
import androidx.media3.decoder.ffmpeg.FfmpegLibrary
import androidx.test.ext.junit.runners.AndroidJUnit4
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith

/** Documents which codecs the bundled FFmpeg build can decode on this device (see logcat "FfmpegProbe"). */
@UnstableApi
@RunWith(AndroidJUnit4::class)
class FfmpegSupportProbe {
    @Test
    fun reportSupport() {
        assertTrue("FFmpeg native library failed to load", FfmpegLibrary.isAvailable())
        val mimes = listOf(
            MimeTypes.VIDEO_H264, MimeTypes.VIDEO_H265, MimeTypes.VIDEO_MP4V, MimeTypes.VIDEO_MPEG2, MimeTypes.VIDEO_VC1,
            MimeTypes.VIDEO_VP8, MimeTypes.VIDEO_VP9, MimeTypes.VIDEO_AV1, MimeTypes.VIDEO_H263,
            MimeTypes.AUDIO_AC3, MimeTypes.AUDIO_E_AC3, MimeTypes.AUDIO_DTS, MimeTypes.AUDIO_DTS_HD, MimeTypes.AUDIO_TRUEHD,
            MimeTypes.AUDIO_FLAC, MimeTypes.AUDIO_OPUS, MimeTypes.AUDIO_VORBIS, MimeTypes.AUDIO_ALAC,
        )
        mimes.forEach { Log.i("FfmpegProbe", "$it -> ${FfmpegLibrary.supportsFormat(it)}") }
        Log.i("FfmpegProbe", "version=${FfmpegLibrary.getVersion()}")
    }
}
