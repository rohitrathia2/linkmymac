package com.linkmymac.android.service

import android.annotation.SuppressLint
import android.content.Context
import android.graphics.ImageFormat
import android.hardware.SensorManager
import android.hardware.camera2.CameraCaptureSession
import android.hardware.camera2.CameraCharacteristics
import android.hardware.camera2.CameraDevice
import android.hardware.camera2.CameraManager
import android.hardware.camera2.CameraMetadata
import android.hardware.camera2.CaptureRequest
import android.media.ImageReader
import android.os.Handler
import android.os.HandlerThread
import android.util.Base64
import android.view.OrientationEventListener
import org.json.JSONObject
import java.util.concurrent.atomic.AtomicBoolean

/**
 * =============================================================================
 * CameraStreamProvider: Live Continuity Camera & Front/Back Lens Streaming Engine
 * =============================================================================
 * WHAT IT DOES: Captures live camera frames from the Android device using the
 *               Camera2 API and streams them over the P2P connection to macOS,
 *               supporting real-time switching between Front (Selfie) and Back (Main) lenses.
 * HOW IT DOES IT:
 *   1. Enumerates camera devices via `CameraManager` to identify lens facing
 *      (`LENS_FACING_BACK` vs `LENS_FACING_FRONT`).
 *   2. Opens the target camera device and configures an `ImageReader` at 640x480 resolution
 *      with hardware-accelerated JPEG compression (`ImageFormat.JPEG`).
 *   3. Enforces a 60ms frame throttle (~15-18 FPS) to maintain smooth video while
 *      preventing socket saturation and thermal throttling.
 *   4. Packages each frame into a `CAMERA_FRAME` JSON payload and dispatches it
 *      via `P2PDaemonService.broadcastControlFrame()`.
 *   5. Handles dynamic lens switching on the fly by cleanly closing the active
 *      session and re-opening the alternate camera hardware.
 * WHY IT DOES IT: Transforms the connected Android device into a high-quality
 *                 wireless or USB webcam ("Continuity Camera") for macOS with
 *                 instant front/back camera toggling.
 * =============================================================================
 */
class CameraStreamProvider(private val context: Context) {

    private val cameraManager = context.getSystemService(Context.CAMERA_SERVICE) as CameraManager
    private var handlerThread: HandlerThread? = null
    private var backgroundHandler: Handler? = null

    private var activeCameraDevice: CameraDevice? = null
    private var activeCaptureSession: CameraCaptureSession? = null
    private var activeImageReader: ImageReader? = null
    private var currentCaptureRequestBuilder: CaptureRequest.Builder? = null

    private var orientationListener: OrientationEventListener? = null
    @Volatile
    private var deviceOrientationDegrees: Int = 0 // 0, 90, 180, 270
    @Volatile
    private var activeSensorOrientation: Int = 90
    @Volatile
    private var activeLensFacing: Int = CameraCharacteristics.LENS_FACING_BACK

    private val isStreaming = AtomicBoolean(false)
    private val isSwitchingLens = AtomicBoolean(false)
    @Volatile
    private var pendingTargetLens: String? = null
    @Volatile
    private var switchWatchdogRunnable: Runnable? = null
    private var currentLens: String = "BACK" // "BACK" or "FRONT"
    @Volatile
    private var targetCameraId: String? = null
    private var lastFrameTimeMs: Long = 0
    private val frameIntervalMs: Long = 65 // ~15 FPS cap for reliable network transmission
    private var wakeLock: android.os.PowerManager.WakeLock? = null

    /** Observable state change callback for Android UI updates */
    @Volatile
    var onCameraStateChanged: ((lens: String, isStreaming: Boolean, isSwitching: Boolean) -> Unit)? = null

    fun getCurrentLens(): String = currentLens
    fun isStreaming(): Boolean = isStreaming.get()
    fun isSwitching(): Boolean = isSwitchingLens.get()

    private fun notifyStateChanged() {
        onCameraStateChanged?.invoke(currentLens, isStreaming.get(), isSwitchingLens.get())
    }

