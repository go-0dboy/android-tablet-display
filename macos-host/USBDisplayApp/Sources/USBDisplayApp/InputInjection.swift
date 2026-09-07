// InputInjection.swift — turning client input into macOS events.
//
// The important correction over v1: a CGEvent only reaches an application as a
// *tablet* event if its mouseEventSubtype says so. v1 set
// .tabletEventPointPressure on a plain mouse event, which AppKit delivers with
// subtype NX_SUBTYPE_DEFAULT — so every drawing app read pressure as a flat
// 1.0 and the headline feature quietly did nothing. Tilt was worse: it was
// carried across the wire and then never written to the event at all.
//
// Getting this right needs three things:
//   1. a proximity-enter event when the pen comes into range, so apps know a
//      tablet exists at all and start looking at pressure;
//   2. subtype NX_SUBTYPE_TABLET_POINT on every pen movement;
//   3. the tablet fields — pressure, tiltX, tiltY, deviceID — populated, with
//      the same deviceID as the proximity event.

import Foundation
import CoreGraphics
import AppKit
import USBDisplayCore

/// NSEvent subtypes for mouse events. Not exposed to Swift, so declared here.
private let NX_SUBTYPE_DEFAULT: Int64 = 0
private let NX_SUBTYPE_TABLET_POINT: Int64 = 1
private let NX_SUBTYPE_TABLET_PROXIMITY: Int64 = 2

/// CGEventType 29 is NSEventTypeMagnify. There is no public CoreGraphics
/// constructor for a gesture event, so a pinch is built by hand. This is the
/// same approach trackpad-emulation tools use; treat it as best-effort.
private let kCGEventTypeMagnify = CGEventType(rawValue: 29)!
/// Event field 33 carries the magnification delta on a magnify event.
private let kCGMagnificationField = CGEventField(rawValue: 33)!

/// Identity we present as the tablet. Constant, so an app that remembers a
/// tablet between sessions sees the same one.
private let kTabletDeviceID: Int64 = 0x01
private let kTabletVendorID: Int64 = 0xBEEF
private let kTabletProductID: Int64 = 0x0001

/// How the client's fingers should behave on the Mac.
public enum TouchMode: String, CaseIterable {
    /// A single finger moves and clicks the pointer.
    case pointer
    /// Fingers are ignored entirely; only the pen draws. The setting that
    /// makes palm rejection a non-issue on a tablet without a real digitiser.
    case penOnly

    var title: String {
        switch self {
        case .pointer: return "Finger moves the pointer"
        case .penOnly: return "Pen only (ignore fingers)"
        }
    }
}

/// Injects client input as macOS events, mapped onto one display.
final class InputInjector {
    private var displayID: CGDirectDisplayID
    private let source: CGEventSource?

    private var isPenDown = false
    private var isPenInProximity = false
    private var isFingerDown = false
    private var lastPoint = CGPoint.zero

    /// Set from the menu. Read on the input thread, written on main.
    var touchMode: TouchMode = .pointer

    init(displayID: CGDirectDisplayID) {
        self.displayID = displayID
        // A private source keeps our synthetic events from being merged with
        // the real HID stream's state, which otherwise makes modifier keys and
        // button state leak between the two.
        self.source = CGEventSource(stateID: .privateState)
        self.source?.setLocalEventsFilterDuringSuppressionState(
            [.permitLocalMouseEvents, .permitLocalKeyboardEvents, .permitSystemDefinedEvents],
            state: .eventSuppressionStateSuppressionInterval)
    }

    func updateDisplayID(_ newID: CGDirectDisplayID) {
        displayID = newID
    }

    /// Map normalised client coordinates onto the virtual display's bounds in
    /// global screen space. Clamped, because a client that reports slightly
    /// out-of-range coordinates should stay on its own display rather than
    /// throwing the pointer onto the Mac's main screen.
    private func screenPoint(x: Float, y: Float) -> CGPoint {
        let bounds = CGDisplayBounds(displayID)
        let clampedX = CGFloat(min(max(x, 0), 1))
        let clampedY = CGFloat(min(max(y, 0), 1))
        return CGPoint(x: bounds.origin.x + clampedX * bounds.width,
                       y: bounds.origin.y + clampedY * bounds.height)
    }

    // MARK: - Finger

