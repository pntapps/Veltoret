package com.pntapps.veltoret.data.net

import android.content.Context
import android.net.ConnectivityManager
import android.net.Network
import android.net.NetworkCapabilities
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow

/**
 * Whether the device can reach the internet right now. Drives "offline mode": when it's false the library
 * shows only titles that can play from this device, and Drive-only actions explain that they need a
 * connection. Uses the system's validated-internet signal, so a Wi-Fi with no internet counts as offline.
 */
class Connectivity(context: Context) {

    private val manager = context.getSystemService(ConnectivityManager::class.java)

    private val _online = MutableStateFlow(currentlyOnline())
    val online: StateFlow<Boolean> = _online.asStateFlow()

    val isOnline: Boolean get() = _online.value

    init {
        manager.registerDefaultNetworkCallback(object : ConnectivityManager.NetworkCallback() {
            override fun onCapabilitiesChanged(network: Network, caps: NetworkCapabilities) {
                _online.value = caps.hasInternet()
            }

            override fun onLost(network: Network) {
                _online.value = currentlyOnline()
            }

            override fun onUnavailable() {
                _online.value = false
            }
        })
    }

    private fun currentlyOnline(): Boolean =
        manager.activeNetwork?.let { manager.getNetworkCapabilities(it) }?.hasInternet() == true

    private fun NetworkCapabilities.hasInternet() =
        hasCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET) &&
            hasCapability(NetworkCapabilities.NET_CAPABILITY_VALIDATED)
}
