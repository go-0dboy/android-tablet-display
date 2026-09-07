// main.swift — the menu bar app.
//
// Everything the person can do lives here: start and stop, choose USB or
// Wi-Fi, pick a device, set the touch mode, and manage the Wacom preset.

import Foundation
import AppKit
import CoreGraphics
import ApplicationServices
import USBDisplayCore

// MARK: - Permissions

enum Permissions {
    static var hasScreenRecording: Bool { CGPreflightScreenCaptureAccess() }
    static func requestScreenRecording() { CGRequestScreenCaptureAccess() }

    static var hasAccessibility: Bool {
        AXIsProcessTrustedWithOptions(
            [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: false] as CFDictionary)
    }
    static func requestAccessibility() {
        AXIsProcessTrustedWithOptions(
            [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary)
    }

    static func openScreenRecordingSettings() {
        open("x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")
    }
    static func openAccessibilitySettings() {
        open("x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")
    }
    private static func open(_ string: String) {
        if let url = URL(string: string) { NSWorkspace.shared.open(url) }
    }
}

// MARK: - App

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {

    private var statusItem: NSStatusItem!
    private let adb = ADBManager()
    private let session = StreamingSession()
    private let displays = DisplayManager()
    private let pairing = PairingController()
    private let bonjour = BonjourAdvertiser()

    private var logWindow: NSWindow?
    private var logTextView: NSTextView?

    private var autoConnect = UserDefaults.standard.object(forKey: "autoConnect") as? Bool ?? true
    private var transport: TransportMode = .usb
    private var lastDeviceReady = false

    /// `--start` begins streaming as soon as a device is ready, without
    /// touching the menu. Used by tools/e2e-test.sh and handy for a kiosk-ish
    /// setup where the Mac should just work when the tablet is plugged in.
    private let autoStartRequested = CommandLine.arguments.contains("--start")
    /// `--wireless` selects Wi-Fi mode at launch.
    private let wirelessRequested = CommandLine.arguments.contains("--wireless")

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.image = NSImage(systemSymbolName: "display",
                                           accessibilityDescription: "USB Tablet Display")
        statusItem.button?.image?.isTemplate = true

        Logger.shared.onLog = { [weak self] line in self?.appendLog(line) }

        session.onStateChanged = { [weak self] in self?.rebuildMenu() }
        session.touchMode = TouchMode(
            rawValue: UserDefaults.standard.string(forKey: "touchMode") ?? "") ?? .pointer
        session.pairing = pairing

        pairing.onPairingNeedsConfirmation = { [weak self] pending in
            self?.presentPairingPrompt(pending)
        }

        bonjour.onError = { message in log(message) }

        log("USB Tablet Display started")
        logStartupDiagnostics()

        if wirelessRequested { transport = .wireless }

        adb.refreshDevices()
        rebuildMenu()

        if autoStartRequested {
            log("--start given; connecting as soon as a device is ready")
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                guard let self else { return }
                if self.transport == .wireless || self.adb.selected != nil {
                    self.startStreaming()
                }
            }
        }

        Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.pollDevices() }
        }
        Timer.scheduledTimer(withTimeInterval: 5.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.pollDisplays() }
        }
    }

    private func logStartupDiagnostics() {
        let version = ProcessInfo.processInfo.operatingSystemVersion
        log("macOS \(version.majorVersion).\(version.minorVersion).\(version.patchVersion)")

        if VirtualDisplayManagerBridge.privateAPIAvailable {
            log("Virtual display API: available")
        } else {
            log("Virtual display API: NOT AVAILABLE on this macOS release. "
                + "Run `swift run vdprobe` and see docs/STATUS.md.")
        }
        if !Permissions.hasScreenRecording { log("Screen Recording permission is needed") }
        if !Permissions.hasAccessibility { log("Accessibility permission is needed (for input)") }
    }

    // MARK: - Device polling and auto-connect

    private func pollDevices() {
        let changed = adb.refreshDevices()
        let ready = adb.selected != nil

        // Seamlessness: once a device is trusted, plugging the cable in should
        // be the entire interaction. No taps, no menu.
        if (autoConnect || autoStartRequested) && transport == .usb
            && ready && !lastDeviceReady && !session.isRunning {
            log("Device appeared; connecting automatically")
            startStreaming()
        }
        lastDeviceReady = ready
        if changed { rebuildMenu() }
    }

    private func pollDisplays() {
        guard let pen = DisplayManager.attachedPenDisplay() else { return }
        // Seed a preset the first time a pen display is recognised, but never
        // apply one the person has not asked for.
        if !displays.hasPreset(for: pen.id) {
            displays.seedDefaultPreset(for: pen.id)
            log("Recognised \(PenDisplayIdentifier.label(for: pen.identity)). "
                + "A starting layout has been saved; apply it from the menu.")
            rebuildMenu()
        }
    }

    // MARK: - Start / stop

    private func startStreaming() {
        guard !session.isRunning else { return }
        session.transport = transport

        guard Permissions.hasScreenRecording else {
            log("Cannot start: Screen Recording permission is not granted")
            Permissions.requestScreenRecording()
            return
        }

        do {
            switch transport {
            case .usb:
                guard adb.selected != nil else {
                    log("Cannot start: no Android device is ready")
                    return
                }
                try session.start(videoPort: WireProtocol.defaultVideoPort,
                                  inputPort: WireProtocol.defaultInputPort,
                                  loopbackOnly: true)
                try adb.setupReverse(videoPort: WireProtocol.defaultVideoPort,
                                     inputPort: WireProtocol.defaultInputPort)
                adb.launchClient()

                if let mode = adb.usbModeDescription() { log("USB mode: \(mode)") }
                if adb.isDeXActive() {
                    log("Samsung DeX is on. It takes over the display pipeline — "
                        + "turn it off if the stream misbehaves.")
                }

            case .wireless:
                // Wireless binds every interface, so it is gated on pairing.
                try session.start(videoPort: WireProtocol.defaultVideoPort,
                                  inputPort: WireProtocol.defaultInputPort,
                                  loopbackOnly: false)
                bonjour.start(name: PairingController.hostName,
                              videoPort: WireProtocol.defaultVideoPort,
                              inputPort: WireProtocol.defaultInputPort)
                log("Wireless mode. Open the app on the tablet and pick this Mac.")
            }
        } catch {
            log("Could not start: \(error.localizedDescription)")
            Task { await session.stop() }
        }
        rebuildMenu()
    }

    private func stopStreaming() {
        bonjour.stop()
        Task {
            await session.stop()
            if transport == .usb {
                adb.stopClient()
                adb.removeReverse(videoPort: WireProtocol.defaultVideoPort,
                                  inputPort: WireProtocol.defaultInputPort)
            }
            rebuildMenu()
        }
    }

    // MARK: - Menu

    private func rebuildMenu() {
        let menu = NSMenu()
        menu.autoenablesItems = false

        // Status
        let statusLine: String
        if !session.isRunning {
            statusLine = "Stopped"
        } else if session.clientConnected {
            statusLine = "Streaming to \(session.stats.clientName)"
        } else {
            statusLine = transport == .usb ? "Waiting for the tablet…"
                                           : "Waiting on Wi-Fi…"
        }
        menu.addItem(disabled(statusLine))

        if session.isRunning && session.clientConnected {
            menu.addItem(disabled(String(format: "   %.0f fps · %.1f Mbps",
                                         session.stats.fps, session.stats.megabitsPerSecond)))
            if session.stats.encodeMedianMs > 0 {
                menu.addItem(disabled(String(format: "   encode %.1f ms (worst %.1f)",
                                             session.stats.encodeMedianMs,
                                             session.stats.encodeWorstMs)))
            }
            if !session.stats.displaySize.isEmpty {
                menu.addItem(disabled("   \(session.stats.displaySize)"))
            }
        }
        if let error = session.lastError {
            menu.addItem(disabled("   \(error)"))
        }

        menu.addItem(.separator())

        // Permissions
        if !Permissions.hasScreenRecording || !Permissions.hasAccessibility {
            menu.addItem(disabled("Permissions needed"))
            if !Permissions.hasScreenRecording {
                menu.addItem(action("   Grant Screen Recording…", #selector(grantScreenRecording)))
            }
            if !Permissions.hasAccessibility {
                menu.addItem(action("   Grant Accessibility…", #selector(grantAccessibility)))
            }
            menu.addItem(.separator())
        }

        // Connection
        let connectionItem = NSMenuItem(title: "Connect over", action: nil, keyEquivalent: "")
        let connectionMenu = NSMenu()
        for mode in TransportMode.allCases {
            let item = NSMenuItem(title: mode.title, action: #selector(setTransport(_:)),
                                  keyEquivalent: "")
            item.target = self
            item.state = transport == mode ? .on : .off
            item.representedObject = mode.rawValue
            item.isEnabled = !session.isRunning
            connectionMenu.addItem(item)
        }
        connectionItem.submenu = connectionMenu
        menu.addItem(connectionItem)

        // Device
        if transport == .usb {
            if let device = adb.selected {
                let deviceItem = NSMenuItem(title: "Tablet: \(device.displayLabel)",
                                            action: nil, keyEquivalent: "")
                let deviceMenu = NSMenu()
                for candidate in adb.devices where candidate.state == .device {
                    let item = NSMenuItem(title: candidate.displayLabel,
                                          action: #selector(pinDevice(_:)), keyEquivalent: "")
                    item.target = self
                    item.state = candidate.serial == device.serial ? .on : .off
                    item.representedObject = candidate.serial
                    deviceMenu.addItem(item)
                }
                deviceMenu.addItem(.separator())
                let auto = NSMenuItem(title: "Pick automatically",
                                      action: #selector(unpinDevice), keyEquivalent: "")
                auto.target = self
                auto.state = adb.preferredSerial == nil ? .on : .off
                deviceMenu.addItem(auto)
                deviceItem.submenu = deviceMenu
                menu.addItem(deviceItem)
            } else if adb.adbPath == nil {
                menu.addItem(disabled("adb not found — brew install --cask android-platform-tools"))
            } else {
                menu.addItem(disabled("No tablet connected"))
            }
            for hint in adb.blockedDeviceHints { menu.addItem(disabled("   \(hint)")) }
        } else {
            menu.addItem(disabled(bonjour.isAdvertising
                                  ? "Visible on the network as “\(PairingController.hostName)”"
                                  : "Not advertising yet"))
            if let pending = pairing.pending, !pending.code.isEmpty {
                menu.addItem(disabled("Pairing code: \(pending.code)"))
                menu.addItem(action("   Codes match — pair “\(pending.deviceName)”",
                                    #selector(confirmPairing)))
                menu.addItem(action("   Don't pair", #selector(rejectPairing)))
            }
        }

        menu.addItem(.separator())

        // Start / stop
        if session.isRunning {
            menu.addItem(action("Stop", #selector(stopAction), key: "s"))
        } else {
            let start = action("Start", #selector(startAction), key: "s")
            start.isEnabled = Permissions.hasScreenRecording
                && (transport == .wireless || adb.selected != nil)
            menu.addItem(start)
        }

        menu.addItem(.separator())

        // Input
        let touchItem = NSMenuItem(title: "Touch", action: nil, keyEquivalent: "")
        let touchMenu = NSMenu()
        for mode in TouchMode.allCases {
            let item = NSMenuItem(title: mode.title, action: #selector(setTouchMode(_:)),
                                  keyEquivalent: "")
            item.target = self
            item.state = session.touchMode == mode ? .on : .off
            item.representedObject = mode.rawValue
            touchMenu.addItem(item)
        }
        touchItem.submenu = touchMenu
        menu.addItem(touchItem)

        let autoItem = action("Connect automatically when plugged in", #selector(toggleAutoConnect))
        autoItem.state = autoConnect ? .on : .off
        menu.addItem(autoItem)

        // Pen display
        if let pen = DisplayManager.attachedPenDisplay() {
            menu.addItem(.separator())
            menu.addItem(disabled(PenDisplayIdentifier.label(for: pen.identity)))
            menu.addItem(action("   Apply saved layout", #selector(applyPenPreset)))
            menu.addItem(action("   Save layout as it is now", #selector(savePenPreset)))
        }

        // Paired devices
        if !pairing.trustStore.clients.isEmpty {
            menu.addItem(.separator())
            let paired = NSMenuItem(title: "Paired devices", action: nil, keyEquivalent: "")
            let pairedMenu = NSMenu()
            for client in pairing.trustStore.clients {
                let item = NSMenuItem(title: "Forget “\(client.name)”",
                                      action: #selector(forgetClient(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = client.keyHex
                pairedMenu.addItem(item)
            }
            paired.submenu = pairedMenu
            menu.addItem(paired)
        }

        menu.addItem(.separator())
        menu.addItem(action("Show log", #selector(showLog), key: "l"))
        menu.addItem(action("Quit", #selector(quit), key: "q"))

        statusItem.menu = menu
    }

    private func disabled(_ title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }

    @discardableResult
    private func action(_ title: String, _ selector: Selector, key: String = "") -> NSMenuItem {
        let item = NSMenuItem(title: title, action: selector, keyEquivalent: key)
        item.target = self
        item.isEnabled = true
        return item
    }

    // MARK: - Menu actions

    @objc private func startAction() { startStreaming() }
    @objc private func stopAction() { stopStreaming() }

    @objc private func grantScreenRecording() {
        Permissions.requestScreenRecording()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            Permissions.openScreenRecordingSettings()
        }
    }

    @objc private func grantAccessibility() { Permissions.requestAccessibility() }

    @objc private func setTransport(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let mode = TransportMode(rawValue: raw) else { return }
        transport = mode
        log("Connection set to \(mode.title)")
        rebuildMenu()
    }

    @objc private func setTouchMode(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let mode = TouchMode(rawValue: raw) else { return }
        session.touchMode = mode
        UserDefaults.standard.set(raw, forKey: "touchMode")
        adb.sendClientAction("SET_TOUCH_MODE", extras: ["mode": raw])
        rebuildMenu()
    }

    @objc private func toggleAutoConnect() {
        autoConnect.toggle()
        UserDefaults.standard.set(autoConnect, forKey: "autoConnect")
        rebuildMenu()
    }

    @objc private func pinDevice(_ sender: NSMenuItem) {
        adb.preferredSerial = sender.representedObject as? String
        if wirelessRequested { transport = .wireless }

        adb.refreshDevices()
        rebuildMenu()

        if autoStartRequested {
            log("--start given; connecting as soon as a device is ready")
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                guard let self else { return }
                if self.transport == .wireless || self.adb.selected != nil {
                    self.startStreaming()
                }
            }
        }
    }

    @objc private func unpinDevice() {
        adb.preferredSerial = nil
        if wirelessRequested { transport = .wireless }

        adb.refreshDevices()
        rebuildMenu()

        if autoStartRequested {
            log("--start given; connecting as soon as a device is ready")
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                guard let self else { return }
                if self.transport == .wireless || self.adb.selected != nil {
                    self.startStreaming()
                }
            }
        }
    }

    @objc private func confirmPairing() {
        _ = pairing.confirmPending()
        rebuildMenu()
    }

    @objc private func rejectPairing() {
        pairing.rejectPending()
        rebuildMenu()
    }

    @objc private func forgetClient(_ sender: NSMenuItem) {
        guard let hex = sender.representedObject as? String,
              let client = pairing.trustStore.clients.first(where: { $0.keyHex == hex })
        else { return }
        pairing.forget(client)
        rebuildMenu()
    }

    @objc private func applyPenPreset() {
        guard let pen = DisplayManager.attachedPenDisplay() else { return }
        for line in displays.applyPreset(to: pen.id) { log("  \(line)") }
        log("Pen mapping itself is Wacom's driver, not ours: in Wacom Center set "
            + "the pen's screen area to this display only. See docs/WACOM-MOVINK.md.")
    }

    @objc private func savePenPreset() {
        guard let pen = DisplayManager.attachedPenDisplay() else { return }
        displays.captureCurrentLayout(of: pen.id)
        rebuildMenu()
    }

    private func presentPairingPrompt(_ pending: PairingController.PendingPairing) {
        rebuildMenu()
        let alert = NSAlert()
        alert.messageText = "Pair with “\(pending.deviceName)”?"
        alert.informativeText = "The tablet should be showing this code:\n\n\(pending.code)\n\n"
            + "Pair only if the codes match."
        alert.addButton(withTitle: "Codes match — pair")
        alert.addButton(withTitle: "Don't pair")
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn {
            _ = pairing.confirmPending()
        } else {
            pairing.rejectPending()
        }
        rebuildMenu()
    }

    // MARK: - Log window

    @objc private func showLog() {
        if logWindow == nil { createLogWindow() }
        logWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func createLogWindow() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 720, height: 440),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable],
                              backing: .buffered, defer: false)
        window.title = "USB Tablet Display — log"
        window.center()

        let scrollView = NSScrollView(frame: window.contentView!.bounds)
        scrollView.autoresizingMask = [.width, .height]
        scrollView.hasVerticalScroller = true

        let textView = NSTextView(frame: scrollView.bounds)
        textView.autoresizingMask = [.width, .height]
        textView.isEditable = false
        textView.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        scrollView.documentView = textView
        window.contentView?.addSubview(scrollView)

        textView.string = Logger.shared.recentLines.joined(separator: "\n") + "\n"
        logWindow = window
        logTextView = textView
    }

    private func appendLog(_ line: String) {
        guard let textView = logTextView else { return }
        textView.string += line + "\n"
        textView.scrollToEndOfDocument(nil)
    }

    @objc private func quit() {
        bonjour.stop()
        Task {
            await session.stop()
            if transport == .usb {
                adb.stopClient()
                adb.removeReverse(videoPort: WireProtocol.defaultVideoPort,
                                  inputPort: WireProtocol.defaultInputPort)
            }
            NSApp.terminate(nil)
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        adb.removeReverse(videoPort: WireProtocol.defaultVideoPort,
                          inputPort: WireProtocol.defaultInputPort)
    }
}

/// Small shim so the app can ask about the private API without importing the
/// Objective-C module everywhere.
enum VirtualDisplayManagerBridge {
    static var privateAPIAvailable: Bool {
        NSClassFromString("CGVirtualDisplay") != nil
            && NSClassFromString("CGVirtualDisplayDescriptor") != nil
            && NSClassFromString("CGVirtualDisplaySettings") != nil
            && NSClassFromString("CGVirtualDisplayMode") != nil
    }
}

// MARK: - Entry point

// AppDelegate is main-actor isolated, and main.swift's top level is not, so
// assert the isolation we already have: this code only ever runs on the main
// thread.
MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    // NSApplication keeps only a weak reference to its delegate.
    objc_setAssociatedObject(app, "usbdisplay.delegate", delegate,
                             .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
    app.run()
}
