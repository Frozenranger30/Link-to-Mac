package de.linktomac.features

import android.app.Activity
import android.content.Intent
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.provider.OpenableColumns
import android.widget.Toast
import de.linktomac.LinkHub
import de.linktomac.LinkService
import de.linktomac.R
import java.io.File
import java.util.UUID
import kotlin.concurrent.thread

/** Share target "Link to Mac": sends text to the Mac clipboard and files to the Mac (F6/F7). */
class ShareActivity : Activity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        if (!LinkHub.isConnected) {
            Toast.makeText(this, R.string.clipboard_not_connected, Toast.LENGTH_LONG).show()
            finish()
            return
        }
        val uris = extractUris(intent)
        val text = intent.getStringExtra(Intent.EXTRA_TEXT)
        if (uris.isEmpty() && text != null) {
            ClipboardBridge.sendText(text)
            Toast.makeText(this, R.string.clipboard_sent, Toast.LENGTH_SHORT).show()
            finish()
            return
        }
        if (uris.isEmpty()) {
            finish()
            return
        }
        // Copy into our cache first: URI grants end when this activity finishes.
        val appCtx = applicationContext
        val copies = uris.mapNotNull { uri -> copyToCache(uri) }
        Toast.makeText(this, getString(R.string.share_sending, copies.size), Toast.LENGTH_SHORT).show()
        finish()
        thread(name = "share-offer") {
            val files = LinkService.instance?.files ?: return@thread
            for ((file, name, mime) in copies) files.offerFile(file, name, mime, deleteAfter = true)
            if (copies.isEmpty()) {
                android.os.Handler(appCtx.mainLooper).post {
                    Toast.makeText(appCtx, R.string.share_failed, Toast.LENGTH_SHORT).show()
                }
            }
        }
    }

    private fun copyToCache(uri: Uri): Triple<File, String, String>? = try {
        var name = "Datei"
        contentResolver.query(uri, arrayOf(OpenableColumns.DISPLAY_NAME), null, null, null)?.use { c ->
            if (c.moveToFirst() && !c.isNull(0)) name = c.getString(0)
        }
        val mime = contentResolver.getType(uri) ?: "application/octet-stream"
        val dir = File(cacheDir, "outgoing").apply { mkdirs() }
        val file = File(dir, UUID.randomUUID().toString())
        contentResolver.openInputStream(uri)?.use { input -> file.outputStream().use { input.copyTo(it, 64 * 1024) } }
        Triple(file, FileBridge.sanitize(name), mime)
    } catch (e: Exception) {
        null
    }

    @Suppress("DEPRECATION")
    private fun extractUris(intent: Intent): List<Uri> = when (intent.action) {
        Intent.ACTION_SEND -> listOfNotNull(
            if (Build.VERSION.SDK_INT >= 33) intent.getParcelableExtra(Intent.EXTRA_STREAM, Uri::class.java)
            else intent.getParcelableExtra(Intent.EXTRA_STREAM),
        )
        Intent.ACTION_SEND_MULTIPLE ->
            (if (Build.VERSION.SDK_INT >= 33) intent.getParcelableArrayListExtra(Intent.EXTRA_STREAM, Uri::class.java)
            else intent.getParcelableArrayListExtra(Intent.EXTRA_STREAM)) ?: emptyList()
        else -> emptyList()
    }
}
