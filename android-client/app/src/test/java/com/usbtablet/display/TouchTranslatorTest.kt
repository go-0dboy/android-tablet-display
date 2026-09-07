package com.usbtablet.display

import org.junit.Assert.*
import org.junit.Test

/**
 * The touch rules, tested without a device.
 *
 * This matters more than usual here: the hardware these rules are written for
 * -- a Samsung tablet with an S Pen -- is not always to hand, so every rule
 * that can be pinned down in a unit test is one fewer thing resting on "it
 * looked right when I tried it".
 */
class TouchTranslatorTest {

    private fun finger(id: Int, x: Float, y: Float, size: Float = 0.05f) =
        PointerSample(id, ToolType.FINGER, x, y, 1f, 0f, 0f, size)

    private fun stylus(x: Float, y: Float, pressure: Float = 0.5f,
                       tilt: Float = 0f, orientation: Float = 0f,
                       tool: ToolType = ToolType.STYLUS) =
        PointerSample(0, tool, x, y, pressure, tilt, orientation, 0.02f)

    // MARK: - Single finger

    @Test
    fun `one finger moves the pointer`() {
        val t = TouchTranslator()
        val down = t.translate(listOf(finger(0, 0.5f, 0.5f)), Phase.DOWN, finger(0, 0.5f, 0.5f))
        assertEquals(1, down.size)
        val touch = down[0] as OutgoingMessage.Touch
        assertEquals(Phase.DOWN, touch.phase)
        assertEquals(0.5f, touch.x, 0.001f)
    }

    @Test
    fun `pen only mode ignores fingers entirely`() {
        val t = TouchTranslator(touchMode = TouchMode.PEN_ONLY)
        assertTrue(t.translate(listOf(finger(0, 0.5f, 0.5f)), Phase.DOWN,
                               finger(0, 0.5f, 0.5f)).isEmpty())
        assertTrue(t.translate(listOf(finger(0, 0.6f, 0.5f)), Phase.MOVE,
                               finger(0, 0.6f, 0.5f)).isEmpty())
    }

    @Test
    fun `pen only mode still passes the pen through`() {
        val t = TouchTranslator(touchMode = TouchMode.PEN_ONLY)
        val messages = t.translate(listOf(stylus(0.3f, 0.3f)), Phase.DOWN, stylus(0.3f, 0.3f))
        assertTrue(messages.any { it is OutgoingMessage.Pen })
    }

    // MARK: - Pen

    @Test
    fun `pen carries pressure and tilt through unchanged`() {
        val t = TouchTranslator()
        val messages = t.translate(
            listOf(stylus(0.4f, 0.6f, pressure = 0.62f, tilt = 0.5f, orientation = 1.1f)),
            Phase.MOVE,
            stylus(0.4f, 0.6f, pressure = 0.62f, tilt = 0.5f, orientation = 1.1f))
        val pen = messages.filterIsInstance<OutgoingMessage.Pen>().single()
        assertEquals(0.62f, pen.pressure, 0.0001f)
        // Tilt stays polar: converting it is the host's job, in one place.
        assertEquals(0.5f, pen.tiltRadians, 0.0001f)
        assertEquals(1.1f, pen.orientationRadians, 0.0001f)
    }

    @Test
    fun `pressure is clamped to the unit range`() {
        val t = TouchTranslator()
        val over = t.translate(listOf(stylus(0f, 0f, pressure = 3.5f)), Phase.DOWN,
                               stylus(0f, 0f, pressure = 3.5f))
        assertEquals(1f, (over[0] as OutgoingMessage.Pen).pressure, 0.0001f)
    }

    @Test
    fun `the eraser end reports the secondary button`() {
        val t = TouchTranslator()
        val messages = t.translate(
            listOf(stylus(0.5f, 0.5f, tool = ToolType.ERASER)), Phase.DOWN,
            stylus(0.5f, 0.5f, tool = ToolType.ERASER))
        assertEquals(0x02, (messages[0] as OutgoingMessage.Pen).buttons)
    }

    @Test
    fun `hover is forwarded so the Mac knows a tablet is present`() {
        val t = TouchTranslator()
        val messages = t.translate(listOf(stylus(0.2f, 0.2f, pressure = 0f)),
                                   Phase.HOVER, stylus(0.2f, 0.2f, pressure = 0f))
        assertEquals(Phase.HOVER, (messages[0] as OutgoingMessage.Pen).phase)
    }

