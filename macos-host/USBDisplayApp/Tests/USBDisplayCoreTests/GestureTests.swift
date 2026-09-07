import XCTest
@testable import USBDisplayCore

final class ZoomStepAccumulatorTests: XCTestCase {

    /// The failure this guards against: a pinch arrives as dozens of small
    /// increments, and emitting a keystroke for each one makes the zoom run
    /// away instantly.
    func testSmallIncrementsDoNotEmitAStepEach() {
        var accumulator = ZoomStepAccumulator(threshold: 0.12)
        var total = 0
        for _ in 0..<20 {
            total += accumulator.steps(for: 0.005)
        }
        // 20 × 0.005 = 0.10, still under one threshold.
        XCTAssertEqual(total, 0)
    }

    func testAccumulatedIncrementsEventuallyEmitAStep() {
        var accumulator = ZoomStepAccumulator(threshold: 0.12)
        var total = 0
        for _ in 0..<30 {
            total += accumulator.steps(for: 0.01)
        }
        // 0.30 total, so two whole steps.
        XCTAssertEqual(total, 2)
    }

    func testZoomingOutEmitsNegativeSteps() {
        var accumulator = ZoomStepAccumulator(threshold: 0.1)
        XCTAssertEqual(accumulator.steps(for: -0.25), -2)
    }

    /// The remainder must carry over, or a slow pinch loses ground on every
    /// event and never zooms at all.
    func testRemainderCarriesOver() {
        var accumulator = ZoomStepAccumulator(threshold: 0.1)
        XCTAssertEqual(accumulator.steps(for: 0.09), 0)
        XCTAssertEqual(accumulator.steps(for: 0.02), 1)   // 0.11 total
        XCTAssertEqual(accumulator.steps(for: 0.09), 1)   // 0.10 remaining + 0.09
    }

    func testDirectionChangeCancelsRatherThanAccumulating() {
        var accumulator = ZoomStepAccumulator(threshold: 0.1)
        XCTAssertEqual(accumulator.steps(for: 0.09), 0)
        XCTAssertEqual(accumulator.steps(for: -0.09), 0)
        // Back to roughly zero, so a further small pinch still emits nothing.
        XCTAssertEqual(accumulator.steps(for: 0.05), 0)
    }

    func testResetClearsTheRemainder() {
        var accumulator = ZoomStepAccumulator(threshold: 0.1)
        _ = accumulator.steps(for: 0.09)
        accumulator.reset()
        XCTAssertEqual(accumulator.steps(for: 0.05), 0)
    }

    /// A garbage magnification must not produce an infinite loop.
    func testNonFiniteInputIsIgnored() {
        var accumulator = ZoomStepAccumulator(threshold: 0.1)
        XCTAssertEqual(accumulator.steps(for: .nan), 0)
        XCTAssertEqual(accumulator.steps(for: .infinity), 0)
        XCTAssertEqual(accumulator.steps(for: 0.15), 1)
    }

    func testALargeJumpEmitsProportionallyManySteps() {
        var accumulator = ZoomStepAccumulator(threshold: 0.1)
        XCTAssertEqual(accumulator.steps(for: 0.55), 5)
    }
}

final class GesturePhaseTests: XCTestCase {

    /// These values were confirmed against a receiver logging real NSEvents:
    /// a scroll posted with phase 1/2/4 arrives as began/changed/ended.
    func testContactPhasesMapToGesturePhases() {
        XCTAssertEqual(GesturePhase.from(.down), .began)
        XCTAssertEqual(GesturePhase.from(.move), .changed)
        XCTAssertEqual(GesturePhase.from(.up), .ended)
        XCTAssertEqual(GesturePhase.from(.cancel), .cancelled)
        XCTAssertEqual(GesturePhase.from(.hover), .none)
    }

    /// 29 is NSEventTypeGesture and carries no magnification; 30 is Magnify.
    /// Using the wrong one is silent, so pin it.
    func testMagnifyEventTypeIsThirty() {
        XCTAssertEqual(GestureEventType.magnify, 30)
        XCTAssertEqual(GestureEventType.gesture, 29)
        XCTAssertNotEqual(GestureEventType.magnify, GestureEventType.gesture)
    }

    func testStrategyPreferenceOrderIsMostCapableFirst() {
        XCTAssertEqual(ZoomStrategy.preferenceOrder.first, .gestureEvent)
        XCTAssertEqual(ZoomStrategy.preferenceOrder.last, .keyboardSteps)
        XCTAssertEqual(Set(ZoomStrategy.preferenceOrder), Set(ZoomStrategy.allCases))
    }
}
