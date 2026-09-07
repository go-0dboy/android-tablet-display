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

/// NSEvent gesture types. CGEventType does not expose them, and the value
/// matters: 29 is NSEventTypeGesture, which AppKit delivers as a generic
/// gesture carrying no magnification. Magnify is 30.
private let kNSEventTypeMagnify = CGEventType(rawValue: 30)!
private let kNSEventTypeBeginGesture = CGEventType(rawValue: 19)!
private let kNSEventTypeEndGesture = CGEventType(rawValue: 20)!

/// Undocumented event fields carrying a gesture's amount and phase.
private let kCGGestureValueField = CGEventField(rawValue: 113)!
private let kCGGesturePhaseField = CGEventField(rawValue: 132)!

/// Virtual key codes.
private let kVK_ANSI_Equal: CGKeyCode = 24
private let kVK_ANSI_Minus: CGKeyCode = 27

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
    /// How a pinch is delivered. Defaults to the strategy that was measured to
    /// work on this macOS; see handle(pinch:).
    var zoomStrategy: ZoomStrategy = .keyboardSteps

    private var zoomAccumulator = ZoomStepAccumulator()

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
        // Marking it continuous makes macOS treat it as a trackpad scroll
        // rather than a mouse wheel, and the phase fields are what
        // momentum-aware applications look for. Verified delivered with the
        // right deltas and phases against a receiver that logs NSEvents.
        cg.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
        cg.setIntegerValueField(.scrollWheelEventScrollPhase,
                                value: GesturePhase.from(event.phase).rawValue)
        cg.setIntegerValueField(.scrollWheelEventMomentumPhase,
                                value: ScrollMomentumPhase.none.rawValue)
        cg.post(tap: .cghidEventTap)
    }

    /// Pinch to zoom.
    ///
    /// There is no public way to post a gesture on macOS, so this was settled
    /// by measurement rather than by reading. Findings on macOS 26.6.2, using
    /// the `gesturelab` tool in this repo against a receiver that logs what
    /// AppKit actually delivers:
    ///
    ///   * Synthesising NSEventTypeMagnify (type 30) with the magnification
    ///     and phase fields produces an event that is never delivered at all —
    ///     not to the target application, and not even to a local event
    ///     monitor. Thirteen values of the gesture-type field were tried
    ///     across all three phases. The kept code is correct as far as anyone
    ///     can tell; the system simply drops it.
    ///   * Command held with a scroll wheel does reach the application, but
    ///     the modifier does not stick to the scroll events, so nothing zooms.
    ///   * Command-plus and command-minus work.
    ///
    /// So the default is keyboard steps, because it is the one that was
    /// observed to work. The others are selectable, because this is exactly
    /// the kind of thing a future macOS may change in either direction, and a
    /// setting costs nothing.
    ///
    /// See docs/STATUS.md for the per-application table.
    func handle(pinch event: PinchEvent) {
        moveCursorIfNeeded()

        switch zoomStrategy {
        case .gestureEvent:  postMagnifyGesture(event)
        case .commandScroll: postCommandScroll(event)
        case .keyboardSteps: postZoomKeystrokes(event)
        }
    }

    /// The trackpad-native path. Kept because it is the only one that could
    /// ever be smooth, and because "does not work today" is not "cannot work".
    private func postMagnifyGesture(_ event: PinchEvent) {
        let phase = GesturePhase.from(event.phase)

        if phase == .began {
            post(gesture: kNSEventTypeBeginGesture, phase: .began, value: 0)
        }
        post(gesture: kNSEventTypeMagnify, phase: phase, value: Double(event.magnification))
        if phase == .ended || phase == .cancelled {
            post(gesture: kNSEventTypeEndGesture, phase: phase, value: 0)
        }
    }

    private func post(gesture type: CGEventType, phase: GesturePhase, value: Double) {
        guard let event = CGEvent(source: source) else { return }
        event.type = type
        event.setIntegerValueField(kCGGesturePhaseField, value: phase.rawValue)
        if value != 0 {
            event.setDoubleValueField(kCGGestureValueField, value: value)
        }
        event.post(tap: .cghidEventTap)
    }

    private func postCommandScroll(_ event: PinchEvent) {
        // Scroll deltas are in points; a pinch increment is a ratio, so scale
        // it into something a zoom-on-scroll application reads as one notch.
        let delta = Int32((Double(event.magnification) * 400).rounded())
        guard delta != 0 || event.phase == .down || event.phase == .up else { return }

        guard let scroll = CGEvent(scrollWheelEvent2Source: source, units: .pixel,
                                   wheelCount: 2, wheel1: delta, wheel2: 0, wheel3: 0)
        else { return }
        scroll.flags = .maskCommand
        scroll.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
        scroll.setIntegerValueField(.scrollWheelEventScrollPhase,
                                    value: GesturePhase.from(event.phase).rawValue)
        scroll.post(tap: .cghidEventTap)
    }

    /// Command-plus and command-minus. Stepped rather than smooth, so a pinch
    /// is accumulated and a keystroke emitted only when enough has built up —
    /// otherwise every one of the dozens of increments in a single pinch would
    /// fire a keypress and the zoom would run away.
    private func postZoomKeystrokes(_ event: PinchEvent) {
        switch event.phase {
        case .down:
            zoomAccumulator.reset()
            return
        case .up, .cancel:
            zoomAccumulator.reset()
            return
        default:
            break
        }

        let steps = zoomAccumulator.steps(for: Double(event.magnification))
        guard steps != 0 else { return }

        let key = steps > 0 ? kVK_ANSI_Equal : kVK_ANSI_Minus
        for _ in 0..<min(abs(steps), 4) {
            postKey(key, flags: .maskCommand)
        }
    }

    private func postKey(_ keyCode: CGKeyCode, flags: CGEventFlags) {
        guard let down = CGEvent(keyboardEventSource: source, virtualKey: keyCode,
                                 keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: keyCode,
                               keyDown: false) else { return }
        down.flags = flags
        up.flags = flags
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
    }

    /// Park the pointer inside the virtual display before a gesture.
    ///
    /// This is not a nicety. Scroll and gesture events are routed to the window
    /// under the POINTER, not to the focused window — posting one with the
    /// cursor elsewhere sends it to whatever happens to be under the mouse,
    /// which looks exactly like "gestures do not work". Finding this was the
    /// difference between scroll appearing broken and scroll being correct.
    private func moveCursorIfNeeded() {
        let bounds = CGDisplayBounds(displayID)
        guard bounds.width > 0 else { return }
        if !bounds.contains(lastPoint) {
            lastPoint = CGPoint(x: bounds.midX, y: bounds.midY)
        }
        CGWarpMouseCursorPosition(lastPoint)
    }
}
