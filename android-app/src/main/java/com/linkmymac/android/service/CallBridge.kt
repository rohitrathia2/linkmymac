package com.linkmymac.android.service

import android.Manifest
import android.content.Context
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Bundle
import android.provider.CallLog
import android.telecom.TelecomManager
import android.telephony.PhoneStateListener
import android.telephony.TelephonyManager
import org.json.JSONArray
import org.json.JSONObject

/**
 * Calls from the Mac: live call state, answer / decline / end, dialing, recent calls.
 * Call audio stays on the phone: Android doesn't let apps route it, and macOS can't
 * act as a Bluetooth headset for a phone.
 */
class CallBridge(private val context: Context, private val names: (String) -> String?) {
    @Suppress("DEPRECATION")
    private var listener: PhoneStateListener? = null

    private fun granted(permission: String) =
        context.checkSelfPermission(permission) == PackageManager.PERMISSION_GRANTED

    private val allowHint = "Allow Phone access in the LinkMyMac app on your phone"

    /** Broadcasts CALL_STATE on ringing / active / idle. Safe to call again after permissions change. */
    @Suppress("DEPRECATION") // TelephonyCallback (API 31+) no longer reports the caller's number
    fun start(onState: (JSONObject) -> Unit) {
        if (listener != null || !granted(Manifest.permission.READ_PHONE_STATE)) return
        val telephony = context.getSystemService(TelephonyManager::class.java) ?: return
        // The no-arg constructor needs a Looper on the calling thread; an executor works from any thread.
        listener = object : PhoneStateListener(context.mainExecutor) {
            override fun onCallStateChanged(state: Int, phoneNumber: String?) {
                val number = phoneNumber.orEmpty() // empty without READ_CALL_LOG
                onState(JSONObject()
                    .put("type", "CALL_STATE")
                    .put("state", when (state) {
                        TelephonyManager.CALL_STATE_RINGING -> "ringing"
                        TelephonyManager.CALL_STATE_OFFHOOK -> "active"
                        else -> "idle"
                    })
                    .put("number", number)
                    .put("name", names(number) ?: ""))
            }
        }.also { telephony.listen(it, PhoneStateListener.LISTEN_CALL_STATE) }
    }

    @Suppress("DEPRECATION")
    fun stop() {
        listener?.let { context.getSystemService(TelephonyManager::class.java)?.listen(it, PhoneStateListener.LISTEN_NONE) }
        listener = null
    }

    /** answer | decline | end. Returns null on success, else a reason. */
    @Suppress("DEPRECATION") // still the only call control a non-dialer app gets
    fun act(action: String): String? {
        if (!granted(Manifest.permission.ANSWER_PHONE_CALLS)) return allowHint
        val telecom = context.getSystemService(TelecomManager::class.java) ?: return "No telephony on this phone"
        return try {
            when (action) {
                "answer" -> { telecom.acceptRingingCall(); null }
                "decline", "end" -> if (telecom.endCall()) null else "There's no call to end"
                else -> "Unknown call action"
            }
        } catch (e: SecurityException) {
            e.message ?: allowHint
        }
    }

    /** Places a call through the system dialer; works with the app in the background. */
    fun dial(number: String): String? {
        if (!granted(Manifest.permission.CALL_PHONE)) return allowHint
        if (number.isBlank()) return "Enter a number"
        return try {
            context.getSystemService(TelecomManager::class.java)
                ?.placeCall(Uri.fromParts("tel", number, null), Bundle())
                ?: return "No telephony on this phone"
            null
        } catch (e: SecurityException) {
            e.message ?: allowHint
        }
    }

    /** The latest [limit] calls, newest first. */
    fun recent(limit: Int): JSONObject {
        val response = JSONObject().put("type", "CALL_LOG")
        if (!granted(Manifest.permission.READ_CALL_LOG)) return response.put("error", allowHint)
        val calls = JSONArray()
        context.contentResolver.query(
            CallLog.Calls.CONTENT_URI,
            arrayOf(CallLog.Calls.NUMBER, CallLog.Calls.CACHED_NAME, CallLog.Calls.TYPE,
                CallLog.Calls.DATE, CallLog.Calls.DURATION),
            null, null, "${CallLog.Calls.DATE} DESC"
        )?.use { c ->
            while (c.moveToNext() && calls.length() < limit) {
                calls.put(JSONObject()
                    .put("number", c.getString(0) ?: "")
                    .put("name", c.getString(1) ?: "")
                    .put("kind", when (c.getInt(2)) {
                        CallLog.Calls.INCOMING_TYPE -> "incoming"
                        CallLog.Calls.OUTGOING_TYPE -> "outgoing"
                        CallLog.Calls.MISSED_TYPE -> "missed"
                        CallLog.Calls.REJECTED_TYPE, CallLog.Calls.BLOCKED_TYPE -> "declined"
                        else -> "other"
                    })
                    .put("dateMs", c.getLong(3))
                    .put("durationSec", c.getLong(4)))
            }
        }
        return response.put("calls", calls)
    }
}
