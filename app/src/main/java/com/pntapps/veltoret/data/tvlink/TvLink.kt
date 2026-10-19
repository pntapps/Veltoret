package com.pntapps.veltoret.data.tvlink

import com.pntapps.veltoret.data.pairing.PairingCrypto
import kotlinx.serialization.Serializable
import java.security.MessageDigest
import javax.crypto.Mac
import javax.crypto.spec.SecretKeySpec

/*
 * "Play on TV": Veltoret on a phone sends a title to Veltoret on a TV and becomes its remote.
 *
 * The TV announces itself as [TvLink.SERVICE_TYPE] and answers plain HTTP (see TvLinkServer). A phone
 * pairs once: the TV shows a 6-digit code, and the phone sends a random secret encrypted with it
 * (PairingCrypto, as "Send to TV"). Every later request is signed with that secret ([TvLink.sign]), so
 * nothing else on the Wi-Fi can play things on the TV or read what's playing.
 */

/** GET /hello: who the TV is, and its pairing key. */
@Serializable
data class LinkHello(val id: String, val name: String, val version: Int, val tvKey: String, val salt: String)

/** POST /pair/start: asks the TV to show a pairing code for this phone. */
@Serializable
data class LinkPairStart(val phoneId: String, val phoneName: String)

/** Sealed with the code into POST /pair (as [com.pntapps.veltoret.data.pairing.PairMessage]). */
@Serializable
data class LinkPairSecret(val phoneId: String, val phoneName: String, val secret: String)

@Serializable
data class LinkReply(val ok: Boolean, val message: String = "", val code: String? = null)

/** POST /play: what to play. The TV prefers its own copy and falls back to [streamUrl] on the phone. */
@Serializable
data class LinkPlay(
    val title: String,
    val subtitle: String? = null,
    /** The phone's file id and account: the TV plays the same file when its library has it. */
    val fileId: String,
    val accountEmail: String,
    val fileName: String? = null,
    /** TMDB ids: the TV plays its own copy of the same movie or episode. */
    val movieId: Int? = null,
    val showId: Int? = null,
    val season: Int? = null,
    val episode: Int? = null,
    /** The phone's own stream ("vlink://…"), for when the TV has no copy. */
    val streamUrl: String? = null,
    val startMs: Long = 0,
    val audioLanguage: String? = null,
    /** A language code, [SUBTITLES_OFF], or null to keep the TV's usual choice. */
    val subtitleLanguage: String? = null,
) {
    companion object { const val SUBTITLES_OFF = "off" }
}

/** POST /command. */
@Serializable
data class LinkCommand(val type: String, val positionMs: Long? = null, val track: String? = null) {
    companion object {
        const val PLAY = "play"
        const val PAUSE = "pause"
        const val SEEK = "seek"
        const val STOP = "stop"
        const val AUDIO = "audio"
        /** [track] null turns subtitles off. */
        const val SUBTITLE = "subtitle"
    }
}

/** A track the phone can pick on the TV. */
@Serializable
data class LinkTrack(val id: String, val label: String, val detail: String = "")

/** POST /status: what the TV is playing now. */
@Serializable
data class LinkStatus(
    /** False when Veltoret's player isn't open on the TV. */
    val active: Boolean = false,
    val title: String = "",
    /** "tv" (its own copy or the same file) or "phone" (streaming from the phone). */
    val source: String = "",
    val playing: Boolean = false,
    val buffering: Boolean = false,
    val positionMs: Long = 0,
    val durationMs: Long = 0,
    val ended: Boolean = false,
    val error: String? = null,
    val audio: List<LinkTrack> = emptyList(),
    val audioSelected: String? = null,
    val subtitles: List<LinkTrack> = emptyList(),
    val subtitleSelected: String? = null,
) {
    companion object {
        const val SOURCE_TV = "tv"
        const val SOURCE_PHONE = "phone"
    }
}

object TvLink {
    const val SERVICE_TYPE = "_veltoret-play._tcp."
    const val VERSION = 1
    /** The scheme of the phone's stream; read by LinkDataSource (plain sockets: Android blocks cleartext OkHttp). */
    const val STREAM_SCHEME = "vlink"
    /** The account the TV's player uses for a video streamed from the phone. */
    const val STREAM_ACCOUNT = "link"

    const val HEADER_PHONE = "X-Veltoret-Phone"
    const val HEADER_TIME = "X-Veltoret-Time"
    const val HEADER_SIGNATURE = "X-Veltoret-Signature"
    /** Signed requests older or newer than this are refused (clocks on home devices are close enough). */
    const val MAX_SKEW_MS = 5 * 60_000L

    fun newSecret(): String = PairingCrypto.b64(ByteArray(32).also { java.security.SecureRandom().nextBytes(it) })

    /** HMAC-SHA256 of the request, keyed with the paired secret. */
    fun sign(secret: String, method: String, path: String, time: Long, body: ByteArray): String {
        val mac = Mac.getInstance("HmacSHA256").apply { init(SecretKeySpec(PairingCrypto.unb64(secret), "HmacSHA256")) }
        mac.update("$method $path $time\n".toByteArray())
        mac.update(body)
        return PairingCrypto.b64(mac.doFinal())
    }

    /** Constant-time check of [signature], within [MAX_SKEW_MS] of [now]. */
    fun verify(secret: String, method: String, path: String, time: Long, body: ByteArray, signature: String, now: Long): Boolean {
        if (kotlin.math.abs(now - time) > MAX_SKEW_MS) return false
        val expected = sign(secret, method, path, time, body)
        return MessageDigest.isEqual(expected.toByteArray(), signature.toByteArray())
    }

    /** "vlink://host:port/token/id" for the phone's stream at "http://host:port/token/id". */
    fun streamUrl(httpUrl: String): String = STREAM_SCHEME + httpUrl.removePrefix("http")

    fun isStream(fileId: String): Boolean = fileId.startsWith("$STREAM_SCHEME://")
}
