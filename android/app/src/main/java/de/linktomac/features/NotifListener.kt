package de.linktomac.features

import android.app.Notification
import android.app.RemoteInput
import android.content.Intent
import android.graphics.Bitmap
import android.graphics.Canvas
import android.graphics.drawable.BitmapDrawable
import android.graphics.drawable.Drawable
import android.os.Bundle
import android.service.notification.NotificationListenerService
import android.service.notification.StatusBarNotification
import android.util.Base64
import de.linktomac.LinkHub
import de.linktomac.Prefs
import de.linktomac.net.MsgType
import de.linktomac.net.NotificationActionInfo
import de.linktomac.net.NotificationKey
import de.linktomac.net.NotificationPosted
import java.io.ByteArrayOutputStream
import java.util.concurrent.ConcurrentHashMap

/** Mirrors phone notifications to the Mac and executes actions/replies from the Mac (F3). */
class NotifListener : NotificationListenerService() {

    private val lastSent = ConcurrentHashMap<String, Int>()

    override fun onListenerConnected() {
        instance = this
        MediaBridge.instance?.refreshSessions()
    }

    override fun onListenerDisconnected() {
        if (instance === this) instance = null
    }

    override fun onDestroy() {
        if (instance === this) instance = null
        super.onDestroy()
    }

    override fun onNotificationPosted(sbn: StatusBarNotification) {
        if (!LinkHub.isConnected || !Prefs(this).feature("notifications")) return
        val posted = convert(sbn) ?: return
        val hash = posted.copy(appIconPng = null, time = 0).hashCode()
        if (lastSent[sbn.key] == hash) return
        lastSent[sbn.key] = hash
        LinkHub.send(MsgType.NOTIFICATION_POSTED, posted)
    }

    override fun onNotificationRemoved(sbn: StatusBarNotification) {
        if (lastSent.remove(sbn.key) != null) {
            LinkHub.send(MsgType.NOTIFICATION_REMOVED, NotificationKey(sbn.key))
        }
    }

    /** Sends all currently visible notifications (after a new connection). */
    fun sendAll() {
        sentIcons.clear()
        lastSent.clear()
        if (!Prefs(this).feature("notifications")) return
        val active = try {
            activeNotifications
        } catch (e: Exception) {
            null
        } ?: return
        active.sortedBy { it.postTime }.forEach { onNotificationPosted(it) }
    }

    private fun convert(sbn: StatusBarNotification): NotificationPosted? {
        if (sbn.packageName == packageName) return null
        val n = sbn.notification
        if (sbn.isOngoing) return null
        if (n.flags and Notification.FLAG_GROUP_SUMMARY != 0) return null
        val extras: Bundle = n.extras
        val title = extras.getCharSequence(Notification.EXTRA_TITLE)?.toString()
            ?: extras.getCharSequence(Notification.EXTRA_TITLE_BIG)?.toString() ?: ""
        val text = extras.getCharSequence(Notification.EXTRA_BIG_TEXT)?.toString()
            ?: extras.getCharSequence(Notification.EXTRA_TEXT)?.toString() ?: ""
        if (title.isBlank() && text.isBlank()) return null

        val actions = n.actions.orEmpty().map { a ->
            NotificationActionInfo(a.title?.toString() ?: "", a.remoteInputs?.any { it.allowFreeFormInput } == true)
        }
        val pm = packageManager
        val appName = try {
            pm.getApplicationLabel(pm.getApplicationInfo(sbn.packageName, 0)).toString()
        } catch (e: Exception) {
            sbn.packageName
        }
        val icon = if (sentIcons.add(sbn.packageName)) appIcon(sbn.packageName) else null
        return NotificationPosted(
            key = sbn.key,
            app = sbn.packageName,
            appName = appName,
            appIconPng = icon,
            title = title,
            text = text,
            time = sbn.postTime,
            actions = actions,
            canReply = actions.any { it.isReply },
        )
    }

    private fun appIcon(pkg: String): String? = try {
        val d = packageManager.getApplicationIcon(pkg)
        val bmp = drawableToBitmap(d, 96)
        val out = ByteArrayOutputStream()
        bmp.compress(Bitmap.CompressFormat.PNG, 100, out)
        Base64.encodeToString(out.toByteArray(), Base64.NO_WRAP)
    } catch (e: Exception) {
        null
    }

    /** Returns null on success or an error message. */
    fun performAction(key: String, index: Int, reply: String?): String? {
        val sbn = activeNotifications?.firstOrNull { it.key == key } ?: return "Mitteilung nicht mehr vorhanden"
        val action = sbn.notification.actions?.getOrNull(index) ?: return "Aktion nicht gefunden"
        return try {
            val inputs = action.remoteInputs
            if (inputs != null && inputs.isNotEmpty() && reply != null) {
                val intent = Intent()
                val results = Bundle()
                inputs.forEach { results.putCharSequence(it.resultKey, reply) }
                RemoteInput.addResultsToIntent(inputs, intent, results)
                action.actionIntent.send(this, 0, intent)
            } else {
                action.actionIntent.send()
            }
            null
        } catch (e: Exception) {
            e.message ?: "Aktion fehlgeschlagen"
        }
    }

    fun dismiss(key: String) {
        lastSent.remove(key)
        try {
            cancelNotification(key)
        } catch (_: Exception) {
        }
    }

    fun dismissAll() {
        lastSent.clear()
        try {
            cancelAllNotifications()
        } catch (_: Exception) {
        }
    }

    companion object {
        @Volatile var instance: NotifListener? = null
            private set
        private val sentIcons = ConcurrentHashMap.newKeySet<String>()

        fun drawableToBitmap(d: Drawable, size: Int): Bitmap {
            if (d is BitmapDrawable && d.bitmap != null) {
                return Bitmap.createScaledBitmap(d.bitmap, size, size, true)
            }
            val bmp = Bitmap.createBitmap(size, size, Bitmap.Config.ARGB_8888)
            val c = Canvas(bmp)
            d.setBounds(0, 0, size, size)
            d.draw(c)
            return bmp
        }
    }
}
