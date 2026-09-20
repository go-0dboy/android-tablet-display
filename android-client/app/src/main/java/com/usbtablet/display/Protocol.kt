package com.usbtablet.display

import java.io.ByteArrayOutputStream

/**
 * The wire format, mirroring the macOS host's USBDisplayCore/Protocol.swift.
 *
 * Two channels run over whichever transport is in use (adb reverse over USB,
 * or a plain TCP socket over Wi-Fi):
 *
 *   Video (host -> client): [u32 BE length][Annex-B access unit]
 *   Input (bidirectional):  [u8 type][u16 BE length][payload]
 *
 * Everything is big-endian, which is what DataOutputStream writes natively and
 * what the Swift side reads, so the two implementations stay comparable by eye.
 */
object WireProtocol {
    const val VERSION = 2

    const val DEFAULT_VIDEO_PORT = 5560
    const val DEFAULT_INPUT_PORT = 5561

    const val MAX_FRAME_BYTES = 16 * 1024 * 1024
    const val MAX_INPUT_PAYLOAD_BYTES = 4096
}

object MessageType {
    const val TOUCH: Int = 0x01
    const val PEN: Int = 0x02
    const val SCROLL: Int = 0x03
    const val PINCH: Int = 0x04
    const val HELLO: Int = 0x10
    const val HELLO_ACK: Int = 0x11
    const val KEEP_ALIVE: Int = 0x12
    const val PAIR_REQUEST: Int = 0x20
    const val PAIR_RESPONSE: Int = 0x21
    const val PAIR_PROOF: Int = 0x22
    const val PAIR_RESULT: Int = 0x23
}

/** Lifecycle of a contact. Must match TouchPhase in the Swift core. */
enum class Phase(val code: Int) {
    DOWN(0), MOVE(1), UP(2), CANCEL(3), HOVER(4), HOVER_END(5);

    companion object {
        fun from(code: Int): Phase? = entries.firstOrNull { it.code == code }
    }
}

/** Capability bits the client advertises in its hello. */
object ClientFlags {
    const val HAS_STYLUS = 1 shl 0
    const val HAS_PRESSURE = 1 shl 1
    const val HAS_TILT = 1 shl 2
    const val DEX_ACTIVE = 1 shl 3
    const val PEN_ONLY = 1 shl 4

    // Old Android video stacks can expose hardware H.264 decoders that
    // become unstable with the modern 60 fps / high-bitrate stream.
    const val LEGACY_VIDEO_DECODER = 1 shl 5
}

sealed class OutgoingMessage {
    /** [x] and [y] are normalised 0..1 across the surface. */
    data class Touch(val pointerId: Int, val phase: Phase, val x: Float, val y: Float) :
        OutgoingMessage()

    /**
     * [tiltRadians] is the angle from the surface normal (Android's AXIS_TILT)
     * and [orientationRadians] the direction of lean (AXIS_ORIENTATION). They
     * are deliberately NOT pre-converted to macOS's tiltX/tiltY here: the host
     * does that, so there is exactly one place where the polar-to-cartesian
     * conversion can be wrong.
     */
    data class Pen(
        val phase: Phase, val x: Float, val y: Float, val pressure: Float,
        val tiltRadians: Float, val orientationRadians: Float, val buttons: Int
    ) : OutgoingMessage()

    data class Scroll(val deltaX: Float, val deltaY: Float, val phase: Phase) : OutgoingMessage()
    data class Pinch(val magnification: Float, val phase: Phase) : OutgoingMessage()

    data class Hello(
        val widthPixels: Int, val heightPixels: Int, val densityDpi: Int,
        val rotationDegrees: Int, val flags: Int, val deviceName: String
    ) : OutgoingMessage()

    object KeepAlive : OutgoingMessage()

    data class PairRequest(
        val clientKey: ByteArray, val clientNonce: ByteArray, val deviceName: String
    ) : OutgoingMessage() {
        override fun equals(other: Any?): Boolean =
            other is PairRequest && clientKey.contentEquals(other.clientKey) &&
                clientNonce.contentEquals(other.clientNonce) && deviceName == other.deviceName

        override fun hashCode(): Int =
            (clientKey.contentHashCode() * 31 + clientNonce.contentHashCode()) * 31 +
                deviceName.hashCode()
    }

