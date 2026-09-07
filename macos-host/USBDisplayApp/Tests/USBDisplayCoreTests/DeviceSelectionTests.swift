import XCTest
@testable import USBDisplayCore

final class ADBOutputParserTests: XCTestCase {

    /// Real `adb devices -l` output, with the serials replaced.
    private let realOutput = """
    List of devices attached
    R5CXXXXXXXX            device product:a56xnsxx model:SM_S931B device:a56x transport_id:2
    emulator-5554          device product:sdk_gphone64_arm64 model:sdk_gphone64_arm64 device:emu64a transport_id:1

    """

    func testParsesModelAndProduct() {
        let devices = ADBOutputParser.parseDevices(realOutput)
        XCTAssertEqual(devices.count, 2)

        let phone = devices[0]
        XCTAssertEqual(phone.state, .device)
        XCTAssertEqual(phone.transport, .usb)
        XCTAssertEqual(phone.model, "SM_S931B")
        XCTAssertTrue(phone.isProbablySamsung)

        let emulator = devices[1]
        XCTAssertEqual(emulator.transport, .emulator)
        XCTAssertFalse(emulator.isProbablySamsung)
    }

    /// The bug: v1 took the first "\tdevice" line, which on this machine is
    /// the emulator. A real phone on the cable must always win.
    func testRealPhoneBeatsEmulator() {
        let devices = ADBOutputParser.parseDevices(realOutput)
        let chosen = ADBOutputParser.selectDevice(from: devices)
        XCTAssertEqual(chosen?.model, "SM_S931B")
        XCTAssertEqual(chosen?.transport, .usb)
    }

    func testEmulatorIsUsedWhenItIsTheOnlyDevice() {
        let output = """
        List of devices attached
        emulator-5554          device product:sdk_gphone64_arm64 model:sdk_gphone64_arm64 device:emu64a
        """
        let chosen = ADBOutputParser.selectDevice(from: ADBOutputParser.parseDevices(output))
        XCTAssertEqual(chosen?.transport, .emulator)
    }

    func testPinnedSerialWins() {
        let devices = ADBOutputParser.parseDevices(realOutput)
        let chosen = ADBOutputParser.selectDevice(from: devices,
                                                  preferredSerial: "emulator-5554")
        XCTAssertEqual(chosen?.serial, "emulator-5554")
    }

    func testPinnedSerialThatIsNotReadyFallsBack() {
        let devices = ADBOutputParser.parseDevices(realOutput)
        let chosen = ADBOutputParser.selectDevice(from: devices,
                                                  preferredSerial: "not-attached")
        XCTAssertEqual(chosen?.model, "SM_S931B")
    }

    func testUnauthorizedDeviceIsNeverSelectedButIsReported() {
        let output = """
        List of devices attached
        ABC123                 unauthorized
        """
        let devices = ADBOutputParser.parseDevices(output)
        XCTAssertNil(ADBOutputParser.selectDevice(from: devices))
        XCTAssertEqual(ADBOutputParser.blockedDevices(from: devices).count, 1)
        XCTAssertEqual(ADBOutputParser.blockedDevices(from: devices).first?.state,
                       .unauthorized)
    }

    func testOfflineDeviceIsNotSelected() {
        let output = """
        List of devices attached
        ABC123                 offline
        emulator-5554          device
        """
        let devices = ADBOutputParser.parseDevices(output)
        XCTAssertEqual(ADBOutputParser.selectDevice(from: devices)?.serial, "emulator-5554")
    }

    func testWirelessAdbSerialIsRecognised() {
        let output = """
        List of devices attached
        192.168.1.44:5555      device product:a56x model:SM_S931B device:a56x
        """
        let devices = ADBOutputParser.parseDevices(output)
        XCTAssertEqual(devices.first?.transport, .network)
    }

    /// A USB phone should beat a Wi-Fi connection to the same phone.
    func testUSBBeatsNetwork() {
        let output = """
        List of devices attached
        192.168.1.44:5555      device model:SM_S931B
        R5CXXXXXXXX            device model:SM_S931B
        """
        let devices = ADBOutputParser.parseDevices(output)
        XCTAssertEqual(ADBOutputParser.selectDevice(from: devices)?.transport, .usb)
    }

