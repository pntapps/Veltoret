package com.pntapps.veltoret.data.tvlink

import android.content.Context
import android.net.nsd.NsdManager
import android.net.nsd.NsdServiceInfo
import android.os.Build
import android.provider.Settings
import com.pntapps.veltoret.data.pairing.PairMessage
import com.pntapps.veltoret.data.pairing.PairingCrypto
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
import kotlinx.serialization.KSerializer
import kotlinx.serialization.json.Json
import java.io.ByteArrayOutputStream
import java.io.IOException
import java.net.Inet4Address
import java.net.InetSocketAddress
import java.net.Socket
import kotlin.coroutines.resume

/** A TV running Veltoret's "Play on TV" listener. [paired]: this phone has its secret. */
data class LinkTv(val id: String, val name: String, val host: String, val port: Int, val paired: Boolean)

/** A request the TV refused, with the sentence to show and its reason code ("open_app", "unpaired"…). */
class LinkException(message: String, val code: String? = null) : IOException(message)

/**
 * The phone's half of "Play on TV": finds Veltoret TVs on the Wi-Fi, pairs with the code the TV shows,
 * and sends signed requests. Plain HTTP over a socket, like SendToTv (Android blocks cleartext OkHttp).
 */
class TvLinkClient(private val context: Context, private val json: Json, private val store: TvLinkStore) {

    /** Veltoret TVs as they're found (each answers /hello first); runs until cancelled. */
    fun find(): Flow<LinkTv> = callbackFlow {
        val nsd = context.getSystemService(NsdManager::class.java) ?: run { close(); return@callbackFlow }
        val resolving = Mutex() // older Android resolves one service at a time
        val listener = object : NsdManager.DiscoveryListener {
            override fun onServiceFound(info: NsdServiceInfo) {
                launch(Dispatchers.IO) {
                    val found = resolving.withLock { resolve(nsd, info) } ?: return@launch
                    val hello = runCatching { hello(found.first, found.second) }.getOrNull() ?: return@launch
                    trySend(LinkTv(hello.id, hello.name, found.first, found.second, store.secret(hello.id) != null))
                }
            }
            override fun onServiceLost(info: NsdServiceInfo) = Unit
            override fun onDiscoveryStarted(serviceType: String) = Unit
            override fun onDiscoveryStopped(serviceType: String) = Unit
            override fun onStartDiscoveryFailed(serviceType: String, errorCode: Int) { close() }
            override fun onStopDiscoveryFailed(serviceType: String, errorCode: Int) = Unit
        }
        runCatching { nsd.discoverServices(TvLink.SERVICE_TYPE, NsdManager.PROTOCOL_DNS_SD, listener) }
            .onFailure { close(); return@callbackFlow }
        awaitClose { runCatching { nsd.stopServiceDiscovery(listener) } }
    }

    @Suppress("DEPRECATION")
    private suspend fun resolve(nsd: NsdManager, info: NsdServiceInfo): Pair<String, Int>? = withTimeoutOrNull(4_000) {
        suspendCancellableCoroutine { cont ->
            nsd.resolveService(info, object : NsdManager.ResolveListener {
                override fun onResolveFailed(info: NsdServiceInfo, errorCode: Int) {
                    if (cont.isActive) cont.resume(null)
                }
                override fun onServiceResolved(info: NsdServiceInfo) {
                    val address = if (Build.VERSION.SDK_INT >= 34) info.hostAddresses.firstOrNull { it is Inet4Address } else info.host
                    if (cont.isActive) cont.resume(address?.hostAddress?.let { it to info.port })
                }
            })
        }
    }

    private fun hello(host: String, port: Int): LinkHello {
        val (status, body) = exchange(host, port, "GET", "/hello", null, emptyMap(), 3_000)
        check(status == 200) { "HTTP $status" }
        return json.decodeFromString(LinkHello.serializer(), body)
    }

    // ---- Pairing --------------------------------------------------------------------------------

    /** Asks [tv] to show a pairing code. Throws [LinkException] when it can't (e.g. Veltoret is closed). */
    suspend fun startPairing(tv: LinkTv) = withContext(Dispatchers.IO) {
        val reply = call(tv, "/pair/start", LinkPairStart.serializer(), LinkPairStart(store.deviceId, phoneName()), signed = false, timeout = 8_000)
        if (!reply.ok) throw LinkException(reply.message, reply.code)
    }