    data class PairProof(val proof: ByteArray) : OutgoingMessage() {
        override fun equals(other: Any?): Boolean =
            other is PairProof && proof.contentEquals(other.proof)

        override fun hashCode(): Int = proof.contentHashCode()
    }
}

sealed class IncomingMessage {
    data class HelloAck(
        val protocolVersion: Int, val accepted: Boolean,
        val displayWidth: Int, val displayHeight: Int, val message: String
    ) : IncomingMessage()

    data class PairResponse(
        val hostKey: ByteArray, val hostNonce: ByteArray,
        val status: Int, val hostName: String
    ) : IncomingMessage() {
        override fun equals(other: Any?): Boolean =
            other is PairResponse && hostKey.contentEquals(other.hostKey) &&
                hostNonce.contentEquals(other.hostNonce) && status == other.status &&
                hostName == other.hostName

        override fun hashCode(): Int =
            ((hostKey.contentHashCode() * 31 + hostNonce.contentHashCode()) * 31 +
                status) * 31 + hostName.hashCode()
    }

    data class PairResult(val accepted: Boolean, val message: String) : IncomingMessage()
    object KeepAlive : IncomingMessage()
    data class Unknown(val type: Int, val payload: ByteArray) : IncomingMessage() {
        override fun equals(other: Any?): Boolean =
            other is Unknown && type == other.type && payload.contentEquals(other.payload)

        override fun hashCode(): Int = type * 31 + payload.contentHashCode()
    }
}

/** Pairing status codes, matching PairStatus in the Swift core. */
object PairStatus {
    const val NEEDS_CONFIRMATION = 0
    const val ALREADY_TRUSTED = 1
    const val REJECTED = 2
}

// MARK: - Encoding

private class Writer {
    val out = ByteArrayOutputStream()

    fun u8(v: Int) { out.write(v and 0xFF) }
    fun u16(v: Int) { out.write((v ushr 8) and 0xFF); out.write(v and 0xFF) }
    fun u32(v: Int) {
        out.write((v ushr 24) and 0xFF); out.write((v ushr 16) and 0xFF)
        out.write((v ushr 8) and 0xFF); out.write(v and 0xFF)
    }
    fun f32(v: Float) = u32(java.lang.Float.floatToIntBits(v))
    fun raw(bytes: ByteArray) = out.write(bytes)

    /** u8 length prefix then UTF-8, truncated rather than allowed to overflow. */
    fun shortString(s: String) {
        var bytes = s.toByteArray(Charsets.UTF_8)
        if (bytes.size > 255) {
            // Truncate on a character boundary so the result is still valid UTF-8.
            var end = 255
            while (end > 0 && (bytes[end].toInt() and 0xC0) == 0x80) end--
            bytes = bytes.copyOf(end)
        }
        u8(bytes.size)
        raw(bytes)
    }
}

object InputCodec {

    /** Encode a message with its [type][u16 length] header. */
    fun encode(message: OutgoingMessage): ByteArray {
        val body = Writer()
        val type: Int

        when (message) {
            is OutgoingMessage.Touch -> {
                type = MessageType.TOUCH
                body.u8(message.pointerId); body.u8(message.phase.code)
                body.f32(message.x); body.f32(message.y)
            }
            is OutgoingMessage.Pen -> {
                type = MessageType.PEN
                body.u8(message.phase.code)
                body.f32(message.x); body.f32(message.y); body.f32(message.pressure)
                body.f32(message.tiltRadians); body.f32(message.orientationRadians)
                body.u8(message.buttons)
            }
            is OutgoingMessage.Scroll -> {
                type = MessageType.SCROLL
                body.f32(message.deltaX); body.f32(message.deltaY); body.u8(message.phase.code)
            }
            is OutgoingMessage.Pinch -> {
                type = MessageType.PINCH
                body.f32(message.magnification); body.u8(message.phase.code)
            }
            is OutgoingMessage.Hello -> {
                type = MessageType.HELLO
                body.u16(WireProtocol.VERSION)
                body.u32(message.widthPixels); body.u32(message.heightPixels)
                body.u16(message.densityDpi); body.u16(message.rotationDegrees)
                body.u8(message.flags)
                body.shortString(message.deviceName)
            }
            is OutgoingMessage.KeepAlive -> type = MessageType.KEEP_ALIVE
            is OutgoingMessage.PairRequest -> {
                type = MessageType.PAIR_REQUEST
                body.u8(message.clientKey.size); body.raw(message.clientKey)
                body.u8(message.clientNonce.size); body.raw(message.clientNonce)
                body.shortString(message.deviceName)
            }
            is OutgoingMessage.PairProof -> {
                type = MessageType.PAIR_PROOF
                body.u8(message.proof.size); body.raw(message.proof)
            }
        }

        val payload = body.out.toByteArray()
        val framed = Writer()
        framed.u8(type)
        framed.u16(payload.size)
        framed.raw(payload)
        return framed.out.toByteArray()
    }
}