    // MARK: - Palm rejection

    @Test
    fun `a finger is ignored while the pen is in range`() {
        val t = TouchTranslator()
        t.translate(listOf(stylus(0.5f, 0.5f)), Phase.HOVER, stylus(0.5f, 0.5f))

        val palm = t.translate(listOf(finger(1, 0.1f, 0.9f)), Phase.DOWN, finger(1, 0.1f, 0.9f))
        assertTrue("a resting hand must not move the pointer while drawing",
                   palm.isEmpty())
    }

    @Test
    fun `fingers work again once the pen leaves`() {
        val t = TouchTranslator()
        t.translate(listOf(stylus(0.5f, 0.5f)), Phase.HOVER, stylus(0.5f, 0.5f))
        t.translate(emptyList(), Phase.HOVER_END, stylus(0.5f, 0.5f))

        val messages = t.translate(listOf(finger(0, 0.3f, 0.3f)), Phase.DOWN,
                                   finger(0, 0.3f, 0.3f))
        assertTrue(messages.any { it is OutgoingMessage.Touch })
    }

    @Test
    fun `a contact far larger than a fingertip is rejected as a palm`() {
        val t = TouchTranslator()
        val messages = t.translate(listOf(finger(0, 0.5f, 0.5f, size = 0.6f)),
                                   Phase.DOWN, finger(0, 0.5f, 0.5f, size = 0.6f))
        assertTrue(messages.none { it is OutgoingMessage.Touch &&
                                   it.phase == Phase.DOWN })
    }

    @Test
    fun `an ordinary fingertip is not rejected`() {
        val t = TouchTranslator()
        val messages = t.translate(listOf(finger(0, 0.5f, 0.5f, size = 0.12f)),
                                   Phase.DOWN, finger(0, 0.5f, 0.5f, size = 0.12f))
        assertTrue(messages.any { it is OutgoingMessage.Touch })
    }

    // MARK: - Two-finger gestures

    @Test
    fun `two fingers moving together scroll`() {
        val t = TouchTranslator()
        t.translate(listOf(finger(0, 0.4f, 0.4f), finger(1, 0.6f, 0.4f)),
                    Phase.DOWN, finger(1, 0.6f, 0.4f))
        // Move both down by the same amount: the span is unchanged, so this is
        // unambiguously a scroll and not a pinch.
        val messages = t.translate(listOf(finger(0, 0.4f, 0.6f), finger(1, 0.6f, 0.6f)),
                                   Phase.MOVE, finger(0, 0.4f, 0.6f))
        assertTrue(messages.any { it is OutgoingMessage.Scroll })
        assertTrue(messages.none { it is OutgoingMessage.Pinch })
    }

    @Test
    fun `two fingers separating pinch`() {
        val t = TouchTranslator()
        t.translate(listOf(finger(0, 0.45f, 0.5f), finger(1, 0.55f, 0.5f)),
                    Phase.DOWN, finger(1, 0.55f, 0.5f))
        // Spread apart with the centroid fixed: unambiguously a zoom.
        val messages = t.translate(listOf(finger(0, 0.25f, 0.5f), finger(1, 0.75f, 0.5f)),
                                   Phase.MOVE, finger(0, 0.25f, 0.5f))
        assertTrue(messages.any { it is OutgoingMessage.Pinch })
        assertTrue(messages.none { it is OutgoingMessage.Scroll })
    }

    @Test
    fun `a pinch outwards reports positive magnification`() {
        val t = TouchTranslator()
        t.translate(listOf(finger(0, 0.45f, 0.5f), finger(1, 0.55f, 0.5f)),
                    Phase.DOWN, finger(1, 0.55f, 0.5f))
        t.translate(listOf(finger(0, 0.25f, 0.5f), finger(1, 0.75f, 0.5f)),
                    Phase.MOVE, finger(0, 0.25f, 0.5f))
        val more = t.translate(listOf(finger(0, 0.15f, 0.5f), finger(1, 0.85f, 0.5f)),
                               Phase.MOVE, finger(0, 0.15f, 0.5f))
        val pinch = more.filterIsInstance<OutgoingMessage.Pinch>()
            .first { it.phase == Phase.MOVE }
        assertTrue("spreading fingers must zoom in, not out", pinch.magnification > 0)
    }

