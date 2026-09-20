// Streaming.swift — capture the virtual display, encode it, ship it.

import Foundation
import ScreenCaptureKit
import VideoToolbox
import CoreMedia
import CoreVideo
import AppKit
import USBDisplayCore

// MARK: - Logging

final class Logger {
    static let shared = Logger()
    private let queue = DispatchQueue(label: "log")
    private var buffer: [String] = []
    var onLog: ((String) -> Void)?

    private let formatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        return f
    }()

    func log(_ message: String) {
        let line = "[\(formatter.string(from: Date()))] \(message)"
        print(line)
        fflush(stdout)
        queue.async {
            self.buffer.append(line)
            if self.buffer.count > 2000 { self.buffer.removeFirst(500) }
        }
        DispatchQueue.main.async { self.onLog?(line) }
    }

    var recentLines: [String] {
        queue.sync { buffer }
    }
}

func log(_ message: String) { Logger.shared.log(message) }

// MARK: - Encoder

/// Which codec to ask VideoToolbox for.
enum VideoCodec: String, CaseIterable {
    case h264
    case hevc

    var cmType: CMVideoCodecType {
        switch self {
        case .h264: return kCMVideoCodecType_H264
        case .hevc: return kCMVideoCodecType_HEVC
        }
    }

    var title: String {
        switch self {
        case .h264: return "H.264 (works everywhere)"
        case .hevc: return "HEVC (smaller, needs a newer device)"
        }
    }
}

enum H264Profile {
    case baseline
    case main
}

struct EncoderSettings {
    var width: Int32
    var height: Int32
    var frameRate: Int
    var bitRate: Int32
    var codec: VideoCodec
    var h264Profile: H264Profile = .main
    var maxFrameDelayCount: Int? = nil
    var enforceDataRateLimit = false
    var keyframeIntervalSeconds = 2
}

/// Hardware video encoder. Emits Annex-B access units with parameter sets
/// prepended to every keyframe, so a client can join the stream at any point.
final class VideoEncoder {
    private var session: VTCompressionSession?
    private let settings: EncoderSettings
    private var forceKeyframeNext = false

    var onEncodedFrame: ((Data, Bool, Int64) -> Void)?
    /// Reports the presentation timestamp of each frame as it comes out, so
    /// the capturer can pair it with when that frame went in.
    var onFramePresentationTime: ((Int64) -> Void)?

    // Reports whether an encode callback produced a usable access unit. This
    // is encoder completion only; network delivery is tracked separately.
    var onFrameFinished: ((Int64, OSStatus, Bool) -> Void)?

    init(settings: EncoderSettings) throws {
        self.settings = settings

        var created: VTCompressionSession?

        // Explicitly allow VideoToolbox to select the hardware encoder.
        // This still permits a software fallback if this Mac cannot provide
        // hardware encoding for the requested codec/profile.
        let encoderSpecification = [
            kVTVideoEncoderSpecification_EnableHardwareAcceleratedVideoEncoder:
                kCFBooleanTrue!
        ] as CFDictionary

        let status = VTCompressionSessionCreate(
            allocator: kCFAllocatorDefault,
            width: settings.width, height: settings.height,
            codecType: settings.codec.cmType,
            encoderSpecification: encoderSpecification, imageBufferAttributes: nil,
            compressedDataAllocator: nil, outputCallback: nil, refcon: nil,
            compressionSessionOut: &created)

        guard status == noErr, let session = created else {
            throw EncoderError.sessionCreationFailed(status: status, codec: settings.codec)
        }
        self.session = session
        configure(session)

        var hardwareValue: CFTypeRef?
        let hardwareStatus = withUnsafeMutablePointer(to: &hardwareValue) { pointer in
            VTSessionCopyProperty(
                session,
                key: kVTCompressionPropertyKey_UsingHardwareAcceleratedVideoEncoder,
                allocator: kCFAllocatorDefault,
                valueOut: pointer
            )
        }

        if hardwareStatus == noErr, let hardwareValue {
            let usingHardware = CFBooleanGetValue(
                unsafeBitCast(hardwareValue, to: CFBoolean.self)
            )
            log("VideoToolbox hardware encoder: \(usingHardware ? "yes" : "no")")
        } else {
            log("VideoToolbox hardware encoder: unknown (status \(hardwareStatus))")
        }

        log("Encoder ready: \(settings.codec.rawValue) \(settings.width)x\(settings.height) "
            + "@ \(settings.frameRate)fps, \(settings.bitRate / 1_000_000) Mbps")
    }

