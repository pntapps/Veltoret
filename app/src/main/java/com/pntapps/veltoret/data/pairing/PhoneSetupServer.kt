package com.pntapps.veltoret.data.pairing

import android.content.Context
import android.net.ConnectivityManager
import android.net.NetworkCapabilities
import android.net.nsd.NsdManager
import android.net.nsd.NsdServiceInfo
import android.os.Build
import android.provider.Settings
import com.pntapps.veltoret.data.smb.FoundServer
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.cancel
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withTimeoutOrNull
import kotlinx.serialization.Serializable
import kotlinx.serialization.json.Json
import java.io.BufferedInputStream
import java.io.ByteArrayOutputStream
import java.io.InputStream
import java.net.Inet4Address
import java.net.InetAddress
import java.net.ServerSocket
import java.net.Socket
import java.security.KeyPair

/** What a phone sent: the same fields as the TV's "Add network server" screen. */
@Serializable
data class PhoneSubmission(
    val address: String,
    val guest: Boolean = false,
    val username: String = "",
    val password: String = "",
    /** The server's name on the phone (option two), so the TV shows the same name. */
    val name: String? = null,
)

@Serializable
data class PairOffer(val tvKey: String, val salt: String, val name: String)

@Serializable
data class PairMessage(val phoneKey: String, val iv: String, val data: String)

@Serializable
data class SetupReply(val ok: Boolean, val message: String)

/**
 * "Use your phone" on TV: a tiny web server that runs only while that screen is open.
 * - Option one: the QR code opens `http://<tv>:<port>/s/<token>` in the phone's browser, a form whose
 *   answer comes back here. The random token in the address is what lets a phone in.
 * - Option two: Veltoret on a phone finds this TV (DNS-SD `_veltoret._tcp`), asks for the TV's key
 *   (`GET /pair`) and sends the server encrypted (`POST /pair`, see [PairingCrypto]); the 6-digit
 *   [code] on screen is part of the key and changes after every wrong attempt.
 * [onSubmit] tries the details and returns null on success or a sentence explaining the problem.
 */
