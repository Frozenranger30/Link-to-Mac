import Foundation

enum CodecError: Error {
    case frameTooLarge(Int)
}

/// Length-prefixed framing: 4 byte big endian length + payload (PROTOCOL.md §2).
enum MessageCodec {
    static let maxFrame = 16 * 1024 * 1024

    static func frame(_ payload: Data) -> Data {
        var length = UInt32(payload.count).bigEndian
        var data = Data(bytes: &length, count: 4)
        data.append(payload)
        return data
    }

    static func encode<T: Encodable>(_ message: Outgoing<T>) throws -> Data {
        frame(try message.encoded())
    }
}

/// Accumulates bytes and yields complete frames.
struct FrameReader {
    private var buffer = Data()

    mutating func append(_ data: Data) {
        buffer.append(data)
    }

    /// Returns the next complete frame payload, or nil if more data is needed.
    mutating func next() throws -> Data? {
        guard buffer.count >= 4 else { return nil }
        let start = buffer.startIndex
        let length = Int(buffer[start]) << 24 | Int(buffer[start + 1]) << 16 | Int(buffer[start + 2]) << 8 | Int(buffer[start + 3])
        guard length <= MessageCodec.maxFrame else { throw CodecError.frameTooLarge(length) }
        guard buffer.count >= 4 + length else { return nil }
        let payload = buffer.subdata(in: (start + 4)..<(start + 4 + length))
        buffer.removeSubrange(start..<(start + 4 + length))
        buffer = Data(buffer) // re-base indices
        return payload
    }

    /// Takes up to `count` raw bytes that are already buffered (used after a header frame).
    mutating func takeRaw(max count: Int) -> Data {
        let n = min(count, buffer.count)
        let chunk = buffer.prefix(n)
        buffer.removeFirst(n)
        buffer = Data(buffer)
        return Data(chunk)
    }

    var bufferedCount: Int { buffer.count }
}

extension Data {
    var hexString: String { map { String(format: "%02x", $0) }.joined() }
}
