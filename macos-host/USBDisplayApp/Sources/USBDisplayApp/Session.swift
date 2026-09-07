// Session.swift — one streaming session, from "a client connected" to "the
// display went away".
//
// The order of operations matters and is different from v1. v1 created a
// hardcoded 2560x1600 display before anyone connected, then streamed to
// whoever showed up. Here the client says hello first, and the display is
// built to match the panel it will actually be shown on — which is what makes
// the scale, the density and the aspect ratio come out right.

import Foundation
import CoreGraphics
import AppKit
import VirtualDisplay
import USBDisplayCore

/// How the client is reaching us.
enum TransportMode: String, CaseIterable {
    case usb
    case wireless

    var title: String {
        switch self {
        case .usb: return "USB (cable)"
        case .wireless: return "Wi-Fi (same network)"
        }
    }
}

struct SessionStats {
    var fps: Double = 0
    var megabitsPerSecond: Double = 0
    var droppedFrames = 0
    var clientName: String = ""
    var displaySize: String = ""
    /// Capture-to-encoded time on the host, in milliseconds. This is the
    /// portion of the pipeline the host can measure directly; it excludes the
    /// wire and everything on the tablet.
    var encodeMedianMs: Double = 0
    var encodeWorstMs: Double = 0
}

@MainActor
final class StreamingSession: ObservableObject {

    private let virtualDisplay = VirtualDisplayManager()
    private var videoServer: VideoServer?
    private var inputServer: InputServer?
    private var capturer: ScreenCapturer?
    private var injector: InputInjector?

    private(set) var displayID: CGDirectDisplayID = 0
    private(set) var isRunning = false
    private(set) var clientConnected = false
    private(set) var stats = SessionStats()
    private(set) var lastError: String?

    /// True once a wireless client has proved it is paired, or immediately
    /// over USB.
    var isClientAuthenticated: Bool { transport == .usb || isAuthenticated }

    /// Settings, owned by the menu.
    var codec: VideoCodec = .h264
    var frameRate = 60
    var bitRate: Int32 = 15_000_000
    var touchMode: TouchMode = .pointer {
        didSet { injector?.touchMode = touchMode }
    }
    var zoomStrategy: ZoomStrategy = .keyboardSteps {
        didSet { injector?.zoomStrategy = zoomStrategy }
    }
    var transport: TransportMode = .usb
    /// Desktop scale on the tablet. Changing it rebuilds the display, because
    /// the mode has to change underneath macOS.
    var scalePreference: ScalePreference = .automatic

    /// Wireless sessions must authenticate before a single frame is sent.
    /// Over USB the cable is the authorisation and this stays nil.
    var pairing: PairingController?
    private var isAuthenticated = false

    var onStateChanged: (() -> Void)?

    // Frame accounting.
    private var frameCount = 0
    private var byteCount = 0
    private var statsTimer: Timer?
    private var statsTick = 0
    private var restartWorkItem: DispatchWorkItem?
    /// Kept so a scale change can rebuild the display without waiting for the
    /// client to reconnect and say hello again.
    private var lastHello: ClientHello?

    // MARK: - Lifecycle

    func start(videoPort: UInt16, inputPort: UInt16, loopbackOnly: Bool) throws {
        guard !isRunning else { return }
        lastError = nil

        let video = VideoServer(port: videoPort, loopbackOnly: loopbackOnly)
        let input = InputServer(port: inputPort, loopbackOnly: loopbackOnly)

        video.onClientConnected = { [weak self] in
            Task { @MainActor in self?.capturer?.forceKeyframe() }
        }
        video.onClientDisconnected = { [weak self] in
            Task { @MainActor in self?.handleClientGone() }
        }
        input.onMessage = { [weak self] message in
            Task { @MainActor in self?.handle(message) }
        }
        input.onClientDisconnected = { [weak self] in
            Task { @MainActor in self?.handleClientGone() }
        }

        try video.start()
        try input.start()

        videoServer = video
        inputServer = input
        isRunning = true

        // The system can pull the virtual display out from under us across a
        // sleep/wake cycle; rebuild rather than stream into a void.
        virtualDisplay.onTerminated = { [weak self] in
            Task { @MainActor in
                log("The virtual display was terminated by the system; rebuilding")
                self?.displayID = 0
                self?.scheduleRestart()
            }
        }

        observeSleepWake()
        startStatsTimer()
        log("Session started, waiting for a client on \(videoPort)/\(inputPort)")
        onStateChanged?()
    }

