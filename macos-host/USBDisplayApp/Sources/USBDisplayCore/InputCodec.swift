// InputCodec.swift — encode/decode for the input channel.
//
// Every value is big-endian, matching Java's DataOutputStream on the Android
// side so the two implementations stay trivially comparable.

import Foundation

public enum CodecError: Error, Equatable {
    case truncated(expected: Int, got: Int)
    case payloadTooLarge(Int)
    case badPhase(UInt8)
    case badString
}

// MARK: - Primitive readers/writers

/// A cursor over a Data buffer that refuses to read past the end.
public struct ByteReader {
    private let data: Data
    private var offset: Int

    public init(_ data: Data) {
        self.data = data
        self.offset = 0
    }

    public var remaining: Int { data.count - offset }

    public mutating func u8() throws -> UInt8 {
        guard remaining >= 1 else { throw CodecError.truncated(expected: 1, got: remaining) }
        defer { offset += 1 }
        return data[data.startIndex + offset]
    }

    public mutating func u16() throws -> UInt16 {
        guard remaining >= 2 else { throw CodecError.truncated(expected: 2, got: remaining) }
        var v: UInt16 = 0
        for _ in 0..<2 { v = (v << 8) | UInt16(try u8()) }
        return v
    }

    public mutating func u32() throws -> UInt32 {
        guard remaining >= 4 else { throw CodecError.truncated(expected: 4, got: remaining) }
        var v: UInt32 = 0
        for _ in 0..<4 { v = (v << 8) | UInt32(try u8()) }
        return v
    }

    public mutating func f32() throws -> Float {
        Float(bitPattern: try u32())
    }

    public mutating func bytes(_ count: Int) throws -> Data {
        guard remaining >= count else { throw CodecError.truncated(expected: count, got: remaining) }
        let start = data.startIndex + offset
        defer { offset += count }
        return data.subdata(in: start..<(start + count))
    }

    /// u8 length prefix, then that many UTF-8 bytes.
    public mutating func shortString() throws -> String {
        let length = Int(try u8())
        let raw = try bytes(length)
        guard let s = String(data: raw, encoding: .utf8) else { throw CodecError.badString }
        return s
    }
}

public struct ByteWriter {
    public private(set) var data = Data()
    public init() {}

    public mutating func u8(_ v: UInt8) { data.append(v) }
    public mutating func u16(_ v: UInt16) { data.append(UInt8(v >> 8)); data.append(UInt8(v & 0xFF)) }
    public mutating func u32(_ v: UInt32) {
        data.append(UInt8((v >> 24) & 0xFF)); data.append(UInt8((v >> 16) & 0xFF))
        data.append(UInt8((v >> 8) & 0xFF));  data.append(UInt8(v & 0xFF))
    }
    public mutating func f32(_ v: Float) { u32(v.bitPattern) }
    public mutating func raw(_ d: Data) { data.append(d) }

    /// Truncates to 255 bytes rather than failing — a device name is cosmetic.
    public mutating func shortString(_ s: String) {
        var utf8 = Array(s.utf8)
        if utf8.count > 255 { utf8 = Array(utf8.prefix(255)) }
        u8(UInt8(utf8.count))
        data.append(contentsOf: utf8)
    }
}

// MARK: - Message codec

public enum InputCodec {

