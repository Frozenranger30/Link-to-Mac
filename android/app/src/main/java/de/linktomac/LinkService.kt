package de.linktomac

import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.net.nsd.NsdManager
import android.net.nsd.NsdServiceInfo
import android.net.wifi.WifiManager
import android.os.Build
import android.os.IBinder
import android.util.Log
import androidx.core.app.NotificationCompat
import androidx.core.app.ServiceCompat
import de.linktomac.features.CallBridge
import de.linktomac.features.ClipboardBridge
import de.linktomac.features.ContactsBridge
import de.linktomac.features.FileBridge
import de.linktomac.features.FindPhone
import de.linktomac.features.InputService
import de.linktomac.features.MediaBridge
import de.linktomac.features.MirrorPermissionActivity
import de.linktomac.features.MirrorService
import de.linktomac.features.NotifListener
import de.linktomac.features.PhotosBridge
import de.linktomac.features.SmsBridge
import de.linktomac.features.StatusBridge
import de.linktomac.net.CallAction
import de.linktomac.net.CallLogBody
import de.linktomac.net.CallLogGet
import de.linktomac.net.ChannelHeader
import de.linktomac.net.ClipboardSet
import de.linktomac.net.Contacts
import de.linktomac.net.ControlConnection
import de.linktomac.net.Envelope
import de.linktomac.net.ErrorCode
import de.linktomac.net.FileDone
import de.linktomac.net.FileOffer
import de.linktomac.net.FileReply
import de.linktomac.net.Frames
import de.linktomac.net.InputKey
import de.linktomac.net.InputScroll
import de.linktomac.net.InputTouch
import de.linktomac.net.MediaAction
import de.linktomac.net.MirrorStart
import de.linktomac.net.MsgType
import de.linktomac.net.NotificationAction
import de.linktomac.net.NotificationKey
import de.linktomac.net.PhotoGet
import de.linktomac.net.PhotosList
import de.linktomac.net.ProtocolJson
import de.linktomac.net.SettingsUpdate
import de.linktomac.net.SmsMarkRead
import de.linktomac.net.SmsMessages
import de.linktomac.net.SmsMessagesGet
import de.linktomac.net.SmsSend
import de.linktomac.net.SmsThreads
import de.linktomac.net.SmsThreadsGet
import de.linktomac.net.TlsServer
import de.linktomac.pairing.PairingManager
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.delay
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import java.net.ServerSocket
import javax.net.ssl.SSLServerSocket
import javax.net.ssl.SSLSocket

/**
 * Foreground service that keeps the TLS servers running, announces itself via mDNS and routes
 * control messages from the Mac to the feature bridges.
 */
class LinkService : Service(), ControlConnection.Listener {
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
    private lateinit var prefs: Prefs
    private lateinit var pairing: PairingManager
    private val servers = mutableListOf<ServerSocket>()
    private var nsd: NsdManager? = null
    private var nsdListener: NsdManager.RegistrationListener? = null
    private var wifiLock: WifiManager.WifiLock? = null

    lateinit var contacts: ContactsBridge
    lateinit var status: StatusBridge
    lateinit var sms: SmsBridge
    lateinit var calls: CallBridge
    lateinit var photos: PhotosBridge
    lateinit var files: FileBridge
    lateinit var media: MediaBridge
    lateinit var find: FindPhone

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onCreate() {
        super.onCreate()
        prefs = Prefs(this)
        pairing = PairingManager(this)
        Notifications.createChannels(this)
        startAsForeground(getString(R.string.service_waiting))
        instance = this
        LinkHub.setState(LinkHub.State.WAITING)

        contacts = ContactsBridge(this)
        status = StatusBridge(this).also { it.start() }
        sms = SmsBridge(this, contacts).also { it.start() }
        calls = CallBridge(this, contacts).also { it.start() }
        photos = PhotosBridge(this)
        files = FileBridge(this)
        media = MediaBridge(this).also { it.start() }
        find = FindPhone(this)

        @Suppress("DEPRECATION")
        wifiLock = getSystemService(WifiManager::class.java)
            ?.createWifiLock(WifiManager.WIFI_MODE_FULL_HIGH_PERF, "LinkToMac")
            ?.apply {
                setReferenceCounted(false)
                acquire()
            }

        scope.launch {
            try {
                pairing.ensureIdentity()
                val tls = TlsServer(pairing)
                startServer(tls.listen(CONTROL_PORT)) { onControlSocket(it) }
                startServer(tls.listen(DATA_PORT)) { files.handleDataConnection(it) }
                startServer(tls.listen(VIDEO_PORT)) { onVideoSocket(it) }
                registerNsd()
            } catch (e: Exception) {
                Log.e(TAG, "server start failed", e)
                updateNotification(getString(R.string.service_error, e.message ?: ""))
            }
        }
        scope.launch {
            while (isActive) {
                delay(60_000)
                if (LinkHub.isConnected) status.sendIfChanged()
            }
        }
    }

