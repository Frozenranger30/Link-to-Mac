package de.linktomac.ui

import android.Manifest
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import android.os.PowerManager
import android.provider.Settings
import androidx.annotation.StringRes
import androidx.core.app.NotificationManagerCompat
import androidx.core.content.ContextCompat
import de.linktomac.R
import de.linktomac.features.InputService

/** One row in the permission checklist. */
data class PermissionItem(
    val id: String,
    @StringRes val title: Int,
    @StringRes val explanation: Int,
    val runtime: List<String> = emptyList(),
    val special: ((Context) -> Intent)? = null,
    val isGranted: (Context) -> Boolean,
)

object PermissionCatalog {
    private fun granted(ctx: Context, perms: List<String>) =
        perms.all { ContextCompat.checkSelfPermission(ctx, it) == PackageManager.PERMISSION_GRANTED }

    private val photoPerm = if (Build.VERSION.SDK_INT >= 33) Manifest.permission.READ_MEDIA_IMAGES else Manifest.permission.READ_EXTERNAL_STORAGE
    private val phonePerms = listOf(
        Manifest.permission.READ_PHONE_STATE,
        Manifest.permission.READ_CALL_LOG,
        Manifest.permission.CALL_PHONE,
        Manifest.permission.ANSWER_PHONE_CALLS,
    )
    private val smsPerms = listOf(Manifest.permission.READ_SMS, Manifest.permission.RECEIVE_SMS, Manifest.permission.SEND_SMS)

    fun notificationAccess(ctx: Context) = NotificationManagerCompat.getEnabledListenerPackages(ctx).contains(ctx.packageName)

    fun accessibilityEnabled(ctx: Context): Boolean {
        val enabled = Settings.Secure.getString(ctx.contentResolver, Settings.Secure.ENABLED_ACCESSIBILITY_SERVICES) ?: return false
        val me = ComponentName(ctx, InputService::class.java)
        return enabled.split(':').any { ComponentName.unflattenFromString(it) == me }
    }

    fun batteryUnrestricted(ctx: Context) =
        ctx.getSystemService(PowerManager::class.java).isIgnoringBatteryOptimizations(ctx.packageName)

    fun all(): List<PermissionItem> = buildList {
        if (Build.VERSION.SDK_INT >= 33) {
            val p = listOf(Manifest.permission.POST_NOTIFICATIONS)
            add(PermissionItem("post", R.string.perm_post_title, R.string.perm_post_text, runtime = p) { granted(it, p) })
        }
        add(
            PermissionItem(
                "listener", R.string.perm_listener_title, R.string.perm_listener_text,
                special = { Intent(Settings.ACTION_NOTIFICATION_LISTENER_SETTINGS) },
            ) { notificationAccess(it) },
        )
        add(PermissionItem("sms", R.string.perm_sms_title, R.string.perm_sms_text, runtime = smsPerms) { granted(it, smsPerms) })
        add(PermissionItem("phone", R.string.perm_phone_title, R.string.perm_phone_text, runtime = phonePerms) { granted(it, phonePerms) })
        val contacts = listOf(Manifest.permission.READ_CONTACTS)
        add(PermissionItem("contacts", R.string.perm_contacts_title, R.string.perm_contacts_text, runtime = contacts) { granted(it, contacts) })
        val photos = listOf(photoPerm)
        add(PermissionItem("photos", R.string.perm_photos_title, R.string.perm_photos_text, runtime = photos) { granted(it, photos) })
        add(
            PermissionItem(
                "accessibility", R.string.perm_access_title, R.string.perm_access_text,
                special = { Intent(Settings.ACTION_ACCESSIBILITY_SETTINGS) },
            ) { accessibilityEnabled(it) },
        )
        add(
            PermissionItem(
                "battery", R.string.perm_battery_title, R.string.perm_battery_text,
                special = { ctx ->
                    @Suppress("BatteryLife")
                    Intent(Settings.ACTION_REQUEST_IGNORE_BATTERY_OPTIMIZATIONS, Uri.parse("package:" + ctx.packageName))
                },
            ) { batteryUnrestricted(it) },
        )
    }

    fun appDetails(ctx: Context) =
        Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS, Uri.parse("package:" + ctx.packageName))
}