    func stop() async {
        guard isRunning else { return }
        isRunning = false
        restartWorkItem?.cancel()
        statsTimer?.invalidate(); statsTimer = nil

        injector?.resetState()
        isAuthenticated = false
        await capturer?.stop()
        capturer = nil
        inputServer?.stop(); inputServer = nil
        videoServer?.stop(); videoServer = nil
        virtualDisplay.destroyDisplay()
        displayID = 0
        clientConnected = false
        stats = SessionStats()
        log("Session stopped")
        onStateChanged?()
    }

    // MARK: - Client handshake

    private func handle(_ message: InputMessage) {
        // Over Wi-Fi, nothing but the pairing handshake is honoured until the
        // device has proved it is trusted. Without this gate anything on the
        // network could receive a live video feed of the Mac's screen.
        if transport == .wireless && !isAuthenticated {
            switch message {
            case .pairRequest, .pairProof:
                break
            default:
                return
            }
        }

        switch message {
        case .hello(let hello):
            handleHello(hello)
        case .touch(let event):
            injector?.handle(touch: event)
        case .pen(let event):
            injector?.handle(pen: event)
        case .scroll(let event):
            injector?.handle(scroll: event)
        case .pinch(let event):
            injector?.handle(pinch: event)
        case .keepAlive:
            inputServer?.send(.keepAlive)

        case .pairRequest(let request):
            guard let pairing else { return }
            let response = pairing.handle(request: request,
                                          wirelessEnabled: transport == .wireless)
            inputServer?.send(.pairResponse(response))
            if response.status == .rejected {
                inputServer?.send(.pairResult(PairResult(
                    accepted: false, message: "This Mac is not accepting wireless devices.")))
            }

        case .pairProof(let proof):
            guard let pairing else { return }
            if pairing.verify(proof: proof) {
                isAuthenticated = true
                inputServer?.send(.pairResult(PairResult(accepted: true, message: "Paired")))
                log("Wireless client authenticated")
            } else {
                inputServer?.send(.pairResult(PairResult(
                    accepted: false,
                    message: "Not paired yet — confirm the code on the Mac.")))
            }
            onStateChanged?()

        case .helloAck, .pairResponse, .pairResult, .unknown:
            break
        }
    }

    private func handleHello(_ hello: ClientHello) {
        log("Client says hello: \(hello.deviceName), \(hello.widthPixels)x\(hello.heightPixels) "
            + "@ \(hello.densityDpi)dpi, rotation \(hello.rotationDegrees)°")

        if hello.protocolVersion != WireProtocol.version {
            log("Protocol mismatch: client speaks v\(hello.protocolVersion), "
                + "host speaks v\(WireProtocol.version). Update the other side.")
            inputServer?.send(.helloAck(HelloAck(
                accepted: false, displayWidth: 0, displayHeight: 0,
                message: "Host speaks protocol v\(WireProtocol.version)")))
            return
        }
        if hello.flags.contains(.dexActive) {
            log("Samsung DeX is active on the client. DeX takes over the display "
                + "pipeline; if the stream stalls, turn DeX off.")
        }

        lastHello = hello
        let spec = DisplayGeometry.spec(for: hello, refreshRate: Double(frameRate),
                                        scale: scalePreference)
        guard createDisplay(spec: spec) else {
            inputServer?.send(.helloAck(HelloAck(
                accepted: false, displayWidth: 0, displayHeight: 0,
                message: lastError ?? "Could not create a display")))
            return
        }

        clientConnected = true
        stats.clientName = hello.deviceName
        stats.displaySize = "\(spec.pixelWidth)x\(spec.pixelHeight)"
            + (spec.hiDPI ? " HiDPI" : "")

        inputServer?.send(.helloAck(HelloAck(
            accepted: true,
            displayWidth: UInt32(spec.pixelWidth), displayHeight: UInt32(spec.pixelHeight),
            message: "\(spec.pixelWidth)x\(spec.pixelHeight)")))

        Task { await startCapture(spec: spec) }
        onStateChanged?()
    }

    private func createDisplay(spec: VirtualDisplaySpec) -> Bool {
        let objc = makeParameters(spec)
        guard virtualDisplay.createDisplay(spec: objc) else {
            lastError = virtualDisplay.lastError
                ?? "The virtual display could not be created."
            log("Virtual display failed: \(lastError!)")
            return false
        }
        displayID = virtualDisplay.displayID

        if let injector {
            injector.updateDisplayID(displayID)
        } else {
            let created = InputInjector(displayID: displayID)
            created.touchMode = touchMode
            created.zoomStrategy = zoomStrategy
            injector = created
        }
        return true
    }

