package com.usbtablet.display

import kotlin.math.abs
import kotlin.math.hypot

/**
 * Turns Android touch input into protocol messages.
 *
 * Kept free of Android framework types on purpose: [PointerSample] is a plain
 * value, so every rule here -- palm rejection, the one-finger/two-finger
 * split, the gesture thresholds -- is unit-testable without a device. Given
 * the hardware this has to work on is a phone and a tablet that are not always
 * to hand, that is the difference between "tested" and "hoped".
 *
 * The bug this replaces: the old client switched on `event.action` rather than
 * `event.actionMasked`. ACTION_POINTER_DOWN and ACTION_POINTER_UP carry the
 * pointer index packed into the high bits, so those cases never matched and
 * multi-touch did not exist at all.
 */

/** What the fingers should do on the Mac. Mirrors TouchMode in the host. */
enum class TouchMode(val wireName: String) {
    POINTER("pointer"),
    PEN_ONLY("penOnly");

    companion object {
        fun from(name: String?): TouchMode =
            entries.firstOrNull { it.wireName == name } ?: POINTER
    }
}

enum class ToolType { FINGER, STYLUS, ERASER, OTHER }

/** One pointer at one instant, normalised. */
data class PointerSample(
    val pointerId: Int,
    val tool: ToolType,
    /** Normalised 0..1 across the surface. */
    val x: Float,
    val y: Float,
    val pressure: Float,
    /** Android AXIS_TILT: angle from the surface normal, radians. */
    val tiltRadians: Float,
    /** Android AXIS_ORIENTATION: direction of lean, radians. */
    val orientationRadians: Float,
    /** Contact size, normalised against the surface's smaller edge. Used for
     *  palm rejection: a palm is simply much larger than a fingertip. */
    val sizeFraction: Float = 0f
)

/** Which gesture the current set of contacts is doing. */
private enum class GestureState { NONE, PENDING, SCROLLING, PINCHING }

