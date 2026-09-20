import Foundation
import CoreGraphics
import VirtualDisplay
import USBDisplayCore

/// Thread-safe statistics collected from encoder callbacks.
private final class CaptureProbeStats {
    private let lock = NSLock()

    private var frameCount = 0
    private var keyframeCount = 0
    private var byteCount = 0
    private var sawAnnexB = false
    private var streamError: String?

    func recordFrame(_ data: Data, keyframe: Bool) {
        lock.lock()
        defer { lock.unlock() }

        frameCount += 1
        byteCount += data.count

        if keyframe {
            keyframeCount += 1
        }

        if data.count >= 4 {
            let prefix = Array(data.prefix(4))
            if prefix == [0x00, 0x00, 0x00, 0x01] {
                sawAnnexB = true
            }
        }
    }

    func recordError(_ error: Error) {
        lock.lock()
        streamError = error.localizedDescription
        lock.unlock()
    }

    func snapshot() -> (
        frames: Int,
        keyframes: Int,
        bytes: Int,
        annexB: Bool,
        error: String?
    ) {
        lock.lock()
        defer { lock.unlock() }

        return (
            frameCount,
            keyframeCount,
            byteCount,
            sawAnnexB,
            streamError
        )
    }
}

@MainActor
enum CaptureProbe {

    private static func activeDisplays()
        -> [(id: CGDirectDisplayID, bounds: CGRect)] {

        var count: UInt32 = 0

        guard CGGetActiveDisplayList(0, nil, &count) == .success,
              count > 0 else {
            return []
        }

        var ids = [CGDirectDisplayID](
            repeating: 0,
            count: Int(count)
        )

        guard CGGetActiveDisplayList(
            count,
            &ids,
            &count
        ) == .success else {
            return []
        }

        return ids.prefix(Int(count)).map {
            ($0, CGDisplayBounds($0))
        }
    }

    private static func describe(
        _ displays: [(id: CGDirectDisplayID, bounds: CGRect)]
    ) -> String {
        displays.map {
            "\($0.id)(\(Int($0.bounds.width))x\(Int($0.bounds.height)))"
        }
        .joined(separator: " ")
    }

