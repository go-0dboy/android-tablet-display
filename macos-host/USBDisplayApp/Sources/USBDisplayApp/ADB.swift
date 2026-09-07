// ADB.swift — talking to the Android device over USB.
//
// The transport is `adb reverse`: the client dials 127.0.0.1 on the phone and
// adb forwards that to the host's listening socket over the USB cable. No
// accessory mode, no tethering, no root — which is why it works on a stock
// One UI device with nothing but USB debugging turned on.

import Foundation
import USBDisplayCore

struct CommandResult {
    var exitCode: Int32
    var output: String
}

/// Run a command, capturing stdout+stderr. Bounded so a hung adb cannot wedge
/// the app.
@discardableResult
func runCommand(_ launchPath: String, _ arguments: [String],
                timeout: TimeInterval = 15) -> CommandResult {
    let process = Process()
    let pipe = Pipe()
    process.executableURL = URL(fileURLWithPath: launchPath)
    process.arguments = arguments
    process.standardOutput = pipe
    process.standardError = pipe

    do { try process.run() } catch {
        return CommandResult(exitCode: -1, output: error.localizedDescription)
    }

    // Read on a background thread: a full pipe buffer with no reader is the
    // classic way to deadlock waitUntilExit().
    var data = Data()
    let readQueue = DispatchQueue(label: "adb.read")
    let done = DispatchSemaphore(value: 0)
    readQueue.async {
        data = pipe.fileHandleForReading.readDataToEndOfFile()
        done.signal()
    }

    let deadline = Date().addingTimeInterval(timeout)
    while process.isRunning && Date() < deadline {
        Thread.sleep(forTimeInterval: 0.02)
    }
    if process.isRunning {
        process.terminate()
        _ = done.wait(timeout: .now() + 1)
        return CommandResult(exitCode: -1, output: "timed out after \(Int(timeout))s")
    }
    _ = done.wait(timeout: .now() + 2)
    return CommandResult(exitCode: process.terminationStatus,
                         output: String(data: data, encoding: .utf8) ?? "")
}

final class ADBManager {
    enum ADBError: Error, LocalizedError {
        case notFound
        case noDevice
        case commandFailed(String)

        var errorDescription: String? {
            switch self {
            case .notFound:
                return "adb was not found. Install it with: brew install --cask android-platform-tools"
            case .noDevice:
                return "No Android device is ready."
            case .commandFailed(let msg):
                return msg
            }
        }
    }

    private(set) var adbPath: String?
    private(set) var devices: [AndroidDevice] = []
    private(set) var selected: AndroidDevice?
    /// Set from the menu when the user pins a device. Persisted.
    var preferredSerial: String? {
        didSet { UserDefaults.standard.set(preferredSerial, forKey: "preferredDeviceSerial") }
    }

    static let packageName = "com.usbtablet.display"

    init() {
        preferredSerial = UserDefaults.standard.string(forKey: "preferredDeviceSerial")
        findADB()
    }

    private func findADB() {
        let candidates = [
            "\(NSHomeDirectory())/Library/Android/sdk/platform-tools/adb",
            "/opt/homebrew/bin/adb",
            "/usr/local/bin/adb",
            "/opt/homebrew/share/android-commandlinetools/platform-tools/adb"
        ]
        for path in candidates where FileManager.default.fileExists(atPath: path) {
            adbPath = path
            log("Found adb at \(path)")
            return
        }
        let which = runCommand("/usr/bin/which", ["adb"], timeout: 5)
        if which.exitCode == 0 {
            let trimmed = which.output.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { adbPath = trimmed; log("Found adb via which: \(trimmed)") }
        }
        if adbPath == nil { log("adb was not found on this Mac") }
    }

    // MARK: - Devices

