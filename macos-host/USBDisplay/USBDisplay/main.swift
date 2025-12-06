import Foundation
import ScreenCaptureKit
import VideoToolbox
import CoreMedia
import AppKit
import VirtualDisplay

// Helper to ensure print flushes immediately
func log(_ message: String) {
    print(message)
    fflush(stdout)
}

// MARK: - Configuration

struct Config {
    static let targetWidth: Int32 = 2560
    static let targetHeight: Int32 = 1600
    static let frameRate: Int = 60
    static let videoPort: UInt16 = 5560
    static let touchPort: UInt16 = 5561
    static let bitRate: Int32 = 15_000_000  // 15 Mbps for higher resolution
}

// MARK: - H.264 Encoder

class H264Encoder {
    private var compressionSession: VTCompressionSession?
    private var frameCount: Int64 = 0
    var onEncodedFrame: ((Data) -> Void)?

    init() throws {
        var session: VTCompressionSession?

        let status = VTCompressionSessionCreate(
            allocator: kCFAllocatorDefault,
            width: Config.targetWidth,
            height: Config.targetHeight,
            codecType: kCMVideoCodecType_H264,
            encoderSpecification: nil,
            imageBufferAttributes: nil,
            compressedDataAllocator: nil,
            outputCallback: nil,
            refcon: nil,
            compressionSessionOut: &session
        )

        guard status == noErr, let session = session else {
            throw EncoderError.failedToCreateSession(status)
        }

        self.compressionSession = session
        try configureSession()
        log("H264 encoder initialized")
    }

    private func configureSession() throws {
        guard let session = compressionSession else { return }

        // Real-time encoding for low latency
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_RealTime, value: kCFBooleanTrue)

        // Set bitrate
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_AverageBitRate,
                            value: Config.bitRate as CFNumber)

        // Set profile (Baseline for compatibility, Main for quality)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_ProfileLevel,
                            value: kVTProfileLevel_H264_Main_AutoLevel)

        // Allow frame reordering (B-frames) - disable for lower latency
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_AllowFrameReordering,
                            value: kCFBooleanFalse)

        // Max keyframe interval
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_MaxKeyFrameInterval,
                            value: Config.frameRate * 2 as CFNumber)

        // Expected frame rate
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_ExpectedFrameRate,
                            value: Config.frameRate as CFNumber)

        VTCompressionSessionPrepareToEncodeFrames(session)
    }

    func encode(pixelBuffer: CVPixelBuffer, timestamp: CMTime) {
        guard let session = compressionSession else { return }

        var infoFlagsOut = VTEncodeInfoFlags()

        VTCompressionSessionEncodeFrame(
            session,
            imageBuffer: pixelBuffer,
            presentationTimeStamp: timestamp,
            duration: CMTime(value: 1, timescale: CMTimeScale(Config.frameRate)),
            frameProperties: nil,
            infoFlagsOut: &infoFlagsOut
        ) { [weak self] status, flags, sampleBuffer in
            guard status == noErr, let sampleBuffer = sampleBuffer else { return }
            self?.handleEncodedFrame(sampleBuffer)
        }

        frameCount += 1
    }

    private func handleEncodedFrame(_ sampleBuffer: CMSampleBuffer) {
        guard let dataBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else { return }

        var length: Int = 0
        var dataPointer: UnsafeMutablePointer<Int8>?

        CMBlockBufferGetDataPointer(dataBuffer, atOffset: 0, lengthAtOffsetOut: nil,
                                     totalLengthOut: &length, dataPointerOut: &dataPointer)

        guard let pointer = dataPointer else { return }

        // Check if this is a keyframe
        let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false)
        var isKeyframe = true
        if let attachments = attachments, CFArrayGetCount(attachments) > 0 {
            let attachment = unsafeBitCast(CFArrayGetValueAtIndex(attachments, 0), to: CFDictionary.self)
            if let notSync = CFDictionaryGetValue(attachment, Unmanaged.passUnretained(kCMSampleAttachmentKey_NotSync).toOpaque()) {
                isKeyframe = !(unsafeBitCast(notSync, to: CFBoolean.self) == kCFBooleanTrue)
            }
        }

        // For keyframes, prepend SPS/PPS
        var frameData = Data()

        if isKeyframe {
            if let formatDesc = CMSampleBufferGetFormatDescription(sampleBuffer) {
                // Get SPS
                var spsSize: Int = 0
                var spsCount: Int = 0
                var spsPointer: UnsafePointer<UInt8>?
                CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
                    formatDesc, parameterSetIndex: 0,
                    parameterSetPointerOut: &spsPointer, parameterSetSizeOut: &spsSize,
                    parameterSetCountOut: &spsCount, nalUnitHeaderLengthOut: nil
                )

                if let sps = spsPointer {
                    // NAL start code + SPS
                    frameData.append(contentsOf: [0x00, 0x00, 0x00, 0x01])
                    frameData.append(UnsafeBufferPointer(start: sps, count: spsSize))
                }

                // Get PPS
                var ppsSize: Int = 0
                var ppsPointer: UnsafePointer<UInt8>?
                CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
                    formatDesc, parameterSetIndex: 1,
                    parameterSetPointerOut: &ppsPointer, parameterSetSizeOut: &ppsSize,
                    parameterSetCountOut: nil, nalUnitHeaderLengthOut: nil
                )

                if let pps = ppsPointer {
                    // NAL start code + PPS
                    frameData.append(contentsOf: [0x00, 0x00, 0x00, 0x01])
                    frameData.append(UnsafeBufferPointer(start: pps, count: ppsSize))
                }
            }
        }

        // Convert AVCC to Annex B (replace length prefixes with start codes)
        var offset = 0
        while offset < length - 4 {
            var naluLength: UInt32 = 0
            memcpy(&naluLength, pointer.advanced(by: offset), 4)
            naluLength = CFSwapInt32BigToHost(naluLength)

            frameData.append(contentsOf: [0x00, 0x00, 0x00, 0x01])
            frameData.append(Data(bytes: pointer.advanced(by: offset + 4), count: Int(naluLength)))

            offset += 4 + Int(naluLength)
        }

        onEncodedFrame?(frameData)
    }

    deinit {
        if let session = compressionSession {
            VTCompressionSessionInvalidate(session)
        }
    }

    enum EncoderError: Error {
        case failedToCreateSession(OSStatus)
    }
}

