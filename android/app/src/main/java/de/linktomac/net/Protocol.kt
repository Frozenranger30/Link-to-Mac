package de.linktomac.net

import kotlinx.serialization.Serializable
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.decodeFromJsonElement
import kotlinx.serialization.json.encodeToJsonElement
import kotlinx.serialization.json.jsonObject
import java.util.UUID

/** Shared JSON configuration (see docs/PROTOCOL.md). */
val ProtocolJson = Json {
    ignoreUnknownKeys = true
    encodeDefaults = true
    explicitNulls = false
}

const val PROTOCOL_VERSION = 1

/** Envelope of every control message. */
@Serializable
data class Envelope(
    val id: String = UUID.randomUUID().toString(),
    val type: String,
    val ts: Long = System.currentTimeMillis(),
    val replyTo: String? = null,
    val body: JsonObject = JsonObject(emptyMap()),
) {
    inline fun <reified T> bodyAs(): T = ProtocolJson.decodeFromJsonElement(body)

    fun encode(): ByteArray = ProtocolJson.encodeToString(serializer(), this).toByteArray(Charsets.UTF_8)

    companion object {
        fun decode(bytes: ByteArray): Envelope =
            ProtocolJson.decodeFromString(serializer(), bytes.toString(Charsets.UTF_8))

        inline fun <reified T> of(type: String, body: T, replyTo: String? = null): Envelope =
            Envelope(type = type, replyTo = replyTo, body = ProtocolJson.encodeToJsonElement(body).jsonObject)

        fun empty(type: String, replyTo: String? = null): Envelope =
            Envelope(type = type, replyTo = replyTo, body = buildJsonObject { })
    }
}

object MsgType {
    const val HELLO = "hello"
    const val AUTH = "auth"
    const val AUTH_OK = "auth.ok"
    const val PAIR_REQUEST = "pair.request"
    const val PAIR_ACCEPT = "pair.accept"
    const val PAIR_REJECT = "pair.reject"
    const val UNPAIR = "unpair"
    const val PING = "ping"
    const val PONG = "pong"
    const val STATUS_UPDATE = "status.update"
    const val SETTINGS_UPDATE = "settings.update"
    const val NOTIFICATION_POSTED = "notification.posted"
    const val NOTIFICATION_REMOVED = "notification.removed"
    const val NOTIFICATION_ACTION = "notification.action"
    const val NOTIFICATION_CLEAR_ALL = "notification.clearAll"
    const val SMS_THREADS_GET = "sms.threads.get"
    const val SMS_THREADS = "sms.threads"
    const val SMS_MESSAGES_GET = "sms.messages.get"
    const val SMS_MESSAGES = "sms.messages"
    const val SMS_RECEIVED = "sms.received"
    const val SMS_SEND = "sms.send"
    const val SMS_SENT = "sms.sent"
    const val SMS_MARK_READ = "sms.markRead"
    const val CALL_STATE = "call.state"
    const val CALL_ACTION = "call.action"
    const val CALLLOG_GET = "calllog.get"
    const val CALLLOG = "calllog"
    const val CONTACTS_GET = "contacts.get"
    const val CONTACTS = "contacts"
    const val PHOTOS_LIST = "photos.list"
    const val PHOTOS = "photos"
    const val PHOTO_GET = "photo.get"
    const val FILE_OFFER = "file.offer"
    const val FILE_ACCEPT = "file.accept"
    const val FILE_REJECT = "file.reject"
    const val FILE_PROGRESS = "file.progress"
    const val FILE_DONE = "file.done"
    const val CLIPBOARD_SET = "clipboard.set"
    const val MIRROR_START = "mirror.start"
    const val MIRROR_STOP = "mirror.stop"
    const val MIRROR_CONFIG = "mirror.config"
    const val MIRROR_STOPPED = "mirror.stopped"
    const val INPUT_TOUCH = "input.touch"
    const val INPUT_KEY = "input.key"
    const val INPUT_SCROLL = "input.scroll"
    const val FIND_RING = "find.ring"
    const val FIND_STOP = "find.stop"
    const val MEDIA_STATE = "media.state"
    const val MEDIA_ACTION = "media.action"
    const val ERROR = "error"
}

object ErrorCode {
    const val UNAUTHORIZED = "unauthorized"
    const val PERMISSION_DENIED = "permission_denied"
    const val NOT_FOUND = "not_found"
    const val FEATURE_DISABLED = "feature_disabled"
    const val BAD_REQUEST = "bad_request"
    const val INTERNAL = "internal"
}

// ---- Bodies -------------------------------------------------------------------------------

@Serializable
data class Hello(
    val deviceName: String,
    val model: String? = null,
    val appVersion: String,
    val protocolVersion: Int = PROTOCOL_VERSION,
    val capabilities: List<String> = emptyList(),
    val challenge: String? = null,
)

@Serializable
data class Auth(val keyFingerprint: String, val signature: String)

@Serializable
data class AuthOk(val sessionToken: String)

@Serializable
data class PairRequest(
    val deviceName: String,
    val model: String,
    val port: Int,
    val certFingerprint: String,
    val proof: String,
)