class PhoneSetupServer(
    private val context: Context,
    private val json: Json,
    private val foundServers: () -> List<FoundServer>,
    private val onSubmit: suspend (PhoneSubmission) -> String?,
) {
    val token: String = PairingCrypto.newToken()
    private val _code = MutableStateFlow(PairingCrypto.newCode())
    val code: StateFlow<String> = _code.asStateFlow()
    private val _url = MutableStateFlow<String?>(null)
    /** The address the QR code shows; null until listening (or with no Wi-Fi/Ethernet). */
    val url: StateFlow<String?> = _url.asStateFlow()

    private val keys: KeyPair = PairingCrypto.newKeyPair()
    private val salt = PairingCrypto.newSalt()
    private val busy = Mutex()
    private var socket: ServerSocket? = null
    private var scope: CoroutineScope? = null
    private var registration: NsdManager.RegistrationListener? = null
    private val tvName = deviceName(context)

    fun start() {
        val ip = localIpv4(context) ?: return
        val server = ServerSocket(0, 8, InetAddress.getByName("0.0.0.0"))
        socket = server
        _url.value = "http://${ip.hostAddress}:${server.localPort}/s/$token"
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

    // ---------------------------------------------------------------------------------------------

    private class Request(val method: String, val path: String, val body: ByteArray)

    private suspend fun handle(client: Socket) {
        // Only devices on the home network; nothing from outside it can reach a TV anyway.
        val from = client.inetAddress
        if (!(from.isSiteLocalAddress || from.isLinkLocalAddress || from.isLoopbackAddress)) return
        client.soTimeout = 15_000
        val request = runCatching { read(BufferedInputStream(client.getInputStream())) }.getOrNull() ?: return
        val out = client.getOutputStream()
        val (status, type, body) = route(request)
        out.write(
            ("HTTP/1.1 $status\r\nContent-Type: $type\r\nContent-Length: ${body.size}\r\n" +
                "Cache-Control: no-store\r\nConnection: close\r\n\r\n").toByteArray()
        )
        out.write(body)
        out.flush()
    }

    private suspend fun route(r: Request): Triple<String, String, ByteArray> {
        val page = "/s/$token"
        return when {
            r.method == "GET" && r.path == page ->
                ok("text/html; charset=utf-8", PhoneSetupPage.html(tvName, foundServers(), "$page/send"))
            r.method == "POST" && r.path == "$page/send" -> {
                val submission = runCatching { json.decodeFromString(PhoneSubmission.serializer(), String(r.body)) }.getOrNull()
                    ?: return reply(400, SetupReply(false, "Something went wrong. Reload the page and try again."))
                reply(200, attempt(submission))
            }
            r.method == "GET" && r.path == "/pair" ->
                reply(200, PairOffer(PairingCrypto.encodeKey(keys.public), PairingCrypto.b64(salt), tvName))
            r.method == "POST" && r.path == "/pair" -> {
                val message = runCatching { json.decodeFromString(PairMessage.serializer(), String(r.body)) }.getOrNull()
                    ?: return reply(400, SetupReply(false, "The TV didn't understand the request"))
                val plain = runCatching {
                    val phoneKey = PairingCrypto.decodeKey(message.phoneKey)
                    val key = PairingCrypto.sessionKey(keys, phoneKey, _code.value, salt)
                    PairingCrypto.open(key, PairingCrypto.Sealed(message.iv, message.data), phoneKey.encoded)
                }.getOrNull()
                if (plain == null) {
                    // A new code after every miss: guessing it one try at a time can't work.
                    _code.value = PairingCrypto.newCode()
                    return reply(403, SetupReply(false, "That code didn't match. The TV now shows a new code; enter that one."))
                }
                val submission = runCatching { json.decodeFromString(PhoneSubmission.serializer(), String(plain)) }.getOrNull()
                    ?: return reply(400, SetupReply(false, "The TV didn't understand the request"))
                reply(200, attempt(submission))
            }
            else -> Triple("404 Not Found", "text/plain", "Not found".toByteArray())
        }
    }

    /** One phone at a time; waits for the TV's answer so the phone can show it. */
    private suspend fun attempt(submission: PhoneSubmission): SetupReply = busy.withLock {
        // Wrapped so a timeout (null) isn't mistaken for success (a null error).
        val outcome = withTimeoutOrNull(60_000) { Outcome(onSubmit(submission)) }
        when {
            outcome == null -> SetupReply(false, "The TV took too long to answer. Check it's still on this screen and try again.")
            outcome.error == null -> SetupReply(true, "Connected. Choose your folders on the TV.")
            else -> SetupReply(false, outcome.error)
        }
    }

    private class Outcome(val error: String?)

    private fun ok(type: String, text: String) = Triple("200 OK", type, text.toByteArray())

    private fun reply(code: Int, value: Any): Triple<String, String, ByteArray> {
        val text = when (value) {
            is SetupReply -> json.encodeToString(SetupReply.serializer(), value)
            is PairOffer -> json.encodeToString(PairOffer.serializer(), value)
            else -> error("unsupported")
        }
        val status = when (code) { 200 -> "200 OK"; 403 -> "403 Forbidden"; else -> "400 Bad Request" }
        return Triple(status, "application/json; charset=utf-8", text.toByteArray())
    }

    private fun read(input: InputStream): Request? {
        val head = ByteArrayOutputStream()
        // Headers end with an empty line; refuse anything oversized.
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
        val length = lines.firstOrNull { it.startsWith("content-length:", ignoreCase = true) }
            ?.substringAfter(':')?.trim()?.toIntOrNull() ?: 0
        if (length !in 0..MAX_BODY) return null
        val body = ByteArray(length)
        var read = 0
        while (read < length) {
            val n = input.read(body, read, length - read)
            if (n < 0) return null
            read += n
        }
        return Request(method, target.substringBefore('?'), body)
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
            serviceName = tvName
            serviceType = SERVICE_TYPE
            setPort(port)
        }
        runCatching { nsd.registerService(info, NsdManager.PROTOCOL_DNS_SD, listener) }.onSuccess { registration = listener }
    }

    companion object {
        const val SERVICE_TYPE = "_veltoret._tcp."
        private const val MAX_HEAD = 8 * 1024
        private const val MAX_BODY = 16 * 1024

        /** The name people gave the TV in its settings, else its model. */
        fun deviceName(context: Context): String =
            Settings.Global.getString(context.contentResolver, Settings.Global.DEVICE_NAME)?.takeIf { it.isNotBlank() }
                ?: Build.MODEL

        fun localIpv4(context: Context): Inet4Address? {
            val cm = context.getSystemService(ConnectivityManager::class.java) ?: return null
            @Suppress("DEPRECATION")
            val networks = listOfNotNull(cm.activeNetwork) + cm.allNetworks
            for (network in networks.distinct()) {
                val caps = cm.getNetworkCapabilities(network) ?: continue
                if (!caps.hasTransport(NetworkCapabilities.TRANSPORT_WIFI) && !caps.hasTransport(NetworkCapabilities.TRANSPORT_ETHERNET)) continue
                cm.getLinkProperties(network)?.linkAddresses?.map { it.address }?.filterIsInstance<Inet4Address>()?.firstOrNull()?.let { return it }
            }
            return null
        }
    }
}