    private func configure(_ session: VTCompressionSession) {
        func set(_ key: CFString, _ value: CFTypeRef, named name: String) {
            let status = VTSessionSetProperty(session, key: key, value: value)
            if status != noErr {
                log("Encoder rejected \(name) (status \(status))")
            }
        }

        let profile: CFString
        if settings.codec == .h264 {
            switch settings.h264Profile {
            case .baseline:
                profile = kVTProfileLevel_H264_Baseline_AutoLevel
            case .main:
                profile = kVTProfileLevel_H264_Main_AutoLevel
            }
        } else {
            profile = kVTProfileLevel_HEVC_Main_AutoLevel
        }
        set(kVTCompressionPropertyKey_ProfileLevel, profile, named: "profile")
        set(kVTCompressionPropertyKey_RealTime, kCFBooleanTrue, named: "real-time mode")
        set(kVTCompressionPropertyKey_AllowFrameReordering, kCFBooleanFalse,
            named: "frame reordering")

        if let maxFrameDelayCount = settings.maxFrameDelayCount {
            set(kVTCompressionPropertyKey_MaxFrameDelayCount,
                maxFrameDelayCount as CFNumber,
                named: "maximum frame delay")
        }

        set(kVTCompressionPropertyKey_ExpectedFrameRate,
            settings.frameRate as CFNumber,
            named: "expected frame rate")
        set(kVTCompressionPropertyKey_AverageBitRate,
            settings.bitRate as CFNumber,
            named: "average bit rate")
        if settings.enforceDataRateLimit {
            let bytesPerSecond = max(Int(settings.bitRate) / 8, 1)
            let limits = [
                NSNumber(value: bytesPerSecond),
                NSNumber(value: 1)
            ] as CFArray
            set(kVTCompressionPropertyKey_DataRateLimits, limits,
                named: "data-rate limit")
        }
        let keyframeSeconds = max(settings.keyframeIntervalSeconds, 1)
        set(kVTCompressionPropertyKey_MaxKeyFrameInterval,
            (settings.frameRate * keyframeSeconds) as CFNumber,
            named: "keyframe interval")
        set(kVTCompressionPropertyKey_MaxKeyFrameIntervalDuration,
            keyframeSeconds as CFNumber,
            named: "keyframe interval duration")
        let prepareStatus = VTCompressionSessionPrepareToEncodeFrames(session)
        if prepareStatus != noErr {
            log("Encoder preparation failed (status \(prepareStatus))")
        }
    }

    /// Ask for an immediate keyframe. Called the moment a client connects, so
    /// the first thing it receives is decodable rather than a P-frame
    /// referencing pictures it never saw.
    func forceKeyframe() {
        forceKeyframeNext = true
    }

    func encode(pixelBuffer: CVPixelBuffer, timestamp: CMTime) {
        guard let session else { return }

        var properties: CFDictionary?
        if forceKeyframeNext {
            forceKeyframeNext = false
            properties = [kVTEncodeFrameOptionKey_ForceKeyFrame: kCFBooleanTrue!] as CFDictionary
        }

        let presentationValue = timestamp.value

        let submitStatus = VTCompressionSessionEncodeFrame(
            session, imageBuffer: pixelBuffer, presentationTimeStamp: timestamp,
            duration: CMTime(value: 1, timescale: CMTimeScale(settings.frameRate)),
            frameProperties: properties, infoFlagsOut: nil
        ) { [weak self] status, _, sampleBuffer in
            guard let self = self else { return }

            var emitted = false
            if status == noErr, let sampleBuffer = sampleBuffer {
                emitted = self.emit(sampleBuffer)
            }

            self.onFrameFinished?(presentationValue, status, emitted)
        }

        // A synchronous submission failure does not get an output callback.
        if submitStatus != noErr {
            onFrameFinished?(presentationValue, submitStatus, false)
        }
    }

