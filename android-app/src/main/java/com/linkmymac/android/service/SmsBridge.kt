package com.linkmymac.android.service

import android.Manifest
import android.content.Context
import android.content.pm.PackageManager
import android.database.ContentObserver
import android.net.Uri
import android.os.Handler
import android.os.Looper
import android.provider.ContactsContract
import android.provider.Telephony
import android.telephony.SmsManager
import org.json.JSONArray
import org.json.JSONObject

/**
 * SMS for the Mac: conversation list, one conversation, sending, and a change ping.
 * Reads the system SMS provider (READ_SMS) and sends through SmsManager (SEND_SMS);
 * as a non-default SMS app, Android itself records what we send.
 */
class SmsBridge(private val context: Context) {
    private var observer: ContentObserver? = null

    private fun granted(permission: String) =
        context.checkSelfPermission(permission) == PackageManager.PERMISSION_GRANTED

    private fun missing(type: String) = JSONObject()
        .put("type", type)
        .put("error", "Allow Messages access in the LinkMyMac app on your phone")

    /** Newest message of each conversation, newest conversation first. */
    fun threads(limit: Int): JSONObject {
        if (!granted(Manifest.permission.READ_SMS)) return missing("SMS_THREADS")
        val seen = HashSet<Long>()
        val threads = JSONArray()
        context.contentResolver.query(
            Telephony.Sms.CONTENT_URI,
            arrayOf(Telephony.Sms.THREAD_ID, Telephony.Sms.ADDRESS, Telephony.Sms.BODY,
                Telephony.Sms.DATE, Telephony.Sms.READ, Telephony.Sms.TYPE),
            null, null, "${Telephony.Sms.DATE} DESC"
        )?.use { c ->
            while (c.moveToNext() && threads.length() < limit) {
                val threadId = c.getLong(0)
                if (!seen.add(threadId)) continue
                val address = c.getString(1) ?: ""
                threads.put(JSONObject()
                    .put("threadId", threadId)
                    .put("address", address)
                    .put("name", contactName(address) ?: "")
                    .put("snippet", (c.getString(2) ?: "").take(160))
                    .put("dateMs", c.getLong(3))
                    .put("unread", c.getInt(4) == 0 && c.getInt(5) == Telephony.Sms.MESSAGE_TYPE_INBOX))
            }
        }
        return JSONObject().put("type", "SMS_THREADS").put("threads", threads)
    }

    /** The latest [limit] messages of one conversation, oldest first. */
    fun messages(threadId: Long, limit: Int): JSONObject {
        if (!granted(Manifest.permission.READ_SMS)) return missing("SMS_MESSAGES").put("threadId", threadId)
        val newestFirst = ArrayList<JSONObject>()
        context.contentResolver.query(
            Telephony.Sms.CONTENT_URI,
            arrayOf(Telephony.Sms._ID, Telephony.Sms.BODY, Telephony.Sms.DATE, Telephony.Sms.TYPE),
            "${Telephony.Sms.THREAD_ID} = ?", arrayOf(threadId.toString()),
            "${Telephony.Sms.DATE} DESC"
        )?.use { c ->
            while (c.moveToNext() && newestFirst.size < limit) {
                newestFirst.add(JSONObject()
                    .put("id", c.getLong(0))
                    .put("body", c.getString(1) ?: "")
                    .put("dateMs", c.getLong(2))
                    .put("incoming", c.getInt(3) == Telephony.Sms.MESSAGE_TYPE_INBOX))
            }
        }
        return JSONObject()
            .put("type", "SMS_MESSAGES")
            .put("threadId", threadId)
            .put("messages", JSONArray(newestFirst.asReversed()))
    }

    /** Returns null when the message was handed to the radio, else a reason. */
    fun send(address: String, body: String): String? {
        if (!granted(Manifest.permission.SEND_SMS)) return "Allow Messages access in the LinkMyMac app on your phone"
        if (address.isBlank() || body.isEmpty()) return "Recipient and message are required"
        return try {
            val sms = context.getSystemService(SmsManager::class.java) ?: return "This phone can't send SMS"
            val parts = sms.divideMessage(body)
            if (parts.size > 1) {
                sms.sendMultipartTextMessage(address, null, parts, null, null)
            } else {
                sms.sendTextMessage(address, null, body, null, null)
            }
            null
        } catch (e: Exception) {
            e.message ?: "Send failed"
        }
    }

    /** Tells the Mac to refresh when any SMS arrives, is sent or is read (debounced). */
    fun startObserving(onChange: () -> Unit) {
        if (observer != null || !granted(Manifest.permission.READ_SMS)) return
        val handler = Handler(Looper.getMainLooper())
        val notify = Runnable(onChange)
        observer = object : ContentObserver(handler) {
            override fun onChange(selfChange: Boolean) {
                handler.removeCallbacks(notify)
                handler.postDelayed(notify, 500)
            }
        }.also { context.contentResolver.registerContentObserver(Telephony.Sms.CONTENT_URI, true, it) }
    }

    fun stopObserving() {
        observer?.let { context.contentResolver.unregisterContentObserver(it) }
        observer = null
    }

    /** Contact name for a phone number, if the user allowed contacts access. */
    fun contactName(number: String): String? {
        if (number.isBlank() || !granted(Manifest.permission.READ_CONTACTS)) return null
        return try {
            val uri = Uri.withAppendedPath(ContactsContract.PhoneLookup.CONTENT_FILTER_URI, Uri.encode(number))
            context.contentResolver.query(uri, arrayOf(ContactsContract.PhoneLookup.DISPLAY_NAME), null, null, null)
                ?.use { if (it.moveToFirst()) it.getString(0) else null }
        } catch (_: Exception) {
            null
        }
    }
}
