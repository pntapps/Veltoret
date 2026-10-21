package com.pntapps.veltoret.data.tvlink

import android.content.Context
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import android.util.Base64
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import java.security.KeyStore
import java.util.UUID
import javax.crypto.Cipher
import javax.crypto.KeyGenerator
import javax.crypto.SecretKey
import javax.crypto.spec.GCMParameterSpec

/** A paired device: a TV (on a phone) or a phone (on a TV). */
data class LinkPeer(val id: String, val name: String)

/**
 * Paired devices and their shared secrets, plus this device's own link id. Secrets are encrypted with a
 * key that never leaves the Android Keystore; the file is excluded from backups (like SMB passwords).
 */
class TvLinkStore(context: Context) {
    private val prefs = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
    private val _peers = MutableStateFlow(load())
    val peers: StateFlow<List<LinkPeer>> = _peers.asStateFlow()

    /** This device's id in the link protocol (random, made once). */
    val deviceId: String = prefs.getString(KEY_DEVICE_ID, null) ?: UUID.randomUUID().toString().also {
        prefs.edit().putString(KEY_DEVICE_ID, it).apply()
    }

    fun save(peer: LinkPeer, secret: String) {
        prefs.edit()
            .putString(KEY_NAME + peer.id, peer.name)
            .putString(KEY_SECRET + peer.id, encrypt(secret))
            .apply()
        _peers.value = load()
    }

    fun remove(id: String) {
        prefs.edit().remove(KEY_NAME + id).remove(KEY_SECRET + id).apply()
        _peers.value = load()
    }

    fun clear() {
        _peers.value.forEach { prefs.edit().remove(KEY_NAME + it.id).remove(KEY_SECRET + it.id).apply() }
        _peers.value = load()
    }

    /** Null when not paired, or when it can't be decrypted (data restored onto another device): pair again. */
    fun secret(id: String): String? = prefs.getString(KEY_SECRET + id, null)?.let { runCatching { decrypt(it) }.getOrNull() }

    private fun load(): List<LinkPeer> = prefs.all.entries
        .filter { it.key.startsWith(KEY_NAME) }
        .map { LinkPeer(it.key.removePrefix(KEY_NAME), it.value as String) }
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
        return Base64.encodeToString(cipher.iv + cipher.doFinal(plain.toByteArray(Charsets.UTF_8)), Base64.NO_WRAP)
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
        const val PREFS = "tv_link"
        private const val KEY_DEVICE_ID = "device_id"
        private const val KEY_NAME = "name:"
        private const val KEY_SECRET = "secret:"
        private const val KEYSTORE = "AndroidKeyStore"
        private const val KEY_ALIAS = "veltoret-link"
        private const val TRANSFORMATION = "AES/GCM/NoPadding"
        private const val IV_BYTES = 12
    }
}
