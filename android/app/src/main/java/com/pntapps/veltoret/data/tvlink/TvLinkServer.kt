package com.pntapps.veltoret.data.tvlink

import android.content.Context
import android.net.nsd.NsdManager
import android.net.nsd.NsdServiceInfo
import com.pntapps.veltoret.BuildConfig
import com.pntapps.veltoret.data.pairing.PairMessage
import com.pntapps.veltoret.data.pairing.PairingCrypto
import com.pntapps.veltoret.data.pairing.PhoneSetupServer
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.cancel
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import kotlinx.serialization.KSerializer
import kotlinx.serialization.json.Json
import java.io.BufferedInputStream
import java.io.ByteArrayOutputStream
import java.io.InputStream
import java.net.InetAddress
import java.net.ServerSocket
import java.net.Socket
import java.security.KeyPair

/**
 * The TV's "Play on TV" listener (runs in TvLinkService). Plain HTTP on the home network:
 * - `GET /hello`: the TV's id, name and pairing key.
 * - `POST /pair/start`, `POST /pair`: pairing with the code the TV shows (a new code after every miss).
 * - `POST /play`, `/command`, `/status`: signed with the paired secret ([TvLink.sign]); a replayed
 *   request (same signature) is refused.
 */
class TvLinkServer(
    private val context: Context,
    private val json: Json,
    private val store: TvLinkStore,
    private val host: TvLinkHost,
) {
    private val keys: KeyPair = PairingCrypto.newKeyPair()
    private val salt = PairingCrypto.newSalt()
    private val name = PhoneSetupServer.deviceName(context)
    private var socket: ServerSocket? = null
    private var scope: CoroutineScope? = null
    private var registration: NsdManager.RegistrationListener? = null
    /** Signatures seen recently, with their time, so a captured request can't be sent again. */
    private val seen = LinkedHashMap<String, Long>()

    val running: Boolean get() = socket != null

    fun start() {
        if (socket != null) return
        val server = ServerSocket(0, 16, InetAddress.getByName("0.0.0.0"))
        socket = server
        val s = CoroutineScope(Job() + Dispatchers.IO).also { scope = it }
        s.launch {
            while (isActive) {
                val client = runCatching { server.accept() }.getOrNull() ?: break
                launch { client.use { handle(it) } }
            }
        }
        register(server.localPort)
    }

    fun stop() {
        registration?.let { runCatching { context.getSystemService(NsdManager::class.java)?.unregisterService(it) } }
        registration = null
        runCatching { socket?.close() }
        socket = null
        scope?.cancel()
        scope = null
    }

    private class Request(val method: String, val path: String, val headers: Map<String, String>, val body: ByteArray)
    private class Response(val status: String, val body: String)

    private suspend fun handle(client: Socket) {
        val from = client.inetAddress
        if (!(from.isSiteLocalAddress || from.isLinkLocalAddress || from.isLoopbackAddress)) return
        client.soTimeout = 15_000
        val request = runCatching { read(BufferedInputStream(client.getInputStream())) }.getOrNull() ?: return
        val response = runCatching { route(request) }.getOrElse {
            if (BuildConfig.DEBUG) android.util.Log.w("VeltoretLink", "request failed", it)
            reply("500 Internal Server Error", LinkReply.serializer(), LinkReply(false, "The TV couldn't do that"))
        }
        val body = response.body.toByteArray()
        client.getOutputStream().apply {
            write(
                ("HTTP/1.1 ${response.status}\r\nContent-Type: application/json; charset=utf-8\r\n" +
                    "Content-Length: ${body.size}\r\nCache-Control: no-store\r\nConnection: close\r\n\r\n").toByteArray()
            )
            write(body)
            flush()
        }
    }

    private suspend fun route(r: Request): Response = when {
        r.method == "GET" && r.path == "/hello" ->
            ok(LinkHello.serializer(), LinkHello(store.deviceId, name, TvLink.VERSION, PairingCrypto.encodeKey(keys.public), PairingCrypto.b64(salt)))
        r.method == "POST" && r.path == "/pair/start" -> {
            val start = decode(LinkPairStart.serializer(), r.body) ?: return bad()
            if (host.startPairing(start.phoneName)) ok(LinkReply.serializer(), LinkReply(true, "Enter the code shown on the TV"))
            else ok(LinkReply.serializer(), LinkReply(false, "Open Veltoret on the TV to see the code", code = "open_app"))
        }
        r.method == "POST" && r.path == "/pair" -> pair(r)
        r.method == "POST" && r.path in setOf("/play", "/command", "/status") -> {
            if (!authorized(r)) return reply("401 Unauthorized", LinkReply.serializer(), LinkReply(false, "Pair this phone with the TV again", code = "unpaired"))
            when (r.path) {
                "/play" -> ok(LinkReply.serializer(), host.play(decode(LinkPlay.serializer(), r.body) ?: return bad()))
                "/command" -> ok(LinkReply.serializer(), host.command(decode(LinkCommand.serializer(), r.body) ?: return bad()))
                else -> ok(LinkStatus.serializer(), host.status())
            }
        }
        else -> reply("404 Not Found", LinkReply.serializer(), LinkReply(false, "Not found"))
    }

    private fun pair(r: Request): Response {
        val code = host.pairingCode() ?: return reply("409 Conflict", LinkReply.serializer(), LinkReply(false, "Start pairing again"))
        val message = decode(PairMessage.serializer(), r.body) ?: return bad()
        val plain = runCatching {
            val phoneKey = PairingCrypto.decodeKey(message.phoneKey)
            val key = PairingCrypto.sessionKey(keys, phoneKey, code, salt)
            PairingCrypto.open(key, PairingCrypto.Sealed(message.iv, message.data), phoneKey.encoded)
        }.getOrNull()
        if (plain == null) {
            host.newPairingCode()
            return reply("403 Forbidden", LinkReply.serializer(), LinkReply(false, "That code didn't match. The TV now shows a new code; enter that one.", code = "wrong_code"))
        }
        val secret = decode(LinkPairSecret.serializer(), plain) ?: return bad()
        store.save(LinkPeer(secret.phoneId, secret.phoneName), secret.secret)
        host.endPairing()
        return ok(LinkReply.serializer(), LinkReply(true, "Paired"))
    }

    private fun authorized(r: Request): Boolean {
        val phone = r.headers[TvLink.HEADER_PHONE.lowercase()] ?: return false
        val time = r.headers[TvLink.HEADER_TIME.lowercase()]?.toLongOrNull() ?: return false
        val signature = r.headers[TvLink.HEADER_SIGNATURE.lowercase()] ?: return false
        val secret = store.secret(phone) ?: return false
        val now = System.currentTimeMillis()
        if (!TvLink.verify(secret, r.method, r.path, time, r.body, signature, now)) return false
        synchronized(seen) {
            seen.entries.removeAll { now - it.value > TvLink.MAX_SKEW_MS * 2 }
            if (seen.containsKey(signature)) return false
            seen[signature] = now
        }
        return true
    }

    private fun <T> decode(serializer: KSerializer<T>, body: ByteArray): T? =
        runCatching { json.decodeFromString(serializer, String(body)) }.getOrNull()

    private fun <T> ok(serializer: KSerializer<T>, value: T) = reply("200 OK", serializer, value)
    private fun bad() = reply("400 Bad Request", LinkReply.serializer(), LinkReply(false, "The TV didn't understand the request"))
    private fun <T> reply(status: String, serializer: KSerializer<T>, value: T) = Response(status, json.encodeToString(serializer, value))

    private fun read(input: InputStream): Request? {
        val head = ByteArrayOutputStream()
        while (true) {
            val b = input.read()
            if (b < 0) return null
            head.write(b)
            if (head.size() > MAX_HEAD) return null
            val bytes = head.toByteArray()
            val n = bytes.size
            if (n >= 4 && bytes[n - 4] == '\r'.code.toByte() && bytes[n - 3] == '\n'.code.toByte() &&
                bytes[n - 2] == '\r'.code.toByte() && bytes[n - 1] == '\n'.code.toByte()
            ) break
        }
        val lines = String(head.toByteArray(), Charsets.ISO_8859_1).split("\r\n")
        val (method, target) = lines.first().split(' ').let { if (it.size < 2) return null else it[0] to it[1] }
        val headers = lines.drop(1).filter { ':' in it }.associate { it.substringBefore(':').trim().lowercase() to it.substringAfter(':').trim() }
        val length = headers["content-length"]?.toIntOrNull() ?: 0
        if (length !in 0..MAX_BODY) return null
        val body = ByteArray(length)
        var read = 0
        while (read < length) {
            val n = input.read(body, read, length - read)
            if (n < 0) return null
            read += n
        }
        return Request(method, target.substringBefore('?'), headers, body)
    }

    private fun register(port: Int) {
        val nsd = context.getSystemService(NsdManager::class.java) ?: return
        val listener = object : NsdManager.RegistrationListener {
            override fun onServiceRegistered(info: NsdServiceInfo) = Unit
            override fun onRegistrationFailed(info: NsdServiceInfo, errorCode: Int) = Unit
            override fun onServiceUnregistered(info: NsdServiceInfo) = Unit
            override fun onUnregistrationFailed(info: NsdServiceInfo, errorCode: Int) = Unit
        }
        val info = NsdServiceInfo().apply {
            serviceName = name
            serviceType = TvLink.SERVICE_TYPE
            setPort(port)
        }
        runCatching { nsd.registerService(info, NsdManager.PROTOCOL_DNS_SD, listener) }.onSuccess { registration = listener }
    }

    companion object {
        private const val MAX_HEAD = 8 * 1024
        private const val MAX_BODY = 64 * 1024
    }
}
