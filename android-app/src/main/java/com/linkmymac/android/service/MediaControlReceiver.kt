package com.linkmymac.android.service

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent

/**
 * =============================================================================
 * MediaControlReceiver: System Notification Media Action Broadcast Receiver
 * =============================================================================
 * WHAT IT DOES:
 *   Intercepts user clicks on media notification buttons (Previous, Play/Pause, Next)
 *   in the Android notification panel and lock screen.
 *
 * HOW IT DOES IT:
 *   Receives broadcast intents (`ACTION_PLAY_PAUSE`, `ACTION_NEXT`, `ACTION_PREV`)
 *   and delegates to `P2PDaemonService.sendMediaCommand()`.
 *
 * WHY IT DOES IT:
 *   Allows instantaneous control of macOS media playback without needing to open
 *   the companion application.
 * =============================================================================
 */
class MediaControlReceiver : BroadcastReceiver() {

    override fun onReceive(context: Context, intent: Intent) {
        val action = intent.action ?: return
        android.util.Log.d("MediaControlReceiver", "Received media action: $action")

        when (action) {
            MediaNotificationHelper.ACTION_PLAY_PAUSE -> {
                P2PDaemonService.sendMediaCommand("TOGGLE_PLAY_PAUSE")
            }
            MediaNotificationHelper.ACTION_NEXT -> {
                P2PDaemonService.sendMediaCommand("NEXT_TRACK")
            }
            MediaNotificationHelper.ACTION_PREV -> {
                P2PDaemonService.sendMediaCommand("PREV_TRACK")
            }
        }
    }
}
