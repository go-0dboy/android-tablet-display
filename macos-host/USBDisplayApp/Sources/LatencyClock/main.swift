// latencyclock — a clock designed to be read by a machine, not a person.
//
// Measuring glass-to-glass latency by photographing a clock means reading
// digits off an image, which is exactly the step that goes wrong. This draws
// the timestamp twice: as text a person can read, and as a row of black and
// white blocks encoding the same value in binary. tools/measure-latency.sh
// screencaps the tablet, decodes the blocks, and subtracts.
//
//   swift run latencyclock --display <id>
//
// Run `swift run vdprobe` or read the host's log to find the display id.

import AppKit
import CoreGraphics

/// Bits in the encoded timestamp. 2^22 ms is about 70 minutes of unambiguous
/// range, which is far longer than any measurement run.
let bitCount = 22

/// Milliseconds since an arbitrary fixed epoch, wrapped to `bitCount` bits.
func timestampValue() -> UInt32 {
    let ms = UInt64(Date().timeIntervalSince1970 * 1000)
    return UInt32(ms & ((1 << UInt64(bitCount)) - 1))
}

final class ClockView: NSView {
    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.black.setFill()
        bounds.fill()

        let value = timestampValue()

        // --- Machine-readable row.
        // A leading white marker block anchors the row so the reader can find
        // it without knowing exactly where the window landed.
        let blockWidth = bounds.width / CGFloat(bitCount + 2)
        let blockHeight = min(bounds.height * 0.45, 160)

        NSColor.white.setFill()
        NSRect(x: 0, y: 0, width: blockWidth, height: blockHeight).fill()

        for bit in 0..<bitCount {
            let isSet = (value >> UInt32(bitCount - 1 - bit)) & 1 == 1
            (isSet ? NSColor.white : NSColor.black).setFill()
            let rect = NSRect(x: blockWidth * CGFloat(bit + 1), y: 0,
                              width: blockWidth, height: blockHeight)
            rect.fill()
            // A thin grey separator keeps adjacent equal bits distinguishable
            // after the encoder has been at them.
            NSColor.gray.setFill()
            NSRect(x: rect.maxX - 1, y: 0, width: 1, height: blockHeight).fill()
        }

        // --- Human-readable text.
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss.SSS"
        let text = formatter.string(from: Date())
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 72, weight: .bold),
            .foregroundColor: NSColor.green
        ]
        text.draw(at: CGPoint(x: 20, y: blockHeight + 20), withAttributes: attributes)
        "bits: \(value)".draw(
            at: CGPoint(x: 20, y: blockHeight + 110),
            withAttributes: [
                .font: NSFont.monospacedSystemFont(ofSize: 24, weight: .regular),
                .foregroundColor: NSColor.white
            ])
    }
}

// Parse --display <id>, defaulting to the last display in the list, which is
// normally the most recently created one.
var targetDisplayID: CGDirectDisplayID?
let arguments = CommandLine.arguments
if let index = arguments.firstIndex(of: "--display"), index + 1 < arguments.count {
    targetDisplayID = CGDirectDisplayID(arguments[index + 1])
}

var displayCount: UInt32 = 0
CGGetActiveDisplayList(0, nil, &displayCount)
var displayIDs = [CGDirectDisplayID](repeating: 0, count: Int(displayCount))
CGGetActiveDisplayList(displayCount, &displayIDs, &displayCount)

guard let displayID = targetDisplayID ?? displayIDs.last else {
    print("No displays found.")
    exit(1)
}
guard displayIDs.contains(displayID) else {
    print("Display \(displayID) is not attached. Attached: \(displayIDs)")
    exit(1)
}

let bounds = CGDisplayBounds(displayID)
print("Drawing the clock on display \(displayID) at \(bounds)")
print("Encoding \(bitCount) bits; leading white block marks the start of the row.")

let app = NSApplication.shared
app.setActivationPolicy(.accessory)

// Fill the display, so the block row is as large as possible and survives
// whatever scaling the client applies.
let window = NSWindow(contentRect: bounds, styleMask: [.borderless],
                      backing: .buffered, defer: false)
window.setFrame(bounds, display: true)
window.level = .screenSaver
window.backgroundColor = .black
window.isOpaque = true
window.ignoresMouseEvents = true

let view = ClockView(frame: NSRect(origin: .zero, size: bounds.size))
window.contentView = view
window.orderFrontRegardless()

// Redraw every frame. CVDisplayLink would be tidier, but a 120 Hz timer is
// plenty for a clock whose resolution only needs to beat one frame time.
Timer.scheduledTimer(withTimeInterval: 1.0 / 120.0, repeats: true) { _ in
    view.needsDisplay = true
}

app.run()
