import XCTest
@testable import USBDisplayCore

final class InputCodecTests: XCTestCase {

    /// Every message type must survive a round trip unchanged. This is the
    /// test that would have caught the v1 pen format carrying tilt fields the
    /// host then ignored.
    func testRoundTripsEveryMessageType() throws {
        let messages: [InputMessage] = [
            .touch(TouchEvent(pointerId: 0, phase: .down, x: 0.25, y: 0.75)),
            .touch(TouchEvent(pointerId: 3, phase: .cancel, x: 1.0, y: 0.0)),
            .pen(PenEvent(phase: .move, x: 0.5, y: 0.5, pressure: 0.42,
                          tiltRadians: 0.3, orientationRadians: 1.2, buttons: 0x01)),
            .pen(PenEvent(phase: .hover, x: 0, y: 1, pressure: 0,
                          tiltRadians: 0, orientationRadians: 0, buttons: 0)),
            .scroll(ScrollEvent(deltaX: -12.5, deltaY: 30, phase: .move)),
            .pinch(PinchEvent(magnification: 0.05, phase: .down)),
            .keepAlive,
            .hello(ClientHello(widthPixels: 2560, heightPixels: 1600, densityDpi: 320,
                               rotationDegrees: 90,
                               flags: [.hasStylus, .hasPressure, .hasTilt],
                               deviceName: "Galaxy Tab S9")),
            .helloAck(HelloAck(accepted: true, displayWidth: 2560, displayHeight: 1600,
                               message: "ok"))
        ]

        for message in messages {
            let encoded = InputCodec.encode(message)
            var parser = InputStreamParser()
            parser.append(encoded)
            let decoded = try parser.next()
            XCTAssertEqual(decoded, message, "round trip failed for \(message)")
            XCTAssertNil(try parser.next(), "parser produced a spurious extra message")
        }
    }

    /// The whole reason for length-prefixed framing: a stream that arrives one
    /// byte at a time must decode identically to one that arrives whole.
    func testParserSurvivesByteAtATimeDelivery() throws {
        let original: [InputMessage] = [
            .hello(ClientHello(widthPixels: 1920, heightPixels: 1200, densityDpi: 240,
                               rotationDegrees: 0, flags: [.hasStylus],
                               deviceName: "test")),
            .pen(PenEvent(phase: .down, x: 0.1, y: 0.2, pressure: 1.0,
                          tiltRadians: 0.5, orientationRadians: 2.0, buttons: 0)),
            .touch(TouchEvent(pointerId: 1, phase: .up, x: 0.9, y: 0.9))
        ]
        var wire = Data()
        for message in original { wire.append(InputCodec.encode(message)) }

        var parser = InputStreamParser()
        var received: [InputMessage] = []
        for byte in wire {
            parser.append(Data([byte]))
            while let message = try parser.next() { received.append(message) }
        }
        XCTAssertEqual(received, original)
        XCTAssertEqual(parser.pendingByteCount, 0)
    }

    /// Several messages in one TCP read must all come out.
    func testParserHandlesCoalescedMessages() throws {
        var wire = Data()
        for i in 0..<50 {
            wire.append(InputCodec.encode(
                .touch(TouchEvent(pointerId: UInt8(i % 5), phase: .move,
                                  x: Float(i) / 50, y: 0.5))))
        }
        var parser = InputStreamParser()
        parser.append(wire)

        var count = 0
        while try parser.next() != nil { count += 1 }
        XCTAssertEqual(count, 50)
    }

    /// An unknown message type must be skipped, not treated as desync. This is
    /// what lets an old client talk to a new host.
    func testUnknownMessageTypeIsSkippedNotFatal() throws {
        var wire = Data()
        wire.append(InputCodec.encode(.unknown(type: 0x7F, payload: Data([1, 2, 3, 4]))))
        wire.append(InputCodec.encode(.touch(TouchEvent(pointerId: 0, phase: .down,
                                                        x: 0.5, y: 0.5))))
        var parser = InputStreamParser()
        parser.append(wire)

        let first = try parser.next()
        guard case .unknown(let type, let payload) = first else {
            return XCTFail("expected an unknown message, got \(String(describing: first))")
        }
        XCTAssertEqual(type, 0x7F)
        XCTAssertEqual(payload, Data([1, 2, 3, 4]))

        // The known message after it still decodes: the stream stayed in sync.
        XCTAssertEqual(try parser.next(),
                       .touch(TouchEvent(pointerId: 0, phase: .down, x: 0.5, y: 0.5)))
    }

    func testOversizedPayloadIsRejected() {
        // Hand-build a header claiming a payload larger than the cap.
        var wire = Data([InputMessageType.touch.rawValue])
        wire.append(0xFF); wire.append(0xFF)   // 65535 bytes
        wire.append(Data(repeating: 0, count: 16))

        var parser = InputStreamParser()
        parser.append(wire)
        XCTAssertThrowsError(try parser.next()) { error in
            XCTAssertEqual(error as? CodecError, .payloadTooLarge(65535))
        }
    }

    func testBadPhaseIsRejected() {
        var writer = ByteWriter()
        writer.u8(0)      // pointerId
        writer.u8(99)     // not a valid phase
        writer.f32(0); writer.f32(0)
        XCTAssertThrowsError(
            try InputCodec.decode(type: InputMessageType.touch.rawValue,
                                  payload: writer.data)) { error in
            XCTAssertEqual(error as? CodecError, .badPhase(99))
        }
    }

