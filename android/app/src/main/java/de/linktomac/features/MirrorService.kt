package de.linktomac.features

import android.app.Activity
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.hardware.display.DisplayManager
import android.hardware.display.VirtualDisplay
import android.media.MediaCodec
import android.media.MediaCodecInfo
import android.media.MediaFormat
import android.media.projection.MediaProjection
import android.media.projection.MediaProjectionManager
import android.os.Build
import android.os.Bundle
import android.os.Handler
import android.os.IBinder
import android.os.Looper
import android.util.Base64
import android.util.Log
import android.view.Surface
import androidx.core.app.NotificationCompat
import androidx.core.app.ServiceCompat
import de.linktomac.LinkHub
import de.linktomac.Notifications
import de.linktomac.R
import de.linktomac.net.MirrorConfig
import de.linktomac.net.MirrorStart
import de.linktomac.net.MirrorStopped
import de.linktomac.net.MsgType
import java.io.DataOutputStream

/**
 * Screen mirroring (F9): MediaProjection -> VirtualDisplay -> MediaCodec H.264.
 * Frames are written to the video socket (port 47802) once the Mac has connected.
 */
class MirrorService : Service() {
    private var projection: MediaProjection? = null
    private var display: VirtualDisplay? = null
    private var encoder: Encoder? = null
    private var params = MirrorStart()
    private val handler = Handler(Looper.getMainLooper())
    private var stoppedReason: String? = null

    private val rotationCheck = object : Runnable {
        override fun run() {
            val e = encoder ?: return
            val (w, h) = targetSize()
            if (w != e.width || h != e.height) restartEncoder()
            handler.postDelayed(this, 500)
        }
    }

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        if (intent?.action == ACTION_STOP) {
            stopSelf()
            return START_NOT_STICKY
        }
        val resultCode = intent?.getIntExtra(EXTRA_RESULT_CODE, Activity.RESULT_CANCELED) ?: Activity.RESULT_CANCELED
        @Suppress("DEPRECATION")
        val data: Intent? = if (Build.VERSION.SDK_INT >= 33) intent?.getParcelableExtra(EXTRA_DATA, Intent::class.java) else intent?.getParcelableExtra(EXTRA_DATA)
        params = MirrorStart(
            maxSize = intent?.getIntExtra(EXTRA_MAX_SIZE, 1280) ?: 1280,
            bitrate = intent?.getIntExtra(EXTRA_BITRATE, 6_000_000) ?: 6_000_000,
            fps = intent?.getIntExtra(EXTRA_FPS, 30) ?: 30,
        )

        val stopPi = android.app.PendingIntent.getService(
            this, 4, Intent(this, MirrorService::class.java).setAction(ACTION_STOP), android.app.PendingIntent.FLAG_IMMUTABLE,
        )
        val notification = NotificationCompat.Builder(this, Notifications.CH_SERVICE)
            .setSmallIcon(R.drawable.ic_stat_link)
            .setContentTitle(getString(R.string.mirror_running))
            .setOngoing(true)
            .addAction(0, getString(R.string.mirror_stop), stopPi)
            .build()
        val type = if (Build.VERSION.SDK_INT >= 29) ServiceInfo.FOREGROUND_SERVICE_TYPE_MEDIA_PROJECTION else 0
        ServiceCompat.startForeground(this, Notifications.ID_MIRROR, notification, type)

