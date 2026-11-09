package de.linktomac

import android.content.Context
import android.content.SharedPreferences

/**
 * Persistent settings. Only public data is stored here (the Mac's public key and name);
 * private keys live in the Android Keystore.
 */
class Prefs(context: Context) {
    private val sp: SharedPreferences = context.getSharedPreferences("linktomac", Context.MODE_PRIVATE)

    var macName: String?
        get() = sp.getString("macName", null)
        set(v) = sp.edit().putString("macName", v).apply()

    /** Base64 DER SubjectPublicKeyInfo of the paired Mac. */
    var macPublicKey: String?
        get() = sp.getString("macPublicKey", null)
        set(v) = sp.edit().putString("macPublicKey", v).apply()

    var macKeyFingerprint: String?
        get() = sp.getString("macKeyFingerprint", null)
        set(v) = sp.edit().putString("macKeyFingerprint", v).apply()

    val isPaired: Boolean get() = macPublicKey != null

    fun feature(name: String): Boolean = sp.getBoolean("feature_$name", true)
    fun setFeature(name: String, enabled: Boolean) = sp.edit().putBoolean("feature_$name", enabled).apply()

    var onboardingDone: Boolean
        get() = sp.getBoolean("onboardingDone", false)
        set(v) = sp.edit().putBoolean("onboardingDone", v).apply()

    fun clearPairing() {
        sp.edit().remove("macName").remove("macPublicKey").remove("macKeyFingerprint").apply()
    }

    companion object {
        val FEATURES = listOf("notifications", "sms", "calls", "photos", "files", "clipboard", "mirror", "media")
    }
}