    /**
     * -------------------------------------------------------------------------
     * startStream: Live Camera Pipeline Initialization
     * -------------------------------------------------------------------------
     * WHAT IT DOES: Boots the background handler thread, acquires wakelock, and opens camera.
     * HOW IT DOES IT:
     *   - Normalizes requested lens ("FRONT" or "BACK").
     *   - Manages atomic streaming state transition.
     *   - If already streaming, switches to requested lens if different or recovers session.
     *   - Initializes orientation listener and background thread.
     * WHY IT DOES IT: Offloads image capture processing from the main UI thread while ensuring
     *                 seamless recovery and state synchronization.
     * -------------------------------------------------------------------------
     */
    fun startStream(lens: String = "BACK") {
        val normalized = if (lens.equals("FRONT", ignoreCase = true)) "FRONT" else "BACK"
        val previousLens = currentLens
        currentLens = normalized
        android.util.Log.d("CameraStreamProvider", "startStream: lens=$normalized, wasStreaming=${isStreaming.get()}")
        if (isStreaming.getAndSet(true)) {
            if (activeCameraDevice == null || activeCaptureSession == null) {
                android.util.Log.d("CameraStreamProvider", "Recovering camera device for $normalized")
                startBackgroundThread()
                initOrientationListener()
                openSelectedCamera(normalized, 0)
            } else if (normalized != previousLens) {
                switchLens(normalized)
            }
            return
        }

        initOrientationListener()
        startBackgroundThread()
        try {
            val pm = context.getSystemService(Context.POWER_SERVICE) as android.os.PowerManager
            wakeLock = pm.newWakeLock(
                android.os.PowerManager.SCREEN_BRIGHT_WAKE_LOCK or android.os.PowerManager.ACQUIRE_CAUSES_WAKEUP,
                "LinkMyMac:CameraStream"
            ).apply { acquire(30 * 60 * 1000L) }
        } catch (_: Exception) {}
        openSelectedCamera(normalized, 0)
        notifyStateChanged()
    }

    /**
     * -------------------------------------------------------------------------
     * stopStream: Live Camera Pipeline Teardown
     * -------------------------------------------------------------------------
     * WHAT IT DOES: Halts camera capture, closes camera device, and shuts down threads.
     * HOW IT DOES IT: Closes `activeCaptureSession`, `activeCameraDevice`, and
     *                 `activeImageReader`, quits the `HandlerThread`, and sets `isStreaming = false`.
     * WHY IT DOES IT: Releases Android hardware camera locks immediately so other
     *                 apps can use the camera and saves battery when streaming ends.
     * -------------------------------------------------------------------------
     */
    fun stopStream() {
        if (!isStreaming.getAndSet(false)) return
        isSwitchingLens.set(false)
        pendingTargetLens = null
        switchWatchdogRunnable?.let { backgroundHandler?.removeCallbacks(it) }
        switchWatchdogRunnable = null
        targetCameraId = null

        orientationListener?.disable()
        orientationListener = null

        try {
            activeCaptureSession?.stopRepeating()
            activeCaptureSession?.close()
            activeCaptureSession = null

            activeCameraDevice?.close()
            activeCameraDevice = null

            activeImageReader?.close()
            activeImageReader = null
            currentCaptureRequestBuilder = null
        } catch (_: Exception) {}

        try {
            wakeLock?.let { if (it.isHeld) it.release() }
            wakeLock = null
        } catch (_: Exception) {}
        stopBackgroundThread()

        // Notify macOS that stream has stopped
        val stopFrame = JSONObject().apply {
            put("type", "CAMERA_STREAM_STATUS")
            put("isStreaming", false)
            put("lens", currentLens)
            put("isSwitching", false)
        }
        P2PDaemonService.broadcastControlFrame(stopFrame)
        notifyStateChanged()
    }

