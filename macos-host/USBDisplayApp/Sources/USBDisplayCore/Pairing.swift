// Pairing.swift — trusting a device over Wi-Fi.
//
// Over USB the cable is the authorisation: adb already made the user tap
// "Allow USB debugging" and nothing else can reach the loopback socket. Over
// Wi-Fi that is gone — anything on the network could otherwise connect and
// receive a live video feed of the Mac's screen. So wireless mode pairs first.
//
// The scheme is a short authenticated string, the same shape of check as a
// Bluetooth passkey:
//
//   1. Both sides send a random nonce and a long-lived public identity key.
//   2. Both derive the same six digits from those four values.
//   3. Both show the digits. The person confirms they match, on the host.
//   4. The host records the client's identity key as trusted.
//
// After that the client proves it holds the same key with an HMAC over fresh
// nonces, so a later connection needs no taps at all — which is the "seamless"
// part — while an unpaired device cannot get a single frame.
//
// This is not a substitute for a transport that encrypts the video. It
// authenticates the peer; it does not hide the pixels from someone already
// capturing the LAN. That limitation is written down in docs/WIRELESS.md
// rather than papered over.

import Foundation
import CryptoKit

public struct PairingIdentity: Equatable, Sendable {
    /// 32 random bytes, generated once per install and kept thereafter.
    public var key: Data

    public init(key: Data) { self.key = key }

    public static func generate() -> PairingIdentity {
        var bytes = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return PairingIdentity(key: Data(bytes))
    }

    /// Short, stable, non-secret handle for this identity. Safe to log and to
    /// show in a device list.
    public var fingerprint: String {
        let digest = SHA256.hash(data: key)
        return digest.prefix(4).map { String(format: "%02X", $0) }.joined()
    }
}

public struct PairingNonce: Equatable, Sendable {
    public var bytes: Data
    public init(bytes: Data) { self.bytes = bytes }

    public static func generate() -> PairingNonce {
        var raw = [UInt8](repeating: 0, count: 16)
        _ = SecRandomCopyBytes(kSecRandomDefault, raw.count, &raw)
        return PairingNonce(bytes: Data(raw))
    }
}

public enum Pairing {
    /// Digits in the code the person compares.
    public static let codeDigits = 6

    /// Derive the short authenticated string both screens display.
    ///
    /// Order matters and is fixed as client-then-host so the two
    /// implementations cannot disagree about it.
    public static func shortCode(clientNonce: PairingNonce,
                                 hostNonce: PairingNonce,
                                 clientKey: Data,
                                 hostKey: Data) -> String {
        var input = Data()
        input.append(contentsOf: Array("usbtabletdisplay-sas-v1".utf8))
        input.append(clientNonce.bytes)
        input.append(hostNonce.bytes)
        input.append(clientKey)
        input.append(hostKey)

        let digest = SHA256.hash(data: input)
        // Fold the first four bytes into a number, then take the low digits.
        var value: UInt32 = 0
        for byte in digest.prefix(4) { value = (value << 8) | UInt32(byte) }

        var modulus: UInt32 = 1
        for _ in 0..<codeDigits { modulus *= 10 }
        let code = value % modulus

        return String(format: "%0\(codeDigits)u", code)
    }

    /// Proof that a returning client still holds the key it paired with.
    public static func sessionProof(clientKey: Data,
                                    clientNonce: PairingNonce,
                                    hostNonce: PairingNonce) -> Data {
        var message = Data()
        message.append(contentsOf: Array("usbtabletdisplay-session-v1".utf8))
        message.append(clientNonce.bytes)
        message.append(hostNonce.bytes)
        let mac = HMAC<SHA256>.authenticationCode(
            for: message, using: SymmetricKey(data: clientKey))
        return Data(mac)
    }

    /// Constant-time comparison. A byte-by-byte early exit here would leak the
    /// proof one byte at a time to anything that can time the handshake.
    public static func verify(proof: Data, matches expected: Data) -> Bool {
        guard proof.count == expected.count, !proof.isEmpty else { return false }
        var difference: UInt8 = 0
        for (a, b) in zip(proof, expected) { difference |= (a ^ b) }
        return difference == 0
    }
}

/// A device the user has confirmed. Stored on the host.
public struct TrustedClient: Equatable, Sendable, Codable {
    public var name: String
    /// Hex-encoded identity key.
    public var keyHex: String
    public var pairedAt: Date
    public var lastSeen: Date?

    public init(name: String, keyHex: String, pairedAt: Date, lastSeen: Date? = nil) {
        self.name = name
        self.keyHex = keyHex
        self.pairedAt = pairedAt
        self.lastSeen = lastSeen
    }

    public var key: Data? { Data(hexString: keyHex) }

    public var fingerprint: String {
        guard let key else { return "????????" }
        return PairingIdentity(key: key).fingerprint
    }
}

public struct TrustStore: Equatable, Sendable, Codable {
    public private(set) var clients: [TrustedClient]

    public init(clients: [TrustedClient] = []) { self.clients = clients }

    public func client(withKey key: Data) -> TrustedClient? {
        let hex = key.hexString
        return clients.first { $0.keyHex.caseInsensitiveCompare(hex) == .orderedSame }
    }

    public func isTrusted(key: Data) -> Bool { client(withKey: key) != nil }

    public mutating func trust(name: String, key: Data) {
        let hex = key.hexString
        if let index = clients.firstIndex(where: {
            $0.keyHex.caseInsensitiveCompare(hex) == .orderedSame
        }) {
            clients[index].name = name
            clients[index].lastSeen = Date()
        } else {
            clients.append(TrustedClient(name: name, keyHex: hex, pairedAt: Date(),
                                         lastSeen: Date()))
        }
    }

    public mutating func forget(keyHex: String) {
        clients.removeAll { $0.keyHex.caseInsensitiveCompare(keyHex) == .orderedSame }
    }

    public mutating func forgetAll() { clients.removeAll() }

    public func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(self)
    }

    public static func decoded(from data: Data) throws -> TrustStore {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(TrustStore.self, from: data)
    }
}

// MARK: - Hex helpers

public extension Data {
    var hexString: String {
        map { String(format: "%02x", $0) }.joined()
    }

    init?(hexString: String) {
        let chars = Array(hexString)
        guard chars.count % 2 == 0 else { return nil }
        var bytes = [UInt8]()
        bytes.reserveCapacity(chars.count / 2)
        var index = 0
        while index < chars.count {
            guard let byte = UInt8(String(chars[index...index + 1]), radix: 16) else { return nil }
            bytes.append(byte)
            index += 2
        }
        self = Data(bytes)
    }
}
