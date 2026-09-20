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

    var onEncodedFrame: ((Data, Bool, @escaping () -> Void) -> Void)?
    var onStreamError: ((Error) -> Void)?

    private(set) var lastFrameAt: Date?
    private(set) var capturedFrames = 0

    private var encodeLatenciesMs: [Double] = []
    private var pendingCaptureAt: [Int64: CFAbsoluteTime] = [:]
    private let latencyLock = NSLock()

    // Bound the complete encoder/network pipeline. Frames which have not yet
    // entered VideoToolbox are safe to replace; encoded H.264 access units are
    // always delivered in order by VideoServer.
    private let maxFramesInFlight = 2
    private var framesInFlight = 0
    private var outstandingFrames = Set<Int64>()
    private var pendingLatestFrame: (CVPixelBuffer, CFAbsoluteTime)?
    private var currentFrame: CVPixelBuffer?
    private var frameTimer: DispatchSourceTimer?
    private let metricsLock = NSLock()
    private var pipelineMetrics = CapturePipelineMetrics()

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

    func drainPipelineMetrics() -> CapturePipelineMetrics {
        metricsLock.lock()
        var result = pipelineMetrics
        pipelineMetrics = CapturePipelineMetrics()
        metricsLock.unlock()
        result.framesInFlight = captureQueue.sync { framesInFlight }
        return result
    }

    func forceKeyframe() {
        encoder?.forceKeyframe()
    }

    func start(displayID: CGDirectDisplayID,
               settings: EncoderSettings) async throws {

        await stop()

        let encoder = try VideoEncoder(settings: settings)

        encoder.onEncodedFrame = { [weak self] data, isKeyframe, presentationValue in
            guard let self = self else { return }
            self.metricsLock.lock()
            self.pipelineMetrics.encoded += 1
            self.metricsLock.unlock()

            let completion: () -> Void = { [weak self] in
                guard let self = self else { return }
                self.completeFrame(presentationValue)
            }
            if let deliver = self.onEncodedFrame {
                deliver(data, isKeyframe, completion)
            } else {
                completion()
            }
        }

        encoder.onFrameFinished = { [weak self] presentationValue, _, emitted in
            if !emitted { self?.completeFrame(presentationValue) }
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
        startFrameTimer(frameRate: settings.frameRate)

        let outputWidth = Int(settings.width)
        let outputHeight = Int(settings.height)

        guard let stream = CGDisplayStream(
            dispatchQueueDisplay: displayID,
            outputWidth: outputWidth,
            outputHeight: outputHeight,
            pixelFormat: Int32(kCVPixelFormatType_32BGRA),
            properties: nil,
            queue: captureQueue,
            handler: { [weak self] status, _, surface, _ in
                guard let self = self else { return }

                switch status {

                case .frameComplete:
                    guard let surface = surface else { return }
                    self.handle(surface: surface)

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
            stopFrameTimer()
            self.encoder?.invalidate()
            self.encoder = nil
            throw CaptureError.streamCreationFailed(displayID)
        }

        let result = stream.start()

        guard result == .success else {
            stopFrameTimer()
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

    private func handle(surface: IOSurfaceRef) {

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

        metricsLock.lock()
        pipelineMetrics.captureCallbacks += 1
        metricsLock.unlock()

        enqueueLatest(pixelBuffer: pixelBuffer)
    }

    /// Called only on captureQueue. CGDisplayStream may issue callbacks at the
    /// main display's 60 Hz even when the virtual display is 30 Hz. Keep only
    /// the newest callback; a fixed-cadence timer performs admission without
    /// the jitter sensitivity of an elapsed-time check inside this callback.
    private func enqueueLatest(pixelBuffer: CVPixelBuffer) {
        guard encoder != nil, !stopping else { return }

        if pendingLatestFrame != nil {
            metricsLock.lock()
            pipelineMetrics.replacements += 1
            metricsLock.unlock()
        }
        pendingLatestFrame = (pixelBuffer, CFAbsoluteTimeGetCurrent())
    }

    private func submitLatestIfPossible() {
        guard !stopping, framesInFlight < maxFramesInFlight else { return }

        let pixelBuffer: CVPixelBuffer
        let capturedAt: CFAbsoluteTime

        if let pending = pendingLatestFrame {
            pendingLatestFrame = nil
            currentFrame = pending.0
            pixelBuffer = pending.0
            capturedAt = pending.1
        } else if let currentFrame = currentFrame {
            // CGDisplayStream is damage-driven and may deliver only a handful
            // of callbacks per second while typing. Keep feeding the last
            // surface at the requested cadence so VideoToolbox does not hold a
            // sparse update until another damaged frame arrives.
            pixelBuffer = currentFrame
            capturedAt = CFAbsoluteTimeGetCurrent()
        } else {
            return
        }

        // A repeated image is still a distinct video frame. Give every
        // submission a fresh monotonic timestamp rather than reusing the
        // timestamp from the CGDisplayStream callback.
        let presentation = CMClockGetTime(CMClockGetHostTimeClock())
        submit(pixelBuffer: pixelBuffer,
               timestamp: presentation,
               capturedAt: capturedAt)
    }

    private func submit(pixelBuffer: CVPixelBuffer,
                        timestamp: CMTime,
                        capturedAt: CFAbsoluteTime) {
        framesInFlight += 1
        outstandingFrames.insert(timestamp.value)

        metricsLock.lock()
        pipelineMetrics.submitted += 1
        metricsLock.unlock()

        latencyLock.lock()
        pendingCaptureAt[timestamp.value] = capturedAt
        latencyLock.unlock()

        encoder?.encode(pixelBuffer: pixelBuffer, timestamp: timestamp)
    }

    private func completeFrame(_ presentationValue: Int64) {
        captureQueue.async { [weak self] in
            guard let self = self,
                  self.outstandingFrames.remove(presentationValue) != nil else { return }

            self.framesInFlight -= 1
        }
    }

    private func startFrameTimer(frameRate: Int) {
        let framesPerSecond = max(frameRate, 1)
        let interval = DispatchTimeInterval.nanoseconds(1_000_000_000 / framesPerSecond)
        let timer = DispatchSource.makeTimerSource(queue: captureQueue)
        timer.schedule(deadline: .now(), repeating: interval, leeway: .milliseconds(1))
        timer.setEventHandler { [weak self] in
            self?.submitLatestIfPossible()
        }
        frameTimer = timer
        timer.resume()
    }

    private func stopFrameTimer() {
        frameTimer?.cancel()
        frameTimer = nil
    }

    func stop() async {
        stopping = true
        stopFrameTimer()

        if let stream = stream {
            _ = stream.stop()
        }

        stream = nil

        encoder?.invalidate()
        encoder = nil

        captureQueue.sync {
            pendingLatestFrame = nil
            currentFrame = nil
            outstandingFrames.removeAll()
            framesInFlight = 0
        }

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