    /// Refresh the device list. Returns true if the selected device changed.
    @discardableResult
    func refreshDevices() -> Bool {
        guard let adb = adbPath else { return false }
        let result = runCommand(adb, ["devices", "-l"], timeout: 10)
        let parsed = ADBOutputParser.parseDevices(result.output)
        let newSelection = ADBOutputParser.selectDevice(from: parsed,
                                                        preferredSerial: preferredSerial)
        let changed = newSelection?.serial != selected?.serial
        devices = parsed
        selected = newSelection

        if changed {
            if let device = newSelection {
                // Log the label, never the raw serial — logs get pasted into
                // issues and a serial identifies the handset.
                log("Device ready: \(device.displayLabel) over \(device.transport)")
            } else {
                log("No device ready")
            }
        }
        return changed
    }

    /// Devices that are attached but unusable, with the reason.
    var blockedDeviceHints: [String] {
        ADBOutputParser.blockedDevices(from: devices).map { device in
            switch device.state {
            case .unauthorized:
                return "\(device.displayLabel): tap “Allow” on the USB debugging prompt"
            case .offline:
                return "\(device.displayLabel): offline — unplug and replug the cable"
            default:
                return "\(device.displayLabel): \(device.state.rawValue)"
            }
        }
    }

    // MARK: - Port forwarding

    func setupReverse(videoPort: UInt16, inputPort: UInt16) throws {
        guard let adb = adbPath else { throw ADBError.notFound }
        guard let device = selected else { throw ADBError.noDevice }

        for port in [videoPort, inputPort] {
            let result = runCommand(adb, ["-s", device.serial, "reverse",
                                          "tcp:\(port)", "tcp:\(port)"], timeout: 10)
            guard result.exitCode == 0 else {
                throw ADBError.commandFailed(
                    "adb reverse failed for port \(port). \(reverseFailureHint(result.output))")
            }
        }
        log("Reverse forwards established on \(videoPort) and \(inputPort)")
    }

