// Wireless.swift — finding the host on a Wi-Fi network, and deciding whether
// to trust the device that turns up.
//
// USB stays the default. Wireless is an explicit choice in both apps, because
// it trades latency for freedom and the person should be the one making that
// trade knowingly.
//
// Discovery is Bonjour: the host advertises _usbtablet._tcp with the video
// port in its TXT record, and the client browses for it. That removes the "type
// in the Mac's IP address" step, which is the part people give up at.

import Foundation
import Network
import USBDisplayCore

/// Advertises the host on the local network.
final class BonjourAdvertiser: NSObject, NetServiceDelegate {
    static let serviceType = "_usbtablet._tcp"

    private var service: NetService?
    private(set) var isAdvertising = false
    var onError: ((String) -> Void)?

    /// - Parameters:
    ///   - name: what the client shows in its list. The Mac's user-visible
    ///     computer name, not its hostname or anything account-derived.
    func start(name: String, videoPort: UInt16, inputPort: UInt16) {
        stop()

        let service = NetService(domain: "local.", type: Self.serviceType,
                                 name: name, port: Int32(videoPort))
        service.delegate = self

        let record: [String: Data] = [
            "v": Data(String(WireProtocol.version).utf8),
            "video": Data(String(videoPort).utf8),
            "input": Data(String(inputPort).utf8)
        ]
        service.setTXTRecord(NetService.data(fromTXTRecord: record))
        service.publish()

        self.service = service
        log("Advertising “\(name)” on the network as \(Self.serviceType) port \(videoPort)")
    }

    func stop() {
        service?.stop()
        service = nil
        isAdvertising = false
    }

    func netServiceDidPublish(_ sender: NetService) {
        isAdvertising = true
        log("Bonjour advertisement is live")
    }

    func netService(_ sender: NetService, didNotPublish errorDict: [String: NSNumber]) {
        isAdvertising = false
        let code = errorDict[NetService.errorCode]?.intValue ?? -1
        let message = "Could not advertise on the network (Bonjour error \(code)). "
            + "Check that Local Network access is allowed for this app in "
            + "System Settings > Privacy & Security > Local Network."
        log(message)
        onError?(message)
    }
}

/// The host's side of pairing: who is allowed to receive the screen.
@MainActor
final class PairingController {

    /// A pairing waiting for the person to confirm the code.
    struct PendingPairing {
        var deviceName: String
        var clientKey: Data
        var code: String
        var expectedProof: Data
    }

    private(set) var trustStore = TrustStore()
    private(set) var pending: PendingPairing?
    private let storeURL: URL
    private let identityURL: URL

    /// This host's long-lived identity. Generated once.
    private(set) var identity: PairingIdentity

    /// Called when a device needs the person to compare a code.
    var onPairingNeedsConfirmation: ((PendingPairing) -> Void)?
    /// Called when the session becomes authenticated (or fails).
    var onAuthenticationResult: ((Bool, String) -> Void)?

    init() {
        let support = FileManager.default.urls(for: .applicationSupportDirectory,
                                               in: .userDomainMask)[0]
            .appendingPathComponent("USBTabletDisplay", isDirectory: true)
        try? FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        storeURL = support.appendingPathComponent("trusted-devices.json")
        identityURL = support.appendingPathComponent("host-identity.bin")

        if let data = try? Data(contentsOf: identityURL), data.count == 32 {
            identity = PairingIdentity(key: data)
        } else {
            identity = PairingIdentity.generate()
            // Owner-only: this key is what proves this Mac's identity.
            try? identity.key.write(to: identityURL, options: [.atomic, .completeFileProtection])
            try? FileManager.default.setAttributes([.posixPermissions: 0o600],
                                                   ofItemAtPath: identityURL.path)
        }

        if let data = try? Data(contentsOf: storeURL),
           let decoded = try? TrustStore.decoded(from: data) {
            trustStore = decoded
        }
    }

