// DisplayManager.swift — the CoreGraphics side of recognising displays and
// putting them where the user wants them.
//
// This is what the Wacom Movink gets out of this project. The Movink needs no
// streaming: it is a real monitor over USB-C DisplayPort Alt Mode and macOS
// draws to it directly. What macOS does badly is remember it — unplug the
// panel and plug it back in and the arrangement, the scale and the rotation
// have all drifted. A preset, applied automatically when the panel is
// recognised, is the whole feature.

import Foundation
import CoreGraphics
import IOKit
import IOKit.usb
import IOKit.hid
import USBDisplayCore

final class DisplayManager {

    private(set) var presetStore = DisplayPresetStore()
    private let storeURL: URL

    init() {
        let support = FileManager.default.urls(for: .applicationSupportDirectory,
                                               in: .userDomainMask)[0]
            .appendingPathComponent("USBTabletDisplay", isDirectory: true)
        try? FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        storeURL = support.appendingPathComponent("display-presets.json")
        loadPresets()
    }

    // MARK: - Enumeration

    static func activeDisplayIDs() -> [CGDirectDisplayID] {
        var count: UInt32 = 0
        guard CGGetActiveDisplayList(0, nil, &count) == .success, count > 0 else { return [] }
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetActiveDisplayList(count, &ids, &count) == .success else { return [] }
        return Array(ids.prefix(Int(count)))
    }

    static func identity(of displayID: CGDirectDisplayID) -> DisplayIdentity {
        DisplayIdentity(vendorNumber: CGDisplayVendorNumber(displayID),
                        modelNumber: CGDisplayModelNumber(displayID),
                        name: localizedName(of: displayID),
                        pixelWidth: CGDisplayPixelsWide(displayID),
                        pixelHeight: CGDisplayPixelsHigh(displayID))
    }

    /// The name shown in the Displays pane. There is no direct CoreGraphics
    /// call for it, so read it from the IODisplay registry.
    static func localizedName(of displayID: CGDirectDisplayID) -> String {
        var name = ""
        var iterator = io_iterator_t()
        let matching = IOServiceMatching("IODisplayConnect")
        guard IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iterator)
                == KERN_SUCCESS else { return name }
        defer { IOObjectRelease(iterator) }

        let targetVendor = CGDisplayVendorNumber(displayID)
        let targetModel = CGDisplayModelNumber(displayID)

