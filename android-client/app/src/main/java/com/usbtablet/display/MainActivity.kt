package com.usbtablet.display

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.media.MediaCodec
import android.media.MediaFormat
import android.os.Bundle
import android.util.Log
import android.view.MotionEvent
import android.view.SurfaceHolder
import android.view.View
import android.view.WindowManager
import androidx.appcompat.app.AppCompatActivity
import androidx.lifecycle.lifecycleScope
import com.usbtablet.display.databinding.ActivityMainBinding
import kotlinx.coroutines.*
import java.io.DataInputStream
import java.io.DataOutputStream
import java.io.EOFException
import java.net.ConnectException
import java.net.Socket
import java.net.SocketTimeoutException
import java.util.concurrent.atomic.AtomicBoolean

class MainActivity : AppCompatActivity() {

    companion object {
        private const val TAG = "USBDisplay"
        private const val HOST = "127.0.0.1"  // localhost via ADB port forward
        private const val VIDEO_PORT = 5560
        private const val TOUCH_PORT = 5561

        private const val VIDEO_WIDTH = 2560
        private const val VIDEO_HEIGHT = 1600

        // Longer timeouts for better resilience
        private const val CONNECT_TIMEOUT_MS = 10000
        private const val READ_TIMEOUT_MS = 30000  // 30 seconds - give server time to start capture
        private const val RECONNECT_DELAY_MS = 1000L

        // Touch event types
        private const val TOUCH_DOWN: Byte = 0
        private const val TOUCH_MOVE: Byte = 1
        private const val TOUCH_UP: Byte = 2

        // Pen/stylus event types (with pressure/tilt)
        private const val PEN_DOWN: Byte = 10
        private const val PEN_MOVE: Byte = 11
        private const val PEN_UP: Byte = 12
        private const val PEN_HOVER: Byte = 13  // Hovering without touching
    }

    private lateinit var binding: ActivityMainBinding
    private var decoder: MediaCodec? = null
    private var videoSocket: Socket? = null
    private var touchSocket: Socket? = null
    private var touchOutputStream: DataOutputStream? = null
    private var isRunning = AtomicBoolean(false)
    private var frameCount = 0
    private var lastStatsTime = System.currentTimeMillis()
    private var connectionAttempts = 0
    private var showStats = true  // Toggle for FPS display

    // Broadcast receiver for FPS toggle from macOS host
    private val fpsToggleReceiver = object : BroadcastReceiver() {
        override fun onReceive(context: Context?, intent: Intent?) {
            when (intent?.action) {
                "com.usbtablet.display.SHOW_FPS" -> {
                    showStats = true
                    runOnUiThread {
                        if (isRunning.get()) {
                            binding.statsText.visibility = View.VISIBLE
                        }
                    }
                }
                "com.usbtablet.display.HIDE_FPS" -> {
                    showStats = false
                    runOnUiThread {
                        binding.statsText.visibility = View.GONE
                    }
                }
            }
        }
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)