// MARK: - Decoding

class TruncatedMessageException(message: String) : Exception(message)

private class Reader(private val data: ByteArray) {
    private var offset = 0
    val remaining: Int get() = data.size - offset

    fun u8(): Int {
        if (remaining < 1) throw TruncatedMessageException("expected 1 byte, had $remaining")
        return data[offset++].toInt() and 0xFF
    }
    fun u16(): Int = (u8() shl 8) or u8()
    fun u32(): Int = (u8() shl 24) or (u8() shl 16) or (u8() shl 8) or u8()
    fun bytes(count: Int): ByteArray {
        if (remaining < count) throw TruncatedMessageException("expected $count, had $remaining")
        val slice = data.copyOfRange(offset, offset + count)
        offset += count
        return slice
    }
    fun shortString(): String = String(bytes(u8()), Charsets.UTF_8)
}

/**
 * Feeds bytes in, yields whole messages out. A read that lands mid-header is
 * handled the same as one that lands mid-payload, which is the whole point:
 * the previous protocol used fixed-size reads and a single short read
 * desynchronised the channel permanently.
 */
class InputStreamParser {
    private var buffer = ByteArray(0)

    val pendingByteCount: Int get() = buffer.size

    fun append(bytes: ByteArray, count: Int = bytes.size) {
        val combined = ByteArray(buffer.size + count)
        System.arraycopy(buffer, 0, combined, 0, buffer.size)
        System.arraycopy(bytes, 0, combined, buffer.size, count)
        buffer = combined
    }

    /** Next complete message, or null if more bytes are needed. */
    fun next(): IncomingMessage? {
        if (buffer.size < 3) return null

        val type = buffer[0].toInt() and 0xFF
        val length = ((buffer[1].toInt() and 0xFF) shl 8) or (buffer[2].toInt() and 0xFF)
        if (length > WireProtocol.MAX_INPUT_PAYLOAD_BYTES) {
            throw TruncatedMessageException("payload of $length bytes is implausible")
        }
        if (buffer.size < 3 + length) return null

        val payload = buffer.copyOfRange(3, 3 + length)
        buffer = buffer.copyOfRange(3 + length, buffer.size)
        return decode(type, payload)
    }

    private fun decode(type: Int, payload: ByteArray): IncomingMessage {
        val r = Reader(payload)
        return when (type) {
            MessageType.HELLO_ACK -> IncomingMessage.HelloAck(
                protocolVersion = r.u16(),
                accepted = r.u8() != 0,
                displayWidth = r.u32(),
                displayHeight = r.u32(),
                message = r.shortString()
            )
            MessageType.PAIR_RESPONSE -> IncomingMessage.PairResponse(
                hostKey = r.bytes(r.u8()),
                hostNonce = r.bytes(r.u8()),
                status = r.u8(),
                hostName = r.shortString()
            )
            MessageType.PAIR_RESULT -> IncomingMessage.PairResult(
                accepted = r.u8() != 0,
                message = r.shortString()
            )
            MessageType.KEEP_ALIVE -> IncomingMessage.KeepAlive
            // Unknown types are carried, not fatal: that is what lets an older
            // client keep working against a newer host.
            else -> IncomingMessage.Unknown(type, payload)
        }
    }
}

object VideoFraming {
    fun isPlausibleFrameLength(length: Int): Boolean =
        length > 0 && length <= WireProtocol.MAX_FRAME_BYTES
}
