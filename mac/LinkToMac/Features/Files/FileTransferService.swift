import AppKit
import Foundation
import UniformTypeIdentifiers

/// File transfers in both directions with progress (F6, PROTOCOL.md §5).
final class FileTransferService: ObservableObject {
    enum Direction { case incoming, outgoing }

    enum State: Equatable {
        case offered      // incoming, waiting for the user's decision
        case waiting      // waiting for the other side
        case running
        case done
        case failed(String)
    }

    struct Transfer: Identifiable, Equatable {
        let id: String
        let name: String
        let size: Int64
        let direction: Direction
        var bytes: Int64 = 0
        var state: State
        var url: URL?
        let date = Date()

        var fraction: Double { size > 0 ? min(1, Double(bytes) / Double(size)) : (state == .done ? 1 : 0) }
    }

    @Published private(set) var transfers: [Transfer] = []

    private let connection: ConnectionManager
    private let settings: AppSettings
    private var sources: [String: URL] = [:]
    private var offers: [String: FileOfferBody] = [:]
    private var photoExpectations: [String: (URL, (Result<URL, Error>) -> Void)] = [:]
    private var channels: [String: DataChannel] = [:]
    var onReceived: ((Transfer) -> Void)?

    init(connection: ConnectionManager, settings: AppSettings) {
        self.connection = connection
        self.settings = settings
        connection.on(MsgType.fileOffer) { [weak self] msg in
            guard let self, let offer = try? msg.body(FileOfferBody.self) else { return }
            self.incomingOffer(offer, replyTo: msg.id)
        }
        connection.on(MsgType.fileAccept) { [weak self] msg in
            guard let self, let r = try? msg.body(FileReplyBody.self) else { return }
            self.startUpload(r.transferId)
        }
        connection.on(MsgType.fileReject) { [weak self] msg in
            guard let self, let r = try? msg.body(FileReplyBody.self) else { return }
            self.finishOutgoing(r.transferId, ok: false, error: r.reason == "feature_disabled"
                ? String(localized: "Dateiempfang ist auf dem Handy ausgeschaltet") : String(localized: "Vom Handy abgelehnt"))
        }
        connection.on(MsgType.fileProgress) { [weak self] msg in
            guard let self, let p = try? msg.body(FileProgressBody.self) else { return }
            self.update(p.transferId) { $0.bytes = max($0.bytes, p.bytes) }
        }
        connection.on(MsgType.fileDone) { [weak self] msg in
            guard let self, let d = try? msg.body(FileDoneBody.self) else { return }
            self.finishOutgoing(d.transferId, ok: d.ok, error: d.error)
        }
        connection.onDisconnected { [weak self] in
            guard let self else { return }
            for t in self.transfers where t.state == .running || t.state == .waiting || t.state == .offered {
                self.update(t.id) { $0.state = .failed(String(localized: "Verbindung getrennt")) }
            }
            self.channels.values.forEach { $0.cancel() }
            self.channels.removeAll()
            let expectations = self.photoExpectations
            self.photoExpectations.removeAll()
            expectations.values.forEach { $0.1(.failure(LinkError.notConnected)) }
        }
    }

    // MARK: Mac -> Phone

    func send(urls: [URL]) {
        for url in urls { send(url: url) }
    }

