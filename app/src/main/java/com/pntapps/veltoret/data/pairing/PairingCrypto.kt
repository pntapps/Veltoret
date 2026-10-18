package com.pntapps.veltoret.data.pairing

import java.security.KeyFactory
import java.security.KeyPair
import java.security.KeyPairGenerator
import java.security.PublicKey
import java.security.SecureRandom
import java.security.spec.ECGenParameterSpec
import java.security.spec.X509EncodedKeySpec
import java.util.Base64
import javax.crypto.Cipher
import javax.crypto.KeyAgreement
import javax.crypto.Mac
import javax.crypto.SecretKeyFactory
import javax.crypto.spec.GCMParameterSpec
import javax.crypto.spec.PBEKeySpec
import javax.crypto.spec.SecretKeySpec

/**
 * Encryption for "Send to TV" (a phone hands a saved network server, password included, to a TV).
 *
 * Each pairing makes fresh P-256 keys on both sides; their ECDH secret keeps the message private from
 * anyone listening on the network. The 6-digit code shown on the TV is mixed into the key, so a device
 * that impersonates the TV can't read it without the code either; the TV makes a new code after every
 * wrong attempt, so guessing it online is hopeless. (Someone actively intercepting the home network
 * during those seconds could still try codes offline; the code stretching slows that down. It's far
 * safer than typing the password into a web page, which is option one.)
 */
object PairingCrypto {
    private const val CURVE = "secp256r1"
    private const val CODE_ITERATIONS = 120_000
    private const val INFO = "veltoret-send-to-tv-v1"
    private val random = SecureRandom()

    fun newKeyPair(): KeyPair = KeyPairGenerator.getInstance("EC").apply { initialize(ECGenParameterSpec(CURVE), random) }.generateKeyPair()

    fun newCode(): String = (random.nextInt(900_000) + 100_000).toString()

    fun newSalt(): ByteArray = ByteArray(16).also { random.nextBytes(it) }

    /** A long random token for the QR code's web page (option one). */
    fun newToken(): String = b64(ByteArray(18).also { random.nextBytes(it) }).replace('+', '-').replace('/', '_')

    fun encodeKey(key: PublicKey): String = b64(key.encoded)

    fun decodeKey(text: String): PublicKey = KeyFactory.getInstance("EC").generatePublic(X509EncodedKeySpec(unb64(text)))

    /** The AES key both sides arrive at from their own private key, the other's public key, the code and the salt. */
    fun sessionKey(own: KeyPair, other: PublicKey, code: String, salt: ByteArray): ByteArray {
        val shared = KeyAgreement.getInstance("ECDH").run {
            init(own.private)
            doPhase(other, true)
            generateSecret()
        }
        val stretchedCode = SecretKeyFactory.getInstance("PBKDF2WithHmacSHA256")
            .generateSecret(PBEKeySpec(code.toCharArray(), salt, CODE_ITERATIONS, 256)).encoded
        return Mac.getInstance("HmacSHA256").run {
            init(SecretKeySpec(stretchedCode, "HmacSHA256"))
            update(shared)
            doFinal(INFO.toByteArray())
        }
    }

    class Sealed(val iv: String, val data: String)

    /** [aad] binds the message to the sender's public key (it's checked, not hidden). */
    fun seal(key: ByteArray, plain: ByteArray, aad: ByteArray): Sealed {
        val iv = ByteArray(12).also { random.nextBytes(it) }
        val cipher = Cipher.getInstance("AES/GCM/NoPadding").apply {
            init(Cipher.ENCRYPT_MODE, SecretKeySpec(key, "AES"), GCMParameterSpec(128, iv))
            updateAAD(aad)
        }
        return Sealed(b64(iv), b64(cipher.doFinal(plain)))
    }

    /** Null when the key is wrong (a wrong code) or the message was changed. */
    fun open(key: ByteArray, sealed: Sealed, aad: ByteArray): ByteArray? = runCatching {
        Cipher.getInstance("AES/GCM/NoPadding").run {
            init(Cipher.DECRYPT_MODE, SecretKeySpec(key, "AES"), GCMParameterSpec(128, unb64(sealed.iv)))
            updateAAD(aad)
            doFinal(unb64(sealed.data))
        }
    }.getOrNull()

    fun b64(bytes: ByteArray): String = Base64.getEncoder().encodeToString(bytes)
    fun unb64(text: String): ByteArray = Base64.getDecoder().decode(text)
}
