package de.linktomac.features

import android.app.Activity
import android.content.ClipData
import android.content.ClipboardManager
import android.content.Context
import android.content.Intent
import android.os.Build
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.service.quicksettings.TileService
import android.util.Base64
import android.widget.Toast
import androidx.core.content.FileProvider
import de.linktomac.LinkHub
import de.linktomac.Prefs
import de.linktomac.R
import de.linktomac.net.ClipboardSet
import de.linktomac.net.MsgType
import java.io.File

/**
 * Clipboard sync (F7). Mac -> phone works automatically (apps may write the clipboard in the
 * background). Phone -> Mac needs a user gesture because Android 10+ blocks background reads:
 * Quick Settings tile, share sheet or the button in the app (SPEC §7.4).
 */
object ClipboardBridge {
    private val main = Handler(Looper.getMainLooper())

    /** Text we set ourselves, to avoid echoing it back to the Mac. */
    @Volatile var lastFromMac: String? = null

    fun applyFromMac(context: Context, body: ClipboardSet) {
        if (!Prefs(context).feature("clipboard")) return
        main.post {
            val cm = context.getSystemService(ClipboardManager::class.java) ?: return@post
            try {
                when {
                    body.mime.startsWith("text") && body.text != null -> {
                        lastFromMac = body.text
                        cm.setPrimaryClip(ClipData.newPlainText("Mac", body.text))
                    }
                    body.mime.startsWith("image") && body.dataBase64 != null -> {
                        val dir = File(context.cacheDir, "clipboard").apply { mkdirs() }
                        dir.listFiles()?.forEach { it.delete() }
                        val file = File(dir, "mac-clipboard-${System.currentTimeMillis()}.png")
                        file.writeBytes(Base64.decode(body.dataBase64, Base64.DEFAULT))
                        val uri = FileProvider.getUriForFile(context, context.packageName + ".files", file)
                        cm.setPrimaryClip(ClipData.newUri(context.contentResolver, "Mac", uri))
                    }
                }
            } catch (_: Exception) {
            }
        }
    }

    /** Must be called while one of our activities has focus. */
    fun sendCurrent(context: Context): Boolean {
        val cm = context.getSystemService(ClipboardManager::class.java) ?: return false
        val clip = cm.primaryClip ?: return false
        if (clip.itemCount == 0) return false
        val text = clip.getItemAt(0).coerceToText(context)?.toString() ?: return false
        if (text.isEmpty()) return false
        return sendText(text)
    }

    fun sendText(text: String): Boolean =
        LinkHub.send(MsgType.CLIPBOARD_SET, ClipboardSet(mime = "text/plain", text = text))
}

/** Transparent activity that reads the clipboard once it has window focus, sends it and closes. */
class ClipboardSendActivity : Activity() {
    private var done = false

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        if (Build.VERSION.SDK_INT >= 34) overrideActivityTransition(OVERRIDE_TRANSITION_OPEN, 0, 0)
    }

    override fun onWindowFocusChanged(hasFocus: Boolean) {
        super.onWindowFocusChanged(hasFocus)
        if (!hasFocus || done) return
        done = true
        val msg = when {
            !LinkHub.isConnected -> R.string.clipboard_not_connected
            ClipboardBridge.sendCurrent(this) -> R.string.clipboard_sent
            else -> R.string.clipboard_empty
        }
        Toast.makeText(this, msg, Toast.LENGTH_SHORT).show()
        finish()
    }
}

/** Quick Settings tile "Zwischenablage an Mac". */
class ClipboardTileService : TileService() {
    override fun onStartListening() {
        super.onStartListening()
        qsTile?.let {
            it.state = if (LinkHub.isConnected) android.service.quicksettings.Tile.STATE_ACTIVE else android.service.quicksettings.Tile.STATE_INACTIVE
            it.updateTile()
        }
    }

    @Suppress("DEPRECATION")
    override fun onClick() {
        super.onClick()
        val intent = Intent(this, ClipboardSendActivity::class.java).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        if (Build.VERSION.SDK_INT >= 34) {
            val pi = android.app.PendingIntent.getActivity(this, 0, intent, android.app.PendingIntent.FLAG_IMMUTABLE)
            startActivityAndCollapse(pi)
        } else {
            startActivityAndCollapse(intent)
        }
    }
}
