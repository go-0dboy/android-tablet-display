// Protocol.swift — the wire format shared by the macOS host and the Android client.
//
// Two channels run over the same transport (ADB reverse over USB, or TCP over
// Wi-Fi). Both are length-prefixed so a short read can never desynchronise the
// stream — the v1 format used fixed-size records, which meant one dropped byte
// corrupted every frame that followed.
//
//   Video channel  (host -> client): [u32 BE length][Annex-B H.264/HEVC access unit]
//   Input channel  (bidirectional):  [u8 type][u16 BE length][payload]
//
// Keeping the input channel self-describing lets either side skip a message
// type it does not understand, so an older client can talk to a newer host.

import Foundation

public enum WireProtocol {
    /// Bumped whenever a payload layout changes incompatibly.
    public static let version: UInt16 = 2

    public static let defaultVideoPort: UInt16 = 5560
    public static let defaultInputPort: UInt16 = 5561
    /// Port the host's Bonjour service advertises for wireless mode.
    public static let defaultWirelessPort: UInt16 = 5562

    /// Largest video frame we will accept. A 4K keyframe is comfortably under
    /// this; anything larger means the stream is corrupt, not merely big.
    public static let maxFrameBytes = 16 * 1024 * 1024
    /// Largest input message. Input payloads are tiny; the cap is a guard.
    public static let maxInputPayloadBytes = 4096
}

/// Message types on the input channel.
public enum InputMessageType: UInt8, Sendable {
    case touch = 0x01
    case pen = 0x02
    case scroll = 0x03
    case pinch = 0x04
    case hello = 0x10       // client -> host, first message on the channel
    case helloAck = 0x11    // host -> client
    case keepAlive = 0x12   // either direction

    // Wireless pairing. Over USB these are never sent: the cable and adb's own
    // "Allow USB debugging" prompt are the authorisation.
    case pairRequest = 0x20   // client -> host
    case pairResponse = 0x21  // host -> client
    case pairProof = 0x22     // client -> host
    case pairResult = 0x23    // host -> client
}

/// Lifecycle of a contact (finger, pen, or gesture).
public enum TouchPhase: UInt8, Sendable {
    case down = 0
    case move = 1
    case up = 2
    case cancel = 3
    case hover = 4      // pen in range but not touching
    case hoverEnd = 5
}

/// A single finger contact. `pointerId` is stable for the life of the contact,
/// which is what makes two-finger gestures possible at all.
public struct TouchEvent: Equatable, Sendable {
    public var pointerId: UInt8
    public var phase: TouchPhase
    /// Normalised 0...1 across the client's surface.
    public var x: Float
    public var y: Float

    public init(pointerId: UInt8, phase: TouchPhase, x: Float, y: Float) {
        self.pointerId = pointerId
        self.phase = phase
        self.x = x
        self.y = y
    }
}

/// A pen contact. Tilt is carried as altitude/azimuth in radians — the form
/// Android reports natively (AXIS_TILT is a magnitude, AXIS_ORIENTATION a
/// direction) — and converted to macOS's tiltX/tiltY only at injection time.
public struct PenEvent: Equatable, Sendable {
    public var phase: TouchPhase
    public var x: Float
    public var y: Float
    /// 0...1.
    public var pressure: Float
    /// Angle from the surface normal, radians. 0 = perpendicular.
    public var tiltRadians: Float
    /// Direction the pen leans, radians, 0 = towards the top of the display.
    public var orientationRadians: Float
    /// Bit 0 = barrel button, bit 1 = eraser end.
    public var buttons: UInt8

    public init(phase: TouchPhase, x: Float, y: Float, pressure: Float,
                tiltRadians: Float, orientationRadians: Float, buttons: UInt8) {
        self.phase = phase
        self.x = x
        self.y = y
        self.pressure = pressure
        self.tiltRadians = tiltRadians
        self.orientationRadians = orientationRadians
        self.buttons = buttons
    }

    /// macOS wants tilt as two independent -1...1 components. Android gives a
    /// polar pair, so decompose it. tiltX is positive to the right, tiltY
    /// positive towards the top, matching NSEvent's tablet fields.
    public var macOSTilt: (x: Float, y: Float) {
        // sin(tilt) maps 0 (perpendicular) -> 0 and pi/2 (flat) -> 1.
        let magnitude = min(max(sin(tiltRadians), 0), 1)
        return (magnitude * sin(orientationRadians), magnitude * cos(orientationRadians))
    }
}

/// Two-finger scroll, already accumulated on the client into a delta.
public struct ScrollEvent: Equatable, Sendable {
    /// Points, positive = content moves right / up, matching NSEvent.
    public var deltaX: Float
    public var deltaY: Float
    public var phase: TouchPhase

    public init(deltaX: Float, deltaY: Float, phase: TouchPhase) {
        self.deltaX = deltaX
        self.deltaY = deltaY
        self.phase = phase
    }
}

/// Pinch-to-zoom, as an incremental magnification factor.
public struct PinchEvent: Equatable, Sendable {
    /// Incremental change, e.g. 0.02 means "2% larger since the last event".
    public var magnification: Float
    public var phase: TouchPhase

