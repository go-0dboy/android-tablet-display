package com.usbtablet.display

import android.content.Context
import java.security.MessageDigest
import java.security.SecureRandom
import javax.crypto.Mac
import javax.crypto.spec.SecretKeySpec

/**
 * The client half of wireless pairing. Mirrors Pairing.swift on the host.
 *
 * Over USB none of this runs: the cable, plus the "Allow USB debugging" prompt
 * adb already made the person accept, is the authorisation. Over Wi-Fi that is
 * gone, so both ends derive the same six digits from two nonces and two
 * identity keys, show them, and a person confirms they match. After that the
 * client proves it holds the key and connects with no taps at all.
 */
object ClientPairing {
    private const val PREFS = "usbtablet.pairing"
    private const val KEY_IDENTITY = "identity"
    const val CODE_DIGITS = 6

    /** This install's long-lived identity, generated once and kept. */
    fun identity(context: Context): ByteArray {
        val prefs = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
        prefs.getString(KEY_IDENTITY, null)?.let { hex ->
            fromHex(hex)?.let { if (it.size == 32) return it }
        }
        val key = ByteArray(32).also { SecureRandom().nextBytes(it) }
        prefs.edit().putString(KEY_IDENTITY, toHex(key)).apply()
        return key
    }

    fun nonce(): ByteArray = ByteArray(16).also { SecureRandom().nextBytes(it) }

    /**
     * The digits both screens show. Input order is client-then-host and is
     * fixed, so the two implementations cannot disagree about it.
     */
    fun shortCode(
        clientNonce: ByteArray, hostNonce: ByteArray,
        clientKey: ByteArray, hostKey: ByteArray
    ): String {
        val digest = MessageDigest.getInstance("SHA-256")
        digest.update("usbtabletdisplay-sas-v1".toByteArray(Charsets.UTF_8))
        digest.update(clientNonce)
        digest.update(hostNonce)
        digest.update(clientKey)
        digest.update(hostKey)
        val hash = digest.digest()

        var value = 0L
        for (i in 0 until 4) value = (value shl 8) or (hash[i].toLong() and 0xFF)

        var modulus = 1L
        repeat(CODE_DIGITS) { modulus *= 10 }
        return String.format("%0${CODE_DIGITS}d", value % modulus)
    }

    /** Proof that this client holds the key it paired with. */
    fun sessionProof(
        clientKey: ByteArray, clientNonce: ByteArray, hostNonce: ByteArray
    ): ByteArray {
        val mac = Mac.getInstance("HmacSHA256")
        mac.init(SecretKeySpec(clientKey, "HmacSHA256"))
        mac.update("usbtabletdisplay-session-v1".toByteArray(Charsets.UTF_8))
        mac.update(clientNonce)
        mac.update(hostNonce)
        return mac.doFinal()
    }

    fun toHex(bytes: ByteArray): String =
        bytes.joinToString("") { "%02x".format(it) }

    fun fromHex(hex: String): ByteArray? {
        if (hex.length % 2 != 0) return null
        return try {
            ByteArray(hex.length / 2) {
                hex.substring(it * 2, it * 2 + 2).toInt(16).toByte()
            }
        } catch (_: NumberFormatException) {
            null
        }
    }
}
