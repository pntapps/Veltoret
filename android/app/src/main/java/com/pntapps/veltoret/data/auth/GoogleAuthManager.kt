package com.pntapps.veltoret.data.auth

import android.accounts.Account
import android.content.Context
import android.content.Intent
import com.google.android.gms.auth.GoogleAuthUtil
import com.google.android.gms.auth.api.identity.AuthorizationRequest
import com.google.android.gms.auth.api.identity.AuthorizationResult
import com.google.android.gms.auth.api.identity.Identity
import com.google.android.gms.common.api.Scope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.tasks.await
import kotlinx.coroutines.withContext
import java.io.IOException
import java.util.concurrent.ConcurrentHashMap

/** Thrown when an account's Drive access can't be refreshed silently and the user must re-consent. */
class AuthRequiredException(val email: String) : IOException("Google account $email needs to be reconnected")

/**
 * Issues Google Drive access tokens per account using Play services' AuthorizationClient.
 * Tokens are cached in memory and refreshed silently; Play services owns the long-lived grant.
 */
class GoogleAuthManager(private val context: Context) {

    private data class CachedToken(val token: String, val expiresAt: Long)

    private val cache = ConcurrentHashMap<String, CachedToken>()
    private val mutex = Mutex()
    private val client get() = Identity.getAuthorizationClient(context)

    fun request(email: String): AuthorizationRequest = AuthorizationRequest.builder()
        .setRequestedScopes(listOf(Scope(DRIVE_SCOPE)))
        .setAccount(Account(email, GOOGLE_ACCOUNT_TYPE))
        .build()

    suspend fun authorize(email: String): AuthorizationResult = client.authorize(request(email)).await()

    fun resultFromIntent(data: Intent?): AuthorizationResult = client.getAuthorizationResultFromIntent(data)

    fun remember(email: String, token: String) {
        cache[email] = CachedToken(token, System.currentTimeMillis() + TOKEN_TTL_MS)
    }

    suspend fun accessToken(email: String): String {
        cache[email]?.takeIf { it.expiresAt > System.currentTimeMillis() }?.let { return it.token }
        return mutex.withLock {
            cache[email]?.takeIf { it.expiresAt > System.currentTimeMillis() }?.let { return@withLock it.token }
            val result = try {
                authorize(email)
            } catch (e: Exception) {
                throw IOException("Could not authorize $email: ${e.message}", e)
            }
            val token = result.accessToken
            if (result.hasResolution() || token == null) throw AuthRequiredException(email)
            remember(email, token)
            token
        }
    }

    /** Drops a token Google rejected so the next call fetches a fresh one. */
    suspend fun invalidate(email: String) {
        val stale = cache.remove(email) ?: return
        withContext(Dispatchers.IO) {
            runCatching { GoogleAuthUtil.clearToken(context, stale.token) }
        }
    }

    fun forget(email: String) {
        cache.remove(email)
    }

    companion object {
        const val DRIVE_SCOPE = "https://www.googleapis.com/auth/drive"
        const val GOOGLE_ACCOUNT_TYPE = "com.google"
        private const val TOKEN_TTL_MS = 45 * 60 * 1000L
    }
}