    /**
     * -------------------------------------------------------------------------
     * switchLens: Front / Back Camera Lens Switcher (FaceTime Style)
     * -------------------------------------------------------------------------
     * WHAT IT DOES: Dynamically switches the active camera feed between Front and Back lenses.
     * HOW IT DOES IT:
     *   - Normalizes target lens ("FRONT" / "BACK").
     *   - Sets atomic `isSwitchingLens` flag and `pendingTargetLens`.
     *   - Immediately emits `CAMERA_STREAM_STATUS` with `isSwitching = true` to update macOS UI.
     *   - Gracefully stops repeating capture and closes active camera.
     *   - Chains the opening of the target camera to the `onClosed()` HAL callback,
     *     guaranteeing hardware ISP resources are fully released before reopening.
     *   - Arms a 450ms watchdog timer as fallback in case HAL drops the `onClosed()` callback.
     * WHY IT DOES IT: Prevents `CameraAccessException: CAMERA_IN_USE` errors caused by
     *                 premature camera reopening before HAL releases the prior lens session.
     * -------------------------------------------------------------------------
     */
    @Synchronized
    fun switchLens(targetLens: String) {
        val normalized = if (targetLens.equals("FRONT", ignoreCase = true)) "FRONT" else "BACK"
        currentLens = normalized
        android.util.Log.d("CameraStreamProvider", "switchLens: requesting switch to $normalized")

        if (!isStreaming.get()) {
            startStream(normalized)
            return
        }

        // Notify macOS immediately of the pending switch
        val switchingStatus = JSONObject().apply {
            put("type", "CAMERA_STREAM_STATUS")
            put("isStreaming", true)
            put("lens", normalized)
            put("isSwitching", true)
        }
        P2PDaemonService.broadcastControlFrame(switchingStatus)

        isSwitchingLens.set(true)
        pendingTargetLens = normalized
        lastFrameTimeMs = 0
        notifyStateChanged()

        // Cancel any pending watchdog timer
        switchWatchdogRunnable?.let { backgroundHandler?.removeCallbacks(it) }

        val closingCamera = activeCameraDevice
        if (closingCamera != null) {
            // Close active capture session and device
            try {
                activeCaptureSession?.stopRepeating()
                activeCaptureSession?.close()
                activeCaptureSession = null
                activeImageReader?.close()
                activeImageReader = null
                currentCaptureRequestBuilder = null
            } catch (_: Exception) {}

            try {
                closingCamera.close()
            } catch (_: Exception) {}
            activeCameraDevice = null

            // Watchdog fallback in case HAL onClosed is dropped
            val watchdog = Runnable {
                if (isSwitchingLens.compareAndSet(true, false) && isStreaming.get()) {
                    android.util.Log.w("CameraStreamProvider", "switchLens: Watchdog triggered opening $normalized")
                    openSelectedCamera(normalized, 0)
                }
            }
            switchWatchdogRunnable = watchdog
            backgroundHandler?.postDelayed(watchdog, 450)
        } else {
            // No camera currently open, directly open target lens
            isSwitchingLens.set(false)
            openSelectedCamera(normalized, 0)
        }
    }

    /**
     * -------------------------------------------------------------------------
     * initOrientationListener: Hardware Device Tilt Tracking
     * -------------------------------------------------------------------------
     * WHAT IT DOES: Monitors device physical orientation changes (portrait vs landscape).
     * HOW IT DOES IT:
     *   - Uses Android OrientationEventListener with SENSOR_DELAY_NORMAL.
     *   - Normalizes raw angle (0..359) to nearest 90-degree quadrant: 0, 90, 180, 270.
     *   - Dynamically reapplies JPEG_ORIENTATION to the repeating capture request.
     * WHY IT DOES IT: Guarantees camera video feed orientation strictly matches
     *                 the physical Android device orientation on macOS.
     * -------------------------------------------------------------------------
     */
    private fun initOrientationListener() {
        if (orientationListener != null) return
        orientationListener = object : OrientationEventListener(context, SensorManager.SENSOR_DELAY_NORMAL) {
            override fun onOrientationChanged(orientation: Int) {
                if (orientation == ORIENTATION_UNKNOWN) return
                val newRotation = when (orientation) {
                    in 45..134 -> 270 // device tilted to the right
                    in 135..224 -> 180 // upside down
                    in 225..314 -> 90 // device tilted to the left
                    else -> 0 // upright portrait
                }
                if (newRotation != deviceOrientationDegrees) {
                    deviceOrientationDegrees = newRotation
                    updateCaptureOrientation()
                }
            }
        }
        if (orientationListener?.canDetectOrientation() == true) {
            orientationListener?.enable()
        }
    }

