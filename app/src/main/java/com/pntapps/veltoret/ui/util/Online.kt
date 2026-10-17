package com.pntapps.veltoret.ui.util

import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.ui.platform.LocalContext
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import com.pntapps.veltoret.data.storage.LocalStorage

/** Whether the device can reach the internet right now (see `Connectivity`). */
@Composable
fun rememberOnline(): Boolean {
    val online by LocalContext.current.container.connectivity.online.collectAsStateWithLifecycle()
    return online
}

/** A file can play now if it's on this device, or if it's on Drive and we're online. */
fun canPlayNow(accountEmail: String?, online: Boolean) = online || LocalStorage.isLocal(accountEmail)
