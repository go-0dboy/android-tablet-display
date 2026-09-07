// PenDisplay.swift — recognising a real pen display, and remembering how the
// user likes it arranged.
//
// A Wacom Movink 14 is not a streaming target at all: it is a monitor with a
// digitiser, and macOS already knows how to draw on a monitor. What this
// project can usefully add is the part macOS does badly — every time the panel
// is unplugged and replugged the arrangement, scale and rotation drift, and
// the pen has to be re-restricted to that one display by hand.
//
// This file is the pure, testable half: identification and preset storage.
// The half that talks to CoreGraphics lives in the app target.

import Foundation

/// A display the host can recognise and manage.
public struct DisplayIdentity: Equatable, Sendable, Codable {
    /// EDID manufacturer id, as CGDisplayVendorNumber reports it.
    public var vendorNumber: UInt32
    /// EDID product code, as CGDisplayModelNumber reports it.
    public var modelNumber: UInt32
    /// Localised name macOS shows in the Displays pane, when it has one.
    public var name: String
    public var pixelWidth: Int
    public var pixelHeight: Int

    public init(vendorNumber: UInt32, modelNumber: UInt32, name: String,
                pixelWidth: Int, pixelHeight: Int) {
        self.vendorNumber = vendorNumber
        self.modelNumber = modelNumber
        self.name = name
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
    }

    /// Stable key for storing a preset. Deliberately excludes the serial
    /// number: two identical panels share a preset, which is the behaviour a
    /// person expects and keeps no device-unique value on disk.
    public var presetKey: String {
        "\(vendorNumber)-\(modelNumber)-\(pixelWidth)x\(pixelHeight)"
    }
}

public enum PenDisplayVendor {
    /// EDID manufacturer ids are three letters packed into 5 bits each, with
    /// A=1. "WAC" is Wacom's registered PNP id.
    ///   W=23, A=1, C=3  ->  (23<<10) | (1<<5) | 3
    public static let wacomEDID: UInt32 = (23 << 10) | (1 << 5) | 3   // 0x5C23

    /// Wacom's USB vendor id, for the digitiser that enumerates alongside the
    /// panel. Published in the Linux wacom driver and libwacom.
    public static let wacomUSB: UInt32 = 0x056A

    /// The Movink 13 enumerates as three USB devices under Wacom's vendor id:
    /// the composite HID digitiser, an internal hub, and a USB Billboard
    /// device (which is how a USB-C peripheral advertises DisplayPort Alt
    /// Mode). Product ids confirmed against libwacom, OpenTabletDriver and a
    /// captured lsusb dump — see docs/WACOM-MOVINK.md for the sources.
    public static let movinkPenUSB: UInt32 = 0x03F0
    public static let movinkHubUSB: UInt32 = 0x03F1
    public static let movinkBillboardUSB: UInt32 = 0x03F2

    /// All product ids that mean "a Movink is on the cable".
    public static let movinkUSBProductIDs: Set<UInt32> = [
        movinkPenUSB, movinkHubUSB, movinkBillboardUSB
    ]

    /// Decode a packed EDID manufacturer id back to its three letters, so a
    /// diagnostic can print "WAC" instead of 23587.
    public static func edidLetters(_ packed: UInt32) -> String {
        let first  = UInt8((packed >> 10) & 0x1F)
        let second = UInt8((packed >> 5) & 0x1F)
        let third  = UInt8(packed & 0x1F)
        func letter(_ v: UInt8) -> Character {
            guard v >= 1 && v <= 26 else { return "?" }
            return Character(UnicodeScalar(UInt8(64) + v))
        }
        return String([letter(first), letter(second), letter(third)])
    }
}

/// What kind of display this is, as far as the host can tell.
public enum PenDisplayKind: String, Equatable, Sendable, Codable {
    /// A Wacom panel we recognised by EDID vendor.
    case wacom
    /// Specifically a Movink-class panel: Wacom vendor at 2560x1600.
    case wacomMovink
    /// Our own virtual display.
    case virtualDisplay
    case other

    public var isPenDisplay: Bool { self == .wacom || self == .wacomMovink }
}

public enum PenDisplayIdentifier {

    /// The Movink 13's panel is 1920x1080 OLED — Wacom's own spec sheet, whose
    /// supported-timing list tops out at 1920x1080 @60Hz. Note the product is
    /// "Movink 13" (model DTH135K0); there is no "Movink 14" pen display.
    /// Wacom's separate "MovinkPad Pro 14" is a standalone Android tablet, not
    /// a display you plug into a Mac — which makes it a streaming target for
    /// this project rather than a monitor to lay out. See docs/WACOM-MOVINK.md.
    public static let movinkPixelWidth = 1920
    public static let movinkPixelHeight = 1080