@Serializable
data class PairAccept(val macName: String, val publicKey: String)

@Serializable
data class PairReject(val reason: String? = null)

@Serializable
data class StatusUpdate(
    val battery: Int,
    val charging: Boolean,
    val wifiSignal: Int,
    val network: String,
    val cellSignal: Int = -1,
    val dnd: Boolean,
    val carrier: String? = null,
)

@Serializable
data class SettingsUpdate(val features: Map<String, Boolean> = emptyMap())

@Serializable
data class NotificationActionInfo(val title: String, val isReply: Boolean = false)

@Serializable
data class NotificationPosted(
    val key: String,
    val app: String,
    val appName: String,
    val appIconPng: String? = null,
    val title: String,
    val text: String,
    val time: Long,
    val actions: List<NotificationActionInfo> = emptyList(),
    val canReply: Boolean = false,
)

@Serializable
data class NotificationKey(val key: String)

@Serializable
data class NotificationAction(val key: String, val actionIndex: Int, val replyText: String? = null)

@Serializable
data class SmsThreadsGet(val limit: Int = 200)

@Serializable
data class SmsThread(
    val threadId: Long,
    val address: String,
    val contactName: String? = null,
    val snippet: String,
    val date: Long,
    val unread: Int,
)

@Serializable
data class SmsThreads(val threads: List<SmsThread>)

@Serializable
data class SmsMessagesGet(val threadId: Long, val before: Long? = null, val limit: Int = 100)

@Serializable
data class SmsMessage(
    val id: Long,
    val threadId: Long,
    val address: String,
    val body: String,
    val date: Long,
    val outgoing: Boolean,
    val read: Boolean,
)

@Serializable
data class SmsMessages(val threadId: Long, val messages: List<SmsMessage>)

@Serializable
data class SmsReceived(val message: SmsMessage, val contactName: String? = null)

@Serializable
data class SmsSend(val address: String, val text: String)

@Serializable
data class SmsSent(val ok: Boolean, val error: String? = null)

@Serializable
data class SmsMarkRead(val threadId: Long)

@Serializable
data class CallState(val state: String, val number: String? = null, val contactName: String? = null)

@Serializable
data class CallAction(val action: String, val number: String? = null)

@Serializable
data class CallLogGet(val limit: Int = 200)

@Serializable
data class CallEntry(
    val id: Long,
    val number: String,
    val contactName: String? = null,
    val type: String,
    val date: Long,
    val duration: Long,
)

@Serializable
data class CallLogBody(val calls: List<CallEntry>)

@Serializable
data class Contact(val name: String, val numbers: List<String>)

@Serializable
data class Contacts(val contacts: List<Contact>)

@Serializable
data class PhotosList(val offset: Int = 0, val limit: Int = 60)

@Serializable
data class PhotoInfo(
    val id: Long,
    val date: Long,
    val width: Int,
    val height: Int,
    val name: String,
    val mime: String,
    val thumbJpeg: String,
)

@Serializable
data class Photos(val offset: Int, val total: Int, val photos: List<PhotoInfo>)

@Serializable
data class PhotoGet(val id: Long, val transferId: String)

@Serializable
data class FileOffer(
    val transferId: String,
    val name: String,
    val size: Long,
    val mime: String,
    val sha256: String,
    val purpose: String = "file",
)

@Serializable
data class FileReply(val transferId: String, val reason: String? = null)

@Serializable
data class FileProgress(val transferId: String, val bytes: Long, val size: Long)

@Serializable
data class FileDone(val transferId: String, val ok: Boolean, val error: String? = null)

@Serializable
data class ClipboardSet(val mime: String, val text: String? = null, val dataBase64: String? = null)

@Serializable
data class MirrorStart(val maxSize: Int = 1280, val bitrate: Int = 6_000_000, val fps: Int = 30)

@Serializable
data class MirrorConfig(val width: Int, val height: Int, val sps: String, val pps: String)

@Serializable
data class MirrorStopped(val reason: String? = null)

@Serializable
data class InputTouch(
    val action: String,
    val x: Double,
    val y: Double,
    val x2: Double? = null,
    val y2: Double? = null,
    val durationMs: Long? = null,
)

@Serializable
data class InputKey(val key: String, val text: String? = null)

@Serializable
data class InputScroll(val x: Double, val y: Double, val dx: Double, val dy: Double)

@Serializable
data class MediaState(
    val active: Boolean,
    val playing: Boolean = false,
    val title: String? = null,
    val artist: String? = null,
    val app: String? = null,
    val appName: String? = null,
    val artPng: String? = null,
)

@Serializable
data class MediaAction(val action: String)

@Serializable
data class ErrorBody(val code: String, val message: String)

/** Header frame of data (47801) and video (47802) connections. */
@Serializable
data class ChannelHeader(
    val sessionToken: String,
    val transferId: String? = null,
    val direction: String? = null,
)

/** QR code content shown by the Mac. */
@Serializable
data class PairingQr(
    val v: Int,
    val name: String,
    val host: String,
    val hosts: List<String> = emptyList(),
    val port: Int,
    val keyFingerprint: String,
    val pairToken: String,
)
