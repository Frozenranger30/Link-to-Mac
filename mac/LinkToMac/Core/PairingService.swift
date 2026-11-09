import AppKit
import CoreImage
import Foundation
import Network

/// Shows the pairing QR code and accepts `pair.request` on port 47805 (PROTOCOL.md §3).
final class PairingService: ObservableObject {
    struct PendingRequest: Identifiable {
        let id = UUID()
        let request: PairRequestBody
        let host: String
        fileprivate let connection: NWConnection
    }

    static let port: UInt16 = 47805
    static let tokenLifetime: TimeInterval = 5 * 60

    @Published private(set) var qrImage: NSImage?
    /// The JSON encoded in the QR code (also used by the end-to-end test).
    private(set) var qrJSON: String?
    @Published private(set) var hosts: [String] = []
    @Published private(set) var expiresAt = Date()
    @Published var pending: PendingRequest?
    @Published private(set) var errorMessage: String?
    @Published private(set) var isActive = false

    var onPaired: ((PairedDevice) -> Void)?

    private let trust = TrustStore.shared
    private var token = Data()
    private var tokenUsed = false
    private var listener: NWListener?
    private var refreshTimer: Timer?
    private var readers: [ObjectIdentifier: FrameReader] = [:]

    func start() {
        guard !isActive else { return }
        isActive = true
        errorMessage = nil
        startListener()
        regenerate()
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            guard let self else { return }
            if Date() >= self.expiresAt || self.tokenUsed && self.pending == nil { self.regenerate() }
            let current = NetworkInfo.ipv4Addresses()
            if current != self.hosts { self.regenerate() }
        }
    }

    func stop() {
        isActive = false
        refreshTimer?.invalidate()
        refreshTimer = nil
        listener?.cancel()
        listener = nil
        if let p = pending { reply(p, accept: false) }
        token = Data()
    }

    /// Creates a new one-time token and QR code.
    func regenerate() {
        token = AuthCrypto.randomBytes(32)
        tokenUsed = false
        expiresAt = Date().addingTimeInterval(Self.tokenLifetime)
        hosts = NetworkInfo.ipv4Addresses()
        let qr = PairingQR(
            v: 1,
            name: NetworkInfo.computerName,
            host: hosts.first ?? "",
            hosts: hosts,
            port: Int(Self.port),
            keyFingerprint: trust.keyFingerprint,
            pairToken: token.base64EncodedString()
        )
        if let json = try? JSONEncoder().encode(qr) {
            qrJSON = String(data: json, encoding: .utf8)
            qrImage = Self.makeQR(json)
        }
        if hosts.isEmpty {
            errorMessage = String(localized: "Keine WLAN-Verbindung gefunden. Verbinde den Mac mit demselben WLAN wie das Handy.")
        } else if listener != nil {
            errorMessage = nil
        }
    }

    static func makeQR(_ data: Data) -> NSImage? {
        guard let filter = CIFilter(name: "CIQRCodeGenerator") else { return nil }
        filter.setValue(data, forKey: "inputMessage")
        filter.setValue("M", forKey: "inputCorrectionLevel")
        guard let output = filter.outputImage?.transformed(by: CGAffineTransform(scaleX: 10, y: 10)) else { return nil }
        let rep = NSCIImageRep(ciImage: output)
        let image = NSImage(size: rep.size)
        image.addRepresentation(rep)
        return image
    }

    // MARK: Listener

    private func startListener() {
        do {
            let params = NWParameters.tcp
            params.allowLocalEndpointReuse = true
            let l = try NWListener(using: params, on: NWEndpoint.Port(rawValue: Self.port)!)
            l.newConnectionHandler = { [weak self] conn in self?.accept(conn) }
            l.stateUpdateHandler = { [weak self] state in
                if case let .failed(error) = state {
                    self?.errorMessage = String(localized: "Kopplungs-Port nicht verfügbar: \(error.localizedDescription)")
                }
            }
            l.start(queue: .main)
            listener = l
        } catch {
            errorMessage = String(localized: "Kopplungs-Port nicht verfügbar: \(error.localizedDescription)")
        }
    }

    private func accept(_ conn: NWConnection) {
        readers[ObjectIdentifier(conn)] = FrameReader()
        conn.stateUpdateHandler = { [weak self, weak conn] state in
            guard let conn else { return }
            switch state {
            case .failed, .cancelled:
                self?.readers.removeValue(forKey: ObjectIdentifier(conn))
                if self?.pending?.connection === conn { self?.pending = nil }
            default: break
            }
        }
        conn.start(queue: .main)
        receive(conn)
        // Drop idle connections.
        DispatchQueue.main.asyncAfter(deadline: .now() + 15) { [weak self, weak conn] in
            guard let self, let conn, self.pending?.connection !== conn, self.readers[ObjectIdentifier(conn)] != nil else { return }
            conn.cancel()
        }
    }

    private func receive(_ conn: NWConnection) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self, weak conn] data, _, isComplete, error in
            guard let self, let conn else { return }
            let key = ObjectIdentifier(conn)
            if let data { self.readers[key]?.append(data) }
            if let frame = try? self.readers[key]?.next() {
                self.readers.removeValue(forKey: key)
                self.handle(frame, from: conn)
                return
            }
            if isComplete || error != nil {
                conn.cancel()
                return
            }
            self.receive(conn)
        }
    }

    private func handle(_ frame: Data, from conn: NWConnection) {
        guard let msg = try? Incoming(data: frame), msg.type == MsgType.pairRequest,
              let req = try? msg.body(PairRequestBody.self) else {
            conn.cancel()
            return
        }
        let expected = AuthCrypto.pairingProof(token: token, certFingerprint: req.certFingerprint, keyFingerprint: trust.keyFingerprint)
        let valid = !token.isEmpty && !tokenUsed && Date() < expiresAt && constantTimeEquals(expected, req.proof)
            && req.certFingerprint.count == 64
        guard valid else {
            sendAndClose(conn, Outgoing(type: MsgType.pairReject, replyTo: msg.id, body: PairRejectBody(reason: "invalid_or_expired")))
            errorMessage = String(localized: "Ungültiger oder abgelaufener QR-Code. Bitte erneut scannen.")
            regenerate()
            return
        }
        tokenUsed = true
        var host = ""
        if case let .hostPort(h, _) = conn.endpoint { host = ConnectionManager.hostString(h) }
        if let old = pending { reply(old, accept: false) }
        pending = PendingRequest(request: req, host: host, connection: conn)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// Answers the pending request after the user decided.
    func reply(_ p: PendingRequest, accept: Bool) {
        if pending?.id == p.id { pending = nil }
        if accept {
            let body = PairAcceptBody(macName: NetworkInfo.computerName, publicKey: trust.publicKeyDER.base64EncodedString())
            sendAndClose(p.connection, Outgoing(type: MsgType.pairAccept, body: body))
            let device = PairedDevice(
                name: p.request.deviceName,
                model: p.request.model,
                certFingerprint: p.request.certFingerprint.lowercased(),
                lastHost: p.host.isEmpty ? nil : p.host,
                port: p.request.port
            )
            trust.pairedDevice = device
            onPaired?(device)
        } else {
            sendAndClose(p.connection, Outgoing(type: MsgType.pairReject, body: PairRejectBody(reason: "declined")))
            regenerate()
        }
    }

    private func sendAndClose<T: Encodable>(_ conn: NWConnection, _ msg: Outgoing<T>) {
        guard let data = try? MessageCodec.encode(msg) else {
            conn.cancel()
            return
        }
        conn.send(content: data, completion: .contentProcessed { _ in
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { conn.cancel() }
        })
    }

    private func constantTimeEquals(_ a: String, _ b: String) -> Bool {
        let x = Array(a.utf8), y = Array(b.utf8)
        guard x.count == y.count else { return false }
        var diff: UInt8 = 0
        for i in 0..<x.count { diff |= x[i] ^ y[i] }
        return diff == 0
    }
}