    static func run() async -> Int {

        print("=== captureprobe: Monterey capture -> H.264 check ===")

        let os = ProcessInfo.processInfo.operatingSystemVersion

        print(
            "macOS         : "
            + "\(os.majorVersion).\(os.minorVersion).\(os.patchVersion)"
        )

        #if arch(arm64)
        print("architecture  : arm64 (Apple Silicon)")
        #else
        print("architecture  : x86_64 (Intel)")
        #endif

        // ------------------------------------------------------------
        // 1. Verify private virtual-display API.
        // ------------------------------------------------------------

        let missing = VirtualDisplayManager.missingPrivateClasses()

        guard missing.isEmpty else {
            print(
                "private API   : MISSING -> "
                + missing.joined(separator: ", ")
            )
            print("")
            print("RESULT: FAIL. Virtual-display API is unavailable.")
            return 2
        }

        print("private API   : available")

        let before = activeDisplays()

        print(
            "displays before: \(before.count) -> "
            + describe(before)
        )

        // ------------------------------------------------------------
        // 2. Create the same kind of virtual display the app uses.
        // ------------------------------------------------------------

        let hello = ClientHello(
            widthPixels: 1280,
            heightPixels: 800,
            densityDpi: 160,
            rotationDegrees: 0,
            flags: [],
            deviceName: "captureprobe"
        )

        let spec = DisplayGeometry.spec(for: hello)

        print(
            "requesting    : "
            + "\(spec.pixelWidth)x\(spec.pixelHeight) px / "
            + "\(spec.pointWidth)x\(spec.pointHeight) pt"
        )

        let manager = VirtualDisplayManager()

        let parameters = VirtualDisplayParameters.make(
            pixelWidth: Int32(spec.pixelWidth),
            pixelHeight: Int32(spec.pixelHeight),
            pointWidth: Int32(spec.pointWidth),
            pointHeight: Int32(spec.pointHeight),
            ppi: Int32(spec.ppi),
            hiDPI: spec.hiDPI,
            refreshRate: spec.refreshRate,
            name: "captureprobe test display"
        )

        // Keep a separate identity from vdprobe and the real app.
        parameters.productID = 0x567A
        parameters.serialNum = 0x9002

        var needsDestroy = false

        defer {
            if needsDestroy {
                manager.destroyDisplay()
            }
        }

        guard manager.createDisplay(spec: parameters) else {
            print("create        : REFUSED")
            print("reason        : \(manager.lastError ?? "unknown")")
            print("")
            print("RESULT: FAIL. Could not create virtual display.")
            return 3
        }

        needsDestroy = true

        let displayID = manager.displayID

        print("create        : OK, displayID=\(displayID)")

        // Give WindowServer time to publish the new display.
        try? await Task.sleep(nanoseconds: 1_500_000_000)

        let afterCreate = activeDisplays()

        print(
            "displays after : \(afterCreate.count) -> "
            + describe(afterCreate)
        )

        guard displayID != 0,
              afterCreate.contains(where: { $0.id == displayID }) else {

            print("")
            print("RESULT: FAIL. Virtual display never became active.")
            return 4
        }

        // ------------------------------------------------------------
        // 3. Start the real Monterey capture implementation.
        // ------------------------------------------------------------

        let capturer = CGDisplayStreamCapturer()
        let stats = CaptureProbeStats()

        capturer.onEncodedFrame = { data, isKeyframe in
            stats.recordFrame(data, keyframe: isKeyframe)
        }

        capturer.onStreamError = { error in
            stats.recordError(error)
        }

        let settings = EncoderSettings(
            width: Int32(spec.pixelWidth),
            height: Int32(spec.pixelHeight),
            frameRate: 30,
            bitRate: 4_000_000,
            codec: .h264
        )

        do {
            try await capturer.start(
                displayID: displayID,
                settings: settings
            )
        } catch {
            print("capture       : FAILED")
            print("reason        : \(error.localizedDescription)")
            print("")
            print("RESULT: FAIL. Capture backend could not start.")
            return 5
        }

        print("capture       : started")

        // Make the first encoded frame independently decodable.
        capturer.forceKeyframe()

        // A static virtual display does not necessarily produce 30 new
        // surfaces per second. That is fine: this probe validates the
        // pipeline, not frame-rate performance.
        for second in 1...6 {
            try? await Task.sleep(nanoseconds: 1_000_000_000)

            let current = stats.snapshot()

            print(
                "second \(second)      : "
                + "\(current.frames) frames, "
                + "\(current.keyframes) keyframes, "
                + "\(current.bytes) bytes"
            )
        }

        // ------------------------------------------------------------
        // 4. Stop cleanly and evaluate the encoded stream.
        // ------------------------------------------------------------

        await capturer.stop()

        let result = stats.snapshot()

        print("")
        print("encoded frames : \(result.frames)")
        print("keyframes      : \(result.keyframes)")
        print("encoded bytes  : \(result.bytes)")
        print("Annex-B        : \(result.annexB ? "yes" : "NO")")

        if let error = result.error {
            print("stream error   : \(error)")
        } else {
            print("stream error   : none")
        }

        manager.destroyDisplay()
        needsDestroy = false

        try? await Task.sleep(nanoseconds: 500_000_000)

        let final = activeDisplays()

        print(
            "after teardown : \(final.count) -> "
            + describe(final)
        )

        // ------------------------------------------------------------
        // 5. PASS / FAIL.
        // ------------------------------------------------------------

        guard result.error == nil else {
            print("")
            print("RESULT: FAIL. CGDisplayStream reported an error.")
            return 6
        }

        guard result.frames > 0,
              result.bytes > 0 else {

            print("")
            print(
                "RESULT: FAIL. Capture ran, but VideoToolbox "
                + "produced no H.264 frames."
            )
            return 7
        }

        guard result.keyframes > 0 else {
            print("")
            print("RESULT: FAIL. No H.264 keyframe was produced.")
            return 8
        }

        guard result.annexB else {
            print("")
            print(
                "RESULT: FAIL. Encoded output does not look "
                + "like Annex-B H.264."
            )
            return 9
        }

        print("")
        print(
            "RESULT: PASS. CGVirtualDisplay -> CGDisplayStream "
            + "-> IOSurface -> CVPixelBuffer -> VideoToolbox H.264 works."
        )

        return 0
    }
}
