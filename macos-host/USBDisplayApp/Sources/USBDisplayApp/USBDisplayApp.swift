import Foundation
import ScreenCaptureKit
import VideoToolbox
import CoreMedia
import AppKit
import VirtualDisplay

// MARK: - Configuration

struct Config {
    static let targetWidth: Int32 = 2560
    static let targetHeight: Int32 = 1600
    static let frameRate: Int = 60
    static let videoPort: UInt16 = 5560
    static let touchPort: UInt16 = 5561
    static let bitRate: Int32 = 15_000_000
}

// MARK: - Logging

class Logger {
    static let shared = Logger()
    var onLog: ((String) -> Void)?

    func log(_ message: String) {
        let timestamp = DateFormatter.localizedString(from: Date(), dateStyle: .none, timeStyle: .medium)
        let logMessage = "[\(timestamp)] \(message)"
        print(logMessage)
        fflush(stdout)
        DispatchQueue.main.async {
            self.onLog?(logMessage)
        }
    }
}

func log(_ message: String) {
    Logger.shared.log(message)
}

// MARK: - ADB Manager

class ADBManager {
    enum ADBError: Error, LocalizedError {
        case notFound
        case noDevice
        case commandFailed(String)

        var errorDescription: String? {
            switch self {
            case .notFound: return "ADB not found"
            case .noDevice: return "No Android device connected"
            case .commandFailed(let msg): return "ADB command failed: \(msg)"
            }
        }
    }

    private(set) var adbPath: String?
    private(set) var deviceSerial: String?
    private var portForwardsActive = false

    init() {
        findADB()
    }

    private func findADB() {
        // Check common locations
        let possiblePaths = [
            "/opt/homebrew/bin/adb",
            "/usr/local/bin/adb",
            "\(NSHomeDirectory())/Library/Android/sdk/platform-tools/adb",
            "/Applications/Android Studio.app/Contents/jbr/Contents/Home/../../../platform-tools/adb"
        ]

        for path in possiblePaths {
            if FileManager.default.fileExists(atPath: path) {
                adbPath = path
                log("Found ADB at: \(path)")
                return
            }
        }

        // Try which command
        let result = runCommand("/usr/bin/which", arguments: ["adb"])
        if result.exitCode == 0, !result.output.isEmpty {
            adbPath = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
            log("Found ADB via which: \(adbPath!)")
        }
    }

    func checkDevice() -> Bool {
        guard let adb = adbPath else { return false }

        let result = runCommand(adb, arguments: ["devices"])
        let lines = result.output.components(separatedBy: "\n")

        for line in lines {
            if line.contains("\tdevice") {
                let serial = line.components(separatedBy: "\t").first ?? ""
                if !serial.isEmpty {
                    deviceSerial = serial
                    return true
                }
            }
        }

        deviceSerial = nil
        return false
    }

    func setupPortForwards() throws {
        guard let adb = adbPath else { throw ADBError.notFound }
        guard let device = deviceSerial else { throw ADBError.noDevice }

        // Set up reverse port forwards
        let videoResult = runCommand(adb, arguments: ["-s", device, "reverse", "tcp:\(Config.videoPort)", "tcp:\(Config.videoPort)"])
        if videoResult.exitCode != 0 {
            throw ADBError.commandFailed("Failed to set up video port forward: \(videoResult.output)")
        }
        log("Video port forward established: \(Config.videoPort)")

        let touchResult = runCommand(adb, arguments: ["-s", device, "reverse", "tcp:\(Config.touchPort)", "tcp:\(Config.touchPort)"])
        if touchResult.exitCode != 0 {
            throw ADBError.commandFailed("Failed to set up touch port forward: \(touchResult.output)")
        }
        log("Touch port forward established: \(Config.touchPort)")

        portForwardsActive = true
    }

    func removePortForwards() {
        guard let adb = adbPath, let device = deviceSerial else { return }

        _ = runCommand(adb, arguments: ["-s", device, "reverse", "--remove", "tcp:\(Config.videoPort)"])
        _ = runCommand(adb, arguments: ["-s", device, "reverse", "--remove", "tcp:\(Config.touchPort)"])

        portForwardsActive = false
        log("Port forwards removed")
    }