    @discardableResult
    private func emit(_ sampleBuffer: CMSampleBuffer) -> Bool {
        guard let block = CMSampleBufferGetDataBuffer(sampleBuffer) else { return false }

        var totalLength = 0
        var pointer: UnsafeMutablePointer<Int8>?
        guard CMBlockBufferGetDataPointer(block, atOffset: 0, lengthAtOffsetOut: nil,
                                          totalLengthOut: &totalLength,
                                          dataPointerOut: &pointer) == noErr,
              let base = pointer else { return false }

        let isKeyframe = Self.isKeyframe(sampleBuffer)

        var out = Data()
        out.reserveCapacity(totalLength + 256)

        if isKeyframe, let format = CMSampleBufferGetFormatDescription(sampleBuffer) {
            for parameterSet in Self.parameterSets(format, codec: settings.codec) {
                out.append(contentsOf: [0x00, 0x00, 0x00, 0x01])
                out.append(parameterSet)
            }
        }

        // VideoToolbox emits length-prefixed NAL units; the client's decoder
        // wants Annex-B start codes.
        var offset = 0
        while offset + 4 <= totalLength {
            var naluLength: UInt32 = 0
            memcpy(&naluLength, base.advanced(by: offset), 4)
            let length = Int(CFSwapInt32BigToHost(naluLength))
            guard length > 0, offset + 4 + length <= totalLength else { break }

            out.append(contentsOf: [0x00, 0x00, 0x00, 0x01])
            out.append(Data(bytes: base.advanced(by: offset + 4), count: length))
            offset += 4 + length
        }

        guard !out.isEmpty else { return false }
        let presentationValue = CMSampleBufferGetPresentationTimeStamp(sampleBuffer).value
        onFramePresentationTime?(presentationValue)
        onEncodedFrame?(out, isKeyframe, presentationValue)
        return true
    }

    private static func isKeyframe(_ sampleBuffer: CMSampleBuffer) -> Bool {
        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(
                sampleBuffer, createIfNecessary: false),
              CFArrayGetCount(attachments) > 0 else { return true }
        let dict = unsafeBitCast(CFArrayGetValueAtIndex(attachments, 0), to: CFDictionary.self)
        guard let notSync = CFDictionaryGetValue(
                dict, Unmanaged.passUnretained(kCMSampleAttachmentKey_NotSync).toOpaque())
        else { return true }
        return unsafeBitCast(notSync, to: CFBoolean.self) != kCFBooleanTrue
    }

    /// H.264 has SPS+PPS; HEVC adds VPS. Pulling them by count rather than
    /// assuming two is what makes the HEVC path work at all.
    private static func parameterSets(_ format: CMFormatDescription,
                                      codec: VideoCodec) -> [Data] {
        var count = 0
        let countStatus: OSStatus
        if codec == .h264 {
            countStatus = CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
                format, parameterSetIndex: 0, parameterSetPointerOut: nil,
                parameterSetSizeOut: nil, parameterSetCountOut: &count,
                nalUnitHeaderLengthOut: nil)
        } else {
            countStatus = CMVideoFormatDescriptionGetHEVCParameterSetAtIndex(
                format, parameterSetIndex: 0, parameterSetPointerOut: nil,
                parameterSetSizeOut: nil, parameterSetCountOut: &count,
                nalUnitHeaderLengthOut: nil)
        }
        guard countStatus == noErr, count > 0 else { return [] }

        var sets: [Data] = []
        for index in 0..<count {
            var size = 0
            var ptr: UnsafePointer<UInt8>?
            let status: OSStatus
            if codec == .h264 {
                status = CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
                    format, parameterSetIndex: index, parameterSetPointerOut: &ptr,
                    parameterSetSizeOut: &size, parameterSetCountOut: nil,
                    nalUnitHeaderLengthOut: nil)
            } else {
                status = CMVideoFormatDescriptionGetHEVCParameterSetAtIndex(
                    format, parameterSetIndex: index, parameterSetPointerOut: &ptr,
                    parameterSetSizeOut: &size, parameterSetCountOut: nil,
                    nalUnitHeaderLengthOut: nil)
            }
            if status == noErr, let ptr, size > 0 {
                sets.append(Data(bytes: ptr, count: size))
            }
        }
        return sets
    }

    func invalidate() {
        if let session {
            VTCompressionSessionCompleteFrames(session, untilPresentationTimeStamp: .invalid)
            VTCompressionSessionInvalidate(session)
        }
        session = nil
    }

    deinit { invalidate() }

    enum EncoderError: Error, LocalizedError {
        case sessionCreationFailed(status: OSStatus, codec: VideoCodec)

        var errorDescription: String? {
            switch self {
            case .sessionCreationFailed(let status, let codec):
                return "Could not start the \(codec.rawValue.uppercased()) encoder "
                     + "(VideoToolbox error \(status))."
            }
        }
    }
}