    private func save() {
        guard let data = try? trustStore.encoded() else { return }
        try? data.write(to: storeURL, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600],
                                               ofItemAtPath: storeURL.path)
    }

    /// Handle a client's opening request. Returns the response to send back.
    func handle(request: PairRequest, wirelessEnabled: Bool) -> PairResponse {
        guard wirelessEnabled else {
            log("Refused a wireless pairing request: wireless mode is off")
            return PairResponse(hostKey: identity.key,
                                hostNonce: PairingNonce.generate().bytes,
                                status: .rejected, hostName: Self.hostName)
        }
        guard request.clientKey.count == 32, request.clientNonce.count == 16 else {
            log("Refused a malformed pairing request")
            return PairResponse(hostKey: identity.key,
                                hostNonce: PairingNonce.generate().bytes,
                                status: .rejected, hostName: Self.hostName)
        }

        let hostNonce = PairingNonce.generate()
        let clientNonce = PairingNonce(bytes: request.clientNonce)
        let expectedProof = Pairing.sessionProof(clientKey: request.clientKey,
                                                 clientNonce: clientNonce,
                                                 hostNonce: hostNonce)

        if trustStore.isTrusted(key: request.clientKey) {
            pending = PendingPairing(deviceName: request.deviceName,
                                     clientKey: request.clientKey,
                                     code: "", expectedProof: expectedProof)
            log("Known device “\(request.deviceName)” reconnecting; no confirmation needed")
            return PairResponse(hostKey: identity.key, hostNonce: hostNonce.bytes,
                                status: .alreadyTrusted, hostName: Self.hostName)
        }

        let code = Pairing.shortCode(clientNonce: clientNonce, hostNonce: hostNonce,
                                     clientKey: request.clientKey, hostKey: identity.key)
        let pendingPairing = PendingPairing(deviceName: request.deviceName,
                                            clientKey: request.clientKey,
                                            code: code, expectedProof: expectedProof)
        pending = pendingPairing
        log("New device “\(request.deviceName)” wants to pair. Code: \(code)")
        onPairingNeedsConfirmation?(pendingPairing)

        return PairResponse(hostKey: identity.key, hostNonce: hostNonce.bytes,
                            status: .needsConfirmation, hostName: Self.hostName)
    }

    /// Check a returning client's proof.
    func verify(proof: PairProof) -> Bool {
        guard let pending else { return false }
        guard Pairing.verify(proof: proof.proof, matches: pending.expectedProof) else {
            log("A device failed to prove it holds the paired key; refusing it")
            onAuthenticationResult?(false, "The device could not prove it is paired.")
            return false
        }
        guard trustStore.isTrusted(key: pending.clientKey) else {
            log("Proof is valid but the device is not confirmed yet")
            return false
        }
        trustStore.trust(name: pending.deviceName, key: pending.clientKey)
        save()
        onAuthenticationResult?(true, pending.deviceName)
        return true
    }

    /// The person clicked "these codes match".
    func confirmPending() -> Bool {
        guard let pending else { return false }
        trustStore.trust(name: pending.deviceName, key: pending.clientKey)
        save()
        log("Paired with “\(pending.deviceName)” (\(pending.clientKey.hexString.prefix(8)))")
        return true
    }

    func rejectPending() {
        if let pending { log("Refused to pair with “\(pending.deviceName)”") }
        pending = nil
    }

    func forget(_ client: TrustedClient) {
        trustStore.forget(keyHex: client.keyHex)
        save()
        log("Forgot “\(client.name)”. It will have to pair again.")
    }

    func forgetAll() {
        trustStore.forgetAll()
        save()
        log("Forgot every paired device.")
    }

    /// The Mac's user-visible name. Falls back to something generic rather
    /// than to a hostname, which often carries the owner's real name.
    static var hostName: String {
        let name = Host.current().localizedName ?? ""
        return name.isEmpty ? "Mac" : name
    }
}