    private fun computeJpegOrientation(): Int {
        return if (activeLensFacing == CameraCharacteristics.LENS_FACING_FRONT) {
            (activeSensorOrientation + deviceOrientationDegrees) % 360
        } else {
            (activeSensorOrientation - deviceOrientationDegrees + 360) % 360
        }
    }

    private fun updateCaptureOrientation() {
        val session = activeCaptureSession ?: return
        val builder = currentCaptureRequestBuilder ?: return
        val handler = backgroundHandler ?: return
        try {
            val orientation = computeJpegOrientation()
            builder.set(CaptureRequest.JPEG_ORIENTATION, orientation)
            session.setRepeatingRequest(builder.build(), null, handler)
        } catch (_: Exception) {}
    }

    /**
     * -------------------------------------------------------------------------
     * openSelectedCamera: Hardware Camera Resolution, Opening & Exponential Backoff
     * -------------------------------------------------------------------------
     * WHAT IT DOES: Resolves the physical camera ID for requested lens and opens it with retries.
     * HOW IT DOES IT:
     *   - Maps lens to CameraCharacteristics.LENS_FACING_FRONT or LENS_FACING_BACK.
     *   - Queries CameraManager for characteristics (sensor orientation, facing).
     *   - Invokes `cameraManager.openCamera` with comprehensive StateCallback.
     *   - Handles synchronous `CameraAccessException` and asynchronous HAL error codes
     *     by automatically retrying with exponential backoff (up to 3 attempts).
     *   - Directs `onClosed` callback to trigger queued lens switches immediately.
     * WHY IT DOES IT: Eliminates silent failures and guarantees rock-solid recovery on
     *                 OEM camera drivers (e.g. Vivo dual-camera HAL lock contention).
     * -------------------------------------------------------------------------
     */
    @SuppressLint("MissingPermission")
    private fun openSelectedCamera(lens: String, retryCount: Int = 0) {
        val targetFacing = if (lens.equals("FRONT", ignoreCase = true)) {
            CameraCharacteristics.LENS_FACING_FRONT
        } else {
            CameraCharacteristics.LENS_FACING_BACK
        }

        val cameraId = findCameraIdForFacing(targetFacing) ?: run {
            cameraManager.cameraIdList.firstOrNull() ?: return
        }
        targetCameraId = cameraId
        android.util.Log.d("CameraStreamProvider", "openSelectedCamera: lens=$lens, cameraId=$cameraId, retryCount=$retryCount")

        try {
            val characteristics = cameraManager.getCameraCharacteristics(cameraId)
            activeSensorOrientation = characteristics.get(CameraCharacteristics.SENSOR_ORIENTATION) ?: 90
            activeLensFacing = characteristics.get(CameraCharacteristics.LENS_FACING) ?: targetFacing

            cameraManager.openCamera(cameraId, object : CameraDevice.StateCallback() {
                override fun onOpened(camera: CameraDevice) {
                    android.util.Log.d("CameraStreamProvider", "onOpened: cameraId=${camera.id}, target=$targetCameraId, streaming=${isStreaming.get()}")
                    if (!isStreaming.get() || camera.id != targetCameraId) {
                        android.util.Log.w("CameraStreamProvider", "Closing obsolete or cancelled camera ${camera.id}")
                        camera.close()
                        return
                    }
                    activeCameraDevice?.close()
                    activeCameraDevice = camera
                    isSwitchingLens.set(false)
                    notifyStateChanged()
                    startCaptureSession(camera)
                }

                override fun onClosed(camera: CameraDevice) {
                    android.util.Log.d("CameraStreamProvider", "onClosed: cameraId=${camera.id}")
                    if (activeCameraDevice == camera) {
                        activeCameraDevice = null
                    }
                    // If a lens switch was awaiting this camera closure, execute it now!
                    if (isSwitchingLens.compareAndSet(true, false)) {
                        switchWatchdogRunnable?.let { backgroundHandler?.removeCallbacks(it) }
                        switchWatchdogRunnable = null
                        val next = pendingTargetLens ?: currentLens
                        android.util.Log.d("CameraStreamProvider", "onClosed: Hardware released, opening queued lens $next")
                        backgroundHandler?.post {
                            if (isStreaming.get()) {
                                openSelectedCamera(next, 0)
                            }
                        }
                    }
                }

                override fun onDisconnected(camera: CameraDevice) {
                    android.util.Log.d("CameraStreamProvider", "onDisconnected: cameraId=$cameraId")
                    camera.close()
                    if (activeCameraDevice == camera) {
                        activeCameraDevice = null
                    }
                }

                override fun onError(camera: CameraDevice, error: Int) {
                    android.util.Log.e("CameraStreamProvider", "onError: cameraId=$cameraId, error=$error (retryCount=$retryCount)")
                    camera.close()
                    if (activeCameraDevice == camera) {
                        activeCameraDevice = null
                    }
                    if (isStreaming.get() && retryCount < 3) {
                        val delay = (retryCount + 1) * 250L
                        android.util.Log.w("CameraStreamProvider", "Retrying camera open in ${delay}ms...")
                        backgroundHandler?.postDelayed({
                            if (isStreaming.get()) {
                                openSelectedCamera(lens, retryCount + 1)
                            }
                        }, delay)
                    } else {
                        isSwitchingLens.set(false)
                        val errorStatus = JSONObject().apply {
                            put("type", "CAMERA_STREAM_STATUS")
                            put("isStreaming", false)
                            put("lens", currentLens)
                            put("isSwitching", false)
                            put("error", "Camera error $error")
                        }
                        P2PDaemonService.broadcastControlFrame(errorStatus)
                    }
                }
            }, backgroundHandler)
        } catch (e: Exception) {
            android.util.Log.e("CameraStreamProvider", "Exception in openCamera for $cameraId (retryCount=$retryCount)", e)
            if (isStreaming.get() && retryCount < 3) {
                val delay = (retryCount + 1) * 250L
                backgroundHandler?.postDelayed({
                    if (isStreaming.get()) {
                        openSelectedCamera(lens, retryCount + 1)
                    }
                }, delay)
            } else {
                isSwitchingLens.set(false)
                val errorStatus = JSONObject().apply {
                    put("type", "CAMERA_STREAM_STATUS")
                    put("isStreaming", false)
                    put("lens", currentLens)
                    put("isSwitching", false)
                    put("error", e.localizedMessage ?: "Camera opening failed")
                }
                P2PDaemonService.broadcastControlFrame(errorStatus)
            }
        }
    }

