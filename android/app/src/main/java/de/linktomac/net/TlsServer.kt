package de.linktomac.net

import de.linktomac.pairing.PairingManager
import java.net.Socket
import java.security.Principal
import java.security.PrivateKey
import java.security.SecureRandom
import java.security.cert.X509Certificate
import javax.net.ssl.SSLContext
import javax.net.ssl.SSLEngine
import javax.net.ssl.SSLServerSocket
import javax.net.ssl.X509ExtendedKeyManager

/** Creates TLS server sockets that present the phone's Keystore-backed certificate. */
class TlsServer(private val pairing: PairingManager) {

    private val context: SSLContext by lazy {
        val km = KeystoreKeyManager(pairing.certificate, pairing.privateKey)
        SSLContext.getInstance("TLS").apply { init(arrayOf(km), null, SecureRandom()) }
    }

    fun listen(port: Int): SSLServerSocket {
        val ss = context.serverSocketFactory.createServerSocket() as SSLServerSocket
        ss.reuseAddress = true
        ss.bind(java.net.InetSocketAddress(port))
        val wanted = setOf("TLSv1.3", "TLSv1.2")
        ss.enabledProtocols = ss.supportedProtocols.filter { it in wanted }.toTypedArray()
        ss.needClientAuth = false
        return ss
    }

    private class KeystoreKeyManager(
        private val cert: X509Certificate,
        private val key: PrivateKey,
    ) : X509ExtendedKeyManager() {
        override fun getClientAliases(keyType: String?, issuers: Array<out Principal>?) = null
        override fun chooseClientAlias(keyType: Array<out String>?, issuers: Array<out Principal>?, socket: Socket?) = null
        override fun getServerAliases(keyType: String?, issuers: Array<out Principal>?) = arrayOf(ALIAS)
        override fun chooseServerAlias(keyType: String?, issuers: Array<out Principal>?, socket: Socket?): String? =
            if (keyType == null || keyType.startsWith("EC")) ALIAS else null
        override fun chooseEngineServerAlias(keyType: String?, issuers: Array<out Principal>?, engine: SSLEngine?): String? =
            chooseServerAlias(keyType, issuers, null)
        override fun getCertificateChain(alias: String?): Array<X509Certificate> = arrayOf(cert)
        override fun getPrivateKey(alias: String?): PrivateKey = key

        companion object { const val ALIAS = "linktomac" }
    }
}
