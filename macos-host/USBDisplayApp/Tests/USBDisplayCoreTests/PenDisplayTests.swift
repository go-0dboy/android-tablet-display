import XCTest
@testable import USBDisplayCore

final class PenDisplayTests: XCTestCase {

    /// "WAC" is Wacom's registered PNP id; the packing is the EDID standard's.
    func testWacomEDIDVendorDecodesToWAC() {
        XCTAssertEqual(PenDisplayVendor.edidLetters(PenDisplayVendor.wacomEDID), "WAC")
        XCTAssertEqual(PenDisplayVendor.wacomEDID, 0x5C23)
    }

    func testKnownVendorsDecodeCorrectly() {
        // APP = Apple: A=1, P=16, P=16
        let apple: UInt32 = (1 << 10) | (16 << 5) | 16
        XCTAssertEqual(PenDisplayVendor.edidLetters(apple), "APP")
    }

    func testWacomPanelIsRecognisedByEDIDVendor() {
        let identity = DisplayIdentity(vendorNumber: PenDisplayVendor.wacomEDID,
                                       modelNumber: 0x1234, name: "",
                                       pixelWidth: 1920, pixelHeight: 1080)
        XCTAssertTrue(PenDisplayIdentifier.classify(identity).isPenDisplay)
    }

    func testMovinkIsRecognisedByName() {
        let identity = DisplayIdentity(vendorNumber: 0, modelNumber: 0,
                                       name: "Wacom Movink 13",
                                       pixelWidth: 1920, pixelHeight: 1080)
        XCTAssertEqual(PenDisplayIdentifier.classify(identity), .wacomMovink)
    }

    /// The trap this guards: 1920x1080 is the commonest resolution there is.
    /// An ordinary monitor must not be mistaken for a Movink just because it
    /// is 1080p.
    func testOrdinary1080pMonitorIsNotMistakenForAMovink() {
        let identity = DisplayIdentity(vendorNumber: 0x1E6D, modelNumber: 0x5B11,
                                       name: "LG ULTRAGEAR+",
                                       pixelWidth: 1920, pixelHeight: 1080)
        XCTAssertEqual(PenDisplayIdentifier.classify(identity), .other)
        // Even with a Movink elsewhere on the bus, an LG panel is not it.
        XCTAssertEqual(PenDisplayIdentifier.classify(identity, movinkOnUSB: true), .other)
    }

    /// With the Movink's USB device present, a matching anonymous 1080p panel
    /// is the Movink.
    func testResolutionMatchCountsOnlyWhenTheUSBDeviceIsPresent() {
        let identity = DisplayIdentity(vendorNumber: 0, modelNumber: 0, name: "",
                                       pixelWidth: 1920, pixelHeight: 1080)
        XCTAssertEqual(PenDisplayIdentifier.classify(identity), .other)
        XCTAssertEqual(PenDisplayIdentifier.classify(identity, movinkOnUSB: true),
                       .wacomMovink)
    }

    func testOurOwnVirtualDisplayIsNotAPenDisplay() {
        let identity = DisplayIdentity(vendorNumber: 0x1234, modelNumber: 0x5678,
                                       name: "Android Tablet Display",
                                       pixelWidth: 2560, pixelHeight: 1600)
        XCTAssertEqual(PenDisplayIdentifier.classify(identity), .virtualDisplay)
        XCTAssertFalse(PenDisplayIdentifier.classify(identity).isPenDisplay)
    }

    /// A preset key must be stable across replugs but must not contain
    /// anything device-unique that we would rather not write to disk.
    func testPresetKeyIsStableAndCarriesNoSerial() {
        let a = DisplayIdentity(vendorNumber: 0x5C23, modelNumber: 0x0100,
                                name: "Wacom Movink 13", pixelWidth: 1920, pixelHeight: 1080)
        let b = DisplayIdentity(vendorNumber: 0x5C23, modelNumber: 0x0100,
                                name: "Wacom Movink 13", pixelWidth: 1920, pixelHeight: 1080)
        XCTAssertEqual(a.presetKey, b.presetKey)
        XCTAssertFalse(a.presetKey.lowercased().contains("serial"))
    }

    func testPresetsRoundTripThroughJSON() throws {
        var store = DisplayPresetStore()
        let identity = DisplayIdentity(vendorNumber: 0x5C23, modelNumber: 0x0100,
                                       name: "Wacom Movink 13",
                                       pixelWidth: 1920, pixelHeight: 1080)
        store.save(DisplayPresetStore.defaultMovinkPreset(originX: 2560), for: identity)

        let restored = try DisplayPresetStore.decoded(from: store.encoded())
        XCTAssertEqual(restored, store)
        XCTAssertEqual(restored.preset(for: identity)?.originX, 2560)
        XCTAssertTrue(restored.preset(for: identity)?.penMappedToThisDisplayOnly ?? false)
    }

    /// The default preset must not steal the menu bar from the user's main
    /// screen — an unasked-for change like that is how an app gets deleted.
    func testDefaultMovinkPresetDoesNotStealMainDisplay() {
        let preset = DisplayPresetStore.defaultMovinkPreset(originX: 0)
        XCTAssertFalse(preset.isMainDisplay)
        XCTAssertTrue(preset.isValid)
        XCTAssertEqual(preset.rotationDegrees, 0)
    }

    /// The Movink's panel is 1080p at ~166 ppi, so the native 1:1 mode is
    /// right; a 2x mode would waste half the panel.
    func testDefaultMovinkPresetUsesNativeResolution() {
        let preset = DisplayPresetStore.defaultMovinkPreset(originX: 0)
        XCTAssertEqual(preset.pixelWidth, 1920)
        XCTAssertEqual(preset.pixelHeight, 1080)
        XCTAssertEqual(preset.pointWidth, 1920)
        XCTAssertEqual(preset.pointHeight, 1080)
    }

    func testInvalidRotationIsRejected() {
        var preset = DisplayPresetStore.defaultMovinkPreset(originX: 0)
        preset.rotationDegrees = 45
        XCTAssertFalse(preset.isValid)
        preset.rotationDegrees = 270
        XCTAssertTrue(preset.isValid)
    }

    func testRemovingAPresetWorks() {
        var store = DisplayPresetStore()
        let identity = DisplayIdentity(vendorNumber: 1, modelNumber: 2, name: "x",
                                       pixelWidth: 100, pixelHeight: 100)
        store.save(DisplayPreset(), for: identity)
        XCTAssertNotNil(store.preset(for: identity))
        store.remove(for: identity)
        XCTAssertNil(store.preset(for: identity))
    }
}