    func testEmptyAndNoisyOutputDoesNotCrash() {
        XCTAssertTrue(ADBOutputParser.parseDevices("").isEmpty)
        XCTAssertTrue(ADBOutputParser.parseDevices("List of devices attached\n\n").isEmpty)
        let noisy = """
        * daemon not running; starting now at tcp:5037
        * daemon started successfully
        List of devices attached

        """
        XCTAssertTrue(ADBOutputParser.parseDevices(noisy).isEmpty)
    }

    /// Labels go in the menu and in logs that get pasted into bug reports, so
    /// a model name is preferred over the serial.
    func testDisplayLabelPrefersModelOverSerial() {
        let device = AndroidDevice(serial: "R5CXXXXXXXX", state: .device,
                                   transport: .usb, model: "SM_S931B")
        XCTAssertEqual(device.displayLabel, "SM S931B")
        XCTAssertFalse(device.displayLabel.contains("R5C"))
    }

    func testDisplayLabelFallsBackToSerialWhenModelIsUnknown() {
        let device = AndroidDevice(serial: "ABC123", state: .device, transport: .usb)
        XCTAssertEqual(device.displayLabel, "ABC123")
    }
}

final class DisplayGeometryTests: XCTestCase {

    /// A high-density tablet must get a HiDPI display, not a 1:1 desktop that
    /// renders everything at half size. This is the v1 bug.
    func testHighDensityTabletGetsHiDPI() {
        let hello = ClientHello(widthPixels: 2560, heightPixels: 1600, densityDpi: 320,
                                rotationDegrees: 0, flags: [], deviceName: "Tab S9")
        let spec = DisplayGeometry.spec(for: hello)
        XCTAssertTrue(spec.hiDPI)
        XCTAssertEqual(spec.pixelWidth, 2560)
        XCTAssertEqual(spec.pointWidth, 1280)
        XCTAssertEqual(spec.pointHeight, 800)
        XCTAssertEqual(spec.ppi, 320)
    }

    func testLowDensityDisplayStaysOneToOne() {
        let hello = ClientHello(widthPixels: 1920, heightPixels: 1080, densityDpi: 160,
                                rotationDegrees: 0, flags: [], deviceName: "cheap tablet")
        let spec = DisplayGeometry.spec(for: hello)
        XCTAssertFalse(spec.hiDPI)
        XCTAssertEqual(spec.pointWidth, spec.pixelWidth)
    }

    /// Encoders and Samsung's decoder want dimensions on a 16-pixel grid.
    func testDimensionsAreAlignedForTheEncoder() {
        let hello = ClientHello(widthPixels: 1439, heightPixels: 899, densityDpi: 160,
                                rotationDegrees: 0, flags: [], deviceName: "odd")
        let spec = DisplayGeometry.spec(for: hello)
        XCTAssertEqual(spec.pixelWidth % 16, 0)
        XCTAssertEqual(spec.pixelHeight % 16, 0)
        XCTAssertLessThanOrEqual(spec.pixelWidth, 1439)
    }

    func testPortraitMetricsWithLandscapeRotationAreSwapped() {
        let hello = ClientHello(widthPixels: 1600, heightPixels: 2560, densityDpi: 320,
                                rotationDegrees: 90, flags: [], deviceName: "rotated")
        let spec = DisplayGeometry.spec(for: hello)
        XCTAssertEqual(spec.pixelWidth, 2560)
        XCTAssertEqual(spec.pixelHeight, 1600)
    }

    /// A client that already reported post-rotation metrics must be left alone.
    func testAlreadyLandscapeMetricsAreNotSwappedTwice() {
        let hello = ClientHello(widthPixels: 2560, heightPixels: 1600, densityDpi: 320,
                                rotationDegrees: 90, flags: [], deviceName: "rotated")
        let spec = DisplayGeometry.spec(for: hello)
        XCTAssertEqual(spec.pixelWidth, 2560)
        XCTAssertEqual(spec.pixelHeight, 1600)
    }

    /// A client cannot talk the host into an encoder size it cannot sustain.
    func testAbsurdDimensionsAreClamped() {
        let hello = ClientHello(widthPixels: 99999, heightPixels: 99999, densityDpi: 640,
                                rotationDegrees: 0, flags: [], deviceName: "liar")
        let spec = DisplayGeometry.spec(for: hello)
        XCTAssertLessThanOrEqual(spec.pixelWidth, 4096)
        XCTAssertLessThanOrEqual(spec.pixelHeight, 4096)
    }