        // Keep screen on
        window.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)

        // Immersive fullscreen
        hideSystemUI()

        binding = ActivityMainBinding.inflate(layoutInflater)
        setContentView(binding.root)

        // Set up touch listener on the surface view
        binding.surfaceView.setOnTouchListener { view, event ->
            handleTouch(view, event)
            true
        }

        // Set up hover listener for stylus hover events
        binding.surfaceView.setOnHoverListener { view, event ->
            handleTouch(view, event)
            true
        }

        // Tap stats to toggle visibility
        binding.statsText.setOnClickListener {
            showStats = !showStats
            binding.statsText.visibility = if (showStats) View.VISIBLE else View.GONE
        }

        // Register broadcast receiver for FPS toggle
        val filter = IntentFilter().apply {
            addAction("com.usbtablet.display.SHOW_FPS")
            addAction("com.usbtablet.display.HIDE_FPS")
        }
        registerReceiver(fpsToggleReceiver, filter, RECEIVER_EXPORTED)

        binding.surfaceView.holder.addCallback(object : SurfaceHolder.Callback {
            override fun surfaceCreated(holder: SurfaceHolder) {
                Log.d(TAG, "Surface created")
                startStreaming()
            }

            override fun surfaceChanged(holder: SurfaceHolder, format: Int, width: Int, height: Int) {
                Log.d(TAG, "Surface changed: ${width}x${height}")
            }

            override fun surfaceDestroyed(holder: SurfaceHolder) {
                Log.d(TAG, "Surface destroyed")
                stopStreaming()
            }
        })
    }

    private fun handleTouch(view: View, event: MotionEvent) {
        val outputStream = touchOutputStream ?: return

        // Convert view coordinates to normalized (0-1) coordinates
        val normalizedX = event.x / view.width
        val normalizedY = event.y / view.height

        // Check if this is a stylus/pen event
        val isStylus = event.getToolType(0) == MotionEvent.TOOL_TYPE_STYLUS

        val touchType: Byte
        val isPenHover: Boolean

        if (isStylus) {
            // Stylus events - check for hover (buttonState or no pressure indicates hover)
            val isHovering = event.pressure == 0f ||
                (event.action == MotionEvent.ACTION_HOVER_ENTER ||
                 event.action == MotionEvent.ACTION_HOVER_MOVE ||
                 event.action == MotionEvent.ACTION_HOVER_EXIT)

            isPenHover = isHovering
            touchType = when (event.action) {
                MotionEvent.ACTION_DOWN -> PEN_DOWN
                MotionEvent.ACTION_MOVE -> PEN_MOVE
                MotionEvent.ACTION_UP, MotionEvent.ACTION_CANCEL -> PEN_UP
                MotionEvent.ACTION_HOVER_ENTER, MotionEvent.ACTION_HOVER_MOVE -> PEN_HOVER
                MotionEvent.ACTION_HOVER_EXIT -> PEN_UP
                else -> return
            }
        } else {
            // Regular finger touch
            isPenHover = false
            touchType = when (event.action) {
                MotionEvent.ACTION_DOWN -> TOUCH_DOWN
                MotionEvent.ACTION_MOVE -> TOUCH_MOVE
                MotionEvent.ACTION_UP, MotionEvent.ACTION_CANCEL -> TOUCH_UP
                else -> return
            }
        }

        // Get pressure and tilt for stylus
        val pressure = if (isStylus && !isPenHover) event.pressure.coerceIn(0f, 1f) else 0f
        val tiltX = if (isStylus) event.getAxisValue(MotionEvent.AXIS_TILT) else 0f
        val tiltY = if (isStylus) event.getAxisValue(MotionEvent.AXIS_ORIENTATION) else 0f

        // Send touch event asynchronously
        lifecycleScope.launch(Dispatchers.IO) {
            try {
                synchronized(outputStream) {
                    if (isStylus) {
                        // Pen protocol: type (1) + x (4) + y (4) + pressure (4) + tiltX (4) + tiltY (4) = 21 bytes
                        outputStream.writeByte(touchType.toInt())
                        outputStream.writeFloat(normalizedX)
                        outputStream.writeFloat(normalizedY)
                        outputStream.writeFloat(pressure)
                        outputStream.writeFloat(tiltX)
                        outputStream.writeFloat(tiltY)
                    } else {
                        // Touch protocol: type (1 byte) + x (4 bytes float) + y (4 bytes float) = 9 bytes
                        outputStream.writeByte(touchType.toInt())
                        outputStream.writeFloat(normalizedX)
                        outputStream.writeFloat(normalizedY)
                    }
                    outputStream.flush()
                }
            } catch (e: Exception) {
                Log.w(TAG, "Failed to send touch event", e)
            }
        }
    }

    private fun hideSystemUI() {
        @Suppress("DEPRECATION")
        window.decorView.systemUiVisibility = (
            View.SYSTEM_UI_FLAG_IMMERSIVE_STICKY
            or View.SYSTEM_UI_FLAG_LAYOUT_STABLE
            or View.SYSTEM_UI_FLAG_LAYOUT_HIDE_NAVIGATION
            or View.SYSTEM_UI_FLAG_LAYOUT_FULLSCREEN
            or View.SYSTEM_UI_FLAG_HIDE_NAVIGATION
            or View.SYSTEM_UI_FLAG_FULLSCREEN
        )
    }

    private fun startStreaming() {
        isRunning.set(true)
        connectionAttempts = 0

        lifecycleScope.launch(Dispatchers.IO) {
            while (isRunning.get()) {
                connectionAttempts++
                try {
                    updateStatus("Waiting for macOS host...")
                    connectAndStream()
                } catch (e: ConnectException) {
                    Log.w(TAG, "Connection refused (attempt $connectionAttempts)", e)
                    updateStatus("Waiting for macOS host...")
                    delay(RECONNECT_DELAY_MS)
                } catch (e: SocketTimeoutException) {
                    Log.w(TAG, "Socket timeout (attempt $connectionAttempts)", e)
                    updateStatus("Waiting for macOS host...")
                    delay(RECONNECT_DELAY_MS)
                } catch (e: EOFException) {
                    Log.w(TAG, "Server closed connection", e)
                    updateStatus("Reconnecting...")
                    delay(RECONNECT_DELAY_MS)
                } catch (e: Exception) {
                    Log.e(TAG, "Connection error (attempt $connectionAttempts)", e)
                    updateStatus("Waiting for macOS host...")
                    delay(RECONNECT_DELAY_MS)
                } finally {
                    closeConnection()
                }
            }
        }
    }

    private fun stopStreaming() {
        isRunning.set(false)
        closeConnection()
    }

    private fun closeConnection() {
        try {
            touchOutputStream = null
            touchSocket?.close()
        } catch (e: Exception) {
            Log.w(TAG, "Error closing touch socket", e)
        }
        touchSocket = null

        try {
            videoSocket?.close()
        } catch (e: Exception) {
            Log.w(TAG, "Error closing video socket", e)
        }
        videoSocket = null
        releaseDecoder()
    }

    private suspend fun connectAndStream() {
        // Connect to the macOS host via ADB reverse port forward
        Log.d(TAG, "Connecting to video stream at $HOST:$VIDEO_PORT")

        videoSocket = Socket().apply {
            soTimeout = READ_TIMEOUT_MS
            tcpNoDelay = true
            connect(java.net.InetSocketAddress(HOST, VIDEO_PORT), CONNECT_TIMEOUT_MS)
        }

        Log.d(TAG, "Video connected! Connecting touch channel...")
        updateStatus("Connecting...")

        // Connect touch channel
        try {
            touchSocket = Socket().apply {
                tcpNoDelay = true
                connect(java.net.InetSocketAddress(HOST, TOUCH_PORT), CONNECT_TIMEOUT_MS)
            }
            touchOutputStream = DataOutputStream(touchSocket!!.getOutputStream())
            Log.d(TAG, "Touch channel connected!")
        } catch (e: Exception) {
            Log.w(TAG, "Touch channel not available (touch will be disabled)", e)
            // Continue without touch - video still works
        }

        updateStatus("Starting stream...")

        val inputStream = DataInputStream(videoSocket!!.getInputStream())

        // Initialize decoder
        initDecoder()

        // Reset connection attempts on successful connection
        connectionAttempts = 0

        updateStatus("")  // Hide status text
        showStats(true)

        // Read and decode frames
        var framesReceived = 0
        while (isRunning.get() && videoSocket?.isConnected == true) {
            try {
                // Read frame length (4 bytes, big endian)
                val length = inputStream.readInt()

                if (length <= 0 || length > 10_000_000) {
                    Log.w(TAG, "Invalid frame length: $length, skipping")
                    continue
                }

                // Read frame data
                val frameData = ByteArray(length)
                inputStream.readFully(frameData)

                framesReceived++
                if (framesReceived == 1) {
                    Log.d(TAG, "First frame received! Size: $length bytes")
                }

                // Decode frame
                decodeFrame(frameData)

                // Update stats
                frameCount++
                val now = System.currentTimeMillis()
                if (now - lastStatsTime >= 1000) {
                    val fps = frameCount * 1000.0 / (now - lastStatsTime)
                    updateStats("${String.format("%.1f", fps)} fps | ${length / 1024} KB")
                    frameCount = 0
                    lastStatsTime = now
                }

            } catch (e: SocketTimeoutException) {
                // Read timeout - check if we should continue
                Log.d(TAG, "Read timeout, checking connection...")
                if (!isRunning.get()) break
                // Continue waiting if still running
            } catch (e: EOFException) {
                Log.d(TAG, "End of stream")
                throw e
            } catch (e: Exception) {
                if (isRunning.get()) {
                    throw e
                }
            }
        }
    }

    private fun initDecoder() {
        try {
            val format = MediaFormat.createVideoFormat(MediaFormat.MIMETYPE_VIDEO_AVC, VIDEO_WIDTH, VIDEO_HEIGHT)
            format.setInteger(MediaFormat.KEY_MAX_INPUT_SIZE, VIDEO_WIDTH * VIDEO_HEIGHT)

            // Low latency settings
            format.setInteger(MediaFormat.KEY_LOW_LATENCY, 1)

            decoder = MediaCodec.createDecoderByType(MediaFormat.MIMETYPE_VIDEO_AVC)
            decoder?.configure(format, binding.surfaceView.holder.surface, null, 0)
            decoder?.start()

            Log.d(TAG, "Decoder initialized: ${VIDEO_WIDTH}x${VIDEO_HEIGHT}")
        } catch (e: Exception) {
            Log.e(TAG, "Failed to initialize decoder", e)
        }
    }

    private fun releaseDecoder() {
        try {
            decoder?.stop()
            decoder?.release()
        } catch (e: Exception) {
            Log.w(TAG, "Error releasing decoder", e)
        }
        decoder = null
    }

    private fun decodeFrame(data: ByteArray) {
        val decoder = decoder ?: return

        try {
            // Get input buffer with timeout
            val inputIndex = decoder.dequeueInputBuffer(10000)
            if (inputIndex >= 0) {
                val inputBuffer = decoder.getInputBuffer(inputIndex)
                inputBuffer?.clear()
                inputBuffer?.put(data)

                decoder.queueInputBuffer(inputIndex, 0, data.size, 0, 0)
            }

            // Get output buffer
            val bufferInfo = MediaCodec.BufferInfo()
            var outputIndex = decoder.dequeueOutputBuffer(bufferInfo, 0)

            while (outputIndex >= 0) {
                // Release the buffer to render to surface
                decoder.releaseOutputBuffer(outputIndex, true)
                outputIndex = decoder.dequeueOutputBuffer(bufferInfo, 0)
            }

        } catch (e: Exception) {
            Log.e(TAG, "Decode error", e)
        }
    }

    private suspend fun updateStatus(text: String) {
        withContext(Dispatchers.Main) {
            binding.statusText.text = text
            binding.statusContainer.visibility = if (text.isEmpty()) View.GONE else View.VISIBLE
            binding.progressBar.visibility = if (text.isEmpty()) View.GONE else View.VISIBLE
        }
    }

    private suspend fun showStats(show: Boolean) {
        withContext(Dispatchers.Main) {
            // Only show if both streaming AND user hasn't hidden it
            binding.statsText.visibility = if (show && showStats) View.VISIBLE else View.GONE
            // Hide status container when streaming
            if (show) {
                binding.statusContainer.visibility = View.GONE
            }
        }
    }

    private suspend fun updateStats(text: String) {
        withContext(Dispatchers.Main) {
            binding.statsText.text = text
        }
    }

    override fun onResume() {
        super.onResume()
        hideSystemUI()
    }

    override fun onDestroy() {
        super.onDestroy()
        try {
            unregisterReceiver(fpsToggleReceiver)
        } catch (e: Exception) {
            // Receiver may not be registered
        }
        stopStreaming()
    }
}
