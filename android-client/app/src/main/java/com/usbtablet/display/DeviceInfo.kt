package com.usbtablet.display

import android.content.Context
import android.os.Build
import android.provider.Settings
import android.util.DisplayMetrics
import android.view.InputDevice
import android.view.MotionEvent
import android.view.Surface

/**
 * What this device is, and what it can do -- the facts the host needs to build
 * a display that matches the panel rather than a hardcoded guess.
 */
object DeviceInfo {

    /** Model name for the Mac's Displays pane. Never a serial or an id. */
    fun displayName(): String {
        val manufacturer = Build.MANUFACTURER.replaceFirstChar { it.uppercase() }
        val model = Build.MODEL
        return if (model.startsWith(manufacturer, ignoreCase = true)) model
               else "$manufacturer $model"
    }

    data class Metrics(
        val widthPixels: Int,
        val heightPixels: Int,
        val densityDpi: Int,
        val rotationDegrees: Int
    )

    /**
     * The real size of the surface we are about to draw into, including the
     * area under the cutout and system bars, because the client runs edge to
     * edge and streams into all of it.
     */
    @Suppress("DEPRECATION")
    fun metrics(context: Context): Metrics {
        val windowManager = context.getSystemService(Context.WINDOW_SERVICE)
            as android.view.WindowManager

        var width: Int
        var height: Int
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
            val bounds = windowManager.currentWindowMetrics.bounds
            width = bounds.width()
            height = bounds.height()
        } else {
            val metrics = DisplayMetrics()
            windowManager.defaultDisplay.getRealMetrics(metrics)
            width = metrics.widthPixels
            height = metrics.heightPixels
        }

        val density = context.resources.displayMetrics.densityDpi
        val rotation = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
            context.display?.rotation ?: Surface.ROTATION_0
        } else {
            windowManager.defaultDisplay.rotation
        }

        // Report the surface as it will actually be laid out. The activity is
        // locked to landscape, so a portrait-shaped reading here means the
        // metrics are pre-rotation and need swapping.
        if (height > width) {
            val swap = width; width = height; height = swap
        }

        return Metrics(width, height, density, rotation * 90)
    }

    /** Does this device have a stylus digitiser -- an S Pen, or any other? */
    fun hasStylus(): Boolean {
        for (id in InputDevice.getDeviceIds()) {
            val device = InputDevice.getDevice(id) ?: continue
            if (device.supportsSource(InputDevice.SOURCE_STYLUS) ||
                device.supportsSource(InputDevice.SOURCE_BLUETOOTH_STYLUS)) {
                return true
            }
        }
        return false
    }

    /** Does the digitiser report pressure with real resolution, not just 0/1? */
    fun hasPressure(): Boolean = axisIsUseful(MotionEvent.AXIS_PRESSURE)

    fun hasTilt(): Boolean = axisIsUseful(MotionEvent.AXIS_TILT)

    private fun axisIsUseful(axis: Int): Boolean {
        for (id in InputDevice.getDeviceIds()) {
            val device = InputDevice.getDevice(id) ?: continue
            if (!device.supportsSource(InputDevice.SOURCE_STYLUS)) continue
            val range = device.getMotionRange(axis, InputDevice.SOURCE_STYLUS) ?: continue
            if (range.max > range.min) return true
        }
        return false
    }

    /**
     * Is Samsung DeX running?
     *
     * DeX takes over the display pipeline, which can move or pause this
     * activity mid-stream. Detecting it means the log can say why the picture
     * stopped instead of leaving the person to guess. There is no public API,
     * so this reads the One UI system setting and falls back to the
     * configuration flag Samsung sets on DeX displays.
     */
    fun isDeXActive(context: Context): Boolean {
        try {
            val value = Settings.Global.getInt(context.contentResolver, "semdesktopmode", 0)
            if (value == 1 || value == 4) return true
        } catch (_: Exception) {
            // Not a Samsung device, or the setting is not readable.
        }
        return try {
            val config = context.resources.configuration
            val field = config.javaClass.getDeclaredField("semDesktopModeEnabled")
            field.getInt(config) == 1
        } catch (_: Exception) {
            false
        }
    }

    /** Assemble the capability flags for the hello message. */
    fun flags(context: Context, penOnly: Boolean): Int {
        var flags = 0
        if (hasStylus()) flags = flags or ClientFlags.HAS_STYLUS
        if (hasPressure()) flags = flags or ClientFlags.HAS_PRESSURE
        if (hasTilt()) flags = flags or ClientFlags.HAS_TILT
        if (isDeXActive(context)) flags = flags or ClientFlags.DEX_ACTIVE
        if (penOnly) flags = flags or ClientFlags.PEN_ONLY

        // Android 7.1 and older commonly use first-generation hardware
        // MediaCodec implementations. Ask the host for the conservative
        // H.264 compatibility stream instead of the modern default.
        if (Build.VERSION.SDK_INT <= Build.VERSION_CODES.N_MR1) {
            flags = flags or ClientFlags.LEGACY_VIDEO_DECODER
        }

        return flags
    }
}