    @Test
    fun `a tiny movement does not commit to a gesture`() {
        val t = TouchTranslator()
        t.translate(listOf(finger(0, 0.4f, 0.4f), finger(1, 0.6f, 0.4f)),
                    Phase.DOWN, finger(1, 0.6f, 0.4f))
        val jitter = t.translate(listOf(finger(0, 0.4005f, 0.4f), finger(1, 0.6005f, 0.4f)),
                                 Phase.MOVE, finger(0, 0.4005f, 0.4f))
        assertTrue("a resting hand's jitter must not scroll the Mac", jitter.isEmpty())
    }

    @Test
    fun `once scrolling it stays scrolling`() {
        val t = TouchTranslator()
        t.translate(listOf(finger(0, 0.4f, 0.4f), finger(1, 0.6f, 0.4f)),
                    Phase.DOWN, finger(1, 0.6f, 0.4f))
        t.translate(listOf(finger(0, 0.4f, 0.6f), finger(1, 0.6f, 0.6f)),
                    Phase.MOVE, finger(0, 0.4f, 0.6f))
        // Now also change the span. A committed scroll must not become a zoom.
        val messages = t.translate(listOf(finger(0, 0.3f, 0.7f), finger(1, 0.7f, 0.7f)),
                                   Phase.MOVE, finger(0, 0.3f, 0.7f))
        assertTrue(messages.none { it is OutgoingMessage.Pinch })
    }

    @Test
    fun `a second finger releases a pointer that was already down`() {
        val t = TouchTranslator()
        t.translate(listOf(finger(0, 0.5f, 0.5f)), Phase.DOWN, finger(0, 0.5f, 0.5f))
        val messages = t.translate(listOf(finger(0, 0.4f, 0.4f), finger(1, 0.6f, 0.4f)),
                                   Phase.DOWN, finger(1, 0.6f, 0.4f))
        val release = messages.filterIsInstance<OutgoingMessage.Touch>()
            .firstOrNull { it.phase == Phase.UP }
        assertNotNull("the Mac must not be left mid-drag when a gesture starts", release)
    }

    @Test
    fun `lifting to one finger does not resume dragging`() {
        val t = TouchTranslator()
        t.translate(listOf(finger(0, 0.4f, 0.4f), finger(1, 0.6f, 0.4f)),
                    Phase.DOWN, finger(1, 0.6f, 0.4f))
        t.translate(listOf(finger(0, 0.4f, 0.6f), finger(1, 0.6f, 0.6f)),
                    Phase.MOVE, finger(0, 0.4f, 0.6f))
        val messages = t.translate(listOf(finger(0, 0.4f, 0.6f)), Phase.UP,
                                   finger(1, 0.6f, 0.6f))
        assertTrue(messages.none { it is OutgoingMessage.Touch &&
                                   it.phase == Phase.DOWN })
    }

    @Test
    fun `a pen arriving mid-gesture ends the gesture`() {
        val t = TouchTranslator()
        t.translate(listOf(finger(0, 0.4f, 0.4f), finger(1, 0.6f, 0.4f)),
                    Phase.DOWN, finger(1, 0.6f, 0.4f))
        t.translate(listOf(finger(0, 0.4f, 0.6f), finger(1, 0.6f, 0.6f)),
                    Phase.MOVE, finger(0, 0.4f, 0.6f))

        val messages = t.translate(listOf(stylus(0.5f, 0.5f)), Phase.HOVER, stylus(0.5f, 0.5f))
        assertTrue("the scroll must be closed out before the pen takes over",
                   messages.any { it is OutgoingMessage.Scroll && it.phase == Phase.UP })
        assertTrue(messages.any { it is OutgoingMessage.Pen })
    }

    @Test
    fun `reset clears state so a reconnect starts clean`() {
        val t = TouchTranslator()
        t.translate(listOf(finger(0, 0.5f, 0.5f)), Phase.DOWN, finger(0, 0.5f, 0.5f))
        t.reset()
        // No stray UP from the previous session.
        val messages = t.translate(listOf(finger(0, 0.4f, 0.4f), finger(1, 0.6f, 0.4f)),
                                   Phase.DOWN, finger(1, 0.6f, 0.4f))
        assertTrue(messages.none { it is OutgoingMessage.Touch && it.phase == Phase.UP })
    }
}
