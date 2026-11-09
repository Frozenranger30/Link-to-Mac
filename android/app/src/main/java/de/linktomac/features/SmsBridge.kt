package de.linktomac.features

import android.Manifest
import android.app.Activity
import android.app.PendingIntent
import android.content.BroadcastReceiver
import android.content.ContentValues
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.content.pm.PackageManager
import android.database.ContentObserver
import android.os.Build
import android.os.Handler
import android.os.HandlerThread
import android.provider.Telephony
import android.telephony.SmsManager
import androidx.core.content.ContextCompat
import de.linktomac.LinkHub
import de.linktomac.net.MsgType
import de.linktomac.net.SmsMessage
import de.linktomac.net.SmsReceived
import de.linktomac.net.SmsSent
import de.linktomac.net.SmsThread
import java.util.concurrent.atomic.AtomicInteger

/** Reads SMS from the Telephony provider, watches for new ones and sends SMS (F4). */
class SmsBridge(private val context: Context, private val contacts: ContactsBridge) {
    private val thread = HandlerThread("sms-observer").apply { start() }
    private val handler = Handler(thread.looper)
    @Volatile private var lastId = -1L
    private var registered = false
    private val requestCodes = AtomicInteger(1000)

    private val observer = object : ContentObserver(handler) {
        override fun onChange(selfChange: Boolean) = checkNew()
    }

    private val sentReceiver = object : BroadcastReceiver() {
        override fun onReceive(c: Context, intent: Intent) {
            val replyTo = intent.getStringExtra(EXTRA_REPLY_TO)
            val ok = resultCode == Activity.RESULT_OK
            LinkHub.send(MsgType.SMS_SENT, SmsSent(ok, if (ok) null else "Fehlercode $resultCode"), replyTo)
        }
    }

    fun allowed() =
        ContextCompat.checkSelfPermission(context, Manifest.permission.READ_SMS) == PackageManager.PERMISSION_GRANTED

    fun start() {
        ContextCompat.registerReceiver(context, sentReceiver, IntentFilter(ACTION_SENT), ContextCompat.RECEIVER_NOT_EXPORTED)
        tryRegisterObserver()
    }

    fun tryRegisterObserver() {
        if (registered || !allowed()) return
        lastId = maxId()
        context.contentResolver.registerContentObserver(Telephony.Sms.CONTENT_URI, true, observer)
        registered = true
    }

    fun stop() {
        try {
            context.unregisterReceiver(sentReceiver)
        } catch (_: Exception) {
        }
        if (registered) context.contentResolver.unregisterContentObserver(observer)
        registered = false
        thread.quitSafely()
    }

    private fun maxId(): Long = try {
        context.contentResolver.query(
            Telephony.Sms.CONTENT_URI, arrayOf(Telephony.Sms._ID), null, null, Telephony.Sms._ID + " DESC",
        )?.use { c -> if (c.moveToFirst()) c.getLong(0) else 0L } ?: 0L
    } catch (e: Exception) {
        0L
    }

    private fun checkNew() {
        if (!allowed()) return
        val since = lastId
        val news = query("${Telephony.Sms._ID} > ?", arrayOf(since.toString()), Telephony.Sms._ID + " ASC", 50)
        for (m in news) {
            if (m.id > lastId) lastId = m.id
            // Only fully stored messages (type inbox or sent).
            if (LinkHub.isConnected) {
                LinkHub.send(MsgType.SMS_RECEIVED, SmsReceived(m, contacts.nameFor(m.address)))
            }
        }
    }

    fun threads(limit: Int): List<SmsThread> {
        if (!allowed()) return emptyList()
        val result = LinkedHashMap<Long, SmsThread>()
        val unread = HashMap<Long, Int>()
        context.contentResolver.query(
            Telephony.Sms.CONTENT_URI,
            arrayOf(Telephony.Sms.THREAD_ID, Telephony.Sms.ADDRESS, Telephony.Sms.BODY, Telephony.Sms.DATE, Telephony.Sms.READ, Telephony.Sms.TYPE),
            null, null, Telephony.Sms.DATE + " DESC",
        )?.use { c ->
            var rows = 0
            while (c.moveToNext() && rows < 20_000) {
                rows++
                val tid = c.getLong(0)
                val read = c.getInt(4) != 0
                val type = c.getInt(5)
                if (!read && type == Telephony.Sms.MESSAGE_TYPE_INBOX) unread[tid] = (unread[tid] ?: 0) + 1
                if (tid !in result && result.size < limit) {
                    val address = c.getString(1) ?: ""
                    result[tid] = SmsThread(
                        threadId = tid,
                        address = address,
                        contactName = null,
                        snippet = c.getString(2) ?: "",
                        date = c.getLong(3),
                        unread = 0,
                    )
                }
            }
        }
        return result.values.map { it.copy(unread = unread[it.threadId] ?: 0, contactName = contacts.nameFor(it.address)) }
    }

