// DisplayGeometry.swift — turning what the client says it is into virtual
// display parameters.
//
// v1 hardcoded 2560x1600 at 110 ppi with HiDPI off, so on a high-density
// Samsung tablet macOS drew a 2560-wide desktop onto a panel where everything
// was half the size it should be. The client now reports its real metrics in
// the hello message and the display is built to match.

import Foundation

public struct VirtualDisplaySpec: Equatable, Sendable {
    /// Backing store, in pixels.
    public var pixelWidth: Int
    public var pixelHeight: Int
    /// The point size macOS lays the desktop out in.
    public var pointWidth: Int
    public var pointHeight: Int
    public var ppi: Int
    public var hiDPI: Bool
    public var refreshRate: Double
    public var name: String

    public init(pixelWidth: Int, pixelHeight: Int, pointWidth: Int, pointHeight: Int,
                ppi: Int, hiDPI: Bool, refreshRate: Double, name: String) {
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
        self.pointWidth = pointWidth
        self.pointHeight = pointHeight
        self.ppi = ppi
        self.hiDPI = hiDPI
        self.refreshRate = refreshRate
        self.name = name
    }

    public var physicalWidthMM: Double { Double(pixelWidth) / Double(ppi) * 25.4 }
    public var physicalHeightMM: Double { Double(pixelHeight) / Double(ppi) * 25.4 }
}

/// How much desktop the person wants on the tablet.
///
/// The automatic choice is right for a phone and for most tablets, but it is a
/// guess: a 14-inch tablet at 2560x1600 gets a 1280x800 desktop, which is
/// crisp but coarse, while someone using it as a second monitor may want the
/// full 2560x1600 and smaller text. That is taste, not a fact the host can
/// derive, so it is a setting.
public enum ScalePreference: String, CaseIterable, Sendable {
    /// Pick from the panel's density. HiDPI above ~200 dpi.
    case automatic
    /// Native resolution, smallest text, most desktop.
    case moreSpace
    /// HiDPI, largest text, least desktop.
    case largerText

    public var title: String {
        switch self {
        case .automatic:   return "Automatic"
        case .moreSpace:   return "More space (smaller text)"
        case .largerText:  return "Larger text (sharper)"
        }
    }
}

public enum DisplayGeometry {

    /// H.264 levels and most hardware decoders want even dimensions; some
    /// Samsung decoders want a multiple of 16 to avoid a green edge column.
    public static func alignedDown(_ value: Int, to multiple: Int = 16) -> Int {
        max(multiple, (value / multiple) * multiple)
    }

    /// Above roughly 200 dpi a 1:1 desktop is unreadable, so macOS should draw
    /// at 2x and let the panel show the detail — the same call Apple makes for
    /// Retina panels. Below that, 1:1 keeps the most desktop on screen.
    public static let hiDPIThresholdDPI = 200

    /// Build the display spec for a connected client.
    ///
    /// - Parameters:
    ///   - hello: what the client reported.
    ///   - maxPixels: cap on either axis, so a phone claiming an absurd size
    ///     cannot ask the encoder for something it cannot sustain.
    public static func spec(for hello: ClientHello,
                            refreshRate: Double = 60,
                            maxPixels: Int = 4096,
                            scale: ScalePreference = .automatic) -> VirtualDisplaySpec {

        // Rotation is applied by the client's own window manager, so the
        // surface it hands us is already in its final orientation — but a
        // client that reports pre-rotation metrics needs the swap.
        var width = Int(hello.widthPixels)
        var height = Int(hello.heightPixels)
        if hello.rotationDegrees == 90 || hello.rotationDegrees == 270 {
            // Only swap if the reported metrics are portrait while the surface
            // is rotated to landscape; a client that already swapped them will
            // report landscape and fall through untouched.
            if height > width { swap(&width, &height) }
        }

        width = min(max(width, 640), maxPixels)
        height = min(max(height, 480), maxPixels)
        width = alignedDown(width)
        height = alignedDown(height)

        let dpi = Int(hello.densityDpi)
        let useHiDPI: Bool
        switch scale {
        case .automatic:  useHiDPI = dpi >= hiDPIThresholdDPI
        case .moreSpace:  useHiDPI = false
        case .largerText: useHiDPI = true
        }

        // In HiDPI the mode is half the backing store, which is what makes
        // macOS report "looks like WxH" at half the pixel count.
        let pointWidth = useHiDPI ? width / 2 : width
        let pointHeight = useHiDPI ? height / 2 : height

        // The descriptor's physical size is what drives macOS's own idea of
        // density, so feed it the device's real dpi rather than a constant.
        let ppi = dpi > 0 ? dpi : 160

        return VirtualDisplaySpec(
            pixelWidth: width,
            pixelHeight: height,
            pointWidth: max(pointWidth, 320),
            pointHeight: max(pointHeight, 240),
            ppi: ppi,
            hiDPI: useHiDPI,
            refreshRate: refreshRate,
            name: displayName(for: hello.deviceName)
        )
    }

    /// The string that lands in the Mac's Displays pane. A bare model number
    /// tells the user nothing, so it is prefixed — and it is never the serial.
    public static func displayName(for deviceName: String) -> String {
        let trimmed = deviceName.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "_", with: " ")
        if trimmed.isEmpty { return "Android Tablet Display" }
        if trimmed.count > 40 { return String(trimmed.prefix(40)) }
        return trimmed
    }

    /// Default used before any client has said hello.
    public static var fallbackSpec: VirtualDisplaySpec {
        VirtualDisplaySpec(pixelWidth: 2560, pixelHeight: 1600,
                           pointWidth: 2560, pointHeight: 1600,
                           ppi: 110, hiDPI: false, refreshRate: 60,
                           name: "Android Tablet Display")
    }
}
