import AppKit
import Foundation
import Network

/// Starts/stops mirroring, receives the video stream (port 47802) and forwards input (F9).
final class MirrorController: ObservableObject {
    enum State: Equatable {
        case idle
        case requesting
        case running
        case failed(String)
    }

    @Published private(set) var state: State = .idle
    @Published private(set) var videoSize = CGSize(width: 9, height: 19.5)
    @Published var lastError: String?

    let decoder = H264Decoder()
    private let connection: ConnectionManager
    private var video: NWConnection?
    private let queue = DispatchQueue(label: "link.video", qos: .userInteractive)
    private var buffer = Data()

    var maxSize = 1280
    var bitrate = 6_000_000
    var fps = 30

    init(connection: ConnectionManager) {
        self.connection = connection
        decoder.onSize = { [weak self] size in self?.videoSize = size }
        connection.on(MsgType.mirrorConfig) { [weak self] msg in
            guard let self, let cfg = try? msg.body(MirrorConfigBody.self) else { return }
            self.videoSize = CGSize(width: cfg.width, height: cfg.height)
            if self.video == nil { self.openVideo() }
        }
        connection.on(MsgType.mirrorStopped) { [weak self] msg in
            guard let self else { return }
            let reason = (try? msg.body(MirrorStoppedBody.self))?.reason
            self.closeVideo()
            switch reason {
            case "denied": self.state = .failed(String(localized: "Die Bildschirmaufnahme wurde auf dem Handy nicht erlaubt."))
            case nil, "stopped_on_phone": self.state = .idle
            default: self.state = .failed(reason ?? "")
            }
        }
        connection.on(MsgType.error) { [weak self] msg in
            guard let self, let err = try? msg.body(ErrorBody.self) else { return }
            if err.code == "permission_denied" && err.message.contains("Bedienungshilfe") {
                self.lastError = err.message
            }
            if err.code == "feature_disabled" && self.state == .requesting {
                self.state = .failed(err.message)
            }
        }
        connection.onDisconnected { [weak self] in
            self?.closeVideo()
            self?.state = .idle
        }
    }

    func start() {
        guard connection.isConnected else { return }
        lastError = nil
        state = .requesting
        decoder.reset()
        connection.send(MsgType.mirrorStart, MirrorStartBody(maxSize: maxSize, bitrate: bitrate, fps: fps))
    }

    func stop() {
        connection.send(MsgType.mirrorStop)
        closeVideo()
        state = .idle
    }

    private func openVideo() {
        guard let endpoint = connection.channelEndpoint(port: 47802),
              let params = connection.channelParameters(queue: queue),
              let token = connection.sessionToken else { return }
        let conn = NWConnection(to: endpoint, using: params)
        video = conn
        buffer = Data()
        conn.stateUpdateHandler = { [weak self, weak conn] st in
            guard let self, let conn else { return }
            switch st {
            case .ready:
                let header = MessageCodec.frame((try? JSONEncoder().encode(ChannelHeader(sessionToken: token))) ?? Data())
                conn.send(content: header, completion: .contentProcessed { _ in })
                DispatchQueue.main.async { self.state = .running }
                self.receive(conn)
            case let .failed(error), let .waiting(error):
                DispatchQueue.main.async {
                    if self.video === conn {
                        self.closeVideo()
                        self.state = .failed(error.localizedDescription)
                    }
                }
            default: break
            }
        }
        conn.start(queue: queue)
    }

    private func receive(_ conn: NWConnection) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 1 << 20) { [weak self, weak conn] data, _, done, error in
            guard let self, let conn else { return }
            if let data { self.buffer.append(data); self.drain() }
            if done || error != nil {
                DispatchQueue.main.async {
                    if self.video === conn {
                        self.closeVideo()
                        if self.state == .running { self.state = .idle }
                    }
                }
                return
            }
            self.receive(conn)
        }
    }

    /// Parses `8 byte pts + 4 byte length + payload` frames (runs on the video queue).
    private func drain() {
        while buffer.count >= 12 {
            let b = buffer.startIndex
            let len = Int(buffer[b + 8]) << 24 | Int(buffer[b + 9]) << 16 | Int(buffer[b + 10]) << 8 | Int(buffer[b + 11])
            guard len >= 0, len < 32 << 20 else {
                buffer.removeAll()
                return
            }
            guard buffer.count >= 12 + len else { return }
            let payload = buffer.subdata(in: (b + 12)..<(b + 12 + len))
            buffer.removeSubrange(b..<(b + 12 + len))
            buffer = Data(buffer)
            decoder.decode(payload)
        }
    }

    private func closeVideo() {
        video?.cancel()
        video = nil
    }

    // MARK: Input

    func tap(_ p: CGPoint) {
        connection.send(MsgType.inputTouch, InputTouchBody(action: "tap", x: p.x, y: p.y))
    }

    func longPress(_ p: CGPoint, ms: Int) {
        connection.send(MsgType.inputTouch, InputTouchBody(action: "longpress", x: p.x, y: p.y, durationMs: ms))
    }

    func swipe(from a: CGPoint, to b: CGPoint, ms: Int) {
        connection.send(MsgType.inputTouch, InputTouchBody(action: "swipe", x: a.x, y: a.y, x2: b.x, y2: b.y, durationMs: ms))
    }

    func scroll(at p: CGPoint, dx: Double, dy: Double) {
        connection.send(MsgType.inputScroll, InputScrollBody(x: p.x, y: p.y, dx: dx, dy: dy))
    }

    func key(_ key: String, text: String? = nil) {
        connection.send(MsgType.inputKey, InputKeyBody(key: key, text: text))
    }
}
