// Gestures.swift — how a two-finger gesture from the tablet becomes something
// macOS acts on.
//
// Scrolling is easy: CoreGraphics has a documented scroll-wheel constructor,
// and adding the phase fields a trackpad sends makes it behave like a trackpad
// rather than a mouse wheel.
//
// Zooming is not. There is no public way to post a gesture event. That is a
// reason to work out what does function, not a reason to stop — so there are
// three strategies here, tried in order, and the host records which one
// actually moved a real application.

import Foundation

/// How to deliver a pinch.
public enum ZoomStrategy: String, CaseIterable, Sendable, Codable {
    /// Synthesise the same gesture event an actual trackpad produces.
    /// Undocumented, and the only option that gives smooth, continuous zoom.
    case gestureEvent
    /// Command and scroll wheel. Many graphics and map applications treat this
    /// as zoom, and it is continuous.
    case commandScroll
    /// Command-plus and command-minus. Stepped rather than smooth, but it works
    /// in more applications than anything else.
    case keyboardSteps

    public var title: String {
        switch self {
        case .gestureEvent:  return "Trackpad gesture (smooth)"
        case .commandScroll: return "⌘ + scroll"
        case .keyboardSteps: return "⌘ + and ⌘ −"
        }
    }

    /// Order to try when nothing has been chosen: smoothest first, most
    /// compatible last.
    public static let preferenceOrder: [ZoomStrategy] =
        [.gestureEvent, .commandScroll, .keyboardSteps]
}

/// Event-field numbers CoreGraphics does not publish.
///
/// A magnify event carries its amount and phase in fields AppKit reads back
/// through `-[NSEvent magnification]` and `-[NSEvent phase]`. The numbers are
/// stable across releases and are the same ones every trackpad-gesture tool
/// uses; they are named here so the call sites read as intent rather than as
/// magic numbers.
public enum GestureEventField {
    /// The gesture's own type discriminator.
    public static let gestureType: UInt32 = 110
    /// Magnification amount, as a double.
    public static let gestureValue: UInt32 = 113
    /// Gesture phase: 1 began, 2 changed, 4 ended, 8 cancelled.
    public static let gesturePhase: UInt32 = 132
    /// Rotation amount in degrees, as a double.
    public static let gestureRotation: UInt32 = 114
}

/// NSEvent type values, which CGEventType does not expose.
public enum GestureEventType {
    public static let rotate: UInt32 = 18
    public static let beginGesture: UInt32 = 19
    public static let endGesture: UInt32 = 20
    public static let gesture: UInt32 = 29
    /// The one that matters. Using 29 here instead of 30 produces an event
    /// AppKit delivers as a generic gesture with no magnification, which looks
    /// like "pinch does nothing" from the outside.
    public static let magnify: UInt32 = 30
    public static let swipe: UInt32 = 31
    public static let smartMagnify: UInt32 = 32
}

/// Phase values shared by gesture and scroll events.
public enum GesturePhase: Int64, Sendable {
    case none = 0
    case began = 1
    case changed = 2
    case ended = 4
    case cancelled = 8

    /// Map a contact phase onto the gesture phase macOS expects.
    public static func from(_ phase: TouchPhase) -> GesturePhase {
        switch phase {
        case .down:            return .began
        case .move:            return .changed
        case .up:              return .ended
        case .cancel:          return .cancelled
        case .hover, .hoverEnd: return .none
        }
    }
}

/// Momentum phase on a scroll event. A trackpad reports these, and applications
/// with inertial scrolling look for them.
public enum ScrollMomentumPhase: Int64, Sendable {
    case none = 0
    case begin = 1
    case `continue` = 2
    case end = 3
}

/// Turns a stream of pinch magnifications into discrete zoom steps, for the
/// strategies that cannot zoom continuously.
///
/// A pinch arrives as many small increments; firing a ⌘+ for each would zoom
/// wildly. This accumulates until the total crosses a threshold, then emits one
/// step and keeps the remainder.
public struct ZoomStepAccumulator {
    /// Total relative change needed before one step is emitted. 0.12 is about
    /// a finger-width of pinch, which lines up with one ⌘+ press feeling right.
    public var threshold: Double
    private var accumulated: Double = 0

    public init(threshold: Double = 0.12) {
        self.threshold = threshold
    }

    /// Feed one magnification increment; get back how many steps to emit.
    /// Positive means zoom in.
    public mutating func steps(for magnification: Double) -> Int {
        guard magnification.isFinite else { return 0 }
        accumulated += magnification

        var steps = 0
        while accumulated >= threshold {
            accumulated -= threshold
            steps += 1
        }
        while accumulated <= -threshold {
            accumulated += threshold
            steps -= 1
        }
        return steps
    }

    public mutating func reset() {
        accumulated = 0
    }
}

/// Which strategies were observed to work, so the host can prefer one and the
/// docs can carry a real table rather than a guess.
public struct ZoomStrategyReport: Equatable, Sendable, Codable {
    public var strategy: ZoomStrategy
    public var application: String
    public var worked: Bool
    public var note: String

    public init(strategy: ZoomStrategy, application: String, worked: Bool, note: String = "") {
        self.strategy = strategy
        self.application = application
        self.worked = worked
        self.note = note
    }
}
