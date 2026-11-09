import Foundation

/// Message types, see docs/PROTOCOL.md §7.
enum MsgType {
    static let hello = "hello"
    static let auth = "auth"
    static let authOk = "auth.ok"
    static let pairRequest = "pair.request"
    static let pairAccept = "pair.accept"
    static let pairReject = "pair.reject"
    static let unpair = "unpair"
    static let ping = "ping"
    static let pong = "pong"
    static let statusUpdate = "status.update"
    static let settingsUpdate = "settings.update"
    static let notificationPosted = "notification.posted"
    static let notificationRemoved = "notification.removed"
    static let notificationAction = "notification.action"
    static let notificationClearAll = "notification.clearAll"
    static let smsThreadsGet = "sms.threads.get"
    static let smsThreads = "sms.threads"
    static let smsMessagesGet = "sms.messages.get"
    static let smsMessages = "sms.messages"
    static let smsReceived = "sms.received"
    static let smsSend = "sms.send"
    static let smsSent = "sms.sent"
    static let smsMarkRead = "sms.markRead"
    static let callState = "call.state"
    static let callAction = "call.action"
    static let calllogGet = "calllog.get"
    static let calllog = "calllog"
    static let contactsGet = "contacts.get"
    static let contacts = "contacts"
    static let photosList = "photos.list"
    static let photos = "photos"
    static let photoGet = "photo.get"
    static let fileOffer = "file.offer"
    static let fileAccept = "file.accept"
    static let fileReject = "file.reject"
    static let fileProgress = "file.progress"
    static let fileDone = "file.done"
    static let clipboardSet = "clipboard.set"
    static let mirrorStart = "mirror.start"
    static let mirrorStop = "mirror.stop"
    static let mirrorConfig = "mirror.config"
    static let mirrorStopped = "mirror.stopped"
    static let inputTouch = "input.touch"
    static let inputKey = "input.key"
    static let inputScroll = "input.scroll"
    static let findRing = "find.ring"
    static let findStop = "find.stop"
    static let mediaState = "media.state"
    static let mediaAction = "media.action"
    static let error = "error"
}

let protocolVersion = 1

/// Header part of every control message (the body is decoded separately).
struct EnvelopeHeader: Decodable {
    let id: String
    let type: String
    let ts: Int64?
    let replyTo: String?
}

private struct BodyWrapper<T: Decodable>: Decodable {
    let body: T
}

struct Empty: Codable, Equatable {}

/// An incoming message: header plus the raw JSON so the body can be decoded lazily.
struct Incoming {
    let header: EnvelopeHeader
    let raw: Data

    var type: String { header.type }
    var id: String { header.id }
    var replyTo: String? { header.replyTo }

    init(data: Data) throws {
        raw = data
        header = try JSONDecoder().decode(EnvelopeHeader.self, from: data)
    }

    func body<T: Decodable>(_ type: T.Type) throws -> T {
        try JSONDecoder().decode(BodyWrapper<T>.self, from: raw).body
    }
}

/// An outgoing message.
struct Outgoing<T: Encodable>: Encodable {
    var id: String = UUID().uuidString.lowercased()
    let type: String
    var ts: Int64 = Int64(Date().timeIntervalSince1970 * 1000)
    var replyTo: String?
    let body: T

    func encoded() throws -> Data {
        let enc = JSONEncoder()
        enc.outputFormatting = [.withoutEscapingSlashes]
        return try enc.encode(self)
    }
}

// MARK: - Bodies

struct HelloBody: Codable {
    var deviceName: String
    var model: String?
    var appVersion: String
    var protocolVersion: Int
    var capabilities: [String]
    var challenge: String?
}

struct AuthBody: Codable {
    let keyFingerprint: String
    let signature: String
}

struct AuthOkBody: Codable {
    let sessionToken: String
}

struct PairRequestBody: Codable {
    let deviceName: String
    let model: String
    let port: Int
    let certFingerprint: String
    let proof: String
}

struct PairAcceptBody: Codable {
    let macName: String
    let publicKey: String
}

struct PairRejectBody: Codable {
    let reason: String?
}

struct StatusBody: Codable, Equatable {
    var battery: Int
    var charging: Bool
    var wifiSignal: Int
    var network: String
    var cellSignal: Int?
    var dnd: Bool
    var carrier: String?
}

struct SettingsUpdateBody: Codable {
    let features: [String: Bool]
}

struct NotificationActionInfo: Codable, Hashable {
    let title: String
    let isReply: Bool
}

struct NotificationPostedBody: Codable, Identifiable, Equatable {
    let key: String
    let app: String
    let appName: String
    var appIconPng: String?
    let title: String
    let text: String
    let time: Int64
    let actions: [NotificationActionInfo]
    let canReply: Bool

