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

struct EncoderSettings {
    var width: Int32
    var height: Int32
    var frameRate: Int
    var bitRate: Int32
    var codec: VideoCodec
}

/// Hardware video encoder. Emits Annex-B access units with parameter sets
/// prepended to every keyframe, so a client can join the stream at any point.
final class VideoEncoder {
    private var session: VTCompressionSession?
    private let settings: EncoderSettings
    private var forceKeyframeNext = false

    var onEncodedFrame: ((Data, Bool) -> Void)?

    init(settings: EncoderSettings) throws {
        self.settings = settings

        var created: VTCompressionSession?
        let status = VTCompressionSessionCreate(
            allocator: kCFAllocatorDefault,
            width: settings.width, height: settings.height,
            codecType: settings.codec.cmType,
            encoderSpecification: nil, imageBufferAttributes: nil,
            compressedDataAllocator: nil, outputCallback: nil, refcon: nil,
            compressionSessionOut: &created)

        guard status == noErr, let session = created else {
            throw EncoderError.sessionCreationFailed(status: status, codec: settings.codec)
        }
        self.session = session
        configure(session)
        log("Encoder ready: \(settings.codec.rawValue) \(settings.width)x\(settings.height) "
            + "@ \(settings.frameRate)fps, \(settings.bitRate / 1_000_000) Mbps")
    }

    private func configure(_ session: VTCompressionSession) {
        let profile: CFString = settings.codec == .h264
            ? kVTProfileLevel_H264_Main_AutoLevel
            : kVTProfileLevel_HEVC_Main_AutoLevel
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_ProfileLevel, value: profile)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_RealTime, value: kCFBooleanTrue)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_AllowFrameReordering,
                             value: kCFBooleanFalse)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_AverageBitRate,
                             value: settings.bitRate as CFNumber)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_ExpectedFrameRate,
                             value: settings.frameRate as CFNumber)
        // A keyframe every two seconds bounds how long a reconnecting client
        // stares at a black screen — and forceKeyframe() covers the common case.
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_MaxKeyFrameInterval,
                             value: (settings.frameRate * 2) as CFNumber)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_MaxKeyFrameIntervalDuration,
                             value: 2 as CFNumber)
        VTCompressionSessionPrepareToEncodeFrames(session)
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

        VTCompressionSessionEncodeFrame(
            session, imageBuffer: pixelBuffer, presentationTimeStamp: timestamp,
            duration: CMTime(value: 1, timescale: CMTimeScale(settings.frameRate)),
            frameProperties: properties, infoFlagsOut: nil
        ) { [weak self] status, _, sampleBuffer in
            guard status == noErr, let sampleBuffer else { return }
            self?.emit(sampleBuffer)
        }
    }

    private func emit(_ sampleBuffer: CMSampleBuffer) {
        guard let block = CMSampleBufferGetDataBuffer(sampleBuffer) else { return }

        var totalLength = 0
        var pointer: UnsafeMutablePointer<Int8>?
        guard CMBlockBufferGetDataPointer(block, atOffset: 0, lengthAtOffsetOut: nil,
                                          totalLengthOut: &totalLength,
                                          dataPointerOut: &pointer) == noErr,
              let base = pointer else { return }

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

        guard !out.isEmpty else { return }
        onEncodedFrame?(out, isKeyframe)
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

/// Captures one display with ScreenCaptureKit and feeds the encoder.
final class ScreenCapturer: NSObject, SCStreamDelegate, SCStreamOutput {
    private var stream: SCStream?
    private var encoder: VideoEncoder?

    var onEncodedFrame: ((Data, Bool) -> Void)?
    var onStreamError: ((Error) -> Void)?
    /// Wall-clock time the most recent frame was captured, for latency stats.
    private(set) var lastFrameAt: Date?
    private(set) var capturedFrames = 0

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
        encoder.onEncodedFrame = { [weak self] data, isKeyframe in
            self?.onEncodedFrame?(data, isKeyframe)
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
        encoder?.encode(pixelBuffer: pixelBuffer,
                        timestamp: CMSampleBufferGetPresentationTimeStamp(sampleBuffer))
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
