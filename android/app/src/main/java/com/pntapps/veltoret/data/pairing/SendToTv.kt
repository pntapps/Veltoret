package com.pntapps.veltoret.data.pairing

import android.content.Context
import android.net.nsd.NsdManager
import android.net.nsd.NsdServiceInfo
import android.os.Build
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.channels.awaitClose
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.callbackFlow
import kotlinx.coroutines.launch
import kotlinx.coroutines.suspendCancellableCoroutine
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withContext
import kotlinx.coroutines.withTimeoutOrNull
import kotlinx.serialization.json.Json
import java.io.ByteArrayOutputStream
import java.net.Inet4Address
import java.net.InetSocketAddress
import java.net.Socket
import kotlin.coroutines.resume

/** A TV showing Veltoret's "Use your phone" screen. */
data class FoundTv(val name: String, val host: String, val port: Int)

/**
 * The phone's half of "Send to TV": finds TVs showing "Use your phone" ([PhoneSetupServer] announces
 * them) and sends one saved network server there, encrypted with the code the TV shows.
 *
 * Talks plain HTTP over a socket on purpose: Android refuses cleartext `http://` through OkHttp and
 * HttpURLConnection, and a TV on the home network has no certificate. The content is encrypted anyway.
 */
class SendToTv(private val context: Context, private val json: Json) {

    /**
     * TVs as they're found; runs until cancelled. Each one is checked first: a TV that reopened its
     * "Use your phone" screen can still be announced under its old address ("Mi Box (2)") for a while.
     */
    fun find(): Flow<FoundTv> = callbackFlow {
        val nsd = context.getSystemService(NsdManager::class.java) ?: run { close(); return@callbackFlow }
        val resolving = Mutex() // older Android resolves one service at a time
        val listener = object : NsdManager.DiscoveryListener {
            override fun onServiceFound(info: NsdServiceInfo) {
                launch(Dispatchers.IO) {
                    val tv = resolving.withLock { resolve(nsd, info) } ?: return@launch
                    // Only TVs that answer, under the name the TV gives itself.
                    val offer = runCatching { offer(tv, timeout = 3_000) }.getOrNull() ?: return@launch
                    trySend(tv.copy(name = offer.name))
                }
            }
            override fun onServiceLost(info: NsdServiceInfo) = Unit
            override fun onDiscoveryStarted(serviceType: String) = Unit
            override fun onDiscoveryStopped(serviceType: String) = Unit
            override fun onStartDiscoveryFailed(serviceType: String, errorCode: Int) { close() }
            override fun onStopDiscoveryFailed(serviceType: String, errorCode: Int) = Unit
        }
        runCatching { nsd.discoverServices(PhoneSetupServer.SERVICE_TYPE, NsdManager.PROTOCOL_DNS_SD, listener) }
            .onFailure { close(); return@callbackFlow }
        awaitClose { runCatching { nsd.stopServiceDiscovery(listener) } }
    }

    @Suppress("DEPRECATION")
    private suspend fun resolve(nsd: NsdManager, info: NsdServiceInfo): FoundTv? = withTimeoutOrNull(4_000) {
        suspendCancellableCoroutine { cont ->
            nsd.resolveService(info, object : NsdManager.ResolveListener {
                override fun onResolveFailed(info: NsdServiceInfo, errorCode: Int) {
                    if (cont.isActive) cont.resume(null)
                }
                override fun onServiceResolved(info: NsdServiceInfo) {
                    val address = if (Build.VERSION.SDK_INT >= 34) info.hostAddresses.firstOrNull { it is Inet4Address } else info.host
                    if (cont.isActive) cont.resume(address?.hostAddress?.let { FoundTv(info.serviceName, it, info.port) })
                }
            })
        }
    }

    /** Sends [submission] to [tv]; the TV's answer, or a sentence about what went wrong. */
    suspend fun send(tv: FoundTv, code: String, submission: PhoneSubmission): SetupReply = withContext(Dispatchers.IO) {
        try {
            val offer = runCatching { offer(tv, timeout = 5_000) }.getOrElse {
                return@withContext SetupReply(false, "Couldn't reach the TV. Check it's on the same Wi-Fi and still showing \"Use your phone\".")
            }
            val keys = PairingCrypto.newKeyPair()
            val key = PairingCrypto.sessionKey(keys, PairingCrypto.decodeKey(offer.tvKey), code.trim(), PairingCrypto.unb64(offer.salt))
            val sealed = PairingCrypto.seal(key, json.encodeToString(PhoneSubmission.serializer(), submission).toByteArray(), keys.public.encoded)
            val message = PairMessage(PairingCrypto.encodeKey(keys.public), sealed.iv, sealed.data)
            // The TV answers only after trying the server, which can take a while.
            val (_, reply) = exchange(tv, "POST", "/pair", json.encodeToString(PairMessage.serializer(), message), timeout = 75_000)
            json.decodeFromString(SetupReply.serializer(), reply)
        } catch (e: Exception) {
            if (e is kotlinx.coroutines.CancellationException) throw e
            SetupReply(false, "The TV stopped answering. Check it's still showing \"Use your phone\" and try again.")
        }
    }

    private fun offer(tv: FoundTv, timeout: Int): PairOffer {
        val (status, body) = exchange(tv, "GET", "/pair", null, timeout)
        check(status == 200) { "HTTP $status" }
        return json.decodeFromString(PairOffer.serializer(), body)
    }

    /** One HTTP/1.1 request; the TV closes the connection after answering. Returns the status and body. */
    private fun exchange(tv: FoundTv, method: String, path: String, body: String?, timeout: Int): Pair<Int, String> =
        Socket().use { socket ->
            socket.connect(InetSocketAddress(tv.host, tv.port), 5_000)
            socket.soTimeout = timeout
            val bytes = body?.toByteArray() ?: ByteArray(0)
            val head = buildString {
                append("$method $path HTTP/1.1\r\nHost: ${tv.host}:${tv.port}\r\nConnection: close\r\n")
                if (body != null) append("Content-Type: application/json\r\nContent-Length: ${bytes.size}\r\n")
                append("\r\n")
            }
            socket.getOutputStream().apply { write(head.toByteArray()); write(bytes); flush() }
            val all = ByteArrayOutputStream()
            socket.getInputStream().copyTo(all)
            val text = all.toString(Charsets.UTF_8.name())
            val status = text.substringBefore("\r\n").split(' ').getOrNull(1)?.toIntOrNull() ?: error("Not HTTP")
            status to text.substringAfter("\r\n\r\n", "")
        }
}
