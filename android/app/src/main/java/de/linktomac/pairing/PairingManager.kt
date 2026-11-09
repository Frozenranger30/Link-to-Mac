package de.linktomac.pairing

import android.content.Context
import android.os.Build
import android.provider.Settings
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import android.util.Base64
import de.linktomac.Prefs
import de.linktomac.net.Auth
import de.linktomac.net.Envelope
import de.linktomac.net.Frames
import de.linktomac.net.MsgType
import de.linktomac.net.PairAccept
import de.linktomac.net.PairReject
import de.linktomac.net.PairRequest
import de.linktomac.net.PairingQr
import de.linktomac.net.ProtocolJson
import de.linktomac.net.sha256Hex
import java.math.BigInteger
import java.net.InetSocketAddress
import java.net.Socket
import java.security.KeyFactory
import java.security.KeyPairGenerator
import java.security.KeyStore
import java.security.PrivateKey
import java.security.Signature
import java.security.cert.X509Certificate
import java.security.spec.ECGenParameterSpec
import java.security.spec.X509EncodedKeySpec
import java.util.Calendar
import javax.crypto.Mac
import javax.crypto.spec.SecretKeySpec
import javax.security.auth.x500.X500Principal

/**
 * Owns the phone's TLS identity (EC P-256 key in the Android Keystore with a self-signed
 * certificate) and implements the pairing handshake described in docs/PROTOCOL.md §3.
 */
class PairingManager(private val context: Context) {
    private val prefs = Prefs(context)

    private val keyStore: KeyStore by lazy { KeyStore.getInstance(KEYSTORE).apply { load(null) } }

    @Synchronized
    fun ensureIdentity() {
        if (keyStore.containsAlias(ALIAS)) return
        val start = Calendar.getInstance().apply { add(Calendar.DAY_OF_YEAR, -1) }.time
        val end = Calendar.getInstance().apply { add(Calendar.YEAR, 30) }.time
        val spec = KeyGenParameterSpec.Builder(ALIAS, KeyProperties.PURPOSE_SIGN or KeyProperties.PURPOSE_VERIFY)
            .setAlgorithmParameterSpec(ECGenParameterSpec("secp256r1"))
            .setDigests(
                KeyProperties.DIGEST_NONE,
                KeyProperties.DIGEST_SHA256,
                KeyProperties.DIGEST_SHA384,
                KeyProperties.DIGEST_SHA512,
            )
            .setCertificateSubject(X500Principal("CN=LinkToMac Android"))
            .setCertificateSerialNumber(BigInteger.valueOf(System.currentTimeMillis()))
            .setCertificateNotBefore(start)
            .setCertificateNotAfter(end)
            .build()
        val gen = KeyPairGenerator.getInstance(KeyProperties.KEY_ALGORITHM_EC, KEYSTORE)
        gen.initialize(spec)
        gen.generateKeyPair()
    }

    val certificate: X509Certificate
        get() {
            ensureIdentity()
            return keyStore.getCertificate(ALIAS) as X509Certificate
        }

    val privateKey: PrivateKey
        get() {
            ensureIdentity()
            return keyStore.getKey(ALIAS, null) as PrivateKey
        }

    val certFingerprint: String get() = sha256Hex(certificate.encoded)

    /** Deletes our TLS identity, so a new pairing gets a fresh certificate. */
    fun resetIdentity() {
        if (keyStore.containsAlias(ALIAS)) keyStore.deleteEntry(ALIAS)
    }

    fun parseQr(raw: String): PairingQr? = try {
        val qr = ProtocolJson.decodeFromString(PairingQr.serializer(), raw)
        if (qr.v == 1 && qr.pairToken.isNotEmpty() && qr.keyFingerprint.length == 64) qr else null
    } catch (e: Exception) {
        null
    }

    sealed class Result {
        data class Success(val macName: String) : Result()
        data class Rejected(val reason: String?) : Result()
        data class Failed(val message: String) : Result()
    }