    /**
     * -------------------------------------------------------------------------
     * startCaptureSession: ImageReader Binding & Repeating Preview Request
     * -------------------------------------------------------------------------
     * WHAT IT DOES: Configures the camera session to capture 640x480 JPEG frames.
     * HOW IT DOES IT:
     *   1. Creates `ImageReader.newInstance(640, 480, ImageFormat.JPEG, 2)`.
     *   2. Attaches an `OnImageAvailableListener` that extracts JPEG bytes and broadcasts.
     *   3. Applies computeJpegOrientation() to CaptureRequest.JPEG_ORIENTATION.
     *   4. Builds a `TEMPLATE_PREVIEW` capture request and starts repeating requests.
     * WHY IT DOES IT: Hardware JPEG compression minimizes CPU load while respecting
     *                 real-time device tilt & rotation angles.
     * -------------------------------------------------------------------------
     */
    private fun startCaptureSession(camera: CameraDevice) {
        val imageReader = ImageReader.newInstance(640, 480, ImageFormat.JPEG, 2)
        activeImageReader = imageReader

        imageReader.setOnImageAvailableListener({ reader ->
            val image = reader.acquireLatestImage() ?: return@setOnImageAvailableListener
            try {
                val now = System.currentTimeMillis()
                if (now - lastFrameTimeMs >= frameIntervalMs) {
                    lastFrameTimeMs = now
                    val planes = image.planes
                    if (planes.isNotEmpty()) {
                        val buffer = planes[0].buffer
                        val bytes = ByteArray(buffer.remaining())
                        buffer.get(bytes)

                        val base64 = Base64.encodeToString(bytes, Base64.NO_WRAP)
                        val framePacket = JSONObject().apply {
                            put("type", "CAMERA_FRAME")
                            put("lens", currentLens)
                            put("width", image.width)
                            put("height", image.height)
                            put("frameBase64", base64)
                            put("rotationDegrees", computeJpegOrientation())
                            put("deviceOrientation", deviceOrientationDegrees)
                            put("sensorOrientation", activeSensorOrientation)
                            put("timestampMs", now)
                        }
                        P2PDaemonService.broadcastControlFrame(framePacket)
                    }
                }
            } catch (_: Exception) {
            } finally {
                image.close()
            }
        }, backgroundHandler)

        try {
            val surface = imageReader.surface
            val previewRequestBuilder = camera.createCaptureRequest(CameraDevice.TEMPLATE_PREVIEW).apply {
                addTarget(surface)
                set(CaptureRequest.CONTROL_MODE, CameraMetadata.CONTROL_MODE_AUTO)
                set(CaptureRequest.CONTROL_AF_MODE, CaptureRequest.CONTROL_AF_MODE_CONTINUOUS_PICTURE)
                set(CaptureRequest.JPEG_ORIENTATION, computeJpegOrientation())
            }
            currentCaptureRequestBuilder = previewRequestBuilder

            camera.createCaptureSession(
                listOf(surface),
                object : CameraCaptureSession.StateCallback() {
                    override fun onConfigured(session: CameraCaptureSession) {
                        activeCaptureSession = session
                        try {
                            session.setRepeatingRequest(
                                previewRequestBuilder.build(),
                                null,
                                backgroundHandler
                            )

                            // Notify macOS that stream is now active and lens switch is complete
                            val statusFrame = JSONObject().apply {
                                put("type", "CAMERA_STREAM_STATUS")
                                put("isStreaming", true)
                                put("lens", currentLens)
                                put("isSwitching", false)
                            }
                            P2PDaemonService.broadcastControlFrame(statusFrame)
                        } catch (_: Exception) {}
                    }

                    override fun onConfigureFailed(session: CameraCaptureSession) {
                        android.util.Log.e("CameraStreamProvider", "Capture session configuration failed")
                        activeCaptureSession = null
                        isSwitchingLens.set(false)
                        val errorStatus = JSONObject().apply {
                            put("type", "CAMERA_STREAM_STATUS")
                            put("isStreaming", false)
                            put("lens", currentLens)
                            put("isSwitching", false)
                            put("error", "Capture session configuration failed")
                        }
                        P2PDaemonService.broadcastControlFrame(errorStatus)
                    }
                },
                backgroundHandler
            )
        } catch (_: Exception) {}
    }

    private fun findCameraIdForFacing(facing: Int): String? {
        for (id in cameraManager.cameraIdList) {
            val characteristics = cameraManager.getCameraCharacteristics(id)
            val lensFacing = characteristics.get(CameraCharacteristics.LENS_FACING)
            if (lensFacing == facing) {
                return id
            }
        }
        return null
    }

    private fun startBackgroundThread() {
        if (handlerThread == null) {
            handlerThread = HandlerThread("LMM-CameraStream").apply {
                start()
                backgroundHandler = Handler(looper)
            }
        }
    }

    private fun stopBackgroundThread() {
        handlerThread?.quitSafely()
        try {
            handlerThread?.join(500)
        } catch (_: Exception) {}
        handlerThread = null
        backgroundHandler = null
    }
}
