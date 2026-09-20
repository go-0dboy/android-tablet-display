import Foundation
import CoreGraphics
import CoreMedia
import CoreVideo
import IOSurface

/// Legacy capture backend for macOS Monterey.
///
/// CGDisplayStream delivers IOSurface frames for a specific display.
/// Each surface is wrapped as a CVPixelBuffer and passed into the same
/// VideoToolbox encoder used by the ScreenCaptureKit backend.
final class CGDisplayStreamCapturer: DisplayCapturer {

    private var stream: CGDisplayStream?
    private var encoder: VideoEncoder?
    private let captureQueue = DispatchQueue(
        label: "usbdisplay.cgdisplaystream.capture",
        qos: .userInteractive
    )

    var onEncodedFrame: ((Data, Bool) -> Void)?
    var onStreamError: ((Error) -> Void)?

    private(set) var lastFrameAt: Date?
    private(set) var capturedFrames = 0

    private var encodeLatenciesMs: [Double] = []
    private var pendingCaptureAt: [Int64: CFAbsoluteTime] = [:]
    private let latencyLock = NSLock()

    private var stopping = false

    func drainEncodeLatency()
        -> (median: Double, worst: Double, count: Int)? {

        latencyLock.lock()
        let samples = encodeLatenciesMs
        encodeLatenciesMs.removeAll(keepingCapacity: true)
        latencyLock.unlock()

        guard !samples.isEmpty else { return nil }

        let sorted = samples.sorted()
        return (
            sorted[sorted.count / 2],
            sorted.last ?? 0,
            sorted.count
        )
    }

    func forceKeyframe() {
        encoder?.forceKeyframe()
    }

    func start(displayID: CGDirectDisplayID,
               settings: EncoderSettings) async throws {

        await stop()

        let encoder = try VideoEncoder(settings: settings)

        encoder.onEncodedFrame = { [weak self] data, isKeyframe in
            self?.onEncodedFrame?(data, isKeyframe)
        }

        encoder.onFramePresentationTime = { [weak self] presentationValue in
            guard let self = self else { return }

            self.latencyLock.lock()

            if let captured =
                self.pendingCaptureAt.removeValue(forKey: presentationValue) {

                let ms =
                    (CFAbsoluteTimeGetCurrent() - captured) * 1000

                self.encodeLatenciesMs.append(ms)

                if self.encodeLatenciesMs.count > 600 {
                    self.encodeLatenciesMs.removeFirst(300)
                }
            }

            self.latencyLock.unlock()
        }

        self.encoder = encoder
        stopping = false

        let outputWidth = Int(settings.width)
        let outputHeight = Int(settings.height)

        guard let stream = CGDisplayStream(
            dispatchQueueDisplay: displayID,
            outputWidth: outputWidth,
            outputHeight: outputHeight,
            pixelFormat: Int32(kCVPixelFormatType_32BGRA),
            properties: nil,
            queue: captureQueue,
            handler: { [weak self] status, displayTime, surface, _ in
                guard let self = self else { return }

                switch status {

                case .frameComplete:
                    guard let surface = surface else { return }
                    self.handle(
                        surface: surface,
                        displayTime: displayTime,
                        settings: settings
                    )

                case .stopped:
                    if !self.stopping {
                        let error = CaptureError.streamStopped
                        log("CGDisplayStream stopped unexpectedly")
                        self.onStreamError?(error)
                    }

                case .frameIdle, .frameBlank:
                    break

                @unknown default:
                    break
                }
            }
        ) else {
            self.encoder?.invalidate()
            self.encoder = nil
            throw CaptureError.streamCreationFailed(displayID)
        }

        let result = stream.start()

        guard result == .success else {
            self.encoder?.invalidate()
            self.encoder = nil
            throw CaptureError.streamStartFailed(result)
        }

        self.stream = stream

        log(
            "Capture started with CGDisplayStream: "
            + "\(outputWidth)x\(outputHeight), display \(displayID)"
        )
    }

    // CGDisplayStream may deliver frames faster than the stream profile asks for.
    // VideoToolbox's ExpectedFrameRate is only a hint; it does not throttle input.
    //
    // Drop excess capture callbacks BEFORE VideoToolbox sees them. This is safe
    // for H.264 prediction because the encoder builds its dependency chain only
    // from frames that are actually submitted to it.
    private let pacingLock = NSLock()
    private var lastSubmittedFrameSeconds: Double = 0

    private func shouldSubmitFrame(frameRate: Int) -> Bool {
        let fps = max(frameRate, 1)
        let minimumInterval = 1.0 / Double(fps)

        let hostTime = CMClockGetTime(CMClockGetHostTimeClock())
        let now = CMTimeGetSeconds(hostTime)

        pacingLock.lock()
        defer { pacingLock.unlock() }

        if lastSubmittedFrameSeconds > 0,
           now - lastSubmittedFrameSeconds < minimumInterval {
            return false
        }

        // Use the actual submission time rather than trying to "catch up".
        // Catch-up bursts are exactly what we do not want for an interactive
        // display and an old hardware decoder.
        lastSubmittedFrameSeconds = now
        return true
    }

    private func handle(surface: IOSurfaceRef,
                        displayTime: UInt64,
                        settings: EncoderSettings) {

        guard shouldSubmitFrame(frameRate: settings.frameRate) else {
            return
        }

        var unmanagedPixelBuffer: Unmanaged<CVPixelBuffer>?

        let result = CVPixelBufferCreateWithIOSurface(
            kCFAllocatorDefault,
            surface,
            nil,
            &unmanagedPixelBuffer
        )

        guard result == kCVReturnSuccess,
              let unmanagedPixelBuffer = unmanagedPixelBuffer else {
            log("Could not wrap IOSurface in CVPixelBuffer: \(result)")
            return
        }

        // CVPixelBufferCreateWithIOSurface follows the Core Foundation
        // Create Rule, so ownership is transferred to us here.
        let pixelBuffer = unmanagedPixelBuffer.takeRetainedValue()

        lastFrameAt = Date()
        capturedFrames += 1

        // Host clock gives VideoToolbox a monotonic timestamp.
        let presentation =
            CMClockGetTime(CMClockGetHostTimeClock())

        latencyLock.lock()

        pendingCaptureAt[presentation.value] =
            CFAbsoluteTimeGetCurrent()

        if pendingCaptureAt.count > 240 {
            pendingCaptureAt.removeAll(keepingCapacity: true)
        }

        latencyLock.unlock()

        encoder?.encode(
            pixelBuffer: pixelBuffer,
            timestamp: presentation
        )
    }

    func stop() async {
        stopping = true

        if let stream = stream {
            _ = stream.stop()
        }

        stream = nil

        encoder?.invalidate()
        encoder = nil

        clearPendingCaptureState()
    }

    private func clearPendingCaptureState() {
        latencyLock.lock()
        pendingCaptureAt.removeAll(keepingCapacity: true)
        latencyLock.unlock()
    }

    enum CaptureError: Error, LocalizedError {
        case streamCreationFailed(CGDirectDisplayID)
        case streamStartFailed(CGError)
        case streamStopped

        var errorDescription: String? {
            switch self {
            case .streamCreationFailed(let id):
                return "CGDisplayStream could not capture display \(id)."

            case .streamStartFailed(let error):
                return "CGDisplayStream failed to start (CoreGraphics error \(error.rawValue))."

            case .streamStopped:
                return "CGDisplayStream stopped unexpectedly."
            }
        }
    }
}