// MARK: - Screen Capturer

class ScreenCapturer: NSObject, SCStreamDelegate, SCStreamOutput {
    private var stream: SCStream?
    private var encoder: H264Encoder?
    private var targetDisplayID: CGDirectDisplayID?
    var onEncodedFrame: ((Data) -> Void)?
    var onStreamError: ((Error) -> Void)?

    func start(displayID: CGDirectDisplayID? = nil) async throws {
        self.targetDisplayID = displayID
        log("Getting available content...")

        // Get available content - retry a few times if displays list is empty
        var content: SCShareableContent?
        for attempt in 1...3 {
            content = try await SCShareableContent.current
            if !content!.displays.isEmpty {
                break
            }
            log("No displays found, retrying... (attempt \(attempt)/3)")
            try? await Task.sleep(nanoseconds: 1_000_000_000)
        }

        guard let content = content, !content.displays.isEmpty else {
            throw CaptureError.noDisplayFound
        }

        // Find the target display
        var display: SCDisplay?
        if let targetID = displayID {
            // Find display by ID
            display = content.displays.first { $0.displayID == targetID }
            if display == nil {
                log("WARNING: Target display ID \(targetID) not found, available displays:")
                for d in content.displays {
                    log("  - Display \(d.displayID): \(d.width)x\(d.height)")
                }
                // Fall back to first display
                display = content.displays.first
            }
        } else {
            display = content.displays.first
        }

        guard let display = display else {
            throw CaptureError.noDisplayFound
        }

        log("Capturing display ID \(display.displayID): \(display.width)x\(display.height)")

        // Create filter for the display
        let filter = SCContentFilter(display: display, excludingWindows: [])

        // Configure stream
        let config = SCStreamConfiguration()
        config.width = Int(Config.targetWidth)
        config.height = Int(Config.targetHeight)
        config.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(Config.frameRate))
        config.pixelFormat = kCVPixelFormatType_32BGRA
        config.showsCursor = true
        config.queueDepth = 3