// MARK: - Capture

/// Common interface for display-capture implementations.
///
/// macOS 13+ uses ScreenCaptureKit. Monterey uses the older
/// CGDisplayStream API because it is known to work with the virtual
/// displays created by this application on macOS 12.
protocol DisplayCapturer: AnyObject {
    /// The receiver must invoke the completion after the whole access unit has
    /// either been delivered or abandoned with its connection. This lets the
    /// capturer bound the complete encode/network pipeline without blocking a
    /// VideoToolbox callback.
    var onEncodedFrame: ((Data, Bool, @escaping () -> Void) -> Void)? { get set }
    var onStreamError: ((Error) -> Void)? { get set }

    func start(displayID: CGDirectDisplayID,
               settings: EncoderSettings) async throws
    func stop() async
    func forceKeyframe()
    func drainEncodeLatency()
        -> (median: Double, worst: Double, count: Int)?
    func drainPipelineMetrics() -> CapturePipelineMetrics
}

struct CapturePipelineMetrics {
    var captureCallbacks = 0
    var submitted = 0
    var encoded = 0
    var replacements = 0
    var framesInFlight = 0
}

/// Captures one display with ScreenCaptureKit and feeds the encoder.
@available(macOS 12.3, *)
final class ScreenCapturer: NSObject, SCStreamDelegate, SCStreamOutput, DisplayCapturer {
    private var stream: SCStream?
    private var encoder: VideoEncoder?

    var onEncodedFrame: ((Data, Bool, @escaping () -> Void) -> Void)?
    var onStreamError: ((Error) -> Void)?
    /// Wall-clock time the most recent frame was captured, for latency stats.
    private(set) var lastFrameAt: Date?
    private(set) var capturedFrames = 0

    /// Milliseconds from ScreenCaptureKit handing us a frame to the encoder
    /// producing the compressed bytes. This is the part of the pipeline the
    /// host can measure honestly; display scanout on the tablet is not
    /// visible to any software on either machine.
    private(set) var encodeLatenciesMs: [Double] = []
    private var pendingCaptureAt: [Int64: CFAbsoluteTime] = [:]
    private let latencyLock = NSLock()

    private let schedulingQueue = DispatchQueue(
        label: "usbdisplay.screencapture.pipeline",
        qos: .userInteractive
    )
    private let maxFramesInFlight = 2
    private var framesInFlight = 0
    private var outstandingFrames = Set<Int64>()
    private var pendingLatestFrame: (CVPixelBuffer, CMTime)?
    private let metricsLock = NSLock()
    private var pipelineMetrics = CapturePipelineMetrics()

    /// Summary for the menu and the log: median and worst encode time.
    func drainEncodeLatency() -> (median: Double, worst: Double, count: Int)? {
        latencyLock.lock()
        let samples = encodeLatenciesMs
        encodeLatenciesMs.removeAll(keepingCapacity: true)
        latencyLock.unlock()

        guard !samples.isEmpty else { return nil }
        let sorted = samples.sorted()
        return (sorted[sorted.count / 2], sorted.last ?? 0, sorted.count)
    }

    func drainPipelineMetrics() -> CapturePipelineMetrics {
        metricsLock.lock()
        var result = pipelineMetrics
        pipelineMetrics = CapturePipelineMetrics()
        metricsLock.unlock()
        result.framesInFlight = schedulingQueue.sync { framesInFlight }
        return result
    }

    func forceKeyframe() { encoder?.forceKeyframe() }