    func testTinyDimensionsAreRaisedToAUsableFloor() {
        let hello = ClientHello(widthPixels: 4, heightPixels: 4, densityDpi: 160,
                                rotationDegrees: 0, flags: [], deviceName: "tiny")
        let spec = DisplayGeometry.spec(for: hello)
        XCTAssertGreaterThanOrEqual(spec.pixelWidth, 640)
        XCTAssertGreaterThanOrEqual(spec.pixelHeight, 480)
    }

    func testZeroDensityDoesNotProduceADivideByZeroSize() {
        let hello = ClientHello(widthPixels: 1920, heightPixels: 1080, densityDpi: 0,
                                rotationDegrees: 0, flags: [], deviceName: "no dpi")
        let spec = DisplayGeometry.spec(for: hello)
        XCTAssertGreaterThan(spec.ppi, 0)
        XCTAssertTrue(spec.physicalWidthMM.isFinite)
        XCTAssertGreaterThan(spec.physicalWidthMM, 0)
    }

    /// The Displays pane should say what the thing is. It must never say the
    /// serial number.
    func testDisplayNameIsFriendlyAndBounded() {
        XCTAssertEqual(DisplayGeometry.displayName(for: "SM_S931B"), "SM S931B")
        XCTAssertEqual(DisplayGeometry.displayName(for: "   "), "Android Tablet Display")
        XCTAssertEqual(DisplayGeometry.displayName(for: ""), "Android Tablet Display")
        XCTAssertLessThanOrEqual(
            DisplayGeometry.displayName(for: String(repeating: "x", count: 200)).count, 40)
    }
}

final class ScalePreferenceTests: XCTestCase {

    /// A 14-inch tablet at 2560x1600 is the case the automatic rule is least
    /// sure about, so the person must be able to overrule it in both
    /// directions.
    private let tablet = ClientHello(widthPixels: 2560, heightPixels: 1600,
                                     densityDpi: 240, rotationDegrees: 0,
                                     flags: [], deviceName: "14-inch tablet")

    func testMoreSpaceGivesTheFullNativeDesktop() {
        let spec = DisplayGeometry.spec(for: tablet, scale: .moreSpace)
        XCTAssertFalse(spec.hiDPI)
        XCTAssertEqual(spec.pointWidth, 2560)
        XCTAssertEqual(spec.pointHeight, 1600)
    }

    func testLargerTextGivesAHiDPIDesktop() {
        let spec = DisplayGeometry.spec(for: tablet, scale: .largerText)
        XCTAssertTrue(spec.hiDPI)
        XCTAssertEqual(spec.pointWidth, 1280)
        XCTAssertEqual(spec.pixelWidth, 2560)
    }

    func testAutomaticStillFollowsDensity() {
        XCTAssertTrue(DisplayGeometry.spec(for: tablet, scale: .automatic).hiDPI)

        let lowDensity = ClientHello(widthPixels: 1920, heightPixels: 1080,
                                     densityDpi: 140, rotationDegrees: 0,
                                     flags: [], deviceName: "low dpi")
        XCTAssertFalse(DisplayGeometry.spec(for: lowDensity, scale: .automatic).hiDPI)
    }

    /// Whatever the preference, the backing store must not change — only how
    /// macOS lays the desktop out on it.
    func testScaleNeverChangesTheBackingStore() {
        for preference in ScalePreference.allCases {
            let spec = DisplayGeometry.spec(for: tablet, scale: preference)
            XCTAssertEqual(spec.pixelWidth, 2560, "\(preference) changed the backing store")
            XCTAssertEqual(spec.pixelHeight, 1600)
        }
    }

    /// Forcing HiDPI on a small panel must not produce an unusably tiny desktop.
    func testLargerTextOnASmallPanelStaysUsable() {
        let phone = ClientHello(widthPixels: 720, heightPixels: 480, densityDpi: 160,
                                rotationDegrees: 0, flags: [], deviceName: "small")
        let spec = DisplayGeometry.spec(for: phone, scale: .largerText)
        XCTAssertGreaterThanOrEqual(spec.pointWidth, 320)
        XCTAssertGreaterThanOrEqual(spec.pointHeight, 240)
    }
}