    /// Classify a display.
    ///
    /// - Parameter movinkOnUSB: whether a Movink's USB digitiser is currently
    ///   enumerated. This is the reliable signal: the panel's EDID name has
    ///   never been captured publicly, so matching on EDID alone would be a
    ///   guess. When the USB device is present and exactly one display matches
    ///   the panel's resolution, that display is the Movink.
    public static func classify(_ identity: DisplayIdentity,
                                movinkOnUSB: Bool = false) -> PenDisplayKind {
        let name = identity.name.lowercased()

        if name.contains("usb tablet display") { return .virtualDisplay }

        let isWacomVendor = identity.vendorNumber == PenDisplayVendor.wacomEDID
        let isWacomName = name.contains("wacom") || name.contains("movink")
            || name.contains("cintiq")
        let looksLikeMovinkPanel = identity.pixelWidth == movinkPixelWidth
            && identity.pixelHeight == movinkPixelHeight

        if name.contains("movink") { return .wacomMovink }
        if isWacomVendor || isWacomName {
            return movinkOnUSB && looksLikeMovinkPanel ? .wacomMovink : .wacom
        }

        // A resolution match alone proves nothing: 1920x1080 is the commonest
        // resolution there is and would otherwise catch half the monitors ever
        // made. Accept it only for a panel that identifies itself as nothing
        // else — no EDID vendor and no name — while a Movink is on the bus.
        let identifiesAsSomethingElse = identity.vendorNumber != 0 || !name.isEmpty
        if movinkOnUSB && looksLikeMovinkPanel && !identifiesAsSomethingElse {
            return .wacomMovink
        }

        return .other
    }

    /// A friendly label for the menu.
    public static func label(for identity: DisplayIdentity) -> String {
        if !identity.name.isEmpty && identity.name != "Unknown" { return identity.name }
        switch classify(identity) {
        case .wacomMovink: return "Wacom Movink"
        case .wacom:       return "Wacom pen display"
        case .virtualDisplay: return "USB Tablet Display"
        case .other:
            return "\(PenDisplayVendor.edidLetters(identity.vendorNumber)) display"
        }
    }
}

// MARK: - Layout presets

/// Where a display sits and how it is configured. Saved per display identity
/// and re-applied when that display comes back.
public struct DisplayPreset: Equatable, Sendable, Codable {
    /// Top-left of the display in the global desktop coordinate space.
    public var originX: Int
    public var originY: Int
    /// Desired mode, in points and pixels. Zero means "leave it alone".
    public var pointWidth: Int
    public var pointHeight: Int
    public var pixelWidth: Int
    public var pixelHeight: Int
    /// 0, 90, 180 or 270.
    public var rotationDegrees: Int
    /// Set the display as the one the menu bar lives on.
    public var isMainDisplay: Bool
    /// Restrict pen input to this display only. Enforced by the host for the
    /// virtual display; for a Wacom panel this is a reminder the app surfaces,
    /// because only Wacom's own driver can map its digitiser.
    public var penMappedToThisDisplayOnly: Bool
    /// Path to a ColorSync profile to assign, if the user picked one.
    public var colorProfilePath: String?

    public init(originX: Int = 0, originY: Int = 0,
                pointWidth: Int = 0, pointHeight: Int = 0,
                pixelWidth: Int = 0, pixelHeight: Int = 0,
                rotationDegrees: Int = 0, isMainDisplay: Bool = false,
                penMappedToThisDisplayOnly: Bool = true,
                colorProfilePath: String? = nil) {
        self.originX = originX
        self.originY = originY
        self.pointWidth = pointWidth
        self.pointHeight = pointHeight
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
        self.rotationDegrees = rotationDegrees
        self.isMainDisplay = isMainDisplay
        self.penMappedToThisDisplayOnly = penMappedToThisDisplayOnly
        self.colorProfilePath = colorProfilePath
    }

    public var hasMode: Bool { pointWidth > 0 && pointHeight > 0 }

    /// Rotation must be one of four values; anything else is rejected rather
    /// than rounded, because a bad rotation can leave a display unusable.
    public var isValid: Bool {
        [0, 90, 180, 270].contains(rotationDegrees)
    }
}

/// Presets keyed by display identity, persisted as JSON.
public struct DisplayPresetStore: Equatable, Sendable, Codable {
    public private(set) var presets: [String: DisplayPreset]

    public init(presets: [String: DisplayPreset] = [:]) {
        self.presets = presets
    }

    public func preset(for identity: DisplayIdentity) -> DisplayPreset? {
        presets[identity.presetKey]
    }

    public mutating func save(_ preset: DisplayPreset, for identity: DisplayIdentity) {
        presets[identity.presetKey] = preset
    }

    public mutating func remove(for identity: DisplayIdentity) {
        presets.removeValue(forKey: identity.presetKey)
    }

    public func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(self)
    }

    public static func decoded(from data: Data) throws -> DisplayPresetStore {
        try JSONDecoder().decode(DisplayPresetStore.self, from: data)
    }

    /// Sensible starting point for a freshly recognised Movink: native
    /// resolution, no rotation, pen restricted to it, placed to the right of
    /// the main display. Deliberately not made the main display — taking the
    /// menu bar away from someone unasked is the kind of surprise that gets an
    /// app deleted.
    public static func defaultMovinkPreset(originX: Int) -> DisplayPreset {
        DisplayPreset(originX: originX, originY: 0,
                      // The Movink's 1920x1080 panel at 13.3" is about 166 ppi.
                      // That is below the point where macOS's 2x is right, so
                      // the default is the native 1:1 mode, not a scaled one.
                      pointWidth: PenDisplayIdentifier.movinkPixelWidth,
                      pointHeight: PenDisplayIdentifier.movinkPixelHeight,
                      pixelWidth: PenDisplayIdentifier.movinkPixelWidth,
                      pixelHeight: PenDisplayIdentifier.movinkPixelHeight,
                      rotationDegrees: 0,
                      isMainDisplay: false,
                      penMappedToThisDisplayOnly: true,
                      colorProfilePath: nil)
    }
}