        // Create encoder
        encoder = try H264Encoder()
        encoder?.onEncodedFrame = { [weak self] data in
            self?.onEncodedFrame?(data)
        }

        // Create and start stream
        stream = SCStream(filter: filter, configuration: config, delegate: self)

        try stream?.addStreamOutput(self, type: .screen, sampleHandlerQueue: .global(qos: .userInteractive))
        try await stream?.startCapture()

        log("Screen capture started!")
    }

    func stop() async {
        try? await stream?.stopCapture()
        stream = nil
        encoder = nil
    }

    // MARK: SCStreamOutput

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen else { return }
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }

        let timestamp = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        encoder?.encode(pixelBuffer: pixelBuffer, timestamp: timestamp)
    }

    // MARK: SCStreamDelegate

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        log("Stream stopped with error: \(error)")
        onStreamError?(error)
    }

    enum CaptureError: Error {
        case noDisplayFound
    }
}

// MARK: - Socket Server

class SocketServer {
    private var serverSocket: Int32 = -1
    private var clientSocket: Int32 = -1
    private let port: UInt16
    private var isRunning = false

    init(port: UInt16) {
        self.port = port
    }

    func start() throws {
        serverSocket = socket(AF_INET, SOCK_STREAM, 0)
        guard serverSocket >= 0 else {
            throw SocketError.failedToCreate
        }

        var reuse: Int32 = 1
        setsockopt(serverSocket, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout<Int32>.size))

        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        addr.sin_addr.s_addr = INADDR_ANY

        let bindResult = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(serverSocket, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }

        guard bindResult == 0 else {
            throw SocketError.failedToBind
        }

        guard listen(serverSocket, 5) == 0 else {
            throw SocketError.failedToListen
        }

        isRunning = true
        log("Socket server listening on port \(port)")
    }

    func acceptClient() -> Bool {
        var clientAddr = sockaddr_in()
        var clientAddrLen = socklen_t(MemoryLayout<sockaddr_in>.size)

        let socket = withUnsafeMutablePointer(to: &clientAddr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                accept(serverSocket, $0, &clientAddrLen)
            }
        }

        if socket >= 0 {
            // Close previous client if any
            if clientSocket >= 0 {
                close(clientSocket)
            }
            clientSocket = socket
            log("Client connected!")
            return true
        }
        return false
    }

    func disconnectClient() {
        if clientSocket >= 0 {
            close(clientSocket)
            clientSocket = -1
        }
    }

    func hasClient() -> Bool {
        return clientSocket >= 0
    }

    func send(data: Data) -> Bool {
        guard clientSocket >= 0 else { return false }

        // Send frame length first (4 bytes, big endian)
        var length = UInt32(data.count).bigEndian
        let lenResult = Darwin.send(clientSocket, &length, 4, 0)

        if lenResult <= 0 {
            log("Failed to send length, closing client")
            close(clientSocket)
            clientSocket = -1
            return false
        }

        // Send frame data
        let dataResult = data.withUnsafeBytes { buffer in
            Darwin.send(clientSocket, buffer.baseAddress!, data.count, 0)
        }

        if dataResult <= 0 {
            log("Failed to send data, closing client")
            close(clientSocket)
            clientSocket = -1
            return false
        }

        return true
    }

    func stop() {
        isRunning = false
        if clientSocket >= 0 {
            close(clientSocket)
            clientSocket = -1
        }
        if serverSocket >= 0 {
            close(serverSocket)
            serverSocket = -1
        }
    }

    enum SocketError: Error {
        case failedToCreate
        case failedToBind
        case failedToListen
        case acceptFailed
    }
}

// MARK: - Touch Input Server

class TouchInputServer {
    private var serverSocket: Int32 = -1
    private var clientSocket: Int32 = -1
    private let port: UInt16
    private var isRunning = false
    private let injector: TouchInjector

    init(port: UInt16, displayID: CGDirectDisplayID) {
        self.port = port
        self.injector = TouchInjector(displayID: displayID)
    }

