package de.linktomac.net

import java.io.DataInputStream
import java.io.DataOutputStream
import java.io.IOException
import java.io.InputStream
import java.io.OutputStream
import java.security.MessageDigest

/** Length-prefixed frame codec: 4 byte big endian length + payload. */
object Frames {
    const val MAX_FRAME = 16 * 1024 * 1024

    fun write(out: OutputStream, payload: ByteArray) {
        val header = byteArrayOf(
            (payload.size ushr 24).toByte(),
            (payload.size ushr 16).toByte(),
            (payload.size ushr 8).toByte(),
            payload.size.toByte(),
        )
        out.write(header)
        out.write(payload)
        out.flush()
    }

    fun read(input: InputStream): ByteArray {
        val din = if (input is DataInputStream) input else DataInputStream(input)
        val len = din.readInt()
        if (len < 0 || len > MAX_FRAME) throw IOException("Invalid frame length $len")
        val buf = ByteArray(len)
        din.readFully(buf)
        return buf
    }

    fun writeEnvelope(out: OutputStream, env: Envelope) = write(out, env.encode())
    fun readEnvelope(input: InputStream): Envelope = Envelope.decode(read(input))

    /** Video frame: 8 byte pts (µs) + 4 byte length + Annex-B data. */
    fun writeVideoFrame(out: DataOutputStream, ptsUs: Long, data: ByteArray, offset: Int, length: Int) {
        out.writeLong(ptsUs)
        out.writeInt(length)
        out.write(data, offset, length)
        out.flush()
    }
}

fun ByteArray.toHex(): String = joinToString("") { "%02x".format(it) }

fun sha256Hex(bytes: ByteArray): String = MessageDigest.getInstance("SHA-256").digest(bytes).toHex()