    func launchAndroidApp() {
        guard let adb = adbPath, let device = deviceSerial else { return }

        // Force stop first
        _ = runCommand(adb, arguments: ["-s", device, "shell", "am", "force-stop", "com.usbtablet.display"])

        // Launch app
        let result = runCommand(adb, arguments: ["-s", device, "shell", "am", "start", "-n", "com.usbtablet.display/.MainActivity"])
        if result.exitCode == 0 {
            log("Android app launched")
        } else {
            log("Failed to launch Android app: \(result.output)")
        }
    }

    func stopAndroidApp() {
        guard let adb = adbPath, let device = deviceSerial else { return }
        _ = runCommand(adb, arguments: ["-s", device, "shell", "am", "force-stop", "com.usbtablet.display"])
        log("Android app stopped")
    }

    private func runCommand(_ command: String, arguments: [String]) -> (exitCode: Int32, output: String) {
        let process = Process()
        let pipe = Pipe()

        process.executableURL = URL(fileURLWithPath: command)
        process.arguments = arguments
        process.standardOutput = pipe
        process.standardError = pipe

        do {
            try process.run()
            process.waitUntilExit()

            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let output = String(data: data, encoding: .utf8) ?? ""

            return (process.terminationStatus, output)
        } catch {
            return (-1, error.localizedDescription)
        }
    }
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