    private fun startAsForeground(text: String) {
        val type = if (Build.VERSION.SDK_INT >= 29) ServiceInfo.FOREGROUND_SERVICE_TYPE_CONNECTED_DEVICE else 0
        ServiceCompat.startForeground(this, Notifications.ID_SERVICE, Notifications.service(this, text), type)
    }

    private fun updateNotification(text: String) {
        Notifications.notify(this, Notifications.ID_SERVICE, Notifications.service(this, text))
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        when (intent?.action) {
            ACTION_STOP_RING -> find.stop()
            ACTION_STOP -> {
                stopSelf()
                return START_NOT_STICKY
            }
        }
        if (!prefs.isPaired) {
            // Nothing to serve without a paired Mac.
            stopSelf()
            return START_NOT_STICKY
        }
        sms.tryRegisterObserver()
        return START_STICKY
    }

    private fun startServer(server: SSLServerSocket, handler: (SSLSocket) -> Unit) {
        servers += server
        scope.launch {
            while (isActive && !server.isClosed) {
                val socket = try {
                    server.accept() as SSLSocket
                } catch (e: Exception) {
                    if (server.isClosed) break
                    delay(200)
                    continue
                }
                scope.launch {
                    try {
                        handler(socket)
                    } catch (e: Exception) {
                        Log.w(TAG, "handler failed: ${e.message}")
                        try {
                            socket.close()
                        } catch (_: Exception) {
                        }
                    }
                }
            }
        }
    }

    // ---- Control channel ---------------------------------------------------------------

    private fun onControlSocket(socket: SSLSocket) {
        if (!prefs.isPaired) {
            socket.close()
            return
        }
        val conn = ControlConnection(socket, pairing, PairingManager.deviceName(this), CAPABILITIES, this)
        conn.start(scope)
    }

    override fun onAuthenticated(conn: ControlConnection) {
        val old = LinkHub.connection
        LinkHub.setConnection(conn)
        if (old != null && old !== conn) old.close()
        updateNotification(getString(R.string.service_connected, prefs.macName ?: "Mac"))
        scope.launch {
            delay(200)
            status.sendNow()
            if (calls.current.state != "idle") LinkHub.send(MsgType.CALL_STATE, calls.current)
            NotifListener.instance?.sendAll()
            media.resend()
        }
    }

    override fun onClosed(conn: ControlConnection) {
        if (LinkHub.connection === conn) {
            LinkHub.setConnection(null)
            LinkHub.setState(LinkHub.State.WAITING)
            files.clear()
            MirrorService.stop(this)
            updateNotification(getString(R.string.service_waiting))
        }
    }

    override fun onMessage(conn: ControlConnection, env: Envelope) {
        scope.launch {
            try {
                route(env)
            } catch (e: Exception) {
                Log.w(TAG, "route ${env.type} failed", e)
                LinkHub.sendError(ErrorCode.INTERNAL, e.message ?: "error", env.id)
            }
        }
    }

    private fun featureOff(name: String, env: Envelope): Boolean {
        if (prefs.feature(name)) return false
        LinkHub.sendError(ErrorCode.FEATURE_DISABLED, "Funktion „$name“ ist auf dem Handy ausgeschaltet", env.id)
        return true
    }