    /// Encode one message including its [type][u16 length] header.
    public static func encode(_ message: InputMessage) -> Data {
        var body = ByteWriter()
        let type: UInt8

        switch message {
        case .touch(let e):
            type = InputMessageType.touch.rawValue
            body.u8(e.pointerId); body.u8(e.phase.rawValue)
            body.f32(e.x); body.f32(e.y)

        case .pen(let e):
            type = InputMessageType.pen.rawValue
            body.u8(e.phase.rawValue)
            body.f32(e.x); body.f32(e.y); body.f32(e.pressure)
            body.f32(e.tiltRadians); body.f32(e.orientationRadians)
            body.u8(e.buttons)

        case .scroll(let e):
            type = InputMessageType.scroll.rawValue
            body.f32(e.deltaX); body.f32(e.deltaY); body.u8(e.phase.rawValue)

        case .pinch(let e):
            type = InputMessageType.pinch.rawValue
            body.f32(e.magnification); body.u8(e.phase.rawValue)

        case .hello(let h):
            type = InputMessageType.hello.rawValue
            body.u16(h.protocolVersion)
            body.u32(h.widthPixels); body.u32(h.heightPixels)
            body.u16(h.densityDpi); body.u16(h.rotationDegrees)
            body.u8(h.flags.rawValue)
            body.shortString(h.deviceName)

        case .helloAck(let a):
            type = InputMessageType.helloAck.rawValue
            body.u16(a.protocolVersion)
            body.u8(a.accepted ? 1 : 0)
            body.u32(a.displayWidth); body.u32(a.displayHeight)
            body.shortString(a.message)

        case .keepAlive:
            type = InputMessageType.keepAlive.rawValue

        case .pairRequest(let r):
            type = InputMessageType.pairRequest.rawValue
            body.u8(UInt8(r.clientKey.count)); body.raw(r.clientKey)
            body.u8(UInt8(r.clientNonce.count)); body.raw(r.clientNonce)
            body.shortString(r.deviceName)

        case .pairResponse(let r):
            type = InputMessageType.pairResponse.rawValue
            body.u8(UInt8(r.hostKey.count)); body.raw(r.hostKey)
            body.u8(UInt8(r.hostNonce.count)); body.raw(r.hostNonce)
            body.u8(r.status.rawValue)
            body.shortString(r.hostName)

        case .pairProof(let p):
            type = InputMessageType.pairProof.rawValue
            body.u8(UInt8(p.proof.count)); body.raw(p.proof)

        case .pairResult(let r):
            type = InputMessageType.pairResult.rawValue
            body.u8(r.accepted ? 1 : 0)
            body.shortString(r.message)

        case .unknown(let t, let payload):
            type = t
            body.raw(payload)
        }

        var out = ByteWriter()
        out.u8(type)
        out.u16(UInt16(min(body.data.count, Int(UInt16.max))))
        out.raw(body.data)
        return out.data
    }