    /** Sends the secret sealed with [code]; on success the TV is remembered as paired. */
    suspend fun pair(tv: LinkTv, code: String) = withContext(Dispatchers.IO) {
        val hello = hello(tv.host, tv.port)
        val keys = PairingCrypto.newKeyPair()
        val key = PairingCrypto.sessionKey(keys, PairingCrypto.decodeKey(hello.tvKey), code.trim(), PairingCrypto.unb64(hello.salt))
        val secret = TvLink.newSecret()
        val plain = json.encodeToString(LinkPairSecret.serializer(), LinkPairSecret(store.deviceId, phoneName(), secret)).toByteArray()
        val sealed = PairingCrypto.seal(key, plain, keys.public.encoded)
        val message = PairMessage(PairingCrypto.encodeKey(keys.public), sealed.iv, sealed.data)
        val reply = call(tv, "/pair", PairMessage.serializer(), message, signed = false, timeout = 15_000)
        if (!reply.ok) throw LinkException(reply.message, reply.code)
        store.save(LinkPeer(hello.id, hello.name), secret)
    }

    fun forget(tvId: String) = store.remove(tvId)

    // ---- Playback -------------------------------------------------------------------------------

    /** Plays [request] on [tv]; returns where it plays from ([LinkStatus.SOURCE_TV] or [LinkStatus.SOURCE_PHONE]). */
    suspend fun play(tv: LinkTv, request: LinkPlay): String = withContext(Dispatchers.IO) {
        val reply = call(tv, "/play", LinkPlay.serializer(), request, signed = true, timeout = 15_000)
        if (!reply.ok) throw LinkException(reply.message, reply.code)
        reply.message
    }

    suspend fun command(tv: LinkTv, command: LinkCommand) = withContext(Dispatchers.IO) {
        val reply = call(tv, "/command", LinkCommand.serializer(), command, signed = true, timeout = 8_000)
        if (!reply.ok) throw LinkException(reply.message, reply.code)
    }

    suspend fun status(tv: LinkTv): LinkStatus = withContext(Dispatchers.IO) {
        val body = request(tv, "/status", ByteArray(0), signed = true, timeout = 5_000)
        json.decodeFromString(LinkStatus.serializer(), body)
    }

    private fun <T> call(tv: LinkTv, path: String, serializer: KSerializer<T>, value: T, signed: Boolean, timeout: Int): LinkReply {
        val body = request(tv, path, json.encodeToString(serializer, value).toByteArray(), signed, timeout)
        return json.decodeFromString(LinkReply.serializer(), body)
    }

    /** POSTs [body]; returns the response body, or throws [LinkException] with the TV's message. */
    private fun request(tv: LinkTv, path: String, body: ByteArray, signed: Boolean, timeout: Int): String {
        val headers = if (!signed) emptyMap() else {
            val secret = store.secret(tv.id) ?: throw LinkException("Pair this phone with ${tv.name} first", "unpaired")
            val time = System.currentTimeMillis()
            mapOf(
                TvLink.HEADER_PHONE to store.deviceId,
                TvLink.HEADER_TIME to time.toString(),
                TvLink.HEADER_SIGNATURE to TvLink.sign(secret, "POST", path, time, body),
            )
        }
        val (status, text) = try {
            exchange(tv.host, tv.port, "POST", path, body, headers, timeout)
        } catch (e: IOException) {
            throw LinkException("Couldn't reach ${tv.name}. Check it's on and on the same Wi-Fi.")
        }
        if (status == 200) return text
        val reply = runCatching { json.decodeFromString(LinkReply.serializer(), text) }.getOrNull()
        if (reply?.code == "unpaired") store.remove(tv.id)
        throw LinkException(reply?.message ?: "${tv.name} couldn't do that (HTTP $status)", reply?.code)
    }

    /** One HTTP/1.1 request; the TV closes the connection after answering. Returns the status and body. */
    private fun exchange(host: String, port: Int, method: String, path: String, body: ByteArray?, headers: Map<String, String>, timeout: Int): Pair<Int, String> =
        Socket().use { socket ->
            socket.connect(InetSocketAddress(host, port), 4_000)
            socket.soTimeout = timeout
            val bytes = body ?: ByteArray(0)
            val head = buildString {
                append("$method $path HTTP/1.1\r\nHost: $host:$port\r\nConnection: close\r\n")
                headers.forEach { (k, v) -> append("$k: $v\r\n") }
                if (body != null) append("Content-Type: application/json\r\nContent-Length: ${bytes.size}\r\n")
                append("\r\n")
            }
            socket.getOutputStream().apply { write(head.toByteArray()); write(bytes); flush() }
            val all = ByteArrayOutputStream()
            socket.getInputStream().copyTo(all)
            val text = all.toString(Charsets.UTF_8.name())
            val status = text.substringBefore("\r\n").split(' ').getOrNull(1)?.toIntOrNull() ?: throw IOException("Not HTTP")
            status to text.substringAfter("\r\n\r\n", "")
        }

    /** The name the TV shows while pairing ("Galaxy Tab S8"). */
    private fun phoneName(): String =
        Settings.Global.getString(context.contentResolver, Settings.Global.DEVICE_NAME)?.takeIf { it.isNotBlank() } ?: Build.MODEL
}
