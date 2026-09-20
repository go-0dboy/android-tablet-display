package com.usbtablet.display

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.media.MediaCodec
import android.media.MediaFormat
import android.net.nsd.NsdManager
import android.net.nsd.NsdServiceInfo
import android.os.Build
import android.os.Bundle
import android.util.Log
import android.view.MotionEvent
import android.view.SurfaceHolder
import android.view.View
import android.view.WindowManager
import androidx.appcompat.app.AppCompatActivity
import androidx.core.view.WindowCompat
import androidx.core.view.WindowInsetsCompat
import androidx.core.view.WindowInsetsControllerCompat
import androidx.lifecycle.lifecycleScope
import com.usbtablet.display.databinding.ActivityMainBinding
import kotlinx.coroutines.*
import java.io.DataInputStream
import java.io.EOFException
import java.io.OutputStream
import java.net.InetSocketAddress
import java.net.Socket
import java.net.SocketTimeoutException
import java.util.concurrent.atomic.AtomicBoolean

class MainActivity : AppCompatActivity() {

    companion object {
        private const val TAG = "USBDisplay"
        /** Over USB the host is reachable on loopback via `adb reverse`. */
        private const val USB_HOST = "127.0.0.1"
        private const val CONNECT_TIMEOUT_MS = 10_000
        private const val READ_TIMEOUT_MS = 20_000
        private const val RECONNECT_DELAY_MS = 800L
        private const val SERVICE_TYPE = "_usbtablet._tcp."

        const val ACTION_SET_TOUCH_MODE = "com.usbtablet.display.SET_TOUCH_MODE"
        const val ACTION_LOG_PEN = "com.usbtablet.display.LOG_PEN"
        const val ACTION_SHOW_FPS = "com.usbtablet.display.SHOW_FPS"
        const val ACTION_HIDE_FPS = "com.usbtablet.display.HIDE_FPS"
    }

    private lateinit var binding: ActivityMainBinding

    private var decoder: MediaCodec? = null
    private var videoSocket: Socket? = null
    private var inputSocket: Socket? = null
    private var inputOut: OutputStream? = null
    private val running = AtomicBoolean(false)

    private val translator = TouchTranslator()
    private var showStats = true
    private var wirelessMode = false
    private var hostAddress: String? = null
    private var videoPort = WireProtocol.DEFAULT_VIDEO_PORT
    private var inputPort = WireProtocol.DEFAULT_INPUT_PORT

    private var frameCount = 0
    private var byteCount = 0L
    private var lastStatsAt = System.currentTimeMillis()
    private var decoderWidth = 0
    private var decoderHeight = 0

    private val settingsReceiver = object : BroadcastReceiver() {
        override fun onReceive(context: Context?, intent: Intent?) {
            when (intent?.action) {
                ACTION_SHOW_FPS -> setStatsVisible(true)
                ACTION_HIDE_FPS -> setStatsVisible(false)
                ACTION_SET_TOUCH_MODE -> {
                    translator.touchMode = TouchMode.from(intent.getStringExtra("mode"))
                    Log.d(TAG, "Touch mode: ${translator.touchMode}")
                }
                ACTION_LOG_PEN -> {
                    PenDiagnostics.enabled = intent.getBooleanExtra("enabled", true)
                    PenDiagnostics.reset()
                    Log.i(TAG, "Pen diagnostics: ${PenDiagnostics.enabled}")
                    if (PenDiagnostics.enabled) PenDiagnostics.logDeviceCapabilities()
                }
            }
        }
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        window.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)

        binding = ActivityMainBinding.inflate(layoutInflater)
        setContentView(binding.root)
        goFullscreen()

        wirelessMode = intent.getBooleanExtra("wireless", false)

        binding.surfaceView.setOnTouchListener { view, event ->
            handleMotion(view, event); true
        }
        binding.surfaceView.setOnHoverListener { view, event ->
            handleMotion(view, event); true
        }
        binding.statsText.setOnClickListener { setStatsVisible(!showStats) }

