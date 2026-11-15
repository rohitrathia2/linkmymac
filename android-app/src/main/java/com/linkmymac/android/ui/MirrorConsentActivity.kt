package com.linkmymac.android.ui

import android.app.Activity
import android.content.Intent
import android.media.projection.MediaProjectionManager
import android.os.Bundle
import com.linkmymac.android.service.P2PDaemonService
import com.linkmymac.android.service.ScreenMirrorService
import org.json.JSONObject

/** Invisible activity: shows Android's screen-capture prompt, then starts mirroring (or tells the Mac no). */
class MirrorConsentActivity : Activity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        val prompt = getSystemService(MediaProjectionManager::class.java).createScreenCaptureIntent()
        @Suppress("DEPRECATION")
        startActivityForResult(prompt, 1)
    }

    @Deprecated("Framework Activity result API; this app doesn't use AndroidX Activity.")
    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        @Suppress("DEPRECATION")
        super.onActivityResult(requestCode, resultCode, data)
        if (resultCode == RESULT_OK && data != null) {
            startForegroundService(Intent(this, ScreenMirrorService::class.java)
                .putExtra(ScreenMirrorService.EXTRA_RESULT_CODE, resultCode)
                .putExtra(ScreenMirrorService.EXTRA_DATA, data))
        } else {
            P2PDaemonService.broadcastControlFrame(JSONObject()
                .put("type", "MIRROR_STATUS")
                .put("active", false)
                .put("error", "Screen mirroring was declined on the phone"))
        }
        finish()
    }
}
