// gesturelab — post a gesture and find out whether an application reacted.
//
// macOS has no public way to post a pinch, and the undocumented route works in
// some applications and not others. Rather than guess, this posts a gesture at
// whatever is frontmost and reports what happened, so docs/STATUS.md can carry
// a measured table instead of an assumption.
//
//   swift run gesturelab zoom-in  --strategy gestureEvent
//   swift run gesturelab zoom-out --strategy keyboardSteps
//   swift run gesturelab scroll   --dy 120
//   swift run gesturelab list
//
// Whatever application is frontmost receives the gesture, so bring the one you
// want to test to the front first. Needs Accessibility permission.

import Foundation
import AppKit
import CoreGraphics
import USBDisplayCore

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(1)
}

let arguments = CommandLine.arguments
guard arguments.count > 1 else {
    print("""
    usage: gesturelab <command> [options]

      zoom-in / zoom-out   post a pinch
      scroll               post a two-finger scroll
      key                  post a keystroke, e.g. --key 0 --cmd (zoom reset)
      activate             bring an application to the front by name
      list                 show the strategies

    options:
      --strategy <name>    gestureEvent | commandScroll | keyboardSteps
      --amount <double>    magnification per step (default 0.25)
      --steps <int>        how many increments (default 8)
      --dx / --dy <double> scroll delta in points
    """)
    exit(0)
}

func value(_ flag: String) -> String? {
    guard let index = arguments.firstIndex(of: flag), index + 1 < arguments.count else { return nil }
    return arguments[index + 1]
}

let command = arguments[1]
let strategy = ZoomStrategy(rawValue: value("--strategy") ?? "gestureEvent")
    ?? .gestureEvent
let amount = Double(value("--amount") ?? "") ?? 0.25
let stepCount = Int(value("--steps") ?? "") ?? 8

if command == "list" {
    for s in ZoomStrategy.allCases { print("\(s.rawValue)\t\(s.title)") }
    exit(0)
}

guard AXIsProcessTrusted() else {
    fail("Accessibility permission is required. Grant it to the terminal or to "
       + "USB Tablet Display.app, then run this again.")
}

let source = CGEventSource(stateID: .combinedSessionState)
let frontmost = NSWorkspace.shared.frontmostApplication?.localizedName ?? "unknown"
print("frontmost application: \(frontmost)")
print("strategy: \(strategy.rawValue)")

/// Scroll and gesture events are routed to the window under the POINTER, not
/// to the focused window. Posting one without putting the cursor over the
/// target sends it to whatever happens to be under the mouse — which looks
/// exactly like "the event does not work".
func centreCursorOn(application name: String) -> Bool {
    let windows = CGWindowListCopyWindowInfo(
        [.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
    var best: (rect: CGRect, area: CGFloat) = (.zero, 0)
    for window in windows {
        guard let owner = window[kCGWindowOwnerName as String] as? String, owner == name,
              let bounds = window[kCGWindowBounds as String] as? [String: Any],
              let rect = CGRect(dictionaryRepresentation: bounds as CFDictionary)
        else { continue }
        let area = rect.width * rect.height
        if area > best.area { best = (rect, area) }
    }
    guard best.area > 0 else { return false }
    let centre = CGPoint(x: best.rect.midX, y: best.rect.midY)
    CGWarpMouseCursorPosition(centre)
    CGAssociateMouseAndMouseCursorPosition(1)
    usleep(120_000)
    print("cursor moved to \(Int(centre.x)),\(Int(centre.y)) over \(name)")
    return true
}

if let target = value("--over") {
    if !centreCursorOn(application: target) {
        print("warning: found no window belonging to \(target)")
    }
}

/// Build a gesture event by hand: no public constructor exists.
func postGesture(type: UInt32, phase: GesturePhase, magnification: Double) {
    guard let event = CGEvent(source: source) else { return }
    event.type = CGEventType(rawValue: type)!
    event.setIntegerValueField(CGEventField(rawValue: GestureEventField.gesturePhase)!,
                               value: phase.rawValue)
    if magnification != 0 {
        event.setDoubleValueField(CGEventField(rawValue: GestureEventField.gestureValue)!,
                                  value: magnification)
    }
    event.post(tap: .cghidEventTap)
}

func postScroll(dx: Double, dy: Double, phase: GesturePhase, flags: CGEventFlags = []) {
    guard let event = CGEvent(scrollWheelEvent2Source: source, units: .pixel,
                              wheelCount: 2, wheel1: Int32(dy), wheel2: Int32(dx),
                              wheel3: 0) else { return }
    event.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
    event.setIntegerValueField(.scrollWheelEventScrollPhase, value: phase.rawValue)
    event.flags = flags
    event.post(tap: .cghidEventTap)
}

func postKey(_ keyCode: CGKeyCode, flags: CGEventFlags) {
    guard let down = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: true),
          let up = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: false)
    else { return }
    down.flags = flags
    up.flags = flags
    down.post(tap: .cghidEventTap)
    usleep(20_000)
    up.post(tap: .cghidEventTap)
}