        // Use Main profile for good quality/compression balance
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_ProfileLevel, value: kVTProfileLevel_H264_Main_AutoLevel)

        // Real-time encoding
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_RealTime, value: kCFBooleanTrue)

        // Bitrate
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_AverageBitRate, value: Config.bitRate as CFNumber)

        // Keyframe interval
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_MaxKeyFrameInterval, value: Config.frameRate * 2 as CFNumber)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_ExpectedFrameRate, value: Config.frameRate as CFNumber)

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

        let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false)
        var isKeyframe = true
        if let attachments = attachments, CFArrayGetCount(attachments) > 0 {
            let attachment = unsafeBitCast(CFArrayGetValueAtIndex(attachments, 0), to: CFDictionary.self)
            if let notSync = CFDictionaryGetValue(attachment, Unmanaged.passUnretained(kCMSampleAttachmentKey_NotSync).toOpaque()) {
                isKeyframe = !(unsafeBitCast(notSync, to: CFBoolean.self) == kCFBooleanTrue)
            }
        }

        var frameData = Data()

        if isKeyframe {
            if let formatDesc = CMSampleBufferGetFormatDescription(sampleBuffer) {
                var spsSize: Int = 0
                var spsCount: Int = 0
                var spsPointer: UnsafePointer<UInt8>?
                CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
                    formatDesc, parameterSetIndex: 0,
                    parameterSetPointerOut: &spsPointer, parameterSetSizeOut: &spsSize,
                    parameterSetCountOut: &spsCount, nalUnitHeaderLengthOut: nil
                )

                if let sps = spsPointer {
                    frameData.append(contentsOf: [0x00, 0x00, 0x00, 0x01])
                    frameData.append(UnsafeBufferPointer(start: sps, count: spsSize))
                }

                var ppsSize: Int = 0
                var ppsPointer: UnsafePointer<UInt8>?
                CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
                    formatDesc, parameterSetIndex: 1,
                    parameterSetPointerOut: &ppsPointer, parameterSetSizeOut: &ppsSize,
                    parameterSetCountOut: nil, nalUnitHeaderLengthOut: nil
                )

                if let pps = ppsPointer {
                    frameData.append(contentsOf: [0x00, 0x00, 0x00, 0x01])
                    frameData.append(UnsafeBufferPointer(start: pps, count: ppsSize))
                }
            }
        }

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

        var display: SCDisplay?
        if let targetID = displayID {
            display = content.displays.first { $0.displayID == targetID }
            if display == nil {
                log("WARNING: Target display ID \(targetID) not found, using first display")
                display = content.displays.first
            }
        } else {
            display = content.displays.first
        }

        guard let display = display else {
            throw CaptureError.noDisplayFound
        }

        log("Capturing display ID \(display.displayID): \(display.width)x\(display.height)")

        let filter = SCContentFilter(display: display, excludingWindows: [])

        let config = SCStreamConfiguration()
        config.width = Int(Config.targetWidth)
        config.height = Int(Config.targetHeight)
        config.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(Config.frameRate))
        config.pixelFormat = kCVPixelFormatType_32BGRA
        config.showsCursor = true
        config.queueDepth = 2  // Minimum queue depth for lowest latency
        config.scalesToFit = true

        encoder = try H264Encoder()
        encoder?.onEncodedFrame = { [weak self] data in
            self?.onEncodedFrame?(data)
        }

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

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen else { return }
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }

        let timestamp = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        encoder?.encode(pixelBuffer: pixelBuffer, timestamp: timestamp)
    }

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
            if clientSocket >= 0 {
                close(clientSocket)
            }
            clientSocket = socket

            // Enable TCP_NODELAY for low latency (disable Nagle's algorithm)
            var noDelay: Int32 = 1
            setsockopt(clientSocket, IPPROTO_TCP, TCP_NODELAY, &noDelay, socklen_t(MemoryLayout<Int32>.size))

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

        var length = UInt32(data.count).bigEndian
        let lenResult = Darwin.send(clientSocket, &length, 4, 0)

        if lenResult <= 0 {
            close(clientSocket)
            clientSocket = -1
            return false
        }

        let dataResult = data.withUnsafeBytes { buffer in
            Darwin.send(clientSocket, buffer.baseAddress!, data.count, 0)
        }

        if dataResult <= 0 {
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
                if clientSocket >= 0 {
                    close(clientSocket)
                }
                clientSocket = socket
                log("Touch client connected!")
                readTouchEvents()
            }
        }
    }

    private func readTouchEvents() {
        let PEN_DOWN: UInt8 = 10
        let PEN_MOVE: UInt8 = 11
        let PEN_UP: UInt8 = 12
        let PEN_HOVER: UInt8 = 13

        while isRunning && clientSocket >= 0 {
            var eventType: UInt8 = 0
            let typeRead = recv(clientSocket, &eventType, 1, 0)

            if typeRead <= 0 {
                log("Touch client disconnected")
                close(clientSocket)
                clientSocket = -1
                break
            }

            let isPenEvent = eventType >= PEN_DOWN && eventType <= PEN_HOVER
            let remainingBytes = isPenEvent ? 20 : 8

            var buffer = [UInt8](repeating: 0, count: remainingBytes)
            var totalRead = 0

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

            let xBits = UInt32(buffer[0]) << 24 | UInt32(buffer[1]) << 16 | UInt32(buffer[2]) << 8 | UInt32(buffer[3])
            let yBits = UInt32(buffer[4]) << 24 | UInt32(buffer[5]) << 16 | UInt32(buffer[6]) << 8 | UInt32(buffer[7])

            let x = Float(bitPattern: xBits)
            let y = Float(bitPattern: yBits)

            if isPenEvent {
                let pressureBits = UInt32(buffer[8]) << 24 | UInt32(buffer[9]) << 16 | UInt32(buffer[10]) << 8 | UInt32(buffer[11])
                let tiltXBits = UInt32(buffer[12]) << 24 | UInt32(buffer[13]) << 16 | UInt32(buffer[14]) << 8 | UInt32(buffer[15])
                let tiltYBits = UInt32(buffer[16]) << 24 | UInt32(buffer[17]) << 16 | UInt32(buffer[18]) << 8 | UInt32(buffer[19])

                let pressure = Float(bitPattern: pressureBits)
                let tiltX = Float(bitPattern: tiltXBits)
                let tiltY = Float(bitPattern: tiltYBits)

                injector.injectPen(type: eventType, normalizedX: x, normalizedY: y, pressure: pressure, tiltX: tiltX, tiltY: tiltY)
            } else {
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

// MARK: - Touch Injector

class TouchInjector {
    private var displayID: CGDirectDisplayID
    private var isMouseDown = false
    private var isPenDown = false

    private let TOUCH_DOWN: UInt8 = 0
    private let TOUCH_MOVE: UInt8 = 1
    private let TOUCH_UP: UInt8 = 2

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
        let bounds = CGDisplayBounds(displayID)
        let screenX = bounds.origin.x + CGFloat(normalizedX) * bounds.width
        let screenY = bounds.origin.y + CGFloat(normalizedY) * bounds.height
        let point = CGPoint(x: screenX, y: screenY)

        switch type {
        case TOUCH_DOWN:
            if let event = CGEvent(mouseEventSource: nil, mouseType: .leftMouseDown, mouseCursorPosition: point, mouseButton: .left) {
                event.post(tap: .cghidEventTap)
                isMouseDown = true
            }
        case TOUCH_MOVE:
            let eventType: CGEventType = isMouseDown ? .leftMouseDragged : .mouseMoved
            if let event = CGEvent(mouseEventSource: nil, mouseType: eventType, mouseCursorPosition: point, mouseButton: .left) {
                event.post(tap: .cghidEventTap)
            }
        case TOUCH_UP:
            if let event = CGEvent(mouseEventSource: nil, mouseType: .leftMouseUp, mouseCursorPosition: point, mouseButton: .left) {
                event.post(tap: .cghidEventTap)
                isMouseDown = false
            }
        default:
            break
        }
    }

    func injectPen(type: UInt8, normalizedX: Float, normalizedY: Float, pressure: Float, tiltX: Float, tiltY: Float) {
        let bounds = CGDisplayBounds(displayID)
        let screenX = bounds.origin.x + CGFloat(normalizedX) * bounds.width
        let screenY = bounds.origin.y + CGFloat(normalizedY) * bounds.height
        let point = CGPoint(x: screenX, y: screenY)

        switch type {
        case PEN_DOWN:
            if let event = CGEvent(mouseEventSource: nil, mouseType: .leftMouseDown, mouseCursorPosition: point, mouseButton: .left) {
                event.setDoubleValueField(.tabletEventPointPressure, value: Double(pressure))
                event.setIntegerValueField(.tabletEventPointButtons, value: 1)
                event.post(tap: .cghidEventTap)
                isPenDown = true
            }
        case PEN_MOVE:
            let eventType: CGEventType = isPenDown ? .leftMouseDragged : .mouseMoved
            if let event = CGEvent(mouseEventSource: nil, mouseType: eventType, mouseCursorPosition: point, mouseButton: .left) {
                event.setDoubleValueField(.tabletEventPointPressure, value: Double(pressure))
                if isPenDown {
                    event.setIntegerValueField(.tabletEventPointButtons, value: 1)
                }
                event.post(tap: .cghidEventTap)
            }
        case PEN_UP:
            if let event = CGEvent(mouseEventSource: nil, mouseType: .leftMouseUp, mouseCursorPosition: point, mouseButton: .left) {
                event.setDoubleValueField(.tabletEventPointPressure, value: 0)
                event.post(tap: .cghidEventTap)
                isPenDown = false
            }
        case PEN_HOVER:
            if let event = CGEvent(mouseEventSource: nil, mouseType: .mouseMoved, mouseCursorPosition: point, mouseButton: .left) {
                event.setDoubleValueField(.tabletEventPointPressure, value: 0)
                event.post(tap: .cghidEventTap)
            }
        default:
            break
        }
    }
}

// MARK: - Streaming Controller

class StreamingController: ObservableObject {
    private let virtualDisplayManager = VirtualDisplayManager()
    private var virtualDisplayID: CGDirectDisplayID?
    private var server: SocketServer?
    private var touchServer: TouchInputServer?
    private var capturer: ScreenCapturer?

    private var frameCount = 0
    private var lastReportTime = Date()
    private var totalBytesSent = 0

    private var isPaused = false
    private var shouldRestart = false

    @Published var isStreaming = false
    @Published var fps: Double = 0
    @Published var bitrate: String = "0 Mbps"
    @Published var clientConnected = false

    init() {
        setupSleepWakeNotifications()
    }

    private func setupSleepWakeNotifications() {
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.willSleepNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.handleWillSleep()
        }

        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.handleDidWake()
        }

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
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            return true
        } else {
            log("WARNING: Failed to create virtual display, will capture main display instead")
            return false
        }
    }

    func recreateVirtualDisplay() async {
        if virtualDisplayManager.isActive && virtualDisplayID != nil {
            log("Virtual display still active (ID: \(virtualDisplayID!))")
            return
        }

        log("Attempting to create virtual display...")
        try? await Task.sleep(nanoseconds: 1_000_000_000)

        if await createVirtualDisplay() {
            touchServer?.updateDisplayID(virtualDisplayID!)
        } else {
            virtualDisplayID = nil
            log("Will use main display as fallback")
        }
    }

    func start() async throws {
        guard !isStreaming else { return }

        // Create virtual display
        _ = await createVirtualDisplay()

        // Create and start video server
        server = SocketServer(port: Config.videoPort)
        try server?.start()

        // Create and start touch server
        if let displayID = virtualDisplayID {
            touchServer = TouchInputServer(port: Config.touchPort, displayID: displayID)
            try touchServer?.start()
        }

        // Wait for client
        log("Waiting for Android client to connect...")
        while server?.acceptClient() == false {
            try? await Task.sleep(nanoseconds: 100_000_000)
        }

        DispatchQueue.main.async {
            self.clientConnected = true
        }

        // Start capture
        try await startCapture()

        DispatchQueue.main.async {
            self.isStreaming = true
        }

        // Run main loop
        await runLoop()
    }

    private func startCapture() async throws {
        capturer = ScreenCapturer()

        capturer?.onStreamError = { [weak self] error in
            log("Stream error detected, will restart...")
            self?.shouldRestart = true
        }

        capturer?.onEncodedFrame = { [weak self] data in
            guard let self = self, !self.isPaused else { return }

            if self.server?.send(data: data) == true {
                self.frameCount += 1
                self.totalBytesSent += data.count

                let now = Date()
                if now.timeIntervalSince(self.lastReportTime) >= 1.0 {
                    let fps = Double(self.frameCount)
                    let mbps = Double(self.totalBytesSent) * 8.0 / 1_000_000.0

                    DispatchQueue.main.async {
                        self.fps = fps
                        self.bitrate = String(format: "%.1f Mbps", mbps)
                    }

                    self.frameCount = 0
                    self.totalBytesSent = 0
                    self.lastReportTime = now
                }
            } else {
                log("Client disconnected, will wait for reconnection...")
                DispatchQueue.main.async {
                    self.clientConnected = false
                }
                self.shouldRestart = true
            }
        }

        try await capturer?.start(displayID: virtualDisplayID)
        log("Streaming started!")
    }

    private func stopCapture() async {
        await capturer?.stop()
        capturer = nil
    }

    private func runLoop() async {
        while isStreaming {
            if shouldRestart {
                shouldRestart = false
                isPaused = false

                log("Restarting stream...")
                await stopCapture()

                await recreateVirtualDisplay()

                if server?.hasClient() == false {
                    log("Waiting for client to reconnect...")
                    while server?.acceptClient() == false {
                        try? await Task.sleep(nanoseconds: 100_000_000)
                        if !isStreaming { return }
                    }
                    DispatchQueue.main.async {
                        self.clientConnected = true
                    }
                }

                do {
                    try await startCapture()
                } catch {
                    log("Failed to restart capture: \(error)")
                    try? await Task.sleep(nanoseconds: 2_000_000_000)
                    shouldRestart = true
                }
            }

            if isPaused && capturer != nil {
                log("Stream paused")
                await stopCapture()
            }

            try? await Task.sleep(nanoseconds: 500_000_000)
        }
    }

    func stop() async {
        isStreaming = false
        clientConnected = false
        fps = 0
        bitrate = "0 Mbps"

        await stopCapture()
        touchServer?.stop()
        touchServer = nil
        server?.stop()
        server = nil
        virtualDisplayManager.destroyDisplay()
        virtualDisplayID = nil

        log("Streaming stopped")
    }
}

