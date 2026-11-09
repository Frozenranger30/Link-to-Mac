package de.linktomac.features

import android.app.NotificationManager
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.net.ConnectivityManager
import android.net.NetworkCapabilities
import android.os.BatteryManager
import android.telephony.TelephonyManager
import androidx.core.content.ContextCompat
import de.linktomac.LinkHub
import de.linktomac.net.MsgType
import de.linktomac.net.StatusUpdate

/** Collects battery, network and DND state and sends `status.update` (F2). */
class StatusBridge(private val context: Context) {
    private var lastSent: StatusUpdate? = null

    private val batteryReceiver = object : BroadcastReceiver() {
        override fun onReceive(c: Context, intent: Intent) {
            if (LinkHub.isConnected) sendIfChanged()
        }
    }

    fun start() {
        val filter = IntentFilter().apply {
            addAction(Intent.ACTION_BATTERY_CHANGED)
            addAction(Intent.ACTION_POWER_CONNECTED)
            addAction(Intent.ACTION_POWER_DISCONNECTED)
            addAction(NotificationManager.ACTION_INTERRUPTION_FILTER_CHANGED)
        }
        ContextCompat.registerReceiver(context, batteryReceiver, filter, ContextCompat.RECEIVER_NOT_EXPORTED)
    }

    fun stop() {
        try {
            context.unregisterReceiver(batteryReceiver)
        } catch (_: Exception) {
        }
    }

    fun sendNow() {
        val s = snapshot()
        lastSent = s
        LinkHub.send(MsgType.STATUS_UPDATE, s)
    }

    fun sendIfChanged() {
        val s = snapshot()
        if (s != lastSent) {
            lastSent = s
            LinkHub.send(MsgType.STATUS_UPDATE, s)
        }
    }

    fun snapshot(): StatusUpdate {
        val battery = context.registerReceiver(null, IntentFilter(Intent.ACTION_BATTERY_CHANGED))
        val level = battery?.getIntExtra(BatteryManager.EXTRA_LEVEL, -1) ?: -1
        val scale = battery?.getIntExtra(BatteryManager.EXTRA_SCALE, 100) ?: 100
        val pct = if (level >= 0 && scale > 0) level * 100 / scale else -1
        val status = battery?.getIntExtra(BatteryManager.EXTRA_STATUS, -1) ?: -1
        val charging = status == BatteryManager.BATTERY_STATUS_CHARGING || status == BatteryManager.BATTERY_STATUS_FULL

        val cm = context.getSystemService(ConnectivityManager::class.java)
        val caps = cm?.getNetworkCapabilities(cm.activeNetwork)
        val network = when {
            caps == null -> "none"
            caps.hasTransport(NetworkCapabilities.TRANSPORT_WIFI) -> "wifi"
            caps.hasTransport(NetworkCapabilities.TRANSPORT_CELLULAR) -> "mobile"
            else -> "other"
        }
        val wifiSignal = if (network == "wifi") rssiToLevel(caps?.signalStrength ?: Int.MIN_VALUE) else 0

        val tm = context.getSystemService(TelephonyManager::class.java)
        val cell = try {
            tm?.signalStrength?.level ?: -1
        } catch (e: Exception) {
            -1
        }
        val carrier = try {
            tm?.networkOperatorName?.takeIf { it.isNotBlank() }
        } catch (e: Exception) {
            null
        }

        val nm = context.getSystemService(NotificationManager::class.java)
        val dnd = nm?.currentInterruptionFilter?.let { it != NotificationManager.INTERRUPTION_FILTER_ALL && it != NotificationManager.INTERRUPTION_FILTER_UNKNOWN } ?: false

        return StatusUpdate(
            battery = pct,
            charging = charging,
            wifiSignal = wifiSignal,
            network = network,
            cellSignal = cell,
            dnd = dnd,
            carrier = carrier,
        )
    }

    private fun rssiToLevel(rssi: Int): Int = when {
        rssi == Int.MIN_VALUE || rssi < -100 -> 0
        rssi >= -55 -> 4
        rssi >= -66 -> 3
        rssi >= -77 -> 2
        rssi >= -88 -> 1
        else -> 0
    }
}