    func updateDisplayID(_ displayID: CGDirectDisplayID) {
        injector.updateDisplayID(displayID)
    }

    func start() throws {
        serverSocket = socket(AF_INET, SOCK_STREAM, 0)
        guard serverSocket >= 0 else {
            throw SocketServer.SocketError.failedToCreate
        }

        var reuse: Int32 = 1
        setsockopt(serverSocket, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout<Int32>.size))

        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        addr.sin_addr.s_addr = INADDR_ANY

        let bindResult = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(serverSocket, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }

        guard bindResult == 0 else {
            throw SocketServer.SocketError.failedToBind
        }

        guard listen(serverSocket, 5) == 0 else {
            throw SocketServer.SocketError.failedToListen
        }

        isRunning = true
        log("Touch input server listening on port \(port)")

        // Start accepting clients in background
        DispatchQueue.global(qos: .userInteractive).async { [weak self] in
            self?.acceptLoop()
        }
    }

    private func acceptLoop() {
        while isRunning {
            var clientAddr = sockaddr_in()
            var clientAddrLen = socklen_t(MemoryLayout<sockaddr_in>.size)

            let socket = withUnsafeMutablePointer(to: &clientAddr) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    accept(serverSocket, $0, &clientAddrLen)
                }
            }

            if socket >= 0 {
                // Close previous client if any
                if clientSocket >= 0 {
                    close(clientSocket)
                }
                clientSocket = socket
                log("Touch client connected!")

                // Start reading touch events
                readTouchEvents()
            }
        }
    }

    private func readTouchEvents() {
        // Pen event types (10-13) have extended data
        let PEN_DOWN: UInt8 = 10
        let PEN_MOVE: UInt8 = 11
        let PEN_UP: UInt8 = 12
        let PEN_HOVER: UInt8 = 13

        while isRunning && clientSocket >= 0 {
            // First read just the event type (1 byte)
            var eventType: UInt8 = 0
            let typeRead = recv(clientSocket, &eventType, 1, 0)

            if typeRead <= 0 {
                log("Touch client disconnected")
                close(clientSocket)
                clientSocket = -1
                break
            }

            // Determine packet size based on event type
            let isPenEvent = eventType >= PEN_DOWN && eventType <= PEN_HOVER
            let remainingBytes = isPenEvent ? 20 : 8  // Pen: x(4)+y(4)+pressure(4)+tiltX(4)+tiltY(4)=20, Touch: x(4)+y(4)=8

            var buffer = [UInt8](repeating: 0, count: remainingBytes)
            var totalRead = 0

            // Read remaining bytes (may need multiple recv calls)
            while totalRead < remainingBytes {
                let bytesRead = buffer.withUnsafeMutableBytes { ptr in
                    recv(clientSocket, ptr.baseAddress! + totalRead, remainingBytes - totalRead, 0)
                }
                if bytesRead <= 0 {
                    log("Touch client disconnected during read")
                    close(clientSocket)
                    clientSocket = -1
                    return
                }
                totalRead += bytesRead
            }

            // Parse floats (big endian from Java DataOutputStream)
            let xBits = UInt32(buffer[0]) << 24 | UInt32(buffer[1]) << 16 | UInt32(buffer[2]) << 8 | UInt32(buffer[3])
            let yBits = UInt32(buffer[4]) << 24 | UInt32(buffer[5]) << 16 | UInt32(buffer[6]) << 8 | UInt32(buffer[7])

            let x = Float(bitPattern: xBits)
            let y = Float(bitPattern: yBits)

            if isPenEvent {
                // Parse additional pen data
                let pressureBits = UInt32(buffer[8]) << 24 | UInt32(buffer[9]) << 16 | UInt32(buffer[10]) << 8 | UInt32(buffer[11])
                let tiltXBits = UInt32(buffer[12]) << 24 | UInt32(buffer[13]) << 16 | UInt32(buffer[14]) << 8 | UInt32(buffer[15])
                let tiltYBits = UInt32(buffer[16]) << 24 | UInt32(buffer[17]) << 16 | UInt32(buffer[18]) << 8 | UInt32(buffer[19])

                let pressure = Float(bitPattern: pressureBits)
                let tiltX = Float(bitPattern: tiltXBits)
                let tiltY = Float(bitPattern: tiltYBits)

                // Inject pen event with pressure
                injector.injectPen(type: eventType, normalizedX: x, normalizedY: y, pressure: pressure, tiltX: tiltX, tiltY: tiltY)
            } else {
                // Inject regular touch event
                injector.injectTouch(type: eventType, normalizedX: x, normalizedY: y)
            }
        }
    }

    func stop() {
        isRunning = false
        if clientSocket >= 0 {
            close(clientSocket)
            clientSocket = -1
        }
        if serverSocket >= 0 {
            close(serverSocket)
            serverSocket = -1
        }
    }
}

