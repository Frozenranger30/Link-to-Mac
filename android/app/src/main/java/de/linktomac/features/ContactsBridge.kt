package de.linktomac.features

import android.Manifest
import android.content.Context
import android.content.pm.PackageManager
import android.net.Uri
import android.provider.ContactsContract
import androidx.core.content.ContextCompat
import de.linktomac.net.Contact
import java.util.concurrent.ConcurrentHashMap

/** Resolves phone numbers to contact names (F12) with a small cache. */
class ContactsBridge(private val context: Context) {
    private val cache = ConcurrentHashMap<String, String>()
    private val misses = ConcurrentHashMap.newKeySet<String>()

    private fun allowed() =
        ContextCompat.checkSelfPermission(context, Manifest.permission.READ_CONTACTS) == PackageManager.PERMISSION_GRANTED

    fun nameFor(number: String?): String? {
        if (number.isNullOrBlank() || !allowed()) return null
        cache[number]?.let { return it }
        if (number in misses) return null
        val uri = Uri.withAppendedPath(ContactsContract.PhoneLookup.CONTENT_FILTER_URI, Uri.encode(number))
        val name = try {
            context.contentResolver.query(uri, arrayOf(ContactsContract.PhoneLookup.DISPLAY_NAME), null, null, null)?.use { c ->
                if (c.moveToFirst()) c.getString(0) else null
            }
        } catch (e: Exception) {
            null
        }
        if (name != null) cache[number] = name else misses += number
        return name
    }

    fun clearCache() {
        cache.clear()
        misses.clear()
    }

    fun all(): List<Contact> {
        if (!allowed()) return emptyList()
        val map = LinkedHashMap<String, MutableList<String>>()
        context.contentResolver.query(
            ContactsContract.CommonDataKinds.Phone.CONTENT_URI,
            arrayOf(
                ContactsContract.CommonDataKinds.Phone.DISPLAY_NAME,
                ContactsContract.CommonDataKinds.Phone.NUMBER,
            ),
            null, null,
            ContactsContract.CommonDataKinds.Phone.DISPLAY_NAME + " COLLATE NOCASE ASC",
        )?.use { c ->
            while (c.moveToNext()) {
                val name = c.getString(0) ?: continue
                val number = c.getString(1) ?: continue
                val list = map.getOrPut(name) { mutableListOf() }
                if (number !in list) list += number
            }
        }
        return map.map { (n, nums) -> Contact(n, nums) }
    }
}
