package de.linktomac.e2e

import android.app.Activity
import android.os.Bundle
import android.util.Base64
import android.util.Log
import de.linktomac.LinkService
import de.linktomac.pairing.PairingManager
import kotlin.concurrent.thread

/** Test-only entry point: `am start -n de.linktomac/.e2e.E2ePairActivity --es qr64 <base64 QR JSON>`. */
class E2ePairActivity : Activity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        val qr64 = intent.getStringExtra("qr64")
        val app = applicationContext
        finish()
        if (qr64 == null) return
        thread {
            val pairing = PairingManager(app)
            val qr = pairing.parseQr(String(Base64.decode(qr64, Base64.DEFAULT), Charsets.UTF_8))
            if (qr == null) {
                Log.e(TAG, "E2E: invalid QR")
                return@thread
            }
            val result = pairing.pair(qr)
            Log.i(TAG, "E2E: pairing result $result")
            if (result is PairingManager.Result.Success) LinkService.start(app)
        }
    }

    companion object {
        private const val TAG = "LinkToMacE2E"
    }
}
