import CryptoKit
import Foundation
import Network

/// One file transfer over the data channel (port 47801, PROTOCOL.md §5).
final class DataChannel {
    typealias Progress = (Int64) -> Void

    private let connection: NWConnection
    private let queue = DispatchQueue(label: "link.data", qos: .userInitiated)
    private var finished = false

    private init(connection: NWConnection) {
        self.connection = connection
    }

    static func open(manager: ConnectionManager) -> DataChannel? {
        guard let endpoint = manager.channelEndpoint(port: 47801) else { return nil }
        let channel = DataChannel(connection: NWConnection(to: endpoint, using: manager.channelParameters(queue: DispatchQueue(label: "link.data.tls"))!))
        return channel
    }

    func cancel() {
        connection.cancel()
    }

    private func sendHeader(_ header: ChannelHeader) {
        let data = MessageCodec.frame((try? JSONEncoder().encode(header)) ?? Data())
        connection.send(content: data, completion: .contentProcessed { _ in })
    }

    private func finish(_ completion: @escaping (Result<Void, Error>) -> Void, _ result: Result<Void, Error>) {
        guard !finished else { return }
        finished = true
        DispatchQueue.main.async { completion(result) }
    }

    /// Phone -> Mac: receives `size` bytes into `destination` and verifies SHA-256.
    func download(token: String, transferId: String, size: Int64, sha256: String, to destination: URL,
                  progress: @escaping Progress, completion: @escaping (Result<Void, Error>) -> Void) {
        FileManager.default.createFile(atPath: destination.path, contents: nil)
        guard let handle = try? FileHandle(forWritingTo: destination) else {
            completion(.failure(CocoaError(.fileWriteNoPermission)))
            return
        }
        var hasher = SHA256()
        var received: Int64 = 0
        var lastReport = Date.distantPast

        func receiveChunk() {
            connection.receive(minimumIncompleteLength: 1, maximumLength: 512 * 1024) { [weak self] data, _, isComplete, error in
                guard let self else { return }
                if let data, !data.isEmpty {
                    let take = data.prefix(Int(min(Int64(data.count), size - received)))
                    handle.write(take)
                    hasher.update(data: take)
                    received += Int64(take.count)
                    if Date().timeIntervalSince(lastReport) > 0.2 || received == size {
                        lastReport = Date()
                        let r = received
                        DispatchQueue.main.async { progress(r) }
                    }
                }
                if received >= size {
                    self.complete(handle, &hasher, sha256, completion)
                    return
                }
                if let error {
                    try? handle.close()
                    self.connection.cancel()
                    self.finish(completion, .failure(error))
                    return
                }
                if isComplete {
                    try? handle.close()
                    self.connection.cancel()
                    self.finish(completion, .failure(LinkError.remote(String(localized: "Übertragung abgebrochen"))))
                    return
                }
                receiveChunk()
            }
        }
        connection.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                self.sendHeader(ChannelHeader(sessionToken: token, transferId: transferId, direction: "download"))
                if size == 0 { self.complete(handle, &hasher, sha256, completion) } else { receiveChunk() }
            case let .failed(error), let .waiting(error):
                try? handle.close()
                self.connection.cancel()
                self.finish(completion, .failure(error))
            default: break
            }
        }

        connection.start(queue: queue)
    }

    private func complete(_ handle: FileHandle, _ hasher: inout SHA256, _ expected: String, _ completion: @escaping (Result<Void, Error>) -> Void) {
        try? handle.close()
        connection.cancel()
        let digest = Data(hasher.finalize()).hexString
        finish(completion, digest == expected.lowercased() ? .success(()) : .failure(LinkError.integrity))
    }

    /// Mac -> Phone: streams the file. Completion fires when all bytes were handed to the network;
    /// the phone confirms with `file.done` on the control channel.
    func upload(token: String, transferId: String, from source: URL,
                progress: @escaping Progress, completion: @escaping (Result<Void, Error>) -> Void) {
        guard let handle = try? FileHandle(forReadingFrom: source) else {
            completion(.failure(CocoaError(.fileReadNoPermission)))
            return
        }
        var sent: Int64 = 0
        var lastReport = Date.distantPast

        func sendNext() {
            let chunk = handle.readData(ofLength: 64 * 1024)
            if chunk.isEmpty {
                try? handle.close()
                let s = sent
                DispatchQueue.main.async { progress(s) }
                finish(completion, .success(()))
                return
            }
            connection.send(content: chunk, completion: .contentProcessed { [weak self] error in
                guard let self else { return }
                if let error {
                    try? handle.close()
                    self.finish(completion, .failure(error))
                    return
                }
                sent += Int64(chunk.count)
                if Date().timeIntervalSince(lastReport) > 0.2 {
                    lastReport = Date()
                    let s = sent
                    DispatchQueue.main.async { progress(s) }
                }
                sendNext()
            })
        }

        connection.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                self.sendHeader(ChannelHeader(sessionToken: token, transferId: transferId, direction: "upload"))
                sendNext()
            case let .failed(error), let .waiting(error):
                try? handle.close()
                self.connection.cancel()
                self.finish(completion, .failure(error))
            default: break
            }
        }
        connection.start(queue: queue)
    }
}

enum FileHashing {
    /// Streams a file through SHA-256.
    static func sha256(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while true {
            let chunk = handle.readData(ofLength: 1024 * 1024)
            if chunk.isEmpty { break }
            hasher.update(data: chunk)
        }
        return Data(hasher.finalize()).hexString
    }
}