    private fun route(env: Envelope) {
        when (env.type) {
            MsgType.UNPAIR -> {
                prefs.clearPairing()
                LinkHub.connection?.close()
                stopSelf()
            }
            MsgType.SETTINGS_UPDATE -> {
                env.bodyAs<SettingsUpdate>().features.forEach { (k, v) -> if (k in Prefs.FEATURES) prefs.setFeature(k, v) }
            }
            // Notifications
            MsgType.NOTIFICATION_ACTION -> {
                if (featureOff("notifications", env)) return
                val a = env.bodyAs<NotificationAction>()
                val err = NotifListener.instance?.performAction(a.key, a.actionIndex, a.replyText) ?: "Kein Benachrichtigungszugriff"
                if (err != null) LinkHub.sendError(ErrorCode.NOT_FOUND, err, env.id)
            }
            MsgType.NOTIFICATION_REMOVED -> NotifListener.instance?.dismiss(env.bodyAs<NotificationKey>().key)
            MsgType.NOTIFICATION_CLEAR_ALL -> NotifListener.instance?.dismissAll()
            // SMS
            MsgType.SMS_THREADS_GET -> {
                if (featureOff("sms", env)) return
                if (!sms.allowed()) return permissionError(env, "SMS lesen")
                val limit = env.bodyAs<SmsThreadsGet>().limit.coerceIn(1, 500)
                LinkHub.send(MsgType.SMS_THREADS, SmsThreads(sms.threads(limit)), env.id)
            }
            MsgType.SMS_MESSAGES_GET -> {
                if (featureOff("sms", env)) return
                val r = env.bodyAs<SmsMessagesGet>()
                LinkHub.send(MsgType.SMS_MESSAGES, SmsMessages(r.threadId, sms.messages(r.threadId, r.before, r.limit.coerceIn(1, 500))), env.id)
            }
            MsgType.SMS_SEND -> {
                if (featureOff("sms", env)) return
                val r = env.bodyAs<SmsSend>()
                sms.send(r.address, r.text, env.id)
            }
            MsgType.SMS_MARK_READ -> sms.markRead(env.bodyAs<SmsMarkRead>().threadId)
            // Calls
            MsgType.CALL_ACTION -> {
                if (featureOff("calls", env)) return
                val a = env.bodyAs<CallAction>()
                calls.action(a.action, a.number)?.let { LinkHub.sendError(ErrorCode.PERMISSION_DENIED, it, env.id) }
            }
            MsgType.CALLLOG_GET -> {
                if (featureOff("calls", env)) return
                LinkHub.send(MsgType.CALLLOG, CallLogBody(calls.callLog(env.bodyAs<CallLogGet>().limit.coerceIn(1, 1000))), env.id)
            }
            MsgType.CONTACTS_GET -> LinkHub.send(MsgType.CONTACTS, Contacts(contacts.all()), env.id)
            // Photos and files
            MsgType.PHOTOS_LIST -> {
                if (featureOff("photos", env)) return
                if (!photos.allowed()) return permissionError(env, "Fotos")
                val r = env.bodyAs<PhotosList>()
                LinkHub.send(MsgType.PHOTOS, photos.list(r.offset.coerceAtLeast(0), r.limit.coerceIn(1, 100)), env.id)
            }
            MsgType.PHOTO_GET -> {
                if (featureOff("photos", env)) return
                val r = env.bodyAs<PhotoGet>()
                val item = photos.item(r.id) ?: return LinkHub.sendError(ErrorCode.NOT_FOUND, "Foto nicht gefunden", env.id).let { }
                if (!files.offerUri(item.uri, item.name, item.mime, r.transferId, "photo")) {
                    LinkHub.sendError(ErrorCode.INTERNAL, "Foto konnte nicht gelesen werden", env.id)
                }
            }
            MsgType.FILE_OFFER -> files.onOffer(env.bodyAs<FileOffer>(), env.id)
            MsgType.FILE_ACCEPT -> Unit // the Mac connects to the data port next
            MsgType.FILE_REJECT -> files.onRemoteReject(env.bodyAs<FileReply>().transferId)
            MsgType.FILE_DONE -> files.onRemoteDone(env.bodyAs<FileDone>())
            MsgType.FILE_PROGRESS -> Unit
            // Clipboard
            MsgType.CLIPBOARD_SET -> ClipboardBridge.applyFromMac(this, env.bodyAs<ClipboardSet>())
            // Mirroring and input
            MsgType.MIRROR_START -> {
                if (featureOff("mirror", env)) return
                requestMirror(env.bodyAs<MirrorStart>())
            }
            MsgType.MIRROR_STOP -> MirrorService.stop(this)
            MsgType.INPUT_TOUCH -> InputService.instance?.touch(env.bodyAs<InputTouch>()) ?: inputMissing(env)
            MsgType.INPUT_KEY -> InputService.instance?.key(env.bodyAs<InputKey>()) ?: inputMissing(env)
            MsgType.INPUT_SCROLL -> InputService.instance?.scroll(env.bodyAs<InputScroll>()) ?: inputMissing(env)
            // Misc
            MsgType.FIND_RING -> find.ring()
            MsgType.FIND_STOP -> find.stop()
            MsgType.MEDIA_ACTION -> media.action(env.bodyAs<MediaAction>().action)
            MsgType.ERROR -> Log.w(TAG, "Mac reported error: ${env.body}")
        }
    }

    private var inputWarned = 0L
    private fun inputMissing(env: Envelope) {
        val now = System.currentTimeMillis()
        if (now - inputWarned > 10_000) {
            inputWarned = now
            LinkHub.sendError(ErrorCode.PERMISSION_DENIED, "Bedienungshilfe „Link to Mac Steuerung“ ist nicht aktiviert", env.id)
        }
    }

