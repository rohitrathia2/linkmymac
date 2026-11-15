package com.linkmymac.android.service

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.graphics.Bitmap
import android.graphics.PixelFormat
import android.hardware.display.DisplayManager
import android.hardware.display.VirtualDisplay
import android.media.Image
import android.media.ImageReader
import android.media.projection.MediaProjection
import android.media.projection.MediaProjectionManager
import android.os.Build
import android.os.Handler
import android.os.HandlerThread
import android.os.IBinder
import android.os.SystemClock
import android.util.Base64
import android.util.DisplayMetrics
import android.view.Display
import org.json.JSONObject
import java.io.ByteArrayOutputStream

/** Full physical screen size in pixels (works from any Context, unlike WindowMetrics). */
fun Context.realScreenSize(): Pair<Int, Int> {
    val display = getSystemService(DisplayManager::class.java).getDisplay(Display.DEFAULT_DISPLAY)
    val metrics = DisplayMetrics()
    @Suppress("DEPRECATION") display.getRealMetrics(metrics)
    return metrics.widthPixels to metrics.heightPixels
}

/**
 * Mirrors the phone screen to the paired Mac as JPEG frames (MIRROR_FRAME).
 * Started by MirrorConsentActivity once the person approves Android's capture prompt.
 * Frames go out with blocking writes: a slow link drops frames instead of queuing them.
 */
class ScreenMirrorService : Service() {
    companion object {
        const val EXTRA_RESULT_CODE = "resultCode"
        const val EXTRA_DATA = "data"
        const val PROMPT_NOTIFICATION_ID = 3001
        private const val MAX_WIDTH = 720
        private const val FRAME_INTERVAL_MS = 80L // ≈12 fps
        private const val JPEG_QUALITY = 60

        @Volatile
        var isRunning = false
            private set

        fun stop(context: Context) {
            context.stopService(Intent(context, ScreenMirrorService::class.java))
        }
    }

    private var projection: MediaProjection? = null
    private var virtualDisplay: VirtualDisplay? = null
    private var reader: ImageReader? = null
    private var thread: HandlerThread? = null
    private var frame: Bitmap? = null
    private var lastFrameAt = 0L

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        startInForeground() // must precede getMediaProjection on Android 10+
        @Suppress("DEPRECATION")
        val data = intent?.getParcelableExtra<Intent>(EXTRA_DATA)
        if (data == null || projection != null) return START_NOT_STICKY
        try {
            startCapture(intent.getIntExtra(EXTRA_RESULT_CODE, 0), data)
        } catch (e: Exception) {
            report(active = false, error = e.message ?: "Couldn't start screen capture")
            stopSelf()
        }
        return START_NOT_STICKY
    }

    private fun startInForeground() {
        val nm = getSystemService(NotificationManager::class.java)
        nm.createNotificationChannel(NotificationChannel("linkmymac_mirror", "Screen mirroring", NotificationManager.IMPORTANCE_LOW))
        nm.cancel(PROMPT_NOTIFICATION_ID)
        val notification = Notification.Builder(this, "linkmymac_mirror")
            .setSmallIcon(android.R.drawable.ic_menu_slideshow)
            .setContentTitle("Mirroring your screen to your Mac")
            .setOngoing(true)
            .build()
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            startForeground(1003, notification, ServiceInfo.FOREGROUND_SERVICE_TYPE_MEDIA_PROJECTION)
        } else {
            startForeground(1003, notification)
        }
    }

    private fun startCapture(resultCode: Int, data: Intent) {
        val proj = getSystemService(MediaProjectionManager::class.java).getMediaProjection(resultCode, data)
            ?: error("Screen capture wasn't allowed")
        projection = proj
        val handler = Handler(HandlerThread("linkmymac-mirror").also { thread = it; it.start() }.looper)
        proj.registerCallback(object : MediaProjection.Callback() {
            override fun onStop() = stopSelf() // e.g. the person tapped "Stop" in the status bar
        }, handler)

        val (screenW, screenH) = realScreenSize()
        val scale = minOf(1f, MAX_WIDTH.toFloat() / screenW)
        val width = (screenW * scale).toInt() and 1.inv() // even sizes keep encoders happy
        val height = (screenH * scale).toInt() and 1.inv()
        val imageReader = ImageReader.newInstance(width, height, PixelFormat.RGBA_8888, 2)
        reader = imageReader
        virtualDisplay = proj.createVirtualDisplay(
            "LinkMyMac", width, height, resources.displayMetrics.densityDpi,
            DisplayManager.VIRTUAL_DISPLAY_FLAG_AUTO_MIRROR, imageReader.surface, null, handler
        )
        imageReader.setOnImageAvailableListener({ r ->
            r.acquireLatestImage()?.use { sendFrame(it, width, height) } // latest only: stale frames are dropped
        }, handler)
        isRunning = true
        report(active = true, width = width, height = height)
    }

    private fun sendFrame(image: Image, width: Int, height: Int) {
        val now = SystemClock.elapsedRealtime()
        if (now - lastFrameAt < FRAME_INTERVAL_MS) return
        lastFrameAt = now
        val plane = image.planes[0]
        val rowPixels = plane.rowStride / plane.pixelStride // rows may be padded
        val bitmap = frame?.takeIf { it.width == rowPixels && it.height == height }
            ?: Bitmap.createBitmap(rowPixels, height, Bitmap.Config.ARGB_8888).also { frame = it }
        bitmap.copyPixelsFromBuffer(plane.buffer)
        val visible = if (rowPixels == width) bitmap else Bitmap.createBitmap(bitmap, 0, 0, width, height)
        val jpeg = ByteArrayOutputStream().also { visible.compress(Bitmap.CompressFormat.JPEG, JPEG_QUALITY, it) }
        val sent = P2PDaemonService.sendToMacBlocking(JSONObject()
            .put("type", "MIRROR_FRAME")
            .put("width", width)
            .put("height", height)
            .put("jpegBase64", Base64.encodeToString(jpeg.toByteArray(), Base64.NO_WRAP)))
        if (!sent) stopSelf() // no paired Mac left
    }

    private fun report(active: Boolean, error: String? = null, width: Int = 0, height: Int = 0) {
        P2PDaemonService.broadcastControlFrame(JSONObject()
            .put("type", "MIRROR_STATUS")
            .put("active", active)
            .put("width", width)
            .put("height", height)
            .put("controlEnabled", ControlService.instance != null)
            .apply { error?.let { put("error", it) } })
    }

    override fun onDestroy() {
        isRunning = false
        virtualDisplay?.release()
        reader?.close()
        projection?.stop()
        thread?.quitSafely()
        virtualDisplay = null
        reader = null
        projection = null
        report(active = false)
        super.onDestroy()
    }
}