        if (resultCode != Activity.RESULT_OK || data == null || projection != null) {
            if (projection == null) {
                stoppedReason = "denied"
                stopSelf()
            }
            return START_NOT_STICKY
        }
        try {
            val mpm = getSystemService(MediaProjectionManager::class.java)
            val p = mpm.getMediaProjection(resultCode, data)
            projection = p
            p.registerCallback(object : MediaProjection.Callback() {
                override fun onStop() {
                    stoppedReason = "stopped_on_phone"
                    stopSelf()
                }
            }, handler)
            startEncoder()
            handler.postDelayed(rotationCheck, 500)
            running = this
        } catch (e: Exception) {
            Log.e(TAG, "mirror start failed", e)
            stoppedReason = e.message ?: "error"
            stopSelf()
        }
        return START_NOT_STICKY
    }

    private fun targetSize(): Pair<Int, Int> {
        val real = DisplayInfo.realSize(this)
        val longSide = maxOf(real.x, real.y)
        val scale = if (longSide > params.maxSize) params.maxSize.toDouble() / longSide else 1.0
        fun align(v: Double) = (v.toInt() / 16 * 16).coerceAtLeast(16)
        return align(real.x * scale) to align(real.y * scale)
    }

    private fun startEncoder() {
        val (w, h) = targetSize()
        val enc = Encoder(w, h, params.bitrate, params.fps)
        encoder = enc
        val dpi = DisplayInfo.densityDpi(this)
        val existing = display
        if (existing == null) {
            display = projection!!.createVirtualDisplay(
                "LinkToMac", w, h, dpi, DisplayManager.VIRTUAL_DISPLAY_FLAG_AUTO_MIRROR, enc.surface, null, null,
            )
        } else {
            existing.resize(w, h, dpi)
            existing.surface = enc.surface
        }
        enc.startDrain()
    }

    private fun restartEncoder() {
        val old = encoder
        encoder = null
        display?.surface = null
        old?.release()
        startEncoder()
    }

    override fun onDestroy() {
        handler.removeCallbacksAndMessages(null)
        if (running === this) running = null
        encoder?.release()
        encoder = null
        display?.release()
        display = null
        projection?.stop()
        projection = null
        closeSink()
        LinkHub.send(MsgType.MIRROR_STOPPED, MirrorStopped(stoppedReason))
        super.onDestroy()
    }

    /** Wraps one MediaCodec instance and its output thread. */
    private inner class Encoder(val width: Int, val height: Int, bitrate: Int, fps: Int) {
        private val codec: MediaCodec = MediaCodec.createEncoderByType(MediaFormat.MIMETYPE_VIDEO_AVC)
        val surface: Surface
        @Volatile private var alive = true
        private var thread: Thread? = null

        init {
            val format = MediaFormat.createVideoFormat(MediaFormat.MIMETYPE_VIDEO_AVC, width, height).apply {
                setInteger(MediaFormat.KEY_COLOR_FORMAT, MediaCodecInfo.CodecCapabilities.COLOR_FormatSurface)
                setInteger(MediaFormat.KEY_BIT_RATE, bitrate)
                setInteger(MediaFormat.KEY_FRAME_RATE, fps)
                setInteger(MediaFormat.KEY_I_FRAME_INTERVAL, 2)
                setLong(MediaFormat.KEY_REPEAT_PREVIOUS_FRAME_AFTER, 100_000)
                setInteger(MediaFormat.KEY_PROFILE, MediaCodecInfo.CodecProfileLevel.AVCProfileBaseline)
                setInteger(MediaFormat.KEY_LEVEL, MediaCodecInfo.CodecProfileLevel.AVCLevel41)
            }
            try {
                codec.configure(format, null, null, MediaCodec.CONFIGURE_FLAG_ENCODE)
            } catch (e: Exception) {
                // Some encoders reject the explicit profile/level – retry without.
                format.removeKey(MediaFormat.KEY_PROFILE)
                format.removeKey(MediaFormat.KEY_LEVEL)
                codec.reset()
                codec.configure(format, null, null, MediaCodec.CONFIGURE_FLAG_ENCODE)
            }
            surface = codec.createInputSurface()
            codec.start()
        }

        fun startDrain() {
            thread = Thread({ drain() }, "mirror-encoder").apply { start() }
        }

        fun requestKeyFrame() {
            try {
                codec.setParameters(Bundle().apply { putInt(MediaCodec.PARAMETER_KEY_REQUEST_SYNC_FRAME, 0) })
            } catch (_: Exception) {
            }
        }

        private fun drain() {
            val info = MediaCodec.BufferInfo()
            var buf = ByteArray(256 * 1024)
            while (alive) {
                val index = try {
                    codec.dequeueOutputBuffer(info, 100_000)
                } catch (e: Exception) {
                    break
                }
                if (index < 0) continue
                val out = codec.getOutputBuffer(index)
                if (out != null && info.size > 0) {
                    if (buf.size < info.size) buf = ByteArray(info.size * 2)
                    out.position(info.offset)
                    out.get(buf, 0, info.size)
                    val data = buf.copyOf(info.size)
                    if (info.flags and MediaCodec.BUFFER_FLAG_CODEC_CONFIG != 0) {
                        onConfig(data, width, height)
                    } else {
                        writeFrame(info.presentationTimeUs, data)
                    }
                }
                try {
                    codec.releaseOutputBuffer(index, false)
                } catch (_: Exception) {
                    break
                }
            }
        }

        fun release() {
            alive = false
            thread?.join(500)
            try {
                codec.stop()
            } catch (_: Exception) {
            }
            codec.release()
            surface.release()
        }
    }

    companion object {
        private const val TAG = "MirrorService"
        const val ACTION_STOP = "de.linktomac.MIRROR_STOP"
        const val EXTRA_RESULT_CODE = "resultCode"
        const val EXTRA_DATA = "data"
        const val EXTRA_MAX_SIZE = "maxSize"
        const val EXTRA_BITRATE = "bitrate"
        const val EXTRA_FPS = "fps"

        @Volatile var running: MirrorService? = null
            private set
        @Volatile var pendingParams = MirrorStart()

        private val sinkLock = Any()
        private var sink: DataOutputStream? = null
        private var sinkSocket: java.net.Socket? = null
        @Volatile private var config: ByteArray? = null

        private fun onConfig(data: ByteArray, width: Int, height: Int) {
            config = data
            val nals = splitAnnexB(data)
            val sps = nals.firstOrNull { it.isNotEmpty() && (it[0].toInt() and 0x1f) == 7 }
            val pps = nals.firstOrNull { it.isNotEmpty() && (it[0].toInt() and 0x1f) == 8 }
            if (sps != null && pps != null) {
                LinkHub.send(
                    MsgType.MIRROR_CONFIG,
                    MirrorConfig(width, height, Base64.encodeToString(sps, Base64.NO_WRAP), Base64.encodeToString(pps, Base64.NO_WRAP)),
                )
            }
            writeFrame(0, data)
        }

        private fun writeFrame(pts: Long, data: ByteArray) {
            synchronized(sinkLock) {
                val out = sink ?: return
                try {
                    de.linktomac.net.Frames.writeVideoFrame(out, pts, data, 0, data.size)
                } catch (e: Exception) {
                    closeSinkLocked()
                }
            }
        }

        /** Called by the video server once the Mac has connected and authenticated. */
        fun attachSink(socket: java.net.Socket) {
            synchronized(sinkLock) {
                closeSinkLocked()
                sinkSocket = socket
                sink = DataOutputStream(java.io.BufferedOutputStream(socket.getOutputStream(), 256 * 1024))
                config?.let {
                    try {
                        de.linktomac.net.Frames.writeVideoFrame(sink!!, 0, it, 0, it.size)
                    } catch (_: Exception) {
                    }
                }
            }
            running?.encoder?.requestKeyFrame()
        }

        fun closeSink() = synchronized(sinkLock) { closeSinkLocked() }

        private fun closeSinkLocked() {
            try {
                sinkSocket?.close()
            } catch (_: Exception) {
            }
            sink = null
            sinkSocket = null
        }

        /** Splits an Annex-B byte stream into NAL units (without start codes). */
        fun splitAnnexB(data: ByteArray): List<ByteArray> {
            val starts = mutableListOf<Pair<Int, Int>>() // (startCodeIndex, payloadIndex)
            var i = 0
            while (i + 3 <= data.size) {
                if (data[i].toInt() == 0 && data[i + 1].toInt() == 0) {
                    if (data[i + 2].toInt() == 1) {
                        starts += i to i + 3; i += 3; continue
                    }
                    if (i + 4 <= data.size && data[i + 2].toInt() == 0 && data[i + 3].toInt() == 1) {
                        starts += i to i + 4; i += 4; continue
                    }
                }
                i++
            }
            return starts.mapIndexed { idx, (_, payload) ->
                val end = if (idx + 1 < starts.size) starts[idx + 1].first else data.size
                data.copyOfRange(payload, end)
            }
        }

        fun stop(context: Context) {
            context.stopService(Intent(context, MirrorService::class.java))
        }
    }
}

/** Asks the user for screen capture permission and starts [MirrorService]. */
class MirrorPermissionActivity : Activity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        Notifications.cancel(this, Notifications.ID_MIRROR_REQUEST)
        val mpm = getSystemService(MediaProjectionManager::class.java)
        @Suppress("DEPRECATION")
        startActivityForResult(mpm.createScreenCaptureIntent(), REQUEST)
    }

    @Deprecated("Deprecated in Java")
    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
        if (requestCode == REQUEST) {
            if (resultCode == RESULT_OK && data != null) {
                val p = MirrorService.pendingParams
                val intent = Intent(this, MirrorService::class.java)
                    .putExtra(MirrorService.EXTRA_RESULT_CODE, resultCode)
                    .putExtra(MirrorService.EXTRA_DATA, data)
                    .putExtra(MirrorService.EXTRA_MAX_SIZE, p.maxSize)
                    .putExtra(MirrorService.EXTRA_BITRATE, p.bitrate)
                    .putExtra(MirrorService.EXTRA_FPS, p.fps)
                startForegroundService(intent)
            } else {
                LinkHub.send(MsgType.MIRROR_STOPPED, MirrorStopped("denied"))
            }
        }
        finish()
    }

    companion object {
        private const val REQUEST = 7
    }
}