    func testTruncatedPayloadIsRejectedNotRead()  {
        var writer = ByteWriter()
        writer.u8(0); writer.u8(TouchPhase.down.rawValue)
        writer.f32(0.5)   // y is missing
        XCTAssertThrowsError(
            try InputCodec.decode(type: InputMessageType.touch.rawValue,
                                  payload: writer.data))
    }

    /// A device name longer than the 255-byte field must truncate rather than
    /// corrupt the frame that follows it.
    func testOverlongDeviceNameTruncatesSafely() throws {
        let longName = String(repeating: "M", count: 400)
        let hello = ClientHello(widthPixels: 100, heightPixels: 100, densityDpi: 160,
                                rotationDegrees: 0, flags: [], deviceName: longName)
        var parser = InputStreamParser()
        parser.append(InputCodec.encode(.hello(hello)))
        parser.append(InputCodec.encode(.keepAlive))

        guard case .hello(let decoded)? = try parser.next() else {
            return XCTFail("hello did not decode")
        }
        XCTAssertEqual(decoded.deviceName.utf8.count, 255)
        // The message after it is intact, which is the real assertion.
        XCTAssertEqual(try parser.next(), .keepAlive)
    }

    func testMultibyteDeviceNameSurvives() throws {
        let hello = ClientHello(widthPixels: 100, heightPixels: 100, densityDpi: 160,
                                rotationDegrees: 0, flags: [],
                                deviceName: "갤럭시 탭 · Galaxy")
        var parser = InputStreamParser()
        parser.append(InputCodec.encode(.hello(hello)))
        guard case .hello(let decoded)? = try parser.next() else {
            return XCTFail("hello did not decode")
        }
        XCTAssertEqual(decoded.deviceName, "갤럭시 탭 · Galaxy")
    }
}

final class VideoFramingTests: XCTestCase {

    func testFramePrefixesBigEndianLength() {
        let payload = Data([0xAA, 0xBB, 0xCC])
        let framed = VideoFraming.frame(payload)
        XCTAssertEqual(Array(framed.prefix(4)), [0, 0, 0, 3])
        XCTAssertEqual(framed.dropFirst(4), payload)
    }

    func testImplausibleLengthsAreRejected() {
        XCTAssertFalse(VideoFraming.isPlausibleFrameLength(0))
        XCTAssertFalse(VideoFraming.isPlausibleFrameLength(-1))
        XCTAssertFalse(VideoFraming.isPlausibleFrameLength(WireProtocol.maxFrameBytes + 1))
        XCTAssertTrue(VideoFraming.isPlausibleFrameLength(1))
        XCTAssertTrue(VideoFraming.isPlausibleFrameLength(1_500_000))
    }
}

final class PenTiltTests: XCTestCase {

    /// A pen held straight up has no tilt in either axis, whatever direction
    /// it is nominally pointing.
    func testPerpendicularPenHasNoTilt() {
        for orientation in stride(from: Float(0), to: 6.28, by: 0.5) {
            let pen = PenEvent(phase: .move, x: 0, y: 0, pressure: 1,
                               tiltRadians: 0, orientationRadians: orientation, buttons: 0)
            let tilt = pen.macOSTilt
            XCTAssertEqual(tilt.x, 0, accuracy: 0.0001)
            XCTAssertEqual(tilt.y, 0, accuracy: 0.0001)
        }
    }

    /// Fully flat, pointing "up" the display, is +1 on Y and 0 on X.
    func testFlatPenTowardsTopIsFullYTilt() {
        let pen = PenEvent(phase: .move, x: 0, y: 0, pressure: 1,
                           tiltRadians: .pi / 2, orientationRadians: 0, buttons: 0)
        let tilt = pen.macOSTilt
        XCTAssertEqual(tilt.x, 0, accuracy: 0.0001)
        XCTAssertEqual(tilt.y, 1, accuracy: 0.0001)
    }

    /// Fully flat, pointing right, is +1 on X.
    func testFlatPenTowardsRightIsFullXTilt() {
        let pen = PenEvent(phase: .move, x: 0, y: 0, pressure: 1,
                           tiltRadians: .pi / 2, orientationRadians: .pi / 2, buttons: 0)
        let tilt = pen.macOSTilt
        XCTAssertEqual(tilt.x, 1, accuracy: 0.0001)
        XCTAssertEqual(tilt.y, 0, accuracy: 0.0001)
    }

    /// macOS tablet fields are defined on -1...1; nothing may escape that.
    func testTiltIsAlwaysWithinUnitRange() {
        for tilt in stride(from: Float(-3.2), through: 3.2, by: 0.2) {
            for orientation in stride(from: Float(-6.5), through: 6.5, by: 0.4) {
                let pen = PenEvent(phase: .move, x: 0, y: 0, pressure: 1,
                                   tiltRadians: tilt, orientationRadians: orientation,
                                   buttons: 0)
                let result = pen.macOSTilt
                XCTAssertLessThanOrEqual(abs(result.x), 1.0001)
                XCTAssertLessThanOrEqual(abs(result.y), 1.0001)
                XCTAssertFalse(result.x.isNaN)
                XCTAssertFalse(result.y.isNaN)
            }
        }
    }
}
