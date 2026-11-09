import AppKit
import CryptoKit
import Foundation
import Network

/// Builds TLS parameters that only accept the phone certificate with the pinned fingerprint.
enum PinnedTLS {
    static func parameters(fingerprint: String, onMismatch: (() -> Void)? = nil, queue: DispatchQueue) -> NWParameters {
        let tls = NWProtocolTLS.Options()
        let sec = tls.securityProtocolOptions
        sec_protocol_options_set_min_tls_protocol_version(sec, .TLSv12)
        sec_protocol_options_set_verify_block(sec, { _, trustRef, complete in
            let trust = sec_trust_copy_ref(trustRef).takeRetainedValue()
            var ok = false
            if let chain = SecTrustCopyCertificateChain(trust) as? [SecCertificate], let leaf = chain.first {
                let der = SecCertificateCopyData(leaf) as Data
                ok = Data(SHA256.hash(data: der)).hexString == fingerprint.lowercased()
            }
            if !ok { onMismatch?() }
            complete(ok)
        }, queue)
        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true
        tcp.enableKeepalive = true
        tcp.keepaliveIdle = 10
        tcp.connectionTimeout = 6
        return NWParameters(tls: tls, tcp: tcp)
    }
}

enum LinkError: LocalizedError {
    case notConnected
    case timeout
    case remote(String)
    case integrity

    var errorDescription: String? {
        switch self {
        case .notConnected: return String(localized: "Nicht mit dem Handy verbunden")
        case .timeout: return String(localized: "Das Handy antwortet nicht")
        case let .remote(msg): return msg
        case .integrity: return String(localized: "Die Prüfsumme der Datei stimmt nicht")
        }
    }
}

/// Owns the control connection to the phone (PROTOCOL.md §4). All callbacks run on the main queue.
final class ConnectionManager: ObservableObject {
    enum State: Equatable {
        case notPaired
        case searching
        case connecting
        case connected
        case failed(String)
    }

    @Published private(set) var state: State = .notPaired
    @Published private(set) var phoneName: String?
    @Published private(set) var phoneModel: String?
    @Published private(set) var capabilities: [String] = []
    @Published private(set) var lastError: String?

    private(set) var sessionToken: String?
    private(set) var remoteHost: NWEndpoint.Host?

    private let trust = TrustStore.shared
    private var connection: NWConnection?
    private var reader = FrameReader()
    private var browser: NWBrowser?
    private var bonjourEndpoints: [NWEndpoint] = []
    private var attempt = 0
    private var reconnectWork: DispatchWorkItem?
    private var heartbeat: Timer?
    private var lastReceived = Date()
    private var pinMismatch = false
    private var pending: [String: (Result<Incoming, Error>) -> Void] = [:]
    private var handlers: [String: [(Incoming) -> Void]] = [:]
    private var connectedHandlers: [() -> Void] = []
    private var disconnectedHandlers: [() -> Void] = []
    private var pathMonitor: NWPathMonitor?

    var isConnected: Bool { state == .connected }