    func start(displayID: CGDirectDisplayID, settings: EncoderSettings) async throws {
        // A display created a moment ago may not be in SCShareableContent yet.
        var display: SCDisplay?
        for attempt in 1...6 {
            let content = try await SCShareableContent.excludingDesktopWindows(
                false, onScreenWindowsOnly: false)
            display = content.displays.first { $0.displayID == displayID }
            if display != nil { break }
            log("Display \(displayID) not shareable yet (attempt \(attempt)/6)")
            try? await Task.sleep(nanoseconds: 500_000_000)
        }

        guard let display else { throw CaptureError.displayNotFound(displayID) }
        log("Capturing display \(display.displayID): \(display.width)x\(display.height)")

        let filter = SCContentFilter(display: display, excludingWindows: [])

        let config = SCStreamConfiguration()
        config.width = Int(settings.width)
        config.height = Int(settings.height)
        config.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(settings.frameRate))
        config.pixelFormat = kCVPixelFormatType_32BGRA
        config.showsCursor = true
        config.scalesToFit = true
        // Queue depth 3 is the smallest that does not drop frames under a
        // burst while still keeping the buffer shallow enough to stay
        // responsive; 2 stalls the encoder on this machine.
        config.queueDepth = 3
        config.colorSpaceName = CGColorSpace.sRGB

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
            guard let self else { return }
            self.latencyLock.lock()
            if let captured = self.pendingCaptureAt.removeValue(forKey: presentationValue) {
                let ms = (CFAbsoluteTimeGetCurrent() - captured) * 1000
                self.encodeLatenciesMs.append(ms)
                if self.encodeLatenciesMs.count > 600 {
                    self.encodeLatenciesMs.removeFirst(300)
                }
            }
            self.latencyLock.unlock()
        }
        self.encoder = encoder

        let stream = SCStream(filter: filter, configuration: config, delegate: self)
        try stream.addStreamOutput(self, type: .screen,
                                   sampleHandlerQueue: .global(qos: .userInteractive))
        try await stream.startCapture()
        self.stream = stream
        log("Capture started")
    }

    func stop() async {
        try? await stream?.stopCapture()
        stream = nil
        encoder?.invalidate()
        encoder = nil
        schedulingQueue.sync {
            pendingLatestFrame = nil
            outstandingFrames.removeAll()
            framesInFlight = 0
        }
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
                of type: SCStreamOutputType) {
        guard type == .screen,
              let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }

        // ScreenCaptureKit delivers a status attachment; skip frames that are
        // idle or blank rather than spending encoder time on them.
        if let attachments = CMSampleBufferGetSampleAttachmentsArray(
                sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
           let raw = attachments.first?[.status] as? Int,
           let status = SCFrameStatus(rawValue: raw),
           status != .complete {
            return
        }

        lastFrameAt = Date()
        capturedFrames += 1
        metricsLock.lock()
        pipelineMetrics.captureCallbacks += 1
        metricsLock.unlock()

        let presentation = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        schedulingQueue.async { [weak self] in
            self?.enqueueLatest(pixelBuffer: pixelBuffer, timestamp: presentation)
        }
    }

    private func enqueueLatest(pixelBuffer: CVPixelBuffer, timestamp: CMTime) {
        guard encoder != nil else { return }
        if framesInFlight < maxFramesInFlight {
            submit(pixelBuffer: pixelBuffer, timestamp: timestamp)
        } else {
            if pendingLatestFrame != nil {
                metricsLock.lock()
                pipelineMetrics.replacements += 1
                metricsLock.unlock()
            }
            pendingLatestFrame = (pixelBuffer, timestamp)
        }
    }

    private func submit(pixelBuffer: CVPixelBuffer, timestamp: CMTime) {
        framesInFlight += 1
        outstandingFrames.insert(timestamp.value)
        metricsLock.lock()
        pipelineMetrics.submitted += 1
        metricsLock.unlock()

        latencyLock.lock()
        pendingCaptureAt[timestamp.value] = CFAbsoluteTimeGetCurrent()
        latencyLock.unlock()
        encoder?.encode(pixelBuffer: pixelBuffer, timestamp: timestamp)
    }

    private func completeFrame(_ presentationValue: Int64) {
        schedulingQueue.async { [weak self] in
            guard let self = self,
                  self.outstandingFrames.remove(presentationValue) != nil else { return }
            self.framesInFlight -= 1
            if let pending = self.pendingLatestFrame {
                self.pendingLatestFrame = nil
                self.submit(pixelBuffer: pending.0, timestamp: pending.1)
            }
        }
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        log("Capture stopped: \(error.localizedDescription)")
        onStreamError?(error)
    }

    enum CaptureError: Error, LocalizedError {
        case displayNotFound(CGDirectDisplayID)

        var errorDescription: String? {
            switch self {
            case .displayNotFound(let id):
                return "The virtual display (\(id)) never became available to capture. "
                     + "Check that Screen Recording permission is granted."
            }
        }
    }
}
