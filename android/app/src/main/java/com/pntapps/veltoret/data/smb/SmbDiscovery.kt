package com.pntapps.veltoret.data.smb

import android.content.Context
import android.net.ConnectivityManager
import android.net.NetworkCapabilities
import android.net.nsd.NsdManager
import android.net.nsd.NsdServiceInfo
import android.os.Build
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.channels.awaitClose
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.channelFlow
import kotlinx.coroutines.flow.flowOn
import kotlinx.coroutines.launch
import kotlinx.coroutines.suspendCancellableCoroutine
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.Semaphore
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.sync.withPermit
import kotlinx.coroutines.withTimeoutOrNull
import java.net.DatagramPacket
import java.net.DatagramSocket
import java.net.Inet4Address
import java.net.InetAddress
import java.net.InetSocketAddress
import java.net.Socket
import kotlin.coroutines.resume

/** A file-sharing server found on the local network. [name] is what it calls itself, when it says. */
data class FoundServer(val address: String, val name: String?, val isRouter: Boolean = false)

/**
 * Finds SMB servers on the Wi-Fi/Ethernet network, for people who don't know their server's address.
 * Two ways at once:
 * - servers that announce themselves (DNS-SD "_smb._tcp": NAS boxes, Macs, many Linux machines);
 * - a sweep of the local subnet for anything accepting file-sharing connections (port 445), which
 *   finds routers with a USB drive and Windows PCs that don't announce. Each hit is asked its NetBIOS name.
 * Results stream in as they're found; the flow completes when both are done.
 */
class SmbDiscovery(private val context: Context) {

    fun discover(): Flow<FoundServer> = channelFlow {
        val network = localNetwork() ?: return@channelFlow
        launch { announced().collect { send(it) } }
        launch {
            sweep(network) { send(it) }
        }
    }.flowOn(Dispatchers.IO)

    private data class LocalNetwork(val ownAddress: Int, val prefix: Int, val gateway: String?)

    /** The Wi-Fi or Ethernet network's IPv4 address and gateway; null on mobile data or no network. */
    private fun localNetwork(): LocalNetwork? {
        val cm = context.getSystemService(ConnectivityManager::class.java) ?: return null
        @Suppress("DEPRECATION")
        val candidates = listOfNotNull(cm.activeNetwork) + cm.allNetworks
        for (network in candidates.distinct()) {
            val caps = cm.getNetworkCapabilities(network) ?: continue
            if (!caps.hasTransport(NetworkCapabilities.TRANSPORT_WIFI) && !caps.hasTransport(NetworkCapabilities.TRANSPORT_ETHERNET)) continue
            val props = cm.getLinkProperties(network) ?: continue
            val link = props.linkAddresses.firstOrNull { it.address is Inet4Address } ?: continue
            val gateway = props.routes.firstOrNull { it.isDefaultRoute && it.gateway is Inet4Address }?.gateway?.hostAddress
            return LocalNetwork(toInt(link.address as Inet4Address), link.prefixLength, gateway)
        }
        return null
    }

    private suspend fun sweep(network: LocalNetwork, emit: suspend (FoundServer) -> Unit) = coroutineScope {
        val permits = Semaphore(SWEEP_PARALLELISM)
        for (host in subnetHosts(network.ownAddress, network.prefix)) {
            if (host == network.ownAddress) continue
            launch {
                permits.withPermit {
                    val address = fromInt(host)
                    if (acceptsSmb(address)) emit(FoundServer(address, netBiosName(address), isRouter = address == network.gateway))
                }
            }
        }
    }

    private fun acceptsSmb(address: String): Boolean = runCatching {
        Socket().use { it.connect(InetSocketAddress(address, 445), CONNECT_TIMEOUT_MS) }
        true
    }.getOrDefault(false)

    /** The machine's own name (e.g. "MYNAS") for an address someone typed; null if it doesn't answer. */
    suspend fun nameOf(address: String): String? = kotlinx.coroutines.withContext(Dispatchers.IO) { netBiosName(address) }

