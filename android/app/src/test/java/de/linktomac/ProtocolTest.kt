package de.linktomac

import de.linktomac.features.MirrorService
import de.linktomac.net.*
import de.linktomac.pairing.PairingManager
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.ByteArrayInputStream
import java.io.ByteArrayOutputStream

class ProtocolTest {
    private fun resource(name: String): String =
        javaClass.classLoader!!.getResourceAsStream(name)!!.readBytes().toString(Charsets.UTF_8)

    private val decoders: Map<String, (Envelope) -> Any> = mapOf(
        "hello" to { e -> e.bodyAs<Hello>() },
        "auth" to { e -> e.bodyAs<Auth>() },
        "auth.ok" to { e -> e.bodyAs<AuthOk>() },
        "pair.request" to { e -> e.bodyAs<PairRequest>() },
        "pair.accept" to { e -> e.bodyAs<PairAccept>() },
        "pair.reject" to { e -> e.bodyAs<PairReject>() },
        "status.update" to { e -> e.bodyAs<StatusUpdate>() },
        "settings.update" to { e -> e.bodyAs<SettingsUpdate>() },
        "notification.posted" to { e -> e.bodyAs<NotificationPosted>() },
        "notification.removed" to { e -> e.bodyAs<NotificationKey>() },
        "notification.action" to { e -> e.bodyAs<NotificationAction>() },
        "sms.threads.get" to { e -> e.bodyAs<SmsThreadsGet>() },
        "sms.threads" to { e -> e.bodyAs<SmsThreads>() },
        "sms.messages.get" to { e -> e.bodyAs<SmsMessagesGet>() },
        "sms.messages" to { e -> e.bodyAs<SmsMessages>() },
        "sms.received" to { e -> e.bodyAs<SmsReceived>() },
        "sms.send" to { e -> e.bodyAs<SmsSend>() },
        "sms.sent" to { e -> e.bodyAs<SmsSent>() },
        "sms.markRead" to { e -> e.bodyAs<SmsMarkRead>() },
        "call.state" to { e -> e.bodyAs<CallState>() },
        "call.action" to { e -> e.bodyAs<CallAction>() },
        "calllog.get" to { e -> e.bodyAs<CallLogGet>() },
        "calllog" to { e -> e.bodyAs<CallLogBody>() },
        "contacts" to { e -> e.bodyAs<Contacts>() },
        "photos.list" to { e -> e.bodyAs<PhotosList>() },
        "photos" to { e -> e.bodyAs<Photos>() },
        "photo.get" to { e -> e.bodyAs<PhotoGet>() },
        "file.offer" to { e -> e.bodyAs<FileOffer>() },
        "file.accept" to { e -> e.bodyAs<FileReply>() },
        "file.reject" to { e -> e.bodyAs<FileReply>() },
        "file.progress" to { e -> e.bodyAs<FileProgress>() },
        "file.done" to { e -> e.bodyAs<FileDone>() },
        "clipboard.set" to { e -> e.bodyAs<ClipboardSet>() },
        "mirror.start" to { e -> e.bodyAs<MirrorStart>() },
        "mirror.config" to { e -> e.bodyAs<MirrorConfig>() },
        "mirror.stopped" to { e -> e.bodyAs<MirrorStopped>() },
        "input.touch" to { e -> e.bodyAs<InputTouch>() },
        "input.key" to { e -> e.bodyAs<InputKey>() },
        "input.scroll" to { e -> e.bodyAs<InputScroll>() },
        "media.state" to { e -> e.bodyAs<MediaState>() },
        "media.action" to { e -> e.bodyAs<MediaAction>() },
        "error" to { e -> e.bodyAs<ErrorBody>() },
    )

    @Test
    fun allExamplesDecode() {
        val types = listOf(
            "hello", "auth", "auth.ok", "pair.request", "pair.accept", "pair.reject", "unpair", "ping", "pong",
            "status.update", "settings.update", "notification.posted", "notification.removed", "notification.action",
            "notification.clearAll", "sms.threads.get", "sms.threads", "sms.messages.get", "sms.messages", "sms.received",
            "sms.send", "sms.sent", "sms.markRead", "call.state", "call.action", "calllog.get", "calllog", "contacts.get",
            "contacts", "photos.list", "photos", "photo.get", "file.offer", "file.accept", "file.reject", "file.progress",
            "file.done", "clipboard.set", "mirror.start", "mirror.stop", "mirror.config", "mirror.stopped", "input.touch",
            "input.key", "input.scroll", "find.ring", "find.stop", "media.state", "media.action", "error",
        )
        for (t in types) {
            val env = Envelope.decode(resource("$t.json").toByteArray())
            assertEquals(t, env.type)
            decoders[t]?.invoke(env)
            // Round trip
            val again = Envelope.decode(env.encode())
            assertEquals(env, again)
        }
    }

    @Test
    fun frameRoundTrip() {
        val env = Envelope.of(MsgType.SMS_SEND, SmsSend("+49170", "Grüße 👋"))
        val out = ByteArrayOutputStream()
        Frames.writeEnvelope(out, env)
        val bytes = out.toByteArray()
        val len = ((bytes[0].toInt() and 0xff) shl 24) or ((bytes[1].toInt() and 0xff) shl 16) or
            ((bytes[2].toInt() and 0xff) shl 8) or (bytes[3].toInt() and 0xff)
        assertEquals(bytes.size - 4, len)
        val back = Frames.readEnvelope(ByteArrayInputStream(bytes))
        assertEquals("Grüße 👋", back.bodyAs<SmsSend>().text)
    }

    @Test
    fun pairingProofMatchesTestVector() {
        val v = ProtocolJson.parseToJsonElement(resource("_test-vectors.json")) as kotlinx.serialization.json.JsonObject
        fun s(k: String) = (v[k] as kotlinx.serialization.json.JsonPrimitive).content
        val token = java.util.Base64.getDecoder().decode(s("pairToken"))
        assertEquals(s("proof"), PairingManager.hmacProof(token, s("certFingerprint"), s("keyFingerprint")))
        assertEquals(
            s("authMessage"),
            PairingManager.authMessage(s("authMessageChallenge"), s("certFingerprint")).toString(Charsets.UTF_8),
        )
    }

    @Test
    fun qrParses() {
        val qr = ProtocolJson.decodeFromString(PairingQr.serializer(), resource("_pairing-qr.json"))
        assertEquals(47805, qr.port)
        assertEquals(64, qr.keyFingerprint.length)
    }

    @Test
    fun annexBSplit() {
        val data = byteArrayOf(0, 0, 0, 1, 0x67, 1, 2, 0, 0, 1, 0x68, 3, 0, 0, 0, 1, 0x65, 9, 9, 9)
        val nals = MirrorService.splitAnnexB(data)
        assertEquals(3, nals.size)
        assertArrayEquals(byteArrayOf(0x67, 1, 2), nals[0])
        assertArrayEquals(byteArrayOf(0x68, 3), nals[1])
        assertTrue(nals[2][0].toInt() == 0x65)
    }
}
