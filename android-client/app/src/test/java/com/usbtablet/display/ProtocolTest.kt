package com.usbtablet.display

import org.junit.Assert.*
import org.junit.Test

/**
 * The client and the host each have their own implementation of the wire
 * format. These tests pin down the byte layout so the two cannot drift apart
 * silently -- the failure mode being a stream that decodes into nonsense
 * rather than an error anyone can see.
 */
class ProtocolTest {

    @Test
    fun `touch message has the exact byte layout the host expects`() {
        val encoded = InputCodec.encode(
            OutgoingMessage.Touch(pointerId = 3, phase = Phase.MOVE, x = 0f, y = 1f))

        // [type][u16 length][pointerId][phase][x f32][y f32]
        assertEquals(3 + 10, encoded.size)
        assertEquals(MessageType.TOUCH, encoded[0].toInt() and 0xFF)
        assertEquals(0, encoded[1].toInt())
        assertEquals(10, encoded[2].toInt())
        assertEquals(3, encoded[3].toInt())
        assertEquals(Phase.MOVE.code, encoded[4].toInt())
        // 0.0f is four zero bytes; 1.0f is 0x3F800000, big-endian.
        assertEquals(0, encoded[5].toInt())
        assertEquals(0x3F.toByte(), encoded[9])
        assertEquals(0x80.toByte(), encoded[10])
    }

    @Test
    fun `pen message carries pressure tilt orientation and buttons`() {
        val encoded = InputCodec.encode(OutgoingMessage.Pen(
            Phase.DOWN, 0.5f, 0.5f, 0.75f, 0.3f, 1.2f, buttons = 0x01))
        // phase + 5 floats + buttons
        assertEquals(3 + 22, encoded.size)
        assertEquals(MessageType.PEN, encoded[0].toInt() and 0xFF)
        assertEquals(22, encoded[2].toInt())
        assertEquals(0x01, encoded[encoded.size - 1].toInt())
    }

    @Test
    fun `hello carries the protocol version first`() {
        val encoded = InputCodec.encode(OutgoingMessage.Hello(
            2560, 1600, 320, 90, ClientFlags.HAS_STYLUS, "Galaxy Tab"))
        assertEquals(MessageType.HELLO, encoded[0].toInt() and 0xFF)
        val version = ((encoded[3].toInt() and 0xFF) shl 8) or (encoded[4].toInt() and 0xFF)
        assertEquals(WireProtocol.VERSION, version)
    }

    @Test
    fun `every message declares a length matching its payload`() {
        val messages = listOf(
            OutgoingMessage.Touch(0, Phase.DOWN, 0.1f, 0.2f),
            OutgoingMessage.Pen(Phase.MOVE, 0f, 0f, 1f, 0f, 0f, 0),
            OutgoingMessage.Scroll(1f, -2f, Phase.MOVE),
            OutgoingMessage.Pinch(0.05f, Phase.DOWN),
            OutgoingMessage.KeepAlive,
            OutgoingMessage.Hello(100, 100, 160, 0, 0, "x"),
            OutgoingMessage.PairRequest(ByteArray(32), ByteArray(16), "phone"),
            OutgoingMessage.PairProof(ByteArray(32))
        )
        for (message in messages) {
            val encoded = InputCodec.encode(message)
            val declared = ((encoded[1].toInt() and 0xFF) shl 8) or (encoded[2].toInt() and 0xFF)
            assertEquals("length header wrong for $message", encoded.size - 3, declared)
        }
    }

    @Test
    fun `parser reassembles a message split across reads`() {
        val ack = byteArrayOf(
            MessageType.HELLO_ACK.toByte(), 0, 14,
            0, 2,                       // version
            1,                          // accepted
            0, 0, 0x0A, 0,              // width 2560
            0, 0, 0x06, 0x40,           // height 1600
            2, 'o'.code.toByte(), 'k'.code.toByte()
        )
        val parser = InputStreamParser()
        // One byte at a time, the worst case a TCP stream can produce.
        var result: IncomingMessage? = null
        for (byte in ack) {
            parser.append(byteArrayOf(byte))
            result = parser.next() ?: result
        }
        assertTrue(result is IncomingMessage.HelloAck)
        val helloAck = result as IncomingMessage.HelloAck
        assertTrue(helloAck.accepted)
        assertEquals(2560, helloAck.displayWidth)
        assertEquals(1600, helloAck.displayHeight)
        assertEquals("ok", helloAck.message)
    }

    @Test
    fun `parser skips an unknown message type without losing sync`() {
        val parser = InputStreamParser()
        parser.append(byteArrayOf(0x7F, 0, 2, 9, 9))            // unknown
        parser.append(byteArrayOf(MessageType.KEEP_ALIVE.toByte(), 0, 0))

        val first = parser.next()
        assertTrue(first is IncomingMessage.Unknown)
        assertEquals(0x7F, (first as IncomingMessage.Unknown).type)
        // The stream is still in sync, which is the point.
        assertTrue(parser.next() is IncomingMessage.KeepAlive)
    }

    @Test
    fun `parser returns null rather than a partial message`() {
        val parser = InputStreamParser()
        parser.append(byteArrayOf(MessageType.HELLO_ACK.toByte(), 0, 14, 0, 2))
        assertNull(parser.next())
        assertEquals(5, parser.pendingByteCount)
    }

    @Test(expected = TruncatedMessageException::class)
    fun `parser rejects an implausible payload length`() {
        val parser = InputStreamParser()
        parser.append(byteArrayOf(MessageType.TOUCH.toByte(), 0xFF.toByte(), 0xFF.toByte()))
        parser.next()
    }

    @Test
    fun `an overlong device name is truncated on a character boundary`() {
        // Four-byte emoji: a naive 255-byte cut would split one in half and
        // produce invalid UTF-8 that the host cannot decode.
        val name = "\uD83C\uDFA8".repeat(100)
        val encoded = InputCodec.encode(OutgoingMessage.Hello(100, 100, 160, 0, 0, name))

        // Hello payload: version(2) + w(4) + h(4) + dpi(2) + rotation(2)
        // + flags(1) = 15 bytes, then the length-prefixed name.
        val payload = encoded.copyOfRange(3, encoded.size)
        val nameLength = payload[15].toInt() and 0xFF
        assertTrue("name must fit the u8 length field", nameLength <= 255)
        assertEquals("payload size must match the declared name length",
                     16 + nameLength, payload.size)

        val decoded = String(payload.copyOfRange(16, payload.size), Charsets.UTF_8)
        assertFalse("truncation split a character", decoded.contains('\uFFFD'))
        // 255 / 4 = 63 whole emoji.
        assertEquals(63, decoded.length / 2)
    }

    @Test
    fun `frame lengths are sanity checked`() {
        assertFalse(VideoFraming.isPlausibleFrameLength(0))
        assertFalse(VideoFraming.isPlausibleFrameLength(-5))
        assertFalse(VideoFraming.isPlausibleFrameLength(WireProtocol.MAX_FRAME_BYTES + 1))
        assertTrue(VideoFraming.isPlausibleFrameLength(1_200_000))
    }
}
