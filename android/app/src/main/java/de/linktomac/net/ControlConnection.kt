package de.linktomac.net

import android.util.Base64
import android.util.Log
import de.linktomac.BuildConfig
import de.linktomac.pairing.PairingManager
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.channels.Channel
import kotlinx.coroutines.launch
import java.io.BufferedInputStream
import java.io.BufferedOutputStream
import java.io.DataInputStream
import java.security.SecureRandom
import java.util.concurrent.atomic.AtomicBoolean
import javax.net.ssl.SSLSocket

/**
 * One control connection from the Mac (port 47800). Handles the challenge/response
 * authentication, a dedicated writer coroutine and the read loop.
 */
class ControlConnection(
    private val socket: SSLSocket,
    private val pairing: PairingManager,
    private val deviceName: String,
    private val capabilities: List<String>,
    private val listener: Listener,
) {
    interface Listener {
        fun onAuthenticated(conn: ControlConnection)
        fun onMessage(conn: ControlConnection, env: Envelope)
        fun onClosed(conn: ControlConnection)
    }

    private val outbox = Channel<Envelope>(Channel.UNLIMITED)
    private val closed = AtomicBoolean(false)
    private val challenge = randomB64(32)
    private var jobs = mutableListOf<Job>()

    @Volatile var authenticated = false
        private set
    @Volatile var sessionToken: String? = null
        private set
    val remoteAddress: String? get() = socket.inetAddress?.hostAddress

    fun start(scope: CoroutineScope) {
        socket.soTimeout = READ_TIMEOUT_MS
        socket.tcpNoDelay = true
        jobs += scope.launch(Dispatchers.IO) { writeLoop() }
        jobs += scope.launch(Dispatchers.IO) { readLoop() }
        send(
            Envelope.of(
                MsgType.HELLO,
                Hello(
                    deviceName = deviceName,
                    model = android.os.Build.MODEL,
                    appVersion = BuildConfig.VERSION_NAME,
                    capabilities = capabilities,
                    challenge = challenge,
                ),
            ),
        )
    }

    fun send(env: Envelope): Boolean {
        if (closed.get()) return false
        return outbox.trySend(env).isSuccess
    }

    private suspend fun writeLoop() {
        try {
            val out = BufferedOutputStream(socket.getOutputStream(), 64 * 1024)
            for (env in outbox) {
                Frames.writeEnvelope(out, env)
            }
        } catch (e: Exception) {
            Log.w(TAG, "write failed: ${e.message}")
        } finally {
            close()
        }
    }

    private fun readLoop() {
        try {
            socket.startHandshake()
            val input = DataInputStream(BufferedInputStream(socket.getInputStream(), 64 * 1024))
            while (!closed.get()) {
                val env = Frames.readEnvelope(input)
                handle(env)
            }
        } catch (e: Exception) {
            Log.i(TAG, "connection ended: ${e.message}")
        } finally {
            close()
        }
    }

    private fun handle(env: Envelope) {
        when (env.type) {
            MsgType.PING -> send(Envelope.empty(MsgType.PONG, replyTo = env.id))
            MsgType.PONG -> Unit
            MsgType.AUTH -> {
                val ok = try {
                    pairing.verifyAuth(env.bodyAs(), challenge)
                } catch (e: Exception) {
                    false
                }
                if (ok) {
                    val token = randomB64(32)
                    sessionToken = token
                    authenticated = true
                    send(Envelope.of(MsgType.AUTH_OK, AuthOk(token), replyTo = env.id))
                    listener.onAuthenticated(this)
                } else {
                    send(Envelope.of(MsgType.ERROR, ErrorBody(ErrorCode.UNAUTHORIZED, "Unknown Mac – please pair again")))
                    outbox.close()
                }
            }
            MsgType.HELLO -> Unit
            else -> if (authenticated) listener.onMessage(this, env)
        }
    }

    fun close() {
        if (!closed.compareAndSet(false, true)) return
        outbox.close()
        try {
            socket.close()
        } catch (_: Exception) {
        }
        listener.onClosed(this)
    }

    companion object {
        private const val TAG = "ControlConnection"
        const val READ_TIMEOUT_MS = 30_000

        private val random = SecureRandom()
        fun randomB64(n: Int): String {
            val b = ByteArray(n)
            random.nextBytes(b)
            return Base64.encodeToString(b, Base64.NO_WRAP)
        }
    }
}