class TouchTranslator(
    var touchMode: TouchMode = TouchMode.POINTER,
    /**
     * Contacts larger than this fraction of the surface's short edge are
     * treated as a palm. 0.28 is deliberately generous: rejecting a real
     * fingertip is far more annoying than accepting an occasional palm.
     */
    private val palmSizeThreshold: Float = 0.28f,
    /** Movement, in normalised units, before a two-finger gesture commits. */
    private val gestureSlop: Float = 0.01f,
    /** Points of scroll per unit of normalised movement. */
    private val scrollScale: Float = 1400f
) {
    private var gesture = GestureState.NONE
    private var lastCentroidX = 0f
    private var lastCentroidY = 0f
    private var lastSpan = 0f
    private var gestureStartCentroidX = 0f
    private var gestureStartCentroidY = 0f
    private var gestureStartSpan = 0f

    /** True while a stylus is touching or hovering. */
    private var stylusInRange = false
    private var pointerDown = false

    /**
     * Feed one frame of pointer state and get the messages to send.
     *
     * @param pointers every contact currently down (empty on an up event).
     * @param phase what happened to [changed].
     * @param changed the pointer this event is about, if any.
     */
    fun translate(
        pointers: List<PointerSample>,
        phase: Phase,
        changed: PointerSample?
    ): List<OutgoingMessage> {
        val messages = mutableListOf<OutgoingMessage>()

        // --- Pen first. A stylus always wins over any finger on the glass.
        val stylus = pointers.firstOrNull { it.tool == ToolType.STYLUS || it.tool == ToolType.ERASER }
            ?: changed?.takeIf { it.tool == ToolType.STYLUS || it.tool == ToolType.ERASER }

        if (stylus != null) {
            // A pen coming into range cancels anything the fingers were doing,
            // so a hand resting on the screen does not keep dragging.
            if (!stylusInRange) {
                messages += endGesture()
                messages += releasePointerIfDown(stylus.x, stylus.y)
            }
            stylusInRange = phase != Phase.HOVER_END && phase != Phase.UP && phase != Phase.CANCEL

            messages += OutgoingMessage.Pen(
                phase = phase,
                x = stylus.x, y = stylus.y,
                pressure = stylus.pressure.coerceIn(0f, 1f),
                tiltRadians = stylus.tiltRadians,
                orientationRadians = stylus.orientationRadians,
                buttons = buttonsFor(stylus)
            )
            return messages
        }

        if (stylusInRange && phase == Phase.HOVER_END) stylusInRange = false

        // --- Palm rejection. While a pen is in range, fingers are ignored
        // outright; that is the single most effective rule there is.
        if (stylusInRange) return messages

        val real = pointers.filter { it.sizeFraction <= palmSizeThreshold }
        if (real.isEmpty() && pointers.isNotEmpty()) {
            // Everything on the glass looks like a palm.
            messages += endGesture()
            messages += releasePointerIfDown(pointers[0].x, pointers[0].y)
            return messages
        }

        return messages + when {
            real.size >= 2 -> handleGesture(real, phase)
            real.size == 1 -> handleSingleFinger(real[0], phase)
            else -> endGesture() + releasePointerIfDown(lastCentroidX, lastCentroidY)
        }
    }

    private fun buttonsFor(sample: PointerSample): Int =
        if (sample.tool == ToolType.ERASER) 0x02 else 0x00

    private fun handleSingleFinger(finger: PointerSample, phase: Phase): List<OutgoingMessage> {
        val messages = mutableListOf<OutgoingMessage>()

        // Lifting from two fingers to one must not resume pointer dragging.
        if (gesture == GestureState.SCROLLING || gesture == GestureState.PINCHING) {
            messages += endGesture()
            return messages
        }
        gesture = GestureState.NONE

        if (touchMode == TouchMode.PEN_ONLY) return messages

        when (phase) {
            Phase.DOWN -> { pointerDown = true }
            Phase.UP, Phase.CANCEL -> { pointerDown = false }
            else -> {}
        }
        lastCentroidX = finger.x
        lastCentroidY = finger.y

        messages += OutgoingMessage.Touch(0, phase, finger.x, finger.y)
        return messages
    }

    private fun handleGesture(pointers: List<PointerSample>, phase: Phase): List<OutgoingMessage> {
        val messages = mutableListOf<OutgoingMessage>()

        // A finger that was moving the pointer must be released before a
        // gesture starts, or the Mac is left mid-drag.
        messages += releasePointerIfDown(lastCentroidX, lastCentroidY)

        val a = pointers[0]
        val b = pointers[1]
        val centroidX = (a.x + b.x) / 2f
        val centroidY = (a.y + b.y) / 2f
        val span = hypot((a.x - b.x), (a.y - b.y))

        if (gesture == GestureState.NONE || phase == Phase.DOWN) {
            gesture = GestureState.PENDING
            gestureStartCentroidX = centroidX
            gestureStartCentroidY = centroidY
            gestureStartSpan = span
            lastCentroidX = centroidX
            lastCentroidY = centroidY
            lastSpan = span
            return messages
        }

        if (gesture == GestureState.PENDING) {
            val moved = hypot(centroidX - gestureStartCentroidX,
                              centroidY - gestureStartCentroidY)
            val spanChange = abs(span - gestureStartSpan)
            if (moved < gestureSlop && spanChange < gestureSlop) return messages

            // Whichever exceeded the slop first decides the gesture. Locking it
            // in stops a scroll from drifting into a zoom halfway through.
            gesture = if (spanChange > moved) GestureState.PINCHING else GestureState.SCROLLING
            lastCentroidX = centroidX
            lastCentroidY = centroidY
            lastSpan = span

            messages += if (gesture == GestureState.PINCHING) {
                OutgoingMessage.Pinch(0f, Phase.DOWN)
            } else {
                OutgoingMessage.Scroll(0f, 0f, Phase.DOWN)
            }
            return messages
        }

        when (gesture) {
            GestureState.SCROLLING -> {
                // Natural scrolling: dragging content down moves the view up,
                // which is what macOS does by default and what a tablet user
                // expects from the same gesture on the phone.
                val dx = (centroidX - lastCentroidX) * scrollScale
                val dy = (centroidY - lastCentroidY) * scrollScale
                if (phase == Phase.UP || phase == Phase.CANCEL) {
                    messages += OutgoingMessage.Scroll(0f, 0f, Phase.UP)
                    gesture = GestureState.NONE
                } else if (dx != 0f || dy != 0f) {
                    messages += OutgoingMessage.Scroll(dx, dy, Phase.MOVE)
                }
            }
            GestureState.PINCHING -> {
                if (phase == Phase.UP || phase == Phase.CANCEL) {
                    messages += OutgoingMessage.Pinch(0f, Phase.UP)
                    gesture = GestureState.NONE
                } else if (lastSpan > 0.0001f) {
                    // Incremental factor, which is what NSEvent's magnification
                    // field expects: 0.02 means "2% larger since last time".
                    val magnification = (span - lastSpan) / lastSpan
                    if (abs(magnification) > 0.0001f) {
                        messages += OutgoingMessage.Pinch(magnification, Phase.MOVE)
                    }
                }
            }
            else -> {}
        }

        lastCentroidX = centroidX
        lastCentroidY = centroidY
        lastSpan = span
        return messages
    }

    private fun endGesture(): List<OutgoingMessage> {
        val messages = when (gesture) {
            GestureState.SCROLLING -> listOf(OutgoingMessage.Scroll(0f, 0f, Phase.UP))
            GestureState.PINCHING -> listOf(OutgoingMessage.Pinch(0f, Phase.UP))
            else -> emptyList()
        }
        gesture = GestureState.NONE
        return messages
    }

    private fun releasePointerIfDown(x: Float, y: Float): List<OutgoingMessage> {
        if (!pointerDown) return emptyList()
        pointerDown = false
        return listOf(OutgoingMessage.Touch(0, Phase.UP, x, y))
    }

    /** Called when the connection drops, so no state leaks into the next one. */
    fun reset() {
        gesture = GestureState.NONE
        pointerDown = false
        stylusInRange = false
        lastSpan = 0f
    }
}