        while case let service = IOIteratorNext(iterator), service != 0 {
            defer { IOObjectRelease(service) }
            guard let info = IODisplayCreateInfoDictionary(
                    service, IOOptionBits(kIODisplayOnlyPreferredName))?
                    .takeRetainedValue() as? [String: Any] else { continue }

            let vendor = info[kDisplayVendorID as String] as? UInt32
            let product = info[kDisplayProductID as String] as? UInt32
            guard vendor == targetVendor, product == targetModel else { continue }

            if let names = info[kDisplayProductName as String] as? [String: String],
               let first = names.values.first {
                name = first
                break
            }
        }
        return name
    }

    /// Is a Wacom Movink's USB digitiser enumerated right now? This is the
    /// trustworthy signal — the panel's EDID name has never been captured
    /// publicly, so matching a display on EDID alone would be a guess.
    static func movinkIsOnUSB() -> Bool {
        wacomUSBProductIDs().contains { PenDisplayVendor.movinkUSBProductIDs.contains($0) }
    }

    /// Every Wacom USB product id currently attached.
    static func wacomUSBProductIDs() -> Set<UInt32> {
        var found = Set<UInt32>()
        var iterator = io_iterator_t()
        guard IOServiceGetMatchingServices(kIOMainPortDefault,
                                           IOServiceMatching(kIOUSBDeviceClassName),
                                           &iterator) == KERN_SUCCESS else { return found }
        defer { IOObjectRelease(iterator) }

        while case let device = IOIteratorNext(iterator), device != 0 {
            defer { IOObjectRelease(device) }

            func number(_ key: String) -> UInt32? {
                guard let ref = IORegistryEntryCreateCFProperty(
                        device, key as CFString, kCFAllocatorDefault, 0)?
                        .takeRetainedValue() as? NSNumber else { return nil }
                return ref.uint32Value
            }
            guard number(kUSBVendorID) == PenDisplayVendor.wacomUSB else { continue }
            if let product = number(kUSBProductID) { found.insert(product) }
        }
        return found
    }

    /// Classify every attached display.
    static func survey() -> [(id: CGDirectDisplayID, identity: DisplayIdentity, kind: PenDisplayKind)] {
        let movinkPresent = movinkIsOnUSB()
        return activeDisplayIDs().map { id in
            let identity = identity(of: id)
            return (id, identity, PenDisplayIdentifier.classify(identity,
                                                                movinkOnUSB: movinkPresent))
        }
    }

    /// The first recognised pen display, if one is attached.
    static func attachedPenDisplay()
        -> (id: CGDirectDisplayID, identity: DisplayIdentity, kind: PenDisplayKind)? {
        survey().first { $0.kind.isPenDisplay }
    }

    // MARK: - Presets

    private func loadPresets() {
        guard let data = try? Data(contentsOf: storeURL) else { return }
        if let decoded = try? DisplayPresetStore.decoded(from: data) {
            presetStore = decoded
        }
    }

    private func savePresets() {
        guard let data = try? presetStore.encoded() else { return }
        try? data.write(to: storeURL, options: .atomic)
    }

    /// Record how a display is arranged right now, so it can be restored.
    @discardableResult
    func captureCurrentLayout(of displayID: CGDirectDisplayID) -> DisplayPreset {
        let bounds = CGDisplayBounds(displayID)
        let mode = CGDisplayCopyDisplayMode(displayID)

        let preset = DisplayPreset(
            originX: Int(bounds.origin.x),
            originY: Int(bounds.origin.y),
            pointWidth: mode.map { $0.width } ?? 0,
            pointHeight: mode.map { $0.height } ?? 0,
            pixelWidth: mode.map { $0.pixelWidth } ?? 0,
            pixelHeight: mode.map { $0.pixelHeight } ?? 0,
            rotationDegrees: Int(CGDisplayRotation(displayID)),
            isMainDisplay: CGDisplayIsMain(displayID) != 0,
            penMappedToThisDisplayOnly: true,
            colorProfilePath: nil)

        presetStore.save(preset, for: Self.identity(of: displayID))
        savePresets()
        log("Saved layout for \(PenDisplayIdentifier.label(for: Self.identity(of: displayID))): "
            + "\(preset.pointWidth)x\(preset.pointHeight) at \(preset.originX),\(preset.originY)")
        return preset
    }

    /// Put a display back where its preset says it belongs.
    ///
    /// Returns a list of what was applied and what could not be, because two
    /// of the things a person most wants here are not settable by any public
    /// API and saying so is better than silently not doing them.
    @discardableResult
    func applyPreset(to displayID: CGDirectDisplayID) -> [String] {
        let identity = Self.identity(of: displayID)
        guard let preset = presetStore.preset(for: identity) else {
            return ["No saved layout for \(PenDisplayIdentifier.label(for: identity))."]
        }
        guard preset.isValid else {
            return ["The saved layout is invalid and was not applied."]
        }

        var applied: [String] = []
        var config: CGDisplayConfigRef?
        guard CGBeginDisplayConfiguration(&config) == .success, let config else {
            return ["macOS refused to begin a display reconfiguration."]
        }

        if preset.hasMode, let mode = bestMode(for: displayID, preset: preset) {
            CGConfigureDisplayWithDisplayMode(config, displayID, mode, nil)
            applied.append("mode \(preset.pointWidth)x\(preset.pointHeight)")
        }

        CGConfigureDisplayOrigin(config, displayID,
                                 Int32(preset.originX), Int32(preset.originY))
        applied.append("position \(preset.originX),\(preset.originY)")

        if preset.isMainDisplay {
            CGConfigureDisplayWithDisplayMode(config, displayID,
                                              CGDisplayCopyDisplayMode(displayID), nil)
            applied.append("main display")
        }

        guard CGCompleteDisplayConfiguration(config, .permanently) == .success else {
            CGCancelDisplayConfiguration(config)
            return ["macOS rejected the layout change."]
        }

        if CGDisplayRotation(displayID) != Double(preset.rotationDegrees) {
            // Rotation is only settable through IOKit's private display
            // interface, which is a different and riskier proposition than
            // moving a window. Report it rather than pretend.
            applied.append("rotation NOT applied (macOS exposes no public API "
                           + "for it — set it in System Settings > Displays)")
        }

        log("Applied layout to \(PenDisplayIdentifier.label(for: identity)): "
            + applied.joined(separator: ", "))
        return applied
    }

    private func bestMode(for displayID: CGDirectDisplayID,
                          preset: DisplayPreset) -> CGDisplayMode? {
        // The option is required: without it the list contains no HiDPI modes
        // at all, so a saved 2x layout can never be restored.
        let options = [kCGDisplayShowDuplicateLowResolutionModes: kCFBooleanTrue] as CFDictionary
        guard let modes = CGDisplayCopyAllDisplayModes(displayID, options) as? [CGDisplayMode]
        else { return nil }

        // Exact match on both point and pixel size first — that is the only
        // way to distinguish a HiDPI mode from its 1x namesake.
        if let exact = modes.first(where: {
            $0.width == preset.pointWidth && $0.height == preset.pointHeight
                && $0.pixelWidth == preset.pixelWidth && $0.pixelHeight == preset.pixelHeight
        }) { return exact }

        return modes.first { $0.width == preset.pointWidth && $0.height == preset.pointHeight }
    }

    func forgetPreset(for displayID: CGDirectDisplayID) {
        presetStore.remove(for: Self.identity(of: displayID))
        savePresets()
    }

    func hasPreset(for displayID: CGDirectDisplayID) -> Bool {
        presetStore.preset(for: Self.identity(of: displayID)) != nil
    }

    /// Seed a sensible preset for a freshly recognised Movink, placed to the
    /// right of the widest existing display so it does not land on top of one.
    @discardableResult
    func seedDefaultPreset(for displayID: CGDirectDisplayID) -> DisplayPreset {
        let rightEdge = Self.activeDisplayIDs()
            .filter { $0 != displayID }
            .map { Int(CGDisplayBounds($0).maxX) }
            .max() ?? 0

        let preset = DisplayPresetStore.defaultMovinkPreset(originX: rightEdge)
        presetStore.save(preset, for: Self.identity(of: displayID))
        savePresets()
        return preset
    }
}
