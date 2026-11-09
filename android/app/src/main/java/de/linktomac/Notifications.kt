package de.linktomac

import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.net.Uri
import androidx.core.app.NotificationCompat
import androidx.core.app.NotificationManagerCompat
import de.linktomac.ui.MainActivity

/** Notification channels and helpers for the phone side. */
object Notifications {
    const val CH_SERVICE = "service"
    const val CH_TRANSFER = "transfer"
    const val CH_EVENTS = "events"

    const val ID_SERVICE = 1
    const val ID_MIRROR_REQUEST = 2
    const val ID_FIND = 3
    const val ID_MIRROR = 4
    private const val ID_TRANSFER_BASE = 1000

    fun createChannels(context: Context) {
        val nm = context.getSystemService(NotificationManager::class.java)
        nm.createNotificationChannel(
            NotificationChannel(CH_SERVICE, context.getString(R.string.channel_service), NotificationManager.IMPORTANCE_MIN),
        )
        nm.createNotificationChannel(
            NotificationChannel(CH_TRANSFER, context.getString(R.string.channel_transfer), NotificationManager.IMPORTANCE_LOW),
        )
        nm.createNotificationChannel(
            NotificationChannel(CH_EVENTS, context.getString(R.string.channel_events), NotificationManager.IMPORTANCE_HIGH),
        )
    }

    fun openAppIntent(context: Context): PendingIntent = PendingIntent.getActivity(
        context, 0, Intent(context, MainActivity::class.java).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK),
        PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
    )

    fun service(context: Context, text: String) = NotificationCompat.Builder(context, CH_SERVICE)
        .setSmallIcon(R.drawable.ic_stat_link)
        .setContentTitle(context.getString(R.string.app_name))
        .setContentText(text)
        .setOngoing(true)
        .setShowWhen(false)
        .setContentIntent(openAppIntent(context))
        .setPriority(NotificationCompat.PRIORITY_MIN)
        .build()

    fun transferId(id: String) = ID_TRANSFER_BASE + (id.hashCode() and 0xffff)

    fun transferProgress(context: Context, id: String, name: String, bytes: Long, size: Long, incoming: Boolean) {
        val pct = if (size > 0) (bytes * 100 / size).toInt() else 0
        val n = NotificationCompat.Builder(context, CH_TRANSFER)
            .setSmallIcon(R.drawable.ic_stat_link)
            .setContentTitle(context.getString(if (incoming) R.string.transfer_receiving else R.string.transfer_sending, name))
            .setProgress(100, pct, false)
            .setOnlyAlertOnce(true)
            .setOngoing(true)
            .build()
        notify(context, transferId(id), n)
    }

    fun transferDone(context: Context, id: String, name: String, ok: Boolean, incoming: Boolean, uri: Uri?, mime: String?) {
        val b = NotificationCompat.Builder(context, CH_TRANSFER)
            .setSmallIcon(R.drawable.ic_stat_link)
            .setAutoCancel(true)
            .setContentTitle(
                context.getString(
                    when {
                        !ok -> R.string.transfer_failed
                        incoming -> R.string.transfer_received
                        else -> R.string.transfer_sent
                    },
                    name,
                ),
            )
        if (ok && incoming && uri != null) {
            val view = Intent(Intent.ACTION_VIEW).setDataAndType(uri, mime ?: "*/*")
                .addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_ACTIVITY_NEW_TASK)
            b.setContentIntent(PendingIntent.getActivity(context, transferId(id), view, PendingIntent.FLAG_IMMUTABLE))
            b.setContentText(context.getString(R.string.transfer_saved_in))
        }
        notify(context, transferId(id), b.build())
    }

    fun notify(context: Context, id: Int, n: android.app.Notification) {
        try {
            NotificationManagerCompat.from(context).notify(id, n)
        } catch (_: SecurityException) {
            // POST_NOTIFICATIONS not granted – nothing we can do.
        }
    }

    fun cancel(context: Context, id: Int) = NotificationManagerCompat.from(context).cancel(id)
}
