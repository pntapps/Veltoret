package com.pntapps.veltoret.ui.accounts

import android.accounts.AccountManager
import android.app.Activity
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.IntentSenderRequest
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.rememberUpdatedState
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.platform.LocalContext
import com.google.android.gms.common.api.ApiException
import com.google.android.gms.common.api.CommonStatusCodes
import com.pntapps.veltoret.data.auth.GoogleAuthManager
import com.pntapps.veltoret.data.db.AccountEntity
import com.pntapps.veltoret.ui.util.container
import kotlinx.coroutines.launch

/** [setupProblem] = the failure looks like this build isn't registered in Google Cloud (see SETUP.md). */
data class ConnectError(val title: String, val message: String, val setupProblem: Boolean = false)

class AccountConnector(
    val connect: () -> Unit,
    val reconnect: (email: String) -> Unit,
    val busy: () -> Boolean,
)

/**
 * Connect flow: system account chooser → Play services Drive consent → profile lookup.
 * Using the chooser first lets people add a second (or third) Google account explicitly.
 */
@Composable
fun rememberAccountConnector(
    onConnected: (AccountEntity) -> Unit,
    onError: (ConnectError) -> Unit,
): AccountConnector {
    val context = LocalContext.current
    val container = context.container
    val scope = rememberCoroutineScope()
    val connected by rememberUpdatedState(onConnected)
    val failed by rememberUpdatedState(onError)
    var pendingEmail by rememberSaveable { mutableStateOf<String?>(null) }
    var working by remember { mutableStateOf(false) }

    fun finish(email: String, token: String?) {
        scope.launch {
            try {
                connected(container.accountRepository.addAccount(email, token))
            } catch (e: Exception) {
                failed(ConnectError("Couldn't open your Drive", e.message ?: "Google Drive didn't respond. Check your connection and try again."))
            } finally {
                working = false
            }
        }
    }

    val consent = rememberLauncherForActivityResult(ActivityResultContracts.StartIntentSenderForResult()) { result ->
        val email = pendingEmail
        if (result.resultCode == Activity.RESULT_OK && email != null) {
            runCatching { container.auth.resultFromIntent(result.data) }
                .onSuccess { finish(email, it.accessToken) }
                .onFailure { working = false; failed(describe(it)) }
        } else {
            working = false
            failed(
                ConnectError(
                    "Google didn't grant access",
                    "If you closed the Google screen, just try again. If Google showed \"Access blocked\" or an " +
                        "error like 400 / 401 / 403, this copy of the app isn't registered with Google Cloud yet.",
                    setupProblem = true,
                )
            )
        }
    }

    fun authorize(email: String) {
        pendingEmail = email
        working = true
        scope.launch {
            try {
                val result = container.auth.authorize(email)
                val pending = result.pendingIntent
                if (result.hasResolution() && pending != null) {
                    consent.launch(IntentSenderRequest.Builder(pending.intentSender).build())
                } else {
                    finish(email, result.accessToken)
                }
            } catch (e: Exception) {
                working = false
                failed(describe(e))
            }
        }
    }

    val chooser = rememberLauncherForActivityResult(ActivityResultContracts.StartActivityForResult()) { result ->
        val email = result.data?.getStringExtra(AccountManager.KEY_ACCOUNT_NAME)
        if (result.resultCode == Activity.RESULT_OK && email != null) authorize(email)
    }

    return remember {
        AccountConnector(
            connect = {
                chooser.launch(
                    AccountManager.newChooseAccountIntent(
                        null, null, arrayOf(GoogleAuthManager.GOOGLE_ACCOUNT_TYPE), null, null, null, null,
                    )
                )
            },
            reconnect = { authorize(it) },
            busy = { working },
        )
    }
}

private fun describe(e: Throwable): ConnectError {
    val status = (e as? ApiException)?.statusCode
    return when (status) {
        CommonStatusCodes.DEVELOPER_ERROR -> ConnectError(
            "Google sign-in isn't set up for this build",
            "Google doesn't recognise this app yet. Register its package name and SHA-1 fingerprint as an Android " +
                "OAuth client in Google Cloud, then try again.",
            setupProblem = true,
        )
        CommonStatusCodes.NETWORK_ERROR -> ConnectError("No connection", "Check your internet connection and try again.")
        CommonStatusCodes.CANCELED -> ConnectError("Sign-in cancelled", "Tap Connect to try again.")
        else -> ConnectError(
            "Couldn't connect",
            (e.message ?: "Google sign-in failed.") + if (status != null) " (code $status)" else "",
            setupProblem = status == null || status == CommonStatusCodes.INTERNAL_ERROR,
        )
    }
}