    /// `adb reverse` fails in a small number of recognisable ways; say which.
    private func reverseFailureHint(_ output: String) -> String {
        let lower = output.lowercased()
        if lower.contains("more than one device") {
            return "More than one device is attached — pin one from the Device menu."
        }
        if lower.contains("device unauthorized") || lower.contains("unauthorized") {
            return "The device has not accepted this Mac. Tap “Allow” on the USB debugging prompt."
        }
        if lower.contains("closed") {
            return "The device dropped off the cable. Try a different cable or port — "
                 + "a charge-only cable carries no data."
        }
        return output.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func removeReverse(videoPort: UInt16, inputPort: UInt16) {
        guard let adb = adbPath, let device = selected else { return }
        for port in [videoPort, inputPort] {
            _ = runCommand(adb, ["-s", device.serial, "reverse", "--remove", "tcp:\(port)"],
                           timeout: 5)
        }
    }

    // MARK: - App control

    func launchClient(wireless: Bool = false) {
        guard let adb = adbPath, let device = selected else { return }
        _ = runCommand(adb, ["-s", device.serial, "shell", "am", "force-stop",
                             Self.packageName], timeout: 10)
        var args = ["-s", device.serial, "shell", "am", "start", "-n",
                    "\(Self.packageName)/.MainActivity"]
        if wireless {
            args += ["--ez", "wireless", "true"]
        }
        let result = runCommand(adb, args, timeout: 15)
        if result.exitCode == 0 && !result.output.lowercased().contains("error") {
            log("Client launched on \(device.displayLabel)")
        } else {
            log("Could not launch the client: \(result.output.trimmingCharacters(in: .whitespacesAndNewlines))")
            log("Is the app installed? Run: adb install -r android-client/app/build/outputs/apk/debug/app-debug.apk")
        }
    }

    func stopClient() {
        guard let adb = adbPath, let device = selected else { return }
        _ = runCommand(adb, ["-s", device.serial, "shell", "am", "force-stop",
                             Self.packageName], timeout: 10)
    }

    var isClientInstalled: Bool {
        guard let adb = adbPath, let device = selected else { return false }
        let result = runCommand(adb, ["-s", device.serial, "shell", "pm", "list", "packages",
                                      Self.packageName], timeout: 10)
        return result.output.contains(Self.packageName)
    }

    /// Broadcast a setting change to a running client.
    func sendClientAction(_ action: String, extras: [String: String] = [:]) {
        guard let adb = adbPath, let device = selected else { return }
        var args = ["-s", device.serial, "shell", "am", "broadcast",
                    "-a", "\(Self.packageName).\(action)",
                    "-p", Self.packageName]
        for (key, value) in extras { args += ["--es", key, value] }
        _ = runCommand(adb, args, timeout: 10)
    }

    // MARK: - Samsung / One UI diagnostics

    /// What One UI has the USB port set to. adb works in every one of these
    /// modes as long as USB debugging is on, so this exists to answer the
    /// "I set it to File Transfer and it still doesn't work" question with a
    /// fact rather than a guess.
    func usbModeDescription() -> String? {
        guard let adb = adbPath, let device = selected, device.transport == .usb else { return nil }
        let result = runCommand(adb, ["-s", device.serial, "shell", "getprop", "sys.usb.config"],
                                timeout: 8)
        guard result.exitCode == 0 else { return nil }
        let raw = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else { return nil }

        // Values look like "mtp,adb" / "rndis,adb" / "midi,adb" / "adb".
        let parts = Set(raw.split(separator: ",").map(String.init))
        var described: [String] = []
        if parts.contains("mtp") { described.append("File transfer") }
        if parts.contains("ptp") { described.append("Photo transfer") }
        if parts.contains("rndis") || parts.contains("ncm") { described.append("USB tethering") }
        if parts.contains("midi") { described.append("MIDI") }
        if described.isEmpty { described.append("Charging only") }
        let hasADB = parts.contains("adb")
        return described.joined(separator: " + ") + (hasADB ? " + debugging" : " (no debugging!)")
    }

    /// Samsung DeX takes over the display pipeline when it starts, which can
    /// move or pause the client activity. Detect it so the log says why the
    /// stream stopped instead of leaving the user guessing.
    func isDeXActive() -> Bool {
        guard let adb = adbPath, let device = selected else { return false }
        // Samsung exposes DeX state as a system setting on One UI.
        let result = runCommand(adb, ["-s", device.serial, "shell",
                                      "settings", "get", "global", "semdesktopmode"],
                                timeout: 8)
        let value = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
        return value == "1" || value == "4"
    }

    /// Physical screen metrics, as a fallback if the client never says hello.
    func deviceMetrics() -> (width: Int, height: Int, density: Int)? {
        guard let adb = adbPath, let device = selected else { return nil }

        let size = runCommand(adb, ["-s", device.serial, "shell", "wm", "size"], timeout: 8)
        let density = runCommand(adb, ["-s", device.serial, "shell", "wm", "density"], timeout: 8)

        func lastNumberPair(_ text: String) -> (Int, Int)? {
            // "Physical size: 1080x2340" and possibly "Override size: ..."
            let lines = text.components(separatedBy: .newlines).filter { $0.contains("x") }
            guard let line = lines.last,
                  let range = line.range(of: #"(\d+)x(\d+)"#, options: .regularExpression) else { return nil }
            let pair = line[range].split(separator: "x").compactMap { Int($0) }
            guard pair.count == 2 else { return nil }
            return (pair[0], pair[1])
        }
        func lastNumber(_ text: String) -> Int? {
            let lines = text.components(separatedBy: .newlines).filter { $0.contains(":") }
            guard let line = lines.last,
                  let range = line.range(of: #"(\d+)"#, options: .regularExpression, range: line.range(of: ":")!.upperBound..<line.endIndex)
            else { return nil }
            return Int(line[range])
        }

        guard let (w, h) = lastNumberPair(size.output) else { return nil }
        return (w, h, lastNumber(density.output) ?? 160)
    }

    /// Convenience for the docs/receipt: the exact command a person can run.
    func installCommandHint(apkPath: String) -> String {
        let serialPart = selected.map { "-s \($0.serial) " } ?? ""
        return "adb \(serialPart)install -r \(apkPath)"
    }
}
