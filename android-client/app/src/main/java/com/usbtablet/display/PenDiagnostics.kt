package com.usbtablet.display

import android.util.Log
import android.view.InputDevice
import android.view.MotionEvent

/**
 * Logs what the digitiser actually reports, so the pen path can be verified
 * against real hardware instead of assumed.
 *
 * Every stylus is documented as reporting TOOL_TYPE_STYLUS with pressure and
 * tilt, and every stylus is slightly different in practice — which axes are
 * populated, what ranges they use, whether the side buttons arrive as
 * BUTTON_STYLUS_PRIMARY or BUTTON_SECONDARY, whether hover events come through
 * at all. Guessing produces a driver that half works. This prints the facts.
 *
 * Off by default. Turn it on without rebuilding:
 *
 *     adb shell am broadcast -a com.usbtablet.display.LOG_PEN \
 *         -p com.usbtablet.display --ez enabled true
 *     adb logcat -s USBDisplayPen
 */
object PenDiagnostics {

    private const val TAG = "USBDisplayPen"

    @Volatile
    var enabled = false

    private var loggedDeviceSummary = false
    private var eventsLogged = 0
    /** Movement is continuous; logging every sample floods logcat uselessly. */
    private const val MOVE_SAMPLE_EVERY = 15
    private var moveCounter = 0

    fun reset() {
        loggedDeviceSummary = false
        eventsLogged = 0
        moveCounter = 0
    }

    /** One-off dump of every input device that claims to be a stylus. */
    fun logDeviceCapabilities() {
        if (!enabled || loggedDeviceSummary) return
        loggedDeviceSummary = true

        Log.i(TAG, "--- input devices reporting a stylus source ---")
        var found = 0
        for (id in InputDevice.getDeviceIds()) {
            val device = InputDevice.getDevice(id) ?: continue
            val isStylus = device.supportsSource(InputDevice.SOURCE_STYLUS) ||
                device.supportsSource(InputDevice.SOURCE_BLUETOOTH_STYLUS)
            if (!isStylus) continue
            found++

            Log.i(TAG, "device '${device.name}' (id=$id)")
            Log.i(TAG, "   sources=0x${Integer.toHexString(device.sources)}")

            for ((label, axis) in listOf(
                "PRESSURE" to MotionEvent.AXIS_PRESSURE,
                "TILT" to MotionEvent.AXIS_TILT,
                "ORIENTATION" to MotionEvent.AXIS_ORIENTATION,
                "DISTANCE" to MotionEvent.AXIS_DISTANCE,
                "TOUCH_MAJOR" to MotionEvent.AXIS_TOUCH_MAJOR
            )) {
                val range = device.getMotionRange(axis, InputDevice.SOURCE_STYLUS)
                if (range == null) {
                    Log.i(TAG, "   $label: NOT REPORTED")
                } else {
                    Log.i(TAG, "   $label: min=${range.min} max=${range.max} " +
                               "resolution=${range.resolution} fuzz=${range.fuzz}")
                }
            }
        }
        if (found == 0) {
            Log.w(TAG, "No device reports a stylus source. " +
                       "Pressure and tilt cannot work on this hardware.")
        }
        Log.i(TAG, "--- end of device list ---")
    }

    /** Log one MotionEvent, naming the constants rather than printing ints. */
    fun log(event: MotionEvent) {
        if (!enabled) return
        logDeviceCapabilities()

        val action = event.actionMasked
        if (action == MotionEvent.ACTION_MOVE || action == MotionEvent.ACTION_HOVER_MOVE) {
            moveCounter++
            if (moveCounter % MOVE_SAMPLE_EVERY != 0) return
        }

        val index = event.actionIndex
        val tool = when (event.getToolType(index)) {
            MotionEvent.TOOL_TYPE_STYLUS -> "STYLUS"
            MotionEvent.TOOL_TYPE_ERASER -> "ERASER"
            MotionEvent.TOOL_TYPE_FINGER -> "FINGER"
            MotionEvent.TOOL_TYPE_MOUSE -> "MOUSE"
            else -> "UNKNOWN(${event.getToolType(index)})"
        }

        // Only the pen is interesting here; fingers would drown it out.
        if (tool == "FINGER") return

        Log.i(TAG, buildString {
            append(actionName(action))
            append(" tool=").append(tool)
            append(" pointers=").append(event.pointerCount)
            append(" pressure=").append("%.4f".format(event.getPressure(index)))
            append(" tilt=").append("%.4f".format(event.getAxisValue(MotionEvent.AXIS_TILT, index)))
            append(" orientation=").append("%.4f".format(event.getOrientation(index)))
            append(" distance=").append("%.3f".format(
                event.getAxisValue(MotionEvent.AXIS_DISTANCE, index)))
            append(" buttons=").append(buttonNames(event.buttonState))
            append(" touchMajor=").append("%.1f".format(event.getTouchMajor(index)))
        })
        eventsLogged++
    }

    private fun actionName(action: Int): String = when (action) {
        MotionEvent.ACTION_DOWN -> "DOWN"
        MotionEvent.ACTION_UP -> "UP"
        MotionEvent.ACTION_MOVE -> "MOVE"
        MotionEvent.ACTION_CANCEL -> "CANCEL"
        MotionEvent.ACTION_POINTER_DOWN -> "POINTER_DOWN"
        MotionEvent.ACTION_POINTER_UP -> "POINTER_UP"
        MotionEvent.ACTION_HOVER_ENTER -> "HOVER_ENTER"
        MotionEvent.ACTION_HOVER_MOVE -> "HOVER_MOVE"
        MotionEvent.ACTION_HOVER_EXIT -> "HOVER_EXIT"
        else -> "ACTION_$action"
    }

    private fun buttonNames(state: Int): String {
        if (state == 0) return "none"
        val names = mutableListOf<String>()
        if (state and MotionEvent.BUTTON_PRIMARY != 0) names += "PRIMARY"
        if (state and MotionEvent.BUTTON_SECONDARY != 0) names += "SECONDARY"
        if (state and MotionEvent.BUTTON_TERTIARY != 0) names += "TERTIARY"
        if (state and MotionEvent.BUTTON_STYLUS_PRIMARY != 0) names += "STYLUS_PRIMARY"
        if (state and MotionEvent.BUTTON_STYLUS_SECONDARY != 0) names += "STYLUS_SECONDARY"
        if (names.isEmpty()) names += "0x${Integer.toHexString(state)}"
        return names.joinToString("|")
    }
}
