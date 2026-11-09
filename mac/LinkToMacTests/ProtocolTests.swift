import CryptoKit
import XCTest
@testable import LinkToMac

final class ProtocolTests: XCTestCase {
    private var examplesDir: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("shared/protocol-examples")
    }

    private func load(_ name: String) throws -> Data {
        try Data(contentsOf: examplesDir.appendingPathComponent(name))
    }

    func testAllExamplesDecode() throws {
        let files = try FileManager.default.contentsOfDirectory(atPath: examplesDir.path).filter { $0.hasSuffix(".json") && !$0.hasPrefix("_") }
        XCTAssertGreaterThan(files.count, 40)
        for f in files {
            let msg = try Incoming(data: try load(f))
            XCTAssertEqual(msg.type + ".json", f)
            switch msg.type {
            case MsgType.hello: _ = try msg.body(HelloBody.self)
            case MsgType.statusUpdate: _ = try msg.body(StatusBody.self)
            case MsgType.notificationPosted: _ = try msg.body(NotificationPostedBody.self)
            case MsgType.smsThreads: _ = try msg.body(SmsThreadsBody.self)
            case MsgType.smsMessages: _ = try msg.body(SmsMessagesBody.self)
            case MsgType.smsReceived: _ = try msg.body(SmsReceivedBody.self)
            case MsgType.callState: _ = try msg.body(CallStateBody.self)
            case MsgType.calllog: _ = try msg.body(CallLogBody.self)
            case MsgType.contacts: _ = try msg.body(ContactsBody.self)
            case MsgType.photos: _ = try msg.body(PhotosBody.self)
            case MsgType.fileOffer: _ = try msg.body(FileOfferBody.self)
            case MsgType.fileDone: _ = try msg.body(FileDoneBody.self)
            case MsgType.fileProgress: _ = try msg.body(FileProgressBody.self)
            case MsgType.clipboardSet: _ = try msg.body(ClipboardSetBody.self)
            case MsgType.mirrorConfig: _ = try msg.body(MirrorConfigBody.self)
            case MsgType.mediaState: _ = try msg.body(MediaStateBody.self)
            case MsgType.pairRequest: _ = try msg.body(PairRequestBody.self)
            case MsgType.authOk: _ = try msg.body(AuthOkBody.self)
            case MsgType.error: _ = try msg.body(ErrorBody.self)
            case MsgType.inputTouch: _ = try msg.body(InputTouchBody.self)
            default: break
            }
        }
    }

    func testFrameRoundTrip() throws {
        let out = Outgoing(type: MsgType.smsSend, body: SmsSendBody(address: "+49170", text: "Grüße 👋"))
        let data = try MessageCodec.encode(out)
        var reader = FrameReader()
        reader.append(data.prefix(3))
        XCTAssertNil(try reader.next())
        reader.append(data.dropFirst(3))
        let frame = try XCTUnwrap(try reader.next())
        let msg = try Incoming(data: frame)
        XCTAssertEqual(try msg.body(SmsSendBody.self).text, "Grüße 👋")
        XCTAssertNil(try reader.next())
    }

    func testPairingProofMatchesAndroid() throws {
        let v = try JSONSerialization.jsonObject(with: try load("_test-vectors.json")) as! [String: String]
        let token = try XCTUnwrap(Data(base64Encoded: v["pairToken"]!))
        XCTAssertEqual(AuthCrypto.pairingProof(token: token, certFingerprint: v["certFingerprint"]!, keyFingerprint: v["keyFingerprint"]!), v["proof"])
        XCTAssertEqual(String(decoding: AuthCrypto.authMessage(challenge: v["authMessageChallenge"]!, certFingerprint: v["certFingerprint"]!), as: UTF8.self), v["authMessage"])
    }

    func testQRDecodes() throws {
        let qr = try JSONDecoder().decode(PairingQR.self, from: try load("_pairing-qr.json"))
        XCTAssertEqual(qr.port, 47805)
    }

    func testSignatureIsJavaCompatibleDER() throws {
        let key = P256.Signing.PrivateKey()
        let sig = try key.signature(for: Data("x".utf8)).derRepresentation
        XCTAssertEqual(sig.first, 0x30) // ASN.1 SEQUENCE like Java's SHA256withECDSA
        XCTAssertEqual(key.publicKey.derRepresentation.count, 91) // SubjectPublicKeyInfo for X509EncodedKeySpec
    }

    func testOneTimeCode() {
        XCTAssertEqual(OneTimeCode.find(in: "Dein Bestätigungscode lautet 482913."), "482913")
        XCTAssertEqual(OneTimeCode.find(in: "Your verification code: 123-456"), "123456")
        XCTAssertNil(OneTimeCode.find(in: "Treffen um 2024 Uhr?"))
        XCTAssertNil(OneTimeCode.find(in: "Ruf mich an: 0170 1234567"))
    }

    func testNalSplit() {
        let data = Data([0, 0, 0, 1, 0x67, 1, 2, 0, 0, 1, 0x68, 3, 0, 0, 0, 1, 0x65, 9])
        let nals = H264Decoder.nalUnits(data)
        XCTAssertEqual(nals.count, 3)
        XCTAssertEqual(nals[0], Data([0x67, 1, 2]))
        XCTAssertEqual(nals[2], Data([0x65, 9]))
    }
}