let kVK_ANSI_Equal: CGKeyCode = 24
let kVK_ANSI_Minus: CGKeyCode = 27

func zoom(_ direction: Double) {
    let perStep = amount * direction

    switch strategy {
    case .gestureEvent:
        // A real trackpad brackets a pinch with begin/end gesture events, and
        // some applications only start listening once they have seen one.
        postGesture(type: GestureEventType.beginGesture, phase: .began, magnification: 0)
        postGesture(type: GestureEventType.magnify, phase: .began, magnification: 0)
        for _ in 0..<stepCount {
            postGesture(type: GestureEventType.magnify, phase: .changed,
                        magnification: perStep / Double(stepCount))
            usleep(16_000)
        }
        postGesture(type: GestureEventType.magnify, phase: .ended, magnification: 0)
        postGesture(type: GestureEventType.endGesture, phase: .ended, magnification: 0)

    case .commandScroll:
        // Setting the command flag on the scroll event alone is not enough:
        // applications read the CURRENT modifier state, so Command has to be
        // genuinely held down around the scroll, not merely annotated onto it.
        let commandKey: CGKeyCode = 55
        if let down = CGEvent(keyboardEventSource: source, virtualKey: commandKey,
                              keyDown: true) {
            down.flags = .maskCommand
            down.post(tap: .cghidEventTap)
        }
        usleep(60_000)

        postScroll(dx: 0, dy: 0, phase: .began, flags: .maskCommand)
        for _ in 0..<stepCount {
            postScroll(dx: 0, dy: perStep * 40, phase: .changed, flags: .maskCommand)
            usleep(16_000)
        }
        postScroll(dx: 0, dy: 0, phase: .ended, flags: .maskCommand)

        usleep(60_000)
        if let up = CGEvent(keyboardEventSource: source, virtualKey: commandKey,
                            keyDown: false) {
            up.flags = []
            up.post(tap: .cghidEventTap)
        }

    case .keyboardSteps:
        var accumulator = ZoomStepAccumulator()
        let steps = accumulator.steps(for: perStep)
        for _ in 0..<abs(steps == 0 ? 1 : steps) {
            postKey(direction > 0 ? kVK_ANSI_Equal : kVK_ANSI_Minus, flags: .maskCommand)
            usleep(80_000)
        }
    }
}

// Activating and keying are done here rather than through AppleScript on
// purpose: System Events needs a separate Automation permission that is easy
// to be missing, and when it is missing the call hangs rather than failing.
if command == "activate" {
    let name = value("--app") ?? ""
    let matches = NSWorkspace.shared.runningApplications.filter {
        $0.localizedName == name
    }
    guard let app = matches.first else { fail("no running application named \(name)") }
    app.activate(options: [.activateAllWindows])
    print("activated \(name)")
    exit(0)
}

if command == "key" {
    let keyName = value("--key") ?? "0"
    let codes: [String: CGKeyCode] = ["0": 29, "=": 24, "-": 27, "+": 24]
    guard let code = codes[keyName] else { fail("unknown key \(keyName)") }
    var flags: CGEventFlags = []
    if arguments.contains("--cmd") { flags.insert(.maskCommand) }
    postKey(code, flags: flags)
    print("posted key \(keyName)")
    exit(0)
}

switch command {
case "zoom-in":  zoom(1); print("posted zoom in")
case "zoom-out": zoom(-1); print("posted zoom out")
case "scroll":
    let dx = Double(value("--dx") ?? "0") ?? 0
    let dy = Double(value("--dy") ?? "120") ?? 120
    postScroll(dx: 0, dy: 0, phase: .began)
    for _ in 0..<stepCount {
        postScroll(dx: dx / Double(stepCount), dy: dy / Double(stepCount), phase: .changed)
        usleep(16_000)
    }
    postScroll(dx: 0, dy: 0, phase: .ended)
    print("posted scroll dx=\(dx) dy=\(dy)")
default:
    fail("unknown command: \(command)")
}
