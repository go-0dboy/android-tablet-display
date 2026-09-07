import XCTest
@testable import USBDisplayCore

final class PairingTests: XCTestCase {

    private let clientKey = Data(repeating: 0xA1, count: 32)
    private let hostKey = Data(repeating: 0xB2, count: 32)
    private let clientNonce = PairingNonce(bytes: Data(repeating: 0x01, count: 16))
    private let hostNonce = PairingNonce(bytes: Data(repeating: 0x02, count: 16))

    /// Both ends must derive the same digits from the same inputs, or nobody
    /// can ever pair.
    func testShortCodeIsDeterministic() {
        let a = Pairing.shortCode(clientNonce: clientNonce, hostNonce: hostNonce,
                                  clientKey: clientKey, hostKey: hostKey)
        let b = Pairing.shortCode(clientNonce: clientNonce, hostNonce: hostNonce,
                                  clientKey: clientKey, hostKey: hostKey)
        XCTAssertEqual(a, b)
        XCTAssertEqual(a.count, Pairing.codeDigits)
        XCTAssertTrue(a.allSatisfy(\.isNumber))
    }

    /// The code exists to catch a machine-in-the-middle, so changing any input
    /// must change the digits.
    func testShortCodeChangesWithEveryInput() {
        let base = Pairing.shortCode(clientNonce: clientNonce, hostNonce: hostNonce,
                                     clientKey: clientKey, hostKey: hostKey)
        let otherClientNonce = Pairing.shortCode(
            clientNonce: PairingNonce(bytes: Data(repeating: 0x09, count: 16)),
            hostNonce: hostNonce, clientKey: clientKey, hostKey: hostKey)
        let otherHostNonce = Pairing.shortCode(
            clientNonce: clientNonce,
            hostNonce: PairingNonce(bytes: Data(repeating: 0x09, count: 16)),
            clientKey: clientKey, hostKey: hostKey)
        let otherClientKey = Pairing.shortCode(
            clientNonce: clientNonce, hostNonce: hostNonce,
            clientKey: Data(repeating: 0x09, count: 32), hostKey: hostKey)

        XCTAssertNotEqual(base, otherClientNonce)
        XCTAssertNotEqual(base, otherHostNonce)
        XCTAssertNotEqual(base, otherClientKey)
    }

    /// Swapping the roles must not produce the same code, or the ordering
    /// convention is not actually pinned down.
    func testShortCodeIsOrderSensitive() {
        let forward = Pairing.shortCode(clientNonce: clientNonce, hostNonce: hostNonce,
                                        clientKey: clientKey, hostKey: hostKey)
        let reversed = Pairing.shortCode(clientNonce: hostNonce, hostNonce: clientNonce,
                                         clientKey: hostKey, hostKey: clientKey)
        XCTAssertNotEqual(forward, reversed)
    }

    /// Codes must be spread across the range, not clustered — a code that is
    /// always "000123" authenticates nothing.
    func testShortCodesAreWellDistributed() {
        var seen = Set<String>()
        for _ in 0..<500 {
            seen.insert(Pairing.shortCode(clientNonce: PairingNonce.generate(),
                                          hostNonce: PairingNonce.generate(),
                                          clientKey: PairingIdentity.generate().key,
                                          hostKey: hostKey))
        }
        // With 10^6 possible codes, 500 draws should essentially never collide.
        XCTAssertGreaterThan(seen.count, 495)
    }

    func testSessionProofVerifies() {
        let proof = Pairing.sessionProof(clientKey: clientKey, clientNonce: clientNonce,
                                         hostNonce: hostNonce)
        let expected = Pairing.sessionProof(clientKey: clientKey, clientNonce: clientNonce,
                                            hostNonce: hostNonce)
        XCTAssertTrue(Pairing.verify(proof: proof, matches: expected))
    }

    /// A device that does not hold the key must not get in.
    func testSessionProofFailsWithTheWrongKey() {
        let good = Pairing.sessionProof(clientKey: clientKey, clientNonce: clientNonce,
                                        hostNonce: hostNonce)
        let bad = Pairing.sessionProof(clientKey: Data(repeating: 0xFF, count: 32),
                                       clientNonce: clientNonce, hostNonce: hostNonce)
        XCTAssertFalse(Pairing.verify(proof: bad, matches: good))
    }

    /// Replaying an old proof against a fresh host nonce must fail, or
    /// wireless mode is trivially replayable.
    func testSessionProofIsNonceBound() {
        let old = Pairing.sessionProof(clientKey: clientKey, clientNonce: clientNonce,
                                       hostNonce: hostNonce)
        let fresh = Pairing.sessionProof(clientKey: clientKey, clientNonce: clientNonce,
                                         hostNonce: PairingNonce.generate())
        XCTAssertFalse(Pairing.verify(proof: old, matches: fresh))
    }

    func testVerifyRejectsEmptyAndMismatchedLengths() {
        XCTAssertFalse(Pairing.verify(proof: Data(), matches: Data()))
        XCTAssertFalse(Pairing.verify(proof: Data([1, 2]), matches: Data([1, 2, 3])))
    }

    func testGeneratedIdentitiesAreDistinct() {
        let a = PairingIdentity.generate()
        let b = PairingIdentity.generate()
        XCTAssertNotEqual(a.key, b.key)
        XCTAssertEqual(a.key.count, 32)
        XCTAssertNotEqual(a.fingerprint, b.fingerprint)
        XCTAssertEqual(a.fingerprint.count, 8)
    }

    func testTrustStoreRoundTrips() throws {
        var store = TrustStore()
        let key = PairingIdentity.generate().key
        store.trust(name: "Galaxy S25", key: key)
        XCTAssertTrue(store.isTrusted(key: key))

        let restored = try TrustStore.decoded(from: store.encoded())
        XCTAssertTrue(restored.isTrusted(key: key))
        XCTAssertEqual(restored.clients.first?.name, "Galaxy S25")
    }

    func testTrustingTheSameDeviceTwiceDoesNotDuplicateIt() {
        var store = TrustStore()
        let key = PairingIdentity.generate().key
        store.trust(name: "Phone", key: key)
        store.trust(name: "Phone renamed", key: key)
        XCTAssertEqual(store.clients.count, 1)
        XCTAssertEqual(store.clients.first?.name, "Phone renamed")
    }

    func testForgettingADeviceRevokesIt() {
        var store = TrustStore()
        let key = PairingIdentity.generate().key
        store.trust(name: "Phone", key: key)
        store.forget(keyHex: key.hexString)
        XCTAssertFalse(store.isTrusted(key: key))
    }

    func testUnknownKeyIsNotTrusted() {
        var store = TrustStore()
        store.trust(name: "Phone", key: PairingIdentity.generate().key)
        XCTAssertFalse(store.isTrusted(key: PairingIdentity.generate().key))
    }

    func testHexRoundTrip() {
        let data = Data([0x00, 0x0F, 0xA5, 0xFF])
        XCTAssertEqual(data.hexString, "000fa5ff")
        XCTAssertEqual(Data(hexString: "000fa5ff"), data)
        XCTAssertNil(Data(hexString: "abc"))     // odd length
        XCTAssertNil(Data(hexString: "zzzz"))    // not hex
    }
}