// MARK: - Touch Injector (converts touch to mouse events)

class TouchInjector {
    private var displayID: CGDirectDisplayID
    private var isMouseDown = false
    private var isPenDown = false

    // Touch event types (matching Android)
    private let TOUCH_DOWN: UInt8 = 0
    private let TOUCH_MOVE: UInt8 = 1
    private let TOUCH_UP: UInt8 = 2

    // Pen event types (matching Android)
    private let PEN_DOWN: UInt8 = 10
    private let PEN_MOVE: UInt8 = 11
    private let PEN_UP: UInt8 = 12
    private let PEN_HOVER: UInt8 = 13

    init(displayID: CGDirectDisplayID) {
        self.displayID = displayID
    }

    func updateDisplayID(_ newDisplayID: CGDirectDisplayID) {
        self.displayID = newDisplayID
    }

    func injectTouch(type: UInt8, normalizedX: Float, normalizedY: Float) {
        // Get the display bounds
        let bounds = CGDisplayBounds(displayID)

        // Convert normalized coordinates to screen coordinates
        let screenX = bounds.origin.x + CGFloat(normalizedX) * bounds.width
        let screenY = bounds.origin.y + CGFloat(normalizedY) * bounds.height

        let point = CGPoint(x: screenX, y: screenY)

        switch type {
        case TOUCH_DOWN:
            // Mouse down
            if let event = CGEvent(mouseEventSource: nil, mouseType: .leftMouseDown, mouseCursorPosition: point, mouseButton: .left) {
                event.post(tap: .cghidEventTap)
                isMouseDown = true
            }

        case TOUCH_MOVE:
            // Mouse drag (if down) or move
            let eventType: CGEventType = isMouseDown ? .leftMouseDragged : .mouseMoved
            if let event = CGEvent(mouseEventSource: nil, mouseType: eventType, mouseCursorPosition: point, mouseButton: .left) {
                event.post(tap: .cghidEventTap)
            }

        case TOUCH_UP:
            // Mouse up
            if let event = CGEvent(mouseEventSource: nil, mouseType: .leftMouseUp, mouseCursorPosition: point, mouseButton: .left) {
                event.post(tap: .cghidEventTap)
                isMouseDown = false
            }

        default:
            break
        }
    }

