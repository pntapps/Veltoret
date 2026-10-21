package com.pntapps.veltoret

import com.pntapps.veltoret.data.pairing.PairingCrypto
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class PairingCryptoTest {

    private val message = """{"host":"192.168.0.10","username":"me","password":"p@ss w'rd"}""".toByteArray()

    @Test
    fun phoneAndTvAgreeOnTheKeyAndTheMessageArrives() {
        val tv = PairingCrypto.newKeyPair()
        val phone = PairingCrypto.newKeyPair()
        val salt = PairingCrypto.newSalt()
        val code = PairingCrypto.newCode()
        // Keys travel as text, like over the network.
        val tvSeesPhone = PairingCrypto.decodeKey(PairingCrypto.encodeKey(phone.public))
        val phoneSeesTv = PairingCrypto.decodeKey(PairingCrypto.encodeKey(tv.public))

        val phoneKey = PairingCrypto.sessionKey(phone, phoneSeesTv, code, salt)
        val tvKey = PairingCrypto.sessionKey(tv, tvSeesPhone, code, salt)
        assertArrayEquals(phoneKey, tvKey)

        val aad = phone.public.encoded
        val sealed = PairingCrypto.seal(phoneKey, message, aad)
        assertArrayEquals(message, PairingCrypto.open(tvKey, sealed, aad))
    }

    @Test
    fun aWrongCodeCannotOpenIt() {
        val tv = PairingCrypto.newKeyPair()
        val phone = PairingCrypto.newKeyPair()
        val salt = PairingCrypto.newSalt()
        val sealed = PairingCrypto.seal(PairingCrypto.sessionKey(phone, tv.public, "123456", salt), message, phone.public.encoded)
        assertNull(PairingCrypto.open(PairingCrypto.sessionKey(tv, phone.public, "123457", salt), sealed, phone.public.encoded))
    }

    @Test
    fun anotherKeyPairCannotOpenIt() {
        val tv = PairingCrypto.newKeyPair()
        val phone = PairingCrypto.newKeyPair()
        val eavesdropper = PairingCrypto.newKeyPair()
        val salt = PairingCrypto.newSalt()
        val sealed = PairingCrypto.seal(PairingCrypto.sessionKey(phone, tv.public, "123456", salt), message, phone.public.encoded)
        assertNull(PairingCrypto.open(PairingCrypto.sessionKey(eavesdropper, phone.public, "123456", salt), sealed, phone.public.encoded))
    }

    @Test
    fun codesAndTokensLookRight() {
        repeat(50) {
            val code = PairingCrypto.newCode()
            assertEquals(6, code.length)
            assertTrue(code.all(Char::isDigit))
        }
        val token = PairingCrypto.newToken()
        assertEquals(24, token.length)
        assertTrue(token.none { it == '+' || it == '/' })
    }

    @Test
    fun phonePageEscapesServerNames() {
        val html = com.pntapps.veltoret.data.pairing.PhoneSetupPage.html(
            "Living room <TV>",
            listOf(com.pntapps.veltoret.data.smb.FoundServer("192.168.0.10", "NAS\"><script>x</script>")),
            "/s/token/send",
        )
        assertTrue("Living room &lt;TV&gt;" in html)
        assertTrue("<script>x</script>" !in html)
        assertTrue("NAS&quot;&gt;&lt;script&gt;" in html)
    }
}