    func send(url: URL) {
        guard connection.isConnected else { return }
        let id = UUID().uuidString.lowercased()
        let accessing = url.startAccessingSecurityScopedResource()
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize).map { Int64($0) } ?? 0
        let isDir = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
        guard !isDir else {
            if accessing { url.stopAccessingSecurityScopedResource() }
            transfers.insert(Transfer(id: id, name: url.lastPathComponent, size: 0, direction: .outgoing,
                                      state: .failed(String(localized: "Ordner können nicht gesendet werden"))), at: 0)
            return
        }
        transfers.insert(Transfer(id: id, name: url.lastPathComponent, size: size, direction: .outgoing, state: .waiting, url: url), at: 0)
        sources[id] = url
        DispatchQueue.global(qos: .userInitiated).async {
            let hash = try? FileHashing.sha256(of: url)
            DispatchQueue.main.async {
                guard let hash else {
                    self.finishOutgoing(id, ok: false, error: String(localized: "Datei konnte nicht gelesen werden"))
                    return
                }
                let mime = UTType(filenameExtension: url.pathExtension)?.preferredMIMEType ?? "application/octet-stream"
                let offer = FileOfferBody(transferId: id, name: url.lastPathComponent, size: size, mime: mime, sha256: hash, purpose: "file")
                if self.connection.send(MsgType.fileOffer, offer) == nil {
                    self.finishOutgoing(id, ok: false, error: LinkError.notConnected.localizedDescription)
                }
            }
        }
    }

    private func startUpload(_ id: String) {
        guard let url = sources[id], let token = connection.sessionToken, let channel = DataChannel.open(manager: connection) else { return }
        channels[id] = channel
        update(id) { $0.state = .running }
        channel.upload(token: token, transferId: id, from: url, progress: { [weak self] sent in
            self?.update(id) { $0.bytes = max($0.bytes, sent) }
        }, completion: { [weak self] result in
            if case let .failure(error) = result {
                self?.finishOutgoing(id, ok: false, error: error.localizedDescription)
            }
            // On success we wait for file.done from the phone.
        })
    }

    private func finishOutgoing(_ id: String, ok: Bool, error: String?) {
        channels.removeValue(forKey: id)?.cancel()
        if let url = sources.removeValue(forKey: id) { url.stopAccessingSecurityScopedResource() }
        update(id) {
            $0.state = ok ? .done : .failed(error ?? String(localized: "Fehlgeschlagen"))
            if ok { $0.bytes = $0.size }
        }
    }

    // MARK: Phone -> Mac

    func expectPhoto(transferId: String, destination: URL, completion: @escaping (Result<URL, Error>) -> Void) {
        photoExpectations[transferId] = (destination, completion)
        DispatchQueue.main.asyncAfter(deadline: .now() + 120) { [weak self] in
            if let e = self?.photoExpectations.removeValue(forKey: transferId) { e.1(.failure(LinkError.timeout)) }
        }
    }

    func cancelExpectation(_ transferId: String) {
        photoExpectations.removeValue(forKey: transferId)
    }

    private func incomingOffer(_ offer: FileOfferBody, replyTo: String) {
        if offer.purpose == "photo" {
            guard let expectation = photoExpectations.removeValue(forKey: offer.transferId) else {
                connection.send(MsgType.fileReject, FileReplyBody(transferId: offer.transferId, reason: "unexpected"), replyTo: replyTo)
                return
            }
            let (dest, completion) = expectation
            let tmp = dest.appendingPathExtension("part")
            download(offer, to: tmp, visible: false) { result in
                switch result {
                case .success:
                    try? FileManager.default.removeItem(at: dest)
                    do {
                        try FileManager.default.moveItem(at: tmp, to: dest)
                        completion(.success(dest))
                    } catch {
                        completion(.failure(error))
                    }
                case let .failure(error):
                    try? FileManager.default.removeItem(at: tmp)
                    completion(.failure(error))
                }
            }
            connection.send(MsgType.fileAccept, FileReplyBody(transferId: offer.transferId), replyTo: replyTo)
            return
        }
        offers[offer.transferId] = offer
        transfers.insert(Transfer(id: offer.transferId, name: offer.name, size: offer.size, direction: .incoming, state: .offered), at: 0)
        if settings.autoAcceptFiles { accept(offer.transferId) }
    }

    func accept(_ id: String) {
        guard let offer = offers.removeValue(forKey: id) else { return }
        let dest = Self.uniqueDownloadURL(name: offer.name)
        update(id) {
            $0.state = .waiting
            $0.url = dest
        }
        download(offer, to: dest, visible: true) { [weak self] result in
            guard let self else { return }
            switch result {
            case .success:
                self.update(id) { $0.state = .done; $0.bytes = $0.size }
                if let t = self.transfers.first(where: { $0.id == id }) { self.onReceived?(t) }
            case let .failure(error):
                try? FileManager.default.removeItem(at: dest)
                self.update(id) { $0.state = .failed(error.localizedDescription) }
            }
        }
        connection.send(MsgType.fileAccept, FileReplyBody(transferId: id))
    }

    func reject(_ id: String) {
        offers.removeValue(forKey: id)
        connection.send(MsgType.fileReject, FileReplyBody(transferId: id, reason: "declined"))
        update(id) { $0.state = .failed(String(localized: "Abgelehnt")) }
    }

    private func download(_ offer: FileOfferBody, to dest: URL, visible: Bool, completion: @escaping (Result<Void, Error>) -> Void) {
        guard let token = connection.sessionToken, let channel = DataChannel.open(manager: connection) else {
            completion(.failure(LinkError.notConnected))
            return
        }
        channels[offer.transferId] = channel
        if visible { update(offer.transferId) { $0.state = .running } }
        // Give the phone a moment to process file.accept before we connect.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            channel.download(token: token, transferId: offer.transferId, size: offer.size, sha256: offer.sha256, to: dest, progress: { [weak self] bytes in
                if visible { self?.update(offer.transferId) { $0.bytes = bytes } }
            }, completion: { [weak self] result in
                guard let self else { return }
                self.channels.removeValue(forKey: offer.transferId)
                let ok: Bool
                if case .success = result { ok = true } else { ok = false }
                var errorText: String?
                if case let .failure(e) = result { errorText = e.localizedDescription }
                self.connection.send(MsgType.fileDone, FileDoneBody(transferId: offer.transferId, ok: ok, error: errorText))
                completion(result)
            })
        }
    }

    // MARK: Helpers

    private func update(_ id: String, _ change: (inout Transfer) -> Void) {
        guard let i = transfers.firstIndex(where: { $0.id == id }) else { return }
        change(&transfers[i])
    }

    func clearFinished() {
        transfers.removeAll { t in
            if case .failed = t.state { return true }
            return t.state == .done
        }
    }

    static var downloadsFolder: URL {
        FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0]
    }

    static func uniqueDownloadURL(name: String) -> URL {
        let safe = name.replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: ":", with: "_")
        let base = downloadsFolder
        var url = base.appendingPathComponent(safe)
        let ext = url.pathExtension
        let stem = url.deletingPathExtension().lastPathComponent
        var n = 2
        while FileManager.default.fileExists(atPath: url.path) {
            url = base.appendingPathComponent(ext.isEmpty ? "\(stem) \(n)" : "\(stem) \(n).\(ext)")
            n += 1
        }
        return url
    }
}
