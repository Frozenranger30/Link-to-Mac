package de.linktomac.features

import android.Manifest
import android.content.ContentUris
import android.content.Context
import android.content.pm.PackageManager
import android.graphics.Bitmap
import android.net.Uri
import android.os.Build
import android.provider.MediaStore
import android.util.Base64
import android.util.Size
import androidx.core.content.ContextCompat
import de.linktomac.net.PhotoInfo
import de.linktomac.net.Photos
import java.io.ByteArrayOutputStream

/** Recent photos and screenshots from MediaStore (F5). */
class PhotosBridge(private val context: Context) {

    fun allowed(): Boolean {
        val perm = if (Build.VERSION.SDK_INT >= 33) Manifest.permission.READ_MEDIA_IMAGES else Manifest.permission.READ_EXTERNAL_STORAGE
        if (ContextCompat.checkSelfPermission(context, perm) == PackageManager.PERMISSION_GRANTED) return true
        // Android 14 "selected photos only" access.
        return Build.VERSION.SDK_INT >= 34 &&
            ContextCompat.checkSelfPermission(context, "android.permission.READ_MEDIA_VISUAL_USER_SELECTED") == PackageManager.PERMISSION_GRANTED
    }

    data class Item(val uri: Uri, val name: String, val mime: String, val size: Long)

    fun list(offset: Int, limit: Int): Photos {
        if (!allowed()) return Photos(offset, 0, emptyList())
        val result = mutableListOf<PhotoInfo>()
        var total = 0
        context.contentResolver.query(
            MediaStore.Images.Media.EXTERNAL_CONTENT_URI,
            arrayOf(
                MediaStore.Images.Media._ID,
                MediaStore.Images.Media.DATE_TAKEN,
                MediaStore.Images.Media.DATE_ADDED,
                MediaStore.Images.Media.WIDTH,
                MediaStore.Images.Media.HEIGHT,
                MediaStore.Images.Media.DISPLAY_NAME,
                MediaStore.Images.Media.MIME_TYPE,
            ),
            null, null, MediaStore.Images.Media.DATE_ADDED + " DESC",
        )?.use { c ->
            total = minOf(c.count, MAX_PHOTOS)
            if (offset < total && c.moveToPosition(offset)) {
                do {
                    val id = c.getLong(0)
                    val uri = ContentUris.withAppendedId(MediaStore.Images.Media.EXTERNAL_CONTENT_URI, id)
                    val taken = c.getLong(1).takeIf { it > 0 } ?: (c.getLong(2) * 1000)
                    val thumb = thumbnail(uri) ?: continue
                    result += PhotoInfo(
                        id = id,
                        date = taken,
                        width = c.getInt(3),
                        height = c.getInt(4),
                        name = c.getString(5) ?: "IMG_$id.jpg",
                        mime = c.getString(6) ?: "image/jpeg",
                        thumbJpeg = thumb,
                    )
                } while (result.size < limit && c.position + 1 < total && c.moveToNext())
            }
        }
        return Photos(offset, total, result)
    }

    private fun thumbnail(uri: Uri): String? = try {
        val bmp = context.contentResolver.loadThumbnail(uri, Size(256, 256), null)
        val out = ByteArrayOutputStream()
        bmp.compress(Bitmap.CompressFormat.JPEG, 75, out)
        bmp.recycle()
        Base64.encodeToString(out.toByteArray(), Base64.NO_WRAP)
    } catch (e: Exception) {
        null
    }

    fun item(id: Long): Item? {
        if (!allowed()) return null
        val uri = ContentUris.withAppendedId(MediaStore.Images.Media.EXTERNAL_CONTENT_URI, id)
        return context.contentResolver.query(
            uri, arrayOf(MediaStore.Images.Media.DISPLAY_NAME, MediaStore.Images.Media.MIME_TYPE, MediaStore.Images.Media.SIZE), null, null, null,
        )?.use { c ->
            if (!c.moveToFirst()) null else Item(uri, c.getString(0) ?: "IMG_$id.jpg", c.getString(1) ?: "image/jpeg", c.getLong(2))
        }
    }

    companion object {
        const val MAX_PHOTOS = 2000
    }
}