    private func startCapture(spec: VirtualDisplaySpec) async {
        await capturer?.stop()

        let capturer = ScreenCapturer()
        capturer.onEncodedFrame = { [weak self] data, _ in
            guard let self else { return }
            if self.videoServer?.send(frame: data) == true {
                self.frameCount += 1
                self.byteCount += data.count
            }
        }
        capturer.onStreamError = { [weak self] _ in
            Task { @MainActor in self?.scheduleRestart() }
        }

        do {
            try await capturer.start(
                displayID: displayID,
                settings: EncoderSettings(width: Int32(spec.pixelWidth),
                                          height: Int32(spec.pixelHeight),
                                          frameRate: frameRate,
                                          bitRate: bitRate,
                                          codec: codec))
            self.capturer = capturer
            capturer.forceKeyframe()
        } catch {
            lastError = error.localizedDescription
            log("Capture failed: \(error.localizedDescription)")
            onStateChanged?()
        }
    }

    private func handleClientGone() {
        guard clientConnected else { return }
        clientConnected = false
        // Leave no phantom pen hovering over a display that is going away.
        injector?.resetState()
        stats = SessionStats()
        log("Client disconnected; waiting for it to come back")
        onStateChanged?()

        Task {
            await capturer?.stop()
            capturer = nil
            // The display is torn down too: leaving an orphan virtual display
            // on the desktop after the tablet is unplugged is worse than
            // rebuilding one when it returns.
            virtualDisplay.destroyDisplay()
            displayID = 0
            onStateChanged?()
        }
    }

    /// Rebuild the display at a new scale, reusing what the client already
    /// told us about itself.
    func applyScaleChange() async {
        guard isRunning, let hello = lastHello else { return }
        let spec = DisplayGeometry.spec(for: hello, refreshRate: Double(frameRate),
                                        scale: scalePreference)
        log("Rebuilding the display at \(scalePreference.title.lowercased())")
        await capturer?.stop()
        capturer = nil
        guard createDisplay(spec: spec) else { return }
        stats.displaySize = "\(spec.pixelWidth)x\(spec.pixelHeight)"
            + (spec.hiDPI ? " HiDPI" : "")
        await startCapture(spec: spec)
        onStateChanged?()
    }

    // MARK: - Sleep, wake, restart

    private func observeSleepWake() {
        let center = NSWorkspace.shared.notificationCenter
        center.addObserver(forName: NSWorkspace.didWakeNotification,
                           object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in
                log("The Mac woke; rebuilding the session")
                self?.scheduleRestart()
            }
        }
        center.addObserver(forName: NSWorkspace.screensDidWakeNotification,
                           object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.capturer?.forceKeyframe() }
        }
    }

    /// Coalesce restarts: a wake can fire several notifications at once, and
    /// recreating the display faster than WindowServer settles makes the next
    /// applySettings fail.
    private func scheduleRestart() {
        restartWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            Task { @MainActor in await self?.restart() }
        }
        restartWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5, execute: work)
    }

    private func restart() async {
        guard isRunning else { return }
        await capturer?.stop()
        capturer = nil
        virtualDisplay.destroyDisplay()
        displayID = 0
        clientConnected = false
        // The client reconnects on its own and says hello again, which
        // rebuilds the display at whatever size it is now.
        videoServer?.dropClient()
        onStateChanged?()
    }

    // MARK: - Stats

    private func startStatsTimer() {
        statsTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.stats.fps = Double(self.frameCount)
                self.stats.megabitsPerSecond = Double(self.byteCount) * 8 / 1_000_000
                if let latency = self.capturer?.drainEncodeLatency() {
                    self.stats.encodeMedianMs = latency.median
                    self.stats.encodeWorstMs = latency.worst
                }
                // Log a line every 5s so a session leaves a record of how it
                // actually performed, rather than only showing it in a menu
                // nobody had open at the time.
                self.statsTick += 1
                if self.statsTick % 5 == 0 && self.clientConnected {
                    log(String(format:
                        "%.0f fps · %.1f Mbps · encode %.1f ms median, %.1f ms worst",
                        self.stats.fps, self.stats.megabitsPerSecond,
                        self.stats.encodeMedianMs, self.stats.encodeWorstMs))
                }
                self.frameCount = 0
                self.byteCount = 0
                if self.clientConnected { self.onStateChanged?() }
            }
        }
    }
}

/// Bridge the Swift geometry struct to the Objective-C parameters object.
private func makeParameters(_ spec: USBDisplayCore.VirtualDisplaySpec)
    -> VirtualDisplayParameters {
    VirtualDisplayParameters.make(
        pixelWidth: Int32(spec.pixelWidth), pixelHeight: Int32(spec.pixelHeight),
        pointWidth: Int32(spec.pointWidth), pointHeight: Int32(spec.pointHeight),
        ppi: Int32(spec.ppi), hiDPI: spec.hiDPI,
        refreshRate: spec.refreshRate, name: spec.name)
}