    func handle(touch event: TouchEvent) {
        guard touchMode == .pointer else { return }
        // Only the first contact drives the pointer. Additional contacts are
        // either part of a gesture (which the client sends as scroll/pinch) or
        // a palm, and either way must not fight the primary finger.
        guard event.pointerId == 0 else { return }

        let point = screenPoint(x: event.x, y: event.y)
        lastPoint = point

        switch event.phase {
        case .down:
            post(mouse: .leftMouseDown, at: point, subtype: NX_SUBTYPE_DEFAULT)
            isFingerDown = true
        case .move:
            post(mouse: isFingerDown ? .leftMouseDragged : .mouseMoved,
                 at: point, subtype: NX_SUBTYPE_DEFAULT)
        case .up, .cancel:
            if isFingerDown {
                post(mouse: .leftMouseUp, at: point, subtype: NX_SUBTYPE_DEFAULT)
                isFingerDown = false
            }
        case .hover, .hoverEnd:
            break
        }
    }

    // MARK: - Pen

    func handle(pen event: PenEvent) {
        let point = screenPoint(x: event.x, y: event.y)
        lastPoint = point

        switch event.phase {
        case .hover:
            enterProximityIfNeeded()
            postTabletPoint(.mouseMoved, at: point, event: event, pressure: 0, buttonMask: 0)

        case .hoverEnd:
            if isPenDown {
                postTabletPoint(.leftMouseUp, at: point, event: event, pressure: 0, buttonMask: 0)
                isPenDown = false
            }
            leaveProximityIfNeeded()

        case .down:
            enterProximityIfNeeded()
            let button = penButton(for: event)
            postTabletPoint(button.down, at: point, event: event,
                            pressure: max(event.pressure, 0.001), buttonMask: button.mask)
            isPenDown = true

        case .move:
            enterProximityIfNeeded()
            if isPenDown {
                let button = penButton(for: event)
                postTabletPoint(button.dragged, at: point, event: event,
                                pressure: max(event.pressure, 0.001), buttonMask: button.mask)
            } else {
                postTabletPoint(.mouseMoved, at: point, event: event, pressure: 0, buttonMask: 0)
            }

        case .up, .cancel:
            if isPenDown {
                let button = penButton(for: event)
                postTabletPoint(button.up, at: point, event: event, pressure: 0, buttonMask: 0)
                isPenDown = false
            }
        }
    }

    /// The S Pen's barrel button is the conventional right-click; the eraser
    /// end maps to a right-click too, because macOS has no eraser concept and
    /// most apps bind erase to the secondary button.
    private func penButton(for event: PenEvent)
        -> (down: CGEventType, dragged: CGEventType, up: CGEventType, mask: Int64) {
        let barrel = event.buttons & 0x01 != 0
        let eraser = event.buttons & 0x02 != 0
        if barrel || eraser {
            return (.rightMouseDown, .rightMouseDragged, .rightMouseUp, 0x02)
        }
        return (.leftMouseDown, .leftMouseDragged, .leftMouseUp, 0x01)
    }

    /// Apps decide whether to look for pressure at all based on seeing a
    /// tablet come into proximity. Without this, many ignore the tablet fields.
    private func enterProximityIfNeeded() {
        guard !isPenInProximity else { return }
        isPenInProximity = true
        postProximity(entering: true)
    }

    private func leaveProximityIfNeeded() {
        guard isPenInProximity else { return }
        isPenInProximity = false
        postProximity(entering: false)
    }

    /// Called when a client disconnects, so the Mac is not left believing a
    /// pen is hovering over a display that no longer exists.
    func resetState() {
        if isPenDown {
            post(mouse: .leftMouseUp, at: lastPoint, subtype: NX_SUBTYPE_DEFAULT)
            isPenDown = false
        }
        if isFingerDown {
            post(mouse: .leftMouseUp, at: lastPoint, subtype: NX_SUBTYPE_DEFAULT)
            isFingerDown = false
        }
        leaveProximityIfNeeded()
    }

    private func postProximity(entering: Bool) {
        guard let event = CGEvent(mouseEventSource: source, mouseType: .mouseMoved,
                                  mouseCursorPosition: lastPoint, mouseButton: .left) else { return }
        event.setIntegerValueField(.mouseEventSubtype, value: NX_SUBTYPE_TABLET_PROXIMITY)
        event.setIntegerValueField(.tabletProximityEventVendorID, value: kTabletVendorID)
        event.setIntegerValueField(.tabletProximityEventTabletID, value: kTabletProductID)
        event.setIntegerValueField(.tabletProximityEventPointerID, value: 0)
        event.setIntegerValueField(.tabletProximityEventDeviceID, value: kTabletDeviceID)
        event.setIntegerValueField(.tabletProximityEventSystemTabletID, value: 0)
        event.setIntegerValueField(.tabletProximityEventVendorPointerType, value: 1)   // pen
        event.setIntegerValueField(.tabletProximityEventVendorPointerSerialNumber, value: 1)
        event.setIntegerValueField(.tabletProximityEventVendorUniqueID, value: 0)
        // Advertise pressure, tilt and absolute position so apps enable them.
        event.setIntegerValueField(.tabletProximityEventCapabilityMask, value: 0x0F)
        event.setIntegerValueField(.tabletProximityEventPointerType, value: 1)         // NX_TABLET_POINTER_PEN
        event.setIntegerValueField(.tabletProximityEventEnterProximity, value: entering ? 1 : 0)
        event.post(tap: .cghidEventTap)
    }