    /** Blocking: connects to the Mac's pairing port and waits for the user's decision there. */
    fun pair(qr: PairingQr): Result {
        val fp = certFingerprint
        val tokenBytes = try {
            Base64.decode(qr.pairToken, Base64.DEFAULT)
        } catch (e: IllegalArgumentException) {
            return Result.Failed("Ungültiger QR-Code")
        }
        val proof = hmacProof(tokenBytes, fp, qr.keyFingerprint)
        val request = PairRequest(
            deviceName = deviceName(context),
            model = Build.MODEL,
            port = de.linktomac.LinkService.CONTROL_PORT,
            certFingerprint = fp,
            proof = proof,
        )
        val hosts = (listOf(qr.host) + qr.hosts).filter { it.isNotBlank() }.distinct()
        var lastError = "Mac nicht erreichbar"
        for (host in hosts) {
            try {
                Socket().use { socket ->
                    socket.connect(InetSocketAddress(host, qr.port), 5000)
                    socket.soTimeout = 180_000 // the user has to confirm on the Mac
                    Frames.writeEnvelope(socket.getOutputStream(), Envelope.of(MsgType.PAIR_REQUEST, request))
                    val reply = Frames.readEnvelope(socket.getInputStream())
                    return when (reply.type) {
                        MsgType.PAIR_ACCEPT -> {
                            val accept = reply.bodyAs<PairAccept>()
                            val keyDer = Base64.decode(accept.publicKey, Base64.DEFAULT)
                            if (sha256Hex(keyDer) != qr.keyFingerprint) {
                                Result.Failed("Schlüssel des Mac passt nicht zum QR-Code")
                            } else {
                                prefs.macName = accept.macName
                                prefs.macPublicKey = accept.publicKey
                                prefs.macKeyFingerprint = qr.keyFingerprint
                                Result.Success(accept.macName)
                            }
                        }
                        MsgType.PAIR_REJECT -> Result.Rejected(reply.bodyAs<PairReject>().reason)
                        else -> Result.Failed("Unerwartete Antwort: ${reply.type}")
                    }
                }
            } catch (e: Exception) {
                lastError = e.message ?: e.javaClass.simpleName
            }
        }
        return Result.Failed(lastError)
    }

    /** Verifies the Mac's `auth` signature over the challenge (PROTOCOL.md §4). */
    fun verifyAuth(auth: Auth, challenge: String): Boolean {
        val keyB64 = prefs.macPublicKey ?: return false
        if (auth.keyFingerprint != prefs.macKeyFingerprint) return false
        return try {
            val keyDer = Base64.decode(keyB64, Base64.DEFAULT)
            val pub = KeyFactory.getInstance("EC").generatePublic(X509EncodedKeySpec(keyDer))
            val sig = Signature.getInstance("SHA256withECDSA")
            sig.initVerify(pub)
            sig.update(authMessage(challenge, certFingerprint))
            sig.verify(Base64.decode(auth.signature, Base64.DEFAULT))
        } catch (e: Exception) {
            false
        }
    }

    companion object {
        const val KEYSTORE = "AndroidKeyStore"
        const val ALIAS = "linktomac_tls"

        fun hmacProof(token: ByteArray, certFingerprint: String, keyFingerprint: String): String {
            val mac = Mac.getInstance("HmacSHA256")
            mac.init(SecretKeySpec(token, "HmacSHA256"))
            val out = mac.doFinal("$certFingerprint|$keyFingerprint".toByteArray(Charsets.UTF_8))
            return java.util.Base64.getEncoder().encodeToString(out)
        }

        fun authMessage(challenge: String, certFingerprint: String): ByteArray =
            "linktomac-auth|$challenge|$certFingerprint".toByteArray(Charsets.UTF_8)

        fun deviceName(context: Context): String {
            val name = try {
                Settings.Global.getString(context.contentResolver, Settings.Global.DEVICE_NAME)
            } catch (e: Exception) {
                null
            }
            return name?.takeIf { it.isNotBlank() } ?: "${Build.MANUFACTURER.replaceFirstChar { it.uppercase() }} ${Build.MODEL}"
        }
    }
}