    init() {
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in self?.reconnectNow() }
        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { [weak self] path in
            if path.status == .satisfied { self?.reconnectSoon(delay: 1) }
        }
        monitor.start(queue: .main)
        pathMonitor = monitor
    }

    // MARK: Public API

    func on(_ type: String, _ handler: @escaping (Incoming) -> Void) {
        handlers[type, default: []].append(handler)
    }

    func onConnected(_ handler: @escaping () -> Void) {
        connectedHandlers.append(handler)
    }

    func onDisconnected(_ handler: @escaping () -> Void) {
        disconnectedHandlers.append(handler)
    }

    /// Starts connecting to the paired phone (if any).
    func start() {
        guard trust.pairedDevice != nil else {
            state = .notPaired
            return
        }
        if state == .notPaired || isFailedState { state = .searching }
        startBrowser()
        reconnectNow()
        startHeartbeat()
    }

    func stop() {
        reconnectWork?.cancel()
        heartbeat?.invalidate()
        browser?.cancel()
        browser = nil
        drop(reason: nil)
        state = .notPaired
    }

    func reconnectNow() {
        guard trust.pairedDevice != nil, !isConnected else { return }
        reconnectWork?.cancel()
        if connection == nil { connectNext() }
    }

    @discardableResult
    func send<T: Encodable>(_ type: String, _ body: T, replyTo: String? = nil) -> String? {
        guard let connection, isConnected || type == MsgType.auth || type == MsgType.hello else { return nil }
        let msg = Outgoing(type: type, replyTo: replyTo, body: body)
        guard let data = try? MessageCodec.encode(msg) else { return nil }
        connection.send(content: data, completion: .contentProcessed { _ in })
        return msg.id
    }

    func send(_ type: String) {
        send(type, Empty())
    }

    /// Sends a request and waits for the message whose `replyTo` matches.
    func request<T: Encodable>(_ type: String, _ body: T, timeout: TimeInterval = 20) async throws -> Incoming {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Incoming, Error>) in
            DispatchQueue.main.async {
                guard let id = self.send(type, body) else {
                    cont.resume(throwing: LinkError.notConnected)
                    return
                }
                self.pending[id] = { cont.resume(with: $0) }
                DispatchQueue.main.asyncAfter(deadline: .now() + timeout) {
                    if let cb = self.pending.removeValue(forKey: id) { cb(.failure(LinkError.timeout)) }
                }
            }
        }
    }

    /// Called after a successful pairing.
    func pairedDeviceChanged() {
        drop(reason: nil)
        pinMismatch = false
        lastError = nil
        state = trust.pairedDevice == nil ? .notPaired : .searching
        if trust.pairedDevice != nil { start() }
    }

    // MARK: Connecting

    private var isFailedState: Bool {
        if case .failed = state { return true }
        return false
    }

    private func candidates() -> [NWEndpoint] {
        guard let device = trust.pairedDevice else { return [] }
        var list: [NWEndpoint] = []
        if let host = device.lastHost, let port = NWEndpoint.Port(rawValue: UInt16(device.port)) {
            list.append(.hostPort(host: NWEndpoint.Host(host), port: port))
        }
        list.append(contentsOf: bonjourEndpoints)
        return list
    }

    private func connectNext() {
        guard let device = trust.pairedDevice, connection == nil else { return }
        let list = candidates()
        guard !list.isEmpty else {
            if !isFailedState { state = .searching }
            reconnectSoon(delay: 3)
            return
        }
        let endpoint = list[attempt % list.count]
        attempt += 1
        if !isFailedState { state = .connecting }
        pinMismatch = false
        let params = PinnedTLS.parameters(fingerprint: device.certFingerprint, onMismatch: { [weak self] in
            DispatchQueue.main.async { self?.pinMismatch = true }
        }, queue: .main)
        let conn = NWConnection(to: endpoint, using: params)
        connection = conn
        reader = FrameReader()
        conn.stateUpdateHandler = { [weak self, weak conn] newState in
            guard let self, let conn, conn === self.connection else { return }
            switch newState {
            case .ready:
                self.lastReceived = Date()
                if case let .hostPort(host, _)? = conn.currentPath?.remoteEndpoint {
                    self.remoteHost = host
                }
                self.receive(on: conn)
            case let .waiting(error), let .failed(error):
                if self.pinMismatch {
                    self.state = .failed(String(localized: "Das Zertifikat des Handys hat sich geändert. Bitte neu koppeln."))
                } else {
                    self.lastError = error.localizedDescription
                }
                self.drop(reason: error.localizedDescription)
            case .cancelled:
                break
            default:
                break
            }
        }
        conn.start(queue: .main)
        // Give up on this endpoint if the handshake takes too long.
        DispatchQueue.main.asyncAfter(deadline: .now() + 8) { [weak self, weak conn] in
            guard let self, let conn, conn === self.connection, self.sessionToken == nil else { return }
            self.drop(reason: "timeout")
        }
    }

    private func reconnectSoon(delay: TimeInterval) {
        guard trust.pairedDevice != nil, !isConnected else { return }
        reconnectWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.connectNext() }
        reconnectWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func drop(reason: String?) {
        let wasConnected = isConnected
        if let conn = connection {
            conn.stateUpdateHandler = nil
            conn.cancel()
        }
        connection = nil
        sessionToken = nil
        let callbacks = pending
        pending.removeAll()
        callbacks.values.forEach { $0(.failure(LinkError.notConnected)) }
        if trust.pairedDevice != nil {
            if !isFailedState { state = .searching }
            if wasConnected { disconnectedHandlers.forEach { $0() } }
            reconnectSoon(delay: wasConnected ? 1 : 3)
        }
    }

    // MARK: Receiving

    private func receive(on conn: NWConnection) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 256 * 1024) { [weak self, weak conn] data, _, isComplete, error in
            guard let self, let conn, conn === self.connection else { return }
            if let data, !data.isEmpty {
                self.lastReceived = Date()
                self.reader.append(data)
                do {
                    while let frame = try self.reader.next() {
                        self.handleFrame(frame)
                        if conn !== self.connection { return }
                    }
                } catch {
                    self.drop(reason: "framing")
                    return
                }
            }
            if isComplete || error != nil {
                self.drop(reason: error?.localizedDescription ?? "closed")
                return
            }
            self.receive(on: conn)
        }
    }

    private func handleFrame(_ data: Data) {
        guard let msg = try? Incoming(data: data) else { return }
        if let replyTo = msg.replyTo, let cb = pending.removeValue(forKey: replyTo) {
            cb(msg.type == MsgType.error ? .failure(LinkError.remote((try? msg.body(ErrorBody.self).message) ?? "Fehler")) : .success(msg))
            if msg.type != MsgType.error { return }
        }
        switch msg.type {
        case MsgType.hello:
            handleHello(msg)
        case MsgType.authOk:
            handleAuthOk(msg)
        case MsgType.ping:
            send(MsgType.pong, Empty(), replyTo: msg.id)
        case MsgType.pong:
            break
        case MsgType.unpair:
            handlers[MsgType.unpair]?.forEach { $0(msg) }
        case MsgType.error:
            if let err = try? msg.body(ErrorBody.self) {
                if err.code == "unauthorized" {
                    state = .failed(String(localized: "Das Handy kennt diesen Mac nicht mehr. Bitte neu koppeln."))
                    drop(reason: "unauthorized")
                    return
                }
                lastError = err.message
            }
            handlers[MsgType.error]?.forEach { $0(msg) }
        default:
            handlers[msg.type]?.forEach { $0(msg) }
        }
    }

    private func handleHello(_ msg: Incoming) {
        guard let hello = try? msg.body(HelloBody.self), let device = trust.pairedDevice else { return }
        phoneName = hello.deviceName
        phoneModel = hello.model
        capabilities = hello.capabilities
        guard let challenge = hello.challenge else { return }
        do {
            let signature = try trust.sign(AuthCrypto.authMessage(challenge: challenge, certFingerprint: device.certFingerprint))
            send(MsgType.auth, AuthBody(keyFingerprint: trust.keyFingerprint, signature: signature.base64EncodedString()))
            send(MsgType.hello, HelloBody(
                deviceName: NetworkInfo.computerName,
                model: "Mac",
                appVersion: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0",
                protocolVersion: protocolVersion,
                capabilities: ["notifications", "sms", "calls", "photos", "files", "clipboard", "mirror", "media", "find"],
                challenge: nil
            ))
        } catch {
            lastError = error.localizedDescription
        }
    }

    private func handleAuthOk(_ msg: Incoming) {
        guard let ok = try? msg.body(AuthOkBody.self) else { return }
        sessionToken = ok.sessionToken
        attempt = max(0, attempt - 1) // keep using the endpoint that worked
        lastError = nil
        state = .connected
        if var device = trust.pairedDevice {
            if let host = remoteHost {
                device.lastHost = Self.hostString(host)
            }
            if let name = phoneName { device.name = name }
            trust.pairedDevice = device
        }
        connectedHandlers.forEach { $0() }
    }

    static func hostString(_ host: NWEndpoint.Host) -> String {
        switch host {
        case let .ipv4(addr): return "\(addr)".components(separatedBy: "%").first ?? "\(addr)"
        case let .ipv6(addr): return "\(addr)"
        case let .name(name, _): return name
        @unknown default: return "\(host)"
        }
    }

    // MARK: Heartbeat

    private func startHeartbeat() {
        heartbeat?.invalidate()
        heartbeat = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [weak self] _ in
            guard let self else { return }
            if self.isConnected {
                if Date().timeIntervalSince(self.lastReceived) > 30 {
                    self.drop(reason: "heartbeat")
                } else {
                    self.send(MsgType.ping)
                }
            } else if self.connection == nil {
                self.reconnectNow()
            }
        }
    }

    // MARK: Bonjour

    private func startBrowser() {
        guard browser == nil else { return }
        let b = NWBrowser(for: .bonjourWithTXTRecord(type: "_linktomac._tcp", domain: nil), using: .tcp)
        b.browseResultsChangedHandler = { [weak self] results, _ in
            guard let self, let device = self.trust.pairedDevice else { return }
            let prefix = String(device.certFingerprint.prefix(16))
            self.bonjourEndpoints = results.compactMap { result in
                if case let .bonjour(txt) = result.metadata, let fp = txt["fp"], fp != prefix {
                    return nil
                }
                return result.endpoint
            }
            if !self.isConnected, self.connection == nil { self.reconnectNow() }
        }
        b.start(queue: .main)
        browser = b
    }

    // MARK: Data channels

    /// Endpoint of the data (47801) or video (47802) port on the phone.
    func channelEndpoint(port: UInt16) -> NWEndpoint? {
        guard let host = remoteHost, let p = NWEndpoint.Port(rawValue: port) else { return nil }
        return .hostPort(host: host, port: p)
    }

    func channelParameters(queue: DispatchQueue) -> NWParameters? {
        guard let device = trust.pairedDevice else { return nil }
        return PinnedTLS.parameters(fingerprint: device.certFingerprint, queue: queue)
    }
}
