package de.linktomac.features

import android.content.ComponentName
import android.content.Context
import android.graphics.Bitmap
import android.media.MediaMetadata
import android.media.session.MediaController
import android.media.session.MediaSessionManager
import android.media.session.PlaybackState
import android.os.Handler
import android.os.Looper
import android.util.Base64
import de.linktomac.LinkHub
import de.linktomac.Prefs
import de.linktomac.net.MediaState
import de.linktomac.net.MsgType
import java.io.ByteArrayOutputStream

/** Now-playing info and remote control (F11). Requires notification access. */
class MediaBridge(private val context: Context) {
    private val handler = Handler(Looper.getMainLooper())
    private var controller: MediaController? = null
    private var lastState: MediaState? = null
    private var lastArtKey: String? = null

    private val sessionListener = MediaSessionManager.OnActiveSessionsChangedListener { list -> pick(list) }

    private val callback = object : MediaController.Callback() {
        override fun onPlaybackStateChanged(state: PlaybackState?) = publish()
        override fun onMetadataChanged(metadata: MediaMetadata?) = publish()
        override fun onSessionDestroyed() = refreshSessions()
    }

    fun start() {
        instance = this
        refreshSessions()
    }

    fun stop() {
        if (instance === this) instance = null
        val msm = context.getSystemService(MediaSessionManager::class.java)
        try {
            msm?.removeOnActiveSessionsChangedListener(sessionListener)
        } catch (_: Exception) {
        }
        controller?.unregisterCallback(callback)
        controller = null
    }

    fun refreshSessions() {
        handler.post {
            val msm = context.getSystemService(MediaSessionManager::class.java) ?: return@post
            val comp = ComponentName(context, NotifListener::class.java)
            try {
                msm.removeOnActiveSessionsChangedListener(sessionListener)
                msm.addOnActiveSessionsChangedListener(sessionListener, comp, handler)
                pick(msm.getActiveSessions(comp))
            } catch (e: SecurityException) {
                // Notification access not granted.
            }
        }
    }

    private fun pick(list: List<MediaController>?) {
        val best = list?.firstOrNull { it.playbackState?.state == PlaybackState.STATE_PLAYING } ?: list?.firstOrNull()
        if (best?.sessionToken != controller?.sessionToken) {
            controller?.unregisterCallback(callback)
            controller = best
            best?.registerCallback(callback, handler)
        }
        publish()
    }

    fun current(): MediaState {
        val c = controller ?: return MediaState(active = false)
        val md = c.metadata
        val playing = c.playbackState?.state == PlaybackState.STATE_PLAYING
        val title = md?.getString(MediaMetadata.METADATA_KEY_TITLE)
        val artist = md?.getString(MediaMetadata.METADATA_KEY_ARTIST) ?: md?.getString(MediaMetadata.METADATA_KEY_ALBUM_ARTIST)
        val appName = try {
            val pm = context.packageManager
            pm.getApplicationLabel(pm.getApplicationInfo(c.packageName, 0)).toString()
        } catch (e: Exception) {
            c.packageName
        }
        val artKey = "$title|$artist"
        val art = if (artKey != lastArtKey) {
            lastArtKey = artKey
            (md?.getBitmap(MediaMetadata.METADATA_KEY_ALBUM_ART) ?: md?.getBitmap(MediaMetadata.METADATA_KEY_ART))?.let { encodeArt(it) }
        } else {
            null
        }
        return MediaState(true, playing, title, artist, c.packageName, appName, art)
    }

    fun publish() {
        if (!LinkHub.isConnected || !Prefs(context).feature("media")) return
        val s = current()
        val cmp = s.copy(artPng = null)
        if (cmp == lastState?.copy(artPng = null) && s.artPng == null) return
        lastState = s
        LinkHub.send(MsgType.MEDIA_STATE, s)
    }

    fun resend() {
        lastState = null
        lastArtKey = null
        publish()
    }

    fun action(action: String) {
        val t = controller?.transportControls ?: return
        handler.post {
            when (action) {
                "play" -> t.play()
                "pause" -> t.pause()
                "toggle" -> if (controller?.playbackState?.state == PlaybackState.STATE_PLAYING) t.pause() else t.play()
                "next" -> t.skipToNext()
                "previous" -> t.skipToPrevious()
            }
        }
    }

    private fun encodeArt(bmp: Bitmap): String? = try {
        val scaled = Bitmap.createScaledBitmap(bmp, 128, 128, true)
        val out = ByteArrayOutputStream()
        scaled.compress(Bitmap.CompressFormat.PNG, 100, out)
        Base64.encodeToString(out.toByteArray(), Base64.NO_WRAP)
    } catch (e: Exception) {
        null
    }

    companion object {
        @Volatile var instance: MediaBridge? = null
    }
}