    private fun permissionError(env: Envelope, what: String) {
        LinkHub.sendError(ErrorCode.PERMISSION_DENIED, "Berechtigung „$what“ fehlt auf dem Handy", env.id)
    }

    private fun requestMirror(params: MirrorStart) {
        if (MirrorService.running != null) {
            // Already running: just make sure a fresh key frame arrives.
            return
        }
        MirrorService.pendingParams = params
        val intent = Intent(this, MirrorPermissionActivity::class.java).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        // Starting an activity from the background is only allowed in some cases (e.g. while the
        // accessibility service is active). The notification is the reliable fallback.
        try {
            startActivity(intent)
        } catch (_: Exception) {
        }
        val pi = PendingIntent.getActivity(this, 5, intent, PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT)
        val n = NotificationCompat.Builder(this, Notifications.CH_EVENTS)
            .setSmallIcon(R.drawable.ic_stat_link)
            .setContentTitle(getString(R.string.mirror_request_title))
            .setContentText(getString(R.string.mirror_request_text))
            .setPriority(NotificationCompat.PRIORITY_HIGH)
            .setContentIntent(pi)
            .setAutoCancel(true)
            .setTimeoutAfter(60_000)
            .build()
        Notifications.notify(this, Notifications.ID_MIRROR_REQUEST, n)
    }

    // ---- Video channel -----------------------------------------------------------------

    private fun onVideoSocket(socket: SSLSocket) {
        socket.soTimeout = 15_000
        socket.startHandshake()
        val header = ProtocolJson.decodeFromString(ChannelHeader.serializer(), String(Frames.read(socket.getInputStream()), Charsets.UTF_8))
        val token = LinkHub.sessionToken
        if (token == null || header.sessionToken != token) {
            socket.close()
            return
        }
        socket.soTimeout = 0
        socket.tcpNoDelay = true
        MirrorService.attachSink(socket)
    }

    // ---- mDNS --------------------------------------------------------------------------

    private fun registerNsd() {
        val info = NsdServiceInfo().apply {
            serviceName = PairingManager.deviceName(this@LinkService)
            serviceType = SERVICE_TYPE
            port = CONTROL_PORT
            setAttribute("fp", pairing.certFingerprint.take(16))
            setAttribute("v", "1")
        }
        val listener = object : NsdManager.RegistrationListener {
            override fun onServiceRegistered(info: NsdServiceInfo) = Log.i(TAG, "mDNS registered: ${info.serviceName}")
            override fun onRegistrationFailed(info: NsdServiceInfo, code: Int) = Log.w(TAG, "mDNS failed: $code")
            override fun onServiceUnregistered(info: NsdServiceInfo) = Unit
            override fun onUnregistrationFailed(info: NsdServiceInfo, code: Int) = Unit
        }
        nsd = getSystemService(NsdManager::class.java)
        nsdListener = listener
        nsd?.registerService(info, NsdManager.PROTOCOL_DNS_SD, listener)
    }

    override fun onDestroy() {
        instance = null
        LinkHub.connection?.close()
        LinkHub.setConnection(null)
        LinkHub.setState(LinkHub.State.STOPPED)
        try {
            nsdListener?.let { nsd?.unregisterService(it) }
        } catch (_: Exception) {
        }
        servers.forEach {
            try {
                it.close()
            } catch (_: Exception) {
            }
        }
        status.stop()
        sms.stop()
        calls.stop()
        media.stop()
        find.stop()
        files.clear()
        MirrorService.stop(this)
        wifiLock?.release()
        scope.cancel()
        super.onDestroy()
    }

    companion object {
        private const val TAG = "LinkService"
        const val CONTROL_PORT = 47800
        const val DATA_PORT = 47801
        const val VIDEO_PORT = 47802
        const val SERVICE_TYPE = "_linktomac._tcp"
        const val ACTION_STOP_RING = "de.linktomac.STOP_RING"
        const val ACTION_STOP = "de.linktomac.STOP"

        val CAPABILITIES = listOf(
            "status", "notifications", "sms", "calls", "calllog", "contacts", "photos", "files",
            "clipboard", "mirror", "input", "find", "media",
        )

        @Volatile var instance: LinkService? = null
            private set

        fun start(context: Context) {
            if (!Prefs(context).isPaired) return
            try {
                context.startForegroundService(Intent(context, LinkService::class.java))
            } catch (e: Exception) {
                Log.w(TAG, "could not start service: ${e.message}")
            }
        }

        fun stop(context: Context) {
            context.stopService(Intent(context, LinkService::class.java))
        }
    }
}