    /// Decode a payload that has already been separated from its header.
    public static func decode(type: UInt8, payload: Data) throws -> InputMessage {
        var r = ByteReader(payload)

        guard let known = InputMessageType(rawValue: type) else {
            return .unknown(type: type, payload: payload)
        }

        switch known {
        case .touch:
            let pointerId = try r.u8()
            let phaseRaw = try r.u8()
            guard let phase = TouchPhase(rawValue: phaseRaw) else { throw CodecError.badPhase(phaseRaw) }
            return .touch(TouchEvent(pointerId: pointerId, phase: phase,
                                     x: try r.f32(), y: try r.f32()))

        case .pen:
            let phaseRaw = try r.u8()
            guard let phase = TouchPhase(rawValue: phaseRaw) else { throw CodecError.badPhase(phaseRaw) }
            let x = try r.f32(), y = try r.f32(), pressure = try r.f32()
            let tilt = try r.f32(), orientation = try r.f32()
            // Buttons were added after the first v2 drafts; treat absence as none.
            let buttons = r.remaining >= 1 ? try r.u8() : 0
            return .pen(PenEvent(phase: phase, x: x, y: y, pressure: pressure,
                                 tiltRadians: tilt, orientationRadians: orientation,
                                 buttons: buttons))

        case .scroll:
            let dx = try r.f32(), dy = try r.f32()
            let phaseRaw = try r.u8()
            guard let phase = TouchPhase(rawValue: phaseRaw) else { throw CodecError.badPhase(phaseRaw) }
            return .scroll(ScrollEvent(deltaX: dx, deltaY: dy, phase: phase))

        case .pinch:
            let m = try r.f32()
            let phaseRaw = try r.u8()
            guard let phase = TouchPhase(rawValue: phaseRaw) else { throw CodecError.badPhase(phaseRaw) }
            return .pinch(PinchEvent(magnification: m, phase: phase))

        case .hello:
            let version = try r.u16()
            let w = try r.u32(), h = try r.u32()
            let dpi = try r.u16(), rotation = try r.u16()
            let flags = ClientFlags(rawValue: try r.u8())
            let name = try r.shortString()
            return .hello(ClientHello(protocolVersion: version, widthPixels: w, heightPixels: h,
                                      densityDpi: dpi, rotationDegrees: rotation,
                                      flags: flags, deviceName: name))

        case .helloAck:
            let version = try r.u16()
            let accepted = try r.u8() != 0
            let w = try r.u32(), h = try r.u32()
            let message = try r.shortString()
            return .helloAck(HelloAck(protocolVersion: version, accepted: accepted,
                                      displayWidth: w, displayHeight: h, message: message))

        case .keepAlive:
            return .keepAlive

        case .pairRequest:
            let key = try r.bytes(Int(try r.u8()))
            let nonce = try r.bytes(Int(try r.u8()))
            return .pairRequest(PairRequest(clientKey: key, clientNonce: nonce,
                                            deviceName: try r.shortString()))

        case .pairResponse:
            let key = try r.bytes(Int(try r.u8()))
            let nonce = try r.bytes(Int(try r.u8()))
            let statusRaw = try r.u8()
            guard let status = PairStatus(rawValue: statusRaw) else {
                throw CodecError.badPhase(statusRaw)
            }
            return .pairResponse(PairResponse(hostKey: key, hostNonce: nonce,
                                              status: status, hostName: try r.shortString()))

        case .pairProof:
            return .pairProof(PairProof(proof: try r.bytes(Int(try r.u8()))))

        case .pairResult:
            let accepted = try r.u8() != 0
            return .pairResult(PairResult(accepted: accepted, message: try r.shortString()))
        }
    }
}

// MARK: - Incremental stream parser

/// Feeds bytes in, yields whole messages out. Written as a state machine so a
/// TCP read that lands mid-header is handled the same as one that lands
/// mid-payload — the failure mode this replaces was a fixed-size read that
/// silently desynchronised the channel forever.
public struct InputStreamParser {
    private var buffer = Data()
    public init() {}

    /// Bytes held because a message is not yet complete.
    public var pendingByteCount: Int { buffer.count }

    public mutating func append(_ newBytes: Data) {
        buffer.append(newBytes)
    }

    /// Pull the next complete message, or nil if more bytes are needed.
    public mutating func next() throws -> InputMessage? {
        guard buffer.count >= 3 else { return nil }

        let base = buffer.startIndex
        let type = buffer[base]
        let length = Int(buffer[base + 1]) << 8 | Int(buffer[base + 2])

        guard length <= WireProtocol.maxInputPayloadBytes else {
            throw CodecError.payloadTooLarge(length)
        }
        guard buffer.count >= 3 + length else { return nil }

        let payload = buffer.subdata(in: (base + 3)..<(base + 3 + length))
        buffer.removeSubrange(base..<(base + 3 + length))
        return try InputCodec.decode(type: type, payload: payload)
    }
}

// MARK: - Video framing

public enum VideoFraming {
    /// Prefix a compressed access unit with its big-endian length.
    public static func frame(_ payload: Data) -> Data {
        var w = ByteWriter()
        w.u32(UInt32(payload.count))
        w.raw(payload)
        return w.data
    }

    /// Validate a length prefix before allocating for it.
    public static func isPlausibleFrameLength(_ length: Int) -> Bool {
        length > 0 && length <= WireProtocol.maxFrameBytes
    }
}
