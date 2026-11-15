package com.linkmymac.android.service

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.util.Log

/**
 * Restarts the bridge after a reboot or an app update, so the Mac can reconnect without
 * the user opening the app. Both broadcasts are exempt from Android 12's background
 * foreground-service start limits.
 */
class AutoStartReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        try {
            context.startForegroundService(Intent(context, P2PDaemonService::class.java))
        } catch (e: Exception) {
            // e.g. Android 15 forbids dataSync services from BOOT_COMPLETED; the app's next launch starts it.
            Log.w("AutoStartReceiver", "Could not start the bridge on ${intent.action}: ${e.message}")
        }
    }
}
