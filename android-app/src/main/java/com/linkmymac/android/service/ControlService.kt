package com.linkmymac.android.service

import android.accessibilityservice.AccessibilityService
import android.accessibilityservice.GestureDescription
import android.content.Intent
import android.graphics.Path
import android.os.Build
import android.os.Bundle
import android.view.accessibility.AccessibilityEvent
import android.view.accessibility.AccessibilityNodeInfo
import org.json.JSONObject

/**
 * Lets the Mac's mouse and keyboard drive the phone: taps, drags, scrolls, typing,
 * Back / Home / Recents. The person turns it on once in Accessibility settings
 * ("LinkMyMac Mac Control"); nothing here runs until they do.
 */
class ControlService : AccessibilityService() {
    companion object {
        @Volatile
        var instance: ControlService? = null
            private set
    }

    override fun onServiceConnected() {
        instance = this
    }

    override fun onUnbind(intent: Intent?): Boolean {
        instance = null
        return super.onUnbind(intent)
    }

    override fun onDestroy() {
        instance = null
        super.onDestroy()
    }

    override fun onAccessibilityEvent(event: AccessibilityEvent?) {}
    override fun onInterrupt() {}

    /** One INPUT_* frame from the Mac. Positions are 0..1 of the screen; call on the main thread. */
    fun handle(json: JSONObject) {
        when (json.optString("type")) {
            "INPUT_TAP" -> stroke(json.optDouble("x"), json.optDouble("y"),
                json.optDouble("x"), json.optDouble("y"), json.optLong("durationMs", 60))
            "INPUT_SWIPE" -> stroke(json.optDouble("x1"), json.optDouble("y1"),
                json.optDouble("x2"), json.optDouble("y2"), json.optLong("durationMs", 250))
            "INPUT_TEXT" -> editFocused { it + json.optString("text") }
            "INPUT_KEY" -> when (json.optString("key")) {
                "backspace" -> editFocused { it.dropLast(1) }
                "enter" -> if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
                    focusedInput()?.performAction(AccessibilityNodeInfo.AccessibilityAction.ACTION_IME_ENTER.id)
                }
            }
            "INPUT_GLOBAL" -> performGlobalAction(when (json.optString("action")) {
                "back" -> GLOBAL_ACTION_BACK
                "home" -> GLOBAL_ACTION_HOME
                "recents" -> GLOBAL_ACTION_RECENTS
                "notifications" -> GLOBAL_ACTION_NOTIFICATIONS
                else -> return
            })
        }
    }

    /** A tap is a stroke that starts and ends at the same point; a long press is a long tap. */
    private fun stroke(x1: Double, y1: Double, x2: Double, y2: Double, durationMs: Long) {
        val (width, height) = realScreenSize()
        fun px(v: Double, size: Int) = (v.coerceIn(0.0, 1.0) * (size - 1)).toFloat()
        val path = Path().apply {
            moveTo(px(x1, width), px(y1, height))
            lineTo(px(x2, width), px(y2, height))
        }
        dispatchGesture(GestureDescription.Builder()
            .addStroke(GestureDescription.StrokeDescription(path, 0, durationMs.coerceIn(1, 5_000)))
            .build(), null, null)
    }

    private fun focusedInput(): AccessibilityNodeInfo? =
        rootInActiveWindow?.findFocus(AccessibilityNodeInfo.FOCUS_INPUT)

    /** ACTION_SET_TEXT replaces the whole field, so typing appends to (and Backspace trims) its end. */
    private fun editFocused(change: (String) -> String) {
        val node = focusedInput() ?: return
        val current = if (node.isShowingHintText) "" else node.text?.toString().orEmpty()
        node.performAction(AccessibilityNodeInfo.ACTION_SET_TEXT, Bundle().apply {
            putCharSequence(AccessibilityNodeInfo.ACTION_ARGUMENT_SET_TEXT_CHARSEQUENCE, change(current))
        })
    }
}
