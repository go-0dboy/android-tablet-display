// AndroidDevice.swift — parsing and ranking the devices adb reports.
//
// The v1 host took the first line of `adb devices` that contained a tab and
// "device". On a machine with an emulator running that is the emulator, so the
// host would happily stream to a simulated phone while the real tablet sat
// plugged in and ignored. Selection is now explicit and testable.

import Foundation

public struct AndroidDevice: Equatable, Sendable {
    public enum State: String, Sendable {
        case device        // ready
        case unauthorized  // plugged in, USB debugging prompt not accepted
        case offline
        case recovery
        case unknown
    }

    public enum Transport: Equatable, Sendable {
        case usb
        case emulator
        /// adb over Wi-Fi: the serial is host:port.
        case network
    }

    public var serial: String
    public var state: State
    public var transport: Transport
    /// From `adb devices -l`, e.g. "SM_S931B".
    public var model: String?
    public var product: String?

    public init(serial: String, state: State, transport: Transport,
                model: String? = nil, product: String? = nil) {
        self.serial = serial
        self.state = state
        self.transport = transport
        self.model = model
        self.product = product
    }

    /// What the menu shows. Never the bare serial when a model is known —
    /// serials are effectively device identifiers and end up in screenshots.
    public var displayLabel: String {
        if let model, !model.isEmpty {
            return model.replacingOccurrences(of: "_", with: " ")
        }
        return serial
    }

    /// Samsung models are SM-xxxx / SM_xxxx; the product string also starts
    /// with a codename we do not try to enumerate.
    public var isProbablySamsung: Bool {
        let m = (model ?? "").uppercased()
        return m.hasPrefix("SM-") || m.hasPrefix("SM_") || m.contains("GALAXY")
    }
}

public enum ADBOutputParser {

    /// Parse the output of `adb devices -l`.
    public static func parseDevices(_ output: String) -> [AndroidDevice] {
        var devices: [AndroidDevice] = []

        for rawLine in output.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty { continue }
            if line.hasPrefix("List of devices") { continue }
            if line.hasPrefix("*") { continue }   // daemon start-up chatter

            // serial <ws> state [key:value ...]
            let fields = line.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
            guard fields.count >= 2 else { continue }

            let serial = fields[0]
            let state = AndroidDevice.State(rawValue: fields[1]) ?? .unknown

            var model: String?
            var product: String?
            for field in fields.dropFirst(2) {
                let parts = field.split(separator: ":", maxSplits: 1).map(String.init)
                guard parts.count == 2 else { continue }
                switch parts[0] {
                case "model": model = parts[1]
                case "product": product = parts[1]
                default: break
                }
            }

            devices.append(AndroidDevice(serial: serial, state: state,
                                         transport: transport(for: serial),
                                         model: model, product: product))
        }
        return devices
    }

    static func transport(for serial: String) -> AndroidDevice.Transport {
        if serial.hasPrefix("emulator-") { return .emulator }
        // adb-over-network serials are host:port, and adb pairing uses
        // `adb-<serial>-<suffix>._adb-tls-connect._tcp` style names.
        if serial.contains(":") { return .network }
        return .usb
    }

    /// Rank candidates the way a human would: a real phone on the cable first,
    /// then Wi-Fi debugging, and an emulator only if it is all there is.
    /// `preferredSerial` — the device the user pinned — always wins if ready.
    public static func selectDevice(from devices: [AndroidDevice],
                                    preferredSerial: String? = nil) -> AndroidDevice? {
        let ready = devices.filter { $0.state == .device }

        if let preferredSerial,
           let pinned = ready.first(where: { $0.serial == preferredSerial }) {
            return pinned
        }

        func rank(_ d: AndroidDevice) -> Int {
            switch d.transport {
            case .usb:      return d.isProbablySamsung ? 0 : 1
            case .network:  return 2
            case .emulator: return 3
            }
        }

        return ready.sorted { lhs, rhs in
            let (l, r) = (rank(lhs), rank(rhs))
            if l != r { return l < r }
            return lhs.serial < rhs.serial
        }.first
    }

    /// Devices that are plugged in but not usable, so the UI can say why
    /// instead of reporting "no device connected" at a device that is right there.
    public static func blockedDevices(from devices: [AndroidDevice]) -> [AndroidDevice] {
        devices.filter { $0.state == .unauthorized || $0.state == .offline }
    }
}