        val filter = IntentFilter().apply {
            addAction(ACTION_SHOW_FPS)
            addAction(ACTION_HIDE_FPS)
            addAction(ACTION_SET_TOUCH_MODE)
            addAction(ACTION_LOG_PEN)
        }
        // The host sends these through `adb shell am broadcast`, which runs as
        // a different uid, so the receiver has to be exported. It is targeted
        // at this package (-p) on the sending side and carries no data worth
        // spoofing.
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            registerReceiver(settingsReceiver, filter, RECEIVER_EXPORTED)
        } else {
            @Suppress("UnspecifiedRegisterReceiverFlag")
            registerReceiver(settingsReceiver, filter)
        }

        binding.surfaceView.holder.addCallback(object : SurfaceHolder.Callback {
            override fun surfaceCreated(holder: SurfaceHolder) = start()
            override fun surfaceChanged(h: SurfaceHolder, f: Int, w: Int, ht: Int) {}
            override fun surfaceDestroyed(holder: SurfaceHolder) = stop()
        })

        if (DeviceInfo.isDeXActive(this)) {
            Log.w(TAG, "Samsung DeX is active; the stream may be interrupted")
        }
    }

    private fun goFullscreen() {
        WindowCompat.setDecorFitsSystemWindows(window, false)
        WindowInsetsControllerCompat(window, binding.root).apply {
            hide(WindowInsetsCompat.Type.systemBars())
            systemBarsBehavior =
                WindowInsetsControllerCompat.BEHAVIOR_SHOW_TRANSIENT_BARS_BY_SWIPE
        }
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
            window.attributes.layoutInDisplayCutoutMode =
                WindowManager.LayoutParams.LAYOUT_IN_DISPLAY_CUTOUT_MODE_ALWAYS
        } else if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
            window.attributes.layoutInDisplayCutoutMode =
                WindowManager.LayoutParams.LAYOUT_IN_DISPLAY_CUTOUT_MODE_SHORT_EDGES
        }
    }

    // MARK: - Input

    /**
     * Convert a MotionEvent into normalised samples and hand them to the
     * translator.
     *
     * The v1 bug lived here: it switched on `event.action`, but
     * ACTION_POINTER_DOWN/UP pack the pointer index into the high bits, so
     * those branches never matched and multi-touch never worked.
     */
    private fun handleMotion(view: View, event: MotionEvent) {
        PenDiagnostics.log(event)
        val out = inputOut ?: return
        if (view.width <= 0 || view.height <= 0) return

        val shortEdge = minOf(view.width, view.height).toFloat()

        fun sample(index: Int): PointerSample {
            val tool = when (event.getToolType(index)) {
                MotionEvent.TOOL_TYPE_STYLUS -> ToolType.STYLUS
                MotionEvent.TOOL_TYPE_ERASER -> ToolType.ERASER
                MotionEvent.TOOL_TYPE_FINGER -> ToolType.FINGER
                else -> ToolType.OTHER
            }
            return PointerSample(
                pointerId = event.getPointerId(index),
                tool = tool,
                x = (event.getX(index) / view.width).coerceIn(0f, 1f),
                y = (event.getY(index) / view.height).coerceIn(0f, 1f),
                pressure = event.getPressure(index),
                tiltRadians = event.getAxisValue(MotionEvent.AXIS_TILT, index),
                orientationRadians = event.getOrientation(index),
                sizeFraction = event.getTouchMajor(index) / shortEdge
            )
        }

        val actionIndex = event.actionIndex
        val phase = when (event.actionMasked) {
            MotionEvent.ACTION_DOWN, MotionEvent.ACTION_POINTER_DOWN -> Phase.DOWN
            MotionEvent.ACTION_MOVE -> Phase.MOVE
            MotionEvent.ACTION_UP, MotionEvent.ACTION_POINTER_UP -> Phase.UP
            MotionEvent.ACTION_CANCEL -> Phase.CANCEL
            MotionEvent.ACTION_HOVER_ENTER, MotionEvent.ACTION_HOVER_MOVE -> Phase.HOVER
            MotionEvent.ACTION_HOVER_EXIT -> Phase.HOVER_END
            else -> return
        }

        // On a pointer-up the lifted contact is still in the event, so drop it
        // from the "currently down" set or a two-finger gesture never ends.
        val liftingIndex = if (event.actionMasked == MotionEvent.ACTION_POINTER_UP)
            actionIndex else -1
        val pointers = (0 until event.pointerCount)
            .filter { it != liftingIndex }
            .map { sample(it) }

        val changed = sample(actionIndex.coerceIn(0, event.pointerCount - 1))

        // The S Pen's barrel button arrives as a secondary button press.
        val barrel = event.buttonState and
            (MotionEvent.BUTTON_STYLUS_PRIMARY or MotionEvent.BUTTON_SECONDARY) != 0

        val messages = translator.translate(pointers, phase, changed)
        if (messages.isEmpty()) return

        lifecycleScope.launch(Dispatchers.IO) {
            try {
                synchronized(out) {
                    for (message in messages) {
                        val toSend = if (message is OutgoingMessage.Pen && barrel) {
                            message.copy(buttons = message.buttons or 0x01)
                        } else message
                        out.write(InputCodec.encode(toSend))
                    }
                    out.flush()
                }
            } catch (e: Exception) {
                Log.w(TAG, "Could not send input", e)
            }
        }
    }

    // MARK: - Connection

    private fun start() {
        running.set(true)
        lifecycleScope.launch(Dispatchers.IO) {
            while (running.get()) {
                try {
                    if (wirelessMode && hostAddress == null) {
                        updateStatus("Looking for a Mac on this network…")
                        discoverHost()
                        if (hostAddress == null) { delay(2000); continue }
                    }
                    connectAndStream()
                } catch (e: CancellationException) {
                    throw e
                } catch (e: Exception) {
                    Log.w(TAG, "Connection ended: ${e.message}")
                    updateStatus(waitingMessage())
                    delay(RECONNECT_DELAY_MS)
                } finally {
                    closeConnection()
                }
            }
        }
    }

    private fun waitingMessage(): String =
        if (wirelessMode) "Looking for a Mac on this network…"
        else "Waiting for the Mac…\nStart the app on your Mac and plug in the cable."

    private fun stop() {
        running.set(false)
        translator.reset()
        closeConnection()
    }

    private suspend fun discoverHost() = withContext(Dispatchers.IO) {
        val nsd = getSystemService(Context.NSD_SERVICE) as NsdManager
        val found = CompletableDeferred<NsdServiceInfo?>()

        val listener = object : NsdManager.DiscoveryListener {
            override fun onDiscoveryStarted(type: String) {}
            override fun onServiceFound(service: NsdServiceInfo) {
                @Suppress("DEPRECATION")
                nsd.resolveService(service, object : NsdManager.ResolveListener {
                    override fun onResolveFailed(info: NsdServiceInfo, code: Int) {}
                    override fun onServiceResolved(info: NsdServiceInfo) {
                        if (!found.isCompleted) found.complete(info)
                    }
                })
            }
            override fun onServiceLost(service: NsdServiceInfo) {}
            override fun onDiscoveryStopped(type: String) {}
            override fun onStartDiscoveryFailed(type: String, code: Int) {
                if (!found.isCompleted) found.complete(null)
            }
            override fun onStopDiscoveryFailed(type: String, code: Int) {}
        }

        try {
            nsd.discoverServices(SERVICE_TYPE, NsdManager.PROTOCOL_DNS_SD, listener)
            val info = withTimeoutOrNull(8000) { found.await() }
            if (info != null) {
                @Suppress("DEPRECATION")
                hostAddress = info.host?.hostAddress
                @Suppress("DEPRECATION")
                videoPort = info.port
                inputPort = info.attributes["input"]
                    ?.toString(Charsets.UTF_8)?.toIntOrNull() ?: (videoPort + 1)
                Log.d(TAG, "Found host at $hostAddress:$videoPort")
            }
        } catch (e: Exception) {
            Log.w(TAG, "Discovery failed", e)
        } finally {
            try { nsd.stopServiceDiscovery(listener) } catch (_: Exception) {}
        }
    }

    private suspend fun connectAndStream() {
        val host = if (wirelessMode) (hostAddress ?: return) else USB_HOST
        updateStatus(waitingMessage())

        val video = Socket().apply {
            tcpNoDelay = true
            soTimeout = READ_TIMEOUT_MS
            connect(InetSocketAddress(host, videoPort), CONNECT_TIMEOUT_MS)
        }
        videoSocket = video

        val input = Socket().apply {
            tcpNoDelay = true
            soTimeout = READ_TIMEOUT_MS
            connect(InetSocketAddress(host, inputPort), CONNECT_TIMEOUT_MS)
        }
        inputSocket = input
        val out = input.getOutputStream()
        val parser = InputStreamParser()
        val inStream = input.getInputStream()

        updateStatus("Connecting…")

        if (wirelessMode && !authenticate(out, inStream, parser)) {
            updateStatus("Not paired.\nConfirm the code on your Mac.")
            delay(3000)
            throw Exception("not paired")
        }

        // Tell the host what panel it is drawing onto, so it can build a
        // display that matches instead of guessing.
        val metrics = DeviceInfo.metrics(this@MainActivity)
        val hello = OutgoingMessage.Hello(
            widthPixels = metrics.widthPixels,
            heightPixels = metrics.heightPixels,
            densityDpi = metrics.densityDpi,
            rotationDegrees = metrics.rotationDegrees,
            flags = DeviceInfo.flags(this@MainActivity,
                                     translator.touchMode == TouchMode.PEN_ONLY),
            deviceName = DeviceInfo.displayName()
        )
        synchronized(out) { out.write(InputCodec.encode(hello)); out.flush() }
        inputOut = out
        Log.d(TAG, "Sent hello: ${metrics.widthPixels}x${metrics.heightPixels} " +
                   "@${metrics.densityDpi}dpi")

        // Wait briefly for the ack: it carries the size the host actually
        // created, which after alignment is not always the size we asked for.
        // Configuring the decoder with the wrong dimensions costs a
        // reconfigure on the first keyframe.
        val ack = readAck(inStream, parser)
        val decodeWidth = ack?.takeIf { it.accepted }?.displayWidth ?: metrics.widthPixels
        val decodeHeight = ack?.takeIf { it.accepted }?.displayHeight ?: metrics.heightPixels

        updateStatus("Starting…")
        streamVideo(video, decodeWidth, decodeHeight)
    }

    /** Pair (or prove we are already paired) before any pixels are sent. */
    private suspend fun authenticate(
        out: OutputStream, inStream: java.io.InputStream, parser: InputStreamParser
    ): Boolean {
        val clientKey = ClientPairing.identity(this)
        val clientNonce = ClientPairing.nonce()

        synchronized(out) {
            out.write(InputCodec.encode(OutgoingMessage.PairRequest(
                clientKey, clientNonce, DeviceInfo.displayName())))
            out.flush()
        }

        val response = readMessage(inStream, parser, 10_000)
            as? IncomingMessage.PairResponse ?: return false

        if (response.status == PairStatus.REJECTED) {
            updateStatus("This Mac is not accepting wireless devices.")
            return false
        }

        if (response.status == PairStatus.NEEDS_CONFIRMATION) {
            val code = ClientPairing.shortCode(
                clientNonce, response.hostNonce, clientKey, response.hostKey)
            updateStatus("Pairing code\n\n$code\n\nConfirm this on “${response.hostName}”.")
        }

        val proof = ClientPairing.sessionProof(clientKey, clientNonce, response.hostNonce)
        synchronized(out) {
            out.write(InputCodec.encode(OutgoingMessage.PairProof(proof)))
            out.flush()
        }

        // The person may take a moment to press the button on the Mac.
        val result = readMessage(inStream, parser, 60_000) as? IncomingMessage.PairResult
        return result?.accepted == true
    }

    private fun readMessage(
        inStream: java.io.InputStream, parser: InputStreamParser, timeoutMs: Int
    ): IncomingMessage? {
        val deadline = System.currentTimeMillis() + timeoutMs
        val buffer = ByteArray(2048)
        while (System.currentTimeMillis() < deadline) {
            parser.next()?.let { return it }
            val read = try { inStream.read(buffer) } catch (_: SocketTimeoutException) { 0 }
            if (read < 0) return null
            if (read > 0) parser.append(buffer, read)
        }
        return null
    }

    private fun readAck(
        inStream: java.io.InputStream, parser: InputStreamParser
    ): IncomingMessage.HelloAck? {
        val message = readMessage(inStream, parser, 8_000)
        if (message is IncomingMessage.HelloAck) {
            if (!message.accepted) {
                Log.w(TAG, "Host refused the display: ${message.message}")
            } else {
                Log.d(TAG, "Host created ${message.displayWidth}x${message.displayHeight}")
            }
            return message
        }
        return null
    }

    private suspend fun streamVideo(video: Socket, width: Int, height: Int) {
        val stream = DataInputStream(video.getInputStream().buffered(1 shl 16))
        initDecoder(width, height)

        updateStatus("")
        setStatsVisible(showStats)

        while (running.get() && !video.isClosed) {
            val length = try {
                stream.readInt()
            } catch (e: SocketTimeoutException) {
                if (!running.get()) break else continue
            } catch (e: EOFException) {
                throw e
            }

            if (!VideoFraming.isPlausibleFrameLength(length)) {
                // The stream is unrecoverable at this point: reconnect rather
                // than limp along on garbage.
                throw Exception("implausible frame length $length")
            }

            val frame = ByteArray(length)
            stream.readFully(frame)
            decodeFrame(frame)

            frameCount++
            byteCount += length
            val now = System.currentTimeMillis()
            val elapsed = now - lastStatsAt
            if (elapsed >= 1000) {
                val fps = frameCount * 1000.0 / elapsed
                val mbps = byteCount * 8.0 / elapsed / 1000.0
                updateStats("%.1f fps · %.1f Mbps".format(fps, mbps))
                frameCount = 0
                byteCount = 0
                lastStatsAt = now
            }
        }
    }

    // MARK: - Decoder

    private fun initDecoder(width: Int, height: Int) {
        if (decoder != null && decoderWidth == width && decoderHeight == height) return
        releaseDecoder()
        try {
            val format = MediaFormat.createVideoFormat(
                MediaFormat.MIMETYPE_VIDEO_AVC, width, height).apply {
                setInteger(MediaFormat.KEY_MAX_INPUT_SIZE, width * height)

                // Android 11 introduced the standard low-latency decoder hint.
                // Older MediaCodec implementations may reject unknown format
                // keys, so do not send these hints to legacy devices.
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
                    setInteger(MediaFormat.KEY_LOW_LATENCY, 1)

                    // Some Qualcomm/Samsung decoders honour this vendor hint
                    // even when the standard key is ignored.
                    setInteger("vendor.qti-ext-dec-low-latency.enable", 1)
                }
            }
            decoder = MediaCodec.createDecoderByType(MediaFormat.MIMETYPE_VIDEO_AVC).apply {
                configure(format, binding.surfaceView.holder.surface, null, 0)
                start()
            }
            decoderWidth = width
            decoderHeight = height
            Log.d(TAG, "Decoder ready at ${width}x$height")
        } catch (e: Exception) {
            Log.e(TAG, "Could not start the decoder", e)
        }
    }

    private fun releaseDecoder() {
        try { decoder?.stop(); decoder?.release() } catch (_: Exception) {}
        decoder = null
        decoderWidth = 0
        decoderHeight = 0
    }

    private fun decodeFrame(data: ByteArray) {
        val codec = decoder ?: return

        try {
            val info = MediaCodec.BufferInfo()

            fun drainOutput() {
                var outputIndex = codec.dequeueOutputBuffer(info, 0)
                while (outputIndex >= 0) {
                    codec.releaseOutputBuffer(outputIndex, true)
                    outputIndex = codec.dequeueOutputBuffer(info, 0)
                }
            }

            // Do not silently discard a compressed H.264 access unit.
            // A later P-frame may depend on it and the picture will remain
            // corrupted until the next IDR frame.
            drainOutput()

            var inputIndex = codec.dequeueInputBuffer(10_000)

            while (inputIndex < 0 && running.get()) {
                // Free decoded output before waiting for another input slot.
                drainOutput()
                inputIndex = codec.dequeueInputBuffer(10_000)
            }

            if (inputIndex < 0) {
                return
            }

            val inputBuffer = codec.getInputBuffer(inputIndex)
                ?: throw IllegalStateException("MediaCodec returned no input buffer")

            if (data.size > inputBuffer.capacity()) {
                throw IllegalStateException(
                    "Encoded frame ${data.size} exceeds decoder input buffer ${inputBuffer.capacity()}"
                )
            }

            inputBuffer.clear()
            inputBuffer.put(data)

            codec.queueInputBuffer(
                inputIndex,
                0,
                data.size,
                0,
                0
            )

            drainOutput()

        } catch (e: IllegalStateException) {
            Log.e(TAG, "Decoder fell over; restarting it", e)
            releaseDecoder()
        }
    }

    private fun closeConnection() {
        inputOut = null
        translator.reset()
        try { inputSocket?.close() } catch (_: Exception) {}
        try { videoSocket?.close() } catch (_: Exception) {}
        inputSocket = null
        videoSocket = null
        releaseDecoder()
    }

    // MARK: - UI

    private fun updateStatus(text: String) {
        runOnUiThread {
            binding.statusText.text = text
            val visible = text.isNotEmpty()
            binding.statusContainer.visibility = if (visible) View.VISIBLE else View.GONE
            binding.progressBar.visibility = if (visible) View.VISIBLE else View.GONE
        }
    }

    private fun updateStats(text: String) {
        runOnUiThread { binding.statsText.text = text }
    }

    private fun setStatsVisible(visible: Boolean) {
        showStats = visible
        runOnUiThread {
            binding.statsText.visibility = if (visible) View.VISIBLE else View.GONE
        }
    }

    override fun onResume() {
        super.onResume()
        goFullscreen()
    }

    override fun onDestroy() {
        super.onDestroy()
        try { unregisterReceiver(settingsReceiver) } catch (_: Exception) {}
        stop()
    }
}
