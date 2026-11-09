package de.linktomac.features

import android.content.ContentValues
import android.content.Context
import android.net.Uri
import android.os.Environment
import android.provider.MediaStore
import android.provider.OpenableColumns
import android.util.Log
import de.linktomac.LinkHub
import de.linktomac.Notifications
import de.linktomac.Prefs
import de.linktomac.net.ChannelHeader
import de.linktomac.net.FileDone
import de.linktomac.net.FileOffer
import de.linktomac.net.FileProgress
import de.linktomac.net.FileReply
import de.linktomac.net.Frames
import de.linktomac.net.MsgType
import de.linktomac.net.ProtocolJson
import de.linktomac.net.toHex
import java.io.BufferedInputStream
import java.io.BufferedOutputStream
import java.io.File
import java.io.InputStream
import java.security.MessageDigest
import java.util.UUID
import java.util.concurrent.ConcurrentHashMap
import javax.net.ssl.SSLSocket

/** File transfers in both directions over the data channel (F5/F6, PROTOCOL.md §5). */
class FileBridge(private val context: Context) {
    private val prefs = Prefs(context)

    private class Outgoing(
        val offer: FileOffer,
        val open: () -> InputStream?,
        val cleanup: File?,
    )

    private val outgoing = ConcurrentHashMap<String, Outgoing>()
    private val incoming = ConcurrentHashMap<String, FileOffer>()

    // ---- Phone -> Mac -----------------------------------------------------------------

    /** Offers a local file (e.g. copied from a share intent) to the Mac. */
    fun offerFile(file: File, name: String, mime: String, deleteAfter: Boolean): Boolean {
        val sha = file.inputStream().use { digest(it) }
        val offer = FileOffer(UUID.randomUUID().toString(), name, file.length(), mime, sha)
        outgoing[offer.transferId] = Outgoing(offer, { file.inputStream() }, if (deleteAfter) file else null)
        return LinkHub.send(MsgType.FILE_OFFER, offer)
    }

    /** Offers a content URI (photo download). Blocking: computes the hash. */
    fun offerUri(uri: Uri, name: String, mime: String, transferId: String, purpose: String): Boolean {
        val resolver = context.contentResolver
        val sha = resolver.openInputStream(uri)?.use { digest(it) } ?: return false
        val size = querySize(uri) ?: resolver.openInputStream(uri)?.use { countBytes(it) } ?: return false
        val offer = FileOffer(transferId, name, size, mime, sha, purpose)
        outgoing[transferId] = Outgoing(offer, { resolver.openInputStream(uri) }, null)
        return LinkHub.send(MsgType.FILE_OFFER, offer)
    }

    fun onRemoteReject(id: String) {
        outgoing.remove(id)?.cleanup?.delete()
    }

    fun onRemoteDone(done: FileDone) {
        val o = outgoing.remove(done.transferId) ?: return
        o.cleanup?.delete()
        if (o.offer.purpose == "file") {
            Notifications.transferDone(context, done.transferId, o.offer.name, done.ok, incoming = false, uri = null, mime = null)
        }
    }

    // ---- Mac -> Phone -----------------------------------------------------------------

    fun onOffer(offer: FileOffer, replyTo: String) {
        if (!prefs.feature("files")) {
            LinkHub.send(MsgType.FILE_REJECT, FileReply(offer.transferId, "feature_disabled"), replyTo)
            return
        }
        incoming[offer.transferId] = offer
        LinkHub.send(MsgType.FILE_ACCEPT, FileReply(offer.transferId), replyTo)
    }

    // ---- Data channel -----------------------------------------------------------------

    /** Handles one accepted socket on port 47801. Blocking, call on an IO thread. */
    fun handleDataConnection(socket: SSLSocket) {
        socket.use { s ->
            try {
                s.soTimeout = 60_000
                s.startHandshake()
                val input = BufferedInputStream(s.getInputStream(), 256 * 1024)
                val header = ProtocolJson.decodeFromString(ChannelHeader.serializer(), String(Frames.read(input), Charsets.UTF_8))
                val token = LinkHub.sessionToken
                if (token == null || header.sessionToken != token) {
                    Log.w(TAG, "data connection with invalid session token")
                    return
                }
                val id = header.transferId ?: return
                when (header.direction) {
                    "upload" -> receive(id, input)
                    "download" -> sendData(id, BufferedOutputStream(s.getOutputStream(), 256 * 1024))
                }
            } catch (e: Exception) {
                Log.w(TAG, "data connection failed: ${e.message}")
            }
        }
    }