// MARK: - Permission Manager

class PermissionManager {
    enum PermissionStatus {
        case granted
        case denied
        case unknown
    }

    // Check if we have screen recording permission
    static func checkScreenRecordingPermission() -> PermissionStatus {
        // Try to get shareable content - this will fail if no permission
        let hasPermission = CGPreflightScreenCaptureAccess()
        return hasPermission ? .granted : .denied
    }

    // Request screen recording permission (triggers system dialog)
    static func requestScreenRecordingPermission() {
        // This triggers the permission dialog
        CGRequestScreenCaptureAccess()
    }

    // Check if we have accessibility permission (for touch injection)
    static func checkAccessibilityPermission() -> Bool {
        // Check if we're trusted for accessibility
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: false] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }

    // Request accessibility permission (opens System Preferences)
    static func requestAccessibilityPermission() {
        // This opens the accessibility preferences with a prompt
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        AXIsProcessTrustedWithOptions(options)
    }

    // Open System Preferences to the appropriate pane
    static func openScreenRecordingPreferences() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
            NSWorkspace.shared.open(url)
        }
    }

    static func openAccessibilityPreferences() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }
}

// MARK: - App Delegate (Menu Bar)

class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var adbManager: ADBManager!
    private var streamingController: StreamingController!
    private var streamTask: Task<Void, Never>?
    private var logWindow: NSWindow?
    private var logTextView: NSTextView?
    private var logBuffer: [String] = []
    private var hasScreenRecordingPermission = false
    private var hasAccessibilityPermission = false
    private var showFpsOnAndroid = true

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Hide dock icon
        NSApp.setActivationPolicy(.accessory)

        // Initialize managers
        adbManager = ADBManager()
        streamingController = StreamingController()

        // Set up logging
        Logger.shared.onLog = { [weak self] message in
            self?.appendLog(message)
        }

        // Create status bar item
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "display", accessibilityDescription: "USB Display")
            button.image?.isTemplate = true
        }

        log("USB Display App started")

        // Check permissions on launch
        checkPermissions()

        updateMenu()

        log("Looking for Android device...")

        // Check for device periodically
        Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            self?.checkDevice()
        }

        // Also check permissions periodically (in case user grants them)
        Timer.scheduledTimer(withTimeInterval: 3.0, repeats: true) { [weak self] _ in
            self?.checkPermissions()
        }
    }

    private func checkPermissions() {
        let hadScreen = hasScreenRecordingPermission
        let hadAccessibility = hasAccessibilityPermission

        hasScreenRecordingPermission = PermissionManager.checkScreenRecordingPermission() == .granted
        hasAccessibilityPermission = PermissionManager.checkAccessibilityPermission()

        // Log changes
        if hasScreenRecordingPermission != hadScreen {
            if hasScreenRecordingPermission {
                log("Screen Recording permission granted")
            }
            updateMenu()
        }

        if hasAccessibilityPermission != hadAccessibility {
            if hasAccessibilityPermission {
                log("Accessibility permission granted")
            }
            updateMenu()
        }

        // Log missing permissions on first check
        if !hadScreen && !hasScreenRecordingPermission {
            log("Screen Recording permission required")
        }
        if !hadAccessibility && !hasAccessibilityPermission {
            log("Accessibility permission required (for touch input)")
        }
    }

    private func checkDevice() {
        let hadDevice = adbManager.deviceSerial != nil
        let hasDevice = adbManager.checkDevice()

        if hasDevice != hadDevice {
            updateMenu()
            if hasDevice {
                log("Device connected: \(adbManager.deviceSerial ?? "unknown")")
            } else {
                log("Device disconnected")
            }
        }
    }

    private func updateMenu() {
        let menu = NSMenu()

        // Status section
        let statusTitle = streamingController.isStreaming ? "Streaming" : "Stopped"
        let statusItem = NSMenuItem(title: "Status: \(statusTitle)", action: nil, keyEquivalent: "")
        statusItem.isEnabled = false
        menu.addItem(statusItem)

        if streamingController.isStreaming {
            let fpsItem = NSMenuItem(title: String(format: "  FPS: %.0f", streamingController.fps), action: nil, keyEquivalent: "")
            fpsItem.isEnabled = false
            menu.addItem(fpsItem)

            let bitrateItem = NSMenuItem(title: "  Bitrate: \(streamingController.bitrate)", action: nil, keyEquivalent: "")
            bitrateItem.isEnabled = false
            menu.addItem(bitrateItem)
        }

        menu.addItem(NSMenuItem.separator())

        // Permissions section (show if any missing)
        let needsPermissions = !hasScreenRecordingPermission || !hasAccessibilityPermission
        if needsPermissions {
            let permHeader = NSMenuItem(title: "Permissions Required:", action: nil, keyEquivalent: "")
            permHeader.isEnabled = false
            menu.addItem(permHeader)

            if !hasScreenRecordingPermission {
                let screenItem = NSMenuItem(title: "  Grant Screen Recording...", action: #selector(requestScreenRecording), keyEquivalent: "")
                menu.addItem(screenItem)
            } else {
                let screenOk = NSMenuItem(title: "  Screen Recording: OK", action: nil, keyEquivalent: "")
                screenOk.isEnabled = false
                menu.addItem(screenOk)
            }

            if !hasAccessibilityPermission {
                let accessItem = NSMenuItem(title: "  Grant Accessibility...", action: #selector(requestAccessibility), keyEquivalent: "")
                menu.addItem(accessItem)
            } else {
                let accessOk = NSMenuItem(title: "  Accessibility: OK", action: nil, keyEquivalent: "")
                accessOk.isEnabled = false
                menu.addItem(accessOk)
            }

            menu.addItem(NSMenuItem.separator())
        }

        // Device section
        if let device = adbManager.deviceSerial {
            let deviceItem = NSMenuItem(title: "Device: \(device)", action: nil, keyEquivalent: "")
            deviceItem.isEnabled = false
            menu.addItem(deviceItem)
        } else {
            let noDeviceItem = NSMenuItem(title: "No device connected", action: nil, keyEquivalent: "")
            noDeviceItem.isEnabled = false
            menu.addItem(noDeviceItem)
        }

        if adbManager.adbPath == nil {
            let noAdbItem = NSMenuItem(title: "ADB not found", action: nil, keyEquivalent: "")
            noAdbItem.isEnabled = false
            menu.addItem(noAdbItem)
        }

        menu.addItem(NSMenuItem.separator())

        // Actions
        if streamingController.isStreaming {
            menu.addItem(NSMenuItem(title: "Stop Streaming", action: #selector(stopStreaming), keyEquivalent: "s"))
        } else {
            let startItem = NSMenuItem(title: "Start Streaming", action: #selector(startStreaming), keyEquivalent: "s")
            // Only enable if we have permissions and a device
            let canStart = hasScreenRecordingPermission && adbManager.deviceSerial != nil && adbManager.adbPath != nil
            startItem.isEnabled = canStart
            menu.addItem(startItem)
        }

        let launchAppItem = NSMenuItem(title: "Launch Android App", action: #selector(launchAndroidApp), keyEquivalent: "l")
        launchAppItem.isEnabled = adbManager.deviceSerial != nil
        menu.addItem(launchAppItem)

        menu.addItem(NSMenuItem.separator())

        menu.addItem(NSMenuItem(title: "Show Log", action: #selector(showLog), keyEquivalent: "o"))

        // FPS toggle
        let fpsToggleItem = NSMenuItem(title: showFpsOnAndroid ? "Hide FPS on Android" : "Show FPS on Android", action: #selector(toggleFps), keyEquivalent: "f")
        fpsToggleItem.isEnabled = adbManager.deviceSerial != nil
        menu.addItem(fpsToggleItem)

        menu.addItem(NSMenuItem.separator())

        menu.addItem(NSMenuItem(title: "Quit", action: #selector(quit), keyEquivalent: "q"))

        self.statusItem.menu = menu
    }

    @objc private func requestScreenRecording() {
        log("Requesting Screen Recording permission...")
        PermissionManager.requestScreenRecordingPermission()
        // Also open preferences in case the dialog doesn't appear
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            PermissionManager.openScreenRecordingPreferences()
        }
    }

    @objc private func requestAccessibility() {
        log("Requesting Accessibility permission...")
        PermissionManager.requestAccessibilityPermission()
    }

    @objc private func startStreaming() {
        guard !streamingController.isStreaming else { return }

        log("Starting streaming...")

        // Set up ADB port forwards
        do {
            try adbManager.setupPortForwards()
        } catch {
            log("Failed to set up port forwards: \(error)")
            return
        }

        // Launch Android app
        adbManager.launchAndroidApp()

        // Start streaming in background
        streamTask = Task {
            do {
                try await streamingController.start()
            } catch {
                log("Streaming error: \(error)")
                await streamingController.stop()
                adbManager.removePortForwards()
            }

            DispatchQueue.main.async {
                self.updateMenu()
            }
        }

        // Update menu after a short delay
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
            self.updateMenu()
        }

        // Start periodic menu updates
        Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] timer in
            guard let self = self else {
                timer.invalidate()
                return
            }
            if !self.streamingController.isStreaming {
                timer.invalidate()
            }
            self.updateMenu()
        }
    }

    @objc private func stopStreaming() {
        log("Stopping streaming...")

        streamTask?.cancel()
        streamTask = nil

        Task {
            await streamingController.stop()
            adbManager.stopAndroidApp()
            adbManager.removePortForwards()

            DispatchQueue.main.async {
                self.updateMenu()
            }
        }
    }

    @objc private func launchAndroidApp() {
        adbManager.launchAndroidApp()
    }

    @objc private func toggleFps() {
        showFpsOnAndroid = !showFpsOnAndroid

        // Send broadcast to Android app to toggle FPS display
        guard let adb = adbManager.adbPath, let device = adbManager.deviceSerial else { return }

        let action = showFpsOnAndroid ? "SHOW_FPS" : "HIDE_FPS"
        let result = Process()
        result.executableURL = URL(fileURLWithPath: adb)
        result.arguments = ["-s", device, "shell", "am", "broadcast", "-a", "com.usbtablet.display.\(action)"]
        try? result.run()

        log("FPS display: \(showFpsOnAndroid ? "shown" : "hidden")")
        updateMenu()
    }

    @objc private func showLog() {
        if logWindow == nil {
            createLogWindow()
        }
        logWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func createLogWindow() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 600, height: 400),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "USB Display Log"
        window.center()

        let scrollView = NSScrollView(frame: window.contentView!.bounds)
        scrollView.autoresizingMask = [.width, .height]
        scrollView.hasVerticalScroller = true

        let textView = NSTextView(frame: scrollView.bounds)
        textView.autoresizingMask = [.width, .height]
        textView.isEditable = false
        textView.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        textView.backgroundColor = NSColor.textBackgroundColor

        scrollView.documentView = textView
        window.contentView?.addSubview(scrollView)

        self.logWindow = window
        self.logTextView = textView

        // Add existing log buffer
        for line in logBuffer {
            textView.string += line + "\n"
        }
    }

    private func appendLog(_ message: String) {
        logBuffer.append(message)
        if logBuffer.count > 1000 {
            logBuffer.removeFirst()
        }

        if let textView = logTextView {
            textView.string += message + "\n"
            textView.scrollToEndOfDocument(nil)
        }
    }

    @objc private func quit() {
        if streamingController.isStreaming {
            Task {
                await streamingController.stop()
                adbManager.stopAndroidApp()
                adbManager.removePortForwards()

                DispatchQueue.main.async {
                    NSApp.terminate(nil)
                }
            }
        } else {
            NSApp.terminate(nil)
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        if streamingController.isStreaming {
            adbManager.stopAndroidApp()
            adbManager.removePortForwards()
        }
    }
}

// MARK: - Main Entry Point

@main
struct USBDisplayApp {
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.run()
    }
}
