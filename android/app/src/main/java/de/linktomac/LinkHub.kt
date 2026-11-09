package de.linktomac

import de.linktomac.net.ControlConnection
import de.linktomac.net.Envelope
import de.linktomac.net.ErrorBody
import de.linktomac.net.MsgType
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow

/** Process-wide access point to the current Mac connection (used by services and the UI). */
object LinkHub {
    enum class State { STOPPED, WAITING, CONNECTED }

    private val _state = MutableStateFlow(State.STOPPED)
    val state: StateFlow<State> = _state.asStateFlow()

    private val _macAddress = MutableStateFlow<String?>(null)
    val macAddress: StateFlow<String?> = _macAddress.asStateFlow()

    @Volatile
    var connection: ControlConnection? = null
        private set

    val isConnected: Boolean get() = connection?.authenticated == true
    val sessionToken: String? get() = connection?.takeIf { it.authenticated }?.sessionToken

    internal fun setConnection(conn: ControlConnection?) {
        connection = conn
        _macAddress.value = conn?.remoteAddress
        _state.value = if (conn?.authenticated == true) State.CONNECTED else if (_state.value == State.STOPPED) State.STOPPED else State.WAITING
    }

    internal fun setState(s: State) {
        _state.value = s
    }

    fun send(env: Envelope): Boolean {
        val c = connection ?: return false
        if (!c.authenticated) return false
        return c.send(env)
    }

    inline fun <reified T> send(type: String, body: T, replyTo: String? = null): Boolean =
        send(Envelope.of(type, body, replyTo))

    fun sendError(code: String, message: String, replyTo: String? = null) =
        send(MsgType.ERROR, ErrorBody(code, message), replyTo)
}