    private fun netBiosName(address: String): String? = runCatching {
        DatagramSocket().use { socket ->
            socket.soTimeout = NETBIOS_TIMEOUT_MS
            val query = NetBios.nodeStatusQuery((System.nanoTime() and 0x7FFF).toInt())
            socket.send(DatagramPacket(query, query.size, InetAddress.getByName(address), NetBios.PORT))
            val buffer = ByteArray(1024)
            val reply = DatagramPacket(buffer, buffer.size)
            socket.receive(reply)
            NetBios.parseNodeStatus(buffer, reply.length)
        }
    }.getOrNull()

    /** Servers announcing "_smb._tcp" over multicast DNS, for [ANNOUNCE_WINDOW_MS]. */
    private fun announced(): Flow<FoundServer> = channelFlow {
        val nsd = context.getSystemService(NsdManager::class.java) ?: return@channelFlow
        val resolving = Mutex() // older Android resolves one service at a time
        val listener = object : NsdManager.DiscoveryListener {
            override fun onServiceFound(info: NsdServiceInfo) {
                launch {
                    resolving.withLock { resolve(nsd, info) }?.let { send(it) }
                }
            }
            override fun onServiceLost(info: NsdServiceInfo) = Unit
            override fun onDiscoveryStarted(serviceType: String) = Unit
            override fun onDiscoveryStopped(serviceType: String) = Unit
            override fun onStartDiscoveryFailed(serviceType: String, errorCode: Int) { close() }
            override fun onStopDiscoveryFailed(serviceType: String, errorCode: Int) = Unit
        }
        runCatching { nsd.discoverServices(SERVICE_TYPE, NsdManager.PROTOCOL_DNS_SD, listener) }
            .onFailure { close(); return@channelFlow }
        launch {
            delay(ANNOUNCE_WINDOW_MS)
            close()
        }
        awaitClose { runCatching { nsd.stopServiceDiscovery(listener) } }
    }

    @Suppress("DEPRECATION")
    private suspend fun resolve(nsd: NsdManager, info: NsdServiceInfo): FoundServer? = withTimeoutOrNull(RESOLVE_TIMEOUT_MS) {
        suspendCancellableCoroutine { cont ->
            nsd.resolveService(info, object : NsdManager.ResolveListener {
                override fun onResolveFailed(info: NsdServiceInfo, errorCode: Int) {
                    if (cont.isActive) cont.resume(null)
                }
                override fun onServiceResolved(info: NsdServiceInfo) {
                    val address = if (Build.VERSION.SDK_INT >= 34) info.hostAddresses.firstOrNull { it is Inet4Address }
                    else info.host
                    if (cont.isActive) cont.resume(address?.hostAddress?.let { FoundServer(it, info.serviceName) })
                }
            })
        }
    }

    companion object {
        private const val SERVICE_TYPE = "_smb._tcp."
        private const val SWEEP_PARALLELISM = 64
        private const val CONNECT_TIMEOUT_MS = 400
        private const val NETBIOS_TIMEOUT_MS = 700
        private const val RESOLVE_TIMEOUT_MS = 3_000L
        private const val ANNOUNCE_WINDOW_MS = 5_000L
        /** Never sweep more than a /22 (1022 addresses); bigger networks fall back to the /24 around us. */
        private const val MIN_PREFIX = 22

        /** The other addresses on our subnet (network and broadcast addresses left out). */
        fun subnetHosts(own: Int, prefix: Int): List<Int> {
            val bits = if (prefix in MIN_PREFIX..30) prefix else 24
            val mask = -1 shl (32 - bits)
            val base = own and mask
            val size = 1 shl (32 - bits)
            return (1 until size - 1).map { base + it }
        }

        fun toInt(address: Inet4Address): Int =
            address.address.fold(0) { acc, b -> (acc shl 8) or (b.toInt() and 0xFF) }

        fun fromInt(ip: Int): String = "${ip ushr 24 and 0xFF}.${ip ushr 16 and 0xFF}.${ip ushr 8 and 0xFF}.${ip and 0xFF}"
    }
}