    fun messages(threadId: Long, before: Long?, limit: Int): List<SmsMessage> {
        if (!allowed()) return emptyList()
        val sel = StringBuilder("${Telephony.Sms.THREAD_ID} = ?")
        val args = mutableListOf(threadId.toString())
        if (before != null) {
            sel.append(" AND ${Telephony.Sms.DATE} < ?")
            args += before.toString()
        }
        return query(sel.toString(), args.toTypedArray(), Telephony.Sms.DATE + " DESC", limit).reversed()
    }

    private fun query(selection: String, args: Array<String>, order: String, limit: Int): List<SmsMessage> {
        val list = mutableListOf<SmsMessage>()
        try {
            context.contentResolver.query(
                Telephony.Sms.CONTENT_URI,
                arrayOf(Telephony.Sms._ID, Telephony.Sms.THREAD_ID, Telephony.Sms.ADDRESS, Telephony.Sms.BODY, Telephony.Sms.DATE, Telephony.Sms.TYPE, Telephony.Sms.READ),
                selection, args, order,
            )?.use { c ->
                while (c.moveToNext() && list.size < limit) {
                    val type = c.getInt(5)
                    if (type != Telephony.Sms.MESSAGE_TYPE_INBOX && type != Telephony.Sms.MESSAGE_TYPE_SENT) continue
                    list += SmsMessage(
                        id = c.getLong(0),
                        threadId = c.getLong(1),
                        address = c.getString(2) ?: "",
                        body = c.getString(3) ?: "",
                        date = c.getLong(4),
                        outgoing = type == Telephony.Sms.MESSAGE_TYPE_SENT,
                        read = c.getInt(6) != 0,
                    )
                }
            }
        } catch (_: Exception) {
        }
        return list
    }

    fun send(address: String, text: String, replyTo: String) {
        if (ContextCompat.checkSelfPermission(context, Manifest.permission.SEND_SMS) != PackageManager.PERMISSION_GRANTED) {
            LinkHub.send(MsgType.SMS_SENT, SmsSent(false, "Berechtigung „SMS senden“ fehlt"), replyTo)
            return
        }
        try {
            val sms = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
                context.getSystemService(SmsManager::class.java)
            } else {
                @Suppress("DEPRECATION") SmsManager.getDefault()
            }
            val parts = sms.divideMessage(text)
            val intent = Intent(ACTION_SENT).setPackage(context.packageName).putExtra(EXTRA_REPLY_TO, replyTo)
            val sentPi = PendingIntent.getBroadcast(
                context, requestCodes.incrementAndGet(), intent,
                PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
            )
            val sentIntents = ArrayList<PendingIntent?>(parts.size).apply {
                repeat(parts.size) { i -> add(if (i == parts.size - 1) sentPi else null) }
            }
            sms.sendMultipartTextMessage(address, null, parts, sentIntents, null)
        } catch (e: Exception) {
            LinkHub.send(MsgType.SMS_SENT, SmsSent(false, e.message ?: "Senden fehlgeschlagen"), replyTo)
        }
    }

    /** Marking as read only works for the default SMS app; we try and ignore failures. */
    fun markRead(threadId: Long) {
        try {
            val values = ContentValues().apply { put(Telephony.Sms.READ, 1) }
            context.contentResolver.update(Telephony.Sms.CONTENT_URI, values, "${Telephony.Sms.THREAD_ID} = ? AND ${Telephony.Sms.READ} = 0", arrayOf(threadId.toString()))
        } catch (_: Exception) {
        }
    }

    companion object {
        const val ACTION_SENT = "de.linktomac.SMS_SENT"
        const val EXTRA_REPLY_TO = "replyTo"
    }
}
