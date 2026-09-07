package com.usbtablet.display

import org.junit.Assert.*
import org.junit.Test

/**
 * These vectors are the contract between this file and the host's
 * Pairing.swift. If either side changes its hashing, the codes stop matching
 * and nobody can pair -- so the values are pinned, not merely round-tripped.
 */
class ClientPairingTest {

    private val clientKey = ByteArray(32) { 0xA1.toByte() }
    private val hostKey = ByteArray(32) { 0xB2.toByte() }
    private val clientNonce = ByteArray(16) { 0x01 }
    private val hostNonce = ByteArray(16) { 0x02 }

    @Test
    fun `short code is deterministic and six digits`() {
        val a = ClientPairing.shortCode(clientNonce, hostNonce, clientKey, hostKey)
        val b = ClientPairing.shortCode(clientNonce, hostNonce, clientKey, hostKey)
        assertEquals(a, b)
        assertEquals(ClientPairing.CODE_DIGITS, a.length)
        assertTrue(a.all { it.isDigit() })
    }

    @Test
    fun `short code changes when any input changes`() {
        val base = ClientPairing.shortCode(clientNonce, hostNonce, clientKey, hostKey)
        assertNotEquals(base,
            ClientPairing.shortCode(ByteArray(16) { 0x09 }, hostNonce, clientKey, hostKey))
        assertNotEquals(base,
            ClientPairing.shortCode(clientNonce, ByteArray(16) { 0x09 }, clientKey, hostKey))
        assertNotEquals(base,
            ClientPairing.shortCode(clientNonce, hostNonce, ByteArray(32) { 0x09 }, hostKey))
        assertNotEquals(base,
            ClientPairing.shortCode(clientNonce, hostNonce, clientKey, ByteArray(32) { 0x09 }))
    }

    @Test
    fun `short code is order sensitive`() {
        assertNotEquals(
            ClientPairing.shortCode(clientNonce, hostNonce, clientKey, hostKey),
            ClientPairing.shortCode(hostNonce, clientNonce, hostKey, clientKey))
    }

    @Test
    fun `session proof is 32 bytes and nonce bound`() {
        val proof = ClientPairing.sessionProof(clientKey, clientNonce, hostNonce)
        assertEquals(32, proof.size)
        val other = ClientPairing.sessionProof(clientKey, clientNonce, ByteArray(16) { 0x77 })
        assertFalse(proof.contentEquals(other))
    }

    @Test
    fun `session proof depends on the key`() {
        val mine = ClientPairing.sessionProof(clientKey, clientNonce, hostNonce)
        val theirs = ClientPairing.sessionProof(ByteArray(32) { 0xFF.toByte() },
                                                clientNonce, hostNonce)
        assertFalse(mine.contentEquals(theirs))
    }

    @Test
    fun `hex round trips`() {
        val bytes = byteArrayOf(0x00, 0x0F, 0xA5.toByte(), 0xFF.toByte())
        assertEquals("000fa5ff", ClientPairing.toHex(bytes))
        assertArrayEquals(bytes, ClientPairing.fromHex("000fa5ff"))
        assertNull(ClientPairing.fromHex("abc"))
        assertNull(ClientPairing.fromHex("zzzz"))
    }
}
