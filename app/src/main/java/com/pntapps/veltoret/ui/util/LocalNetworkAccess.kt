package com.pntapps.veltoret.ui.util

import android.content.pm.PackageManager
import android.os.Build
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberUpdatedState
import androidx.compose.runtime.setValue
import androidx.compose.ui.platform.LocalContext
import androidx.core.content.ContextCompat

/**
 * Runs an action that talks to the local network, first asking for Android 17's "local network"
 * permission (ACCESS_LOCAL_NETWORK, in Nearby devices) when needed. Earlier versions don't need it.
 * [onDenied] gets a sentence to show when the user says no.
 */
@Composable
fun rememberLocalNetworkAccess(onDenied: (String) -> Unit): (() -> Unit) -> Unit {
    val context = LocalContext.current
    val denied by rememberUpdatedState(onDenied)
    var pending by remember { mutableStateOf<(() -> Unit)?>(null) }
    val launcher = rememberLauncherForActivityResult(ActivityResultContracts.RequestPermission()) { granted ->
        val action = pending
        pending = null
        if (granted) action?.invoke()
        else denied("Veltoret needs the \"Nearby devices\" permission to reach servers on your network. You can allow it in Android's app settings.")
    }
    return remember {
        { action ->
            if (Build.VERSION.SDK_INT < LOCAL_NETWORK_SDK ||
                ContextCompat.checkSelfPermission(context, LOCAL_NETWORK_PERMISSION) == PackageManager.PERMISSION_GRANTED
            ) {
                action()
            } else {
                pending = action
                launcher.launch(LOCAL_NETWORK_PERMISSION)
            }
        }
    }
}

// Android 17 (API 37) enforces local network access for apps targeting it.
private const val LOCAL_NETWORK_SDK = 37
private const val LOCAL_NETWORK_PERMISSION = "android.permission.ACCESS_LOCAL_NETWORK"