    var id: String { key }
    var date: Date { Date(timeIntervalSince1970: TimeInterval(time) / 1000) }
}

struct NotificationKeyBody: Codable {
    let key: String
}

struct NotificationActionBody: Codable {
    let key: String
    let actionIndex: Int
    let replyText: String?
}

struct SmsThreadsGetBody: Codable {
    let limit: Int
}

struct SmsThread: Codable, Identifiable, Equatable {
    let threadId: Int64
    let address: String
    var contactName: String?
    var snippet: String
    var date: Int64
    var unread: Int

    var id: Int64 { threadId }
    var displayName: String { contactName ?? address }
}

struct SmsThreadsBody: Codable {
    let threads: [SmsThread]
}

struct SmsMessagesGetBody: Codable {
    let threadId: Int64
    let before: Int64?
    let limit: Int
}

struct SmsMessage: Codable, Identifiable, Equatable {
    let id: Int64
    let threadId: Int64
    let address: String
    let body: String
    let date: Int64
    let outgoing: Bool
    let read: Bool
}

struct SmsMessagesBody: Codable {
    let threadId: Int64
    let messages: [SmsMessage]
}

struct SmsReceivedBody: Codable {
    let message: SmsMessage
    let contactName: String?
}

struct SmsSendBody: Codable {
    let address: String
    let text: String
}

struct SmsSentBody: Codable {
    let ok: Bool
    let error: String?
}

struct SmsMarkReadBody: Codable {
    let threadId: Int64
}

struct CallStateBody: Codable, Equatable {
    let state: String
    let number: String?
    let contactName: String?
}

struct CallActionBody: Codable {
    let action: String
    let number: String?
}

struct CallLogGetBody: Codable {
    let limit: Int
}

struct CallEntry: Codable, Identifiable, Equatable {
    let id: Int64
    let number: String
    let contactName: String?
    let type: String
    let date: Int64
    let duration: Int64
}

struct CallLogBody: Codable {
    let calls: [CallEntry]
}

struct Contact: Codable, Hashable {
    let name: String
    let numbers: [String]
}

struct ContactsBody: Codable {
    let contacts: [Contact]
}

struct PhotosListBody: Codable {
    let offset: Int
    let limit: Int
}

struct PhotoInfo: Codable, Identifiable, Equatable {
    let id: Int64
    let date: Int64
    let width: Int
    let height: Int
    let name: String
    let mime: String
    let thumbJpeg: String
}

struct PhotosBody: Codable {
    let offset: Int
    let total: Int
    let photos: [PhotoInfo]
}

struct PhotoGetBody: Codable {
    let id: Int64
    let transferId: String
}

struct FileOfferBody: Codable {
    let transferId: String
    let name: String
    let size: Int64
    let mime: String
    let sha256: String
    var purpose: String?
}

struct FileReplyBody: Codable {
    let transferId: String
    var reason: String?
}

struct FileProgressBody: Codable {
    let transferId: String
    let bytes: Int64
    let size: Int64
}

struct FileDoneBody: Codable {
    let transferId: String
    let ok: Bool
    let error: String?
}

struct ClipboardSetBody: Codable {
    let mime: String
    var text: String?
    var dataBase64: String?
}

struct MirrorStartBody: Codable {
    let maxSize: Int
    let bitrate: Int
    let fps: Int
}

struct MirrorConfigBody: Codable {
    let width: Int
    let height: Int
    let sps: String
    let pps: String
}

struct MirrorStoppedBody: Codable {
    let reason: String?
}

struct InputTouchBody: Codable {
    let action: String
    let x: Double
    let y: Double
    var x2: Double?
    var y2: Double?
    var durationMs: Int?
}

struct InputKeyBody: Codable {
    let key: String
    var text: String?
}

struct InputScrollBody: Codable {
    let x: Double
    let y: Double
    let dx: Double
    let dy: Double
}

struct MediaStateBody: Codable, Equatable {
    let active: Bool
    var playing: Bool?
    var title: String?
    var artist: String?
    var app: String?
    var appName: String?
    var artPng: String?
}

struct MediaActionBody: Codable {
    let action: String
}

struct ErrorBody: Codable {
    let code: String
    let message: String
}

/// Header frame for data/video channels.
struct ChannelHeader: Codable {
    let sessionToken: String
    var transferId: String?
    var direction: String?
}

/// QR code content.
struct PairingQR: Codable {
    let v: Int
    let name: String
    let host: String
    let hosts: [String]
    let port: Int
    let keyFingerprint: String
    let pairToken: String
}