    func injectPen(type: UInt8, normalizedX: Float, normalizedY: Float, pressure: Float, tiltX: Float, tiltY: Float) {
        // Get the display bounds
        let bounds = CGDisplayBounds(displayID)

        // Convert normalized coordinates to screen coordinates
        let screenX = bounds.origin.x + CGFloat(normalizedX) * bounds.width
        let screenY = bounds.origin.y + CGFloat(normalizedY) * bounds.height

        let point = CGPoint(x: screenX, y: screenY)

        switch type {
        case PEN_DOWN:
            // Pen down - use tablet event with pressure
            if let event = CGEvent(mouseEventSource: nil, mouseType: .leftMouseDown, mouseCursorPosition: point, mouseButton: .left) {
                // Set tablet pressure (0.0 to 1.0 maps to 0 to 65535)
                event.setDoubleValueField(.tabletEventPointPressure, value: Double(pressure))
                event.setIntegerValueField(.tabletEventPointButtons, value: 1)
                event.post(tap: .cghidEventTap)
                isPenDown = true
            }

        case PEN_MOVE:
            // Pen drag with pressure
            let eventType: CGEventType = isPenDown ? .leftMouseDragged : .mouseMoved
            if let event = CGEvent(mouseEventSource: nil, mouseType: eventType, mouseCursorPosition: point, mouseButton: .left) {
                event.setDoubleValueField(.tabletEventPointPressure, value: Double(pressure))
                if isPenDown {
                    event.setIntegerValueField(.tabletEventPointButtons, value: 1)
                }
                event.post(tap: .cghidEventTap)
            }

        case PEN_UP:
            // Pen up
            if let event = CGEvent(mouseEventSource: nil, mouseType: .leftMouseUp, mouseCursorPosition: point, mouseButton: .left) {
                event.setDoubleValueField(.tabletEventPointPressure, value: 0)
                event.post(tap: .cghidEventTap)
                isPenDown = false
            }

        case PEN_HOVER:
            // Pen hovering (no button pressed)
            if let event = CGEvent(mouseEventSource: nil, mouseType: .mouseMoved, mouseCursorPosition: point, mouseButton: .left) {
                // Hovering events can still include proximity data
                event.setDoubleValueField(.tabletEventPointPressure, value: 0)
                event.post(tap: .cghidEventTap)
            }

        default:
            break
        }
    }
}

// MARK: - Streaming Controller (handles reconnection and sleep/wake)

class StreamingController {
    private let virtualDisplayManager = VirtualDisplayManager()
    private var virtualDisplayID: CGDirectDisplayID?
    private let server: SocketServer
    private var touchServer: TouchInputServer?
    private var capturer: ScreenCapturer?

    private var frameCount = 0
    private var lastReportTime = Date()
    private var totalBytesSent = 0

    private var isPaused = false
    private var shouldRestart = false
    private var isStreaming = false

    init(videoPort: UInt16, touchPort: UInt16) {
        self.server = SocketServer(port: videoPort)
        setupSleepWakeNotifications()
    }

    func startTouchServer(port: UInt16) {
        guard let displayID = virtualDisplayID else {
            log("Cannot start touch server: no virtual display")
            return
        }

        touchServer = TouchInputServer(port: port, displayID: displayID)
        do {
            try touchServer?.start()
        } catch {
            log("Failed to start touch server: \(error)")
        }
    }

    func updateTouchDisplayID() {
        if let displayID = virtualDisplayID {
            touchServer?.updateDisplayID(displayID)
        }
    }

    private func setupSleepWakeNotifications() {
        // Listen for sleep notification
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.willSleepNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.handleWillSleep()
        }