    public init(magnification: Float, phase: TouchPhase) {
        self.magnification = magnification
        self.phase = phase
    }
}

/// What the client tells the host about itself the moment it connects. The
/// host sizes the virtual display from this, which is why the display comes up
/// at the tablet's real resolution and density instead of a hardcoded guess.
public struct ClientHello: Equatable, Sendable {
    public var protocolVersion: UInt16
    public var widthPixels: UInt32
    public var heightPixels: UInt32
    /// Android's DisplayMetrics.densityDpi.
    public var densityDpi: UInt16
    /// Surface rotation in degrees: 0, 90, 180, 270.
    public var rotationDegrees: UInt16
    public var flags: ClientFlags
    /// Human-readable device model, for the Displays pane.
    public var deviceName: String

    public init(protocolVersion: UInt16 = WireProtocol.version,
                widthPixels: UInt32, heightPixels: UInt32, densityDpi: UInt16,
                rotationDegrees: UInt16, flags: ClientFlags, deviceName: String) {
        self.protocolVersion = protocolVersion
        self.widthPixels = widthPixels
        self.heightPixels = heightPixels
        self.densityDpi = densityDpi
        self.rotationDegrees = rotationDegrees
        self.flags = flags
        self.deviceName = deviceName
    }
}

public struct ClientFlags: OptionSet, Equatable, Sendable {
    public let rawValue: UInt8
    public init(rawValue: UInt8) { self.rawValue = rawValue }

    /// Device reports a stylus digitiser (S Pen, or any TOOL_TYPE_STYLUS source).
    public static let hasStylus = ClientFlags(rawValue: 1 << 0)
    /// Device reports pressure resolution better than on/off.
    public static let hasPressure = ClientFlags(rawValue: 1 << 1)
    /// Device reports tilt.
    public static let hasTilt = ClientFlags(rawValue: 1 << 2)
    /// Samsung DeX is currently active — the client warns, the host logs it.
    public static let dexActive = ClientFlags(rawValue: 1 << 3)
    /// User asked for pen-only mode: fingers do not move the pointer.
    public static let penOnly = ClientFlags(rawValue: 1 << 4)
}

/// Host's answer to a hello: what it actually created.
public struct HelloAck: Equatable, Sendable {
    public var protocolVersion: UInt16
    public var accepted: Bool
    public var displayWidth: UInt32
    public var displayHeight: UInt32
    public var message: String

    public init(protocolVersion: UInt16 = WireProtocol.version, accepted: Bool,
                displayWidth: UInt32, displayHeight: UInt32, message: String) {
        self.protocolVersion = protocolVersion
        self.accepted = accepted
        self.displayWidth = displayWidth
        self.displayHeight = displayHeight
        self.message = message
    }
}

/// Client opening a wireless session: who it is, and a fresh nonce.
public struct PairRequest: Equatable, Sendable {
    public var clientKey: Data       // 32 bytes
    public var clientNonce: Data     // 16 bytes
    public var deviceName: String

    public init(clientKey: Data, clientNonce: Data, deviceName: String) {
        self.clientKey = clientKey
        self.clientNonce = clientNonce
        self.deviceName = deviceName
    }
}

/// How the host is treating this client.
public enum PairStatus: UInt8, Sendable {
    /// Never seen before: both sides show the code and a person confirms.
    case needsConfirmation = 0
    /// Already trusted: prove it and carry on, no taps.
    case alreadyTrusted = 1
    /// Refused — wireless is off, or the user declined.
    case rejected = 2
}

public struct PairResponse: Equatable, Sendable {
    public var hostKey: Data         // 32 bytes
    public var hostNonce: Data       // 16 bytes
    public var status: PairStatus
    public var hostName: String

    public init(hostKey: Data, hostNonce: Data, status: PairStatus, hostName: String) {
        self.hostKey = hostKey
        self.hostNonce = hostNonce
        self.status = status
        self.hostName = hostName
    }
}

/// Proof that a returning client still holds the key it paired with.
public struct PairProof: Equatable, Sendable {
    public var proof: Data           // 32 bytes
    public init(proof: Data) { self.proof = proof }
}

public struct PairResult: Equatable, Sendable {
    public var accepted: Bool
    public var message: String
    public init(accepted: Bool, message: String) {
        self.accepted = accepted
        self.message = message
    }
}

/// Anything the input channel can carry, once decoded.
public enum InputMessage: Equatable, Sendable {
    case touch(TouchEvent)
    case pen(PenEvent)
    case scroll(ScrollEvent)
    case pinch(PinchEvent)
    case hello(ClientHello)
    case helloAck(HelloAck)
    case keepAlive
    case pairRequest(PairRequest)
    case pairResponse(PairResponse)
    case pairProof(PairProof)
    case pairResult(PairResult)
    /// A well-formed message of a type we do not know. Carried so the reader
    /// can skip it rather than losing sync.
    case unknown(type: UInt8, payload: Data)
}
