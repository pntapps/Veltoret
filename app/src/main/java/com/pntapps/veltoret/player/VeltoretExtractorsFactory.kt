package com.pntapps.veltoret.player

import android.net.Uri
import androidx.annotation.OptIn
import androidx.media3.common.util.UnstableApi
import androidx.media3.extractor.DefaultExtractorsFactory
import androidx.media3.extractor.Extractor
import androidx.media3.extractor.ExtractorsFactory
import androidx.media3.extractor.mkv.MatroskaExtractor
import androidx.media3.extractor.mkv.VeltoretMatroskaExtractor
import androidx.media3.extractor.text.DefaultSubtitleParserFactory
import androidx.media3.extractor.text.SubtitleParser

/**
 * Media3's default extractors, except MKV/WebM uses [VeltoretMatroskaExtractor], which also handles
 * files whose track list is stored at the end (common in release-group MKVs).
 */
@OptIn(UnstableApi::class)
class VeltoretExtractorsFactory(private val delegate: DefaultExtractorsFactory) : ExtractorsFactory {

    private var subtitleParserFactory: SubtitleParser.Factory = DefaultSubtitleParserFactory()
    private var textTranscoding = true

    override fun setSubtitleParserFactory(subtitleParserFactory: SubtitleParser.Factory): ExtractorsFactory {
        this.subtitleParserFactory = subtitleParserFactory
        delegate.setSubtitleParserFactory(subtitleParserFactory)
        return this
    }

    @Deprecated("Deprecated in Media3")
    override fun experimentalSetTextTrackTranscodingEnabled(textTrackTranscodingEnabled: Boolean): ExtractorsFactory {
        textTranscoding = textTrackTranscodingEnabled
        @Suppress("DEPRECATION")
        delegate.experimentalSetTextTrackTranscodingEnabled(textTrackTranscodingEnabled)
        return this
    }

    override fun createExtractors(): Array<Extractor> = swap(delegate.createExtractors())

    override fun createExtractors(uri: Uri, responseHeaders: Map<String, List<String>>): Array<Extractor> =
        swap(delegate.createExtractors(uri, responseHeaders))

    private fun swap(extractors: Array<Extractor>): Array<Extractor> = Array(extractors.size) { i ->
        val e = extractors[i]
        if (e is MatroskaExtractor) {
            VeltoretMatroskaExtractor(
                subtitleParserFactory,
                if (textTranscoding) 0 else VeltoretMatroskaExtractor.FLAG_EMIT_RAW_SUBTITLE_DATA,
            )
        } else {
            e
        }
    }
}