    private fun sendData(id: String, out: BufferedOutputStream) {
        val o = outgoing[id] ?: return
        val buf = ByteArray(CHUNK)
        var sent = 0L
        var lastNotify = 0L
        o.open()?.use { input ->
            while (true) {
                val n = input.read(buf)
                if (n < 0) break
                out.write(buf, 0, n)
                sent += n
                val now = System.currentTimeMillis()
                if (o.offer.purpose == "file" && now - lastNotify > 500) {
                    lastNotify = now
                    Notifications.transferProgress(context, id, o.offer.name, sent, o.offer.size, incoming = false)
                }
            }
        }
        out.flush()
    }

    private fun receive(id: String, input: InputStream) {
        val offer = incoming.remove(id) ?: return
        val resolver = context.contentResolver
        val values = ContentValues().apply {
            put(MediaStore.Downloads.DISPLAY_NAME, sanitize(offer.name))
            put(MediaStore.Downloads.MIME_TYPE, offer.mime.ifBlank { "application/octet-stream" })
            put(MediaStore.Downloads.RELATIVE_PATH, Environment.DIRECTORY_DOWNLOADS + "/LinkToMac")
            put(MediaStore.Downloads.IS_PENDING, 1)
        }
        val uri = resolver.insert(MediaStore.Downloads.EXTERNAL_CONTENT_URI, values)
        if (uri == null) {
            LinkHub.send(MsgType.FILE_DONE, FileDone(id, false, "Speichern nicht möglich"))
            return
        }
        val md = MessageDigest.getInstance("SHA-256")
        var received = 0L
        var lastProgress = 0L
        val buf = ByteArray(CHUNK)
        var error: String? = null
        try {
            resolver.openOutputStream(uri)?.use { out ->
                while (received < offer.size) {
                    val want = minOf(buf.size.toLong(), offer.size - received).toInt()
                    val n = input.read(buf, 0, want)
                    if (n < 0) break
                    out.write(buf, 0, n)
                    md.update(buf, 0, n)
                    received += n
                    val now = System.currentTimeMillis()
                    if (now - lastProgress > 400) {
                        lastProgress = now
                        LinkHub.send(MsgType.FILE_PROGRESS, FileProgress(id, received, offer.size))
                        Notifications.transferProgress(context, id, offer.name, received, offer.size, incoming = true)
                    }
                }
            }
            if (received != offer.size) error = "Übertragung unvollständig"
            else if (md.digest().toHex() != offer.sha256.lowercase()) error = "Prüfsumme falsch"
        } catch (e: Exception) {
            error = e.message ?: "Fehler beim Speichern"
        }
        if (error == null) {
            resolver.update(uri, ContentValues().apply { put(MediaStore.Downloads.IS_PENDING, 0) }, null, null)
        } else {
            resolver.delete(uri, null, null)
        }
        LinkHub.send(MsgType.FILE_DONE, FileDone(id, error == null, error))
        Notifications.transferDone(context, id, offer.name, error == null, incoming = true, uri = uri.takeIf { error == null }, mime = offer.mime)
    }

    fun clear() {
        outgoing.values.forEach { it.cleanup?.delete() }
        outgoing.clear()
        incoming.clear()
    }

    private fun querySize(uri: Uri): Long? = try {
        context.contentResolver.query(uri, arrayOf(OpenableColumns.SIZE), null, null, null)?.use { c ->
            if (c.moveToFirst() && !c.isNull(0)) c.getLong(0).takeIf { it > 0 } else null
        }
    } catch (e: Exception) {
        null
    }

    companion object {
        private const val TAG = "FileBridge"
        const val CHUNK = 64 * 1024

        fun digest(input: InputStream): String {
            val md = MessageDigest.getInstance("SHA-256")
            val buf = ByteArray(CHUNK)
            while (true) {
                val n = input.read(buf)
                if (n < 0) break
                md.update(buf, 0, n)
            }
            return md.digest().toHex()
        }

        private fun countBytes(input: InputStream): Long {
            val buf = ByteArray(CHUNK)
            var total = 0L
            while (true) {
                val n = input.read(buf)
                if (n < 0) break
                total += n
            }
            return total
        }

        fun sanitize(name: String): String =
            name.replace(Regex("[\\\\/:*?\"<>|\\u0000]"), "_").trim().ifBlank { "Datei" }.take(200)
    }
}
