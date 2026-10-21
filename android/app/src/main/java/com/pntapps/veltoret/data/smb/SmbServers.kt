package com.pntapps.veltoret.data.smb

import android.content.Context
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import android.util.Base64
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.serialization.Serializable
import kotlinx.serialization.json.Json
import java.security.KeyStore
import javax.crypto.Cipher
import javax.crypto.KeyGenerator
import javax.crypto.SecretKey
import javax.crypto.spec.GCMParameterSpec

/**
 * A network share server (SMB: Windows file sharing, Samba on routers and NAS boxes).
 * Its account id is [account] ("smb://host"); files are "smb://host/share/folder/file" (see [SmbPath]).
 */
@Serializable
data class SmbServer(
    val host: String,
    val port: Int = 445,
    /** Empty for guest access. */
    val username: String = "",
    val domain: String = "",
    /** What the user sees; the host unless the server told us its name. */
    val name: String = host,
) {
    val account: String get() = SmbPath.account(host)
    val guest: Boolean get() = username.isEmpty()
}

/**
 * Saved servers and their passwords. Passwords are encrypted with a key that never leaves the Android
 * Keystore; the file is excluded from backups (a restored copy couldn't be decrypted anyway).
 */
class SmbServerStore(context: Context, private val json: Json) {
    private val prefs = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
    private val _servers = MutableStateFlow(load())
    val servers: StateFlow<List<SmbServer>> = _servers.asStateFlow()

    fun server(account: String): SmbServer? = _servers.value.firstOrNull { it.account == account }

    fun save(server: SmbServer, password: String) {
        prefs.edit()
            .putString(KEY_SERVER + server.account, json.encodeToString(SmbServer.serializer(), server))
            .putString(KEY_PASSWORD + server.account, if (password.isEmpty()) "" else encrypt(password))
            .apply()
        _servers.value = load()
    }

    fun remove(account: String) {
        prefs.edit().remove(KEY_SERVER + account).remove(KEY_PASSWORD + account).apply()
        _servers.value = load()
    }

    /** Null when it can't be decrypted (e.g. the app data was restored onto another phone): sign in again. */
    fun password(account: String): String? {
        val stored = prefs.getString(KEY_PASSWORD + account, null) ?: return null
        if (stored.isEmpty()) return ""
        return runCatching { decrypt(stored) }.getOrNull()
    }

    private fun load(): List<SmbServer> = prefs.all.entries
        .filter { it.key.startsWith(KEY_SERVER) }
        .mapNotNull { runCatching { json.decodeFromString(SmbServer.serializer(), it.value as String) }.getOrNull() }
        .sortedBy { it.name.lowercase() }

    private fun key(): SecretKey {
        val store = KeyStore.getInstance(KEYSTORE).apply { load(null) }
        (store.getKey(KEY_ALIAS, null) as? SecretKey)?.let { return it }
        return KeyGenerator.getInstance(KeyProperties.KEY_ALGORITHM_AES, KEYSTORE).apply {
            init(
                KeyGenParameterSpec.Builder(KEY_ALIAS, KeyProperties.PURPOSE_ENCRYPT or KeyProperties.PURPOSE_DECRYPT)
                    .setBlockModes(KeyProperties.BLOCK_MODE_GCM)
                    .setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE)
                    .build()
            )
        }.generateKey()
    }

    private fun encrypt(plain: String): String {
        val cipher = Cipher.getInstance(TRANSFORMATION).apply { init(Cipher.ENCRYPT_MODE, key()) }
        val sealed = cipher.iv + cipher.doFinal(plain.toByteArray(Charsets.UTF_8))
        return Base64.encodeToString(sealed, Base64.NO_WRAP)
    }

    private fun decrypt(stored: String): String {
        val sealed = Base64.decode(stored, Base64.NO_WRAP)
        val cipher = Cipher.getInstance(TRANSFORMATION).apply {
            init(Cipher.DECRYPT_MODE, key(), GCMParameterSpec(128, sealed, 0, IV_BYTES))
        }
        return String(cipher.doFinal(sealed, IV_BYTES, sealed.size - IV_BYTES), Charsets.UTF_8)
    }

    companion object {
        /** Also named in res/xml/backup_rules.xml and data_extraction_rules.xml. */
        const val PREFS = "smb_servers"
        private const val KEY_SERVER = "server:"
        private const val KEY_PASSWORD = "password:"
        private const val KEYSTORE = "AndroidKeyStore"
        private const val KEY_ALIAS = "veltoret-smb"
        private const val TRANSFORMATION = "AES/GCM/NoPadding"
        private const val IV_BYTES = 12
    }
}