    private func postTabletPoint(_ type: CGEventType, at point: CGPoint,
                                 event penEvent: PenEvent, pressure: Float, buttonMask: Int64) {
        let button: CGMouseButton = (type == .rightMouseDown || type == .rightMouseDragged
                                     || type == .rightMouseUp) ? .right : .left
        guard let cg = CGEvent(mouseEventSource: source, mouseType: type,
                               mouseCursorPosition: point, mouseButton: button) else { return }

        cg.setIntegerValueField(.mouseEventSubtype, value: NX_SUBTYPE_TABLET_POINT)

        let tilt = penEvent.macOSTilt
        cg.setDoubleValueField(.tabletEventPointPressure, value: Double(min(max(pressure, 0), 1)))
        cg.setDoubleValueField(.tabletEventTiltX, value: Double(min(max(tilt.x, -1), 1)))
        cg.setDoubleValueField(.tabletEventTiltY, value: Double(min(max(tilt.y, -1), 1)))
        cg.setIntegerValueField(.tabletEventPointButtons, value: buttonMask)
        cg.setIntegerValueField(.tabletEventDeviceID, value: kTabletDeviceID)

        // Absolute position in the tablet's own coordinate space. Some apps
        // prefer these over the cursor position for stroke smoothing.
        let bounds = CGDisplayBounds(displayID)
        if bounds.width > 0 && bounds.height > 0 {
            cg.setIntegerValueField(.tabletEventPointX,
                                    value: Int64(Double(penEvent.x) * 32767.0))
            cg.setIntegerValueField(.tabletEventPointY,
                                    value: Int64(Double(penEvent.y) * 32767.0))
        }
        cg.setDoubleValueField(.tabletEventRotation, value: 0)

        cg.post(tap: .cghidEventTap)
    }

    private func post(mouse type: CGEventType, at point: CGPoint, subtype: Int64) {
        guard let event = CGEvent(mouseEventSource: source, mouseType: type,
                                  mouseCursorPosition: point, mouseButton: .left) else { return }
        event.setIntegerValueField(.mouseEventSubtype, value: subtype)
        event.post(tap: .cghidEventTap)
    }

    // MARK: - Gestures

    /// Two-finger scroll. The client accumulates the delta and sends it here in
    /// points, so the host does not need to track individual contacts.
    func handle(scroll event: ScrollEvent) {
        // Scroll events land wherever the pointer is, so put the pointer on
        // the virtual display first or the Mac scrolls the wrong window.
        moveCursorIfNeeded()

        guard let cg = CGEvent(scrollWheelEvent2Source: source,
                               units: .pixel,
                               wheelCount: 2,
                               wheel1: Int32(event.deltaY.rounded()),
                               wheel2: Int32(event.deltaX.rounded()),
                               wheel3: 0) else { return }
        // Marking it continuous makes macOS treat it as a trackpad scroll —
        // which is what gives momentum-aware apps the right feel.
        cg.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
        cg.post(tap: .cghidEventTap)
    }

    /// Pinch to zoom. CoreGraphics has no public gesture constructor, so this
    /// builds an NSEventTypeMagnify event by hand. Best-effort: apps that only
    /// honour Cmd+scroll will not respond to it.
    func handle(pinch event: PinchEvent) {
        moveCursorIfNeeded()

        guard let cg = CGEvent(source: source) else { return }
        cg.type = kCGEventTypeMagnify
        cg.location = lastPoint
        cg.setDoubleValueField(kCGMagnificationField, value: Double(event.magnification))
        cg.setIntegerValueField(.mouseEventSubtype, value: NX_SUBTYPE_DEFAULT)
        cg.post(tap: .cghidEventTap)
    }

    /// Park the pointer inside the virtual display so gestures address it.
    private func moveCursorIfNeeded() {
        let bounds = CGDisplayBounds(displayID)
        guard bounds.width > 0 else { return }
        if !bounds.contains(lastPoint) {
            lastPoint = CGPoint(x: bounds.midX, y: bounds.midY)
        }
        CGWarpMouseCursorPosition(lastPoint)
    }
}
