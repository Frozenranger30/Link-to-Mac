package de.linktomac.features

import android.Manifest
import android.annotation.SuppressLint
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.content.pm.PackageManager
import android.net.Uri
import android.provider.CallLog
import android.telecom.TelecomManager
import android.telephony.TelephonyManager
import androidx.core.content.ContextCompat
import de.linktomac.LinkHub
import de.linktomac.net.CallEntry
import de.linktomac.net.CallState
import de.linktomac.net.MsgType

/** Call state, answer/reject/dial and call log (F8). Audio stays on the phone (SPEC §7.4). */
class CallBridge(private val context: Context, private val contacts: ContactsBridge) {
    @Volatile var current: CallState = CallState("idle")
        private set
    private var lastNumber: String? = null

    private val receiver = object : BroadcastReceiver() {
        override fun onReceive(c: Context, intent: Intent) {
            val stateExtra = intent.getStringExtra(TelephonyManager.EXTRA_STATE) ?: return
            @Suppress("DEPRECATION")
            val number = intent.getStringExtra(TelephonyManager.EXTRA_INCOMING_NUMBER)
            val state = when (stateExtra) {
                TelephonyManager.EXTRA_STATE_RINGING -> "ringing"
                TelephonyManager.EXTRA_STATE_OFFHOOK -> "offhook"
                else -> "idle"
            }
            if (number != null) lastNumber = number
            if (state == "idle") {
                val n = lastNumber
                lastNumber = null
                update(CallState("idle", n, contacts.nameFor(n)))
            } else {
                val n = number ?: lastNumber
                update(CallState(state, n, contacts.nameFor(n)))
            }
        }
    }

    private fun update(s: CallState) {
        if (s == current) return
        // The system sends the broadcast twice (with and without number); skip the poorer duplicate.
        if (s.state == current.state && s.number == null) return
        current = s
        LinkHub.send(MsgType.CALL_STATE, s)
    }

    fun start() {
        ContextCompat.registerReceiver(
            context, receiver, IntentFilter(TelephonyManager.ACTION_PHONE_STATE_CHANGED), ContextCompat.RECEIVER_EXPORTED,
        )
    }

    fun stop() {
        try {
            context.unregisterReceiver(receiver)
        } catch (_: Exception) {
        }
    }

    private fun has(p: String) = ContextCompat.checkSelfPermission(context, p) == PackageManager.PERMISSION_GRANTED

    /** Returns null on success or an error message. */
    @SuppressLint("MissingPermission")
    @Suppress("DEPRECATION")
    fun action(action: String, number: String?): String? {
        val telecom = context.getSystemService(TelecomManager::class.java) ?: return "Telecom nicht verfügbar"
        return try {
            when (action) {
                "answer" -> {
                    if (!has(Manifest.permission.ANSWER_PHONE_CALLS)) return "Berechtigung „Anrufe annehmen“ fehlt"
                    telecom.acceptRingingCall(); null
                }
                "reject", "hangup" -> {
                    if (!has(Manifest.permission.ANSWER_PHONE_CALLS)) return "Berechtigung „Anrufe annehmen“ fehlt"
                    if (telecom.endCall()) null else "Anruf konnte nicht beendet werden"
                }
                "dial" -> {
                    if (number.isNullOrBlank()) return "Keine Nummer"
                    if (!has(Manifest.permission.CALL_PHONE)) return "Berechtigung „Anrufen“ fehlt"
                    telecom.placeCall(Uri.fromParts("tel", number, null), null); null
                }
                else -> "Unbekannte Aktion"
            }
        } catch (e: SecurityException) {
            e.message ?: "Keine Berechtigung"
        } catch (e: Exception) {
            e.message ?: "Fehler"
        }
    }

    fun callLog(limit: Int): List<CallEntry> {
        if (!has(Manifest.permission.READ_CALL_LOG)) return emptyList()
        val list = mutableListOf<CallEntry>()
        try {
            context.contentResolver.query(
                CallLog.Calls.CONTENT_URI,
                arrayOf(CallLog.Calls._ID, CallLog.Calls.NUMBER, CallLog.Calls.CACHED_NAME, CallLog.Calls.TYPE, CallLog.Calls.DATE, CallLog.Calls.DURATION),
                null, null, CallLog.Calls.DATE + " DESC",
            )?.use { c ->
                while (c.moveToNext() && list.size < limit) {
                    val number = c.getString(1) ?: ""
                    val type = when (c.getInt(3)) {
                        CallLog.Calls.INCOMING_TYPE -> "incoming"
                        CallLog.Calls.OUTGOING_TYPE -> "outgoing"
                        CallLog.Calls.MISSED_TYPE -> "missed"
                        CallLog.Calls.REJECTED_TYPE, CallLog.Calls.BLOCKED_TYPE -> "rejected"
                        else -> "incoming"
                    }
                    list += CallEntry(
                        id = c.getLong(0),
                        number = number,
                        contactName = c.getString(2)?.takeIf { it.isNotBlank() } ?: contacts.nameFor(number),
                        type = type,
                        date = c.getLong(4),
                        duration = c.getLong(5),
                    )
                }
            }
        } catch (_: Exception) {
        }
        return list
    }
}
