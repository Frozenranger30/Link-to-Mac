package de.linktomac.features

import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.media.AudioAttributes
import android.media.AudioManager
import android.media.MediaPlayer
import android.media.RingtoneManager
import android.os.Handler
import android.os.Looper
import android.os.VibrationEffect
import android.os.Vibrator
import androidx.core.app.NotificationCompat
import de.linktomac.LinkService
import de.linktomac.Notifications
import de.linktomac.R

/** "Handy finden" (F10): rings at full alarm volume, also in silent mode. */
class FindPhone(private val context: Context) {
    private var player: MediaPlayer? = null
    private var previousVolume = -1
    private val handler = Handler(Looper.getMainLooper())
    private val stopRunnable = Runnable { stopRinging() }

    fun ring() {
        handler.post { startRinging() }
    }

    fun stop() {
        handler.post { stopRinging() }
    }

    private fun startRinging() {
        if (player != null) return
        val audio = context.getSystemService(AudioManager::class.java)
        previousVolume = audio.getStreamVolume(AudioManager.STREAM_ALARM)
        try {
            audio.setStreamVolume(AudioManager.STREAM_ALARM, audio.getStreamMaxVolume(AudioManager.STREAM_ALARM), 0)
        } catch (_: Exception) {
        }
        val uri = RingtoneManager.getDefaultUri(RingtoneManager.TYPE_ALARM)
            ?: RingtoneManager.getDefaultUri(RingtoneManager.TYPE_RINGTONE)
        player = try {
            MediaPlayer().apply {
                setAudioAttributes(
                    AudioAttributes.Builder()
                        .setUsage(AudioAttributes.USAGE_ALARM)
                        .setContentType(AudioAttributes.CONTENT_TYPE_SONIFICATION)
                        .build(),
                )
                setDataSource(context, uri)
                isLooping = true
                prepare()
                start()
            }
        } catch (e: Exception) {
            null
        }
        context.getSystemService(Vibrator::class.java)?.vibrate(
            VibrationEffect.createWaveform(longArrayOf(0, 800, 400), 0),
        )
        val stopIntent = PendingIntent.getService(
            context, 3,
            Intent(context, LinkService::class.java).setAction(LinkService.ACTION_STOP_RING),
            PendingIntent.FLAG_IMMUTABLE,
        )
        val n = NotificationCompat.Builder(context, Notifications.CH_EVENTS)
            .setSmallIcon(R.drawable.ic_stat_link)
            .setContentTitle(context.getString(R.string.find_title))
            .setContentText(context.getString(R.string.find_text))
            .setPriority(NotificationCompat.PRIORITY_HIGH)
            .setCategory(NotificationCompat.CATEGORY_ALARM)
            .setContentIntent(stopIntent)
            .addAction(0, context.getString(R.string.find_stop), stopIntent)
            .setAutoCancel(true)
            .build()
        Notifications.notify(context, Notifications.ID_FIND, n)
        handler.postDelayed(stopRunnable, 45_000)
    }

    private fun stopRinging() {
        handler.removeCallbacks(stopRunnable)
        player?.let {
            try {
                it.stop()
            } catch (_: Exception) {
            }
            it.release()
        }
        player = null
        context.getSystemService(Vibrator::class.java)?.cancel()
        if (previousVolume >= 0) {
            try {
                context.getSystemService(AudioManager::class.java)
                    .setStreamVolume(AudioManager.STREAM_ALARM, previousVolume, 0)
            } catch (_: Exception) {
            }
            previousVolume = -1
        }
        Notifications.cancel(context, Notifications.ID_FIND)
    }
}