        // Listen for wake notification
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.handleDidWake()
        }

        // Listen for screen sleep/wake
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.screensDidSleepNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            log("Screens did sleep")
            self?.isPaused = true
        }

        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.screensDidWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            log("Screens did wake")
            self?.shouldRestart = true
        }
    }

    private func handleWillSleep() {
        log("System will sleep - pausing stream")
        isPaused = true
    }

    private func handleDidWake() {
        log("System did wake - will restart stream")
        shouldRestart = true
    }

    func createVirtualDisplay() async -> Bool {
        log("Creating virtual display...")
        let created = virtualDisplayManager.createDisplay(
            withWidth: Int32(Config.targetWidth),
            height: Int32(Config.targetHeight),
            ppi: 110,
            hiDPI: false,
            name: "USB Tablet Display"
        )

        if created {
            virtualDisplayID = virtualDisplayManager.displayID
            log("Virtual display created with ID: \(virtualDisplayID!)")

            // Give the system time to recognize the new display
            log("Waiting for display to be recognized...")
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            return true
        } else {
            log("WARNING: Failed to create virtual display, will capture main display instead")
            return false
        }
    }

    func recreateVirtualDisplay() async {
        // Don't destroy the virtual display - just check if it's still valid
        // CGVirtualDisplay cannot be reliably recreated in the same process
        if virtualDisplayManager.isActive && virtualDisplayID != nil {
            log("Virtual display still active (ID: \(virtualDisplayID!))")
            return
        }

        log("Attempting to create virtual display...")

        // Wait a moment for system to stabilize
        try? await Task.sleep(nanoseconds: 1_000_000_000)

        if await createVirtualDisplay() {
            // Update touch server with new display ID
            updateTouchDisplayID()
        } else {
            // Fall back to main display - set virtualDisplayID to nil
            // so ScreenCapturer uses the first available display
            virtualDisplayID = nil
            log("Will use main display as fallback")
        }
    }

    func startServer() throws {
        try server.start()
    }

    func waitForClient() async {
        log("Waiting for Android client to connect...")
        log("Start the USB Display app on your Android device")

        while !server.acceptClient() {
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
    }

    func startCapture() async throws {
        capturer = ScreenCapturer()

        // Set up error handler for stream recovery
        capturer?.onStreamError = { [weak self] error in
            log("Stream error detected, will restart...")
            self?.shouldRestart = true
        }

        // Set up frame callback
        capturer?.onEncodedFrame = { [weak self] data in
            guard let self = self, !self.isPaused else { return }

            if self.server.send(data: data) {
                self.frameCount += 1
                self.totalBytesSent += data.count

                // Report stats every second
                let now = Date()
                if now.timeIntervalSince(self.lastReportTime) >= 1.0 {
                    let mbps = Double(self.totalBytesSent) * 8.0 / 1_000_000.0
                    log("Streaming: \(self.frameCount) fps, \(String(format: "%.1f", mbps)) Mbps")
                    self.frameCount = 0
                    self.totalBytesSent = 0
                    self.lastReportTime = now
                }
            } else {
                // Client disconnected
                log("Client disconnected, will wait for reconnection...")
                self.shouldRestart = true
            }
        }

        try await capturer?.start(displayID: virtualDisplayID)
        isStreaming = true
        log("Streaming started! Press Ctrl+C to stop.")
    }

    func stopCapture() async {
        isStreaming = false
        await capturer?.stop()
        capturer = nil
    }

    func run() async {
        // Main run loop with recovery
        while true {
            // Check if we need to restart
            if shouldRestart {
                shouldRestart = false
                isPaused = false

                log("Restarting stream...")
                await stopCapture()

                // Recreate virtual display if needed
                await recreateVirtualDisplay()

                // Wait for client if disconnected
                if !server.hasClient() {
                    log("Waiting for client to reconnect...")
                    await waitForClient()
                }

                // Restart capture
                do {
                    try await startCapture()
                } catch {
                    log("Failed to restart capture: \(error)")
                    // Wait before retrying
                    try? await Task.sleep(nanoseconds: 2_000_000_000)
                    shouldRestart = true
                }
            }

            // Check if paused (during sleep)
            if isPaused && isStreaming {
                log("Stream paused")
                await stopCapture()
            }

            try? await Task.sleep(nanoseconds: 500_000_000) // Check every 500ms
        }
    }

    func cleanup() {
        touchServer?.stop()
        virtualDisplayManager.destroyDisplay()
        server.stop()
    }
}

// MARK: - Main Application

@main
struct USBDisplayApp {
    static func main() async {
        log("USB Display Host - Starting...")
        log("Resolution: \(Config.targetWidth)x\(Config.targetHeight) @ \(Config.frameRate)fps")
        log("")
        log("IMPORTANT: Before running, execute:")
        log("  adb reverse tcp:\(Config.videoPort) tcp:\(Config.videoPort)")
        log("  adb reverse tcp:\(Config.touchPort) tcp:\(Config.touchPort)")
        log("")

        let controller = StreamingController(videoPort: Config.videoPort, touchPort: Config.touchPort)

        // Set up signal handler for clean shutdown
        signal(SIGINT) { _ in
            log("\nShutting down...")
            exit(0)
        }

        do {
            // Create virtual display
            _ = await controller.createVirtualDisplay()

            // Start video socket server
            try controller.startServer()

            // Start touch input server
            controller.startTouchServer(port: Config.touchPort)

            // Wait for initial client
            await controller.waitForClient()

            // Start capture
            try await controller.startCapture()

            // Run main loop (handles reconnection and sleep/wake)
            await controller.run()

        } catch {
            log("Error: \(error)")
        }

        controller.cleanup()
    }
}
