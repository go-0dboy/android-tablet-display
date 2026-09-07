// vdprobe — does the private virtual-display API work on this Mac?
//
// The macOS host depends on CGVirtualDisplay, which is not public API. If a
// macOS update moves or removes it, everything else in this project stops
// working. Run this first; paste its output into any bug report.
//
//   swift run vdprobe
//
// Exit codes: 0 success, 2 private classes missing, 3 creation refused,
// 4 created but never appeared in the display list.

import Foundation
import CoreGraphics
import VirtualDisplay
import USBDisplayCore

func activeDisplays() -> [(id: CGDirectDisplayID, bounds: CGRect)] {
    var count: UInt32 = 0
    guard CGGetActiveDisplayList(0, nil, &count) == .success, count > 0 else { return [] }
    var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
    guard CGGetActiveDisplayList(count, &ids, &count) == .success else { return [] }
    return ids.prefix(Int(count)).map { ($0, CGDisplayBounds($0)) }
}

func describe(_ displays: [(id: CGDirectDisplayID, bounds: CGRect)]) -> String {
    displays.map { "\($0.id)(\(Int($0.bounds.width))x\(Int($0.bounds.height)))" }
        .joined(separator: " ")
}

print("=== vdprobe: CGVirtualDisplay availability check ===")

let os = ProcessInfo.processInfo.operatingSystemVersion
print("macOS         : \(os.majorVersion).\(os.minorVersion).\(os.patchVersion)")
print("build         : \(ProcessInfo.processInfo.operatingSystemVersionString)")
#if arch(arm64)
print("architecture  : arm64 (Apple Silicon)")
#else
print("architecture  : x86_64 (Intel)")
#endif

let missing = VirtualDisplayManager.missingPrivateClasses()
if !missing.isEmpty {
    print("private API   : MISSING -> \(missing.joined(separator: ", "))")
    print("")
    print("RESULT: FAIL. This macOS release does not expose the private")
    print("virtual-display classes this project is built on. See docs/STATUS.md.")
    exit(2)
}
print("private API   : all four classes present")

let before = activeDisplays()
print("displays before: \(before.count) -> \(describe(before))")

// Probe with the same geometry path the app uses, so a pass here means the
// app's own call will behave the same way.
let hello = ClientHello(widthPixels: 2560, heightPixels: 1600, densityDpi: 240,
                        rotationDegrees: 0, flags: [], deviceName: "vdprobe")
let spec = DisplayGeometry.spec(for: hello)
print("requesting    : \(spec.pixelWidth)x\(spec.pixelHeight) px / "
      + "\(spec.pointWidth)x\(spec.pointHeight) pt @ \(spec.ppi) ppi, hiDPI=\(spec.hiDPI)")

let manager = VirtualDisplayManager()
let parameters = VirtualDisplayParameters.make(pixelWidth: Int32(spec.pixelWidth),
                                       pixelHeight: Int32(spec.pixelHeight),
                                       pointWidth: Int32(spec.pointWidth),
                                       pointHeight: Int32(spec.pointHeight),
                                       ppi: Int32(spec.ppi),
                                       hiDPI: spec.hiDPI,
                                       refreshRate: spec.refreshRate,
                                       name: "vdprobe test display")

guard manager.createDisplay(spec: parameters) else {
    print("create        : REFUSED")
    print("reason        : \(manager.lastError ?? "unknown")")
    print("")
    print("RESULT: FAIL. The private classes exist but refused to create a display.")
    exit(3)
}
print("create        : OK, displayID=\(manager.displayID)")

// Give WindowServer time to publish it.
RunLoop.main.run(until: Date().addingTimeInterval(1.5))

let after = activeDisplays()
print("displays after : \(after.count) -> \(describe(after))")

let id = manager.displayID
guard id != 0, after.contains(where: { $0.id == id }) else {
    print("")
    print("RESULT: FAIL. Created, but the display never joined the active list.")
    manager.destroyDisplay()
    exit(4)
}

let bounds = CGDisplayBounds(id)
print("bounds        : \(Int(bounds.origin.x)),\(Int(bounds.origin.y)) "
      + "\(Int(bounds.width))x\(Int(bounds.height)) pt")
print("backing store : \(CGDisplayPixelsWide(id))x\(CGDisplayPixelsHigh(id)) px")
if let mode = CGDisplayCopyDisplayMode(id) {
    print("active mode   : \(mode.pixelWidth)x\(mode.pixelHeight) px / "
          + "\(mode.width)x\(mode.height) pt @ \(String(format: "%.0f", mode.refreshRate))Hz")
}

// The mode list is the thing to look at when HiDPI does not come out right:
// macOS builds its own ladder from the descriptor and picks from it.
let options = [kCGDisplayShowDuplicateLowResolutionModes: kCFBooleanTrue] as CFDictionary
if let modes = CGDisplayCopyAllDisplayModes(id, options) as? [CGDisplayMode] {
    print("offered modes : \(modes.count)")
    for mode in modes {
        let scaled = mode.pixelWidth != mode.width ? " (HiDPI)" : ""
        print("   \(mode.width)x\(mode.height) pt / "
              + "\(mode.pixelWidth)x\(mode.pixelHeight) px"
              + " @ \(String(format: "%.0f", mode.refreshRate))Hz\(scaled)")
    }
} else {
    print("offered modes : none reported")
}

print("")
print("RESULT: PASS. Virtual display \(id) created and active on this Mac.")
print("Tearing it down...")
manager.destroyDisplay()
RunLoop.main.run(until: Date().addingTimeInterval(0.5))
let final = activeDisplays()
print("displays after teardown: \(final.count) -> \(describe(final))")
if final.contains(where: { $0.id == id }) {
    print("NOTE: the display is still listed after teardown. Some macOS builds")
    print("only release it when the owning process exits; this is a known,")
    print("unresolved difference between reports. See docs/STATUS.md.")
}
exit(0)
